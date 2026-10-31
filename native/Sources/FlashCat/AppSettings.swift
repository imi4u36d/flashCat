import Foundation

enum ThinkingMode: Int, CaseIterable {
    case automatic = 0
    case off = 1
    case on = 2

    var label: String {
        switch self {
        case .automatic: return "自动"
        case .off: return "关闭"
        case .on: return "开启"
        }
    }

    var detail: String {
        switch self {
        case .automatic: return "跟随模型的聊天模板"
        case .off: return "直接回答，不做隐藏推理"
        case .on: return "使用指定的推理等级"
        }
    }
}

enum ReasoningEffort: Int, CaseIterable {
    case minimal = 0
    case low = 1
    case medium = 2
    case high = 3
    case xhigh = 4
    case max = 5

    var label: String {
        switch self {
        case .minimal: return "最少"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .xhigh: return "极高"
        case .max: return "最大"
        }
    }

    var token: String {
        switch self {
        case .minimal: return "minimal"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        case .max: return "max"
        }
    }
}

/// Native persistence: UserDefaults instead of a Dart preferences plugin.
final class AppSettings {
    private let defaults = UserDefaults.standard

    init() {
        importLegacyPreferences()
        migrateLegacyMaxTokensDefault()
    }

    /// 旧 SwiftUI 聊天页把 4096 当作「默认值」并会落盘（`恢复默认` 至今仍写
    /// 4096）。4k 对思考模型是灾难：思考一个人就吃掉 4077 tokens，正文被
    /// `finish_reason=length` 硬截断。现在留空（0）的语义是「模型自身上限」，
    /// 所以这个历史默认值一次性清掉；真想要 4096 重新填一次即可。
    private func migrateLegacyMaxTokensDefault() {
        let flag = "native.migratedMaxTokensDefault"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        guard defaults.integer(forKey: "chat.maxTokens") == 4096 else { return }
        defaults.removeObject(forKey: "chat.maxTokens")
    }

    /// The Flutter client kept its settings in the same defaults domain under
    /// "flutter." keys. Bring them over once so upgrading does not reset the
    /// port, model, context size or chat parameters.
    private func importLegacyPreferences() {
        let flag = "native.importedLegacyPreferences"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)

