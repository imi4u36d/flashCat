// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import Foundation

/// `ChatRunner` 对三类传输的最小要求。真实实现是 `ChatClient` / `ImageClient` /
/// `VideoClient`；测试里换成假实现，就能在不发请求的情况下跑编排。
protocol ChatStreaming: Sendable {
    var lastUsage: ChatUsage { get }
    var lastToolCalls: [ChatToolCall] { get }

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
    ) async -> Result<String, ChatError>

    func cancel()
}

extension ChatStreaming {
    func send(
        port: Int,
        model: String,
        turns: [ChatTurn],
        options: ChatOptions,
        onDelta: @escaping @Sendable (String, Date) -> Void,
        onReasoning: @escaping @Sendable (String, Date) -> Void,
        onUsage: @escaping @Sendable (ChatUsage) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) async -> Result<String, ChatError> {
        await send(
            port: port, model: model, turns: turns, options: options,
            tools: ChatToolSchema(), onDelta: onDelta, onReasoning: onReasoning,
            onUsage: onUsage, onStatus: onStatus, onToolCall: { _, _ in })
    }
}

protocol ImageGenerating: Sendable {
    func generate(
        port: Int,
        request: ImageGenerationRequest,
        onProgress: @escaping @Sendable (String) -> Void
    ) async -> Result<ImageGenerationResult, ImageClientError>
}

protocol VideoGenerating: Sendable {
    func generate(
        port: Int,
        request: VideoGenerationRequest,
        onProgress: @escaping @Sendable (String) -> Void
    ) async -> Result<VideoGenerationResult, VideoClientError>
}

extension ChatClient: ChatStreaming {}
extension ImageClient: ImageGenerating {}
extension VideoClient: VideoGenerating {}
