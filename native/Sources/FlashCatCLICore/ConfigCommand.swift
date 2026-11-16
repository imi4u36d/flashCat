import Foundation
import FlashCatKit

public enum ConfigCommand {
    public static func run(_ context: CLIContext) async throws -> Int32 {
        switch context.invocation.subcommand ?? "list" {
        case "list": return try await list(context)
        case "get": return try await get(context)
        case "set": return try await set(context)
        case "unset": return try await unset(context)
        case "path": return path(context)
        default:
            throw CLIError("未知 config 子命令：\(context.invocation.subcommand ?? "")", exit: .usage,
                           hint: "可用：list / get / set / unset / path")
        }
    }

    // MARK: Online

    private static func list(_ context: CLIContext) async throws -> Int32 {
        let readout = try await readEntries(context)
        let entries = readout.entries
        if context.output.json {
            // `entries` 的形状不变，`warnings` 是新增键：旧脚本读 `.entries` 照常工作，
            // 而把「engines.json 读坏了」写进 stdout 的 JSON 里，才不会只留在 stderr。
            struct Document: Encodable {
                let entries: [ControlConfigEntry]
                let warnings: [String]
            }
            context.output.json(Document(entries: entries, warnings: readout.warnings))
        } else {
            for warning in readout.warnings {
                context.output.warning(warning)
            }
            context.output.table(headers: ["KEY", "VALUE", "TYPE", "TITLE"],
                                 rows: entries.map { [$0.key, $0.value, $0.kind, $0.title] },
                                 empty: "没有设置项")
        }
        return CLIExit.success.rawValue
    }

    private static func get(_ context: CLIContext) async throws -> Int32 {
        guard let key = context.invocation.arguments.first else {
            throw CLIError("需要设置项名称", exit: .usage)
        }
        let readout = try await readEntries(context)
        let entries = readout.entries
        // 单值输出没法再挂一个兄弟键，警告只能走 stderr；退出码不受影响。
        for warning in readout.warnings {
            context.output.warning(warning)
        }
        guard let entry = entries.first(where: { $0.key == key }) else {
            throw CLIError("未知设置项：\(key)", exit: .notFound,
                           hint: "运行 flashcat config list 查看全部键")
        }
        if context.output.json {
            context.output.json(entry)
        } else {
            context.output.line(entry.value)
        }
        return CLIExit.success.rawValue
    }

    private static func set(_ context: CLIContext) async throws -> Int32 {
        guard context.invocation.arguments.count >= 2 else {
            throw CLIError("需要设置项与值", exit: .usage,
                           hint: "例如 flashcat config set appearance dark")
        }
        let key = context.invocation.arguments[0]
        let value = context.invocation.arguments[1]
        do {
            let location = try context.control
            let entry: ControlConfigEntry = try await location.client.post(
                "/v1/config", body: ControlConfigSet(key: key, value: value), timeout: context.timeout)
            if context.output.json {
                context.output.json(entry)
            } else {
                context.output.success("\(key) = \(entry.value)")
            }
            return CLIExit.success.rawValue
        } catch let error as CLIError where ControlFallback.shouldFallBack(error) {
            // 只有「应用没在运行」才写离线配置。`--control-port` 写错、401、超时说明
            // 应用在跑或参数有问题，把这些折叠成离线写入会让一次失败的设置 exit 0。
        }
        try OfflineConfig.set(key: key, value: value, context: context)
        let entries = OfflineConfig.entries(context)
        let valueAfter = entries.first { $0.key == key }?.value ?? value
        if context.output.json {
            context.output.json(ControlConfigEntry(kind: entries.first { $0.key == key }?.kind ?? "string",
                                                    key: key,
                                                    title: entries.first { $0.key == key }?.title ?? key,
                                                    value: valueAfter))
        } else {
            context.output.success("\(key) = \(valueAfter)")
            context.output.note("应用当前未运行；设置在下次启动时生效。")
        }
        return CLIExit.success.rawValue
    }

