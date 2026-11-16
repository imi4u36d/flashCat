import Foundation

/// 网关打点用到的只读值类型。
///
/// 这些形状原先嵌在 App target 的 `GatewayMeter` 里：CLI（`status --json` 的会话
/// 视图）与 Kit 里的其它聚合代码都要读同一批读数，形状留在 App 就谁也拿不到。
/// 放进 Kit 后只有 App 与 CLI 之外的第三份定义才需要重写——这里只依赖 Foundation。

/// 引擎在响应里自报的逐请求耗时（llama.cpp 口径的 `timings`）。
///
/// mlx-serve 在流式末片和非流式正文里都带这一块：`prompt_n` / `cached_n` /
/// `prompt_ms` 与 `predicted_n` / `predicted_ms`。它是唯一能同时覆盖两种
/// 传输的诚实来源——非流式响应的正文一口气回来，网关连「首字」都看不到，
/// 只靠到达时刻只能量出 0.35 秒的下限，那是虚构的速度（14K token 的回答
/// 会被读成 37 769 tok/s）。没有 `timings` 的引擎照旧走网关自己的分片
/// 计时，两条路都不猜。
public struct GatewayRequestTimings: Equatable, Sendable {
    public var promptTokens: Int
    public var cachedTokens: Int
    public var promptMilliseconds: Double
    public var predictedTokens: Int
    public var predictedMilliseconds: Double

    /// 测试与 App 侧的 `noteTimings` 都直接构造它，所以初始化器必须是 public：
    /// 结构体的 memberwise init 默认是 internal，跨模块调不到。
    public init(promptTokens: Int,
                cachedTokens: Int,
                promptMilliseconds: Double,
                predictedTokens: Int,
                predictedMilliseconds: Double) {
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
        self.promptMilliseconds = promptMilliseconds
        self.predictedTokens = predictedTokens
        self.predictedMilliseconds = predictedMilliseconds
    }

    /// 预填充读数的最小样本量（真正前向的 token）。
    ///
    /// 命中前缀缓存后往往只剩几十个 token 要算，耗时被缓存恢复的固定开销主导
    /// （实测 2195 个 token 里缓存 2164，31 个前向摊 92 ms → 334 tok/s）。
    /// 那个数字既不是这台机器算提示词的速度，也不是缓存的速度，报出来只是
    /// 让人怀疑整块指标。低于这个量就当这一路没有可读的预填充。
    public static let prefillSampleTokens = 128

    /// 真正前向过的提示词 token。命中缓存的那部分只是被搬回来，没有算。
    public var forwardedTokens: Int { max(0, promptTokens - cachedTokens) }

    /// 逐请求预填充吞吐。
    ///
    /// 样本太小就不报：命中缓存后只剩几十个 token 的前向，耗时由缓存恢复
    /// 的固定开销主导（实测 2195 个 token 里缓存 2164，31 个前向摊 92 ms =
    /// 334 tok/s），那既不是这台机器算提示词的速度，也不是缓存的速度。
    public var prefillRate: Double? {
        guard forwardedTokens >= GatewayRequestTimings.prefillSampleTokens,
              promptMilliseconds >= 25 else { return nil }
        let rate = Double(forwardedTokens) / (promptMilliseconds / 1000)
        guard rate.isFinite, rate > 0 else { return nil }
        return rate
    }

    /// 逐请求解码吞吐。分子分母都只算「真正生成」的那一段，不含预填充、
    /// 排队与网络。一个 token 的回答也报不出速度，同样不猜。
    public var decodeRate: Double? {
        guard predictedTokens >= 2, predictedMilliseconds >= 20 else { return nil }
        let rate = Double(predictedTokens) / (predictedMilliseconds / 1000)
        guard rate.isFinite, rate > 0 else { return nil }
        return rate
    }
}

/// 概览大数字与总解码曲线要的是「所有请求合起来」的读数，而不是某一路。
/// 各引擎的实时速率口径不一（最近批次 / 滚动均值 / 累计均值），只有网关
/// 能按请求给出同一时间基的读数；`GatewaySessionMeter` 把各会话的窗口估计器
/// 相加，曲线和「最近请求」逐行才能真正对上。
public struct GatewayMeterOverview: Sendable {
    public let decodeRate: Double
    /// true = 至少还有一个没收尾的会话。收尾即 false——概览不再挂
    /// LAST 终值，曲线也在这一刻冻结。
    public let isLive: Bool

    /// 只在同一个模块里由聚合逻辑构造，跨模块的调用方只读，所以不需要 public init。
    init(decodeRate: Double, isLive: Bool) {
        self.decodeRate = decodeRate
        self.isLive = isLive
    }
}

/// 一次缓存命中率的汇总。
public struct GatewayCacheHitSample: Equatable, Sendable {
    /// 0…1，按 token 加权（不是各请求命中率的算术平均）。
    public let rate: Double
    /// 参与汇总的请求数：都有 usage，都报了提示词量。
    public let requests: Int

    init(rate: Double, requests: Int) {
        self.rate = rate
        self.requests = requests
    }
}

/// 一条请求的只读快照。用结构体而不是 `[String: Any]`：概览每秒刷新一次，
/// 字典装箱、字符串键和 `as?` 转换都是白花的分配；字段固定后 UI 也不会
/// 因为拼错键悄悄拿到 0。
public struct GatewaySessionSnapshot: Sendable {
    public enum State: String, Sendable {
        case prefill, decode, done, failed
    }

    public let id: Int
    public let model: String
    public let dialect: String
    public let state: State
    public let elapsed: TimeInterval
    public let ttftMilliseconds: Double?
    public let promptTokens: Int
    public let completionTokens: Int
    public let decodeRate: Double
    /// 网关侧的逐请求预填充估算，仅作行内诊断；概览卡读 `recentPrefill()`，
    /// 两者共用同一套分子分母。
    public let prefillRate: Double
    public let ctxTokens: Int

    /// 由 `snapshot(limit:now:)` 在同一个模块内构造，外部只读。
    init(id: Int,
         model: String,
         dialect: String,
         state: State,
         elapsed: TimeInterval,
         ttftMilliseconds: Double?,
         promptTokens: Int,
         completionTokens: Int,
         decodeRate: Double,
         prefillRate: Double,
         ctxTokens: Int) {
        self.id = id
        self.model = model
        self.dialect = dialect
        self.state = state
        self.elapsed = elapsed
        self.ttftMilliseconds = ttftMilliseconds
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.decodeRate = decodeRate
        self.prefillRate = prefillRate
        self.ctxTokens = ctxTokens
    }
}
