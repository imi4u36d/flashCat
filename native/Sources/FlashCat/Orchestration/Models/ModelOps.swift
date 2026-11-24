// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import Foundation

/// 模型与下载编排：硬件推荐、模型库清单、辅助模型（DFlash2）的绑定，以及
/// 安装 / 应用 / 切换 / 下载这条链的下游动作。
///
/// 这些代码原来长在 `AppState` 的 `// MARK: hardware`、`// MARK: model library`、
/// `// MARK: draft assignments`、`// MARK: models`、`// MARK: download center`
/// 五段里，和界面状态、引擎生命周期、日志挤在同一个类上。它们的共同点是「围绕
/// 模型目录做决定」：删哪个文件、下哪个仓库、下完要不要把选中模型换过去、推荐页
/// 该不该弹——都不需要知道 SwiftUI 怎么画，只需要模型库、设置与引擎目录。
///
/// 状态一个都没复制：清单 / 公共仓库 / 推荐结果仍在 `ModelLibraryStore`，选中
/// 模型仍在 `EngineSessionStore`，下载进度仍在 `DownloadCenter`。这里只留下
/// 「这一轮下载 / 补件」自己的局部状态（`supplementInFlight`）和模型库清单的短
/// 缓存（`libraryEntriesCache`），后者由 `AppState.invalidateModelCaches()` 一并
/// 清掉。
///
/// 要回头找 `AppState` 办的事（停引擎、切模型、弹提示、写日志、退出前收后端）
/// 用 `Hooks` 闭包接回来：这里不认识 `AppState.shared`，才不会反过来把它拽进环。
@MainActor
final class ModelOps {
    /// 只认识 `ModelHost` 协议。弱引用：外层持有本对象，强引用回去就是一个环。
    weak var host: (any ModelHost)?

    /// 依赖全部构造时注入：这里不读单例，也就能在没有界面的地方单独构造出来跑。
    private let settings: AppSettings
    private let downloads: DownloadCenter
    /// Internal so tests can assert the queued request without a display path.
    let modelLibrary: ModelLibraryStore
    /// 引擎目录、引擎侧扫描缓存与模型清单都归它：删模型、下模型都得先重扫。
    private let engineCoordinator: any EngineCataloging

    /// 启动前补件期间为真：那段时间的下载收尾不能再另起一次切模型。
    private var supplementInFlight = false

    /// 模型目录扫描的短缓存。`libraryEntries(for:)` 会被侧栏计数、模型页、
    /// 选择器等视图在每次重绘时调用；以前每秒的指标刷新都会触发多次目录枚举
    /// 与 JSON 读取。这里缓存 1 秒，下载/删除/重新加载时立即失效。
    /// 引擎侧那份同名缓存在 `EngineCoordinator` 手里，共用这一档 TTL。
    static let modelListTTL: TimeInterval = 1.0
    private var libraryEntriesCache: [EngineID: (entries: [ModelLibraryEntry], at: Date)] = [:]

    init(
        settings: AppSettings,
        downloads: DownloadCenter,
        modelLibrary: ModelLibraryStore,
        engineCoordinator: any EngineCataloging
    ) {
        self.settings = settings
        self.downloads = downloads
        self.modelLibrary = modelLibrary
        self.engineCoordinator = engineCoordinator
    }

    /// 模型库清单的扫描缓存：和引擎那份一起在下载 / 删除 / 重扫时失效。
    func invalidateLibraryCache() {
        libraryEntriesCache.removeAll()
    }

    // MARK: - store 转发（状态不复制，只转发）

