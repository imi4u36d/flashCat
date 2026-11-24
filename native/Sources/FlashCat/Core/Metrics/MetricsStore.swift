// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Combine
import FlashCatKit
import Foundation

// MARK: - 曲线采样点

struct ThroughputSample: Identifiable {
    /// 用时间戳做身份：每个采样点的时刻天然唯一，没必要为每个点再分配一个
    /// UUID。10 分钟窗口里最多一千多个点，省下的是持续的分配与 16 字节/点。
    var id: Date { at }
    let at: Date
    let value: Double
}

/// 概览速度读数的来源。速度类指标统一走网关按请求打点，避免同一个页面里
/// 引擎的 LIVE / AVG 和网关估算混着用；引擎实时计数只作为兜底。
/// 收尾后的上一请求终值（LAST）不再是一个可用来源：概览只认「此刻在跑」。
enum SpeedOrigin: Equatable {
    /// 没有在跑会话，也没有可用的引擎实时计数：没有当前速度。
    case none
    /// 网关在跑会话的合计速率（重采样后的窗口读数）。窗口读数就是当前速度本身，
    /// 所以活跃期间不区分估算与精确计数——引擎侧的 tok/s 同样是计数器差分的估计。
    case gatewayLive
    /// 网关看不见的直连请求，用引擎的实时计数兜底。
    case engineLive
}

/// 一个指标格当前的**取数来源**。owner 表算出来的就是这个值，界面直接按它
/// 打角标与说明文案，不再各自 switch `EngineRateKind`/`SpeedOrigin`。
///
/// 速度格只认 LIVE：它只回答「此刻多快」，上一请求的终值不参与。预填充格
/// 是唯一的例外——预填充本来就是一次性的，短提示词在 1 秒采样里常常抓不到
/// 正在处理的那一刻，所以它允许把**明确标成 LAST**的最近一次实测值留在卡片上。
/// 这个实测值优先由网关自己按请求算（`.gatewayLast`），引擎的 `.engineLast`
/// 只在网关没有会话记录（客户端绕过网关直连引擎端口）时兜底。平均解码速度
/// 单独有 `.gatewayMean` / `.engineMean` 这一档，只服务 hero 的「模型启动以来平均」。
enum MetricOrigin: Equatable {
    /// 没有任何可用读数（引擎未上报、或值 ≤ 0）。
    case none
    /// 网关按请求打点的实时读数（重采样窗口）。
    case gatewayLive
    /// 网关按请求打点算出的最近一次预填充实测值。
    case gatewayLast
    /// 网关按会话累计的「模型启动以来平均」——hero 的解码均值与缓存命中率共用。
    case gatewayMean
    /// 引擎此刻正在量的实时值。
    case engineLive
    /// 引擎测过的上一请求值：数字是真的，描述的是刚结束的那一次。
    case engineLast
    /// 引擎进程 / 会话累计均值。
    case engineMean
}

/// 一格指标的 owner 表输出：数值 + 它回答的是哪个问题。
/// `value == nil` 时 `origin == .none`，界面画「—」。
struct MetricReading: Equatable {
    let value: Double?
    let origin: MetricOrigin

    static let none = MetricReading(value: nil, origin: .none)
}

/// 首字延迟格的取数结果：数值 + 它来自哪一侧的观测。
///
/// 首字和预填充一样是一次性观测，但它没有 `MetricOrigin` 那套速度语义：
/// 引擎 status 里有样本时优先（splash 给 p50，mlx-serve 给直方图均值，
/// MTPLX 给上一请求值），引擎没有这个字段（oMLX）或还没有样本
/// （splash 首个请求前 p50 = 0）时，退回网关逐请求量到的最近一次首字。
/// 两侧都没有才是 「—」。
struct TTFTReading: Equatable {
    enum Source: Equatable {
        /// 没有任何首字样本。
        case none
        /// 引擎 status 上报的首字统计。
        case engine
        /// 网关按请求实测的最近一次首字。
        case gateway
    }

    let milliseconds: Double?
    let source: Source
    let kind: EngineTTFTKind

    init(milliseconds: Double?, source: Source, kind: EngineTTFTKind = .none) {
        self.milliseconds = milliseconds
        self.source = source
        self.kind = kind
    }

