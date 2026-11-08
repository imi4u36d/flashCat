import AppKit
import Foundation
import FlashCatKit

/// The local command channel used by the bundled `flashcat` CLI.
///
/// It is deliberately separate from the inference gateway: the gateway speaks
/// OpenAI / Anthropic and may be disabled, while this server exists to drive
/// the app itself (start engines, switch models, read downloads, edit
/// settings). It binds loopback only and requires the per-launch token written
/// to `control.json`, so another process on the Mac cannot steer the app by
/// merely finding the port.
@MainActor
final class ControlServer {
    /// Immutable and read from the `nonisolated` request entry point, so the
    /// authorization check does not need to hop onto the main actor.
    nonisolated let token: String

    private(set) var port: UInt16 = 0
    private(set) var isRunning = false
    let logs = LogStore(path: FlashCatPaths.controlLogFile)

    private var server: GatewayHTTPServer?
    /// Bumped by every start/stop so a start that finishes binding after the
    /// user disabled the interface can tell it is stale and close its listener.
    private var generation = 0
    /// Internal rather than private: the diagnostics extension in another file
    /// reports the same identity.
    let startedAt = Date()
    let appVersion: String
    let appBuild: String?
    let appPath: String?

    init() {
        // A random token per launch is enough: the file lives in the user's
        // Application Support folder with mode 0600.
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let info = Bundle.main.infoDictionary
        appVersion = (info?["CFBundleShortVersionString"] as? String) ?? "dev"
        appBuild = info?["CFBundleVersion"] as? String
        if Bundle.main.bundlePath.hasSuffix(".app") {
            appPath = Bundle.main.bundlePath
        } else {
            appPath = nil
        }
    }

    // MARK: Lifecycle

    /// Try the configured port and walk upward when it is taken. The runtime
    /// file records whichever port actually bound, so a collision never leaves
    /// the CLI guessing.
    func start(preferredPort: UInt16) async {
        guard server == nil else { return }
        generation += 1
        let generation = generation
        logs.openFile()
        logs.append("==> 启动命令行接口 · 端口 \(preferredPort)", level: .system)

        let lastCandidate = min(Int(preferredPort) + 20, 65_535)
        let candidates = (Int(preferredPort)...lastCandidate).compactMap { UInt16(exactly: $0) }
        for candidate in candidates {
            let newServer = GatewayHTTPServer { [weak self] request in
                guard let self else {
                    return Self.failure(503, "unavailable", "控制接口已停止")
                }
                return await self.route(request)
            }
            if await newServer.start(port: candidate) {
                // `start` suspends on the bind: a settings toggle can call
                // `stop()` meanwhile. Do not resurrect the listener or rewrite
                // control.json in that case.
                guard generation == self.generation else {
                    newServer.stop()
                    return
                }
                server = newServer
                port = candidate
                isRunning = true
                writeRuntimeFile()
                logs.append("==> 命令行接口已就绪 · 127.0.0.1:\(candidate)", level: .system)
                if candidate != preferredPort {
                    logs.append("==> 端口 \(preferredPort) 被占用，改用 \(candidate)", level: .warning)
                }
                return
            }
        }
        isRunning = false
        logs.append("==> 控制接口未能启动：\(preferredPort)…\(lastCandidate) 均被占用", level: .error)
    }

    func stop() {
        generation += 1
        server?.stop()
        server = nil
        isRunning = false
        if let runtime = ControlRuntime.load(), runtime.pid == getpid() {
            try? FileManager.default.removeItem(atPath: FlashCatPaths.controlRuntimeFile)
        }
        logs.append("==> 命令行接口已停止", level: .system)
    }

    func restart(port: UInt16) async {
        stop()
        await start(preferredPort: port)
    }

    private func writeRuntimeFile() {
        let runtime = ControlRuntime(pid: getpid(),
                                     port: port,
                                     token: token,
                                     appVersion: appVersion,
                                     appPath: appPath,
                                     startedAt: startedAt)
        do {
            try runtime.write()
        } catch {
            logs.append("==> 无法写入 \(FlashCatPaths.controlRuntimeFile)：\(error.localizedDescription)",
                        level: .error)
        }
    }

