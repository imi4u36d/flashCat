import Foundation

/// 统一的 token 估算与解码速率估计。
///
/// 之前应用内对话和网关各有一套整数版 token 估算（`other / 4` 与
/// `(other + 3) / 4`，CJK 判定区间还不一样），再各自用「固定窗口攒够就清零」
/// 的方式算瞬时速度。一个 SSE 分片常常只有一两个字符：整数除法把它估成
/// 0 token 后整片丢弃，计数就完全由网络分片边界决定；窗口每次清零又让
/// 相邻窗口的读数互不相关。两者叠起来，就是概览页 LIVE 数字忽高忽低的主因。
///
/// 字符估算收成一条口径：**字符按小数权重累加**（`TokenEstimator`），一两个
/// 字符的分片也留下 0.25 这样的贡献，计数不再由 SSE 切分方式决定。
///
/// 速率估计有两个互补的实现：
/// - `DecodeWindowMeter`（**当前速度**的口径）：按固定窗口总量，分布无关，
///   概览 hero、曲线与「最近请求」逐行都用它；
/// - `DecodeRateMeter`（连续时间低通）：事件驱动，服务应用内对话页的
///   直播条——那边逐片到达，要的是「最后一个脉冲的强度」。
public enum TokenEstimator {
    /// 字符级 token 权重。CJK/全角约 1 token/字，其余脚本约 4 字符/token。
    /// 返回 Double 是刻意的：短分片也能留下 0.25 这样的贡献，不会被抹成 0。
    public static func fractional(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var weighted = 0.0
        for scalar in text.unicodeScalars {
            weighted += isWide(scalar.value) ? 1.0 : 0.25
        }
        return weighted
    }

    /// 需要整数 token 数时（消息计数、prompt 长度）用。向上取整，短文本不会
    /// 被算成 0；长文本的误差最多 1 token。
    public static func estimate(_ text: String) -> Int {
        Int(fractional(text).rounded(.up))
    }

    /// 从 OpenAI 的 `messages` 里估出输入侧长度（含 system 和工具描述的量级）。
    public static func promptTokens(messages: Any?) -> Int {
        guard let list = messages as? [[String: Any]] else { return 0 }
        var total = 0
        for message in list {
            if let text = message["content"] as? String {
                total += estimate(text)
            } else if let parts = message["content"] as? [[String: Any]] {
                for part in parts {
                    switch part["type"] as? String {
                    case "text":
                        if let text = part["text"] as? String { total += estimate(text) }
                    case "image_url":
                        total += approximateImageTokens
                    default:
                        break
                    }
                }
            }
        }
        // 每条消息的角色/分隔开销，量级参考 OpenAI 的 4 token/条。
        return total + list.count * 4
    }

    /// 一张 1024px 图在 Qwen 系视觉塔上的量级。只用于界面上的上下文估算，
    /// 引擎回报的真实 usage 会覆盖它；不同视觉塔会差几百 token，不必精确。
    public static let approximateImageTokens = 1024

    /// CJK 表意文字与假名、韩文、全角标点/字母。两处旧实现的分段在这里合并。
    private static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }
}

/// 连续时间的解码速率低通滤波器，单位 tok/s。纯值类型，时间由调用方注入，
/// 因此可以在没有真实引擎的测试里用确定性的时间戳验证收敛与抗抖。
///
/// 模型：把每个分片看成强度为 `tokens` 的脉冲，
/// `acc(t) = acc(t-1)·e^(-Δt/τ) + tokens/τ`；稳态下 acc 就等于真实速率 R。
/// 刚起步时 acc 还没积起来，除以预热因子 `1 - e^(-elapsed/τ)` 补偿，避免
/// 前两三秒系统性低报。读取时再按距上一个分片的时间衰减，输出不会僵在旧值。
///
/// 适用面：**应用内对话页的直播条**（逐分片回调，事件节奏天然密集）。
/// 概览的当前速度改走 `DecodeWindowMeter`：低通的输出随读取时刻连续衰减，
/// 秒级轮询会把衰减中的中间态当成「变慢了」读出来；窗口总量分布无关，
/// 稳态下与取样时刻无关。
public struct DecodeRateMeter {
    /// 时间常数：越大越稳，对真实变速跟得越慢。2.5 秒约覆盖 2~3 个解码批次，
    /// 既能压住分片抖动，又能在模型切换思考/正文时一两秒内反映出来。
    public let timeConstant: TimeInterval
    /// 停顿宽限：短于这个时间的无输出不降速。SSE 分片抖动、投机解码批量吐字
    /// 都会造成零点几秒的空隙，不该被当成「引擎慢了」。
    public let holdTime: TimeInterval
    /// 分母下限，防止第一个分片就除出天文数字。
    public let minimumElapsed: TimeInterval

