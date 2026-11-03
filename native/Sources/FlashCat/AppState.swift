import Foundation
import SwiftUI
import AppKit
import FlashCatKit

enum Page: String, CaseIterable, Identifiable {
    case overview = "概览"
    case chat = "对话"
    case models = "模型"
    case engines = "引擎"
    case logs = "日志"
    case settings = "设置"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .chat: return "bubble.left.and.text.bubble.right"
        case .models: return "shippingbox"
        case .engines: return "gearshape"
        case .logs: return "doc.plaintext"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct ThroughputSample: Identifiable {
    let id = UUID()
    let at: Date
    let value: Double
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
    @Published var serverState: ServerState = .stopped
    @Published var stats: ServerStats?
    @Published var logs: [LogLine] = []
    @Published var catalog = ModelCatalog()
    @Published var selectedModel: String = ""
    /// Non-nil while newly selected weights are loading. The switchers show an
    /// inline spinner and the overview swaps live metrics for skeletons.
    @Published private(set) var switchingModel: String?
    /// Stage the running switch is in ("卸载旧模型" / "加载新模型"). Shown in the
    /// switcher instead of a generic spinner so the wait is explainable.
    @Published private(set) var switchStage: String = ""
    /// 每次切换领一个号，只有当代的结尾允许改「切换中」状态。被接管或被取消的
    /// 旧任务回来时代数已经不同，它就静默退出：既不会抹掉新切换的状态，也没人
    /// 能把界面永久留在「切换中」。
    private var switchGeneration = 0
    /// 切换进行中又选了一个本引擎的模型：排到这次切换之后，只保留最后一次。
    /// 以前这里直接丢弃，读者看到的是「点了没反应」。
    private var queuedSwitchModel: String?
    /// Non-nil while a model switch is waiting for the reader to confirm that
    /// the model that is loaded now gets stopped first. Switching weights means
    /// unloading the resident model, so the engine is briefly unusable — that is
    /// worth one click, not a silent stall.
    @Published var confirmingModelSwitch: String?
    @Published var messages: [ChatMessage] = []
    @Published var threads: [ChatThread] = []
    /// 当前会话在「最近对话」里的 id。以前每轮生成结束都新建一条线程，同一段
    /// 对话会在侧栏堆成好几份（概览读到的上下文也可能来自旧副本）；现在这个 id
    /// 跟着 `conversation.json` 一起用，`history.save` 原地覆盖而不是 insert。
    /// 落在 UserDefaults，重启后续着同一条。
    private var threadID: String {
        get {
            let defaults = UserDefaults.standard
            if let existing = defaults.string(forKey: "chat.threadID"), !existing.isEmpty {
                return existing
            }
            let fresh = Self.newThreadID()
            defaults.set(fresh, forKey: "chat.threadID")
            return fresh
        }
        set { UserDefaults.standard.set(newValue, forKey: "chat.threadID") }
    }

    static func newThreadID() -> String {
        String(Int(Date().timeIntervalSince1970 * 1_000_000))
    }
    @Published var generating = false
    @Published var generationStatus: String?
    /// Persistent banner for errors that need the reader's attention.
    @Published var notice: String?
    /// Transient bottom toast.
    @Published var toastMessage: String?
    /// 侧边栏是否展开。折叠后网页侧留一条图标 rail，导航不消失；
    /// 状态落盘到 UserDefaults 的 `sidebarVisible`，重启后沿用上次的样子。
    @Published var showsSidebar: Bool
    @Published var throughput: [ThroughputSample] = []
    /// 草稿接受率（DFlash2 / MTP）的时间序列，采样节奏与吞吐一致，
    /// 概览页用它画第二条实时曲线。value 是 0…1 的比例。
    @Published var acceptance: [ThroughputSample] = []
    /// 应用内对话流式回复的本地测速（tok/s）。三个引擎对「解码速度」的口径
    /// 并不一致：splash 报实时值，oMLX 报开机以来的累计均值（只在请求结束
    /// 时跳一格）。生成期间概览卡与曲线统一改用这个本地口径，空闲时回落到
    /// 引擎自报的读数。
    @Published private(set) var liveDecodeRate: Double?
    /// 流式测速的滑动窗口：窗口内的 token 估算数与窗口起点。
    private var streamWindowTokens = 0
    private var streamWindowStart: Date?
    @Published var downloadingModel: String?
    /// Which engine the running download is for: two engines can hold models
    /// with the same id, and only the one being written shows the progress bar.
    @Published private(set) var downloadingEngine: EngineID?
    @Published var downloadFraction: Double?
    /// Live transfer speed of the running download, bytes per second.
    @Published private(set) var downloadSpeed: Double = 0
    /// Download center rows. Paused and failed transfers survive a relaunch
    /// (the Hub keeps partial files in the destination's `.cache`), so the
    /// list is persisted and "downloading" rows become "paused" on load.
    @Published private(set) var downloadTasks: [ModelDownloadTask] = []
    /// Hugging Face 浏览器的状态：列表与单个仓库详情分开存——弹层里翻 tab 不
    /// 该把列表挤掉，两者也都只是「看一眼」，不持久化、不碰磁盘。
    @Published private(set) var hubResults: [HubModel] = []
    /// 公共目录里已落盘的仓库 id（模型广场标「已在本机」用）。
    @Published private(set) var sharedRepos: [String] = []
    /// 本机已有的全部仓库：公共目录加三个引擎自己的模型目录。比 `sharedRepos`
    /// 宽——引擎目录里手放的、或从引擎推荐里下的权重同样算「已经有了」，下载
    /// 弹窗据此把下载按钮换成「已下载」。跟着 `reloadModels` 走，不进两秒一次的
    /// 快照热路径。
    @Published private(set) var localModelRepos: [String] = []
    /// 手填仓库 id 的预检结果：输入停下后查一次 Hub，弹窗里显示体积/参数量/
    /// 文件清单/README 摘要，看清了再按下「开始下载」。和模型广场的 `hubDetail`
    /// 分开存，两边同时在屏上也不会互相挤掉。
    @Published private(set) var repoProbe: HubModel?
    @Published private(set) var repoProbeLoading = false
    @Published private(set) var repoProbeError: String?
    /// 当前这份预检结果属于哪个仓库。网页拿它对输入框：用户还在改 id 时，
    /// 旧结果不能被当成新仓库的结果显示出来。
    @Published private(set) var repoProbeRepo = ""
    private var repoProbeTask: Task<Void, Never>?
    private var repoProbeKey = ""
    @Published private(set) var hubDetail: HubModel?
    @Published private(set) var hubQuery = ""
    @Published private(set) var hubSort: HubSort = .trending
    @Published private(set) var hubFilter: HubFilter = .all
    /// 0 起的页码。HF 的 skip 是纯偏移，所以页码就是 skip / pageSize。
    @Published private(set) var hubPage = 0
    /// 这一页满了就认为还有下一页（HF 不给总数，模型列表也没有 count 接口）。
    @Published private(set) var hubHasMore = false
    @Published private(set) var hubLoading = false
    @Published private(set) var hubDetailLoading = false
    @Published private(set) var hubError: String?
    private var hubSearchTask: Task<Void, Never>?
    private var hubDetailTask: Task<Void, Never>?
    /// Which engine's model library the model page shows. Browsing is
    /// deliberately independent of the running engine, so an engine that is
    /// stopped — or that has no weights at all — can still be inspected,
    /// filled from the Hub and compared with the others.
    @Published var libraryEngine: EngineID = .splash
    /// Hub search for the model page. Session-scoped: the results live in
    /// memory only, so switching engines or relaunching drops them.
    @Published private(set) var hubSearch = HubSearchState()
    /// Set when a model is picked for an engine that is not running: the switch
    /// is a bigger step than a model change, so it asks first.
    @Published var pendingLibraryUse: LibraryUseRequest?
    /// Set when a switch targets an engine whose pack is not installed. The
    /// weights can be on disk (browsing works without the runtime), so without
    /// this the switch would silently do nothing while claiming success.
    @Published var pendingEngineInstall: EngineID?
    /// What this Mac should run, per engine; `nil` until the first launch has
    /// decided. Stored in `AppSettings`, so the model page's tags outlive a
    /// relaunch without touching the hardware again.
    @Published private(set) var hardwareRecommendation: HardwareRecommendation?
    /// The first-run page is up. Only when nothing is installed yet and the
    /// question has not been answered before.
    @Published var showsRecommendationPage = false
    /// Model to download as soon as the recommended engine's install finishes:
    /// the downloader refuses to run while the pack is missing.
    @Published var pendingRecommendedDownload: (engine: EngineID, model: String)?

    /// Bumped whenever any engine's tuning is saved. `speculativeMode` reads it
    /// so a view showing the mode re-renders after the config page saves.
    @Published private(set) var tuningRevision = 0

    private var toastWork: DispatchWorkItem?
    /// Polls the folder a snapshot download writes into, so the card can show
    /// a percentage without the downloader having to report one.
    private var downloadWatchTask: Task<Void, Never>?
    /// Bytes the Hub says the whole repository needs, printed by the downloader
    /// before the transfer starts.
    private var downloadTotalBytes = 0
    /// The running downloader child process; terminating it is how pause and
    /// cancel stop the transfer while the Hub's partial files stay on disk.
    private var downloadProcess: Process?
    /// Set while a caller waits for a download to end (a launch that has to
    /// fetch the model's DFlash2 draft first). Reported once, in
    /// `finishDownload`, whichever way the process ended.
    private var downloadCompletion: ((DownloadOutcome) -> Void)?
    /// True while that launch-triggered download runs: it must not steal the
    /// selection or pop a toast, the engine start right behind it says more.
    private var supplementInFlight = false
    private var pauseRequested = false
    private var cancelRequested = false
    private var lastWatchBytes = 0
    private var lastWatchDate: Date?
    /// Hub cache folders the running download fills, discovered from the
    /// child's `Fetching …` lines. Splash's tqdm only counts finished files —
    /// its bar sits at 0% for minutes while one shard streams — so byte growth
    /// under these folders is what actually moves the bar.
    private var downloadWatchDirectories: [String] = []
    /// Size of each watched folder when it joined the watch: bytes that were
    /// already cached before this download started are not new progress.
    private var downloadWatchBaselines: [String: Int] = [:]
    /// 正在下载到公共目录的仓库与它的授权引擎：下载成功后据此写授权表、建
    /// 链接。非公共下载时为 nil。
    private var pendingSharedRepo: String?
    private var pendingSharedEngines: [EngineID] = []
    /// The single task that owns a model switch. Nothing else may touch the
    /// engine while it runs — the old weights must be confirmed gone before the
    /// new ones allocate.
    private var switchTask: Task<Void, Never>?
    /// Active engine as of the last pack install/uninstall callback. When an
    /// uninstall removes the engine in use, `rebuild()` silently falls back to
    /// another pack (or to none); comparing against this snapshot is how the
    /// models page and the selected model are pointed at the new reality.
    private var installsObservedEngine: EngineID?

    let settings = AppSettings()
    /// Owns the day/night skin choice and applies it to AppKit.
    let theme: ThemeController
    let history = ChatHistory()
    let conversation = ConversationStore()
    let chatClient = ChatClient()
    /// The fixed-port API gateway (OpenAI + Claude formats). One instance for
    /// the whole app; requests it serves read the live engine state from here.
    let gateway = GatewayController.shared
    var engines: EngineManager?
    /// Pack installs shown on the engines page; owns its own installer actor.
    let installs = EngineInstallCenter()
    var controller: EngineController? { engines?.active }
    var activeEngine: EngineID { engines?.activeID ?? .splash }
    var availableEngines: [EngineID] { engines?.installedIDs ?? [] }

    /// Splash's pack doubles as this app's model installer: hub models are
    /// fetched by the same Python that serves them. `nil` until splash is
    /// installed, which is why downloading asks for it explicitly.
    var splashRuntime: EngineRuntime? {
        guard let root = EngineInstallations.newest(.splash, version: nil)?.root.path else { return nil }
        return EngineRuntime(root: root)
    }

    init() {
        theme = ThemeController(settings: settings)
        showsSidebar = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true
        downloadTasks = ModelDownloadStore.load()
        NotificationCenter.default.addObserver(forName: EngineStore.tuningDidChangeNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tuningRevision += 1 }
        }
    }

