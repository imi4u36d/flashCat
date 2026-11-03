import Foundation

public struct EngineTelemetryDocument {
    public let source: EngineTelemetrySource
    public let json: [String: Any]

    public init(source: EngineTelemetrySource, json: [String: Any]) {
        self.source = source
        self.json = json
    }
}

/// Folds each engine's own status payload into `EngineStatus`.
///
/// The three engines agree on almost nothing: splash nests everything under
/// `metrics`/`instance`, oMLX keeps one flat `/api/status` document, MTPLX
/// splits the truth between `/health` (pid, model), `/v1/mtplx/snapshot`
/// (metrics) and `/v1/models` (context length). These parsers are the only
/// place that knowledge lives.
public enum EngineStatusParser {

    /// Parse every telemetry source a descriptor asks for and merge it into one
    /// engine-neutral snapshot. Adding a new reporting format no longer means
    /// adding another engine-id branch in the controller.
    public static func parse(documents: [EngineTelemetryDocument],
                             fallbackState: EngineRunState = .ready) -> EngineStatus {
        var result = EngineStatus(state: fallbackState)
        let ordered = documents.sorted {
            rank($0.source.role) < rank($1.source.role)
        }
        for document in ordered {
            let next: EngineStatus
            switch document.source.format {
            case .splashStatus:
                next = splash(status: document.json, fallbackState: fallbackState)
            case .omlxStatus:
                next = omlx(status: document.json, health: nil, fallbackState: fallbackState)
            case .omlxModels:
                next = omlxModelStatus(document.json, fallbackState: fallbackState)
            case .mtplxSnapshot:
                let health = documents.first { $0.source.role == .health }?.json
                next = mtplx(snapshot: document.json, health: health, fallbackState: fallbackState)
            case .openAIModels:
                next = openAIModelStatus(document.json, fallbackState: fallbackState)
            case .prometheusJSON:
                next = prometheusJSON(document.json, fallbackState: fallbackState)
            case .llamaProps:
                next = llamaProps(document.json, fallbackState: fallbackState)
            case .strataHealth:
                next = strataHealth(document.json, fallbackState: fallbackState)
            case .strataStatus:
                next = strataStatus(document.json, fallbackState: fallbackState)
            case .strataMetrics:
                next = strataMetrics(document.json, fallbackState: fallbackState)
            }
            merge(next, into: &result)
        }
        return result
    }

    private static func rank(_ role: EngineTelemetryRole) -> Int {
        switch role {
        case .health: return 0
        case .status: return 1
        case .metrics: return 2
        case .props: return 3
        case .inventory: return 4
        }
    }

    private static func merge(_ next: EngineStatus, into result: inout EngineStatus) {
        if next.state != .ready || result.state == .stopped { result.state = next.state }
        if let value = next.model, !value.isEmpty { result.model = value }
        if !next.loadedModels.isEmpty { result.loadedModels = next.loadedModels }
        if let value = next.decodeTokensPerSecond, value > 0 { result.decodeTokensPerSecond = value }
        if let value = next.prefillTokensPerSecond, value > 0 { result.prefillTokensPerSecond = value }
        if let value = next.draftAcceptance { result.draftAcceptance = value }
        if let value = next.ttftMilliseconds { result.ttftMilliseconds = value }
        if next.activeRequests > 0 || result.activeRequests == 0 { result.activeRequests = next.activeRequests }
        if next.queuedRequests > 0 { result.queuedRequests = next.queuedRequests }
        if next.requestsCompleted > 0 { result.requestsCompleted = next.requestsCompleted }
        if next.requestsFailed > 0 { result.requestsFailed = next.requestsFailed }
        if let value = next.memoryBytes { result.memoryBytes = value }
        if let value = next.peakMemoryBytes { result.peakMemoryBytes = value }
        if let value = next.maximumContextTokens { result.maximumContextTokens = value }
        if let value = next.startedAt { result.startedAt = value }
        if let value = next.uptimeSeconds { result.uptimeSeconds = value }
        if let value = next.processIdentifier { result.processIdentifier = value }
        if let value = next.detail { result.detail = value }
        if let value = next.reasoningEfforts, !value.isEmpty { result.reasoningEfforts = value }
        result.extras.merge(next.extras) { _, new in new }
    }

