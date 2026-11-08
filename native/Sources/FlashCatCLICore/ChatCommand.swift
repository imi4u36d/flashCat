import Foundation
import FlashCatKit

public enum ChatCommand {
    public static func run(_ context: CLIContext) async throws -> Int32 {
        let prompt = try readPrompt(context)
        let gateway = try await resolveGateway(context)
        let model = try await resolveModel(context, gateway: gateway)
        let stream = shouldStream(context)

        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "messages": [["role": "user", "content": prompt]],
            "temperature": numberOption(context, "temperature", fallback: context.local.double("chat.temperature", fallback: 0.7)),
            "top_p": numberOption(context, "top-p", fallback: context.local.double("chat.topP", fallback: 0.95)),
        ]
        let maxTokens = Int(context.invocation.option("max-tokens") ?? "") ?? context.local.integer("chat.maxTokens", fallback: 0)
        if maxTokens > 0 { body["max_tokens"] = maxTokens }
        if stream { body["stream_options"] = ["include_usage": true] }
        if let system = context.invocation.option("system"), !system.isEmpty {
            body["messages"] = [["role": "system", "content": system],
                                ["role": "user", "content": prompt]]
        }

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw CLIError("无法编码对话请求")
        }
        var request = URLRequest(url: gateway.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = context.longTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("flashcat-cli", forHTTPHeaderField: "User-Agent")
        request.httpBody = payload

        let started = Date()
        let result: ChatResult
        if stream {
            result = try await consumeStream(context, request: request, model: model, started: started)
        } else {
            result = try await consumeJSON(context, request: request, model: model, started: started)
        }
        if context.output.json {
            context.output.json(result)
        } else if !result.content.isEmpty {
            if result.content.hasSuffix("\n") == false { context.output.line() }
            if context.isTTY && !context.output.quiet {
                context.output.note(statsLine(result))
            }
        }
        return CLIExit.success.rawValue
    }

    // MARK: Prompt

    private static func readPrompt(_ context: CLIContext) throws -> String {
        // `chat -` is the explicit "read stdin" spelling: it must work even
        // when stdout is a terminal (the common `echo … | flashcat chat -`
        // case) and lets an interactive user end input with Ctrl-D.
        let explicitStdin = context.invocation.arguments == ["-"]
        let parts = explicitStdin ? [] : context.invocation.arguments
        if !parts.isEmpty {
            let text = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw CLIError("提示词不能为空", exit: .usage) }
            return text
        }
        guard !context.stdinIsTTY || explicitStdin else {
            throw CLIError("需要提示词", exit: .usage,
                           hint: "例如 flashcat chat \"你好\"，或 echo 你好 | flashcat chat -")
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw CLIError("stdin 里没有提示词", exit: .usage) }
        return text
    }

    // MARK: Gateway

    /// Prefer the running app's gateway record; fall back to the configured
    /// port when the control interface is disabled.
    private static func resolveGateway(_ context: CLIContext) async throws -> URL {
        if let explicit = context.invocation.option("gateway-url") ?? context.environment["FLASHCAT_GATEWAY_URL"],
           var url = URL(string: explicit) {
            if url.path.hasSuffix("/v1") { url.deleteLastPathComponent() }
            guard portOpen(url.port ?? 80) else {
                throw CLIError("网关不可达：\(explicit)", exit: .notRunning,
                               hint: "先运行 flashcat app open 或 flashcat gateway start")
            }
            return url
        }
        if let location = try? context.control,
           let status: ControlStatus = try? await location.client.get("/v1/status", timeout: context.timeout) {
            if !status.gateway.running {
                guard status.gateway.enabled else {
                    throw CLIError("API 网关已关闭", exit: .conflict,
                                   hint: "运行 flashcat gateway start 打开它")
                }
                _ = try? await location.client.postData("/v1/gateway/start",
                                                        body: Data("{}".utf8),
                                                        timeout: 10)
                let deadline = Date().addingTimeInterval(15)
                while Date() < deadline {
                    if let again: ControlStatus = try? await location.client.get("/v1/status",
                                                                                 timeout: 5),
                       again.gateway.running,
                       let url = URL(string: again.gateway.baseURL) {
                        return url
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                throw CLIError("API 网关没有启动起来", exit: .timeout,
                               hint: "看 flashcat logs --gateway")
            }
            guard let url = URL(string: status.gateway.baseURL) else {
                throw CLIError("网关地址无效", exit: .failure)
            }
            return url
        }
        let port = context.local.gatewayPort
        guard context.local.gatewayEnabled, portOpen(port) else {
            throw CLIError("连不上本地网关（127.0.0.1:\(port)）", exit: .notRunning,
                           hint: "先运行 flashcat app open；网关关闭时用 flashcat gateway start")
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)") else {
            throw CLIError("网关地址无效", exit: .failure)
        }
        return url
    }

    // MARK: Model

    private static func resolveModel(_ context: CLIContext, gateway: URL) async throws -> String {
        if let model = context.invocation.option("model"), !model.isEmpty { return model }
        if let engine = context.invocation.option("engine") {
            guard let id = EngineID(rawValue: engine) else {
                throw CLIError("未知引擎：\(engine)", exit: .usage)
            }
            if let location = try? context.control {
                var query = [URLQueryItem(name: "all", value: "false")]
                query.append(URLQueryItem(name: "engine", value: id.rawValue))
                if let models: [ControlModelSummary] = try? await location.client.get("/v1/models",
                                                                                       query: query,
                                                                                       timeout: context.timeout),
                   let first = models.first(where: { !$0.helper }) {
                    return first.id
                }
            }
            if let first = context.local.localModels(engine: id).first {
                return first.id
            }
            throw CLIError("\(id.displayName) 没有可用模型", exit: .notFound)
        }
        if let location = try? context.control,
           let status: ControlStatus = try? await location.client.get("/v1/status", timeout: context.timeout),
           let model = status.engine?.model, !model.isEmpty {
            return model
        }
        if !context.local.selectedModel.isEmpty { return context.local.selectedModel }

        // Last resort: ask the gateway what it can serve. This also covers a
        // client that pinned a model in a different engine.
        if let models: OpenAIModels = try? await fetchModels(gateway: gateway), let first = models.data.first {
            return first.id
        }
        throw CLIError("没有可用模型", exit: .notFound,
                       hint: "先运行 flashcat models download <repo> 或 flashcat models use <模型>")
    }

    private struct OpenAIModels: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }

    private static func fetchModels(gateway: URL) async throws -> OpenAIModels {
        var request = URLRequest(url: gateway.appendingPathComponent("v1/models"))
        request.timeoutInterval = 10
        let (data, _) = try await CLIHTTP.session().data(for: request)
        return try JSONDecoder().decode(OpenAIModels.self, from: data)
    }

    // MARK: Streaming

    public struct Usage: Encodable {
        public var promptTokens: Int?
        public var completionTokens: Int?
    }

    public struct ChatResult: Encodable {
        public var model: String
        public var content: String
        public var reasoning: String
        public var finishReason: String?
        public var usage: Usage?
        public var seconds: Double
        public var tokensPerSecond: Double?
    }

    private static func shouldStream(_ context: CLIContext) -> Bool {
        if context.invocation.flag("no-stream") { return false }
        if context.invocation.flag("stream") { return true }
        return context.isTTY && !context.output.json
    }

    private static func consumeStream(_ context: CLIContext,
                                      request: URLRequest,
                                      model: String,
                                      started: Date) async throws -> ChatResult {
        var decoder = SSEAccumulator(model: model)
        let (bytes, response) = try await CLIHTTP.session().bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var data = Data()
            do {
                for try await byte in bytes { data.append(byte) }
            } catch {
                // A partial error body still names the failure.
            }
            throw gatewayError(data, status: status)
        }
        do {
            for try await line in bytes.lines {
                let events = decoder.consume(line: line)
                for event in events {
                    switch event {
                    case .content(let text):
                        if !context.output.json { context.output.write(text) }
                    case .reasoning(let text):
                        if context.invocation.flag("show-reasoning") && !context.output.json {
                            context.output.errorText(context.output.dim(text))
                        }
                    }
                }
            }
        } catch {
            throw CLIError("对话流中断：\(error.localizedDescription)")
        }
        if let error = decoder.errorMessage {
            throw CLIError("网关错误：\(error)")
        }
        return decoder.finish(started: started)
    }

    private static func consumeJSON(_ context: CLIContext,
                                    request: URLRequest,
                                    model: String,
                                    started: Date) async throws -> ChatResult {
        let (data, response) = try await CLIHTTP.session().data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw gatewayError(data, status: status)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw CLIError("网关返回了无法解析的响应")
        }
        let content = (message["content"] as? String) ?? ""
        let reasoning = (message["reasoning_content"] as? String)
            ?? (message["reasoning"] as? String) ?? ""
        if !context.output.json {
            if !content.isEmpty { context.output.write(content) }
        }
        let seconds = Date().timeIntervalSince(started)
        var usage: Usage?
        if let raw = object["usage"] as? [String: Any] {
            usage = Usage(promptTokens: raw["prompt_tokens"] as? Int,
                          completionTokens: raw["completion_tokens"] as? Int)
        }
        let completion = usage?.completionTokens
        return ChatResult(model: model,
                          content: content,
                          reasoning: reasoning,
                          finishReason: choices.first?["finish_reason"] as? String,
                          usage: usage,
                          seconds: seconds,
                          tokensPerSecond: completion.map { Double($0) / max(seconds, 0.001) })
    }

    private static func gatewayError(_ data: Data, status: Int) -> CLIError {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return CLIError("网关错误：\(message)", exit: status == 404 ? .notFound : .failure)
            }
            if let message = object["message"] as? String {
                return CLIError("网关错误：\(message)", exit: .failure)
            }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return CLIError("网关返回 HTTP \(status)\(text.isEmpty ? "" : "：\(text)")",
                        exit: status == 404 ? .notFound : .failure)
    }

    private static func statsLine(_ result: ChatResult) -> String {
        var parts = [result.model]
        if let tokens = result.usage?.completionTokens { parts.append("\(tokens) tokens") }
        if let rate = result.tokensPerSecond { parts.append(String(format: "%.1f tok/s", rate)) }
        parts.append(String(format: "%.1f s", result.seconds))
        return parts.joined(separator: " · ")
    }

    private static func numberOption(_ context: CLIContext, _ key: String, fallback: Double) -> Double {
        guard let raw = context.invocation.option(key), let value = Double(raw) else { return fallback }
        return value
    }
}

