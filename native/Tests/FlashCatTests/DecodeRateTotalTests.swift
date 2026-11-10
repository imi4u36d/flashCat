import XCTest
import FlashCatKit
@testable import FlashCat

/// 指标 owner 表的解码格（hero、灵动岛、菜单栏共用的取数口径）。
///
/// 速度类指标统一走网关按请求打点：应用内对话也注册在 `GatewayMeter` 里，
/// 所以 hero、曲线与「最近请求」同一份数据。引擎的 LAST / AVG 不是当前速度，
/// 不能拿来补位；引擎实时计数只在网关没有会话时兜底，而且要求引擎确实有
/// 在跑请求。`MetricOrigin` 是界面可见口径，`SpeedOrigin` 是它的旧名等价。
final class DecodeRateTotalTests: XCTestCase {
    /// 把 `speedOrigin` + 值折叠成界面口径。`engine` 默认 nil，调用点只写关心的参数。
    private static func origin(gateway: Double,
                               gatewayIsLive: Bool = true,
                               engine: Double? = nil,
                               engineKind: EngineRateKind = .none,
                               activeRequests: Int = 0,
                               gatewayAge: TimeInterval? = nil) -> MetricOrigin {
        let speed = AppState.speedOrigin(gateway: gateway,
                                         gatewayIsLive: gatewayIsLive,
                                         engine: engine,
                                         engineKind: engineKind,
                                         activeRequests: activeRequests,
                                         gatewayAge: gatewayAge)
        return AppState.reading(origin: speed, gateway: gateway, engine: engine).origin
    }

    private static func value(gateway: Double,
                              gatewayIsLive: Bool = true,
                              engine: Double? = nil,
                              engineKind: EngineRateKind = .none,
                              activeRequests: Int = 0,
                              gatewayAge: TimeInterval? = nil) -> Double {
        let speed = AppState.speedOrigin(gateway: gateway,
                                         gatewayIsLive: gatewayIsLive,
                                         engine: engine,
                                         engineKind: engineKind,
                                         activeRequests: activeRequests,
                                         gatewayAge: gatewayAge)
        return AppState.reading(origin: speed, gateway: gateway, engine: engine).value ?? 0
    }

    func testGatewayAggregateWinsOverEngineLive() {
        // 两路并发时引擎的“实时”可能只是最近一个批次；网关的按请求之和
        // 才是当前合计，也才能和「最近请求」每一行对上。
        XCTAssertEqual(Self.value(gateway: 81.6, engine: 44.1, engineKind: .live, activeRequests: 2),
                       81.6, accuracy: 0.001)
        XCTAssertEqual(Self.origin(gateway: 81.6, engine: 44.1, engineKind: .live, activeRequests: 2),
                       .gatewayLive)
    }

    /// 请求结束后网关保留的终值不是当前速度；LAST 采集入口已取消，
    /// 宁可显示「—」也不能把上一请求的值挂成实时读数。
    func testGatewayFinishedTailIsNotCurrentSpeed() {
        XCTAssertEqual(Self.value(gateway: 44.1, gatewayIsLive: false), 0)
        XCTAssertEqual(Self.origin(gateway: 44.1, gatewayIsLive: false), .none)
    }

    /// 客户端直连引擎端口时网关看不见，才轮到引擎的实时计数。
    func testEngineLiveIsFallbackWhenGatewayHasNothing() {
        XCTAssertEqual(Self.value(gateway: 0, engine: 44.1, engineKind: .live, activeRequests: 1),
                       44.1, accuracy: 0.001)
        XCTAssertEqual(Self.origin(gateway: 0, engine: 44.1, engineKind: .live, activeRequests: 1),
                       .engineLive)
    }

    /// 引擎空闲时可能继续回报最后一格（MTPLX 的 rolling.mean 就是典型），
    /// 没有在跑请求就不能把它当当前速度。
    func testEngineLiveNeedsRunningRequests() {
        XCTAssertEqual(Self.value(gateway: 0, engine: 44.1, engineKind: .live), 0)
        XCTAssertEqual(Self.origin(gateway: 0, engine: 44.1, engineKind: .live), .none)
    }

    /// oMLX 的累计均值、splash 空闲时的上一批次终值都不是当前速度。
    func testEngineLastAndLifetimeMeanAreNotCurrentSpeed() {
        for kind in [EngineRateKind.lastRequest, .lifetimeMean] {
            XCTAssertEqual(Self.value(gateway: 0, engine: 44.1, engineKind: kind, activeRequests: 1), 0)
            XCTAssertEqual(Self.origin(gateway: 0, engine: 44.1, engineKind: kind, activeRequests: 1), .none)
        }
    }

    /// 网关读数超过新鲜度门槛（两个 1 秒节拍）就不再冒充「此刻」：过期的
    /// 网关值必须让位给引擎的实时计数。
    func testStaleGatewayReadingFallsBackToEngineLive() {
        XCTAssertEqual(Self.origin(gateway: 44.1, gatewayIsLive: true,
                                   engine: 30, engineKind: .live, activeRequests: 1,
                                   gatewayAge: 0.5),
                       .gatewayLive)
        XCTAssertEqual(Self.origin(gateway: 44.1, gatewayIsLive: true,
                                   engine: 30, engineKind: .live, activeRequests: 1,
                                   gatewayAge: 3.0),
                       .engineLive)
    }

    func testIdleReadsZero() {
        XCTAssertEqual(Self.value(gateway: 0), 0)
        XCTAssertEqual(Self.origin(gateway: 0), .none)
    }

    // MARK: 预填充格

    /// 预填充的 owner 是引擎（网关只有已废弃的 TTFT 口径）：LIVE 与 AVG
    /// 一对一翻译，LAST 不再是一个采集入口——空闲时上一请求的实测值不显示。
    func testPrefillReadingDropsLastButKeepsLiveAndMean() {
        XCTAssertEqual(AppState.prefillReading(engine: 2100, engineKind: .live).origin, .engineLive)
        XCTAssertEqual(AppState.prefillReading(engine: 3400, engineKind: .lastRequest), .none)
        XCTAssertEqual(AppState.prefillReading(engine: 900, engineKind: .lifetimeMean).origin, .engineMean)
        XCTAssertEqual(AppState.prefillReading(engine: 900, engineKind: .none).origin, .none)
        XCTAssertEqual(AppState.prefillReading(engine: 0, engineKind: .live).origin, .none)
        XCTAssertEqual(AppState.prefillReading(engine: nil, engineKind: .live), .none)
    }

    // MARK: 曲线冻结

    /// 进行中不冻结；收尾那一拍记下时刻；空闲保持原时刻；新请求解冻。
    func testChartFreezesWhenRequestsFinishAndThawsOnTheNextOne() {
        let now = Date()
        XCTAssertNil(AppState.chartFrozenAt(previous: nil, wasLive: false, isLive: false, now: now))
        XCTAssertNil(AppState.chartFrozenAt(previous: nil, wasLive: true, isLive: true, now: now))
        XCTAssertEqual(AppState.chartFrozenAt(previous: nil, wasLive: true, isLive: false, now: now), now)
        let earlier = now.addingTimeInterval(-10)
        XCTAssertEqual(AppState.chartFrozenAt(previous: earlier, wasLive: false, isLive: false, now: now), earlier)
        XCTAssertNil(AppState.chartFrozenAt(previous: earlier, wasLive: false, isLive: true, now: now))
    }
}
