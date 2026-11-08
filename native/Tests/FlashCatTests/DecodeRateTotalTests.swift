import XCTest
import FlashCatKit
@testable import FlashCat

/// 概览「总解码」的取数口径。
///
/// 速度类指标统一走网关按请求打点：应用内对话也注册在 `GatewayMeter` 里，
/// 所以 hero、曲线与「最近请求」同一份数据。引擎的 LAST / AVG 不是当前速度，
/// 不能拿来补位；引擎实时计数只在网关没有会话时兜底，而且要求引擎确实有
/// 在跑请求。
final class DecodeRateTotalTests: XCTestCase {
    func testGatewayAggregateWinsOverEngineLive() {
        // 两路并发时引擎的“实时”可能只是最近一个批次；网关的按请求之和
        // 才是当前合计，也才能和「最近请求」每一行对上。
        XCTAssertEqual(AppState.totalDecodeRate(gateway: 81.6,
                                                engine: 44.1,
                                                engineKind: .live,
                                                activeRequests: 2),
                       81.6, accuracy: 0.001)
        XCTAssertEqual(AppState.speedOrigin(gateway: 81.6,
                                            engine: 44.1,
                                            engineKind: .live,
                                            activeRequests: 2),
                       .gatewayLive)
    }

    /// 请求结束后网关保留的终值不是当前速度，界面要按 LAST 标。
    func testGatewayFinishedTailIsMarkedLast() {
        XCTAssertEqual(AppState.totalDecodeRate(gateway: 44.1,
                                                gatewayIsLive: false,
                                                engine: nil,
                                                engineKind: .none,
                                                activeRequests: 0),
                       44.1, accuracy: 0.001)
        XCTAssertEqual(AppState.speedOrigin(gateway: 44.1,
                                            gatewayIsLive: false,
                                            engine: nil,
                                            engineKind: .none,
                                            activeRequests: 0),
                       .gatewayLast)
    }

    /// 客户端直连引擎端口时网关看不见，才轮到引擎的实时计数。
    func testEngineLiveIsFallbackWhenGatewayHasNothing() {
        XCTAssertEqual(AppState.totalDecodeRate(gateway: 0,
                                                engine: 44.1,
                                                engineKind: .live,
                                                activeRequests: 1),
                       44.1, accuracy: 0.001)
        XCTAssertEqual(AppState.speedOrigin(gateway: 0,
                                            engine: 44.1,
                                            engineKind: .live,
                                            activeRequests: 1),
                       .engineLive)
    }

    /// 引擎空闲时可能继续回报最后一格（MTPLX 的 rolling.mean 就是典型），
    /// 没有在跑请求就不能把它当当前速度。
    func testEngineLiveNeedsRunningRequests() {
        XCTAssertEqual(AppState.totalDecodeRate(gateway: 0,
                                                engine: 44.1,
                                                engineKind: .live,
                                                activeRequests: 0),
                       0)
        XCTAssertEqual(AppState.speedOrigin(gateway: 0,
                                            engine: 44.1,
                                            engineKind: .live,
                                            activeRequests: 0),
                       .none)
    }

    /// oMLX 的累计均值、splash 空闲时的上一批次终值都不是当前速度。
    func testEngineLastAndLifetimeMeanAreNotCurrentSpeed() {
        for kind in [EngineRateKind.lastRequest, .lifetimeMean] {
            XCTAssertEqual(AppState.totalDecodeRate(gateway: 0,
                                                    engine: 44.1,
                                                    engineKind: kind,
                                                    activeRequests: 1),
                           0)
            XCTAssertEqual(AppState.speedOrigin(gateway: 0,
                                                engine: 44.1,
                                                engineKind: kind,
                                                activeRequests: 1),
                           .none)
        }
    }

    func testIdleReadsZero() {
        XCTAssertEqual(AppState.totalDecodeRate(gateway: 0,
                                                engine: nil,
                                                engineKind: .none,
                                                activeRequests: 0),
                       0)
        XCTAssertEqual(AppState.speedOrigin(gateway: 0,
                                            engine: nil,
                                            engineKind: .none,
                                            activeRequests: 0),
                       .none)
    }
}
