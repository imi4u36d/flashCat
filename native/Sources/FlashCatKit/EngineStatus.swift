import Foundation

// MARK: - Rate semantics

/// 一个速率读数的**来源与粒度**。
///
/// 「这个数字是不是引擎量过的」问得不够：五家引擎全都自报速率，但粒度和新鲜度
/// 完全不同，同一个数字放在 1 秒的轮询里可能含义相反。所以这里编码的是
/// 「这个数字回答的是哪个问题」，界层据此决定该不该打 `LIVE`、`LAST`、`AVG`。
///
/// 预填充天然不是连续量：一个请求做完，计数器就不动了，此刻「多快」没有定义。
/// MTPLX 自己的仪表盘把这种情况分成三格（prefill 面板：active / last / mean），
/// 我们照同一套语义命名，而不是硬凑一个「当前速度」。
public enum EngineRateKind: String, Codable, Sendable {
    /// 正在发生的量，每秒刷新都有意义。
    ///
    /// 两个来源：累计计数器的相邻差分（mlx-serve 的
    /// `prefill_tokens_total` / `prefill_time_seconds`），以及引擎自报的瞬时场
    /// （splash 的 `current_*_batch.tokens_per_second`、strata 的
    /// `live.prefill_tok_s_mean`、mtplx 的 `in_flight[].prefill_state`）。
    case live

    /// 上一个已完成请求的实测值。数字是真的，但它描述的是过去那一次，
    /// 不是「此刻」。当前解码速度不采用这一档；预填充格在网关没有自己的
    /// 实测值（客户端绕过网关直连引擎端口）时才保留它并打 `LAST`。
    case lastRequest

    /// 进程或会话累计均值，只在请求结束跳一格。一个快的首轮会长期抬高它，
    /// 不能当实时读数用（splash 的 `metrics.prefill_tokens_per_second` 本质是
    /// 两个累计计数器之比，oMLX 的 `avg_*_tps` 同）。
    case lifetimeMean

    /// 引擎没有给出这个方向的速率。速度格由网关按请求打点；预填充格
    /// 没有可用的网关口径（TTFT 估算已废弃），显示「—」。
    case none

    /// 可信程度排序，用于多端点合并时选出「谁描述了这个数值」。
    /// 数值大 = 更接近「此刻」。
    public var rank: Int {
        switch self {
        case .none: return 0
        case .lifetimeMean: return 1
        case .lastRequest: return 2
        case .live: return 3
        }
    }
}

/// 速率 + 它的粒度。`value == nil` 时 `kind` 必须是 `.none`。
public struct EngineRateSample: Sendable, Equatable {
    public var value: Double?
    public var kind: EngineRateKind

    public init(value: Double? = nil, kind: EngineRateKind = .none) {
        self.value = kind == .none ? nil : value
        self.kind = value == nil ? .none : kind
    }

    public static let none = EngineRateSample()

    /// 只有真·实时读数才允许被当作「当前速度」。
    public var isLive: Bool { kind == .live && (value ?? 0) > 0 }

    public var isActive: Bool { (value ?? 0) > 0 }
}

// MARK: - Status

/// Engine-neutral snapshot. Every adapter folds its own `/status` payload into
/// this shape so the overview, the menu bar and the chat can stay engine-blind.
public struct EngineStatus: Sendable, Equatable {
    public var state: EngineRunState
    public var model: String?
    public var loadedModels: [String]
    public var decodeTokensPerSecond: Double?
    public var prefillTokensPerSecond: Double?
    /// 上面两个速率各自的粒度。见 `EngineRateKind`。
    ///
    /// 取代旧的 `decodeRateIsLive` / `prefillRateIsLive` 两个布尔：一个 bool 分不出
    /// 「上一请求的实测值」和「开机以来的累计均值」，而这两个都会看起来像实时数，
    /// 正是概览页把几千 tok/s 当当前速度的根因。
    public var decodeRateKind: EngineRateKind
    public var prefillRateKind: EngineRateKind
    public var draftAcceptance: Double?
    public var ttftMilliseconds: Double?
    public var activeRequests: Int
    public var queuedRequests: Int
    public var requestsCompleted: Int
    public var requestsFailed: Int
    public var memoryBytes: Int?
    public var peakMemoryBytes: Int?
    public var maximumContextTokens: Int?
    public var startedAt: Double?
    public var uptimeSeconds: Double?
    public var processIdentifier: Int32?
    public var detail: String?
    /// Engine-specific extras the generic UI does not render. oMLX fills
    /// `cache_efficiency`/`total_cached_tokens`, MTPLX its MTP statistics.
    public var extras: [String: Double]
    /// Reasoning effort tokens the loaded model supports, as the engine itself
    /// reports them (oMLX `/v1/models/status` per-model `reasoning_efforts`,
    /// MTPLX snapshot `settings.reasoning_policy.effort_levels`). nil = the
    /// engine does not say, and the caller falls back to the built-in list.
    public var reasoningEfforts: [String]?

