import Foundation
import SwiftUI
import AppKit
import Darwin
import FlashCatKit

enum Page: String, CaseIterable, Identifiable {
    case overview = "概览"
    case chat = "对话"
    case models = "模型"
    case engines = "引擎"
    case logs = "日志"
    case settings = "设置"
    /// 实验室是设置之后的一页，进去再用顶部分段切换图片和视频。
    case lab = "实验室"

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

    /// 主工作区七页：实验室紧跟在设置后面。
    static let workspace: [Page] = [.overview, .chat, .models, .engines, .logs, .settings, .lab]
}

struct ThroughputSample: Identifiable {
    /// 用时间戳做身份：每个采样点的时刻天然唯一，没必要为每个点再分配一个
    /// UUID。10 分钟窗口里最多一千多个点，省下的是持续的分配与 16 字节/点。
    var id: Date { at }
    let at: Date
    let value: Double
}

/// 概览速度读数的来源。速度类指标统一走网关按请求打点，避免同一个页面里
/// 引擎的 LIVE / AVG 和网关估算混着用；引擎实时计数只作为兜底。
/// 收尾后的上一请求终值（LAST）不再是一个可用来源：概览只认「此刻在跑」。
enum SpeedOrigin: Equatable {
    /// 没有在跑会话，也没有可用的引擎实时计数：没有当前速度。
    case none
    /// 网关在跑会话的合计速率（重采样后的窗口读数）。窗口读数就是当前速度本身，
    /// 所以活跃期间不区分估算与精确计数——引擎侧的 tok/s 同样是计数器差分的估计。
    case gatewayLive
    /// 网关看不见的直连请求，用引擎的实时计数兜底。
    case engineLive
}

/// 一个指标格当前的**取数来源**。owner 表算出来的就是这个值，界面直接按它
/// 打角标与说明文案，不再各自 switch `EngineRateKind`/`SpeedOrigin`。
///
/// 速度格只认 LIVE：它只回答「此刻多快」，上一请求的终值不参与。预填充格
/// 是唯一的例外——预填充本来就是一次性的，短提示词在 1 秒采样里常常抓不到
/// 正在处理的那一刻，所以它允许把**明确标成 LAST**的最近一次实测值留在卡片上。
/// 这个实测值优先由网关自己按请求算（`.gatewayLast`），引擎的 `.engineLast`
/// 只在网关没有会话记录（客户端绕过网关直连引擎端口）时兜底。平均解码速度
/// 单独有 `.gatewayMean` / `.engineMean` 这一档，只服务 hero 的「模型启动以来平均」。
enum MetricOrigin: Equatable {
    /// 没有任何可用读数（引擎未上报、或值 ≤ 0）。
    case none
    /// 网关按请求打点的实时读数（重采样窗口）。
    case gatewayLive
    /// 网关按请求打点算出的最近一次预填充实测值。
    case gatewayLast
    /// 网关按会话累计的「模型启动以来平均」——hero 的解码均值与缓存命中率共用。
    case gatewayMean
    /// 引擎此刻正在量的实时值。
    case engineLive
    /// 引擎测过的上一请求值：数字是真的，描述的是刚结束的那一次。
    case engineLast
    /// 引擎进程 / 会话累计均值。
    case engineMean
}

/// 一格指标的 owner 表输出：数值 + 它回答的是哪个问题。
/// `value == nil` 时 `origin == .none`，界面画「—」。
struct MetricReading: Equatable {
    let value: Double?
    let origin: MetricOrigin

    static let none = MetricReading(value: nil, origin: .none)
}

/// 首字延迟格的取数结果：数值 + 它来自哪一侧的观测。
///
/// 首字和预填充一样是一次性观测，但它没有 `MetricOrigin` 那套速度语义：
/// 引擎 status 里有样本时优先（splash 给 p50，mlx-serve 给直方图均值，
/// MTPLX 给上一请求值），引擎没有这个字段（oMLX / strata）或还没有样本
/// （splash 首个请求前 p50 = 0）时，退回网关逐请求量到的最近一次首字。
/// 两侧都没有才是 「—」。
struct TTFTReading: Equatable {
    enum Source: Equatable {
        /// 没有任何首字样本。
        case none
        /// 引擎 status 上报的首字统计。
        case engine
        /// 网关按请求实测的最近一次首字。
        case gateway
    }

    let milliseconds: Double?
    let source: Source

    static let none = TTFTReading(milliseconds: nil, source: .none)
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
    /// Bumped when the startup engine/model preference changes. The value lives
    /// in `EngineStore` (and is written with the *current* engine untouched),
    /// so the settings row needs this tick to re-render.
    @Published private(set) var defaultRevision = 0
    /// Non-nil while newly selected weights are loading. The switchers show an
    /// inline spinner and the overview swaps live metrics for skeletons.
    @Published private(set) var switchingModel: String?
    /// Stage the running switch is in ("卸载旧模型" / "加载新模型"). Shown in the
    /// switcher instead of a generic spinner so the wait is explainable.
    @Published private(set) var switchStage: String = ""
    /// 「已等待 m:ss」读的是时钟，不是任何 `@Published` 字段：引擎安静加载的几
    /// 分钟里 `syncController` 的「只有真的变了才发布」会把每一秒都挡掉，灵动岛的
    /// 秒数就停住，等下一行日志或一个指标变化才跳一大截。这个计数器只在模型忙的
    /// 时候每秒推一格，专门让读时钟的文案重算。
    @Published private(set) var lifecycleTick: Int = 0
    /// 上面那个计数器的心跳；模型不忙时它不发任何东西，界面不白白每秒重绘。
    private var lifecycleClock: Timer?
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

    /// 侧栏「最近对话」用它高亮当前线程；threadID 本身只用于落盘。
    var currentThreadID: String { threadID }

    /// 正在生成的是哪一段对话——可能是读者已经切走、在后台继续跑的那一段。
    /// 侧栏据此把那一行标成「生成中」：不然切走后只剩下一个点不动的输入框，
    /// 看不出回答正在哪儿长。
    var generatingThreadID: String? {
        guard generating else { return nil }
        return background?.threadID ?? threadID
    }

    static func newThreadID() -> String {
        String(Int(Date().timeIntervalSince1970 * 1_000_000))
    }
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
    /// 每次发送领一个号。取消或重开对话时推进，启动等待中的旧任务回来
    /// 发现代数不同就静默退出，不会在已经取消的回复里继续发请求。
    private var sendGeneration = 0
    /// 正在跑的图像请求。停止按钮先掐断它，再按对话同一套收尾。
    private var imageTask: Task<Void, Never>?
    /// 正在跑的视频请求（可能正在生成几十秒，也可能在封装 MP4）。
    private var videoTask: Task<Void, Never>?
    /// 正在跑的一整轮「对话 + 画图」：中间要换图像模型、画完再换回来，
    /// 可能持续几分钟，停止按钮要和上面两个一起掐断它。
    private var imageToolTask: Task<Void, Never>?
    /// 输入框旁的「画」开关：文本模型这一轮可以主动调图像模型。
    /// 默认开——这是对话页的主动能力，关掉是少数情况。
    @Published var imageToolEnabled = ImageToolSettings.enabled {
        didSet { ImageToolSettings.setEnabled(imageToolEnabled) }
    }
    /// 工具借用的图像模型。空串表示用当前引擎里第一个能出图的模型。
    @Published var imageToolModelID = ImageToolSettings.modelID {
        didSet { ImageToolSettings.setModelID(imageToolModelID) }
    }
    /// 画完图后图像模型是否留在显存里。开着时下一轮生图直接复用权重，
    /// 代价是对话模型和图像模型同时占内存；设置页可以关掉。
    @Published var imageToolResident = ImageToolSettings.resident {
        didSet { ImageToolSettings.setResident(imageToolResident) }
    }

    /// The assistant message this generation owns, located by id.
    private var streamMessageID = ""
    /// 读者切走了、但还在后台生成的那一段对话。
    ///
    /// 生成一旦开始就不能靠「当前页面显示哪段对话」来决定回答写到哪：切走时
    /// 把整段对话连同它自己的 `threadID` 搬到这里，流式更新认这一份，跑完后
    /// 按自己的 id 落回历史，读者回到这段对话时再整体接回 `messages`。
    private struct BackgroundGeneration {
        let threadID: String
        var messages: [ChatMessage]
    }
    private var background: BackgroundGeneration?
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
    /// 概览总解码曲线的样本。速度统一取网关按请求打点的聚合；网关没有
    /// 在跑会话时，只收引擎的实时计数（且引擎必须有在跑请求），引擎的
    /// LAST/AVG 不再被画成时间序列。
    /// 曲线样本只服务概览 60 秒与菜单栏近 5 分钟；保留 10 分钟足够，
    /// 以前留 30 分钟，多出来的两三千个点没有任何界面读。
    private static let sampleRetention: TimeInterval = 600
    @Published var throughput: [ThroughputSample] = []
    /// 草稿接受率（DFlash2 / MTP）的时间序列，采样节奏与吞吐一致，
    /// 概览页用它画第二条实时曲线。value 是 0…1 的比例。
    @Published var acceptance: [ThroughputSample] = []
    /// 应用内对话流式回复的本地测速（tok/s）。只服务对话页直播条；
    /// 概览与灵动岛的速度读数统一走 owner 表（`decodeReading`），不再用它补位。
    @Published private(set) var liveDecodeRate: Double?
    // 预填充不再由应用自己按「整段提示词 / 首字耗时」估算。同一会话的第二轮
    // 几乎全部命中前缀缓存，分子里的 token 大部分根本没被前向，TTFT 里还混着
    // 排队和缓存恢复，两者一除能把读数放大两个数量级。现在只显示引擎真的
    // 量过的数：mlx-serve 用 prefill_tokens_total / prefill_time_seconds
    //（都不含缓存恢复），其余引擎用它自己的 prefill 字段；引擎没有时回落到
    // 网关的按请求打点。
    /// 网关按请求打点的聚合速率。概览曲线与「最近请求」同源，
    /// 应用内对话也注册在 `GatewayMeter` 里。收尾后归零：只表示「此刻多快」。
    @Published private(set) var gatewayDecodeRate: Double = 0
    /// `gatewayDecodeRate` 是否来自在跑会话。false = 没有在跑会话（或引擎
    /// 已经收尾），此时没有当前速度，读数不挂上一请求的终值。
    @Published private(set) var gatewayRateIsLive = false
    /// 网关自己量出来的预填充速度（最近一次完成的预填充）。分子是 usage
    /// 报告的提示词 token 减去前缀缓存命中量，分母是请求发出到首 token 的
    /// 墙钟——不读任何引擎自报的预填充字段，所以换引擎不会让这格变空。
    /// 0 = 还没有可用的实测值。
    @Published private(set) var gatewayPrefillRate: Double = 0
    /// 网关自己量出来的最近一次首字耗时（毫秒）。引擎 status 里没有 TTFT
    /// （oMLX / strata），或还没有样本（splash 首个请求前 p50 = 0）时，
    /// 首字格退到这条按请求的实测值。0 = 还没有可用的实测值。
    @Published private(set) var gatewayTTFTMilliseconds: Double = 0
    /// 网关按代累计的缓存命中率（0…1）。分子是 usage 里的前缀缓存命中量，
    /// 分母是同一批请求的提示词总量（按 token 加权）；只统计真的收到 usage
    /// 的请求。0 = 还没有样本，界面不能把它当成「0% 命中」。
    @Published private(set) var gatewayCacheHitRate: Double = 0
    /// 上面这个读数覆盖的请求数，卡片的说明文案会原样引用它。
    @Published private(set) var gatewayCacheHitRequests: Int = 0
    /// 模型启动以来的平均解码速度（网关按会话累计）。hero 大数字读它：
    /// 曲线回答「此刻多快」，大数字回答「这台模型平均吐字多快」。0 = 还没有
    /// 可算的样本，界面画「—」。
    @Published private(set) var averageDecodeRate: Double = 0
    /// 60 秒曲线冻结的时刻。请求收尾后设为收尾时刻，`overviewThroughput`
    /// 与横轴都以它为右缘——曲线停住，不再随挂钟把终点挤出窗口。
    /// 新请求开始时清空，曲线恢复滚动。
    @Published private(set) var throughputFrozenAt: Date?
    /// 上一次采样时是否还有请求在跑，用来识别「1 → 0」这次收尾。
    private var chartWasLive = false
    /// 累计均值的身份（引擎 + 进程 + 模型）。换代时清空 `GatewayMeter`
    /// 的累计量，避免把上一台模型的成绩算进这一台。
    private var lifetimeIdentity: String?
    /// 预填充**没有**网关侧聚合：网关的「(整段提示词 − 缓存命中) / 首字耗时」
    /// 口径已废弃（分母混着排队与缓存恢复，分子要等末帧 usage），概览只显示
    /// 引擎自报的速率。`GatewayMeter` 仍为「最近请求」逐行保留各自的预填充读数。
    /// 本次请求的提示词 token 估算，生成期间用来实时刷新上下文占用。
    private var livePromptTokens = 0
    /// 生成期间的连续时间低通速率估计。不再用「攒够 0.9 秒就清零」的窗口：
    /// 那种非重叠窗口让相邻读数互不相关，SSE 分片一抖数字就跟着跳。
    /// 只服务对话页直播条——概览概览按每秒一拍读网关，不在分片回调里改。
    private var decodeMeter = DecodeRateMeter()
    /// 回答结束后保留一小段平滑读数，避免 LIVE 数字在收尾瞬间台阶式回落。
    private var generationEndedAt: Date?
    /// 概览速度读数的上一拍。`syncController` 会被引擎的多次状态变化触发，
    /// 不加闸就会在一秒内发布好几次——概览的刻钟是 1 秒，不是事件驱动。
    private var lastSpeedPublishAt: Date?
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
    @Published private(set) var downloadTasks: [ModelDownloadTask] = [] {
        didSet {
            // 进度每 0.5 秒都会改 `downloadedBytes`，但模型集合没变；只有
            // 引擎/模型/状态真的变化时才让模型目录缓存失效，避免下载期间
            // 侧栏和模型页反复扫盘。
            let before = oldValue.map { "\($0.engine.rawValue)|\($0.model)|\($0.status.rawValue)" }
            let after = downloadTasks.map { "\($0.engine.rawValue)|\($0.model)|\($0.status.rawValue)" }
            if before != after { invalidateModelCaches() }
        }
    }
    /// Hugging Face 浏览器的状态：列表与单个仓库详情分开存——弹层里翻 tab 不
    /// 该把列表挤掉，两者也都只是「看一眼」，不持久化、不碰磁盘。
    @Published private(set) var hubResults: [HubModel] = []
    /// 公共目录里已落盘的仓库 id（模型广场标「已在本机」用）。
    @Published private(set) var sharedRepos: [String] = []
    /// 本机已有的全部仓库：公共目录加各引擎自己的模型目录。比 `sharedRepos`
    /// 宽——引擎目录里手放的、或从引擎推荐里下的权重同样算「已经有了」，下载
    /// 弹窗据此把下载按钮换成「已下载」。跟着 `reloadModels` 走，不进两秒一次的
    /// 每帧都会读的热路径。
    @Published private(set) var localModelRepos: [String] = []
    /// 手填仓库 id 的预检结果：输入停下后查一次 Hub，弹窗里显示体积/参数量/
    /// 文件清单/README 摘要，看清了再按下「开始下载」。和模型广场的 `hubDetail`
    /// 分开存，两边同时在屏上也不会互相挤掉。
    @Published private(set) var repoProbe: HubModel?
    @Published private(set) var repoProbeLoading = false
    @Published private(set) var repoProbeError: String?
    /// 当前这份预检结果属于哪个仓库。界面拿它对输入框：用户还在改 id 时，
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
    /// 本次会话里 downloader 宣布「还要抓」的字节数。Splash 的每个仓库只报
    /// 尚未进缓存的那部分，续传时它是「剩余」而不是总量，所以总量要用
    /// `downloadResumeBytes + downloadFetchedBytes` 重新算。
    private var downloadFetchedBytes = 0
    /// The running downloader child process; terminating it is how pause and
    /// cancel stop the transfer while the Hub's partial files stay on disk.
    private var downloadProcess: Process?
    /// Sibling marker for the model folder this transfer writes. It is created
    /// before the child starts and removed only on success, so a canceled or
    /// crashed download can never pass the scanner as an installed model.
    private var downloadIncompleteMarker: String?
    /// Set while a caller waits for a download to end (a launch that has to
    /// fetch the model's DFlash2 draft first). Reported once, in
    /// `finishDownload`, whichever way the process ended.
    private var downloadCompletion: ((DownloadOutcome) -> Void)?
    /// True while that launch-triggered download runs: it must not steal the
    /// selection or pop a toast, the engine start right behind it says more.
    private var supplementInFlight = false
    private var pauseRequested = false
    private var cancelRequested = false
    /// 用户直接删掉了正在跑的那一行：停掉子进程后 `finishDownload` 要把
    /// 任务行和半成品一起清掉，而不是像普通取消那样留一行「已暂停」。
    private var removeRequested = false
    private var lastWatchBytes = 0
    private var lastWatchDate: Date?
    /// Bytes this transfer already had on disk when it (re)started. A resumed
    /// download begins counting from here instead of 0, so both the card and
    /// the download center keep showing 已下载/总量 across a pause.
    private var downloadResumeBytes = 0
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
    /// Serialises API-triggered model preparation. The visible switcher has its
    /// own task/generation state, while two HTTP clients may arrive together;
    /// chaining here keeps the second request from issuing a second load while
    /// the first is still unloading or starting an engine.
    private var gatewayPreparationTail: Task<Void, Never>?
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
    /// 图像生成/编辑走同一台引擎的 `/v1/images/generations`，与对话互不干扰。
    let imageClient = ImageClient()
    /// 视频生成走 `/v1/video/generations`，原始帧在客户端封装成 MP4。
    let videoClient = VideoClient()
    /// The fixed-port API gateway (OpenAI + Claude formats). One instance for
    /// the whole app; requests it serves read the live engine state from here.
    let gateway = GatewayController.shared
    /// The loopback command channel used by the bundled `flashcat` CLI.
    let control = ControlServer()
    var engines: EngineManager?
    /// Pack installs shown on the engines page; owns its own installer actor.
    let installs = EngineInstallCenter()
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

