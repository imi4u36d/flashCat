import XCTest
@testable import FlashCatCLICore

final class SSEAccumulatorTests: XCTestCase {
    func testCollectsContentReasoningAndUsage() {
        var accumulator = SSEAccumulator(model: "demo")
        XCTAssertEqual(accumulator.consume(line: #"data: {"choices":[{"delta":{"reasoning_content":"想"}}]}"#),
                       [.reasoning("想")])
        XCTAssertEqual(accumulator.consume(line: #"data: {"choices":[{"delta":{"content":"你"}}]}"#),
                       [.content("你")])
        XCTAssertEqual(accumulator.consume(line: #"data: {"choices":[{"delta":{"content":"好"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#),
                       [.content("好")])
        XCTAssertEqual(accumulator.consume(line: "data: [DONE]"), [])
        XCTAssertEqual(accumulator.content, "你好")
        XCTAssertEqual(accumulator.reasoning, "想")
        XCTAssertEqual(accumulator.finishReason, "stop")
        XCTAssertEqual(accumulator.promptTokens, 3)
        XCTAssertEqual(accumulator.completionTokens, 2)
        XCTAssertEqual(accumulator.finish(started: Date()).tokensPerSecond.map { $0 > 0 }, true)
    }

    func testErrorFrameIsRecorded() {
        var accumulator = SSEAccumulator(model: "demo")
        _ = accumulator.consume(line: #"data: {"error":{"message":"模型未加载"}}"#)
        XCTAssertEqual(accumulator.errorMessage, "模型未加载")
    }

    func testNonDataLinesAreIgnored() {
        var accumulator = SSEAccumulator(model: "demo")
        XCTAssertEqual(accumulator.consume(line: ": keep-alive"), [])
        XCTAssertEqual(accumulator.consume(line: ""), [])
        XCTAssertEqual(accumulator.content, "")
    }

    func testPlainJSONIsNotMistakenForAStream() {
        var accumulator = SSEAccumulator(model: "demo")
        XCTAssertEqual(accumulator.consume(line: #"{"choices":[]}"#), [])
    }
}
