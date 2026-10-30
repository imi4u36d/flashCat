//
//  WebViewShell.swift
//  flashCat
//
//  「精密仪器」WebUI 宿主：Swift 引擎管线保持不变，UI 层整体换成
//  docs/ui/redesign-precision-instrument.html 的 1:1 网页实现。
//
//  数据流：
//    Swift → JS  全量状态快照（Combine 订阅 + 1s 心跳，去抖 0.1s 合并）
//    JS → Swift  webkit.messageHandlers.bridge 命令（JSON：type + payload）
//

import SwiftUI
import WebKit
import Combine
import FlashCatKit

struct WebViewShell: NSViewRepresentable {
    @ObservedObject var state: AppState

    func makeCoordinator() -> WebBridge {
        WebBridge(state: state)
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // 快照推送由 Combine 驱动，这里不需要逐帧同步。
    }
}

// MARK: - Page naming

private extension Page {
    var webName: String {
        switch self {
        case .overview: return "overview"
        case .chat: return "chat"
        case .models: return "models"
        case .engines: return "engines"
        case .logs: return "logs"
        case .settings: return "settings"
        }
    }

    static func from(webName: String) -> Page? {
        allCases.first { $0.webName == webName }
    }
}

private extension AppAppearance {
    var webName: String {
        switch self {
        case .system: return "system"
        case .light: return "light"
        case .dark: return "dark"
        }
    }
}

// MARK: - Bridge

