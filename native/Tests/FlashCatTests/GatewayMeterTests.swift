import XCTest
@testable import FlashCat

/// 网关按请求打点的两个易错点：agent 的工具调用算不算生成量、
/// 前缀缓存命中的提示词算不算预填充。
final class GatewayMeterTests: XCTestCase {
    // MARK: 生成量

    func testTextAndReasoningBothCount() {
        XCTAssertEqual(GatewayMeter.generatedText(["content": "abc"]), "abc")
        XCTAssertEqual(GatewayMeter.generatedText(["reasoning_content": "想"]), "想")
        XCTAssertEqual(GatewayMeter.generatedText(["reasoning": "想"]), "想")
        XCTAssertEqual(GatewayMeter.generatedText(["content": "a", "reasoning_content": "b"]), "ab")
    }

    /// agent 的回复大头是工具调用的参数；不数它，会话在概览里永远是 0 tok/s。
    func testToolCallsCountAsGeneratedTokens() {
        let delta: [String: Any] = [
            "tool_calls": [
                ["index": 0,
                 "function": ["name": "read_file", "arguments": #"{"path":"a.swift"}"#]],
            ],
        ]
        let text = GatewayMeter.generatedText(delta)
        XCTAssertTrue(text.contains("read_file"))
        XCTAssertTrue(text.contains("a.swift"))
        XCTAssertGreaterThan(text.count, 0)
    }

    func testEmptyDeltaGeneratesNothing() {
        XCTAssertEqual(GatewayMeter.generatedText([:]), "")
        XCTAssertEqual(GatewayMeter.generatedText(["tool_calls": [[String: Any]]()]), "")
    }

    // MARK: 缓存命中

    func testCachedTokensReadBothDialects() {
        XCTAssertEqual(GatewayMeter.cachedTokens([
            "prompt_tokens_details": ["cached_tokens": 1_024],
        ]), 1_024)
        XCTAssertEqual(GatewayMeter.cachedTokens([
            "input_tokens_details": ["cached_tokens": 2_048],
        ]), 2_048)
        XCTAssertEqual(GatewayMeter.cachedTokens(["prompt_tokens": 10]), 0)
        XCTAssertEqual(GatewayMeter.cachedTokens([
            "prompt_tokens_details": ["cached_tokens": -5],
        ]), 0)
    }

    // MARK: 概览聚合

    /// 在跑会话 → `isLive = true`；收尾瞬间 `isLive = false`，当前速度归零。
    /// 概览不再挂 LAST 终值；已结束会话的全程均值只留在「最近请求」的行与
    /// 累计平均里。
    func testOverviewStopsAtFinishInsteadOfHoldingLast() {
        let meter = GatewayMeter()
        let id = meter.begin(model: "test-model", dialect: "test", promptTokens: 10)
        let start = Date()
        for step in 0..<20 {
            meter.addTokens(id, 5, at: start.addingTimeInterval(Double(step) * 0.02))
        }

        let live = meter.overview(now: start.addingTimeInterval(0.38))
        XCTAssertTrue(live.isLive)
        XCTAssertGreaterThan(live.decodeRate, 0)

        let running = meter.snapshot(now: start.addingTimeInterval(0.38))
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(running[0].state, .decode)
        XCTAssertGreaterThan(running[0].decodeRate, 0)

        meter.finish(id, at: start.addingTimeInterval(0.4))
        // 收尾即停：没有 1.2s 的 LAST 宽限，曲线在同一个采样边界冻结。
        let stopped = meter.overview(now: start.addingTimeInterval(0.4))
        XCTAssertFalse(stopped.isLive)
        XCTAssertEqual(stopped.decodeRate, 0, accuracy: 0.001)

        let finished = meter.snapshot(now: start.addingTimeInterval(0.4))
        XCTAssertEqual(finished[0].state, .done)
        // 行仍保留全程均值，供「最近请求」显示；它不再进 hero / 曲线。
        XCTAssertGreaterThan(finished[0].decodeRate, 0)
    }

    /// 概览在请求结束后要维持最后一次请求的信息：已结束的会话不能按时间
    /// 自动消失，否则「最近请求」会在收尾几秒后一起归零。当前速度归零，
    /// 但列表与累计平均保留。
    func testFinishedRequestSurvivesLongAfterFinish() {
        let meter = GatewayMeter()
        let start = Date()
        let id = meter.begin(model: "last-model", dialect: "test", promptTokens: 10,
                             at: start)
        // 逐片回来才有可测的到达跨度；一行数据也要按真实节奏喂，
        // 单点（0.35 秒下限）不算速度。
        for step in 0..<20 {
            meter.addTokens(id, 6, at: start.addingTimeInterval(Double(step) * 0.1))
        }
        meter.finish(id, at: start.addingTimeInterval(2.0))

        let later = Date().addingTimeInterval(10 * 60)
        let rows = meter.snapshot(limit: 6, now: later)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].state, .done)
        XCTAssertEqual(rows[0].model, "last-model")
        XCTAssertGreaterThan(rows[0].decodeRate, 0)

        let overview = meter.overview(now: later)
        XCTAssertFalse(overview.isLive)
        XCTAssertEqual(overview.decodeRate, 0, accuracy: 0.001)
        XCTAssertGreaterThan(meter.lifetimeAverage() ?? 0, 0)
    }

