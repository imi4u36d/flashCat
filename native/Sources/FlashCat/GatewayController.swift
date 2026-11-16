// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation
import SwiftUI
@preconcurrency import FlashCatKit

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
            let message = "端口 \(port) 被占用，网关未启动"
            failureMessage = message
            logs.append("==> \(message)", level: .error)
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
        let openaiPayload = Self.parseObject(request.body)
        // The gateway is the only place that knows which engine owns a model.
        // Resolve the request's `model` before touching the upstream: an
        // engine may ignore an unknown id and answer from whichever weights it
        // already holds, which is worse than a clean error because the client
        // believes the requested model ran.
        if let preparationError = await AppState.shared.prepareModelForGateway(
            openaiPayload?["model"] as? String) {
            return Self.preparationErrorResponse(preparationError, anthropic: false)
        }

        let snapshot = await MainActor.run { () -> EngineSnapshot? in
            guard let state = Optional(AppState.shared), let controller = state.controller,
                  controller.isReady else { return nil }
            return EngineSnapshot(port: controller.port)
        }
        guard let upstream = snapshot else {
            return Self.errorResponse(GatewayAPIError.overloaded("推理引擎未运行，请先在 flashCat 中启动服务"),
                                      anthropic: false)
        }

        let wantsStream = (openaiPayload?["stream"] as? Bool) ?? false
        // 引擎侧没有 per-session 指标，网关是唯一知道「这一路什么时候进来、第一个
        // token 什么时候到、一共吐了多少字」的地方，概览页的会话网格就从这里取数。
        let meterID = GatewayMeter.shared.begin(
            model: (openaiPayload?["model"] as? String) ?? "",
            dialect: "openai",
            promptTokens: TokenEstimator.promptTokens(messages: openaiPayload?["messages"]))
        if wantsStream {
            let response: GatewayUpstream.StreamResponse
            switch await GatewayUpstream.postStreaming(port: upstream.port,
                                                       path: request.path,
                                                       body: request.body) {
            case .success(let streamed):
                response = streamed
            case .failure(let error):
                GatewayMeter.shared.finish(meterID, failed: true)
                return Self.upstreamFailureResponse(error, anthropic: false)
            }
            if response.status >= 300 {
                GatewayMeter.shared.finish(meterID, failed: true)
                return await Self.drainAsResponse(response)
            }
            return GatewayResponse.sse { session in
                // 生产者可能从任意一行早退（`session.write` 返回 false 表示客户端
                // 已断开），也可能在上游断流时退出；收尾交给 withStreamMetering
                // 的 defer，这一路才会在概览里落定。
                await Self.withStreamMetering(GatewayMeter.shared, id: meterID) {
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
                            // 顺手解析每一片：既算实时速率，也接住末片的 usage。
                            if let data = GatewayUpstream.dataPayload(ofLine: trimmed),
                               let chunk = Self.parseObject(Data(data.utf8)) {
                                GatewayMeter.shared.ingest(meterID, chunk: chunk)
                            }
                            _ = session.write(trimmed + "\n\n")
                        }
                    } catch {
                        // Upstream vanished: the client sees the stream end.
                    }
                    GatewayMeter.shared.finish(meterID)
                    if !ended { _ = session.write("data: [DONE]\n\n") }
                    session.close()
                }
            }
        }

        let buffered: GatewayUpstream.BufferedResponse
        switch await GatewayUpstream.postJSON(port: upstream.port,
                                             path: request.path,
                                             body: request.body) {
        case .success(let response):
            buffered = response
        case .failure(let error):
            GatewayMeter.shared.finish(meterID, failed: true)
            return Self.upstreamFailureResponse(error, anthropic: false)
        }
        if (200..<300).contains(buffered.status) {
            GatewayMeter.shared.ingestResponse(meterID, body: buffered.body)
        } else {
            GatewayMeter.shared.finish(meterID, failed: true)
        }
        var out = GatewayResponse()
        out.status = buffered.status == 0 ? 502 : buffered.status
        out.body = buffered.body
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

        let model = (openai["model"] as? String) ?? ""
        if let preparationError = await AppState.shared.prepareModelForGateway(model) {
            return Self.preparationErrorResponse(preparationError, anthropic: true)
        }

        let snapshot = await MainActor.run { () -> EngineSnapshot? in
            guard let controller = AppState.shared.controller, controller.isReady else { return nil }
            return EngineSnapshot(port: controller.port)
        }
        guard let upstream = snapshot else {
            return Self.errorResponse(GatewayAPIError.overloaded("推理引擎未运行，请先在 flashCat 中启动服务"),
                                      anthropic: true)
        }
        // 只算一次：旧实现给 meter 和 StreamTranslator 各算了一遍，
        // `countInputTokens` 要遍历全部 messages，长对话上直接翻倍。
        let inputTokens = AnthropicCodec.countInputTokens(payload)
        let meterID = GatewayMeter.shared.begin(model: model,
                                               dialect: "claude",
                                               promptTokens: inputTokens)

        if stream {
            let response: GatewayUpstream.StreamResponse
            switch await GatewayUpstream.postStreaming(port: upstream.port,
                                                       path: "/v1/chat/completions",
                                                       body: openaiBody) {
            case .success(let streamed):
                response = streamed
            case .failure(let error):
                GatewayMeter.shared.finish(meterID, failed: true)
                return Self.upstreamFailureResponse(error, anthropic: true)
            }
            if response.status >= 300 {
                GatewayMeter.shared.finish(meterID, failed: true)
                return await Self.drainAsAnthropicError(response)
            }
            return GatewayResponse.sse { session in
                // 三个 `where !session.write(frame) { return }` 都是早退路径：
                // 没有 withStreamMetering 时它们会把这一路永远留在「在跑」。
                await Self.withStreamMetering(GatewayMeter.shared, id: meterID) {
                    let translator = AnthropicCodec.StreamTranslator(model: model, inputTokens: inputTokens)
                    for frame in translator.startEvents() where !session.write(frame) { return }
                    do {
                        for try await line in response.bytes.lines {
                            if session.isClosed { break }
                            guard let payload = GatewayUpstream.dataPayload(ofLine: line),
                                  let chunk = Self.parseObject(Data(payload.utf8)) else { continue }
                            GatewayMeter.shared.ingest(meterID, chunk: chunk)
                            for frame in translator.consume(chunk: chunk)
                            where !session.write(frame) { return }
                        }
                    } catch {
                        // Upstream vanished mid-stream: finishEvents below closes
                        // what is open so the client sees a well-formed message.
                    }
                    GatewayMeter.shared.finish(meterID)
                    for frame in translator.finishEvents() where !session.write(frame) { return }
                    session.close()
                }
            }
        }

        let buffered: GatewayUpstream.BufferedResponse
        switch await GatewayUpstream.postJSON(port: upstream.port,
                                             path: "/v1/chat/completions",
                                             body: openaiBody) {
        case .success(let response):
            buffered = response
        case .failure(let error):
            GatewayMeter.shared.finish(meterID, failed: true)
            return Self.upstreamFailureResponse(error, anthropic: true)
        }
        guard (200..<300).contains(buffered.status) else {
            GatewayMeter.shared.finish(meterID, failed: true)
            var out = GatewayResponse()
            out.status = buffered.status == 0 ? 502 : buffered.status
            out.body = Data((try? JSONSerialization.data(
                withJSONObject: AnthropicCodec.errorEnvelope(from: buffered.body,
                                                             upstreamStatus: buffered.status)))
                ?? Data(#"{"type":"error","error":{"type":"api_error","message":"engine error"}}"#.utf8))
            return out
        }
        guard let openaiResponse = Self.parseObject(buffered.body) else {
            GatewayMeter.shared.finish(meterID, failed: true)
            return Self.errorResponse(GatewayAPIError(status: 502, type: "api_error",
                                                      message: "引擎返回了无法解析的响应"),
                                      anthropic: true)
        }
        GatewayMeter.shared.ingestResponse(meterID, body: buffered.body)
        return GatewayResponse.json(AnthropicCodec.translateResponse(openaiResponse))
    }

    // MARK: helpers

    private struct EngineSnapshot {
        let port: Int
    }

    /// 流式应答的收尾边界。
    ///
    /// 生产者随时可能从任意一行早退（`session.write` 返回 false 表示客户端已
    /// 断开），也可能在上游断流时退出。旧实现是
    /// `for frame in … where !session.write(frame) { return }` 直接 return，
    /// `GatewayMeter.finish` 永远不执行：这一路在概览里永远是「在跑」——曲线
    /// 不冻结、`latestContext()` 一直把它算进去，会话表满了 32 条之后还会把
    /// 真正在跑的请求挤掉。`finish` 自身幂等（见 GatewayMeter.finish 里
    /// `finishedAt == nil` 的判断），所以把收尾放进 `defer` 是安全的。
    nonisolated static func withStreamMetering(_ meter: GatewayMeter,
                                              id: Int,
                                              _ produce: () async -> Void) async {
        defer { meter.finish(id) }
        await produce()
    }

    /// 上游失败要同时做两件事：回一个能区分的状态码，并写进网关日志。
    ///
    /// 旧实现把「引擎没起」「等超时」「连接断了」统统回成 503 且一个字不落日志，
    /// 用户只能看到 503，然后从「是不是模型太大」开始猜。现在 503 = 引擎不可达
    /// （可重试）、504 = 引擎在跑但太慢、502 = 请求没走通。
    nonisolated private static func upstreamFailureResponse(_ error: GatewayUpstreamError,
                                                            anthropic: Bool) -> GatewayResponse {
        logUpstreamFailure(error)
        let apiError: GatewayAPIError
        switch error {
        case .notReachable:
            // 引擎没起来属于「暂时不可用」，沿用 overloaded_error：SDK 默认把它
            // 当成可重试的过载，而不是请求写错了。
            apiError = GatewayAPIError.overloaded(error.logMessage)
        case .timedOut:
            apiError = GatewayAPIError(status: 504,
                                       type: anthropic ? "api_error" : "upstream",
                                       message: error.logMessage)
        case .transport:
            apiError = GatewayAPIError(status: 502,
                                       type: anthropic ? "api_error" : "upstream",
                                       message: error.logMessage)
        }
        return errorResponse(apiError, anthropic: anthropic)
    }

    /// `LogStore.append` 自己带锁、不要求主 actor，但 `logs` 挂在 @MainActor 的
    /// 单例上，这里 hop 一次再写；日志写晚一拍没有关系。
    nonisolated private static func logUpstreamFailure(_ error: GatewayUpstreamError) {
        let line = "==> \(error.logMessage)"
        Task { @MainActor in
            GatewayController.shared.logs.append(line, level: .error)
        }
    }

    nonisolated private static func parseObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated private static func errorResponse(_ error: GatewayAPIError, anthropic: Bool) -> GatewayResponse {
        GatewayResponse.json(anthropic ? error.anthropicEnvelope() : error.openAIEnvelope(),
                             status: error.status)
    }

    nonisolated private static func preparationErrorResponse(_ error: GatewayModelPreparationError,
                                                               anthropic: Bool) -> GatewayResponse {
        let apiError: GatewayAPIError
        switch error {
        case .modelNotFound(let message):
            apiError = .notFound(message)
        case .badRequest(let message):
            apiError = .badRequest(message)
        case .unavailable(let message):
            apiError = .overloaded(message)
        case .failed(let message):
            apiError = GatewayAPIError(status: 503, type: "api_error", message: message)
        }
        return errorResponse(apiError, anthropic: anthropic)
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
