// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

package enum ThinkingMode: Int, CaseIterable {
    case automatic = 0
    case off = 1
    case on = 2

    package var label: String {
        switch self {
        case .automatic: return "自动"
        case .off: return "关闭"
        case .on: return "开启"
        }
    }

    package var detail: String {
        switch self {
        case .automatic: return "跟随模型的聊天模板"
        case .off: return "直接回答，不做隐藏推理"
        case .on: return "使用指定的推理等级"
        }
    }
}

package enum ReasoningEffort: Int, CaseIterable {
    // 等级范围固定为 Low / Medium / High / XHigh；rawValue 保留原值以兼容旧偏好。
    case low = 1
    case medium = 2
    case high = 3
    case xhigh = 4

    package var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "XHigh"
        }
    }

    package var token: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        }
    }

    /// 把落盘的整数还原成等级。旧版本存过的 minimal(0) / max(5) 收敛到
    /// 新范围的两端，`AppSettings` 和 `@AppStorage` 观察者共用这一套规则。
    package static func stored(_ raw: Int) -> ReasoningEffort {
        if let value = ReasoningEffort(rawValue: raw) { return value }
        switch raw {
        case 0: return .low
        case 5: return .xhigh
        default: return .medium
        }
    }
}

/// Native persistence: UserDefaults instead of a Dart preferences plugin.
package final class AppSettings {
    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

        let keys = [
            "port", "model", "maxMemory", "maxContext", "idleReleaseOff",
            "languageOnly", "thinkingMode", "reasoningEffort", "extraArgs",
            "autoStart", "launchAtLogin", "hfCache", "recentModels", "chat.system",
        ]
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

    package var port: Int { defaults.integer(forKey: "port") == 0 ? 8000 : defaults.integer(forKey: "port") }
    package func setPort(_ value: Int) { defaults.set(value, forKey: "port") }

    package var model: String { defaults.string(forKey: "model") ?? "" }
    package func setModel(_ value: String) { defaults.set(value, forKey: "model") }

    package var maxMemory: String { defaults.string(forKey: "maxMemory") ?? "" }
    package func setMaxMemory(_ value: String) { defaults.set(value, forKey: "maxMemory") }

    package var maxContext: String { defaults.string(forKey: "maxContext") ?? "" }
    package func setMaxContext(_ value: String) { defaults.set(value, forKey: "maxContext") }

    package var idleReleaseOff: Bool { defaults.bool(forKey: "idleReleaseOff") }
    package func setIdleReleaseOff(_ value: Bool) { defaults.set(value, forKey: "idleReleaseOff") }

    package var languageOnly: Bool { defaults.bool(forKey: "languageOnly") }
    package func setLanguageOnly(_ value: Bool) { defaults.set(value, forKey: "languageOnly") }

    package var thinkingMode: ThinkingMode {
        ThinkingMode(rawValue: defaults.integer(forKey: "thinkingMode")) ?? .automatic
    }
    package func setThinkingMode(_ value: ThinkingMode) { defaults.set(value.rawValue, forKey: "thinkingMode") }

    package var reasoningEffort: ReasoningEffort {
        // 缺省时按产品默认 .medium；旧版本存过的 minimal(0) / max(5) 收敛到
        // 新范围的两端，避免升级后跳回 .medium。
        guard let stored = defaults.object(forKey: "reasoningEffort") as? Int else { return .medium }
        return ReasoningEffort.stored(stored)
    }
    package func setReasoningEffort(_ value: ReasoningEffort) {
        defaults.set(value.rawValue, forKey: "reasoningEffort")
    }

    package var effectiveReasoningEffort: String? {
        switch thinkingMode {
        case .automatic: return nil
        case .off: return "none"
        case .on: return reasoningEffort.token
        }
    }

    package var extraArgs: String { defaults.string(forKey: "extraArgs") ?? "" }
    package func setExtraArgs(_ value: String) { defaults.set(value, forKey: "extraArgs") }

    package var autoStart: Bool { defaults.bool(forKey: "autoStart") }
    package func setAutoStart(_ value: Bool) { defaults.set(value, forKey: "autoStart") }

    package var launchAtLogin: Bool { defaults.bool(forKey: "launchAtLogin") }
    package func setLaunchAtLogin(_ value: Bool) { defaults.set(value, forKey: "launchAtLogin") }

    package var hfCache: String { defaults.string(forKey: "hfCache") ?? "" }
    package func setHfCache(_ value: String) { defaults.set(value, forKey: "hfCache") }

    /// 官方来源的 Hugging Face 端点。空串表示官方地址；`HubClient` 和下载器
    /// 都从这里读，所以设置页写一次两边一起生效。HF-Mirror 通道固定用
    /// hf-mirror.com，不读这个值。
    package var hfEndpoint: String {
        HFEndpoint.normalized(defaults.string(forKey: "hfEndpoint") ?? "") ?? ""
    }

    package func setHfEndpoint(_ value: String) {
        let normalized = HFEndpoint.normalized(value) ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            defaults.removeObject(forKey: "hfEndpoint")
        } else {
            defaults.set(normalized, forKey: "hfEndpoint")
        }
    }

    /// 受限仓库的访问令牌。只发给 Hugging Face；换到 ModelScope 时不会
    /// 被带过去。
    package var hfToken: String {
        defaults.string(forKey: "hfToken") ?? ""
    }

    package func setHfToken(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: "hfToken")
        } else {
            defaults.set(trimmed, forKey: "hfToken")
        }
    }

    /// 模型广场默认查哪家。CLI/控制接口的 `download` 也沿用这个通道；只有
    /// ModelScope 不参与——裸 repo id 默认仍按 Hugging Face 端点解释。
    package var hubSource: HubSource {
        guard let raw = defaults.string(forKey: "hubSource"),
            let value = HubSource(rawValue: raw)
        else { return .huggingFace }
        return value
    }

    package func setHubSource(_ value: HubSource) {
        defaults.set(value.rawValue, forKey: "hubSource")
    }

    /// The recommendation worked out from this Mac's hardware, kept so the model
    /// page can tag its suggestions without inspecting the machine again — and
    /// so the answer does not change under a user who is halfway through a
    /// first-run install.
    package var hardwareRecommendation: HardwareRecommendation? {
        guard let data = defaults.data(forKey: "hardwareRecommendation") else { return nil }
        return try? JSONDecoder().decode(HardwareRecommendation.self, from: data)
    }

    package func setHardwareRecommendation(_ value: HardwareRecommendation?) {
        guard let value else {
            defaults.removeObject(forKey: "hardwareRecommendation")
            return
        }
        defaults.set(try? JSONEncoder().encode(value), forKey: "hardwareRecommendation")
    }

    /// Whether the first-run recommendation page has already been answered.
    /// Stored apart from the recommendation itself: re-checking the hardware
    /// must not make the page pop up again.
    package var hardwareRecommendationSeen: Bool { defaults.bool(forKey: "hardwareRecommendation.seen") }
    package func setHardwareRecommendationSeen(_ value: Bool) {
        defaults.set(value, forKey: "hardwareRecommendation.seen")
    }

    /// Which skin the console wears. `.system` follows the macOS appearance.
    package var appearance: AppAppearance {
        get {
            guard let raw = defaults.object(forKey: "appearance") as? Int else { return .system }
            return AppAppearance.normalized(rawValue: raw)
        }
        set { defaults.set(newValue.rawValue, forKey: "appearance") }
    }

    package var recentModels: [String] { defaults.stringArray(forKey: "recentModels") ?? [] }

    /// 0 是合法值（温度 0 = 贪心解码），不能用「读到 0 就当未设置」判断，
    /// 否则把温度拉到 0 的用户重启后又跑回 0.7。按 key 是否存在区分。
    package var temperature: Double {
        guard let stored = defaults.object(forKey: "chat.temperature") as? NSNumber else { return 0.7 }
        return stored.doubleValue
    }
    package func setTemperature(_ value: Double) { defaults.set(value, forKey: "chat.temperature") }

    package var topP: Double {
        guard let stored = defaults.object(forKey: "chat.topP") as? NSNumber else { return 0.95 }
        return stored.doubleValue
    }
    package func setTopP(_ value: Double) { defaults.set(value, forKey: "chat.topP") }

    package var systemPrompt: String { defaults.string(forKey: "chat.system") ?? "" }
    package func setSystemPrompt(_ value: String) { defaults.set(value, forKey: "chat.system") }

    /// 0 = 未设置：请求不带自定义上限，默认用模型支持的最大上下文
    /// （`AppState.effectiveMaxTokens`：模型自身上限，按引擎生效窗口封顶）。
    package var maxTokens: Int { defaults.integer(forKey: "chat.maxTokens") }
    package func setMaxTokens(_ value: Int) { defaults.set(value, forKey: "chat.maxTokens") }

    // MARK: API gateway

    /// The unified local gateway's port. The gateway itself is always on — it
    /// gives clients a stable OpenAI + Claude endpoint across engines. 9000
    /// keeps clear of the engine port blocks (8000/8100/8200 + 20 each).
    package var gatewayPort: Int {
        let value = defaults.integer(forKey: "gatewayPort")
        return (1024...65535).contains(value) ? value : 9000
    }
    package func setGatewayPort(_ value: Int) { defaults.set(value, forKey: "gatewayPort") }

    // MARK: CLI control API

    /// The local control server `flashcat` talks to, always on: the gateway
    /// answers inference requests, this one answers app commands (start/stop
    /// engines, switch models, read downloads, edit settings). 9100 sits
    /// outside 9000 and every engine block. If it is taken, the server walks
    /// upward and records the real port in `control.json`.
    package var controlPort: Int {
        // The override exists for tests and for a second instance launched from
        // a checkout; the shipped app uses the setting.
        if let raw = ProcessInfo.processInfo.environment["FLASHCAT_CONTROL_PORT"],
            let value = Int(raw), (1024...65535).contains(value)
        {
            return value
        }
        let value = defaults.integer(forKey: "controlPort")
        return (1024...65535).contains(value) ? value : 9100
    }
    package func setControlPort(_ value: Int) { defaults.set(value, forKey: "controlPort") }

    package func rememberModel(_ id: String) {
        var values = recentModels.filter { $0 != id }
        values.insert(id, at: 0)
        defaults.set(Array(values.prefix(8)), forKey: "recentModels")
    }

    package func serveArguments() -> [String] {
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

    package static func splitArguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let closing = quote {
                if character == closing { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