    static let none = TTFTReading(milliseconds: nil, source: .none, kind: .none)
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
final class MetricsStore: ObservableObject {
    // MARK: 曲线样本
    //
    // 曲线样本只服务概览 60 秒与菜单栏近 5 分钟；保留 10 分钟足够，
    // 以前留 30 分钟，多出来的两三千个点没有任何界面读。
    /// `nonisolated`：窗口裁剪在纯静态函数里做，测试要能不等主线程直接调用。
    nonisolated private static let sampleRetention: TimeInterval = 600

    /// 概览总解码曲线的样本。速度统一取网关按请求打点的聚合；网关没有
    /// 在跑会话时，只收引擎的实时计数（且引擎必须有在跑请求），引擎的
    /// LAST/AVG 不再被画成时间序列。
    @Published private(set) var throughput: [ThroughputSample] = []
    /// 草稿接受率（DFlash2 / MTP）的时间序列，采样节奏与吞吐一致，
    /// 概览页用它画第二条实时曲线。value 是 0…1 的比例。
    @Published private(set) var acceptance: [ThroughputSample] = []

    // MARK: 网关聚合读数
    //
    // 预填充不再由应用自己按「整段提示词 / 首字耗时」估算。同一会话的第二轮
    // 几乎全部命中前缀缓存，分子里的 token 大部分根本没被前向，TTFT 里还混着
    // 排队和缓存恢复，两者一除能把读数放大两个数量级。现在只显示引擎真的
    // 量过的数：mlx-serve 用 prefill_tokens_total / prefill_time_seconds
    //（都不含缓存恢复），其余引擎用它自己的 prefill 字段；引擎没有时回落到
    // 网关的按请求打点。
    /// 网关按请求打点的聚合速率。概览曲线与「最近请求」同源，
    /// 应用内对话也注册在 `GatewayMeter` 里。收尾后归零：只表示「此刻多快」。
    @Published private(set) var gatewayDecodeRate: Double = 0
    /// `gatewayDecodeRate` 是否来自在跑会话。false = 没有在跑会话（或引擎
    /// 已经收尾），此时没有当前速度，读数不挂上一请求的终值。
    @Published private(set) var gatewayRateIsLive = false
    /// 网关自己量出来的预填充速度（最近一次完成的预填充）。分子是 usage
    /// 报告的提示词 token 减去前缀缓存命中量，分母是请求发出到首 token 的
    /// 墙钟——不读任何引擎自报的预填充字段，所以换引擎不会让这格变空。
    /// 0 = 还没有可用的实测值。
    @Published private(set) var gatewayPrefillRate: Double = 0
    /// 网关自己量出来的最近一次首字耗时（毫秒）。引擎 status 里没有 TTFT
    /// （oMLX），或还没有样本（splash 首个请求前 p50 = 0）时，
    /// 首字格退到这条按请求的实测值。0 = 还没有可用的实测值。
    @Published private(set) var gatewayTTFTMilliseconds: Double = 0
    /// 网关按代累计的缓存命中率（0…1）。分子是 usage 里的前缀缓存命中量，
    /// 分母是同一批请求的提示词总量（按 token 加权）；只统计真的收到 usage
    /// 的请求。0 = 还没有样本，界面不能把它当成「0% 命中」。
    @Published private(set) var gatewayCacheHitRate: Double = 0
    /// 上面这个读数覆盖的请求数，卡片的说明文案会原样引用它。
    @Published private(set) var gatewayCacheHitRequests: Int = 0
    /// 模型启动以来的平均解码速度（网关按会话累计）。hero 大数字读它：
    /// 曲线回答「此刻多快」，大数字回答「这台模型平均吐字多快」。0 = 还没有
    /// 可算的样本，界面画「—」。
    @Published private(set) var averageDecodeRate: Double = 0
    /// 网关侧最近/在跑会话的上下文占用 tokens（含外部客户端与网关流量）。
    @Published private(set) var gatewayContextTokens: Int = 0
    @Published private(set) var gatewayContextIsLive: Bool = false
    /// 60 秒曲线冻结的时刻。请求收尾后设为收尾时刻，`overviewThroughput`
    /// 与横轴都以它为右缘——曲线停住，不再随挂钟把终点挤出窗口。
    /// 新请求开始时清空，曲线恢复滚动。
    @Published private(set) var throughputFrozenAt: Date?

