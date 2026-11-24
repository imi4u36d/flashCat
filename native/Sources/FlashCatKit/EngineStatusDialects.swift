// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

// MARK: - 说明
//
// 四家引擎的遥测形状彼此不同，但差异只有两类：**同一件事叫什么**（路径拼写）
// 和**少数几个复合读法**（数组遍历、跨字段相除、跨文档回落）。这份文件把第一类
// 写成表（`EngineStatusDialect`），第二类写成 5 个具名 refinement；`StatusParsers`
// 里的折叠核心因此不含任何引擎 id / adapter 分支。
//
// 新增引擎时有两种情况：复用已有格式（llama.cpp 系、OpenAI `/v1/models` 系）
// 只需在 descriptor 的 `telemetry` 里点名格式；引入新格式则在这里加一行方言。
// `EngineDescriptorConformanceTests` 会盯着「descriptor 点了名、这里却没实现」。

// MARK: - JSON 取值助手

extension JSONValue {
    /// 按候选顺序取第一个非空字符串。字段名在各版本引擎之间会漂移，表里因此可以
    /// 写多个拼写，而不是在解析代码里堆 `??`。
    static func firstString(_ json: [String: Any], _ paths: [String]) -> String? {
        for path in paths {
            if let value = digString(json, path) { return value }
        }
        return nil
    }

    static func firstInt(_ json: [String: Any], _ paths: [String]) -> Int? {
        for path in paths {
            if let value = digInt(json, path) { return value }
        }
        return nil
    }

    static func firstNumber(_ json: [String: Any], _ paths: [String]) -> Double? {
        for path in paths {
            if let value = digNumber(json, path) { return value }
        }
        return nil
    }

    static func firstBool(_ json: [String: Any], _ paths: [String]) -> Bool? {
        for path in paths {
            if let value = digBool(json, path) { return value }
        }
        return nil
    }
}

// MARK: - 活动阶段

/// 从状态文档读出的「此刻在跑什么」。splash 的批次速率要靠它判断粒度。
struct StatusActivity: Sendable {
    var prefilling = false
    var decoding = false

    static let idle = StatusActivity()
}

/// 哪份文档能说明「此刻在跑什么」。
enum StatusActivitySource: Sendable {
    case none
    /// `active_requests[].phase`（splash）。
    case requestPhases(path: String)

    func read(from json: [String: Any]) -> StatusActivity {
        switch self {
        case .none:
            return .idle
        case .requestPhases(let path):
            guard let array = JSONValue.dig(json, path) as? [[String: Any]] else { return .idle }
            let phases = Set(array.compactMap { $0["phase"] as? String })
            return StatusActivity(
                prefilling: phases.contains("prefill"),
                decoding: phases.contains("decode"))
        }
    }
}

// MARK: - 字段规则

/// `EngineStatus` 里可以用「一条路径直接读进来」的落点。
///
/// 落点决定读取方式（字符串 / 整数 / 数组条数），路径决定引擎的拼写。派生落点
/// 排在标量之后算，因为它们依赖别的落点先就位（`uptimeFromStartedAt` 要有
/// `startedAt`、`loadedModelsFromModel` 要有 `model`）。
enum StatusField: Sendable {
    case model
    case maximumContextTokens
    case memoryBytes
    case peakMemoryBytes
    case startedAt
    case uptimeSeconds
    case processIdentifier
    case activeRequests
    case queuedRequests
    case requestsCompleted
    case requestsFailed
    case draftAcceptance
    case reasoningEfforts
    case detail
    // 以下依赖标量先生效，按「派生」登记。
    /// 引擎没报 uptime 时用启动时刻反推。
    case uptimeFromStartedAt
    /// 用数组条数表示在跑请求（splash），数组不在时才看标量兜底。
    case activeRequestsFromArray
    /// `loadedModels = [model]`——splash 与 MTPLX 都没有单独的模型列表字段。
    case loadedModelsFromModel
    /// `kv <format>`。
    case kvDetail
    /// `v<version>`。
    case versionDetail
}

