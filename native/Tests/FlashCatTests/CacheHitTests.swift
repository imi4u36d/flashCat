import XCTest
import FlashCatKit
@testable import FlashCat

/// 概览第四格：缓存命中率的 owner 表与引擎侧单位换算。
///
/// 这一格有两个容易搞错的地方：一是把「没有样本」画成 0%（反之，真的
/// 一次都没命中必须显示 0%）；二是引擎给的是「命中量 / 提示词总量」两个
/// 计数器，而 oMLX 的 `cache_efficiency` 是百分数——混用会差 100 倍。
final class CacheHitTests: XCTestCase {
    // MARK: owner 表

    /// 网关按代累计优先；没有网关样本时才退回引擎的开机以来读数。
    func testCacheHitPrefersGatewayAggregate() {
        let reading = AppState.cacheHitReading(gateway: 0.86, requests: 3, engine: 0.4)
        XCTAssertEqual(reading.origin, .gatewayMean)
        XCTAssertEqual(reading.value ?? 0, 0.86, accuracy: 0.0001)

        let fallback = AppState.cacheHitReading(gateway: 0, requests: 0, engine: 0.4)
        XCTAssertEqual(fallback.origin, .engineMean)
        XCTAssertEqual(fallback.value ?? 0, 0.4, accuracy: 0.0001)
    }

    /// 0% 是合法读数（有样本、一次都没命中）；「没有样本」才画「—」。
    func testZeroIsAReadingAndNoSamplesIsNot() {
        let zero = AppState.cacheHitReading(gateway: 0, requests: 2, engine: nil)
        XCTAssertEqual(zero.origin, .gatewayMean)
        XCTAssertEqual(zero.value, 0)

        XCTAssertEqual(AppState.cacheHitReading(gateway: 0, requests: 0, engine: nil), .none)
    }

    /// 两个累计计数器的比值就是命中率；分母为 0（进程刚起、还没有请求）
    /// 时不给读数，界面画「—」而不是 0%。
    func testEngineCountersBecomeARatio() {
        var status = EngineStatus()
        status.extras = ["total_cached_tokens": 12_800, "prompt_tokens_total": 16_000]
        let stats = ServerStats(engineStatus: status, previous: nil)
        XCTAssertEqual(stats.cacheHitRate ?? 0, 0.8, accuracy: 0.0001)

        var idle = EngineStatus()
        idle.extras = ["total_cached_tokens": 0, "prompt_tokens_total": 0]
        XCTAssertNil(ServerStats(engineStatus: idle, previous: nil).cacheHitRate)
        XCTAssertNil(ServerStats(engineStatus: EngineStatus(), previous: nil).cacheHitRate)
    }
}
