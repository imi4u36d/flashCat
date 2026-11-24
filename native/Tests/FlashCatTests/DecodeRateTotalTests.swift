// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCat
@testable import FlashCatCore

/// 指标 owner 表的解码格（hero、灵动岛、菜单栏共用的取数口径）。
///
/// 当前速度**只认网关按请求打点**：应用内对话也注册在 `GatewayMeter` 里，
/// 所以曲线、胶囊与「最近请求」是同一份数据。引擎的 LAST / AVG 不是当前速度；
/// 引擎的累计计数差分也不再参与——两套探测量的不是同一批请求，混用就是
/// 同一个请求被双重采样。`MetricOrigin` 是界面可见口径，`SpeedOrigin` 是它的
/// 旧名等价。
final class DecodeRateTotalTests: XCTestCase {
    /// 把 `speedOrigin` + 值折叠成界面口径。
    private static func origin(
        gateway: Double,
        gatewayIsLive: Bool = true,
        gatewayAge: TimeInterval? = nil
    ) -> MetricOrigin {
        let speed = AppState.speedOrigin(gatewayIsLive: gatewayIsLive, gatewayAge: gatewayAge)
        return AppState.reading(origin: speed, gateway: gateway).origin
    }

    private static func value(
        gateway: Double,
        gatewayIsLive: Bool = true,
        gatewayAge: TimeInterval? = nil
    ) -> Double {
        let speed = AppState.speedOrigin(gatewayIsLive: gatewayIsLive, gatewayAge: gatewayAge)
        return AppState.reading(origin: speed, gateway: gateway).value ?? 0
    }

    /// 网关有在跑会话时，读数就是它的按请求之和；曲线和「最近请求」每一行
    /// 相加能对上。
    func testGatewayAggregateIsTheCurrentSpeed() {
        XCTAssertEqual(Self.value(gateway: 81.6), 81.6, accuracy: 0.001)
        XCTAssertEqual(Self.origin(gateway: 81.6), .gatewayLive)
    }

    /// 网关还有会话没收尾时，这一路就是唯一 owner：哪怕这一拍读到 0
    /// （预填充、分片间隙），也如实说 0，不找引擎补位。
    func testGatewaySessionOwnsTheReadingEvenAtZeroRate() {
        XCTAssertEqual(Self.value(gateway: 0), 0)
        XCTAssertEqual(Self.origin(gateway: 0), .gatewayLive)
    }

    /// 请求结束后网关保留的终值不是当前速度；LAST 采集入口已取消，
    /// 宁可显示「—」也不能把上一请求的值挂成实时读数。
    func testGatewayFinishedTailIsNotCurrentSpeed() {
        XCTAssertEqual(Self.value(gateway: 44.1, gatewayIsLive: false), 0)
        XCTAssertEqual(Self.origin(gateway: 44.1, gatewayIsLive: false), .none)
    }

    /// 网关没有在跑会话（空闲，或客户端直连引擎端口）就没有当前速度：
    /// 引擎的计数器差分不再是兜底——它覆盖整台进程，和网关量的不是同一批
    /// 请求，混进来就是双重采样。
    func testNoGatewaySessionMeansNoCurrentSpeed() {
        XCTAssertEqual(Self.value(gateway: 0, gatewayIsLive: false), 0)
        XCTAssertEqual(Self.origin(gateway: 0, gatewayIsLive: false), .none)
    }

    /// 网关读数超过新鲜度门槛（两个 1 秒节拍）就不再冒充「此刻」。
    func testStaleGatewayReadingReadsNothing() {
        XCTAssertEqual(Self.origin(gateway: 44.1, gatewayIsLive: true, gatewayAge: 0.5), .gatewayLive)
        XCTAssertEqual(Self.origin(gateway: 44.1, gatewayIsLive: true, gatewayAge: 3.0), .none)
    }

    // MARK: 预填充格

    /// 预填充统一只认网关按请求算出的实测值（LAST），不再读取引擎自报字段。
    func testPrefillUsesGatewayMeasurementOnly() {
        let reading = AppState.prefillReading(gateway: 1_800)
        XCTAssertEqual(reading.origin, .gatewayLast)
        XCTAssertEqual(reading.value ?? 0, 1_800, accuracy: 0.001)

        XCTAssertEqual(AppState.prefillReading(gateway: 0), .none)
        XCTAssertEqual(AppState.prefillReading(gateway: -1), .none)
    }

    // MARK: 首字格

    /// 首字统一只认网关逐请求实测，没有正样本时画「—」：0 不是「首字很快」。
    func testTTFTUsesGatewayMeasurementOnly() {
        let reading = AppState.ttftReading(gateway: 250)
        XCTAssertEqual(reading.milliseconds ?? 0, 250, accuracy: 0.001)
        XCTAssertEqual(reading.source, .gateway)
        XCTAssertEqual(reading.kind, .lastRequest)

        XCTAssertEqual(AppState.ttftReading(gateway: 0), .none)
        XCTAssertEqual(AppState.ttftReading(gateway: -1), .none)
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