    private static func unset(_ context: CLIContext) async throws -> Int32 {
        guard let key = context.invocation.arguments.first else {
            throw CLIError("需要设置项名称", exit: .usage)
        }
        let readout = try await readEntries(context)
        for warning in readout.warnings {
            context.output.warning(warning)
        }
        guard let entry = readout.entries.first(where: { $0.key == key }) else {
            throw CLIError("未知设置项：\(key)", exit: .notFound)
        }
        guard entry.kind == "string" else {
            throw CLIError("\(key) 不是字符串设置项，不能清空；请显式 set 一个值", exit: .usage)
        }
        do {
            let location = try context.control
            let updated: ControlConfigEntry = try await location.client.post(
                "/v1/config", body: ControlConfigSet(key: key, value: ""), timeout: context.timeout)
            if context.output.json {
                context.output.json(updated)
            } else {
                context.output.success("\(key) = ")
            }
            return CLIExit.success.rawValue
        } catch let error as CLIError where ControlFallback.shouldFallBack(error) {
            // 与 `set` 同一条判据：应用没在运行才退到离线清空。
        }
        try OfflineConfig.set(key: key, value: "", context: context)
        context.output.success("\(key) = ")
        return CLIExit.success.rawValue
    }

    /// 一次读取的结果。`warnings` 只可能在离线路径上有值：在线文档由应用给出，
    /// 磁盘上那份 engines.json 坏没坏不影响它。
    private struct Entries {
        var entries: [ControlConfigEntry]
        var warnings: [String]
    }

    private static func readEntries(_ context: CLIContext) async throws -> Entries {
        do {
            let location = try context.control
            let document: ControlConfigDocument = try await location.client.get(
                "/v1/config", timeout: context.timeout)
            return Entries(entries: document.entries, warnings: [])
        } catch let error as CLIError where ControlFallback.shouldFallBack(error) {
            // 应用没在跑：磁盘上的配置就是当下的事实。401 / 超时 / 后端 500 不能
            // 「降级成磁盘上的旧值」——那会把一个出错的运行时报成一份正常的配置。
        }
        // 离线值全部从磁盘拼，读不动的理由必须一起带出去，否则一份读坏的
        // engines.json 只会表现成「所有引擎端口都是默认值」这种假事实。
        let readout = context.local.engineConfigurationReadout()
        return Entries(entries: OfflineConfig.entries(context),
                       warnings: readout.warning.map { [$0] } ?? [])
    }

    // MARK: Path

    private static func path(_ context: CLIContext) -> Int32 {
        let rows = [
            ["support", FlashCatPaths.supportDirectory],
            ["engines", FlashCatPaths.enginesDirectory],
            ["models", FlashCatPaths.modelsRoot],
            ["shared", FlashCatPaths.sharedModelsDirectory],
            ["config", FlashCatPaths.engineConfigurationFile],
            ["control", FlashCatPaths.controlRuntimeFile],
            ["logs", FlashCatPaths.logsDirectory],
        ]
        if context.output.json {
            let map = Dictionary(uniqueKeysWithValues: rows.map { ($0[0], $0[1]) })
            context.output.json(map)
        } else {
            context.output.table(headers: ["NAME", "PATH"], rows: rows)
        }
        return CLIExit.success.rawValue
    }
}

