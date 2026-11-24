// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Combine
import FlashCatCore
import FlashCatKit
import Foundation

/// 模型选择与服务启停的编排：选模型、跨引擎换模型、待确认的切换、启停重启，
/// 以及「引擎现在到底处在哪个阶段」这句话。
///
/// 搬出来的理由和前面几刀一样：这些动作要同时读引擎会话状态、引擎管理器和
/// 模型库，还要弹提示、写切模型的流程状态，是原先 AppState 里最粗的一束。
/// 依赖全部从 `init` 注进来（都是 store 与编排对象），**不反向持有 AppState**：
/// 回调走 UIStateStore，这是「界面状态」而不是「装配根」。
@MainActor
final class ServiceCoordinator {
    private let session: EngineSessionStore
    private let library: ModelLibraryStore
    private let chat: ChatStore
    private let settings: AppSettings
    private let ui: UIStateStore
    private let engineCoordinator: EngineCoordinator

    init(
        session: EngineSessionStore,
        library: ModelLibraryStore,
        chat: ChatStore,
        settings: AppSettings,
        ui: UIStateStore,
        engineCoordinator: EngineCoordinator
    ) {
        self.session = session
        self.library = library
        self.chat = chat
        self.settings = settings
        self.ui = ui
        self.engineCoordinator = engineCoordinator
    }

    // MARK: 默认选择

    /// Engine + model the app should open with next time. This is a preference,
    /// not the engine that is running: the settings page writes it without
    /// performing a handoff, so the live engine keeps serving its own model.
    var defaultSelection: (engine: EngineID, model: String)? {
        _ = session.defaultRevision
        guard !needsEngineSetup else { return nil }
        let preferred = EngineStore.shared.defaultEngineID ?? engineCoordinator.activeEngine
        let engine =
            engineCoordinator.engineIsInstalled(preferred)
            ? preferred
            : engineCoordinator.activeEngine
        guard engineCoordinator.engineIsInstalled(engine) else { return nil }
        let saved = EngineStore.shared.configuration(for: engine).lastModel ?? ""
        // 当前引擎的真相是 `selectedModel`：少数路径（splash 的即时选择）只写
        // 这里、不写 `engines.json` 的 `lastModel`，回落时不能把行里的模型读丢。
        let remembered =
            engine == engineCoordinator.activeEngine && !session.selectedModel.isEmpty
            ? session.selectedModel
            : saved
        let models = engineCoordinator.engineModels(for: engine).map(\.id)
        guard let model = EngineModelSelection.resolve(saved: remembered, available: models) else { return nil }
        return (engine, model)
    }

    // MARK: 模型选择

    /// Resolve the model this engine should start on. Model ids are engine
    /// scoped — Splash packages are `owner/repo` (e.g. the `omlx/…-e5133ef4`
    /// staging repo oMLX publishes), while the packs serve the `owner--repo`
    /// link names in their own folder. A remembered id from another engine, or
    /// one whose weights have gone, would 404 on every request, so it is
    /// replaced by a model the engine really has and the store is repaired.
    func adoptSavedModel(for id: EngineID) {
        let models = engineCoordinator.engineModels(for: id)
        let saved = EngineStore.shared.configuration(for: id).lastModel
        guard let chosen = EngineModelSelection.resolve(saved: saved, available: models.map(\.id)) else {
            session.selectedModel = ""
            return
        }
        selectModel(chosen)
        if chosen != saved {
            engineCoordinator.engines?.setModel(chosen, for: id)
        }
    }

    func selectModel(_ id: String) {
        session.selectedModel = id
        settings.setModel(id)
        settings.rememberModel(id)
    }