    /// 累计平均：分子是生成的 token，分母是首 token 到末 token 的解码时长，
    /// 不把 TTFT / 空闲摊进去。请求收尾后仍在，并且新请求会继续累加。
    func testLifetimeAverageAccumulatesDecodeOnly() {
        let meter = GatewayMeter()
        let start = Date()
        let first = meter.begin(model: "m", dialect: "test", promptTokens: 10)
        for step in 0..<100 {
            meter.addTokens(first, 1, at: start.addingTimeInterval(Double(step) * 0.01))
        }
        meter.finish(first, at: start.addingTimeInterval(1.01))

        let average = meter.lifetimeAverage()
        XCTAssertEqual(average ?? 0, 100.0 / 0.99, accuracy: 2.0)

        let second = meter.begin(model: "m", dialect: "test", promptTokens: 10)
        for step in 0..<50 {
            meter.addTokens(second, 1, at: start.addingTimeInterval(2.0 + Double(step) * 0.01))
        }
        let combined = meter.lifetimeAverage()
        // 150 token / (0.99 + 0.49) 秒 ≈ 101.4；落在两段各自的速率之间。
        XCTAssertEqual(combined ?? 0, 150.0 / 1.48, accuracy: 2.0)

        meter.finish(second, at: start.addingTimeInterval(2.5))
        XCTAssertEqual(meter.lifetimeAverage() ?? 0, combined ?? 0, accuracy: 0.001)
        meter.resetLifetime()
        XCTAssertNil(meter.lifetimeAverage())
    }

    /// 历史表里可能躺着多条已完成请求；概览的当前速度不能把整张表相加成
    /// 越来越大的累计值。空闲时当前速度为 0，历史只进累计平均。
    func testIdleOverviewReportsNothingButLifetimeAverageKeepsHistory() {
        let meter = GatewayMeter()
        let start = Date()
        let first = meter.begin(model: "first", dialect: "test", promptTokens: 10, at: start)
        for step in 0..<8 {
            meter.addTokens(first, 10, at: start.addingTimeInterval(Double(step) * 0.1))
        }
        meter.finish(first, at: start.addingTimeInterval(0.7))
        let second = meter.begin(model: "second", dialect: "test", promptTokens: 10,
                                 at: start.addingTimeInterval(0.72))
        for step in 0..<5 {
            meter.addTokens(second, 8, at: start.addingTimeInterval(0.8 + Double(step) * 0.05))
        }
        meter.finish(second, at: start.addingTimeInterval(1.0))

        let now = start.addingTimeInterval(3.0)
        let rows = meter.snapshot(limit: 6, now: now)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last?.model, "second")

