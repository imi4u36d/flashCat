import XCTest
@testable import FlashCatKit

/// 实时解码速率的回归测试。
///
/// 这些用例针对的正是「LIVE 数字忽高忽低」的三个历史成因：短分片被整数
/// 除法抹成 0、非重叠窗口每次清零、批量吐字把瞬时值顶出尖峰。改动任何一
/// 处估计逻辑前，先让这里说清楚什么样的输出才算稳定。
final class DecodeRateMeterTests: XCTestCase {
    private let epoch = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: token 估算

    func testFractionalTokensKeepShortPieces() {
        XCTAssertEqual(TokenEstimator.fractional(""), 0)
        XCTAssertEqual(TokenEstimator.fractional("a"), 0.25, accuracy: 0.0001)
        XCTAssertEqual(TokenEstimator.fractional("中"), 1.0, accuracy: 0.0001)
        // 短的 ASCII 分片必须留下贡献，否则整片会被 guard tokens > 0 丢掉。
        XCTAssertGreaterThan(TokenEstimator.fractional("a"), 0)
        XCTAssertEqual(TokenEstimator.estimate("a"), 1)
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
    }

    func testEstimateIsIndependentOfChunking() {
        let text = "hello 世界, flashCat 解码速度 abc123"
        var byPiece = 0.0
        for scalar in text.unicodeScalars {
            byPiece += TokenEstimator.fractional(String(scalar))
        }
        XCTAssertEqual(byPiece, TokenEstimator.fractional(text), accuracy: 0.0001)
    }

    func testPromptTokensIncludesMessageOverhead() {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "You are helpful."],
            ["role": "user", "content": "你好 world"],
        ]
        XCTAssertGreaterThan(TokenEstimator.promptTokens(messages: messages), 8)
        XCTAssertEqual(TokenEstimator.promptTokens(messages: nil), 0)
    }

    // MARK: 速率收敛

    func testSteadyStreamConvergesToActualRate() {
        var meter = DecodeRateMeter()
        let step = 0.01
        for index in 0..<600 {   // 6 秒，每 10ms 一个 token = 100 tok/s
            meter.add(tokens: 1, at: epoch.addingTimeInterval(Double(index) * step))
        }
        let measured = meter.rate(at: epoch.addingTimeInterval(599 * step))
        XCTAssertEqual(measured, 100.0, accuracy: 5.0)
    }

    func testWarmupDoesNotUnderReport() {
        var meter = DecodeRateMeter()
        for index in 0..<20 {
            meter.add(tokens: 1, at: epoch.addingTimeInterval(Double(index) * 0.01))
        }
        // 没有预热补偿时这里只会报 8 tok/s 上下；真实速率是 100。
        let measured = meter.rate(at: epoch.addingTimeInterval(0.19))
        XCTAssertEqual(measured, 100.0, accuracy: 15.0)
    }

    /// 同一段输出，逐 token 吐与一次吐 5 个（投机解码验证的典型形态），
    /// 平滑后的速率必须基本一致。
    func testBurstSizeDoesNotChangeRate() {
        func run(batch: Int) -> Double {
            var meter = DecodeRateMeter()
            var emitted = 0
            var time = 0.0
            while emitted < 400 {
                meter.add(tokens: Double(batch), at: epoch.addingTimeInterval(time))
                emitted += batch
                time += Double(batch) * 0.01
            }
            return meter.rate(at: epoch.addingTimeInterval(time - Double(batch) * 0.01))
        }
        let fine = run(batch: 1)
        let coarse = run(batch: 5)
        XCTAssertEqual(fine, coarse, accuracy: 5.0)
    }

    /// 恒定 100 tok/s，但分片忽大忽小、间隔忽长忽短。旧的非重叠窗口会把
    /// 这种抖动 1:1 变成读数跳变，低通后应几乎是一条直线。
    func testBurstyChunksStaySteady() {
        let pattern: [Double] = [1, 5, 2, 6, 1, 4, 3, 2]
        var meter = DecodeRateMeter()
        var time = 0.0
        var readings: [Double] = []
        for _ in 0..<60 {
            for count in pattern {
                time += count / 100.0
                meter.add(tokens: count, at: epoch.addingTimeInterval(time))
            }
            readings.append(meter.rate(at: epoch.addingTimeInterval(time)))
        }
        let settled = Array(readings.dropFirst(20))
        let mean = settled.reduce(0, +) / Double(settled.count)
        let maxDeviation = settled.reduce(0.0) { max($0, abs($1 - mean)) }
        XCTAssertEqual(mean, 100.0, accuracy: 5.0)
        XCTAssertLessThan(maxDeviation / mean, 0.05)
    }

    // MARK: 停顿与收尾

    func testShortPauseHoldsRateLongPauseDecays() {
        var meter = DecodeRateMeter()
        for index in 0..<400 {
            meter.add(tokens: 1, at: epoch.addingTimeInterval(Double(index) * 0.01))
        }
        let last = epoch.addingTimeInterval(3.99)
        let during = meter.rate(at: last)
        XCTAssertEqual(meter.rate(at: last.addingTimeInterval(0.5)), during, accuracy: during * 0.02)
        XCTAssertLessThan(meter.rate(at: last.addingTimeInterval(3.0)), during * 0.6)
    }

    func testAverageRateExcludesTTFT() {
        var meter = DecodeRateMeter()
        // 请求发出 2 秒后才来首 token；meter 只见解码阶段，不见 prefill。
        let first = epoch.addingTimeInterval(2.0)
        for index in 0..<100 {
            meter.add(tokens: 1, at: first.addingTimeInterval(Double(index) * 0.01))
        }
        XCTAssertEqual(meter.decodingSeconds, 0.99, accuracy: 0.001)
        XCTAssertEqual(meter.averageRate(), 100.0 / 0.99, accuracy: 1.0)
        XCTAssertEqual(meter.totalTokens, 100.0, accuracy: 0.001)
    }

    func testResetStartsANewGeneration() {
        var meter = DecodeRateMeter()
        for index in 0..<100 {
            meter.add(tokens: 1, at: epoch.addingTimeInterval(Double(index) * 0.01))
        }
        XCTAssertGreaterThan(meter.rate(at: epoch.addingTimeInterval(0.99)), 0)
        meter.reset()
        XCTAssertEqual(meter.rate(at: epoch.addingTimeInterval(1.0)), 0)
        XCTAssertEqual(meter.totalTokens, 0)
        XCTAssertEqual(meter.decodingSeconds, 0)
        meter.add(tokens: 1, at: epoch.addingTimeInterval(10.0))
        XCTAssertGreaterThan(meter.rate(at: epoch.addingTimeInterval(10.0)), 0)
    }

    func testReadingIsSideEffectFree() {
        var meter = DecodeRateMeter()
        for index in 0..<300 {
            meter.add(tokens: 1, at: epoch.addingTimeInterval(Double(index) * 0.01))
        }
        let at = epoch.addingTimeInterval(2.99)
        let first = meter.rate(at: at)
        _ = meter.rate(at: at)
        _ = meter.rate(at: at)
        XCTAssertEqual(meter.rate(at: at), first, accuracy: 0.0001)
    }
}
