import XCTest
@testable import FlashCatKit

/// 引擎累计计数器 → 实时速率的换算。
///
/// 这些用例钉住的正是线上看到的两类错数：
/// - 同一会话的第二轮请求几乎全命中前缀缓存，按「整段提示词 / 首字耗时」
///   算出来的预填充会被放大两个数量级；
/// - 引擎明明在解码，概览却显示 0 tok/s（只统计了网关看得见的请求）。
final class EngineLiveRatesTests: XCTestCase {
    private let epoch = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func status(decode: Double = 1_000,
                        prefillLive: Double = 0,
                        prefillTokens: Double = 0,
                        prefillSeconds: Double = 0,
                        running: Int = 1,
                        prefilling: Int = 0) -> EngineStatus {
        EngineStatus(state: .ready,
                     activeRequests: running,
                     extras: [
                        EngineRateCounters.decodeLive: decode,
                        EngineRateCounters.prefillLive: prefillLive,
                        EngineRateCounters.prefillTokens: prefillTokens,
                        EngineRateCounters.prefillSeconds: prefillSeconds,
                        EngineRateCounters.prefilling: Double(prefilling),
                     ])
    }

    // MARK: 解码

    func testDecodeRateIsTheGaugeDelta() {
        var meter = EngineLiveRates()
        _ = meter.observe(status(decode: 1_000), at: epoch)
        let reading = meter.observe(status(decode: 1_050), at: epoch.addingTimeInterval(1))
        XCTAssertEqual(reading.decode.value ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(reading.decode.kind, .live)
    }

    func testDecodeIsNilWhenNothingIsRunning() {
        var meter = EngineLiveRates()
        _ = meter.observe(status(decode: 1_000, running: 0), at: epoch)
        let reading = meter.observe(status(decode: 1_400, running: 0), at: epoch.addingTimeInterval(1))
        // 计数器涨了但引擎说没有在跑的请求（可能是收尾的那一格），不能报速度。
        XCTAssertNil(reading.decode.value)
    }

    func testDecodeIgnoresBackwardsCounters() {
        var meter = EngineLiveRates()
        _ = meter.observe(status(decode: 9_000), at: epoch)
        let reading = meter.observe(status(decode: 20), at: epoch.addingTimeInterval(1))
        XCTAssertNil(reading.decode.value)
    }

    // MARK: 预填充

    /// 预填充的分子只能取「真正前向过」的 token。`prompt_tokens_total` 再大
    /// 也不该进这个算式——那正是同会话第二轮虚高的来源。
    func testPrefillUsesForwardedTokensNotWholePrompt() {
        var meter = EngineLiveRates()
        var first = status(prefillTokens: 100, prefillSeconds: 1.0)
        first.extras["prompt_tokens_total"] = 108_000
        _ = meter.observe(first, at: epoch)
        var second = status(prefillTokens: 400, prefillSeconds: 1.2)
        second.extras["prompt_tokens_total"] = 216_000
        let reading = meter.observe(second, at: epoch.addingTimeInterval(1))
        // 300 个真正前向的 token / 0.2 秒预填充耗时 = 1500 tok/s。
        XCTAssertEqual(reading.prefill.value ?? 0, 1_500, accuracy: 0.001)
        // 这一格描述的是「刚做完的那一次」，已经不是当前速度。
        XCTAssertEqual(reading.prefill.kind, .lastRequest)
    }

    /// 请求做完后计数器不再变化：读数要留着（否则卡片空成「—」），但粒度必须
    /// 降成 `.lastRequest`。旧实现把它当 `.live` 一直贴在空闲格上——概览页那个
    /// 恒定不变的几千 tok/s 就是这么来的。
    func testIdlePrefillKeepsTheValueButDemotesItToLastRequest() {
        var meter = EngineLiveRates()
        _ = meter.observe(status(prefillTokens: 100, prefillSeconds: 1.0), at: epoch)
        let reading = meter.observe(status(prefillTokens: 400, prefillSeconds: 1.2),
                                    at: epoch.addingTimeInterval(1))
        XCTAssertEqual(reading.prefill.value ?? 0, 1_500, accuracy: 0.001)
        XCTAssertEqual(reading.prefill.kind, .lastRequest)

        let idle = meter.observe(status(prefillTokens: 400, prefillSeconds: 1.2, running: 0),
                                 at: epoch.addingTimeInterval(9))
        XCTAssertEqual(idle.prefill.value ?? 0, 1_500, accuracy: 0.001)
        XCTAssertEqual(idle.prefill.kind, .lastRequest)
        XCTAssertFalse(idle.prefill.isLive)
    }

    /// chunk 边界之间再轮询（gauge 没动）时，读数必须**保持**上一次的
    /// 窗口速度，而不是像「累计 ÷ 已用时」那样随时间自己往下滑。
    func testPrefillHoldsTheChunkRateBetweenChunkUpdates() {
        var meter = EngineLiveRates()
        _ = meter.observe(status(prefillTokens: 100, prefillSeconds: 1.0), at: epoch)
        _ = meter.observe(status(prefillTokens: 400, prefillSeconds: 1.2),
                          at: epoch.addingTimeInterval(1))

        // t+2：预填充开始（gauge 为 0），起点只记下来，不出数。
        let first = meter.observe(status(prefillLive: 0, prefillTokens: 400,
                                         prefillSeconds: 1.2, prefilling: 1),
                                  at: epoch.addingTimeInterval(2))
        XCTAssertNotEqual(first.prefill.kind, .live)

        // 第一个 chunk 完成：8000 token / 1 秒。
        let second = meter.observe(status(prefillLive: 8_000, prefillTokens: 400,
                                          prefillSeconds: 1.2, prefilling: 1),
                                   at: epoch.addingTimeInterval(3))
        XCTAssertEqual(second.prefill.kind, .live)
        XCTAssertEqual(second.prefill.value ?? 0, 8_000, accuracy: 0.001)

        // 同一 chunk 内再轮询（gauge 没动）：仍是 LIVE，数值不衰减。
        let sameChunk = meter.observe(status(prefillLive: 8_000, prefillTokens: 400,
                                             prefillSeconds: 1.2, prefilling: 1),
                                      at: epoch.addingTimeInterval(3.6))
        XCTAssertEqual(sameChunk.prefill.kind, .live)
        XCTAssertEqual(sameChunk.prefill.value ?? 0, 8_000, accuracy: 0.001)

        // 下一个 chunk 做完：8000 → 16000 用 1 秒，窗口仍是 8000。
        let next = meter.observe(status(prefillLive: 16_000, prefillTokens: 400,
                                        prefillSeconds: 1.2, prefilling: 1),
                                 at: epoch.addingTimeInterval(4))
        XCTAssertEqual(next.prefill.value ?? 0, 8_000, accuracy: 0.001)

        // 预填充结束（prefilling 归 0）：实时值作废，回到闩锁的 LAST。
        let done = meter.observe(status(prefillTokens: 400, prefillSeconds: 1.2),
                                 at: epoch.addingTimeInterval(5))
        XCTAssertEqual(done.prefill.kind, .lastRequest)
    }

    /// 窗口要忘掉请求开头那段慢 chunk：读数跟着最近的 chunk 走，而不是
    /// 「整轮请求从开始到现在的平均」。
    func testPrefillWindowForgetsTheSlowStart() {
        var meter = EngineLiveRates()
        // t+1 开始；t+3 才前向 1000 token（很慢的一段）。
        _ = meter.observe(status(prefillLive: 0, prefilling: 1), at: epoch.addingTimeInterval(1))
        let slow = meter.observe(status(prefillLive: 1_000, prefilling: 1),
                                 at: epoch.addingTimeInterval(3))
        XCTAssertEqual(slow.prefill.value ?? 0, 500, accuracy: 0.001)

        // 之后连续两个快 chunk：1000 → 5000（1 秒）→ 9000（1 秒）。
        let warm = meter.observe(status(prefillLive: 5_000, prefilling: 1),
                                 at: epoch.addingTimeInterval(4))
        XCTAssertEqual(warm.prefill.value ?? 0, 4_000, accuracy: 0.001)
        let fast = meter.observe(status(prefillLive: 9_000, prefilling: 1),
                                 at: epoch.addingTimeInterval(5))
        // 旧窗口 [0, 1000] 已经滑出；最近两秒是 1000 → 9000，即 4000 tok/s。
        // 若按整轮累计，这里会是 9000 / 4 = 2250。
        XCTAssertEqual(fast.prefill.value ?? 0, 4_000, accuracy: 0.001)
        XCTAssertGreaterThan(fast.prefill.value ?? 0, 2_250)
    }

    /// 同一个预填充位上换了新请求（gauge 归零重来，`requests_prefilling`
    /// 一直是 1）：旧窗口必须丢掉，不能拿上一轮的 token 差当速度。
    func testNewRequestResetsThePrefillWindow() {
        var meter = EngineLiveRates()
        _ = meter.observe(status(prefillLive: 1_000, prefilling: 1), at: epoch)
        _ = meter.observe(status(prefillLive: 9_000, prefilling: 1),
                          at: epoch.addingTimeInterval(1))
        // 新请求从 500 开始：不给数（窗口里只有一个点）。
        let reset = meter.observe(status(prefillLive: 500, prefilling: 1),
                                  at: epoch.addingTimeInterval(2))
        XCTAssertNotEqual(reset.prefill.kind, .live)
        // 新请求第一个 chunk：500 → 1500，正好 1000 tok/s。
        let reading = meter.observe(status(prefillLive: 1_500, prefilling: 1),
                                    at: epoch.addingTimeInterval(3))
        XCTAssertEqual(reading.prefill.value ?? 0, 1_000, accuracy: 0.001)
        XCTAssertEqual(reading.prefill.kind, .live)
    }

    /// 真有一路在预填充时（`prefill_tokens_live` 在涨），必须报 `.live`。
    func testInFlightPrefillOutranksTheLatchedValue() {
        var meter = EngineLiveRates()
        _ = meter.observe(status(prefillTokens: 100, prefillSeconds: 1.0), at: epoch)
        _ = meter.observe(status(prefillTokens: 400, prefillSeconds: 1.2),
                          at: epoch.addingTimeInterval(1))
        _ = meter.observe(status(prefillLive: 600, prefillTokens: 400,
                                 prefillSeconds: 1.2, prefilling: 1),
                          at: epoch.addingTimeInterval(2))
        let reading = meter.observe(status(prefillLive: 1_600, prefillTokens: 400,
                                           prefillSeconds: 1.2, prefilling: 1),
                                    at: epoch.addingTimeInterval(3))
        // 600 → 1600，1 秒；描述的是当前这段，不是从请求开始的累计。
        XCTAssertEqual(reading.prefill.value ?? 0, 1_000, accuracy: 0.001)
        XCTAssertEqual(reading.prefill.kind, .live)
        XCTAssertTrue(reading.prefill.isLive)
    }

    /// `prefill_tokens_live` 是**本请求累计**已前向的 token；窗口只取最近
    /// 两点之间的差值。
    func testPrefillLiveGaugeTracksInFlightRequest() {
        var meter = EngineLiveRates()
        _ = meter.observe(status(prefillLive: 1_000, prefilling: 1), at: epoch)
        let reading = meter.observe(status(prefillLive: 3_000, prefilling: 1),
                                    at: epoch.addingTimeInterval(1))
        XCTAssertEqual(reading.prefill.value ?? 0, 2_000, accuracy: 0.001)
        XCTAssertEqual(reading.prefill.kind, .live)
    }

    /// 引擎重启后计数器归零：不能把「变小」算成负速率，也不能继续显示重启前
    /// 的预填充值。
    func testRestartedCountersClearTheOldBaseline() {
        var meter = EngineLiveRates()
        _ = meter.observe(status(prefillTokens: 5_000, prefillSeconds: 5.0), at: epoch)
        _ = meter.observe(status(prefillTokens: 5_500, prefillSeconds: 5.5),
                          at: epoch.addingTimeInterval(1))
        let restarted = meter.observe(status(decode: 0, prefillTokens: 0, prefillSeconds: 0, running: 0),
                                      at: epoch.addingTimeInterval(2))
        XCTAssertNil(restarted.prefill.value)
        XCTAssertNil(restarted.decode.value)
    }

    /// 没有这些计数键的引擎（splash / oMLX / MTPLX）不会被这套逻辑改写口径。
    func testEnginesWithoutCountersAreLeftAlone() {
        var meter = EngineLiveRates()
        let plain = EngineStatus(state: .ready, activeRequests: 1)
        XCTAssertEqual(meter.observe(plain, at: epoch), EngineLiveRates.Reading())
        XCTAssertEqual(meter.observe(plain, at: epoch.addingTimeInterval(1)),
                       EngineLiveRates.Reading())
    }
}
