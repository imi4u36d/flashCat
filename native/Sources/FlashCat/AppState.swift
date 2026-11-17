// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Combine
import Darwin
import FlashCatKit
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// 界面自身状态（当前页、启动页、侧栏、错误横幅、灵动岛通知）独立成 store。
    /// 这里保留同名转发，视图与菜单栏读的仍是 `state.xxx`。
    let ui = UIStateStore()
    var section: Page {
        get { ui.section }
        set { ui.section = newValue }
    }
    /// Re-open the launch page from the engines tab; the page is also shown
    /// automatically while no engine is installed.
    var showsLaunchPage: Bool {
        get { ui.showsLaunchPage }
        set { ui.showsLaunchPage = newValue }
    }
    /// 引擎会话状态（服务状态、指标、当前模型、切换流程）独立成 store。
    /// 这里保留同名 get/set 转发，编排代码与视图都不用改。
    let engineSession = EngineSessionStore()
    var serverState: ServerState {
        get { engineSession.serverState }
        set { engineSession.serverState = newValue }
    }
    var stats: ServerStats? {
        get { engineSession.stats }
        set { engineSession.stats = newValue }
    }
    var selectedModel: String {
        get { engineSession.selectedModel }
        set { engineSession.selectedModel = newValue }
    }
    var defaultRevision: Int {
        get { engineSession.defaultRevision }
        set { engineSession.defaultRevision = newValue }
    }
    var switchingModel: String? {
        get { engineSession.switchingModel }
        set { engineSession.switchingModel = newValue }
    }
    var switchStage: String {
        get { engineSession.switchStage }
        set { engineSession.switchStage = newValue }
    }
    var lifecycleTick: Int {
        get { engineSession.lifecycleTick }
        set { engineSession.lifecycleTick = newValue }
    }
    var confirmingModelSwitch: String? {
        get { engineSession.confirmingModelSwitch }
        set { engineSession.confirmingModelSwitch = newValue }
    }
    var pendingEngineInstall: EngineID? {
        get { engineSession.pendingEngineInstall }
        set { engineSession.pendingEngineInstall = newValue }
    }
    /// 日志流（当前引擎的尾巴）与它的刷新节拍在 `LogFeedService` 里；这里保留
    /// 同名转发，`EngineCoordinator.syncController` 与日志页都不用改。
    let logFeed: LogFeedService
    var logs: [LogLine] {
        get { logFeed.logs }
        set { logFeed.logs = newValue }
    }
    /// 日志页读它：合并视图覆盖所有引擎，别的引擎写新行时 `logs` 不会发布，
    /// 靠这一拍让页面重新取一份。活动引擎的写入仍走 `logs`。
    var logsRevision: Int {
        get { logFeed.logsRevision }
        set { logFeed.logsRevision = newValue }
    }
    /// 本机模型库：清单、公共目录里的仓库、当前浏览的引擎，以及硬件推荐。
    /// 这里只留 get/set 转发——扫盘时机属于编排（下载完成、授权变更、引擎装卸
    /// 都要顺手通知别人），所以仍由 AppState 决定。
    let modelLibrary = ModelLibraryStore()
    var catalog: ModelCatalog {
        get { modelLibrary.catalog }
        set { modelLibrary.catalog = newValue }
    }
    var sharedRepos: [String] {
        get { modelLibrary.sharedRepos }
        set { modelLibrary.sharedRepos = newValue }
    }
    var localModelRepos: [String] {
        get { modelLibrary.localModelRepos }
        set { modelLibrary.localModelRepos = newValue }
    }
    var libraryEngine: EngineID {
        get { modelLibrary.libraryEngine }
        set { modelLibrary.libraryEngine = newValue }
    }
    var pendingLibraryUse: LibraryUseRequest? {
        get { modelLibrary.pendingLibraryUse }
        set { modelLibrary.pendingLibraryUse = newValue }
    }
    var hardwareRecommendation: HardwareRecommendation? {
        get { modelLibrary.hardwareRecommendation }
        set { modelLibrary.hardwareRecommendation = newValue }
    }
    var showsRecommendationPage: Bool {
        get { modelLibrary.showsRecommendationPage }
        set { modelLibrary.showsRecommendationPage = newValue }
    }
    var pendingRecommendedDownload: (engine: EngineID, model: String)? {
        get { modelLibrary.pendingRecommendedDownload }
        set { modelLibrary.pendingRecommendedDownload = newValue }
    }
    var tuningRevision: Int {
        get { modelLibrary.tuningRevision }
        set { modelLibrary.tuningRevision = newValue }
    }
    /// 对话页自己的会话状态（待删线程、图像工具开关）同样独立成 store，
    /// 这里保留同名转发。
    let chatSession = ChatSessionStore()
    var pendingThreadDelete: ChatThread? {
        get { chatSession.pendingThreadDelete }
        set { chatSession.pendingThreadDelete = newValue }
    }
    var imageToolEnabled: Bool {
        get { chatSession.imageToolEnabled }
        set { chatSession.imageToolEnabled = newValue }
    }
    var imageToolModelID: String {
        get { chatSession.imageToolModelID }
        set { chatSession.imageToolModelID = newValue }
    }
    var imageToolResident: Bool {
        get { chatSession.imageToolResident }
        set { chatSession.imageToolResident = newValue }
    }
    /// 高频对话状态独立成 store；这里保留同名转发，内部逻辑不用改。
    let chat = ChatStore()
    var messages: [ChatMessage] {
        get { chat.messages }
        set { chat.messages = newValue }
    }
    var threads: [ChatThread] {
        get { chat.threads }
        set { chat.threads = newValue }
    }
    /// 对话编排在 `ChatRunner` 里；这里只把它的依赖与回调接上。
    let runner: ChatRunner

    /// 侧栏「最近对话」用它高亮当前线程；threadID 本身只用于落盘。
    var currentThreadID: String { runner.currentThreadID }

    /// 正在生成的是哪一段对话——可能是读者已经切走、在后台继续跑的那一段。
    /// 侧栏据此把那一行标成「生成中」：不然切走后只剩下一个点不动的输入框，
    /// 看不出回答正在哪儿长。
    var generatingThreadID: String? { runner.generatingThreadID }
    var generating: Bool {
        get { chat.generating }
        set { chat.generating = newValue }
    }
    var generationStatus: String? {
        get { chat.generationStatus }
        set { chat.generationStatus = newValue }
    }
    /// 非 nil 时这条回复还在等引擎启动/加载权重；对话页据此把占位提示
    /// 从「等待首个 token」换成「模型正在启动中」。
    var chatStartupStage: String? {
        get { chat.chatStartupStage }
        set { chat.chatStartupStage = newValue }
    }
    /// Persistent banner for errors that need the reader's attention.
    var notice: String? {
        get { ui.notice }
        set { ui.notice = newValue }
    }
    /// 灵动岛上短暂展示的当前通知；过期后回到引擎状态。
    var islandNotice: IslandNotice? { ui.islandNotice }
    /// 本次会话的通知历史，展开灵动岛后按时间倒序查看。
    var islandNotices: [IslandNotice] { ui.islandNotices }
    /// 尚未展开查看的通知数量。
    var islandUnread: Int { ui.islandUnread }
    /// 悬浮导航列是否显示。隐藏后主视口铺满窗口，重新显示时恢复玻璃列；
    /// 状态落盘到 UserDefaults 的 `sidebarVisible`，重启后沿用上次的样子。
    var showsSidebar: Bool {
        get { ui.showsSidebar }
        set { ui.showsSidebar = newValue }
    }
    /// 侧栏动画截止时刻：只是调度信息，不进 `objectWillChange`。
    var sidebarAnimUntil: Date {
        get { ui.sidebarAnimUntil }
        set { ui.sidebarAnimUntil = newValue }
    }

    /// 下载中心：进程、进度、任务行都在它手里。AppState 只留策略——什么时候
    /// 该下载、下完要不要选中这个模型——所以这边看到的是一层只读转发。
    let downloads = DownloadCenter()
    var downloadingModel: String? { downloads.downloadingModel }
    /// Which engine the running download is for: two engines can hold models
    /// with the same id, and only the one being written shows the progress bar.
    var downloadingEngine: EngineID? { downloads.downloadingEngine }
    var downloadFraction: Double? { downloads.downloadFraction }
    /// Live transfer speed of the running download, bytes per second.
    var downloadSpeed: Double { downloads.downloadSpeed }
    /// Download center rows. Paused and failed transfers survive a relaunch
    /// (the Hub keeps partial files in the destination's `.cache`), so the
    /// list is persisted and "downloading" rows become "paused" on load.
    var downloadTasks: [ModelDownloadTask] { downloads.downloadTasks }
    /// Hugging Face 浏览器：列表、详情、手填仓库的预检都在 `HubStore`。这边只
    /// 留只读转发——浏览本来就不该碰磁盘或引擎，谁能不能下载由 AppState 判断。
    let hub = HubStore()
    var hubResults: [HubModel] { hub.hubResults }
    var hubDetail: HubModel? { hub.hubDetail }
    var hubQuery: String { hub.hubQuery }
    var hubSort: HubSort { hub.hubSort }
    var hubFilter: HubFilter { hub.hubFilter }
    var hubSource: HubSource { hub.hubSource }
    var hubPage: Int { hub.hubPage }
    var hubHasMore: Bool { hub.hubHasMore }
    var hubLoading: Bool { hub.hubLoading }
    var hubDetailLoading: Bool { hub.hubDetailLoading }
    var hubError: String? { hub.hubError }
    var hubSearch: HubSearchState { hub.hubSearch }
    var repoProbe: HubModel? { hub.repoProbe }
    var repoProbeLoading: Bool { hub.repoProbeLoading }
    var repoProbeError: String? { hub.repoProbeError }
    var repoProbeRepo: String { hub.repoProbeRepo }

    let settings = AppSettings()
    /// Owns the day/night skin choice and applies it to AppKit.
    let theme: ThemeController
    /// 写盘失败必须落进日志页（见 `recordHistoryWriteFailure`），所以构造点
    /// 在 init 里，以便注入回调。
    let history: ChatHistory
    let conversation: ConversationStore
    let chatClient = ChatClient()
    /// 图像生成/编辑走同一台引擎的 `/v1/images/generations`，与对话互不干扰。
    let imageClient = ImageClient()
    /// 视频生成走 `/v1/video/generations`，原始帧在客户端封装成 MP4。
    let videoClient = VideoClient()
    /// The fixed-port API gateway (OpenAI + Claude formats). One instance for
    /// the whole app; requests it serves read the live engine state from here.
    let gateway = GatewayController.shared
    /// The loopback command channel used by the bundled `flashcat` CLI.
    let control = ControlServer()
    /// 引擎管理器归 `EngineCoordinator` 所有：装卸、切换都在那边重建控制器列表。
    var engines: EngineManager? { engineCoordinator.engines }
    /// Pack installs shown on the engines page; owns its own installer actor.
    let installs = EngineInstallCenter()
    /// 引擎编排：启停、装卸联动、模型热切换、网关模型准备。界面读的状态仍从这里转发。
    let engineCoordinator: EngineCoordinator
    /// 模型与下载编排：硬件推荐、模型库清单、安装 / 应用 / 下载的连锁动作。
    let modelOps: ModelOps
    /// 选模型与启停编排：跨引擎换模型、待确认切换、服务阶段判定都在这里；
    /// 界面读的状态仍由 AppState 转发，签名不变。
    let service: ServiceCoordinator
    var controller: EngineController? { engines?.active }
    /// 上下文窗口的推导与记忆：模型自身上限 × 引擎本次收敛窗口，外加落盘记忆。
    let contextWindows: ContextWindowTracker
    var activeEngine: EngineID { engines?.activeID ?? .splash }
    var availableEngines: [EngineID] { engines?.installedIDs ?? [] }

    /// 下次启动用哪个引擎 + 模型：这套偏好的解析搬进了 `ServiceCoordinator`，
    /// 它同时读引擎会话、引擎管理器与 `EngineStore`。
    var defaultSelection: (engine: EngineID, model: String)? { service.defaultSelection }

    init() {
        // 历史/对话写盘失败走这一条回调。用静态入口而不是捕获 `self`：`history`
        // 是 `let`，构造它的那一刻转义闭包还不允许碰 `self`；而回调真正触发的
        // 时候（用户翻历史、写线程列表）单例早已就绪。
        history = ChatHistory(onWriteFailure: { message in
            LogFeedService.recordHistoryWriteFailure(message)
        })
        conversation = ConversationStore(onWriteFailure: { message in
            LogFeedService.recordHistoryWriteFailure(message)
        })
        theme = ThemeController(settings: settings)
        // 只拿装配对象，状态一律走 `host` 转发：两边各存一份是这类拆分最容易留的坑。
        engineCoordinator = EngineCoordinator(
            settings: settings, installs: installs, control: control, gateway: gateway,
            metrics: metrics, downloads: downloads)
        modelOps = ModelOps(
            settings: settings, downloads: downloads, modelLibrary: modelLibrary,
            engineCoordinator: engineCoordinator)
        logFeed = LogFeedService(engine: engineCoordinator, gateway: gateway)
        service = ServiceCoordinator(
            session: engineSession, library: modelLibrary, chat: chat, settings: settings,
            ui: ui, engineCoordinator: engineCoordinator)
        contextWindows = ContextWindowTracker(
            session: engineSession, library: modelLibrary, engineCoordinator: engineCoordinator)
        runner = ChatRunner(
            chat: chat, session: chatSession, engineSession: engineSession, settings: settings,
            history: history, conversation: conversation, chatClient: chatClient,
            imageClient: imageClient, videoClient: videoClient, metrics: metrics)
        // 三段闭包接线（对话 / 下载 / 模型编排）放在 `AppState+Wiring.swift`：
        // 它们只是把「回到装配根办的事」接上，读起来比埋在这里清楚。
        runner.hooks = makeRunnerHooks()
        downloads.hooks = makeDownloadHooks()
        modelOps.hooks = makeModelOpsHooks()
        downloads.onEvent = { [weak self] event in self?.modelOps.handle(event) }
        // 视图只订阅 AppState：每个 store / 编排对象的发布都要桥回来，否则数值
        // 在变而页面不重绘。八个 owner 分别是指标、下载中心、Hub 浏览、对话会话、
        // 引擎会话、模型库、界面状态、日志流。放在 init 末尾：前面的赋值不该触发重绘。
        metricsBridge = makeBridge(metrics)
        downloadsBridge = makeBridge(downloads)
        hubBridge = makeBridge(hub)
        chatSessionBridge = makeBridge(chatSession)
        engineSessionBridge = makeBridge(engineSession)
        modelLibraryBridge = makeBridge(modelLibrary)
        uiBridge = makeBridge(ui)
        logFeedBridge = makeBridge(logFeed)
        makeTuningObserver()
        // 编排层是装配链的最后一环：等 hook 和桥都接好再把 `self` 交过去，
        // 否则构造期间的回调会摸到一个还没装配完的 AppState。
        engineCoordinator.host = self
    }

    // MARK: derived

    var selectedModelInfo: ModelInfo? { catalog.machineModel(selectedModel) }

    /// 两处扫描缓存一起失效：引擎那份归 `EngineCoordinator`，模型库那份归
    /// `ModelOps`（`libraryEntries(for:)` 的 1 秒短缓存）。
    func invalidateModelCaches() {
        engineCoordinator.invalidateModelCache()
        modelOps.invalidateLibraryCache()
    }

    /// 上下文窗口的推导（20s 扫描缓存 + 两个 UserDefaults 记忆键）搬进了
    /// `ContextWindowTracker`，它同时读引擎会话、模型库与引擎管理器。
    /// 聊天参数默认值与概览页「已用 / 总量」读的还是这几个名字。
    func modelContextWindow(_ model: String) -> Int? { contextWindows.window(of: model) }
    func rememberContextWindows() { contextWindows.rememberModels() }
    func rememberReportedWindow() { contextWindows.rememberReported() }
    /// 聊天参数留空「最大生成 tokens」时的默认值：先取模型自身上限，再用引擎
    /// **生效窗口**封顶，两者都没报时退回 32768。
    ///
    /// 引擎窗口只是本次加载收敛后的值——splash 会被 `--max-context` 和 KV 预算
    /// 压低，omlx 的 `/api/status` 干脆不报（解析层只从 health 兜底）。以前直接
    /// 拿它当默认，等于让支持 262144 的模型只拿到 32768，甚至拿不到模型上限。
    var effectiveMaxTokens: Int {
        if settings.maxTokens > 0 { return settings.maxTokens }
        return contextWindowTokens ?? 32_768
    }

    var contextWindowTokens: Int? { contextWindows.tokens }
    var contextWindowCeiling: Int? { contextWindows.ceiling }
    /// 当前会话已占用的上下文 tokens。
    ///
    /// 生成期间用「本次提示词估算 + 已生成 token」实时推进，否则整段回复期间
    /// 顶栏与概览卡会停在上一次的 usage 上；回复结束后再回落到引擎回报的真实
    /// `prompt + completion`，所以静止时的数字仍然是 KV 里真正躺着的量。
    var contextUsedTokens: Int {
        if generating, runner.livePromptTokens > 0 {
            return runner.livePromptTokens + Int(metrics.streamTotalTokens.rounded())
        }
        guard let last = messages.last(where: { $0.role == "assistant" && ($0.usage?.promptTokens ?? 0) > 0 }),
            let usage = last.usage
        else { return 0 }
        return usage.promptTokens + usage.completionTokens
    }

    /// 概览页「当前上下文」的统一口径：应用内实时生成优先，否则取网关侧
    /// 最近/在跑会话（覆盖外部客户端、网关流量与本轮启动后已完成的对话）。
    /// 不退回磁盘持久化的旧对话历史，以免刚打开应用或刚换模型时遗留上次数值。
    var overviewContextUsedTokens: Int {
        if generating, runner.livePromptTokens > 0 {
            return contextUsedTokens
        }
        return gatewayContextTokens
    }

    var overviewContextIsEstimating: Bool {
        (generating && runner.livePromptTokens > 0) || gatewayContextIsLive
    }

    /// 引擎/模型是否可用、当前处在哪个阶段：搬进了 `ServiceCoordinator`，
    /// 它同时读引擎会话与引擎管理器，是这组判断唯一的 owner。这里只转发。
    var isSwitchingModel: Bool { service.isSwitchingModel }
    var isRunning: Bool { service.isRunning }
    var isReady: Bool { service.isReady }
    var isModelBusy: Bool { service.isModelBusy }
    var canChat: Bool { service.canChat }
    var engineStageText: String { service.engineStageText }
    var startupStage: String { service.startupStage }
    var startupSeconds: Int { service.startupSeconds }

    var port: Int { service.port }
    var failureMessage: String? { service.failureMessage }
    var downloadProgress: Double? { service.downloadProgress }
    /// Non-nil when nothing can run yet. Every engine — splash included — is an
    /// installed pack, so this is simply "no pack installed".
    var runtimeMissing: String? {
        needsEngineSetup ? "还没有安装推理引擎。打开启动页选择一个引擎即可下载安装。" : nil
    }
    /// No engine pack installed yet: the launch page owns the window until one
    /// is chosen.
    var needsEngineSetup: Bool { service.needsEngineSetup }
    var isPresentingLaunchPage: Bool { !showsRecommendationPage && (needsEngineSetup || showsLaunchPage) }
    var installedEngineIDs: [EngineID] { engines?.installedIDs ?? [] }
    /// Version of whatever engine is active, so the sidebar names the thing that
    /// is actually running instead of always claiming splash.
    var engineVersion: String { controller?.installation.version ?? "—" }
    var health: (label: String, tone: TagTone) { healthTone(stats) }

    // MARK: 指标转发
    //
    // 曲线、网关聚合、冻结时间这类高频读数整体搬进 `MetricsStore`，它是唯一 owner；
    // AppState 只把界面已经读惯的名字转过去，所以视图层一行都不用改。
    // 好处是这些读数变化时不再连带动整棵 AppState 状态树重绘。

    /// 指标状态机。它的 `objectWillChange` 在 `init` 里桥到 AppState 自己的。
    let metrics = MetricsStore()

    /// store 的发布桥回 `objectWillChange`。视图仍然是 `@ObservedObject var state`，
    /// 桥断了数值虽然在变，页面却不会重画——这是搬移里最容易漏的一根线。
    private var metricsBridge: AnyCancellable?
    private var downloadsBridge: AnyCancellable?
    private var hubBridge: AnyCancellable?
    private var modelLibraryBridge: AnyCancellable?
    private var engineSessionBridge: AnyCancellable?
    private var chatSessionBridge: AnyCancellable?
    private var uiBridge: AnyCancellable?
    private var logFeedBridge: AnyCancellable?

    var throughput: [ThroughputSample] { metrics.throughput }
    var acceptance: [ThroughputSample] { metrics.acceptance }
    var gatewayDecodeRate: Double { metrics.gatewayDecodeRate }
    var gatewayRateIsLive: Bool { metrics.gatewayRateIsLive }
    var gatewayPrefillRate: Double { metrics.gatewayPrefillRate }
    var gatewayTTFTMilliseconds: Double { metrics.gatewayTTFTMilliseconds }
    var gatewayCacheHitRate: Double { metrics.gatewayCacheHitRate }
    var gatewayCacheHitRequests: Int { metrics.gatewayCacheHitRequests }
    var averageDecodeRate: Double { metrics.averageDecodeRate }
    var gatewayContextTokens: Int { metrics.gatewayContextTokens }
    var gatewayContextIsLive: Bool { metrics.gatewayContextIsLive }
    var throughputFrozenAt: Date? { metrics.throughputFrozenAt }

    /// 读数入口都显式收 `stats`/`isRunning`：这两样是 AppState 的状态，
    /// store 里再存一份就会有两个真相。
    var decodeReading: MetricReading { metrics.decodeReading(stats: stats, isRunning: isRunning) }
    var averageDecodeReading: MetricReading { metrics.averageDecodeReading(stats: stats, isRunning: isRunning) }
    var menuBarDecodeReading: MetricReading { metrics.menuBarDecodeReading(stats: stats, isRunning: isRunning) }
    var prefillReading: MetricReading { metrics.prefillReading(stats: stats, isRunning: isRunning) }
    var ttftReading: TTFTReading { metrics.ttftReading(stats: stats, isRunning: isRunning) }
    var cacheHitReading: MetricReading { metrics.cacheHitReading(stats: stats, isRunning: isRunning) }
    var speedOrigin: SpeedOrigin { metrics.currentSpeedOrigin(stats: stats, isRunning: isRunning) }
    var overviewChartEnd: Date { metrics.overviewChartEnd }

    func overviewThroughput(window: TimeInterval) -> [ThroughputSample] {
        metrics.overviewThroughput(window: window)
    }

    func recentThroughput(window: TimeInterval) -> [ThroughputSample] {
        metrics.recentThroughput(window: window)
    }

    // MARK: 纯函数转发
    //
    // 这 7 个静态纯函数被既有测试直接调用（DecodeRateTotalTests / CacheHitTests），
    // 实现已经搬进 store，留一层转发让测试原样通过。

    nonisolated static func reading(
        origin: SpeedOrigin,
        gateway: Double,
        engine: Double?
    ) -> MetricReading {
        MetricsStore.reading(origin: origin, gateway: gateway, engine: engine)
    }

    nonisolated static func prefillReading(
        gateway: Double,
        engine: Double?,
        engineKind: EngineRateKind = .none
    ) -> MetricReading {
        MetricsStore.prefillReading(gateway: gateway, engine: engine, engineKind: engineKind)
    }

    nonisolated static func prefillReading(
        engine: Double?,
        engineKind: EngineRateKind = .none
    ) -> MetricReading {
        MetricsStore.prefillReading(engine: engine, engineKind: engineKind)
    }

    nonisolated static func ttftReading(
        engine: Double?,
        engineKind: EngineTTFTKind = .none,
        gateway: Double
    ) -> TTFTReading {
        MetricsStore.ttftReading(engine: engine, engineKind: engineKind, gateway: gateway)
    }

    nonisolated static func cacheHitReading(
        gateway: Double,
        requests: Int,
        engine: Double?
    ) -> MetricReading {
        MetricsStore.cacheHitReading(gateway: gateway, requests: requests, engine: engine)
    }

    nonisolated static func speedOrigin(
        gateway: Double,
        gatewayIsLive: Bool = true,
        engine: Double?,
        engineKind: EngineRateKind = .none,
        activeRequests: Int = 0,
        gatewayAge: TimeInterval? = nil
    ) -> SpeedOrigin {
        MetricsStore.speedOrigin(
            gateway: gateway,
            gatewayIsLive: gatewayIsLive,
            engine: engine,
            engineKind: engineKind,
            activeRequests: activeRequests,
            gatewayAge: gatewayAge)
    }

    nonisolated static func chartFrozenAt(
        previous: Date?,
        wasLive: Bool,
        isLive: Bool,
        now: Date
    ) -> Date? {
        MetricsStore.chartFrozenAt(previous: previous, wasLive: wasLive, isLive: isLive, now: now)
    }

    // MARK: 网关地址
    ///
    /// 端点 URL、网关地址与启停设置搬进了 `AppState+Gateway.swift`：它们只读
    /// 端口与设置，不碰编排状态，单独一页比夹在派生量里好找。

    // MARK: engine orchestration

    /// 引擎编排搬进了 `EngineCoordinator`，这里每个入口只留一行转发：视图、
    /// 菜单栏和 CLI 读的仍是 `state.xxx`，行为与搬之前一致。
    func bootstrap() { engineCoordinator.bootstrap() }

    func applyControlSettings() { engineCoordinator.applyControlSettings() }

    func adoptEngine(_ id: EngineID) { engineCoordinator.adoptEngine(id) }

    func reloadModels() { engineCoordinator.reloadModels() }

    func engineIsInstalled(_ id: EngineID) -> Bool { engineCoordinator.engineIsInstalled(id) }

    func requestEngineInstall(_ id: EngineID) { engineCoordinator.requestEngineInstall(id) }

    func confirmEngineInstall() { engineCoordinator.confirmEngineInstall() }

    func cancelEngineInstall() { engineCoordinator.cancelEngineInstall() }

    @discardableResult
    func switchEngine(_ id: EngineID, start: Bool = true) async -> Bool {
        await engineCoordinator.switchEngine(id, start: start)
    }

    func switchEnginePort(_ id: EngineID, port: Int) { engineCoordinator.switchEnginePort(id, port: port) }

    func engineModels() -> [EngineModel] { engineCoordinator.engineModels() }

    func engineModels(for id: EngineID) -> [EngineModel] { engineCoordinator.engineModels(for: id) }

    func prepareModelForGateway(
        _ requestedModel: String?,
        allowingGeneration: Bool = false
    ) async -> GatewayModelPreparationError? {
        await engineCoordinator.prepareModelForGateway(
            requestedModel, allowingGeneration: allowingGeneration)
    }

    func abortModelSwitch() { engineCoordinator.abortModelSwitch() }

    func shortModelName(_ id: String) -> String { engineCoordinator.shortModelName(id) }

    // MARK: hardware

    /// 硬件推荐搬进了 `ModelOps`：那边认识 `ModelLibraryStore` 与 `AppSettings`。
    /// 启动页与模型页读的仍是这几个入口，所以这里只留一行转发。
    func settleRecommendation() { modelOps.settleRecommendation() }

    func dismissRecommendationPage() { modelOps.dismissRecommendationPage() }

    func dismissRecommendation(engine: EngineID?) { modelOps.dismissRecommendation(engine: engine) }

    func recommendationTag(for id: String, engine: EngineID) -> String? {
        modelOps.recommendationTag(for: id, engine: engine)
    }

    func engineInstallFailed(_ engine: EngineID) { modelOps.engineInstallFailed(engine) }

    // MARK: model library

    /// 清单与推荐的行计算搬进了 `ModelOps`（1 秒短缓存也跟着搬）。当前浏览的
    /// 引擎仍留在 store 上，所以这里只转两行；`browseEngine` 还要清 Hub 搜索，
    /// 留着。
    func libraryRecommendations(for engine: EngineID) -> [ModelRecommendation] {
        modelOps.libraryRecommendations(for: engine)
    }

    func libraryEntries(for engine: EngineID) -> [ModelLibraryEntry] {
        modelOps.libraryEntries(for: engine)
    }

    func browseEngine(_ id: EngineID) {
        libraryEngine = id
        hub.resetSearch()
    }

    // MARK: hub

    /// 浏览相关的调用点保持不变：视图和本地控制通道仍然问 AppState，动作转给
    /// `HubStore`。搜索有两个入口（按引擎栏的一次性查询、模型广场的列表分页），
    /// 两套状态各自独立。
    func searchHub(_ query: String) { hub.searchHub(query) }

    func searchHub(
        _ query: String, sort: String, filter: String? = nil, page: Int = 0,
        source: HubSource? = nil
    ) {
        hub.searchHub(query, sort: sort, filter: filter, page: page, source: source)
    }

    func hubResults(for engine: EngineID) -> [HubSearchResult] { hub.hubResults(for: engine) }

    func loadHubDetail(_ repo: String, source: HubSource? = nil) {
        hub.loadHubDetail(repo, source: source)
    }

    func closeHubDetail() { hub.closeHubDetail() }

    func probeRepo(_ repo: String, source: HubSource? = nil) {
        hub.probeRepo(repo, source: source)
    }

    func clearRepoProbe() { hub.clearRepoProbe() }

    // MARK: draft assignments

    /// 辅助模型（DFlash2）的绑定与「用这个模型」的连锁动作搬进了 `ModelOps`：
    /// 它们最后都落到下载、切引擎、停引擎上，和模型那一段是同一件事。
    func draftAssignment(for engine: EngineID, model: String) -> String? {
        modelOps.draftAssignment(for: engine, model: model)
    }

    func installedDraftIds(for engine: EngineID) -> [String] { modelOps.installedDraftIds(for: engine) }

    func setDraftAssignment(_ draft: String?, engine: EngineID, model: String) {
        modelOps.setDraftAssignment(draft, engine: engine, model: model)
    }

    func useModel(_ id: String, engine: EngineID) { modelOps.useModel(id, engine: engine) }

    func confirmLibraryUse() { modelOps.confirmLibraryUse() }

    func cancelLibraryUse() { modelOps.cancelLibraryUse() }

    // MARK: service

    /// 选模型与启停的编排（跨引擎换模型、待确认的切换、「引擎处在哪个阶段」）
    /// 搬进了 `ServiceCoordinator`。菜单栏、控制通道、命令面板、设置页与网关
    /// 调的还是这几个入口，签名一个都没动。
    func adoptSavedModel(for id: EngineID) { service.adoptSavedModel(for: id) }
    func selectModel(_ id: String) { service.selectModel(id) }
    func applyModelFromAnyEngine(_ id: String, engine: EngineID) {
        service.applyModelFromAnyEngine(id, engine: engine)
    }
    func setDefaultModel(_ id: String, engine: EngineID) {
        service.setDefaultModel(id, engine: engine)
    }
    func applyModel(_ id: String) { service.applyModel(id) }
    func confirmModelSwitch() { service.confirmModelSwitch() }
    func cancelModelSwitchRequest() { service.cancelModelSwitchRequest() }
    func startService() { service.startService() }
    func stopService() { service.stopService() }
    func toggleService() { service.toggleService() }
    func restartService() { service.restartService() }

    // MARK: logs

    /// 日志的读取、清空与合并视图搬进了 `LogFeedService`；日志页与本地控制通道
    /// 调的还是这几个入口，签名一个都没动。
    func refreshLogs() { logFeed.refreshLogs() }

    func logEntries(for source: LogFeedSource, limit: Int = 4000) -> [LogFeedEntry] {
        logFeed.logEntries(for: source, limit: limit)
    }

    func clearLogs() { logFeed.clearLogs() }

    func clearLogs(for engine: EngineID) { logFeed.clearLogs(for: engine) }

    /// 清空当前正在读的那一份：`全部日志` 要清掉每台引擎的内存尾巴。
    func clearLogs(for source: LogFeedSource) { logFeed.clearLogs(for: source) }

    // MARK: chat
    /// 对话编排整条链路搬到了 `ChatRunner`，这里只留一行转发；状态仍由上面两个
    /// store 持有，所以视图读的 `state.messages` 等转发一行没动。
    func send(
        _ text: String, attachment: ChatImageAttachment? = nil, lastFrame: ChatImageAttachment? = nil,
        referenceImages: [ChatImageAttachment] = [], referenceClips: [VideoReferenceClip] = [],
        image: ImageOptions = ImageOptions(), video: VideoOptions = VideoOptions()
    ) {
        runner.send(
            text, attachment: attachment, lastFrame: lastFrame, referenceImages: referenceImages,
            referenceClips: referenceClips, image: image, video: video)
    }

    static func estimateTokens(_ text: String) -> Int { ChatRunner.estimateTokens(text) }
    func cancelGeneration() { runner.cancelGeneration() }
    func regenerate() { runner.regenerate() }
    func newConversation() { runner.newConversation() }
    func openThread(_ thread: ChatThread) { runner.openThread(thread) }
    func requestThreadDelete(_ thread: ChatThread) { runner.requestThreadDelete(thread) }
    func cancelThreadDelete() { runner.cancelThreadDelete() }
    func confirmThreadDelete() { runner.confirmThreadDelete() }
    func deleteThread(_ thread: ChatThread) { runner.deleteThread(thread) }
    func clearThreads() { runner.clearThreads() }
    func resetChatParameters() { runner.resetChatParameters() }

    /// 当前选中的模型本身。图像参数面板要用它上报的架构来选分辨率预设。
    var activeModel: EngineModel? { runner.activeModel }
    var activeModelSupportsImage: Bool { runner.activeModelSupportsImage }
    var activeModelSupportsVideo: Bool { runner.activeModelSupportsVideo }
    var activeModelSupportsVision: Bool { runner.activeModelSupportsVision }
    var activeModelSupportsVideoReferences: Bool { runner.activeModelSupportsVideoReferences }
    var imageToolModels: [EngineModel] { runner.imageToolModels }
    var imageToolModel: EngineModel? { runner.imageToolModel }
    var supportsImageTool: Bool { runner.supportsImageTool }
    var imageToolActive: Bool { runner.imageToolActive }

    // MARK: models

    /// 模型的安装、删除、下载与切换连锁搬进了 `ModelOps`。视图、本地控制通道
    /// （`ControlServer+Documents`）和 `EngineCoordinator` 调的还是 `state.xxx`，
    /// 签名一个都没动。
    func deleteModel(_ model: ModelInfo) { modelOps.deleteModel(model) }

    func removeModel(_ id: String, engine: EngineID) { modelOps.removeModel(id, engine: engine) }

    func downloadModel(_ id: String) { modelOps.downloadModel(id) }

    @discardableResult
    func downloadModel(_ id: String, engine: EngineID, family: String? = nil) -> Bool {
        modelOps.downloadModel(id, engine: engine, family: family)
    }

    @discardableResult
    func downloadShared(
        _ repo: String, engines: [EngineID],
        source: HubSource = .huggingFace,
        include: [String] = []
    ) -> Bool {
        modelOps.downloadShared(repo, engines: engines, source: source, include: include)
    }

    func repoIsLocal(_ repo: String) -> Bool { modelOps.repoIsLocal(repo) }

    func setSharedEngines(_ engines: [EngineID], repo: String) { modelOps.setSharedEngines(engines, repo: repo) }

    func removeShared(_ id: String) { modelOps.removeShared(id) }

    func ensureSplashDraft(_ model: ModelInfo?) async -> StartPreparation { await modelOps.ensureSplashDraft(model) }

    // MARK: download center

    /// 下载中心的门面同样只留一行：传输在 `DownloadCenter`、策略在 `ModelOps`，
    /// 界面与本地控制通道不必知道它们搬去了哪里。
    func pauseDownload() { modelOps.pauseDownload() }

    func resumeDownload(_ task: ModelDownloadTask) { modelOps.resumeDownload(task) }

    func cancelDownload(_ task: ModelDownloadTask) { modelOps.cancelDownload(task) }

    func removeTask(_ task: ModelDownloadTask) { modelOps.removeTask(task) }

    func prepareForTermination() { modelOps.prepareForTermination() }

    func finishTermination() { modelOps.finishTermination() }

    /// 复制到剪贴板并顺带提示一次；提示本身走 `UIStateStore`，视图不必自己弹。
    func copy(_ text: String, label: String = "已复制") { ui.copy(text, label: label) }

    // MARK: toasts

    /// 通知与侧栏状态搬进了 `UIStateStore`，这里只留一行转发：视图、菜单栏和
    /// 命令面板调的还是 `state.toast(...)` / `state.toggleSidebar()`。
    func toast(
        _ message: String,
        title: String? = nil,
        kind: IslandNotice.Kind? = nil,
        transient: Bool = false
    ) {
        ui.toast(message, title: title, kind: kind, transient: transient)
    }

    func dismissToast() { ui.dismissToast() }

    func markIslandNoticesRead() { ui.markIslandNoticesRead() }

    func clearIslandNotices() { ui.clearIslandNotices() }

    func toggleSidebar() { ui.toggleSidebar() }
}

let splashVersion = "1.4.0"
