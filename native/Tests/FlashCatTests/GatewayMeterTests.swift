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
        let id = meter.begin(model: "last-model", dialect: "test", promptTokens: 10)
        meter.addTokens(id, 120, at: Date())
        meter.finish(id)

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
        let first = meter.begin(model: "first", dialect: "test", promptTokens: 10)
        meter.addTokens(first, 80, at: start)
        meter.finish(first, at: start.addingTimeInterval(0.7))
        let second = meter.begin(model: "second", dialect: "test", promptTokens: 10)
        meter.addTokens(second, 40, at: start.addingTimeInterval(0.72))
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

    /// role-only 首帧不产生文字，但它是「流开始回东西」的第一个证据：
    /// 首字时刻必须在它身上记下，TTFT 才不晚计。旧实现只在文字非空时
    /// 打点，空 delta 被整帧忽略。
    func testRoleOnlyDeltaRecordsFirstToken() {
        let meter = GatewayMeter()
        let id = meter.begin(model: "m", dialect: "openai", promptTokens: 10)
        let at = Date()
        meter.ingest(id, chunk: ["choices": [["delta": ["role": "assistant"]]]])
        // 首字时刻已记下：TTFT 由 snapshot 给出。
        let row = meter.snapshot(now: at.addingTimeInterval(0.2)).first
        XCTAssertEqual(row?.ttftMilliseconds ?? -1, 0, accuracy: 1)
        XCTAssertEqual(row?.completionTokens, 0)
    }
}