    private var firstAt: Date?
    private var lastAt: Date?
    /// 低通状态，量纲与速率相同（tok/s）。
    private var accumulated: Double = 0
    /// 累计估算 token 数（含 reasoning），用于没有 usage 时给消息兜底。
    public private(set) var totalTokens: Double = 0

    /// 本轮最后一个分片的到达时刻。聚合层用它判断「此刻是否还在吐字」：
    /// `finishedAt == nil` 只说明请求还没收尾，不等于这一拍有输出。
    public var lastTokenAt: Date? { lastAt }

    public init(timeConstant: TimeInterval = 2.5,
                holdTime: TimeInterval = 0.8,
                minimumElapsed: TimeInterval = 0.35) {
        self.timeConstant = max(0.1, timeConstant)
        self.holdTime = max(0, holdTime)
        self.minimumElapsed = max(0.05, minimumElapsed)
    }

    /// 解码时长：首分片到末分片。不含 TTFT / prefill，与流式读数同口径。
    public var decodingSeconds: TimeInterval {
        guard let first = firstAt, let last = lastAt else { return 0 }
        return max(minimumElapsed, last.timeIntervalSince(first))
    }

    public mutating func reset() {
        firstAt = nil
        lastAt = nil
        accumulated = 0
        totalTokens = 0
    }

    /// 喂一个流式分片。`tokens` 用 `TokenEstimator.fractional` 的结果。
    public mutating func add(tokens: Double, at now: Date) {
        guard tokens > 0 else { return }
        if let last = lastAt {
            let gap = max(0, now.timeIntervalSince(last))
            accumulated *= exp(-gap / timeConstant)
        } else {
            firstAt = now
        }
        accumulated += tokens / timeConstant
        totalTokens += tokens
        lastAt = now
    }

    /// 当前平滑速率。可以任意频次读取，不改变内部状态。
    public func rate(at now: Date) -> Double {
        guard let first = firstAt, let last = lastAt, accumulated > 0 else { return 0 }
        let silent = max(0, now.timeIntervalSince(last) - holdTime)
        let decayed = accumulated * exp(-silent / timeConstant)
        // 预热补偿按「首分片 → 末分片」算。分母是「等效平均间隔」对应的
        // `1 − e^(−τ_eff/τ)`，不是观测总时长：稳态流 100 tok/s 跑了 30 秒,
        // 每片间隔 0.01s，稳态 acc≈100，若除以 `1 − e^(−30/2.5) ≈ 1.0`
        // 就报 100（恰好对，因为已完全预热）。但只跑了 1 秒时 acc 还没
        // 积满，要除以 `1 − e^(−1/2.5) ≈ 0.33` 抬到 100 —— 用总时长就对。
        // 真正的坑是**稀疏分片**：思考流每 2s 一个长分片，观测 10s 内 acc
        // 在脉冲间大幅衰减，总时长法把 warmup 当 1.0、把衰减后的低 acc
        // 直接报出，读数只有真实值的 40%。等效间隔法：平均间隔 g =
        // observed/(n−1)，warmup = `1 − e^(−g/τ) · (1 + g/τ)`（一阶修正），
        // 保证批内衰减与计数口径自洽。实测稳态 100 的流两种算法差 3% 以内。
        let observed = max(0.05, last.timeIntervalSince(first))
        let warmup = max(0.001, 1 - exp(-observed / timeConstant))
        return decayed / warmup
    }

    /// 整段解码的累计平均，用于回答结束后消息下方那个 tok/s。
    public func averageRate() -> Double {
        guard totalTokens > 0, decodingSeconds > 0 else { return 0 }
        return totalTokens / decodingSeconds
    }
}