    // MARK: 私有状态
    /// 上一次采样时是否还有请求在跑，用来识别「1 → 0」这次收尾。
    private var chartWasLive = false
    /// 累计均值的身份（引擎 + 进程 + 模型）。换代时清空 `GatewayMeter`
    /// 的累计量，避免把上一台模型的成绩算进这一台。
    private var lifetimeIdentity: String?
    /// 上一次观察到的引擎运行秒数，用于在没有 pid/startedAt 时检测重启。
    private var previousUptimeSeconds: Double?
    /// 生成期间的连续时间低通速率估计。不再用「攒够 0.9 秒就清零」的窗口：
    /// 那种非重叠窗口让相邻读数互不相关，SSE 分片一抖数字就跟着跳。
    /// 只服务对话页直播条——概览按每秒一拍读网关，不在分片回调里改。
    private var decodeMeter = DecodeRateMeter()
    /// 概览速度读数的上一拍。`syncController` 会被引擎的多次状态变化触发，
    /// 不加闸就会在一秒内发布好几次——概览的刻钟是 1 秒，不是事件驱动。
    private var lastSpeedPublishAt: Date?
    /// 解码速度读数与它自己的时间基之间的最大跨度。超过这个跨度，重采样器
    /// 的窗口就覆盖不到调用方所在的时间——这个读数就不再回答「此刻多快」，
    /// 降级为「没有当前速度」，让引擎 LIVE 计数补位。
    nonisolated private static let rateReadingFreshness: TimeInterval = 2.0
    /// `gatewayDecodeRate` 最后一次刷新的时刻，用于 `decodeReading` 的新鲜度
    /// 门槛。只在主线程读写。
    private var gatewayReadingAt: Date?
    /// 打点的真相源。生产只传 `.shared`（网关自己登记会话的那一份）；
    /// 测试传独立实例，免得读到其他测试或应用内对话留下的会话。
    private let meter: GatewayMeter

    init(meter: GatewayMeter = .shared) {
        self.meter = meter
    }

    // MARK: 指标 owner 表
    //
    // 每个指标格只有一个 owner，owner 缺席时才走声明好的降级链。以前同一个页面
    // 里 hero 走网关、预填充格走引擎、灵动岛又是引擎优先，两处数字天然对不上；
    // 现在所有界面（概览 / 灵动岛 / 菜单栏）都从下面这几个函数取数，一格一个
    // 来源、一个粒度，角标与说明文案由 `MetricOrigin` 直接给出。
    //
    // 分工的物理边界：网关只看得见流里的东西（分片节奏、TTFT、请求合计、
    // usage 里的缓存命中量），队列深度、KV 驻留、显存、草稿接受率这些只有引擎
    // 量得到。速度类指标 owner = 网关；引擎实时计数只在网关没有会话在跑时兜底
    //（客户端直连引擎端口），LAST/AVG 永远不参与当前速度。

    /// 解码格的 owner 表输出：`speedOrigin` 的判定 + 它的值，永远同源。
    /// 概览曲线与菜单栏的「当前解码速度」都读它；收尾后归零，不挂 LAST。
    func decodeReading(stats: ServerStats?, isRunning: Bool) -> MetricReading {
        Self.reading(
            origin: currentSpeedOrigin(stats: stats, isRunning: isRunning),
            gateway: gatewayDecodeRate,
            engine: stats?.decodeTokensPerSecond)
    }

    nonisolated static func reading(
        origin: SpeedOrigin,
        gateway: Double,
        engine: Double?
    ) -> MetricReading {
        switch origin {
        case .gatewayLive: return MetricReading(value: gateway, origin: .gatewayLive)
        case .engineLive: return MetricReading(value: engine, origin: .engineLive)
        case .none: return .none
        }
    }