    public static func parse(engine: EngineID,
                             status: [String: Any]?,
                             health: [String: Any]?,
                             fallbackState: EngineRunState = .ready) -> EngineStatus {
        switch engine.adapter {
        case .splash: return splash(status: status ?? [:], fallbackState: fallbackState)
        case .omlx: return omlx(status: status ?? [:], health: health, fallbackState: fallbackState)
        case .mtplx: return mtplx(snapshot: status ?? [:], health: health, fallbackState: fallbackState)
        default: return EngineStatus(state: fallbackState)
        }
    }

    // MARK: splash

    public static func splash(status json: [String: Any],
                              fallbackState: EngineRunState = .ready) -> EngineStatus {
        var result = EngineStatus(state: fallbackState)
        result.decodeTokensPerSecond = JSONValue.digNumber(json, "metrics.decode_tokens_per_second")
        result.prefillTokensPerSecond = JSONValue.digNumber(json, "metrics.prefill_tokens_per_second")
        result.draftAcceptance = JSONValue.digNumber(json, "metrics.draft_acceptance_rate")
        result.ttftMilliseconds = JSONValue.digNumber(json, "metrics.ttft_ms.p50")
        if let array = JSONValue.dig(json, "active_requests") as? [Any] {
            result.activeRequests = array.count
        } else {
            result.activeRequests = JSONValue.digInt(json, "admission.restoring") ?? 0
        }
        result.queuedRequests = JSONValue.digInt(json, "admission.waiting") ?? 0
        result.memoryBytes = JSONValue.digInt(json, "memory_actual.current_bytes")
        result.peakMemoryBytes = JSONValue.digInt(json, "memory_actual.peak_bytes")
        result.maximumContextTokens = JSONValue.digInt(json, "maximum_context_tokens")
        result.model = JSONValue.digString(json, "instance.model")
        result.requestsCompleted = JSONValue.digInt(json, "requests.completed") ?? 0
        result.requestsFailed = JSONValue.digInt(json, "requests.failed") ?? 0
        result.startedAt = JSONValue.digNumber(json, "instance.started_at")
        result.uptimeSeconds = JSONValue.digNumber(json, "uptime_seconds")
            ?? result.startedAt.map { Date().timeIntervalSince1970 - $0 }
        result.processIdentifier = JSONValue.digInt(json, "instance.pid").map(Int32.init)
        result.loadedModels = result.model.map { [$0] } ?? []
        result.detail = JSONValue.digString(json, "kv.format").map { "kv \($0)" }
        if let thermal = JSONValue.digString(json, "metrics.thermal_state", "thermal_state") {
            result.extras["thermal_state"] = thermal == "nominal" ? 0 : 1
        }
        if let pressure = JSONValue.digString(json, "memory_pressure") {
            result.extras["memory_pressure_warn"] = pressure == "normal" ? 0 : 1
        }
        return result
    }

    // MARK: oMLX