    private var catalog: ModelCatalog { modelLibrary.catalog }
    private var localModelRepos: [String] { modelLibrary.localModelRepos }
    private var libraryEngine: EngineID { modelLibrary.libraryEngine }
    private var hardwareRecommendation: HardwareRecommendation? {
        get { modelLibrary.hardwareRecommendation }
        set { modelLibrary.hardwareRecommendation = newValue }
    }
    private var showsRecommendationPage: Bool {
        get { modelLibrary.showsRecommendationPage }
        set { modelLibrary.showsRecommendationPage = newValue }
    }
    private var pendingRecommendedDownload: (engine: EngineID, model: String)? {
        get { modelLibrary.pendingRecommendedDownload }
        set { modelLibrary.pendingRecommendedDownload = newValue }
    }
    private var pendingLibraryUse: LibraryUseRequest? {
        get { modelLibrary.pendingLibraryUse }
        set { modelLibrary.pendingLibraryUse = newValue }
    }
    private var tuningRevision: Int { modelLibrary.tuningRevision }
    private var downloadingModel: String? { downloads.downloadingModel }

    // MARK: - 回到 AppState 的动作

    private var activeEngine: EngineID { host?.activeEngine ?? .splash }
    private var selectedModel: String {
        get { host?.selectedModel ?? "" }
        set { host?.selectedModel = newValue }
    }
    private var needsEngineSetup: Bool { host?.needsEngineSetup ?? true }
    /// 当前引擎控制器：切过引擎之后旧的那个已经没用了，每次现取。
    private var controller: EngineController? { engineCoordinator.engines?.active }

    private func reloadModels() { engineCoordinator.reloadModels() }

    private func engineModels(for engine: EngineID) -> [EngineModel] { engineCoordinator.engineModels(for: engine) }

    private func shortModelName(_ id: String) -> String { engineCoordinator.shortModelName(id) }

    private func engineIsInstalled(_ id: EngineID) -> Bool { engineCoordinator.engineIsInstalled(id) }

    private func requestEngineInstall(_ id: EngineID) { engineCoordinator.requestEngineInstall(id) }

    @discardableResult
    private func switchEngine(_ id: EngineID, start: Bool = true) async -> Bool {
        await engineCoordinator.switchEngine(id, start: start)
    }

    private func stopService() { host?.stopService() }

    private func adoptSavedModel(for engine: EngineID) { host?.adoptSavedModel(for: engine) }

    private func applyModel(_ id: String) { host?.applyModel(id) }

    private func applyModelFromAnyEngine(_ id: String, engine: EngineID) {
        host?.applyModelFromAnyEngine(id, engine: engine)
    }

    private var notice: String? {
        get { host?.notice }
        set { host?.notice = newValue ?? "" }
    }

    private func toast(_ message: String, kind: IslandNotice.Kind? = nil, transient: Bool = false) {
        host?.toast(message, kind: kind, transient: transient)
    }

    private func append(log line: String, engine: EngineID) { host?.appendLog(line, engine: engine) }

    // MARK: hardware

    /// Work out what this Mac should run, and open the first-run page while
    /// nothing is installed yet.
    ///
    /// The answer is recomputed on every launch instead of recalled: the
    /// catalogs live inside the engine packs, so an engine update is the new
    /// answer. Until a pack with a catalog is installed there is nothing to
    /// pick, and the page stays away — the engine list is the first-run screen.
    func settleRecommendation() {
        recomputeRecommendation()
        // Someone who already had engines before this feature existed keeps
        // their models: they get the tags silently, not a page telling them to
        // start over. Writing `seen` here is also what stops an upgraded user
        // whose packs later go missing from landing on a first-run page.
        guard needsEngineSetup else {
            settings.setHardwareRecommendationSeen(true)
            return
        }
        guard !settings.hardwareRecommendationSeen else { return }
        guard !(hardwareRecommendation?.picks.isEmpty ?? true) else { return }
        showsRecommendationPage = true
    }

    private func recomputeRecommendation() {
        ModelRecommendations.invalidate()
        let recommendation = HardwareAdvisor.recommend(machine: DeviceProfile.current().machine)
        hardwareRecommendation = recommendation
        settings.setHardwareRecommendation(recommendation)
    }

