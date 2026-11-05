import Foundation

/// 统一的 token 估算与解码速率估计。
///
/// 之前应用内对话和网关各有一套整数版 token 估算（`other / 4` 与
/// `(other + 3) / 4`，CJK 判定区间还不一样），再各自用「固定窗口攒够就清零」
/// 的方式算瞬时速度。一个 SSE 分片常常只有一两个字符：整数除法把它估成
/// 0 token 后整片丢弃，计数就完全由网络分片边界决定；窗口每次清零又让
/// 相邻窗口的读数互不相关。两者叠起来，就是概览页 LIVE 数字忽高忽低的主因。
///
/// 这里把口径收成一条：**字符按小数权重累加 + 连续时间低通**。
/// 速率不再由「某个窗口里数出几个 token」决定，而是把每个分片当成一个脉冲
/// 喂进一阶低通滤波器，旧样本按时间自然衰减，因此分片边界、批量吐字
/// （投机解码一次验证多个 draft token）都不会把读数撕成锯齿。
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
                for part in parts where (part["type"] as? String) == "text" {
                    if let text = part["text"] as? String { total += estimate(text) }
                }
            }
        }
        // 每条消息的角色/分隔开销，量级参考 OpenAI 的 4 token/条。
        return total + list.count * 4
    }

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
        // 预热窗口按「首分片 → 末分片」算，不能掺入读取时刻：acc 只在有
        // 分片时更新，若让 now 也进 warmup，一次普通停顿会被重复衰减两遍
        // （silent 一次、warmup 一次），起步阶段还会因 minimumElapsed 低报。
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