    /// `/api/status` (authoritative, updated every refresh) is paired with
    /// `/health` (which is the cheap liveness probe and carries `status`).
    public static func omlx(status json: [String: Any],
                            health: [String: Any]? = nil,
                            fallbackState: EngineRunState = .ready) -> EngineStatus {
        var result = EngineStatus(state: fallbackState)
        result.decodeTokensPerSecond = JSONValue.digNumber(json, "avg_generation_tps")
        result.prefillTokensPerSecond = JSONValue.digNumber(json, "avg_prefill_tps")
        result.activeRequests = JSONValue.digInt(json, "active_requests") ?? 0
        result.queuedRequests = JSONValue.digInt(json, "waiting_requests") ?? 0
        result.requestsCompleted = JSONValue.digInt(json, "total_requests") ?? 0
        result.memoryBytes = JSONValue.digInt(json, "model_memory_used")
        result.peakMemoryBytes = JSONValue.digInt(json, "model_memory_max")
        result.uptimeSeconds = JSONValue.digNumber(json, "uptime_seconds")
        result.startedAt = result.uptimeSeconds.map { Date().timeIntervalSince1970 - $0 }

        let loaded = (JSONValue.dig(json, "loaded_models") as? [String]) ?? []
        result.loadedModels = loaded
        result.model = loaded.first
            ?? JSONValue.digString(json, "default_model")
            ?? ((health?["default_model"] as? String))

        if let efficiency = JSONValue.digNumber(json, "cache_efficiency") {
            result.extras["cache_efficiency"] = efficiency
        }
        if let cached = JSONValue.digNumber(json, "total_cached_tokens") {
            result.extras["total_cached_tokens"] = cached
        }
        if let loadedCount = JSONValue.digNumber(json, "models_loaded") {
            result.extras["models_loaded"] = loadedCount
        }
        let loading = JSONValue.digInt(json, "models_loading") ?? 0
        if loading > 0, result.state == .ready, loaded.isEmpty {
            result.state = .loading
        }
        if let version = JSONValue.digString(json, "version") { result.detail = "v\(version)" }
        return result
    }

    /// Read `/v1/models/status` into model rows. `models` is a flat array; the
    /// scalar siblings (`loaded_count`, `current_model_memory`) describe the pool.
    public static func omlxModels(_ json: [String: Any]) -> (models: [EngineModel], loadedCount: Int, memoryUsed: Int?) {
        let entries = (json["models"] as? [[String: Any]]) ?? []
        var models: [EngineModel] = []
        for entry in entries {
            guard let id = JSONValue.string(entry["id"]), !id.isEmpty else { continue }
            models.append(EngineModel(
                id: id,
                path: JSONValue.string(entry["model_path"]),
                bytes: JSONValue.int(entry["actual_size"]) ?? JSONValue.int(entry["estimated_size"]),
                maximumContextTokens: JSONValue.int(entry["max_context_window"])
                    ?? JSONValue.int(entry["model_context_length"]),
                loaded: JSONValue.bool(entry["loaded"]) ?? false,
                loading: JSONValue.bool(entry["is_loading"]) ?? false,
                kind: JSONValue.string(entry["engine_type"]) ?? JSONValue.string(entry["model_type"]),
                hidden: JSONValue.bool(entry["is_hidden"]) ?? false,
                helper: JSONValue.bool(entry["is_helper"]) ?? false,
                engine: .omlx))
        }
        models.sort { $0.id.lowercased() < $1.id.lowercased() }
        return (models,
                JSONValue.int(json["loaded_count"]) ?? models.filter { $0.loaded }.count,
                JSONValue.int(json["current_model_memory"]))
    }

    private static func omlxModelStatus(_ json: [String: Any],
                                        fallbackState: EngineRunState) -> EngineStatus {
        var result = EngineStatus(state: fallbackState)
        let parsed = omlxModels(json)
        let chatModels = parsed.models.filter { !$0.helper && !$0.hidden }
        result.loadedModels = chatModels.filter(\.loaded).map(\.id)
        result.model = result.loadedModels.first
        if parsed.loadedCount > 0, result.loadedModels.isEmpty,
           chatModels.contains(where: \.loading) {
            result.state = .loading
        }
        if let current = chatModels.first(where: \.loaded) {
            result.maximumContextTokens = current.maximumContextTokens
            result.detail = current.kind
        }
        return result
    }

    // MARK: MTPLX