    /// Puts away the first-run page without answering it — used when an engine
    /// arrives by other means (engines page, another install finishing), so the
    /// page can never outlive its precondition and hide the launch page.
    func dismissRecommendationPage() {
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

    /// 记住用户选中的推荐引擎，等安装完 `adoptEngine` 时自动拉取推荐模型；
    /// 刻意不在这里关掉推荐页，让用户在原位看到实时安装进度。
    func armRecommendedDownload(for engine: EngineID) {
        guard let pick = hardwareRecommendation?.pick(for: engine) else { return }
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
            ModelLibraryEntry.normalized(pick.model) == ModelLibraryEntry.normalized(id)
        else { return nil }
        return L10n.format("推荐 · %@", pick.reason)
    }

    /// An install that failed voids whatever the first-run page armed for it:
    /// a later install of the same engine must not silently start a
    /// multi-gigabyte model download the user did not ask for again.
    func engineInstallFailed(_ engine: EngineID) {
        if pendingRecommendedDownload?.engine == engine { pendingRecommendedDownload = nil }
    }

    // MARK: model library

    /// The rows this engine ships in its own pack: Splash's suggested-models
    /// list, MTPLX's official catalog. oMLX and MLX-Serve ship none.
    func libraryRecommendations(for engine: EngineID) -> [ModelRecommendation] {
        ModelRecommendations.list(for: engine)
    }

    /// Installed weights plus the engine's suggestions as one grid — the same
    /// rows whether or not that engine is installed, running or holding a model.
    func libraryEntries(for engine: EngineID) -> [ModelLibraryEntry] {
        if let hit = libraryEntriesCache[engine],
            Date().timeIntervalSince(hit.at) < Self.modelListTTL
        {
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
                return ModelInfo(
                    id: model.id,
                    path: path,
                    bytes: model.bytes ?? 0,
                    origin: .local,
                    targetName: "",
                    quantization: ModelQuantization.detect(in: model.id)
                        ?? EngineModelStore.meta(of: path).quantization)
            }
        }
        return ModelLibrary.entries(
            installed: installed,
            engine: engine,
            recommendations: libraryRecommendations(for: engine)
        ) { id in
            engine.adapter == .splash ? self.catalog.draftRepository(id, family: nil) : nil
        }
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
            toast(
                L10n.format("已为 %@ 指定辅助模型 %@", shortModelName(model), shortModelName(draft)),
                transient: true)
        } else {
            toast(
                L10n.format("已清除 %@ 的辅助模型，跟随引擎设置", shortModelName(model)),
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
        let path =
            engineModels(for: engine).first(where: { $0.id == id })?.path
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

    /// Fetch weights into one engine's own model folder. Both paths download
    /// through the huggingface_hub that ships inside the engine packs: Splash's
    /// installer picks the single GGUF quant out of a repository that carries a
    /// dozen and prepares its assembly, while the other engines run flashCat's
    /// snapshot downloader into their folder (MLX-Serve borrows a Python pack
    /// when it needs a quant pick or a mirror).
    ///
    /// Pause and cancel terminate the child process; the Hub keeps partial
    /// files in the destination's `.cache`, so resuming later — even after a
    /// relaunch — continues from the bytes already on disk.
    ///
    /// - Parameter family: the model's Splash family when the caller knows it,
    ///   which picks the released DFlash2 draft more surely than the id does.
    /// - Parameter source: the Hub the model plaza's user picked.
    /// - Parameter include: the file patterns of one GGUF quant, when the
    ///   caller chose a quant instead of the whole repository.
    /// - Parameter activate: whether finishing the transfer should also make
    ///   the model current. The Model Hub downloads only; the model page asks
    ///   for the switch.
    /// - Returns: whether the download started. A `false` comes with a `notice`.
    @discardableResult
    func downloadModel(
        _ id: String, engine: EngineID, family: String? = nil,
        source: HubSource? = nil, include: [String] = [], activate: Bool = true
    ) -> Bool {
        guard downloadingModel == nil else {
            toast("正在下载另一个模型，先等它结束")
            return false
        }
        reloadModels()
        guard !repoIsLocal(id) else {
            notice = "「\(id)」已经在本机了，不用重复下载"
            return false
        }
        // Splash resolves its own released DFlash2 draft from the family when
        // the installer is not told about one; the pack's list is the source of
        // truth. Other engines carry their draft inside the pack.
        let draft =
            engine.adapter == .splash
            ? catalog.draftRepository(id, family: family)
            : nil
        let origin = source ?? HubSource.downloadSource

        let plan: ModelInstaller.Plan
        do {
            plan = try ModelInstaller.plan(
                engine: engine,
                model: id,
                draftRepository: draft,
                cache: settings.hfCache,
                source: origin,
                include: include)
        } catch {
            notice = (error as? ModelInstaller.Failure)?.message ?? "\(error)"
            return false
        }
        return downloads.startDownload(
            plan, engine: engine, id: id, shared: nil,
            source: origin, include: include.isEmpty ? nil : include,
            activate: activate)
    }

    /// 从 Hub 下任意仓库到公共目录，并记下它给哪些引擎用。
    ///
    /// 这是「开放下载」的入口：不设格式/家族门槛，支持与否交给用户自己
    /// 判断。卡片只负责标明来源（引擎推荐 / 个人下载），不再把人挡在门外。
    /// - Returns: whether the transfer started. `false` comes with a `notice`,
    ///   which the control server (and therefore the CLI) reports verbatim.
    @discardableResult
    func downloadShared(
        _ repo: String, engines: [EngineID],
        source: HubSource = HubSource.downloadSource,
        include: [String] = []
    ) -> Bool {
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
            plan = try ModelInstaller.sharedPlan(
                repo: target,
                engines: engines,
                cache: settings.hfCache,
                source: source,
                include: include)
        } catch {
            notice = (error as? ModelInstaller.Failure)?.message ?? "\(error)"
            return false
        }
        return downloads.startDownload(
            plan, engine: engines.first ?? libraryEngine, id: target,
            shared: engines, source: source, include: include.isEmpty ? nil : include)
    }

    /// 改一个共享模型能被哪些引擎看见：写授权表并同步链接，模型页随即重算。

    /// 这个仓库是不是已经在本机了（公共目录或任一引擎的模型目录）。
    /// 判定放在这里而不是视图：置灰只是表现，真正的门在这儿。
    func repoIsLocal(_ repo: String) -> Bool {
        localModelRepos.contains(ModelSharing.canonical(repo))
    }

    /// 这份权重落在哪个引擎的目录里，用来把「在模型页查看」带到真正看得见
    /// 它的那一栏。公共目录优先看授权表；引擎目录则按扫描结果找。
    func engineHolding(_ id: String) -> EngineID? {
        let repo = ModelSharing.canonical(id)
        if ModelSharing.isShared(repo) {
            let engines = ModelSharing.engines(for: repo)
            if engines.contains(activeEngine) { return activeEngine }
            return EngineCatalog.allIDs.first { engines.contains($0) }
        }
        let key = ModelLibraryEntry.normalized(repo)
        func holds(_ engine: EngineID) -> Bool {
            if engine.adapter == .splash {
                return catalog.machine.contains {
                    ModelLibraryEntry.normalized($0.id) == key
                }
            }
            return engineModels(for: engine).contains {
                ModelLibraryEntry.normalized($0.id) == key
            }
        }
        if holds(activeEngine) { return activeEngine }
        return EngineCatalog.allIDs.first(where: holds)
    }

    func setSharedEngines(_ engines: [EngineID], repo: String) {
        let repo = ModelSharing.canonical(repo)
        ModelSharing.setEngines(Set(engines), for: repo)
        EngineModelStore.invalidateMetaCache()
        reloadModels()
        toast(
            engines.isEmpty
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
        if Set(engines) == Set(EngineCatalog.allIDs) {
            toast("已下载 " + repo + "，所有引擎的模型页都能看到")
        } else {
            toast("已下载 " + repo + "，可用于 " + engines.map(\.displayName).joined(separator: "、"))
        }
    }

    /// Run a download and wait for it to end.
    ///
    /// Only the launch path uses this: a start that has to fetch the model's
    /// DFlash2 draft hands the engine a model that is complete, so the engine
    /// never has to download inside its own startup (its launcher refuses to
    /// touch the network).
    private func downloadAndWait(_ id: String, engine: EngineID, family: String?) async -> DownloadOutcome {
        guard downloads.downloadingModel == nil else {
            let other = downloads.downloadingModel.map(shortModelName) ?? "另一个模型"
            return .failed("正在下载 \(other)，等它结束后再启动")
        }
        return await withCheckedContinuation { continuation in
            downloads.setCompletion { continuation.resume(returning: $0) }
            if !downloadModel(id, engine: engine, family: family) {
                // Nothing started, so nothing will call back: release the
                // caller with the notice downloadModel already wrote.
                downloads.setCompletion(nil)
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

    // MARK: download center

    /// 下载中心对外的门面。界面与本地控制通道（`ControlServer+Documents`）
    /// 原来直接调这些方法，搬进 store 之后仍然从这里转一下——策略留在这一侧，
    /// 传输动作委托出去。
    func pauseDownload() { downloads.pauseDownload() }

    /// Continue a paused transfer: the same snapshot downloader runs again and
    /// the Hub resumes its partial files.
    func resumeDownload(_ task: ModelDownloadTask) {
        // 下进公共目录的任务要回到公共目录，否则续传会另起一份到引擎目录里。
        if let engines = task.shared, !engines.isEmpty {
            downloadShared(
                task.model,
                engines: engines,
                source: task.source ?? HubSource.downloadSource,
                include: task.include ?? [])
            return
        }
        downloadModel(
            task.model, engine: task.engine,
            source: task.source ?? HubSource.downloadSource,
            include: task.include ?? [],
            activate: task.activateOnFinish ?? true)
    }

    func cancelDownload(_ task: ModelDownloadTask) { downloads.cancelDownload(task) }

    /// Remove a finished/failed/stale row from the center.
    func removeTask(_ task: ModelDownloadTask) { downloads.removeTask(task) }

    /// Quit-time cleanup that is not engine lifecycle. Gateway and control
    /// server first, then the downloader child: an orphaned one keeps pulling
    /// gigabytes to disk with no window left to stop it from.
    func prepareForTermination() {
        host?.stopBackends()
        downloads.prepareForTermination()
    }

    func finishTermination() {
        downloads.finishTermination()
    }

    /// 下载收尾。这两件事都要看当前引擎与启动流程，所以由这里消费，
    /// store 只报告「下完了」。
    ///
    /// 这里不写 `private`：唯一的调用点是 `AppState.init` 里 `downloads.onEvent`
    /// 的接线，得在类外可达。
    func handle(_ event: DownloadEvent) {
        switch event {
        case .modelReady(let engine, let model, let installed, let activate):
            // 启动前补件之后紧跟的是启动本身：没有提示要回答，选中模型也不能
            // 在启动底下被换掉。
            guard !supplementInFlight else { return }
            guard engine == activeEngine else {
                toast(L10n.format("已下载 %@，切到 %@ 就能用", model, engine.displayName))
                return
            }
            guard activate else {
                toast(L10n.format("已下载 %@，已在模型库", model))
                return
            }
            applyModel(installed)
            toast(L10n.format("已下载 %@", model))
        case .shareRequested(let repo, let engines):
            publishShared(repo: repo, engines: engines)
        }
    }
}
