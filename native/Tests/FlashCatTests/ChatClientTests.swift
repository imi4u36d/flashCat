import Foundation
import XCTest
import FlashCatKit
@testable import FlashCat

/// 流式客户端在「停止后立刻重发」时的竞态回归测试。
///
/// `URLSession` 会在 `cancel()` 之后继续把被取消 task 的回调投递到 delegate
/// 队列。旧实现把这些回调写进「当前请求」的共享字段，于是新请求会被旧请求的
/// didComplete 提前收尾（报「服务没有返回内容」），缓冲也会被旧分片污染。
/// 这里用一个真实的本地 SSE 服务把那条路径跑一遍。
final class ChatClientTests: XCTestCase {
    /// 回调来自 delegate 队列，用锁保护的收集器让测试能安全地读。
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var pieces: [String] = []

        func add(_ piece: String) {
            lock.lock()
            pieces.append(piece)
            lock.unlock()
        }

        var joined: String {
            lock.lock()
            defer { lock.unlock() }
            return pieces.joined()
        }
    }

    private let fastBody = "新回答完整"
    private let slowChunk = "旧流分片"

    /// 起一个只答 SSE 的网关：`model == "slow"` 时每 25ms 吐一片，直到客户端
    /// 断开；其余请求立刻吐完整段，以 `[DONE]` 收尾。
    private func makeServer() async -> (GatewayHTTPServer, UInt16)? {
        let server = GatewayHTTPServer { [fastBody, slowChunk] request in
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            let model = body?["model"] as? String ?? ""
            if model == "slow" {
                return .sse { session in
                    for _ in 0..<120 where !session.isClosed {
                        let frame = "data: {\"choices\":[{\"delta\":{\"content\":\"\(slowChunk)\"}}]}\n\n"
                        if !session.write(frame) { return }
                        try? await Task.sleep(nanoseconds: 25_000_000)
                    }
                    session.close()
                }
            }
            return .sse { session in
                session.write("data: {\"choices\":[{\"delta\":{\"content\":\"\(fastBody)\"}}]}\n\n")
                session.write("data: [DONE]\n\n")
                session.close()
            }
        }
        // GatewayTests 用 39100…39140；这里换一段端口，避免并行测试撞车。
        for port in UInt16(39420)...UInt16(39460) {
            if await server.start(port: port) { return (server, port) }
        }
        return nil
    }

    private var options: ChatOptions {
        ChatOptions(temperature: 0.7, topP: 1, maxTokens: 0, reasoningEffort: nil, systemPrompt: "")
    }

    private func send(_ client: ChatClient, port: Int, model: String,
                      onDelta: @escaping @Sendable (String, Date) -> Void = { _, _ in })
        async -> Result<String, ChatError> {
        await client.send(port: port, model: model,
                          turns: [ChatTurn(role: "user", content: "你好")],
                          options: options,
                          onDelta: onDelta,
                          onReasoning: { _, _ in },
                          onUsage: { _ in },
                          onStatus: { _ in })
    }

    func testCancelThenResendKeepsTheNewStreamIntact() async throws {
        guard let (server, port) = await makeServer() else {
            throw XCTSkip("本地端口都被占用，跳过这条网络回归测试")
        }
        defer { server.stop() }

        let client = ChatClient()
        // 先让慢流跑起来：等它真的开始吐字，再发下一条。
        let slow = Task { await self.send(client, port: Int(port), model: "slow") }
        try await Task.sleep(nanoseconds: 250_000_000)

        let collected = Collector()
        let result = await send(client, port: Int(port), model: "fast") { piece, _ in
            collected.add(piece)
        }

        switch result {
        case .success(let text):
            XCTAssertEqual(text, fastBody)
        case .failure(let error):
            XCTFail("重发的新流被旧流收尾了：\(error.message)")
        }
        XCTAssertEqual(collected.joined, fastBody, "新流的回调里混进了旧请求的分片")
        _ = await slow.value
    }

    func testSequentialSendsBothComplete() async throws {
        guard let (server, port) = await makeServer() else {
            throw XCTSkip("本地端口都被占用，跳过这条网络回归测试")
        }
        defer { server.stop() }

        let client = ChatClient()
        for attempt in 0..<3 {
            let collected = Collector()
            let result = await send(client, port: Int(port), model: "fast") { piece, _ in
                collected.add(piece)
            }
            guard case .success(let text) = result else {
                return XCTFail("第 \(attempt + 1) 次请求失败：\(result)")
            }
            XCTAssertEqual(text, fastBody)
            XCTAssertEqual(collected.joined, fastBody)
        }
    }
}
