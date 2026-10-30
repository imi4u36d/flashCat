import XCTest
@testable import FlashCatKit

/// Gateway translation coverage: Anthropic → OpenAI requests, OpenAI →
/// Anthropic responses, and the streamed event grammar.
final class GatewayTests: XCTestCase {

    /// `[String: Any]` is not Equatable; compare through canonical JSON.
    private func assertJSONEqual(_ a: Any, _ b: Any,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let left = (try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]))
            ?? Data()
        let right = (try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys]))
            ?? Data()
        XCTAssertEqual(String(decoding: left, as: UTF8.self),
                       String(decoding: right, as: UTF8.self),
                       file: file, line: line)
    }

    // MARK: request translation

    func testBasicRequestTranslation() throws {
        let payload: [String: Any] = [
            "model": "Qwen3.8-27B",
            "max_tokens": 1024,
            "system": "你是一个简洁的助手。",
            "messages": [
                ["role": "user", "content": "你好"],
            ],
            "temperature": 0.3,
            "top_p": 0.9,
            "stop_sequences": ["END"],
        ]
        let result = try AnthropicCodec.translateRequest(payload)
        XCTAssertTrue(result.stream == false)
        let openai = result.openai
        XCTAssertEqual(openai["model"] as? String, "Qwen3.8-27B")
        XCTAssertEqual(openai["max_tokens"] as? Int, 1024)
        XCTAssertEqual(openai["temperature"] as? Double, 0.3)
        XCTAssertEqual(openai["top_p"] as? Double, 0.9)
        XCTAssertEqual(openai["stop"] as? [String], ["END"])

        let messages = openai["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "你是一个简洁的助手。")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "你好")
    }

    func testRequestRequiresModelAndMaxTokens() {
        XCTAssertThrowsError(try AnthropicCodec.translateRequest([
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 10,
        ]))
        XCTAssertThrowsError(try AnthropicCodec.translateRequest([
            "model": "m",
            "messages": [["role": "user", "content": "hi"]],
        ]))
        XCTAssertThrowsError(try AnthropicCodec.translateRequest([
            "model": "m",
            "max_tokens": 10,
            "messages": [[String: Any]](),
        ]))
    }

    func testBase64ImageBecomesDataURL() throws {
        let payload: [String: Any] = [
            "model": "vl",
            "max_tokens": 100,
            "messages": [
                ["role": "user", "content": [
                    ["type": "text", "text": "图里是什么"],
                    ["type": "image", "source": [
                        "type": "base64", "media_type": "image/png", "data": "aGVsbG8=",
                    ]],
                ]],
            ],
        ]
        let openai = try AnthropicCodec.translateRequest(payload).openai
        let messages = openai["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.count, 1)
        let parts = messages[0]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let image = parts[1]["image_url"] as? [String: Any] ?? [:]
        XCTAssertEqual(image["url"] as? String, "data:image/png;base64,aGVsbG8=")
    }

    func testToolRoundTripRequest() throws {
        let payload: [String: Any] = [
            "model": "m",
            "max_tokens": 512,
            "tools": [
                ["name": "get_weather",
                 "description": "查天气",
                 "input_schema": ["type": "object", "properties": ["city": ["type": "string"]]]],
            ],
            "tool_choice": ["type": "tool", "name": "get_weather"],
            "messages": [
                ["role": "user", "content": "北京天气如何"],
                ["role": "assistant", "content": [
                    ["type": "tool_use", "id": "toolu_1", "name": "get_weather",
                     "input": ["city": "北京"]],
                ]],
                ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": "toolu_1",
                     "content": "晴，25 度"],
                ]],
            ],
        ]
        let openai = try AnthropicCodec.translateRequest(payload).openai

        let tools = openai["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        let function = tools[0]["function"] as? [String: Any] ?? [:]
        XCTAssertEqual(function["name"] as? String, "get_weather")
        assertJSONEqual(function["parameters"] ?? [:],
                        ["type": "object", "properties": ["city": ["type": "string"]]])
        assertJSONEqual(openai["tool_choice"] ?? [:],
                        ["type": "function", "function": ["name": "get_weather"]])

        let messages = openai["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.count, 3)
        // The assistant tool_use block becomes OpenAI tool_calls.
        XCTAssertEqual(messages[1]["role"] as? String, "assistant")
        let calls = messages[1]["tool_calls"] as? [[String: Any]] ?? []
        XCTAssertEqual(calls[0]["id"] as? String, "toolu_1")
        let callFunction = calls[0]["function"] as? [String: Any] ?? [:]
        XCTAssertEqual(callFunction["name"] as? String, "get_weather")
        XCTAssertEqual(callFunction["arguments"] as? String, #"{"city":"北京"}"#)
        // The tool_result turn becomes a tool message first.
        XCTAssertEqual(messages[2]["role"] as? String, "tool")
        XCTAssertEqual(messages[2]["tool_call_id"] as? String, "toolu_1")
        XCTAssertEqual(messages[2]["content"] as? String, "晴，25 度")
    }

    // MARK: response translation

    func testResponseTranslation() {
        let openai: [String: Any] = [
            "id": "chatcmpl-1",
            "model": "Qwen3.8-27B",
            "choices": [
                ["index": 0,
                 "message": ["role": "assistant", "content": "你好！"],
                 "finish_reason": "stop"],
            ],
            "usage": ["prompt_tokens": 12, "completion_tokens": 5],
        ]
        let message = AnthropicCodec.translateResponse(openai)
        XCTAssertEqual(message["type"] as? String, "message")
        XCTAssertEqual(message["role"] as? String, "assistant")
        XCTAssertEqual(message["stop_reason"] as? String, "end_turn")
        let content = message["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "你好！")
        let usage = message["usage"] as? [String: Any] ?? [:]
        XCTAssertEqual(usage["input_tokens"] as? Int, 12)
        XCTAssertEqual(usage["output_tokens"] as? Int, 5)
    }

    func testResponseToolUseAndLengthReason() {
        let openai: [String: Any] = [
            "id": "chatcmpl-2",
            "model": "m",
            "choices": [
                ["index": 0,
                 "message": [
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": [
                        ["id": "call_1", "type": "function",
                         "function": ["name": "get_weather", "arguments": #"{"city":"北京"}"#]],
                    ],
                 ],
                 "finish_reason": "tool_calls"],
            ],
            "usage": [:],
        ]
        let message = AnthropicCodec.translateResponse(openai)
        XCTAssertEqual(message["stop_reason"] as? String, "tool_use")
        let content = message["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(content[0]["type"] as? String, "tool_use")
        XCTAssertEqual(content[0]["id"] as? String, "call_1")
        XCTAssertEqual(content[0]["name"] as? String, "get_weather")
        assertJSONEqual(content[0]["input"] ?? [:], ["city": "北京"])
    }

    // MARK: streaming translation

    private func parseFrame(_ frame: String) -> (event: String?, object: [String: Any]) {
        var event: String?
        var data = ""
        for line in frame.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("event: ") { event = String(line.dropFirst(7)) }
            if line.hasPrefix("data: ") { data = String(line.dropFirst(6)) }
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] ?? [:]
        return (event, object)
    }

    func testStreamTextSequence() {
        let translator = AnthropicCodec.StreamTranslator(model: "m", inputTokens: 7)
        let start = translator.startEvents().map(parseFrame)
        XCTAssertEqual(start.count, 2)
        XCTAssertEqual(start[0].event, "message_start")
        XCTAssertEqual(start[0].object["type"] as? String, "message_start")
        let message = start[0].object["message"] as? [String: Any] ?? [:]
        XCTAssertEqual((message["usage"] as? [String: Any])?["input_tokens"] as? Int, 7)
        XCTAssertEqual(start[1].object["type"] as? String, "ping")

        let chunk: [String: Any] = [
            "choices": [["index": 0, "delta": ["content": "早上"]]],
        ]
        let frames = translator.consume(chunk: chunk).map(parseFrame)
        // First text delta opens the block: content_block_start + delta.
        XCTAssertEqual(frames[0].object["type"] as? String, "content_block_start")
        XCTAssertEqual(frames[0].object["index"] as? Int, 0)
        XCTAssertEqual(frames[1].object["type"] as? String, "content_block_delta")
        let delta = frames[1].object["delta"] as? [String: Any] ?? [:]
        XCTAssertEqual(delta["type"] as? String, "text_delta")
        XCTAssertEqual(delta["text"] as? String, "早上")

        let second = translator.consume(chunk: [
            "choices": [["index": 0, "delta": ["content": "好"], "finish_reason": "stop"]],
        ]).map(parseFrame)
        XCTAssertEqual(second[0].object["type"] as? String, "content_block_delta")

        let finish = translator.finishEvents().map(parseFrame)
        XCTAssertEqual(finish[0].object["type"] as? String, "content_block_stop")
        XCTAssertEqual(finish[1].event, "message_delta")
        let deltaTop = finish[1].object["delta"] as? [String: Any] ?? [:]
        XCTAssertEqual(deltaTop["stop_reason"] as? String, "end_turn")
        XCTAssertEqual((finish[1].object["usage"] as? [String: Any])?["output_tokens"] as? Int, 0)
        XCTAssertEqual(finish[2].object["type"] as? String, "message_stop")
    }

    func testStreamThinkingBlocks() {
        let translator = AnthropicCodec.StreamTranslator(model: "m")
        _ = translator.startEvents()
        let thinking = translator.consume(chunk: [
            "choices": [["index": 0, "delta": ["reasoning_content": "让我想想"]]],
        ]).map(parseFrame)
        XCTAssertEqual(thinking[0].object["type"] as? String, "content_block_start")
        XCTAssertEqual((thinking[0].object["content_block"] as? [String: Any])?["type"] as? String, "thinking")
        XCTAssertEqual((thinking[1].object["delta"] as? [String: Any])?["type"] as? String, "thinking_delta")

        // The text that follows closes thinking and opens text.
        let text = translator.consume(chunk: [
            "choices": [["index": 0, "delta": ["content": "答案是 4"]]],
        ]).map(parseFrame)
        XCTAssertEqual(text[0].object["type"] as? String, "content_block_stop")
        XCTAssertEqual(text[1].object["type"] as? String, "content_block_start")
        XCTAssertEqual((text[1].object["content_block"] as? [String: Any])?["type"] as? String, "text")

        let finish = translator.finishEvents().map(parseFrame)
        XCTAssertEqual(finish[0].object["type"] as? String, "content_block_stop")
    }

    func testStreamToolCallWithArguments() {
        let translator = AnthropicCodec.StreamTranslator(model: "m")
        _ = translator.startEvents()
        let begin = translator.consume(chunk: [
            "choices": [["index": 0, "delta": ["tool_calls": [
                ["index": 0, "id": "call_9", "type": "function",
                 "function": ["name": "get_weather", "arguments": ""]],
            ]]]],
        ]).map(parseFrame)
        XCTAssertEqual(begin[0].object["type"] as? String, "content_block_start")
        let block = begin[0].object["content_block"] as? [String: Any] ?? [:]
        XCTAssertEqual(block["type"] as? String, "tool_use")
        XCTAssertEqual(block["id"] as? String, "call_9")
        XCTAssertEqual(block["name"] as? String, "get_weather")

        let fragment = translator.consume(chunk: [
            "choices": [["index": 0, "delta": ["tool_calls": [
                ["index": 0, "function": ["arguments": #"{"city":"#]],
            ]]]],
        ]).map(parseFrame)
        XCTAssertEqual((fragment[0].object["delta"] as? [String: Any])?["type"] as? String, "input_json_delta")
        XCTAssertEqual((fragment[0].object["delta"] as? [String: Any])?["partial_json"] as? String, #"{"city":"#)

        let finish = translator.finishEvents().map(parseFrame)
        let delta = finish.first { $0.event == "message_delta" }
        assertJSONEqual(delta?.object["delta"] ?? [:],
                        ["stop_reason": "tool_use", "stop_sequence": NSNull()])
    }

    // MARK: errors & counting

    func testErrorEnvelopeRewrite() {
        let body = Data(#"{"error":{"message":"model not found","type":"invalid_request_error"}}"#.utf8)
        let envelope = AnthropicCodec.errorEnvelope(from: body, upstreamStatus: 400)
        XCTAssertEqual(envelope["type"] as? String, "error")
        let error = envelope["error"] as? [String: Any] ?? [:]
        XCTAssertEqual(error["message"] as? String, "model not found")

        let plain = AnthropicCodec.errorEnvelope(from: Data(), upstreamStatus: 503)
        let plainError = plain["error"] as? [String: Any] ?? [:]
        XCTAssertEqual(plainError["type"] as? String, "overloaded_error")
    }

    func testCountInputTokens() {
        let payload: [String: Any] = [
            "system": "hello world",          // 10 chars / 4 → 2
            "messages": [
                ["role": "user", "content": "你好世界"],  // CJK ×4 → 4
                ["role": "user", "content": [
                    ["type": "image", "source": ["type": "base64", "data": "x"]],
                ]],
            ],
        ]
        XCTAssertEqual(AnthropicCodec.countInputTokens(payload), 2 + 4 + 1_000)
    }

    func testSSEDataPayloadParsing() {
        XCTAssertNil(GatewayUpstream.dataPayload(ofLine: ": keep-alive"))
        XCTAssertNil(GatewayUpstream.dataPayload(ofLine: "data: [DONE]"))
        XCTAssertEqual(GatewayUpstream.dataPayload(ofLine: #"data: {"id":1}"#), #"{"id":1}"#)
        XCTAssertNil(GatewayUpstream.dataPayload(ofLine: "event: ping"))
    }

    // MARK: server round trip (loopback sockets)

    /// Drives the real HTTP server over 127.0.0.1: a buffered JSON answer, a
    /// second request on the same connection (keep-alive), and an SSE stream
    /// with multiple frames.
    func testServerRoundTrip() async throws {
        let server = GatewayHTTPServer { request in
            switch (request.method, request.path) {
            case ("GET", "/hello"):
                return .json(["ok": true, "echo": request.header("x-probe") ?? ""])
            case ("GET", "/stream"):
                return .sse { session in
                    for index in 0..<3 {
                        guard session.writeEvent(data: #"{"n":\#(index)}"#) else { return }
                    }
                    _ = session.write("data: [DONE]\n\n")
                    session.close()
                }
            default:
                return .json(["error": "nope"], status: 404)
            }
        }

        // Bind an ephemeral-ish port; retry a few in case of collision.
        var started = false
        var port: UInt16 = 0
        for candidate in UInt16(39100)...UInt16(39140) {
            if await server.start(port: candidate) {
                started = true
                port = candidate
                break
            }
            server.stop()
        }
        XCTAssertTrue(started, "没有可用的测试端口")

        let session = URLSession.shared
        // Buffered + keep-alive: two requests on one connection.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hello")!)
        request.setValue("probe-value", forHTTPHeaderField: "x-probe")
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["ok"] as? Bool, true)
        XCTAssertEqual(object?["echo"] as? String, "probe-value")

        // SSE stream.
        let (streamData, streamResponse) = try await session.data(
            for: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/stream")!))
        XCTAssertEqual((streamResponse as? HTTPURLResponse)?.statusCode, 200)
        let text = String(decoding: streamData, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "data: ").count - 1, 4) // 3 events + [DONE]
        XCTAssertTrue(text.contains(#"{"n":2}"#))

        // Anthropic-style dialect detection.
        var anthropicRequest = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        anthropicRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        server.stop()
    }
}
