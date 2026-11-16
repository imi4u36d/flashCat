// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 一次失败的请求，带上客户端应当看到的状态码与错误类型。
/// `type` 走 Anthropic 的错误分类；OpenAI 直通路径的传输层失败（502/504）改抛
/// `upstream`，并把引擎自己的正文原样转出去。
public struct GatewayAPIError: Error {
    public var status: Int
    public var type: String
    public var message: String

    public init(status: Int, type: String, message: String) {
        self.status = status
        self.type = type
        self.message = message
    }

    public static func badRequest(_ message: String) -> GatewayAPIError {
        GatewayAPIError(status: 400, type: "invalid_request_error", message: message)
    }

    public static func notFound(_ message: String) -> GatewayAPIError {
        GatewayAPIError(status: 404, type: "not_found_error", message: message)
    }

    /// 引擎没在运行，或还没就绪。
    public static func overloaded(_ message: String) -> GatewayAPIError {
        GatewayAPIError(status: 503, type: "overloaded_error", message: message)
    }

    public func anthropicEnvelope() -> [String: Any] {
        ["type": "error", "error": ["type": type, "message": message]]
    }

    /// OpenAI 形状的错误，给直通路由用。
    public func openAIEnvelope() -> [String: Any] {
        ["error": ["message": message, "type": type, "code": nil]]
    }
}

/// 在 Anthropic Messages API 与 OpenAI Chat Completions API 之间做翻译。全是
/// 基于 `[String: Any]` JSON 的纯函数、不碰 I/O，所以整个表面都能单测。
///
/// 覆盖：system 提示、纯文本与多模态（base64 图片）内容、`tool_use` /
/// `tool_result` 块、`tools` / `tool_choice`、停止序列、采样参数、非流式响应，
/// 以及完整的 SSE 事件序列（`message_start` … `message_stop`），包括引擎上报
/// `reasoning_content` 时生成的 `thinking` 块。
public enum AnthropicCodec {

    // MARK: - Request: Anthropic → OpenAI（请求翻译：Anthropic 转 OpenAI）

    /// 为一份 `/v1/messages` 请求体拼出 OpenAI chat-completions 载荷。
    /// `stream` 单独返回，好让调用方挑传输方式。
    public static func translateRequest(_ payload: [String: Any]) throws -> (openai: [String: Any], stream: Bool) {
        guard let model = payload["model"] as? String, !model.isEmpty else {
            throw GatewayAPIError.badRequest("messages: model 是必填字段")
        }
        let maxTokens = (payload["max_tokens"] as? Int)
            ?? (payload["max_tokens"] as? Double).map(Int.init)
        guard let maxTokens, maxTokens > 0 else {
            throw GatewayAPIError.badRequest("max_tokens: 该字段必填，且必须是正整数")
        }
        guard let messages = payload["messages"] as? [[String: Any]], !messages.isEmpty else {
            throw GatewayAPIError.badRequest("messages: 该字段必填，且至少包含一条消息")
        }

        var openaiMessages: [[String: Any]] = []

        if let systemText = flattenText(payload["system"]), !systemText.isEmpty {
            openaiMessages.append(["role": "system", "content": systemText])
        }

        for (index, message) in messages.enumerated() {
            let role = (message["role"] as? String) ?? "user"
            guard role == "user" || role == "assistant" else {
                throw GatewayAPIError.badRequest("messages[\(index)].role: 只支持 user 或 assistant")
            }
            try appendMessage(role: role, content: message["content"], index: index, into: &openaiMessages)
        }

        var openai: [String: Any] = [
            "model": model,
            "messages": openaiMessages,
            "max_tokens": maxTokens,
        ]
        if let temperature = payload["temperature"] as? Double { openai["temperature"] = temperature }
        if let topP = payload["top_p"] as? Double { openai["top_p"] = topP }
        if let stop = payload["stop_sequences"] as? [String], !stop.isEmpty { openai["stop"] = stop }
        if let tools = translateTools(payload["tools"]) { openai["tools"] = tools }
        if let choice = translateToolChoice(payload["tool_choice"]) {
            openai["tool_choice"] = choice
        }

        let stream = (payload["stream"] as? Bool) ?? false
        // 上游必须**知道**这是流式请求：网关按 SSE 逐行转发、逐片打点，
        // 而引擎默认按非流式处理。以前这里只把 `stream` 交回调用方、没有写进
        // 上游请求体，引擎于是回一整块 JSON；转发层按 `data:` 行解析，一行都
        // 认不出来——Claude 的流式客户端只会收到 message_start / message_stop，
        // 正文全空，概览里这一路连 token 都没有。
        openai["stream"] = stream
        if stream {
            // 末片的 usage 带上 prompt/completion 与缓存命中量；网关要靠它
            // 校正计数，Anthropic 侧也要在 message_delta 里报 output_tokens。
            openai["stream_options"] = ["include_usage": true]
        }
        return (openai, stream)
    }

