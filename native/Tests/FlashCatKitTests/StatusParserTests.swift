import XCTest
@testable import FlashCatKit

final class StatusParserTests: XCTestCase {

    // MARK: helpers

    private func fixture(_ name: String, in folder: String) throws -> Data {
        let bundle = Bundle.module
        guard let base = bundle.url(forResource: "Fixtures", withExtension: nil) else {
            throw XCTSkip("Fixtures directory missing from test bundle")
        }
        let url = base.appendingPathComponent(folder).appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    /// Samples captured with `curl -i` start with response headers; strip them.
    private func json(_ data: Data) throws -> [String: Any] {
        var body = data
        if let text = String(data: data, encoding: .utf8), text.hasPrefix("HTTP/") {
            guard let range = data.range(of: Data("\r\n\r\n".utf8)) else {
                throw XCTSkip("malformed header block")
            }
            body = data.subdata(in: range.upperBound..<data.count)
        }
        let object = try JSONSerialization.jsonObject(with: body)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func load(_ name: String, _ folder: String) throws -> [String: Any] {
        try json(try fixture(name, in: folder))
    }

    // MARK: oMLX

    func testOMLXStatusMapsCountersAndMemory() throws {
        let status = EngineStatusParser.parse(engine: .omlx,
                                              status: try load("api-status.json", "omlx"),
                                              health: try load("health.txt", "omlx"))
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.detail, "v0.7.2")
        XCTAssertEqual(status.uptimeSeconds.map { $0 > 0 }, true)
        XCTAssertEqual(status.activeRequests, 0)
        XCTAssertEqual(status.requestsCompleted, 0)
        // `loaded_models` is empty on an idle server, so the default model is the
        // only hint about what would run.
        XCTAssertEqual(status.model, "Qwen3.8-27B-oQ4e-mtp")
        XCTAssertEqual(status.maximumContextTokens, nil)
    }

    /// 缓存命中率的分母：三家引擎都把「提示词总量」原样交出来，上层才能和
    /// `total_cached_tokens` 相除。oMLX 的 `cache_efficiency` 是百分数，
    /// 但同一份 payload 里本来就有两个计数器，界面统一用比值，少一套单位。
    func testEnginesExposePromptTotalsForCacheHitRate() {
        let mtplx = EngineStatusParser.mtplx(snapshot: [
            "lifetime": ["prompt_tokens_total": 16_000, "cached_tokens_total": 12_800],
        ])
        XCTAssertEqual(mtplx.extras["prompt_tokens_total"], 16_000)
        XCTAssertEqual(mtplx.extras["total_cached_tokens"], 12_800)

        let omlx = EngineStatusParser.omlx(status: [
            "total_prompt_tokens": 16_000,
            "total_cached_tokens": 12_800,
            "cache_efficiency": 80.0,
        ])
        XCTAssertEqual(omlx.extras["prompt_tokens_total"], 16_000)
        XCTAssertEqual(omlx.extras["total_cached_tokens"], 12_800)
    }

    func testOMLXModelInventoryKeepsOptionalFieldsOptional() throws {
        let payload = try load("models-status.json", "omlx")
        let parsed = EngineStatusParser.omlxModels(payload)
        XCTAssertEqual(parsed.models.count, 8)
        XCTAssertEqual(parsed.loadedCount, 1)

        let markitdown = try XCTUnwrap(parsed.models.first { $0.id == "MarkItDown" })
        // Built-in tools have no path and no context window; every field the
        // regular models carry must survive their absence.
        XCTAssertEqual(markitdown.path, "builtin://markitdown")
        XCTAssertNil(markitdown.maximumContextTokens)
        XCTAssertFalse(markitdown.helper)

        // The only entry `loaded` in this capture is the built-in converter, so
        // `loaded_count` is 1 even though no weights are resident.
        XCTAssertTrue(markitdown.loaded)

        let qwen = try XCTUnwrap(parsed.models.first { $0.id == "Qwen3.8-27B-oQ4e-mtp" })
        XCTAssertEqual(qwen.maximumContextTokens, 262144)
        XCTAssertEqual(qwen.path, "/Users/example/.omlx/models/Jundot/Qwen3.8-27B-oQ4e-mtp")
        XCTAssertGreaterThan(qwen.bytes ?? 0, 0)
        XCTAssertFalse(qwen.loaded)

        let helper = try XCTUnwrap(parsed.models.first { $0.id == "Qwen3.8-27B-DFlash2" })
        XCTAssertTrue(helper.helper)
        XCTAssertTrue(helper.hidden)
    }

    func testOMLXLoadingStateWhileModelIsWarmingUp() {
        let status = EngineStatusParser.parse(engine: .omlx, status: [
            "models_loading": 1,
            "models_loaded": 0,
            "loaded_models": [String](),
        ], health: nil)
        XCTAssertEqual(status.state, .loading)
    }

    // MARK: MTPLX

    func testMTPLXSnapshotMapsRollingRates() throws {
        let health = try load("health.json", "mtplx")
        let snapshot = try load("snapshot-after.json", "mtplx")
        let status = EngineStatusParser.parse(engine: .mtplx, status: snapshot, health: health)

        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.model, "youssofal-qwen3.5-4b-mtplx-optimized-speed")
        XCTAssertEqual(status.maximumContextTokens, 262144)
        XCTAssertEqual(status.processIdentifier.map { $0 > 0 }, true)
        XCTAssertNotNil(status.uptimeSeconds)
        XCTAssertGreaterThan(status.decodeTokensPerSecond ?? 0, 0)
        XCTAssertGreaterThan(status.uptimeSeconds ?? 0, 0)
    }

