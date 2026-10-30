import Foundation
import SwiftUI
import FlashCatKit

/// The local API gateway: one fixed port that speaks both standard dialects —
/// OpenAI (`/v1/chat/completions`, `/v1/models`) and Anthropic
/// (`/v1/messages`, `/v1/messages/count_tokens`) — over every engine flashCat
/// manages. Clients pin their Base URL once and it keeps working across
/// engine switches and port changes.
///
/// Requests forward to the engine that is currently running. The model list is
/// unified: every installed engine's models show up, with the loaded one
/// marked, so `/v1/models` answers the same way the big cloud APIs do.
@MainActor
final class GatewayController: ObservableObject {
    static let shared = GatewayController()

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = GatewayDefaults.port
    @Published private(set) var failureMessage: String?

    let logs = LogStore(path: Paths.logsDirectory + "/gateway.log")
    private var server: GatewayHTTPServer?

    enum GatewayDefaults {
        static let port: UInt16 = 9000
    }

    private init() {}

    var baseURL: String { "http://127.0.0.1:\(port)" }

    // MARK: lifecycle

    func start(port: UInt16) async {
        guard server == nil else { return }
        logs.openFile()
        logs.append("==> 启动 API 网关 · 端口 \(port)", level: .system)
        let newServer = GatewayHTTPServer { [weak self] request in
            await self?.route(request) ?? GatewayResponse.json(
                ["type": "error", "error": ["type": "api_error", "message": "gateway unavailable"]],
                status: 500)
        }
        guard await newServer.start(port: port) else {
            failureMessage = "端口 \(port) 被占用，网关未启动"
            logs.append("==> \(failureMessage!)", level: .error)
            isRunning = false
            return
        }
        server = newServer
        self.port = port
        failureMessage = nil
        isRunning = true
        logs.append("==> API 网关已就绪 · OpenAI /v1/chat/completions · Claude /v1/messages", level: .system)
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        logs.append("==> API 网关已停止", level: .system)
    }

    // MARK: routing

    nonisolated func route(_ request: GatewayRequest) async -> GatewayResponse {
        // Fast paths off the main actor; state reads hop in briefly.
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/health"):
            return await MainActor.run { Self.healthDocument() }
        case ("GET", "/v1/models"):
            return await MainActor.run { self.modelsDocument(request) }
        case ("POST", "/v1/messages/count_tokens"):
            return await MainActor.run { Self.countTokensDocument(request) }
        default:
            break
        }

        // /v1/models/<id>
        if request.method == "GET", request.path.hasPrefix("/v1/models/") {
            let id = String(request.path.dropFirst("/v1/models/".count))
            return await MainActor.run { self.singleModelDocument(id: id, request: request) }
        }

        guard request.method == "POST" else {
            return Self.errorResponse(GatewayAPIError(status: 405, type: "invalid_request_error",
                                                      message: "method \(request.method) is not supported"),
                                      anthropic: request.isAnthropicStyle)
        }