@MainActor
final class WebBridge: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    private let state: AppState
    private var cancellables: Set<AnyCancellable> = []
    private var heartbeat: Timer?
    private var pushScheduled = false

    init(state: AppState) {
        self.state = state
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "bridge")

        if let index = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "WebUI") {
            webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        }
        webView.setValue(false, forKey: "drawsBackground") // 皮肤底色由页面接管

        // 任何 @Published 变化 → 去抖后推送快照。
        state.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.schedulePush() }
            .store(in: &cancellables)

        // 心跳：概览的 UP 计时、吞吐窗口、日志跟随都需要与真实时间同步。
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let page = self.state.section.webName as String? else { return }
                if page == "overview" || page == "logs" || self.state.generating {
                    self.pushSnapshot()
                }
                // 启动页可见时持续拉索引，行上的「最新 vX」才会出现。
                if self.state.isPresentingLaunchPage {
                    await self.state.installs.loadIndexIfNeeded()
                }
            }
        }

        // 页面加载完成后立即推送首帧。
        webView.navigationDelegate = self
    }

    // MARK: JS → Swift

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard message.name == "bridge",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        Task { @MainActor in
            self.handle(type: type, body: body)
        }
    }

    private func handle(type: String, body: [String: Any]) {
        let engine = { () -> EngineID? in
            guard let raw = body["engine"] as? String else { return nil }
            return EngineID(rawValue: raw)
        }()
        switch type {
        case "nav":
            if let name = body["page"] as? String, let page = Page.from(webName: name) {
                state.section = page
                if page == .engines {
                    // 上游版本检查跟着引擎页触发（原生页是 .task，网页壳在这里补）。
                    Task { @MainActor in
                        state.installs.refreshInstalled()
                        await state.installs.loadIndexIfNeeded()
                        await state.installs.checkUpstream(force: true)
                    }
                }
            }
        case "startService": state.startService()
        case "stopService": state.stopService()
        case "restartService": state.restartService()
        case "switchEngine": if let engine { state.switchEngine(engine) }
        case "browseEngine": if let engine { state.browseEngine(engine) }
        case "useModel":
            if let engine, let id = body["id"] as? String { state.useModel(id, engine: engine) }
        case "downloadModel":
            if let engine, let id = body["id"] as? String { state.downloadModel(id, engine: engine) }
        case "removeModel":
            if let engine, let id = body["id"] as? String { state.removeModel(id, engine: engine) }
        case "revealModel":
            if let engine, let id = body["id"] as? String {
                let entry = state.libraryEntries(for: engine).first { $0.id == id }
                if let path = entry?.model.path, !path.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        case "sendChat":
            if let text = body["text"] as? String, !text.isEmpty { state.send(text) }
        case "stopGeneration": state.cancelGeneration()
        case "regenerate": state.regenerate()
        case "newChat": state.newConversation()
        case "openThread":
            if let id = body["id"] as? String, let thread = state.threads.first(where: { $0.id == id }) {
                state.openThread(thread)
            }
        case "clearChat": state.newConversation()
        case "clearThreads": state.clearThreads()
        case "copyConversation":
            let body = state.messages
                .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { "\($0.role == "user" ? "你" : "AI")\n\($0.content)" }
                .joined(separator: "\n\n")
            guard !body.isEmpty else { break }
            state.copy(body, label: "已复制整段对话")
        case "copyText":
            state.copy(body["text"] as? String ?? "", label: body["label"] as? String ?? "已复制")
        case "copyGateway": state.copy(state.gatewayURL, label: "网关地址已复制")
        case "copyLogText":
            if let text = body["text"] as? String, !text.isEmpty {
                state.copy(text, label: "已复制筛选后的日志")
            }
        case "clearLogs": state.clearLogs()
        case "openFinder": openFinder(body)
        case "rescan":
            _ = EngineModelLinker.synchronize(engine ?? state.activeEngine)
            state.reloadModels()
            state.toast("已重新扫描 \((engine ?? state.activeEngine).displayName) 的模型目录")
        case "importModels": pickAndImport(engine: engine)
        case "installEngine":
            if let engine {
                installEngine(engine, adoptOnFirstInstall: (body["launch"] as? Bool) ?? state.needsEngineSetup)
            }
        case "openLaunchPage": state.showsLaunchPage = true
        case "finishLaunch": state.showsLaunchPage = false
        case "pauseDownload": state.pauseDownload()
        case "resumeDownload": downloadTask(from: body) { state.resumeDownload($0) }
        case "cancelDownload": downloadTask(from: body) { state.cancelDownload($0) }
        case "removeTask": downloadTask(from: body) { state.removeTask($0) }
        case "saveEngineConfig":
            if let engine { saveEngineConfig(engine, body) }
        case "confirmEngineInstall": state.confirmEngineInstall()
        case "cancelEngineInstall": state.cancelEngineInstall()
        case "setGatewayEnabled":
            state.settings.setGatewayEnabled((body["on"] as? Bool) ?? false)
            state.applyGatewaySettings()
        case "setGatewayPort":
            if let port = body["port"] as? Int, (1024...65535).contains(port) {
                state.settings.setGatewayPort(port)
                state.applyGatewaySettings()
            }
        case "appearance":
            if let raw = body["mode"] as? String {
                let mode: AppAppearance
                switch raw {
                case "light": mode = .light
                case "dark": mode = .dark
                default: mode = .system
                }
                state.theme.set(mode)
            }
        case "saveSettings": saveSettings(body)
        case "confirmLibraryUse": state.confirmLibraryUse()
        case "cancelLibraryUse": state.cancelLibraryUse()
        case "confirmModelSwitch": state.confirmModelSwitch()
        case "cancelModelSwitch": state.cancelModelSwitchRequest()
        case "toast": state.toast(body["message"] as? String ?? "")
        default: break
        }
        schedulePush()
    }

    private func openFinder(_ body: [String: Any]) {
        let engine = (body["engine"] as? String).flatMap(EngineID.init(rawValue:))
        switch body["kind"] as? String {
        case "engines":
            let directory = EnginePaths.enginesDirectory
            Paths.ensureDirectory(directory)
            NSWorkspace.shared.open(URL(fileURLWithPath: directory))
        case "models":
            let directory = EnginePaths.modelsDirectory(state.libraryEngine)
            Paths.ensureDirectory(directory)
            NSWorkspace.shared.open(URL(fileURLWithPath: directory))
        case "engineModels":
            guard let engine else { break }
            let directory = EnginePaths.modelsDirectory(engine)
            Paths.ensureDirectory(directory)
            NSWorkspace.shared.open(URL(fileURLWithPath: directory))
        case "engineLogs":
            guard let engine else { break }
            let path = EnginePaths.logFile(engine)
            guard Paths.fileExists(path) else {
                state.toast("该引擎还没有日志文件")
                break
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case "logs":
            guard Paths.fileExists(Paths.logFile) else {
                state.toast("日志文件尚未创建")
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Paths.logFile)])
        default: break
        }
    }

    private func pickAndImport(engine: EngineID?) {
        let target = engine ?? state.libraryEngine
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        panel.message = "选择要导入 \(target.displayName) 的模型目录"
        if panel.runModal() == .OK, let url = panel.url {
            state.importModel(url.path, move: false, engine: target)
        }
    }

    /// 按 engine+model 定位下载中心里的任务行（网页不持有任务对象）。
    private func downloadTask(from body: [String: Any], _ perform: (ModelDownloadTask) -> Void) {
        guard let raw = body["engine"] as? String, let engine = EngineID(rawValue: raw),
              let model = body["model"] as? String,
              let task = state.downloadTasks.first(where: { $0.engine == engine && $0.model == model }) else { return }
        perform(task)
    }

    /// 网页侧的引擎安装：优先走发布索引直装，索引里没有再走上游构建，
    /// 两者都没有时只提示。启动页发起的首次安装会把新引擎设为活动引擎。
    private func installEngine(_ engine: EngineID, adoptOnFirstInstall: Bool) {
        let center = state.installs
        if adoptOnFirstInstall {
            center.onInstalled = { [weak state] id in
                state?.adoptEngine(id)
                state?.installs.onInstalled = nil
            }
        } else {
            center.onInstalled = nil
        }
        let latest = center.releases[engine]?.max { EngineVersionOrder.isNewer($1.version, than: $0.version) }
        if let latest {
            center.install(latest, for: engine)
        } else if case .update(_, let release) = center.upstream[engine] {
            center.buildAndInstall(release, for: engine)
        } else {
            state.toast("暂时没有 \(engine.displayName) 的可用安装版本")
        }
    }

    /// 网页配置面板的保存：调优参数 + 可选端口变更，oMLX 的开关保存后按模型重新加载。
    private func saveEngineConfig(_ engine: EngineID, _ body: [String: Any]) {
        guard let tuningObject = body["tuning"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: tuningObject),
              let tuning = try? JSONDecoder().decode(EngineTuning.self, from: data) else {
            state.toast("配置格式有误，未能保存")
            return
        }
        EngineStore.shared.setTuning(tuning.sanitized(), for: engine)
        if let portText = body["port"] as? String,
           let port = Int(portText.trimmingCharacters(in: .whitespaces)),
           (1024...65535).contains(port),
           port != (EngineStore.shared.configuration(for: engine).port ?? engine.defaultPort) {
            state.switchEnginePort(engine, port: port)
        }
        if let stored = EngineStore.shared.configuration(for: engine).tuning, stored.omlxHeadsConflict {
            state.toast("oMLX 不允许 MTP 与 DFlash2 同时开启，已保留一个")
        }
        Task { await state.engines?.controller(engine)?.reapplyTuning() }
        state.toast("\(engine.displayName) 的配置已保存")
    }

    private func saveSettings(_ body: [String: Any]) {
        let settings = state.settings
        let engine = state.activeEngine
        var activePortChanged = false

        if let ports = body["ports"] as? [String: Any] {
            for id in EngineID.allCases {
                guard let text = ports[id.rawValue] as? String,
                      let value = Int(text.trimmingCharacters(in: .whitespaces)),
                      (1024...65535).contains(value) else { continue }
                let stored = EngineStore.shared.configuration(for: id).port ?? id.defaultPort
                if value != stored {
                    state.switchEnginePort(id, port: value)
                    if id == engine { activePortChanged = true }
                }
            }
        }
        let before = (thinking: settings.thinkingMode,
                      effort: settings.reasoningEffort,
                      model: settings.model,
                      hfCache: settings.hfCache)
        if let thinking = body["thinking"] as? String, let mode = ThinkingMode(webName: thinking),
           mode != settings.thinkingMode {
            settings.setThinkingMode(mode)
        }
        if let effort = body["effort"] as? String, let value = ReasoningEffort(webName: effort),
           value != settings.reasoningEffort {
            settings.setReasoningEffort(value)
        }
        if let autoStart = body["autoStart"] as? Bool { settings.setAutoStart(autoStart) }
        if let launchAtLogin = body["launchAtLogin"] as? Bool {
            LoginItem.set(enabled: launchAtLogin)
            settings.setLaunchAtLogin(launchAtLogin)
        }
        if let hfCache = body["hfCache"] as? String {
            let expanded = WebPaths.expandTilde(hfCache)
            if expanded != settings.hfCache { settings.setHfCache(expanded) }
        }
        if let model = body["model"] as? String, !model.isEmpty, model != settings.model {
            state.selectModel(model)
            state.engines?.setModel(model, for: engine)
        }
        // 对话参数按请求生效，不参与引擎重启判断。
        if let temperature = body["temperature"] as? Double, temperature != settings.temperature {
            settings.setTemperature(temperature)
        }
        if let topP = body["topP"] as? Double, topP != settings.topP {
            settings.setTopP(topP)
        }
        if let maxTokens = body["maxTokens"] as? Int, maxTokens >= 16, maxTokens != settings.maxTokens {
            settings.setMaxTokens(maxTokens)
        }
        if let systemPrompt = body["systemPrompt"] as? String, systemPrompt != settings.systemPrompt {
            settings.setSystemPrompt(systemPrompt)
        }

        let engineSettingsChanged = activePortChanged
            || settings.thinkingMode != before.thinking
            || settings.reasoningEffort != before.effort
            || settings.model != before.model
            || settings.hfCache != before.hfCache
        if state.isRunning && engineSettingsChanged {
            state.restartService()
            state.toast("设置已保存，正在重启服务")
        } else {
            state.toast("设置已保存")
        }
    }

    // MARK: Swift → JS

    func schedulePush() {
        guard !pushScheduled else { return }
        pushScheduled = true
        // 去抖已合并突发推送，这里只排下一轮 runloop 收口。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }
            self.pushScheduled = false
            self.pushSnapshot()
        }
    }

    func pushSnapshot() {
        guard let json = WebSnapshot.json(state: state) else { return }
        webView.evaluateJavaScript("window.__fc__.push(\(json));", completionHandler: nil)
    }

    func pushToast(_ message: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [message]),
              let text = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__fcToast(\(text));", completionHandler: nil)
    }
}

