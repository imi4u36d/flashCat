// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Combine
import Darwin
import FlashCatKit
import Foundation
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case overview = "概览"
    case chat = "对话"
    case models = "模型"
    case engines = "引擎"
    case logs = "日志"
    case settings = "设置"
    /// 实验是设置之后的一页，进去再用顶部分段切换图片和视频。
    case lab = "实验"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .chat: return "bubble.left"
        case .models: return "square.stack.3d.up"
        case .engines: return "cpu"
        case .logs: return "doc.plaintext"
        case .settings: return "slider.horizontal.3"
        case .lab: return "flask"
        }
    }

    /// 主工作区七页：实验紧跟在设置后面。
    static let workspace: [Page] = [.overview, .chat, .models, .engines, .logs, .settings, .lab]
}

/// How a download ended, for the callers that wait on one instead of
/// watching the download center.
enum DownloadOutcome {
    /// Every byte arrived and the model is installed.
    case finished
    /// The user paused or cancelled it; nothing is wrong, it just is not there.
    case cancelled
    case failed(String)
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var section: Page = .overview
    /// Re-open the launch page from the engines tab; the page is also shown
    /// automatically while no engine is installed.
    @Published var showsLaunchPage = false
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
    @Published var logs: [LogLine] = []
    /// 日志页读它：合并视图覆盖所有引擎，别的引擎写新行时 `logs` 不会发布，
    /// 靠这一拍让页面重新取一份。活动引擎的写入仍走 `logs`。
    @Published var logsRevision = 0
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
    @Published var notice: String?
    /// 灵动岛上短暂展示的当前通知；过期后回到引擎状态。
    @Published private(set) var islandNotice: IslandNotice?
    /// 本次会话的通知历史，展开灵动岛后按时间倒序查看。
    @Published private(set) var islandNotices: [IslandNotice] = []
    /// 尚未展开查看的通知数量。
    @Published private(set) var islandUnread = 0
    /// 悬浮导航列是否显示。隐藏后主视口铺满窗口，重新显示时恢复玻璃列；
    /// 状态落盘到 UserDefaults 的 `sidebarVisible`，重启后沿用上次的样子。
    @Published var showsSidebar: Bool

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

    private var toastWork: DispatchWorkItem?

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
    var controller: EngineController? { engines?.active }
    var activeEngine: EngineID { engines?.activeID ?? .splash }
    var availableEngines: [EngineID] { engines?.installedIDs ?? [] }

    /// Engine + model the app should open with next time. This is a preference,
    /// not the engine that is running: the settings page writes it without
    /// performing a handoff, so the live engine keeps serving its own model.
    var defaultSelection: (engine: EngineID, model: String)? {
        _ = defaultRevision
        guard !needsEngineSetup else { return nil }
        let preferred = EngineStore.shared.defaultEngineID ?? activeEngine
        let engine = engineIsInstalled(preferred) ? preferred : activeEngine
        guard engineIsInstalled(engine) else { return nil }
        let saved = EngineStore.shared.configuration(for: engine).lastModel ?? ""
        // 当前引擎的真相是 `selectedModel`：少数路径（splash 的即时选择）只写
        // 这里、不写 `engines.json` 的 `lastModel`，回落时不能把行里的模型读丢。
        let remembered = engine == activeEngine && !selectedModel.isEmpty ? selectedModel : saved
        let models = engineModels(for: engine).map(\.id)
        guard let model = EngineModelSelection.resolve(saved: remembered, available: models) else { return nil }
        return (engine, model)
    }

