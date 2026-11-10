import XCTest
@testable import FlashCatKit

/// 解码速率估计器（`DecodeWindowMeter`）的回归测试。
///
/// 钉住「当前速度」读数的四条性质，每条都对应旧实现（连续时间低通）的
/// 一种病灶：
/// 1. **稳态恒等于吞吐**——分子分母都是墙钟窗口的量，一起滑；分片
///    大小、取样时刻、轮询相位都不进读数（旧低通随取样时刻连续衰减，
///    1Hz 与 0.4s 快拍各读各的，谷—峰交替就是「闪烁」本体）。
/// 2. **成批到达摊平**——脉冲串只把总量留给自己落进的那个窗口。
/// 3. **收尾是缓坡不是悬崖**——最后一个分片之后保持一个窗，线性遗忘
///    两窗归零；悬崖把曲线砸成深 V，指数尾（旧低通 τ=2.5s）挂着半旧值
///    盖过 LAST 宽限。
/// 4. **起步与单帧不闪尖峰**——首帧 10ms 内说 0；之后读数按真实跨度
///    建立，`windowTokens` 提供分布无关的量做对账。
final class DecodeWindowMeterTests: XCTestCase {
    private let epoch = Date(timeIntervalSinceReferenceDate: 2_000_000)

    /// 喂一段恒定速率的流。生成器每次给出「下一批 token 数」，内部按
    /// `rate` 换算到达时刻——节奏由生成器决定，总量只由速率与时长决定。
    private func stream(rate R: Double,
                        seconds: Double,
                        window W: TimeInterval = 1.0,
                        next: () -> Double) -> DecodeWindowMeter {
        var meter = DecodeWindowMeter(window: W)
        var time = 0.0
        while time < seconds {
            let take = next()
            guard take > 0 else { break }
            meter.add(tokens: take, at: epoch.addingTimeInterval(time))
            time += take / R
        }
        return meter
    }

    // MARK: 稳态

    func testSteadyTokenStreamReadsTrueRate() {
        let meter = stream(rate: 100, seconds: 6) { 1 }
        XCTAssertEqual(meter.rate(at: epoch.addingTimeInterval(5.99)), 100.0, accuracy: 5.0)
    }

    /// 同一段输出两种到达分布：逐 token、每 100ms 一批 10。稳态读数必须
    /// 一致——低通做不到这点（batch 之间衰减 18% 再加热回去），这正是
    /// 旧实现闪烁的机理。
    func testArrivalDistributionDoesNotChangeReading() {
        var seen: [Double] = []
        for batch in [1.0, 10.0] {
            let meter = stream(rate: 100, seconds: 6) { batch }
            seen.append(meter.rate(at: epoch.addingTimeInterval(5.5)))
        }
        XCTAssertGreaterThan(seen[0], 90)
        XCTAssertEqual(seen[0], seen[1], accuracy: 5.0,
                       "逐 token \(seen[0]) 与成批 \(seen[1]) 的稳态读数不一致")
    }

    /// 稳态读数与取样时刻无关：同一段流上 20 个不同相位的读数必须完全
    /// 一致——秒拍与 0.4s 快拍共用同一个 `@Published` 字段的安全网。
    /// （旧低通在同一秒内会给出 100→82→67 的连续衰减。）
    func testSteadyOutputIsIndependentOfSamplingPhase() {
        let meter = stream(rate: 80, seconds: 6) { 1 }
        let readings = stride(from: 5.0, through: 5.95, by: 0.05).map {
            meter.rate(at: epoch.addingTimeInterval($0))
        }
        let mean = readings.reduce(0, +) / Double(readings.count)
        let spread = (readings.max() ?? 0) - (readings.min() ?? 0)
        XCTAssertEqual(mean, 80.0, accuracy: 3.0)
        XCTAssertLessThan(spread, 1.0, "稳态漂移 \(spread)：读数随取样时刻变化")
    }

