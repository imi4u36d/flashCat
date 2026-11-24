// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCat
@testable import FlashCatCore

/// 搬进 `MetricsStore` 的那一整套指标：曲线窗口、10 分钟裁剪、接受率落点门槛、
/// 曲线冻结，以及 store 自己的节拍。
///
/// 这些判断原来长在 AppState 里，只能靠跑起来看界面。搬移把阈值（0.9 / 1e-4 /
/// 0.15 / 600 / 2.0）一字不改地留在这里，用纯函数把它们钉住——以后谁想「顺手
/// 调一下手感」，测试会先说话。
final class MetricsStoreTests: XCTestCase {
    private static let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private static func samples(
        every step: TimeInterval,
        count: Int,
        endingAt end: Date
    ) -> [ThroughputSample] {
        (0..<count).map { index in
            let offset = end.addingTimeInterval(-Double(count - 1 - index) * step)
            return ThroughputSample(at: offset, value: Double(index))
        }
    }

    // MARK: 窗口切片

    /// 窗口左缘含端点：`end - window` 那一刻的样本必须留下，再早一格就出窗。
    func testSuffixKeepsSamplesFromWindowStartInclusive() {
        let end = Self.anchor
        let samples = Self.samples(every: 10, count: 6, endingAt: end)
        // 样本时刻：-50 / -40 / -30 / -20 / -10 / 0
        let window = MetricsStore.suffix(of: samples, window: 20, endingAt: end)
        XCTAssertEqual(window.map(\.value), [3, 4, 5])
    }

    /// 右缘之后（理论上不该有）的迟到样本要被排除，冻结的曲线因此不会自己长高。
    func testSuffixStopsAtEndingAt() {
        let end = Self.anchor
        let early = ThroughputSample(at: end.addingTimeInterval(-5), value: 1)
        let late = ThroughputSample(at: end.addingTimeInterval(5), value: 2)
        let window = MetricsStore.suffix(of: [early, late], window: 60, endingAt: end)
        XCTAssertEqual(window.map(\.value), [1])
    }

    func testSuffixOfEmptySeriesIsEmpty() {
        XCTAssertTrue(MetricsStore.suffix(of: [], window: 60, endingAt: Self.anchor).isEmpty)
    }

    /// 窗口比整条序列还宽时全留下——启动头几秒不该因为样本不够就空图。
    func testSuffixWiderThanSeriesKeepsEverything() {
        let end = Self.anchor
        let samples = Self.samples(every: 10, count: 4, endingAt: end)
        XCTAssertEqual(MetricsStore.suffix(of: samples, window: 600, endingAt: end).count, 4)
    }

    // MARK: 保留窗口

    /// 保留 10 分钟：更老的样本直接丢，曲线只服务概览 60 秒与菜单栏 5 分钟。
    func testTrimmedDropsSamplesOlderThanTenMinutes() {
        let now = Self.anchor
        let old = ThroughputSample(at: now.addingTimeInterval(-601), value: 1)
        let edge = ThroughputSample(at: now.addingTimeInterval(-600), value: 2)
        let fresh = ThroughputSample(at: now, value: 3)
        let kept = MetricsStore.trimmed([old, edge, fresh], at: now)
        XCTAssertEqual(kept.map(\.value), [2, 3])
    }

    // MARK: 曲线冻结

    /// 有请求在跑永远解冻：新请求一来曲线就得继续往前爬。
    func testChartFrozenAtUnfreezesWhileLive() {
        let frozen = MetricsStore.chartFrozenAt(previous: Self.anchor, wasLive: false, isLive: true, now: Self.anchor)
        XCTAssertNil(frozen)
    }

    /// 冻结记的是**第一次**收尾时刻；空闲期间反复走的节拍不能把右缘一路往后推。
    func testChartFrozenAtKeepsFirstFreeze() {
        let frozen = MetricsStore.chartFrozenAt(
            previous: Self.anchor,
            wasLive: false,
            isLive: false,
            now: Self.anchor.addingTimeInterval(300))
        XCTAssertEqual(frozen, Self.anchor)
    }

    /// 1 → 0 的那一拍记下收尾时刻。
    func testChartFrozenAtFreezesOnLiveToIdle() {
        let now = Self.anchor
        XCTAssertEqual(MetricsStore.chartFrozenAt(previous: nil, wasLive: true, isLive: false, now: now), now)
    }

    /// 一直空闲不冻结，否则启动即冻、横轴永远停在开机时刻。
    func testChartFrozenAtStaysOpenWhenNeverLive() {
        XCTAssertNil(MetricsStore.chartFrozenAt(previous: nil, wasLive: false, isLive: false, now: Self.anchor))
    }

    // MARK: 接受率落点

    /// 第一次有值就落点。
    func testAcceptanceFirstSampleIsDue() {
        let due = MetricsStore.shouldSampleAcceptance(
            lastAt: nil,
            lastValue: nil,
            latest: 0.4,
            reportedDecodeRate: nil,
            throughputLastValue: nil,
            now: Self.anchor)
        XCTAssertTrue(due)
    }

    /// 0.9 秒的最短间隔：数值再变也不落点，否则每秒一拍会画出锯齿。
    func testAcceptanceRespectsCadence() {
        let now = Self.anchor
        let due = MetricsStore.shouldSampleAcceptance(
            lastAt: now.addingTimeInterval(-0.3),
            lastValue: 0.4,
            latest: 0.5,
            reportedDecodeRate: nil,
            throughputLastValue: nil,
            now: now)
        XCTAssertFalse(due)
    }

