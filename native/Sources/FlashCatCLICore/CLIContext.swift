// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation

/// Finds the app bundle the CLI belongs to. When the command is symlinked into
/// `~/.local/bin` the executable resolves back into the bundle, so `app open`
/// and the bundled pack index still find the right installation.
public enum AppLocator {
    public static func resolve(
        environment: [String: String],
        executable: String = CommandLine.arguments.first ?? ""
    ) -> URL? {
        if let explicit = environment["FLASHCAT_APP"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            return url.pathExtension == "app" ? url : url.deletingLastPathComponent()
        }
        if let fromExecutable = bundleContaining(executable: executable) { return fromExecutable }
        if Bundle.main.bundlePath.hasSuffix(".app") { return Bundle.main.bundleURL }
        return installed(environment: environment)
    }

    public static func installed(environment: [String: String]) -> URL? {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let candidates = [
            "/Applications/flashCat.app",
            home + "/Applications/flashCat.app",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public static func bundleContaining(executable: String) -> URL? {
        guard !executable.isEmpty else { return nil }
        var url = URL(fileURLWithPath: executable)
        // `argv[0]` can be a PATH-resolved name; Bundle.main knows the real
        // file when it exists.
        if !FileManager.default.fileExists(atPath: url.path),
            let resolved = Bundle.main.executableURL
        {
            url = resolved
        }
        url = url.resolvingSymlinksInPath()
        if url.pathExtension == "app" { return url }
        var cursor = url.deletingLastPathComponent()
        for _ in 0..<6 {
            if cursor.pathExtension == "app" { return cursor }
            // `.../flashCat.app/Contents/Helpers/flashcat`
            if cursor.lastPathComponent == "Contents" {
                let bundle = cursor.deletingLastPathComponent()
                if bundle.pathExtension == "app" { return bundle }
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        return nil
    }

    public static func resourceRoot(_ app: URL?) -> URL? {
        guard let app else { return nil }
        return app.appendingPathComponent("Contents/Resources")
    }

    public static func engineResourceRoot(_ app: URL?) -> String? {
        resourceRoot(app)?.appendingPathComponent("engines").path
    }
}

/// Read-only view of the files the app writes, used when the control server is
/// not reachable. No command mutates files through this type except
/// `config set`, which goes through UserDefaults directly.
public struct LocalState {
    public let environment: [String: String]
    public let app: URL?
    /// `engines.json` 的位置；测试注入临时文件，避免读到真实应用的引擎配置。
    public let engineConfigurationFile: String
    private let defaults: UserDefaults?

    /// `defaults` / `engineConfigurationFile` 可注入：`config` 的离线路径要能用临时域与临时
    /// 文件跑单测，否则测试会写坏用户真实的偏好设置和 engines.json。
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults? = nil,
        engineConfigurationFile: String = FlashCatPaths.engineConfigurationFile
    ) {
        self.environment = environment
        self.app = AppLocator.resolve(environment: environment)
        self.defaults = defaults ?? UserDefaults(suiteName: FlashCatPaths.preferencesDomain)
        self.engineConfigurationFile = engineConfigurationFile
    }

    public var extraEngineRoots: [String] {
        AppLocator.engineResourceRoot(app).map { [$0] } ?? []
    }

    public func installed(_ id: EngineID) -> [EngineInstallation] {
        EngineInstallations.installed(id, extraRoots: extraEngineRoots)
    }

    public func newest(_ id: EngineID) -> EngineInstallation? {
        EngineInstallations.newest(id, version: nil, extraRoots: extraEngineRoots)
    }

    public var installedIDs: [EngineID] {
        EngineCatalog.allIDs.filter { newest($0) != nil }
    }

    public func string(_ key: String) -> String? {
        defaults?.string(forKey: key)
    }

    public func integer(_ key: String, fallback: Int) -> Int {
        guard let value = defaults?.object(forKey: key) as? NSNumber else { return fallback }
        return value.intValue
    }

    public func bool(_ key: String, fallback: Bool) -> Bool {
        guard defaults?.object(forKey: key) != nil else { return fallback }
        return defaults?.bool(forKey: key) ?? fallback
    }

    public func double(_ key: String, fallback: Double) -> Double {
        guard let value = defaults?.object(forKey: key) as? NSNumber else { return fallback }
        return value.doubleValue
    }

    public var gatewayPort: Int {
        let value = integer("gatewayPort", fallback: 9000)
        return (1024...65535).contains(value) ? value : 9000
    }

    public var gatewayEnabled: Bool { bool("gatewayEnabled", fallback: true) }
    public var controlPort: Int {
        let value = integer("controlPort", fallback: 9100)
        return (1024...65535).contains(value) ? value : 9100
    }
    public var controlEnabled: Bool { bool("controlAPIEnabled", fallback: true) }
    public var selectedModel: String { string("model") ?? "" }

    /// `nil` 表示连应用偏好域都打不开（沙箱/权限问题），此时 `config set` 必须报错而不是假装写入。
    public var preferencesAvailable: Bool { defaults != nil }

    public func setPreference(_ value: Any, forKey key: String) {
        defaults?.set(value, forKey: key)
    }

    public func flushPreferences() {
        _ = defaults?.synchronize()
    }

    // MARK: engines.json

    public struct EngineConfiguration: Equatable {
        public var active: String?
        public var lastModel: [String: String] = [:]
        public var port: [String: Int] = [:]
    }

    /// 读 `engines.json` 的结果：配置本体 + 读不动时的原因。
    ///
    /// 为什么要带原因：以前这里用 `try?` 把「文件坏了」「顶层不是对象」和
    /// 「文件不存在」一律折成空配置，`status` / `config list` 于是打出一份
    /// 看起来完全正常、其实全由默认值拼出来的文档，用户看不到磁盘上那份
    /// JSON 已经损坏。文件不存在是首次启动的正常状态，不算问题。
    public struct EngineConfigurationReadout: Equatable {
        public let configuration: EngineConfiguration
        /// 非 nil 表示配置没读成、值已按空配置处理；这条理由可以直接给人看。
        public let warning: String?
    }

    /// 文件在、却读不动。调用方据此打一行警告：以前这种情况会被静默当成
    /// 「没有引擎」，`status` 于是输出一份看起来很正常的假文档。
    public func engineConfigurationIsUnreadable() -> Bool {
        engineConfigurationReadout().warning != nil
    }

    public func engineConfigurationReadout() -> EngineConfigurationReadout {
        let path = engineConfigurationFile
        guard FileManager.default.fileExists(atPath: path) else {
            return EngineConfigurationReadout(configuration: EngineConfiguration(), warning: nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            return EngineConfigurationReadout(
                configuration: EngineConfiguration(),
                warning: "engines.json 读不出来（\(error.localizedDescription)），引擎与端口按默认值处理：\(path)")
        }
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return EngineConfigurationReadout(
                    configuration: EngineConfiguration(),
                    warning: "engines.json 的顶层不是对象，引擎与端口按默认值处理：\(path)")
            }
            object = parsed
        } catch {
            return EngineConfigurationReadout(
                configuration: EngineConfiguration(),
                warning: "engines.json 解析失败（\(error.localizedDescription)），引擎与端口按默认值处理：\(path)")
        }
        return EngineConfigurationReadout(configuration: LocalState.parse(object), warning: nil)
    }

    public var engineConfiguration: EngineConfiguration {
        engineConfigurationReadout().configuration
    }

    private static func parse(_ object: [String: Any]) -> EngineConfiguration {
        var configuration = EngineConfiguration()
        if let active = object["active"] as? [String: Any],
            let version = active["version"] as? String
        {
            configuration.active = version
        }
        for (key, raw) in object {
            // `active` 与 `default` 是记账行，不是引擎：前者记上次跑过的引擎，
            // 后者是启动偏好，都不带 per-engine 的 model/port 字段。
            guard key != "active", key != "default", let value = raw as? [String: Any] else { continue }
            if let model = value["lastModel"] as? String, !model.isEmpty {
                configuration.lastModel[key] = model
            }
            if let port = value["port"] as? Int {
                configuration.port[key] = port
            }
        }
        return configuration
    }

    public var activeEngine: EngineID {
        let configuration = engineConfiguration
        if let active = configuration.active,
            let id = EngineID(rawValue: active),
            newest(id) != nil
        {
            return id
        }
        return installedIDs.first ?? .splash
    }

    public var enginePort: Int {
        let configuration = engineConfiguration
        return configuration.port[activeEngine.rawValue] ?? activeEngine.defaultPort
    }

    /// 离线文档的唯一取数口：这里只收集事实，文档长什么样由 `ControlEngineDocuments`
    /// 决定，`status --offline`、`engines --offline` 与 App 的 `/v1/status` 因此同源。
    public func engineDocumentInputs() -> [ControlEngineDocumentInput] {
        let configuration = engineConfiguration
        let active = activeEngine
        let selected = selectedModel
        return EngineCatalog.allIDs.map { id in
            ControlEngineDocumentInput(
                id: id,
                installedVersion: newest(id)?.version,
                installedVersions: installed(id).map(\.version),
                isActive: active == id,
                phase: .stopped,
                configuredPort: configuration.port[id.rawValue],
                selectedModel: selected,
                lastModel: configuration.lastModel[id.rawValue])
        }
    }

    // MARK: Models

    public struct LocalModel: Equatable, Sendable {
        public var id: String
        public var engine: String
        public var path: String
        public var bytes: Int?
    }

    /// A deliberately simple directory scan for the offline case. The app's
    /// model library also merges the built-in catalog and shared-model grants;
    /// that logic needs the running app, so `models list` says "offline view"
    /// instead of pretending the two lists are identical.
    public func localModels(engine: EngineID) -> [LocalModel] {
        let root = FlashCatPaths.modelsDirectory(engine)
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: root) else { return [] }
        var models: [LocalModel] = []
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let path = root + "/" + entry
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if engine.descriptor.modelLayout == .nested {
                guard let children = try? manager.contentsOfDirectory(atPath: path) else { continue }
                for child in children.sorted() where !child.hasPrefix(".") {
                    let childPath = path + "/" + child
                    var childIsDirectory: ObjCBool = false
                    guard manager.fileExists(atPath: childPath, isDirectory: &childIsDirectory),
                        childIsDirectory.boolValue
                    else { continue }
                    models.append(
                        LocalModel(
                            id: entry + "/" + child, engine: engine.rawValue,
                            path: childPath, bytes: directoryBytes(childPath)))
                }
            } else {
                models.append(
                    LocalModel(
                        id: entry, engine: engine.rawValue,
                        path: path, bytes: directoryBytes(path)))
            }
        }
        return models
    }

