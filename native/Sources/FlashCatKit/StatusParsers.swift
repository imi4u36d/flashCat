import Foundation

/// 不可变的遥测文档：`json` 是解析后的字典，创建后只读。并发拉取时需要在
/// 任务之间传递，语义上安全，因此显式声明 `@unchecked Sendable`。
public struct EngineTelemetryDocument: @unchecked Sendable {
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
        // 速率与它的粒度必须**成对**合并。文档按 health → status → metrics →
        // props → inventory 的顺序折叠，后到的会覆盖数值；如果只让数值覆盖、
        // 粒度另外取最强，就会出现「数值是后来的累计均值、角标却写着 LIVE」。
        // 所以只有来源粒度不弱于当前时才整对替换：更好的来源（`.live`）不会被
        // 后面端点的均值洗掉，均值也不会冒充实时。
        if let value = next.decodeTokensPerSecond, value > 0,
           next.decodeRateKind.rank >= result.decodeRateKind.rank {
            result.decodeTokensPerSecond = value
            result.decodeRateKind = next.decodeRateKind
        }
        if let value = next.prefillTokensPerSecond, value > 0,
           next.prefillRateKind.rank >= result.prefillRateKind.rank {
            result.prefillTokensPerSecond = value
            result.prefillRateKind = next.prefillRateKind
        }
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

    /// splash 在跑请求所处的阶段集合（`active_requests[].phase`）。
    private static func activePhases(_ json: [String: Any]) -> Set<String> {
        guard let array = JSONValue.dig(json, "active_requests") as? [[String: Any]] else { return [] }
        return Set(array.compactMap { $0["phase"] as? String })
    }

    /// splash 的 `current_*_batch` 读数。`valid: false` 表示引擎还没跑过同类
    /// 批次（刚启动、或只解码没预填充），此时必须交回均值口径而不是报 0。
    private static func batchRate(_ json: [String: Any], _ path: String) -> Double? {
        guard let value = JSONValue.digNumber(json, "\(path).tokens_per_second"), value > 0,
              JSONValue.digBool(json, "\(path).valid") != false
        else { return nil }
        return value
    }

    /// `prefill_rates.tokens / compute_time_s`：最近一批预填充 chunk 的滚动均值。
    /// 分子分母同口径（都只含真正前向的部分），所以是可信的——只是它描述的是
    /// 「最近这一段时间」，不是「此刻」。
    private static func prefillWindowedRate(_ json: [String: Any]) -> Double? {
        guard let tokens = JSONValue.digNumber(json, "prefill_rates.tokens"),
              let seconds = JSONValue.digNumber(json, "prefill_rates.compute_time_s"),
              tokens > 0, seconds > 0 else { return nil }
        return tokens / seconds
    }

    /// MTPLX 快照里正在跑的预填充速率。多路并发时取 `elapsed_s` 最大的那一路，
    /// 与 MTPLX 自己仪表盘的做法一致（dashboard/src/state/store.ts
    /// `usePrimaryActivePrefill`）。分子是 `tokens_done / elapsed_s`，即已完成
    /// 的前向 token 除以本请求预填充已用时，缓存恢复不算在内。
    private static func activePrefillRate(_ json: [String: Any]) -> Double? {
        guard let handles = JSONValue.dig(json, "in_flight") as? [[String: Any]] else { return nil }
        var best: (elapsed: Double, rate: Double)?
        for handle in handles {
            guard let state = handle["prefill_state"] as? [String: Any],
                  let phase = state["phase"] as? String, phase != "completed"
            else { continue }
            let elapsed = JSONValue.number(state["elapsed_s"]) ?? 0
            let done = JSONValue.number(state["tokens_done"]) ?? 0
            let reported = JSONValue.number(state["live_prefill_tok_s"])
                ?? JSONValue.number(state["prefill_tok_s"])
            // 服务端每个 chunk 刷新的 `live_prefill_tok_s` 才是「此刻」；
            // `tokens_done / elapsed_s` 是这一轮从开始到现在的均值，只在
            // 引擎没给实时场时兜底。过去优先用均值，读数会越跑越钝。
            let rate = reported ?? (done > 0 && elapsed > 0 ? done / elapsed : nil)
            guard let rate, rate > 0 else { continue }
            if best.map({ elapsed > $0.elapsed }) ?? true { best = (elapsed, rate) }
        }
        return best?.rate
    }

    // MARK: splash