    /// 过了间隔但数值没动、解码读数也静止：不落点，曲线不无谓刷新。
    func testAcceptanceSkipsUnchangedReading() {
        let now = Self.anchor
        let due = MetricsStore.shouldSampleAcceptance(
            lastAt: now.addingTimeInterval(-1),
            lastValue: 0.4,
            latest: 0.40005,
            reportedDecodeRate: 12,
            throughputLastValue: 12.1,
            now: now)
        XCTAssertFalse(due)
    }

    /// 变化超过 1e-4 就落点。
    func testAcceptanceSamplesRealChange() {
        let now = Self.anchor
        let due = MetricsStore.shouldSampleAcceptance(
            lastAt: now.addingTimeInterval(-1),
            lastValue: 0.4,
            latest: 0.42,
            reportedDecodeRate: 12,
            throughputLastValue: 12.1,
            now: now)
        XCTAssertTrue(due)
    }

    /// 接受率没变但引擎自报的速率与曲线末端差过 0.15：也算读数在动，要落点。
    func testAcceptanceSamplesWhenDecodeRateIsMoving() {
        let now = Self.anchor
        let due = MetricsStore.shouldSampleAcceptance(
            lastAt: now.addingTimeInterval(-1),
            lastValue: 0.4,
            latest: 0.4,
            reportedDecodeRate: 20,
            throughputLastValue: 12,
            now: now)
        XCTAssertTrue(due)
    }

    // MARK: store 节拍

    /// 一拍只做一件事：把这一秒的引擎状态翻译成读数。没有接受率就一个点都不落。
    @MainActor
    func testTickSamplesAcceptanceAtOneSecondCadence() {
        let store = MetricsStore(meter: GatewayMeter())
        var stats = ServerStats()
        stats.draftAcceptance = 0.4

        store.tick(now: Self.anchor, stats: stats, isRunning: true, activeEngine: .splash)
        XCTAssertEqual(store.acceptance.count, 1)

        // 半秒后再来一拍：门槛没过，不落点。
        store.tick(now: Self.anchor.addingTimeInterval(0.3), stats: stats, isRunning: true, activeEngine: .splash)
        XCTAssertEqual(store.acceptance.count, 1)

        stats.draftAcceptance = 0.5
        store.tick(now: Self.anchor.addingTimeInterval(1), stats: stats, isRunning: true, activeEngine: .splash)
        XCTAssertEqual(store.acceptance.count, 2)
    }

    /// 引擎不报接受率时 acceptance 一直是空的，界面据此画「—」而不是 0%。
    @MainActor
    func testTickWithoutAcceptanceLeavesSeriesEmpty() {
        let store = MetricsStore(meter: GatewayMeter())
        store.tick(now: Self.anchor, stats: ServerStats(), isRunning: true, activeEngine: .splash)
        XCTAssertTrue(store.acceptance.isEmpty)
        XCTAssertTrue(store.throughput.isEmpty)
    }

    /// 总解码曲线只认网关这一路探测。网关还有会话没收尾时，即使这一拍读数是 0
    /// （预填充 / 分片间隙），也不能拿引擎的实时计数补点——两套探测覆盖的
    /// 请求范围不同，混用就是同一个请求被双重采样。
    @MainActor
    func testThroughputDoesNotBorrowEngineProbeWhileGatewaySessionIsLive() {
        let meter = GatewayMeter()
        _ = meter.begin(model: "m", dialect: "test", promptTokens: 10)
        let store = MetricsStore(meter: meter)
        var stats = ServerStats()
        stats.decodeTokensPerSecond = 50
        stats.decodeRateKind = .live
        stats.activeRequests = 1

        // 用真实时刻：网关读数的新鲜度门槛拿 `Date()` 比，锚点时间会被判成过期。
        store.tick(now: Date(), stats: stats, isRunning: true, activeEngine: .splash)
        XCTAssertTrue(store.throughput.isEmpty)
        XCTAssertTrue(store.gatewayRateIsLive)
    }

    /// 引擎自报的实时解码速度不再是曲线来源：网关没有在跑会话时，即使引擎说
    /// 自己在 50 tok/s（客户端直连引擎端口），曲线也不落点。这条曲线只回答
    /// 「网关看见的请求多快」。
    @MainActor
    func testThroughputIgnoresEngineProbeWithoutGatewaySessions() {
        let store = MetricsStore(meter: GatewayMeter())
        var stats = ServerStats()
        stats.decodeTokensPerSecond = 50
        stats.decodeRateKind = .live
        stats.activeRequests = 1

        store.tick(now: Date(), stats: stats, isRunning: true, activeEngine: .splash)
        XCTAssertTrue(store.throughput.isEmpty)
        XCTAssertFalse(store.gatewayRateIsLive)
    }

    /// 没有会话在跑时不冻结曲线：启动即空闲不算「收尾」。
    @MainActor
    func testTickDoesNotFreezeChartWhenNeverLive() {
        let store = MetricsStore(meter: GatewayMeter())
        store.tick(now: Self.anchor, stats: ServerStats(), isRunning: false, activeEngine: .splash)
        XCTAssertNil(store.throughputFrozenAt)
        // 解冻时右缘跟着挂钟走，而不是钉在某个旧时刻。
        XCTAssertEqual(store.overviewChartEnd.timeIntervalSinceNow, 0, accuracy: 5)
    }
}
