// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Combine
import FlashCatKit
import Foundation

// MARK: - 曲线采样点

package struct ThroughputSample: Identifiable {
    /// 用时间戳做身份：每个采样点的时刻天然唯一，没必要为每个点再分配一个
    /// UUID。10 分钟窗口里最多一千多个点，省下的是持续的分配与 16 字节/点。
    package var id: Date { at }
    package let at: Date
    package let value: Double
}

/// 概览当前速度的来源。速度类指标**只认网关按请求打点**：一份数据、一个口径，
/// 不再和引擎的计数器差分混着用。收尾后的上一请求终值（LAST）不是一个可用
/// 来源：概览只认「此刻在跑」。
package enum SpeedOrigin: Equatable {
    /// 没有在跑的网关会话：没有当前速度。
    case none
    /// 网关在跑会话的合计速率（重采样后的窗口读数）。窗口读数就是当前速度本身，
    /// 所以活跃期间不区分估算与精确计数。只要还有没收尾的会话，这一路就是
    /// 唯一 owner：读数是 0（预填充 / 分片间隙）也由它如实说 0。
    case gatewayLive
}

/// 一个指标格当前的**取数来源**。owner 表算出来的就是这个值，界面直接按它
/// 打角标与说明文案。
///
/// 概览与菜单栏的所有请求性能指标（实时解码、平均解码、预填充、首字延迟、
/// 缓存命中率）统一只认网关按请求打点（`GatewaySessionMeter`），不再读引擎
/// 自报速率或对引擎计数器做差分。
package enum MetricOrigin: Equatable {
    /// 没有任何可用读数（尚无样本、或值 ≤ 0）。
    case none
    /// 网关按请求打点的实时读数（重采样窗口）。
    case gatewayLive
    /// 网关按请求打点算出的最近一次预填充实测值。
    case gatewayLast
    /// 网关按会话累计的「模型启动以来平均」——hero 的解码均值与缓存命中率共用。
    case gatewayMean
    /// 引擎每秒上报的实时预填充读数（预填充进行中，网关此时尚未收到首 token）。
    case engineLive
    /// 引擎刚刚完成的预填充批次实测值（请求仍在解码、网关末帧 usage 尚未到达时立即显示）。
    case engineLast
    /// 引擎进程累计预填充均值（无逐请求读数时的兜底）。
    case engineMean
}

/// 一格指标的 owner 表输出：数值 + 它回答的是哪个问题。
/// `value == nil` 时 `origin == .none`，界面画「—」。
package struct MetricReading: Equatable {
    package let value: Double?
    package let origin: MetricOrigin

    package static let none = MetricReading(value: nil, origin: .none)
}

/// 首字延迟格的取数结果：数值 + 它来自哪一侧的观测。
///
/// 首字和预填充一样是一次性观测，统一取网关按请求实测的最近一次首字；
/// 网关还没有样本时画「—」。
package struct TTFTReading: Equatable {
    package enum Source: Equatable {
        /// 没有任何首字样本。
        case none
        /// 网关按请求实测的最近一次首字。
        case gateway
    }

    package let milliseconds: Double?
    package let source: Source
    package let kind: EngineTTFTKind

    package init(milliseconds: Double?, source: Source, kind: EngineTTFTKind = .none) {
        self.milliseconds = milliseconds
        self.source = source
        self.kind = kind
    }

    package static let none = TTFTReading(milliseconds: nil, source: .none, kind: .none)
}

// MARK: - MetricsStore

