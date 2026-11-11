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
        let entries = try await readEntries(context)
        if context.output.json {
            context.output.json(ControlConfigDocument(entries: entries))
        } else {
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
        let entries = try await readEntries(context)
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
        if let location = try? context.control {
            do {
                let entry: ControlConfigEntry = try await location.client.post(
                    "/v1/config", body: ControlConfigSet(key: key, value: value), timeout: context.timeout)
                if context.output.json {
                    context.output.json(entry)
                } else {
                    context.output.success("\(key) = \(entry.value)")
                }
                return CLIExit.success.rawValue
            } catch let error as CLIError where error.exit == .notRunning {
                // The runtime file outlived the app; fall through to the
                // offline writer instead of failing a pure setting.
            }
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
        let entries = try await readEntries(context)
        guard let entry = entries.first(where: { $0.key == key }) else {
            throw CLIError("未知设置项：\(key)", exit: .notFound)
        }
        guard entry.kind == "string" else {
            throw CLIError("\(key) 不是字符串设置项，不能清空；请显式 set 一个值", exit: .usage)
        }
        if let location = try? context.control {
            do {
                let updated: ControlConfigEntry = try await location.client.post(
                    "/v1/config", body: ControlConfigSet(key: key, value: ""), timeout: context.timeout)
                if context.output.json {
                    context.output.json(updated)
                } else {
                    context.output.success("\(key) = ")
                }
                return CLIExit.success.rawValue
            } catch let error as CLIError where error.exit == .notRunning {
                // Fall through to the offline writer.
            }
        }
        try OfflineConfig.set(key: key, value: "", context: context)
        context.output.success("\(key) = ")
        return CLIExit.success.rawValue
    }

    private static func readEntries(_ context: CLIContext) async throws -> [ControlConfigEntry] {
        if let location = try? context.control {
            do {
                let document: ControlConfigDocument = try await location.client.get(
                    "/v1/config", timeout: context.timeout)
                return document.entries
            } catch let error as CLIError where error.exit == .notRunning {
                // 应用没在跑：磁盘上的配置就是当下的事实。
            }
            // 401 / 超时 / 后端 500 不能「降级成磁盘上的旧值」——那会把一个
            // 出错的运行时报成一份看起来正常的配置。
        }
        if LocalState.engineConfigurationIsUnreadable() {
            context.output.warning("engines.json 无法解析，引擎相关的值读不到；文件路径："
                                   + FlashCatPaths.engineConfigurationFile)
        }
        return OfflineConfig.entries(context)
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
enum OfflineConfig {
    static func entries(_ context: CLIContext) -> [ControlConfigEntry] {
        let local = context.local
        let defaults = UserDefaults(suiteName: FlashCatPaths.preferencesDomain)
        func string(_ key: String, fallback: String = "") -> String {
            defaults?.string(forKey: key) ?? fallback
        }
        func int(_ key: String, fallback: Int) -> Int {
            (defaults?.object(forKey: key) as? NSNumber)?.intValue ?? fallback
        }
        func double(_ key: String, fallback: Double) -> Double {
            (defaults?.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
        }
        func bool(_ key: String, fallback: Bool) -> Bool {
            guard defaults?.object(forKey: key) != nil else { return fallback }
            return defaults?.bool(forKey: key) ?? fallback
        }

        let appearance: String
        switch int("appearance", fallback: 0) {
        case 1: appearance = "light"
        case 2: appearance = "dark"
        default: appearance = "system"
        }
        let thinking: String
        switch int("thinkingMode", fallback: 0) {
        case 1: thinking = "off"
        case 2: thinking = "on"
        default: thinking = "auto"
        }
        let reasoning = ["low", "medium", "high", "xhigh"][
            min(max(int("reasoningEffort", fallback: 2) - 1, 0), 3)
        ]

        var rows: [ControlConfigEntry] = [
            entry("appearance", "外观", "enum", appearance),
            entry("autoStart", "随应用启动引擎", "bool", CLIFormat.bool(bool("autoStart", fallback: false))),
            // 这几项由应用持有（要同步 LaunchAgent / 启停监听），离线写不进去，
            // 所以如实报 mutable:false，而不是先答应再 exit 6。
            entry("launchAtLogin", "登录时启动", "bool", CLIFormat.bool(bool("launchAtLogin", fallback: false)), mutable: false),
            entry("gatewayEnabled", "API 网关", "bool", CLIFormat.bool(local.gatewayEnabled), mutable: false),
            entry("gatewayPort", "API 网关端口", "int", String(local.gatewayPort), mutable: false),
            entry("controlAPIEnabled", "命令行接口", "bool", CLIFormat.bool(local.controlEnabled), mutable: false),
            entry("controlPort", "命令行接口端口", "int", String(local.controlPort), mutable: false),
            // 0 是「还没写过」，在线文档会归一成 8000；离线也照同一个口径报，
            // 否则同一条命令在线离线读出两个端口。
            entry("port", "默认引擎端口", "int", String(normalizedPort(int("port", fallback: 8000)))),
            entry("model", "当前模型", "string", local.selectedModel, mutable: false),
            entry("thinkingMode", "思考模式", "enum", thinking),
            entry("reasoningEffort", "推理等级", "enum", reasoning),
            entry("temperature", "温度", "double", String(format: "%.2f", double("chat.temperature", fallback: 0.7))),
            entry("topP", "Top P", "double", String(format: "%.2f", double("chat.topP", fallback: 0.95))),
            entry("maxTokens", "最大输出", "int", String(int("chat.maxTokens", fallback: 0))),
            entry("systemPrompt", "系统提示", "string", string("chat.system")),
            entry("hfCache", "下载缓存目录", "string", string("hfCache")),
            entry("maxMemory", "最大内存参数", "string", string("maxMemory")),
            entry("maxContext", "最大上下文参数", "string", string("maxContext")),
            entry("extraArgs", "额外启动参数", "string", string("extraArgs")),
            entry("idleReleaseOff", "常驻权重", "bool", CLIFormat.bool(bool("idleReleaseOff", fallback: false))),
            entry("languageOnly", "纯文本", "bool", CLIFormat.bool(bool("languageOnly", fallback: false))),
            entry("hfEndpoint", "Hugging Face 端点", "string", string("hfEndpoint")),
            entry("hfToken", "Hugging Face Token", "string", string("hfToken")),
        ]
        for id in EngineCatalog.allIDs {
            rows.append(entry("engines.\(id.rawValue).port",
                              "\(id.displayName) 端口",
                              "int",
                              String(normalizedPort(local.engineConfiguration.port[id.rawValue] ?? id.defaultPort)),
                              mutable: false))
        }
        return rows
    }

    static func set(key: String, value: String, context: CLIContext) throws {
        guard let defaults = UserDefaults(suiteName: FlashCatPaths.preferencesDomain) else {
            throw CLIError("无法打开应用偏好设置", exit: .failure)
        }
        func bool() throws -> Bool {
            switch value.lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: throw CLIError("\(key) 需要 true / false", exit: .usage)
            }
        }
        func int(_ range: ClosedRange<Int>) throws -> Int {
            guard let parsed = Int(value), range.contains(parsed) else {
                throw CLIError("\(key) 需要 \(range.lowerBound)…\(range.upperBound) 的整数", exit: .usage)
            }
            return parsed
        }
        func double(_ range: ClosedRange<Double>) throws -> Double {
            guard let parsed = Double(value), range.contains(parsed) else {
                throw CLIError("\(key) 需要 \(range.lowerBound)…\(range.upperBound) 的数字", exit: .usage)
            }
            return parsed
        }

        switch key {
        case "appearance":
            let raw: Int
            switch value.lowercased() {
            case "system": raw = 0
            case "light": raw = 1
            case "dark": raw = 2
            default: throw CLIError("appearance 只能是 system / light / dark", exit: .usage)
            }
            defaults.set(raw, forKey: "appearance")
        case "autoStart": defaults.set(try bool(), forKey: "autoStart")
        case "thinkingMode":
            let raw: Int
            switch value.lowercased() {
            case "auto", "automatic": raw = 0
            case "off": raw = 1
            case "on": raw = 2
            default: throw CLIError("thinkingMode 只能是 auto / off / on", exit: .usage)
            }
            defaults.set(raw, forKey: "thinkingMode")
        case "reasoningEffort":
            let raw: Int
            switch value.lowercased() {
            case "low": raw = 1
            case "medium": raw = 2
            case "high": raw = 3
            case "xhigh": raw = 4
            default: throw CLIError("reasoningEffort 只能是 low / medium / high / xhigh", exit: .usage)
            }
            defaults.set(raw, forKey: "reasoningEffort")
        case "temperature": defaults.set(try double(0...2), forKey: "chat.temperature")
        case "topP": defaults.set(try double(0...1), forKey: "chat.topP")
        case "maxTokens": defaults.set(try int(0...1_000_000), forKey: "chat.maxTokens")
        case "systemPrompt": defaults.set(value, forKey: "chat.system")
        case "hfCache": defaults.set(value, forKey: "hfCache")
        case "maxMemory": defaults.set(value, forKey: "maxMemory")
        case "maxContext": defaults.set(value, forKey: "maxContext")
        case "extraArgs": defaults.set(value, forKey: "extraArgs")
        case "idleReleaseOff": defaults.set(try bool(), forKey: "idleReleaseOff")
        case "languageOnly": defaults.set(try bool(), forKey: "languageOnly")
        case "hfEndpoint": defaults.set(value, forKey: "hfEndpoint")
        case "hfToken": defaults.set(value, forKey: "hfToken")
        case "port": defaults.set(try int(1024...65535), forKey: "port")
        case "model":
            throw CLIError("model 是只读项；用 flashcat models use <模型>", exit: .usage)
        case "launchAtLogin":
            throw CLIError("launchAtLogin 需要应用在运行（要同步 LaunchAgent）", exit: .conflict,
                           hint: "先 flashcat app open，再设置")
        case "gatewayEnabled", "gatewayPort", "controlAPIEnabled", "controlPort":
            throw CLIError("\(key) 需要应用在运行才能立即生效", exit: .conflict,
                           hint: "先 flashcat app open，再设置")
        default:
            if key.hasPrefix("engines."), key.hasSuffix(".port") {
                throw CLIError("引擎端口需要应用在运行", exit: .conflict,
                               hint: "先 flashcat app open；或直接改 \(FlashCatPaths.engineConfigurationFile)")
            }
            throw CLIError("未知设置项：\(key)", exit: .notFound,
                           hint: "运行 flashcat config list 查看全部键")
        }
        _ = context
        defaults.synchronize()
    }

    /// `0` 与负数都表示「没配置」，对外统一显示默认端口。
    private static func normalizedPort(_ value: Int) -> Int {
        value > 0 ? value : 8000
    }

    private static func entry(_ key: String, _ title: String, _ kind: String,
                              _ value: String, mutable: Bool = true) -> ControlConfigEntry {
        ControlConfigEntry(kind: kind, key: key, title: title, value: value, mutable: mutable)
    }
}