    public init(state: EngineRunState = .stopped,
                model: String? = nil,
                loadedModels: [String] = [],
                decodeTokensPerSecond: Double? = nil,
                prefillTokensPerSecond: Double? = nil,
                decodeRateKind: EngineRateKind = .none,
                prefillRateKind: EngineRateKind = .none,
                draftAcceptance: Double? = nil,
                ttftMilliseconds: Double? = nil,
                activeRequests: Int = 0,
                queuedRequests: Int = 0,
                requestsCompleted: Int = 0,
                requestsFailed: Int = 0,
                memoryBytes: Int? = nil,
                peakMemoryBytes: Int? = nil,
                maximumContextTokens: Int? = nil,
                startedAt: Double? = nil,
                uptimeSeconds: Double? = nil,
                processIdentifier: Int32? = nil,
                detail: String? = nil,
                extras: [String: Double] = [:],
                reasoningEfforts: [String]? = nil) {
        self.state = state
        self.model = model
        self.loadedModels = loadedModels
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.decodeRateKind = decodeRateKind
        self.prefillRateKind = prefillRateKind
        self.draftAcceptance = draftAcceptance
        self.ttftMilliseconds = ttftMilliseconds
        self.activeRequests = activeRequests
        self.queuedRequests = queuedRequests
        self.requestsCompleted = requestsCompleted
        self.requestsFailed = requestsFailed
        self.memoryBytes = memoryBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.maximumContextTokens = maximumContextTokens
        self.startedAt = startedAt
        self.uptimeSeconds = uptimeSeconds
        self.processIdentifier = processIdentifier
        self.detail = detail
        self.extras = extras
        self.reasoningEfforts = reasoningEfforts
    }

    public var isReady: Bool { state == .ready }

    /// 此刻是否真的有一路在预填充。只有上报该计数的引擎（目前 mlx-serve）
    /// 会为真；轮询侧据此把采样提到 chunk 节奏，其余引擎保持原频率。
    public var isPrefilling: Bool {
        (extras[EngineRateCounters.prefilling] ?? 0) > 0
    }

    public var memoryText: String? { memoryBytes.map(EngineFormat.bytes) }
    public var peakMemoryText: String? { peakMemoryBytes.map(EngineFormat.bytes) }
}

// MARK: - Models

public struct EngineModel: Identifiable, Sendable, Equatable {
    public let id: String
    /// Absolute path on disk when the engine reports one.
    public var path: String?
    public var bytes: Int?
    public var maximumContextTokens: Int?
    public var loaded: Bool
    public var loading: Bool
    /// `engine_type` / `model_type` from the engine, shown as a subtitle.
    public var kind: String?
    /// `/v1/models` 的 `meta.architecture`（如 `qwen_image_21`、`flux2`）。
    /// 图像参数面板靠它选该模型自己的分辨率预设；引擎没报时退回按 id 猜。
    public var architecture: String?
    /// 引擎在 `/v1/models` 里给这个模型报的能力串（`chat` / `image` /
    /// `vision` / `video` …）。空数组表示引擎没报，按对话模型处理。
    /// 同一个引擎可以同时挂对话模型和图像模型，所以能力要看模型，不是看引擎。
    public var capabilities: [String]
    public var hidden: Bool
    public var helper: Bool
    public var engine: EngineID

