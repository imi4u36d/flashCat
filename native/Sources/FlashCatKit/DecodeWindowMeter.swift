import Foundation

/// 按墙钟窗口计量的解码速率估计器，单位 tok/s。纯值类型，时间由调用方注入。
///
/// 与 `DecodeRateMeter`（连续时间低通）的分工：低通是**事件节奏**的读数，
/// 输出随取样时刻连续衰减——0.5s 的分片间隙掉 18%，1Hz/0.4s 轮询把加热、
/// 冷却的中间态原样读出来，谷—峰交替就是概览页「解码速度闪烁」的本体。
/// 这里把口径换成**窗口**：「窗 `[t−W, t]` 里到了多少 token，摊在多长的
/// 已观测跨度上」。稳态恒等于吞吐——分子分母一起滑，分片边界、批量
/// 大小、轮询相位都不进读数；真变速一两拍内跟上。
///
/// 收尾的形状是设计的一部分：最后一个分片之后**保持**一个完整窗
/// （悬崖把曲线砸成深 V），再**线性遗忘**一个窗归零（指数尾会挂着
/// 半旧值冒充当前速度——上一代低通的另一个病）。归零之后由
/// `GatewayMeter.overview` 的 LAST 宽限接管，界面角标负责说真话。
///
/// 窗口右缘**钳到最后一个事件**（`t = min(now, last)`）：读数是对已到达
/// 分片的答案，与「谁什么时候来读」无关——秒拍与 0.4s 快拍共用同一个
/// `@Published` 读数也不会错开，早读几十毫秒不会把窗口掏空成 0（那是
/// 把闪烁换了个方向）。静默的真相由**取样时刻** `now` 走保持段与遗忘段
/// （`[W, 2W]`）说出。
public struct DecodeWindowMeter {
    /// 本轮最后一个 token 的到达时刻：聚合层用它判断「此刻是否还在吐字」
    /// （`finishedAt == nil` 只说明请求还没收尾，不等于这一拍有输出）。
    private var lastArrival: Date?
    private var firstArrival: Date?
    /// 累计估算 token 数（含 reasoning），用于没有 usage 时给消息兜底。
    public private(set) var totalTokens: Double = 0

    /// 墙钟到达事件 `(时刻, token 数)`，按到达升序。有界：按事件年龄
    /// 裁剪（`arrivalCapacitySeconds`），超龄的最老事件弹出——它们早已
    /// 在任何合法读数的边缘之外。
    private struct Arrival {
        let at: Date
        let tokens: Double
    }
    private var arrivals: [Arrival] = []

    /// 窗口长度 W，也是保持段的宽度与遗忘坡的单位。0.5s：一个 poll
    /// 间隔（1s）的一半、预填充快拍（0.4s）的整倍；收尾缓坡总长
    /// 2W = 1.0s，短于 `GatewayMeter` 的 LAST 宽限（1.2s），hero 交接
    /// 落在零位上。
    public let window: TimeInterval
    /// 分母下限：起步期（观测跨度 < W）的读数至少按 `minimumElapsed`
    /// 摊——单 token = 1/0.35 ≈ 2.9，是「一个分片的最小可观测速率」，
    /// 既不是尖峰也不是装死。`averageRate` 的跨度同样有它兜底。
    public let minimumElapsed: TimeInterval
    /// 事件保留上限（秒）：读数最远用到 `last − 2W`（遗忘坡底）。
    /// 单位是**时间**不是条数——旧版拿 `window * 8` 当条数上限（W=1 →
    /// 8 个事件），100 tok/s 的流一个窗口只剩 8 个 token，读数被掏空成
    /// 18；时间上限在任何流量下都保住窗口里的量，数组由分片率自然
    /// 有界（1000 片/s × 4s ≈ 4000 点，几十 KB 封顶）。
    private let arrivalCapacitySeconds: Double

    public init(window: TimeInterval = 0.5, minimumElapsed: TimeInterval = 0.35) {
        self.window = max(0.2, window)
        self.minimumElapsed = max(0.05, minimumElapsed)
        self.arrivalCapacitySeconds = window * 8
    }

    /// 本轮最后一个 token 的到达时刻。
    public var lastTokenAt: Date? { lastArrival }