    /// HERO 大数字：模型启动以来的平均解码速度，而不是曲线的实时值。
    ///
    /// 优先用网关按会话结算的累计量（覆盖所有经过网关的请求，含应用内对话）；
    /// 没有网关样本时退回引擎自己的 `.lifetimeMean`。两者都不是当前速度，
    /// 所以 `origin` 是 `gatewayMean` / `engineMean`，界面打 `AVG`。
    func averageDecodeReading(stats: ServerStats?, isRunning: Bool) -> MetricReading {
        guard isRunning else { return .none }
        if averageDecodeRate > 0 {
            return MetricReading(value: averageDecodeRate, origin: .gatewayMean)
        }
        if let lifetime = stats?.lifetimeDecodeTokensPerSecond, lifetime > 0 {
            return MetricReading(value: lifetime, origin: .engineMean)
        }
        if stats?.decodeRateKind == .lifetimeMean,
            let engine = stats?.decodeTokensPerSecond, engine > 0
        {
            return MetricReading(value: engine, origin: .engineMean)
        }
        return .none
    }

    /// 菜单栏解码格：有实时读数就报实时，空闲时退回「模型启动以来平均」。
    /// 面板只有一格，不能像概览那样把实时曲线和大数字分开摆——空闲时那格
    /// 若空着，读者会以为测速坏了。退回的值带着 `.gatewayMean` / `.engineMean`
    /// 的 origin，面板据此打 `AVG` 角标，不把平均值冒充成此刻速度。
    func menuBarDecodeReading(stats: ServerStats?, isRunning: Bool) -> MetricReading {
        let live = decodeReading(stats: stats, isRunning: isRunning)
        guard live.value == nil else { return live }
        return averageDecodeReading(stats: stats, isRunning: isRunning)
    }

    /// 预填充格的 owner 表输出。
    ///
    /// 预填充是一次性动作，短提示词（几百 token）在 1 秒采样里几乎抓不到
    /// 引擎的 `in_flight` 实时窗口；换一台引擎，引擎自报字段的名字和粒度还会
    /// 整个变掉。所以 LAST 这一档走**按请求的实测值**：引擎在响应里自报的
    /// `timings`（`prompt_n − cached_n` / `prompt_ms`，流式与非流式都带）优先，
    /// 没有它才退回网关自己算的 TTFT 口径（分子是 usage 里的提示词 token 减去
    /// 前缀缓存命中量，分母是请求发出到首 token 的墙钟，只对流式响应成立）。
    /// 只有「此刻真的在预填充」才用引擎的 `.live`（那时网关还没有首 token），
    /// 其余时间按请求的实测值优先，引擎的 LAST/AVG 只在网关没有会话记录时兜底。
    ///
    /// 预填充**没有**网关侧聚合：网关的「(整段提示词 − 缓存命中) / 首字耗时」
    /// 口径已废弃（分母混着排队与缓存恢复，分子要等末帧 usage），概览只显示
    /// 引擎自报的速率。`GatewayMeter` 仍为「最近请求」逐行保留各自的预填充读数。
    func prefillReading(stats: ServerStats?, isRunning: Bool) -> MetricReading {
        guard isRunning else { return .none }
        return Self.prefillReading(
            gateway: gatewayPrefillRate,
            engine: stats?.prefillTokensPerSecond,
            engineKind: stats?.prefillRateKind ?? .none)
    }

    /// 预填充格的完整 owner 顺序：就地预填充（引擎 LIVE）→ 网关实测 LAST →
    /// 引擎 LAST / AVG。抽成纯函数，测试可以钉住优先级。
    nonisolated static func prefillReading(
        gateway: Double,
        engine: Double?,
        engineKind: EngineRateKind = .none
    ) -> MetricReading {
        let engineReading = prefillReading(engine: engine, engineKind: engineKind)
        // 实时预填充只有引擎量得到：这时网关连首 token 都还没拿到。
        if engineReading.origin == .engineLive { return engineReading }
        if gateway > 0 { return MetricReading(value: gateway, origin: .gatewayLast) }
        return engineReading
    }

    /// 引擎自报速率的翻译层，不含网关。保留给测试和网关缺席时的兜底。
    nonisolated static func prefillReading(
        engine: Double?,
        engineKind: EngineRateKind = .none
    ) -> MetricReading {
        guard let engine, engine > 0 else { return .none }
        switch engineKind {
        case .live:
            return MetricReading(value: engine, origin: .engineLive)
        case .lastRequest:
            return MetricReading(value: engine, origin: .engineLast)
        case .lifetimeMean:
            return MetricReading(value: engine, origin: .engineMean)
        case .none:
            return .none
        }
    }

