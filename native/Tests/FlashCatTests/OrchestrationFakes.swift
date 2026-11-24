// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import Foundation

@testable import FlashCat

/// 编排层测试用的最小替身。只实现协议要求，不做真实 I/O。
@MainActor
final class FakeChatHost: ChatHost {
    var controller: EngineController?
    var activeEngine: EngineID = .splash
    var modelList: [EngineModel] = []
    var selectedModelInfo: ModelInfo?
    var effectiveMaxTokens = 0
    var canChat = false
    var engineStageText = ""
    var port = 0
    var needsEngineSetup = true
    var notice: String?
    var toasts: [String] = []
    var warnings: [String] = []
    var showedChat = 0
    var preparedModels: [String] = []

    func engineModels(for engine: EngineID) -> [EngineModel] { modelList }
    func prepareModelForGateway(
        _ model: String, allowingGeneration: Bool
    ) async -> GatewayModelPreparationError? {
        preparedModels.append(model)
        return nil
    }
    func gatewayModelIsResident(_ model: String, in controller: EngineController) -> Bool { false }
    func toast(_ message: String, title: String?, kind: IslandNotice.Kind?, transient: Bool) {
        toasts.append(message)
    }
    func logWarning(_ line: String) { warnings.append(line) }
    func showChat() { showedChat += 1 }
}

@MainActor
final class FakeModelHost: ModelHost {
    var activeEngine: EngineID = .splash
    var selectedModel = ""
    var needsEngineSetup = true
    var notice: String?
    var toasts: [String] = []
    var logs: [String] = []
    var stoppedService = 0
    var adopted: [EngineID] = []
    var applied: [String] = []
    var stoppedBackends = 0

    func stopService() { stoppedService += 1 }
    func adoptSavedModel(for engine: EngineID) { adopted.append(engine) }
    func applyModel(_ model: String) { applied.append(model) }
    func applyModelFromAnyEngine(_ model: String, engine: EngineID) { applied.append(model) }
    func toast(_ message: String, title: String?, kind: IslandNotice.Kind?, transient: Bool) {
        toasts.append(message)
    }
    func appendLog(_ line: String, engine: EngineID) { logs.append(line) }
    func stopBackends() { stoppedBackends += 1 }
}

@MainActor
final class FakeDownloadHost: DownloadHost {
    var notice: String?
    var logs: [String] = []
    var toasts: [String] = []
    var reloads = 0
    var inventoryChanges = 0

    func log(_ line: String, engine: EngineID?) { logs.append(line) }
    func toast(_ message: String, title: String?, kind: IslandNotice.Kind?, transient: Bool) {
        toasts.append(message)
    }
    func reloadModels() { reloads += 1 }
    func modelInventoryChanged() { inventoryChanges += 1 }
}

@MainActor
final class FakeEngineCatalog: EngineCataloging {
    var engines: EngineManager?
    var installed: Set<EngineID> = []
    var models: [EngineID: [EngineModel]] = [:]
    var switched: [EngineID] = []
    var reloads = 0
    var installRequests: [EngineID] = []

    func reloadModels() { reloads += 1 }
    func engineIsInstalled(_ id: EngineID) -> Bool { installed.contains(id) }
    func requestEngineInstall(_ id: EngineID) { installRequests.append(id) }
    func engineModels(for id: EngineID) -> [EngineModel] { models[id] ?? [] }
    func shortModelName(_ id: String) -> String { id }
    func switchEngine(_ id: EngineID, start: Bool) async -> Bool {
        switched.append(id)
        return true
    }
}

struct FakeChatStream: ChatStreaming {
    var lastUsage = ChatUsage()
    var lastToolCalls: [ChatToolCall] = []

    func send(
        port: Int,
        model: String,
        turns: [ChatTurn],
        options: ChatOptions,
        tools: ChatToolSchema,
        onDelta: @escaping @Sendable (String, Date) -> Void,
        onReasoning: @escaping @Sendable (String, Date) -> Void,
        onUsage: @escaping @Sendable (ChatUsage) -> Void,
        onStatus: @escaping @Sendable (String) -> Void,
        onToolCall: @escaping @Sendable (String, Date) -> Void
    ) async -> Result<String, ChatError> {
        .success("ok")
    }

    func cancel() {}
}

struct FakeImageGenerator: ImageGenerating {
    func generate(
        port: Int,
        request: ImageGenerationRequest,
        onProgress: @escaping @Sendable (String) -> Void
    ) async -> Result<ImageGenerationResult, ImageClientError> {
        .failure(ImageClientError(message: "测试替身不生成图片"))
    }
}

struct FakeVideoGenerator: VideoGenerating {
    func generate(
        port: Int,
        request: VideoGenerationRequest,
        onProgress: @escaping @Sendable (String) -> Void
    ) async -> Result<VideoGenerationResult, VideoClientError> {
        .failure(VideoClientError(message: "测试替身不生成视频"))
    }
}