    /// 解码时长：首 token 到末 token，不含 TTFT / prefill。
    public var decodingSeconds: TimeInterval {
        guard let first = firstArrival, let last = lastArrival else { return 0 }
        return max(minimumElapsed, last.timeIntervalSince(first))
    }

    /// 真正观测到的跨度：首片到末片，**没有 `minimumElapsed` 兜底**。
    /// 0 = 只有一个到达点（或没有），说明这一路根本没有可测的间隔。
    ///
    /// 聚合层拿它决定「能不能报全程平均」：单点会话除以 `decodingSeconds`
    /// 得到的是 1/0.35 ≈ 2.9 的虚构速率；成批到达的非流式响应更夸张，
    /// 14 155 token 会被摊成 37 769 tok/s。
    public var observedDecodeSpan: TimeInterval {
        guard let first = firstArrival, let last = lastArrival else { return 0 }
        return max(0, last.timeIntervalSince(first))
    }

    public mutating func reset() {
        arrivals.removeAll(keepingCapacity: true)
        firstArrival = nil
        lastArrival = nil
        totalTokens = 0
    }

    /// 喂一个流式分片。`tokens` 用 `TokenEstimator.fractional` 的结果。
    /// 事件一律按**到达时刻**进桶，乱序分片按插入位置放；`lastArrival`
    /// 只认真正的最新事件——旧实现从低通改造时漏了更新它，窗口锚死在
    /// 第一个分片上，稳态 100 tok/s 读出 18。
    public mutating func add(tokens: Double, at now: Date) {
        guard tokens > 0 else { return }
        totalTokens += tokens
        if firstArrival == nil { firstArrival = now }
        if lastArrival.map({ now >= $0 }) ?? true { lastArrival = now }
        if arrivals.last.map({ now >= $0.at }) ?? true {
            arrivals.append(Arrival(at: now, tokens: tokens))
        } else {
            var index = arrivals.count - 1
            while index > 0, arrivals[index - 1].at > now { index -= 1 }
            arrivals.insert(Arrival(at: now, tokens: tokens), at: index)
        }
        // 裁剪的时钟用 `lastArrival` 而不是分片的到达时刻：乱序、补记、
        // 或调用方拿一个更晚的 `now` 喂旧分片，都不该把当前窗口饿死——
        // 旧实现按 `now` 裁剪，测试里先喂 t=10 的一片再把读数时刻回拨，
        // 窗口被掏空，读数一路是 0。
        if let first = arrivals.first, let anchor = lastArrival,
           anchor.timeIntervalSince(first.at) > arrivalCapacitySeconds {
            var drain = 0
            while drain < arrivals.count,
                  anchor.timeIntervalSince(arrivals[drain].at) > arrivalCapacitySeconds {
                drain += 1
            }
            if drain > 0 { arrivals.removeFirst(drain) }
        }
    }