extension StatusField {
    /// 把这条路径读进 `EngineStatus`。读不到就保持原值——引擎少报一项不该把
    /// 已经由别的文档填好的字段清空。
    func apply(to status: inout EngineStatus, paths: [String], json: [String: Any]) {
        switch self {
        case .model:
            if let value = JSONValue.firstString(json, paths) { status.model = value }
        case .maximumContextTokens:
            if let value = JSONValue.firstInt(json, paths) { status.maximumContextTokens = value }
        case .memoryBytes:
            if let value = JSONValue.firstInt(json, paths) { status.memoryBytes = value }
        case .peakMemoryBytes:
            if let value = JSONValue.firstInt(json, paths) { status.peakMemoryBytes = value }
        case .startedAt:
            if let value = JSONValue.firstNumber(json, paths) { status.startedAt = value }
        case .uptimeSeconds:
            if let value = JSONValue.firstNumber(json, paths) { status.uptimeSeconds = value }
        case .processIdentifier:
            if let value = JSONValue.firstInt(json, paths) { status.processIdentifier = Int32(value) }
        case .activeRequests:
            if let value = JSONValue.firstInt(json, paths) { status.activeRequests = value }
        case .queuedRequests:
            if let value = JSONValue.firstInt(json, paths) { status.queuedRequests = value }
        case .requestsCompleted:
            if let value = JSONValue.firstInt(json, paths) { status.requestsCompleted = value }
        case .requestsFailed:
            if let value = JSONValue.firstInt(json, paths) { status.requestsFailed = value }
        case .draftAcceptance:
            if let value = JSONValue.firstNumber(json, paths) { status.draftAcceptance = value }
        case .reasoningEfforts:
            if let values = JSONValue.dig(json, paths.first ?? "") as? [String], !values.isEmpty {
                // 空列表（例如不分级的解析器）视为「未提供」，交由上层兜底。
                status.reasoningEfforts = values
            }
        case .detail:
            if let value = JSONValue.firstString(json, paths) { status.detail = value }
        case .uptimeFromStartedAt:
            // 只在真的没报 uptime 时兜底：每拍重算会让读数轻微抖动。
            if status.uptimeSeconds == nil, let startedAt = status.startedAt {
                status.uptimeSeconds = Date().timeIntervalSince1970 - startedAt
            }
        case .activeRequestsFromArray:
            guard let arrayPath = paths.first else { return }
            if let array = JSONValue.dig(json, arrayPath) as? [Any] {
                status.activeRequests = array.count
            } else {
                status.activeRequests = JSONValue.firstInt(json, Array(paths.dropFirst())) ?? 0
            }
        case .loadedModelsFromModel:
            status.loadedModels = status.model.map { [$0] } ?? []
        case .kvDetail:
            if let value = JSONValue.firstString(json, paths) { status.detail = "kv \(value)" }
        case .versionDetail:
            if let value = JSONValue.firstString(json, paths) { status.detail = "v\(value)" }
        }
    }
}

// MARK: - 速率规则

/// 一个速率的取法：按顺序尝试候选档，第一个给出有效值的档生效。
///
/// 速率与它的粒度必须**成对**写入。文档按 health → status → metrics → props →
/// inventory 的顺序折叠，后到的会覆盖数值；如果只让数值覆盖、粒度另外取最强，
/// 就会出现「数值是后来的累计均值、角标却写着 LIVE」。
struct StatusRateRule: Sendable {
    /// 读数的落点。
    enum Target: Sendable {
        case decode
        case prefill
        case lifetimeDecode
    }

    /// 读数来源。
    enum Source: Sendable {
        /// 按候选顺序取第一个字段。`*_tok_s` 这类字段「没有数据」就是 0 或缺失。
        case paths([String])
        /// 分子 / 分母两个字段相除，两边都必须 > 0（Prometheus 的直方图均值）。
        case quotient(numerator: [String], denominator: [String])
        /// `<prefix>.tokens_per_second`，且 `<prefix>.valid != false`。splash 的
        /// 批次读数：引擎刚启动或没跑过同类批次时必须交回均值口径而不是报 0。
        case batch(prefix: String)
        /// MTPLX 的 `in_flight[]`：正在跑的那一路的预填充速率（取 elapsed 最大的一路）。
        case activePrefillHandles
    }

    /// 粒度的判定方式。
    enum Kind: Sendable {
        /// 值 > 0 时用这个粒度，否则 `.none`。
        case whenPositive(EngineRateKind)
        /// 有值就按这个粒度写，不管大小。
        case fixed(EngineRateKind)
    }

    struct Tier: Sendable {
        let source: Source
        let kind: Kind
        /// 只接受 > 0 的值。`*_tok_s` 类字段的「没有数据」就是 0。
        var requiresPositive: Bool = true
        /// 档位命中后，如果此刻真有该阶段在跑，把 `.lastRequest` 升成 `.live`。
        /// splash 的批次读数是「最近一个完成的批次」，空闲时会一直停在原处。
        var escalatesWithActivity: Bool = false
    }

    let target: Target
    let tiers: [Tier]
    /// 一档都没命中时写下的粒度。splash 的均值档即使没值也算「均值口径」。
    var fallbackKind: EngineRateKind? = nil