    func testMTPLXIdleSnapshotHasNoLatestBlock() throws {
        let health = try load("health.json", "mtplx")
        let snapshot = try load("snapshot.json", "mtplx")
        // Before any request `latest` is null; the parser must fall back rather
        // than report a decode rate of zero-ish garbage.
        XCTAssertTrue(snapshot["latest"] is NSNull)
        let status = EngineStatusParser.parse(engine: .mtplx, status: snapshot, health: health)
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.activeRequests, 0)
        XCTAssertEqual(status.detail, "MTP")
    }

    func testMTPLXModelsExposeContextLength() throws {
        let models = EngineStatusParser.openAIModels(try load("models.json", "mtplx"), engine: .mtplx)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].id, "youssofal-qwen3.5-4b-mtplx-optimized-speed")
        XCTAssertEqual(models[0].maximumContextTokens, 262144)
        XCTAssertEqual(models[0].engine, .mtplx)
    }

    // MARK: splash

    func testSplashStatusKeepsNestedMetrics() {
        let status = EngineStatusParser.parse(engine: .splash, status: [
            "metrics": [
                "decode_tokens_per_second": 63.5,
                "prefill_tokens_per_second": 410.0,
                "draft_acceptance_rate": 0.82,
                "ttft_ms": ["p50": 120.0],
            ],
            "admission": ["waiting": 2],
            "instance": ["model": "Qwen3.8-27B-DFlash2", "pid": 4711],
            "requests": ["completed": 12, "failed": 1],
            "memory_actual": ["current_bytes": 1_000, "peak_bytes": 2_000],
            "maximum_context_tokens": 65536,
            "kv": ["format": "q8"],
        ], health: nil)

        XCTAssertEqual(status.decodeTokensPerSecond, 63.5)
        XCTAssertEqual(status.prefillTokensPerSecond, 410)
        // 没有 current_*_batch 时这两个数是进程累计计数器之比，只能标成均值。
        XCTAssertEqual(status.decodeRateKind, .lifetimeMean)
        XCTAssertEqual(status.prefillRateKind, .lifetimeMean)
        XCTAssertEqual(status.draftAcceptance, 0.82)
        XCTAssertEqual(status.ttftMilliseconds, 120)
        XCTAssertEqual(status.queuedRequests, 2)
        XCTAssertEqual(status.model, "Qwen3.8-27B-DFlash2")
        XCTAssertEqual(status.loadedModels, ["Qwen3.8-27B-DFlash2"])
        XCTAssertEqual(status.processIdentifier, 4711)
        XCTAssertEqual(status.requestsCompleted, 12)
        XCTAssertEqual(status.requestsFailed, 1)
        XCTAssertEqual(status.memoryBytes, 1_000)
        XCTAssertEqual(status.peakMemoryBytes, 2_000)
        XCTAssertEqual(status.maximumContextTokens, 65_536)
        XCTAssertEqual(status.detail, "kv q8")
    }

    /// splash 的 `metrics.prefill_tokens_per_second` 是两个进程累计计数器之比，
    /// 一个快的首轮会把它长期抬高；真·瞬时值在同源的 `current_prefill_batch`。
    /// 有批次样本时必须走批次，且标成 `.live`。
    func testSplashPrefersTheCurrentBatchOverTheLifetimeRatio() {
        let status = EngineStatusParser.parse(engine: .splash, status: [
            "metrics": [
                "prefill_tokens_per_second": 3_400.0,
                "decode_tokens_per_second": 52.0,
                "current_prefill_batch": ["valid": true, "input_tokens": 512,
                                          "wall_ms": 150.0, "tokens_per_second": 512.0],
                "current_decode_batch": ["valid": true, "output_tokens": 24,
                                         "wall_ms": 400.0, "tokens_per_second": 60.0],
            ],
            "active_requests": [["id": 1, "phase": "prefill"], ["id": 2, "phase": "decode"]],
            "instance": ["model": "Qwen3.8-27B-DFlash2"],
        ], health: nil)

        XCTAssertEqual(status.prefillTokensPerSecond, 512)
        XCTAssertEqual(status.prefillRateKind, .live)
        XCTAssertEqual(status.decodeTokensPerSecond, 60)
        XCTAssertEqual(status.decodeRateKind, .live)
    }

    /// `current_*_batch` 是「最近一个完成的批次」，空闲时它一直停在那儿。
    /// 这时不能说它是当前速度——那是上一请求的终值，必须标 `LAST`。
    func testSplashIdleBatchIsMarkedAsLastRequest() {
        let status = EngineStatusParser.parse(engine: .splash, status: [
            "metrics": [
                "current_prefill_batch": ["valid": true, "tokens_per_second": 512.0],
                "current_decode_batch": ["valid": true, "tokens_per_second": 60.0],
            ],
            "active_requests": [],
        ], health: nil)

        XCTAssertEqual(status.prefillTokensPerSecond, 512)
        XCTAssertEqual(status.prefillRateKind, .lastRequest)
        XCTAssertEqual(status.decodeRateKind, .lastRequest)
    }

    /// 引擎刚启动、还没跑过预填充时 `valid` 是 false：这时不能报 0 当成速度，
    /// 必须退回到均值口径（并如实标成均值）。
    func testSplashInvalidBatchFallsBackToTheLifetimeRatio() {
        let status = EngineStatusParser.parse(engine: .splash, status: [
            "metrics": [
                "prefill_tokens_per_second": 410.0,
                "current_prefill_batch": ["valid": false, "tokens_per_second": 0.0],
            ],
        ], health: nil)

        XCTAssertEqual(status.prefillTokensPerSecond, 410)
        XCTAssertEqual(status.prefillRateKind, .lifetimeMean)
    }

    func testSplashActiveRequestsCountsBusySlots() {
        let status = EngineStatusParser.parse(engine: .splash, status: [
            "active_requests": [["id": 1], ["id": 2]],
        ], health: nil)
        XCTAssertEqual(status.activeRequests, 2)
    }

    // MARK: mlx-serve

    func testMLXServeMergesInventoryMetricsAndProps() {
        let inventory = EngineTelemetrySource(role: .inventory, path: "/v1/models", format: .openAIModels)
        let metrics = EngineTelemetrySource(role: .metrics, path: "/metrics.json", format: .prometheusJSON)
        let props = EngineTelemetrySource(role: .props, path: "/props", format: .llamaProps)
        let status = EngineStatusParser.parse(documents: [
            EngineTelemetryDocument(source: inventory, json: [
                "data": [
                    ["id": "org/chat", "loaded": true, "state": "ready",
                     "capabilities": ["chat", "streaming"], "context_length": 131_072],
                    ["id": "org/image", "loaded": false, "capabilities": ["image"]],
                ],
            ]),
            EngineTelemetryDocument(source: metrics, json: [
                "counters": ["requests_success_total": 7, "requests_failed_total": 2],
                "gauges": ["requests_running": 1, "requests_waiting": 3,
                           "mlx_active_bytes": 4_194_304],
                "histograms": ["time_to_first_token_seconds": ["count": 2, "sum": 0.4]],
            ]),
            EngineTelemetryDocument(source: props, json: [
                "memory": ["active_bytes": 8_388_608, "peak_bytes": 12_582_912,
                           "max_safe_context": 65_536],
            ]),
        ])

        XCTAssertEqual(status.model, "org/chat")
        XCTAssertEqual(status.loadedModels, ["org/chat"])
        XCTAssertEqual(status.maximumContextTokens, 131_072)
        XCTAssertEqual(status.activeRequests, 1)
        XCTAssertEqual(status.queuedRequests, 3)
        XCTAssertEqual(status.requestsCompleted, 7)
        XCTAssertEqual(status.requestsFailed, 2)
        XCTAssertEqual(status.ttftMilliseconds ?? 0, 200, accuracy: 0.001)
    }

    /// 速率相关的原始计数必须原样带出来：解析器不差分，但轮询侧要有东西可差。
    func testMLXServeMetricsExposeCountersForLiveRates() {
        let metrics = EngineTelemetrySource(role: .metrics, path: "/metrics.json", format: .prometheusJSON)
        let status = EngineStatusParser.parse(documents: [
            EngineTelemetryDocument(source: metrics, json: [
                "counters": ["prefill_tokens_total": 88_000,
                             "prompt_tokens_total": 16_100_000,
                             "prefix_cache_tokens_total": 16_000_000],
                "gauges": ["requests_running": 1,
                           "generation_tokens_live": 36_000,
                           "prefill_tokens_live": 0,
                           "requests_prefilling": 0],
                "histograms": ["prefill_time_seconds": ["count": 214, "sum": 66.5]],
            ]),
        ])
        XCTAssertEqual(status.extras[EngineRateCounters.decodeLive], 36_000)
        XCTAssertEqual(status.extras[EngineRateCounters.prefillLive], 0)
        XCTAssertEqual(status.extras[EngineRateCounters.prefillTokens], 88_000)
        XCTAssertEqual(status.extras[EngineRateCounters.prefillSeconds], 66.5)
        XCTAssertEqual(status.extras["total_cached_tokens"], 16_000_000)
        // 命中率的分母：与命中量同一代的提示词总量。
        XCTAssertEqual(status.extras["prompt_tokens_total"], 16_100_000)
        // 解析器本身不报速率，粒度也就无从谈起；由轮询侧差分后标成 `.live`。
        XCTAssertNil(status.decodeTokensPerSecond)
        XCTAssertEqual(status.decodeRateKind, .none)
    }

    /// 进程级累计吞吐：两个计数器之比。它不是「此刻多快」（那是 `.live`），
    /// 但网关一个样本都没有时（客户端直连引擎、或全是非流式请求），hero 与
    /// 预填充格靠它至少还能说出一句真话，而不是一律画「—」。
    func testMLXServeLifetimeRatiosFillDecodeAndPrefillMeans() {
        let metrics = EngineTelemetrySource(role: .metrics, path: "/metrics.json", format: .prometheusJSON)
        let status = EngineStatusParser.parse(documents: [
            EngineTelemetryDocument(source: metrics, json: [
                "counters": ["prefill_tokens_total": 3_318.0,
                             "generation_tokens_total": 180.0],
                "histograms": ["prefill_time_seconds": ["count": 6, "sum": 2.0],
                               "decode_time_seconds": ["count": 6, "sum": 2.4]],
            ]),
        ])

        XCTAssertEqual(status.decodeTokensPerSecond ?? 0, 75, accuracy: 0.001)
        XCTAssertEqual(status.decodeRateKind, .lifetimeMean)
        XCTAssertEqual(status.prefillTokensPerSecond ?? 0, 1_659, accuracy: 0.001)
        XCTAssertEqual(status.prefillRateKind, .lifetimeMean)
    }

    /// 计数器还是 0（刚开机）时不能报 0 当速度：那会让界面把「还没样本」
    /// 画成一个真实的零吞吐。
    func testMLXServeEmptyCountersReportNoRate() {
        let status = EngineStatusParser.prometheusJSON([
            "counters": ["prefill_tokens_total": 0, "generation_tokens_total": 0],
            "histograms": ["prefill_time_seconds": ["count": 0, "sum": 0],
                           "decode_time_seconds": ["count": 0, "sum": 0]],
        ])
        XCTAssertNil(status.decodeTokensPerSecond)
        XCTAssertNil(status.prefillTokensPerSecond)
        XCTAssertEqual(status.decodeRateKind, .none)
        XCTAssertEqual(status.prefillRateKind, .none)
    }

    // MARK: Strata

    /// MTPLX 的 `latest.prefill_tok_s` 只在请求结束时落一次，空闲时会原样重复
    /// 上一请求的终值——那正是「一个恒定不变的几千」的来历，所以它只能是
    /// `.lastRequest`，不能当当前速度。
    func testMTPLXLatestPrefillIsMarkedAsLastRequest() {
        let status = EngineStatusParser.mtplx(snapshot: [
            "latest": ["prefill_tok_s": 3_400.0, "decode_tok_s": 40.0],
            "rolling": ["mean": 38.0],
        ])
        XCTAssertEqual(status.prefillTokensPerSecond, 3_400)
        XCTAssertEqual(status.prefillRateKind, .lastRequest)
        XCTAssertEqual(status.decodeRateKind, .live)
    }

    /// `prefill_rates` 里的 `peak_tok_s` 是**单 chunk 峰值**，绝不能当读数用
    /// （那正是「恒定不变的大数字」的直接来源）；同一处还有 tokens/compute_time_s
    /// 这个滚动均值，才是合理的兜底。
    func testMTPLXUsesWindowedRateNotPeak() {
        let status = EngineStatusParser.mtplx(snapshot: [
            "prefill_rates": ["tokens": 96_000, "compute_time_s": 40.0,
                              "peak_tok_s": 8_500.0, "samples": 12],
        ])
        // 96000 / 40 = 2400，不是峰值 8500。
        XCTAssertEqual(status.prefillTokensPerSecond ?? 0, 2_400, accuracy: 0.001)
        XCTAssertEqual(status.prefillRateKind, .lifetimeMean)
        XCTAssertEqual(status.extras["prefill_peak_tps"], 8_500)
    }

    /// 正在预填充时，实时值在 `in_flight[].prefill_state`，服务端每完成一个
    /// chunk 就刷新一次。这条路径必须优先于 `latest`。
    func testMTPLXPrefersTheInFlightPrefillRate() {
        let status = EngineStatusParser.mtplx(snapshot: [
            "latest": ["prefill_tok_s": 3_400.0, "decode_tok_s": 40.0],
            "in_flight": [[
                "request_id": "r1",
                "prefill_state": ["phase": "chunk", "tokens_done": 4_096,
                                  "tokens_total": 32_768, "elapsed_s": 2.0,
                                  "prefill_tok_s": 2_048.0],
            ]],
        ])
        XCTAssertEqual(status.prefillTokensPerSecond, 2_048)
        XCTAssertEqual(status.prefillRateKind, .live)
    }

    /// 多路并发预填充时取 `elapsed_s` 最大的那一路（MTPLX 自己的仪表盘
    /// `usePrimaryActivePrefill` 也是这么选的），不是简单相加。
    func testMTPLXPicksTheLongestRunningPrefill() {
        let status = EngineStatusParser.mtplx(snapshot: [
            "in_flight": [
                ["request_id": "short",
                 "prefill_state": ["phase": "chunk", "tokens_done": 100,
                                   "elapsed_s": 0.2, "prefill_tok_s": 500.0]],
                ["request_id": "long",
                 "prefill_state": ["phase": "chunk", "tokens_done": 4_000,
                                   "elapsed_s": 1.0, "prefill_tok_s": 4_000.0]],
            ],
        ])
        XCTAssertEqual(status.prefillTokensPerSecond, 4_000)
        XCTAssertEqual(status.prefillRateKind, .live)
    }

    /// 多端点折叠时，速率与粒度必须成对替换：一个后来端点的累计均值不能
    /// 覆盖前面已经拿到的实时值——否则会出现「数值是均值、角标却写 LIVE」，
    /// 或反过来让均值冒充实时。
    func testMergeDoesNotLetALaterMeanOverwriteALiveRate() {
        let metrics = EngineTelemetrySource(role: .metrics, path: "/live", format: .strataMetrics)
        let props = EngineTelemetrySource(role: .props, path: "/props", format: .llamaProps)
        let status = EngineStatusParser.parse(documents: [
            EngineTelemetryDocument(source: metrics,
                                    json: ["live": ["tok_s": 42.0, "prefill_tok_s_mean": 640.0]]),
            // props 排在后（rank 3），带一个累计均值：数值更强但粒度更弱。
            EngineTelemetryDocument(source: props,
                                    json: ["timings": ["predicted_per_second": 31.0,
                                                       "prompt_per_second": 200.0]]),
        ])
        // .live(3) 不被 .lastRequest(2) 覆盖。
        XCTAssertEqual(status.decodeTokensPerSecond, 42.0)
        XCTAssertEqual(status.decodeRateKind, .live)
        XCTAssertEqual(status.prefillTokensPerSecond, 640.0)
        XCTAssertEqual(status.prefillRateKind, .live)
    }

    /// oMLX 只有进程累计均值（`_build_snapshot` 拿两个累计量相除），
    /// 请求之间不会动，所以只能是 `.lifetimeMean`。
    func testOMLXPrefillIsALifetimeMean() {
        let status = EngineStatusParser.omlx(status: [
            "avg_prefill_tps": 1_800.0,
            "avg_generation_tps": 44.0,
            "total_requests": 9,
        ])
        XCTAssertEqual(status.prefillRateKind, .lifetimeMean)
        XCTAssertEqual(status.decodeRateKind, .lifetimeMean)
    }

    func testStrataMetricsMapLiveAndTotals() {
        let status = EngineStatusParser.strataMetrics([
            "engine": ["model": "strata-qwen", "max_context": 32_768],
            "live": ["state": "generating", "tok_s": 41.5,
                     "prefill_tok_s_mean": 640, "running": 1, "queued": 2, "waiting": 1],
            "totals": ["requests": 9, "output_tokens": 500, "decode_ms": 10_000],
            "requests": [["decode_tok_s": 50]],
        ])
        XCTAssertEqual(status.model, "strata-qwen")
        XCTAssertEqual(status.maximumContextTokens, 32_768)
        XCTAssertEqual(status.decodeTokensPerSecond, 41.5)
        XCTAssertEqual(status.prefillTokensPerSecond, 640)
        XCTAssertEqual(status.decodeRateKind, .live)
        XCTAssertEqual(status.prefillRateKind, .live)
        XCTAssertEqual(status.activeRequests, 1)
        XCTAssertEqual(status.queuedRequests, 3)
        XCTAssertEqual(status.requestsCompleted, 9)
    }
}