    /// 窗口是界面每一帧都要问的值，而取它要么重扫模型目录、要么读 config.json，
    /// 这里跟 EngineModelStore.meta 用同一档 20s 缓存，避免把扫描塞进推送热路径。
    private var contextWindowCache: (key: String, value: Int?, at: Date)?

    /// 模型目录扫描的短缓存。`engineModels(for:)` / `libraryEntries(for:)` 会被
    /// 侧栏计数、模型页、选择器等视图在每次重绘时调用；以前每秒的指标刷新都会
    /// 触发多次目录枚举与 JSON 读取。这里缓存 1 秒，下载/删除/重新加载时立即失效。
    private static let modelListTTL: TimeInterval = 1.0
    private var engineModelsCache: [EngineID: (models: [EngineModel], at: Date)] = [:]
    private var libraryEntriesCache: [EngineID: (entries: [ModelLibraryEntry], at: Date)] = [:]

    private func invalidateModelCaches() {
        engineModelsCache.removeAll()
        libraryEntriesCache.removeAll()
    }

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

    /// 当前会话已占用的上下文 tokens。
    ///
    /// 生成期间用「本次提示词估算 + 已生成 token」实时推进，否则整段回复期间
    /// 顶栏与概览卡会停在上一次的 usage 上；回复结束后再回落到引擎回报的真实
    /// `prompt + completion`，所以静止时的数字仍然是 KV 里真正躺着的量。
    var contextUsedTokens: Int {
        if generating, livePromptTokens > 0 {
            return livePromptTokens + Int(decodeMeter.totalTokens.rounded())
        }
        guard let last = messages.last(where: { $0.role == "assistant" && ($0.usage?.promptTokens ?? 0) > 0 }),
              let usage = last.usage else { return 0 }
        return usage.promptTokens + usage.completionTokens
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
              startupStage == EngineStartupStage.ready.rawValue else {
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
           stage != EngineStartupStage.ready.rawValue, stage != "已停止" {
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

    // MARK: 指标 owner 表
    //
    // 每个指标格只有一个 owner，owner 缺席时才走声明好的降级链。以前同一个页面
    // 里 hero 走网关、预填充格走引擎、灵动岛又是引擎优先，两处数字天然对不上；
    // 现在所有界面（概览 / 灵动岛 / 菜单栏）都从下面这几个函数取数，一格一个
    // 来源、一个粒度，角标与说明文案由 `MetricOrigin` 直接给出。
    //
    // 分工的物理边界：网关只看得见流里的东西（分片节奏、TTFT、请求合计、
    // usage 里的缓存命中量），队列深度、KV 驻留、显存、草稿接受率这些只有引擎
    // 量得到。速度类指标 owner = 网关；引擎实时计数只在网关没有会话在跑时兜底
    //（客户端直连引擎端口），LAST/AVG 永远不参与当前速度。

    /// 概览曲线与菜单栏的「当前解码速度」。应用内对话也注册在 `GatewayMeter`
    /// 里，所以曲线和「最近请求」每一行是同一份数据；收尾后归零，不挂 LAST。
    var totalDecodeRate: Double { decodeReading.value ?? 0 }

    /// 当前速度读数的来源，界面据此打「网关」/「引擎实时」。
    /// 只认 LIVE：收尾后的上一请求终值不是当前速度。
    var speedOrigin: SpeedOrigin { currentSpeedOrigin }

    /// 解码格的 owner 表输出：`speedOrigin` 的判定 + 它的值，永远同源。
    var decodeReading: MetricReading {
        Self.reading(origin: speedOrigin,
                     gateway: gatewayDecodeRate,
                     engine: stats?.decodeTokensPerSecond)
    }

    nonisolated static func reading(origin: SpeedOrigin,
                                    gateway: Double,
                                    engine: Double?) -> MetricReading {
        switch origin {
        case .gatewayLive: return MetricReading(value: gateway, origin: .gatewayLive)
        case .engineLive: return MetricReading(value: engine, origin: .engineLive)
        case .none: return .none
        }
    }

    /// HERO 大数字：模型启动以来的平均解码速度，而不是曲线的实时值。
    ///
    /// 优先用网关按会话结算的累计量（覆盖所有经过网关的请求，含应用内对话）；
    /// 没有网关样本时退回引擎自己的 `.lifetimeMean`。两者都不是当前速度，
    /// 所以 `origin` 是 `gatewayMean` / `engineMean`，界面打 `AVG`。
    var averageDecodeReading: MetricReading {
        guard isRunning else { return .none }
        if averageDecodeRate > 0 {
            return MetricReading(value: averageDecodeRate, origin: .gatewayMean)
        }
        if stats?.decodeRateKind == .lifetimeMean,
           let engine = stats?.decodeTokensPerSecond, engine > 0 {
            return MetricReading(value: engine, origin: .engineMean)
        }
        return .none
    }

    /// 菜单栏解码格：有实时读数就报实时，空闲时退回「模型启动以来平均」。
    /// 面板只有一格，不能像概览那样把实时曲线和大数字分开摆——空闲时那格
    /// 若空着，读者会以为测速坏了。退回的值带着 `.gatewayMean` / `.engineMean`
    /// 的 origin，面板据此打 `AVG` 角标，不把平均值冒充成此刻速度。
    var menuBarDecodeReading: MetricReading {
        let live = decodeReading
        guard live.value == nil else { return live }
        return averageDecodeReading
    }

    /// 预填充格的 owner 表输出。
    ///
    /// 预填充是一次性动作，短提示词（几百 token）在 1 秒采样里几乎抓不到
    /// 引擎的 `in_flight` 实时窗口；换一台引擎，引擎自报字段的名字和粒度还会
    /// 整个变掉。所以 LAST 这一档走**按请求的实测值**：引擎在响应里自报的
    /// `timings`（`prompt_n − cached_n` / `prompt_ms`，流式与非流式都带）优先，
    /// 没有它才退回网关自己算的 TTFT 口径（分子是 usage 里的提示词 token 减去
    /// 前缀缓存命中量，分母是请求发出到首 token 的墙钟，只对流式响应成立）。
    /// 只有「此刻真的在预填充」才用引擎的 `.live`（那时网关还没有首 token），
    /// 其余时间按请求的实测值优先，引擎的 LAST/AVG 只在网关没有会话记录时兜底。
    var prefillReading: MetricReading {
        guard isRunning else { return .none }
        return Self.prefillReading(gateway: gatewayPrefillRate,
                                   engine: stats?.prefillTokensPerSecond,
                                   engineKind: stats?.prefillRateKind ?? .none)
    }

    /// 预填充格的完整 owner 顺序：就地预填充（引擎 LIVE）→ 网关实测 LAST →
    /// 引擎 LAST / AVG。抽成纯函数，测试可以钉住优先级。
    nonisolated static func prefillReading(gateway: Double,
                                           engine: Double?,
                                           engineKind: EngineRateKind = .none) -> MetricReading {
        let engineReading = prefillReading(engine: engine, engineKind: engineKind)
        // 实时预填充只有引擎量得到：这时网关连首 token 都还没拿到。
        if engineReading.origin == .engineLive { return engineReading }
        if gateway > 0 { return MetricReading(value: gateway, origin: .gatewayLast) }
        return engineReading
    }

    /// 引擎自报速率的翻译层，不含网关。保留给测试和网关缺席时的兜底。
    nonisolated static func prefillReading(engine: Double?,
                                           engineKind: EngineRateKind = .none) -> MetricReading {
        guard let engine, engine > 0 else { return .none }
        switch engineKind {
        case .live:
            return MetricReading(value: engine, origin: .engineLive)
        case .lastRequest:
            return MetricReading(value: engine, origin: .engineLast)
        case .lifetimeMean:
            return MetricReading(value: engine, origin: .engineMean)
        case .none:
            return .none
        }
    }

    /// 首字延迟格的 owner 表输出：引擎 status → 网关最近一次实测 → 没有。
    ///
    /// 引擎的 TTFT 统计是首选：它有样本时覆盖所有经过引擎的请求，splash 还给
    /// 的是 p50。但它不是每家都有——oMLX / strata 的 status 没有这个字段，
    /// splash 在首个请求之前报 0——这时退到网关逐请求量到的首字（应用内对话
    /// 也注册在网关里）。两侧都没有才画「—」：0 不是「首字很快」。
    var ttftReading: TTFTReading {
        guard isRunning else { return .none }
        return Self.ttftReading(engine: stats?.ttftMilliseconds,
                                gateway: gatewayTTFTMilliseconds)
    }

    /// 首字格的 owner 顺序，抽成纯函数给测试钉住。引擎值必须 > 0 才算样本；
    /// 网关值是「最近一次真的量到首字」的请求，同样 > 0 才可用。
    nonisolated static func ttftReading(engine: Double?,
                                        gateway: Double) -> TTFTReading {
        if let engine, engine > 0 {
            return TTFTReading(milliseconds: engine, source: .engine)
        }
        if gateway > 0 {
            return TTFTReading(milliseconds: gateway, source: .gateway)
        }
        return .none
    }

    /// 缓存命中率格的 owner 表输出。
    ///
    /// 主口径是网关按代累计的「命中量 / 提示词总量」（按 token 加权）：它和
    /// 其他格一样按请求打点，覆盖应用内对话与所有经过网关的客户端，也不依赖
    /// 任何一家引擎自报字段——换引擎不会让这格变空。网关一个带 usage 的请求
    /// 都没有时（客户端绕过网关直连引擎端口），退回引擎自己报的开机以来
    /// 命中率：mlx-serve / MTPLX 的 `cached / prompt` 两个累计计数器、oMLX 的
    /// `total_cached_tokens / total_prompt_tokens`。两个口径都是累计平均，
    /// 所以角标只有 `AVG`；没有样本时画「—」，不拿 0% 冒充「一次都没命中」。
    var cacheHitReading: MetricReading {
        guard isRunning else { return .none }
        return Self.cacheHitReading(gateway: gatewayCacheHitRate,
                                    requests: gatewayCacheHitRequests,
                                    engine: stats?.cacheHitRate)
    }

    /// 缓存命中率的 owner 顺序：网关按代累计 → 引擎开机以来。抽成纯函数，
    /// 测试可以钉住「网关样本优先」与「0% 是合法读数、没样本才是 —」。
    nonisolated static func cacheHitReading(gateway: Double,
                                            requests: Int,
                                            engine: Double?) -> MetricReading {
        if requests > 0, gateway >= 0, gateway <= 1 {
            return MetricReading(value: gateway, origin: .gatewayMean)
        }
        if let engine, engine >= 0, engine <= 1 {
            return MetricReading(value: engine, origin: .engineMean)
        }
        return .none
    }

    /// 解码速度读数与它自己的时间基之间的最大跨度。超过这个跨度，重采样器
    /// 的窗口就覆盖不到调用方所在的时间——这个读数就不再回答「此刻多快」，
    /// 降级为「没有当前速度」，让引擎 LIVE 计数补位。
    nonisolated private static let rateReadingFreshness: TimeInterval = 2.0
    /// `gatewayDecodeRate` 最后一次刷新的时刻，用于 `decodeReading` 的新鲜度
    /// 门槛。只在主线程读写。
    private var gatewayReadingAt: Date?

    /// 速度来源的判定。抽成纯函数，测试可以钉住「引擎 LIVE 不能压过网关」、
    /// 「引擎 LAST/AVG 不算当前速度」「空闲不显示旧值」「读数过旧降级」。
    /// `gatewayIsLive == false` 时网关值一律不参与——没有 LAST 这种"降级"。
    nonisolated static func speedOrigin(gateway: Double,
                                        gatewayIsLive: Bool = true,
                                        engine: Double?,
                                        engineKind: EngineRateKind = .none,
                                        activeRequests: Int = 0,
                                        gatewayAge: TimeInterval? = nil) -> SpeedOrigin {
        if gateway > 0, gatewayIsLive,
           gatewayAge == nil || gatewayAge! <= rateReadingFreshness {
            return .gatewayLive
        }
        if engineKind == .live, let engine, engine > 0, activeRequests > 0 {
            return .engineLive
        }
        return .none
    }

    /// `speedOrigin` 的界面可见口径：带上主线程那份 `gatewayDecodeRate` 的年龄。
    var currentSpeedOrigin: SpeedOrigin {
        guard isRunning else { return .none }
        return Self.speedOrigin(gateway: gatewayDecodeRate,
                                gatewayIsLive: gatewayRateIsLive,
                                engine: stats?.decodeTokensPerSecond,
                                engineKind: stats?.decodeRateKind ?? .none,
                                activeRequests: stats?.activeRequests ?? 0,
                                gatewayAge: gatewayReadingAt.map(Date().timeIntervalSince))
    }

    /// 概览 60 秒曲线的右缘：请求收尾后冻结在收尾时刻，新请求开始后恢复
    /// 跟随挂钟。hero 不再有 sparkline，只有概览曲线读这个口径。
    var overviewChartEnd: Date { throughputFrozenAt ?? Date() }

    /// 概览曲线样本。冻结后只取到 `throughputFrozenAt`，不会随着窗口
    /// 继续滚动而把曲线抽空。
    func overviewThroughput(window: TimeInterval) -> [ThroughputSample] {
        guard window > 0 else { return throughput }
        return Self.suffix(of: throughput, window: window, endingAt: overviewChartEnd)
    }

    /// 概览用 60 秒、菜单栏用近 5 分钟；序列保留 10 分钟，留一点余量。
    /// 菜单栏的 sparkline 不冻结，所以这里仍以当前时刻为右缘。
    func recentThroughput(window: TimeInterval) -> [ThroughputSample] {
        guard window > 0 else { return throughput }
        return Self.suffix(of: throughput, window: window, endingAt: Date())
    }

    /// Same windows for the draft-acceptance curve, so both charts scroll together.
    func recentAcceptance(window: TimeInterval) -> [ThroughputSample] {
        guard window > 0 else { return acceptance }
        return Self.suffix(of: acceptance, window: window, endingAt: Date())
    }

    /// 序列按时间升序排列，用二分找窗口起点；概览每秒都会为几张图各取一次，
    /// 全表 `filter` 在千余个样本上没有必要。`endingAt` 是窗口右缘：冻结的
    /// 曲线传收尾时刻，右缘之后（理论上没有）的迟到样本一并排除。
    private static func suffix(of samples: [ThroughputSample],
                               window: TimeInterval,
                               endingAt end: Date) -> [ThroughputSample] {
        guard !samples.isEmpty else { return [] }
        let cutoff = end.addingTimeInterval(-window)
        var low = 0
        var high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].at < cutoff {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < samples.count else { return [] }
        return samples[low...].filter { $0.at <= end }
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

    /// 引擎启动、加载权重、热切换期间每秒推一格 `lifecycleTick`。
    ///
    /// 这些时段的文案里带着 `已等待 m:ss`，而秒数是从时钟算出来的，不挂在任何
    /// `@Published` 字段上；同步函数为了避免空闲时整页每秒重绘，只在数值真的变化
    /// 时才发布。引擎安静搬权重的几分钟里两者一撞，灵动岛、概览和菜单栏的秒数就
    /// 一起停住，看起来和卡死没区别。这个节拍器只在 `isModelBusy` 时发布，空闲时
    /// 一声不响。
    ///
    /// 用 `.common` 模式：默认模式的定时器在弹窗、菜单或拖拽时停止，而启动失败的
    /// 提示正好是弹窗，等待时长会停在那一刻。
    private func installLifecycleClock() {
        lifecycleClock?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isModelBusy else { return }
                self.lifecycleTick &+= 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lifecycleClock = timer
    }

    private func syncController() {
        // 每秒轮询都会走到这里。引擎空闲时状态与指标往往原封不动，无条件赋值
        // `@Published` 会让整页每秒重绘一次；只在真的变化时才发布。
        let nextState = controller?.state ?? .stopped
        if serverState != nextState { serverState = nextState }
        let nextStats = controller?.stats
        if stats != nextStats { stats = nextStats }
        if let store = controller?.logs, store.latestId != logs.last?.id {
            logs = store.snapshot(limit: 4000)
        } else if controller == nil, !logs.isEmpty {
            logs = []
        }

        let now = Date()
        // 概览的速度读数统一在这里按 **1 秒一拍** 发布：引擎轮询是 1s，
        // 应用内对话的分片回调只喂对话页直播条，不再顺带刷新概览。
        // `@Published` 只在数值真的变化时发布，空闲时不重绘。
        publishDecodeRate(at: now)

        // 回答结束后先保留最后一次平滑读数，5 秒后才撤掉，免得对话页直播条
        // 在收尾瞬间台阶式归零；概览速度不受这段保留影响。
        if !generating, let ended = generationEndedAt, now.timeIntervalSince(ended) >= 5 {
            generationEndedAt = nil
            liveDecodeRate = nil
        }
        // 取消 / 出错的回复没有「结束保留期」，空闲后立刻撤掉旧读数。
        if !generating, generationEndedAt == nil, liveDecodeRate != nil {
            liveDecodeRate = nil
        }

        // 接受率与吞吐同频采样。引擎给的是会话累计值：空闲时它不变，生成时才爬。
        // 因此只在「数值真的变了」或「解码读数正在动」的时候落点——否则每秒都会多
        // 一个样本，概览页的曲线与读数会无谓刷新。
        if let latest = stats?.draftAcceptance {
            let cutoff = now.addingTimeInterval(-Self.sampleRetention)
            let due = acceptance.last.map { now.timeIntervalSince($0.at) >= 0.9 } ?? true
            let changed = acceptance.last.map { abs($0.value - latest) > 0.0001 } ?? true
            let rateMoving = stats?.decodeTokensPerSecond.map { reported in
                throughput.last.map { abs($0.value - reported) > 0.15 } ?? true
            } ?? false
            if due, changed || rateMoving {
                acceptance.append(ThroughputSample(at: now, value: latest))
                acceptance.removeAll { $0.at < cutoff }
            }
        }

        if switchingModel != nil { syncSwitchStage() }
    }

    /// 流式回复的本地测速：每个增量按小数权重喂进连续时间低通估计器。
    ///
    /// 这条低通只服务对话页直播条——那里要的是「最后一个脉冲的强度」，按
    /// 分片节奏刷新是对的。概览的曲线 / 大数字按统一的 1 秒节拍读网关，
    /// 不再被分片回调推着「立即变化」。
    private func recordStreamDelta(_ piece: String, at event: Date) {
        let tokens = TokenEstimator.fractional(piece)
        guard tokens > 0 else { return }
        // 用分片真正到达的时刻，而不是主线程排到这一条任务的时刻。UI 忙时
        // 一批回调会被挤在一起处理，若在此时取 `Date()`，估计器会以为几十个
        // token 是「瞬间」吐出来的，读数被抬出一个尖峰。
        decodeMeter.add(tokens: tokens, at: event)
        let chatRate = decodeMeter.rate(at: Date())
        liveDecodeRate = chatRate > 0 ? chatRate : nil
    }

    /// 概览速度的唯一节拍：读一次网关聚合、发布当前速度与平均速度、
    /// 落一个 1 秒曲线点、判断是否该冻结曲线。
    ///
    /// 应用内对话也注册在 `GatewayMeter` 里，所以这里的实时值、曲线末端与
    /// 「最近请求」读的是同一份按请求打点。收尾后 `overview.isLive` 立刻
    /// 变 false：当前速度归零（不再挂 LAST），曲线冻结在最后一个采样点。
    ///
    /// 采样规则只有一条：**一拍最多一个点**。`publishDecodeRate` 自己已经
    /// 按 1 秒闸住，所以这里不再做第二道时间门槛；按「值变了」加密采样
    /// 更不行——同一秒内的多次 `syncController` 会把 60 秒曲线灌成非等距的点。
    func publishDecodeRate(at now: Date) {
        // 一秒一拍：同一拍里 `syncController` 可能被多个状态变化叫醒，
        // 但概览的数字只该在整秒上变。0.95 留一点定时器抖动余量。
        if let last = lastSpeedPublishAt, now.timeIntervalSince(last) < 0.95 { return }
        lastSpeedPublishAt = now
        // 累计均值的身份先对齐：引擎 / 进程 / 模型换代时清空上一台的成绩。
        syncLifetimeIdentity()
        let overview = GatewayMeter.shared.overview(now: now)
        publishGatewayOverview(overview, at: now)
        publishGatewayPrefill()
        publishGatewayTTFT()
        publishGatewayCacheHit()
        publishAverageDecodeRate()
        // 直连引擎端口的请求网关看不见：引擎自己报的 activeRequests 也算
        // 「还有东西在跑」，Chart 不该在它跑完之前冻结。
        let live = overview.isLive || (stats?.activeRequests ?? 0) > 0
        sampleSpeed(at: now, isLive: live)
        updateChartFreeze(isLive: live, at: now)
    }

    /// 把网关的聚合读数发布成当前速度的两个 `@Published` 值，并盖上时间戳。
    ///
    /// `gatewayReadingAt` 是 owner 表的新鲜度门槛：读数只在真的发布过之后
    /// 才有资格谈年龄。
    private func publishGatewayOverview(_ overview: GatewayMeter.Overview, at now: Date) {
        let changed = gatewayDecodeRate != overview.decodeRate || gatewayRateIsLive != overview.isLive
        if changed {
            gatewayDecodeRate = overview.decodeRate
            gatewayRateIsLive = overview.isLive
        }
        // 时间戳每次同步都盖：读数稳定在同一个值时 `changed` 为 false，
        // 但这一拍仍然是新鲜的。只在数值变化时盖章会把「稳定的高速」
        // 误判成「过旧」，1 秒节拍下尤其明显。
        gatewayReadingAt = now
    }

    /// 发布网关自己算的预填充实测值。它不是「当前速度」，所以不走
    /// `gatewayReadingAt` 的新鲜度门槛：预填充做完就固定了，只是标成 LAST。
    private func publishGatewayPrefill() {
        let next = GatewayMeter.shared.recentPrefill() ?? 0
        guard abs(gatewayPrefillRate - next) > 0.5 else { return }
        gatewayPrefillRate = next
    }

    /// 发布网关实测的最近一次首字。与预填充同样是「做完就固定」的观测，
    /// 不走 `gatewayReadingAt` 的新鲜度门槛：它描述的是上一轮等了多久，
    /// 不是「此刻多快」。新一代（换引擎 / 换模型）后读数自然回 0。
    private func publishGatewayTTFT() {
        let next = GatewayMeter.shared.recentTTFTMilliseconds() ?? 0
        guard abs(gatewayTTFTMilliseconds - next) > 0.5 else { return }
        gatewayTTFTMilliseconds = next
    }

    /// 发布网关按代累计的缓存命中率。与预填充同样不走新鲜度门槛：它描述的是
    /// 最近这批有 usage 的请求，做完就固定，直到下一条 usage 回来才跳一格。
    /// 引擎停下时清回 0 / 0——界面靠 `requests == 0` 区分「没样本」与「0%」。
    private func publishGatewayCacheHit() {
        let next = isRunning ? GatewayMeter.shared.cacheHit() : nil
        let rate = next?.rate ?? 0
        let requests = next?.requests ?? 0
        guard abs(gatewayCacheHitRate - rate) > 0.0001
                || gatewayCacheHitRequests != requests else { return }
        gatewayCacheHitRate = rate
        gatewayCacheHitRequests = requests
    }

    /// 发布 HERO 的「模型启动以来平均」。网关累计量为 0 时保留 0，界面会
    /// 去看引擎的 `.lifetimeMean`，两处都没有就画「—」。
    private func publishAverageDecodeRate() {
        let next = isRunning ? (GatewayMeter.shared.lifetimeAverage() ?? 0) : 0
        guard abs(averageDecodeRate - next) > 0.0001 else { return }
        averageDecodeRate = next
    }

    /// 把一次网关读数落到 60 秒曲线上。只有「在跑」且读数 > 0 时落点：
    /// 静默段不拿 0 去填谷，曲线保留最后一段真实形状；请求收尾由
    /// `updateChartFreeze` 冻结整张图。一拍一个点由调用方的 1 秒闸保证。
    private func sampleSpeed(at now: Date, isLive: Bool) {
        guard isLive else { return }
        let sample = totalDecodeRate
        guard sample > 0 else { return }
        throughput.append(ThroughputSample(at: now, value: sample))
        throughput.removeAll { $0.at < now.addingTimeInterval(-Self.sampleRetention) }
    }

    /// 请求全部收尾时把 60 秒曲线冻在收尾时刻；新请求一开始就解冻。
    /// 冻结的是**右缘**（`overviewChartEnd`），不是样本数组：窗口不再随
    /// 挂钟向前滑，曲线也就不会在空闲几分钟后被裁空。
    private func updateChartFreeze(isLive: Bool, at now: Date) {
        let next = Self.chartFrozenAt(previous: throughputFrozenAt,
                                      wasLive: chartWasLive,
                                      isLive: isLive,
                                      now: now)
        if throughputFrozenAt != next { throughputFrozenAt = next }
        chartWasLive = isLive
    }

    /// 曲线冻结状态的纯逻辑：进行中永远解冻；1 → 0 的那一拍记下收尾时刻；
    /// 一直空闲时不冻结（否则启动即冻，横轴永远停在开机时刻）。
    /// 抽出来是为了在没有窗口的测试里钉住这三条。
    nonisolated static func chartFrozenAt(previous: Date?,
                                          wasLive: Bool,
                                          isLive: Bool,
                                          now: Date) -> Date? {
        if isLive { return nil }
        if let previous { return previous }
        return wasLive ? now : nil
    }

    /// 累计均值的身份 = 引擎 + 进程 + 进程启动时刻 + 模型。任一变化都说明
    /// 换了一台「模型启动以来」，上一台的累计量不该再算进来。
    private func syncLifetimeIdentity() {
        guard let stats else { return }
        let key = [
            activeEngine.rawValue,
            stats.instancePid.map(String.init) ?? "-",
            stats.startedAt.map { String(format: "%.3f", $0) } ?? "-",
            stats.model ?? "-"
        ].joined(separator: "|")
        guard key != lifetimeIdentity else { return }
        lifetimeIdentity = key
        GatewayMeter.shared.resetLifetime()
        if averageDecodeRate != 0 { averageDecodeRate = 0 }
    }

    func bootstrap() {
        // 先让等待时长的心跳跑起来：下面的 autoStart 可能立刻拉起引擎，
        // 而「已等待 0:01」从第一秒就该开始走。
        installLifecycleClock()

        let service = ModelCatalogService()
        let migration = service.migrateLegacyDirectories()
        if !migration.isEmpty {
            let moved = migration.moved + migration.archived
            toast(L10n.format("已把 %lld 项旧模型数据迁入 Application Support/flashCat", moved))
        }
        Paths.ensureDirectory(Paths.modelsDirectory)

        // 旧版本用软链接把 ~/.omlx、~/.mtplx 的权重挂进模型目录；现在模型必须
        // 真正待在自己的目录里，启动时把链接换成权重本身，并清掉失效链接。
        var adopted = 0
        for engine in EngineCatalog.allIDs {
            adopted += EngineModelStore.adoptExistingWeights(engine).adopted.count
        }
        if adopted > 0 {
            toast(L10n.format("已把 %lld 个模型搬进 flashCat 的模型目录，不再依赖外部目录", adopted))
        }

        // 授权表是公共目录的真相：启动时按它把各引擎目录里的链接对齐。
        ModelSharing.synchronize()

        catalog = service.load()
        if catalog.machine.isEmpty {
            selectedModel = settings.model
        } else if settings.model.isEmpty, let first = catalog.machine.first {
            selectedModel = first.id
            settings.setModel(selectedModel)
        } else {
            selectedModel = settings.model
        }
        messages = conversation.load()
        // 旧版本留下的重复线程只在启动时清理一次，之后都走缓存。
        threads = history.load(pruneLegacy: true)

        attachEngines()
        // A crashed or force-quit session can leave an engine resident with its
        // weights; clear those before anything of this session starts.
        engines?.sweepOrphanEngines()
        syncController()

        // Work out (or recall) what this Mac should run before the launch page
        // takes over: the first-run page and the launch page both ask "which
        // engine", and the recommendation is what answers it.
        settleRecommendation()

        // The CLI needs a status endpoint even on a fresh install, so the
        // command channel comes up before the launch-page early return.
        startControlServerIfNeeded()

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

    /// Start the CLI control channel when it is enabled and not already up.
    /// Called from `bootstrap` and from the settings page after the toggle or
    /// port changes.
    func startControlServerIfNeeded() {
        guard settings.controlAPIEnabled, !control.isRunning else { return }
        let port = UInt16(settings.controlPort)
        Task { [control] in
            await control.start(preferredPort: port)
        }
    }

    /// Apply the control-interface settings without requiring a relaunch.
    func applyControlSettings() {
        guard settings.controlAPIEnabled else {
            control.stop()
            return
        }
        let port = UInt16(settings.controlPort)
        if control.isRunning, control.port == port { return }
        Task { [control] in
            await control.restart(port: port)
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
        engines?.rebuild(preferring: id)
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

    /// 本机已经有这些仓库：公共目录里的 + 各引擎模型目录里的权重。
    /// 模型广场和手填下载都按它判「已下载」，所以启动时（`bootstrap`）也要扫
    /// 一次——只挂在 `reloadModels` 上会等引擎安装/下载/授权变化才第一次算，
    /// 刚开app 时广场会全是「下载」。
    /// 三次目录扫描的 stat 走 `EngineModelStore` 的 meta 缓存，只有新增目录才真读盘。
    func refreshLocalRepos() {
        var local = Set(sharedRepos.map { ModelSharing.canonical($0) })
        for id in EngineCatalog.allIDs {
            for model in LocalEngineModels.scan(engine: id,
                                                directory: EnginePaths.modelsDirectory(id)) {
                local.insert(ModelSharing.canonical(model.id))
            }
        }
        localModelRepos = local.sorted()
    }

    func reloadModels() {
        // 授权表是真相，磁盘上的链接跟着它走：启动、下载完成、授权变更都从这里过。
        ModelSharing.invalidateCaches()
        invalidateModelCaches()
        ModelSharing.synchronize()
        // 公共目录里已经有哪些仓库：模型广场用它标「已在本机」。跟着
        // reloadModels 走（不挂在每两秒的指标轮询里），磁盘不会被反复扫。
        sharedRepos = ModelSharing.scan().map { $0.id }
        refreshLocalRepos()
        catalog = ModelCatalogService().load()
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
        return L10n.format("推荐 · %@", pick.reason)
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
    /// unified memory, so switching stops the old one first — and waits for it
    /// to really exit before the new engine is allowed to load anything.
    ///
    /// `start` keeps "switch" meaning "serve this engine": the destination is
    /// started even when the previous one was idle, so a switch never leaves the
    /// reader staring at a stopped engine. Callers that have a download to finish
    /// first (the library sheet) pass `false` and start after it.
    @discardableResult
    func switchEngine(_ id: EngineID, start: Bool = true) async -> Bool {
        guard let engines, id != engines.activeID else { return false }
        // 换引擎本身就是重启进程：正在进行的切换（包括跨引擎跳过去的那一半）
        // 已经没有意义，直接作废。以前这里 toast 一句就 return，读者再点最多
        // 的选择都没反应，而那个被跳过的切换还在原地挂着。
        if isSwitchingModel { retireModelSwitch() }
        // A pending「切换模型？」sheet names the old engine's weights; it can
        // no longer be confirmed once the engine under it changed.
        confirmingModelSwitch = nil
        guard engines.controller(id) != nil else {
            requestEngineInstall(id)
            return false
        }
        let activated = await engines.activate(id)
        // The pack disappeared (or the handoff was cancelled) while the old
        // engine was stopping: do not point the library at an engine we are not
        // actually running.
        guard activated || activeEngine == id else {
            requestEngineInstall(id)
            return false
        }
        libraryEngine = id
        reloadModels()
        // Switching to an engine must not keep the previous engine's model id:
        // the remembered one only survives if this engine can serve it.
        adoptSavedModel(for: id)
        syncController()
        if start, !selectedModel.isEmpty { startService() }
        toast(L10n.format("已切换到 %@", id.displayName), transient: true)
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
        if let hit = engineModelsCache[id],
           Date().timeIntervalSince(hit.at) < Self.modelListTTL {
            return hit.models
        }
        let models = scanEngineModels(for: id)
        engineModelsCache[id] = (models, Date())
        return models
    }

    private func scanEngineModels(for id: EngineID) -> [EngineModel] {
        // A half-downloaded snapshot already carries config.json and a
        // tokenizer, which is enough for the scan to call it a servable model.
        // Every download-center row means its folder is not finished (success
        // removes the row), so hide those folders from the library until the
        // downloader is done — the card then keeps showing live progress on
        // the suggestion row instead of flipping to a "使用" button.
        let unfinished = Set(downloadTasks.map { ModelSharing.canonical($0.model) })
        let shared = sharedModels(for: id)
            .filter { !unfinished.contains(ModelSharing.canonical($0.id)) }
        if id.adapter == .splash {
            // 公共目录里的权重已经在 catalog.local 里（load 会把 ModelSharing.scan()
            // 并进来），这里只过滤没下完的，不再追加一遍。
            return catalog.machine
                .filter { ModelSharing.visible($0.id, engine: .splash) }
                .filter { !unfinished.contains(ModelSharing.canonical($0.id)) }
                .map {
                    // Splash 的视觉能力来自独立的 mmproj 投影（GGUF 旁边的
                    // mmproj-*.gguf），目录扫描看不到；不补这个能力位，视觉
                    // 模型在对话页会被当成纯文本模型，画完图也不回传像素。
                    let vision = $0.mmprojPath != nil
                        || LocalEngineModels.capabilities(at: $0.path).contains("vision")
                        || LocalEngineModels.capabilities(at: $0.targetName).contains("vision")
                    return EngineModel(id: $0.id, path: $0.path, bytes: $0.bytes,
                                       maximumContextTokens: nil, loaded: false, loading: false,
                                       kind: nil, capabilities: vision ? ["chat", "vision"] : [],
                                       hidden: false, helper: false, engine: .splash)
                }
        }
        let scanned = LocalEngineModels.scan(engine: id, directory: EnginePaths.modelsDirectory(id))
        // Flat-layout packs (oMLX, MTPLX, Strata) scan as `owner--repo` while
        // the download task is keyed by `owner/repo`. Canonicalise both sides
        // or the partial folder slips through and the card flips to "使用"
        // before the transfer is done.
        return scanned.filter { !unfinished.contains(ModelSharing.canonical($0.id)) } + shared
    }

    /// 公共目录里授权给这个引擎的权重。oMLX / MTPLX 目录里也有它们，但那是
    /// 软链，`LocalEngineModels.scan` 会跳过——模型页的真相来自这里。
    private func sharedModels(for engine: EngineID) -> [EngineModel] {
        ModelSharing.scan()
            .filter { ModelSharing.engines(for: $0.id).contains(engine) }
            .map { model in
                // Splash 认 `owner/repo`，两个 pack 认扁平目录名——启动时交给引擎
                // 的就是这个 id，不能用另一种写法。
                let id = engine.adapter == .splash || engine.descriptor.modelLayout == .nested
                    ? model.id
                    : ModelInstaller.folderName(for: model.id)
                let vision = model.mmprojPath != nil
                    || LocalEngineModels.capabilities(at: model.targetName).contains("vision")
                return EngineModel(id: id,
                                   path: model.targetName,
                                   bytes: model.bytes,
                                   maximumContextTokens: nil, loaded: false, loading: false,
                                   kind: nil, capabilities: vision ? ["chat", "vision"] : [],
                                   hidden: false, helper: false, engine: engine)
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
        if let hit = libraryEntriesCache[engine],
           Date().timeIntervalSince(hit.at) < Self.modelListTTL {
            return hit.entries
        }
        let entries = buildLibraryEntries(for: engine)
        libraryEntriesCache[engine] = (entries, Date())
        return entries
    }

    private func buildLibraryEntries(for engine: EngineID) -> [ModelLibraryEntry] {
        let installed: [ModelInfo]
        if engine.adapter == .splash {
            installed = catalog.machine.filter { ModelSharing.visible($0.id, engine: .splash) }
        } else {
            installed = engineModels(for: engine).map { model in
                let path = model.path ?? (EnginePaths.modelsDirectory(engine) + "/" + model.id)
                return ModelInfo(id: model.id,
                                 path: path,
                                 bytes: model.bytes ?? 0,
                                 origin: .local,
                                 targetName: "",
                                 quantization: ModelQuantization.detect(in: model.id)
                                     ?? EngineModelStore.meta(of: path).quantization)
            }
        }
        return ModelLibrary.entries(installed: installed,
                                    engine: engine,
                                    recommendations: libraryRecommendations(for: engine)) { id in
            engine.adapter == .splash ? self.catalog.draftRepository(id, family: nil) : nil
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
        hubSearch.results
            .filter { $0.engines.contains(engine) }
            .map { $0.targeting(engine) }
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
            toast(L10n.format("已为 %@ 指定辅助模型 %@", shortModelName(model), shortModelName(draft)),
                  transient: true)
        } else {
            toast(L10n.format("已清除 %@ 的辅助模型，跟随引擎设置", shortModelName(model)),
                  transient: true)
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
        // The engine handoff is async (it waits for the old process to let go of
        // its weights), so the download / model pick follows it in the same task
        // instead of assuming the switch already happened.
        Task { [weak self] in
            guard let self else { return }
            // A failed switch (engine uninstalled between dialog and confirm,
            // say) must not leave a download pointed at a runtime that is not
            // there.
            guard self.engineIsInstalled(request.engine) else {
                self.requestEngineInstall(request.engine)
                return
            }
            // Don't start the destination's old weights: either the download
            // follows, or applyModel starts the picked model itself.
            let switched = await self.switchEngine(request.engine, start: false)
            // Only follow the handoff when it landed on the requested engine;
            // a failed activation must not point a download at another runtime.
            guard switched || self.activeEngine == request.engine else { return }
            if request.needsDownload {
                self.downloadModel(request.model, engine: request.engine)
            } else {
                self.applyModel(request.model)
            }
        }
    }

    func cancelLibraryUse() { pendingLibraryUse = nil }

    // MARK: API gateway model preparation

    /// Make the model named by an API request the one that is actually loaded.
    ///
    /// This is deliberately separate from `applyModel`: API clients cannot
    /// answer a confirmation sheet, and a request that names a different model
    /// must not be silently served by the currently resident one. The method
    /// resolves ownership across every installed engine, performs the engine
    /// handoff when needed, starts a stopped engine, and waits until the engine
    /// reports the requested weights resident.
    ///
    /// `nil` means the requested (or currently selected) model is ready.
    /// - Parameter allowingGeneration: 应用内图像生成用。它自己已经把
    ///   `generating` 置真，但换模型正是这次生成要做的事，不能因此拒绝自己。
    func prepareModelForGateway(_ requestedModel: String?,
                                allowingGeneration: Bool = false) async -> GatewayModelPreparationError? {
        let previous = gatewayPreparationTail
        let operation = Task { @MainActor [weak self] () -> GatewayModelPreparationError? in
            await previous?.value
            guard let self else { return .unavailable("flashCat 状态不可用") }
            return await self.prepareModelForGatewayExclusively(
                requestedModel, allowingGeneration: allowingGeneration)
        }
        gatewayPreparationTail = Task { _ = await operation.value }
        return await operation.value
    }

    private func prepareModelForGatewayExclusively(_ requestedModel: String?,
                                                  allowingGeneration: Bool)
        async -> GatewayModelPreparationError? {
        guard !needsEngineSetup, let engines else {
            return .unavailable("还没有安装推理引擎，请先在 flashCat 中安装并启动一个引擎")
        }

        // A model picked in the UI may still be loading. Wait for that switch
        // instead of issuing a competing load against an engine that is in the
        // middle of unloading its previous weights.
        let switchWaitDeadline = Date().addingTimeInterval(max(activeEngine.startupTimeout, 30))
        while isSwitchingModel, Date() < switchWaitDeadline {
            if Task.isCancelled { return .failed("模型准备已取消") }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if isSwitchingModel {
            return .unavailable("模型仍在切换中，请稍后重试")
        }

        var orderedEngines = [activeEngine]
        orderedEngines.append(contentsOf: availableEngines.filter { $0 != activeEngine })
        let modelsByEngine = Dictionary(uniqueKeysWithValues: orderedEngines.map { engine in
            (engine, engineModels(for: engine).map(\.id))
        })

        let route: GatewayModelRoute
        let wanted = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if wanted.isEmpty {
            let activeModels = modelsByEngine[activeEngine] ?? []
            guard let fallback = EngineModelSelection.resolve(saved: selectedModel,
                                                              available: activeModels) else {
                return .badRequest("请求没有 model 字段，flashCat 也没有可用的默认模型")
            }
            route = GatewayModelRoute(model: fallback, engine: activeEngine)
        } else {
            guard let resolved = GatewayModelRouting.resolve(requestedModel: wanted,
                                                              orderedEngines: orderedEngines,
                                                              modelsByEngine: modelsByEngine) else {
                return .modelNotFound("没有已安装的模型 \(wanted)")
            }
            route = resolved
        }

        guard let destination = engines.controller(route.engine) else {
            return .unavailable("\(route.engine.displayName) 没有可用的运行时")
        }

        // Changing weights under a running in-app generation would abort that
        // response. If the request needs no physical model change it can share
        // the resident model; otherwise report back rather than corrupting the
        // current chat.
        let alreadyActive = route.engine == activeEngine
        let alreadyResident = gatewayModelIsResident(route.model, in: destination)
        let requiresWork = !alreadyActive || !destination.isRunning || !alreadyResident
        if generating, requiresWork, !allowingGeneration {
            return .unavailable("flashCat 正在生成回复，暂时不能切换模型")
        }
        if requiresWork || selectedModel != route.model {
            gateway.logs.append("==> API 请求模型 \(route.model) · \(route.engine.displayName)",
                                level: .system)
        }

        if !alreadyActive {
            let activated = await engines.activate(route.engine)
            guard activated || activeEngine == route.engine else {
                return .failed("切换到 \(route.engine.displayName) 失败")
            }
            libraryEngine = route.engine
            reloadModels()
            syncController()
        }

        // Avoid rewriting UserDefaults and the engine configuration on every
        // request when the requested model is already selected and resident.
        if selectedModel != route.model {
            selectModel(route.model)
        }
        let savedModel = EngineStore.shared.configuration(for: route.engine).lastModel
        if savedModel != route.model {
            engines.setModel(route.model, for: route.engine)
        }
        syncController()

        guard let controller = self.controller, controller.id == route.engine else {
            return .unavailable("\(route.engine.displayName) 没有可用的运行时")
        }

        if !controller.isRunning {
            await controller.start(localModel: selectedModelInfo, requestedModel: route.model)
        } else if !gatewayModelIsResident(route.model, in: controller),
                  controller.model != route.model {
            // A running engine with other weights resident: use the same
            // unload-confirm-load path as the switcher. Hot engines do this in
            // place; restart engines stop the process first.
            let outcome = await controller.switchModel(route.model) { _ in
                // The controller already writes the unload/load stages to its
                // own log. Do not borrow the UI switcher's `switchStage`: that
                // field is owned and cleared by `beginModelSwitch`, and setting
                // it here would leave a stale stage in the status line.
            }
            if case .failed(let reason) = outcome {
                return .failed(reason)
            }
        }

        let ready = await controller.waitForSwitchReady(route.model,
                                                         timeout: route.engine.startupTimeout)
        syncController()
        guard ready else {
            let reason = controller.failureMessage
                ?? "\(route.engine.displayName) 未能在预期时间内加载 \(route.model)"
            return .failed(reason)
        }
        if requiresWork {
            gateway.logs.append("==> API 模型已就绪 · \(route.model) · 端口 \(controller.port)",
                                level: .system)
        }
        return nil
    }

    /// Whether the controller's own telemetry says these exact weights are
    /// resident. During a cold start there is no status document yet, so the
    /// caller also checks `controller.model` and waits for the load to finish.
    private func gatewayModelIsResident(_ target: String, in controller: EngineController) -> Bool {
        guard let status = controller.status else { return false }
        return status.model == target || status.loadedModels.contains(target)
    }

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
        toast(L10n.format("已把 %@ 设为 %@ 的默认模型，下次启动生效；当前运行的 %@ 不受影响",
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
        retireModelSwitch()
        confirmingModelSwitch = nil
        let generation = switchGeneration
        // 停着的时候不再只换选择：跨引擎选模型同样意味着「现在就跑它」，
        // 所以界面直接进入「启动引擎」。
        switchingModel = model
        switchStage = wasRunning ? "停止旧引擎" : "启动引擎"

        switchTask = Task { [weak self] in
            guard let self else { return }
            // 只在这里换引擎：等旧引擎真的退出，再让新引擎加载权重。
            let activated = await engines.activate(engine)
            // 被更新的选择接管了：状态与引擎都归那一代，这里静默退出。
            guard generation == self.switchGeneration else { return }
            guard activated || self.activeEngine == engine else {
                self.settleModelSwitch(generation: generation,
                                       outcome: .failed("\(engine.displayName) 没有可用的控制器"))
                return
            }
            self.libraryEngine = engine
            self.reloadModels()
            // The picked model wins over the engine's remembered one.
            self.selectModel(model)
            engines.setModel(model, for: engine)
            self.syncController()

            self.switchStage = "加载新模型"
            guard let controller = self.controller else {
                self.settleModelSwitch(generation: generation,
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
                // 排队只是「你的点击没丢」的一过性回执：不留在通知历史里。
                toast(L10n.format("正在切换模型，完成后自动切到 %@", shortModelName(target)),
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
    ///
    /// 切换等于「让它现在就用这份权重」：引擎停着时不是只记住选择，而是直接用
    /// 新权重启动。以前这里只 toast「已切换」，读者看到引擎一直停着，以为切换
    /// 没生效。
    private func beginModelSwitch(to id: String) {
        // 上一次切换（比如跨引擎跳过来的那一次加载）先作废，这一次从头开始。
        retireModelSwitch()
        let generation = switchGeneration
        let wasRunning = isRunning
        switchingModel = id
        switchStage = wasRunning ? "准备切换" : "启动引擎"
        switchTask = Task { [weak self] in
            guard let self, let controller = self.controller else {
                self?.settleModelSwitch(generation: generation,
                                        outcome: .failed("\(self?.activeEngine.displayName ?? "引擎") 没有可用的控制器"))
                return
            }
            guard wasRunning else {
                await controller.start(localModel: self.selectedModelInfo, requestedModel: id)
                let ready = await controller.waitForSwitchReady(id, timeout: self.activeEngine.startupTimeout)
                self.settleModelSwitch(generation: generation, outcome: ready
                    ? .ready
                    : .failed(controller.failureMessage ?? "\(self.activeEngine.displayName) 未能在预期时间内就绪"))
                return
            }
            let outcome = await controller.switchModel(id) { stage in
                // 被接管之后就不要再往新切换的阶段行里写了。
                guard generation == self.switchGeneration else { return }
                self.switchStage = stage
            }
            self.settleModelSwitch(generation: generation, outcome: outcome)
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
        // 排队的模型 id 只属于这台引擎；换引擎/被接管之后它就指向另一份权重
        // 目录里的名字，留着只会在下一次收起时把别人的模型当成这台引擎的。
        queuedSwitchModel = nil
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
        // 退路回执，不是需要回头再看的状态：加载仍在后台推进，阶段行会说。
        toast(L10n.format("已取消等待 · %@ 仍在后台加载", engine.displayName),
              kind: .warning,
              transient: true)
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
            // 换模型是读者自己点的那一下的结果，看到「运行中」就够了：
            // 这条只闪一下，不写进通知历史。
            toast(L10n.format("模型已就绪 · %@", shortModelName(selectedModel)),
                  kind: .success,
                  transient: true)
        case .failed(let reason):
            notice = reason
            toast("模型切换失败，请查看日志")
        }
    }

    private func cancelModelSwitch() {
        queuedSwitchModel = nil
        retireModelSwitch()
    }

    /// Display name for a model id: the repository's own name, not a made-up
    /// product alias. Engines that keep weights in a flat `owner--repo` folder
    /// are canonicalised first so toasts do not print the storage form.
    func shortModelName(_ id: String) -> String {
        let value = id.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return "—" }
        let canonical = value.replacingOccurrences(of: "--", with: "/")
        return canonical.split(separator: "/").last.map(String.init) ?? canonical
    }

    // MARK: logs

    func refreshLogs() { logs = controller?.logs.snapshot(limit: 4000) ?? [] }

    func clearLogs() {
        controller?.logs.clear()
        refreshLogs()
    }

    // MARK: chat

    /// Mutate the assistant message this generation owns, located by id.
    ///
    /// The stream used to hold an array index from the moment `send` started.
    /// `messages` is replaced wholesale by `newConversation` / `openThread`, so
    /// by the time a token arrived that index could still be in bounds while
    /// pointing at a different conversation — the reply was silently appended to
    /// somebody else's message. Ids survive the replacement; indices do not.
    @discardableResult
    private func updateStreamingMessage(_ body: (inout ChatMessage) -> Void) -> Bool {
        guard !streamMessageID.isEmpty else { return false }
        // 读者切走后回答继续长在后台那一份里，不能写进他现在看的对话。
        if var running = background {
            guard let index = running.messages.firstIndex(where: { $0.id.uuidString == streamMessageID })
            else { return false }
            body(&running.messages[index])
            background = running
            return true
        }
        guard let index = messages.firstIndex(where: { $0.id.uuidString == streamMessageID })
        else { return false }
        body(&messages[index])
        return true
    }

    /// 发送前把引擎带到「真的能用」：先等正在进行的切换结束，引擎没起就启动，
    /// 再等权重加载完成。启动阶段实时写进 `chatStartupStage`，占位回复据此显示
    /// 「模型正在启动中」。返回 false 表示启动失败或已被取消。
    private func prepareChatSession(generation: Int) async -> Bool {
        if isSwitchingModel {
            let switchDeadline = Date().addingTimeInterval(activeEngine.startupTimeout)
            while isSwitchingModel, Date() < switchDeadline {
                if sendGeneration != generation || Task.isCancelled { return false }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if isSwitchingModel { return false }
        }
        guard let controller else { return false }
        guard !canChat else { return true }
        if !controller.isRunning {
            await controller.start(localModel: selectedModelInfo, requestedModel: selectedModel)
        }
        // 启动本身可能包含较长的准备（比如补下 draft 权重），从真正开跑之后再
        // 计时，别让准备阶段吃掉等待权重的预算。
        let deadline = Date().addingTimeInterval(activeEngine.startupTimeout)
        while Date() < deadline {
            if sendGeneration != generation || Task.isCancelled { return false }
            if canChat { return true }
            if serverState == .failed { return false }
            if !isRunning, serverState == .stopped { return false }
            let stage = engineStageText
            if !stage.isEmpty, stage != "已停止" { chatStartupStage = stage }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return canChat
    }

    func send(_ text: String,
              attachment: ChatImageAttachment? = nil,
              lastFrame: ChatImageAttachment? = nil,
              referenceImages: [ChatImageAttachment] = [],
              referenceClips: [VideoReferenceClip] = [],
              image: ImageOptions = ImageOptions(),
              video: VideoOptions = VideoOptions()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || generating { return }
        guard !needsEngineSetup else {
            notice = "还没有安装推理引擎，请先在启动页选择一个"
            return
        }
        guard !selectedModel.isEmpty else {
            notice = "还没有选择模型"
            return
        }
        if activeModelSupportsVideo {
            sendVideo(trimmed, attachment: attachment, lastFrame: lastFrame,
                      referenceImages: referenceImages, referenceClips: referenceClips,
                      options: video)
            return
        }
        if activeModelSupportsImage {
            sendImage(trimmed, attachment: attachment, options: image)
            return
        }
        // 文本模型 + 开了「画」+ 引擎里有图像模型：这一轮把画图当工具交给它，
        // 由模型自己决定画几张、写什么分镜。
        if imageToolActive, let imageModel = imageToolModel {
            sendWithImageTool(trimmed, imageModel: imageModel)
            return
        }
        // 引擎没就绪也允许发送：先把这句话摆进对话，回复气泡里显示启动状态，
        // 等引擎真的能用之后 `prepareChatSession` 再继续跑这次生成。
        let needsStartup = !canChat

        // 被「停止」的空回答留在界面上，但不该当成一轮空 assistant 发给引擎。
        var turns: [ChatTurn] = messages
            .filter { !$0.streaming && !$0.content.isEmpty }
            .map { ChatTurn(role: $0.role, content: $0.content) }
        var openingTurn = ChatTurn(role: "user", content: trimmed)
        if activeModelSupportsVision {
            // 工具结果里只有路径，历史回放拿不到像素。视觉模型提问时把最近
            // 一组成品重新挂上，它才能接着回答「这张图哪里不对」。
            openingTurn.imageURLs = imageURLs(for: recentGeneratedImagePaths())
        }
        turns.append(openingTurn)

        messages.append(ChatMessage(role: "user", content: trimmed, model: selectedModel, createdAt: Date()))
        messages.append(ChatMessage(role: "assistant", content: "", model: selectedModel, createdAt: Date(), streaming: true))
        streamMessageID = messages[messages.count - 1].id.uuidString
        // 先把「问题」这条写进最近对话：这样切走之后它在列表里就有自己的
        // 一行（标着「生成中」），后台跑完再原地覆盖成完整的一问一答。
        // 不给占位的话，一段刚开始的对话在跑完之前根本点不回来。
        history.save(messages: messages, threadID: threadID)
        threads = history.load()
        generating = true
        generationStatus = "生成中"
        sendGeneration &+= 1
        let generation = sendGeneration
        chatStartupStage = needsStartup ? "模型正在启动中…" : nil
        liveDecodeRate = nil
        generationEndedAt = nil
        decodeMeter.reset()

        // 最大生成 tokens：思考与正文共享的总输出上限。留空时取模型自身上限
        // 并按引擎生效窗口封顶（见 effectiveMaxTokens），4096 那种小默认会让
        // 思考模型一开思考就被 finish_reason=length 硬截断。
        let maxTokensLimit = effectiveMaxTokens
        // 系统提示按这一轮的附件补齐后再定稿：`options` 保持 `let`，各个
        // `@Sendable` 回调里捕获的就是一份不再变化的值，跨隔离域读也安全。
        var systemPrompt = settings.systemPrompt
        if !openingTurn.imageURLs.isEmpty {
            systemPrompt += "\n\n随这条消息附上的是你最近生成的成品；先看图再回答，不要只凭对话里的路径猜。"
        }
        let options = ChatOptions(temperature: settings.temperature,
                                  topP: settings.topP,
                                  maxTokens: maxTokensLimit,
                                  reasoningEffort: settings.effectiveReasoningEffort,
                                  systemPrompt: systemPrompt,
                                  thinkingBudget: EngineStore.shared
                                      .tuning(for: activeEngine)
                                      .effectiveThinkingBudget(for: activeEngine))
        let model = selectedModel
        // 上下文实时估算的基数：本轮提示词（含系统提示）的 token 数。回复结束
        // 后仍会回落到引擎回报的真实 usage。
        let promptTokens = TokenEstimator.promptTokens(
            messages: turns.map { ["role": $0.role, "content": $0.content] })
            + TokenEstimator.estimate(options.systemPrompt)
            + turns.reduce(0) { $0 + $1.imageURLs.count } * TokenEstimator.approximateImageTokens
        livePromptTokens = promptTokens
        // 应用内对话直接连引擎端口，不经过网关；概览页的「最近请求」与会话
        // 计数统一读 GatewayMeter，所以这里也要打点，否则对话页的请求在
        // 概览里永远是 0 条。
        let meterID = GatewayMeter.shared.begin(
            model: model,
            dialect: "chat",
            promptTokens: promptTokens)

        Task {
            if needsStartup {
                let ready = await self.prepareChatSession(generation: generation)
                // 等启动的这段时间被「停止」停掉时，这次打点还没人收尾；
                // 直接 return 会让概览里的请求永远停在「运行中」。
                guard self.sendGeneration == generation else {
                    GatewayMeter.shared.finish(meterID, failed: true)
                    return
                }
                guard ready else {
                    GatewayMeter.shared.finish(meterID, failed: true)
                    let reason = self.controller?.failureMessage ?? "模型未能启动，请查看日志"
                    self.notice = reason
                    self.updateStreamingMessage { message in
                        message.content = "出错：\(reason)"
                        message.streaming = false
                    }
                    self.chatStartupStage = nil
                    self.generating = false
                    self.persistStreamingConversation()
                    return
                }
                self.chatStartupStage = nil
            }
            // 启动等待不算进首字时长，否则「思考了 N 秒」会把引擎启动时间也算上。
            let started = Date()
            // 网关侧的打点也要从这里起算：`begin` 发生在 prepareChatSession
            // 之前，冷启动时那段加载几十 GB 权重的时间不能摊进预填充。
            GatewayMeter.shared.markStarted(meterID, at: started)
            let endpointPort = self.port
            let result = await chatClient.send(port: endpointPort, model: model, turns: turns, options: options,
                onDelta: { piece, at in
                    GatewayMeter.shared.addTokens(meterID, TokenEstimator.fractional(piece), at: at)
                    Task { @MainActor in
                        guard self.sendGeneration == generation else { return }
                        let found = self.updateStreamingMessage { message in
                            if message.firstTokenSeconds == nil {
                                let ttft = at.timeIntervalSince(started)
                                message.firstTokenSeconds = ttft
                                // 正文首字之前的这段时间就是思考阶段；记下来，回答结束后
                                // 折叠的思考块仍能给出真实时长。
                                message.thinkingSeconds = ttft
                            }
                            message.content += piece
                        }
                        guard found else { return }
                        self.recordStreamDelta(piece, at: at)
                    }
                },
                onReasoning: { piece, at in
                    GatewayMeter.shared.addTokens(meterID, TokenEstimator.fractional(piece), at: at)
                    Task { @MainActor in
                        guard self.sendGeneration == generation else { return }
                        let found = self.updateStreamingMessage { message in
                            message.reasoning = (message.reasoning ?? "") + piece
                            if message.content.isEmpty {
                                self.generationStatus = "思考中"
                            }
                        }
                        guard found else { return }
                        // 思考流同样计入本地测速：思考模型的输出大头在 reasoning，
                        // 不计的话思考阶段 liveDecodeRate 一直是 nil，对话页直播条
                        // 只能显示「— tok/s」。
                        self.recordStreamDelta(piece, at: at)
                    }
                },
                onUsage: { usage in
                    GatewayMeter.shared.noteUsage(meterID,
                                                  promptTokens: usage.promptTokens,
                                                  completionTokens: usage.completionTokens,
                                                  cachedPromptTokens: usage.cachedPromptTokens)
                    Task { @MainActor in
                        guard self.sendGeneration == generation else { return }
                        guard self.updateStreamingMessage({ $0.usage = usage }) else { return }
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
                    Task { @MainActor in
                        guard self.sendGeneration == generation else { return }
                        self.generationStatus = status
                    }
                })

            let elapsed = Date().timeIntervalSince(started)
            // 这一轮已经被「停止」收掉（或被新的一轮顶掉）：打点照常收尾，
            // 消息不再动——收尾由 cancelGeneration 做，这里再写一次会把刚标上
            // 的「已停止生成」覆盖成「出错：已取消」。
            let stale = self.sendGeneration != generation
            switch result {
            case .success(let text):
                GatewayMeter.shared.finish(meterID)
                guard !stale else { return }
                self.updateStreamingMessage { message in
                    message.content = text
                    message.seconds = elapsed
                    let finalUsage = chatClient.lastUsage
                    if finalUsage.completionTokens > 0 { message.usage = finalUsage }
                    var tokens = finalUsage.completionTokens
                    if tokens == 0 {
                        // Streaming responses often omit usage; fall back to the
                        // accumulated fraction-weighted estimate so the message
                        // still shows a token count and rate.
                        tokens = Int(decodeMeter.totalTokens.rounded())
                        if tokens > 0 {
                            message.usage = ChatUsage(promptTokens: 0, completionTokens: tokens)
                        }
                    }
                    // 分母取「首分片 → 末分片」，不再把 TTFT / prefill 混进
                    // decode 时长：旧口径让消息下方的总平均天生比直播条低一大截，
                    // 两个数字看起来像彼此矛盾。
                    if tokens > 0, decodeMeter.decodingSeconds > 0 {
                        message.tokensPerSecond = Double(tokens) / decodeMeter.decodingSeconds
                    }
                    // 收尾时把 LIVE 读数落在最终平均上，而不是瞬间清空。
                    if let finalRate = message.tokensPerSecond, finalRate > 0 {
                        liveDecodeRate = finalRate
                        generationEndedAt = Date()
                    }
                }
            case .failure(let error):
                GatewayMeter.shared.finish(meterID, failed: !isCancellation(error))
                guard !stale else { return }
                self.updateStreamingMessage { message in
                    if message.content.isEmpty {
                        message.content = "出错：\(error.message)"
                    }
                }
                if !isCancellation(error) { notice = error.message }
            }
            updateStreamingMessage { $0.streaming = false }
            // 这一轮已经被取消时不要再落盘：`messages` 现在可能已经是另一段
            // 对话，按新的 `threadID` 写回会把那段对话整条覆盖掉。取消路径
            // 自己负责把这一轮存盘。
            guard self.sendGeneration == generation else { return }
            generating = false
            // 读者早就切走了：回答落回它自己的会话，再冒一条通知告诉他落在哪。
            if let finished = self.persistStreamingConversation(),
               let thread = self.threads.first(where: { $0.id == finished }) {
                self.toast(L10n.format("「%@」已在后台生成完成", thread.title),
                           kind: .success)
            }
        }
    }

    /// 当前选中的模型本身。图像参数面板要用它上报的架构来选分辨率预设、
    /// 判断步数是否被蒸馏权重固定；找不到时返回 nil，面板退回通用预设。
    var activeModel: EngineModel? {
        guard !selectedModel.isEmpty else { return nil }
        return engineModels(for: activeEngine).first { $0.id == selectedModel }
    }

    /// 当前选中的模型能不能出图。能力跟着模型走：同一个 mlx-serve 进程里
    /// 对话模型和图像模型可以同时挂着，所以按模型 id 找它自己上报的能力。
    var activeModelSupportsImage: Bool { activeModel?.supportsImage ?? false }

    /// 当前选中的模型能不能出视频。和图像一样按模型 id 查它自己上报的能力。
    var activeModelSupportsVideo: Bool { activeModel?.supportsVideo ?? false }

    /// 当前选中的模型能不能读图（图进文出）。它决定画完的成品要不要以
    /// 像素形式回传给模型；纯文本模型只能拿到路径，硬塞 image_url 会 400。
    var activeModelSupportsVision: Bool { activeModel?.supportsVision ?? false }

    // MARK: - 对话里主动画图

    /// 当前引擎会不会说工具调用协议。只挂在支持工具的引擎上：给别的引擎
    /// 发 `tools` 字段，轻则被忽略，重则 400。
    private var activeEngineSupportsToolUse: Bool {
        activeEngine.capabilities.contains(.toolUse)
    }

    /// 工具可借用的图像模型：当前引擎里报了 image 能力、且没被隐藏的。
    var imageToolModels: [EngineModel] {
        engineModels(for: activeEngine).filter { $0.supportsImage && !$0.hidden && !$0.helper }
    }

    /// 这次画图用哪个图像模型。用户没选过时退回第一个能出图的模型。
    var imageToolModel: EngineModel? {
        let models = imageToolModels
        if !imageToolModelID.isEmpty,
           let chosen = models.first(where: { $0.id == imageToolModelID }) {
            return chosen
        }
        return models.first
    }

    /// 对话页显不显示「画」这个开关：文本模型 + 引擎支持工具 + 引擎里有图像
    /// 模型，三者同时成立才有意义。图像/视频模型本身就是画图链路，不需要工具。
    var supportsImageTool: Bool {
        guard activeEngineSupportsToolUse else { return false }
        guard activeModel?.supportsChat == true else { return false }
        guard !activeModelSupportsImage, !activeModelSupportsVideo else { return false }
        return imageToolModel != nil
    }

    /// 这一轮发送要不要真的把工具挂进请求。
    var imageToolActive: Bool { imageToolEnabled && supportsImageTool }

    /// 当前视频模型是不是 REF2VA：只有它吃参考图/参考视频，且不接受首尾帧。
    var activeModelSupportsVideoReferences: Bool {
        activeModel?.supportsVideoReferences ?? false
    }

    /// 图像模型的发送链路：和对话共用消息列表、历史与打点，只把
    /// `/v1/chat/completions` 换成 `/v1/images/generations`。
    ///
    /// 编排复用 `prepareModelForGateway(allowingGeneration:)`：加载几十 GB 的
    /// 图像权重、把对话模型换出去，都走网关那条已经验证过冷启动的路径。
    private func sendImage(_ prompt: String,
                           attachment: ChatImageAttachment?,
                           options: ImageOptions) {
        let model = selectedModel
        // 蒸馏包的采样表写在权重里：引擎只认那个步数，个别包收到别的值会直接
        // 拒绝。面板已经把滑杆换成固定值，这里再把请求对齐一次，别让旧设置
        // （比如上一次的 20 步）带进一个只跑 8 步的模型。
        let fixedSteps = activeModel.flatMap { ImageModelProfile(model: $0).fixedSteps }
        let requestSteps = fixedSteps ?? options.steps
        // 引擎在没收到 seed 时会用固定的 42：每次一样，用户也没法复现。
        // 这里先落一个具体值，图注里能看见、能复制，也能原样再发一次。
        let seed = options.seed ?? Int.random(in: 1...1_000_000_000)
        var sourcePath: String?
        var sourceBase64: String?
        if let attachment {
            guard let imported = ImageStore.importImage(atPath: attachment.path),
                  let encoded = ImageStore.base64(atPath: imported) else {
                notice = "读取图片失败：\(attachment.name)"
                return
            }
            sourcePath = imported
            sourceBase64 = encoded
        }

        messages.append(ChatMessage(role: "user", content: prompt, model: model,
                                    createdAt: Date(), imagePath: sourcePath))
        let placeholder = ChatMessage(role: "assistant", content: "", model: model,
                                      createdAt: Date(), streaming: true,
                                      imageProgress: "正在准备图像模型")
        messages.append(placeholder)
        streamMessageID = placeholder.id.uuidString
        history.save(messages: messages, threadID: threadID)
        threads = history.load()
        generating = true
        generationStatus = "正在准备图像模型"
        sendGeneration &+= 1
        let generation = sendGeneration
        chatStartupStage = nil
        imageTask?.cancel()
        imageTask = Task { [weak self] in
            guard let self else { return }
            let preparation = await self.prepareModelForGateway(model,
                                                                allowingGeneration: true)
            guard self.sendGeneration == generation else { return }
            if let preparation {
                self.failImage(preparation.message)
                return
            }

            let meterID = GatewayMeter.shared.begin(model: model, dialect: "image",
                                                    promptTokens: 0)
            GatewayMeter.shared.markStarted(meterID, at: Date())
            self.generationStatus = sourceBase64 == nil ? "正在生成图像" : "正在重绘图像"
            let request = ImageGenerationRequest(
                model: model,
                prompt: prompt,
                size: options.size,
                seed: seed,
                steps: requestSteps,
                sourceBase64: sourceBase64,
                strength: sourceBase64 == nil ? nil : options.strength,
                mode: sourceBase64 == nil ? nil : "variation")
            let outcome = await self.imageClient.generate(port: self.port,
                                                          request: request) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.sendGeneration == generation else { return }
                    self.updateStreamingMessage { $0.imageProgress = progress }
                }
            }
            guard self.sendGeneration == generation else {
                GatewayMeter.shared.finish(meterID, failed: true)
                return
            }
            switch outcome {
            case .success(let result):
                GatewayMeter.shared.finish(meterID)
                let path = ImageStore.save(result.png)
                // 图注用引擎实际跑的步数：Turbo 这类蒸馏包会把 20 步请求
                // 改写成自己的 8 步 sigma 表，写请求值会让图注和面板打架。
                let note = self.imageNote(options: options,
                                          attachment: attachment,
                                          path: path,
                                          actualSteps: result.steps)
                self.updateStreamingMessage { message in
                    message.streaming = false
                    message.imageProgress = nil
                    message.seconds = result.seconds
                    message.imagePath = path
                    message.imageSeed = seed
                    message.imageNote = note
                    if path == nil {
                        message.content = "图像已生成，但写入磁盘失败"
                    }
                }
                if let path {
                    // 只登记模型生成的成品；用户底图挂在前面那条 user 消息的
                    // imagePath 上，不会走到这里。历史只保留六段对话，图库自己
                    // 留一份索引，删掉对话也不会把已保存的作品一起抹掉。
                    ImageGalleryStore.shared.record(GalleryImage(
                        path: path,
                        prompt: prompt,
                        model: model,
                        createdAt: Date(),
                        note: note,
                        seed: seed))
                }
                if path == nil { self.notice = "图像已生成，但写入磁盘失败" }
            case .failure(let error):
                GatewayMeter.shared.finish(meterID, failed: true)
                self.failImage(error.message)
            }
            self.imageTask = nil
            self.generating = false
            self.persistStreamingConversation()
        }
    }

    // MARK: - 对话里主动画图（工具调用）

    /// 一次「文本模型主动画图」的完整一轮：模型写分镜 → 换图像模型逐张画 →
    /// 换回对话模型把结果交还给它接着写。
    ///
    /// 整轮共用一条占位消息：正文由最后一轮聊天写，图片按张追加，阶段行显示
    /// 「正在画第 2/3 张 · 去噪 8/20」。引擎换模型的几十秒里，用户看得见在做什么。
    private func sendWithImageTool(_ text: String, imageModel: EngineModel) {
        let chatModel = selectedModel
        let needsStartup = !canChat
        let turnStarted = Date()
        // 能力在发车前定死：画图过程中 activeModel 会跟着换到图像模型，
        // 回来后再查就变成「图像模型能不能读图」了。
        let seesImages = activeModelSupportsVision

        var sent = conversationTurns()
        var openingTurn = ChatTurn(role: "user", content: text)
        if seesImages {
            // 历史里的工具结果只有路径，补上最近一组成品的像素，模型才能
            // 接住「把刚才那张改一下」这类追问。
            openingTurn.imageURLs = imageURLs(for: recentGeneratedImagePaths())
        }
        sent.append(openingTurn)

        messages.append(ChatMessage(role: "user", content: text, model: chatModel, createdAt: Date()))
        messages.append(ChatMessage(role: "assistant", content: "", model: chatModel, createdAt: Date(), streaming: true))
        streamMessageID = messages[messages.count - 1].id.uuidString
        // 先把这一问摆进最近对话：换模型要几十秒，用户中途切走也点得回来。
        history.save(messages: messages, threadID: threadID)
        threads = history.load()
        generating = true
        generationStatus = "生成中"
        sendGeneration &+= 1
        let generation = sendGeneration
        chatStartupStage = needsStartup ? "模型正在启动中…" : nil
        liveDecodeRate = nil
        generationEndedAt = nil
        decodeMeter.reset()

        var options = ChatOptions(temperature: settings.temperature,
                                  topP: settings.topP,
                                  maxTokens: effectiveMaxTokens,
                                  reasoningEffort: settings.effectiveReasoningEffort,
                                  systemPrompt: settings.systemPrompt,
                                  thinkingBudget: EngineStore.shared
                                      .tuning(for: activeEngine)
                                      .effectiveThinkingBudget(for: activeEngine))
        // 工具描述已经写清用途，系统提示只补一句「别光描述、直接画」。
        options.systemPrompt = options.systemPrompt.isEmpty
            ? ImageTool.guidance
            : options.systemPrompt + "\n\n" + ImageTool.guidance
        options.systemPrompt += seesImages
            ? "\n\n画完的成品会作为图片回传给你。先看清画面再回答或继续改，不要只凭提示词猜。"
            : "\n\n你看不到图片本身，只拿得到路径与尺寸。不要编造画面里没确认的细节。"
        let tools = ChatToolSchema(ImageTool.schema(sizeOptions: ImageModelProfile(model: imageModel).presets.map(\.id)))
        let imageOptions = ImageOptionsStore.load()
        // 整组图共用一个 seed：同一条提示词重发能复现，图注里也能看见。
        let seriesSeed = Int.random(in: 1...1_000_000_000)

        imageToolTask?.cancel()
        imageToolTask = Task { [weak self] in
            guard let self else { return }
            defer { self.imageToolTask = nil }

            if needsStartup {
                let ready = await self.prepareChatSession(generation: generation)
                guard self.sendGeneration == generation else { return }
                guard ready else {
                    let reason = self.controller?.failureMessage ?? "模型未能启动，请查看日志"
                    self.finishImageToolTurn(failure: reason, generation: generation)
                    return
                }
                self.chatStartupStage = nil
            }

            // 引擎可能还停在上一轮画图用的图像模型上（用户中途停止过），
            // 直接发聊天请求会 503。先把对话模型换回显存，已经在了就是空操作。
            if let problem = await self.ensureResidentModel(chatModel, stage: { stage in
                self.setToolStage(stage, generation: generation)
            }) {
                self.finishImageToolTurn(failure: problem, generation: generation)
                return
            }

            var transcript = ""
            var usage = ChatUsage()
            var rounds = 0
            var drawn = 0
            self.setToolStage("正在规划画面…", generation: generation)

            // 每一趟都是一次完整的对话请求：模型要么交出画图调用，要么给出最终
            // 回答。画完把「调用 + 结果」追加回上下文，下一趟它就能接着写。
            while true {
                guard self.sendGeneration == generation, !Task.isCancelled else { return }
                // 轮次用完、或这一轮已经画满：最后一趟不带工具，模型只能把
                // 这一组图讲完，不会又画一轮把对话卡在这里。
                let roundTools = (rounds >= ImageTool.maximumRounds || drawn >= ImageTool.maximumImagesPerTurn)
                    ? ChatToolSchema() : tools
                let started = Date()
                let promptTokens = TokenEstimator.promptTokens(
                    messages: sent.map { ["role": $0.role, "content": $0.content] })
                    + TokenEstimator.estimate(options.systemPrompt)
                    + sent.reduce(0) { $0 + $1.imageURLs.count } * TokenEstimator.approximateImageTokens
                self.livePromptTokens = promptTokens
                let meterID = GatewayMeter.shared.begin(model: chatModel, dialect: "chat",
                                                        promptTokens: promptTokens)
                GatewayMeter.shared.markStarted(meterID, at: started)

                let result = await self.chatClient.send(
                    port: self.port,
                    model: chatModel,
                    turns: sent,
                    options: options,
                    tools: roundTools,
                    onDelta: { piece, at in
                        GatewayMeter.shared.addTokens(meterID, TokenEstimator.fractional(piece), at: at)
                        Task { @MainActor in
                            guard self.sendGeneration == generation else { return }
                            let found = self.updateStreamingMessage { message in
                                if message.firstTokenSeconds == nil {
                                    let ttft = at.timeIntervalSince(started)
                                    message.firstTokenSeconds = ttft
                                    message.thinkingSeconds = ttft
                                }
                                // 模型已经开口了，阶段行让位给正文。
                                message.toolStage = nil
                                message.content += piece
                            }
                            guard found else { return }
                            self.recordStreamDelta(piece, at: at)
                        }
                    },
                    onReasoning: { piece, at in
                        GatewayMeter.shared.addTokens(meterID, TokenEstimator.fractional(piece), at: at)
                        Task { @MainActor in
                            guard self.sendGeneration == generation else { return }
                            let found = self.updateStreamingMessage { message in
                                message.reasoning = (message.reasoning ?? "") + piece
                                if message.content.isEmpty { self.generationStatus = "思考中" }
                            }
                            guard found else { return }
                            self.recordStreamDelta(piece, at: at)
                        }
                    },
                    onUsage: { reported in
                        GatewayMeter.shared.noteUsage(meterID,
                                                      promptTokens: reported.promptTokens,
                                                      completionTokens: reported.completionTokens,
                                                      cachedPromptTokens: reported.cachedPromptTokens)
                    },
                    onStatus: { status in
                        Task { @MainActor in
                            guard self.sendGeneration == generation else { return }
                            self.generationStatus = status
                        }
                    },
                    onToolCall: { piece, at in
                        // 工具参数也是模型真写出来的字，和网关的统计口径一致。
                        GatewayMeter.shared.addTokens(meterID, TokenEstimator.fractional(piece), at: at)
                        Task { @MainActor in
                            guard self.sendGeneration == generation else { return }
                            self.recordStreamDelta(piece, at: at)
                        }
                    })

                // 收尾先看代数：被「停止」或被新的一轮顶掉时，打点收掉即可，
                // 消息由 cancelGeneration 负责，这里再写一次会盖掉「已停止生成」。
                let stale = self.sendGeneration != generation
                var answer = ""
                switch result {
                case .failure(let error):
                    GatewayMeter.shared.finish(meterID, failed: !isCancellation(error))
                    if stale || isCancellation(error) { return }
                    self.finishImageToolTurn(failure: error.message, generation: generation)
                    return
                case .success(let text):
                    GatewayMeter.shared.finish(meterID)
                    if stale { return }
                    answer = text
                    transcript += text
                }

                let reported = self.chatClient.lastUsage
                usage.promptTokens += reported.promptTokens
                usage.completionTokens += reported.completionTokens
                usage.cachedPromptTokens += reported.cachedPromptTokens
                if let reasoning = reported.reasoningTokens {
                    usage.reasoningTokens = (usage.reasoningTokens ?? 0) + reasoning
                }
                usage.finishReason = reported.finishReason

                let calls = roundTools.isEmpty
                    ? []
                    : self.chatClient.lastToolCalls.filter { $0.name == ImageTool.name }
                guard !calls.isEmpty else {
                    self.finishImageToolTurn(content: transcript, usage: usage,
                                             generation: generation, started: turnStarted)
                    return
                }

                sent.append(ChatTurn(role: "assistant", content: answer, toolCalls: calls))
                var results: [ChatToolResult] = []
                var drawnPaths: [String] = []
                for call in calls {
                    guard self.sendGeneration == generation, !Task.isCancelled else { return }
                    let outcome = await self.runImageTool(call,
                                                          imageModel: imageModel,
                                                          chatModel: chatModel,
                                                          generation: generation,
                                                          allowance: ImageTool.maximumImagesPerTurn - drawn,
                                                          seed: seriesSeed,
                                                          options: imageOptions)
                    drawn += outcome.drawn
                    results.append(outcome.result)
                    drawnPaths.append(contentsOf: outcome.imagePaths)
                    sent.append(ChatTurn(role: "tool", content: outcome.result.content,
                                         toolCallID: outcome.result.callID))
                }
                self.recordToolExchange(calls: calls, results: results, generation: generation)
                rounds += 1
                // 视觉模型：把刚落盘的成品按生成顺序回传，让它在同一轮里
                // 真正「看见」自己画了什么，再决定补画还是收尾。这是一条
                // 只存在于内存里的 user 轮，不写进 messages，也不落盘。
                if seesImages, !drawnPaths.isEmpty {
                    let urls = self.imageURLs(for: drawnPaths)
                    if !urls.isEmpty {
                        self.setToolStage("正在看刚画的图…", generation: generation)
                        sent.append(ChatTurn(role: "user",
                                             content: self.visionFeedback(
                                                count: urls.count,
                                                canDrawMore: rounds < ImageTool.maximumRounds
                                                    && drawn < ImageTool.maximumImagesPerTurn),
                                             imageURLs: urls))
                    }
                }
                // 常驻时没有「换回」这一步，阶段行已经在 runImageTool 里清掉。
                if !self.imageToolResident {
                    self.setToolStage("正在换回对话模型…", generation: generation)
                }
            }
        }
    }

    private struct ImageToolOutcome {
        let result: ChatToolResult
        let drawn: Int
        /// 本轮成功落盘的图片，按生成顺序。视觉模型要把它们回传成像素。
        var imagePaths: [String] = []
    }

    /// 执行一次画图调用：把图像模型换进来、逐张画完、再换回对话模型。
    /// 结果无论成败都写一段 JSON 回给模型——失败也要让它知道为什么，
    /// 它才能向用户解释或者少画两张。
    private func runImageTool(_ call: ChatToolCall,
                              imageModel: EngineModel,
                              chatModel: String,
                              generation: Int,
                              allowance: Int,
                              seed: Int,
                              options: ImageOptions) async -> ImageToolOutcome {
        let parsed: ImageTool.Call
        switch ImageTool.parse(call) {
        case .success(let value):
            parsed = value
        case .failure(let error):
            return ImageToolOutcome(result: ChatToolResult(callID: call.id,
                                                           content: ImageTool.failure(error.message)),
                                    drawn: 0, imagePaths: [])
        }
        guard allowance > 0 else {
            return ImageToolOutcome(result: ChatToolResult(
                callID: call.id,
                content: ImageTool.failure("这一轮已经画满 \(ImageTool.maximumImagesPerTurn) 张了，先把这组图交给用户。")),
                                    drawn: 0, imagePaths: [])
        }
        let prompts = parsed.prompts.count > allowance
            ? Array(parsed.prompts.prefix(allowance))
            : parsed.prompts

        let profile = ImageModelProfile(model: imageModel)
        // 蒸馏包只认自己的采样表，面板也把步数固定住了；工具沿用同一套规则。
        let steps = profile.fixedSteps ?? options.steps
        let size = Self.sanitizedCanvas(parsed.size, profile: profile, fallback: options.size)

        setToolStage("正在准备图像模型 \(imageModel.shortName)…", generation: generation)
        if let error = await ensureResidentModel(imageModel.id,
                                                 stage: { [weak self] stage in
                                                     self?.setToolStage(stage, generation: generation)
                                                 },
                                                 alongside: imageToolResident) {
            _ = await ensureResidentModel(chatModel, stage: { _ in })
            return ImageToolOutcome(result: ChatToolResult(
                callID: call.id,
                content: ImageTool.failure("图像模型没能加载：\(error)")),
                                    drawn: 0, imagePaths: [])
        }

        var images: [(path: String, note: String)] = []
        var failureMessage: String?
        for (index, prompt) in prompts.enumerated() {
            if Task.isCancelled || sendGeneration != generation { break }
            setToolStage("正在画第 \(index + 1)/\(prompts.count) 张…", generation: generation)
            let meterID = GatewayMeter.shared.begin(model: imageModel.id, dialect: "image",
                                                    promptTokens: TokenEstimator.estimate(prompt))
            GatewayMeter.shared.markStarted(meterID)
            let request = ImageGenerationRequest(model: imageModel.id,
                                                 prompt: prompt,
                                                 size: size,
                                                 seed: seed,
                                                 steps: steps,
                                                 sourceBase64: nil,
                                                 strength: nil,
                                                 mode: nil)
            let outcome = await imageClient.generate(port: port, request: request) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.sendGeneration == generation else { return }
                    self.setToolStage("正在画第 \(index + 1)/\(prompts.count) 张 · \(progress)",
                                      generation: generation)
                }
            }
            switch outcome {
            case .success(let result):
                GatewayMeter.shared.finish(meterID)
                guard let path = ImageStore.save(result.png) else {
                    failureMessage = "图片已经生成，但写入磁盘失败"
                    continue
                }
                let requestOptions = ImageOptions(size: size, steps: steps, seed: seed,
                                                  strength: options.strength)
                let note = imageNote(options: requestOptions,
                                     attachment: nil,
                                     path: path,
                                     actualSteps: result.steps)
                images.append((path, note))
                appendToolImage(path: path, note: note, seed: seed, generation: generation)
                ImageGalleryStore.shared.record(GalleryImage(
                    path: path,
                    prompt: prompt,
                    model: imageModel.id,
                    createdAt: Date(),
                    note: note,
                    seed: seed))
            case .failure(let error):
                // ImageClientError 不是 ChatError，取消与否看任务本身。
                let cancelled = Task.isCancelled
                GatewayMeter.shared.finish(meterID, failed: !cancelled)
                failureMessage = error.message
                if cancelled { break }
            }
        }

        // 允许常驻且对话模型还在显存里：图像模型留着，下一轮画图直接复用；
        // 否则（设置关掉、或引擎为了腾内存把对话模型挤掉了）必须换回来——
        // 不换的话下一趟聊天要等引擎重新加载，用户看到的是「模型正在启动」。
        if imageToolResident,
           let controller,
           gatewayModelIsResident(chatModel, in: controller) {
            setToolStage(nil, generation: generation)
        } else {
            setToolStage("正在换回对话模型…", generation: generation)
            _ = await ensureResidentModel(chatModel, stage: { _ in })
            setToolStage(nil, generation: generation)
        }

        guard !images.isEmpty else {
            return ImageToolOutcome(result: ChatToolResult(
                callID: call.id,
                content: ImageTool.failure(failureMessage ?? "没有画出图片")),
                                    drawn: 0, imagePaths: [])
        }
        var content = ImageTool.result(images: images, seed: seed, size: size)
        if let failureMessage {
            content += "（有 \(prompts.count - images.count) 张失败：\(failureMessage)）"
        }
        return ImageToolOutcome(result: ChatToolResult(callID: call.id, content: content),
                                drawn: images.count,
                                imagePaths: images.map(\.path))
    }

    /// 把某个模型换进显存，但不改 `selectedModel`：工具只是借用图像模型，
    /// 对话的模式和模型选择都不该跟着变（那会把输入框切到「提示词 → 图像」）。
    ///
    /// `alongside` 为真时只加载、不卸载已经常驻的模型：图像模型进来时对话模型
    /// 还要接着把这一轮写完，换掉它就得再花几十秒加载回来。
    private func ensureResidentModel(_ target: String,
                                     stage: @escaping (String) -> Void,
                                     alongside: Bool = false) async -> String? {
        guard let controller else { return "推理引擎未就绪" }
        if gatewayModelIsResident(target, in: controller) { return nil }
        if !controller.isRunning {
            await controller.start()
        }
        let outcome = alongside
            ? await controller.loadModelKeepingResident(target, stage: stage)
            : await controller.switchModel(target, stage: stage)
        switch outcome {
        case .ready:
            return nil
        case .failed(let message):
            return message
        }
    }

    /// 组装回放给引擎的上下文。画过图的 assistant 轮要带着 tool_calls，
    /// 紧接着按 call_id 补 tool 结果——只留最终文字的话，模型会忘记自己画了
    /// 什么，用户追问「第二张换个光线」时它接不上。
    private func conversationTurns() -> [ChatTurn] {
        var turns: [ChatTurn] = []
        for message in messages where !message.streaming {
            if !message.toolCalls.isEmpty {
                let answered = Set(message.toolResults.map(\.callID))
                if message.toolCalls.allSatisfy({ answered.contains($0.id) }) {
                    turns.append(ChatTurn(role: "assistant", content: message.content,
                                          toolCalls: message.toolCalls))
                    for result in message.toolResults {
                        turns.append(ChatTurn(role: "tool", content: result.content,
                                              toolCallID: result.callID))
                    }
                    continue
                }
            }
            guard !message.content.isEmpty else { continue }
            turns.append(ChatTurn(role: message.role, content: message.content))
        }
        return turns
    }

    /// 模型可能忽略枚举自己编尺寸：解析成宽高后用这一族的规则校一遍，
    /// 不合格就退回用户当前设置；连用户设置都不适用时（换了图像模型家族），
    /// 取这一族的第一个预设，而不是让引擎去拒绝一个它画不了的长宽比。
    private static func sanitizedCanvas(_ raw: String?,
                                        profile: ImageModelProfile,
                                        fallback: String) -> String {
        func acceptable(_ value: String) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let parts = trimmed.split(separator: "x")
            guard parts.count == 2,
                  let width = Int(parts[0]),
                  let height = Int(parts[1]),
                  profile.isValidCanvas(width: width, height: height) else { return false }
            return profile.allowsCustomCanvas || profile.presets.contains { $0.id == trimmed }
        }
        if let raw, acceptable(raw) { return raw.lowercased() }
        if acceptable(fallback) { return fallback.lowercased() }
        return profile.presets.first?.id ?? fallback
    }

    /// 阶段行（「正在画第 2/3 张 · 去噪 8/20」）写进占位消息，代替正文位置。
    private func setToolStage(_ stage: String?, generation: Int) {
        guard sendGeneration == generation else { return }
        updateStreamingMessage { $0.toolStage = stage }
    }

    /// 一张图画完就挂到消息上：用户不用等整组画完才看到第一张。
    private func appendToolImage(path: String, note: String, seed: Int, generation: Int) {
        guard sendGeneration == generation else { return }
        updateStreamingMessage { message in
            message.imagePaths.append(path)
            if message.imagePath == nil { message.imagePath = path }
            if message.imageNote == nil { message.imageNote = note }
            message.imageSeed = seed
        }
    }

    /// 最近一组成品。只回看紧邻的几条消息：再往前追，用户已经在聊别的了，
    /// 把旧图塞进请求既费上下文，也容易让模型答非所问。
    private func recentGeneratedImagePaths(within distance: Int = 6) -> [String] {
        for message in messages.suffix(distance).reversed() where message.role == "assistant" {
            if !message.imagePaths.isEmpty { return message.imagePaths }
            if let path = message.imagePath { return [path] }
        }
        return []
    }

    /// 落盘路径 → OpenAI 的 data URL。读不到/解码失败的直接跳过，不让一张
    /// 坏图把整轮对话卡死。
    private func imageURLs(for paths: [String]) -> [String] {
        paths.compactMap { ImageStore.chatImageURL(atPath: $0) }
    }

    /// 画完后紧跟着的一条「用户」消息：把成品递到模型眼前，并明确告诉它
    /// 该看什么、还能不能继续画。只放在本轮的内存上下文里，不落盘。
    private func visionFeedback(count: Int, canDrawMore: Bool) -> String {
        var text = "你刚画好了这 \(count) 张图，下面按生成顺序附上成品。"
        text += "先逐张看清画面：主体、构图、文字、手部这些细节，是否达到你在提示词里写的要求。"
        text += "描述时只说你真正看到的，不要照着提示词编。"
        text += canDrawMore
            ? "达到要求就用一两句话向用户交代；需要改就继续调用 \(ImageTool.name) 补画，只补要改的，别重复画已经满意的。"
            : "这一轮的画图次数已经用完，直接根据看到的画面收尾；还需要改的地方，用文字告诉用户。"
        return text
    }

    /// 调用与结果留在消息里，下一轮（甚至重启后）还要按原样回放给引擎。
    private func recordToolExchange(calls: [ChatToolCall],
                                    results: [ChatToolResult],
                                    generation: Int) {
        guard sendGeneration == generation else { return }
        updateStreamingMessage { message in
            message.toolCalls.append(contentsOf: calls)
            message.toolResults.append(contentsOf: results)
        }
    }

    /// 这一轮画完：压上累计用量、收掉「生成中」，再落盘。
    private func finishImageToolTurn(content: String,
                                     usage: ChatUsage,
                                     generation: Int,
                                     started: Date) {
        guard sendGeneration == generation else { return }
        let elapsed = Date().timeIntervalSince(started)
        updateStreamingMessage { message in
            if !content.isEmpty { message.content = content }
            message.streaming = false
            message.toolStage = nil
            message.seconds = elapsed
            if usage.completionTokens > 0 {
                message.usage = usage
                if decodeMeter.decodingSeconds > 0 {
                    message.tokensPerSecond = Double(usage.completionTokens) / decodeMeter.decodingSeconds
                }
            } else {
                // 流式响应常省略 usage，退回按分片估的数字，消息右下角不至于是空的。
                let tokens = Int(decodeMeter.totalTokens.rounded())
                if tokens > 0 {
                    message.usage = ChatUsage(promptTokens: 0, completionTokens: tokens)
                    if decodeMeter.decodingSeconds > 0 {
                        message.tokensPerSecond = Double(tokens) / decodeMeter.decodingSeconds
                    }
                }
            }
            if let rate = message.tokensPerSecond, rate > 0 {
                liveDecodeRate = rate
                generationEndedAt = Date()
            }
        }
        chatStartupStage = nil
        generationStatus = "完成"
        generating = false
        persistStreamingConversation()
    }

    /// 失败收尾：和文本链路同一口径，气泡里写原因、顶部再冒一条。
    private func finishImageToolTurn(failure: String, generation: Int) {
        guard sendGeneration == generation else { return }
        updateStreamingMessage { message in
            message.streaming = false
            message.toolStage = nil
            if message.content.isEmpty { message.content = "出错：\(failure)" }
        }
        notice = failure
        chatStartupStage = nil
        generationStatus = "失败"
        generating = false
        persistStreamingConversation()
    }

    /// 视频模型的发送链路：对话、历史、打点都复用，只把端点换成
    /// `/v1/video/generations`。服务端回的是 rgb8 原始帧，VideoClient 在客户端
    /// 封装成 MP4 后落盘，消息里只留路径。
    private func sendVideo(_ prompt: String,
                           attachment: ChatImageAttachment?,
                           lastFrame: ChatImageAttachment?,
                           referenceImages: [ChatImageAttachment],
                           referenceClips: [VideoReferenceClip],
                           options: VideoOptions) {
        let model = selectedModel
        let seed = options.seed ?? Int.random(in: 1...1_000_000_000)
        var sourcePath: String?
        var sourceBase64: String?
        if let attachment {
            guard let imported = ImageStore.importImage(atPath: attachment.path),
                  let encoded = ImageStore.base64(atPath: imported) else {
                notice = "读取首帧图片失败：\(attachment.name)"
                return
            }
            sourcePath = imported
            sourceBase64 = encoded
        }
        var lastFramePath: String?
        var lastFrameBase64: String?
        if let lastFrame {
            guard let imported = ImageStore.importImage(atPath: lastFrame.path),
                  let encoded = ImageStore.base64(atPath: imported) else {
                notice = "读取尾帧图片失败：\(lastFrame.name)"
                return
            }
            lastFramePath = imported
            lastFrameBase64 = encoded
        }
        // REF2VA 的参考图先拷进作品目录，base64 留到 Task 里再读：一次挑
        // 九张相机原图，主线程不能停在文件读取上。
        var referenceImagePaths: [String] = []
        for item in referenceImages {
            guard let imported = ImageStore.importImage(atPath: item.path) else {
                notice = "读取参考图失败：\(item.name)"
                return
            }
            referenceImagePaths.append(imported)
        }
        let referenceClipPaths = referenceClips.map(\.path)
        let usesReferences = !referenceImagePaths.isEmpty || !referenceClipPaths.isEmpty

        messages.append(ChatMessage(role: "user", content: prompt, model: model,
                                    createdAt: Date(),
                                    imagePath: usesReferences ? nil : sourcePath,
                                    videoLastFramePath: usesReferences ? nil : lastFramePath,
                                    videoReferenceImagePaths:
                                        referenceImagePaths.isEmpty ? nil : referenceImagePaths,
                                    videoReferenceClipPaths:
                                        referenceClipPaths.isEmpty ? nil : referenceClipPaths))
        let placeholder = ChatMessage(role: "assistant", content: "", model: model,
                                      createdAt: Date(), streaming: true,
                                      videoProgress: "正在准备视频模型")
        messages.append(placeholder)
        streamMessageID = placeholder.id.uuidString
        history.save(messages: messages, threadID: threadID)
        threads = history.load()
        generating = true
        generationStatus = "正在准备视频模型"
        sendGeneration &+= 1
        let generation = sendGeneration
        chatStartupStage = nil
        videoTask?.cancel()
        videoTask = Task { [weak self] in
            guard let self else { return }
            // 参考素材先读完再加载模型：文件有问题就早点报错，不必让用户等
            // 几十 GB 的权重加载完才发现参考视频读不了。
            var referenceImagesBase64: [String] = []
            let referencePixel = options.referenceDetail == .max
                ? 1280
                : max(options.dimensions.width, options.dimensions.height)
            for path in referenceImagePaths {
                guard self.sendGeneration == generation else { return }
                guard let encoded = ImageStore.jpegBase64(atPath: path,
                                                          maximumPixel: CGFloat(referencePixel)) else {
                    self.failVideo("读取参考图失败：\((path as NSString).lastPathComponent)")
                    return
                }
                referenceImagesBase64.append(encoded)
            }
            var referencePayloads: [VideoReferencePayload] = []
            if !referenceClipPaths.isEmpty {
                let canvas = options.dimensions
                let maximum = options.referenceDetail == .max
                    ? CGSize(width: 1280, height: 1280)
                    : CGSize(width: canvas.width, height: canvas.height)
                for (index, path) in referenceClipPaths.enumerated() {
                    guard self.sendGeneration == generation else { return }
                    let label = "正在读取参考视频 \(index + 1)/\(referenceClipPaths.count)"
                    self.generationStatus = label
                    self.updateStreamingMessage { $0.videoProgress = label }
                    do {
                        let frames = try await VideoReferenceExtractor.frames(
                            url: URL(fileURLWithPath: path),
                            maximumSize: maximum) { [weak self] text in
                                Task { @MainActor in
                                    guard let self, self.sendGeneration == generation else { return }
                                    self.updateStreamingMessage { $0.videoProgress = text }
                                }
                            }
                        referencePayloads.append(VideoReferencePayload(framesBase64: frames))
                    } catch is CancellationError {
                        return
                    } catch {
                        self.failVideo(error.localizedDescription)
                        return
                    }
                }
            }
            let preparation = await self.prepareModelForGateway(model,
                                                                allowingGeneration: true)
            guard self.sendGeneration == generation else { return }
            if let preparation {
                self.failVideo(preparation.message)
                return
            }

            let meterID = GatewayMeter.shared.begin(model: model, dialect: "video",
                                                    promptTokens: 0)
            GatewayMeter.shared.markStarted(meterID, at: Date())
            if usesReferences {
                self.generationStatus = "正在生成视频（\(referenceImagesBase64.count) 张参考图 · \(referencePayloads.count) 段参考视频）"
            } else {
                switch (sourceBase64, lastFrameBase64) {
                case (nil, nil): self.generationStatus = "正在生成视频"
                case (.some, .some): self.generationStatus = "正在生成视频（首尾帧）"
                case (.some, nil): self.generationStatus = "正在生成视频（首帧）"
                case (nil, .some): self.generationStatus = "正在生成视频（尾帧）"
                }
            }
            let dimensions = options.dimensions
            let request = VideoGenerationRequest(
                model: model,
                prompt: prompt,
                size: "\(dimensions.width)x\(dimensions.height)",
                frames: options.frames,
                steps: options.steps,
                seed: seed,
                firstFrameBase64: usesReferences ? nil : sourceBase64,
                lastFrameBase64: usesReferences ? nil : lastFrameBase64,
                referenceImagesBase64: referenceImagesBase64,
                referenceVideos: referencePayloads,
                referenceDetail: options.referenceDetail)
            let outcome = await self.videoClient.generate(port: self.port,
                                                          request: request) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.sendGeneration == generation else { return }
                    self.updateStreamingMessage { $0.videoProgress = progress }
                }
            }
            guard self.sendGeneration == generation else {
                GatewayMeter.shared.finish(meterID, failed: true)
                return
            }
            switch outcome {
            case .success(let result):
                GatewayMeter.shared.finish(meterID)
                let mp4 = result.mp4
                let path = await Task.detached(priority: .userInitiated) {
                    VideoStore.save(mp4)
                }.value
                guard self.sendGeneration == generation else { return }
                let note = self.videoNote(options: options, source: sourcePath,
                                          lastFrame: lastFramePath,
                                          referenceImages: referenceImagePaths.count,
                                          referenceClips: referencePayloads.count,
                                          result: result, seed: seed)
                self.updateStreamingMessage { message in
                    message.streaming = false
                    message.videoProgress = nil
                    message.seconds = result.seconds
                    message.videoPath = path
                    message.videoSourcePath = sourcePath
                    message.videoNote = note
                    if path == nil {
                        message.content = "视频已生成，但写入磁盘失败"
                    }
                }
                if path == nil {
                    self.notice = "视频已生成，但写入磁盘失败"
                } else if let path {
                    // 和图片一样单独记一份：历史只留最近六段，删对话也不该丢作品。
                    VideoGalleryStore.shared.record(GalleryVideo(path: path,
                                                                 prompt: prompt,
                                                                 model: model,
                                                                 createdAt: Date(),
                                                                 note: note,
                                                                 seed: seed))
                }
            case .failure(let error):
                GatewayMeter.shared.finish(meterID, failed: true)
                self.failVideo(error.message)
            }
            self.videoTask = nil
            self.generating = false
            self.persistStreamingConversation()
        }
    }

    /// 视频链路的失败收尾。显存不够和帧数过大是最常见的两类，直接说怎么改。
    private func failVideo(_ raw: String) {
        let message = Self.friendlyVideoError(raw)
        updateStreamingMessage { item in
            item.streaming = false
            item.videoProgress = nil
            if item.content.isEmpty { item.content = "出错：\(message)" }
        }
        notice = message
        chatStartupStage = nil
        videoTask = nil
        generating = false
        persistStreamingConversation()
    }

    private static func friendlyVideoError(_ raw: String) -> String {
        let lowered = raw.lowercased()
        if lowered.contains("does not support references")
            || lowered.contains("declares no 'ref2va'")
            || lowered.contains("ref2va pack cannot serve") {
            return "这个视频模型不支持参考素材。参考图/参考视频需要 REF2VA 视频包；首尾帧请换用 FL2VA/LTX 包。"
        }
        if lowered.contains("attach at least one image or video") {
            return "REF2VA 必须至少附一张参考图或一段参考视频。"
        }
        if lowered.contains("too many reference") || lowered.contains("too many references") {
            return "参考素材超出上限：最多 9 张参考图、3 段参考视频，合计 12 个。"
        }
        if lowered.contains("60 mib") || lowered.contains("upload budget") {
            return "参考素材太大，超过 60 MB 上传上限。减少参考图数量，或把参考细节改成「匹配画布」。"
        }
        if lowered.contains("at least 5 frames") || lowered.contains("needs at least 5") {
            return "参考视频太短：至少需要 5 帧（约 0.2 秒）。换一段更长的视频。"
        }
        if lowered.contains("ref_videos") || lowered.contains("ref_images")
            || lowered.contains("ref_image_size") {
            return "参考素材没有被接受（\(raw)）。参考图请用 PNG/JPEG，参考视频至少 5 帧。"
        }
        if lowered.contains("out of memory") || lowered.contains("oom")
            || lowered.contains("insufficient memory") || lowered.contains("memory") {
            return "显存不够生成这段视频。把分辨率或帧数调小一些再试（例如 512×384、49 帧）。"
        }
        if lowered.contains("vae_encoder") || lowered.contains("last frame conditioning") {
            return "这个视频模型没有带尾帧条件需要的 VAE 编码器：去掉尾帧，只留首帧或纯文字再试。"
        }
        if lowered.contains("last_frame") || lowered.contains("last frame") {
            if lowered.contains("9 frames") || lowered.contains("at least 9") {
                return "尾帧要求至少 9 帧：把帧数调到 9 以上（例如 49 帧）再试。"
            }
            return "尾帧图片没有被接受：换一张 PNG/JPEG，或去掉尾帧重试。"
        }
        if lowered.contains("first_frame") || lowered.contains("first frame") {
            return "首帧图片没有被接受：换一张 PNG/JPEG，或去掉附件改为纯文字生成。"
        }
        if lowered.contains("num_frames") || lowered.contains("too many frames") {
            return "帧数超出这个模型的范围：把帧数调小后重试。"
        }
        if lowered.contains("does not load") || lowered.contains("failed to load") {
            return "这个视频模型加载失败（\(raw)）。请确认权重完整、显存够用后重试。"
        }
        return raw
    }

    private func videoNote(options: VideoOptions,
                           source: String?,
                           lastFrame: String?,
                           referenceImages: Int = 0,
                           referenceClips: Int = 0,
                           result: VideoGenerationResult,
                           seed: Int) -> String {
        var parts = ["\(result.width)×\(result.height)",
                     "\(result.frames) 帧",
                     "\(result.fps)fps",
                     "\(options.steps) 步"]
        if source != nil, lastFrame != nil {
            parts.append("首尾帧生视频")
        } else if source != nil {
            parts.append("首帧生视频")
        } else if lastFrame != nil {
            parts.append("尾帧生视频")
        }
        var references: [String] = []
        if referenceImages > 0 { references.append("\(referenceImages) 张参考图") }
        if referenceClips > 0 { references.append("\(referenceClips) 段参考视频") }
        if !references.isEmpty {
            parts.append(references.joined(separator: " + "))
        }
        parts.append("seed \(seed)")
        return parts.joined(separator: " · ")
    }

    /// 图像链路的失败收尾：气泡里写原因，顶部再冒一条，和对话的错误口径一致。
    private func failImage(_ raw: String) {
        let message = Self.friendlyImageError(raw)
        updateStreamingMessage { item in
            item.streaming = false
            item.imageProgress = nil
            if item.content.isEmpty { item.content = "出错：\(message)" }
        }
        notice = message
        chatStartupStage = nil
        imageTask = nil
        generating = false
        persistStreamingConversation()
    }

    /// 把引擎的原始报错翻译成能照着做的建议。本地 Qwen 转换包没带视觉塔，
    /// 指令编辑必然 400，这不算用户操作错。
    private static func friendlyImageError(_ raw: String) -> String {
        let lowered = raw.lowercased()
        if lowered.contains("vision tower") || lowered.contains("re-convert") {
            return "当前图像模型缺少视觉塔，不能按指令改图。去掉附件、只发提示词可以重绘，或换用带视觉塔的转换包。"
        }
        if lowered.contains("does not load") {
            return "这个图像模型加载失败（\(raw)）。请确认权重完整后重试。"
        }
        return raw
    }

    private func imageNote(options: ImageOptions,
                           attachment: ChatImageAttachment?,
                           path: String?,
                           actualSteps: Int? = nil) -> String {
        var parts: [String] = []
        if let path, let pixels = ImageStore.pixelSize(atPath: path) {
            parts.append("\(Int(pixels.width))×\(Int(pixels.height))")
        } else {
            parts.append(options.size.replacingOccurrences(of: "x", with: "×"))
        }
        if let actualSteps, actualSteps > 0, actualSteps != options.steps {
            parts.append("\(actualSteps) 步（引擎实际）")
        } else {
            parts.append("\(options.steps) 步")
        }
        if attachment != nil {
            parts.append("重绘 \(Int((options.strength * 100).rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    /// 把刚跑完的这一轮落盘：切到后台的那一轮按它自己的 `threadID` 写回历史，
    /// 还在前台的就照旧写当前会话。
    /// - Returns: 写回的是后台那一段时返回它的 `threadID`，前台返回 nil。
    @discardableResult
    private func persistStreamingConversation() -> String? {
        if let running = background {
            background = nil
            history.save(messages: running.messages, threadID: running.threadID)
            threads = history.load()
            return running.threadID
        }
        conversation.save(messages)
        history.save(messages: messages, threadID: threadID)
        threads = history.load()
        return nil
    }

    /// 与网关共用 Kit 里的同一套估算，避免两个页面对同一段文本给出不同 token 数。
    static func estimateTokens(_ text: String) -> Int {
        TokenEstimator.estimate(text)
    }

    private func isCancellation(_ error: ChatError) -> Bool {
        error.message.localizedCaseInsensitiveContains("cancel")
            || error.message.localizedCaseInsensitiveContains("取消")
    }

    func cancelGeneration() {
        sendGeneration &+= 1
        chatStartupStage = nil
        chatClient.cancel()
        imageTask?.cancel()
        imageTask = nil
        videoTask?.cancel()
        videoTask = nil
        imageToolTask?.cancel()
        imageToolTask = nil
        generating = false
        generationStatus = "已取消"
        settleStreamingMessage()
        // 这一轮的分片还可能在路上：断开落点之后迟到的分片找不到消息，
        // 不会写进紧接着发出的下一轮。
        streamMessageID = ""
        // 后台那一轮也按它自己的会话收尾：点「停止」不该让它的半截回答消失。
        persistStreamingConversation()
    }

    /// 把还在流式的那条收掉：保留已经吐出的正文与思考，正文为空也不删，
    /// 由消息行显示「已停止生成」。前台与后台都认。
    private func settleStreamingMessage() {
        if var running = background {
            settleStreamingOnStop(&running.messages)
            background = running
            return
        }
        settleStreamingOnStop(&messages)
    }

    /// Drop the trailing answer and ask again with the same prompt.
    func regenerate() {
        guard !generating else { return }
        guard let lastUser = messages.last(where: { $0.role == "user" }) else { return }
        while let last = messages.last, last.role == "assistant" { messages.removeLast() }
        if messages.last?.role == "user" { messages.removeLast() }
        // 图生图那一轮：底图是用户消息的一部分，重来一次也要带着它。
        let attachment = lastUser.imagePath.map { path in
            ChatImageAttachment(path: path,
                                name: (path as NSString).lastPathComponent,
                                pixelSize: ImageStore.pixelSize(atPath: path))
        }
        send(lastUser.content, attachment: attachment)
    }

    /// 切走会话：把正在生成的那一段连人带消息搬到后台，别中断、也别写串。
    ///
    /// 以前这里直接 `cancelGeneration()`，而它只写 `conversation.json`——
    /// 「最近对话」里留着的还是上一轮的快照。于是「回复到一半切去概览 /
    /// 从列表点回同一段对话」看到的就是：刚才那条回答不见了。现在生成继续
    /// 在后台跑完，跑完按它自己的 `threadID` 落回历史。
    private func detachGenerationForThreadSwitch() {
        guard generating, background == nil else { return }
        background = BackgroundGeneration(threadID: threadID, messages: messages)
    }

    func newConversation() {
        detachGenerationForThreadSwitch()
        messages.removeAll()
        conversation.clear()
        threadID = Self.newThreadID()
    }

    func openThread(_ thread: ChatThread) {
        // 点回正在生成的那一段：把后台那份接回前台，后面的分片继续往这里写。
        if let running = background, running.threadID == thread.id {
            background = nil
            messages = running.messages
            threadID = thread.id
            section = .chat
            return
        }
        detachGenerationForThreadSwitch()
        guard thread.id != threadID else {
            // 点的就是当前这段：别用历史里的旧快照把正在流的回答盖掉。
            section = .chat
            return
        }
        messages = thread.messages.map {
            ChatMessage(role: $0.role, content: $0.content, model: $0.model,
                        createdAt: $0.createdAt, usage: $0.usage,
                        seconds: $0.seconds, tokensPerSecond: $0.tokensPerSecond,
                        firstTokenSeconds: $0.firstTokenSeconds,
                        thinkingSeconds: $0.thinkingSeconds,
                        reasoning: $0.reasoning,
                        interrupted: $0.interrupted,
                        imagePath: $0.imagePath,
                        imageNote: $0.imageNote,
                        imageSourcePath: $0.imageSourcePath,
                        imageStrength: $0.imageStrength,
                        imageSeed: $0.imageSeed,
                        imagePaths: $0.imagePaths,
                        toolCalls: $0.toolCalls,
                        toolResults: $0.toolResults,
                        videoPath: $0.videoPath,
                        videoNote: $0.videoNote,
                        videoSourcePath: $0.videoSourcePath,
                        videoLastFramePath: $0.videoLastFramePath)
        }
        threadID = thread.id
        // 打开的这段对话就是「当前对话」：不写回 `conversation.json` 的话，
        // 下次启动会拿 list 里旧的正文配上这里新的 `threadID`，下一轮保存
        // 还会把旧正文写到新 id 名下。
        conversation.save(messages)
        section = .chat
    }

    func deleteThread(_ thread: ChatThread) {
        // 删掉的正是后台还在生成的那段：先停掉，别让它跑完再把这条写回来。
        if background?.threadID == thread.id { cancelGeneration() }
        history.delete(id: thread.id)
        threads = history.load()
        // 删掉的是当前这段对话：下一轮算新会话，别写回刚删掉的 id。
        if thread.id == threadID { threadID = Self.newThreadID() }
        toast(L10n.format("已删除对话「%@」", thread.title))
    }

    func clearThreads() {
        if background != nil { cancelGeneration() }
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
        toast("已恢复默认对话参数", transient: true)
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
            toast(L10n.format("已删除 %@", model.id))
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
        let path = engineModels(for: engine).first(where: { $0.id == id })?.path
            ?? EnginePaths.modelPath(for: engine, model: id)
        do {
            try FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".flashcat-incomplete")
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
        toast(L10n.format("已删除 %@ 及其权重文件", id))
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
        reloadModels()
        guard !repoIsLocal(id) else {
            notice = "「\(id)」已经在本机了，不用重复下载"
            return false
        }
        let recommendation = ModelRecommendations.recommendation(for: id)
        let draft = engine.adapter == .splash
            ? (catalog.draftRepository(id, family: family) ?? recommendation?.draftRepository)
            : nil

        let plan: ModelInstaller.Plan
        do {
            plan = try ModelInstaller.plan(engine: engine,
                                           model: id,
                                           draftRepository: draft,
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
    /// - Returns: whether the transfer started. `false` comes with a `notice`,
    ///   which the control server (and therefore the CLI) reports verbatim.
    @discardableResult
    func downloadShared(_ repo: String, engines: [EngineID]) -> Bool {
        guard downloadingModel == nil else {
            toast("正在下载另一个模型，先等它结束")
            return false
        }
        let target = ModelSharing.canonical(repo.trimmingCharacters(in: .whitespaces))
        guard target.contains("/") else {
            notice = "仓库 id 要写成 owner/repo"
            return false
        }
        guard !engines.isEmpty else {
            notice = "至少选一个引擎，否则下完就没人能用它"
            return false
        }
        // 已经在本机的仓库不再下一遍：先 reload 一次，免得上一次下载刚落地、
        // 清单还是旧的。
        reloadModels()
        guard !repoIsLocal(target) else {
            notice = "「\(target)」已经在本机了，不用重复下载"
            return false
        }
        let plan: ModelInstaller.Plan
        do {
            plan = try ModelInstaller.sharedPlan(repo: target,
                                                 engines: engines,
                                                 cache: settings.hfCache)
        } catch {
            notice = (error as? ModelInstaller.Failure)?.message ?? "\(error)"
            return false
        }
        return startDownload(plan, engine: engines.first ?? libraryEngine, id: target, shared: engines)
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
                // Quantization and memory need real file sizes, which the list
                // endpoint does not return. Show the rows immediately, then
                // fill in metadata a few repositories at a time.
                let enriched = await HubClient.enrich(models)
                guard !Task.isCancelled else { return }
                self?.hubResults = enriched
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
    /// 判定放在这里而不是视图：置灰只是表现，真正的门在这儿。
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
        try? FileManager.default.removeItem(atPath: ModelSharing.path(for: repo) + ".flashcat-incomplete")
        if selectedModel == repo || selectedModel == ModelInstaller.folderName(for: repo) {
            selectedModel = ""
            adoptSavedModel(for: activeEngine)
        }
        EngineModelStore.invalidateMetaCache()
        reloadModels()
        toast(L10n.format("已删除 %@ 及其权重文件", repo))
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
        removeRequested = false
        downloadSpeed = 0
        // Resume, not restart: a paused/failed row already recorded where the
        // transfer stood, and the Hub's partial files are still on disk. Seed
        // the progress with those bytes so the bar continues from 已下载/总量
        // instead of dropping back to 0%. A brand-new download has no row and
        // therefore starts at zero.
        let previous = downloadTasks.first { $0.engine == engine && $0.model == id }
        let resumeTotal = max(previous?.totalBytes ?? 0, 0)
        let previousBytes = max(previous?.downloadedBytes ?? 0, 0)
        // Without a known total the row still knows how many bytes were on
        // disk; keep them and let the first TOTAL line supply the denominator.
        let resumeBytes = resumeTotal > 0 ? min(previousBytes, resumeTotal) : previousBytes
        downloadResumeBytes = resumeBytes
        downloadFetchedBytes = 0
        lastWatchBytes = resumeBytes
        lastWatchDate = nil
        downloadWatchDirectories = []
        downloadWatchBaselines = [:]
        downloadIncompleteMarker = plan.incompleteMarker
        // 标记只下在「本来就不存在」的目标上，且必须落在模型目录内：否则一次
        // 失败的重复下载会给已装好的模型盖章，之后「移除」就会删掉好权重。
        if let marker = plan.incompleteMarker,
           !Paths.fileExists(plan.destination),
           FlashCatPaths.contains(plan.destination, in: EnginePaths.modelsRoot) {
            Paths.ensureDirectory((marker as NSString).deletingLastPathComponent)
            FileManager.default.createFile(atPath: marker, contents: nil)
        }
        upsertTask(engine: engine, model: id) { task in
            task.status = .downloading
            task.shared = shared
            task.downloadedBytes = resumeBytes
            task.totalBytes = max(task.totalBytes, resumeTotal)
            if task.addedAt.timeIntervalSinceNow < -60 * 60 * 24 * 30 { task.addedAt = Date() }
        }
        downloadingModel = id
        downloadingEngine = engine
        downloadTotalBytes = resumeTotal
        downloadFraction = resumeTotal > 0 ? Double(resumeBytes) / Double(resumeTotal) : 0
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
                    // Snapshot downloader: TOTAL is the repository's full size,
                    // so it is the denominator with or without a resume.
                    self.downloadTotalBytes = max(total, self.downloadResumeBytes)
                    self.upsertTask(engine: engine, model: id) {
                        $0.totalBytes = max($0.totalBytes, self.downloadTotalBytes)
                    }
                    if let directory = plan.watchDirectory {
                        if !self.downloadWatchDirectories.contains(directory) {
                            self.downloadWatchDirectories.append(directory)
                        }
                        self.startDownloadWatch(engine: engine, model: id)
                    }
                } else if let fetch = Self.fetchPlan(in: line) {
                    // Splash's installer announces every repository it is
                    // about to fetch with its exact byte size. On a fresh
                    // download those sizes sum to the total; on a resume the
                    // cache already holds part of the repository and the
                    // announcement only covers what is still missing, so the
                    // denominator is 已下载 + 剩余, never just 剩余.
                    self.downloadFetchedBytes += fetch.bytes
                    self.downloadTotalBytes = max(self.downloadTotalBytes,
                                                  self.downloadResumeBytes + self.downloadFetchedBytes)
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

        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            // 走到这里时下载进程已经退出，回调只带三个可发送的值；用
            // `Task { @MainActor }` 而不是闭包里的 `self?`——弱引用在
            // `@Sendable` 闭包里被当成「可变捕获」，严格并发会报错。
            Task { @MainActor in
                AppState.shared.finishDownload(engine: engine, model: id, status: status)
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
            downloadTotalBytes = 0
            downloadResumeBytes = 0
            downloadFetchedBytes = 0
            lastWatchBytes = 0
            lastWatchDate = nil
            downloadWatchDirectories = []
            downloadWatchBaselines = [:]
            downloadIncompleteMarker = nil
            if let marker = plan.incompleteMarker {
                try? FileManager.default.removeItem(atPath: marker)
            }
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
        toast(L10n.format("%@ 缺少 DFlash2 加速模型，先下载好再启动", shortModelName(model.id)), kind: .warning)
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

    // MARK: termination

    private var terminatingDownloadPid: Int32?

    /// Quit-time cleanup that is not engine lifecycle. The downloader is a child
    /// process too, and an orphaned one keeps pulling gigabytes to disk with no
    /// window left to stop it from.
    func prepareForTermination() {
        gateway.stop()
        control.stop()
        guard let process = downloadProcess, process.isRunning else { return }
        terminatingDownloadPid = processPid(process)
        append(log: "==> 退出应用，终止正在进行的下载", engine: downloadingEngine ?? activeEngine)
        process.terminate()
    }

    /// SIGTERM was ignored, or the child is blocked inside a network read.
    /// Partial files stay on disk, so the next launch resumes the transfer
    /// instead of starting over.
    func finishTermination() {
        guard let pid = terminatingDownloadPid else { return }
        terminatingDownloadPid = nil
        kill(pid, SIGKILL)
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
            discardPartialDownload(task)
            toast("已从下载中心移除")
        }
    }

    /// Removing a paused/failed row is the explicit "throw the partial bytes
    /// away" action. Only folders still carrying the incomplete marker are
    /// touched, so a finished model that happens to share the id is safe.
    private func discardPartialDownload(_ task: ModelDownloadTask) {
        let path: String
        if let shared = task.shared, !shared.isEmpty {
            path = ModelSharing.path(for: task.model)
        } else if task.engine.adapter == .splash {
            return
        } else {
            path = EnginePaths.modelPath(for: task.engine, model: task.model)
        }
        let marker = ModelInstaller.incompleteMarker(for: path)
        guard Paths.fileExists(marker),
              FlashCatPaths.contains(path, in: EnginePaths.modelsRoot) else { return }
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: marker)
        EngineModelStore.invalidateMetaCache()
        reloadModels()
    }

    /// Remove a finished/failed/stale row from the center.
    ///
    /// Deleting the row of the transfer that is still running has to stop the
    /// child as well: the progress watcher upserts the row every half second,
    /// so merely dropping it from the list would make it reappear immediately.
    func removeTask(_ task: ModelDownloadTask) {
        if let process = downloadProcess, process.isRunning,
           downloadingModel == task.model, downloadingEngine == task.engine {
            removeRequested = true
            cancelRequested = true
            downloadSpeed = 0
            append(log: "==> 删除下载任务并停止传输：\(task.model)", engine: task.engine)
            process.terminate()
            return
        }
        removeTask(engine: task.engine, model: task.model)
        discardPartialDownload(task)
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
                // The bytes the resumed transfer started with are added back on
                // top: they are part of this model, unlike a foreign cache entry.
                var downloaded = self.downloadResumeBytes
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
        let incompleteMarker = downloadIncompleteMarker
        downloadIncompleteMarker = nil
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
        downloadResumeBytes = 0
        downloadFetchedBytes = 0
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
            toast("已暂停下载，进度已保留", transient: true)
            outcome = .cancelled
            return
        }
        if cancelRequested {
            cancelRequested = false
            if removeRequested {
                // 用户点的是删除而不是暂停：行和半成品一起清掉。
                removeRequested = false
                let stale = ModelDownloadTask(engine: engine, model: model, status: .paused,
                                              shared: sharedRepo == nil ? nil : sharedEngines)
                removeTask(engine: engine, model: model)
                discardPartialDownload(stale)
                append(log: "==> 已删除下载任务 \(model)，半成品已清理", engine: engine)
                toast("已从下载中心移除")
                outcome = .cancelled
                return
            }
            // Keep the row as paused: the partial bytes and the marker are
            // still on disk, so the model card must keep showing that state
            // instead of flipping back to a clickable "下载". Removing the row
            // is a second, explicit step in the download center.
            upsertTask(engine: engine, model: model) { $0.status = .paused }
            append(log: "==> 已停止下载 \(model)，进度已保留", engine: engine)
            toast("已停止下载，可在下载中心继续或移除", transient: true)
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
        if let incompleteMarker {
            try? FileManager.default.removeItem(atPath: incompleteMarker)
        }
        // The scan at the top of this method still saw the marker; drop the
        // cached byte count and rescan now that the destination is complete,
        // so the card can flip from progress to "使用".
        EngineModelStore.invalidateMetaCache()
        reloadModels()

        if let sharedRepo {
            publishShared(repo: sharedRepo, engines: sharedEngines)
            append(log: "==> 已下载 \(sharedRepo) 到公共目录", engine: engine)
            return
        }

        // Splash addresses a model by its repository id, the packs by the
        // folder name flashCat gave it.
        let repo = model.split(separator: ":", maxSplits: 1).first.map(String.init) ?? model
        let installed = engine.adapter == .splash
            || engine.descriptor.modelLayout == .nested
            || engine.descriptor.modelLayout == .external
            ? model
            : ModelInstaller.folderName(for: repo)
        append(log: "==> 已下载 \(model)", engine: engine)
        outcome = .finished
        // A launch-triggered fetch is followed by the launch itself: no toast
        // to answer, and the selection must not move under the start.
        guard !supplementInFlight else { return }
        guard engine == activeEngine else {
            toast(L10n.format("已下载 %@，切到 %@ 就能用", model, engine.displayName))
            return
        }
        applyModel(installed)
        toast(L10n.format("已下载 %@", model))
    }

    /// Engine logs are per engine; only the running engine's copy is on screen.
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
    func toast(_ message: String,
               title: String? = nil,
               kind: IslandNotice.Kind? = nil,
               transient: Bool = false) {
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

let SPLASH_VERSION = "1.4.0"

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