    /// 当前速率。可以任意频次读取，不改变内部状态。
    ///
    /// 两段时间（`a` = 最后一个事件，`t = min(now, a)` = 窗口右缘）：
    /// - **窗口在流内**（`t < a`）：窗 `[t−W, t]` 的量 ÷
    ///   `min(W, max(t − first, 0.01))`。稳态恒等于吞吐——分子分母一起
    ///   滑，与分片大小、取样时刻都无关；边缘压着的分片按「铺在自己的
    ///   到达时刻上」部分计。早读（`t < a`）只少看未来那几毫秒的片
    ///   （连续跳过，**不能 break**——未来片挡在队尾，旧版一个 break
    ///   把整个窗口读空，稳态 100 读成 10）。
    /// - **保持段与遗忘段**（`t ≥ a`）：冻结在最后一个完整窗
    ///   `[a−W, a]`（起步期 `[first, a]`，量除以实际跨度，`0.35` 兜底
    ///   防单帧除零——一个分片的一帧不是速度，摊在窗上下限内如实说
    ///   `1/0.35`）。窗口平均在流停止后会自己滑进空段——右缘每拍少
    ///   一段流量，读数一路掉；「保持」必须是冻住，不是让窗口继续走。
    ///   `now` 越过 `a + W` 起**线性**遗忘，`a + 2W` 归零（尺是取样
    ///   时刻 `now`：窗口钳到 `a` 时尾仍随墙钟增长，用钳后的 `t` 会把
    ///   尾折叠成 0、读数永远挂满值不归零）。悬崖把曲线砸成深 V；指数
    ///   尾（旧低通 τ=2.5s）挂着半旧值盖过 LAST 宽限——两头都实测过，
    ///   线性取中间，坡底落在 LAST 宽限（1.2s）之内，hero 交接已贴零。
    ///
    /// 起步（`now < first + 0.01`）说 0：一帧之内没有速率——首片刚到时
    /// 分母趋零，任何数都是尖峰。`minimumElapsed` 的兜底归
    /// `decodingSeconds` / `averageRate`（全程均值的尺），不进逐拍读数。
    ///
    /// 窗口右缘**钳到最后一个事件**：`now` 之后的空段是还没发生的路，
    /// 不算「变慢」，窗口也不许借未来的量——秒拍与 0.4s 快拍共用同一个
    /// `@Published` 读数也不会错开。静默的真相由 `now` 走保持/遗忘说出。
    public func rate(at now: Date) -> Double {
        guard let first = firstArrival, let last = lastArrival, !arrivals.isEmpty else { return 0 }
        // 起步第一帧：没有足够的观测说「多快」——0，不是钳出来的满值。
        guard now.timeIntervalSince(first) >= 0.01 else { return 0 }
        let tail = now.timeIntervalSince(last)
        let t = min(now, last)

        if t >= last {
            let observed = last.timeIntervalSince(first)
            let held = windowTokens(endingAt: last) / min(window, max(0.35, observed))
            guard tail < 2 * window else { return 0 }
            return held * max(0, 1 - max(0, tail - window) / window)
        }

        // 窗口在流内。
        let cutoff = t.addingTimeInterval(-window)
        let span = min(window, max(t.timeIntervalSince(first), 0.01))

        // 反向扫：出窗即停只对**左缘**成立（`at < cutoff`）；`at > t` 的
        // 未来量连续跳过不中断。数组有界。曾试过「老化水位线」省这一扫,
        // 水位不随读取前进，把已出窗的历史量当现值累加，稳态 100 读出
        // 500——读数正确优先于省一次遍历。
        // 半开窗 `(t−W, t]`：每个边界点只归它右边的窗，稳态精确等于
        // 吞吐——闭窗会让边界点双计，满窗读到 W+ε 的量、除以 W，100
        // 变 101，一个恒定的 +batch/窗 偏差。
        var sum = 0.0
        var i = arrivals.count - 1
        while i >= 0 {
            let arrival = arrivals[i]
            if arrival.at <= cutoff { break }
            if arrival.at <= t { sum += arrival.tokens }
            i -= 1
        }
        return sum / span
    }

    /// 最后一个完整窗的冻结速率（保持段的值）：`[a−W, a]` 的量 ÷
    /// `min(W, max(minimumElapsed, a − first))`。聚合层的 LAST 宽限用它
    /// 把 hero 撑过自己的线性坡——曲线归曲线（坡负责落地），hero 归
    /// hero（LAST 之前保持峰值），两把尺各管各的，这正是宽限存在的意义。
    public func frozenWindowRate() -> Double {
        guard let first = firstArrival, let last = lastArrival else { return 0 }
        let observed = last.timeIntervalSince(first)
        return windowTokens(endingAt: last) / min(window, max(minimumElapsed, observed))
    }

    /// `[t−W, t]` 窗口内到达的 token 总量。墙钟窗口的量只由**到达时刻**
    /// 决定，与「谁在什么时候来读」无关——聚合层做等间隔读数、诊断脚本
    /// 对账都从这里走。右缘钳到最后一个事件：窗口不越过观测边界，
    /// 「未来的量」永不参与任何读数。`t < first` 返回 0（空窗）。
    public func windowTokens(endingAt t: Date) -> Double {
        guard let first = firstArrival, t >= first else { return 0 }
        let cutoff = t.addingTimeInterval(-window)
        var sum = 0.0
        var i = arrivals.count - 1
        while i >= 0 {
            let arrival = arrivals[i]
            if arrival.at <= cutoff { break }
            if arrival.at <= t { sum += arrival.tokens }
            i -= 1
        }
        return sum
    }

    /// 整段解码的累计平均，用于回答结束后消息下方那个 tok/s。
    public func averageRate() -> Double {
        guard totalTokens > 0, decodingSeconds > 0 else { return 0 }
        return totalTokens / decodingSeconds
    }
}