    init() {
        // 历史/对话写盘失败走这一条回调。用静态入口而不是捕获 `self`：`history`
        // 是 `let`，构造它的那一刻转义闭包还不允许碰 `self`；而回调真正触发的
        // 时候（用户翻历史、写线程列表）单例早已就绪。
        history = ChatHistory(onWriteFailure: { message in
            AppState.recordHistoryWriteFailure(message)
        })
        conversation = ConversationStore(onWriteFailure: { message in
            AppState.recordHistoryWriteFailure(message)
        })
        theme = ThemeController(settings: settings)
        showsSidebar = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true
        // 只拿装配对象，状态一律走 `host` 转发：两边各存一份是这类拆分最容易留的坑。
        engineCoordinator = EngineCoordinator(
            settings: settings, installs: installs, control: control, gateway: gateway,
            metrics: metrics, downloads: downloads)
        modelOps = ModelOps(
            settings: settings, downloads: downloads, modelLibrary: modelLibrary,
            engineCoordinator: engineCoordinator)
        // 对话编排搬进 `ChatRunner`：依赖交过去，要回到 AppState 办的事用闭包接上。
        runner = ChatRunner(
            chat: chat, session: chatSession, engineSession: engineSession, settings: settings,
            history: history, conversation: conversation, chatClient: chatClient,
            imageClient: imageClient, videoClient: videoClient, metrics: metrics)
        runner.hooks = ChatRunner.Hooks(
            controller: { [weak self] in self?.controller },
            activeEngine: { [weak self] in self?.activeEngine ?? .splash },
            engineModels: { [weak self] engine in self?.engineModels(for: engine) ?? [] },
            selectedModelInfo: { [weak self] in self?.selectedModelInfo },
            effectiveMaxTokens: { [weak self] in self?.effectiveMaxTokens ?? 0 },
            canChat: { [weak self] in self?.canChat ?? false },
            engineStageText: { [weak self] in self?.engineStageText ?? "" },
            port: { [weak self] in self?.port ?? 0 },
            needsEngineSetup: { [weak self] in self?.needsEngineSetup ?? true },
            prepareModel: { [weak self] model, allowing in
                guard let self else { return .unavailable("flashCat 状态不可用") }
                return await self.prepareModelForGateway(model, allowingGeneration: allowing)
            },
            modelIsResident: { [weak self] model, controller in
                self?.engineCoordinator.gatewayModelIsResident(model, in: controller) ?? false
            },
            setNotice: { [weak self] message in self?.notice = message },
            toast: { [weak self] message, kind, transient in
                self?.toast(message, kind: kind, transient: transient)
            },
            logWarning: { [weak self] line in
                self?.controller?.logs.append(line, level: .warning)
                self?.refreshLogs()
            },
            showChat: { [weak self] in self?.section = .chat }
        )
        // 下载中心只负责传输：写日志、弹提示、重扫模型目录这些它不该知道细节的
        // 事用闭包注入，收尾（要不要选中新模型、公共目录的授权表怎么写）走事件
        // 回调。这样两边谁都不持有对方，少一个环。
        downloads.hooks = DownloadCenter.Hooks(
            log: { [weak self] line, engine in
                guard let self else { return }
                self.append(log: line, engine: engine ?? self.activeEngine)
            },
            toast: { [weak self] message, transient in
                self?.toast(message, transient: transient)
            },
            setNotice: { [weak self] message in self?.notice = message },
            reloadModels: { [weak self] in self?.reloadModels() },
            modelInventoryChanged: { [weak self] in self?.invalidateModelCaches() }
        )
        // 模型/下载编排搬进 `ModelOps`：状态仍在 store 里，要回到 AppState 办的
        // 事（停引擎、切模型、弹提示、写日志、退出前收后端）用闭包接上，谁也不
        // 持有对方。
        modelOps.hooks = ModelOps.Hooks(
            activeEngine: { [weak self] in self?.activeEngine ?? .splash },
            selectedModel: { [weak self] in self?.selectedModel ?? "" },
            setSelectedModel: { [weak self] model in self?.selectedModel = model },
            needsEngineSetup: { [weak self] in self?.needsEngineSetup ?? true },
            stopService: { [weak self] in self?.stopService() },
            adoptSavedModel: { [weak self] engine in self?.adoptSavedModel(for: engine) },
            applyModel: { [weak self] model in self?.applyModel(model) },
            applyModelFromAnyEngine: { [weak self] model, engine in
                self?.applyModelFromAnyEngine(model, engine: engine)
            },
            notice: { [weak self] in self?.notice },
            setNotice: { [weak self] message in self?.notice = message },
            toast: { [weak self] message, kind, transient in
                self?.toast(message, kind: kind, transient: transient)
            },
            appendLog: { [weak self] line, engine in self?.append(log: line, engine: engine) },
            stopBackends: { [weak self] in
                self?.gateway.stop()
                self?.control.stop()
            }
        )
        downloads.onEvent = { [weak self] event in self?.modelOps.handle(event) }
        // 指标搬进 `MetricsStore` 之后，视图仍然只订阅 AppState；不把 store 的发布
        // 桥回来，数值会在变而页面不重绘。放在 init 末尾：前面的赋值不该触发重绘。
        metricsBridge = metrics.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // 下载中心是第二个 owner：进度、任务行都在它那儿，同样要把发布桥回来。
        downloadsBridge = downloads.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Hub 浏览同理：搜索结果 / 预检结果由 store 发布，界面只认 AppState 的通知。
        hubBridge = hub.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // 对话页的会话状态（待删线程、图像工具开关）。
        chatSessionBridge = chatSession.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // 引擎会话状态是第三个 owner：服务状态/指标/切换阶段都在它那儿。
        engineSessionBridge = engineSession.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // 模型库的清单与推荐由 store 持有，重绘同样要桥回来。
        modelLibraryBridge = modelLibrary.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        NotificationCenter.default.addObserver(
            forName: EngineStore.tuningDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tuningRevision += 1 }
        }
        // 编排层是装配链的最后一环：等 hook 和桥都接好再把 `self` 交过去，
        // 否则构造期间的回调会摸到一个还没装配完的 AppState。
        engineCoordinator.host = self
    }

    // MARK: derived

    var selectedModelInfo: ModelInfo? { catalog.machineModel(selectedModel) }

    /// 窗口是界面每一帧都要问的值，而取它要么重扫模型目录、要么读 config.json，
    /// 这里跟 EngineModelStore.meta 用同一档 20s 缓存，避免把扫描塞进推送热路径。
    private var contextWindowCache: (key: String, value: Int?, at: Date)?

    /// 两处扫描缓存一起失效：引擎那份归 `EngineCoordinator`，模型库那份归
    /// `ModelOps`（`libraryEntries(for:)` 的 1 秒短缓存）。
    func invalidateModelCaches() {
        engineCoordinator.invalidateModelCache()
        modelOps.invalidateLibraryCache()
    }

    /// 模型**自身**支持的上下文（config.json 的 max_position_embeddings），
    /// 不是引擎本次加载收敛后的窗口。模型库扫盘结果对 omlx / mtplx 就带这一项；
    /// splash 的机型目录只有路径，得现读 config.json（仍走 20s TTL 缓存）。
    func modelContextWindow(_ model: String) -> Int? {
        guard !model.isEmpty else { return nil }
        let key = "\(activeEngine.rawValue)|\(model)"
        if let cache = contextWindowCache, cache.key == key,
            Date().timeIntervalSince(cache.at) < 20
        {
            return cache.value
        }
        var window = engineModels(for: activeEngine)
            .first { $0.id == model }?.maximumContextTokens
        if window == nil || window == 0,
            let path = catalog.machineModel(model)?.path, !path.isEmpty
        {
            window = EngineModelStore.meta(of: path).maximumContextTokens
        }
        // GGUF 权重里没有 config.json，引擎停着时上面两条都拿不到值；记住上次
        // 真正拿到的窗口（落 UserDefaults），引擎停下或重开应用后概览「总量」
        // 才不会退成「—」。记忆只在「被告知」的那一刻写（`rememberContextWindows`
        // 与 `syncController`）：读路径一旦有副作用，任何一次重绘都会改用户设置，
        // 既难推理也没法停。
        let value: Int?
        if let window, window > 0 {
            value = window
        } else {
            let remembered = UserDefaults.standard.integer(forKey: Self.contextWindowKey(key))
            value = remembered > 0 ? remembered : nil
        }
        contextWindowCache = (key, value, Date())
        return value
    }

    private static func contextWindowKey(_ key: String) -> String { "contextWindow." + key }

    /// 引擎报告的窗口单独一层记忆：它是**本次加载**收敛后的值（splash 会被
    /// `--max-context` 和 KV 预算压低），不能拿去当模型自身上限。
    private static func reportedWindowKey(_ key: String) -> String { "contextWindowEngine." + key }

    /// 模型库刚扫过（或选中模型刚变）：把已知的模型窗口落盘记住。
    ///
    /// 写入点放在「重新扫盘」这类真实的状态变化里，而不是 `modelContextWindow`
    /// 的读取路径上——那个方法每帧都会被界面问到，顺手写 UserDefaults 意味着
    /// 重绘即改用户设置。这里只在确实知道值时写，且值没变就不重复写。
    func rememberContextWindows() {
        let engine = activeEngine
        for model in engineModels(for: engine) {
            guard let window = model.maximumContextTokens, window > 0 else { continue }
            let key = Self.contextWindowKey("\(engine.rawValue)|\(model.id)")
            if UserDefaults.standard.integer(forKey: key) != window {
                UserDefaults.standard.set(window, forKey: key)
            }
        }
    }

    /// 引擎报出本次窗口的那一刻记下来。同样只在状态变化时写。
    func rememberReportedWindow() {
        guard let reported = stats?.maximumContextTokens, reported > 0,
            !selectedModel.isEmpty
        else { return }
        UserDefaults.standard.set(
            reported,
            forKey: Self.reportedWindowKey("\(activeEngine.rawValue)|\(selectedModel)"))
    }

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

    /// 本次加载**实际可用**的上下文窗口：模型自身上限与引擎生效窗口取小。
    /// 聊天参数留空时用它封顶；两者都没报时为 nil。
    var contextWindowTokens: Int? {
        var engineWindow: Int?
        if let reported = stats?.maximumContextTokens, reported > 0 { engineWindow = reported }
        switch (modelContextWindow(selectedModel), engineWindow) {
        case (let model?, let window?): return min(model, window)
        case (let model?, nil): return model
        case (nil, let window?): return window
        case (nil, nil): return nil
        }
    }

    /// 概览页「已用 / 总量」的右半边：**模型的上下文上限**。
    ///
    /// 引擎可能把窗口压低（splash 的 `--max-context`、KV 预算），那是「这次能用
    /// 多少」；这里回答的是「这个模型最多吃多少」，所以优先不看引擎窗口。GGUF
    /// 权重没有 config.json，引擎也没在跑的时候只能靠记忆（`rememberReportedWindow`
    /// 在引擎报出窗口时写、这里只读），停引擎/重启后依然显示 262K 而不是「—」。
    var contextWindowCeiling: Int? {
        guard !selectedModel.isEmpty else { return nil }
        if let model = modelContextWindow(selectedModel) { return model }
        let key = Self.reportedWindowKey("\(activeEngine.rawValue)|\(selectedModel)")
        if let reported = stats?.maximumContextTokens, reported > 0 { return reported }
        let remembered = UserDefaults.standard.integer(forKey: key)
        return remembered > 0 ? remembered : nil
    }

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

    var isSwitchingModel: Bool { switchingModel != nil }
    /// The process exists. It says nothing about whether the weights are
    /// resident — a starting/switching engine answers no chats yet.
    var isRunning: Bool { controller?.isRunning ?? false }
    /// The engine's HTTP layer reports ready, which for hot-loading engines can
    /// happen while the weights are still being mapped in.
    var isReady: Bool { controller?.isReady ?? false }

    /// The model is not usable yet: launching, unloading, loading weights,
    /// warming up, or waiting for memory. The lifecycle line and the chat
    /// composer key off this instead of `isRunning`, which is true the moment
    /// the process spawns.
    var isModelBusy: Bool {
        if isSwitchingModel || serverState == .starting || serverState == .stopping {
            return true
        }
        return serverState == .ready && startupStage != EngineStartupStage.ready.rawValue
    }

    /// Only a ready engine with the requested weights really resident may take
    /// a chat request. Sending during the load window is what used to surface
    /// as a request error right after switching models.
    var canChat: Bool {
        !isSwitchingModel
            && serverState == .ready
            && isReady
            && startupStage == EngineStartupStage.ready.rawValue
    }

    /// Lifecycle text for every surface — the title-bar pill, the overview, the
    /// menu-bar panel and the command palette: names the phase the engine is
    /// really in, so a weight load never reads as 「运行中」. It stays quiet about
    /// the model switch itself: 「切换中」/「加载新模型」 only restate what the
    /// reader just clicked, while the switcher already shows that progress.
    var engineStageText: String {
        // 这段字里的秒数是从时钟算的，不挂在任何数据字段上。读一次心跳，把
        // 「它依赖每秒的时钟」写进这里的依赖关系：`@ObservedObject` 本来就会在
        // 每次发布时重绘，但将来若换成按读取追踪的 `@Observable`，这一行仍然是
        // 灵动岛、概览、菜单栏能继续走的理由。
        _ = lifecycleTick
        // 换模型是点下去之后一过性的事：进度和秒数在模型选择器里已经有了，
        // 这里不再复述「切换中」「加载新模型」，只报引擎真实处于的阶段。
        // 卸载旧权重的那段空窗里引擎进程还亮着、阶段会回落到「运行中」——
        // 刚被清空的模型不能说它在跑，那一格宁可空着。
        guard isSwitchingModel,
            startupStage == EngineStartupStage.ready.rawValue
        else {
            return residentStageText
        }
        return ""
    }

    /// 引擎自己上报的阶段行，不含「切换中」这类应用层编排出来的话：启停、
    /// 加载权重、预热。灵动岛、概览、菜单栏与命令面板共用这一句措辞和秒数。
    private var residentStageText: String {
        if serverState == .ready {
            let stage = startupStage
            guard stage != EngineStartupStage.ready.rawValue else { return L10n.t("运行中") }
            // 热加载引擎的 HTTP 壳子先绿、权重后到：这一段仍是「模型还不能用」，
            // 秒数不能在最长的一段里消失。用权重加载自己的起点——引擎已经跑了
            // 几个小时再被要求换权重时，进程的起点会给出一个荒唐的数字。
            guard let waited = controller?.weightLoadSeconds else { return L10n.t(stage) }
            return [L10n.t(stage), L10n.format("已等待 %@", Format.elapsed(waited))]
                .joined(separator: " · ")
        }
        var parts = [L10n.t(serverState.rawValue)]
        let stage = startupStage
        if !stage.isEmpty, stage != serverState.rawValue,
            stage != EngineStartupStage.ready.rawValue, stage != "已停止"
        {
            parts.append(L10n.t(stage))
        }
        if serverState == .starting {
            parts.append(L10n.format("已等待 %@", Format.elapsed(startupSeconds)))
        }
        return parts.joined(separator: " · ")
    }

    var port: Int {
        controller?.port
            ?? EngineStore.shared.configuration(for: activeEngine).port
            ?? activeEngine.defaultPort
    }
    var startupStage: String { controller?.startupStage ?? "已停止" }
    /// Seconds the current start has been running; 0 while idle. The console
    /// pairs it with the stage so a slow weight load shows elapsed time.
    var startupSeconds: Int { controller?.busySeconds ?? 0 }
    var failureMessage: String? { controller?.failureMessage }
    var downloadProgress: Double? { controller?.downloadProgress }
    /// Non-nil when nothing can run yet. Every engine — splash included — is an
    /// installed pack, so this is simply "no pack installed".
    var runtimeMissing: String? {
        needsEngineSetup ? "还没有安装推理引擎。打开启动页选择一个引擎即可下载安装。" : nil
    }
    /// No engine pack installed yet: the launch page owns the window until one
    /// is chosen.
    var needsEngineSetup: Bool { engines?.installedIDs.isEmpty ?? true }
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

    var endpointURL: String { "http://127.0.0.1:\(port)/v1" }

    /// The gateway's address for OpenAI-dialect clients: engine-independent, so
    /// a client's Base URL never needs to change when the engine or its port does.
    var gatewayURL: String { "http://127.0.0.1:\(settings.gatewayPort)/v1" }

    /// The same gateway for Anthropic-dialect clients. Anthropic SDKs and Claude
    /// Code append `/v1/messages` themselves, so this one stops at the root.
    var gatewayClaudeURL: String { "http://127.0.0.1:\(settings.gatewayPort)" }

    /// Start the gateway when enabled; restart it onto a new port when the
    /// setting changed, or stop it when disabled.
    func applyGatewaySettings() {
        if !settings.gatewayEnabled {
            gateway.stop()
            return
        }
        let port = UInt16(settings.gatewayPort)
        if gateway.isRunning, gateway.port == port { return }
        if gateway.isRunning { gateway.stop() }
        Task { [gateway] in
            await gateway.start(port: port)
        }
    }

    /// The speculative head the active engine runs with its stored tuning
    /// (DFlash2, MTP or none). Reading `tuningRevision` keeps the dependency
    /// alive for SwiftUI: views that show the mode refresh after a save.
    var speculativeMode: SpeculativeMode {
        _ = tuningRevision
        return EngineStore.shared.tuning(for: activeEngine).speculativeMode(for: activeEngine)
    }

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

    func searchHub(_ query: String, sort: String, filter: String? = nil, page: Int = 0) {
        hub.searchHub(query, sort: sort, filter: filter, page: page)
    }

    func hubResults(for engine: EngineID) -> [HubSearchResult] { hub.hubResults(for: engine) }

    func loadHubDetail(_ repo: String) { hub.loadHubDetail(repo) }

    func closeHubDetail() { hub.closeHubDetail() }

    func probeRepo(_ repo: String) { hub.probeRepo(repo) }

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

    /// Resolve the model this engine should start on. Model ids are engine
    /// scoped — Splash packages are `owner/repo` (e.g. the `omlx/…-e5133ef4`
    /// staging repo oMLX publishes), while the packs serve the `owner--repo`
    /// link names in their own folder. A remembered id from another engine, or
    /// one whose weights have gone, would 404 on every request, so it is
    /// replaced by a model the engine really has and the store is repaired.
    func adoptSavedModel(for id: EngineID) {
        let models = engineModels(for: id)
        let saved = EngineStore.shared.configuration(for: id).lastModel
        guard let chosen = EngineModelSelection.resolve(saved: saved, available: models.map(\.id)) else {
            selectedModel = ""
            return
        }
        selectModel(chosen)
        if chosen != saved {
            engines?.setModel(chosen, for: id)
        }
    }

    func selectModel(_ id: String) {
        selectedModel = id
        settings.setModel(id)
        settings.rememberModel(id)
    }

    /// Pick a model from any engine group in the switcher menu. A model
    /// belongs to the engine that serves its format, so one from another
    /// engine hops engines too — without another prompt, because the menu
    /// only ever showed models and the hop is the switch the reader asked
    /// for.
    func applyModelFromAnyEngine(_ id: String, engine: EngineID) {
        guard !generating else {
            toast("正在生成，先停止再切换模型")
            return
        }
        guard engineIsInstalled(engine) else {
            requestEngineInstall(engine)
            return
        }
        guard engineModels(for: engine).contains(where: { $0.id == id }) else {
            toast(L10n.format("%@ 没有模型 %@", engine.displayName, shortModelName(id)))
            return
        }
        guard engine != activeEngine else {
            applyModel(id)
            return
        }
        hopEngine(engine, model: id)
    }

    /// Choose the model the settings page should remember for the next launch.
    ///
    /// The menu spans every installed engine, but this is a preference, not a
    /// model switch: picking a model that belongs to another engine used to hop
    /// engines immediately and stop the live one. Now the pick is remembered on
    /// that engine's configuration and the running process is left alone; the
    /// default engine only moves in `EngineStore`, never in `EngineManager`.
    func setDefaultModel(_ id: String, engine: EngineID) {
        guard engineIsInstalled(engine) else {
            requestEngineInstall(engine)
            return
        }
        guard engineModels(for: engine).contains(where: { $0.id == id }) else {
            toast(L10n.format("%@ 没有模型 %@", engine.displayName, shortModelName(id)))
            return
        }
        EngineStore.shared.setDefaultEngine(engine)
        engines?.setModel(id, for: engine)
        defaultRevision += 1
        guard engine != activeEngine else {
            // This engine is already the one that runs; keeping the old
            // immediate-apply behaviour is what "默认模型" meant for it.
            applyModelFromAnyEngine(id, engine: engine)
            return
        }
        toast(
            L10n.format(
                "已把 %@ 设为 %@ 的默认模型，下次启动生效；当前运行的 %@ 不受影响",
                shortModelName(id), engine.displayName, activeEngine.displayName),
            transient: true)
    }

    /// Make `engine` the running one and load `model` on it in one motion.
    /// The sidebar still switches engines explicitly, but the model switcher
    /// hides the hop: from the reader's point of view only the model changed.
    ///
    /// The handoff is a real unload, not just a load: the old engine is stopped
    /// and awaited (process gone, port released) before the new one starts, so
    /// two models never sit in unified memory at the same time. The switcher
    /// shows 「停止旧引擎」 during that wait and 「加载新模型」 afterwards.
    private func hopEngine(_ engine: EngineID, model: String) {
        guard let engines, engines.controller(engine) != nil else { return }
        let wasRunning = isRunning
        // 跨引擎的新选择必须立刻生效：上一次切换（可能是另一台引擎上几分钟的
        // 权重加载）在这里作废，而不是排队等它结束——排队就是「点了新模型，
        // 界面还停在旧的那一次切换里」。
        engineCoordinator.retireModelSwitch()
        confirmingModelSwitch = nil
        let generation = engineCoordinator.currentSwitchGeneration
        // 停着的时候不再只换选择：跨引擎选模型同样意味着「现在就跑它」，
        // 所以界面直接进入「启动引擎」。
        switchingModel = model
        switchStage = wasRunning ? "停止旧引擎" : "启动引擎"

        engineCoordinator.switchTask = Task { [weak self] in
            guard let self else { return }
            // 只在这里换引擎：等旧引擎真的退出，再让新引擎加载权重。
            let activated = await engines.activate(engine)
            // 被更新的选择接管了：状态与引擎都归那一代，这里静默退出。
            guard generation == self.engineCoordinator.currentSwitchGeneration else { return }
            guard activated || self.activeEngine == engine else {
                self.engineCoordinator.settleModelSwitch(
                    generation: generation,
                    outcome: .failed("\(engine.displayName) 没有可用的控制器"))
                return
            }
            self.libraryEngine = engine
            self.reloadModels()
            // The picked model wins over the engine's remembered one.
            self.selectModel(model)
            engines.setModel(model, for: engine)
            self.engineCoordinator.syncController()

            self.switchStage = "加载新模型"
            guard let controller = self.controller else {
                self.engineCoordinator.settleModelSwitch(
                    generation: generation,
                    outcome: .failed("\(engine.displayName) 没有可用的控制器"))
                return
            }
            await controller.start(localModel: self.selectedModelInfo, requestedModel: model)
            // 等「真的加载完」而不是「HTTP 壳子绿了」，否则界面会在权重刚
            // 开始搬的时候就退出「切换中」（见 waitForSwitchReady 里的日志）。
            let ready = await controller.waitForSwitchReady(model, timeout: engine.startupTimeout)
            self.engineCoordinator.settleModelSwitch(
                generation: generation,
                outcome: ready
                    ? .ready
                    : .failed(controller.failureMessage ?? "\(engine.displayName) 未能在预期时间内就绪"))
        }
    }

    /// Select a model and, if the engine is live, reload it on the new weights.
    /// The switcher UI stays in a loading state until the new engine reports
    /// ready, so a slow weight load never looks like an ignored click.
    func applyModel(_ id: String) {
        let target = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        if target == selectedModel {
            // 选回正在切的那一个（或已生效的那一个）= 没必要再动；如果刚才排过
            // 一次别的选择，这次点击就是「改主意」，把队列清掉。
            if isSwitchingModel { engineCoordinator.queuedSwitchModel = nil }
            return
        }
        guard !generating else {
            toast("正在生成，先停止再切换模型")
            return
        }
        if isSwitchingModel {
            // 同引擎的第二次选择不能打断已经在跑的加载（EngineController 单飞），
            // 排到这次切换之后；队列只留最后一次，读者连点三下就是最后一下生效。
            if target != switchingModel {
                engineCoordinator.queuedSwitchModel = target
                // 排队只是「你的点击没丢」的一过性回执：不留在通知历史里。
                toast(
                    L10n.format("正在切换模型，完成后自动切到 %@", shortModelName(target)),
                    transient: true)
            }
            return
        }

        // The menu only offers this engine's models, but a stale list or an id
        // typed into settings must not reach the wire: the engine would answer
        // 404 and keep retrying it.
        let models = engineModels()
        if !EngineModelSelection.isServable(target, available: models.map(\.id)) {
            toast(L10n.format("%@ 没有模型 %@", activeEngine.displayName, shortModelName(target)))
            return
        }

        // With weights loaded the switch unloads them first, which leaves the
        // engine without a model for a while — ask before doing that. With
        // nothing resident the pick is only a selection, applied on next start.
        guard
            EngineModelSelection.needsConfirmation(
                isRunning: isRunning,
                current: selectedModel,
                target: target)
        else {
            commitModelSwitch(to: target)
            return
        }
        confirmingModelSwitch = target
    }

    /// Run the switch the reader just approved.
    func confirmModelSwitch() {
        guard let target = confirmingModelSwitch else { return }
        confirmingModelSwitch = nil
        commitModelSwitch(to: target)
    }

    func cancelModelSwitchRequest() {
        confirmingModelSwitch = nil
    }

    private func commitModelSwitch(to target: String) {
        selectModel(target)
        if activeEngine != .splash {
            engines?.setModel(target, for: activeEngine)
        }
        engineCoordinator.beginModelSwitch(to: target)
    }

    func startService() {
        guard !isSwitchingModel else { return }
        guard !needsEngineSetup else {
            notice = "还没有安装推理引擎，请先在启动页选择一个"
            return
        }
        guard !selectedModel.isEmpty else {
            notice = "还没有选择模型"
            return
        }
        // Weights already on disk launch in place; an id that is not downloaded
        // yet goes through the requested-model path so the engine's own launcher
        // can fetch it.
        Task {
            await controller?.start(localModel: selectedModelInfo, requestedModel: selectedModel)
        }
    }

    func stopService() {
        engineCoordinator.cancelModelSwitch()
        controller?.stop()
    }

    func toggleService() {
        if isRunning {
            stopService()
        } else if !isSwitchingModel {
            startService()
        }
    }

    func restartService() {
        Task { await controller?.restart(localModel: selectedModelInfo) }
    }

    // MARK: logs

    func refreshLogs() { logs = controller?.logs.snapshot(limit: 4000) ?? [] }

    /// 日志页要的行。`.all` 把每台已装引擎的尾巴并成一份（最新在前），
    /// 单引擎来源只取它自己的；行里带着来源，页面据此决定要不要显示来源列。
    func logEntries(for source: LogFeedSource, limit: Int = 4000) -> [LogFeedEntry] {
        switch source {
        case .all:
            let groups = (engines?.available ?? []).map { controller in
                LogFeed.Group(
                    key: controller.id.rawValue,
                    tag: controller.id.rawValue,
                    lines: controller.logs.snapshot(limit: limit))
            }
            return LogFeed.entries(from: groups, limit: limit)
        case .engine(let id):
            let lines = engines?.controller(id)?.logs.snapshot(limit: limit) ?? []
            return LogFeed.entries(
                from: [LogFeed.Group(key: id.rawValue, tag: nil, lines: lines)],
                limit: limit)
        }
    }

    func clearLogs() {
        controller?.logs.clear()
        refreshLogs()
        logsRevision &+= 1
    }

    func clearLogs(for engine: EngineID) {
        engines?.controller(engine)?.logs.clear()
        if engine == activeEngine { refreshLogs() }
        // 清空不改变 `latestId`，指纹看不出这一拍，得自己通知日志页。
        logsRevision &+= 1
    }

    /// 清空当前正在读的那一份：`全部日志` 要清掉每台引擎的内存尾巴。
    func clearLogs(for source: LogFeedSource) {
        switch source {
        case .all:
            for controller in engines?.available ?? [] { controller.logs.clear() }
            refreshLogs()
            logsRevision &+= 1
        case .engine(let id):
            clearLogs(for: id)
        }
    }

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
    func downloadShared(_ repo: String, engines: [EngineID]) -> Bool {
        modelOps.downloadShared(repo, engines: engines)
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

    /// Engine logs are per engine; only the running engine's copy is on screen.
    /// 历史写盘失败在 ChatHistory 的后台串行队列上触发，要回到主 actor 才能
    /// 写日志流。写成静态入口是为了让 `history` 的构造闭包不必捕获 `self`
    ///（init 期间不允许），代价是只对单例有效——而 AppState 本来就是单例。
    nonisolated private static func recordHistoryWriteFailure(_ message: String) {
        Task { @MainActor in
            AppState.shared.reportHistoryWriteFailure(message)
        }
    }

    /// 日志页读的就是当前引擎的日志流，失败优先落在那里。引擎还没挂上时退到
    /// 网关日志：两条都是会落盘的真实文件，反正不许让失败凭空消失。
    private func reportHistoryWriteFailure(_ message: String) {
        if let store = controller?.logs {
            store.append(message, level: .error)
            logs = store.snapshot(limit: 4000)
        } else {
            gateway.logs.append(message, level: .error)
        }
    }

    private func append(log line: String, engine: EngineID) {
        engines?.controller(engine)?.logs.append(line, level: .system)
        if engine == activeEngine { logs = controller?.logs.snapshot(limit: 4000) ?? [] }
    }

    func copy(_ text: String, label: String = "已复制") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // 回执：粘贴的时候就能看见结果，不必占一行历史。
        toast(label, transient: true)
    }

    // MARK: toasts

    /// - Parameter transient: 一过性提示：模型加载、切换这类过程，以及复制和各
    ///   种入口的成功回执。结果在界面上立刻看得见（阶段行、选择器里的进度、
    ///   粘贴板、已经改好的设置），留在历史里只是噪音，所以只闪几秒，不占通知
    ///   历史与未读数。失败、阻塞、后台任务完成和破坏性操作仍然留存——那是读
    ///   者回头要看的。
    func toast(
        _ message: String,
        title: String? = nil,
        kind: IslandNotice.Kind? = nil,
        transient: Bool = false
    ) {
        // Classify from the source text (the kind rules are written against
        // Chinese phrases) before swapping in the localized message. Callers
        // that already know the lifecycle phase pass an explicit kind so a
        // model-ready notice reads as success and a still-loading notice stays
        // warning, regardless of how the message happens to be worded.
        let kind = kind ?? IslandNotice.Kind(message: message)
        let notice = IslandNotice(
            title: L10n.t(title ?? kind.defaultTitle),
            message: L10n.t(message),
            kind: kind,
            transient: transient
        )
        islandNotice = notice
        // 一过性提示只占胶囊那一格：3 秒后自己回到引擎状态，不写历史、不加未读。
        if !transient {
            islandNotices.insert(notice, at: 0)
            if islandNotices.count > 30 {
                islandNotices.removeLast(islandNotices.count - 30)
            }
            islandUnread += 1
        }
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.islandNotice?.id == notice.id else { return }
            self.islandNotice = nil
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    /// 收起灵动岛时清掉短暂通知，历史仍留在通知列表里。
    func dismissToast() {
        toastWork?.cancel()
        islandNotice = nil
    }

    /// 展开灵动岛即视为读过了所有通知。
    func markIslandNoticesRead() {
        islandUnread = 0
    }

    func clearIslandNotices() {
        toastWork?.cancel()
        islandNotice = nil
        islandNotices.removeAll()
        islandUnread = 0
    }

    // MARK: sidebar

    /// 侧栏折叠/展开动画的截止时刻。动画每帧都在重排与合成，期间任何整表刷新
    /// （模型目录扫描、日志重排）都要推迟到收口之后，否则会吃掉 CA 提交的帧。
    /// 不进 objectWillChange：它只是调度信息。
    var sidebarAnimUntil = Date.distantPast

    func toggleSidebar() {
        // 侧栏列宽、收起按钮的横向位置和图标栏的裁切共用这一个动画事务，
        // 从菜单栏、命令面板或标题栏按钮触发时表现一致。
        withAnimation(.smooth(duration: 0.25)) {
            showsSidebar.toggle()
        }
        sidebarAnimUntil = Date().addingTimeInterval(0.35)
        UserDefaults.standard.set(showsSidebar, forKey: "sidebarVisible")
    }
}

