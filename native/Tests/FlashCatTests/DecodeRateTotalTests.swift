import XCTest
@testable import FlashCat

/// 概览「总解码」的取数顺序。
///
/// 线上问题：应用内对话正在生成、外部客户端同时经网关跑另一路时，概览顶上的
/// 大数字与「总解码 · 最近 60 秒」标题只显示应用内那一路（37.5），而不是两路
/// 合起来的 81.6。取数顺序必须以网关聚合为准，这里把它钉住。
final class DecodeRateTotalTests: XCTestCase {
    func testAggregateBeatsSingleSessionLiveRate() {
        // 应用内 37.5 + 外部 44.1 = 81.6：直播读数只是其中一路，不能盖住合计。
        XCTAssertEqual(AppState.totalDecodeRate(gateway: 81.6, live: 37.5, engine: 44.1),
                       81.6, accuracy: 0.001)
    }

    func testFallsBackToLiveRateWhenGatewayHasNothing() {
        // 网关没有打点（客户端直接连引擎端口）时，应用内直播读数仍可用。
        XCTAssertEqual(AppState.totalDecodeRate(gateway: 0, live: 37.5, engine: 44.1),
                       37.5, accuracy: 0.001)
    }

    func testFallsBackToEngineReportWhenNothingElseIsLive() {
        XCTAssertEqual(AppState.totalDecodeRate(gateway: 0, live: nil, engine: 44.1),
                       44.1, accuracy: 0.001)
    }

    func testIdleReadsZero() {
        XCTAssertEqual(AppState.totalDecodeRate(gateway: 0, live: nil, engine: nil), 0)
        XCTAssertEqual(AppState.totalDecodeRate(gateway: 0, live: 0, engine: 0), 0)
    }

    /// 引擎的实时计数覆盖所有会话（包括直连引擎端口、网关看不见的 agent
    /// 请求），比网关的按请求聚合更接近「总解码」。以前这种场景会显示 0.00：
    /// 网关没有打点，引擎的 `generation_tokens_live` 又没被解析。
    func testLiveEngineCounterBeatsGatewayEstimate() {
        XCTAssertEqual(AppState.totalDecodeRate(gateway: 44.1, live: nil, engine: 81.6,
                                                engineIsLive: true),
                       81.6, accuracy: 0.001)
    }

    /// 累计均值不算实时：oMLX 的 avg_generation_tps 只在请求结束时跳一格，
    /// 生成过程中它不动，不能让网关的按请求读数让位。
    func testCumulativeEngineReportStillLosesToGateway() {
        XCTAssertEqual(AppState.totalDecodeRate(gateway: 44.1, live: nil, engine: 81.6,
                                                engineIsLive: false),
                       44.1, accuracy: 0.001)
    }
}
