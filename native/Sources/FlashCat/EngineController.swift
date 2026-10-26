import Foundation
import FlashCatKit

enum ServerState: String {
    case stopped = "已停止"
    case starting = "启动中"
    case ready = "运行中"
    case stopping = "停止中"
    case failed = "异常"

    init(_ state: EngineRunState) {
        switch state {
        case .stopped: self = .stopped
        case .starting, .loading: self = .starting
        case .ready: self = .ready
        case .stopping: self = .stopping
        case .failed: self = .failed
        }
    }
}

/// Owns one engine process: its pid file, port claim, log stream and health
/// polling. The Splash layout is the legacy case (an `EngineRuntime` tree);
/// every other engine is driven entirely by its runtime pack manifest, so adding
/// an engine never means touching this file again.
@MainActor
final class EngineController {
    let id: EngineID
    let settings: AppSettings
    var catalog: ModelCatalog

    /// Pack-based engines. `nil` for splash, which ships inside the app bundle.
    let installation: EngineInstallation?
    /// Legacy splash runtime tree.
    let runtime: EngineRuntime?
    let logs: LogStore

    var onChange: () -> Void = {}

    private(set) var state: ServerState = .stopped
    /// Engine-neutral view of the engine's own status document.
    private(set) var status: EngineStatus?
    /// Splash-shaped view for the existing dashboards.
    private(set) var stats: ServerStats?
    private(set) var port: Int
    private(set) var model: String = ""
    private(set) var failureMessage: String?
    private(set) var busySince: Date?

    private var process: Process?
    private var attachedPid: Int32?
    private var pollTimer: Timer?
    private var pollInFlight = false
    private var isStopping = false
    private var lastError: String?
    /// Log id the current start began at: history from earlier sessions must
    /// not name this run's stage.
    private var stageBaseline = 0
    private var lineBuffers = [Data(), Data()]
    /// Model the reader asked for. Hot engines load it without a restart, so it
    /// is tracked separately from whatever the engine happens to have loaded.
    private var desiredModel: String?
    /// Guards against firing a load on every poll while one is in flight.
    private var loadInFlight: String?

    init(id: EngineID,
         installation: EngineInstallation?,
         runtime: EngineRuntime?,
         settings: AppSettings,
         catalog: ModelCatalog,
         port: Int) {
        self.id = id
        self.installation = installation
        self.runtime = runtime
        self.settings = settings
        self.catalog = catalog
        self.port = port
        self.logs = LogStore(path: EnginePaths.logFile(id))
    }

    var isRunning: Bool { process != nil || attachedPid != nil }
    var isReady: Bool { state == .ready }
    var isInstalled: Bool { id == .splash ? runtime != nil : installation != nil }

    var manifest: EngineManifest? { installation?.manifest }

    /// Move to a new port while idle. A running engine keeps its socket, so this
    /// only takes effect on the next start.
    func updatePort(_ value: Int) {
        guard value != port else { return }
        port = value
    }

    /// Absolute path handed to the engine: its own folder inside flashCat's
    /// support directory, never the upstream `~/.omlx` or `~/.mtplx` tree.
    var modelsDirectory: String {
        id == .splash ? Paths.modelsDirectory : EnginePaths.modelsDirectory(id)
    }

    var endpoint: EngineEndpoint { EngineEndpoint(engine: id, port: port) }

    // MARK: startup stage, derived from the engine's own log lines

    var startupStage: String {
        switch state {
        case .ready: return "就绪"
        case .failed: return "启动失败"
        case .stopped: return "已停止"
        case .stopping: return "停止中"
        case .starting: break
        }
        if id != .splash, status?.state == .loading { return "加载权重" }
        let recent = logs.tail(60)
        for line in recent where line.id > stageBaseline {
            // The app's own banner echoes the whole command line, --max-context
            // included; scanning it reported "准备上下文" for a server that had
            // already exited. Only the engine's own lines describe its stage.
            guard line.level != .system else { continue }
            let text = line.text
            if text.contains("Ready ·") { return "就绪" }
            if text.lowercased().contains("downloading") { return "下载模型" }
            if text.lowercased().contains("warm") { return "预热" }
            if text.lowercased().contains("load") { return "加载权重" }
            if text.lowercased().contains("kv") || text.lowercased().contains("context") { return "准备上下文" }
        }
        return "启动中"
    }

