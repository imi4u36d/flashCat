// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCat

/// `EngineHost` 协议的第一个直接测试：没有引擎时 `syncController` 必须把界面状态
/// 收敛到「已停止」并清掉旧日志。以前这需要构造整个 `AppState`，现在一个假 host
/// 就够——这正是协议化的价值。
@MainActor
final class EngineCoordinatorTests: XCTestCase {
    func testSyncControllerWithoutEnginePublishesStoppedState() {
        let host = FakeEngineHost()
        host.serverState = .ready
        host.stats = ServerStats(decodeTokensPerSecond: 42)
        host.logs = [
            LogLine(id: 1, time: Date(timeIntervalSince1970: 0), text: "stale", level: .info)
        ]

        let coordinator = makeCoordinator(host: host)
        coordinator.syncController()

        XCTAssertEqual(host.serverState, .stopped)
        XCTAssertNil(host.stats)
        XCTAssertTrue(host.logs.isEmpty)
    }

    func testEngineModelsWithoutManagerIsEmpty() {
        let host = FakeEngineHost()
        let coordinator = makeCoordinator(host: host)
        XCTAssertTrue(coordinator.engineModels(for: .splash).isEmpty)
        XCTAssertEqual(coordinator.activeEngine, .splash)
    }

    private func makeCoordinator(host: FakeEngineHost) -> EngineCoordinator {
        let coordinator = EngineCoordinator(
            settings: AppSettings(),
            installs: EngineInstallCenter(),
            control: ControlServer(),
            gateway: GatewayController.shared,
            metrics: MetricsStore(),
            downloads: DownloadCenter())
        coordinator.host = host
        return coordinator
    }
}

/// 只实现 `EngineHost` 要求的成员；编排读到的每个值都能在测试里直接摆。
@MainActor
private final class FakeEngineHost: ObservableObject, EngineHost {
    @Published var serverState: ServerState = .stopped
    @Published var stats: ServerStats?
    @Published var selectedModel = ""
    @Published var switchingModel: String?
    @Published var switchStage = ""
    @Published var lifecycleTick = 0
    @Published var confirmingModelSwitch: String?
    @Published var pendingEngineInstall: EngineID?
    @Published var catalog = ModelCatalog()
    @Published var libraryEngine: EngineID = .splash
    @Published var sharedRepos: [String] = []
    @Published var localModelRepos: [String] = []
    @Published var messages: [ChatMessage] = []
    @Published var threads: [ChatThread] = []
    @Published var logs: [LogLine] = []
    @Published var logsRevision = 0
    @Published var notice: String?
    @Published var section: Page = .overview
    @Published var showsLaunchPage = false

    var selectedModelInfo: ModelInfo? { nil }
    var isSwitchingModel: Bool { switchingModel != nil }
    var isRunning = false
    var isModelBusy = false
    var needsEngineSetup = true
    var activeEngine: EngineID = .splash
    var pendingRecommendedDownload: (engine: EngineID, model: String)?
    var currentThreadID = "thread"
    var generating = false
    var downloadTasks: [ModelDownloadTask] = []
    let history = ChatHistory()
    let conversation = ConversationStore()

    func toast(_ message: String, title: String?, kind: IslandNotice.Kind?, transient: Bool) {}
    func notifyObjectChanged() { objectWillChange.send() }
    func adoptSavedModel(for id: EngineID) {}
    func selectModel(_ id: String) {}
    func startService() {}
    func reloadModels() {}
    func invalidateModelCaches() {}
    func rememberContextWindows() {}
    func rememberReportedWindow() {}
    func settleRecommendation() {}
    func dismissRecommendationPage() {}
    func applyGatewaySettings() {}
    func downloadModel(_ id: String, engine: EngineID, family: String?) -> Bool { false }
    func ensureSplashDraft(_ model: ModelInfo?) async -> StartPreparation { .ready(model) }
}