    /// 首字延迟格的 owner 表输出：引擎 status → 网关最近一次实测 → 没有。
    ///
    /// 引擎的 TTFT 统计是首选：它有样本时覆盖所有经过引擎的请求，splash 还给
    /// 的是 p50。但它不是每家都有——oMLX 的 status 没有这个字段，
    /// splash 在首个请求之前报 0——这时退到网关逐请求量到的首字（应用内对话
    /// 也注册在网关里）。两侧都没有才画「—」：0 不是「首字很快」。
    func ttftReading(stats: ServerStats?, isRunning: Bool) -> TTFTReading {
        guard isRunning else { return .none }
        return Self.ttftReading(
            engine: stats?.ttftMilliseconds,
            engineKind: stats?.ttftKind ?? .none,
            gateway: gatewayTTFTMilliseconds)
    }

    /// 首字格的 owner 顺序，抽成纯函数给测试钉住。引擎值必须 > 0 才算样本；
    /// 网关值是「最近一次真的量到首字」的请求，同样 > 0 才可用。
    nonisolated static func ttftReading(
        engine: Double?,
        engineKind: EngineTTFTKind = .none,
        gateway: Double
    ) -> TTFTReading {
        if let engine, engine > 0 {
            return TTFTReading(milliseconds: engine, source: .engine, kind: engineKind)
        }
        if gateway > 0 {
            return TTFTReading(milliseconds: gateway, source: .gateway, kind: .lastRequest)
        }
        return .none
    }

    /// 缓存命中率格的 owner 表输出。
    ///
    /// 主口径是网关按代累计的「命中量 / 提示词总量」（按 token 加权）：它和
    /// 其他格一样按请求打点，覆盖应用内对话与所有经过网关的客户端，也不依赖
    /// 任何一家引擎自报字段——换引擎不会让这格变空。网关一个带 usage 的请求
    /// 都没有时（客户端绕过网关直连引擎端口），退回引擎自己报的开机以来
    /// 命中率：mlx-serve / MTPLX 的 `cached / prompt` 两个累计计数器、oMLX 的
    /// `total_cached_tokens / total_prompt_tokens`。两个口径都是累计平均，
    /// 所以角标只有 `AVG`；没有样本时画「—」，不拿 0% 冒充「一次都没命中」。
    func cacheHitReading(stats: ServerStats?, isRunning: Bool) -> MetricReading {
        guard isRunning else { return .none }
        return Self.cacheHitReading(
            gateway: gatewayCacheHitRate,
            requests: gatewayCacheHitRequests,
            engine: stats?.cacheHitRate)
    }

    /// 缓存命中率的 owner 顺序：网关按代累计 → 引擎开机以来。抽成纯函数，
    /// 测试可以钉住「网关样本优先」与「0% 是合法读数、没样本才是 —」。
    nonisolated static func cacheHitReading(
        gateway: Double,
        requests: Int,
        engine: Double?
    ) -> MetricReading {
        if requests > 0, gateway >= 0, gateway <= 1 {
            return MetricReading(value: gateway, origin: .gatewayMean)
        }
        if let engine, engine >= 0, engine <= 1 {
            return MetricReading(value: engine, origin: .engineMean)
        }
        return .none
    }

    /// 速度来源的判定。抽成纯函数，测试可以钉住「引擎 LIVE 不能压过网关」、
    /// 「引擎 LAST/AVG 不算当前速度」「空闲不显示旧值」「读数过旧降级」。
    /// `gatewayIsLive == false` 时网关值一律不参与——没有 LAST 这种"降级"。
    nonisolated static func speedOrigin(
        gateway: Double,
        gatewayIsLive: Bool = true,
        engine: Double?,
        engineKind: EngineRateKind = .none,
        activeRequests: Int = 0,
        gatewayAge: TimeInterval? = nil
    ) -> SpeedOrigin {
        if gateway > 0, gatewayIsLive,
            gatewayAge.map({ $0 <= rateReadingFreshness }) ?? true
        {
            return .gatewayLive
        }
        if engineKind == .live, let engine, engine > 0, activeRequests > 0 {
            return .engineLive
        }
        return .none
    }