    func apply(to status: inout EngineStatus, json: [String: Any], activity: StatusActivity) {
        for tier in tiers {
            guard let value = tier.source.read(from: json) else { continue }
            if tier.requiresPositive, !(value > 0) { continue }
            var kind: EngineRateKind =
                switch tier.kind {
                case .fixed(let declared): declared
                case .whenPositive(let declared): value > 0 ? declared : .none
                }
            if tier.escalatesWithActivity {
                let active = target == .decode ? activity.decoding : activity.prefilling
                kind = active ? .live : .lastRequest
            }
            write(value, kind: kind, into: &status)
            return
        }
        if let fallbackKind { write(nil, kind: fallbackKind, into: &status) }
    }

    private func write(_ value: Double?, kind: EngineRateKind, into status: inout EngineStatus) {
        switch target {
        case .decode:
            if let value { status.decodeTokensPerSecond = value }
            status.decodeRateKind = kind
        case .prefill:
            if let value { status.prefillTokensPerSecond = value }
            status.prefillRateKind = kind
        case .lifetimeDecode:
            if let value { status.lifetimeDecodeTokensPerSecond = value }
        }
    }
}

extension StatusRateRule.Source {
    func read(from json: [String: Any]) -> Double? {
        switch self {
        case .paths(let paths):
            return JSONValue.firstNumber(json, paths)
        case .quotient(let numerator, let denominator):
            guard let top = JSONValue.firstNumber(json, numerator), top > 0,
                let bottom = JSONValue.firstNumber(json, denominator), bottom > 0
            else { return nil }
            return top / bottom
        case .batch(let prefix):
            guard let value = JSONValue.digNumber(json, "\(prefix).tokens_per_second"), value > 0,
                JSONValue.digBool(json, "\(prefix).valid") != false
            else { return nil }
            return value
        case .activePrefillHandles:
            guard let handles = JSONValue.dig(json, "in_flight") as? [[String: Any]] else { return nil }
            var best: (elapsed: Double, rate: Double)?
            for handle in handles {
                guard let state = handle["prefill_state"] as? [String: Any],
                    let phase = state["phase"] as? String, phase != "completed"
                else { continue }
                let elapsed = JSONValue.number(state["elapsed_s"]) ?? 0
                let done = JSONValue.number(state["tokens_done"]) ?? 0
                let reported =
                    JSONValue.number(state["live_prefill_tok_s"])
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
    }
}

// MARK: - TTFT 规则

/// TTFT 的取法。每个方言最多一条。
struct StatusTTFTRule: Sendable {
    enum Source: Sendable {
        /// 字段本身是毫秒。
        case milliseconds([String])
        /// 字段是秒。
        case seconds([String])
        /// `sum / count` 的直方图均值，单位秒。
        case histogramSeconds(sum: String, count: String)
    }

    let source: Source
    let kind: EngineTTFTKind

    func apply(to status: inout EngineStatus, json: [String: Any]) {
        switch source {
        case .milliseconds(let paths):
            guard let value = JSONValue.firstNumber(json, paths) else { return }
            status.ttftMilliseconds = value
            status.ttftKind = value > 0 ? kind : .none
        case .seconds(let paths):
            guard let value = JSONValue.firstNumber(json, paths), value > 0 else { return }
            status.ttftMilliseconds = value * 1000
            status.ttftKind = kind
        case .histogramSeconds(let sum, let count):
            guard let total = JSONValue.firstNumber(json, [sum]), total > 0,
                let samples = JSONValue.firstInt(json, [count]), samples > 0
            else { return }
            status.ttftMilliseconds = total / Double(samples) * 1000
            status.ttftKind = kind
        }
    }
}

// MARK: - extras 规则

/// 写进 `EngineStatus.extras` 的读数。键必须与 `EngineLiveRates` 用同一组常量。
struct StatusExtraRule: Sendable {
    enum Value: Sendable {
        /// 数字原样。
        case number([String])
        /// 枚举转 0/1：大小写不敏感地等于「正常」值记 0，否则记 1。
        case flagNormal([String], String)
    }

    let key: String
    let value: Value

    func apply(to status: inout EngineStatus, json: [String: Any]) {
        switch value {
        case .number(let paths):
            if let number = JSONValue.firstNumber(json, paths) { status.extras[key] = number }
        case .flagNormal(let paths, let normal):
            if let text = JSONValue.firstString(json, paths) {
                status.extras[key] = text.lowercased() == normal.lowercased() ? 0 : 1
            }
        }
    }
}

// MARK: - 条件覆盖

/// 有条件覆盖：条件命中时改写状态或摘要。这些是「状态机规则」，不是字段映射。
struct StatusOverrideRule: Sendable {
    enum When: Sendable {
        /// 有模型在加载、但还没有可用的常驻模型（oMLX 的 `models_loading`）。
        case loadingWithoutLoadedModels([String])
        /// 没有任何模型身份（MTPLX 的 supervisor 已起、模型尚未就绪）。
        case modelAbsent
    }

    let when: When
    /// 命中后写入的状态；nil 表示不动。
    var state: EngineRunState? = nil
    /// 命中后写入的摘要。
    var detail: String? = nil

    func apply(to status: inout EngineStatus, json: [String: Any]) {
        let hit: Bool
        switch when {
        case .loadingWithoutLoadedModels(let paths):
            let count = JSONValue.firstInt(json, paths) ?? 0
            hit = count > 0 && status.state == .ready && status.loadedModels.isEmpty
        case .modelAbsent:
            hit = status.model == nil && status.loadedModels.isEmpty
        }
        guard hit else { return }
        if let state { status.state = state }
        if let detail { status.detail = detail }
    }
}

// MARK: - 方言

/// 少数无法写成「一条路径读进来」的读法：跨文档的身份回落、数组遍历、跨字段
/// 相除。每一项只服务一个格式，命名按格式走，这样新增引擎时不必改动它们。
enum StatusRefinement: Sendable {
    /// oMLX 的模型身份与加载态（`loaded_models` → `default_model` → `/health`）。
    case omlxPool
    /// 从 `/v1/models/status` 的行推出当前模型与上下文窗口。
    case omlxModelStatus
    /// MTPLX 的 `/health` 身份、草稿命中率、在跑预填充数。
    case mtplxTail
    /// Prometheus 的内存口径、失败计数合并、uptime 反推。
    case prometheusGauges
    /// 从 OpenAI `/v1/models` 的行推出常驻模型与当前模型。
    case openAIModelsStatus
}

/// 一个遥测格式的解析声明。所有字段都是数据，解析核心照着它跑。
struct EngineStatusDialect: Sendable {
    /// 「此刻在跑什么」从哪里看。
    var activity: StatusActivitySource = .none
    /// 标量字段：落点 → 路径候选。
    var fields: [StatusField: [String]] = [:]
    /// 依赖标量结果的派生字段。
    var derived: [StatusField: [String]] = [:]
    /// 速率取法。
    var rates: [StatusRateRule] = []
    /// TTFT 取法。
    var ttft: StatusTTFTRule? = nil
    /// 写进 extras 的读数。
    var extras: [StatusExtraRule] = []
    /// 状态机覆盖。
    var overrides: [StatusOverrideRule] = []
    /// 复合读法。
    var refinements: [StatusRefinement] = []
}

// MARK: - 方言表

/// 表里的一档来源。
private func tier(
    _ source: StatusRateRule.Source,
    _ kind: StatusRateRule.Kind,
    requiresPositive: Bool = true,
    escalatesWithActivity: Bool = false
) -> StatusRateRule.Tier {
    StatusRateRule.Tier(
        source: source,
        kind: kind,
        requiresPositive: requiresPositive,
        escalatesWithActivity: escalatesWithActivity)
}

/// 全部方言，键就是 descriptor 的 `telemetry[].format`。
enum EngineStatusDialects {

    /// 「只有一份状态文档」的引擎走 `parse(engine:)`；mlx-serve 的状态分散在
    /// metrics / props / inventory 多份文档里，必须走 `parse(documents:)`，
    /// 所以不在这张表里。
    static let primaryStatusFormat: [EngineAdapterID: EngineTelemetryFormat] = [
        .splash: .splashStatus,
        .omlx: .omlxStatus,
        .mtplx: .mtplxSnapshot,
    ]

    static let byFormat: [EngineTelemetryFormat: EngineStatusDialect] = [
        .splashStatus: splashStatus,
        .omlxStatus: omlxStatus,
        .omlxModels: omlxModelsStatus,
        .mtplxSnapshot: mtplxSnapshot,
        .openAIModels: openAIModelsStatus,
        .prometheusJSON: prometheusJSONStatus,
        .llamaProps: llamaPropsStatus,
    ]

    static func dialect(for format: EngineTelemetryFormat) -> EngineStatusDialect? {
        byFormat[format]
    }

    // MARK: splash

    /// splash 把一切嵌在 `metrics` / `instance` / `memory_actual` 下面，并另有一份
    /// `active_requests[]`。它的 `metrics.*_tokens_per_second` 是**两个进程累计
    /// 计数器之比**（只增不减），所以那是开机以来的均值，用它当读数会让快的首轮
    /// 长期抬高显示值。
    private static let splashStatus = EngineStatusDialect(
        activity: .requestPhases(path: "active_requests"),
        fields: [
            .model: ["instance.model"],
            .maximumContextTokens: ["maximum_context_tokens"],
            .memoryBytes: ["memory_actual.current_bytes"],
            .peakMemoryBytes: ["memory_actual.peak_bytes"],
            .startedAt: ["instance.started_at"],
            .uptimeSeconds: ["uptime_seconds"],
            .processIdentifier: ["instance.pid"],
            .queuedRequests: ["admission.waiting"],
            .requestsCompleted: ["requests.completed"],
            .requestsFailed: ["requests.failed"],
            .draftAcceptance: ["metrics.draft_acceptance_rate"],
        ],
        derived: [
            .uptimeFromStartedAt: [],
            .activeRequestsFromArray: ["active_requests", "admission.restoring"],
            .loadedModelsFromModel: [],
            .kvDetail: ["kv.format"],
        ],
        rates: [
            // 真·瞬时值在同源的 `current_*_batch`：最近一个完成的同类批次。
            // 空闲时它会一直停在那儿，所以粒度还要看此刻有没有该阶段在跑。
            StatusRateRule(
                target: .decode,
                tiers: [
                    tier(
                        .batch(prefix: "metrics.current_decode_batch"),
                        .fixed(.lastRequest), escalatesWithActivity: true),
                    tier(
                        .paths(["metrics.decode_tokens_per_second"]),
                        .fixed(.lifetimeMean), requiresPositive: false),
                ], fallbackKind: .lifetimeMean),
            StatusRateRule(
                target: .prefill,
                tiers: [
                    tier(
                        .batch(prefix: "metrics.current_prefill_batch"),
                        .fixed(.lastRequest), escalatesWithActivity: true),
                    tier(
                        .paths(["metrics.prefill_tokens_per_second"]),
                        .fixed(.lifetimeMean), requiresPositive: false),
                ], fallbackKind: .lifetimeMean),
            StatusRateRule(
                target: .lifetimeDecode,
                tiers: [
                    tier(
                        .paths(["metrics.decode_tokens_per_second"]),
                        .fixed(.lifetimeMean), requiresPositive: false)
                ]),
        ],
        ttft: StatusTTFTRule(source: .milliseconds(["metrics.ttft_ms.p50"]), kind: .p50),
        extras: [
            StatusExtraRule(
                key: "thermal_state",
                value: .flagNormal(["metrics.thermal_state", "thermal_state"], "nominal")),
            StatusExtraRule(
                key: "memory_pressure_warn",
                value: .flagNormal(["memory_pressure"], "normal")),
        ])

    // MARK: oMLX

    /// oMLX 的 `/api/status` 是一份扁平文档。它只给进程累计均值：一次请求结束才
    /// 跳一格，所以如实标成均值，由上层按需要回落到网关的逐请求读数。
    private static let omlxStatus = EngineStatusDialect(
        fields: [
            .activeRequests: ["active_requests"],
            .queuedRequests: ["waiting_requests"],
            .requestsCompleted: ["total_requests"],
            .memoryBytes: ["model_memory_used"],
            .peakMemoryBytes: ["model_memory_max"],
            .uptimeSeconds: ["uptime_seconds"],
        ],
        derived: [
            .versionDetail: ["version"]
        ],
        rates: [
            StatusRateRule(
                target: .decode,
                tiers: [
                    tier(.paths(["avg_generation_tps"]), .whenPositive(.lifetimeMean), requiresPositive: false)
                ]),
            StatusRateRule(
                target: .prefill,
                tiers: [
                    tier(.paths(["avg_prefill_tps"]), .whenPositive(.lifetimeMean), requiresPositive: false)
                ]),
            StatusRateRule(
                target: .lifetimeDecode,
                tiers: [
                    tier(.paths(["avg_generation_tps"]), .fixed(.lifetimeMean), requiresPositive: false)
                ]),
        ],
        extras: [
            StatusExtraRule(key: "cache_efficiency", value: .number(["cache_efficiency"])),
            StatusExtraRule(key: "total_cached_tokens", value: .number(["total_cached_tokens"])),
            // 缓存命中率的分母。`cache_efficiency` 是 percent，但它是这两个计数器
            // 相除得来的；统一用原始计数，界面就不用按引擎分两套单位。
            StatusExtraRule(key: "prompt_tokens_total", value: .number(["total_prompt_tokens"])),
            StatusExtraRule(key: "models_loaded", value: .number(["models_loaded"])),
        ],
        refinements: [.omlxPool])

    private static let omlxModelsStatus = EngineStatusDialect(refinements: [.omlxModelStatus])

    // MARK: MTPLX

    /// MTPLX 把真相分在三处：`/health`（pid、模型）、`/v1/mtplx/snapshot`（实时
    /// 数字）、`/v1/models`（上下文长度）。
    private static let mtplxSnapshot = EngineStatusDialect(
        fields: [
            .activeRequests: ["active_requests", "scheduler.active_requests"],
            .requestsCompleted: ["lifetime.requests_total"],
            .memoryBytes: ["mem.peak_memory_bytes"],
            .peakMemoryBytes: ["mem.peak_memory_bytes"],
            .uptimeSeconds: ["uptime_s", "lifetime.uptime_s"],
            .startedAt: ["lifetime.started_at_s"],
            .maximumContextTokens: ["context_window"],
            .reasoningEfforts: ["settings.reasoning_policy.effort_levels"],
        ],
        rates: [
            // 原始速率按「越接近此刻越优先」排：滚动窗口 → 上一请求终值。
            StatusRateRule(
                target: .decode,
                tiers: [
                    tier(.paths(["rolling.mean"]), .fixed(.live)),
                    tier(.paths(["latest.decode_tok_s"]), .fixed(.lastRequest)),
                ]),
            // 预填充三档：在跑的那一路 → 上一请求终值 → 最近 ≤100 chunk 的均值。
            // 刻意不用同处的 `peak_tok_s`：那是单 chunk 峰值，不是当前速度。
            StatusRateRule(
                target: .prefill,
                tiers: [
                    tier(.activePrefillHandles, .fixed(.live)),
                    tier(.paths(["latest.prefill_tok_s"]), .fixed(.lastRequest)),
                    tier(
                        .quotient(
                            numerator: ["prefill_rates.tokens"],
                            denominator: ["prefill_rates.compute_time_s"]),
                        .fixed(.lifetimeMean)),
                ]),
        ],
        ttft: StatusTTFTRule(source: .seconds(["latest.ttft_s"]), kind: .lastRequest),
        extras: [
            StatusExtraRule(key: "mtp_depth", value: .number(["latest.mtp_depth"])),
            StatusExtraRule(key: "memory_pressure_level", value: .number(["memory_pressure_level"])),
            StatusExtraRule(key: "total_cached_tokens", value: .number(["lifetime.cached_tokens_total"])),
            StatusExtraRule(key: "prompt_tokens_total", value: .number(["lifetime.prompt_tokens_total"])),
            // 峰值只做诊断：它是最近若干 chunk 里的最高一块。
            StatusExtraRule(key: "prefill_peak_tps", value: .number(["prefill_rates.peak_tok_s"])),
        ],
        overrides: [StatusOverrideRule(when: .modelAbsent, state: .loading)],
        refinements: [.mtplxTail])

    // MARK: mlx-serve

    private static let prometheusJSONStatus = EngineStatusDialect(
        fields: [
            .activeRequests: ["gauges.requests_running"],
            .queuedRequests: ["gauges.requests_waiting"],
            .requestsCompleted: ["counters.requests_success_total"],
            .startedAt: ["gauges.process_start_time_seconds"],
        ],
        rates: [
            // 进程级累计吞吐：分子分母都是同一个进程里真正算过/生成过的量。这不是
            // 「此刻多快」，但它是引擎唯一能自报的均值，网关没有样本时靠它至少说
            // 出一句真话。
            StatusRateRule(
                target: .decode,
                tiers: [
                    tier(
                        .quotient(
                            numerator: ["counters.generation_tokens_total"],
                            denominator: ["histograms.decode_time_seconds.sum"]),
                        .fixed(.lifetimeMean))
                ]),
            StatusRateRule(
                target: .prefill,
                tiers: [
                    tier(
                        .quotient(
                            numerator: ["counters.prefill_tokens_total"],
                            denominator: ["histograms.prefill_time_seconds.sum"]),
                        .fixed(.lifetimeMean))
                ]),
            StatusRateRule(
                target: .lifetimeDecode,
                tiers: [
                    tier(
                        .quotient(
                            numerator: ["counters.generation_tokens_total"],
                            denominator: ["histograms.decode_time_seconds.sum"]),
                        .fixed(.lifetimeMean))
                ]),
        ],
        ttft: StatusTTFTRule(
            source: .histogramSeconds(
                sum: "histograms.time_to_first_token_seconds.sum",
                count: "histograms.time_to_first_token_seconds.count"), kind: .lifetimeMean),
        extras: [
            // 速率不在这里算：解析器是无状态纯函数，实时速度只能靠相邻两次采样
            // 差分。这里只交出原始计数，由 `EngineLiveRates` 换算。
            StatusExtraRule(
                key: EngineRateCounters.decodeLive,
                value: .number(["gauges.generation_tokens_live"])),
            StatusExtraRule(
                key: EngineRateCounters.prefillLive,
                value: .number(["gauges.prefill_tokens_live"])),
            StatusExtraRule(
                key: EngineRateCounters.prefillTokens,
                value: .number(["counters.prefill_tokens_total"])),
            StatusExtraRule(
                key: EngineRateCounters.prefillSeconds,
                value: .number(["histograms.prefill_time_seconds.sum"])),
            StatusExtraRule(
                key: EngineRateCounters.prefilling,
                value: .number(["gauges.requests_prefilling"])),
            StatusExtraRule(
                key: "total_cached_tokens",
                value: .number(["counters.prefix_cache_tokens_total"])),
            StatusExtraRule(
                key: "prompt_tokens_total",
                value: .number(["counters.prompt_tokens_total"])),
        ],
        refinements: [.prometheusGauges])

    /// llama-server 兼容的 `/props`：不加载请求也能给出内存与有效上下文。
    private static let llamaPropsStatus = EngineStatusDialect(
        fields: [
            .memoryBytes: ["memory.active_bytes", "memory.peak_bytes"],
            .peakMemoryBytes: ["memory.peak_bytes"],
            .maximumContextTokens: ["memory.max_safe_context", "default_generation_settings.n_ctx"],
            .model: ["default_generation_settings.model"],
            .detail: ["settings.engine", "model_info.model_type"],
        ])

    private static let openAIModelsStatus = EngineStatusDialect(refinements: [.openAIModelsStatus])

    // MARK: 折叠

    /// 按方言把一份文档折成 `EngineStatus`。
    ///
    /// 顺序固定：活动阶段 → 标量字段 → 派生字段 → 速率 → TTFT → extras →
    /// 复合读法 → 状态覆盖。派生要在标量之后（依赖它们的值），覆盖要在最后
    /// （它读的是已经填好的 loadedModels / state）。
    static func fold(
        _ format: EngineTelemetryFormat,
        json: [String: Any],
        health: [String: Any]? = nil,
        fallbackState: EngineRunState
    ) -> EngineStatus {
        var status = EngineStatus(state: fallbackState)
        // 未知格式降级成「只有状态」：descriptor 可能是由未来版本的 pack 清单带
        // 进来的，界面不该因此整块空白，也不该让一次解析抛错。
        guard let dialect = byFormat[format] else { return status }

        let activity = dialect.activity.read(from: json)
        if case .requestPhases = dialect.activity {
            // 让轮询侧知道此刻真的在预填充，采样才能提到 chunk 节奏：splash 的
            // 批次读数每 2048 token 才刷新一次，1 Hz 采样会让读数多停半拍。
            status.extras[EngineRateCounters.prefilling] = activity.prefilling ? 1 : 0
        }
        for (field, paths) in dialect.fields {
            field.apply(to: &status, paths: paths, json: json)
        }
        for (field, paths) in dialect.derived {
            field.apply(to: &status, paths: paths, json: json)
        }
        for rule in dialect.rates {
            rule.apply(to: &status, json: json, activity: activity)
        }
        dialect.ttft?.apply(to: &status, json: json)
        for rule in dialect.extras {
            rule.apply(to: &status, json: json)
        }
        for refinement in dialect.refinements {
            refinement.apply(to: &status, json: json, health: health)
        }
        for rule in dialect.overrides {
            rule.apply(to: &status, json: json)
        }
        return status
    }
}

// MARK: - 复合读法

extension StatusRefinement {
    func apply(to status: inout EngineStatus, json: [String: Any], health: [String: Any]?) {
        switch self {
        case .omlxPool:
            // `/health` 是最便宜的那一份，模型身份在它和 `/api/status` 里都可能出现。
            let loaded = (JSONValue.dig(json, "loaded_models") as? [String]) ?? []
            status.loadedModels = loaded
            status.model =
                loaded.first
                ?? JSONValue.firstString(json, ["default_model"])
                ?? (health?["default_model"] as? String)
            let loading = JSONValue.firstInt(json, ["models_loading"]) ?? 0
            if loading > 0, status.state == .ready, loaded.isEmpty {
                status.state = .loading
            }
        case .omlxModelStatus:
            let parsed = EngineStatusParser.omlxModels(json)
            let chatModels = parsed.models.filter { !$0.helper && !$0.hidden }
            status.loadedModels = chatModels.filter(\.loaded).map(\.id)
            status.model = status.loadedModels.first
            if parsed.loadedCount > 0, status.loadedModels.isEmpty,
                chatModels.contains(where: \.loading)
            {
                status.state = .loading
            }
            if let current = chatModels.first(where: \.loaded) {
                status.maximumContextTokens = current.maximumContextTokens
                status.detail = current.kind
            }
        case .mtplxTail:
            // `/health` 带身份（模型、pid、启动时刻、生成模式），snapshot 带数字。
            if let modelId = JSONValue.firstString(json, ["model_id"]) {
                status.model = modelId
                status.loadedModels = [modelId]
            }
            if let health {
                if let name = JSONValue.string(health["model"]), status.model == nil {
                    status.model = name
                    status.loadedModels = [name]
                }
                if let pid = JSONValue.digInt(health, "startup.pid") {
                    status.processIdentifier = Int32(pid)
                }
                if status.startedAt == nil {
                    status.startedAt = JSONValue.digNumber(health, "startup.started_at")
                }
                if let context = JSONValue.digInt(health, "context_window"),
                    status.maximumContextTokens == nil
                {
                    status.maximumContextTokens = context
                }
                if let mode = JSONValue.digString(health, "generation_mode") {
                    status.detail = mode.uppercased()
                }
            }
            if let accepted = JSONValue.firstNumber(json, ["latest.accepted_drafts"]),
                let drafted = JSONValue.firstNumber(json, ["latest.drafted_tokens"]),
                drafted > 0
            {
                status.draftAcceptance = accepted / drafted
            }
            if let handles = JSONValue.dig(json, "in_flight") as? [[String: Any]] {
                let prefilling = handles.filter { handle in
                    guard let state = handle["prefill_state"] as? [String: Any] else { return false }
                    return (state["phase"] as? String) != "completed"
                }.count
                status.extras[EngineRateCounters.prefilling] = Double(prefilling)
            }
        case .prometheusGauges:
            let failed = JSONValue.firstInt(json, ["counters.requests_failed_total"]) ?? 0
            let cancelled = JSONValue.firstInt(json, ["counters.requests_cancelled_total"]) ?? 0
            let rejected = JSONValue.firstInt(json, ["counters.requests_rejected_total"]) ?? 0
            status.requestsFailed = failed + cancelled + rejected
            // `mlx_active_bytes` 在没加载权重时是一个很小的哨兵值，不能当真。
            if let bytes = JSONValue.firstInt(json, ["gauges.mlx_active_bytes"]), bytes > 16 {
                status.memoryBytes = bytes
            } else if let mb = JSONValue.firstInt(json, ["gauges.memory_mb"]) {
                status.memoryBytes = mb * 1_048_576
            }
            if let startedAt = status.startedAt {
                status.uptimeSeconds = max(0, Date().timeIntervalSince1970 - startedAt)
            }
        case .openAIModelsStatus:
            let entries = (json["data"] as? [[String: Any]]) ?? []
            for entry in entries {
                guard let id = JSONValue.string(entry["id"]), !id.isEmpty else { continue }
                let parsedCapabilities = EngineStatusParser.capabilities(of: entry)
                let isChat = parsedCapabilities.isEmpty || parsedCapabilities.contains("chat")
                let isImage = parsedCapabilities.contains("image")
                let isVideo = parsedCapabilities.contains("video")
                // 图像/视频模型也要进 loadedModels：网关与对话页换模型时靠它确认
                // 「目标权重已经常驻」，否则等待切换会一直等到超时。
                if !parsedCapabilities.isEmpty, !isChat, !isImage, !isVideo { continue }
                let state = JSONValue.digString(entry, "status.value", "state")?.lowercased()
                let loaded =
                    JSONValue.bool(entry["loaded"])
                    ?? (state.map { $0 == "loaded" || $0 == "ready" })
                    ?? (state == "unloaded" ? false : true)
                if loaded { status.loadedModels.append(id) }
                if state == "loading" { status.state = .loading }
                // 只有对话模型能充当「当前模型」：图像权重不提供上下文窗口，
                // 当成当前模型会让顶栏的上下文用量与聊天参数全部错位。
                if loaded, isChat, status.model == nil {
                    status.model = id
                    status.maximumContextTokens =
                        JSONValue.int(entry["max_model_len"])
                        ?? JSONValue.int(entry["context_length"])
                        ?? JSONValue.digInt(entry, "meta.n_ctx", "meta.context_length")
                }
            }
            if status.loadedModels.isEmpty, !entries.isEmpty { status.model = nil }
        }
    }
}
