// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 对话页高频变化的渲染状态。
///
/// 以前这些都挂在 `AppState` 上：每个流式分片、每轮线程列表刷新都会让
/// 所有观察 `AppState` 的页面一起重算。拆成独立 store 后，只有真正显示
/// 对话内容的视图订阅这里，概览、模型页等不会被 token 流带着重绘。
@MainActor
package final class ChatStore: ObservableObject {
    package init() {}
    @Published package var messages: [ChatMessage] = []
    @Published package var threads: [ChatThread] = []
    @Published package var generating = false
    @Published package var generationStatus: String?
    @Published package var chatStartupStage: String?
}