        switch request.path {
        case "/v1/chat/completions":
            return await self.proxyChatCompletions(request)
        case "/v1/messages":
            return await self.anthropicMessages(request)
        default:
            return Self.errorResponse(
                GatewayAPIError(status: 404, type: "not_found_error",
                                message: "未知路径 \(request.path)；可用：/v1/chat/completions（OpenAI）、/v1/messages（Claude）、/v1/models"),
                anthropic: request.isAnthropicStyle)
        }
    }

    // MARK: documents

    nonisolated private static func healthDocument() -> GatewayResponse {
        GatewayResponse.json([
            "service": "flashcat-gateway",
            "status": "ok",
            "endpoints": [
                "openai": "/v1/chat/completions",
                "anthropic": "/v1/messages",
                "models": "/v1/models",
            ],
        ])
    }

    /// Every installed engine's models, deduplicated (the active engine wins),
    /// each entry carrying the engine that serves it and whether its weights
    /// are resident right now.
    private func modelEntries() -> [(id: String, engine: EngineID, loaded: Bool)] {
        guard let state = Optional(AppState.shared) else { return [] }
        var seen = Set<String>()
        var entries: [(id: String, engine: EngineID, loaded: Bool)] = []
        let ordered = [state.activeEngine] + state.availableEngines.filter { $0 != state.activeEngine }
        for engine in ordered {
            guard let controller = state.engines?.controller(engine) else { continue }
            let resident = Set(controller.status?.loadedModels ?? [])
            for model in state.engineModels(for: engine) where !seen.contains(model.id) {
                seen.insert(model.id)
                entries.append((model.id, engine, resident.contains(model.id)))
            }
        }
        return entries
    }

    private func modelsDocument(_ request: GatewayRequest) -> GatewayResponse {
        let entries = modelEntries()
        if request.isAnthropicStyle {
            let models: [[String: Any]] = entries.map { entry in
                [
                    "type": "model",
                    "id": entry.id,
                    "display_name": entry.id,
                    "created_at": "2026-01-01T00:00:00Z",
                ]
            }
            return GatewayResponse.json([
                "data": models,
                "first_id": models.first?["id"] ?? NSNull(),
                "has_more": false,
                "last_id": models.last?["id"] ?? NSNull(),
            ])
        }
        let models: [[String: Any]] = entries.map { entry in
            [
                "id": entry.id,
                "object": "model",
                "created": 1767225600,
                "owned_by": "flashcat:\(entry.engine.rawValue)",
                "loaded": entry.loaded,
            ]
        }
        return GatewayResponse.json(["object": "list", "data": models])
    }

    private func singleModelDocument(id: String, request: GatewayRequest) -> GatewayResponse {
        let entry = modelEntries().first { $0.id == id }
        guard let entry else {
            return Self.errorResponse(GatewayAPIError.notFound("没有模型 \(id)"), anthropic: request.isAnthropicStyle)
        }
        if request.isAnthropicStyle {
            return GatewayResponse.json([
                "type": "model",
                "id": entry.id,
                "display_name": entry.id,
                "created_at": "2026-01-01T00:00:00Z",
            ])
        }
        return GatewayResponse.json([
            "id": entry.id,
            "object": "model",
            "created": 1767225600,
            "owned_by": "flashcat:\(entry.engine.rawValue)",
            "loaded": entry.loaded,
        ])
    }

    nonisolated private static func countTokensDocument(_ request: GatewayRequest) -> GatewayResponse {
        guard let payload = Self.parseObject(request.body) else {
            return errorResponse(GatewayAPIError.badRequest("请求体不是合法的 JSON"), anthropic: true)
        }
        return GatewayResponse.json(["input_tokens": AnthropicCodec.countInputTokens(payload)])
    }

    // MARK: OpenAI passthrough

    /// Forwards `/v1/chat/completions` to the running engine unchanged — both
    /// directions speak OpenAI, so only the transport (stream or not) matters.
    nonisolated private func proxyChatCompletions(_ request: GatewayRequest) async -> GatewayResponse {
        let snapshot = await MainActor.run { () -> EngineSnapshot? in
            guard let state = Optional(AppState.shared), let controller = state.controller,
                  controller.isReady else { return nil }
            return EngineSnapshot(port: controller.port)
        }
        guard let upstream = snapshot else {
            return Self.errorResponse(GatewayAPIError.overloaded("推理引擎未运行，请先在 flashCat 中启动服务"),
                                      anthropic: request.isAnthropicStyle)
        }

        let wantsStream = (Self.parseObject(request.body)?["stream"] as? Bool) ?? false
        if wantsStream {
            guard let response = await GatewayUpstream.postStreaming(port: upstream.port,
                                                                     path: request.path,
                                                                     body: request.body) else {
                return Self.errorResponse(GatewayAPIError.overloaded("无法连接引擎（127.0.0.1:\(upstream.port)）"),
                                          anthropic: false)
            }
            if response.status >= 300 {
                return await Self.drainAsResponse(response)
            }
            return GatewayResponse.sse { session in
                var ended = false
                do {
                    for try await line in response.bytes.lines {
                        if session.isClosed { break }
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty { continue }
                        if trimmed == "data: [DONE]" || trimmed == "[DONE]" {
                            _ = session.write("data: [DONE]\n\n")
                            ended = true
                            break
                        }
                        _ = session.write(trimmed + "\n\n")
                    }
                } catch {
                    // Upstream vanished: the client sees the stream end.
                }
                if !ended { _ = session.write("data: [DONE]\n\n") }
                session.close()
            }
        }

        guard let response = await GatewayUpstream.postJSON(port: upstream.port,
                                                            path: request.path,
                                                            body: request.body) else {
            return Self.errorResponse(GatewayAPIError.overloaded("无法连接引擎（127.0.0.1:\(upstream.port)）"),
                                      anthropic: false)
        }
        var out = GatewayResponse()
        out.status = response.status == 0 ? 502 : response.status
        out.body = response.body
        return out
    }

    // MARK: Anthropic messages

    nonisolated private func anthropicMessages(_ request: GatewayRequest) async -> GatewayResponse {
        guard let payload = Self.parseObject(request.body) else {
            return Self.errorResponse(GatewayAPIError.badRequest("请求体不是合法的 JSON"), anthropic: true)
        }
        let (openai, stream): ([String: Any], Bool)
        do {
            (openai, stream) = try AnthropicCodec.translateRequest(payload)
        } catch let error as GatewayAPIError {
            return Self.errorResponse(error, anthropic: true)
        } catch {
            return Self.errorResponse(GatewayAPIError.badRequest("无法解析请求：\(error.localizedDescription)"),
                                      anthropic: true)
        }
        guard let openaiBody = try? JSONSerialization.data(withJSONObject: openai) else {
            return Self.errorResponse(GatewayAPIError.badRequest("无法编码上游请求"), anthropic: true)
        }

        let snapshot = await MainActor.run { () -> EngineSnapshot? in
            guard let controller = AppState.shared.controller, controller.isReady else { return nil }
            return EngineSnapshot(port: controller.port)
        }
        guard let upstream = snapshot else {
            return Self.errorResponse(GatewayAPIError.overloaded("推理引擎未运行，请先在 flashCat 中启动服务"),
                                      anthropic: true)
        }
        let model = (openai["model"] as? String) ?? ""

        if stream {
            let inputTokens = AnthropicCodec.countInputTokens(payload)
            guard let response = await GatewayUpstream.postStreaming(port: upstream.port,
                                                                     path: "/v1/chat/completions",
                                                                     body: openaiBody) else {
                return Self.errorResponse(GatewayAPIError.overloaded("无法连接引擎（127.0.0.1:\(upstream.port)）"),
                                          anthropic: true)
            }
            if response.status >= 300 {
                return await Self.drainAsAnthropicError(response)
            }
            return GatewayResponse.sse { session in
                let translator = AnthropicCodec.StreamTranslator(model: model, inputTokens: inputTokens)
                for frame in translator.startEvents() where !session.write(frame) { return }
                do {
                    for try await line in response.bytes.lines {
                        if session.isClosed { break }
                        guard let payload = GatewayUpstream.dataPayload(ofLine: line),
                              let chunk = Self.parseObject(Data(payload.utf8)) else { continue }
                        for frame in translator.consume(chunk: chunk)
                        where !session.write(frame) { return }
                    }
                } catch {
                    // Upstream vanished mid-stream: finishEvents below closes
                    // what is open so the client sees a well-formed message.
                }
                for frame in translator.finishEvents() where !session.write(frame) { return }
                session.close()
            }
        }

        guard let response = await GatewayUpstream.postJSON(port: upstream.port,
                                                            path: "/v1/chat/completions",
                                                            body: openaiBody) else {
            return Self.errorResponse(GatewayAPIError.overloaded("无法连接引擎（127.0.0.1:\(upstream.port)）"),
                                      anthropic: true)
        }
        guard (200..<300).contains(response.status) else {
            var out = GatewayResponse()
            out.status = response.status == 0 ? 502 : response.status
            out.body = Data((try? JSONSerialization.data(
                withJSONObject: AnthropicCodec.errorEnvelope(from: response.body,
                                                             upstreamStatus: response.status)))
                ?? Data(#"{"type":"error","error":{"type":"api_error","message":"engine error"}}"#.utf8))
            return out
        }
        guard let openaiResponse = Self.parseObject(response.body) else {
            return Self.errorResponse(GatewayAPIError(status: 502, type: "api_error",
                                                      message: "引擎返回了无法解析的响应"),
                                      anthropic: true)
        }
        return GatewayResponse.json(AnthropicCodec.translateResponse(openaiResponse))
    }

    // MARK: helpers

    private struct EngineSnapshot {
        let port: Int
    }

    nonisolated private static func parseObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated private static func errorResponse(_ error: GatewayAPIError, anthropic: Bool) -> GatewayResponse {
        GatewayResponse.json(anthropic ? error.anthropicEnvelope() : error.openAIEnvelope(),
                             status: error.status)
    }

    /// An upstream streaming request that failed before streaming: drain the
    /// body and answer with it verbatim (OpenAI dialect).
    nonisolated private static func drainAsResponse(_ response: GatewayUpstream.StreamResponse) async -> GatewayResponse {
        var body = Data()
        do {
            for try await byte in response.bytes { body.append(byte) }
        } catch {
            // A partial error body is still better than none.
        }
        var out = GatewayResponse()
        out.status = response.status
        out.body = body
        return out
    }

    /// Same, but rewritten into the Anthropic error envelope.
    nonisolated private static func drainAsAnthropicError(_ response: GatewayUpstream.StreamResponse) async -> GatewayResponse {
        var body = Data()
        do {
            for try await byte in response.bytes { body.append(byte) }
        } catch {
            // A partial error body is still better than none.
        }
        var out = GatewayResponse()
        out.status = response.status
        out.body = Data((try? JSONSerialization.data(
            withJSONObject: AnthropicCodec.errorEnvelope(from: body, upstreamStatus: response.status)))
            ?? Data(#"{"type":"error","error":{"type":"api_error","message":"engine error"}}"#.utf8))
        return out
    }
}