    /// `/health` carries identity (`model`, `model_path`, `startup.pid`);
    /// `/v1/mtplx/snapshot` carries the live numbers.
    public static func mtplx(snapshot json: [String: Any],
                             health: [String: Any]? = nil,
                             fallbackState: EngineRunState = .ready) -> EngineStatus {
        var result = EngineStatus(state: fallbackState)

        // Decode rate: the rolling window is the honest sustained number; the
        // per-request `latest.decode_tok_s` only describes the last answer.
        result.decodeTokensPerSecond = JSONValue.digNumber(json, "rolling.mean")
            ?? JSONValue.digNumber(json, "latest.decode_tok_s")
        result.prefillTokensPerSecond = JSONValue.digNumber(json, "latest.prefill_tok_s")
            ?? JSONValue.digNumber(json, "prefill_rates.peak_tok_s")
        if let ttft = JSONValue.digNumber(json, "latest.ttft_s") {
            result.ttftMilliseconds = ttft * 1000
        }
        let accepted = JSONValue.digNumber(json, "latest.accepted_drafts")
        let drafted = JSONValue.digNumber(json, "latest.drafted_tokens")
        if let accepted, let drafted, drafted > 0 {
            result.draftAcceptance = accepted / drafted
        }
        result.activeRequests = JSONValue.digInt(json, "active_requests")
            ?? JSONValue.digInt(json, "scheduler.active_requests") ?? 0
        result.requestsCompleted = JSONValue.digInt(json, "lifetime.requests_total") ?? 0
        result.memoryBytes = JSONValue.digInt(json, "mem.peak_memory_bytes")
        result.peakMemoryBytes = JSONValue.digInt(json, "mem.peak_memory_bytes")
        result.uptimeSeconds = JSONValue.digNumber(json, "uptime_s")
            ?? JSONValue.digNumber(json, "lifetime.uptime_s")
        result.startedAt = JSONValue.digNumber(json, "lifetime.started_at_s")
        result.maximumContextTokens = JSONValue.digInt(json, "context_window")

        if let modelId = JSONValue.digString(json, "model_id") {
            result.model = modelId
            result.loadedModels = [modelId]
        }

        if let health {
            if let omlxStyle = JSONValue.string(health["model"]), result.model == nil {
                result.model = omlxStyle
                result.loadedModels = [omlxStyle]
            }
            if let pid = JSONValue.digInt(health, "startup.pid") {
                result.processIdentifier = Int32(pid)
            }
            if result.startedAt == nil {
                result.startedAt = JSONValue.digNumber(health, "startup.started_at")
            }
            if let context = JSONValue.digInt(health, "context_window"), result.maximumContextTokens == nil {
                result.maximumContextTokens = context
            }
            if let mode = JSONValue.digString(health, "generation_mode") {
                result.detail = mode.uppercased()
            }
        }

        if let depth = JSONValue.digNumber(json, "latest.mtp_depth") {
            result.extras["mtp_depth"] = depth
        }
        // 思考等级列表由引擎自己报告（settings.reasoning_policy.effort_levels）；
        // 空列表（如 qwen3 解析器不分级）视为「未提供」，交由上层兜底。
        if let levels = JSONValue.dig(json, "settings.reasoning_policy.effort_levels") as? [String],
           !levels.isEmpty {
            result.reasoningEfforts = levels
        }
        if let level = JSONValue.digNumber(json, "memory_pressure_level") {
            result.extras["memory_pressure_level"] = level
        }
        if let cached = JSONValue.digNumber(json, "lifetime.cached_tokens_total") {
            result.extras["total_cached_tokens"] = cached
        }
        if let peak = JSONValue.digNumber(json, "prefill_rates.peak_tok_s") {
            result.extras["prefill_peak_tps"] = peak
        }
        if JSONValue.digString(json, "model_id") == nil, result.loadedModels.isEmpty {
            // The supervisor launched a model that has not finished warming up.
            result.state = .loading
        }
        return result
    }

