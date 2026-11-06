import Foundation

/// 对话页高频变化的渲染状态。
///
/// 以前这些都挂在 `AppState` 上：每个流式分片、每轮线程列表刷新都会让
/// 所有观察 `AppState` 的页面一起重算。拆成独立 store 后，只有真正显示
/// 对话内容的视图订阅这里，概览、模型页等不会被 token 流带着重绘。
@MainActor
final class ChatStore: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var threads: [ChatThread] = []
    @Published var generating = false
    @Published var generationStatus: String?
    @Published var chatStartupStage: String?
}
