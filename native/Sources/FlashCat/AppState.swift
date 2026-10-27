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
        case .engines: return "shippingbox.and.arrow.backward"
        case .logs: return "doc.plaintext"
        case .settings: return "slider.horizontal.3"
        }
    }
}

enum ThroughputRange: String, CaseIterable, Identifiable {
    case seconds45 = "45 秒"
    case minutes5 = "5 分钟"

    var id: String { rawValue }
    var seconds: TimeInterval { self == .seconds45 ? 45 : 300 }
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
    @Published var throughputRange: ThroughputRange = .seconds45
    @Published var downloadingModel: String?
    @Published var downloadFraction: Double?

    private var toastWork: DispatchWorkItem?
    /// The single task that owns a model switch. Nothing else may touch the
    /// engine while it runs — the old weights must be confirmed gone before the
    /// new ones allocate.
    private var switchTask: Task<Void, Never>?

    let settings = AppSettings()
    let history = ChatHistory()
    let conversation = ConversationStore()
    let chatClient = ChatClient()
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
        let visible = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true
        sidebarVisibility = visible ? .all : .detailOnly
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

    func throughput(in range: ThroughputRange) -> [ThroughputSample] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        return throughput.filter { $0.at >= cutoff }
    }

    var endpointURL: String { "http://127.0.0.1:\(port)/v1" }

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
        // Model ids do not carry across engines: a remembered id is only kept
        // when this engine can actually serve it, otherwise the folder's own
        // models win.
        adoptSavedModel(for: activeEngine)

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
        installs.configure(onChange: { [weak self] in
            guard let self else { return }
            self.engines?.rebuild()
            self.reloadModels()
            self.syncController()
            self.objectWillChange.send()
        })
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

    /// Only one engine runs at a time: two MLX engines would fight for the same
    /// unified memory, so switching stops the old one first.
    func switchEngine(_ id: EngineID) {
        guard let engines, id != engines.activeID else { return }
        guard !isSwitchingModel else {
            toast("正在切换模型，稍后再换引擎")
            return
        }
        let wasRunning = isRunning
        engines.activate(id)
        reloadModels()
        // Switching to an engine must not keep the previous engine's model id:
        // the remembered one only survives if this engine can serve it.
        adoptSavedModel(for: id)
        syncController()
        if wasRunning { startService() }
        toast("已切换到 \(id.displayName)")
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
        return LocalEngineModels.scan(engine: id, directory: EnginePaths.modelsDirectory(id))
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

    func importModel(_ source: String, move: Bool = false) {
        let service = ModelCatalogService()
        importProgress = ImportProgress(fraction: 0, message: "正在复制…")
        Task {
            do {
                let result = try service.importDirectory(source, move: move) { fraction, message in
                    DispatchQueue.main.async { self.importProgress = ImportProgress(fraction: fraction, message: message) }
                }
                importProgress = nil
                reloadModels()
                selectModel(result.id)
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

    /// Fetch weights for a hub model through the runtime's own installer, so the
    /// draft model and manifest land where the engine expects them.
    func downloadModel(_ id: String) {
        guard downloadingModel == nil else { return }
        guard let current = splashRuntime else {
            notice = "还没有安装 Splash 引擎，无法下载模型"
            return
        }
        let script = current.root + "/install/models.py"
        guard Paths.fileExists(script) else {
            notice = "Splash 引擎缺少 install/models.py"
            return
        }

        downloadingModel = id
        downloadFraction = 0
        Paths.ensureDirectory(Paths.modelsDirectory)

        var arguments = ["-u", script, "--models", Paths.modelsDirectory, "--model", id]
        if let draft = catalog.draftRepository(id, family: nil) {
            arguments += ["--draft-model", draft]
        }
        arguments.append("prepare")

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        let cache = settings.hfCache.trimmingCharacters(in: .whitespaces)
        if !cache.isEmpty { environment["HF_HUB_CACHE"] = cache }

        controller?.logs.append("==> 准备下载模型：\(id)", level: .system)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: current.pythonPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: current.root)
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        TailReader.read(pipe) { line in
            DispatchQueue.main.async {
                self.controller?.logs.append(line, level: .system)
                if let match = TextPattern.firstMatch("(\\d{1,3})%", line), let value = Double(match[1]) {
                    self.downloadFraction = min(max(value / 100, 0), 1)
                }
                self.logs = self.controller?.logs.snapshot() ?? []
            }
        }

        process.terminationHandler = { finished in
            DispatchQueue.main.async {
                self.downloadingModel = nil
                self.downloadFraction = nil
                self.reloadModels()
                if finished.terminationStatus == 0 {
                    self.applyModel(id)
                    self.toast("已下载 \(id)")
                } else {
                    self.notice = "模型下载失败，退出码 \(finished.terminationStatus)"
                }
            }
        }

        do {
            try process.run()
        } catch {
            downloadingModel = nil
            downloadFraction = nil
            notice = "无法启动下载：\(error.localizedDescription)"
        }
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
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                if let text = String(data: line, encoding: .utf8) {
                    onLine(text)
                }
            }
        }
    }
}
