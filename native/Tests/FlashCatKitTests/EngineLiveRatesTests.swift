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
        XCTAssertEqual(reading.decode ?? 0, 50, accuracy: 0.001)
    }

    func testDecodeIsNilWhenNothingIsRunning() {
        var meter = EngineLiveRates()
        _ = meter.observe(status(decode: 1_000, running: 0), at: epoch)
        let reading = meter.observe(status(decode: 1_400, running: 0), at: epoch.addingTimeInterval(1))
        // 计数器涨了但引擎说没有在跑的请求（可能是收尾的那一格），不能报速度。
        XCTAssertNil(reading.decode)
    }

    func testDecodeIgnoresBackwardsCounters() {
        var meter = EngineLiveRates()
        _ = meter.observe(status(decode: 9_000), at: epoch)
        let reading = meter.observe(status(decode: 20), at: epoch.addingTimeInterval(1))
        XCTAssertNil(reading.decode)
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
        XCTAssertEqual(reading.prefill ?? 0, 1_500, accuracy: 0.001)
    }

    func testPrefillKeepsTheLastMeasurementWhenIdle() {
        var meter = EngineLiveRates()
        _ = meter.observe(status(prefillTokens: 100, prefillSeconds: 1.0), at: epoch)
        let reading = meter.observe(status(prefillTokens: 400, prefillSeconds: 1.2),
                                    at: epoch.addingTimeInterval(1))
        XCTAssertEqual(reading.prefill ?? 0, 1_500, accuracy: 0.001)
        // 请求结束后计数器不再变化：卡片仍应显示刚才那次实测，而不是「—」。
        let idle = meter.observe(status(prefillTokens: 400, prefillSeconds: 1.2, running: 0),
                                 at: epoch.addingTimeInterval(9))
        XCTAssertEqual(idle.prefill ?? 0, 1_500, accuracy: 0.001)
    }

    func testPrefillLiveGaugeTracksInFlightRequest() {
        var meter = EngineLiveRates()
        _ = meter.observe(status(prefillLive: 1_000, prefilling: 1), at: epoch)
        let reading = meter.observe(status(prefillLive: 3_000, prefilling: 1),
                                    at: epoch.addingTimeInterval(1))
        XCTAssertEqual(reading.prefill ?? 0, 2_000, accuracy: 0.001)
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
        XCTAssertNil(restarted.prefill)
        XCTAssertNil(restarted.decode)
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