    /// 成批脉冲（投机解码验证多个 draft token、下游背压憋出的脉冲串）：
    /// 1Hz 与 0.5Hz 的相邻读数跳变都必须小于半个 batch——窗口的量对
    /// 到达分布不敏感，脉冲被摊进它落进的那一个窗。
    func testPulseTrainsDoNotCreateSpikes() {
        var meter = DecodeWindowMeter(window: 1.0)
        // 每 0.5 秒一次脉冲、每次 40 token = 80 tok/s 的稳定吞吐。
        for step in 0..<28 {
            meter.add(tokens: 40, at: epoch.addingTimeInterval(Double(step) * 0.5))
        }
        var readings: [Double] = []
        var t = 12.0
        while t < 13.5 {
            readings.append(meter.rate(at: epoch.addingTimeInterval(t)))
            t += 0.5
        }
        let jump = zip(readings, readings.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        XCTAssertLessThan(jump, 20, "相邻半秒跳变 \(jump): \(readings)")
        XCTAssertGreaterThan(readings.first ?? 0, 70)
    }

    // MARK: 窗口总量（分布无关量）

    func testWindowTokensIsDistributionIndependent() {
        let meter = stream(rate: 100, seconds: 6, window: 1.0) { 1 }
        XCTAssertEqual(meter.windowTokens(endingAt: epoch.addingTimeInterval(5.5)),
                       100.0, accuracy: 2.0)
    }

    // MARK: 停顿与收尾

    /// 收尾形状：保持一个窗（`tail < W` 读数纹丝不动——低通在这里已经
    /// 掉到 ~82% 并继续下滑，这正是旧实现的波纹），再**线性遗忘**一个
    /// 窗，`last + 2W` 归零。悬崖与指数尾都是被实测否掉的错误形状。
    func testPauseHoldsOneWindowThenDecaysLinearly() {
        var meter = DecodeWindowMeter(window: 0.5)
        for index in 0..<400 {
            meter.add(tokens: 1, at: epoch.addingTimeInterval(Double(index) * 0.01))
        }
        let last = epoch.addingTimeInterval(3.99)
        let during = meter.rate(at: last)
        XCTAssertGreaterThan(during, 80)
        // 保持段：半秒内完全不动（低通已衰减 18%）。
        XCTAssertEqual(meter.rate(at: last.addingTimeInterval(0.25)), during, accuracy: 0.5)
        // 遗忘段中点：线性一半。
        XCTAssertEqual(meter.rate(at: last.addingTimeInterval(0.75)), during * 0.5, accuracy: 2.0)
        // 坡底：精确归零，LAST 宽限在 1.2s 接管时曲线已贴地。
        XCTAssertEqual(meter.rate(at: last.addingTimeInterval(1.0)), 0, accuracy: 0.001)
        XCTAssertEqual(meter.rate(at: last.addingTimeInterval(1.2)), 0, accuracy: 0.001)
    }

    /// 窗口右缘 = 取样时刻：早读只少看未来那几毫秒的片（连续跳过），
    /// 不会把整个窗口读空——旧实现用 `break` 处理未来量，稳态 100 被
    /// 读成 10。
    func testEarlyReadDoesNotPanicToZero() {
        let meter = stream(rate: 100, seconds: 6) { 1 }
        XCTAssertEqual(meter.rate(at: epoch.addingTimeInterval(5.0)), 100.0, accuracy: 3.0)
        XCTAssertEqual(meter.rate(at: epoch.addingTimeInterval(5.3)), 100.0, accuracy: 3.0)
    }

    func testAverageRateExcludesTTFT() {
        var meter = DecodeWindowMeter(window: 0.5)
        let first = epoch.addingTimeInterval(2.0)
        for index in 0..<100 {
            meter.add(tokens: 1, at: first.addingTimeInterval(Double(index) * 0.01))
        }
        XCTAssertEqual(meter.decodingSeconds, 0.99, accuracy: 0.001)
        XCTAssertEqual(meter.averageRate(), 100.0 / 0.99, accuracy: 1.0)
        XCTAssertEqual(meter.totalTokens, 100.0, accuracy: 0.001)
    }

    func testResetStartsANewGeneration() {
        var meter = DecodeWindowMeter(window: 0.5)
        for index in 0..<100 {
            meter.add(tokens: 1, at: epoch.addingTimeInterval(Double(index) * 0.01))
        }
        XCTAssertGreaterThan(meter.rate(at: epoch.addingTimeInterval(0.99)), 0)
        meter.reset()
        XCTAssertEqual(meter.rate(at: epoch.addingTimeInterval(1.0)), 0)
        XCTAssertEqual(meter.totalTokens, 0)
        XCTAssertEqual(meter.decodingSeconds, 0)
        XCTAssertNil(meter.lastTokenAt)
        meter.add(tokens: 1, at: epoch.addingTimeInterval(10.0))
        // 单帧内没有「速率」：下一拍起读数建立。
        XCTAssertEqual(meter.rate(at: epoch.addingTimeInterval(10.0)), 0)
        XCTAssertGreaterThan(meter.rate(at: epoch.addingTimeInterval(10.02)), 0)
    }

    func testReadingIsSideEffectFree() {
        var meter = DecodeWindowMeter(window: 0.5)
        for index in 0..<300 {
            meter.add(tokens: 1, at: epoch.addingTimeInterval(Double(index) * 0.01))
        }
        let at = epoch.addingTimeInterval(2.99)
        let first = meter.rate(at: at)
        _ = meter.rate(at: at)
        _ = meter.rate(at: at)
        XCTAssertEqual(meter.rate(at: at), first, accuracy: 0.0001)
    }

    // MARK: 起步

    /// 单 token 的形状：首帧（10ms 内）说 0——一帧之内没有速率；之后
    /// 读数被 `minimumElapsed` 兜底成 1/0.35 = 2.86 的最小可观测速率，
    /// 保持到 `a + W`，线性遗忘 `a + 2W` 归零。不闪天文数字，也不装死
    /// 到遗忘末尾。
    func testSingleTokenSpeaksHonestRate() {
        var meter = DecodeWindowMeter(window: 0.5)
        XCTAssertEqual(meter.rate(at: epoch), 0)
        meter.add(tokens: 1, at: epoch.addingTimeInterval(1.0))
        XCTAssertEqual(meter.rate(at: epoch.addingTimeInterval(1.005)), 0)
        XCTAssertEqual(meter.rate(at: epoch.addingTimeInterval(1.10)), 1 / 0.35, accuracy: 0.01)
        // 保持段：同一个 2.86 纹丝不动。
        XCTAssertEqual(meter.rate(at: epoch.addingTimeInterval(1.4)), 1 / 0.35, accuracy: 0.01)
        // 遗忘段中点（0.5）、坡底归零。
        XCTAssertEqual(meter.rate(at: epoch.addingTimeInterval(1.75)), 0.5 / 0.35, accuracy: 0.01)
        XCTAssertEqual(meter.rate(at: epoch.addingTimeInterval(2.0)), 0, accuracy: 0.001)
    }

    /// 起步期：跨度 `t − first < minimumElapsed` 的头几拍被 0.35s 兜底
    /// ——稀疏流（每 20ms 一片、140ms 8 片）读出 8/0.35 = 23 而不是
    /// 8/0.14 = 57：一帧的观测不够「真实速率」的资格，宁保守不尖峰。
    /// 跨度超过下限（`t − first ≥ 0.35`）后读数即真实速率，不经历低通
    /// 「先低报再爬两三秒」的预热——比旧低通快一个量级。稳态完全等于
    /// 吞吐。
    func testWarmupReadsTrueRateOnceSpanBuilds() {
        var meter = DecodeWindowMeter(window: 1.0)
        // 50 tok/s：每 20ms 一片。
        for step in 0..<8 {
            meter.add(tokens: 1, at: epoch.addingTimeInterval(Double(step) * 0.02))
        }
        XCTAssertEqual(meter.rate(at: epoch.addingTimeInterval(0.14)), 8 / 0.35, accuracy: 0.5)
        // 跨度 0.4 ≥ 0.35：读数回到真实速率。
        var longer = DecodeWindowMeter(window: 1.0)
        for step in 0..<21 {
            longer.add(tokens: 1, at: epoch.addingTimeInterval(Double(step) * 0.02))
        }
        XCTAssertEqual(longer.rate(at: epoch.addingTimeInterval(0.42)), 50.0, accuracy: 4.0)
        let steady = stream(rate: 50, seconds: 6) { 1 }
        XCTAssertEqual(steady.rate(at: epoch.addingTimeInterval(5.9)), 50.0, accuracy: 2.0)
    }

    // MARK: 聚合

    /// 窗口总量按路相加 = 合计：`windowTokens` 是分布无关量，诊断与
    /// 对账走它；速率各路相加的不变量在 `GatewayMeterTests` 里钉。
    func testWindowTokensSumAcrossSessions() {
        var a = DecodeWindowMeter(window: 0.5)
        var b = DecodeWindowMeter(window: 0.5)
        var t = 0.0
        while t < 3 {
            a.add(tokens: 2, at: epoch.addingTimeInterval(t))
            b.add(tokens: 1, at: epoch.addingTimeInterval(t))
            t += 0.05
        }
        // 最后一个满窗 `[2.49, 2.99]`：a 每片 2 token × 11 片 = 21，
        // b 每片 1 token × 11 片 = 11。
        let now = epoch.addingTimeInterval(2.99)
        XCTAssertEqual(a.windowTokens(endingAt: now), 21.0, accuracy: 1.5)
        XCTAssertEqual(a.windowTokens(endingAt: now) + b.windowTokens(endingAt: now),
                       32.0, accuracy: 2.0)
    }
}