/// 概览 / 灵动岛 / 菜单栏的指标状态与曲线：owner 表读数、每秒一拍的发布、
/// 曲线采样与冻结。
///
/// 为什么单独成类：这些字段原来和对话、下载、引擎生命周期等六十多个
/// `@Published` 挤在同一个 `AppState` 上，任何一格读数变化都会把整页重绘一次，
/// 而指标逻辑本身与界面状态无关——它只依赖「引擎状态 + 网关打点」。拆出来之后
/// 这一块的发布节奏和采样规则可以在一个文件里读完，也能在没有窗口的测试里钉住。
///
/// 界面契约没有变：`AppState` 保留同名转发（含 `objectWillChange` 桥），所有
/// `@ObservedObject` 视图照旧读 `state.decodeReading` 这类名字。store 自己**不**
/// 持有 `ServerStats`：它由调用方逐次传进来，避免同一份引擎状态出现两个真相。
@MainActor
package final class MetricsStore: ObservableObject {
    // MARK: 曲线样本
    //
    // 曲线样本只服务概览 60 秒与菜单栏近 5 分钟；保留 10 分钟足够，
    // 以前留 30 分钟，多出来的两三千个点没有任何界面读。
    /// `nonisolated`：窗口裁剪在纯静态函数里做，测试要能不等主线程直接调用。
    nonisolated private static let sampleRetention: TimeInterval = 600

    /// 概览总解码曲线的样本。速度**只取网关按请求打点的聚合**：应用内对话
    /// 也注册在 `GatewayMeter` 里，所以这条曲线覆盖全部经过网关的请求。
    /// 引擎的计数器差分不再参与（那是另一批请求、另一把尺）。
    @Published package private(set) var throughput: [ThroughputSample] = []
    /// 草稿接受率（DFlash2 / MTP）的时间序列，采样节奏与吞吐一致，
    /// 概览页用它画第二条实时曲线。value 是 0…1 的比例。
    @Published package private(set) var acceptance: [ThroughputSample] = []

    // MARK: 网关聚合读数
    //
    // 所有请求性能指标（实时解码、平均解码、预填充、TTFT、缓存命中率）统一由
    // 网关按请求打点给出（应用内对话也注册在 `GatewayMeter` 里），不再退回引擎
    // 自报的速率或计数差分。

    /// 网关按请求打点的聚合速率。概览曲线与「最近请求」同源，
    /// 应用内对话也注册在 `GatewayMeter` 里。收尾后归零：只表示「此刻多快」。
    @Published package private(set) var gatewayDecodeRate: Double = 0
    /// `gatewayDecodeRate` 是否来自在跑会话。false = 没有在跑会话（或引擎
    /// 已经收尾），此时没有当前速度，读数不挂上一请求的终值。
    @Published package private(set) var gatewayRateIsLive = false
    /// 网关自己量出来的预填充速度（最近一次完成的预填充）。引擎返回 `timings`
    /// 时以逐请求 `timings` 为准，否则用 `(promptTokens - cachedTokens) / TTFT`。
    /// 0 = 还没有可用的实测值。
    @Published package private(set) var gatewayPrefillRate: Double = 0
    /// 引擎 1 Hz 轮询上报的预填充速率与粒度：预填充进行中为 `.live`（每秒刷新），
    /// 预填充刚结束而解码尚未收尾时为 `.lastRequest`，让预填充卡不用等整轮回答结束。
    @Published package private(set) var enginePrefillRate: Double = 0
    @Published package private(set) var enginePrefillKind: EngineRateKind = .none
    /// 网关自己量出来的最近一次首字耗时（毫秒）。0 = 还没有可用的实测值。
    @Published package private(set) var gatewayTTFTMilliseconds: Double = 0
    /// 网关按代累计的缓存命中率（0…1）。分子是 usage 里的前缀缓存命中量，
    /// 分母是同一批请求的提示词总量（按 token 加权）；只统计真的收到 usage
    /// 的请求。0 = 还没有样本，界面不能把它当成「0% 命中」。
    @Published package private(set) var gatewayCacheHitRate: Double = 0
    /// 上面这个读数覆盖的请求数，卡片的说明文案会原样引用它。
    @Published package private(set) var gatewayCacheHitRequests: Int = 0
    /// 模型启动以来的平均解码速度（网关按会话累计）。hero 大数字读它：
    /// 曲线回答「此刻多快」，大数字回答「这台模型平均吐字多快」。0 = 还没有
    /// 可算的样本，界面画「—」。
    @Published package private(set) var averageDecodeRate: Double = 0
    /// 网关侧最近/在跑会话的上下文占用 tokens（含外部客户端与网关流量）。
    @Published package private(set) var gatewayContextTokens: Int = 0
    @Published package private(set) var gatewayContextIsLive: Bool = false
    /// 60 秒曲线冻结的时刻。请求收尾后设为收尾时刻，`overviewThroughput`
    /// 与横轴都以它为右缘——曲线停住，不再随挂钟把终点挤出窗口。
    /// 新请求开始时清空，曲线恢复滚动。
    @Published package private(set) var throughputFrozenAt: Date?
    /// 当代已完成会话是否全是非流式：概览曲线为空时仅在这种情形下显示
    /// 「非流式请求无逐秒曲线」，避免把短流式或失败请求误标成非流式。
    @Published package private(set) var chartEmptyIsNonStreamed = false

    // MARK: 私有状态
    /// 上一次采样时是否还有请求在跑，用来识别「1 → 0」这次收尾。
    private var chartWasLive = false
    /// 已核对过短流式补点的最大会话 id，避免重复扫描历史会话。
    private var lastBackfilledSessionID = 0
    /// 累计均值的身份（引擎 + 进程 + 模型）。换代时清空 `GatewayMeter`
    /// 的累计量，避免把上一台模型的成绩算进这一台。
    private var lifetimeIdentity: String?
    /// 上一次观察到的引擎运行秒数，用于在没有 pid/startedAt 时检测重启。
    private var previousUptimeSeconds: Double?
    /// 概览速度读数的上一拍。`syncController` 会被引擎的多次状态变化触发，
    /// 不加闸就会在一秒内发布好几次——概览的刻钟是 1 秒，不是事件驱动。
    private var lastSpeedPublishAt: Date?
    /// 解码速度读数与它自己的时间基之间的最大跨度。超过这个跨度，重采样器
    /// 的窗口就覆盖不到调用方所在的时间——这个读数就不再回答「此刻多快」，
    /// 降级为「没有当前速度」。
    nonisolated private static let rateReadingFreshness: TimeInterval = 2.0
    /// `gatewayDecodeRate` 最后一次刷新的时刻，用于 `decodeReading` 的新鲜度
    /// 门槛。只在主线程读写。
    private var gatewayReadingAt: Date?
    /// 打点的真相源。生产只传 `.shared`（网关自己登记会话的那一份）；
    /// 测试传独立实例，免得读到其他测试或应用内对话留下的会话。
    private let meter: GatewayMeter

    package init(meter: GatewayMeter = .shared) {
        self.meter = meter
    }

    // MARK: 指标 owner 表
    //
    // 每个指标格只有一个 owner：网关按请求打点（`GatewaySessionMeter`）。
    // 所有请求性能界面（概览 / 灵动岛 / 菜单栏）都从下面这几个函数取数，
    // 一格一个来源、一个粒度，不再混用引擎自报速率或计数器差分。
    //
    // 分工的物理边界：网关负责一切请求级吞吐与延迟指标（解码速度、平均解码、
    // 预填充、TTFT、缓存命中率、请求上下文），引擎状态仅保留进程生命周期、
    // 显存、温度、内存压力、上下文上限与草稿接受率等运行态事实。

    /// 解码格的输出：`speedOrigin` 的判定 + 它的值，永远同源。
    /// 概览曲线与菜单栏的「当前解码速度」都读它；收尾后归零，不挂 LAST。
    package func decodeReading(isRunning: Bool) -> MetricReading {
        Self.reading(
            origin: currentSpeedOrigin(isRunning: isRunning),
            gateway: gatewayDecodeRate)
    }

    package nonisolated static func reading(
        origin: SpeedOrigin,
        gateway: Double
    ) -> MetricReading {
        switch origin {
        case .gatewayLive: return MetricReading(value: gateway, origin: .gatewayLive)
        case .none: return .none
        }
    }

    /// HERO 大数字：模型启动以来的平均解码速度，而不是曲线的实时值。
    ///
    /// 统一取网关按会话结算的累计量（覆盖所有经过网关的请求，含应用内对话）；
    /// 没有样本时返回 `.none`，界面画「—」。
    package func averageDecodeReading(isRunning: Bool) -> MetricReading {
        guard isRunning, averageDecodeRate > 0 else { return .none }
        return MetricReading(value: averageDecodeRate, origin: .gatewayMean)
    }

    /// 菜单栏解码格：有实时读数就报实时，空闲时退回「模型启动以来平均」。
    /// 面板只有一格，不能像概览那样把实时曲线和大数字分开摆——空闲时那格
    /// 若空着，读者会以为测速坏了。退回的值带着 `.gatewayMean` 的 origin，
    /// 面板据此打 `AVG` 角标，不把平均值冒充成此刻速度。
    package func menuBarDecodeReading(isRunning: Bool) -> MetricReading {
        let live = decodeReading(isRunning: isRunning)
        guard live.value == nil else { return live }
        return averageDecodeReading(isRunning: isRunning)
    }

    /// 预填充格的 owner 表输出：
    /// 1. 正在预填充（引擎 `.live`）→ 每秒实时刷新（此时网关连首 token 都还没收到）；
    /// 2. 请求仍在解码（`gatewayRateIsLive`）且引擎已报出本轮完成的 `.lastRequest`
    ///    → 立即显示本轮预填充，无需等到整段回答结束才看到末帧 `usage` / `timings`；
    /// 3. 请求收尾后优先网关逐请求实测（`.gatewayLast`）；
    /// 4. 网关无样本时兜底引擎的 `.lastRequest` / `.lifetimeMean`。
    package func prefillReading(isRunning: Bool) -> MetricReading {
        guard isRunning else { return .none }
        return Self.prefillReading(
            gateway: gatewayPrefillRate,
            engine: enginePrefillRate > 0 ? enginePrefillRate : nil,
            engineKind: enginePrefillKind,
            isLive: gatewayRateIsLive)
    }

    /// 预填充格的纯函数口径，便于测试直接验证优先级。
    package nonisolated static func prefillReading(
        gateway: Double,
        engine: Double? = nil,
        engineKind: EngineRateKind = .none,
        isLive: Bool = false
    ) -> MetricReading {
        let engineValue = (engine ?? 0) > 0 ? engine : nil
        if engineKind == .live, let engineValue {
            return MetricReading(value: engineValue, origin: .engineLive)
        }
        if isLive, engineKind == .lastRequest, let engineValue {
            return MetricReading(value: engineValue, origin: .engineLast)
        }
        if gateway > 0 {
            return MetricReading(value: gateway, origin: .gatewayLast)
        }
        if let engineValue {
            switch engineKind {
            case .lastRequest:
                return MetricReading(value: engineValue, origin: .engineLast)
            case .lifetimeMean:
                return MetricReading(value: engineValue, origin: .engineMean)
            case .live:
                return MetricReading(value: engineValue, origin: .engineLive)
            case .none:
                break
            }
        }
        return .none
    }

    /// 首字延迟格的 owner 表输出：仅认网关逐请求实测的最近一次首字。
    /// 没有正样本时画「—」：0 不是「首字很快」。
    package func ttftReading(isRunning: Bool) -> TTFTReading {
        guard isRunning else { return .none }
        return Self.ttftReading(gateway: gatewayTTFTMilliseconds)
    }

    /// 首字格的纯函数口径：网关值是「最近一次真的量到首字」的请求，> 0 才可用。
    package nonisolated static func ttftReading(gateway: Double) -> TTFTReading {
        guard gateway > 0 else { return .none }
        return TTFTReading(milliseconds: gateway, source: .gateway, kind: .lastRequest)
    }

    /// 缓存命中率格的 owner 表输出：仅认网关按代累计的「命中量 / 提示词总量」
    /// （按 token 加权），没有样本时画「—」，不拿 0% 冒充「一次都没命中」。
    package func cacheHitReading(isRunning: Bool) -> MetricReading {
        guard isRunning else { return .none }
        return Self.cacheHitReading(
            gateway: gatewayCacheHitRate,
            requests: gatewayCacheHitRequests)
    }

    /// 缓存命中率的纯函数口径：测试钉住「0% 是合法读数、没样本才是 —」。
    package nonisolated static func cacheHitReading(
        gateway: Double,
        requests: Int
    ) -> MetricReading {
        guard requests > 0, gateway >= 0, gateway <= 1 else { return .none }
        return MetricReading(value: gateway, origin: .gatewayMean)
    }

    /// 速度来源的判定。当前速度只有两种状态：网关在跑会话（`gatewayLive`），
    /// 或者没有当前速度（`none`）。抽成纯函数，测试可以钉住「收尾后不挂 LAST」
    /// 「空闲不显示旧值」「读数过旧降级」。
    ///
    /// `gatewayIsLive == false` 时网关值一律不参与——没有 LAST 这种"降级"。
    /// 判定只看会话是否在跑，不看这一拍的读数是多少：网关的读数由
    /// `reading(origin:gateway:)` 原样带出，0 也是网关的答案。
    package nonisolated static func speedOrigin(
        gatewayIsLive: Bool = true,
        gatewayAge: TimeInterval? = nil
    ) -> SpeedOrigin {
        guard gatewayIsLive, gatewayAge.map({ $0 <= rateReadingFreshness }) ?? true else {
            return .none
        }
        return .gatewayLive
    }

    /// `speedOrigin` 的界面可见口径：带上主线程那份 `gatewayDecodeRate` 的年龄。
    package func currentSpeedOrigin(isRunning: Bool) -> SpeedOrigin {
        guard isRunning else { return .none }
        return Self.speedOrigin(
            gatewayIsLive: gatewayRateIsLive,
            gatewayAge: gatewayReadingAt.map(Date().timeIntervalSince))
    }

    // MARK: 曲线窗口

    /// 概览 60 秒曲线的右缘：请求收尾后冻结在收尾时刻，新请求开始后恢复
    /// 跟随挂钟。hero 不再有 sparkline，只有概览曲线读这个口径。
    package var overviewChartEnd: Date { throughputFrozenAt ?? Date() }

    /// 概览曲线样本。冻结后只取到 `throughputFrozenAt`，不会随着窗口
    /// 继续滚动而把曲线抽空。
    package func overviewThroughput(window: TimeInterval) -> [ThroughputSample] {
        guard window > 0 else { return throughput }
        return Self.suffix(of: throughput, window: window, endingAt: overviewChartEnd)
    }

    /// 概览用 60 秒、菜单栏用近 5 分钟；序列保留 10 分钟，留一点余量。
    /// 菜单栏的 sparkline 不冻结，所以这里仍以当前时刻为右缘。
    package func recentThroughput(window: TimeInterval) -> [ThroughputSample] {
        guard window > 0 else { return throughput }
        return Self.suffix(of: throughput, window: window, endingAt: Date())
    }

    /// 序列按时间升序排列，用二分找窗口起点；概览每秒都会为几张图各取一次，
    /// 全表 `filter` 在千余个样本上没有必要。`endingAt` 是窗口右缘：冻结的
    /// 曲线传收尾时刻，右缘之后（理论上没有）的迟到样本一并排除。
    /// 抽成 `internal` 纯函数，测试可以绕开窗口直接钉住窗口边界。
    package nonisolated static func suffix(
        of samples: [ThroughputSample],
        window: TimeInterval,
        endingAt end: Date
    ) -> [ThroughputSample] {
        guard !samples.isEmpty else { return [] }
        let cutoff = end.addingTimeInterval(-window)
        var low = 0
        var high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].at < cutoff {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < samples.count else { return [] }
        return samples[low...].filter { $0.at <= end }
    }

    /// 丢掉超出保留窗口的老样本。原来写成 `removeAll { $0.at < cutoff }`，
    /// 抽成纯函数后两条曲线用同一把尺，测试也能钉住 10 分钟这条线。
    package nonisolated static func trimmed(_ samples: [ThroughputSample], at now: Date) -> [ThroughputSample] {
        let cutoff = now.addingTimeInterval(-sampleRetention)
        return samples.filter { $0.at >= cutoff }
    }

    // MARK: 每秒节拍

    /// 指标的唯一节拍：发布网关读数、落一个 1 秒曲线点、判断是否该冻结曲线，
    /// 并同频采样草稿接受率。
    ///
    /// 只由 `AppState.syncController` 调用——它已经是全应用唯一的一秒节拍源
    /// （引擎轮询 1 秒）。应用内对话的分片回调只往网关打点里记 token（消息
    /// 读数也读那一份），不刷新概览，也不在这里事件驱动地重发布。
    package func tick(
        now: Date,
        stats: ServerStats?,
        isRunning: Bool,
        activeEngine: EngineID
    ) {
        publishDecodeRate(at: now, stats: stats, isRunning: isRunning, activeEngine: activeEngine)
        // 接受率与吞吐同频采样。引擎给的是会话累计值：空闲时它不变，生成时才爬。
        sampleAcceptance(at: now, stats: stats)
    }

    /// 概览速度节拍：读一次网关聚合、发布当前速度与平均速度、
    /// 落一个 1 秒曲线点、判断是否该冻结曲线。
    ///
    /// 应用内对话也注册在 `GatewayMeter` 里，所以这里的实时值、曲线末端与
    /// 「最近请求」读的是同一份按请求打点。收尾后 `overview.isLive` 立刻
    /// 变 false：当前速度归零（不再挂 LAST），曲线冻结在最后一个采样点。
    ///
    /// 采样规则只有一条：**一拍最多一个点**。`publishDecodeRate` 自己已经
    /// 按 1 秒闸住，所以这里不再做第二道时间门槛；按「值变了」加密采样
    /// 更不行——同一秒内的多次 `syncController` 会把 60 秒曲线灌成非等距的点。
    private func publishDecodeRate(
        at now: Date,
        stats: ServerStats?,
        isRunning: Bool,
        activeEngine: EngineID
    ) {
        // 累计均值的身份先对齐，且不受 0.95 秒节拍闸门延迟：
        // 引擎刚就绪（或重启 / 换模型）时必须立刻完成换代，否则紧随其后发出的
        // 首条请求会在开始吐字后才被迟到的 `resetLifetime` 误划到旧代。
        let identityChanged = syncLifetimeIdentity(stats: stats, activeEngine: activeEngine)
        // 一秒一拍：同一拍里 `syncController` 可能被多个状态变化叫醒，
        // 但概览的数字只该在整秒上变。0.95 留一点定时器抖动余量。
        if !identityChanged, let last = lastSpeedPublishAt, now.timeIntervalSince(last) < 0.95 { return }
        lastSpeedPublishAt = now
        let overview = meter.overview(now: now)
        publishGatewayOverview(overview, at: now)
        publishGatewayPrefill()
        publishEnginePrefill(stats: stats, isRunning: isRunning)
        publishGatewayTTFT()
        publishGatewayCacheHit(isRunning: isRunning)
        publishGatewayContext(isRunning: isRunning)
        publishAverageDecodeRate(isRunning: isRunning)
        // 曲线落点与冻结完全由网关会话驱动。
        let live = overview.isLive
        let backfilledLatestAt = backfillCompletedStreamSamples(
            at: now, isRunning: isRunning, isLive: live, liveDecodeRate: overview.decodeRate)
        sampleSpeed(at: now, isRunning: isRunning, isLive: live)
        updateChartFreeze(isLive: live, at: now, backfilledLatestAt: backfilledLatestAt)
        let nonStreamed = isRunning && meter.hasOnlyNonStreamedCompletedSessions()
        if chartEmptyIsNonStreamed != nonStreamed { chartEmptyIsNonStreamed = nonStreamed }
    }

    /// 把网关的聚合读数发布成当前速度的两个 `@Published` 值，并盖上时间戳。
    ///
    /// `gatewayReadingAt` 是 owner 表的新鲜度门槛：读数只在真的发布过之后
    /// 才有资格谈年龄。
    private func publishGatewayOverview(_ overview: GatewayMeter.Overview, at now: Date) {
        let changed = gatewayDecodeRate != overview.decodeRate || gatewayRateIsLive != overview.isLive
        if changed {
            gatewayDecodeRate = overview.decodeRate
            gatewayRateIsLive = overview.isLive
        }
        // 时间戳每次同步都盖：读数稳定在同一个值时 `changed` 为 false，
        // 但这一拍仍然是新鲜的。只在数值变化时盖章会把「稳定的高速」
        // 误判成「过旧」，1 秒节拍下尤其明显。
        gatewayReadingAt = now
    }

    /// 发布网关自己算的预填充实测值。它不是「当前速度」，所以不走
    /// `gatewayReadingAt` 的新鲜度门槛：预填充做完就固定了，只是标成 LAST。
    private func publishGatewayPrefill() {
        let next = meter.recentPrefill() ?? 0
        guard abs(gatewayPrefillRate - next) > 0.5 else { return }
        gatewayPrefillRate = next
    }

    /// 发布引擎 1 Hz 上报的预填充速率（预填充进行中为 `.live`，刚做完批次为 `.lastRequest`）。
    /// 让预填充卡片在预填充阶段就能像解码一样每秒刷新，且进入解码后立即可见。
    private func publishEnginePrefill(stats: ServerStats?, isRunning: Bool) {
        let rate: Double
        let kind: EngineRateKind
        if isRunning, let reported = stats?.prefillTokensPerSecond, reported > 0,
            let reportedKind = stats?.prefillRateKind, reportedKind != .none
        {
            rate = reported
            kind = reportedKind
        } else {
            rate = 0
            kind = .none
        }
        guard abs(enginePrefillRate - rate) > 0.5 || enginePrefillKind != kind else { return }
        enginePrefillRate = rate
        enginePrefillKind = kind
    }

    /// 发布网关实测的最近一次首字。与预填充同样是「做完就固定」的观测，
    /// 不走 `gatewayReadingAt` 的新鲜度门槛：它描述的是上一轮等了多久，
    /// 不是「此刻多快」。新一代（换引擎 / 换模型）后读数自然回 0。
    private func publishGatewayTTFT() {
        let next = meter.recentTTFTMilliseconds() ?? 0
        guard abs(gatewayTTFTMilliseconds - next) > 0.5 else { return }
        gatewayTTFTMilliseconds = next
    }

    /// 发布网关按代累计的缓存命中率。与预填充同样不走新鲜度门槛：它描述的是
    /// 最近这批有 usage 的请求，做完就固定，直到下一条 usage 回来才跳一格。
    /// 引擎停下时清回 0 / 0——界面靠 `requests == 0` 区分「没样本」与「0%」。
    private func publishGatewayCacheHit(isRunning: Bool) {
        let next = isRunning ? meter.cacheHit() : nil
        let rate = next?.rate ?? 0
        let requests = next?.requests ?? 0
        guard
            abs(gatewayCacheHitRate - rate) > 0.0001
                || gatewayCacheHitRequests != requests
        else { return }
        gatewayCacheHitRate = rate
        gatewayCacheHitRequests = requests
    }

    /// 发布 HERO 的「模型启动以来平均」。网关累计量为 0 时保留 0，界面会
    /// 去看引擎的 `.lifetimeMean`，两处都没有就画「—」。
    private func publishAverageDecodeRate(isRunning: Bool) {
        let next = isRunning ? (meter.lifetimeAverage() ?? 0) : 0
        guard abs(averageDecodeRate - next) > 0.0001 else { return }
        averageDecodeRate = next
    }

    private func publishGatewayContext(isRunning: Bool) {
        let next = isRunning ? meter.latestContext() : nil
        let tokens = next?.tokens ?? 0
        let isLive = next?.isLive ?? false
        if gatewayContextTokens != tokens { gatewayContextTokens = tokens }
        if gatewayContextIsLive != isLive { gatewayContextIsLive = isLive }
    }

    /// 补记落在两个 1 Hz 采样拍之间的短流式请求。
    ///
    /// 高速本机模型下，一次简短的流式回复往往不足 1 秒：可能完整落在两拍之间，
    /// 也可能第一拍刚好撞上预填充（速率 0）、下一拍已经收尾。只要该流式请求在
    /// 解码区间内尚未被实时拍命中，就按它的收尾时刻与实测解码速率补落一个点；
    /// 长流式请求已由 1 Hz 实时拍覆盖，不重复补点。
    private func backfillCompletedStreamSamples(
        at now: Date,
        isRunning: Bool,
        isLive: Bool,
        liveDecodeRate: Double
    ) -> Date? {
        guard isRunning else { return nil }
        let completed = meter.completedStreamedDecodes(afterSessionID: lastBackfilledSessionID)
        guard !completed.isEmpty else { return nil }
        var latestAppended: Date?
        var appended = false
        for item in completed {
            if item.sessionID > lastBackfilledSessionID {
                lastBackfilledSessionID = item.sessionID
            }
            // 解码区间内已有实时拍就不重复补点；并发长请求正在稳定吐字时，
            // 若紧邻前 1.1 秒内已有实时合并点，也不插入单路速率以免拉出假深谷。
            let windowStart =
                (isLive && liveDecodeRate > 0)
                ? item.startedAt.addingTimeInterval(-1.1)
                : item.startedAt
            let alreadySampled = throughput.contains {
                $0.at >= windowStart && $0.at <= item.finishedAt
            }
            guard !alreadySampled else { continue }
            var stamp = min(item.finishedAt, now)
            while throughput.contains(where: { $0.at == stamp }) {
                stamp = stamp.addingTimeInterval(0.001)
            }
            let sample = ThroughputSample(at: stamp, value: item.rate)
            if let last = throughput.last, stamp < last.at {
                let index = throughput.firstIndex(where: { $0.at > stamp }) ?? throughput.count
                throughput.insert(sample, at: index)
            } else {
                throughput.append(sample)
            }
            appended = true
            if latestAppended.map({ stamp > $0 }) ?? true {
                latestAppended = stamp
            }
        }
        if appended {
            throughput = Self.trimmed(throughput, at: now)
        }
        return latestAppended
    }

    /// 把一次读数落到 60 秒曲线上。只有「在跑」且读数 > 0 时落点：
    /// 静默段不拿 0 去填谷，曲线保留最后一段真实形状；请求收尾由
    /// `updateChartFreeze` 冻结整张图。一拍一个点由调用方的 1 秒闸保证。
    ///
    /// 采样与 `decodeReading` 走同一条 owner 表：整条曲线只含网关的窗口读数
    /// （0 不落点）。引擎的计数器差分不再参与——同一个请求被两套探测各采一次
    /// 只会让曲线忽高忽低，和「最近请求」逐行相加也对不上。
    private func sampleSpeed(at now: Date, isRunning: Bool, isLive: Bool) {
        guard isLive else { return }
        let sample = decodeReading(isRunning: isRunning).value ?? 0
        guard sample > 0 else { return }
        throughput.append(ThroughputSample(at: now, value: sample))
        throughput = Self.trimmed(throughput, at: now)
    }

    /// 草稿接受率的落点：只在「数值真的变了」或「解码读数正在动」的时候记，
    /// 否则每秒都会多一个样本，概览的曲线与读数会无谓刷新。
    private func sampleAcceptance(at now: Date, stats: ServerStats?) {
        guard let latest = stats?.draftAcceptance else { return }
        let shouldSample = Self.shouldSampleAcceptance(
            lastAt: acceptance.last?.at,
            lastValue: acceptance.last?.value,
            latest: latest,
            reportedDecodeRate: gatewayRateIsLive ? gatewayDecodeRate : nil,
            throughputLastValue: throughput.last?.value,
            now: now)
        guard shouldSample else { return }
        acceptance.append(ThroughputSample(at: now, value: latest))
        acceptance = Self.trimmed(acceptance, at: now)
    }

    /// 接受率的三条落点门槛，抽成纯函数给测试钉住：
    /// 0.9 秒的最短采样间隔、1e-4 的「数值真的变了」、0.15 的「解码读数在动」。
    /// `reportedDecodeRate` 是这一拍的当前解码读数（网关在跑会话的合计）；
    /// 它与曲线末端的差超过 0.15 就认为读数在动（因此即使接受率没变也要落点，
    /// 曲线才跟得上）。
    package nonisolated static func shouldSampleAcceptance(
        lastAt: Date?,
        lastValue: Double?,
        latest: Double,
        reportedDecodeRate: Double?,
        throughputLastValue: Double?,
        now: Date
    ) -> Bool {
        let due = lastAt.map { now.timeIntervalSince($0) >= 0.9 } ?? true
        let changed = lastValue.map { abs($0 - latest) > 0.0001 } ?? true
        let rateMoving =
            reportedDecodeRate.map { reported in
                throughputLastValue.map { abs($0 - reported) > 0.15 } ?? true
            } ?? false
        return due && (changed || rateMoving)
    }

    /// 请求全部收尾时把 60 秒曲线冻在收尾时刻；新请求一开始就解冻。
    /// 冻结的是**右缘**（`overviewChartEnd`），不是样本数组：窗口不再随
    /// 挂钟向前滑，曲线也就不会在空闲几分钟后被裁空。
    private func updateChartFreeze(isLive: Bool, at now: Date, backfilledLatestAt: Date? = nil) {
        let next: Date?
        if isLive {
            next = nil
        } else if let backfilledLatestAt {
            // 刚补记了落在两拍之间的短流式请求：把冻结右缘推进到当前拍，
            // 确保新样本留在冻结窗口内，且空闲后不会被挂钟滚出 60 秒窗口。
            next = max(now, backfilledLatestAt)
        } else {
            next = Self.chartFrozenAt(
                previous: throughputFrozenAt,
                wasLive: chartWasLive,
                isLive: false,
                now: now)
        }
        if throughputFrozenAt != next { throughputFrozenAt = next }
        chartWasLive = isLive
    }

    /// 曲线冻结状态的纯逻辑：进行中永远解冻；1 → 0 的那一拍记下收尾时刻；
    /// 一直空闲时不冻结（否则启动即冻，横轴永远停在开机时刻）。
    /// 抽出来是为了在没有窗口的测试里钉住这三条。
    package nonisolated static func chartFrozenAt(
        previous: Date?,
        wasLive: Bool,
        isLive: Bool,
        now: Date
    ) -> Date? {
        if isLive { return nil }
        if let previous { return previous }
        return wasLive ? now : nil
    }

    /// 累计均值的身份 = 引擎 + 进程 + 进程启动时刻 + 模型。任一变化都说明
    /// 换了一台「模型启动以来」，上一台的累计量不该再算进来。
    ///
    /// 首次拿到有效身份（`lifetimeIdentity == nil`）时只登记不翻代：此前没有
    /// 上一台引擎/模型，翻代反而会把随引擎冷启动同时发起的首轮请求划进旧代。
    @discardableResult
    private func syncLifetimeIdentity(stats: ServerStats?, activeEngine: EngineID) -> Bool {
        guard let stats else { return false }
        let uptimeRestarted: Bool
        if let prev = previousUptimeSeconds, let current = stats.uptimeSeconds, current + 1.0 < prev {
            uptimeRestarted = true
        } else {
            uptimeRestarted = false
        }
        previousUptimeSeconds = stats.uptimeSeconds

        let key = [
            activeEngine.rawValue,
            stats.instancePid.map(String.init) ?? "-",
            stats.startedAt.map { String(format: "%.3f", $0) } ?? "-",
            stats.model ?? "-",
        ].joined(separator: "|")
        if lifetimeIdentity == nil {
            lifetimeIdentity = key
            return false
        }
        guard uptimeRestarted || key != lifetimeIdentity else { return false }
        lifetimeIdentity = key
        meter.resetLifetime()
        if averageDecodeRate != 0 { averageDecodeRate = 0 }
        if gatewayPrefillRate != 0 { gatewayPrefillRate = 0 }
        if enginePrefillRate != 0 { enginePrefillRate = 0 }
        if enginePrefillKind != .none { enginePrefillKind = .none }
        if gatewayTTFTMilliseconds != 0 { gatewayTTFTMilliseconds = 0 }
        if gatewayCacheHitRate != 0 { gatewayCacheHitRate = 0 }
        if gatewayCacheHitRequests != 0 { gatewayCacheHitRequests = 0 }
        if gatewayContextTokens != 0 { gatewayContextTokens = 0 }
        if gatewayContextIsLive { gatewayContextIsLive = false }
        if chartEmptyIsNonStreamed { chartEmptyIsNonStreamed = false }
        return true
    }
}