    /// `/v1/models` is OpenAI-shaped on every engine; packs add context fields
    /// and may list both loaded and unloaded models.
    public static func openAIModels(_ json: [String: Any], engine: EngineID) -> [EngineModel] {
        let entries = (json["data"] as? [[String: Any]]) ?? []
        var models: [EngineModel] = []
        for entry in entries {
            guard let id = JSONValue.string(entry["id"]), !id.isEmpty else { continue }
            let state = JSONValue.digString(entry, "status.value", "state")
            let loaded = JSONValue.bool(entry["loaded"])
                ?? (state.map { $0.lowercased() == "loaded" || $0.lowercased() == "ready" })
                ?? (state?.lowercased() == "unloaded" ? false : true)
            let loading = state?.lowercased() == "loading"
            let capabilities = entry["capabilities"] as? [String]
            models.append(EngineModel(
                id: id,
                path: nil,
                bytes: JSONValue.int(entry["bytes_on_disk"]),
                maximumContextTokens: JSONValue.int(entry["max_context_length"])
                    ?? JSONValue.int(entry["context_length"])
                    ?? JSONValue.digInt(entry, "meta.n_ctx", "meta.context_length"),
                loaded: loaded,
                loading: loading,
                kind: capabilities?.first ?? JSONValue.string(entry["capability"])
                    ?? JSONValue.digString(entry, "meta.engine", "meta.architecture"),
                hidden: capabilities.map { !$0.contains("chat") } ?? false,
                helper: false,
                engine: engine))
        }
        return models
    }

    private static func openAIModelStatus(_ json: [String: Any],
                                          fallbackState: EngineRunState) -> EngineStatus {
        var result = EngineStatus(state: fallbackState)
        let entries = (json["data"] as? [[String: Any]]) ?? []
        for entry in entries {
            guard let id = JSONValue.string(entry["id"]), !id.isEmpty else { continue }
            let capabilities = entry["capabilities"] as? [String] ?? []
            if !capabilities.isEmpty, !capabilities.contains("chat") { continue }
            let state = JSONValue.digString(entry, "status.value", "state")?.lowercased()
            let loaded = JSONValue.bool(entry["loaded"])
                ?? (state.map { $0 == "loaded" || $0 == "ready" })
                ?? (state == "unloaded" ? false : true)
            if loaded { result.loadedModels.append(id) }
            if state == "loading" { result.state = .loading }
            if loaded, result.model == nil {
                result.model = id
                result.maximumContextTokens = JSONValue.int(entry["max_model_len"])
                    ?? JSONValue.int(entry["context_length"])
                    ?? JSONValue.digInt(entry, "meta.n_ctx", "meta.context_length")
            }
        }
        if result.loadedModels.isEmpty, !entries.isEmpty { result.model = nil }
        return result
    }

    // MARK: mlx-serve / Prometheus JSON

    public static func prometheusJSON(_ json: [String: Any],
                                      fallbackState: EngineRunState = .ready) -> EngineStatus {
        var result = EngineStatus(state: fallbackState)
        result.activeRequests = JSONValue.digInt(json, "gauges.requests_running") ?? 0
        result.queuedRequests = JSONValue.digInt(json, "gauges.requests_waiting") ?? 0
        result.requestsCompleted = JSONValue.digInt(json, "counters.requests_success_total") ?? 0
        let failed = JSONValue.digInt(json, "counters.requests_failed_total") ?? 0
        let cancelled = JSONValue.digInt(json, "counters.requests_cancelled_total") ?? 0
        let rejected = JSONValue.digInt(json, "counters.requests_rejected_total") ?? 0
        result.requestsFailed = failed + cancelled + rejected
        if let bytes = JSONValue.digInt(json, "gauges.mlx_active_bytes"), bytes > 16 {
            result.memoryBytes = bytes
        } else if let mb = JSONValue.digInt(json, "gauges.memory_mb") {
            result.memoryBytes = mb * 1_048_576
        }
        result.startedAt = JSONValue.digNumber(json, "gauges.process_start_time_seconds")
        if let startedAt = result.startedAt {
            result.uptimeSeconds = max(0, Date().timeIntervalSince1970 - startedAt)
        }
        if let count = JSONValue.digInt(json, "histograms.time_to_first_token_seconds.count"),
           count > 0,
           let sum = JSONValue.digNumber(json, "histograms.time_to_first_token_seconds.sum") {
            result.ttftMilliseconds = sum / Double(count) * 1000
        }
        return result
    }