    public func directoryBytes(_ path: String) -> Int? {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return nil }
        var total = 0
        for case let item as String in enumerator {
            let full = path + "/" + item
            if let size = (try? FileManager.default.attributesOfItem(atPath: full)[.size]) as? NSNumber {
                total += size.intValue
            }
        }
        return total
    }

    public func logPath(source: String, engine: EngineID) -> String? {
        switch source {
        case "engine": return FlashCatPaths.logFile(engine)
        case "gateway": return FlashCatPaths.gatewayLogFile
        case "control": return FlashCatPaths.controlLogFile
        case "app": return FlashCatPaths.serverLogFile
        default: return nil
        }
    }
}

/// Process-wide facts shared by the command implementations.
public struct CLIContext {
    public var invocation: CLIInvocation
    public var environment: [String: String]
    public var output: CLIOutput
    public var local: LocalState
    /// stdout is a terminal. Drives colour and the "is this a person watching"
    /// notes; it must not decide whether stdin can be read.
    public var isTTY: Bool
    /// stdin is a terminal. Prompts and `chat -` read stdin only when it is
    /// *not* one (or when the user explicitly asked with `-`).
    public var stdinIsTTY: Bool
    public var executable: String

    public init(
        invocation: CLIInvocation,
        environment: [String: String],
        output: CLIOutput,
        local: LocalState,
        isTTY: Bool,
        stdinIsTTY: Bool,
        executable: String
    ) {
        self.invocation = invocation
        self.environment = environment
        self.output = output
        self.local = local
        self.isTTY = isTTY
        self.stdinIsTTY = stdinIsTTY
        self.executable = executable
    }