let splashVersion = "1.4.0"

/// Streams a child process pipe line by line without blocking the main thread.
///
/// 缓冲区必须是引用类型：`readabilityHandler` 是 `@Sendable` 的，把 `var buffer`
/// 直接捕获进去，等于允许两条线程同时改同一块数据。锁只保护缓冲区，回调在锁外
/// 执行——`onLine` 里通常还要再跳一次主线程，持锁回调会把锁序搞乱。
final class TailReader: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = LineSplitter()

    static func read(_ pipe: Pipe, onLine: @escaping @Sendable (String) -> Void) {
        let reader = TailReader()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                reader.flush(onLine)
                return
            }
            reader.consume(chunk, onLine: onLine)
        }
    }

    private func consume(_ chunk: Data, onLine: @Sendable (String) -> Void) {
        lock.lock()
        let lines = splitter.consume(chunk)
        lock.unlock()
        // 回调在锁外：`onLine` 里通常还要再跳一次主线程，持锁回调会把锁序搞乱。
        for line in lines { onLine(line) }
    }

    private func flush(_ onLine: @Sendable (String) -> Void) {
        lock.lock()
        let rest = splitter.flush()
        lock.unlock()
        if let rest { onLine(rest) }
    }
}

/// 按行切分命令行输出。huggingface_hub 的 tqdm 用回车重画进度条，所以 Splash
/// 的下载在退出前只会吐 `\r`；两种换行都要切，空行（纯重画）丢掉。
struct LineSplitter {
    private var buffer = Data()

    mutating func consume(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = buffer.prefix(upTo: index)
            buffer.removeSubrange(...index)
            if !line.isEmpty, let text = String(data: line, encoding: .utf8) {
                lines.append(text)
            }
        }
        return lines
    }

    mutating func flush() -> String? {
        defer { buffer = Data() }
        guard !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) else { return nil }
        return text
    }
}
