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
    @Published var serverState: ServerState = .stopped
    @Published var stats: ServerStats?
    @Published var logs: [LogLine] = []
    @Published var catalog = ModelCatalog()
    @Published var selectedModel: String = ""
    /// Non-nil while newly selected weights are loading. The switchers show an
    /// inline spinner and the overview swaps live metrics for skeletons.
    @Published private(set) var switchingModel: String?
    @Published var runtimeMissing: String?
    @Published var messages: [ChatMessage] = []
    @Published var threads: [ChatThread] = []
    @Published var generating = false
    @Published var generationStatus: String?
    @Published var update: UpdateState = UpdateState()
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
    private var switchTimer: Timer?
    private var switchCompletion: DispatchWorkItem?
    private var switchStartedAt: Date?
    private var switchSawBusy = false
    private var switchSawStarting = false

    let settings = AppSettings()
    let history = ChatHistory()
    let conversation = ConversationStore()
    let chatClient = ChatClient()
    var runtime: EngineRuntime?
    var engines: EngineManager?
    /// Pack installs shown on the engines page; owns its own installer actor.
    let installs = EngineInstallCenter()
    var controller: EngineController? { engines?.active }
    var activeEngine: EngineID { engines?.activeID ?? .splash }
    var availableEngines: [EngineID] { engines?.installedIDs ?? [.splash] }
    var updater: RuntimeUpdater?

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
    var port: Int { controller?.port ?? settings.port }
    var startupStage: String { controller?.startupStage ?? "已停止" }
    var failureMessage: String? { controller?.failureMessage }
    var downloadProgress: Double? { controller?.downloadProgress }
    var runtimeVersion: String { runtime?.version ?? SPLASH_VERSION }
    /// Version of whatever engine is active, so the sidebar names the thing that
    /// is actually running instead of always claiming splash.
    var engineVersion: String {
        if activeEngine == .splash { return runtime?.version ?? SPLASH_VERSION }
        return engines?.controller(activeEngine)?.manifest?.version ?? "—"
    }
    var health: (label: String, tone: TagTone) { healthTone(stats) }

    var installedRuntimes: [String] {
        let root = Paths.runtimesDirectory
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return entries.filter { Paths.fileExists(root + "/" + $0 + "/release.json") }.sorted()
    }

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

        if switchingModel != nil { checkModelSwitch() }
    }

    func bootstrap() {
        let service = ModelCatalogService()
        service.migrateLegacyDirectory()
        Paths.ensureDirectory(Paths.modelsDirectory)

        runtime = EngineRuntime.locate()
        if runtime == nil {
            runtimeMissing = "未找到内置推理运行时。macOS 请使用 make app 打包；开发时可用 FLASHCAT_RUNTIME 指向运行时目录。"
        } else if runtime!.version == SPLASH_VERSION {
            // Bundled runtime is the one this build ships with: clear any override.
            EngineRuntime.selectRuntime(nil)
        }

        catalog = service.load(runtime: runtime)
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

        attachRuntime()
        syncController()

        // Model folders are per engine; build the links once at launch so the
        // models page opens on something usable.
        if activeEngine != .splash {
            EngineModelLinker.synchronize(activeEngine)
            // splash ids do not exist in another engine's model folder, so the
            // saved splash selection must not leak across: prefer this engine's
            // own last model, then whatever the folder actually contains.
            if let saved = EngineStore.shared.configuration(for: activeEngine).lastModel, !saved.isEmpty {
                selectModel(saved)
            } else if let first = engineModels().first {
                selectModel(first.id)
            } else {
                selectedModel = ""
            }
        }

        if settings.autoStart && !selectedModel.isEmpty {
            startService()
        }
    }

    /// Build the controller/updater pair for the currently selected runtime.
    private func attachRuntime() {
        let manager = EngineManager(runtime: runtime, settings: settings, catalog: catalog)
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

        guard let current = runtime else { return }
        let runtimeUpdater = RuntimeUpdater(currentVersion: current.version)
        runtimeUpdater.onStateChanged = { [weak self] value in
            DispatchQueue.main.async { self?.update = value }
        }
        runtimeUpdater.onLog = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.controller?.logs.append("==> " + message, level: .system)
                self.logs = self.controller?.logs.snapshot() ?? []
            }
        }
        runtimeUpdater.onInstalled = { [weak self] installed in
            DispatchQueue.main.async {
                guard let self else { return }
                let wasRunning = self.isRunning
                if wasRunning { self.controller?.stop() }
                self.runtime = installed
                self.catalog = ModelCatalogService().load(runtime: installed)
                self.attachRuntime()
                self.reloadModels()
                self.toast("运行时已更新到 \(installed.version)")
                if wasRunning { self.restartService() }
            }
        }
        updater = runtimeUpdater
        update = runtimeUpdater.currentState
    }

    func switchRuntime(_ version: String?) {
        EngineRuntime.selectRuntime(version)
        guard let located = EngineRuntime.locate() else {
            notice = "找不到该运行时"
            return
        }
        let wasRunning = isRunning
        controller?.stop()
        runtime = located
        catalog = ModelCatalogService().load(runtime: located)
        attachRuntime()
        reloadModels()
        toast("已切换到运行时 \(located.version)")
        if wasRunning { restartService() }
    }

    func reloadModels() {
        catalog = ModelCatalogService().load(runtime: runtime)
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
        if let saved = EngineStore.shared.configuration(for: id).lastModel, !saved.isEmpty {
            selectedModel = saved
            settings.setModel(saved)
        } else if let first = engineModels().first {
            // Switching to an engine must not keep the previous engine's model id.
            selectModel(first.id)
            engines.setModel(first.id, for: id)
        } else {
            selectedModel = ""
        }
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
    func engineModels() -> [EngineModel] {
        let id = activeEngine
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

        let restarting = isRunning
        selectModel(target)
        if activeEngine != .splash {
            // Hot engines swap weights in place; restart engines reload through
            // the supervisor. Either way the switcher shows a loading state.
            engines?.setModel(target, for: activeEngine)
            beginModelSwitch(to: target, restarting: restarting)
            Task { await controller?.switchModel(target) }
            return
        }
        beginModelSwitch(to: target, restarting: restarting)
    }

    func startService() {
        guard !isSwitchingModel else { return }
        if activeEngine != .splash {
            guard !selectedModel.isEmpty else {
                notice = "还没有选择模型"
                return
            }
            Task {
                await controller?.start(localModel: nil, requestedModel: selectedModel)
            }
            return
        }
        guard let model = selectedModelInfo else {
            if !selectedModel.isEmpty, catalog.localModel(selectedModel) == nil {
                notice = "「\(selectedModel)」还没有下载，先到模型页下载，或直接启动让引擎自动拉取"
            } else {
                notice = "还没有本地模型，请先导入或下载一个模型"
            }
            return
        }
        Task { await controller?.start(localModel: model) }
    }

    func stopService() {
        finishModelSwitch(notify: false)
        controller?.stop()
    }

    func toggleService() {
        if isRunning {
            finishModelSwitch(notify: false)
            controller?.stop()
        } else if !isSwitchingModel {
            if activeEngine == .splash {
                Task { await controller?.start(localModel: selectedModelInfo) }
            } else {
                Task { await controller?.start(localModel: nil, requestedModel: selectedModel) }
            }
        }
    }

    func restartService() {
        if activeEngine == .splash {
            Task { await controller?.restart(localModel: selectedModelInfo) }
        } else {
            Task { await controller?.restart(localModel: nil) }
        }
    }

    // MARK: model switch progress

    private func beginModelSwitch(to id: String, restarting: Bool) {
        switchTimer?.invalidate()
        switchTimer = nil
        switchCompletion?.cancel()
        switchCompletion = nil

        switchingModel = id
        switchStartedAt = Date()
        switchSawBusy = false
        switchSawStarting = false

        if restarting {
            toast("正在加载 \(shortModelName(id))…")
            restartService()
            startSwitchTimer()
        } else {
            toast("已切换到 \(shortModelName(id))")
            let work = DispatchWorkItem { [weak self] in self?.finishModelSwitch() }
            switchCompletion = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        }
    }

    private func startSwitchTimer() {
        switchTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkModelSwitch() }
        }
        RunLoop.main.add(timer, forMode: .common)
        switchTimer = timer
    }

    private func checkModelSwitch() {
        guard let target = switchingModel else {
            switchTimer?.invalidate()
            switchTimer = nil
            return
        }

        switch serverState {
        case .starting:
            switchSawBusy = true
            switchSawStarting = true
        case .stopping:
            switchSawBusy = true
        case .ready, .stopped, .failed:
            break
        }

        // The old engine can still report ready for a moment after the click,
        // so wait until it has actually restarted or the new model is reported.
        let readyOnTarget = serverState == .ready
            && (switchSawBusy || stats?.model == target)
        if readyOnTarget || serverState == .failed {
            finishModelSwitch()
        } else if serverState == .stopped, switchSawStarting {
            // The new engine started and then exited without reporting ready;
            // drop the spinner instead of waiting for the long timeout.
            finishModelSwitch()
        } else if let started = switchStartedAt,
                  Date().timeIntervalSince(started) > 300 {
            finishModelSwitch()
        }
    }

    private func finishModelSwitch(notify: Bool = true) {
        guard switchingModel != nil else { return }
        switchTimer?.invalidate()
        switchTimer = nil
        switchCompletion?.cancel()
        switchCompletion = nil

        let succeeded = serverState == .ready
        let failed = serverState == .failed
        switchingModel = nil
        switchStartedAt = nil
        switchSawBusy = false
        switchSawStarting = false

        guard notify else { return }
        if succeeded {
            toast("模型已就绪 · \(shortModelName(selectedModel))")
        } else if failed {
            toast("模型加载失败，请查看日志")
        }
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
        guard let current = runtime else {
            notice = "运行时不可用，无法下载模型"
            return
        }
        let script = current.root + "/install/models.py"
        guard Paths.fileExists(script) else {
            notice = "内置运行时缺少 install/models.py"
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