    var downloadProgress: Double? {
        for line in logs.tail(40).reversed() {
            if let match = TextPattern.firstMatch("(\\d{1,3}(?:\\.\\d)?)%", line.text),
               let value = Double(match[0]) {
                return min(max(value, 0), 100)
            }
        }
        return nil
    }

    // MARK: start / stop

    /// `localModel` only matters for splash, whose serve script takes an
    /// assembly/target pair. Other engines take a model identifier.
    func start(localModel: ModelInfo? = nil, requestedModel: String? = nil) async {
        if process != nil { return }
        guard let plan = launchPlan(localModel: localModel, requestedModel: requestedModel) else { return }

        desiredModel = plan.model
        let outcome = await claimPort(plan.model)
        if outcome == nil {
            state = .failed
            onChange()
            return
        }
        if let listener = outcome!.attached {
            attach(listener)
            return
        }
        port = outcome!.port
        model = plan.model

        logs.openFile()
        stageBaseline = logs.latestId
        logs.append("==> flashCat 启动 \(id.displayName)：\(plan.model) · 端口 \(port)", level: .system)
        logs.append("==> \(plan.executable) \(plan.arguments.joined(separator: " "))", level: .system)

        let task = Process()
        task.launchPath = plan.executable
        task.arguments = plan.arguments
        task.currentDirectoryURL = URL(fileURLWithPath: plan.workingDirectory)
        task.environment = plan.environment

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        task.standardInput = FileHandle.nullDevice

        task.terminationHandler = { finished in
            DispatchQueue.main.async { self.processExited(finished) }
        }

        do {
            try task.run()
            process = task
            if let pid = processPid(task) { writePidFile(pid) }
            state = .starting
            failureMessage = nil
            stats = nil
            status = nil
            isStopping = false
            busySince = Date()
            startReader(stdout, index: 0)
            startReader(stderr, index: 1)
            startPolling()
            onChange()
        } catch {
            logs.close()
            state = .failed
            failureMessage = "无法启动服务：\(error)"
            onChange()
        }
    }

    struct LaunchPlan {
        let executable: String
        let arguments: [String]
        let workingDirectory: String
        let environment: [String: String]
        let model: String
    }

    private func launchPlan(localModel: ModelInfo?, requestedModel: String?) -> LaunchPlan? {
        let selected = requestedModel
            ?? EngineStore.shared.configuration(for: id).lastModel
            ?? (settings.model.isEmpty ? nil : settings.model)
        guard let selected, !selected.isEmpty else {
            state = .failed
            failureMessage = "还没有选择模型"
            onChange()
            return nil
        }

        if id == .splash { return splashPlan(selected: selected, localModel: localModel) }
        guard let installation, let manifest else {
            state = .failed
            failureMessage = "\(id.displayName) 运行时未安装"
            onChange()
            return nil
        }

        // MTPLX takes a model *path*; oMLX takes a directory plus a model id.
        // Handing it the symlink inside flashCat's own models folder keeps the
        // engine away from the upstream cache while reusing the same bytes.
        let linked = modelsDirectory + "/" + selected
        let modelArgument = id == .mtplx ? linked : selected
        let profile = manifest.launchProfiles["default"]
            ?? manifest.launchProfiles.values.first
            ?? EngineLaunchProfile(args: [])

        let values: [String: String] = [
            "root": installation.root.path,
            "port": String(port),
            "models": modelsDirectory,
            "model": modelArgument,
            "support": Paths.supportDirectory,
            "home": Paths.home,
        ]
        let arguments = profile.args.map { EngineTemplate.expand($0, context: values) }
        if !arguments.contains(String(port)) {
            // A manifest that forgot `{port}` would silently bind its default.
            logs.append("==> 警告：\(id.displayName) 的启动模板未包含 {port}", level: .warning)
        }

        var environment = baseEnvironment(root: installation.root.path)
        for (key, raw) in profile.environment ?? [:] {
            environment[key] = EngineTemplate.expand(raw, context: values)
        }

        return LaunchPlan(executable: installation.entrypoint.path,
                          arguments: arguments,
                          workingDirectory: installation.root.path,
                          environment: environment,
                          model: selected)
    }

