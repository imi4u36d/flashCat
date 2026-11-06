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
        public var decode: Double?
        /// 预填充速度；没有新完成请求时沿用上一次的实测值。
        public var prefill: Double?

        public init(decode: Double? = nil, prefill: Double? = nil) {
            self.decode = decode
            self.prefill = prefill
        }
    }

    private struct Sample {
        let at: Date
        let decodeTokens: Double
        let prefillLiveTokens: Double
        let prefillTokens: Double
        let prefillSeconds: Double
        let running: Int
        let prefilling: Int
    }

    private var previous: Sample?
    /// 最近一次真实测得的预填充速度。预填充是阵发的：请求做完后计数器才
    /// 落账，空闲的一格没有增量，不能因此把卡片清成「—」。
    private var lastPrefill: Double?

    public init() {}

    /// 引擎换了进程或停止时调用，避免拿上一轮的计数当基线。
    public mutating func reset() {
        previous = nil
        lastPrefill = nil
    }

    public mutating func observe(_ status: EngineStatus, at now: Date) -> Reading {
        guard let sample = Self.sample(from: status, at: now) else {
            previous = nil
            return Reading()
        }
        // 引擎重启会把这些计数清零。基线跟着换，别把「变小」算成负速率。
        if let previous, sample.prefillTokens < previous.prefillTokens {
            lastPrefill = nil
        }
        defer { previous = sample }

        var reading = Reading()
        if let last = previous {
            let elapsed = now.timeIntervalSince(last.at)
            // 轮询间隔通常在 1~2 秒；太短会把计数器量化成尖峰，太长（休眠/卡顿）
            // 算出来的只是平均值而不是当前速度。
            if elapsed >= 0.2, elapsed <= 30 {
                if sample.running > 0, sample.decodeTokens >= last.decodeTokens {
                    let delta = sample.decodeTokens - last.decodeTokens
                    if delta > 0 { reading.decode = delta / elapsed }
                }
                if sample.prefilling > 0,
                   sample.prefillLiveTokens >= last.prefillLiveTokens,
                   sample.prefillLiveTokens > 0 {
                    let delta = sample.prefillLiveTokens - last.prefillLiveTokens
                    if delta > 0 { reading.prefill = delta / elapsed }
                }
                // 完成的请求：分子只含真正前向的 token，分母只含预填充耗时。
                // 缓存恢复的 token 与恢复耗时都不在这两个计数器里。
                if sample.prefillTokens > last.prefillTokens,
                   sample.prefillSeconds > last.prefillSeconds {
                    let deltaTokens = sample.prefillTokens - last.prefillTokens
                    let deltaSeconds = sample.prefillSeconds - last.prefillSeconds
                    if deltaSeconds > 0 { reading.prefill = deltaTokens / deltaSeconds }
                }
            }
        }
        if let prefill = reading.prefill {
            lastPrefill = prefill
        } else {
            reading.prefill = lastPrefill
        }
        return reading
    }

    private static func sample(from status: EngineStatus, at now: Date) -> Sample? {
        guard let decode = status.extras[EngineRateCounters.decodeLive],
              let prefillLive = status.extras[EngineRateCounters.prefillLive],
              let prefillTokens = status.extras[EngineRateCounters.prefillTokens],
              let prefillSeconds = status.extras[EngineRateCounters.prefillSeconds]
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