        let overview = meter.overview(now: now)
        XCTAssertFalse(overview.isLive)
        XCTAssertEqual(overview.decodeRate, 0, accuracy: 0.001)
        XCTAssertGreaterThan(meter.lifetimeAverage() ?? 0, 0)
    }

    /// 已结束的请求留在列表里时，耗时必须停在收尾时刻，不能跟着挂钟继续涨。
    func testFinishedElapsedStopsAtFinish() {
        let meter = GatewayMeter()
        let id = meter.begin(model: "m", dialect: "test", promptTokens: 10)
        meter.addTokens(id, 20, at: Date())
        meter.finish(id)

        let immediate = meter.snapshot().first?.elapsed ?? 0
        let later = meter.snapshot(now: Date().addingTimeInterval(30)).first?.elapsed ?? 0
        XCTAssertEqual(immediate, later, accuracy: 0.001)
    }

    /// 末帧 usage 只校正总 token，不能回灌速率：否则请求结束时会炸出一个尖峰。
    func testUsageCorrectsTotalsWithoutBackfillingTheRate() {
        let meter = GatewayMeter()
        let id = meter.begin(model: "m", dialect: "test", promptTokens: 10)
        meter.addTokens(id, 20, at: Date())
        let before = meter.overview().decodeRate
        meter.noteUsage(id, promptTokens: 12, completionTokens: 500)
        let after = meter.overview().decodeRate
        XCTAssertEqual(before, after, accuracy: 0.001)
        XCTAssertEqual(meter.snapshot().first?.completionTokens, 500)
    }

    /// 多路并发时概览是各路速率之和，才能和「最近请求」逐行相加对上。
    func testConcurrentSessionsSumTheirRates() {
        let meter = GatewayMeter()
        let a = meter.begin(model: "a", dialect: "test", promptTokens: 10)
        let b = meter.begin(model: "b", dialect: "test", promptTokens: 10)
        let start = Date()
        for step in 0..<20 {
            let at = start.addingTimeInterval(Double(step) * 0.02)
            meter.addTokens(a, 5, at: at)
            meter.addTokens(b, 2, at: at)
        }
        let now = start.addingTimeInterval(0.38)
        let rows = meter.snapshot(now: now)
        let rowSum = rows.map(\.decodeRate).reduce(0, +)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(meter.overview(now: now).decodeRate, rowSum, accuracy: 1)
    }

    /// 成批到达的抗抖回归：40 token 的脉冲每 0.5 秒一发（投机解码批量
    /// 验证、下游背压憋出的脉冲串都长这样）。逐次读数必须在吞吐附近，
    /// 不允许谷—峰交替——旧低通的分片间 18% 衰减 + 加热就是闪烁本体。
    func testBurstyArrivalsStaySteady() {
        let meter = GatewayMeter()
        let id = meter.begin(model: "m", dialect: "test", promptTokens: 10)
        let start = Date()
        for step in 0..<28 {
            meter.addTokens(id, 40, at: start.addingTimeInterval(Double(step) * 0.5))
        }
        var readings: [Double] = []
        var t = 12.0
        while t < 13.4 {
            readings.append(meter.overview(now: start.addingTimeInterval(t)).decodeRate)
            t += 0.4
        }
        let jump = zip(readings, readings.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        XCTAssertLessThan(jump, 15, "相邻快拍跳变 \(jump): \(readings)")
        XCTAssertGreaterThan(readings.first ?? 0, 70)
    }

    /// 收尾后不再有宽限：同一个 `finish` 调用之后 `isLive` 立即为 false，
    /// 冻结窗峰值不会继续冒充当前速度。最后一个分片之前的静默仍算在跑
    /// （请求没收尾），但读数由估计器按保持 / 遗忘段自己落地。
    func testFinishStopsLiveImmediately() {
        let meter = GatewayMeter()
        let id = meter.begin(model: "m", dialect: "test", promptTokens: 10)
        let start = Date()
        for step in 0..<20 {
            meter.addTokens(id, 5, at: start.addingTimeInterval(Double(step) * 0.02))
        }
        let duringSilence = meter.overview(now: start.addingTimeInterval(0.60))
        XCTAssertTrue(duringSilence.isLive)
        XCTAssertGreaterThan(duringSilence.decodeRate, 0)

        meter.finish(id, at: start.addingTimeInterval(0.65))
        XCTAssertFalse(meter.overview(now: start.addingTimeInterval(0.65)).isLive)
        XCTAssertEqual(meter.overview(now: start.addingTimeInterval(0.65)).decodeRate, 0)
    }

    /// role-only 首帧只是「连接建立」，不是首字：mlx-serve 在预填充开始前
    /// 就先发它。把它记成首字会让 TTFT 只有几毫秒，网关的预填充读数被顶到
    /// 上限。首字必须等第一个真的带内容的分片。
    func testRoleOnlyPreambleDoesNotRecordFirstToken() {
        let meter = GatewayMeter()
        let start = Date()
        let id = meter.begin(model: "m", dialect: "openai", promptTokens: 10, at: start)
        meter.ingest(id, chunk: ["choices": [["delta": ["role": "assistant"]]]])
        XCTAssertNil(meter.snapshot().first?.ttftMilliseconds)
        XCTAssertNil(meter.recentTTFTMilliseconds())

        meter.addTokens(id, 2, at: start.addingTimeInterval(1.2))
        XCTAssertEqual(meter.snapshot().first?.ttftMilliseconds ?? 0, 1_200, accuracy: 1)
        XCTAssertEqual(meter.snapshot().first?.completionTokens, 2)
    }

    // MARK: 网关侧的首字

    /// 「最近一次首字」按 firstTokenAt 排，而不是按会话开始的先后：并发时
    /// 先发起的请求可能后拿到首字，它才是更新的那次观测。
    func testRecentTTFTPicksTheLatestFirstToken() {
        let meter = GatewayMeter()
        let start = Date()
        let slow = meter.begin(model: "m", dialect: "test", promptTokens: 10, at: start)
        let quick = meter.begin(model: "m", dialect: "test", promptTokens: 10,
                                at: start.addingTimeInterval(0.1))
        // quick 先拿到首字（100ms），slow 后拿到（400ms）：最新的是 slow。
        meter.addTokens(quick, 2, at: start.addingTimeInterval(0.2))
        XCTAssertEqual(meter.recentTTFTMilliseconds() ?? 0, 100, accuracy: 1)
        meter.addTokens(slow, 2, at: start.addingTimeInterval(0.4))
        XCTAssertEqual(meter.recentTTFTMilliseconds() ?? 0, 400, accuracy: 1)
    }

    /// 非流式响应没有首字时刻：正文一口气回来，网关手里只有一个到达点，
    /// 不能把它当成首字耗时。这种请求不参与读数。
    func testRecentTTFTIgnoresNonStreamingResponses() throws {
        let meter = GatewayMeter()
        let start = Date()
        let id = meter.begin(model: "m", dialect: "test", promptTokens: 1_000, at: start)
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": "hi"]]],
            "usage": ["prompt_tokens": 1_000, "completion_tokens": 2],
        ])
        meter.ingestResponse(id, body: body)
        XCTAssertNil(meter.recentTTFTMilliseconds())
    }

    /// 换引擎 / 换模型 / 引擎重启会翻代：上一台模型的首字不能留在这格，
    /// 新一代重新等样本。会话表本身仍保留给「最近请求」。
    func testRecentTTFTBelongsToTheCurrentEpoch() {
        let meter = GatewayMeter()
        let start = Date()
        let old = meter.begin(model: "previous", dialect: "test", promptTokens: 10, at: start)
        meter.addTokens(old, 2, at: start.addingTimeInterval(0.8))
        meter.finish(old, at: start.addingTimeInterval(1))
        XCTAssertEqual(meter.recentTTFTMilliseconds() ?? 0, 800, accuracy: 1)

        meter.resetLifetime()
        XCTAssertNil(meter.recentTTFTMilliseconds())
        XCTAssertEqual(meter.snapshot().count, 1)

        let fresh = meter.begin(model: "current", dialect: "test", promptTokens: 10,
                                at: start.addingTimeInterval(10))
        meter.addTokens(fresh, 2, at: start.addingTimeInterval(10.3))
        XCTAssertEqual(meter.recentTTFTMilliseconds() ?? 0, 300, accuracy: 1)
    }

    // MARK: 网关侧的预填充

    /// 预填充由网关自己算：分子扣掉前缀缓存命中量，分母是请求发出到首 token。
    /// 引擎不报任何预填充速率字段时，这一格仍然有值。
    func testRecentPrefillIsMeasuredFromRequestTimingAndCache() {
        let meter = GatewayMeter()
        let start = Date()
        let id = meter.begin(model: "m", dialect: "test", promptTokens: 1_200, at: start)
        // role-only 首帧：不算首字，不能把 TTFT 记成 10ms。
        meter.addTokens(id, 0, at: start.addingTimeInterval(0.01))
        XCTAssertNil(meter.recentPrefill())
        meter.addTokens(id, 4, at: start.addingTimeInterval(0.5))
        // usage 还没到：此时没有 cached 信息，不能报一个虚高的数。
        XCTAssertNil(meter.recentPrefill())

        meter.noteUsage(id,
                        promptTokens: 1_200,
                        completionTokens: 4,
                        cachedPromptTokens: 400)
        meter.finish(id, at: start.addingTimeInterval(1.0))
        // (1200 - 400) / 0.5s = 1600 tok/s。
        XCTAssertEqual(meter.recentPrefill() ?? 0, 1_600, accuracy: 0.5)
    }

    /// 应用内对话在引擎启动/加载之前就登记了会话；计时起点必须挪到真正发出
    /// 请求的那一刻，否则冷启动的模型加载时间会被摊进预填充分母。
    func testMarkStartedExcludesEngineStartupFromPrefill() {
        let meter = GatewayMeter()
        let start = Date()
        let id = meter.begin(model: "m", dialect: "test", promptTokens: 1_000, at: start)
        meter.markStarted(id, at: start.addingTimeInterval(10))
        meter.addTokens(id, 4, at: start.addingTimeInterval(10.5))
        meter.noteUsage(id, promptTokens: 1_000, completionTokens: 4)
        meter.finish(id, at: start.addingTimeInterval(11))

        XCTAssertEqual(meter.recentPrefill() ?? 0, 2_000, accuracy: 0.5)
    }

    /// 最新一路全命中缓存（没有前向 token）时不能把整格空掉：继续往前找
    /// 最近一次真的算过的预填充。
    func testRecentPrefillFallsBackPastFullyCachedRequest() {
        let meter = GatewayMeter()
        let start = Date()
        let first = meter.begin(model: "m", dialect: "test", promptTokens: 1_200, at: start)
        meter.addTokens(first, 4, at: start.addingTimeInterval(0.5))
        meter.noteUsage(first, promptTokens: 1_200, completionTokens: 4, cachedPromptTokens: 400)
        meter.finish(first, at: start.addingTimeInterval(1))

        let cached = meter.begin(model: "m", dialect: "test", promptTokens: 1_200,
                                 at: start.addingTimeInterval(2))
        meter.addTokens(cached, 4, at: start.addingTimeInterval(2.01))
        meter.noteUsage(cached, promptTokens: 1_200, completionTokens: 4, cachedPromptTokens: 1_200)
        meter.finish(cached, at: start.addingTimeInterval(2.5))

        XCTAssertEqual(meter.recentPrefill() ?? 0, 1_600, accuracy: 0.5)
    }

    /// 非流式响应拿不到 TTFT：正文回来时预填充和解码都已经结束。这种会话
    /// 不参与预填充读数，免得把整段回答耗时当成首字耗时，报一个偏低的数。
    func testNonStreamResponseDoesNotProducePrefillReading() throws {
        let meter = GatewayMeter()
        let start = Date()
        let id = meter.begin(model: "m", dialect: "test", promptTokens: 1_000, at: start)
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": "hi"]]],
            "usage": ["prompt_tokens": 1_000, "completion_tokens": 2],
        ])
        meter.ingestResponse(id, body: body)
        XCTAssertNil(meter.recentPrefill())
    }

    // MARK: 缓存命中率

    /// 命中率按 token 加权，不是「各请求命中率的平均」：一段 4K 上下文命中
    /// 3.6K，比一条 100 token 的冷请求更能代表缓存效率。
    func testCacheHitIsWeightedByPromptTokens() {
        let meter = GatewayMeter()
        let start = Date()
        let cold = meter.begin(model: "m", dialect: "openai", promptTokens: 100, at: start)
        meter.addTokens(cold, 2, at: start.addingTimeInterval(0.2))
        meter.noteUsage(cold, promptTokens: 100, completionTokens: 2)
        meter.finish(cold, at: start.addingTimeInterval(0.5))

        let warm = meter.begin(model: "m", dialect: "openai", promptTokens: 4_000,
                               at: start.addingTimeInterval(1))
        meter.addTokens(warm, 2, at: start.addingTimeInterval(1.2))
        meter.noteUsage(warm, promptTokens: 4_000, completionTokens: 2,
                        cachedPromptTokens: 3_600)
        meter.finish(warm, at: start.addingTimeInterval(1.5))

        let sample = meter.cacheHit()
        XCTAssertEqual(sample?.requests, 2)
        // (0 + 3_600) / (100 + 4_000)，而不是 (0% + 90%) / 2。
        XCTAssertEqual(sample?.rate ?? 0, 3_600.0 / 4_100.0, accuracy: 0.0001)
    }

    /// 没有 usage 的请求不能进分母：客户端没开 `stream_options.include_usage`
    /// 时没有 `cached_tokens`，把整段上下文当成未命中会让命中率凭客户端配置
    /// 变低。一次 usage 都没有时返回 nil，界面画「—」。
    func testCacheHitIgnoresRequestsWithoutUsage() {
        let meter = GatewayMeter()
        let start = Date()
        let unknown = meter.begin(model: "m", dialect: "openai", promptTokens: 8_000, at: start)
        meter.addTokens(unknown, 4, at: start.addingTimeInterval(0.4))
        meter.finish(unknown, at: start.addingTimeInterval(1))
        XCTAssertNil(meter.cacheHit())

        let known = meter.begin(model: "m", dialect: "openai", promptTokens: 1_000,
                                at: start.addingTimeInterval(2))
        meter.addTokens(known, 2, at: start.addingTimeInterval(2.2))
        meter.noteUsage(known, promptTokens: 1_000, completionTokens: 2,
                        cachedPromptTokens: 900)
        meter.finish(known, at: start.addingTimeInterval(2.5))

        XCTAssertEqual(meter.cacheHit()?.requests, 1)
        XCTAssertEqual(meter.cacheHit()?.rate ?? 0, 0.9, accuracy: 0.0001)
    }

    /// 全冷启动也是合法读数：0% 与「一次都没算过」不是一回事，前者要显示 0。
    func testCacheHitReportsZeroForColdRequests() {
        let meter = GatewayMeter()
        let start = Date()
        let cold = meter.begin(model: "m", dialect: "openai", promptTokens: 1_800, at: start)
        meter.addTokens(cold, 2, at: start.addingTimeInterval(0.3))
        meter.noteUsage(cold, promptTokens: 1_800, completionTokens: 2)
        meter.finish(cold, at: start.addingTimeInterval(0.6))

        XCTAssertEqual(meter.cacheHit()?.requests, 1)
        XCTAssertEqual(meter.cacheHit()?.rate, 0)
    }

    /// 换引擎 / 换模型 / 重启后从零开始：上一台模型的命中率不该挂在新卡片上。
    func testCacheHitBelongsToTheCurrentEpoch() {
        let meter = GatewayMeter()
        let start = Date()
        let old = meter.begin(model: "previous", dialect: "openai", promptTokens: 1_000, at: start)
        meter.noteUsage(old, promptTokens: 1_000, completionTokens: 2, cachedPromptTokens: 900)
        meter.finish(old, at: start.addingTimeInterval(0.5))
        XCTAssertEqual(meter.cacheHit()?.rate ?? 0, 0.9, accuracy: 0.0001)

        meter.resetLifetime()
        XCTAssertNil(meter.cacheHit())
        // 会话表本身仍在：「最近请求」保留上一轮的行，直到被新请求挤出。
        XCTAssertEqual(meter.snapshot().count, 1)
    }

    // MARK: 引擎自报的逐请求耗时（timings）

    /// 非流式响应没有 `timings` 时不能报速度。正文整段回来，网关手里只有一个
    /// 到达点；旧实现拿窗口下限 0.35 秒当分母，14 155 token 的回答被读成
    /// 40 443 tok/s——概览「最近请求」里 37 769 / 12 558 / 11 551 tok/s 那几行
    /// 就是同一条路径，它们和引擎自己记的 44～60 tok/s 差了两个数量级。
    func testBufferedResponseWithoutTimingsReportsNoRate() throws {
        let meter = GatewayMeter()
        let start = Date()
        let id = meter.begin(model: "m", dialect: "openai", promptTokens: 15_774, at: start)
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": String(repeating: "。“", count: 4_718)]]],
            "usage": ["prompt_tokens": 15_774, "completion_tokens": 14_155],
        ])
        meter.ingestResponse(id, body: body)

        XCTAssertEqual(meter.snapshot().first?.decodeRate ?? -1, 0, accuracy: 0.001)
        // 一个可测样本都没有时宁可返回 nil，界面画「—」。
        XCTAssertNil(meter.lifetimeAverage())
    }

    /// mlx-serve 在非流式正文里也带 `timings`：这是「最近请求」与 hero 唯一
    /// 诚实的来源（分子分母都是引擎量的那一段）。预填充的分子扣掉缓存命中量。
    func testEngineTimingsMeasureBufferedRequests() throws {
        let meter = GatewayMeter()
        let start = Date()
        let id = meter.begin(model: "m", dialect: "openai", promptTokens: 15_774, at: start)
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": String(repeating: "。“", count: 4_718)]]],
            "usage": ["prompt_tokens": 15_774, "completion_tokens": 14_155],
            // 取自 mlx-serve 自己的日志：12052+… 一轮 prefill 6152ms、decode 235926ms。
            "timings": ["prompt_n": 15_774, "cached_n": 0, "prompt_ms": 6_152.0,
                        "predicted_n": 14_155, "predicted_ms": 235_926.0],
        ])
        meter.ingestResponse(id, body: body)

        XCTAssertEqual(meter.snapshot().first?.decodeRate ?? 0, 60.0, accuracy: 0.2)
        XCTAssertEqual(meter.recentPrefill() ?? 0, 2_563.9, accuracy: 1)
        XCTAssertEqual(meter.lifetimeAverage() ?? 0, 60.0, accuracy: 0.2)
    }

    /// 流式末片的 `timings` 优先于网关按到达时刻估的窗口：同一路请求，
    /// 引擎量的 50 tok/s 比「20 片摊在 0.5 秒里」的 40 tok/s 更接近真相。
    func testTimingsFromStreamingChunkOverrideArrivalWindow() {
        let meter = GatewayMeter()
        let start = Date()
        let id = meter.begin(model: "m", dialect: "openai", promptTokens: 900, at: start)
        for step in 0..<20 {
            meter.ingest(id, chunk: ["choices": [["delta": ["content": "字"]]]])
            meter.addTokens(id, 1, at: start.addingTimeInterval(Double(step) * 0.025))
        }
        meter.ingest(id, chunk: ["choices": [], "usage": ["prompt_tokens": 900,
                                                          "completion_tokens": 20],
                                  "timings": ["prompt_n": 900, "cached_n": 0,
                                              "prompt_ms": 300.0,
                                              "predicted_n": 100,
                                              "predicted_ms": 2_000.0]])
        meter.finish(id, at: start.addingTimeInterval(1.0))

        XCTAssertEqual(meter.snapshot().first?.decodeRate ?? 0, 50.0, accuracy: 0.1)
        XCTAssertEqual(meter.recentPrefill() ?? 0, 3_000.0, accuracy: 1)
        XCTAssertEqual(meter.lifetimeAverage() ?? 0, 50.0, accuracy: 0.1)
    }

    /// 换引擎 / 换模型 / 引擎重启会开启新一代：上一台模型的预填充读数不该
    /// 挂在新模型卡片上，宁可从「—」重新等一个样本。
    func testPrefillReadingBelongsToTheCurrentEngineEpoch() {
        let meter = GatewayMeter()
        let start = Date()
        let old = meter.begin(model: "previous", dialect: "openai", promptTokens: 2_400, at: start)
        meter.addTokens(old, 4, at: start.addingTimeInterval(1.0))
        meter.noteTimings(old, GatewayMeter.RequestTimings(promptTokens: 2_400,
                                                           cachedTokens: 0,
                                                           promptMilliseconds: 1_000,
                                                           predictedTokens: 40,
                                                           predictedMilliseconds: 800))
        meter.finish(old, at: start.addingTimeInterval(1.2))
        XCTAssertEqual(meter.recentPrefill() ?? 0, 2_400, accuracy: 1)

        meter.resetLifetime()
        XCTAssertNil(meter.recentPrefill())
        // 会话表本身仍在：「最近请求」要保留上一轮的行，直到被新请求挤出。
        XCTAssertEqual(meter.snapshot().count, 1)

        let fresh = meter.begin(model: "current", dialect: "openai", promptTokens: 1_600,
                                at: start.addingTimeInterval(10))
        meter.addTokens(fresh, 4, at: start.addingTimeInterval(10.5))
        meter.noteTimings(fresh, GatewayMeter.RequestTimings(promptTokens: 1_600,
                                                             cachedTokens: 0,
                                                             promptMilliseconds: 800,
                                                             predictedTokens: 30,
                                                             predictedMilliseconds: 400))
        meter.finish(fresh, at: start.addingTimeInterval(11))
        XCTAssertEqual(meter.recentPrefill() ?? 0, 2_000, accuracy: 1)
    }

    /// 命中缓存后只剩几十个 token 的前向：耗时由缓存恢复的固定开销主导，
    /// 报出来的 334 tok/s 既不是算力也不是缓存速度。这种样本不参与读数，
    /// 继续往前找最近一次真的算过的那一轮。
    func testTimingsSkipTinyForwardedSamples() {
        let meter = GatewayMeter()
        let start = Date()
        let cold = meter.begin(model: "m", dialect: "openai", promptTokens: 2_400, at: start)
        meter.addTokens(cold, 4, at: start.addingTimeInterval(1.0))
        meter.noteTimings(cold, GatewayMeter.RequestTimings(promptTokens: 2_400,
                                                           cachedTokens: 0,
                                                           promptMilliseconds: 1_000,
                                                           predictedTokens: 40,
                                                           predictedMilliseconds: 800))
        meter.finish(cold, at: start.addingTimeInterval(1.2))

        let cached = meter.begin(model: "m", dialect: "openai", promptTokens: 2_195,
                                 at: start.addingTimeInterval(5))
        meter.addTokens(cached, 4, at: start.addingTimeInterval(5.2))
        meter.noteTimings(cached, GatewayMeter.RequestTimings(promptTokens: 2_195,
                                                             cachedTokens: 2_164,
                                                             promptMilliseconds: 92.7,
                                                             predictedTokens: 22,
                                                             predictedMilliseconds: 272))
        meter.finish(cached, at: start.addingTimeInterval(5.5))

        XCTAssertEqual(meter.recentPrefill() ?? 0, 2_400.0, accuracy: 1)
    }
}