    private func splashPlan(selected: String, localModel: ModelInfo?) -> LaunchPlan? {
        guard let runtime else {
            state = .failed
            failureMessage = "未找到内置推理运行时"
            onChange()
            return nil
        }
        let serveScript = Paths.fileExists(runtime.serveScriptPath)
            ? runtime.serveScriptPath
            : (EngineRuntime.bundledResourcesDirectory ?? runtime.root) + "/flashcat_serve.py"

        var arguments: [String] = []
        if let localModel {
            if !Paths.fileExists(serveScript) {
                state = .failed
                failureMessage = "缺少 flashcat_serve.py，无法启动本地模型"
                onChange()
                return nil
            }
            arguments += ["-u", serveScript, "--runtime", runtime.root,
                          "--models-dir", Paths.modelsDirectory,
                          "--model", localModel.id,
                          "--port", String(port)]
            if localModel.origin == .splash {
                // A model Splash installed is already a prepared assembly: hand
                // it to the server as it is instead of preparing it again.
                arguments += ["--assembly", localModel.path]
            } else {
                arguments += ["--target", localModel.targetName]
                if let draft = localModel.draftPath { arguments += ["--draft", draft] }
                if let mmproj = localModel.mmprojPath, !settings.languageOnly {
                    arguments += ["--mmproj", mmproj]
                }
            }
            arguments += settings.serveArguments().filter { $0 != "--offline" }
        } else {
            arguments += ["-u", runtime.launcherPath, "serve", "--model", selected,
                          "--port", String(port)]
            arguments += settings.serveArguments()
        }

        var environment = baseEnvironment(root: runtime.root)
        environment["FLASHCAT_PID_FILE"] = EnginePaths.pidFile(.splash)

        return LaunchPlan(executable: runtime.pythonPath,
                          arguments: arguments,
                          workingDirectory: runtime.root,
                          environment: environment,
                          model: selected)
    }

