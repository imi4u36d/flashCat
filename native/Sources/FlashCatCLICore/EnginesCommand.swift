import Foundation
import FlashCatKit

public enum EnginesCommand {
    public static func run(_ context: CLIContext) async throws -> Int32 {
        let action = context.invocation.subcommand ?? "list"
        switch action {
        case "list":
            return try await list(context)
        case "start":
            return try await controlAction(context, action: "start")
        case "stop":
            return try await controlAction(context, action: "stop")
        case "restart":
            return try await controlAction(context, action: "restart")
        case "use":
            return try await controlAction(context, action: "use")
        case "install":
            return try await install(context)
        case "uninstall":
            return try await uninstall(context)
        case "port":
            return try await port(context)
        case "logs":
            let engine = try context.engineArgument()
            return try await LogsCommand.run(context, engineOverride: engine)
        default:
            throw CLIError("未知 engines 子命令：\(action)", exit: .usage,
                           hint: "可用：list / start / stop / restart / use / install / uninstall / port / logs")
        }
    }

    // MARK: List

    private static func list(_ context: CLIContext) async throws -> Int32 {
        let engines: [ControlEngineState]
        do {
            let location = try context.control
            engines = try await location.client.get("/v1/engines", timeout: context.timeout)
        } catch let error as CLIError where ControlFallback.shouldFallBack(error) {
            // 判据收敛在 ControlFallback：「应用没在运行」才给磁盘视图；令牌、超时、
            // 连接错误必须冒出来，否则一份陈旧的离线列表 + exit 0 会把真正的问题藏掉。
            engines = offlineEngines(context)
        }
        if context.output.json {
            context.output.json(engines)
        } else {
            let rows = engines.map { engine in
                [engine.id,
                 engine.version,
                 engine.isActive ? "yes" : "",
                 engine.isInstalled ? CLIFormat.engineState(engine.state) : "未安装",
                 String(engine.port),
                 engine.model.isEmpty ? "—" : engine.model]
            }
            context.output.table(headers: ["ENGINE", "VERSION", "ACTIVE", "STATE", "PORT", "MODEL"],
                                 rows: rows,
                                 empty: "没有引擎")
        }
        return CLIExit.success.rawValue
    }

    private static func offlineEngines(_ context: CLIContext) -> [ControlEngineState] {
        // 与 `status --offline` 共用 Kit 的文档构造函数：以前这里少一步
        // 「active 引擎优先用 selectedModel」的回退，两个命令对同一状态给出不同结果。
        ControlEngineDocuments.engines(context.local.engineDocumentInputs())
    }

    // MARK: Start / stop / restart / use

    private static func controlAction(_ context: CLIContext, action: String) async throws -> Int32 {
        let id = try context.engineArgument()
        let location = try context.control
        let path = "/v1/engines/\(encoded(id.rawValue))/\(action)"
        let timeout: TimeInterval = action == "stop" ? max(context.timeout, 120) : context.longTimeout
        let engine: ControlEngineState = try await location.client.post(path, timeout: timeout)
        if context.output.json {
            context.output.json(engine)
        } else {
            context.output.line("\(engine.name) \(engine.version) · \(CLIFormat.engineState(engine.state))"
                                + (engine.model.isEmpty ? "" : " · \(engine.model)")
                                + " · :\(engine.port)")
        }
        return CLIExit.success.rawValue
    }

    // MARK: Install

