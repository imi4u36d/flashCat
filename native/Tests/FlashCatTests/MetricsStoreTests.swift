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

    /// 高速模型下的短流式请求：第一拍恰逢预填充（速率 0），随后 0.6 秒内完成吐字，
    /// 下一拍已经收尾。曲线必须补落该请求的真实解码点，不能空白并误标成非流式。
    @MainActor
    func testTickBackfillsShortStreamedRequestCaughtInPrefill() {
        let meter = GatewayMeter()
        let store = MetricsStore(meter: meter)
        let t0 = Date()
        // 先跑一拍建立引擎代际身份（模拟引擎已就绪运行），再发起请求。
        store.tick(now: t0.addingTimeInterval(-1.0), stats: ServerStats(), isRunning: true, activeEngine: .splash)
        let id = meter.begin(model: "m", dialect: "chat", promptTokens: 45, at: t0)

        // 第一拍仍在预填充：isLive = true，但速率为 0，实时拍不落点。
        store.tick(now: t0, stats: ServerStats(), isRunning: true, activeEngine: .splash)
        XCTAssertTrue(store.throughput.isEmpty)
        XCTAssertTrue(store.gatewayRateIsLive)

        // 0.1s 后首字，0.7s 收尾（共 75 tokens / 0.6s = 125 tok/s），均在两拍之间完成。
        meter.addTokens(id, 35, at: t0.addingTimeInterval(0.1))
        meter.addTokens(id, 40, at: t0.addingTimeInterval(0.7))
        meter.noteUsage(id, promptTokens: 45, completionTokens: 75)
        meter.finish(id, at: t0.addingTimeInterval(0.7))

        // 第二拍已收尾：补记该短流式点并冻结右缘。
        let t1 = t0.addingTimeInterval(1.0)
        store.tick(now: t1, stats: ServerStats(), isRunning: true, activeEngine: .splash)
        let visible = store.overviewThroughput(window: 60)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.value ?? 0, 75.0 / 0.6, accuracy: 1.0)
        XCTAssertNotNil(store.throughputFrozenAt)
        XCTAssertFalse(store.chartEmptyIsNonStreamed)
        XCTAssertGreaterThan(store.gatewayPrefillRate, 0)
    }

    /// 两次短流式请求都完整落在 1 秒节拍之间时，每次都能补落采样点，
    /// 且第二次请求会推进冻结右缘，确保两个点都在 60 秒冻结窗口内。
    @MainActor
    func testTickBackfillsShortStreamedRequestsBetweenTicksAndAdvancesFreeze() {
        let meter = GatewayMeter()
        let store = MetricsStore(meter: meter)
        let t0 = Date()
        store.tick(now: t0, stats: ServerStats(), isRunning: true, activeEngine: .splash)

        // 第一次短请求完全落在 t0..t1 之间
        let first = meter.begin(model: "m", dialect: "chat", promptTokens: 40, at: t0.addingTimeInterval(0.05))
        meter.addTokens(first, 30, at: t0.addingTimeInterval(0.15))
        meter.addTokens(first, 30, at: t0.addingTimeInterval(0.65))
        meter.finish(first, at: t0.addingTimeInterval(0.65))

        let t1 = t0.addingTimeInterval(1.0)
        store.tick(now: t1, stats: ServerStats(), isRunning: true, activeEngine: .splash)
        XCTAssertEqual(store.overviewThroughput(window: 60).count, 1)
        XCTAssertEqual(store.throughputFrozenAt, t1)

        // 第二次短请求在 5 秒后也完全落在两拍之间
        let second = meter.begin(model: "m", dialect: "chat", promptTokens: 50, at: t0.addingTimeInterval(5.1))
        meter.addTokens(second, 35, at: t0.addingTimeInterval(5.2))
        meter.addTokens(second, 35, at: t0.addingTimeInterval(5.7))
        meter.finish(second, at: t0.addingTimeInterval(5.7))

        let t2 = t0.addingTimeInterval(6.0)
        store.tick(now: t2, stats: ServerStats(), isRunning: true, activeEngine: .splash)
        let visible = store.overviewThroughput(window: 60)
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(store.throughputFrozenAt, t2)
    }

    /// 真正的非流式请求不会伪造逐秒曲线点，并正确标记非流式空态。
    @MainActor
    func testTickDoesNotBackfillNonStreamedRequest() throws {
        let meter = GatewayMeter()
        let store = MetricsStore(meter: meter)
        let t0 = Date()
        store.tick(now: t0, stats: ServerStats(), isRunning: true, activeEngine: .splash)
        let id = meter.begin(model: "m", dialect: "openai", promptTokens: 200, at: t0.addingTimeInterval(0.1))
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": "hello world"]]],
            "usage": ["prompt_tokens": 200, "completion_tokens": 20],
            "timings": [
                "prompt_n": 200, "cached_n": 0, "prompt_ms": 100.0,
                "predicted_n": 20, "predicted_ms": 200.0,
            ],
        ])
        meter.ingestResponse(id, body: body)

        store.tick(now: t0.addingTimeInterval(1.0), stats: ServerStats(), isRunning: true, activeEngine: .splash)
        XCTAssertTrue(store.throughput.isEmpty)
        XCTAssertTrue(store.chartEmptyIsNonStreamed)
    }

    /// 长流式请求在解码期间已被 1 Hz 实时拍命中，收尾时不额外补记重复点。
    @MainActor
    func testTickDoesNotDuplicateSampleForLongStreamedRequest() {
        let meter = GatewayMeter()
        let store = MetricsStore(meter: meter)
        let t0 = Date()
        let id = meter.begin(model: "m", dialect: "chat", promptTokens: 100, at: t0.addingTimeInterval(-1.5))
        meter.addTokens(id, 50, at: t0.addingTimeInterval(-1.0))
        meter.addTokens(id, 50, at: t0.addingTimeInterval(-0.5))
        meter.addTokens(id, 50, at: t0.addingTimeInterval(-0.1))

        // 实时拍命中解码区间
        store.tick(now: t0, stats: ServerStats(), isRunning: true, activeEngine: .splash)
        XCTAssertEqual(store.throughput.count, 1)

        meter.addTokens(id, 50, at: t0.addingTimeInterval(0.3))
        meter.finish(id, at: t0.addingTimeInterval(0.3))

        // 收尾拍不再多补一个点
        store.tick(now: t0.addingTimeInterval(1.0), stats: ServerStats(), isRunning: true, activeEngine: .splash)
        XCTAssertEqual(store.throughput.count, 1)
    }

    /// 冷启动首轮对话：`begin` 发生在引擎首次上报 `stats` 之前，首次建立 `lifetimeIdentity`
    /// 不得触发 `resetLifetime()` 把这轮正在跑的请求划进旧代；而随后真的换模型/重启时，
    /// 即使距离上一拍不到 0.95 秒也必须立即翻代清零。
    @MainActor
    func testFirstIdentityDoesNotOrphanColdStartSessionAndModelSwitchResetsImmediately() {
        let meter = GatewayMeter()
        let store = MetricsStore(meter: meter)
        let t0 = Date()

        // 引擎启动期间先跑过一拍 `stats == nil`（模拟启动阶段每秒心跳）。
        store.tick(now: t0, stats: nil, isRunning: true, activeEngine: .splash)

        // 冷启动首轮请求在首次 stats 到达前已登记并开始吐字。
        let first = meter.begin(model: "m1", dialect: "chat", promptTokens: 90, at: t0.addingTimeInterval(0.1))
        meter.markStarted(first, at: t0.addingTimeInterval(0.2))
        meter.addTokens(first, 60, at: t0.addingTimeInterval(0.3))
        meter.addTokens(first, 60, at: t0.addingTimeInterval(0.9))
        meter.noteUsage(first, promptTokens: 90, completionTokens: 120)
        meter.finish(first, at: t0.addingTimeInterval(0.9))

        var stats1 = ServerStats()
        stats1.instancePid = 1001
        stats1.startedAt = 1_700_000_000
        stats1.model = "m1"
        store.tick(now: t0.addingTimeInterval(1.0), stats: stats1, isRunning: true, activeEngine: .splash)

        XCTAssertGreaterThan(store.averageDecodeRate, 0)
        XCTAssertGreaterThan(store.gatewayTTFTMilliseconds, 0)
        XCTAssertGreaterThan(store.gatewayPrefillRate, 0)
        XCTAssertEqual(store.gatewayCacheHitRequests, 1)

        // 0.2 秒后真的切了新模型（小于 0.95 秒节拍闸门）：必须立即翻代清零，不等下一秒。
        var stats2 = stats1
        stats2.instancePid = 2002
        stats2.startedAt = 1_700_000_010
        stats2.model = "m2"
        store.tick(now: t0.addingTimeInterval(1.2), stats: stats2, isRunning: true, activeEngine: .splash)

        XCTAssertEqual(store.averageDecodeRate, 0)
        XCTAssertEqual(store.gatewayTTFTMilliseconds, 0)
        XCTAssertEqual(store.gatewayPrefillRate, 0)
        XCTAssertEqual(store.gatewayCacheHitRequests, 0)
    }

    /// 预填充进行中每一秒都应通过引擎 LIVE 读数实时刷新；进入解码后在末帧 usage
    /// 到达前即展示引擎刚完成的批次速度，无需等到整轮回答结束才出现。
    @MainActor
    func testTickPublishesLivePrefillDuringPrefillAndImmediatelyInDecode() {
        let meter = GatewayMeter()
        let store = MetricsStore(meter: meter)
        let t0 = Date()

        var stats = ServerStats()
        stats.instancePid = 1001
        stats.startedAt = 1_700_000_000
        stats.model = "m1"
        store.tick(now: t0, stats: stats, isRunning: true, activeEngine: .splash)
        XCTAssertEqual(store.prefillReading(isRunning: true), .none)

        // 请求开始预填充：网关尚无任何 token，引擎第 1 秒与第 2 秒分别上报实时预填充速率。
        let id = meter.begin(model: "m1", dialect: "chat", promptTokens: 4_000, at: t0.addingTimeInterval(0.2))
        stats.prefillTokensPerSecond = 2_800
        stats.prefillRateKind = .live
        store.tick(now: t0.addingTimeInterval(1.0), stats: stats, isRunning: true, activeEngine: .splash)
        XCTAssertEqual(store.prefillReading(isRunning: true), MetricReading(value: 2_800, origin: .engineLive))

        stats.prefillTokensPerSecond = 3_400
        stats.prefillRateKind = .live
        store.tick(now: t0.addingTimeInterval(2.0), stats: stats, isRunning: true, activeEngine: .splash)
        XCTAssertEqual(store.prefillReading(isRunning: true), MetricReading(value: 3_400, origin: .engineLive))

        // 预填充完成进入解码（任务尚未结束，末帧 usage 未到）：引擎 `.lastRequest` 立即可见。
        meter.addTokens(id, 40, at: t0.addingTimeInterval(2.3))
        stats.prefillTokensPerSecond = 3_640
        stats.prefillRateKind = .lastRequest
        store.tick(now: t0.addingTimeInterval(3.0), stats: stats, isRunning: true, activeEngine: .splash)
        XCTAssertEqual(store.prefillReading(isRunning: true), MetricReading(value: 3_640, origin: .engineLast))

        // 任务收尾并收到 usage：交回网关逐请求实测（`.gatewayLast`）。
        meter.noteTimings(
            id,
            GatewayMeter.RequestTimings(
                promptTokens: 4_000,
                cachedTokens: 0,
                promptMilliseconds: 1_100,
                predictedTokens: 100,
                predictedMilliseconds: 800))
        meter.finish(id, at: t0.addingTimeInterval(3.8))
        store.tick(now: t0.addingTimeInterval(4.0), stats: stats, isRunning: true, activeEngine: .splash)
        XCTAssertEqual(store.prefillReading(isRunning: true).origin, .gatewayLast)
        XCTAssertEqual(store.prefillReading(isRunning: true).value ?? 0, 4_000.0 / 1.1, accuracy: 1.0)
    }
}