    /// A pack must never inherit the user's Python environment: a stray
    /// `PYTHONPATH` would load a different mlx and break the precompiled metal
    /// kernels, so those variables are cleared rather than overridden.
    private func baseEnvironment(root: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment.removeValue(forKey: "PYTHONPATH")
        environment.removeValue(forKey: "PYTHONHOME")
        if let path = environment["PATH"], !path.isEmpty {
            environment["PATH"] = root + "/bin:" + path
        } else {
            environment["PATH"] = root + "/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        let cache = settings.hfCache.trimmingCharacters(in: .whitespaces)
        if !cache.isEmpty { environment["HF_HUB_CACHE"] = cache }
        return environment
    }

    func stop() {
        if process == nil && attachedPid == nil {
            state = .stopped
            onChange()
            return
        }
        if isStopping { return }
        isStopping = true
        state = .stopping
        busySince = Date()
        logs.append("==> 正在停止服务…", level: .system)
        onChange()

        if let process, let pid = processPid(process) {
            sendSignal(pid, SIGINT)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                if let current = self.process, processPid(current) == pid {
                    self.logs.append("==> 服务未在 20 秒内退出，强制结束", level: .system)
                    sendSignal(pid, SIGKILL)
                }
            }
            return
        }

        let pid = attachedPid!
        sendSignal(pid, SIGINT)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            if self.attachedPid == pid {
                self.logs.append("==> 接入的服务未在 20 秒内退出，强制结束（pid \(pid))", level: .system)
                sendSignal(pid, SIGKILL)
                self.attachedPid = nil
                self.removePidFile()
                self.pollTimer?.invalidate()
                if self.state == .stopping {
                    self.state = .stopped
                    self.onChange()
                }
            }
        }
    }

    func restart(localModel: ModelInfo? = nil) async {
        if isRunning {
            stop()
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if process == nil && attachedPid == nil && !portOpen(port) { break }
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        await start(localModel: localModel)
    }

    func toggle(localModel: ModelInfo? = nil) {
        if isRunning { stop() } else { Task { await start(localModel: localModel) } }
    }

    func dispose() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let process, let pid = processPid(process) {
            sendSignal(pid, SIGINT)
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline && process.isRunning { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { sendSignal(pid, SIGKILL) }
        }
        if let pid = attachedPid {
            sendSignal(pid, SIGINT)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                if self.attachedPid == pid && portOpen(self.port) {
                    sendSignal(pid, SIGKILL)
                    self.attachedPid = nil
                }
            }
        }
        removePidFile()
        logs.close()
    }

    func updateCatalog(_ value: ModelCatalog) { catalog = value }

    // MARK: process plumbing

    private func processExited(_ finished: Process) {
        if process == nil { return }
        removePidFile()
        pollTimer?.invalidate()
        pollTimer = nil
        process = nil
        flushBuffers()
        logs.close()
        stats = nil
        status = nil
        busySince = nil
        let wasStopping = isStopping
        isStopping = false
        if wasStopping {
            logs.append("==> 服务已停止", level: .system)
            state = .stopped
        } else if finished.terminationStatus == 0 {
            state = .stopped
        } else {
            state = .failed
            failureMessage = lastError ?? "服务异常退出（退出码 \(finished.terminationStatus)）"
            logs.append("==> \(failureMessage!)", level: .system)
        }
        onChange()
    }

    private func startReader(_ pipe: Pipe, index: Int) {
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        Thread {
            var scratch = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let count = read(descriptor, &scratch, scratch.count)
                if count <= 0 { break }
                let chunk = Data(scratch[0..<count])
                DispatchQueue.main.async { self.ingest(chunk, index: index) }
            }
        }.start()
    }

    private func ingest(_ chunk: Data, index: Int) {
        lineBuffers[index].append(chunk)
        while let newline = lineBuffers[index].firstIndex(of: 0x0A) {
            let segment = lineBuffers[index].prefix(upTo: newline)
            lineBuffers[index].removeSubrange(lineBuffers[index].startIndex...newline)
            let line = String(data: segment, encoding: .utf8) ?? ""
            appendLog(line)
        }
    }

    private func flushBuffers() {
        for index in 0..<2 {
            if !lineBuffers[index].isEmpty {
                appendLog(String(data: lineBuffers[index], encoding: .utf8) ?? "")
                lineBuffers[index] = Data()
            }
        }
    }

    private func appendLog(_ line: String) {
        if line.contains("Ready ·") {
            lastError = nil
            if state == .starting {
                state = .ready
                onChange()
            }
        } else if line.contains("Error ·") || line.lowercased().hasPrefix("error:") {
            // flashcat_serve.py reports preparation failures as "error: ..." on
            // stderr; keep them for the help text instead of a bare exit code.
            lastError = line
        }
        logs.append(line)
    }

    private func note(_ line: String) {
        logs.openFile()
        logs.append(line, level: .system)
        logs.close()
    }

    // MARK: polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { await self.poll() }
        }
    }

    private func poll() async {
        if pollInFlight || (process == nil && attachedPid == nil) { return }
        pollInFlight = true
        defer { pollInFlight = false }

        guard await probeHealth() else {
            if process == nil, attachedPid != nil, !portOpen(port) {
                attachedPid = nil
                removePidFile()
                pollTimer?.invalidate()
                pollTimer = nil
                if state != .stopping {
                    state = .stopped
                    onChange()
                }
            }
            return
        }

        if state == .starting {
            state = .ready
            onChange()
        }
        await ensureDesiredModelLoaded()
        guard let payload = await fetchJSON(path: statusPath) else { return }
        let health = statusPath == healthPath ? nil : await fetchJSON(path: healthPath)
        let parsed = EngineStatusParser.parse(engine: id,
                                              status: payload,
                                              health: health,
                                              fallbackState: .ready)
        status = parsed
        stats = ServerStats(engineStatus: parsed, previous: stats)
        if process == nil { logs.pollFollow() }
        onChange()
    }

    private var healthPath: String {
        manifest?.health.path ?? "/ready"
    }

    /// First entry of the manifest's `status` array; splash reports everything
    /// on one `/status` document.
    private var statusPath: String {
        if id == .splash { return "/status" }
        return manifest?.status?.first ?? manifest?.health.path ?? "/health"
    }

    private func probeHealth() async -> Bool {
        guard let response = await HTTP.get(port: port, path: healthPath, timeout: 1.5) else {
            return false
        }
        let ready = manifest?.health.readyStatus ?? 200
        let loading = manifest?.health.loadingStatus
        if response.status == ready { return true }
        if let loading, response.status == loading { return true }
        // Splash reports readiness as 200 on /ready with an empty body.
        return id == .splash && response.status == 200
    }

    private func fetchJSON(path: String) async -> [String: Any]? {
        guard let response = await HTTP.get(port: port, path: path, timeout: 1.8) else { return nil }
        guard (200..<300).contains(response.status) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) else { return nil }
        return object as? [String: Any]
    }

    // MARK: model switching

    /// Ask for a model. Hot engines load it in place; the rest restart with the
    /// new weights, which is the only thing MTPLX understands.
    func switchModel(_ id: String) async {
        let target = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        desiredModel = target
        model = target
        if id_engineSwitchIsHot, isRunning {
            await loadModelHot(target)
        } else if isRunning {
            await restart(localModel: nil)
        } else {
            await start(localModel: nil, requestedModel: target)
        }
    }

    private var id_engineSwitchIsHot: Bool { id.switchMode == .hot }

    private func loadModelHot(_ target: String) async {
        guard loadInFlight != target else { return }
        loadInFlight = target
        defer { loadInFlight = nil }
        // ServerState has no loading case on purpose: AppState's switch timer
        // owns the "加载中" presentation for both engine kinds.
        // Weight loads are slow (tens of seconds for 27B); the poller keeps the
        // dashboard alive while this awaits.
        let response = await HTTP.post(port: port,
                                       path: "/v1/models/\(target)/load",
                                       timeout: 600)
        logs.append("==> \(id.displayName) 切换到 \(target) → HTTP \(response?.status ?? 0)",
                    level: (response?.status ?? 0) < 300 ? .system : .error)
        if (response?.status ?? 0) >= 300 {
            failureMessage = "加载 \(target) 失败"
            state = .ready
        }
        onChange()
    }

    /// oMLX starts with its own default model, so the requested one may still
    /// be cold once health turns green. Nudge it once per change.
    private func ensureDesiredModelLoaded() async {
        guard id_engineSwitchIsHot, let target = desiredModel, !target.isEmpty else { return }
        if let loaded = status?.loadedModels, loaded.contains(target) { return }
        if status?.model == target { return }
        await loadModelHot(target)
    }

    // MARK: port claim

    struct PortOutcome {
        let port: Int
        let attached: ServerStats?
    }

    private var preferredPort: Int {
        if id == .splash { return settings.port }
        return EngineStore.shared.configuration(for: id).port ?? id.defaultPort
    }

    private func claimPort(_ selectedModel: String) async -> PortOutcome? {
        let wanted = preferredPort
        if !portOpen(wanted) {
            if let stale = readPidFile() {
                note("==> 清理上次遗留的服务进程（pid \(stale)）…")
                sendSignal(stale, SIGINT)
                _ = waitForPortFree(wanted, 10)
            }
            return PortOutcome(port: wanted, attached: nil)
        }

        let listener = await LocalAPI.status(port: wanted)
        if id == .splash, let listener {
            if listener.model == selectedModel {
                note("==> 端口 \(wanted) 上已有相同模型的服务（pid \(listener.instancePid ?? -1)），直接接入，不重复启动")
                return PortOutcome(port: wanted, attached: listener)
            }
            if let pid = listener.instancePid, let stale = readPidFile(), Int(stale) == pid {
                note("==> 端口 \(wanted) 上是本应用上次遗留的服务（pid \(pid)，正在结束它…")
                sendSignal(Int32(pid), SIGINT)
                if waitForPortFree(wanted, 60) {
                    removePidFile()
                    return PortOutcome(port: wanted, attached: nil)
                }
                failureMessage = "遗留的服务进程（pid \(pid)）未能退出，端口 \(wanted) 仍被占用"
                return nil
            }
            failureMessage = "端口 \(wanted) 已被其它推理服务占用（模型 \(listener.model ?? "未知")，pid \(listener.instancePid ?? -1)）。请改用其它端口，或先结束该进程。"
            return nil
        }

        if id != .splash, let stale = readPidFile() {
            // Our own engine from a previous session still holds the port.
            note("==> 端口 \(wanted) 上是上次遗留的 \(id.displayName)（pid \(stale)），正在结束它…")
            sendSignal(stale, SIGINT)
            if waitForPortFree(wanted, 60) {
                removePidFile()
                return PortOutcome(port: wanted, attached: nil)
            }
        }

        for candidate in id.portRange.dropFirst() {
            if candidate > 65535 { break }
            if !portOpen(candidate) {
                note("==> 端口 \(wanted) 被占用，自动改用 \(candidate)")
                if id == .splash {
                    settings.setPort(candidate)
                } else {
                    EngineStore.shared.update(id) { $0.port = candidate }
                }
                return PortOutcome(port: candidate, attached: nil)
            }
        }

        failureMessage = "端口 \(wanted) 及其后 19 个端口都被占用，请在设置中换一个端口"
        return nil
    }

    private func attach(_ listener: ServerStats) {
        attachedPid = Int32(listener.instancePid ?? 0)
        isStopping = false
        stats = listener
        failureMessage = nil
        busySince = Date()
        state = .ready
        stageBaseline = 0
        logs.openFile()
        logs.append("==> flashCat 接入已有服务：\(listener.model ?? "?") · 端口 \(port) · pid \(listener.instancePid ?? -1)", level: .system)
        if let pid = attachedPid, pid > 0 { writePidFile(pid) }
        startPolling()
        onChange()
    }

    private func writePidFile(_ pid: Int32) {
        Paths.ensureDirectory(Paths.supportDirectory)
        try? String(pid).write(toFile: EnginePaths.pidFile(id), atomically: true, encoding: .utf8)
    }

    private func removePidFile() {
        try? FileManager.default.removeItem(atPath: EnginePaths.pidFile(id))
    }

    private func readPidFile() -> Int32? {
        guard let text = try? String(contentsOfFile: EnginePaths.pidFile(id), encoding: .utf8)
            .trimmingCharacters(in: .whitespaces),
            let pid = Int32(text), pid > 0 else { return nil }
        return pid
    }
}

// MARK: - small HTTP client

struct HTTPResponse {
    let status: Int
    let body: Data
}

enum HTTP {
    /// Loopback JSON GET with a hard timeout. `URLSession` is replaced by a
    /// delegate-configured session so a wedged engine cannot hang the poller.
    static func get(port: Int, path: String, timeout: TimeInterval) async -> HTTPResponse? {
        await send(method: "GET", port: port, path: path, timeout: timeout)
    }

    /// POST with an empty body — enough for oMLX's load/unload switches.
    static func post(port: Int, path: String, timeout: TimeInterval) async -> HTTPResponse? {
        await send(method: "POST", port: port, path: path, timeout: timeout)
    }

    private static func send(method: String,
                             port: Int,
                             path: String,
                             timeout: TimeInterval) async -> HTTPResponse? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return HTTPResponse(status: status, body: data)
        } catch {
            return nil
        }
    }
}
