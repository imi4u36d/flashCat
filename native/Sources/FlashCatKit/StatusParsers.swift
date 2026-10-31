import Foundation

/// Folds each engine's own status payload into `EngineStatus`.
///
/// The three engines agree on almost nothing: splash nests everything under
/// `metrics`/`instance`, oMLX keeps one flat `/api/status` document, MTPLX
/// splits the truth between `/health` (pid, model), `/v1/mtplx/snapshot`
/// (metrics) and `/v1/models` (context length). These parsers are the only
/// place that knowledge lives.
public enum EngineStatusParser {

    public static func parse(engine: EngineID,
                             status: [String: Any]?,
                             health: [String: Any]?,
                             fallbackState: EngineRunState = .ready) -> EngineStatus {
        switch engine {
        case .splash: return splash(status: status ?? [:], fallbackState: fallbackState)
        case .omlx: return omlx(status: status ?? [:], health: health, fallbackState: fallbackState)
        case .mtplx: return mtplx(snapshot: status ?? [:], health: health, fallbackState: fallbackState)
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

    /// `/v1/models` is OpenAI-shaped on every engine; MTPLX adds context fields.
    public static func openAIModels(_ json: [String: Any], engine: EngineID) -> [EngineModel] {
        let entries = (json["data"] as? [[String: Any]]) ?? []
        var models: [EngineModel] = []
        for entry in entries {
            guard let id = JSONValue.string(entry["id"]), !id.isEmpty else { continue }
            models.append(EngineModel(
                id: id,
                path: nil,
                bytes: nil,
                maximumContextTokens: JSONValue.int(entry["max_context_length"])
                    ?? JSONValue.int(entry["context_length"]),
                loaded: true,
                loading: false,
                kind: JSONValue.string(entry["capability"]),
                hidden: false,
                helper: false,
                engine: engine))
        }
        return models
    }
}