    /// 一条 Anthropic 消息会变成一到多条 OpenAI 消息：带 `tool_result` 块的
    /// user 轮次拆成若干 `role:"tool"` 消息，它同时携带的文本则再补一条普通
    /// user 消息。
    private static func appendMessage(role: String,
                                      content: Any?,
                                      index: Int,
                                      into openaiMessages: inout [[String: Any]]) throws {
        if let text = content as? String {
            openaiMessages.append(["role": role, "content": text])
            return
        }
        guard let blocks = content as? [[String: Any]] else {
            throw GatewayAPIError.badRequest("messages[\(index)].content: 必须是字符串或内容块数组")
        }

        var textParts: [String] = []
        var contentParts: [[String: Any]] = []
        var toolCalls: [[String: Any]] = []
        var toolResults: [[String: Any]] = []

        for (blockIndex, block) in blocks.enumerated() {
            let type = (block["type"] as? String) ?? ""
            switch type {
            case "text":
                let text = (block["text"] as? String) ?? ""
                if role == "assistant" {
                    textParts.append(text)
                } else {
                    contentParts.append(["type": "text", "text": text])
                }
            case "image":
                guard let part = translateImage(block) else {
                    throw GatewayAPIError.badRequest(
                        "messages[\(index)].content[\(blockIndex)].source: 仅支持 base64 或 URL 图片")
                }
                contentParts.append(part)
            case "tool_use":
                let arguments: Data
                if let input = block["input"], JSONSerialization.isValidJSONObject(input) {
                    arguments = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                } else {
                    arguments = Data("{}".utf8)
                }
                toolCalls.append([
                    "id": (block["id"] as? String) ?? "toolu_\(index)_\(blockIndex)",
                    "type": "function",
                    "function": [
                        "name": (block["name"] as? String) ?? "",
                        "arguments": String(data: arguments, encoding: .utf8) ?? "{}",
                    ],
                ])
            case "tool_result":
                let text = flattenText(block["content"]) ?? ""
                toolResults.append([
                    "role": "tool",
                    "tool_call_id": (block["tool_use_id"] as? String) ?? "",
                    "content": text,
                ])
            case "thinking", "redacted_thinking", "document", "search_result":
                // 引擎没办法把隐藏推理再喂回去；文档与网页结果也不在 OpenAI 接口
                // 里。直接跳过。
                continue
            default:
                throw GatewayAPIError.badRequest("messages[\(index)].content[\(blockIndex)].type: 不支持的内容块 \(type)")
            }
        }

        // OpenAI 要求同一轮里的工具回答排在最前面。
        openaiMessages.append(contentsOf: toolResults)

        if !toolCalls.isEmpty {
            var assistant: [String: Any] = ["role": "assistant", "tool_calls": toolCalls]
            let joined = textParts.joined()
            if !joined.isEmpty { assistant["content"] = joined } else { assistant["content"] = NSNull() }
            openaiMessages.append(assistant)
        } else if role == "assistant" {
            openaiMessages.append(["role": "assistant", "content": textParts.joined()])
        }

        if !contentParts.isEmpty {
            openaiMessages.append(["role": "user", "content": contentParts])
        }
    }

    private static func translateImage(_ block: [String: Any]) -> [String: Any]? {
        guard let source = block["source"] as? [String: Any] else { return nil }
        let type = (source["type"] as? String) ?? ""
        switch type {
        case "base64":
            guard let mediaType = source["media_type"] as? String,
                  let data = source["data"] as? String else { return nil }
            return ["type": "image_url",
                    "image_url": ["url": "data:\(mediaType);base64,\(data)"]]
        case "url":
            guard let url = source["url"] as? String else { return nil }
            return ["type": "image_url", "image_url": ["url": url]]
        default:
            return nil
        }
    }