/// The offline schema mirrors the keys the app reads from UserDefaults. It is
/// deliberately smaller than the server's live list: keys whose change needs a
/// running app (gateway restart, launch agent, engine port reload) are rejected
/// with a hint instead of being written into a file the app will not reread.
///
/// 读与写的语法都来自 `ControlConfigGrammar`：在线文档和这份离线文档曾经各有一套
/// 解析器，结果 `thinkingMode none` 在离线时被拒、`port` 的归一规则也各写一份。
enum OfflineConfig {
    static func entries(_ context: CLIContext) -> [ControlConfigEntry] {
        let local = context.local
        let appearance = ControlConfigGrammar.appearanceToken(local.integer("appearance", fallback: 0))
        let thinking = ControlConfigGrammar.thinkingModeToken(local.integer("thinkingMode", fallback: 0))
        let reasoning = ControlConfigGrammar.reasoningEffortToken(local.integer("reasoningEffort", fallback: 2))

        var rows: [ControlConfigEntry] = [
            entry("appearance", "外观", "enum", appearance),
            entry("autoStart", "随应用启动引擎", "bool",
                  ControlConfigGrammar.format(.bool(local.bool("autoStart", fallback: false)))),
            // 这几项由应用持有（要同步 LaunchAgent / 启停监听），离线写不进去，
            // 所以如实报 mutable:false，而不是先答应再 exit 6。
            entry("launchAtLogin", "登录时启动", "bool",
                  ControlConfigGrammar.format(.bool(local.bool("launchAtLogin", fallback: false))),
                  mutable: false),
            entry("gatewayEnabled", "API 网关", "bool",
                  ControlConfigGrammar.format(.bool(local.gatewayEnabled)), mutable: false),
            entry("gatewayPort", "API 网关端口", "int",
                  ControlConfigGrammar.format(.int(local.gatewayPort)), mutable: false),
            entry("controlAPIEnabled", "命令行接口", "bool",
                  ControlConfigGrammar.format(.bool(local.controlEnabled)), mutable: false),
            entry("controlPort", "命令行接口端口", "int",
                  ControlConfigGrammar.format(.int(local.controlPort)), mutable: false),
            // 0 是「还没写过」，规则由 grammar 归一；离线与在线必须报同一个端口。
            entry("port", "默认引擎端口", "int",
                  ControlConfigGrammar.format(.int(
                      ControlConfigGrammar.port(local.integer("port", fallback: 8000), fallback: 8000)))),
            entry("model", "当前模型", "string", local.selectedModel, mutable: false),
            entry("thinkingMode", "思考模式", "enum", thinking),
            entry("reasoningEffort", "推理等级", "enum", reasoning),
            entry("temperature", "温度", "double",
                  ControlConfigGrammar.format(.double(local.double("chat.temperature", fallback: 0.7)))),
            entry("topP", "Top P", "double",
                  ControlConfigGrammar.format(.double(local.double("chat.topP", fallback: 0.95)))),
            entry("maxTokens", "最大输出", "int",
                  ControlConfigGrammar.format(.int(local.integer("chat.maxTokens", fallback: 0)))),
            entry("systemPrompt", "系统提示", "string", local.string("chat.system") ?? ""),
            entry("hfCache", "下载缓存目录", "string", local.string("hfCache") ?? ""),
            entry("maxMemory", "最大内存参数", "string", local.string("maxMemory") ?? ""),
            entry("maxContext", "最大上下文参数", "string", local.string("maxContext") ?? ""),
            entry("extraArgs", "额外启动参数", "string", local.string("extraArgs") ?? ""),
            entry("idleReleaseOff", "常驻权重", "bool",
                  ControlConfigGrammar.format(.bool(local.bool("idleReleaseOff", fallback: false)))),
            entry("languageOnly", "纯文本", "bool",
                  ControlConfigGrammar.format(.bool(local.bool("languageOnly", fallback: false)))),
            entry("hfEndpoint", "Hugging Face 端点", "string", local.string("hfEndpoint") ?? ""),
            entry("hfToken", "Hugging Face Token", "string", local.string("hfToken") ?? ""),
        ]
        let configuration = local.engineConfiguration
        for id in EngineCatalog.allIDs {
            // 没配置过引擎端口时 `engines.json` 里没有这一项，归一到该引擎自己的默认端口。
            // 以前统一写死 8000，omlx 会显示成 8000，和 App 里的 8100 不一致。
            let port = ControlConfigGrammar.port(configuration.port[id.rawValue], fallback: id.defaultPort)
            rows.append(entry("engines.\(id.rawValue).port",
                              "\(id.displayName) 端口",
                              "int",
                              ControlConfigGrammar.format(.int(port)),
                              mutable: false))
        }
        return rows
    }