extension WebBridge: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushSnapshot()
    }
}

// MARK: - Name maps

private extension ThinkingMode {
    var webName: String {
        switch self {
        case .automatic: return "automatic"
        case .off: return "off"
        case .on: return "on"
        }
    }

    init?(webName: String) {
        switch webName {
        case "automatic": self = .automatic
        case "off": self = .off
        case "on": self = .on
        default: return nil
        }
    }
}

private extension ReasoningEffort {
    var webName: String {
        switch self {
        case .minimal: return "minimal"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        case .max: return "max"
        }
    }

    init?(webName: String) {
        switch webName {
        case "minimal": self = .minimal
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        case "xhigh": self = .xhigh
        case "max": self = .max
        default: return nil
        }
    }
}

private enum WebPaths {
    static func expandTilde(_ path: String) -> String {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "~" { return Paths.home }
        if value.hasPrefix("~/") { return Paths.home + "/" + value.dropFirst(2) }
        return value
    }
}

// MARK: - Snapshot

/// AppState → JSON 快照。字段即 WebUI/app.js 的数据契约。
@MainActor
enum WebSnapshot {
    /// 心跳每秒序列化最多 800 行日志，formatter 必须复用（原先每行 new 一个）。
    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func json(state: AppState) -> String? {
        guard let data = data(state: state),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    @MainActor
    static func data(state: AppState) -> Data? {
        let engine = state.activeEngine
        let stats = state.stats

        var engineState: [String: Any] = [
            "id": engine.rawValue,
            "name": engine.displayName,
            "version": state.engineVersion,
            "state": serverStateName(state.serverState),
            "running": state.isRunning,
            "ready": state.isReady,
            "switching": state.isSwitchingModel,
            "switchStage": state.switchStage,
            "startupStage": state.startupStage,
        ]
        if let failure = state.failureMessage { engineState["failure"] = failure }

        var statsDict: [String: Any] = [:]
        if let stats {
            statsDict = [
                "decodeTokensPerSecond": stats.decodeTokensPerSecond ?? 0,
                "prefillTokensPerSecond": stats.prefillTokensPerSecond ?? 0,
                "ttftMilliseconds": stats.ttftMilliseconds ?? 0,
                "thermal": stats.thermal ?? "",
                "thermalText": stats.thermalText,
                "requestsCompleted": stats.requestsCompleted,
                "requestsFailed": stats.requestsFailed,
                "draftAcceptance": stats.draftAcceptance ?? 0,
                "dflashLabel": draftLabel(state),
                "maximumContextTokens": stats.maximumContextTokens ?? 0,
                "deviceName": stats.deviceName ?? "",
                "gpuCores": stats.gpuCores ?? 0,
                "instancePid": stats.instancePid ?? 0,
                "startedAt": stats.startedAt ?? 0,
                "memoryBytes": stats.memoryBytes ?? 0,
                "physicalMemoryBytes": stats.physicalMemoryBytes ?? 0,
            ]
        }

        let library: [String: Any] = [
            "engine": state.libraryEngine.rawValue,
            "entries": state.libraryEntries(for: state.libraryEngine).map { entry -> [String: Any] in
                var item: [String: Any] = [
                    "id": entry.model.id,
                    "display": entry.model.id.replacingOccurrences(of: "--", with: "/"),
                    "engine": entry.engine.rawValue,
                    "installed": entry.installed,
                    "isDraft": entry.isDraft,
                    "bytes": entry.model.bytes,
                    "originText": entry.installed ? "本机" : "Hugging Face",
                ]
                if let repo = entry.recommendation?.repo { item["repo"] = repo }
                if let tags = entry.recommendation?.tags, !tags.isEmpty { item["tags"] = tags }
                if let memory = entry.recommendation?.minimumMemory, memory > 0 { item["minMemory"] = memory }
                if entry.draftRepository != nil { item["draftTag"] = true }
                return item
            },
        ]

        var enginesInstall: [String: Any] = [:]
        for id in EngineID.allCases {
            let info = state.installs
            var item: [String: Any] = [
                "port": EngineStore.shared.configuration(for: id).port ?? id.defaultPort,
                "versions": (info.installed[id] ?? []),
            ]
            switch info.upstream[id] {
            case .update(_, let release):
                item["upstream"] = ["status": "update", "version": release.version,
                                    "prerelease": release.isPrerelease]
            case .current(let version):
                item["upstream"] = ["status": "current", "version": version]
            case .unavailable:
                item["upstream"] = ["status": "unavailable"]
            case .none:
                item["upstream"] = ["status": "unavailable"]
            }
            if let phase = info.phases[id], phase.isBusy {
                item["phase"] = phase.label
                item["progress"] = info.progress[id] ?? 0
                item["step"] = info.progressStep[id] ?? ""
            } else if let phase = info.phases[id], phase.isFailure {
                item["phase"] = "failed"
            }
            item["params"] = paramsSummary(for: id)
            item["modelsDir"] = EnginePaths.modelsDirectory(id)
            item["logFile"] = EnginePaths.logFile(id)
            item["tuning"] = tuningJSON(EngineStore.shared.configuration(for: id).tuning ?? EngineTuning())
            item["tuningDefault"] = tuningJSON(EngineTuning.defaults(for: id))
            if let latest = state.installs.releases[id]?.max(by: { EngineVersionOrder.isNewer($1.version, than: $0.version) }) {
                var release: [String: Any] = ["version": latest.version]
                if let bytes = latest.bytes { release["bytes"] = bytes }
                item["latestRelease"] = release
            }
            enginesInstall[id.rawValue] = item
        }

        var downloads: [String: Any] = [
            "tasks": state.downloadTasks.map { task in
                ["engine": task.engine.rawValue, "model": task.model,
                 "status": task.status.rawValue, "fraction": task.fraction ?? NSNull(),
                 "totalBytes": task.totalBytes, "downloadedBytes": task.downloadedBytes] as [String: Any]
            },
        ]
        if let model = state.downloadingModel {
            downloads["active"] = [
                "engine": state.downloadingEngine?.rawValue ?? "",
                "model": model,
                "fraction": state.downloadFraction ?? 0,
                "speed": state.downloadSpeed,
            ]
        }

        let settingsDict: [String: Any] = [
            "temperature": state.settings.temperature,
            "topP": state.settings.topP,
            "maxTokens": state.settings.maxTokens,
            "systemPrompt": state.settings.systemPrompt,
            "thinkingMode": state.settings.thinkingMode.webName,
            "thinkingModeLabel": state.settings.thinkingMode.label,
            "reasoningEffort": state.settings.reasoningEffort.webName,
            "reasoningEffortLabel": state.settings.reasoningEffort.label,
            "autoStart": state.settings.autoStart,
            "launchAtLogin": state.settings.launchAtLogin,
            "hfCache": state.settings.hfCache,
            "defaultModel": state.settings.model,
            "gatewayEnabled": state.settings.gatewayEnabled,
            "gatewayPort": state.settings.gatewayPort,
            "ports": Dictionary(uniqueKeysWithValues: EngineID.allCases.map { id in
                (id.rawValue, EngineStore.shared.configuration(for: id).port ?? id.defaultPort)
            }),
        ]

        var pending: [String: Any]? = nil
        if let request = state.pendingLibraryUse {
            pending = ["kind": "use", "engine": request.engine.rawValue,
                       "model": request.model, "needsDownload": request.needsDownload]
        } else if let model = state.confirmingModelSwitch {
            pending = ["kind": "switch", "model": model]
        }
        var pendingInstall: String? = nil
        if let install = state.pendingEngineInstall { pendingInstall = install.rawValue }

        let payload: [String: Any] = [
            "page": state.section.webName,
            "appearance": state.theme.mode.webName,
            "launchPage": state.isPresentingLaunchPage,
            "launchNeedsSetup": state.needsEngineSetup,
            "packIndex": ["loaded": state.installs.indexLoaded,
                          "error": state.installs.indexError ?? NSNull()] as [String: Any],
            "pendingInstall": pendingInstall ?? NSNull(),
            "engine": engineState,
            "port": state.port,
            "endpointURL": state.endpointURL,
            "gatewayURL": state.gatewayURL,
            "selectedModel": state.selectedModel,
            "stats": stats != nil ? statsDict : NSNull(),
            "throughput": state.recentThroughput(window: 0).map { sample in
                ["t": sample.at.timeIntervalSince1970 * 1000, "v": sample.value] as [String: Any]
            },
            "threads": state.threads.map { thread in
                ["id": thread.id, "title": thread.title,
                 "updatedAt": thread.updatedAt.timeIntervalSince1970 * 1000] as [String: Any]
            },
            "messages": state.messages.map { message in
                var item: [String: Any] = [
                    "id": message.id.uuidString,
                    "role": message.role,
                    "content": message.content,
                    "streaming": message.streaming,
                ]
                if let reasoning = message.reasoning, !reasoning.isEmpty { item["reasoning"] = reasoning }
                if let rate = message.tokensPerSecond { item["rate"] = rate }
                if message.tokenCount > 0 { item["tokens"] = message.tokenCount }
                if let ttft = message.firstTokenSeconds { item["ttft"] = ttft }
                return item
            },
            "generating": state.generating,
            "generationStatus": state.generationStatus ?? "",
            "modelsMenu": state.catalog.machine.map { ["id": $0.id] },
            "library": library,
            "downloads": downloads,
            "logs": state.logs.suffix(800).map { line -> [String: Any] in
                return [
                    "id": line.id,
                    "time": Self.logTimeFormatter.string(from: line.time),
                    "level": logLevelName(line),
                    "text": line.text,
                ]
            },
            "enginesInstall": enginesInstall,
            "settings": settingsDict,
            "pending": pending ?? NSNull(),
            "toast": state.toastMessage ?? "",
            "notice": state.notice ?? "",
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private static func serverStateName(_ value: ServerState) -> String {        switch value {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .ready: return "running"
        case .stopping: return "stopping"
        case .failed: return "failed"
        }
    }

    private static func logLevelName(_ line: LogLine) -> String {
        switch line.level {
        case .error: return "error"
        case .warning: return "warning"
        default:
            let lower = line.text.lowercased()
            if lower.contains("error") || lower.contains("fatal") || lower.contains("traceback") {
                return "error"
            }
            if lower.contains("warn") || lower.contains("deprecated") { return "warning" }
            return "info"
        }
    }

    private static func draftLabel(_ state: AppState) -> String {
        switch state.speculativeMode {
        case .dflash: return "DFlash2 接受率"
        case .mtp: return "MTP 接受率"
        case .off: return "草稿接受率"
        }
    }

    /// EngineTuning → 网页配置面板的普通字典（nil 即引擎默认）。
    private static func tuningJSON(_ tuning: EngineTuning) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(tuning),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// 引擎卡的「参数」列：从该引擎的调优配置拼出关键开关。
    private static func paramsSummary(for id: EngineID) -> String {
        let tuning = EngineStore.shared.configuration(for: id).tuning
        guard let tuning else { return "默认" }
        var parts: [String] = []
        if let context = tuning.maxContext, !context.isEmpty { parts.append("--ctx \(context)") }
        if tuning.dflash == true, let draft = tuning.draftModel, !draft.isEmpty {
            let short = draft.split(separator: "/").last.map(String.init) ?? draft
            parts.append("--draft \(short)")
        }
        if let memory = tuning.maxMemory, !memory.isEmpty { parts.append("--max-memory \(memory)") }
        if id == .mtplx, let mtp = tuning.mtp { parts.append(mtp ? "--mtp" : "--no-mtp") }
        return parts.isEmpty ? "默认" : parts.joined(separator: " ")
    }
}

private extension EngineInstallPhase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
