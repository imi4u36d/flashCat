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
}