        let keys = ["port", "model", "maxMemory", "maxContext", "idleReleaseOff",
                    "languageOnly", "thinkingMode", "reasoningEffort", "extraArgs",
                    "autoStart", "launchAtLogin", "hfCache", "recentModels", "chat.system"]
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = defaults.object(forKey: "flutter." + key) {
                defaults.set(value, forKey: key)
            }
        }
        // Numbers were stored as strings by shared_preferences.
        for key in ["chat.temperature", "chat.topP", "chat.maxTokens"] where defaults.object(forKey: key) == nil {
            guard let raw = defaults.object(forKey: "flutter." + key) else { continue }
            if let text = raw as? String, let number = Double(text) {
                defaults.set(number, forKey: key)
            } else if let number = raw as? NSNumber {
                defaults.set(number.doubleValue, forKey: key)
            }
        }
    }

    var port: Int { defaults.integer(forKey: "port") == 0 ? 8000 : defaults.integer(forKey: "port") }
    func setPort(_ value: Int) { defaults.set(value, forKey: "port") }

    var model: String { defaults.string(forKey: "model") ?? "" }
    func setModel(_ value: String) { defaults.set(value, forKey: "model") }

    var maxMemory: String { defaults.string(forKey: "maxMemory") ?? "" }
    func setMaxMemory(_ value: String) { defaults.set(value, forKey: "maxMemory") }

    var maxContext: String { defaults.string(forKey: "maxContext") ?? "" }
    func setMaxContext(_ value: String) { defaults.set(value, forKey: "maxContext") }

    var idleReleaseOff: Bool { defaults.bool(forKey: "idleReleaseOff") }
    func setIdleReleaseOff(_ value: Bool) { defaults.set(value, forKey: "idleReleaseOff") }

    var languageOnly: Bool { defaults.bool(forKey: "languageOnly") }
    func setLanguageOnly(_ value: Bool) { defaults.set(value, forKey: "languageOnly") }

    var thinkingMode: ThinkingMode {
        ThinkingMode(rawValue: defaults.integer(forKey: "thinkingMode")) ?? .automatic
    }
    func setThinkingMode(_ value: ThinkingMode) { defaults.set(value.rawValue, forKey: "thinkingMode") }

    var reasoningEffort: ReasoningEffort {
        // integer(forKey:) is 0 for an absent key, which would read as .minimal;
        // the product default is .medium.
        guard let stored = defaults.object(forKey: "reasoningEffort") as? Int,
              let value = ReasoningEffort(rawValue: stored) else { return .medium }
        return value
    }
    func setReasoningEffort(_ value: ReasoningEffort) { defaults.set(value.rawValue, forKey: "reasoningEffort") }

    var effectiveReasoningEffort: String? {
        switch thinkingMode {
        case .automatic: return nil
        case .off: return "none"
        case .on: return reasoningEffort.token
        }
    }

    var extraArgs: String { defaults.string(forKey: "extraArgs") ?? "" }
    func setExtraArgs(_ value: String) { defaults.set(value, forKey: "extraArgs") }

    var autoStart: Bool { defaults.bool(forKey: "autoStart") }
    func setAutoStart(_ value: Bool) { defaults.set(value, forKey: "autoStart") }

    var launchAtLogin: Bool { defaults.bool(forKey: "launchAtLogin") }
    func setLaunchAtLogin(_ value: Bool) { defaults.set(value, forKey: "launchAtLogin") }

    var hfCache: String { defaults.string(forKey: "hfCache") ?? "" }
    func setHfCache(_ value: String) { defaults.set(value, forKey: "hfCache") }

    /// Which skin the console wears. `.system` follows the macOS appearance.
    var appearance: AppAppearance {
        get {
            guard let raw = defaults.object(forKey: "appearance") as? Int,
                  let value = AppAppearance(rawValue: raw) else { return .system }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: "appearance") }
    }

    var recentModels: [String] { defaults.stringArray(forKey: "recentModels") ?? [] }

    /// 0 是合法值（温度 0 = 贪心解码），不能用「读到 0 就当未设置」判断，
    /// 否则把温度拉到 0 的用户重启后又跑回 0.7。按 key 是否存在区分。
    var temperature: Double {
        guard let stored = defaults.object(forKey: "chat.temperature") as? NSNumber else { return 0.7 }
        return stored.doubleValue
    }
    func setTemperature(_ value: Double) { defaults.set(value, forKey: "chat.temperature") }

    var topP: Double {
        guard let stored = defaults.object(forKey: "chat.topP") as? NSNumber else { return 0.95 }
        return stored.doubleValue
    }
    func setTopP(_ value: Double) { defaults.set(value, forKey: "chat.topP") }

    var systemPrompt: String { defaults.string(forKey: "chat.system") ?? "" }
    func setSystemPrompt(_ value: String) { defaults.set(value, forKey: "chat.system") }

    /// 0 = 未设置：请求不带自定义上限，默认用模型支持的最大上下文
    /// （`AppState.effectiveMaxTokens`：模型自身上限，按引擎生效窗口封顶）。
    var maxTokens: Int { defaults.integer(forKey: "chat.maxTokens") }
    func setMaxTokens(_ value: Int) { defaults.set(value, forKey: "chat.maxTokens") }

    // MARK: API gateway

    /// The unified local gateway on its own fixed port. On by default: it is
    /// what gives clients a stable OpenAI + Claude endpoint across engines.
    var gatewayEnabled: Bool {
        defaults.object(forKey: "gatewayEnabled") == nil ? true : defaults.bool(forKey: "gatewayEnabled")
    }
    func setGatewayEnabled(_ value: Bool) { defaults.set(value, forKey: "gatewayEnabled") }

    /// 9000 keeps clear of the engine port blocks (8000/8100/8200 + 20 each).
    var gatewayPort: Int {
        let value = defaults.integer(forKey: "gatewayPort")
        return (1024...65535).contains(value) ? value : 9000
    }
    func setGatewayPort(_ value: Int) { defaults.set(value, forKey: "gatewayPort") }

    func rememberModel(_ id: String) {
        var values = recentModels.filter { $0 != id }
        values.insert(id, at: 0)
        defaults.set(Array(values.prefix(8)), forKey: "recentModels")
    }

    func serveArguments() -> [String] {
        var result: [String] = []
        let memory = maxMemory.trimmingCharacters(in: .whitespaces)
        if !memory.isEmpty { result += ["--max-memory", memory] }
        let context = maxContext.trimmingCharacters(in: .whitespaces)
        if !context.isEmpty { result += ["--max-context", context] }
        if idleReleaseOff { result += ["--idle-release", "off"] }
        if languageOnly { result.append("--language-only") }
        if let effort = effectiveReasoningEffort {
            result += ["--default-reasoning-effort", effort]
        }
        result += Self.splitArguments(extraArgs)
        return result
    }

    static func splitArguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let closing = quote {
                if character == closing { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
