import Foundation

// MARK: - Status

/// Engine-neutral snapshot. Every adapter folds its own `/status` payload into
/// this shape so the overview, the menu bar and the chat can stay engine-blind.
public struct EngineStatus: Sendable, Equatable {
    public var state: EngineRunState
    public var model: String?
    public var loadedModels: [String]
    public var decodeTokensPerSecond: Double?
    public var prefillTokensPerSecond: Double?
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

    public init(state: EngineRunState = .stopped,
                model: String? = nil,
                loadedModels: [String] = [],
                decodeTokensPerSecond: Double? = nil,
                prefillTokensPerSecond: Double? = nil,
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
                extras: [String: Double] = [:]) {
        self.state = state
        self.model = model
        self.loadedModels = loadedModels
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.prefillTokensPerSecond = prefillTokensPerSecond
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
    }

    public var isReady: Bool { state == .ready }

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
        self.hidden = hidden
        self.helper = helper
        self.engine = engine
    }

    public var shortName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
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
