// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Darwin
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

    /// 上游请求体必须自己带上 `stream`：引擎默认按非流式回一整块 JSON，
    /// 而网关是按 SSE 逐行转发、逐片打点的。少了这个字段，Claude 的流式
    /// 客户端只会收到 message_start / ping / message_stop，正文全空，
    /// 概览里这一路连一个 token 都没有。
    func testStreamingRequestAsksUpstreamForAStream() throws {
        let payload: [String: Any] = [
            "model": "Qwen3.8-27B",
            "max_tokens": 64,
            "stream": true,
            "messages": [["role": "user", "content": "你好"]],
        ]
        let result = try AnthropicCodec.translateRequest(payload)
        XCTAssertTrue(result.stream)
        XCTAssertEqual(result.openai["stream"] as? Bool, true)
        // usage 走末片：否则 completion_tokens 与缓存命中量都拿不到。
        let options = result.openai["stream_options"] as? [String: Any]
        XCTAssertEqual(options?["include_usage"] as? Bool, true)
    }

    /// 非流式请求不能平白多出 `stream_options`：引擎会因此多发一片 usage，
    /// 而这条路上根本没有人逐片读。
    func testNonStreamingRequestStaysBuffered() throws {
        let result = try AnthropicCodec.translateRequest([
            "model": "m",
            "max_tokens": 8,
            "messages": [["role": "user", "content": "hi"]],
        ])
        XCTAssertFalse(result.stream)
        XCTAssertEqual(result.openai["stream"] as? Bool, false)
        XCTAssertNil(result.openai["stream_options"])
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

    func testEveryStreamFrameCarriesItsEventName() {
        // 官方 SDK 按 `event:` 分发；只有 data 的话 content_block_start /
        // content_block_stop / message_stop 都会被当成无名字的消息丢掉。
        let translator = AnthropicCodec.StreamTranslator(model: "m")
        var frames: [(event: String?, object: [String: Any])] = []
        frames += translator.startEvents().map(parseFrame)
        frames += translator.consume(chunk: [
            "choices": [["index": 0, "delta": ["reasoning_content": "想"]]],
        ]).map(parseFrame)
        frames += translator.consume(chunk: [
            "choices": [["index": 0, "delta": ["content": "答"]]],
        ]).map(parseFrame)
        frames += translator.finishEvents().map(parseFrame)

        for frame in frames {
            guard let type = frame.object["type"] as? String else {
                return XCTFail("frame without type: \(frame)")
            }
            XCTAssertEqual(frame.event, type, "event 名与 payload type 不一致")
        }
        XCTAssertTrue(frames.contains { $0.object["type"] as? String == "message_stop" })
    }

    func testTextThenThinkingKeepsBlockIndicesStraight() {
        // 文本中途又冒出思考：旧实现只关「nextBlockIndex-1」，会把后面的正文
        // 继续写到思考块的 index 上，客户端看到的就是「思考里夹着答案」。
        let translator = AnthropicCodec.StreamTranslator(model: "m")
        _ = translator.startEvents()

        let firstText = translator.consume(chunk: [
            "choices": [["index": 0, "delta": ["content": "先"]]],
        ]).map(parseFrame)
        XCTAssertEqual(firstText[0].object["index"] as? Int, 0)

        let thinking = translator.consume(chunk: [
            "choices": [["index": 0, "delta": ["reasoning_content": "等等"]]],
        ]).map(parseFrame)
        XCTAssertEqual(thinking[0].object["type"] as? String, "content_block_stop")
        XCTAssertEqual(thinking[0].object["index"] as? Int, 0, "文本块必须先关掉")
        XCTAssertEqual(thinking[1].object["index"] as? Int, 1)
        XCTAssertEqual(thinking[2].object["index"] as? Int, 1)

        let text = translator.consume(chunk: [
            "choices": [["index": 0, "delta": ["content": "后"]]],
        ]).map(parseFrame)
        XCTAssertEqual(text[0].object["type"] as? String, "content_block_stop")
        XCTAssertEqual(text[0].object["index"] as? Int, 1)
        XCTAssertEqual(text[2].object["index"] as? Int, 2, "新正文必须落在一个新块上")

        let finish = translator.finishEvents().map(parseFrame)
        XCTAssertEqual(finish[0].object["index"] as? Int, 2)
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

    // MARK: protocol edges (raw loopback sockets)

    private struct TimeoutFailure: Error {}

    /// 挂起比失败难查得多：本轮 P1 修的正是「start 永不 resume」，所以每次
    /// 可能卡住的 await 都套一层超时，让「卡住」变成一条明确的失败信息。
    private func withTimeout<T: Sendable>(seconds: TimeInterval,
                                          _ operation: @escaping @Sendable () async -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutFailure()
            }
            guard let value = try await group.next() else { throw TimeoutFailure() }
            group.cancelAll()
            return value
        }
    }

    /// 端口段 39100...39140 被 `testServerRoundTrip` 占用，这里从 39300 起找端口。
    private func startLoopbackServer(_ server: GatewayHTTPServer,
                                     candidates: ClosedRange<UInt16> = 39_300...39_360) async throws -> UInt16 {
        for candidate in candidates {
            if try await withTimeout(seconds: 5, { await server.start(port: candidate) }) {
                return candidate
            }
            server.stop()
        }
        throw TimeoutFailure()
    }

    private func httpGet(port: UInt16, path: String) async throws -> (status: Int, body: Data) {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// P1 回归：stop 之后在同一端口重新 start。旧实现里 listener 进 `.cancelled`
    /// 时没人 resume continuation，这个 await 会永久挂起；端口被占时同理。
    func testServerCanRestartOnSamePort() async throws {
        let server = GatewayHTTPServer { _ in .json(["ok": true]) }
        let port = try await startLoopbackServer(server)
        let beforeRestart = try await httpGet(port: port, path: "/")
        XCTAssertEqual(beforeRestart.status, 200)

        server.stop()
        // 端口刚释放时新 listener 可能先报 waiting，允许重试几次；关键是每次
        // start 都必须返回，而不是把测试挂死。
        var restarted = false
        for _ in 0..<5 where !restarted {
            restarted = try await withTimeout(seconds: 5) { await server.start(port: port) }
            if !restarted {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        XCTAssertTrue(restarted, "同一个端口重启失败（旧实现在这里永久挂起）")
        let afterRestart = try await httpGet(port: port, path: "/")
        XCTAssertEqual(afterRestart.status, 200)
        server.stop()

        // 端口被别的监听者占住时，start 必须回 false；旧实现的 `.cancelled` 分支不 resume。
        let occupied = try XCTUnwrap(OccupiedLoopbackPort(candidates: 39_400...39_460), "没有可占用的测试端口")
        defer { occupied.close() }
        let blocked = GatewayHTTPServer { _ in .json(["ok": true]) }
        defer { blocked.stop() }
        let started = try await withTimeout(seconds: 5) { await blocked.start(port: occupied.port) }
        XCTAssertFalse(started, "端口已被占用时 start 应返回 false")
    }

    /// 头没有上限时，一个只发头、永远不发 `\r\n\r\n` 的客户端能把接收缓冲撑到 OOM。
    func testServerRejectsOversizedHead() async throws {
        let server = GatewayHTTPServer { _ in .json(["ok": true]) }
        let port = try await startLoopbackServer(server)
        defer { server.stop() }
        let client = try XCTUnwrap(RawTCPClient(port: port), "连不上 127.0.0.1:\(port)")

        var request = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        let padding = String(repeating: "x", count: 1_024)
        while request.utf8.count < GatewayHTTPServer.maximumHeadBytes + 4_096 {
            request += "X-Pad: \(padding)\r\n"
        }
        client.send(request) // 故意不发结束的空行
        let response = client.readToEnd()
        XCTAssertTrue(response.contains(" 400 "), "超长请求头应回 400，实际：\(response)")
        XCTAssertTrue(response.contains("head exceeds"), "应答应说明超限原因：\(response)")
    }

    /// 畸形请求行以前会被照常派发（method/path 为空），路由再回 404：客户端拿到
    /// 一个看似正常、实则错误的答案。现在必须在解析处就回 400。
    func testServerAnswersMalformedRequestLineWith400() async throws {
        let server = GatewayHTTPServer { _ in .json(["ok": true]) }
        let port = try await startLoopbackServer(server)
        defer { server.stop() }

        let singleField = try XCTUnwrap(RawTCPClient(port: port))
        singleField.send("BADREQUESTLINE\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        let first = singleField.readToEnd()
        XCTAssertTrue(first.contains(" 400 "), "请求行只有一个字段时应回 400，实际：\(first)")
        XCTAssertFalse(first.contains("\"ok\""), "畸形请求不应到达路由：\(first)")

        let notUTF8 = try XCTUnwrap(RawTCPClient(port: port))
        notUTF8.send(Data([0xFF, 0xFE, 0x00])
            + Data(" / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8))
        let second = notUTF8.readToEnd()
        XCTAssertTrue(second.contains(" 400 "), "非 UTF-8 请求头应回 400，实际：\(second)")
    }

    /// `Expect: 100-continue` 以前完全没实现：严格按 RFC 等 100 的客户端会一直等到
    /// 自己的超时。现在读完头就要先把这一行发出去，正文随后才到。
    func testServerSends100Continue() async throws {
        let server = GatewayHTTPServer { request in .json(["got": request.body.count == 7]) }
        let port = try await startLoopbackServer(server)
        defer { server.stop() }
        let client = try XCTUnwrap(RawTCPClient(port: port))

        client.send([
            "POST /v1/messages HTTP/1.1",
            "Host: 127.0.0.1",
            "Expect: 100-continue",
            "Content-Length: 7",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n"))
        let interim = client.read(until: "\r\n\r\n")
        XCTAssertTrue(interim.contains("100 Continue"), "没有回 100 Continue，实际：\(interim)")

        client.send(#"{"a":1}"#)
        let final = client.readToEnd()
        XCTAssertTrue(final.contains(" 200 "), "最终应答：\(final)")
        XCTAssertTrue(final.contains("\"got\":true"), "正文没有到达路由：\(final)")
    }

    /// chunked 正文的长度只在读的过程中才知道；旧实现按 0 字节正文派发，路由拿到
    /// 的是「成功但内容为空」的请求。缓冲式网关不支持 chunked，必须明确回 400。
    func testServerRejectsChunkedBody() async throws {
        let server = GatewayHTTPServer { _ in .json(["ok": true]) }
        let port = try await startLoopbackServer(server)
        defer { server.stop() }
        let client = try XCTUnwrap(RawTCPClient(port: port))

        client.send([
            "POST /v1/chat/completions HTTP/1.1",
            "Host: 127.0.0.1",
            "Transfer-Encoding: chunked",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n") + "2\r\n{}\r\n0\r\n\r\n")
        let response = client.readToEnd()
        XCTAssertTrue(response.contains(" 400 "), "chunked 应回 400，实际：\(response)")
        XCTAssertTrue(response.contains("transfer-encoding"), "应答应说明不支持的编码：\(response)")
    }

    // MARK: raw socket fixtures

    /// 阻塞式裸 TCP 客户端：畸形请求行、chunked 正文、超长头这些请求 URLSession
    /// 根本构造不出来，只能在字节层拼。目标永远是 127.0.0.1，不依赖外网。
    private final class RawTCPClient {
        private var fd: Int32 = -1

        init?(port: UInt16) {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return nil }
            // Mac 上写已关闭的连接会给进程发 SIGPIPE，默认动作是直接杀进程。
            var noSignal: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            // 读超时让读循环有界；测试失败比测试挂死好定位。
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
                Darwin.close(descriptor)
                return nil
            }
            let connected = withUnsafePointer(to: address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                Darwin.close(descriptor)
                return nil
            }
            fd = descriptor
        }

        deinit {
            if fd >= 0 { Darwin.close(fd) }
        }

        @discardableResult
        func send(_ text: String) -> Int {
            send(Data(text.utf8))
        }

        @discardableResult
        func send(_ data: Data) -> Int {
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base, raw.count)
            }
        }

        /// 读到出现 `marker` 为止（用于「服务器先发、客户端后发正文」的握手）。
        func read(until marker: String, timeout: TimeInterval = 5) -> String {
            let deadline = Date().addingTimeInterval(timeout)
            var received = Data()
            while Date() < deadline {
                guard let chunk = receive() else { break }
                received.append(chunk)
                if String(decoding: received, as: UTF8.self).contains(marker) { break }
            }
            return String(decoding: received, as: UTF8.self)
        }

        /// 读到对端关闭为止；400/413 之后服务器一定主动关连接。
        func readToEnd(timeout: TimeInterval = 5) -> String {
            let deadline = Date().addingTimeInterval(timeout)
            var received = Data()
            while Date() < deadline {
                guard let chunk = receive() else { break }
                received.append(chunk)
            }
            return String(decoding: received, as: UTF8.self)
        }

        /// nil 表示对端已关闭或读超时。
        private func receive() -> Data? {
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let count = buffer.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, raw.count, 0)
            }
            guard count > 0 else { return nil }
            return Data(buffer[0..<count])
        }
    }

    /// 只为占住一个回环端口不放：验证「端口被占时 start 返回 false 而不是挂起」。
    private final class OccupiedLoopbackPort {
        let port: UInt16
        private var fd: Int32 = -1

        init?(candidates: ClosedRange<UInt16>) {
            for candidate in candidates {
                let descriptor = socket(AF_INET, SOCK_STREAM, 0)
                guard descriptor >= 0 else { return nil }
                var reuse: Int32 = 1
                setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = candidate.bigEndian
                inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)

                let bound = withUnsafePointer(to: address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if bound == 0, listen(descriptor, 1) == 0 {
                    fd = descriptor
                    port = candidate
                    return
                }
                Darwin.close(descriptor)
            }
            return nil
        }

        deinit {
            close()
        }

        func close() {
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
        }
    }

    // MARK: upstream failure taxonomy

    /// The three transport failures have to stay distinguishable: the route
    /// answers 503 / 504 / 502 respectively, and the log line names the port
    /// and the cause. Collapsing them into `nil` is what made "engine is not
    /// running" and "the model took forever" look identical to clients.
    func testUpstreamFailureTaxonomy() {
        let refused = GatewayUpstreamError.notReachable(port: 9_000, reason: "Connection refused")
        XCTAssertEqual(refused.status, 503)
        XCTAssertEqual(refused.port, 9_000)
        XCTAssertTrue(refused.logMessage.contains("127.0.0.1:9000"), refused.logMessage)

        let slow = GatewayUpstreamError.timedOut(port: 9_001, seconds: 30)
        XCTAssertEqual(slow.status, 504)
        XCTAssertEqual(slow.port, 9_001)
        XCTAssertTrue(slow.logMessage.contains("127.0.0.1:9001"), slow.logMessage)

        let broken = GatewayUpstreamError.transport(port: 9_002, reason: "Connection reset by peer")
        XCTAssertEqual(broken.status, 502)
        XCTAssertEqual(broken.port, 9_002)
        XCTAssertTrue(broken.logMessage.contains("Connection reset by peer"), broken.logMessage)
    }

    /// End of the same contract, through the real request path: a port nothing
    /// listens on must come back as `notReachable` (503) rather than a silent
    /// failure. Port 1 is privileged, so no test daemon can be sitting there.
    func testPostJSONToClosedPortReportsNotReachable() async throws {
        let status = try await withTimeout(seconds: 10) {
            switch await GatewayUpstream.postJSON(port: 1, path: "/v1/models", body: Data(), timeout: 5) {
            case .success(let buffered): return buffered.status
            case .failure(let error): return error.status
            }
        }
        XCTAssertEqual(status, 503, "connection refused must surface as not-ready, not as a generic failure")
    }
}