    // MARK: Routing

    /// Entry point handed to `GatewayHTTPServer`; runs off the main actor and
    /// only performs the cheap token check before hopping in.
    nonisolated func route(_ request: GatewayRequest) async -> GatewayResponse {
        guard Self.isAuthorized(request, token: token) else {
            Task { @MainActor [weak self] in
                self?.logs.append("==> 拒绝未授权的控制请求：\(request.method) \(request.path)",
                                  level: .warning)
            }
            return Self.failure(401, ControlErrorCode.unauthorized,
                                "缺少或错误的控制接口令牌；请使用随应用安装的 flashcat 命令")
        }
        return await handle(request)
    }

    /// Engine ids inside a request body are external input. An unknown id must
    /// fail with 400 instead of silently falling back to the owning engine.
    private static func unknownEngine(engine: String?,
                                      engines: [String]? = nil) -> GatewayResponse? {
        if let engine, EngineID(rawValue: engine) == nil {
            return failure(400, ControlErrorCode.badRequest, "无效的引擎 id：\(engine)")
        }
        if let engines, let bad = engines.first(where: { EngineID(rawValue: $0) == nil }) {
            return failure(400, ControlErrorCode.badRequest, "无效的引擎 id：\(bad)")
        }
        return nil
    }

    nonisolated private static func isAuthorized(_ request: GatewayRequest, token: String) -> Bool {
        if let value = request.header("authorization"), value == "Bearer \(token)" {
            return true
        }
        return request.header("x-flashcat-token") == token
    }