    public var timeout: TimeInterval {
        guard let raw = invocation.option("timeout"), let value = Double(raw), value > 0 else { return 30 }
        return value
    }

    public var longTimeout: TimeInterval {
        guard let raw = invocation.option("timeout"), let value = Double(raw), value > 0 else { return 900 }
        return value
    }

    public var control: ControlLocation {
        get throws {
            let location = try ControlLocation.discover(invocation: invocation, environment: environment)
            if output.verbose { output.note("控制接口：\(location.baseURL.absoluteString)") }
            return location
        }
    }

    /// Ask before an irreversible action. `--yes` skips the question; a
    /// non-interactive stdin refuses instead of hanging forever on readLine.
    public func confirm(_ prompt: String) throws -> Bool {
        if invocation.flag("yes") { return true }
        // 反过来写会把两个世界都对调：真终端里每个不可逆操作都直接拒绝，而
        // `flashcat ... < /dev/null` 反倒能读到 EOF、静默取消或删除。
        guard stdinIsTTY else {
            throw CLIError("这是一个不可逆操作，非交互环境需要加 --yes", exit: .conflict)
        }
        output.note(prompt + " [y/N]")
        let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }

    public func engineArgument(_ index: Int = 0) throws -> EngineID {
        guard invocation.arguments.indices.contains(index) else {
            throw CLIError(
                "需要引擎 id（\(EngineCatalog.allIDs.map(\.rawValue).joined(separator: " / "))）",
                exit: .usage)
        }
        let raw = invocation.arguments[index]
        guard let id = EngineID(rawValue: raw), EngineCatalog.allIDs.contains(id) else {
            throw CLIError(
                "未知引擎：\(raw)", exit: .usage,
                hint: "可用：" + EngineCatalog.allIDs.map(\.rawValue).joined(separator: ", "))
        }
        return id
    }
}