    public init(id: String,
                path: String? = nil,
                bytes: Int? = nil,
                maximumContextTokens: Int? = nil,
                loaded: Bool = false,
                loading: Bool = false,
                kind: String? = nil,
                architecture: String? = nil,
                capabilities: [String] = [],
                hidden: Bool = false,
                helper: Bool = false,
                engine: EngineID) {
        self.id = id
        self.path = path
        self.bytes = bytes
        self.maximumContextTokens = maximumContextTokens
        self.loaded = loaded
        self.loading = loading
        self.kind = kind
        self.architecture = architecture
        self.capabilities = capabilities
        self.hidden = hidden
        self.helper = helper
        self.engine = engine
    }

    public var shortName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    public var supportsImage: Bool { capabilities.contains("image") }

    public var supportsChat: Bool { capabilities.isEmpty || capabilities.contains("chat") }

    /// mlx-serve 的视频模型（LTX-Video / MiniMax-H3）报 `video`。
    public var supportsVideo: Bool { capabilities.contains("video") }

    /// 能读图（图进文出）的对话模型。和 `supportsImage`（文生图）不是一回事：
    /// Splash/MTPLX/oMLX 的视觉模型会报 `vision`，离线扫描也会补这个能力位。
    public var supportsVision: Bool { capabilities.contains("vision") }

    /// 参考图/参考视频只有 REF2VA 包收：`/v1/models` 不单列这个能力位，
    /// 只能从包名认。REF2VA 不接受首尾帧，两者在界面上互斥。
    public var supportsVideoReferences: Bool {
        supportsVideo && id.lowercased().contains("ref2va")
    }

    /// 能出现在对话页模型菜单里的模型：对话、图像与视频。嵌入之类仍然隐藏。
    public var appearsInChatPicker: Bool { supportsChat || supportsImage || supportsVideo }
}

// MARK: - Endpoint

public struct EngineEndpoint: Sendable, Equatable {
    public let engine: EngineID
    public let port: Int
    /// `""` for the plain OpenAI-compatible root, otherwise a subpath such as
    /// `/v1` that the engine expects in front of `chat/completions`.
    public let prefix: String

    public init(engine: EngineID, port: Int, prefix: String = "/v1") {
        self.engine = engine
        self.port = port
        self.prefix = prefix
    }

    public var baseURL: String { "http://127.0.0.1:\(port)" }
    public var chatCompletionsURL: URL? {
        URL(string: baseURL + prefix + "/chat/completions")
    }
    public var modelsURL: URL? { URL(string: baseURL + prefix + "/models") }
    public var displayText: String { baseURL + prefix }
}

// MARK: - Formatting

public enum EngineFormat {
    public static func bytes(_ bytes: Int) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        let megabytes = Double(bytes) / 1_048_576
        if megabytes >= 1 { return String(format: "%.1f MB", megabytes) }
        return String(format: "%.1f KB", Double(bytes) / 1024)
    }
}

// MARK: - JSON reading helpers

/// Small tolerant extractors. Engine payloads gain and lose fields between
/// releases; a missing key must degrade to nil, never throw.
public enum JSONValue {
    public static func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    public static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number.isFinite ? number : nil
        case let number as Int: return Double(number)
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }

    public static func int(_ value: Any?) -> Int? {
        number(value).map { Int($0) }
    }

    public static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool: return value
        case let number as NSNumber: return number.boolValue
        case let text as String: return ["true", "yes", "1"].contains(text.lowercased())
        default: return nil
        }
    }

    public static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    /// Walk a dotted path: `dig(json, "metrics.ttft_ms.p50")`.
    public static func dig(_ json: [String: Any], _ path: String) -> Any? {
        var current: Any = json
        for key in path.split(separator: ".").map(String.init) {
            guard let node = current as? [String: Any], let next = node[key] else { return nil }
            current = next
        }
        return current
    }

    public static func digNumber(_ json: [String: Any], _ paths: String...) -> Double? {
        for path in paths {
            if let value = number(dig(json, path)) { return value }
        }
        return nil
    }

    public static func digInt(_ json: [String: Any], _ paths: String...) -> Int? {
        for path in paths {
            if let value = int(dig(json, path)) { return value }
        }
        return nil
    }

    public static func digString(_ json: [String: Any], _ paths: String...) -> String? {
        for path in paths {
            if let value = string(dig(json, path)), !value.isEmpty { return value }
        }
        return nil
    }

    public static func digBool(_ json: [String: Any], _ paths: String...) -> Bool? {
        for path in paths {
            if let value = bool(dig(json, path)) { return value }
        }
        return nil
    }
}