    /// `speedOrigin` 的界面可见口径：带上主线程那份 `gatewayDecodeRate` 的年龄。
    func currentSpeedOrigin(stats: ServerStats?, isRunning: Bool) -> SpeedOrigin {
        guard isRunning else { return .none }
        return Self.speedOrigin(
            gateway: gatewayDecodeRate,
            gatewayIsLive: gatewayRateIsLive,
            engine: stats?.decodeTokensPerSecond,
            engineKind: stats?.decodeRateKind ?? .none,
            activeRequests: stats?.activeRequests ?? 0,
            gatewayAge: gatewayReadingAt.map(Date().timeIntervalSince))
    }

    // MARK: 曲线窗口

    /// 概览 60 秒曲线的右缘：请求收尾后冻结在收尾时刻，新请求开始后恢复
    /// 跟随挂钟。hero 不再有 sparkline，只有概览曲线读这个口径。
    var overviewChartEnd: Date { throughputFrozenAt ?? Date() }

    /// 概览曲线样本。冻结后只取到 `throughputFrozenAt`，不会随着窗口
    /// 继续滚动而把曲线抽空。
    func overviewThroughput(window: TimeInterval) -> [ThroughputSample] {
        guard window > 0 else { return throughput }
        return Self.suffix(of: throughput, window: window, endingAt: overviewChartEnd)
    }

    /// 概览用 60 秒、菜单栏用近 5 分钟；序列保留 10 分钟，留一点余量。
    /// 菜单栏的 sparkline 不冻结，所以这里仍以当前时刻为右缘。
    func recentThroughput(window: TimeInterval) -> [ThroughputSample] {
        guard window > 0 else { return throughput }
        return Self.suffix(of: throughput, window: window, endingAt: Date())
    }