    public static func splash(status json: [String: Any],
                              fallbackState: EngineRunState = .ready) -> EngineStatus {
        var result = EngineStatus(state: fallbackState)
        // splash 的 `metrics.*_tokens_per_second` 是**两个进程累计计数器之比**
        // （runtime/engine/Status.hpp: `prefillTokens_ * 1000 / prefillWallMilliseconds_`，
        // 两个量都只加不减），所以它是开机以来的均值：一个快的首轮会把它长期抬高，
        // 空闲时更是原样重复上一格。真·瞬时值在同源的 `current_prefill_batch` /
        // `current_decode_batch` 里——最近一个完成的同类批次，GPU 忙碌期间一直保持新鲜。
        // `current_*_batch` 是「最近一个完成的同类批次」，空闲时它会一直停在那儿。
        // 所以粒度不能只凭「有样本」就判成 `.live`：还要看此刻是否真有该阶段的
        // 在跑请求（splash 的 `active_requests[].phase` 会说是 prefill 还是 decode）。
        // 有 → 批次正在被刷新，是当前速度；没有 → 那是上一请求的终值。
        let prefillingNow = activePhases(json).contains("prefill")
        let decodingNow = activePhases(json).contains("decode")
        // 让轮询侧知道此刻真的在预填充，采样才能提到 chunk 节奏。splash 的
        // `current_prefill_batch` 每块 2048 token 才刷新一次，1 Hz 采样会让
        // 每个读数在屏幕上多停半拍，看起来就像「不动」。
        result.extras[EngineRateCounters.prefilling] = prefillingNow ? 1 : 0
        let prefillBatch = batchRate(json, "metrics.current_prefill_batch")
        let decodeBatch = batchRate(json, "metrics.current_decode_batch")
        result.prefillTokensPerSecond = prefillBatch ?? JSONValue.digNumber(json, "metrics.prefill_tokens_per_second")
        result.prefillRateKind = prefillBatch == nil ? .lifetimeMean : (prefillingNow ? .live : .lastRequest)
        result.decodeTokensPerSecond = decodeBatch ?? JSONValue.digNumber(json, "metrics.decode_tokens_per_second")
        result.decodeRateKind = decodeBatch == nil ? .lifetimeMean : (decodingNow ? .live : .lastRequest)
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
        // oMLX 只给进程累计均值（omlx/server_metrics.py: `_build_snapshot` 拿
        // (prompt − cached) / prefill_dur 累加值相除）。它的分子确实扣了缓存，
        // 所以数是真的，只是粒度粗：一次请求结束才跳一格。`/api/status` 不报
        // 累计耗时（`total_prefill_duration` 只在内部），逐秒实时值需要相邻两次
        // 完成之间对累计 token 差分，代价是只在请求边界动——所以这里如实标成
        // 均值，由上层按需要回落到网关的逐请求读数。
        result.decodeTokensPerSecond = JSONValue.digNumber(json, "avg_generation_tps")
        result.decodeRateKind = (result.decodeTokensPerSecond ?? 0) > 0 ? .lifetimeMean : .none
        result.prefillTokensPerSecond = JSONValue.digNumber(json, "avg_prefill_tps")
        result.prefillRateKind = (result.prefillTokensPerSecond ?? 0) > 0 ? .lifetimeMean : .none
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
        result.decodeRateKind = (result.decodeTokensPerSecond ?? 0) > 0 ? .live : .none
        // 预填充取数按「越接近此刻越优先」排三档：
        //   1. `in_flight[].prefill_state` —— 正在跑的那一路，服务端每完成一个
        //      chunk 就刷新（openai.py `_dashboard_publish_prefill`）。
        //   2. `latest.prefill_tok_s` —— 上一个请求的终值。空闲时它原样重复，
        //      正是「一个恒定不变的几千」的来历，只能标成 `LAST`。
        //   3. `prefill_rates.tokens / compute_time_s` —— 最近 ≤100 个预填充
        //      chunk 的滚动均值（dashboard_state.PrefillHistory.rates()）。
        //      注意**不用**同处的 `peak_tok_s`：那是单 chunk 峰值，拿它当读数
        //      就是那个大数字的直接来源。峰值只留作诊断放在 extras 里。
        let livePrefill = activePrefillRate(json)
        let windowedPrefill = prefillWindowedRate(json)
        let lastPrefill = JSONValue.digNumber(json, "latest.prefill_tok_s")
        if let handles = JSONValue.dig(json, "in_flight") as? [[String: Any]] {
            let prefilling = handles.filter { handle in
                guard let state = handle["prefill_state"] as? [String: Any] else { return false }
                return (state["phase"] as? String) != "completed"
            }.count
            result.extras[EngineRateCounters.prefilling] = Double(prefilling)
        }
        if let livePrefill {
            result.prefillTokensPerSecond = livePrefill
            result.prefillRateKind = .live
        } else if let lastPrefill, lastPrefill > 0 {
            result.prefillTokensPerSecond = lastPrefill
            result.prefillRateKind = .lastRequest
        } else if let windowedPrefill, windowedPrefill > 0 {
            result.prefillTokensPerSecond = windowedPrefill
            result.prefillRateKind = .lifetimeMean
        }
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
        // 峰值只做诊断：它是最近若干 chunk 里的最高一块，不是当前速度。
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
        // 速率不在这里算：解析器是无状态纯函数，而实时速度只能靠相邻两次
        // 采样差分。把原始计数交给 `EngineLiveRates`，由轮询侧喂时间。
        // 这些键同时说明了「这台引擎能提供真实时读数」，上层据此决定取数顺序。
        if let decode = JSONValue.digNumber(json, "gauges.generation_tokens_live") {
            result.extras[EngineRateCounters.decodeLive] = decode
        }
        if let prefillLive = JSONValue.digNumber(json, "gauges.prefill_tokens_live") {
            result.extras[EngineRateCounters.prefillLive] = prefillLive
        }
        if let prefillTokens = JSONValue.digNumber(json, "counters.prefill_tokens_total") {
            result.extras[EngineRateCounters.prefillTokens] = prefillTokens
        }
        if let prefillSeconds = JSONValue.digNumber(json, "histograms.prefill_time_seconds.sum") {
            result.extras[EngineRateCounters.prefillSeconds] = prefillSeconds
        }
        if let prefilling = JSONValue.digNumber(json, "gauges.requests_prefilling") {
            result.extras[EngineRateCounters.prefilling] = prefilling
        }
        // 前缀缓存的量级：用于解释「同一个会话的第二轮为什么不该按整段
        // 上下文算预填充」，也让诊断时能看出缓存是否真的生效。
        if let cached = JSONValue.digNumber(json, "counters.prefix_cache_tokens_total") {
            result.extras["total_cached_tokens"] = cached
        }
        if let prompt = JSONValue.digNumber(json, "counters.prompt_tokens_total") {
            result.extras["prompt_tokens_total"] = prompt
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
            // `timings` 是上一个请求的终值（llama.cpp 口径），不是此刻的速度。
            result.decodeTokensPerSecond = JSONValue.number(last["predicted_per_second"])
            result.decodeRateKind = (result.decodeTokensPerSecond ?? 0) > 0 ? .lastRequest : .none
            result.prefillTokensPerSecond = JSONValue.number(last["prompt_per_second"])
            result.prefillRateKind = (result.prefillTokensPerSecond ?? 0) > 0 ? .lastRequest : .none
        }
        return result
    }