    private static func translateTools(_ value: Any?) -> [[String: Any]]? {
        guard let tools = value as? [[String: Any]], !tools.isEmpty else { return nil }
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            var function: [String: Any] = ["name": name]
            if let description = tool["description"] as? String { function["description"] = description }
            if let schema = tool["input_schema"], JSONSerialization.isValidJSONObject(schema) {
                function["parameters"] = schema
            }
            return ["type": "function", "function": function]
        }
    }

    private static func translateToolChoice(_ value: Any?) -> Any? {
        guard let choice = value as? [String: Any], let type = choice["type"] as? String else { return nil }
        switch type {
        case "auto": return "auto"
        case "any": return "required"
        case "none": return "none"
        case "tool":
            guard let name = choice["name"] as? String else { return nil }
            return ["type": "function", "function": ["name": name]]
        default: return nil
        }
    }

    // MARK: - Response: OpenAI → Anthropic（响应翻译：OpenAI 转 Anthropic）

    public static func translateResponse(_ openai: [String: Any]) -> [String: Any] {
        let choices = openai["choices"] as? [[String: Any]] ?? []
        let choice = choices.first ?? [:]
        let message = choice["message"] as? [String: Any] ?? [:]

        var content: [[String: Any]] = []
        if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
            content.append(["type": "thinking", "thinking": reasoning])
        }
        if let text = message["content"] as? String, !text.isEmpty {
            content.append(["type": "text", "text": text])
        } else if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { content.append(["type": "text", "text": text]) }
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                let function = call["function"] as? [String: Any] ?? [:]
                let arguments = (function["arguments"] as? String) ?? "{}"
                let input = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)))
                    ?? ["_raw": arguments]
                content.append([
                    "type": "tool_use",
                    "id": (call["id"] as? String) ?? "toolu_unknown",
                    "name": (function["name"] as? String) ?? "",
                    "input": input,
                ])
            }
        }
        if content.isEmpty {
            content.append(["type": "text", "text": ""])
        }

        let usage = openai["usage"] as? [String: Any] ?? [:]
        return [
            "id": "msg_" + ((openai["id"] as? String) ?? UUID().uuidString),
            "type": "message",
            "role": "assistant",
            "model": (openai["model"] as? String) ?? "",
            "content": content,
            "stop_reason": stopReason(from: choice["finish_reason"] as? String,
                                      hasToolUse: content.contains { $0["type"] as? String == "tool_use" }),
            "stop_sequence": NSNull(),
            "usage": [
                "input_tokens": int(usage["prompt_tokens"]) ?? 0,
                "output_tokens": int(usage["completion_tokens"]) ?? 0,
            ],
        ]
    }

    private static func stopReason(from openaiReason: String?, hasToolUse: Bool) -> String {
        switch openaiReason {
        case "length": return "max_tokens"
        case "tool_calls", "function_call": return "tool_use"
        case "content_filter": return "refusal"
        default: return hasToolUse ? "tool_use" : "end_turn"
        }
    }

    // MARK: - Streaming: OpenAI chunks → Anthropic events（流式：分片转事件）

    /// 一次流式响应的有状态翻译器：吃进 OpenAI 的 `chat.completion.chunk` 对象，
    /// 吐出符合 Anthropic 事件语法的完整 SSE 帧。
    public final class StreamTranslator {
        private let model: String
        private var inputTokens = 0
        private var outputTokens = 0
        private enum BlockKind { case text, thinking }
        /// 当前打开的块。两个布尔量 + 「下标总是 nextBlockIndex-1」的写法在
        /// 「文本后又来思考」时会算错下标，把正文写进思考块。
        private var openBlock: (index: Int, kind: BlockKind)?
        /// OpenAI 的 tool-call 下标 → Anthropic 的块下标，给那些参数分好几片
        /// 流式到达的工具用。
        private var toolBlocks: [Int: Int] = [:]
        private var openBlocks: [Int] = []
        private var nextBlockIndex = 0
        private var stopReason: String?

        public init(model: String, inputTokens: Int = 0) {
            self.model = model
            self.inputTokens = inputTokens
        }

        /// `message_start`，外加开头一个 `ping`。
        public func startEvents() -> [String] {
            let message: [String: Any] = [
                "id": "msg_" + UUID().uuidString,
                "type": "message",
                "role": "assistant",
                "model": model,
                "content": [],
                "stop_reason": NSNull(),
                "stop_sequence": NSNull(),
                "usage": ["input_tokens": inputTokens, "output_tokens": 0],
            ]
            return [
                frame(event: "message_start",
                      object: ["type": "message_start", "message": message]),
                frame(object: ["type": "ping"]),
            ]
        }

        /// 把一片解析好的 OpenAI chunk 翻成零到多帧。
        public func consume(chunk: [String: Any]) -> [String] {
            var frames: [String] = []
            guard let choices = chunk["choices"] as? [[String: Any]] else {
                absorbUsage(chunk)
                return frames
            }
            let choice = choices.first ?? [:]
            let delta = choice["delta"] as? [String: Any] ?? [:]
            absorbUsage(chunk)

            // 会思考的引擎把隐藏推理放在 reasoning_content 里。
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                frames.append(contentsOf: openThinkingBlock())
                frames.append(thinkingDelta(reasoning))
            }
            if let text = delta["content"] as? String, !text.isEmpty {
                frames.append(contentsOf: openTextBlock())
                frames.append(textDelta(text))
            } else if let parts = delta["content"] as? [[String: Any]] {
                let text = parts.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty {
                    frames.append(contentsOf: openTextBlock())
                    frames.append(textDelta(text))
                }
            }
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for call in toolCalls {
                    frames.append(contentsOf: consumeToolCall(call))
                }
            }
            if let reason = choice["finish_reason"] as? String {
                stopReason = stopReason(from: reason)
            }
            return frames
        }

        /// 关掉还开着的块，并发出结尾事件。
        public func finishEvents() -> [String] {
            var frames: [String] = []
            for index in openBlocks.reversed() {
                frames.append(frame(object: ["type": "content_block_stop", "index": index]))
            }
            openBlocks.removeAll()
            openBlock = nil
            // 引擎始终没发 finish_reason 的工具块，收尾时照样按工具调用结束。
            let reason = stopReason ?? (toolBlocks.isEmpty ? "end_turn" : "tool_use")
            frames.append(frame(event: "message_delta", object: [
                "type": "message_delta",
                "delta": ["stop_reason": reason, "stop_sequence": NSNull()],
                "usage": ["output_tokens": outputTokens],
            ]))
            frames.append(frame(object: ["type": "message_stop"]))
            return frames
        }

        // MARK: private（内部实现）

        private func absorbUsage(_ chunk: [String: Any]) {
            guard let usage = chunk["usage"] as? [String: Any] else { return }
            if let prompt = int(usage["prompt_tokens"]), prompt > 0 { inputTokens = prompt }
            if let completion = int(usage["completion_tokens"]) { outputTokens = completion }
        }

        private func close(_ index: Int) -> String {
            if openBlock?.index == index { openBlock = nil }
            openBlocks.removeAll { $0 == index }
            return frame(object: ["type": "content_block_stop", "index": index])
        }

        private func openTextBlock() -> [String] { ensureBlock(.text) }
        private func openThinkingBlock() -> [String] { ensureBlock(.thinking) }

        /// Anthropic 的块不能交错：换类型时先把上一个块停掉，再开新的。
        private func ensureBlock(_ kind: BlockKind) -> [String] {
            if let current = openBlock, current.kind == kind { return [] }
            var frames: [String] = []
            if let current = openBlock {
                frames.append(close(current.index))
                openBlock = nil
            }
            let index = nextBlockIndex
            nextBlockIndex += 1
            openBlock = (index, kind)
            openBlocks.append(index)
            frames.append(frame(object: [
                "type": "content_block_start",
                "index": index,
                "content_block": kind == .text
                    ? ["type": "text", "text": ""]
                    : ["type": "thinking", "thinking": ""],
            ]))
            return frames
        }

        private func textDelta(_ text: String) -> String {
            let index = openBlock?.index ?? 0
            return frame(event: "content_block_delta", object: [
                "type": "content_block_delta",
                "index": index,
                "delta": ["type": "text_delta", "text": text],
            ])
        }

        private func thinkingDelta(_ text: String) -> String {
            let index = openBlock?.index ?? 0
            return frame(event: "content_block_delta", object: [
                "type": "content_block_delta",
                "index": index,
                "delta": ["type": "thinking_delta", "thinking": text],
            ])
        }

        private func consumeToolCall(_ call: [String: Any]) -> [String] {
            var frames: [String] = []
            let openaiIndex = int(call["index"]) ?? 0

            if toolBlocks[openaiIndex] == nil {
                // 先把开着的 text/thinking 块关掉：Anthropic 的块不能交错。
                if let current = openBlock {
                    frames.append(close(current.index))
                    openBlock = nil
                }
                let function = call["function"] as? [String: Any] ?? [:]
                let blockIndex = nextBlockIndex
                nextBlockIndex += 1
                toolBlocks[openaiIndex] = blockIndex
                openBlocks.append(blockIndex)
                frames.append(frame(object: [
                    "type": "content_block_start",
                    "index": blockIndex,
                    "content_block": [
                        "type": "tool_use",
                        "id": (call["id"] as? String) ?? "toolu_\(blockIndex)",
                        "name": (function["name"] as? String) ?? "",
                        "input": [:],
                    ],
                ]))
            }

            if let fragment = (call["function"] as? [String: Any])?["arguments"] as? String, !fragment.isEmpty {
                let index = toolBlocks[openaiIndex] ?? 0
                frames.append(frame(event: "content_block_delta", object: [
                    "type": "content_block_delta",
                    "index": index,
                    "delta": ["type": "input_json_delta", "partial_json": fragment],
                ]))
            }
            return frames
        }

        private func stopReason(from openaiReason: String) -> String {
            switch openaiReason {
            case "length": return "max_tokens"
            case "tool_calls", "function_call": return "tool_use"
            case "content_filter": return "refusal"
            default: return toolBlocks.isEmpty ? "end_turn" : "tool_use"
            }
        }
    }

    // MARK: - Errors（错误翻译）

    /// 把上游（OpenAI 形状）的错误改写成请求方言期望的信封。Anthropic 客户端
    /// 拿到 `type`/`message` 这一对；状态码不在这里处理——调用方沿用上游响应的
    /// `status`，本函数只在引擎没给 `type` 时按状态码推断一个。
    public static func errorEnvelope(from body: Data, upstreamStatus: Int) -> [String: Any] {
        if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "引擎返回错误"
            let type = (error["type"] as? String) ?? anthropicType(for: upstreamStatus)
            return ["type": "error", "error": ["type": type, "message": message]]
        }
        let text = String(data: body, encoding: .utf8) ?? ""
        let message = text.isEmpty ? "引擎返回 HTTP \(upstreamStatus)" : String(text.prefix(500))
        return ["type": "error", "error": ["type": anthropicType(for: upstreamStatus), "message": message]]
    }

    private static func anthropicType(for status: Int) -> String {
        switch status {
        case 400: return "invalid_request_error"
        case 401, 403: return "authentication_error"
        case 404: return "not_found_error"
        case 429: return "rate_limit_error"
        case 503, 529: return "overloaded_error"
        default: return "api_error"
        }
    }

    // MARK: - Token counting（token 估算）

    /// 给 `/v1/messages/count_tokens` 用的近似输入 token 数。权重口径与
    /// `TokenEstimator` 一致（CJK/全角约 1 字 1 token，其余约 4 字符 1 token），
    /// 但这里是整数累加、末尾直接截断，那边按小数权重向上取整，所以同一条文本两边
    /// 的结果不会完全相等；图片不计实际尺寸，按固定 1000 计。
    public static func countInputTokens(_ payload: [String: Any]) -> Int {
        var total = 0
        if let system = flattenText(payload["system"]) { total += estimate(system) }
        if let messages = payload["messages"] as? [[String: Any]] {
            for message in messages {
                total += count(message["content"])
            }
        }
        return total
    }

    private static func count(_ content: Any?) -> Int {
        if let text = content as? String { return estimate(text) }
        guard let blocks = content as? [[String: Any]] else { return 0 }
        var total = 0
        for block in blocks {
            switch (block["type"] as? String) ?? "" {
            case "text":
                total += estimate((block["text"] as? String) ?? "")
            case "image":
                total += 1_000
            case "tool_use":
                total += estimate((block["name"] as? String) ?? "") + 40
            case "tool_result":
                total += count(block["content"]) + 20
            case "thinking":
                total += estimate((block["thinking"] as? String) ?? "")
            default:
                break
            }
        }
        return total
    }

    public static func estimate(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3000...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
                cjk += 1
            default:
                other += 1
            }
        }
        return cjk + other / 4
    }

    // MARK: - helpers（辅助函数）

    private static func flattenText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" || block["text"] != nil else { return nil }
            return block["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// 一帧完整的 SSE：带名事件（当客户端需要靠它分发时）加上 JSON 载荷。
    public static func frame(event: String? = nil, object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        var result = ""
        // 官方 API 每一帧都带 `event:`，SDK 靠它分发；只给 data 的话
        // content_block_start / message_stop 会被丢掉，客户端一直等不到结尾。
        let name = event ?? (object as? [String: Any])?["type"] as? String
        if let name { result += "event: \(name)\n" }
        result += "data: \(String(data: data, encoding: .utf8) ?? "{}")\n\n"
        return result
    }
}
