import Foundation

struct ChatTurn {
    let role: String
    let content: String
}

struct ChatUsage: Equatable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    /// 命中前缀缓存、没有真正前向的提示词 token。算预填充速度时要扣掉，
    /// 否则同一会话的第二轮会把整段上下文都当成刚算过。
    var cachedPromptTokens: Int = 0
    /// usage.completion_tokens_details.reasoning_tokens —— 思考流的 token 数。
    /// 引擎按思考预算收束思考时，该值正好等于预算，可据此判定"思考被截断"。
    var reasoningTokens: Int?
    /// 本轮结束原因（choice.finish_reason）。`length` 意味着输出触及
    /// max_tokens 上限被硬截断——思考与正文共享该上限，思考一长正文就没了。
    var finishReason: String?
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: String
    var content: String
    var model: String?
    var createdAt: Date?
    var usage: ChatUsage?
    var seconds: Double?
    var tokensPerSecond: Double?
    var firstTokenSeconds: Double?
    /// 从发起请求到正文首字的时间。有 reasoning 时，这段就是「思考」的时长，
    /// 随消息一起落盘，旧回答在折叠块里仍能显示「思考了 8.4 秒」。
    var thinkingSeconds: Double?
    /// 思考模型的 reasoning 流，单独于正文展示（对话页的「思考过程」块）。
    var reasoning: String?
    var streaming = false

    var tokenCount: Int { usage?.completionTokens ?? 0 }

    var rateText: String? {
        if let tokensPerSecond, tokensPerSecond > 0 {
            return String(format: "%.1f tok/s", tokensPerSecond)
        }
        return nil
    }
}

struct ChatOptions {
    var temperature: Double
    var topP: Double
    var maxTokens: Int
    var reasoningEffort: String?
    var systemPrompt: String
    /// 引擎侧生效的思考截断预算（splash `--thinking-token-budget` / oMLX
    /// `thinking_budget_tokens`），只用于本地判定截断，不随请求下发。
    var thinkingBudget: Int? = nil
}

struct ChatError: Error {
    let message: String
}

