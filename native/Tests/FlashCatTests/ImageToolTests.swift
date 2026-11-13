import Foundation
import XCTest
import FlashCatKit
@testable import FlashCat

/// 画图工具的协议层：请求体里怎么挂 `tools`、流式 `tool_calls` 怎么拼回完整
/// 参数、下一轮怎么把「调用 + 结果」原样回放。这三步错一步，模型就会收到
/// 一段它自己都不认识的历史。
final class ImageToolTests: XCTestCase {
    /// 回调在 delegate 队列上跑，用锁保护请求体。
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []

        func add(_ data: Data) {
            lock.lock()
            bodies.append(data)
            lock.unlock()
        }

        var last: [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            guard let data = bodies.last else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return bodies.count
        }
    }

    private func frame(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
    }

    private func makeServer(_ respond: @escaping @Sendable ([[String: Any]]) -> [[String: Any]])
        async -> (GatewayHTTPServer, UInt16, Recorder)? {
        let recorder = Recorder()
        let server = GatewayHTTPServer { request in
            recorder.add(request.body)
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            let chunks = respond((body?["messages"] as? [[String: Any]]) ?? [])
            return .sse { session in
                for chunk in chunks { session.write(self.frame(chunk)) }
                session.write("data: [DONE]\n\n")
                session.close()
            }
        }
        for port in UInt16(39470)...UInt16(39510) {
            if await server.start(port: port) { return (server, port, recorder) }
        }
        return nil
    }

    private var options: ChatOptions {
        ChatOptions(temperature: 0.7, topP: 1, maxTokens: 0, reasoningEffort: nil, systemPrompt: "")
    }

    private var tools: [[String: Any]] {
        ImageTool.schema(sizeOptions: ["1024x1024", "1344x768"])
    }

    private let callID = "call_test_1"

    /// 两片参数、中间夹一片不带参数的装饰分片：拼回来必须还是完整 JSON。
    private func toolCallChunks() -> [[String: Any]] {
        [
            ["choices": [["delta": ["tool_calls": [[
                "index": 0,
                "id": callID,
                "type": "function",
                "function": ["name": ImageTool.name, "arguments": "{\"prompts\":[\"第一幕：橘猫穿"],
            ]]]]]],
            ["choices": [["delta": ["tool_calls": [[
                "index": 0,
                "function": ["arguments": "上宇航服，站在舷窗前\"]}"],
            ]]]]]],
            ["choices": [["delta": [:], "finish_reason": "tool_calls"]]],
        ]
    }

    func testSchemasDescribeTheGenerateImagesFunction() {
        let schema = tools
        XCTAssertEqual(schema.count, 1)
        let function = schema[0]["function"] as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, ImageTool.name)
        let parameters = function?["parameters"] as? [String: Any]
        XCTAssertEqual(parameters?["required"] as? [String], ["prompts"])
        let properties = parameters?["properties"] as? [String: Any]
        let prompts = properties?["prompts"] as? [String: Any]
        XCTAssertEqual(prompts?["maxItems"] as? Int, ImageTool.maximumImagesPerCall)
        let size = properties?["size"] as? [String: Any]
        XCTAssertEqual(size?["enum"] as? [String], ["1024x1024", "1344x768"])
    }

    func testParseAcceptsPromptAliasAndTrimsBlanks() {
        let call = ChatToolCall(id: "x", name: ImageTool.name, arguments: "{\"prompt\":\"  一只猫  \"}")
        guard case .success(let parsed) = ImageTool.parse(call) else {
            return XCTFail("单个 prompt 应该被收下")
        }
        XCTAssertEqual(parsed.prompts, ["一只猫"])
        XCTAssertNil(parsed.size)

        let broken = ChatToolCall(id: "x", name: ImageTool.name, arguments: "not json")
        guard case .failure(let error) = ImageTool.parse(broken) else {
            return XCTFail("坏 JSON 应该报错")
        }
        XCTAssertTrue(error.message.contains("JSON"))

        let empty = ChatToolCall(id: "x", name: ImageTool.name, arguments: "{\"prompts\":[\"  \"]}")
        guard case .failure = ImageTool.parse(empty) else {
            return XCTFail("空提示词应该报错")
        }
    }

    func testResultPayloadRoundTrips() throws {
        let payload = ImageTool.result(images: [("/tmp/a.png", "1024×1024 · 20 步")],
                                       seed: 42,
                                       size: "1024x1024")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["seed"] as? Int, 42)
        let images = try XCTUnwrap(object["images"] as? [[String: Any]])
        XCTAssertEqual(images.first?["path"] as? String, "/tmp/a.png")

        let failure = ImageTool.failure("内存不足")
        let failed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(failure.utf8)) as? [String: Any])
        XCTAssertEqual(failed["ok"] as? Bool, false)
        XCTAssertEqual(failed["error"] as? String, "内存不足")
    }

    func testStreamedToolCallsAreReassembled() async throws {
        guard let (server, port, recorder) = await makeServer({ _ in self.toolCallChunks() }) else {
            return XCTFail("测试服务没起来")
        }
        defer { Task { await server.stop() } }

        let client = ChatClient()
        let result = await client.send(port: Int(port), model: "m",
                                       turns: [ChatTurn(role: "user", content: "画三张")],
                                       options: options,
                                       tools: ChatToolSchema(tools),
                                       onDelta: { _, _ in },
                                       onReasoning: { _, _ in },
                                       onUsage: { _ in },
                                       onStatus: { _ in },
                                       onToolCall: { _, _ in })

        // 只有工具调用、没有正文：不能当成「服务没有返回内容」。
        if case .failure(let error) = result {
            XCTFail("工具调用不该判为失败：\(error.message)")
        }
        let calls = client.lastToolCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.id, callID)
        XCTAssertEqual(calls.first?.name, ImageTool.name)
        XCTAssertEqual(calls.first?.object?["prompts"] as? [String], ["第一幕：橘猫穿上宇航服，站在舷窗前"])

        let body = try XCTUnwrap(recorder.last)
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
        let sent = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual((sent.first?["function"] as? [String: Any])?["name"] as? String, ImageTool.name)
    }

    func testToolHistoryIsReplayedWithCallIDs() async throws {
        guard let (server, port, recorder) = await makeServer({ _ in
            [["choices": [["delta": ["content": "画好了"], "finish_reason": "stop"]]]]
        }) else {
            return XCTFail("测试服务没起来")
        }
        defer { Task { await server.stop() } }

        let call = ChatToolCall(id: callID, name: ImageTool.name,
                                arguments: "{\"prompts\":[\"一只猫\"]}")
        let turns = [
            ChatTurn(role: "user", content: "画一只猫"),
            ChatTurn(role: "assistant", content: "", toolCalls: [call]),
            ChatTurn(role: "tool", content: "{\"ok\":true}", toolCallID: callID),
        ]
        let client = ChatClient()
        let result = await client.send(port: Int(port), model: "m",
                                       turns: turns,
                                       options: options,
                                       onDelta: { _, _ in },
                                       onReasoning: { _, _ in },
                                       onUsage: { _ in },
                                       onStatus: { _ in },
                                       onToolCall: { _, _ in })
        if case .failure(let error) = result { XCTFail("回放失败：\(error.message)") }

        let messages = try XCTUnwrap(recorder.last?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0]["content"] as? String, "画一只猫")
        let assistant = messages[1]
        XCTAssertEqual(assistant["role"] as? String, "assistant")
        // 空正文不带 `content` 键，避免引擎把空串当作 assistant 说过话。
        XCTAssertNil(assistant["content"])
        let calls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["id"] as? String, callID)
        XCTAssertEqual((calls.first?["function"] as? [String: Any])?["name"] as? String, ImageTool.name)
        // 参数必须原样透传：重新编码会打乱前缀缓存，还可能改写模型的 JSON。
        XCTAssertEqual((calls.first?["function"] as? [String: Any])?["arguments"] as? String,
                       "{\"prompts\":[\"一只猫\"]}")

        let tool = messages[2]
        XCTAssertEqual(tool["role"] as? String, "tool")
        XCTAssertEqual(tool["tool_call_id"] as? String, callID)
        XCTAssertEqual(tool["content"] as? String, "{\"ok\":true}")
    }
    /// 视觉模型的一轮：正文和图片必须按 OpenAI 的 content parts 发出去，
    /// 图片用 data URL（引擎不需要再读本机路径）。
    func testVisionTurnSendsTextAndImageParts() async throws {
        guard let (server, port, recorder) = await makeServer({ _ in
            [["choices": [["delta": ["content": "我看到了"], "finish_reason": "stop"]]]]
        }) else {
            return XCTFail("测试服务没起来")
        }
        defer { Task { await server.stop() } }

        let image = "data:image/jpeg;base64,QUJD"
        let client = ChatClient()
        let result = await client.send(port: Int(port), model: "m",
                                       turns: [ChatTurn(role: "user", content: "看看这张",
                                                        imageURLs: [image])],
                                       options: options,
                                       onDelta: { _, _ in },
                                       onReasoning: { _, _ in },
                                       onUsage: { _ in },
                                       onStatus: { _ in })
        if case .failure(let error) = result { XCTFail("视觉请求失败：\(error.message)") }

        let messages = try XCTUnwrap(recorder.last?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        let parts = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "看看这张")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(parts[1]["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, image)
    }

}