    /// 序列按时间升序排列，用二分找窗口起点；概览每秒都会为几张图各取一次，
    /// 全表 `filter` 在千余个样本上没有必要。`endingAt` 是窗口右缘：冻结的
    /// 曲线传收尾时刻，右缘之后（理论上没有）的迟到样本一并排除。
    /// 抽成 `internal` 纯函数，测试可以绕开窗口直接钉住窗口边界。
    nonisolated static func suffix(
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
    nonisolated static func trimmed(_ samples: [ThroughputSample], at now: Date) -> [ThroughputSample] {
        let cutoff = now.addingTimeInterval(-sampleRetention)
        return samples.filter { $0.at >= cutoff }
    }

    // MARK: 每秒节拍

    /// 指标的唯一节拍：发布网关读数、落一个 1 秒曲线点、判断是否该冻结曲线，
    /// 并同频采样草稿接受率。
    ///
    /// 只由 `AppState.syncController` 调用——它已经是全应用唯一的一秒节拍源
    /// （引擎轮询 1 秒）。应用内对话的分片回调只喂对话页直播条，不再顺带刷新
    /// 概览，也不在这里事件驱动地重发布。
    func tick(
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
        // 一秒一拍：同一拍里 `syncController` 可能被多个状态变化叫醒，
        // 但概览的数字只该在整秒上变。0.95 留一点定时器抖动余量。
        if let last = lastSpeedPublishAt, now.timeIntervalSince(last) < 0.95 { return }
        lastSpeedPublishAt = now
        // 累计均值的身份先对齐：引擎 / 进程 / 模型换代时清空上一台的成绩。
        syncLifetimeIdentity(stats: stats, activeEngine: activeEngine)
        let overview = meter.overview(now: now)
        publishGatewayOverview(overview, at: now)
        publishGatewayPrefill()
        publishGatewayTTFT()
        publishGatewayCacheHit(isRunning: isRunning)
        publishGatewayContext(isRunning: isRunning)
        publishAverageDecodeRate(isRunning: isRunning)
        // 直连引擎端口的请求网关看不见：引擎自己报的 activeRequests 也算
        // 「还有东西在跑」，Chart 不该在它跑完之前冻结。
        let live = overview.isLive || (stats?.activeRequests ?? 0) > 0
        sampleSpeed(at: now, stats: stats, isRunning: isRunning, isLive: live)
        updateChartFreeze(isLive: live, at: now)
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

    /// 把一次网关读数落到 60 秒曲线上。只有「在跑」且读数 > 0 时落点：
    /// 静默段不拿 0 去填谷，曲线保留最后一段真实形状；请求收尾由
    /// `updateChartFreeze` 冻结整张图。一拍一个点由调用方的 1 秒闸保证。
    private func sampleSpeed(at now: Date, stats: ServerStats?, isRunning: Bool, isLive: Bool) {
        guard isLive else { return }
        let sample = decodeReading(stats: stats, isRunning: isRunning).value ?? 0
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
            reportedDecodeRate: stats?.decodeTokensPerSecond,
            throughputLastValue: throughput.last?.value,
            now: now)
        guard shouldSample else { return }
        acceptance.append(ThroughputSample(at: now, value: latest))
        acceptance = Self.trimmed(acceptance, at: now)
    }

    /// 接受率的三条落点门槛，抽成纯函数给测试钉住：
    /// 0.9 秒的最短采样间隔、1e-4 的「数值真的变了」、0.15 的「解码读数在动」。
    /// `reportedDecodeRate` 是引擎自报的 tok/s；它与曲线末端的差超过 0.15 就
    /// 认为读数在动（因此即使接受率没变也要落点，曲线才跟得上）。
    nonisolated static func shouldSampleAcceptance(
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
    private func updateChartFreeze(isLive: Bool, at now: Date) {
        let next = Self.chartFrozenAt(
            previous: throughputFrozenAt,
            wasLive: chartWasLive,
            isLive: isLive,
            now: now)
        if throughputFrozenAt != next { throughputFrozenAt = next }
        chartWasLive = isLive
    }

    /// 曲线冻结状态的纯逻辑：进行中永远解冻；1 → 0 的那一拍记下收尾时刻；
    /// 一直空闲时不冻结（否则启动即冻，横轴永远停在开机时刻）。
    /// 抽出来是为了在没有窗口的测试里钉住这三条。
    nonisolated static func chartFrozenAt(
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
    private func syncLifetimeIdentity(stats: ServerStats?, activeEngine: EngineID) {
        guard let stats else { return }
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
        guard uptimeRestarted || key != lifetimeIdentity else { return }
        lifetimeIdentity = key
        meter.resetLifetime()
        if averageDecodeRate != 0 { averageDecodeRate = 0 }
        if gatewayPrefillRate != 0 { gatewayPrefillRate = 0 }
        if gatewayTTFTMilliseconds != 0 { gatewayTTFTMilliseconds = 0 }
        if gatewayCacheHitRate != 0 { gatewayCacheHitRate = 0 }
        if gatewayCacheHitRequests != 0 { gatewayCacheHitRequests = 0 }
        if gatewayContextTokens != 0 { gatewayContextTokens = 0 }
        if gatewayContextIsLive { gatewayContextIsLive = false }
    }

    // MARK: 对话页直播条

    /// 流式回复的本地测速：每个增量按小数权重累进到连续时间估计器里。
    ///
    /// liveDecodeRate 迁出后这条估计器的**速率**已无读者，留下的是两个累计量：
    /// usage 缺席时消息下方的 tok/s（分母取首分片→末分片的真实解码时长，不把
    /// TTFT 混进来）与生成期间的上下文占用估算。喂入因此不能按节流丢片——
    /// 丢了总量和时长都会偏小；概览的曲线与大数字走统一的 1 秒节拍读网关。
    func recordStreamDelta(_ piece: String, at event: Date) {
        let tokens = TokenEstimator.fractional(piece)
        guard tokens > 0 else { return }
        // 用分片真正到达的时刻，而不是主线程排到这一条任务的时刻。UI 忙时
        // 一批回调会被挤在一起处理，若在此时取 `Date()`，估计器会以为几十个
        // token 是「瞬间」吐出来的，读数被抬出一个尖峰。
        decodeMeter.add(tokens: tokens, at: event)
    }

    /// 本轮生成累计的（小数权重）token 数：usage 缺席时消息的 token 数、
    /// 生成期间的上下文占用估算都读它。
    var streamTotalTokens: Double { decodeMeter.totalTokens }

    /// 本轮生成真正观测到解码的时长（首分片 → 末分片）：消息下方的平均
    /// tok/s 拿它当分母，不把 TTFT / 预填充混进来。
    var streamDecodingSeconds: TimeInterval { decodeMeter.decodingSeconds }

    /// 新一轮生成开始时清空低通估计器，不然上一轮的尾巴会被算进这一轮。
    func resetStreamMeter() {
        decodeMeter.reset()
    }
}