    public static func strataMetrics(_ json: [String: Any],
                                     fallbackState: EngineRunState = .ready) -> EngineStatus {
        var result = EngineStatus(state: fallbackState)
        result.model = JSONValue.digString(json, "engine.model")
        result.maximumContextTokens = JSONValue.digInt(json, "engine.max_context")
        result.decodeTokensPerSecond = JSONValue.digNumber(json, "live.tok_s")
        result.decodeRateKind = (result.decodeTokensPerSecond ?? 0) > 0 ? .live : .none
        // strata 的引擎在 stdout 打 `PP <read> <total> <ms> <tok_s>`，serve 层
        // 每收到一行就刷新 `prefill_tok_s_mean`，并在每次请求开始时置回 None
        // （serve/server.py），所以这个字段是逐 chunk 的真·当前值，不是残留值。
        result.prefillTokensPerSecond = JSONValue.digNumber(json, "live.prefill_tok_s_mean")
        result.prefillRateKind = (result.prefillTokensPerSecond ?? 0) > 0 ? .live : .none
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
                result.decodeRateKind = (result.decodeTokensPerSecond ?? 0) > 0 ? .lastRequest : .none
            }
        }
        if JSONValue.digString(json, "live.state") == "reading" {
            result.state = .loading
        }
        return result
    }
}