    // MARK: derived

    var selectedModelInfo: ModelInfo? { catalog.machineModel(selectedModel) }

    /// 窗口是快照每一帧都要问的值，而取它要么重扫模型目录、要么读 config.json，
    /// 这里跟 EngineModelStore.meta 用同一档 20s 缓存，避免把扫描塞进推送热路径。
    private var contextWindowCache: (key: String, value: Int?, at: Date)?

    /// 模型**自身**支持的上下文（config.json 的 max_position_embeddings），
    /// 不是引擎本次加载收敛后的窗口。模型库扫盘结果对 omlx / mtplx 就带这一项；
    /// splash 的机型目录只有路径，得现读 config.json（仍走 20s TTL 缓存）。
    func modelContextWindow(_ model: String) -> Int? {
        guard !model.isEmpty else { return nil }
        let key = "\(activeEngine.rawValue)|\(model)"
        if let cache = contextWindowCache, cache.key == key,
           Date().timeIntervalSince(cache.at) < 20 {
            return cache.value
        }
        var window = engineModels(for: activeEngine)
            .first { $0.id == model }?.maximumContextTokens
        if window == nil || window == 0,
           let path = catalog.machineModel(model)?.path, !path.isEmpty {
            window = EngineModelStore.meta(of: path).maximumContextTokens
        }
        // GGUF 权重里没有 config.json，引擎停着时上面两条都拿不到值；记住上次
        // 真正拿到的窗口（落 UserDefaults），引擎停下或重开应用后概览「总量」
        // 才不会退成「—」。
        let value: Int?
        if let window, window > 0 {
            UserDefaults.standard.set(window, forKey: Self.contextWindowKey(key))
            value = window
        } else {
            let remembered = UserDefaults.standard.integer(forKey: Self.contextWindowKey(key))
            value = remembered > 0 ? remembered : nil
        }
        contextWindowCache = (key, value, Date())
        return value
    }