    private static func install(_ context: CLIContext) async throws -> Int32 {
        let (id, requestedVersion) = try engineAndVersion(context)
        let index = try indexEnvironment(context)
        let installer = EngineInstaller(environment: index)
        let packIndex: EnginePackIndex
        do {
            packIndex = try await installer.loadIndex()
        } catch {
            throw CLIError("无法读取引擎包索引：\(error.localizedDescription)", exit: .failure,
                           hint: "用 --index 指定 pack-index.json，或设置 FLASHCAT_PACK_INDEX_URL")
        }
        let releases = packIndex.releases(for: id)
        guard !releases.isEmpty else {
            throw CLIError("索引里没有 \(id.displayName) 的安装包", exit: .notFound,
                           hint: "先运行 flashcat engines install --index <索引> 或检查 pack-index.json")
        }
        let release: EnginePackRelease
        if let requestedVersion {
            guard let match = releases.first(where: { $0.version == requestedVersion }) else {
                throw CLIError("\(id.displayName) 没有版本 \(requestedVersion)", exit: .notFound,
                               hint: "可用版本：" + releases.map(\.version).joined(separator: ", "))
            }
            release = match
        } else {
            release = releases[0]
        }

        let existing = context.local.newest(id)
        if existing?.version == release.version, !context.invocation.flag("force") {
            if context.output.json {
                struct Body: Encodable {
                    let engine: String
                    let version: String
                    let installed: Bool
                    let message: String
                }
                context.output.json(Body(engine: id.rawValue, version: release.version,
                                         installed: true, message: "已经安装"))
            } else {
                context.output.line("\(id.displayName) \(release.version) 已经安装，无需重复安装")
            }
            return CLIExit.success.rawValue
        }

        guard release.hasAvailableSource else {
            throw CLIError("索引里的 \(id.displayName) \(release.version) 指向本机不存在的归档",
                           exit: .notFound,
                           hint: "用 --index 指定可下载的 pack-index.json，或设置 FLASHCAT_PACK_INDEX_URL")
        }

        if !context.output.json, !context.output.quiet {
            let size = release.bytes.map { " · " + CLIFormat.bytes($0) } ?? ""
            context.output.note("安装 \(id.displayName) \(release.version)\(size)")
        }
        let progress = ProgressPrinter(json: context.output.json,
                                       quiet: context.output.quiet,
                                       interactive: CLI.isatty(FileHandle.standardError.fileDescriptor))
        do {
            let installation = try await installer.install(release, for: id) { phase in
                progress.update(phase)
            }
            progress.finish()
            await reloadApp(context)
            if context.output.json {
                struct Body: Encodable {
                    let engine: String
                    let version: String
                    let path: String
                }
                context.output.json(Body(engine: id.rawValue,
                                         version: installation.version,
                                         path: installation.root.path))
            } else {
                context.output.success("\(id.displayName) \(installation.version) 已安装到 \(installation.root.path)")
            }
            return CLIExit.success.rawValue
        } catch {
            progress.finish()
            throw CLIError("安装失败：\(error.localizedDescription)")
        }
    }

    // MARK: Uninstall

    private static func uninstall(_ context: CLIContext) async throws -> Int32 {
        let (id, requestedVersion) = try engineAndVersion(context)
        let installed = context.local.installed(id)
        guard !installed.isEmpty else {
            throw CLIError("\(id.displayName) 没有安装", exit: .notFound)
        }
        // Never retarget a requested version to the newest pack: asking for
        // `omlx@0.7.2` on a machine that only has 0.7.3 must fail, not delete
        // 0.7.3 after the user confirms a prompt that named 0.7.2.
        let version = try selectedVersion(installed.map(\.version), requested: requestedVersion)
        guard let target = installed.first(where: { $0.version == version }) else {
            throw CLIError("\(id.displayName) 没有安装版本 \(version)", exit: .notFound,
                           hint: "已安装：" + installed.map(\.version).joined(separator: ", "))
        }
        let removable = EnginePackOwnership.isRemovable(directory: target.root.path,
                                                        userRoots: EngineInstallations.userRoots())
        guard removable else {
            throw CLIError("\(id.displayName) \(target.version) 位于只读位置，不能从 CLI 删除",
                           exit: .conflict,
                           hint: "应用 bundle 和 checkout 里的 pack 由构建/签名管理")
        }
        do {
            let location = try context.control
            let engines: [ControlEngineState] = try await location.client.get(
                "/v1/engines", timeout: context.timeout)
            // 401 / 超时当成「没在跑」等于在活的进程底下删掉它的 pack，所以它们
            // 必须抛出去；只有 `.notRunning` 才允许跳过这个检查。
            if let running = engines.first(where: { $0.id == id.rawValue && $0.isRunning }) {
                throw CLIError("\(running.name) 正在运行，先停止再卸载", exit: .conflict,
                               hint: "flashcat engines stop \(id.rawValue)")
            }
        } catch let error as CLIError where ControlFallback.shouldFallBack(error) {
            // 应用没在运行：没有进程能正在跑这个 pack，跳过运行中检查。
        }
        guard try context.confirm("删除 \(id.displayName) \(target.version)（\(target.root.path)）？") else {
            context.output.note("已取消")
            return CLIExit.success.rawValue
        }
        let installer = EngineInstaller(environment: EngineInstallEnvironment(
            packsDirectory: FlashCatPaths.enginesDirectory))
        do {
            let removed = try await installer.uninstall(id, version: target.version)
            guard removed else {
                throw CLIError("没有找到 \(id.displayName) \(target.version)", exit: .notFound)
            }
            await reloadApp(context)
            if context.output.json {
                context.output.json(ControlSimpleResult(message: "已删除 \(id.rawValue) \(target.version)"))
            } else {
                context.output.success("已删除 \(id.displayName) \(target.version)")
            }
            return CLIExit.success.rawValue
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError("删除失败：\(error.localizedDescription)")
        }
    }

