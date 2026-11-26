// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import Foundation

/// 引擎编排：启动/停止、装卸联动、模型热切换、网关模型的准备与就绪等待。
///
/// 这四类事原本散在 `AppState` 的 lifecycle / engines / API gateway model preparation /
/// model switch progress 四段里。它们的共同点是「按顺序驱动引擎，并等它真的到位」：
/// 每一步都要等控制器、要防重入、要在代数变了之后收手——这跟界面状态没有关系，
/// 所以单独成一块。界面读的字段一个都没搬：`serverState`、`switchingModel`、
/// `switchStage` 仍是 `EngineSessionStore` 的发布字段，`AppState` 里已经有
/// `engineSessionBridge` 把发布桥回界面，所以这里改 store 等于界面收到通知，
/// 不需要再造第二套 `@Published`。
///
/// 装配根（`AppState`）里剩下的壳层状态——日志尾巴、气泡、通知、引导页、扫盘缓存
/// ——通过 `host` 弱引用读写：只在少数收尾处用到（发提示、推日志、落引导页），
/// 为它们再摊一层闭包反而看不清调用关系。
@MainActor
final class EngineCoordinator {
    private let settings: AppSettings
    private let installs: EngineInstallCenter
    private let control: ControlServer
    private let gateway: GatewayController
    private let metrics: MetricsStore
    private let downloads: DownloadCenter

    /// 只认识 `EngineHost` 协议，不认识装配根的具体类型。弱引用：外层持有本对象，
    /// 强引用回去就是一个环。
    weak var host: (any EngineHost)?

    /// 引擎管理器的 owner 在这里：装卸、切换都会重建控制器列表。
    private(set) var engines: EngineManager?

    /// 上面那个计数器的心跳；模型不忙时它不发任何东西，界面不白白每秒重绘。
    private var lifecycleClock: Timer?
    /// 每次切换领一个号，只有当代的结尾允许改「切换中」状态。被接管或被取消的
    /// 旧任务回来时代数已经不同，它就静默退出：既不会抹掉新切换的状态，也没人
    /// 能把界面永久留在「切换中」。
    private var switchGeneration = 0
    /// 切换进行中又选了一个本引擎的模型：排到这次切换之后，只保留最后一次。
    /// 以前这里直接丢弃，读者看到的是「点了没反应」。跨引擎切换与排队入口
    /// （`AppState.hopEngine` / `applyModel`）是同一队列的另外两个写入点，
    /// 所以对 `AppState` 可见——单飞的是一个槽，不是某一条代码路径。
    var queuedSwitchModel: String?
    /// 正在跑的那次切换。作废时先 cancel 再清空，见 `retireModelSwitch`。
    /// `hopEngine` 也会把任务放进这个槽，同理。
    var switchTask: Task<Void, Never>?
    /// 网关准备的串行尾巴：API 请求一个接一个地换权重，不能并行抢同一份内存。
    private var gatewayPreparationTail: Task<Void, Never>?
    /// 上一次登记安装回调时看到的引擎。装卸之后活动引擎可能被悄悄换掉，
    /// 靠它比对才知道要不要把模型页和选中模型一起搬过去。
    private var installsObservedEngine: EngineID?
    /// 上一拍参与指纹的非活动引擎存储，见 `syncController`。
    private var logFeedToken: [Int] = []
    /// 模型目录扫描的短缓存（与 `ModelOps` 的模型库缓存同一档 TTL，见
    /// `ModelOps.modelListTTL`）：这里只缓存 `engineModels(for:)` 的结果。
    private var modelsCache: [EngineID: (models: [EngineModel], at: Date)] = [:]

    init(
        settings: AppSettings,
        installs: EngineInstallCenter,
        control: ControlServer,
        gateway: GatewayController,
        metrics: MetricsStore,
        downloads: DownloadCenter
    ) {
        self.settings = settings
        self.installs = installs
        self.control = control
        self.gateway = gateway
        self.metrics = metrics
        self.downloads = downloads
    }

