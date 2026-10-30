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
    /// Non-nil while a model switch is waiting for the reader to confirm that
    /// the model that is loaded now gets stopped first. Switching weights means
    /// unloading the resident model, so the engine is briefly unusable — that is
    /// worth one click, not a silent stall.
    @Published var confirmingModelSwitch: String?
    @Published var messages: [ChatMessage] = []
    @Published var threads: [ChatThread] = []
    @Published var generating = false
    @Published var generationStatus: String?
    @Published var importProgress: ImportProgress?
    /// Persistent banner for errors that need the reader's attention.
    @Published var notice: String?
    /// Transient bottom toast.
    @Published var toastMessage: String?
    @Published var sidebarVisibility: NavigationSplitViewVisibility
    @Published var throughput: [ThroughputSample] = []
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
    /// Which engine's model library the model page shows. Browsing is
    /// deliberately independent of the running engine, so an engine that is
    /// stopped — or that has no weights at all — can still be inspected,
    /// filled from the Hub and compared with the others.
    @Published var libraryEngine: EngineID = .splash
    /// Set when a model is picked for an engine that is not running: the switch
    /// is a bigger step than a model change, so it asks first.
    @Published var pendingLibraryUse: LibraryUseRequest?
    /// Set when a switch targets an engine whose pack is not installed. The
    /// weights can be on disk (browsing works without the runtime), so without
    /// this the switch would silently do nothing while claiming success.
    @Published var pendingEngineInstall: EngineID?

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

    struct ImportProgress {
        let fraction: Double
        let message: String
    }

    init() {
        theme = ThemeController(settings: settings)
        let visible = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true
        sidebarVisibility = visible ? .all : .detailOnly
        downloadTasks = ModelDownloadStore.load()
        NotificationCenter.default.addObserver(forName: EngineStore.tuningDidChangeNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tuningRevision += 1 }
        }
    }

    // MARK: derived

    var selectedModelInfo: ModelInfo? { catalog.machineModel(selectedModel) }
    var isSwitchingModel: Bool { switchingModel != nil }
    var isRunning: Bool { controller?.isRunning ?? false }
    var isReady: Bool { controller?.isReady ?? false }
    var port: Int {
        controller?.port
            ?? EngineStore.shared.configuration(for: activeEngine).port
            ?? activeEngine.defaultPort
    }
    var startupStage: String { controller?.startupStage ?? "已停止" }
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
    var isPresentingLaunchPage: Bool { needsEngineSetup || showsLaunchPage }
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

    var endpointURL: String { "http://127.0.0.1:\(port)/v1" }

    /// The gateway's address: engine-independent, so a client's Base URL never
    /// needs to change when the engine or its port does.
    var gatewayURL: String { "http://127.0.0.1:\(settings.gatewayPort)/v1" }

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

        if let rate = stats?.decodeTokensPerSecond, rate > 0 {
            let now = Date()
            if throughput.last.map({ now.timeIntervalSince($0.at) >= 0.9 }) ?? true {
                throughput.append(ThroughputSample(at: now, value: rate))
                let cutoff = now.addingTimeInterval(-300)
                throughput.removeAll { $0.at < cutoff }
            }
        }

        if switchingModel != nil { syncSwitchStage() }
    }

    func bootstrap() {
        let service = ModelCatalogService()
        service.migrateLegacyDirectory()
        Paths.ensureDirectory(Paths.modelsDirectory)

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

        // Nothing installed yet: the launch page takes over and picks an engine.
        guard !needsEngineSetup else {
            selectedModel = ""
            return
        }

        // Model folders are per engine; build the links once at launch so the
        // models page opens on something usable. Splash's folder *is* the model
        // root, so it needs no links.
        EngineModelLinker.synchronize(activeEngine)
        libraryEngine = activeEngine
        // Model ids do not carry across engines: a remembered id is only kept
        // when this engine can actually serve it, otherwise the folder's own
        // models win.
        adoptSavedModel(for: activeEngine)

        applyGatewaySettings()

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
        EngineModelLinker.synchronize(id)
        reloadModels()
        adoptSavedModel(for: id)
        syncController()
        showsLaunchPage = false
        objectWillChange.send()
    }

    func reloadModels() {
        catalog = ModelCatalogService().load(runtime: splashRuntime)
        controller?.updateCatalog(catalog)
        if selectedModel.isEmpty, let first = catalog.machine.first {
            selectedModel = first.id
            settings.setModel(first.id)
        }
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
        guard !isSwitchingModel else {
            toast("正在切换模型，稍后再换引擎")
            return false
        }
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
        if id == .splash {
            return catalog.machine.map {
                EngineModel(id: $0.id, path: $0.path, bytes: $0.bytes,
                            maximumContextTokens: nil, loaded: false, loading: false,
                            kind: nil, hidden: false, helper: false, engine: .splash)
            }
        }
        let scanned = LocalEngineModels.scan(engine: id, directory: EnginePaths.modelsDirectory(id))
        // A half-downloaded snapshot already carries config.json and a
        // tokenizer, which is enough for the scan to call it a servable model.
        // Every download-center row means its folder is not finished (success
        // removes the row), so hide those folders from the library until the
        // downloader is done — the card then keeps showing live progress on
        // the suggestion row instead of flipping to a "使用" button.
        let unfinished = Set(downloadTasks.map { task -> String in
            let repo = task.model.split(separator: ":", maxSplits: 1).first.map(String.init) ?? task.model
            return ModelInstaller.folderName(for: repo)
        })
        return scanned.filter { !unfinished.contains($0.id) }
    }

    // MARK: model library

    /// The three Qwen tiers this engine can serve, bounded to the build it can
    /// load: Splash and oMLX read MLX folders, MTPLX serves its own packs.
    func libraryRecommendations(for engine: EngineID) -> [ModelRecommendation] {
        ModelRecommendations.list(for: engine)
    }

    /// Installed weights plus the engine's suggestions as one grid — the same
    /// rows whether or not that engine is installed, running or holding a model.
    func libraryEntries(for engine: EngineID) -> [ModelLibraryEntry] {
        let installed: [ModelInfo]
        if engine == .splash {
            installed = catalog.machine
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
        guard !isSwitchingModel else { return }
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
        guard !isSwitchingModel else { return }
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
        let controller = engines.controller(engine)
        switchTask = Task { [weak self] in
            guard let controller else { return }
            await controller.start(localModel: self?.selectedModelInfo, requestedModel: model)
            let ready = await controller.waitForReady(timeout: engine.startupTimeout)
            guard let self, !Task.isCancelled else { return }
            self.finishModelSwitch(outcome: ready
                ? .ready
                : .failed(controller.failureMessage ?? "\(engine.displayName) 未能在预期时间内就绪"))
            self.switchTask = nil
        }
    }

    /// Select a model and, if the engine is live, reload it on the new weights.
    /// The switcher UI stays in a loading state until the new engine reports
    /// ready, so a slow weight load never looks like an ignored click.
    func applyModel(_ id: String) {
        let target = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target != selectedModel else { return }
        guard !generating else {
            toast("正在生成，先停止再切换模型")
            return
        }
        guard !isSwitchingModel else { return }

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
        switchTask?.cancel()
        switchTask = nil

        guard isRunning, let controller else {
            // Nothing is resident, so there is nothing to unload: the choice only
            // takes effect on the next start.
            switchingModel = nil
            switchStage = ""
            toast("已切换到 \(shortModelName(id))")
            return
        }

        switchingModel = id
        switchStage = "准备切换"
        switchTask = Task { [weak self] in
            let outcome = await controller.switchModel(id) { stage in
                self?.switchStage = stage
            }
            guard let self, !Task.isCancelled else { return }
            self.finishModelSwitch(outcome: outcome)
            self.switchTask = nil
        }
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
        switchTask?.cancel()
        switchTask = nil
        switchingModel = nil
        switchStage = ""
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

        let options = ChatOptions(temperature: settings.temperature,
                                  topP: settings.topP,
                                  maxTokens: settings.maxTokens,
                                  reasoningEffort: settings.effectiveReasoningEffort,
                                  systemPrompt: settings.systemPrompt)
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
                    }
                },
                onReasoning: { piece in
                    Task { @MainActor in
                        guard assistantIndex < self.messages.count else { return }
                        self.messages[assistantIndex].reasoning = (self.messages[assistantIndex].reasoning ?? "") + piece
                        if self.messages[assistantIndex].content.isEmpty {
                            self.generationStatus = "思考中"
                        }
                    }
                },
                onUsage: { usage in
                    Task { @MainActor in
                        guard assistantIndex < self.messages.count else { return }
                        self.messages[assistantIndex].usage = usage
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
            history.save(messages: messages)
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
    }

    func openThread(_ thread: ChatThread) {
        cancelGeneration()
        messages = thread.messages.map {
            ChatMessage(role: $0.role, content: $0.content, model: $0.model,
                        createdAt: $0.createdAt, usage: $0.usage,
                        seconds: $0.seconds, tokensPerSecond: $0.tokensPerSecond,
                        firstTokenSeconds: $0.firstTokenSeconds)
        }
        section = .chat
    }

    func deleteThread(_ thread: ChatThread) {
        history.delete(id: thread.id)
        threads = history.load()
        toast("已删除对话「\(thread.title)」")
    }

    func clearThreads() {
        for thread in threads { history.delete(id: thread.id) }
        threads = history.load()
    }

    func resetChatParameters() {
        settings.setTemperature(0.7)
        settings.setTopP(0.95)
        settings.setMaxTokens(4096)
        settings.setSystemPrompt("")
        settings.setThinkingMode(.automatic)
        toast("已恢复默认对话参数")
    }

    // MARK: models

    func importModel(_ source: String, move: Bool = false, engine: EngineID? = nil) {
        let target = engine ?? activeEngine
        let service = ModelCatalogService()
        importProgress = ImportProgress(fraction: 0, message: "正在复制…")
        Task {
            do {
                let result = try service.importDirectory(source,
                                                         move: move,
                                                         into: EnginePaths.modelsDirectory(target),
                                                         flatten: target != .splash) { fraction, message in
                    DispatchQueue.main.async { self.importProgress = ImportProgress(fraction: fraction, message: message) }
                }
                importProgress = nil
                reloadModels()
                if target == activeEngine { selectModel(result.id) }
                toast("已导入 \(result.id)")
            } catch {
                importProgress = nil
                notice = (error as? ModelCatalogService.ImportError)?.message ?? "\(error)"
            }
        }
    }

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
            notice = "删除失败：\((error as? ModelCatalogService.ImportError)?.message ?? error.localizedDescription)"
        }
    }

    /// Remove a model from one engine's folder. The packs find weights through
    /// the links flashCat created, so removing a link only unlinks the model —
    /// the bytes in `~/.omlx` or `~/.mtplx` stay where they are.
    func removeModel(_ id: String, engine: EngineID) {
        guard engine != .splash else {
            if let model = catalog.machine.first(where: { $0.id == id }) {
                deleteModel(model)
            }
            return
        }
        let path = EnginePaths.modelsDirectory(engine) + "/" + id
        let link = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            notice = "移除失败：\(error.localizedDescription)"
            return
        }
        if selectedModel == id, engine == activeEngine {
            selectedModel = ""
            adoptSavedModel(for: engine)
        }
        reloadModels()
        toast(link ? "已从 \(engine.displayName) 移除链接，权重还在原处" : "已删除 \(id)")
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
    func downloadModel(_ id: String, engine: EngineID) {
        guard downloadingModel == nil else {
            toast("正在下载另一个模型，先等它结束")
            return
        }
        let recommendation = ModelRecommendations.recommendation(for: id)
        let draft = engine == .splash
            ? (catalog.draftRepository(id, family: nil) ?? recommendation.draftRepository)
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
            return
        }

        pauseRequested = false
        cancelRequested = false
        downloadSpeed = 0
        lastWatchBytes = 0
        lastWatchDate = nil
        downloadWatchDirectories = []
        downloadWatchBaselines = [:]
        upsertTask(engine: engine, model: id) { task in
            task.status = .downloading
            if task.addedAt.timeIntervalSinceNow < -60 * 60 * 24 * 30 { task.addedAt = Date() }
        }
        downloadingModel = id
        downloadingEngine = engine
        downloadFraction = 0
        downloadTotalBytes = 0
        append(log: "==> \(engine.displayName) 下载模型：\(id)", engine: engine)

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
        } catch {
            downloadingModel = nil
            downloadingEngine = nil
            downloadFraction = nil
            removeTask(engine: engine, model: id)
            notice = "无法启动下载：\(error.localizedDescription)"
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

        if pauseRequested {
            pauseRequested = false
            upsertTask(engine: engine, model: model) { $0.status = .paused }
            append(log: "==> 已暂停 \(model)，可从下载中心继续", engine: engine)
            toast("已暂停下载，进度已保留")
            return
        }
        if cancelRequested {
            cancelRequested = false
            removeTask(engine: engine, model: model)
            append(log: "==> 已取消下载 \(model)", engine: engine)
            toast("已取消下载")
            return
        }

        guard status == 0 else {
            upsertTask(engine: engine, model: model) { $0.status = .failed }
            append(log: "==> 下载失败，退出码 \(status)", engine: engine)
            notice = "模型下载失败，退出码 \(status)（下载中心里可重试）"
            return
        }

        removeTask(engine: engine, model: model)

        // Splash addresses a model by its repository id, the packs by the
        // folder name flashCat gave it.
        let repo = model.split(separator: ":", maxSplits: 1).first.map(String.init) ?? model
        let installed = engine == .splash ? model : ModelInstaller.folderName(for: repo)
        append(log: "==> 已下载 \(model)", engine: engine)
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

    func toggleSidebar() {
        // Keep the rail's collapse/expand in step with the rest of the UI:
        // NavigationSplitView resizes the column without its own transition.
        withAnimation(.easeInOut(duration: 0.26)) {
            sidebarVisibility = sidebarVisibility == .all ? .detailOnly : .all
        }
        UserDefaults.standard.set(sidebarVisibility == .all, forKey: "sidebarVisible")
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