    @MainActor
    private func handle(_ request: GatewayRequest) async -> GatewayResponse {
        guard let route = ControlRoute.parse(method: request.method, path: request.path) else {
            return Self.failure(404, ControlErrorCode.notFound,
                                "未知控制路径 \(request.method) \(request.path)")
        }
        logs.append("==> \(request.method) \(request.path)", level: .info)

        switch route {
        case .health:
            return Self.json(appInfo)
        case .status:
            return Self.json(statusDocument())
        case .engines:
            return Self.json(engineDocuments())
        case .engineStart(let raw):
            guard let id = EngineID(rawValue: raw) else {
                return Self.failure(400, ControlErrorCode.badRequest, "无效的引擎 id：\(raw)")
            }
            return await engineAction(id: id, action: .start)
        case .engineStop(let raw):
            guard let id = EngineID(rawValue: raw) else {
                return Self.failure(400, ControlErrorCode.badRequest, "无效的引擎 id：\(raw)")
            }
            return await engineAction(id: id, action: .stop)
        case .engineRestart(let raw):
            guard let id = EngineID(rawValue: raw) else {
                return Self.failure(400, ControlErrorCode.badRequest, "无效的引擎 id：\(raw)")
            }
            return await engineAction(id: id, action: .restart)
        case .engineUse(let raw):
            guard let id = EngineID(rawValue: raw) else {
                return Self.failure(400, ControlErrorCode.badRequest, "无效的引擎 id：\(raw)")
            }
            return await engineAction(id: id, action: .use)
        case .enginesReload:
            AppState.shared.installs.refreshInstalled()
            AppState.shared.engines?.rebuild()
            AppState.shared.reloadModels()
            return Self.json(engineDocuments())
        case .models:
            if let raw = request.query["engine"], EngineID(rawValue: raw) == nil {
                return Self.failure(400, ControlErrorCode.badRequest, "无效的引擎 id：\(raw)")
            }
            return Self.json(modelDocuments(engine: request.query["engine"],
                                            includeAll: request.query["all"] == "true"))
        case .modelUse:
            guard let body: ControlModelUse = Self.decode(request) else {
                return Self.failure(400, ControlErrorCode.badRequest, "请求体需要 model 字段")
            }
            if let error = Self.unknownEngine(engine: body.engine) { return error }
            return await modelUse(body)
        case .modelDownload:
            guard let body: ControlModelDownload = Self.decode(request) else {
                return Self.failure(400, ControlErrorCode.badRequest, "请求体需要 model 字段")
            }
            if let error = Self.unknownEngine(engine: body.engine, engines: body.engines) {
                return error
            }
            return modelDownload(body)
        case .modelDelete:
            guard let body: ControlModelDelete = Self.decode(request) else {
                return Self.failure(400, ControlErrorCode.badRequest, "请求体需要 model 字段")
            }
            if let error = Self.unknownEngine(engine: body.engine) { return error }
            return modelDelete(body)
        case .downloads:
            return Self.json(downloadDocuments())
        case .downloadPause, .downloadResume, .downloadCancel:
            guard let body: ControlDownloadAction = Self.decode(request) else {
                return Self.failure(400, ControlErrorCode.badRequest, "请求体需要 engine 与 model")
            }
            if let error = Self.unknownEngine(engine: body.engine) { return error }
            return downloadAction(route: route, body: body)
        case .logs:
            return logsDocument(request)
        case .gatewayStart:
            AppState.shared.settings.setGatewayEnabled(true)
            AppState.shared.applyGatewaySettings()
            return Self.json(gatewayState)
        case .gatewayStop:
            AppState.shared.settings.setGatewayEnabled(false)
            AppState.shared.applyGatewaySettings()
            return Self.json(gatewayState)
        case .config:
            return Self.json(ControlConfigDocument(entries: configEntries()))
        case .configSet:
            guard let body: ControlConfigSet = Self.decode(request) else {
                return Self.failure(400, ControlErrorCode.badRequest, "请求体需要 key 与 value")
            }
            return setConfig(body)
        case .appQuit:
            let result = ControlSimpleResult(ok: true, message: "flashCat 正在退出")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSApp.terminate(nil)
            }
            return Self.json(result)
        case .appOpen:
            MainWindow.show()
            return Self.json(ControlSimpleResult(ok: true, message: "已打开 flashCat"))
        case .doctor:
            return Self.json(doctorReport())
        }
    }

    // MARK: App / engine documents

    private var appInfo: ControlAppInfo {
        ControlAppInfo(version: appVersion,
                       build: appBuild,
                       pid: getpid(),
                       startedAt: startedAt,
                       appPath: appPath,
                       controlPort: port)
    }

    private var gatewayState: ControlGatewayState {
        let state = AppState.shared
        return ControlGatewayState(enabled: state.settings.gatewayEnabled,
                                   running: state.gateway.isRunning,
                                   port: Int(state.gateway.port),
                                   baseURL: state.gateway.baseURL,
                                   failure: state.gateway.failureMessage)
    }

    func statusDocument() -> ControlStatus {
        let engines = engineDocuments()
        return ControlStatus(app: appInfo,
                             engine: engines.first { $0.isActive } ?? engines.first,
                             engines: engines,
                             gateway: gatewayState,
                             downloads: downloadDocuments())
    }

    private func engineDocuments() -> [ControlEngineState] {
        let state = AppState.shared
        return EngineCatalog.allIDs.map { id in
            let installed = EngineInstallations.newest(id, version: nil)
            let controller = state.engines?.controller(id)
            let versions = EngineInstallations.installed(id).map(\.version)
            let active = state.activeEngine == id
            let model: String
            if active {
                model = state.selectedModel
            } else {
                model = EngineStore.shared.configuration(for: id).lastModel ?? ""
            }
            let pid = controller?.stats?.instancePid
            let uptime = controller?.status?.uptimeSeconds.map { Int($0) }
            return ControlEngineState(id: id.rawValue,
                                      name: id.displayName,
                                      version: installed?.version ?? "—",
                                      installedVersions: versions,
                                      isActive: active,
                                      isInstalled: installed != nil,
                                      state: Self.runState(controller?.state),
                                      port: controller?.port ?? id.defaultPort,
                                      model: model,
                                      stage: controller?.startupStage ?? "",
                                      uptimeSeconds: uptime,
                                      pid: pid,
                                      capabilities: id.descriptor.capabilities.map(\.rawValue).sorted())
        }
    }

    private static func runState(_ state: ServerState?) -> String {
        switch state {
        case .starting: return "starting"
        case .ready: return "ready"
        case .stopping: return "stopping"
        case .failed: return "failed"
        case .stopped, .none: return "stopped"
        }
    }

    // MARK: Engine actions

    private enum EngineAction {
        case start
        case stop
        case restart
        case use
    }

    private func engineAction(id: EngineID, action: EngineAction) async -> GatewayResponse {
        let state = AppState.shared
        guard let controller = state.engines?.controller(id) else {
            return Self.failure(404, ControlErrorCode.notFound,
                                "\(id.displayName) 还没有安装；先运行 flashcat engines install \(id.rawValue)")
        }

        if action == .stop {
            if id == state.activeEngine {
                state.stopService()
            } else {
                controller.stop()
            }
            let stopped = await waitForEngine(id) { $0.state == .stopped || $0.state == .failed }
            if !stopped {
                return Self.failure(409, ControlErrorCode.conflict,
                                    "\(id.displayName) 未能在超时内停止")
            }
            return Self.json(engineDocument(id))
        }

        if action == .use {
            if id != state.activeEngine {
                guard await state.switchEngine(id, start: false) else {
                    return Self.failure(409, ControlErrorCode.conflict,
                                        "无法切换到 \(id.displayName)")
                }
            }
            return Self.json(engineDocument(id))
        }

        if action == .restart, controller.isRunning {
            if id == state.activeEngine {
                state.stopService()
            } else {
                controller.stop()
            }
            _ = await waitForEngine(id) { $0.state == .stopped || $0.state == .failed }
        }

        if id != state.activeEngine {
            guard await state.switchEngine(id, start: false) else {
                return Self.failure(409, ControlErrorCode.conflict,
                                    "无法切换到 \(id.displayName)")
            }
        }

        if state.selectedModel.isEmpty {
            // A fresh install has no saved selection. Pick the first servable
            // model rather than failing a command the user reasonably expects
            // to work.
            if let first = state.engineModels(for: id)
                .first(where: { !$0.hidden && !$0.helper && !ModelLibraryEntry.isDraftModel($0.id) }) {
                state.applyModelFromAnyEngine(first.id, engine: id)
            } else {
                return Self.failure(409, ControlErrorCode.conflict,
                                    "\(id.displayName) 没有可用模型；先运行 flashcat models download <repo>")
            }
        }

        if !controller.isRunning {
            state.startService()
        }
        guard let active = state.controller else {
            return Self.failure(503, ControlErrorCode.unavailable, "引擎控制器不可用")
        }
        let target = state.selectedModel
        let ready = await active.waitForSwitchReady(target, timeout: id.startupTimeout)
        guard ready else {
            let detail = active.failureMessage ?? "等待超时"
            return Self.failure(503, ControlErrorCode.failed,
                                "\(id.displayName) 未能就绪：\(detail)")
        }
        return Self.json(engineDocument(id))
    }

    private func engineDocument(_ id: EngineID) -> ControlEngineState {
        engineDocuments().first { $0.id == id.rawValue }
            ?? ControlEngineState(id: id.rawValue, name: id.displayName, version: "—",
                                  installedVersions: [], isActive: false, isInstalled: false,
                                  state: "stopped", port: id.defaultPort, model: "",
                                  stage: "")
    }

    /// Poll on the main actor: every source of truth here is `@Published`
    /// state, so a detached waiter would still have to hop back for each check.
    private func waitForEngine(_ id: EngineID,
                               timeout: TimeInterval = 90,
                               predicate: (EngineController) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let controller = AppState.shared.engines?.controller(id) else { return false }
            if predicate(controller) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
}
