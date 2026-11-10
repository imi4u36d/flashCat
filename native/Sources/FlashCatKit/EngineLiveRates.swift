import Foundation

/// 引擎自报的原始计数键。解析器把引擎的累计/瞬时计数放进 `EngineStatus.extras`，
/// 由 `EngineLiveRates` 换算成速率；这几处必须用同一组键。
///
/// mlx-serve 的 `/metrics.json` 不直接给速率，只给原始量：
/// `generation_tokens_live`（在跑会话已生成 + 本步已生成）、`prefill_tokens_live`
/// （当前请求已前向的提示词 token，逐请求归零）、`prefill_tokens_total` 与
/// `prefill_time_seconds`（已完成请求真正前向的 token 数与耗时）。
/// 它自己的监控页也是拿这些做差分。
public enum EngineRateCounters {
    /// 在跑请求已经生成的 token 数（含本步），差分即实时解码速度。
    public static let decodeLive = "rate.decode_live"
    /// 当前预填充请求已经前向的 token 数。
    public static let prefillLive = "rate.prefill_live"
    /// 累计「真正前向过」的提示词 token；前缀缓存恢复的部分不算。
    public static let prefillTokens = "rate.prefill_tokens"
    /// 累计预填充耗时，与 `prefillTokens` 同口径。
    public static let prefillSeconds = "rate.prefill_seconds"
    /// 正在预填充的请求数。
    public static let prefilling = "rate.prefilling"
}

/// 把引擎计数器折成实时解码 / 预填充速度。纯值类型，时间由调用方注入。
///
/// 预填充的分子刻意只取 `prefill_tokens`（引擎真正前向的 token），不取
/// `prompt_tokens`。同一会话的第二轮请求几乎全部命中前缀缓存：一份 108K
/// 上下文的请求实际只前向几百个 token，用 108K 除以首字耗时会把读数放大
/// 两个数量级。引擎已经把「缓存恢复」和「真正计算」分开计数，这里照它的
/// 口径走。
public struct EngineLiveRates {
    public struct Reading: Equatable, Sendable {
        /// 实时解码速度；空闲或这一格没有新增 token 时为 nil。
        public var decode: EngineRateSample
        /// 预填充速度；没有新完成请求时为 `.none`，由上层决定回落。
        public var prefill: EngineRateSample

        public init(decode: EngineRateSample = .none, prefill: EngineRateSample = .none) {
            self.decode = decode
            self.prefill = prefill
        }
    }

    /// 每个字段都单独可选：某个引擎版本少报一项时，其余读数仍然可用，
    /// 不能因为缺一个 histogram 就把整台引擎的速率一起丢掉。
    private struct Sample {
        let at: Date
        let decodeTokens: Double?
        let prefillLiveTokens: Double?
        let prefillTokens: Double?
        let prefillSeconds: Double?
        let running: Int
        let prefilling: Int
    }

    private var previous: Sample?

    /// 当前这一轮预填充的采样点：`(时刻, 已前向 token)`。
    ///
    /// 只在 `prefill_tokens_live` **前进**时追加。gauge 停在原地不代表速度归零，
    /// 只是当前 chunk 还没走完；两个点之间夹着若干个完整 chunk，差值除以时间
    /// 就是这一段 chunk 的真实吞吐。与旧的「本轮累计 ÷ 本轮已用时」相比，分母
    /// 只覆盖最近一小段，不再把请求最早那几秒的慢 chunk 一直带着——那正是
    /// 「读数是平均」的来源。
    private struct PrefillPoint {
        let at: Date
        let tokens: Double
    }
    private var prefillPoints: [PrefillPoint] = []
    /// 最近一个窗口的实测速度。chunk 之间保持不动，等下一次前进再刷新；
    /// 不能让分母随时间长大，否则同一 chunk 内轮询会看到读数一路下滑。
    private var prefillWindowRate: Double?
    /// 本轮预填充的起点，只在「很久没有新 chunk」时用于退回累计均值。
    private var prefillRoundStartedAt: Date?
    private var prefillRoundStartTokens: Double = 0
    private var prefillLastProgressAt: Date?

    /// 窗口长度约等于 1~2 个 prefill chunk：再短会被 chunk 量化带出锯齿，
    /// 再长就开始像「本次请求的平均值」。
    private static let prefillWindow: TimeInterval = 1.2
    /// 首个 chunk 之前的跨度太小，除出来的数字没有意义。
    private static let prefillMinimumSpan: TimeInterval = 0.3
    /// 超过这么久没有新 chunk，实时窗口已经过期：退回本轮累计均值。
    private static let prefillStaleAfter: TimeInterval = 3.0

    public init() {}

    /// 引擎换了进程或停止时调用，避免拿上一轮的计数当基线。
    public mutating func reset() {
        previous = nil
        forgetPrefillRound()
    }