    /// Pick a model from any engine group in the switcher menu. A model
    /// belongs to the engine that serves its format, so one from another
    /// engine hops engines too — without another prompt, because the menu
    /// only ever showed models and the hop is the switch the reader asked
    /// for.
    func applyModelFromAnyEngine(_ id: String, engine: EngineID) {
        guard !chat.generating else {
            ui.toast("正在生成，先停止再切换模型")
            return
        }
        guard engineCoordinator.engineIsInstalled(engine) else {
            engineCoordinator.requestEngineInstall(engine)
            return
        }
        guard engineCoordinator.engineModels(for: engine).contains(where: { $0.id == id }) else {
            ui.toast(L10n.format("%@ 没有模型 %@", engine.displayName, engineCoordinator.shortModelName(id)))
            return
        }
        guard engine != engineCoordinator.activeEngine else {
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
        guard engineCoordinator.engineIsInstalled(engine) else {
            engineCoordinator.requestEngineInstall(engine)
            return
        }
        guard engineCoordinator.engineModels(for: engine).contains(where: { $0.id == id }) else {
            ui.toast(L10n.format("%@ 没有模型 %@", engine.displayName, engineCoordinator.shortModelName(id)))
            return
        }
        EngineStore.shared.setDefaultEngine(engine)
        engineCoordinator.engines?.setModel(id, for: engine)
        session.defaultRevision += 1
        guard engine != engineCoordinator.activeEngine else {
            // This engine is already the one that runs; keeping the old
            // immediate-apply behaviour is what "默认模型" meant for it.
            applyModelFromAnyEngine(id, engine: engine)
            return
        }
        ui.toast(
            L10n.format(
                "已把 %@ 设为 %@ 的默认模型，下次启动生效；当前运行的 %@ 不受影响",
                engineCoordinator.shortModelName(id), engine.displayName,
                engineCoordinator.activeEngine.displayName),
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
        guard let engines = engineCoordinator.engines, engines.controller(engine) != nil else { return }
        let wasRunning = isRunning
        // 跨引擎的新选择必须立刻生效：上一次切换（可能是另一台引擎上几分钟的
        // 权重加载）在这里作废，而不是排队等它结束——排队就是「点了新模型，
        // 界面还停在旧的那一次切换里」。
        engineCoordinator.retireModelSwitch()
        session.confirmingModelSwitch = nil
        let generation = engineCoordinator.currentSwitchGeneration
        // 停着的时候不再只换选择：跨引擎选模型同样意味着「现在就跑它」，
        // 所以界面直接进入「启动引擎」。
        session.switchingModel = model
        session.switchStage = wasRunning ? "停止旧引擎" : "启动引擎"

        engineCoordinator.switchTask = Task { [weak self] in
            guard let self else { return }
            // 只在这里换引擎：等旧引擎真的退出，再让新引擎加载权重。
            let activated = await engines.activate(engine)
            // 被更新的选择接管了：状态与引擎都归那一代，这里静默退出。
            guard generation == self.engineCoordinator.currentSwitchGeneration else { return }
            guard activated || self.engineCoordinator.activeEngine == engine else {
                self.engineCoordinator.settleModelSwitch(
                    generation: generation,
                    outcome: .failed("\(engine.displayName) 没有可用的控制器"))
                return
            }
            self.library.libraryEngine = engine
            self.engineCoordinator.reloadModels()
            // The picked model wins over the engine's remembered one.
            self.selectModel(model)
            engines.setModel(model, for: engine)
            self.engineCoordinator.syncController()

            self.session.switchStage = "加载新模型"
            guard let controller = self.engineCoordinator.controller else {
                self.engineCoordinator.settleModelSwitch(
                    generation: generation,
                    outcome: .failed("\(engine.displayName) 没有可用的控制器"))
                return
            }
            await controller.start(
                localModel: self.library.catalog.machineModel(self.session.selectedModel),
                requestedModel: model)
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
        if target == session.selectedModel {
            // 选回正在切的那一个（或已生效的那一个）= 没必要再动；如果刚才排过
            // 一次别的选择，这次点击就是「改主意」，把队列清掉。
            if isSwitchingModel { engineCoordinator.queuedSwitchModel = nil }
            return
        }
        guard !chat.generating else {
            ui.toast("正在生成，先停止再切换模型")
            return
        }
        if isSwitchingModel {
            // 同引擎的第二次选择不能打断已经在跑的加载（EngineController 单飞），
            // 排到这次切换之后；队列只留最后一次，读者连点三下就是最后一下生效。
            if target != session.switchingModel {
                engineCoordinator.queuedSwitchModel = target
                // 排队只是「你的点击没丢」的一过性回执：不留在通知历史里。
                ui.toast(
                    L10n.format("正在切换模型，完成后自动切到 %@", engineCoordinator.shortModelName(target)),
                    transient: true)
            }
            return
        }

        // The menu only offers this engine's models, but a stale list or an id
        // typed into settings must not reach the wire: the engine would answer
        // 404 and keep retrying it.
        let models = engineCoordinator.engineModels()
        if !EngineModelSelection.isServable(target, available: models.map(\.id)) {
            ui.toast(
                L10n.format(
                    "%@ 没有模型 %@", engineCoordinator.activeEngine.displayName,
                    engineCoordinator.shortModelName(target)))
            return
        }

        // With weights loaded the switch unloads them first, which leaves the
        // engine without a model for a while — ask before doing that. With
        // nothing resident the pick is only a selection, applied on next start.
        guard
            EngineModelSelection.needsConfirmation(
                isRunning: isRunning,
                current: session.selectedModel,
                target: target)
        else {
            commitModelSwitch(to: target)
            return
        }
        session.confirmingModelSwitch = target
    }

    /// Run the switch the reader just approved.
    func confirmModelSwitch() {
        guard let target = session.confirmingModelSwitch else { return }
        session.confirmingModelSwitch = nil
        commitModelSwitch(to: target)
    }

    func cancelModelSwitchRequest() {
        session.confirmingModelSwitch = nil
    }

    private func commitModelSwitch(to target: String) {
        selectModel(target)
        if engineCoordinator.activeEngine != .splash {
            engineCoordinator.engines?.setModel(target, for: engineCoordinator.activeEngine)
        }
        engineCoordinator.beginModelSwitch(to: target)
    }

    // MARK: 服务启停

    func startService() {
        guard !isSwitchingModel else { return }
        guard !needsEngineSetup else {
            ui.notice = "还没有安装推理引擎，请先在启动页选择一个"
            return
        }
        guard !session.selectedModel.isEmpty else {
            ui.notice = "还没有选择模型"
            return
        }
        // Weights already on disk launch in place; an id that is not downloaded
        // yet goes through the requested-model path so the engine's own launcher
        // can fetch it.
        Task {
            await engineCoordinator.controller?.start(
                localModel: library.catalog.machineModel(session.selectedModel),
                requestedModel: session.selectedModel)
        }
    }

    func stopService() {
        engineCoordinator.cancelModelSwitch()
        engineCoordinator.controller?.stop()
    }

    func toggleService() {
        if isRunning {
            stopService()
        } else if !isSwitchingModel {
            startService()
        }
    }

    func restartService() {
        Task {
            await engineCoordinator.controller?.restart(
                localModel: library.catalog.machineModel(session.selectedModel))
        }
    }

    // MARK: 服务状态派生

    var isSwitchingModel: Bool { session.switchingModel != nil }
    /// The process exists. It says nothing about whether the weights are
    /// resident — a starting/switching engine answers no chats yet.
    var isRunning: Bool { engineCoordinator.controller?.isRunning ?? false }
    /// The engine's HTTP layer reports ready, which for hot-loading engines can
    /// happen while the weights are still being mapped in.
    var isReady: Bool { engineCoordinator.controller?.isReady ?? false }

    /// The model is not usable yet: launching, unloading, loading weights,
    /// warming up, or waiting for memory. The lifecycle line and the chat
    /// composer key off this instead of `isRunning`, which is true the moment
    /// the process spawns.
    var isModelBusy: Bool {
        if isSwitchingModel || session.serverState == .starting || session.serverState == .stopping {
            return true
        }
        return session.serverState == .ready && startupStage != EngineStartupStage.ready.rawValue
    }

    /// Only a ready engine with the requested weights really resident may take
    /// a chat request. Sending during the load window is what used to surface
    /// as a request error right after switching models.
    var canChat: Bool {
        !isSwitchingModel
            && session.serverState == .ready
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
        _ = session.lifecycleTick
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
        if session.serverState == .ready {
            let stage = startupStage
            guard stage != EngineStartupStage.ready.rawValue else { return L10n.t("运行中") }
            // 热加载引擎的 HTTP 壳子先绿、权重后到：这一段仍是「模型还不能用」，
            // 秒数不能在最长的一段里消失。用权重加载自己的起点——引擎已经跑了
            // 几个小时再被要求换权重时，进程的起点会给出一个荒唐的数字。
            guard let waited = engineCoordinator.controller?.weightLoadSeconds else { return L10n.t(stage) }
            return [L10n.t(stage), L10n.format("已等待 %@", Format.elapsed(waited))]
                .joined(separator: " · ")
        }
        var parts = [L10n.t(session.serverState.rawValue)]
        let stage = startupStage
        if !stage.isEmpty, stage != session.serverState.rawValue,
            stage != EngineStartupStage.ready.rawValue, stage != "已停止"
        {
            parts.append(L10n.t(stage))
        }
        if session.serverState == .starting {
            parts.append(L10n.format("已等待 %@", Format.elapsed(startupSeconds)))
        }
        return parts.joined(separator: " · ")
    }

    /// 引擎监听的端口：以控制器上报的为准，引擎没起来时按配置、再退回引擎默认端口。
    var port: Int {
        engineCoordinator.controller?.port
            ?? EngineStore.shared.configuration(for: engineCoordinator.activeEngine).port
            ?? engineCoordinator.activeEngine.defaultPort
    }
    var failureMessage: String? { engineCoordinator.controller?.failureMessage }
    var downloadProgress: Double? { engineCoordinator.controller?.downloadProgress }

    var startupStage: String { engineCoordinator.controller?.startupStage ?? "已停止" }
    /// Seconds the current start has been running; 0 while idle. The console
    /// pairs it with the stage so a slow weight load shows elapsed time.
    var startupSeconds: Int { engineCoordinator.controller?.busySeconds ?? 0 }
    /// No engine pack installed yet: the launch page owns the window until one
    /// is chosen.
    var needsEngineSetup: Bool { engineCoordinator.engines?.installedIDs.isEmpty ?? true }
}