/// Streaming client for /v1/chat/completions. Delegate based so a generation
/// can really be cancelled mid-stream.
///
/// 每个请求独占一份流状态（`Request`），delegate 回调按 task 的身份认领。
/// `URLSession` 在 `cancel()` 之后仍会把被取消 task 的 didReceive / didComplete
/// 投递到 delegate 队列；这些回调如果写的是「当前请求」的共享字段，用户点
/// 「停止」后立刻重发时，新请求会被旧回调提前收尾（表现为「服务没有返回内容」），
/// 新流的缓冲区也会被旧分片污染。按 task 认领之后，迟到的回调只会落到它自己
/// 那份已经归档的状态上。
final class ChatClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// 一个请求的全部可变状态。delegate 队列写、`send` 在读 continuation
    /// 恢复之后读；`requests` 表的增删由 `lock` 保护，字段本身不再加锁。
    private final class Request {
        let task: URLSessionDataTask
        var continuation: CheckedContinuation<Void, Never>?
        var buffer = Data()
        var trailing = Data()
        var text = ""
        var raw = ""
        /// 本次流里出现过思考内容。思考被 max_tokens 掐断时正文为空，
        /// 这不应算失败——思考块还得留在对话里给人看。
        var reasoned = false
        var usage = ChatUsage()
        var status = 0
        var transportError: Error?
        /// `cancel()` 打过的标记，收尾时用来区分「用户停止」与「网络失败」。
        var cancelled = false
        var finished = false

        /// 流式回调合并缓冲：SSE 分片可能每秒上百个，逐片回调会让上层为每个
        /// 分片创建一次主线程任务并触发整页重绘。这里按固定节奏合并成一批，
        /// 既保留实时感，又把主线程唤醒次数压到约 30 次/秒。
        var pendingDelta = ""
        var pendingReasoning = ""
        var lastDeltaFlush = Date.distantPast
        static let deltaFlushInterval: TimeInterval = 1.0 / 30.0

        /// 回调都带上分片到达的时刻：解码测速只该相信网络侧的时钟，不能等主线程
        /// 排到这条任务时才取时间（UI 忙时会把一批分片挤成「瞬间到达」）。
        let onDelta: @Sendable (String, Date) -> Void
        let onReasoning: @Sendable (String, Date) -> Void
        let onUsage: @Sendable (ChatUsage) -> Void
        let onStatus: @Sendable (String) -> Void

        init(task: URLSessionDataTask,
             onDelta: @escaping @Sendable (String, Date) -> Void,
             onReasoning: @escaping @Sendable (String, Date) -> Void,
             onUsage: @escaping @Sendable (ChatUsage) -> Void,
             onStatus: @escaping @Sendable (String) -> Void) {
            self.task = task
            self.onDelta = onDelta
            self.onReasoning = onReasoning
            self.onUsage = onUsage
            self.onStatus = onStatus
        }

        func cancel() {
            cancelled = true
            task.cancel()
        }

        func receive(_ data: Data) {
            buffer.append(data)
            // 一次回调里可能有多行。旧实现每处理一行就 `removeSubrange` 一次，
            // 每次都搬移剩余字节，长流上是 O(n²)；这里只在最后裁掉已消费的前缀。
            var consumed = buffer.startIndex
            while let newline = buffer[consumed...].firstIndex(of: 0x0A) {
                consume(buffer[consumed..<newline])
                consumed = buffer.index(after: newline)
            }
            if consumed > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<consumed)
            }
            trailing = buffer
        }

        func consume(_ line: Data) {
            // 用 `.whitespacesAndNewlines`：CRLF 流的分片行尾带 `\r`，
            // 只裁空格时 `[DONE]` 永远匹配不上。
            let trimmed = String(data: line, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty { return }
            if !trimmed.hasPrefix("data:") {
                raw += trimmed
                return
            }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" {
                flushDelta(force: true)
                return
            }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                if text.isEmpty { text = "服务错误：\(message)" }
                return
            }
            // OpenAI chunk shape: {"choices":[{"delta":{"content":"…"}}]}
            var chunk: [String: Any]?
            var finishReason: String?
            if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
                chunk = (first["delta"] as? [String: Any]) ?? (first["message"] as? [String: Any])
                finishReason = first["finish_reason"] as? String
            }
            chunk = chunk ?? (json["delta"] as? [String: Any]) ?? (json["message"] as? [String: Any])

            if let chunk {
                // 正文与思考流分开：reasoning_content 只进思考块，不混入回答。
                if let content = chunk["content"] as? String, !content.isEmpty {
                    text += content
                    pendingDelta += content
                }
                // 不同引擎对思考流的字段名不一致：OpenAI 兼容层常见
                // `reasoning_content`，部分本地引擎用 `reasoning` 或 `thinking`，
                // 也有的把片段包在 `reasoning_details` 数组里。
                let reasoningPiece = (chunk["reasoning_content"] as? String)
                    ?? (chunk["reasoning"] as? String)
                    ?? (chunk["thinking"] as? String)
                    ?? Self.reasoningDetails(chunk["reasoning_details"])
                    ?? ""
                if !reasoningPiece.isEmpty {
                    reasoned = true
                    pendingReasoning += reasoningPiece
                }
            }
            if let finishReason, finishReason != "stop" {
                usage.finishReason = finishReason
            }
            if let used = json["usage"] as? [String: Any] {
                usage.promptTokens = Self.intValue(used["prompt_tokens"])
                usage.completionTokens = Self.intValue(used["completion_tokens"])
                if let details = used["prompt_tokens_details"] as? [String: Any] {
                    usage.cachedPromptTokens = Self.intValue(details["cached_tokens"])
                }
                if let details = used["completion_tokens_details"] as? [String: Any] {
                    let reasoning = Self.intValue(details["reasoning_tokens"])
                    if reasoning > 0 { usage.reasoningTokens = reasoning }
                }
            }
            flushDelta()
        }

        /// 把攒下的正文/思考分片按节奏交给上层。`force` 用于流结束和 `[DONE]`，
        /// 保证最后一批不会因为没到间隔而丢掉。
        func flushDelta(force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastDeltaFlush) >= Self.deltaFlushInterval else { return }
            lastDeltaFlush = now
            if !pendingDelta.isEmpty {
                let piece = pendingDelta
                pendingDelta = ""
                onDelta(piece, now)
            }
            if !pendingReasoning.isEmpty {
                let piece = pendingReasoning
                pendingReasoning = ""
                onReasoning(piece, now)
            }
        }

        /// 少数兼容层把思考片段放进 `reasoning_details: [{text: "…"}]`。
        private static func reasoningDetails(_ value: Any?) -> String? {
            guard let items = value as? [[String: Any]] else { return nil }
            let text = items.compactMap { item in
                (item["text"] as? String) ?? (item["content"] as? String) ?? (item["reasoning"] as? String)
            }.joined()
            return text.isEmpty ? nil : text
        }

        private static func intValue(_ value: Any?) -> Int {
            if let value = value as? Int { return value }
            if let value = value as? Double { return Int(value) }
            return 0
        }

        func readableError(status: Int) -> String {
            if let data = raw.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            return "服务返回 HTTP \(status)"
        }
    }

    private let lock = NSLock()
    /// 还没收尾的请求，按 task 对象认领。通常只有一条；用户停止后立刻重发时
    /// 会短暂有两条——被取消的那条要等 URLSession 送达 didComplete 才会离场。
    private var requests: [ObjectIdentifier: Request] = [:]
    private var current: Request?
    private var storedUsage = ChatUsage()

    /// 本次流结束后引擎报告的 usage。`onUsage` 走的是主线程任务，收尾判断
    /// 可能先于它执行；直接读这份终值，消息下方那个总平均就不会退化成估算。
    var lastUsage: ChatUsage {
        lock.lock()
        defer { lock.unlock() }
        return storedUsage
    }

    /// 是否有请求还没收尾。取消之后、didComplete 送达之前仍是 true。
    var isGenerating: Bool {
        lock.lock()
        defer { lock.unlock() }
        return current.map { !$0.finished } ?? false
    }

    func cancel() {
        lock.lock()
        let request = current
        lock.unlock()
        request?.cancel()
    }

    private func install(_ request: Request) {
        lock.lock()
        let superseded = current
        current = request
        requests[ObjectIdentifier(request.task)] = request
        lock.unlock()
        // 先把新请求挂上去再取消旧请求：旧 task 的 didComplete 可能就在这一刻
        // 投递，它已经认不出「当前」是谁，只会收尾自己那一份。
        superseded?.cancel()
    }

    private func request(for task: URLSessionTask) -> Request? {
        lock.lock()
        defer { lock.unlock() }
        return requests[ObjectIdentifier(task)]
    }

    /// 收尾时的记账：usage 留给 `lastUsage`，当前指针只清自己那一份。
    /// `NSLock` 不能直接在 async 函数里用，所以拆成同步方法。
    private func settle(_ stream: Request) {
        lock.lock()
        storedUsage = stream.usage
        if current === stream { current = nil }
        lock.unlock()
    }

    /// 把 task 从表里摘掉，保证它的 continuation 只恢复一次。
    private func retire(_ task: URLSessionTask) -> Request? {
        lock.lock()
        defer { lock.unlock() }
        let request = requests.removeValue(forKey: ObjectIdentifier(task))
        if let request, current === request { current = nil }
        return request
    }

    func send(port: Int,
              model: String,
              turns: [ChatTurn],
              options: ChatOptions,
              onDelta: @escaping @Sendable (String, Date) -> Void,
              onReasoning: @escaping @Sendable (String, Date) -> Void,
              onUsage: @escaping @Sendable (ChatUsage) -> Void,
              onStatus: @escaping @Sendable (String) -> Void) async -> Result<String, ChatError> {
        cancel()

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "temperature": options.temperature,
            "top_p": options.topP,
            // 流式也要拿 usage（含 reasoning_tokens），否则截断无从判定。
            "stream_options": ["include_usage": true],
        ]
        if options.maxTokens > 0 { body["max_tokens"] = options.maxTokens }
        if let effort = options.reasoningEffort, !effort.isEmpty { body["reasoning_effort"] = effort }

        var messages: [[String: String]] = []
        if !options.systemPrompt.isEmpty { messages.append(["role": "system", "content": options.systemPrompt]) }
        for turn in turns where !turn.content.isEmpty {
            messages.append(["role": turn.role, "content": turn.content])
        }
        body["messages"] = messages

        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
            onStatus("失败")
            return .failure(ChatError(message: "本地网关地址无效：端口 \(port)"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            onStatus("失败")
            return .failure(ChatError(message: "请求体编码失败：\(error.localizedDescription)"))
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let dataTask = session.dataTask(with: request)
        let stream = Request(task: dataTask, onDelta: onDelta, onReasoning: onReasoning,
                             onUsage: onUsage, onStatus: onStatus)
        install(stream)
        onStatus("生成中")

        await withCheckedContinuation { continuation in
            stream.continuation = continuation
            dataTask.resume()
        }
        stream.continuation = nil
        if !stream.trailing.isEmpty { stream.consume(stream.trailing) }
        stream.trailing = Data()
        stream.flushDelta(force: true)
        session.finishTasksAndInvalidate()

        settle(stream)

        if stream.cancelled {
            onStatus("已取消")
            return .failure(ChatError(message: "已取消"))
        }
        if let error = stream.transportError ?? dataTask.error {
            let cancelled = (error as? URLError)?.code == .cancelled
            onStatus(cancelled ? "已取消" : "失败")
            return .failure(ChatError(message: cancelled ? "已取消" : error.localizedDescription))
        }
        if stream.status < 200 || stream.status >= 300 {
            onStatus("失败")
            return .failure(ChatError(message: stream.readableError(status: stream.status)))
        }
        if stream.text.isEmpty && !stream.raw.isEmpty {
            // Some builds answer with a single JSON document instead of SSE.
            if let json = try? JSONSerialization.jsonObject(with: stream.raw.data(using: .utf8) ?? Data()) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                stream.text = content
                onDelta(content, Date())
            }
        }
        if stream.text.isEmpty && !stream.reasoned {
            onStatus("失败")
            return .failure(ChatError(message: "服务没有返回内容"))
        }
        onUsage(stream.usage)
        onStatus("完成")
        return .success(stream.text)
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        request(for: dataTask)?.status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        request(for: dataTask)?.receive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let request = retire(task) else { return }
        request.transportError = error
        request.flushDelta(force: true)
        request.finished = true
        let continuation = request.continuation
        request.continuation = nil
        continuation?.resume()
    }
}