    public mutating func observe(_ status: EngineStatus, at now: Date) -> Reading {
        guard let sample = Self.sample(from: status, at: now) else {
            previous = nil
            return Reading()
        }
        // 引擎重启会把这些计数清零。基线跟着换，别把「变小」算成负速率。
        let restarted: Bool
        if let previous, let current = sample.prefillTokens, let last = previous.prefillTokens {
            restarted = current < last
        } else {
            restarted = false
        }
        defer { previous = sample }
        guard !restarted else {
            // 重启后上一轮的数字与当前进程无关，窗口也得一起丢。
            forgetPrefillRound()
            return Reading()
        }

        var reading = Reading()
        // 预填充的实时值用**滑动窗口**：分子是最近一两个 chunk 前向的 token，
        // 分母是这一小段时间。请求最早那几秒不进分母，所以读数会跟着当前
        // chunk 走，而不是整轮请求的平均；gauge 某一拍没动时保持上一格，
        // 不会因为分母变大而自己往下滑。
        if sample.prefilling > 0, let current = sample.prefillLiveTokens, current >= 0 {
            recordPrefill(tokens: current, at: now)
            if current > 0, let rate = prefillWindowRate {
                reading.prefill = EngineRateSample(value: rate, kind: .live)
            }
        } else if sample.prefilling == 0 {
            // 预填充结束：本轮窗口作废，实时值不再代表「此刻」。
            forgetPrefillRound()
        }

        if let last = previous {
            let elapsed = now.timeIntervalSince(last.at)
            // 轮询间隔通常在 1~2 秒；太短会把计数器量化成尖峰，太长（休眠/卡顿）
            // 算出来的只是平均值而不是当前速度。
            if elapsed >= 0.2, elapsed <= 30 {
                if sample.running > 0,
                   let current = sample.decodeTokens, let lastDecode = last.decodeTokens,
                   current >= lastDecode {
                    let delta = current - lastDecode
                    if delta > 0 {
                        reading.decode = EngineRateSample(value: delta / elapsed, kind: .live)
                    }
                }
            }
        }
        // 预填充结束就交空读数。上一请求的实测值不再作为 `.lastRequest`
        // 挂出来——概览已取消 LAST 采集入口，空闲时宁可画「—」。
        return reading
    }

    private mutating func forgetPrefillRound() {
        prefillPoints.removeAll()
        prefillWindowRate = nil
        prefillRoundStartedAt = nil
        prefillRoundStartTokens = 0
        prefillLastProgressAt = nil
    }

    /// 记一个预填充采样点，并刷新滑动窗口速度。
    ///
    /// gauge 变小 = 换了新请求（`prefill_tokens_live` 每请求归零）；同一个请求内
    /// 只在 token 前进时追加点，窗口外的点及时丢掉，速度才会跟着当前 chunk 走。
    private mutating func recordPrefill(tokens: Double, at now: Date) {
        guard let last = prefillPoints.last else {
            prefillPoints = [PrefillPoint(at: now, tokens: tokens)]
            prefillRoundStartedAt = now
            prefillRoundStartTokens = tokens
            prefillLastProgressAt = now
            return
        }
        guard tokens >= last.tokens else {
            // 新请求占了预填充位：旧窗口与旧基线一起丢掉。
            prefillPoints = [PrefillPoint(at: now, tokens: tokens)]
            prefillWindowRate = nil
            prefillRoundStartedAt = now
            prefillRoundStartTokens = tokens
            prefillLastProgressAt = now
            return
        }
        guard tokens > last.tokens else {
            // 这一拍还没有新 chunk：保持上一次的窗口速度，别让它随时间衰减。
            // 真的卡住超过 `prefillStaleAfter` 才退回本轮累计均值，让读数
            // 至少还在动，也不会把几分钟前的高速度一直挂在角标上。
            if let startedAt = prefillRoundStartedAt,
               let progressedAt = prefillLastProgressAt,
               now.timeIntervalSince(progressedAt) >= Self.prefillStaleAfter {
                let span = now.timeIntervalSince(startedAt)
                if span > 0 {
                    prefillWindowRate = (tokens - prefillRoundStartTokens) / span
                }
            }
            return
        }
        prefillPoints.append(PrefillPoint(at: now, tokens: tokens))
        prefillLastProgressAt = now
        let cutoff = now.addingTimeInterval(-Self.prefillWindow)
        // 窗口里至少要有两个点才算速度；只有一个点时，连同它前一个点一起
        // 保留（那正是「最近一个 chunk」）。窗口外的更早的点一律丢掉，读数
        // 才会从「本轮平均」变成「当前这一小段」。
        if let firstInside = prefillPoints.firstIndex(where: { $0.at >= cutoff }),
           firstInside > 0 {
            let keepFrom = firstInside < prefillPoints.count - 1 ? firstInside : firstInside - 1
            prefillPoints.removeFirst(keepFrom)
        }
        if let base = prefillPoints.first {
            let span = now.timeIntervalSince(base.at)
            if span >= Self.prefillMinimumSpan {
                prefillWindowRate = (tokens - base.tokens) / span
            }
        }
    }

    private static func sample(from status: EngineStatus, at now: Date) -> Sample? {
        let decode = status.extras[EngineRateCounters.decodeLive]
        let prefillLive = status.extras[EngineRateCounters.prefillLive]
        let prefillTokens = status.extras[EngineRateCounters.prefillTokens]
        let prefillSeconds = status.extras[EngineRateCounters.prefillSeconds]
        // 这台引擎不报任何一项：交给别的口径，不要把「没有数据」说成 0。
        guard decode != nil || prefillTokens != nil || prefillSeconds != nil || prefillLive != nil
        else { return nil }
        return Sample(at: now,
                      decodeTokens: decode,
                      prefillLiveTokens: prefillLive,
                      prefillTokens: prefillTokens,
                      prefillSeconds: prefillSeconds,
                      running: status.activeRequests,
                      prefilling: Int(status.extras[EngineRateCounters.prefilling] ?? 0))
    }
}
