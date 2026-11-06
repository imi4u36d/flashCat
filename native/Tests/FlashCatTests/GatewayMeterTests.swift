import XCTest
@testable import FlashCat

/// 网关按请求打点的两个易错点：agent 的工具调用算不算生成量、
/// 前缀缓存命中的提示词算不算预填充。
final class GatewayMeterTests: XCTestCase {
    // MARK: 生成量

    func testTextAndReasoningBothCount() {
        XCTAssertEqual(GatewayMeter.generatedText(["content": "abc"]), "abc")
        XCTAssertEqual(GatewayMeter.generatedText(["reasoning_content": "想"]), "想")
        XCTAssertEqual(GatewayMeter.generatedText(["reasoning": "想"]), "想")
        XCTAssertEqual(GatewayMeter.generatedText(["content": "a", "reasoning_content": "b"]), "ab")
    }

    /// agent 的回复大头是工具调用的参数；不数它，会话在概览里永远是 0 tok/s。
    func testToolCallsCountAsGeneratedTokens() {
        let delta: [String: Any] = [
            "tool_calls": [
                ["index": 0,
                 "function": ["name": "read_file", "arguments": #"{"path":"a.swift"}"#]],
            ],
        ]
        let text = GatewayMeter.generatedText(delta)
        XCTAssertTrue(text.contains("read_file"))
        XCTAssertTrue(text.contains("a.swift"))
        XCTAssertGreaterThan(text.count, 0)
    }

    func testEmptyDeltaGeneratesNothing() {
        XCTAssertEqual(GatewayMeter.generatedText([:]), "")
        XCTAssertEqual(GatewayMeter.generatedText(["tool_calls": [[String: Any]]()]), "")
    }

    // MARK: 缓存命中

    func testCachedTokensReadBothDialects() {
        XCTAssertEqual(GatewayMeter.cachedTokens([
            "prompt_tokens_details": ["cached_tokens": 1_024],
        ]), 1_024)
        XCTAssertEqual(GatewayMeter.cachedTokens([
            "input_tokens_details": ["cached_tokens": 2_048],
        ]), 2_048)
        XCTAssertEqual(GatewayMeter.cachedTokens(["prompt_tokens": 10]), 0)
        XCTAssertEqual(GatewayMeter.cachedTokens([
            "prompt_tokens_details": ["cached_tokens": -5],
        ]), 0)
    }
}