/// Parses the OpenAI SSE frames used by `/v1/chat/completions`. Split out and
/// kept free of I/O so the decoder can be unit tested with a line array.
public struct SSEAccumulator {
    public enum Event: Equatable {
        case content(String)
        case reasoning(String)
    }

    public private(set) var content = ""
    public private(set) var reasoning = ""
    public private(set) var finishReason: String?
    public private(set) var promptTokens: Int?
    public private(set) var completionTokens: Int?
    public private(set) var errorMessage: String?
    public var model: String

    public init(model: String) {
        self.model = model
    }

    public mutating func consume(line: String) -> [Event] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("data:") else { return [] }
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return [] }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        if let error = object["error"] as? [String: Any] {
            errorMessage = (error["message"] as? String) ?? "网关返回了错误"
            return []
        }
        if let usage = object["usage"] as? [String: Any] {
            promptTokens = usage["prompt_tokens"] as? Int
            completionTokens = usage["completion_tokens"] as? Int
        }
        guard let choices = object["choices"] as? [[String: Any]],
              let choice = choices.first else { return [] }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
            finishReason = reason
        }
        guard let delta = choice["delta"] as? [String: Any] else { return [] }
        var events: [Event] = []
        if let text = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String),
           !text.isEmpty {
            reasoning += text
            events.append(.reasoning(text))
        }
        if let text = delta["content"] as? String, !text.isEmpty {
            content += text
            events.append(.content(text))
        }
        return events
    }

    public func finish(started: Date) -> ChatCommand.ChatResult {
        let seconds = Date().timeIntervalSince(started)
        return ChatCommand.ChatResult(model: model,
                                      content: content,
                                      reasoning: reasoning,
                                      finishReason: finishReason,
                                      usage: ChatCommand.Usage(promptTokens: promptTokens,
                                                               completionTokens: completionTokens),
                                      seconds: seconds,
                                      tokensPerSecond: completionTokens.map {
                                          Double($0) / max(seconds, 0.001)
                                      })
    }
}

