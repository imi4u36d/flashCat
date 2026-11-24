// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation

/// `EngineCoordinator` 需要外层提供的状态与动作。
///
/// 以前这里是一个 `weak var host: AppState?`：编排对象因此认识装配根的具体类型，
/// 既没法脱离 AppState 构造，也让「Core 不认识 App」这条边界只能靠约定。协议把
/// 依赖收成一份可枚举的清单——编排到底读了哪些状态、写了哪些动作，看这个文件就
/// 知道；测试里塞一个假 host 就能跑。
@MainActor
package protocol EngineHost: AnyObject, ObservableObject {
    // MARK: 引擎会话

    var serverState: ServerState { get set }
    var stats: ServerStats? { get set }
    var selectedModel: String { get set }
    var selectedModelInfo: ModelInfo? { get }
    var switchingModel: String? { get set }
    var switchStage: String { get set }
    var lifecycleTick: Int { get set }
    var confirmingModelSwitch: String? { get set }
    var pendingEngineInstall: EngineID? { get set }
    var isSwitchingModel: Bool { get }
    var isRunning: Bool { get }
    var isModelBusy: Bool { get }
    var needsEngineSetup: Bool { get }
    var activeEngine: EngineID { get }

    // MARK: 模型库与对话

    var catalog: ModelCatalog { get set }
    var libraryEngine: EngineID { get set }
    var sharedRepos: [String] { get set }
    var localModelRepos: [String] { get set }
    var pendingRecommendedDownload: (engine: EngineID, model: String)? { get set }
    var messages: [ChatMessage] { get set }
    var threads: [ChatThread] { get set }
    var currentThreadID: String { get }
    var generating: Bool { get }
    var history: ChatHistory { get }
    var conversation: ConversationStore { get }
    var downloadTasks: [ModelDownloadTask] { get }

    // MARK: 日志与通知

    var logs: [LogLine] { get set }
    var logsRevision: Int { get set }
    var notice: String? { get set }
    var section: Page { get set }
    var showsLaunchPage: Bool { get set }

    /// 完整签名由协议声明；便利重载见文件末尾的 extension。
    func toast(_ message: String, title: String?, kind: IslandNotice.Kind?, transient: Bool)

    /// `objectWillChange` 的关联类型在存在类型里会被擦成 `any Publisher`，拿不到
    /// `send()`；协议改成一个具名动作，AppState 用 `objectWillChange.send()` 实现。
    func notifyObjectChanged()

    // MARK: 动作

    func adoptSavedModel(for id: EngineID)
    func selectModel(_ id: String)
    func startService()
    func reloadModels()
    func invalidateModelCaches()
    func rememberContextWindows()
    func rememberReportedWindow()
    func settleRecommendation()
    func dismissRecommendationPage()
    func applyGatewaySettings()
    @discardableResult func downloadModel(_ id: String, engine: EngineID, family: String?) -> Bool
    func ensureSplashDraft(_ model: ModelInfo?) async -> StartPreparation
}

extension EngineHost {
    package func toast(_ message: String) {
        toast(message, title: nil, kind: nil, transient: false)
    }

    package func toast(_ message: String, kind: IslandNotice.Kind?, transient: Bool) {
        toast(message, title: nil, kind: kind, transient: transient)
    }

    package func toast(_ message: String, transient: Bool) {
        toast(message, title: nil, kind: nil, transient: transient)
    }

    @discardableResult
    package func downloadModel(_ id: String, engine: EngineID) -> Bool {
        downloadModel(id, engine: engine, family: nil)
    }
}