    private static func contextWindowKey(_ key: String) -> String { "contextWindow." + key }

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
        case let (model?, window?): return min(model, window)
        case let (model?, nil): return model
        case let (nil, window?): return window
        case (nil, nil): return nil
        }
    }

    /// 概览页「已用 / 总量」的右半边：**模型的上下文上限**。
    ///
    /// 引擎可能把窗口压低（splash 的 `--max-context`、KV 预算），那是「这次能用
    /// 多少」；这里回答的是「这个模型最多吃多少」，所以不看引擎窗口。GGUF 权重
    /// 没有 config.json，引擎也没在跑的时候只能靠记忆：每次拿到值就按
    /// `engine|model` 落到 UserDefaults，停引擎/重启后依然显示 262K 而不是「—」。
    var contextWindowCeiling: Int? {
        guard !selectedModel.isEmpty else { return nil }
        if let model = modelContextWindow(selectedModel) { return model }
        let key = Self.contextWindowKey("\(activeEngine.rawValue)|\(selectedModel)")
        if let reported = stats?.maximumContextTokens, reported > 0 {
            UserDefaults.standard.set(reported, forKey: key)
            return reported
        }
        let remembered = UserDefaults.standard.integer(forKey: key)
        return remembered > 0 ? remembered : nil
    }

    /// 当前会话已占用的上下文 tokens：**只认引擎回报的真实 usage**。
    ///
    /// 取最近一条带 `prompt_tokens` 的回复，`prompt + completion` 就是那一轮
    /// 结束时真正躺在 KV 里的量。还没跑完第一轮（或旧数据没带 usage）时返回 0——
    /// 按字符估算出来的数看着像真实值，反而误导。
    var contextUsedTokens: Int {
        guard let last = messages.last(where: { $0.role == "assistant" && ($0.usage?.promptTokens ?? 0) > 0 }),
              let usage = last.usage else { return 0 }
        return usage.promptTokens + usage.completionTokens
    }

    var isSwitchingModel: Bool { switchingModel != nil }
    var isRunning: Bool { controller?.isRunning ?? false }
    var isReady: Bool { controller?.isReady ?? false }
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

    /// Fixed 30-second window for the hero sparkline; older samples are dropped
    /// at the sampler so this only filters late arrivals.
    /// 吞吐卡（MOCKUP A）的三个时间窗：45 秒 / 5 分钟 / 全部。
    func recentThroughput(window: TimeInterval) -> [ThroughputSample] {
        guard window > 0 else { return throughput }
        let cutoff = Date().addingTimeInterval(-window)
        return throughput.filter { $0.at >= cutoff }
    }

    /// Same windows for the draft-acceptance curve, so both charts scroll together.
    func recentAcceptance(window: TimeInterval) -> [ThroughputSample] {
        guard window > 0 else { return acceptance }
        let cutoff = Date().addingTimeInterval(-window)
        return acceptance.filter { $0.at >= cutoff }
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

    // MARK: lifecycle

    private func syncController() {
        serverState = controller?.state ?? .stopped
        stats = controller?.stats
        if let store = controller?.logs, store.latestId != logs.last?.id {
            logs = store.snapshot()
        } else if controller == nil, !logs.isEmpty {
            logs = []
        }

        let now = Date()
        // 保留 30 分钟：概览的区间选择器有「45 秒 / 5 分钟 / 全部」三档，
        // 序列只留 5 分钟的话「全部」永远等于「5 分钟」，看起来就像没生效。
        let cutoff = now.addingTimeInterval(-1800)
        // 引擎空闲时不会把指标清零，而是把「最后一次」原样回报：splash 请求结束后
        // metrics.decode_tokens_per_second 会一直停在最后一格（实测 116.2899403）。
        // 这种重复读数不是新数据。照抄进序列，曲线会凭空续出一段平线，均值也会被
        // 空闲时间一路拖着走——所以只收「数值真的动过」的读数，序列里就只剩下生成
        // 阶段的那几秒。
        //
        // 应用内生成期间这套采样让位给本地测速（recordStreamDelta）：oMLX 的
        // avg_generation_tps 是累计均值，整个生成过程一动不动，一次回复只会在
        // 结束时落 1 个点，曲线永远凑不满两个点（表现就是「回复都结束了图还是
        // 空的」）。外部 API 请求不经过这里，仍走引擎自报的读数。
        let freshRate = stats?.decodeTokensPerSecond.map { rate in
            rate > 0 && (throughput.last.map { abs($0.value - rate) > 0.0001 } ?? true)
        } ?? false

        if !generating, freshRate, let rate = stats?.decodeTokensPerSecond {
            if throughput.last.map({ now.timeIntervalSince($0.at) >= 0.9 }) ?? true {
                throughput.append(ThroughputSample(at: now, value: rate))
                throughput.removeAll { $0.at < cutoff }
            }
        }

        // 接受率与吞吐同频采样。引擎给的是会话累计值：空闲时它不变，生成时才爬。
        // 因此只在「数值真的变了」或「解码读数正在动」的时候落点——否则每秒都会多
        // 一个样本，快照 JSON 每秒都不同，概览页会被迫整页重绘。
        if let latest = stats?.draftAcceptance {
            let due = acceptance.last.map { now.timeIntervalSince($0.at) >= 0.9 } ?? true
            let changed = acceptance.last.map { abs($0.value - latest) > 0.0001 } ?? true
            if due, changed || freshRate {
                acceptance.append(ThroughputSample(at: now, value: latest))
                acceptance.removeAll { $0.at < cutoff }
            }
        }

        if switchingModel != nil { syncSwitchStage() }
    }

    /// 流式回复的本地测速：每个增量累计 token 估算数，窗口攒满 ~0.9 秒算一次
    /// 瞬时速率，与引擎轮询采样同样的节奏落点。三个引擎共用这一个口径，
    /// 曲线在生成期间就是真实在动的。
    private func recordStreamDelta(_ piece: String) {
        let tokens = Self.estimateTokens(piece)
        guard tokens > 0 else { return }
        let now = Date()
        guard let start = streamWindowStart else {
            streamWindowStart = now
            streamWindowTokens = tokens
            return
        }
        streamWindowTokens += tokens
        let interval = now.timeIntervalSince(start)
        guard interval >= 0.9, streamWindowTokens > 0 else { return }
        let rate = Double(streamWindowTokens) / interval
        streamWindowTokens = 0
        streamWindowStart = now
        liveDecodeRate = rate
        let cutoff = now.addingTimeInterval(-1800)
        throughput.append(ThroughputSample(at: now, value: rate))
        throughput.removeAll { $0.at < cutoff }
    }

    func bootstrap() {
        let service = ModelCatalogService()
        service.migrateLegacyDirectory()
        Paths.ensureDirectory(Paths.modelsDirectory)

        // 旧版本用软链接把 ~/.omlx、~/.mtplx 的权重挂进模型目录；现在模型必须
        // 真正待在自己的目录里，启动时把链接换成权重本身，并清掉失效链接。
        var adopted = 0
        for engine in EngineID.allCases {
            adopted += EngineModelStore.adoptExistingWeights(engine).adopted.count
        }
        if adopted > 0 {
            toast("已把 \(adopted) 个模型搬进 flashCat 的模型目录，不再依赖外部目录")
        }

        // 授权表是公共目录的真相：启动时按它把各引擎目录里的链接对齐。
        ModelSharing.synchronize()

        catalog = service.load(runtime: splashRuntime)
        if catalog.machine.isEmpty {
            selectedModel = settings.model
        } else if settings.model.isEmpty {
            selectedModel = catalog.machine.first!.id
            settings.setModel(selectedModel)
        } else {
            selectedModel = settings.model
        }
        messages = conversation.load()
        threads = history.load()

        attachEngines()
        // A crashed or force-quit session can leave an engine resident with its
        // weights; clear those before anything of this session starts.
        engines?.sweepOrphanEngines()
        syncController()

        // Work out (or recall) what this Mac should run before the launch page
        // takes over: the first-run page and the launch page both ask "which
        // engine", and the recommendation is what answers it.
        settleRecommendation()

        // Nothing installed yet: the launch page takes over and picks an engine.
        guard !needsEngineSetup else {
            selectedModel = ""
            return
        }

        // Model folders are per engine and filled above; adopt whatever this
        // engine already has so the models page opens on something usable.
        libraryEngine = activeEngine
        // Model ids do not carry across engines: a remembered id is only kept
        // when this engine can actually serve it, otherwise the folder's own
        // models win.
        adoptSavedModel(for: activeEngine)

        applyGatewaySettings()
        // 模型广场的「已下载」要在第一次打开前就有结论：跟着启动算一次。
        refreshLocalRepos()

        if settings.autoStart && !selectedModel.isEmpty {
            startService()
        }
    }

    /// Point the manager at the installed packs. Installation is the only thing
    /// that changes the controller list, so every engine becomes a controller
    /// here — splash included.
    private func attachEngines() {
        let manager = EngineManager(settings: settings, catalog: catalog)
        manager.onChange = { [weak self] in self?.syncController() }
        // Splash launches run through here: a model installed without its
        // DFlash2 draft gets it fetched before the engine starts.
        manager.prepareForStart = { [weak self] model in
            guard let self else { return .ready(model) }
            return await self.ensureSplashDraft(model)
        }
        engines = manager
        // A finished install/uninstall changes which packs exist, so rebuild the
        // controllers and refresh whatever the models page is showing.
        installsObservedEngine = manager.activeID
        installs.configure(onChange: { [weak self] in
            guard let self else { return }
            self.engines?.rebuild()
            // 卸载正在使用的引擎会让 rebuild 悄悄回落到另一个包（或一个不剩）。
            // 活动引擎因此变化时，模型页和选中模型必须跟上，不能指向已删除的包。
            defer { self.installsObservedEngine = self.activeEngine }
            if self.needsEngineSetup {
                self.selectedModel = ""
                self.libraryEngine = .splash
            } else if self.installsObservedEngine != self.activeEngine {
                self.libraryEngine = self.activeEngine
                self.adoptSavedModel(for: self.activeEngine)
            }
            // 有了引擎，首次运行的推荐页就不再成立：它既不能被这张页盖住
            // 一个已经装好的引擎，也不能在没给出答案的情况下一直挂着。
            if !self.needsEngineSetup { self.dismissRecommendationPage() }
            self.reloadModels()
            self.syncController()
            self.objectWillChange.send()
        })
        // 引擎安装/构建的成功与失败通过全局气泡弹出。
        installs.onToast = { [weak self] message in
            self?.toast(message)
        }
    }

    /// Make a freshly installed engine the one this app runs.
    func adoptEngine(_ id: EngineID) {
        EngineStore.shared.update(id) { $0.enabled = true }
        EngineStore.shared.rememberActive(id)
        engines?.rebuild()
        EngineModelStore.adoptExistingWeights(id)
        reloadModels()
        adoptSavedModel(for: id)
        syncController()
        showsLaunchPage = false
        // Adopting means a pack is on disk: the first-run question is answered by
        // the install itself, so the page must not stay up over a working engine
        // (it is a one-time question either way).
        dismissRecommendationPage()
        // The first-run page may have asked for an engine *and* its model. The
        // downloader needs the pack on disk, so the model download waits for
        // this moment instead of failing with "还没有安装…引擎".
        if let pending = pendingRecommendedDownload {
            pendingRecommendedDownload = nil
            if pending.engine == id {
                let model = pending.model
                DispatchQueue.main.async { [weak self] in
                    self?.downloadModel(model, engine: id)
                }
            }
            // Another engine arrived first: `EngineInstallCenter.onInstalled` is
            // a single slot, so the recommended engine's install can no longer
            // report back and the latch can never be honoured. Drop it (a stale
            // latch would fire a multi-GB download on some later install the
            // user never re-confirmed) rather than leave it armed.
        }
        objectWillChange.send()
    }

    /// 本机已经有这些仓库：公共目录里的 + 三个引擎模型目录里的权重。
    /// 模型广场和手填下载都按它判「已下载」，所以启动时（`bootstrap`）也要扫
    /// 一次——只挂在 `reloadModels` 上会等引擎安装/下载/授权变化才第一次算，
    /// 刚开app 时广场会全是「下载」。
    /// 三次目录扫描的 stat 走 `EngineModelStore` 的 meta 缓存，只有新增目录才真读盘。
    func refreshLocalRepos() {
        var local = Set(sharedRepos.map { ModelSharing.canonical($0) })
        for id in EngineID.allCases {
            for model in LocalEngineModels.scan(engine: id,
                                                directory: EnginePaths.modelsDirectory(id)) {
                local.insert(ModelSharing.canonical(model.id))
            }
        }
        localModelRepos = local.sorted()
    }

    func reloadModels() {
        // 授权表是真相，磁盘上的链接跟着它走：启动、下载完成、授权变更都从这里过。
        ModelSharing.synchronize()
        // 公共目录里已经有哪些仓库：模型广场用它标「已在本机」。跟着
        // reloadModels 走（不进每两秒的快照），磁盘不会被反复扫。
        sharedRepos = ModelSharing.scan().map { $0.id }
        refreshLocalRepos()
        catalog = ModelCatalogService().load(runtime: splashRuntime)
        controller?.updateCatalog(catalog)
        if selectedModel.isEmpty, let first = catalog.machine.first {
            selectedModel = first.id
            settings.setModel(first.id)
        }
    }

    // MARK: hardware

    /// Work out (once) what this Mac should run, and open the first-run page
    /// while nothing is installed yet.
    ///
    /// The answer is stored after the first run and only recomputed on request:
    /// a recommendation that moved between launches would drag the model page's
    /// ★ tag off a pack the user already started downloading.
    func settleRecommendation() {
        if let stored = settings.hardwareRecommendation {
            hardwareRecommendation = stored
        } else {
            recomputeRecommendation()
        }
        // Someone who already had engines before this feature existed keeps
        // their models: they get the tags silently, not a page telling them to
        // start over. Writing `seen` here is also what stops an upgraded user
        // whose packs later go missing from landing on a first-run page.
        guard needsEngineSetup else {
            settings.setHardwareRecommendationSeen(true)
            return
        }
        guard !settings.hardwareRecommendationSeen else { return }
        showsRecommendationPage = true
    }

    private func recomputeRecommendation() {
        let recommendation = HardwareAdvisor.recommend(machine: DeviceProfile.current().machine)
        hardwareRecommendation = recommendation
        settings.setHardwareRecommendation(recommendation)
    }

    /// Puts away the first-run page without answering it — used when an engine
    /// arrives by other means (engines page, another install finishing), so the
    /// page can never outlive its precondition and hide the launch page.
    private func dismissRecommendationPage() {
        guard showsRecommendationPage else { return }
        showsRecommendationPage = false
        settings.setHardwareRecommendationSeen(true)
    }

    /// Answer the first-run page. The engine install itself is started by the
    /// shell (it owns `EngineInstallCenter`); this records what the answer was,
    /// so `adoptEngine` can download the recommended model once the pack lands.
    func dismissRecommendation(engine: EngineID?) {
        showsRecommendationPage = false
        settings.setHardwareRecommendationSeen(true)
        guard let engine, let pick = hardwareRecommendation?.pick(for: engine) else { return }
        pendingRecommendedDownload = (engine: engine, model: pick.model)
    }

    /// The recommendation tag the model page puts on a catalog entry, if this
    /// Mac was told to run that entry on that engine.
    ///
    /// Compared through `ModelLibraryEntry.normalized`, not by string equality:
    /// an installed pack's id is the flat folder name (`owner--repo`) and the
    /// `:VARIANT` suffix is dropped on disk, so a raw compare would lose the tag
    /// exactly when the recommended model is the one that is installed.
    func recommendationTag(for id: String, engine: EngineID) -> String? {
        guard let pick = hardwareRecommendation?.pick(for: engine),
              ModelLibraryEntry.normalized(pick.model) == ModelLibraryEntry.normalized(id) else { return nil }
        return "推荐 · " + pick.reason
    }

    /// An install that failed voids whatever the first-run page armed for it:
    /// a later install of the same engine must not silently start a
    /// multi-gigabyte model download the user did not ask for again.
    func engineInstallFailed(_ engine: EngineID) {
        if pendingRecommendedDownload?.engine == engine { pendingRecommendedDownload = nil }
    }

    // MARK: engines

    /// An engine counts as installed only when its pack produced a controller.
    func engineIsInstalled(_ id: EngineID) -> Bool {
        engines?.controller(id) != nil
    }

    /// Ask for the missing engine instead of pretending the switch happened:
    /// `EngineManager.activate` no-ops without a controller, so a plain switch
    /// would leave the old engine running under a success toast.
    func requestEngineInstall(_ id: EngineID) {
        pendingEngineInstall = id
    }

    func confirmEngineInstall() {
        pendingEngineInstall = nil
        section = .settings
    }

    func cancelEngineInstall() {
        pendingEngineInstall = nil
    }

    /// Only one engine runs at a time: two MLX engines would fight for the same
    /// unified memory, so switching stops the old one first.
    @discardableResult
    func switchEngine(_ id: EngineID) -> Bool {
        guard let engines, id != engines.activeID else { return false }
        // 换引擎本身就是重启进程：正在进行的切换（包括跨引擎跳过去的那一半）
        // 已经没有意义，直接作废。以前这里 toast 一句就 return，读者再点最多
        // 的选择都没反应，而那个被跳过的切换还在原地挂着。
        if isSwitchingModel { retireModelSwitch() }
        guard engines.controller(id) != nil else {
            requestEngineInstall(id)
            return false
        }
        let wasRunning = isRunning
        engines.activate(id)
        libraryEngine = id
        reloadModels()
        // Switching to an engine must not keep the previous engine's model id:
        // the remembered one only survives if this engine can serve it.
        adoptSavedModel(for: id)
        syncController()
        if wasRunning { startService() }
        toast("已切换到 \(id.displayName)")
        return true
    }

    /// Change the port an engine listens on. Only the stored preference moves
    /// while it is idle; a running engine keeps its port until restarted.
    func switchEnginePort(_ id: EngineID, port: Int) {
        guard let engines, let controller = engines.controller(id) else { return }
        guard controller.port != port else { return }
        EngineStore.shared.update(id) { $0.port = port }
        if id == activeEngine, !isRunning {
            controller.updatePort(port)
        }
        syncController()
    }

    /// Models the active engine can actually see: splash reads its catalog,
    /// the others read the flashCat folder that holds links to the weights.
    func engineModels() -> [EngineModel] { engineModels(for: activeEngine) }

    /// Same list, for an engine that is not (yet) the active one — switching
    /// engines has to know what the destination can serve before it commits.
    func engineModels(for id: EngineID) -> [EngineModel] {
        // A half-downloaded snapshot already carries config.json and a
        // tokenizer, which is enough for the scan to call it a servable model.
        // Every download-center row means its folder is not finished (success
        // removes the row), so hide those folders from the library until the
        // downloader is done — the card then keeps showing live progress on
        // the suggestion row instead of flipping to a "使用" button.
        let unfinished = Set(downloadTasks.map { ModelSharing.canonical($0.model) })
        let shared = sharedModels(for: id)
            .filter { !unfinished.contains(ModelSharing.canonical($0.id)) }
        if id == .splash {
            // 公共目录里的权重已经在 catalog.local 里（load 会把 ModelSharing.scan()
            // 并进来），这里只过滤没下完的，不再追加一遍。
            return catalog.machine
                .filter { ModelSharing.visible($0.id, engine: .splash) }
                .filter { !unfinished.contains(ModelSharing.canonical($0.id)) }
                .map {
                    EngineModel(id: $0.id, path: $0.path, bytes: $0.bytes,
                                maximumContextTokens: nil, loaded: false, loading: false,
                                kind: nil, hidden: false, helper: false, engine: .splash)
                }
        }
        let scanned = LocalEngineModels.scan(engine: id, directory: EnginePaths.modelsDirectory(id))
        return scanned.filter { !unfinished.contains($0.id) } + shared
    }

    /// 公共目录里授权给这个引擎的权重。oMLX / MTPLX 目录里也有它们，但那是
    /// 软链，`LocalEngineModels.scan` 会跳过——模型页的真相来自这里。
    private func sharedModels(for engine: EngineID) -> [EngineModel] {
        ModelSharing.scan()
            .filter { ModelSharing.engines(for: $0.id).contains(engine) }
            .map { model in
                // Splash 认 `owner/repo`，两个 pack 认扁平目录名——启动时交给引擎
                // 的就是这个 id，不能用另一种写法。
                let id = engine == .splash ? model.id : ModelInstaller.folderName(for: model.id)
                return EngineModel(id: id,
                                   path: model.targetName,
                                   bytes: model.bytes,
                                   maximumContextTokens: nil, loaded: false, loading: false,
                                   kind: nil, hidden: false, helper: false, engine: engine)
            }
    }

    // MARK: model library

    /// The catalog rows tagged for this engine: Splash gets the Flash-Next
    /// GGUF, oMLX the MLX and oQ builds, MTPLX only its own packs.
    func libraryRecommendations(for engine: EngineID) -> [ModelRecommendation] {
        ModelRecommendations.list(for: engine)
    }

    /// Installed weights plus the engine's suggestions as one grid — the same
    /// rows whether or not that engine is installed, running or holding a model.
    func libraryEntries(for engine: EngineID) -> [ModelLibraryEntry] {
        let installed: [ModelInfo]
        if engine == .splash {
            installed = catalog.machine.filter { ModelSharing.visible($0.id, engine: .splash) }
        } else {
            installed = engineModels(for: engine).map {
                ModelInfo(id: $0.id,
                          path: $0.path ?? (EnginePaths.modelsDirectory(engine) + "/" + $0.id),
                          bytes: $0.bytes ?? 0,
                          origin: .local,
                          targetName: "")
            }
        }
        return ModelLibrary.entries(installed: installed,
                                    engine: engine,
                                    recommendations: libraryRecommendations(for: engine)) { id in
            engine == .splash ? self.catalog.draftRepository(id, family: nil) : nil
        }
    }

    func browseEngine(_ id: EngineID) {
        libraryEngine = id
        // 搜索是「这一栏里的这次查询」：换栏就散，否则新栏会顶着一次它从没
        // 被输入过的查询，把别的引擎的命中当成自己的结果。票号一并作废，
        // 免得还在路上的答案落进新栏。
        hubSearchTicket += 1
        hubSearch = HubSearchState()
    }

    // MARK: Hub search

    private static let hubClient = HubSearchClient()
    /// Bumped on every keystroke that starts a search so a slow answer cannot
    /// overwrite a newer one.
    private var hubSearchTicket = 0

    /// Search the Hub for repositories the current column can serve.
    ///
    /// Two requests, not one: the list endpoint's `siblings[].size` is always
    /// null, so sizes only come from the per-repository endpoint, fetched
    /// concurrently for the handful of hits that survive the format filter.
    func searchHub(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        hubSearchTicket += 1
        let ticket = hubSearchTicket
        guard !trimmed.isEmpty else {
            hubSearch = HubSearchState()
            return
        }
        hubSearch = HubSearchState(query: trimmed, phase: .loading)
        Task { [weak self] in
            guard let self else { return }
            do {
                let hits = try await Self.hubClient.search(trimmed)
                let enriched = await Self.hubClient.enrich(hits)
                let results = enriched.compactMap { HubSearchState.result(for: $0) }
                guard ticket == self.hubSearchTicket else { return }
                self.hubSearch = HubSearchState(query: trimmed, phase: .idle, results: results)
            } catch {
                guard ticket == self.hubSearchTicket else { return }
                let message = (error as? HubError)?.errorDescription ?? "\(error)"
                self.hubSearch = HubSearchState(query: trimmed, phase: .failed, error: message)
            }
        }
    }

    /// The search hits the given column may show. Ownership comes from the
    /// repository's own format, so a row never appears in two columns.
    func hubResults(for engine: EngineID) -> [HubSearchResult] {
        hubSearch.results.filter { $0.engine == engine }
    }

    // MARK: draft assignments

    /// The DFlash2 draft assigned to one model, or nil when it follows the
    /// engine-level tuning. Reading `tuningRevision` keeps card views that show
    /// the pairing alive for SwiftUI.
    func draftAssignment(for engine: EngineID, model: String) -> String? {
        _ = tuningRevision
        return EngineStore.shared.draftAssignment(for: engine, model: model)
    }

    /// Every locally installed draft head an engine could pair with a main model.
    func installedDraftIds(for engine: EngineID) -> [String] {
        engineModels(for: engine).map(\.id).filter(ModelLibraryEntry.isDraftModel).sorted()
    }

    /// Bind a draft from a main model's card menu. When this engine is live the
    /// settings are pushed again and the resident model reloads, so the pairing
    /// takes effect without touching the launch page.
    func setDraftAssignment(_ draft: String?, engine: EngineID, model: String) {
        EngineStore.shared.setDraftAssignment(draft, engine: engine, model: model)
        if let draft, !draft.isEmpty {
            toast("已为 \(shortModelName(model)) 指定辅助模型 \(shortModelName(draft))")
        } else {
            toast("已清除 \(shortModelName(model)) 的辅助模型，跟随引擎设置")
        }
        if engine == activeEngine, controller?.isRunning == true {
            Task { [weak self] in
                await self?.controller?.reapplyTuning()
            }
        }
    }

    /// The card's one action. A model is bound to the engine that serves its
    /// format, so using one from another engine is a switch, not a model
    /// change. Weights already on disk hop silently; only a download — a
    /// bigger commitment than a switch — still asks first.
    func useModel(_ id: String, engine: EngineID) {
        // Weights on disk do not imply a runtime: the library is browsable for
        // an engine that is not installed, but using one of its models has to
        // install the engine first or the switch below would be a no-op.
        guard engineIsInstalled(engine) else {
            requestEngineInstall(engine)
            return
        }
        let installed = engineModels(for: engine).contains { $0.id == id }
        if engine != activeEngine {
            if installed {
                applyModelFromAnyEngine(id, engine: engine)
            } else {
                pendingLibraryUse = LibraryUseRequest(engine: engine, model: id, needsDownload: true)
            }
            return
        }
        if installed {
            applyModel(id)
        } else {
            downloadModel(id, engine: engine)
        }
    }

    func confirmLibraryUse() {
        guard let request = pendingLibraryUse else { return }
        pendingLibraryUse = nil
        // A failed switch (engine uninstalled between dialog and confirm, say)
        // must not leave a download pointed at a runtime that is not there.
        guard switchEngine(request.engine) else { return }
        if request.needsDownload {
            downloadModel(request.model, engine: request.engine)
        } else {
            applyModel(request.model)
        }
    }

    func cancelLibraryUse() { pendingLibraryUse = nil }

    // MARK: service

    /// Resolve the model this engine should start on. Model ids are engine
    /// scoped — Splash packages are `owner/repo` (e.g. the `omlx/…-e5133ef4`
    /// staging repo oMLX publishes), while the packs serve the `owner--repo`
    /// link names in their own folder. A remembered id from another engine, or
    /// one whose weights have gone, would 404 on every request, so it is
    /// replaced by a model the engine really has and the store is repaired.
    private func adoptSavedModel(for id: EngineID) {
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
            toast("\(engine.displayName) 没有模型 \(shortModelName(id))")
            return
        }
        guard engine != activeEngine else {
            applyModel(id)
            return
        }
        hopEngine(engine, model: id)
    }

    /// Make `engine` the running one and load `model` on it in one motion.
    /// The sidebar still switches engines explicitly, but the model switcher
    /// hides the hop: from the reader's point of view only the model changed.
    private func hopEngine(_ engine: EngineID, model: String) {
        guard let engines, engines.controller(engine) != nil else { return }
        let wasRunning = isRunning
        // 跨引擎的新选择必须立刻生效：上一次切换（可能是另一台引擎上几分钟的
        // 权重加载）在这里作废，而不是排队等它结束——排队就是「点了新模型，
        // 界面还停在旧的那一次切换里」。
        retireModelSwitch()
        engines.activate(engine)
        libraryEngine = engine
        reloadModels()
        // The picked model wins over the engine's remembered one.
        selectModel(model)
        engines.setModel(model, for: engine)
        syncController()

        guard wasRunning else {
            toast("已切换到 \(engine.displayName) · \(shortModelName(model))")
            return
        }

        // The old engine's weights are already gone (activate stops it), so
        // the hop is purely a load. Keep the switcher's inline progress until
        // the new engine reports ready, the same way a same-engine switch
        // does.
        switchingModel = model
        switchStage = "加载新模型"
        let generation = switchGeneration
        switchTask = Task { [weak self] in
            guard let self, let controller = self.controller else {
                self?.settleModelSwitch(generation: generation,
                                        outcome: .failed("\(engine.displayName) 没有可用的控制器"))
                return
            }
            await controller.start(localModel: self.selectedModelInfo, requestedModel: model)
            // 等「真的加载完」而不是「HTTP 壳子绿了」，否则界面会在权重刚
            // 开始搬的时候就退出「切换中」（见 waitForSwitchReady 里的日志）。
            let ready = await controller.waitForSwitchReady(model, timeout: engine.startupTimeout)
            self.settleModelSwitch(generation: generation, outcome: ready
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
            if isSwitchingModel { queuedSwitchModel = nil }
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
                queuedSwitchModel = target
                toast("正在切换模型，完成后自动切到 \(shortModelName(target))")
            }
            return
        }

        // The menu only offers this engine's models, but a stale list or an id
        // typed into settings must not reach the wire: the engine would answer
        // 404 and keep retrying it.
        let models = engineModels()
        if !EngineModelSelection.isServable(target, available: models.map(\.id)) {
            toast("\(activeEngine.displayName) 没有模型 \(shortModelName(target))")
            return
        }

        // With weights loaded the switch unloads them first, which leaves the
        // engine without a model for a while — ask before doing that. With
        // nothing resident the pick is only a selection, applied on next start.
        guard EngineModelSelection.needsConfirmation(isRunning: isRunning,
                                                     current: selectedModel,
                                                     target: target) else {
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
        beginModelSwitch(to: target)
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
        cancelModelSwitch()
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

    // MARK: model switch progress

    /// One task drives the whole swap — stop/unload, confirm the old weights are
    /// gone, then load — and reports back when it is really done. The previous
    /// design fired a process restart from the view model and a hot load from
    /// here at the same time, which is what wedged the engine mid-switch.
    private func beginModelSwitch(to id: String) {
        guard isRunning, let controller else {
            // Nothing is resident, so there is nothing to unload: the choice only
            // takes effect on the next start.
            retireModelSwitch()
            toast("已切换到 \(shortModelName(id))")
            return
        }

        // 上一次切换（比如跨引擎跳过来的那一次加载）先作废，这一次从头开始。
        retireModelSwitch()
        let generation = switchGeneration
        switchingModel = id
        switchStage = "准备切换"
        switchTask = Task { [weak self] in
            let outcome = await controller.switchModel(id) { stage in
                // 被接管之后就不要再往新切换的阶段行里写了。
                guard let self, generation == self.switchGeneration else { return }
                self.switchStage = stage
            }
            self?.settleModelSwitch(generation: generation, outcome: outcome)
        }
    }

    /// 上一次切换作废：取消任务、推进代数、清掉「切换中」。跨引擎再选、换引擎、
    /// 用户主动放弃都走这里。以前这些入口要么静默 return，要么只 cancel 任务而
    /// 把状态交给一个再也不会回来的结尾去清——界面就永久停在「切换中」，只能
    /// 重启应用。
    private func retireModelSwitch() {
        switchTask?.cancel()
        switchTask = nil
        switchGeneration &+= 1
        switchingModel = nil
        switchStage = ""
    }

    /// 切换的唯一出口。先核对代数：被接管/被取消的旧任务到这里就静默退出，
    /// 既不会抹掉新切换的状态，也不会把自己忘在「切换中」。当代的结尾负责清
    /// 状态，并把排队的那次选择接着做掉。
    private func settleModelSwitch(generation: Int, outcome: EngineController.ModelSwitchOutcome) {
        guard generation == switchGeneration else { return }
        switchTask = nil
        finishModelSwitch(outcome: outcome)
        guard let next = queuedSwitchModel else { return }
        queuedSwitchModel = nil
        beginModelSwitch(to: next)
    }

    /// 切换中读者的退路：放弃这次等待，状态交回引擎自己的启动阶段（进度、
    /// 已等待秒数、日志都还在推进）。引擎继续在后台加载，不打断已经搬了
    /// 一半的权重。
    func abortModelSwitch() {
        guard switchingModel != nil else { return }
        let engine = activeEngine
        queuedSwitchModel = nil
        retireModelSwitch()
        toast("已取消等待 · \(engine.displayName) 仍在后台加载")
    }

    /// Keep the stage line honest if the engine moves on its own between stages.
    private func syncSwitchStage() {
        guard switchingModel != nil, switchStage.isEmpty else { return }
        switchStage = serverState == .ready ? "加载新模型" : "停止旧模型"
    }

    private func finishModelSwitch(outcome: EngineController.ModelSwitchOutcome) {
        guard switchingModel != nil else { return }
        switchingModel = nil
        switchStage = ""
        switch outcome {
        case .ready:
            toast("模型已就绪 · \(shortModelName(selectedModel))")
        case .failed(let reason):
            notice = reason
            toast("模型切换失败，请查看日志")
        }
    }

    private func cancelModelSwitch() {
        queuedSwitchModel = nil
        retireModelSwitch()
    }

    func shortModelName(_ id: String) -> String {
        let value = id.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return "—" }
        return value.split(separator: "/").last.map(String.init) ?? value
    }

    // MARK: logs

    func refreshLogs() { logs = controller?.logs.snapshot() ?? [] }

    func clearLogs() {
        controller?.logs.clear()
        refreshLogs()
    }

    // MARK: chat

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || generating { return }
        if !isRunning {
            notice = "推理服务未运行，请先启动服务"
            return
        }

        var turns: [ChatTurn] = messages.filter { !$0.streaming }.map { ChatTurn(role: $0.role, content: $0.content) }
        turns.append(ChatTurn(role: "user", content: trimmed))

        messages.append(ChatMessage(role: "user", content: trimmed, model: selectedModel, createdAt: Date()))
        let assistantIndex = messages.count
        messages.append(ChatMessage(role: "assistant", content: "", model: selectedModel, createdAt: Date(), streaming: true))
        generating = true
        generationStatus = "生成中"
        liveDecodeRate = nil
        streamWindowTokens = 0
        streamWindowStart = nil

        // 最大生成 tokens：思考与正文共享的总输出上限。留空时取模型自身上限
        // 并按引擎生效窗口封顶（见 effectiveMaxTokens），4096 那种小默认会让
        // 思考模型一开思考就被 finish_reason=length 硬截断。
        let maxTokensLimit = effectiveMaxTokens
        let options = ChatOptions(temperature: settings.temperature,
                                  topP: settings.topP,
                                  maxTokens: maxTokensLimit,
                                  reasoningEffort: settings.effectiveReasoningEffort,
                                  systemPrompt: settings.systemPrompt,
                                  thinkingBudget: EngineStore.shared
                                      .tuning(for: activeEngine)
                                      .effectiveThinkingBudget(for: activeEngine))
        let model = selectedModel
        let endpointPort = port
        let started = Date()

        Task {
            let result = await chatClient.send(port: endpointPort, model: model, turns: turns, options: options,
                onDelta: { piece in
                    Task { @MainActor in
                        guard assistantIndex < self.messages.count else { return }
                        if self.messages[assistantIndex].firstTokenSeconds == nil {
                            self.messages[assistantIndex].firstTokenSeconds = Date().timeIntervalSince(started)
                        }
                        self.messages[assistantIndex].content += piece
                        self.recordStreamDelta(piece)
                    }
                },
                onReasoning: { piece in
                    Task { @MainActor in
                        guard assistantIndex < self.messages.count else { return }
                        self.messages[assistantIndex].reasoning = (self.messages[assistantIndex].reasoning ?? "") + piece
                        if self.messages[assistantIndex].content.isEmpty {
                            self.generationStatus = "思考中"
                        }
                        // 思考流同样计入本地测速：思考模型的输出大头在 reasoning，
                        // 不计的话思考阶段 liveDecodeRate 一直是 nil，对话页直播条
                        // 只能显示「— tok/s」。
                        self.recordStreamDelta(piece)
                    }
                },
                onUsage: { usage in
                    Task { @MainActor in
                        guard assistantIndex < self.messages.count else { return }
                        self.messages[assistantIndex].usage = usage
                        // 思考截断可见性：引擎按预算收束思考时，reasoning_tokens
                        // 正好落在预算上，用「≥ 预算」判定这次思考被截断。
                        if let budget = options.thinkingBudget,
                           let reasoning = usage.reasoningTokens,
                           reasoning >= budget {
                            self.controller?.logs.append(
                                "==> 思考截断：本次思考 \(reasoning) tokens 触及预算 \(budget)，已被强制收束；如需更长思考请在引擎配置调大「思考截断」",
                                level: .warning)
                            self.refreshLogs()
                        }
                        // max_tokens 是思考与正文共享的总输出上限，打满即硬截断
                        //（finish_reason=length），思考模型默认值下最容易撞上。
                        if usage.finishReason == "length" {
                            let reasoning = usage.reasoningTokens.map { "，其中思考 \($0) tokens" } ?? ""
                            self.controller?.logs.append(
                                "==> 输出截断：本次生成触及最大生成长度 \(options.maxTokens) tokens 的上限\(reasoning)，思考与正文共享该上限；如需更长思考/回答请在聊天参数调大「最大生成 tokens」",
                                level: .warning)
                            self.refreshLogs()
                        }
                    }
                },
                onStatus: { status in
                    Task { @MainActor in self.generationStatus = status }
                })

            let elapsed = Date().timeIntervalSince(started)
            switch result {
            case .success(let text):
                if assistantIndex < messages.count {
                    messages[assistantIndex].content = text
                    messages[assistantIndex].seconds = elapsed
                    var tokens = messages[assistantIndex].usage?.completionTokens ?? 0
                    if tokens == 0 {
                        // Streaming responses often omit usage; estimate so the
                        // message still shows a token count and rate.
                        tokens = Self.estimateTokens(text)
                        if tokens > 0 {
                            messages[assistantIndex].usage = ChatUsage(promptTokens: 0, completionTokens: tokens)
                        }
                    }
                    if tokens > 0, elapsed > 0 {
                        messages[assistantIndex].tokensPerSecond = Double(tokens) / elapsed
                    }
                }
            case .failure(let error):
                if assistantIndex < messages.count, messages[assistantIndex].content.isEmpty {
                    messages[assistantIndex].content = "出错：\(error.message)"
                }
                if !isCancellation(error) { notice = error.message }
            }
            if assistantIndex < messages.count {
                messages[assistantIndex].streaming = false
            }
            generating = false
            conversation.save(messages)
            history.save(messages: messages, threadID: threadID)
            threads = history.load()
        }
    }

    static func estimateTokens(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3000...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
                cjk += 1
            default:
                other += 1
            }
        }
        return cjk + other / 4
    }

    private func isCancellation(_ error: ChatError) -> Bool {
        error.message.localizedCaseInsensitiveContains("cancel")
            || error.message.localizedCaseInsensitiveContains("取消")
    }

    func cancelGeneration() {
        chatClient.cancel()
        generating = false
        generationStatus = "已取消"
        if let index = messages.lastIndex(where: { $0.streaming }) {
            messages[index].streaming = false
            if messages[index].content.isEmpty { messages.remove(at: index) }
        }
        conversation.save(messages)
    }

    /// Drop the trailing answer and ask again with the same prompt.
    func regenerate() {
        guard !generating else { return }
        guard let lastUser = messages.last(where: { $0.role == "user" }) else { return }
        while let last = messages.last, last.role == "assistant" { messages.removeLast() }
        if messages.last?.role == "user" { messages.removeLast() }
        send(lastUser.content)
    }

    func newConversation() {
        cancelGeneration()
        messages.removeAll()
        conversation.clear()
        threadID = Self.newThreadID()
    }

    func openThread(_ thread: ChatThread) {
        cancelGeneration()
        messages = thread.messages.map {
            ChatMessage(role: $0.role, content: $0.content, model: $0.model,
                        createdAt: $0.createdAt, usage: $0.usage,
                        seconds: $0.seconds, tokensPerSecond: $0.tokensPerSecond,
                        firstTokenSeconds: $0.firstTokenSeconds)
        }
        threadID = thread.id
        section = .chat
    }

    func deleteThread(_ thread: ChatThread) {
        history.delete(id: thread.id)
        threads = history.load()
        // 删掉的是当前这段对话：下一轮算新会话，别写回刚删掉的 id。
        if thread.id == threadID { threadID = Self.newThreadID() }
        toast("已删除对话「\(thread.title)」")
    }

    func clearThreads() {
        for thread in threads { history.delete(id: thread.id) }
        threads = history.load()
        threadID = Self.newThreadID()
    }

    func resetChatParameters() {
        settings.setTemperature(0.7)
        settings.setTopP(0.95)
        // 0 = 留空，交回「模型自身上限」；写死 4096 会让思考模型连正文都发不出来。
        settings.setMaxTokens(0)
        settings.setSystemPrompt("")
        settings.setThinkingMode(.automatic)
        toast("已恢复默认对话参数")
    }

    // MARK: models

    func deleteModel(_ model: ModelInfo) {
        do {
            try ModelCatalogService().deleteLocal(model)
            reloadModels()
            if selectedModel == model.id {
                selectedModel = catalog.machine.first?.id ?? ""
                settings.setModel(selectedModel)
            }
            toast("已删除 \(model.id)")
        } catch {
            notice = "删除失败：\((error as? ModelCatalogService.CatalogError)?.message ?? error.localizedDescription)"
        }
    }

    /// Remove a model from one engine's folder. The weights live in flashCat's
    /// own directory now, so this deletes them — the caller asks first.
    func removeModel(_ id: String, engine: EngineID) {
        // 公共目录里的权重只有一份：删它要连带收回授权、拆掉各引擎的链接。
        if ModelSharing.isShared(id) {
            removeShared(id)
            return
        }
        guard engine != .splash else {
            if let model = catalog.machine.first(where: { $0.id == id }) {
                // 正在服务的那份权重删掉后不能留着旧选择：先停引擎，再删，
                // 让下一次启动重新解析模型。
                if engine == activeEngine, selectedModel == id { stopService() }
                deleteModel(model)
            }
            return
        }
        // 正在服务的那份权重删掉后不能只换个选择：进程里还驻留着它，
        // 界面和引擎会各说各话，直到有人手动重启。先停引擎再动手。
        let serving = engine == activeEngine && selectedModel == id
        if serving { stopService() }
        let path = EnginePaths.modelsDirectory(engine) + "/" + id
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            notice = "删除失败：\(error.localizedDescription)"
            return
        }
        if serving {
            selectedModel = ""
            adoptSavedModel(for: engine)
        }
        EngineModelStore.invalidateMetaCache()
        reloadModels()
        toast("已删除 \(id) 及其权重文件")
    }

    /// Fetch weights for the engine the model page is showing.
    func downloadModel(_ id: String) { downloadModel(id, engine: libraryEngine) }

    /// Fetch weights for one engine. Both paths download through the
    /// huggingface_hub that ships inside the engine packs: Splash's installer
    /// picks the single GGUF quant out of a repository that carries a dozen and
    /// prepares its assembly, while oMLX and MTPLX run flashCat's snapshot
    /// downloader straight into their own model folder.
    ///
    /// Pause and cancel terminate the child process; the Hub keeps partial
    /// files in the destination's `.cache`, so resuming later — even after a
    /// relaunch — continues from the bytes already on disk.
    ///
    /// - Parameter family: the model's Splash family when the caller knows it,
    ///   which picks the released DFlash2 draft more surely than the id does.
    /// - Returns: whether the download started. A `false` comes with a `notice`.
    @discardableResult
    func downloadModel(_ id: String, engine: EngineID, family: String? = nil) -> Bool {
        guard downloadingModel == nil else {
            toast("正在下载另一个模型，先等它结束")
            return false
        }
        let recommendation = ModelRecommendations.recommendation(for: id)
        let draft = engine == .splash
            ? (catalog.draftRepository(id, family: family) ?? recommendation?.draftRepository)
            : nil

        let plan: ModelInstaller.Plan
        do {
            plan = try ModelInstaller.plan(engine: engine,
                                           model: id,
                                           draftRepository: draft,
                                           runtime: splashRuntime,
                                           cache: settings.hfCache)
        } catch {
            notice = (error as? ModelInstaller.Failure)?.message ?? "\(error)"
            return false
        }
        return startDownload(plan, engine: engine, id: id, shared: nil)
    }

    /// 从 Hub 下任意仓库到公共目录，并记下它给哪些引擎用。
    ///
    /// 这是「开放下载」的入口：不设格式/家族门槛，支持与否交给用户自己
    /// 判断。卡片只负责标明来源（引擎推荐 / 个人下载），不再把人挡在门外。
    func downloadShared(_ repo: String, engines: [EngineID]) {
        guard downloadingModel == nil else {
            toast("正在下载另一个模型，先等它结束")
            return
        }
        let target = ModelSharing.canonical(repo.trimmingCharacters(in: .whitespaces))
        guard target.contains("/") else {
            notice = "仓库 id 要写成 owner/repo"
            return
        }
        guard !engines.isEmpty else {
            notice = "至少选一个引擎，否则下完就没人能用它"
            return
        }
        // 已经在本机的仓库不再下一遍：先 reload 一次，免得上一次下载刚落地、
        // 清单还是旧的。
        reloadModels()
        guard !repoIsLocal(target) else {
            notice = "「\(target)」已经在本机了，不用重复下载"
            return
        }
        let plan: ModelInstaller.Plan
        do {
            plan = try ModelInstaller.sharedPlan(repo: target,
                                                 engines: engines,
                                                 runtime: splashRuntime,
                                                 cache: settings.hfCache)
        } catch {
            notice = (error as? ModelInstaller.Failure)?.message ?? "\(error)"
            return
        }
        startDownload(plan, engine: engines.first ?? libraryEngine, id: target, shared: engines)
    }

    /// 改一个共享模型能被哪些引擎看见：写授权表并同步链接，模型页随即重算。
    /// 搜索/推荐列表。请求会被下一次调用取消，所以连点排序按钮不会乱序上屏。
    /// 翻页/换筛选走同一个入口，只是把 page 与 filter 一起带下去。
    func searchHub(_ query: String, sort: String, filter: String? = nil, page: Int = 0) {
        let value = HubSort(rawValue: sort) ?? .trending
        let bucket = filter.flatMap(HubFilter.init(rawValue:)) ?? hubFilter
        hubQuery = query
        hubSort = value
        hubFilter = bucket
        hubPage = max(0, page)
        hubSearchTask?.cancel()
        hubError = nil
        hubLoading = true
        let current = hubPage
        hubSearchTask = Task { [weak self] in
            do {
                let models = try await HubClient.search(
                    query: query,
                    sort: value,
                    filter: bucket,
                    page: current
                )
                guard !Task.isCancelled else { return }
                self?.hubResults = models
                self?.hubHasMore = models.count >= HubClient.pageSize
                self?.hubLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.hubResults = []
                self?.hubHasMore = false
                self?.hubLoading = false
                self?.hubError = error.localizedDescription
            }
        }
    }

    /// 打开某个仓库的模型卡：文件清单和 README 都在这一个请求里补齐。
    func loadHubDetail(_ repo: String) {
        hubDetailTask?.cancel()
        hubDetail = nil
        hubError = nil
        hubDetailLoading = true
        hubDetailTask = Task { [weak self] in
            do {
                let detail = try await HubClient.detail(repo)
                guard !Task.isCancelled else { return }
                self?.hubDetail = detail
                self?.hubDetailLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.hubDetailLoading = false
                self?.hubError = error.localizedDescription
            }
        }
    }

    func closeHubDetail() {
        hubDetailTask?.cancel()
        hubDetail = nil
        hubDetailLoading = false
    }

    /// 手填仓库 id 的预检。输入每停一次就调一次，上一次的请求直接取消——
    /// 中间态的仓库 id（`Youssof`、`Youssofal/`）不查，省掉一堆必然 404 的请求。
    func probeRepo(_ repo: String) {
        let key = ModelSharing.canonical(repo.trimmingCharacters(in: .whitespacesAndNewlines))
        guard key != repoProbeKey else { return }
        repoProbeKey = key
        repoProbeRepo = key
        repoProbeTask?.cancel()
        repoProbeError = nil
        guard key.split(separator: "/").count == 2 else {
            repoProbe = nil
            repoProbeLoading = false
            return
        }
        repoProbe = nil
        repoProbeLoading = true
        repoProbeTask = Task { [weak self] in
            do {
                let detail = try await HubClient.detail(key)
                guard !Task.isCancelled else { return }
                self?.repoProbe = detail
                self?.repoProbeLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.repoProbe = nil
                self?.repoProbeLoading = false
                self?.repoProbeError = error.localizedDescription
            }
        }
    }

    /// 弹窗关掉就丢掉预检结果：下次打开是另一个仓库，留着旧卡会先闪一下。
    func clearRepoProbe() {
        repoProbeTask?.cancel()
        repoProbe = nil
        repoProbeLoading = false
        repoProbeError = nil
        repoProbeKey = ""
        repoProbeRepo = ""
    }

    /// 这个仓库是不是已经在本机了（公共目录或任一引擎的模型目录）。
    /// 判定放在这里而不是网页：置灰只是表现，真正的门在这儿。
    func repoIsLocal(_ repo: String) -> Bool {
        localModelRepos.contains(ModelSharing.canonical(repo))
    }

    func setSharedEngines(_ engines: [EngineID], repo: String) {
        let repo = ModelSharing.canonical(repo)
        ModelSharing.setEngines(Set(engines), for: repo)
        EngineModelStore.invalidateMetaCache()
        reloadModels()
        toast(engines.isEmpty
            ? "已收回 \(repo) 的引擎授权"
            : "\(repo) 现在可用于 \(engines.map(\.displayName).joined(separator: "、"))")
    }

    /// 删除公共目录里的权重：先收回授权（各引擎的链接随之删掉），再删文件。
    func removeShared(_ id: String) {
        let repo = ModelSharing.canonical(id)
        ModelSharing.forget(repo)
        try? FileManager.default.removeItem(atPath: ModelSharing.path(for: repo))
        if selectedModel == repo || selectedModel == ModelInstaller.folderName(for: repo) {
            selectedModel = ""
            adoptSavedModel(for: activeEngine)
        }
        EngineModelStore.invalidateMetaCache()
        reloadModels()
        toast("已删除 \(repo) 及其权重文件")
    }

    /// 真正拉起下载器的那一步：两条入口（引擎自己的目录 / 公共目录）只有落地
    /// 位置不同，进度、暂停、取消、续传全部共用这一段。
    /// 共享下载收尾：写授权表，让各引擎目录里的链接跟上，再刷新模型页。
    private func publishShared(repo: String, engines: [EngineID]) {
        ModelSharing.setEngines(Set(engines), for: repo)
        EngineModelStore.invalidateMetaCache()
        reloadModels()
        guard !engines.isEmpty else { return }
        toast("已下载 " + repo + "，可用于 " + engines.map(\.displayName).joined(separator: "、"))
    }

    /// - Returns: whether the process started; `false` comes with a `notice`.
    @discardableResult
    private func startDownload(_ plan: ModelInstaller.Plan,
                               engine: EngineID,
                               id: String,
                               shared: [EngineID]?) -> Bool {
        pendingSharedRepo = shared == nil ? nil : id
        pendingSharedEngines = shared ?? []
        pauseRequested = false
        cancelRequested = false
        downloadSpeed = 0
        lastWatchBytes = 0
        lastWatchDate = nil
        downloadWatchDirectories = []
        downloadWatchBaselines = [:]
        upsertTask(engine: engine, model: id) { task in
            task.status = .downloading
            task.shared = shared
            if task.addedAt.timeIntervalSinceNow < -60 * 60 * 24 * 30 { task.addedAt = Date() }
        }
        downloadingModel = id
        downloadingEngine = engine
        downloadFraction = 0
        downloadTotalBytes = 0
        append(log: shared == nil
            ? "==> \(engine.displayName) 下载模型：\(id)"
            : "==> 下载模型到公共目录：\(id)", engine: engine)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: plan.workingDirectory)
        process.environment = plan.environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        // Where this child's Hub cache lives: splash downloads land there
        // before the finished assembly is installed into the models folder.
        let hubCacheRoot = plan.environment["HF_HUB_CACHE"]
            ?? (plan.environment["HF_HOME"].map { $0 + "/hub" }
                ?? (Paths.home + "/.cache/huggingface/hub"))

        TailReader.read(pipe) { line in
            DispatchQueue.main.async {
                self.append(log: line, engine: engine)
                if let total = Self.totalBytes(in: line) {
                    self.downloadTotalBytes = total
                    self.upsertTask(engine: engine, model: id) { $0.totalBytes = max($0.totalBytes, total) }
                    if let directory = plan.watchDirectory {
                        if !self.downloadWatchDirectories.contains(directory) {
                            self.downloadWatchDirectories.append(directory)
                        }
                        self.startDownloadWatch(engine: engine, model: id)
                    }
                } else if let fetch = Self.fetchPlan(in: line) {
                    // Splash's installer announces every repository it is
                    // about to fetch with its exact byte size. Those sums are
                    // the total, and the repos' Hub cache folders are what
                    // fills up — watching them gives byte progress, which
                    // tqdm alone never provides (its bar only counts finished
                    // files, so it sits at 0% while a shard streams).
                    self.downloadTotalBytes += fetch.bytes
                    self.upsertTask(engine: engine, model: id) {
                        $0.totalBytes = max($0.totalBytes, self.downloadTotalBytes)
                    }
                    let directory = hubCacheRoot + "/models--"
                        + fetch.repo.replacingOccurrences(of: "/", with: "--")
                    if !self.downloadWatchDirectories.contains(directory) {
                        self.downloadWatchDirectories.append(directory)
                    }
                    self.startDownloadWatch(engine: engine, model: id)
                } else if self.downloadTotalBytes == 0,
                          let match = TextPattern.firstMatch("(\\d{1,3})%", line),
                          let value = Double(match[1]) {
                    // Fallback when no total is known: the downloader's own
                    // percentage. Snapshot engines and splash both report
                    // byte totals now, so this only covers unusual output.
                    let fraction = min(max(value / 100, 0), 1)
                    self.downloadFraction = fraction
                    if self.downloadTotalBytes > 0 {
                        self.upsertTask(engine: engine, model: id) {
                            $0.downloadedBytes = Int(fraction * Double(self.downloadTotalBytes))
                        }
                    }
                }
            }
        }

        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                self?.finishDownload(engine: engine,
                                     model: id,
                                     status: finished.terminationStatus)
            }
        }

        do {
            try process.run()
            downloadProcess = process
            return true
        } catch {
            downloadingModel = nil
            downloadingEngine = nil
            downloadFraction = nil
            removeTask(engine: engine, model: id)
            notice = "无法启动下载：\(error.localizedDescription)"
            return false
        }
    }

    /// Run a download and wait for it to end.
    ///
    /// Only the launch path uses this: a start that has to fetch the model's
    /// DFlash2 draft hands the engine a model that is complete, so the engine
    /// never has to download inside its own startup (its launcher refuses to
    /// touch the network).
    private func downloadAndWait(_ id: String, engine: EngineID, family: String?) async -> DownloadOutcome {
        guard downloadingModel == nil else {
            let other = downloadingModel.map(shortModelName) ?? "另一个模型"
            return .failed("正在下载 \(other)，等它结束后再启动")
        }
        return await withCheckedContinuation { continuation in
            downloadCompletion = { continuation.resume(returning: $0) }
            if !downloadModel(id, engine: engine, family: family) {
                // Nothing started, so nothing will call back: release the
                // caller with the notice downloadModel already wrote.
                downloadCompletion = nil
                continuation.resume(returning: .failed(notice ?? "无法启动下载"))
            }
        }
    }

    /// Splash runs every model with its DFlash2 draft, and every family it
    /// recommends is released with one. A model installed by a build that did
    /// not fetch the draft would keep starting without acceleration, so a start
    /// fetches it first: the click waits, the model does not.
    ///
    /// Returns the model to launch — the rescanned one once the draft is on
    /// disk, since only a rescan knows its `draftPath`.
    func ensureSplashDraft(_ model: ModelInfo?) async -> StartPreparation {
        guard let model, model.origin == .splash, model.draftPath == nil else {
            return .ready(model)
        }
        guard let draft = catalog.draftRepository(model.id, family: model.family) else {
            append(log: "==> \(model.id) 没有对应的 DFlash2，按无加速启动", engine: .splash)
            return .ready(model)
        }
        append(log: "==> \(model.id) 缺少 DFlash2，先补齐 \(draft)", engine: .splash)
        toast("\(shortModelName(model.id)) 缺少 DFlash2 加速模型，先下载好再启动")
        supplementInFlight = true
        let outcome = await downloadAndWait(model.id, engine: .splash, family: model.family)
        supplementInFlight = false
        switch outcome {
        case .finished:
            // The download rescanned the catalog on its way out.
            if let refreshed = catalog.machineModel(model.id), refreshed.draftPath != nil {
                append(log: "==> DFlash2 已就绪：\(draft)", engine: .splash)
                return .ready(refreshed)
            }
            append(log: "==> DFlash2 未能装进装配，按无加速启动", engine: .splash)
            return .ready(model)
        case .cancelled:
            // Cancelling the fetch is a decision, not a failure: start anyway.
            append(log: "==> DFlash2 下载已取消，按无加速启动", engine: .splash)
            return .ready(model)
        case .failed(let message):
            return .failed(message)
        }
    }

    // MARK: Download center

    /// Stop the running transfer. Partial files stay in the destination's
    /// `.cache`, so 继续 picks up exactly where this left off.
    func pauseDownload() {
        guard let process = downloadProcess, let model = downloadingModel else { return }
        pauseRequested = true
        downloadSpeed = 0
        append(log: "==> 暂停下载：\(model)，进度已保留", engine: downloadingEngine ?? .splash)
        process.terminate()
    }

    /// Continue a paused transfer: the same snapshot downloader runs again and
    /// the Hub resumes its partial files.
    func resumeDownload(_ task: ModelDownloadTask) {
        // 下进公共目录的任务要回到公共目录，否则续传会另起一份到引擎目录里。
        if let engines = task.shared, !engines.isEmpty {
            downloadShared(task.model, engines: engines)
            return
        }
        downloadModel(task.model, engine: task.engine)
    }

    /// Drop a task from the center. For a running transfer that means
    /// terminating the child; partial files stay on disk so nothing else is
    /// destroyed — a later download simply resumes them.
    func cancelDownload(_ task: ModelDownloadTask) {
        if let process = downloadProcess,
           downloadingModel == task.model, downloadingEngine == task.engine {
            cancelRequested = true
            downloadSpeed = 0
            append(log: "==> 取消下载：\(task.model)", engine: task.engine)
            process.terminate()
        } else {
            removeTask(engine: task.engine, model: task.model)
            toast("已从下载中心移除")
        }
    }

    /// Remove a finished/failed/stale row from the center.
    func removeTask(_ task: ModelDownloadTask) {
        removeTask(engine: task.engine, model: task.model)
    }

    private func upsertTask(engine: EngineID, model: String, _ mutate: (inout ModelDownloadTask) -> Void) {
        if let index = downloadTasks.firstIndex(where: { $0.engine == engine && $0.model == model }) {
            mutate(&downloadTasks[index])
        } else {
            var task = ModelDownloadTask(engine: engine, model: model, status: .downloading)
            mutate(&task)
            downloadTasks.append(task)
        }
        ModelDownloadStore.save(downloadTasks)
    }

    private func removeTask(engine: EngineID, model: String) {
        downloadTasks.removeAll { $0.engine == engine && $0.model == model }
        ModelDownloadStore.save(downloadTasks)
        // 下载行消失 = 这份权重在磁盘上定形了，下次扫描重新读字节数。
        EngineModelStore.invalidateMetaCache()
    }

    private static func totalBytes(in line: String) -> Int? {
        guard line.hasPrefix("TOTAL ") else { return nil }
        return Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces))
    }

    /// `Fetching 8 file(s), 20.43 GB, from owner/repo@38740b847e4c; cached
    /// files are reused.` — how the Splash installer announces each repository
    /// it is about to fetch, with its exact size (hub.py prints GB as 1e9
    /// bytes). The repo's Hub cache folder is where those bytes land.
    private static func fetchPlan(in line: String) -> (bytes: Int, repo: String)? {
        guard let match = TextPattern.firstMatch(
            "Fetching \\d+ file\\(s\\), ([\\d.]+) (GB|MB|KB), from ([^@\\s]+)@", line),
              let value = Double(match[1]) else { return nil }
        let multiplier: Double
        switch match[2] {
        case "GB": multiplier = 1e9
        case "MB": multiplier = 1e6
        default: multiplier = 1e3
        }
        return (Int((value * multiplier).rounded()), match[3])
    }

    /// Watch the folders the running download fills and turn bytes on disk
    /// into a percentage, plus a smoothed transfer speed for the download
    /// center. The walk happens off the main actor: a model folder holds
    /// thousands of shards and the UI thread has a card to animate.
    private func startDownloadWatch(engine: EngineID, model: String) {
        downloadWatchTask?.cancel()
        downloadWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let directories = self.downloadWatchDirectories
                let sizes = await Task.detached(priority: .utility) {
                    directories.map { ModelInstaller.size(of: $0) }
                }.value
                guard !Task.isCancelled else { return }
                // A folder's first sighting sets its baseline, so weights that
                // were already in the cache before this download don't count.
                var downloaded = 0
                for (index, directory) in directories.enumerated() {
                    if let baseline = self.downloadWatchBaselines[directory] {
                        downloaded += max(sizes[index] - baseline, 0)
                    } else {
                        self.downloadWatchBaselines[directory] = sizes[index]
                    }
                }
                let now = Date()
                if let last = self.lastWatchDate,
                   now.timeIntervalSince(last) > 0, downloaded > self.lastWatchBytes {
                    let instant = Double(downloaded - self.lastWatchBytes) / now.timeIntervalSince(last)
                    self.downloadSpeed = self.lastWatchBytes == 0
                        ? instant
                        : self.downloadSpeed * 0.65 + instant * 0.35
                }
                self.lastWatchBytes = downloaded
                self.lastWatchDate = now
                let total = self.downloadTotalBytes
                if total > 0 {
                    self.downloadFraction = min(max(Double(downloaded) / Double(total), 0), 1)
                }
                self.upsertTask(engine: engine, model: model) { task in
                    task.downloadedBytes = downloaded
                    task.totalBytes = max(task.totalBytes, total)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func finishDownload(engine: EngineID, model: String, status: Int32) {
        let sharedRepo = pendingSharedRepo
        let sharedEngines = pendingSharedEngines
        pendingSharedRepo = nil
        pendingSharedEngines = []
        downloadWatchTask?.cancel()
        downloadWatchTask = nil
        downloadProcess = nil
        downloadingModel = nil
        downloadingEngine = nil
        downloadFraction = nil
        downloadTotalBytes = 0
        downloadSpeed = 0
        lastWatchBytes = 0
        lastWatchDate = nil
        downloadWatchDirectories = []
        downloadWatchBaselines = [:]
        reloadModels()

        // A launch may be waiting on this download; it resumes exactly once,
        // whichever branch below ends up running.
        var outcome = DownloadOutcome.failed("下载失败，退出码 \(status)")
        defer {
            let completion = downloadCompletion
            downloadCompletion = nil
            completion?(outcome)
        }

        if pauseRequested {
            pauseRequested = false
            upsertTask(engine: engine, model: model) { $0.status = .paused }
            append(log: "==> 已暂停 \(model)，可从下载中心继续", engine: engine)
            toast("已暂停下载，进度已保留")
            outcome = .cancelled
            return
        }
        if cancelRequested {
            cancelRequested = false
            removeTask(engine: engine, model: model)
            append(log: "==> 已取消下载 \(model)", engine: engine)
            toast("已取消下载")
            outcome = .cancelled
            return
        }

        guard status == 0 else {
            upsertTask(engine: engine, model: model) { $0.status = .failed }
            append(log: "==> 下载失败，退出码 \(status)", engine: engine)
            let message = "模型下载失败，退出码 \(status)（下载中心里可重试）"
            notice = message
            outcome = .failed(message)
            return
        }

        removeTask(engine: engine, model: model)

        if let sharedRepo {
            publishShared(repo: sharedRepo, engines: sharedEngines)
            append(log: "==> 已下载 \(sharedRepo) 到公共目录", engine: engine)
            return
        }

        // Splash addresses a model by its repository id, the packs by the
        // folder name flashCat gave it.
        let repo = model.split(separator: ":", maxSplits: 1).first.map(String.init) ?? model
        let installed = engine == .splash ? model : ModelInstaller.folderName(for: repo)
        append(log: "==> 已下载 \(model)", engine: engine)
        outcome = .finished
        // A launch-triggered fetch is followed by the launch itself: no toast
        // to answer, and the selection must not move under the start.
        guard !supplementInFlight else { return }
        guard engine == activeEngine else {
            toast("已下载 \(model)，切到 \(engine.displayName) 就能用")
            return
        }
        applyModel(installed)
        toast("已下载 \(model)")
    }

    /// Engine logs are per engine; only the running engine's copy is on screen.
    private func append(log line: String, engine: EngineID) {
        engines?.controller(engine)?.logs.append(line, level: .system)
        if engine == activeEngine { logs = controller?.logs.snapshot() ?? [] }
    }

    func copy(_ text: String, label: String = "已复制") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast(label)
    }

    // MARK: toasts

    func toast(_ message: String) {
        toastMessage = message
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.toastMessage = nil
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    func dismissToast() {
        toastWork?.cancel()
        toastMessage = nil
    }

    // MARK: sidebar

    /// 侧栏折叠/展开动画的截止时刻。动画每帧都在重排与合成，期间任何快照推送
    /// （Swift 序列化占用 App 主线程 → 拖慢 CA 提交；JSON.parse 占用 WebContent
    /// 线程 → 直接吃掉动画帧）都要推迟到收口之后。不进 objectWillChange：
    /// 它只是调度信息，触发推送就本末倒置了。
    var sidebarAnimUntil = Date.distantPast

    func toggleSidebar() {
        // UI 整体在网页里：这里只翻状态，快照推给 WebUI 由它做 218px ↔ 84px
        // 的宽度过渡，Swift 侧不再需要驱动任何布局动画。
        showsSidebar.toggle()
        sidebarAnimUntil = Date().addingTimeInterval(0.35)
        UserDefaults.standard.set(showsSidebar, forKey: "sidebarVisible")
    }
}

let SPLASH_VERSION = "1.4.0"

/// Streams a child process pipe line by line without blocking the main thread.
final class TailReader {
    static func read(_ pipe: Pipe, onLine: @escaping (String) -> Void) {
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                if !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) {
                    onLine(text)
                }
                return
            }
            buffer.append(chunk)
            // huggingface_hub's tqdm redraws its bar with carriage returns, so
            // a Splash download only ever speaks \r until it exits. Split on
            // both; a bare \r line is a redraw, not a new log entry.
            while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = buffer.prefix(upTo: index)
                buffer.removeSubrange(...index)
                guard !line.isEmpty, let text = String(data: line, encoding: .utf8) else { continue }
                onLine(text)
            }
        }
    }
}