    /// llama-server-compatible `/props` carries memory and the effective
    /// context without requiring a loaded request.
    public static func llamaProps(_ json: [String: Any],
                                  fallbackState: EngineRunState = .ready) -> EngineStatus {
        var result = EngineStatus(state: fallbackState)
        result.memoryBytes = JSONValue.digInt(json, "memory.active_bytes", "memory.peak_bytes")
        result.peakMemoryBytes = JSONValue.digInt(json, "memory.peak_bytes")
        result.maximumContextTokens = JSONValue.digInt(json, "memory.max_safe_context",
                                                       "default_generation_settings.n_ctx")
        result.model = JSONValue.digString(json, "default_generation_settings.model")
        result.detail = JSONValue.digString(json, "settings.engine", "model_info.model_type")
        return result
    }

    // MARK: Strata

    public static func strataHealth(_ json: [String: Any],
                                    fallbackState: EngineRunState = .ready) -> EngineStatus {
        var result = EngineStatus(state: fallbackState)
        result.model = JSONValue.string(json["model"])
        result.maximumContextTokens = JSONValue.int(json["max_context"])
        if JSONValue.bool(json["loaded"]) == false { result.state = .loading }
        if let pid = JSONValue.int(json["pid"]) { result.processIdentifier = Int32(pid) }
        return result
    }

    public static func strataStatus(_ json: [String: Any],
                                    fallbackState: EngineRunState = .ready) -> EngineStatus {
        var result = EngineStatus(state: fallbackState)
        result.model = JSONValue.digString(json, "model.id", "model", "engine.model")
        result.maximumContextTokens = JSONValue.digInt(json, "max_context", "engine.max_context")
        result.activeRequests = JSONValue.digInt(json, "running", "live.running", "active_requests") ?? 0
        result.queuedRequests = JSONValue.digInt(json, "queued", "live.queued", "waiting") ?? 0
        if JSONValue.digBool(json, "busy") == true { result.detail = "生成中" }
        if let last = JSONValue.dig(json, "timings") as? [String: Any] {
            result.decodeTokensPerSecond = JSONValue.number(last["predicted_per_second"])
            result.prefillTokensPerSecond = JSONValue.number(last["prompt_per_second"])
        }
        return result
    }

    public static func strataMetrics(_ json: [String: Any],
                                     fallbackState: EngineRunState = .ready) -> EngineStatus {
        var result = EngineStatus(state: fallbackState)
        result.model = JSONValue.digString(json, "engine.model")
        result.maximumContextTokens = JSONValue.digInt(json, "engine.max_context")
        result.decodeTokensPerSecond = JSONValue.digNumber(json, "live.tok_s")
        result.prefillTokensPerSecond = JSONValue.digNumber(json, "live.prefill_tok_s_mean")
        result.activeRequests = JSONValue.digInt(json, "live.running") ?? 0
        result.queuedRequests = (JSONValue.digInt(json, "live.queued") ?? 0)
            + (JSONValue.digInt(json, "live.waiting") ?? 0)
        result.requestsCompleted = JSONValue.digInt(json, "totals.requests") ?? 0
        let drafts = JSONValue.digInt(json, "totals.drafts_offered") ?? 0
        let accepted = JSONValue.digInt(json, "totals.drafts_accepted") ?? 0
        if drafts > 0 { result.draftAcceptance = Double(accepted) / Double(drafts) }
        if let promptMs = JSONValue.digNumber(json, "totals.prompt_ms"),
           let output = JSONValue.digNumber(json, "totals.output_tokens"),
           let decodeMs = JSONValue.digNumber(json, "totals.decode_ms"),
           decodeMs > 0 {
            result.detail = String(format: "%.1f tok/s", output / (decodeMs / 1000))
            _ = promptMs
        }
        if let requests = json["requests"] as? [[String: Any]], let latest = requests.first {
            if result.decodeTokensPerSecond == nil {
                result.decodeTokensPerSecond = JSONValue.digNumber(latest, "decode_tok_s")
            }
        }
        if JSONValue.digString(json, "live.state") == "reading" {
            result.state = .loading
        }
        return result
    }
}