    /// 当前活动引擎的控制器。编排里几乎每一步都要它，转发一次省得处处写
    /// `engines?.active`。
    var controller: EngineController? { engines?.active }

    var activeEngine: EngineID { engines?.activeID ?? .splash }

    /// 最近一次异常退出的信号诊断（菜单栏异常卡用）。
    var exitDiagnostic: EngineExitDiagnostic? { controller?.exitDiagnostic }

    var availableEngines: [EngineID] { engines?.installedIDs ?? [] }

    /// 模型目录扫描的缓存在这里，所以失效入口也在这里：`AppState`
    /// 的 `invalidateModelCaches` 会连带上这一份。
    func invalidateModelCache() {
        modelsCache.removeAll()
    }

    /// 当代代数（只读）。跨引擎切换由 `AppState.hopEngine` 驱动：它领完号之后
    /// 要用这个号做「是否已被接管」的判定，判定本身仍在这里完成。
    var currentSwitchGeneration: Int { switchGeneration }

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
                guard let self, let host = self.host, host.isModelBusy else { return }
                host.lifecycleTick &+= 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lifecycleClock = timer
    }

    func syncController() {
        guard let host else { return }
        // 每秒轮询都会走到这里。引擎空闲时状态与指标往往原封不动，无条件赋值
        // `@Published` 会让整页每秒重绘一次；只在真的变化时才发布。
        let nextState = controller?.state ?? .stopped
        if host.serverState != nextState { host.serverState = nextState }
        let nextStats = controller?.stats
        if host.stats != nextStats {
            host.stats = nextStats
            // 引擎刚刚报出（或改口）本次窗口：顺手记住是显式的写入点，
            // 不让读取处去写 UserDefaults。
            host.rememberReportedWindow()
        }
        if let store = controller?.logs, store.latestId != host.logs.last?.id {
            host.logs = store.snapshot(limit: 4000)
        } else if controller == nil, !host.logs.isEmpty {
            host.logs = []
        }

        // 「全部日志」还并着非活动引擎的尾巴：那些写入不经过 `logs`（它只盯
        // 活动引擎），所以用其余存储的 latestId 组成指纹。只有真的长出新行才
        // 发布，空闲时不白白重绘日志页。
        let activeStore = controller?.logs
        let logToken = (engines?.available ?? [])
            .filter { $0.logs !== activeStore }
            .map { $0.logs.latestId }
        if logToken != logFeedToken {
            logFeedToken = logToken
            host.logsRevision &+= 1
        }

        let now = Date()
        // 指标那一半（网关聚合 / 曲线 / 接受率）搬进了 store，仍然按 **1 秒一拍**
        // 发布：引擎轮询是 1s，应用内对话的分片回调只往网关打点里记 token，不刷新
        // 概览。`@Published` 只在数值真的变化时发布，空闲时不重绘；这里只负责把
        // 这一拍的引擎状态递进去。
        metrics.tick(now: now, stats: host.stats, isRunning: host.isRunning, activeEngine: host.activeEngine)

        if host.switchingModel != nil { syncSwitchStage() }
    }

    func bootstrap() {
        guard let host else { return }
        // 先让等待时长的心跳跑起来：下面的 autoStart 可能立刻拉起引擎，
        // 而「已等待 0:01」从第一秒就该开始走。
        installLifecycleClock()

        let service = ModelCatalogService()
        // 旧目录迁移是启动时的静默整理：模型列表会直接显示结果，不弹回执。
        _ = service.migrateLegacyDirectories()
        Paths.ensureDirectory(Paths.modelsDirectory)

        // 旧版本用软链接把 ~/.omlx、~/.mtplx 的权重挂进模型目录；现在模型必须
        // 真正待在自己的目录里，启动时把链接换成权重本身，并清掉失效链接。
        for engine in EngineCatalog.allIDs {
            _ = EngineModelStore.adoptExistingWeights(engine)
        }

        // 授权表是公共目录的真相：启动时按它把各引擎目录里的链接对齐。
        ModelSharing.synchronize()

        host.catalog = service.load()
        if host.catalog.machine.isEmpty {
            host.selectedModel = settings.model
        } else if settings.model.isEmpty, let first = host.catalog.machine.first {
            host.selectedModel = first.id
            settings.setModel(host.selectedModel)
        } else {
            host.selectedModel = settings.model
        }
        host.messages = host.conversation.load()
        // 旧版本留下的重复线程只在启动时清理一次，之后都走缓存。
        host.threads = host.history.load(pruneLegacy: true)
        // 上次退出时的那段对话可能因为旧版 6 条上限被挤出了历史列表：
        // 正文还在，但侧栏没有它、顶栏也没有改名 / 置顶入口。启动时补一条，
        // 只在 id 确实缺失时写盘，已有条目不会被覆盖。
        if !host.messages.isEmpty,
            !host.threads.contains(where: { $0.id == host.currentThreadID })
        {
            host.history.save(
                messages: host.messages,
                threadID: host.currentThreadID,
                updatedAt: host.messages.last?.createdAt ?? Date())
            host.threads = host.history.load()
        }

        attachEngines()
        // A crashed or force-quit session can leave an engine resident with its
        // weights; clear those before anything of this session starts.
        engines?.sweepOrphanEngines()
        syncController()

        // Work out (or recall) what this Mac should run before the launch page
        // takes over: the first-run page and the launch page both ask "which
        // engine", and the recommendation is what answers it.
        host.settleRecommendation()

        // Both loopback interfaces come up before the launch-page early return:
        // the CLI and API clients need endpoints even on a fresh install.
        startControlServerIfNeeded()
        host.applyGatewaySettings()

        // Nothing installed yet: the launch page takes over and picks an engine.
        guard !host.needsEngineSetup else {
            host.selectedModel = ""
            return
        }

        // Model folders are per engine and filled above; adopt whatever this
        // engine already has so the models page opens on something usable.
        host.libraryEngine = activeEngine
        // Model ids do not carry across engines: a remembered id is only kept
        // when this engine can actually serve it, otherwise the folder's own
        // models win.
        host.adoptSavedModel(for: activeEngine)

        // 模型广场的「已下载」要在第一次打开前就有结论：跟着启动算一次。
        refreshLocalRepos()

        if settings.autoStart && !host.selectedModel.isEmpty {
            host.startService()
        }
    }

    /// Start the CLI control channel when it is not already up. Called from
    /// `bootstrap` and from the settings page after the port changes.
    func startControlServerIfNeeded() {
        guard !control.isRunning else { return }
        let port = UInt16(settings.controlPort)
        Task { [control] in
            await control.start(preferredPort: port)
        }
    }

    /// Apply the control-interface port without requiring a relaunch. The
    /// channel itself is always on.
    func applyControlSettings() {
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
        guard let host else { return }
        let manager = EngineManager(settings: settings, catalog: host.catalog)
        manager.onChange = { [weak self] in self?.syncController() }
        // Splash launches run through here: a model installed without its
        // DFlash2 draft gets it fetched before the engine starts.
        manager.prepareForStart = { [weak self] model in
            guard let self, let host = self.host else { return .ready(model) }
            return await host.ensureSplashDraft(model)
        }
        engines = manager
        // A finished install/uninstall changes which packs exist, so rebuild the
        // controllers and refresh whatever the models page is showing.
        installsObservedEngine = manager.activeID
        installs.configure(onChange: { [weak self] in
            guard let self, let host = self.host else { return }
            self.engines?.rebuild()
            // 卸载正在使用的引擎会让 rebuild 悄悄回落到另一个包（或一个不剩）。
            // 活动引擎因此变化时，选中模型必须跟上，不能指向已删除的包；但模型页
            // 看的是哪台引擎是读者自己的选择，不跟着活动引擎跳。
            defer { self.installsObservedEngine = self.activeEngine }
            if host.needsEngineSetup {
                host.selectedModel = ""
                host.libraryEngine = .splash
            } else if self.installsObservedEngine != self.activeEngine {
                host.adoptSavedModel(for: self.activeEngine)
            }
            // 有了引擎，首次运行的推荐页就不再成立：它既不能被这张页盖住
            // 一个已经装好的引擎，也不能在没给出答案的情况下一直挂着。
            if !host.needsEngineSetup { host.dismissRecommendationPage() }
            host.reloadModels()
            self.syncController()
            host.notifyObjectChanged()
        })
        // 安装/构建失败仍走阻塞浮层；成功由卡片上的「已安装」与进度环表示，
        // `toast` 层的成功过滤会把它丢掉。
        installs.onToast = { [weak self] message in
            self?.host?.toast(message)
        }
    }

    /// Make a freshly installed engine the one this app runs.
    func adoptEngine(_ id: EngineID) {
        guard let host else { return }
        // The recommendation list lives inside the pack that just landed (or
        // was replaced): drop what we read from the previous version.
        ModelRecommendations.invalidate()
        EngineStore.shared.update(id) { $0.enabled = true }
        EngineStore.shared.rememberActive(id)
        engines?.rebuild(preferring: id)
        EngineModelStore.adoptExistingWeights(id)
        reloadModels()
        host.adoptSavedModel(for: id)
        syncController()
        host.showsLaunchPage = false
        // Adopting means a pack is on disk: the first-run question is answered by
        // the install itself, so the page must not stay up over a working engine
        // (it is a one-time question either way).
        host.dismissRecommendationPage()
        // The new pack carries its own catalog: refresh the per-engine pick so
        // the model page's recommendation tag reflects what just landed.
        host.settleRecommendation()
        // The first-run page may have asked for an engine *and* its model. The
        // downloader needs the pack on disk, so the model download waits for
        // this moment instead of failing with "还没有安装…引擎".
        if let pending = host.pendingRecommendedDownload {
            host.pendingRecommendedDownload = nil
            if pending.engine == id {
                let model = pending.model
                DispatchQueue.main.async { [weak self] in
                    self?.host?.downloadModel(model, engine: id)
                }
            }
            // Another engine arrived first: `EngineInstallCenter.onInstalled` is
            // a single slot, so the recommended engine's install can no longer
            // report back and the latch can never be honoured. Drop it (a stale
            // latch would fire a multi-GB download on some later install the
            // user never re-confirmed) rather than leave it armed.
        }
        host.notifyObjectChanged()
    }

    /// 本机已经有这些仓库：公共目录里的 + 各引擎模型目录里的权重。
    /// 模型广场和手填下载都按它判「已下载」，所以启动时（`bootstrap`）也要扫
    /// 一次——只挂在 `reloadModels` 上会等引擎安装/下载/授权变化才第一次算，
    /// 刚开app 时广场会全是「下载」。
    /// 三次目录扫描的 stat 走 `EngineModelStore` 的 meta 缓存，只有新增目录才真读盘。
    func refreshLocalRepos() {
        guard let host else { return }
        var local = Set(host.sharedRepos.map { ModelSharing.canonical($0) })
        for id in EngineCatalog.allIDs {
            for model in LocalEngineModels.scan(
                engine: id,
                directory: EnginePaths.modelsDirectory(id))
            {
                local.insert(ModelSharing.canonical(model.id))
            }
        }
        host.localModelRepos = local.sorted()
    }

    func reloadModels() {
        guard let host else { return }
        // 授权表是真相，磁盘上的链接跟着它走：启动、下载完成、授权变更都从这里过。
        ModelSharing.invalidateCaches()
        host.invalidateModelCaches()
        ModelSharing.synchronize()
        // 公共目录里已经有哪些仓库：模型广场用它标「已在本机」。跟着
        // reloadModels 走（不挂在每两秒的指标轮询里），磁盘不会被反复扫。
        host.sharedRepos = ModelSharing.scan().map { $0.id }
        refreshLocalRepos()
        host.catalog = ModelCatalogService().load()
        controller?.updateCatalog(host.catalog)
        if host.selectedModel.isEmpty, let first = host.catalog.machine.first {
            host.selectedModel = first.id
            settings.setModel(first.id)
        }
        // 扫盘之后是唯一「确定知道每个模型窗口」的时刻：在这里落盘记住，
        // 读取处就不必再写 UserDefaults。
        host.rememberContextWindows()
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
        host?.pendingEngineInstall = id
    }

    func confirmEngineInstall() {
        guard let host else { return }
        host.pendingEngineInstall = nil
        host.section = .engines
    }

    func cancelEngineInstall() {
        host?.pendingEngineInstall = nil
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
        guard let host, let engines, id != engines.activeID else { return false }
        // 换引擎本身就是重启进程：正在进行的切换（包括跨引擎跳过去的那一半）
        // 已经没有意义，直接作废。以前这里 toast 一句就 return，读者再点最多
        // 的选择都没反应，而那个被跳过的切换还在原地挂着。
        if host.isSwitchingModel { retireModelSwitch() }
        // A pending「切换模型？」sheet names the old engine's weights; it can
        // no longer be confirmed once the engine under it changed.
        host.confirmingModelSwitch = nil
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
        reloadModels()
        // Switching to an engine must not keep the previous engine's model id:
        // the remembered one only survives if this engine can serve it. The
        // model page's own engine selection is left alone — it is a view state,
        // not a consequence of becoming active.
        host.adoptSavedModel(for: id)
        syncController()
        if start, !host.selectedModel.isEmpty { host.startService() }
        // 侧栏 / 引擎卡的当前引擎标记已经换过去，不再补一过性提示。
        return true
    }

    /// Change the port an engine listens on. Only the stored preference moves
    /// while it is idle; a running engine keeps its port until restarted.
    func switchEnginePort(_ id: EngineID, port: Int) {
        guard let host, let engines, let controller = engines.controller(id) else { return }
        guard controller.port != port else { return }
        EngineStore.shared.update(id) { $0.port = port }
        if id == activeEngine, !host.isRunning {
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
        if let hit = modelsCache[id],
            Date().timeIntervalSince(hit.at) < ModelOps.modelListTTL
        {
            return hit.models
        }
        let models = scanEngineModels(for: id)
        modelsCache[id] = (models, Date())
        return models
    }

    private func scanEngineModels(for id: EngineID) -> [EngineModel] {
        guard let host else { return [] }
        // A half-downloaded snapshot already carries config.json and a
        // tokenizer, which is enough for the scan to call it a servable model.
        // Every download-center row means its folder is not finished (success
        // removes the row), so hide those folders from the library until the
        // downloader is done — the card then keeps showing live progress on
        // the suggestion row instead of flipping to a "使用" button.
        let unfinished = Set(host.downloadTasks.map { ModelSharing.canonical($0.model) })
        let shared = sharedModels(for: id)
            .filter { !unfinished.contains(ModelSharing.canonical($0.id)) }
        if id.adapter == .splash {
            // 公共目录里的权重已经在 catalog.local 里（load 会把 ModelSharing.scan()
            // 并进来），这里只过滤没下完的，不再追加一遍。
            return host.catalog.machine
                .filter { ModelSharing.visible($0.id, engine: .splash) }
                .filter { !unfinished.contains(ModelSharing.canonical($0.id)) }
                .map {
                    // Splash 的视觉能力来自独立的 mmproj 投影（GGUF 旁边的
                    // mmproj-*.gguf），目录扫描看不到；不补这个能力位，视觉
                    // 模型在对话页会被当成纯文本模型，画完图也不回传像素。
                    let vision =
                        $0.mmprojPath != nil
                        || LocalEngineModels.capabilities(at: $0.path).contains("vision")
                        || LocalEngineModels.capabilities(at: $0.targetName).contains("vision")
                    return EngineModel(
                        id: $0.id, path: $0.path, bytes: $0.bytes,
                        maximumContextTokens: nil, loaded: false, loading: false,
                        kind: nil, capabilities: vision ? ["chat", "vision"] : [],
                        hidden: false, helper: false, engine: .splash)
                }
        }
        let scanned = LocalEngineModels.scan(engine: id, directory: EnginePaths.modelsDirectory(id))
        // Flat-layout packs (oMLX, MTPLX) scan as `owner--repo` while
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
                let id =
                    engine.adapter == .splash || engine.descriptor.modelLayout == .nested
                    ? model.id
                    : ModelInstaller.folderName(for: model.id)
                let vision =
                    model.mmprojPath != nil
                    || LocalEngineModels.capabilities(at: model.targetName).contains("vision")
                return EngineModel(
                    id: id,
                    path: model.targetName,
                    bytes: model.bytes,
                    maximumContextTokens: nil, loaded: false, loading: false,
                    kind: nil, capabilities: vision ? ["chat", "vision"] : [],
                    hidden: false, helper: false, engine: engine)
            }
    }

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
    func prepareModelForGateway(
        _ requestedModel: String?,
        allowingGeneration: Bool = false
    ) async -> GatewayModelPreparationError? {
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

    private func prepareModelForGatewayExclusively(
        _ requestedModel: String?,
        allowingGeneration: Bool
    )
        async -> GatewayModelPreparationError?
    {
        guard let host else { return .unavailable("flashCat 状态不可用") }
        guard !host.needsEngineSetup, let engines else {
            return .unavailable("还没有安装推理引擎，请先在 flashCat 中安装并启动一个引擎")
        }

        // A model picked in the UI may still be loading. Wait for that switch
        // instead of issuing a competing load against an engine that is in the
        // middle of unloading its previous weights.
        let switchWaitDeadline = Date().addingTimeInterval(max(activeEngine.startupTimeout, 30))
        while host.isSwitchingModel, Date() < switchWaitDeadline {
            if Task.isCancelled { return .failed("模型准备已取消") }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if host.isSwitchingModel {
            return .unavailable("模型仍在切换中，请稍后重试")
        }

        var orderedEngines = [activeEngine]
        orderedEngines.append(contentsOf: availableEngines.filter { $0 != activeEngine })
        let modelsByEngine = Dictionary(
            uniqueKeysWithValues: orderedEngines.map { engine in
                (engine, engineModels(for: engine).map(\.id))
            })

        let route: GatewayModelRoute
        let wanted = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if wanted.isEmpty {
            let activeModels = modelsByEngine[activeEngine] ?? []
            guard
                let fallback = EngineModelSelection.resolve(
                    saved: host.selectedModel,
                    available: activeModels)
            else {
                return .badRequest("请求没有 model 字段，flashCat 也没有可用的默认模型")
            }
            route = GatewayModelRoute(model: fallback, engine: activeEngine)
        } else {
            guard
                let resolved = GatewayModelRouting.resolve(
                    requestedModel: wanted,
                    orderedEngines: orderedEngines,
                    modelsByEngine: modelsByEngine)
            else {
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
        if host.generating, requiresWork, !allowingGeneration {
            return .unavailable("flashCat 正在生成回复，暂时不能切换模型")
        }
        if requiresWork || host.selectedModel != route.model {
            gateway.logs.append(
                "==> API 请求模型 \(route.model) · \(route.engine.displayName)",
                level: .system)
        }

        if !alreadyActive {
            let activated = await engines.activate(route.engine)
            guard activated || activeEngine == route.engine else {
                return .failed("切换到 \(route.engine.displayName) 失败")
            }
            // A gateway request can switch the running engine at any moment.
            // The model page stays where the reader put it; only the running
            // engine changes.
            reloadModels()
            syncController()
        }

        // Avoid rewriting UserDefaults and the engine configuration on every
        // request when the requested model is already selected and resident.
        if host.selectedModel != route.model {
            host.selectModel(route.model)
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
            await controller.start(localModel: host.selectedModelInfo, requestedModel: route.model)
        } else if !gatewayModelIsResident(route.model, in: controller),
            controller.model != route.model
        {
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

        let ready = await controller.waitForSwitchReady(
            route.model,
            timeout: route.engine.startupTimeout)
        syncController()
        guard ready else {
            let reason =
                controller.failureMessage
                ?? "\(route.engine.displayName) 未能在预期时间内加载 \(route.model)"
            return .failed(reason)
        }
        if requiresWork {
            gateway.logs.append(
                "==> API 模型已就绪 · \(route.model) · 端口 \(controller.port)",
                level: .system)
        }
        return nil
    }

    /// Whether the controller's own telemetry says these exact weights are
    /// resident. During a cold start there is no status document yet, so the
    /// caller also checks `controller.model` and waits for the load to finish.
    func gatewayModelIsResident(_ target: String, in controller: EngineController) -> Bool {
        guard let status = controller.status else { return false }
        return status.model == target || status.loadedModels.contains(target)
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
    func beginModelSwitch(to id: String) {
        // 上一次切换（比如跨引擎跳过来的那一次加载）先作废，这一次从头开始。
        retireModelSwitch()
        let generation = switchGeneration
        let wasRunning = host?.isRunning ?? false
        host?.switchingModel = id
        host?.switchStage = wasRunning ? "准备切换" : "启动引擎"
        switchTask = Task { [weak self] in
            guard let self, let controller = self.controller, let host = self.host else {
                self?.settleModelSwitch(
                    generation: generation,
                    outcome: .failed("\(self?.activeEngine.displayName ?? "引擎") 没有可用的控制器"))
                return
            }
            guard wasRunning else {
                await controller.start(localModel: host.selectedModelInfo, requestedModel: id)
                let ready = await controller.waitForSwitchReady(id, timeout: self.activeEngine.startupTimeout)
                self.settleModelSwitch(
                    generation: generation,
                    outcome: ready
                        ? .ready
                        : .failed(controller.failureMessage ?? "\(self.activeEngine.displayName) 未能在预期时间内就绪"))
                return
            }
            let outcome = await controller.switchModel(id) { stage in
                // 被接管之后就不要再往新切换的阶段行里写了。
                guard generation == self.switchGeneration else { return }
                host.switchStage = stage
            }
            self.settleModelSwitch(generation: generation, outcome: outcome)
        }
    }

    /// 上一次切换作废：取消任务、推进代数、清掉「切换中」。跨引擎再选、换引擎、
    /// 用户主动放弃都走这里。以前这些入口要么静默 return，要么只 cancel 任务而
    /// 把状态交给一个再也不会回来的结尾去清——界面就永久停在「切换中」，只能
    /// 重启应用。
    func retireModelSwitch() {
        switchTask?.cancel()
        switchTask = nil
        switchGeneration &+= 1
        host?.switchingModel = nil
        host?.switchStage = ""
        // 排队的模型 id 只属于这台引擎；换引擎/被接管之后它就指向另一份权重
        // 目录里的名字，留着只会在下一次收起时把别人的模型当成这台引擎的。
        queuedSwitchModel = nil
    }

    /// 切换的唯一出口。先核对代数：被接管/被取消的旧任务到这里就静默退出，
    /// 既不会抹掉新切换的状态，也不会把自己忘在「切换中」。当代的结尾负责清
    /// 状态，并把排队的那次选择接着做掉。
    func settleModelSwitch(generation: Int, outcome: EngineController.ModelSwitchOutcome) {
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
        guard let host, host.switchingModel != nil else { return }
        queuedSwitchModel = nil
        retireModelSwitch()
        // 退路回执由阶段行承担：加载仍在后台推进，不再弹浮层。
    }

    /// Keep the stage line honest if the engine moves on its own between stages.
    private func syncSwitchStage() {
        guard let host, host.switchingModel != nil, host.switchStage.isEmpty else { return }
        host.switchStage = host.serverState == .ready ? "加载新模型" : "停止旧模型"
    }

    private func finishModelSwitch(outcome: EngineController.ModelSwitchOutcome) {
        guard let host, host.switchingModel != nil else { return }
        host.switchingModel = nil
        host.switchStage = ""
        switch outcome {
        case .ready:
            // 换模型是读者自己点的那一下的结果，看到「运行中」就够了。
            break
        case .failed(let reason):
            host.notice = reason.isEmpty ? "模型切换失败，请查看日志" : reason
        }
    }

    /// 切换中途被顶掉时的收尾：连排队的那次一起作废。
    func cancelModelSwitch() {
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
}