    static func set(key: String, value: String, context: CLIContext) throws {
        let local = context.local
        guard local.preferencesAvailable else {
            throw CLIError("无法打开应用偏好设置", exit: .failure)
        }
        do {
            try write(key: key, value: value, local: local)
        } catch let error as ControlConfigError {
            throw Self.cliError(error)
        }
        local.flushPreferences()
    }

    /// 所有解析与拒绝理由都来自 Kit：CLI 只决定退出码，不再自己解释一遍语法。
    private static func write(key: String, value: String, local: LocalState) throws {
        switch key {
        case "appearance":
            local.setPreference(try ControlConfigGrammar.appearance(value), forKey: "appearance")
        case "autoStart":
            local.setPreference(try ControlConfigGrammar.bool(value, key: key), forKey: "autoStart")
        case "thinkingMode":
            local.setPreference(try ControlConfigGrammar.thinkingMode(value), forKey: "thinkingMode")
        case "reasoningEffort":
            local.setPreference(try ControlConfigGrammar.reasoningEffort(value), forKey: "reasoningEffort")
        case "temperature":
            local.setPreference(try ControlConfigGrammar.double(value, key: key, range: 0...2),
                                forKey: "chat.temperature")
        case "topP":
            local.setPreference(try ControlConfigGrammar.double(value, key: key, range: 0...1),
                                forKey: "chat.topP")
        case "maxTokens":
            local.setPreference(try ControlConfigGrammar.int(value, key: key,
                                                             range: ControlConfigGrammar.maxTokensRange),
                                forKey: "chat.maxTokens")
        case "systemPrompt": local.setPreference(value, forKey: "chat.system")
        case "hfCache": local.setPreference(value, forKey: "hfCache")
        case "maxMemory": local.setPreference(value, forKey: "maxMemory")
        case "maxContext": local.setPreference(value, forKey: "maxContext")
        case "extraArgs": local.setPreference(value, forKey: "extraArgs")
        case "idleReleaseOff":
            local.setPreference(try ControlConfigGrammar.bool(value, key: key), forKey: "idleReleaseOff")
        case "languageOnly":
            local.setPreference(try ControlConfigGrammar.bool(value, key: key), forKey: "languageOnly")
        case "hfEndpoint": local.setPreference(value, forKey: "hfEndpoint")
        case "hfToken": local.setPreference(value, forKey: "hfToken")
        case "port":
            local.setPreference(try ControlConfigGrammar.int(value, key: key,
                                                             range: ControlConfigGrammar.portRange),
                                forKey: "port")
        case "model":
            throw ControlConfigError("model 是只读项；用 flashcat models use <模型>", kind: .readOnly)
        case "launchAtLogin":
            throw ControlConfigError("launchAtLogin 需要应用在运行（要同步 LaunchAgent）", kind: .conflict,
                                     hint: "先 flashcat app open，再设置")
        case "gatewayEnabled", "gatewayPort", "controlAPIEnabled", "controlPort":
            throw ControlConfigError("\(key) 需要应用在运行才能立即生效", kind: .conflict,
                                     hint: "先 flashcat app open，再设置")
        default:
            if key.hasPrefix("engines."), key.hasSuffix(".port") {
                throw ControlConfigError("引擎端口需要应用在运行", kind: .conflict,
                                         hint: "先 flashcat app open；或直接改 \(local.engineConfigurationFile)")
            }
            throw ControlConfigError("未知设置项：\(key)", kind: .notFound,
                                     hint: "运行 flashcat config list 查看全部键")
        }
    }

    /// Kit 的错误只描述「为什么」，退出码是 CLI 的约定，在这里映射。
    private static func cliError(_ error: ControlConfigError) -> CLIError {
        let exit: CLIExit
        switch error.kind {
        case .usage, .readOnly: exit = .usage
        case .conflict: exit = .conflict
        case .notFound: exit = .notFound
        }
        return CLIError(error.message, exit: exit, hint: error.hint)
    }

    private static func entry(_ key: String, _ title: String, _ kind: String,
                              _ value: String, mutable: Bool = true) -> ControlConfigEntry {
        ControlConfigEntry(kind: kind, key: key, title: title, value: value, mutable: mutable)
    }
}