    // MARK: Port

    private static func port(_ context: CLIContext) async throws -> Int32 {
        let id = try context.engineArgument()
        let key = "engines.\(id.rawValue).port"
        if let raw = context.invocation.arguments.dropFirst().first {
            guard let value = Int(raw), (1024...65535).contains(value) else {
                throw CLIError("端口需要 1024…65535 的整数", exit: .usage)
            }
            let location = try context.control
            let body = ControlConfigSet(key: key, value: String(value))
            let entry: ControlConfigEntry = try await location.client.post("/v1/config", body: body,
                                                                          timeout: context.timeout)
            if context.output.json {
                context.output.json(entry)
            } else {
                context.output.line("\(id.displayName) 端口 → \(entry.value)")
            }
            return CLIExit.success.rawValue
        }

        let value: Int
        do {
            let location = try context.control
            let document: ControlConfigDocument = try await location.client.get(
                "/v1/config", timeout: context.timeout)
            if let raw = document.entries.first(where: { $0.key == key })?.value, let port = Int(raw) {
                value = ControlConfigGrammar.port(port, fallback: id.defaultPort)
            } else {
                // 在线文档里没有这一项（老版本应用）时，本地 engines.json 才是唯一线索。
                value = ControlConfigGrammar.port(context.local.engineConfiguration.port[id.rawValue],
                                                  fallback: id.defaultPort)
            }
        } catch let error as CLIError where ControlFallback.shouldFallBack(error) {
            // 只有应用没在运行时才读本地；401 / 超时用本地旧值冒充「当前端口」会让
            // 用户以为改端口失败是语法问题。
            value = ControlConfigGrammar.port(context.local.engineConfiguration.port[id.rawValue],
                                              fallback: id.defaultPort)
        }
        if context.output.json {
            struct Body: Encodable {
                let engine: String
                let port: Int
            }
            context.output.json(Body(engine: id.rawValue, port: value))
        } else {
            context.output.line("\(value)")
        }
        return CLIExit.success.rawValue
    }

    // MARK: Helpers

    private static func engineAndVersion(_ context: CLIContext) throws -> (EngineID, String?) {
        guard var raw = context.invocation.arguments.first else {
            throw CLIError("需要引擎 id", exit: .usage,
                           hint: "例如 flashcat engines install omlx")
        }
        var version = context.invocation.option("release")
        if let at = raw.firstIndex(of: "@") {
            version = String(raw[raw.index(after: at)...])
            raw = String(raw[..<at])
        }
        guard let id = EngineID(rawValue: raw), EngineCatalog.allIDs.contains(id) else {
            throw CLIError("未知引擎：\(raw)", exit: .usage,
                           hint: "可用：" + EngineCatalog.allIDs.map(\.rawValue).joined(separator: ", "))
        }
        return (id, version)
    }

