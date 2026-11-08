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

    /// 在跑会话 → `isLive = true`；结束后同一批会话降级成 LAST（`isLive = false`），
    /// 概览 hero 和曲线据此打不同的来源角标。
    func testOverviewIsLiveWhileRunningAndLastAfterFinish() {
        let meter = GatewayMeter()
        let id = meter.begin(model: "test-model", dialect: "test", promptTokens: 10)
        meter.addTokens(id, 100, at: Date())

        let live = meter.overview()
        XCTAssertTrue(live.isLive)
        XCTAssertGreaterThan(live.decodeRate, 0)

        let running = meter.snapshot()
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(running[0].state, .decode)
        XCTAssertGreaterThan(running[0].decodeRate, 0)

        meter.finish(id)
        let last = meter.overview()
        XCTAssertFalse(last.isLive)
        XCTAssertGreaterThan(last.decodeRate, 0)

        let finished = meter.snapshot()
        XCTAssertEqual(finished[0].state, .done)
        XCTAssertEqual(finished[0].decodeRate, last.decodeRate, accuracy: 0.001)
    }

    /// 概览在请求结束后要维持最后一次请求的信息：已结束的会话不能按时间
    /// 自动消失，否则 hero 与「最近请求」会在收尾几秒后一起归零。
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
        XCTAssertEqual(overview.decodeRate, rows[0].decodeRate, accuracy: 0.001)
    }

    /// 历史表里可能躺着多条已完成请求；空闲时大数字只能报最近一条的终值，
    /// 不能把整张表相加成越来越大的累计值。
    func testIdleOverviewReportsLatestRequestNotHistorySum() {
        let meter = GatewayMeter()
        let first = meter.begin(model: "first", dialect: "test", promptTokens: 10)
        meter.addTokens(first, 80, at: Date())
        meter.finish(first)
        let second = meter.begin(model: "second", dialect: "test", promptTokens: 10)
        meter.addTokens(second, 40, at: Date())
        meter.finish(second)

        let rows = meter.snapshot(limit: 6)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last?.model, "second")

        let overview = meter.overview()
        XCTAssertEqual(overview.decodeRate, rows.last?.decodeRate ?? 0, accuracy: 0.001)
        XCTAssertLessThan(overview.decodeRate, rows.map(\.decodeRate).reduce(0, +))
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
        let now = Date()
        meter.addTokens(a, 80, at: now)
        meter.addTokens(b, 40, at: now)

        let rows = meter.snapshot()
        let rowSum = rows.map(\.decodeRate).reduce(0, +)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(meter.overview().decodeRate, rowSum, accuracy: 1)
    }
}
