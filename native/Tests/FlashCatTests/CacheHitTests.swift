// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCat
@testable import FlashCatCore

/// 概览第四格：缓存命中率的 owner 表与引擎侧单位换算。
///
/// 这一格有两个容易搞错的地方：一是把「没有样本」画成 0%（反之，真的
/// 一次都没命中必须显示 0%）；二是引擎给的是「命中量 / 提示词总量」两个
/// 计数器，而 oMLX 的 `cache_efficiency` 是百分数——混用会差 100 倍。
final class CacheHitTests: XCTestCase {
    // MARK: owner 表

    /// 缓存命中率统一只认网关按代累计；没有网关样本时画「—」，不再回退引擎。
    func testCacheHitUsesGatewayAggregateOnly() {
        let reading = AppState.cacheHitReading(gateway: 0.86, requests: 3)
        XCTAssertEqual(reading.origin, .gatewayMean)
        XCTAssertEqual(reading.value ?? 0, 0.86, accuracy: 0.0001)

        XCTAssertEqual(AppState.cacheHitReading(gateway: 0, requests: 0), .none)
        XCTAssertEqual(AppState.cacheHitReading(gateway: 1.2, requests: 1), .none)
        XCTAssertEqual(AppState.cacheHitReading(gateway: -0.1, requests: 1), .none)
    }

    /// 0% 是合法读数（有样本、一次都没命中）；「没有样本」才画「—」。
    func testZeroIsAReadingAndNoSamplesIsNot() {
        let zero = AppState.cacheHitReading(gateway: 0, requests: 2)
        XCTAssertEqual(zero.origin, .gatewayMean)
        XCTAssertEqual(zero.value, 0)

        XCTAssertEqual(AppState.cacheHitReading(gateway: 0, requests: 0), .none)
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