    private static func indexEnvironment(_ context: CLIContext) throws -> EngineInstallEnvironment {
        var indexURL: URL?
        var bundledPath: String?
        if let raw = context.invocation.option("index") ?? context.environment["FLASHCAT_PACK_INDEX_URL"],
           !raw.isEmpty {
            if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
                guard let url = URL(string: raw) else {
                    throw CLIError("索引地址无效：\(raw)", exit: .usage)
                }
                indexURL = url
            } else {
                bundledPath = raw
            }
        } else if let bundled = bundledIndex(context) {
            bundledPath = bundled
        }
        let environment = EngineInstallEnvironment(
            packsDirectory: FlashCatPaths.enginesDirectory,
            indexURL: indexURL,
            bundledIndexPath: bundledPath)
        return environment
    }

    private static func bundledIndex(_ context: CLIContext) -> String? {
        if let app = AppLocator.resolve(environment: context.environment),
           let resources = AppLocator.resourceRoot(app) {
            let candidate = resources.appendingPathComponent("pack-index.json").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        // Development: the binary lives under .build/ and the checkout's index
        // is a few directories up.
        let candidates = [URL(fileURLWithPath: context.executable).deletingLastPathComponent(),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        for start in candidates {
            var cursor = start
            for _ in 0..<6 {
                let candidate = cursor.appendingPathComponent("pack-index.json").path
                if FileManager.default.fileExists(atPath: candidate) { return candidate }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
        }
        return nil
    }

    /// 安装/卸载后让正在运行的应用重建索引，这一步是装饰性的：应用没跑、令牌过期、
    /// 请求失败都不该把已经成功的安装变成失败，所以刻意 best-effort，不向上抛。
    private static func reloadApp(_ context: CLIContext) async {
        guard !context.invocation.flag("no-reload") else { return }
        guard let location = try? context.control else {
            // 没有 control.json 说明应用没在运行：没有可重载的对象，属预期而非错误。
            return
        }
        do {
            _ = try await location.client.postData("/v1/engines/reload", body: Data("{}".utf8),
                                                   timeout: 10)
        } catch {
            // 重载失败不影响安装结果；应用下次启动会自己重建索引。留一行 verbose 线索，
            // 免得「装完没立刻刷新」变成无从排查的怪现象。
            if context.output.verbose {
                context.output.note("重载引擎索引失败（不影响安装）：\(error)")
            }
        }
    }

    /// Pick the installed version to act on. `versions` is newest-first, so a
    /// bare uninstall targets the newest one; an explicit version must match
    /// exactly or the command fails instead of touching another pack.
    static func selectedVersion(_ versions: [String], requested: String?) throws -> String {
        guard let requested, !requested.isEmpty else {
            guard let newest = versions.first else {
                throw CLIError("没有已安装的版本", exit: .notFound)
            }
            return newest
        }
        guard versions.contains(requested) else {
            throw CLIError("没有安装版本 \(requested)", exit: .notFound,
                           hint: "已安装：" + versions.joined(separator: ", "))
        }
        return requested
    }

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

/// One install phase at a time on stderr. The installer reports progress from
/// an actor; a lock keeps two lines from interleaving.
private final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private let json: Bool
    private let quiet: Bool
    private let interactive: Bool
    private var lastLine = ""
    private var endedLine = false

    init(json: Bool, quiet: Bool, interactive: Bool) {
        self.json = json
        self.quiet = quiet
        self.interactive = interactive
    }

    func update(_ phase: EngineInstallPhase) {
        guard !json, !quiet else { return }
        let text: String?
        switch phase {
        case .resolving: text = "解析版本"
        case .downloading(let fraction, let received, let total):
            let percent = String(format: "%.0f%%", min(max(fraction, 0), 1) * 100)
            text = "下载中 \(percent) · \(CLIFormat.bytes(received))"
                + (total.map { " / " + CLIFormat.bytes($0) } ?? "")
        case .verifying: text = "校验 SHA256"
        case .unpacking: text = "解包"
        case .validating: text = "校验包"
        case .activating: text = "激活"
        case .installed: text = "完成"
        case .idle, .failed: text = nil
        }
        guard let text else { return }
        lock.lock()
        defer { lock.unlock() }
        guard text != lastLine else { return }
        lastLine = text
        let line = interactive ? "\r\u{001B}[2K  " + text : "  " + text + "\n"
        FileHandle.standardError.write(Data(line.utf8))
        if case .installed = phase {
            if interactive { FileHandle.standardError.write(Data("\n".utf8)) }
            endedLine = true
        }
    }

    func finish() {
        guard interactive, !json, !quiet, !lastLine.isEmpty, !endedLine else { return }
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data("\n".utf8))
    }
}
