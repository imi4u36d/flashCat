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
/// polling. Every engine — splash included — is driven entirely by the runtime
/// pack manifest it was installed from, so adding an engine never means
/// touching this file again.
@MainActor
final class EngineController {
    let id: EngineID
    let settings: AppSettings
    var catalog: ModelCatalog

    /// The installed pack this controller runs. The launch command, health and
    /// status paths all come from its manifest.
    let installation: EngineInstallation
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
    /// pid of a server we did not spawn but are driving (a listener left behind by
    /// an earlier run, or one started outside the app).
    private(set) var attachedPid: Int32?
    /// Model the reader started the current run with; splash needs it again for
    /// a restart so the local serve path keeps its assembly/target arguments.
    private var runModel: ModelInfo?
    /// oMLX applies MTP/DFlash through its own settings API, once per run.
    private var tuningApplied = false
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
    /// A model switch owns the engine until it finishes: the 1 s poller must not
    /// race it with its own "make sure the desired model is loaded" nudge, or a
    /// load is issued while the previous weights are still being unloaded.
    private var switchInFlight = false
    /// Most recent successful hot load. `/api/status` lags a beat behind the
    /// load response, so without this the poller re-issues the same load the
    /// switch already completed (a second, pointless HTTP 200 in the log).
    private var lastHotLoad: (target: String, at: Date)?

    init(id: EngineID,
         installation: EngineInstallation,
         settings: AppSettings,
         catalog: ModelCatalog,
         port: Int) {
        self.id = id
        self.installation = installation
        self.settings = settings
        self.catalog = catalog
        self.port = port
        self.logs = LogStore(path: EnginePaths.logFile(id))
    }

    var isRunning: Bool { process != nil || attachedPid != nil }
    var isReady: Bool { state == .ready }
    var isInstalled: Bool { installation != nil }

    var manifest: EngineManifest { installation.manifest }

    /// Move to a new port while idle. A running engine keeps its socket, so this
    /// only takes effect on the next start.
    func updatePort(_ value: Int) {
        guard value != port else { return }
        port = value
    }

    /// Absolute path handed to the engine: splash's existing model folder, or
    /// that engine's own folder inside flashCat's support directory.
    var modelsDirectory: String { EnginePaths.modelsDirectory(id) }

    var endpoint: EngineEndpoint { EngineEndpoint(engine: id, port: port) }

    // MARK: startup stage, derived from the engine's own log lines

    var startupStage: String {
        switch state {
        case .ready: return EngineStartupStage.ready.rawValue
        case .failed: return "启动失败"
        case .stopped: return "已停止"
        case .stopping: return "停止中"
        case .starting: break
        }
        if status?.state == .loading { return EngineStartupStage.loadingWeights.rawValue }
        // The stage comes from the engine's own lines only: the app's banner
        // echoes the whole command line, `--max-context` included, and names no
        // phase — scanning it reported a stage for a server that had exited.
        let recent = logs.tail(60)
            .filter { $0.id > stageBaseline && $0.level != .system }
            .map(\.text)
        return EngineStartupStage.derive(from: recent).rawValue
    }

    /// Seconds the current start has been running, nil while idle. The console
    /// shows it beside the stage: a warmup that takes minutes then reads as
    /// progress that is still moving, not as a spinner that hung.
    var busySeconds: Int? {
        guard let busySince else { return nil }
        return max(0, Int(Date().timeIntervalSince(busySince)))
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
        runModel = localModel
        guard let claimed = await claimPort(plan.model) else {
            state = .failed
            onChange()
            return
        }
        port = claimed
        model = plan.model
        tuningApplied = false

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
            if let pid = processPid(task) {
                writePidFile(pid)
                spawnWatchdog(enginePid: pid)
            }
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
            fail("还没有选择模型")
            return nil
        }

        // A pack may ship several profiles: splash has one for a hub id its own
        // launcher resolves and one for a prepared local assembly. Prefer the
        // model-aware profile, then the generic one, then whatever exists.
        let profileNames = [localModel == nil ? "hub" : "local", "default"]
        guard let profile = profileNames.compactMap({ manifest.launchProfiles[$0] }).first
                ?? manifest.launchProfiles.values.first else {
            fail("\(id.displayName) 的运行时包没有启动模板")
            return nil
        }

        // The manifest decides how the model is handed over. An engine only ever
        // sees a path inside flashCat's own models folder — the weights live
        // there, not in the user's upstream caches.
        let modelPath = modelsDirectory + "/" + selected
        let modelArgument: String
        switch manifest.modelArgumentStyle {
        case .name: modelArgument = selected
        case .path: modelArgument = modelPath
        case .id: modelArgument = localModel?.id ?? selected
        }

        let values: [String: String] = [
            "root": installation.root.path,
            "port": String(port),
            "models": modelsDirectory,
            "model": modelArgument,
            "support": Paths.supportDirectory,
            "home": Paths.home,
        ]
        let tuning = EngineStore.shared.tuning(for: id)
        var arguments = EngineTemplate.expand(profile.args, context: values)

        if id == .splash, let localModel {
            if localModel.origin == .splash {
                // A model Splash installed is already a prepared assembly: hand
                // it to the server as it is instead of preparing it again.
                arguments += ["--assembly", localModel.path]
            } else {
                arguments += ["--target", localModel.targetName]
                // DFlash2: an explicit draft directory wins, the model's own draft
                // is the fallback, and the switch can turn drafting off entirely.
                if let draft = tuning.draftDirectory(automatic: localModel.draftPath) {
                    arguments += ["--draft", draft]
                }
                if let mmproj = localModel.mmprojPath, tuning.languageOnly != true {
                    arguments += ["--mmproj", mmproj]
                }
            }
        }
        arguments += tuning.arguments(for: id)
        // 思考截断：Splash 吃 CLI 参数；oMLX 的按模型预算由 pushTuning 推送。
        if id == .splash, let budget = tuning.effectiveThinkingBudget(for: .splash) {
            arguments += ["--thinking-token-budget", String(budget)]
        }
        if id == .splash, let effort = settings.effectiveReasoningEffort {
            arguments += ["--default-reasoning-effort", effort]
        }

        if !arguments.contains(String(port)) {
            // A manifest that forgot `{port}` would silently bind its default.
            logs.append("==> 警告：\(id.displayName) 的启动模板未包含 {port}", level: .warning)
        }

        var environment = baseEnvironment(root: installation.root.path)
        for (key, raw) in profile.environment ?? [:] {
            environment[key] = EngineTemplate.expand(raw, context: values)
        }
        // MTPLX 的思考截断走 ThinkingGuard 的环境变量：引擎默认关、且默认
        // 只覆盖 agent 工具循环，这里显式开启并把范围放宽到普通聊天，
        // 与 splash/oMLX 的截断语义对齐。重启后生效。
        if id == .mtplx, let budget = tuning.effectiveThinkingBudget(for: .mtplx) {
            environment["MTPLX_THINKING_BUDGET"] = String(budget)
            environment["MTPLX_THINKING_GUARD_SCOPE"] = "all"
        }
        // flashcat_serve.py detaches a watchdog that ends the server when the
        // app is gone; it finds this app through the pid file.
        if id == .splash {
            environment["FLASHCAT_PID_FILE"] = EnginePaths.pidFile(.splash)
        }

        return LaunchPlan(executable: installation.entrypoint.path,
                          arguments: arguments,
                          workingDirectory: installation.root.path,
                          environment: environment,
                          model: selected)
    }

    private func fail(_ message: String) {
        state = .failed
        failureMessage = message
        onChange()
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
        // Whatever was resident dies with the process, so the hot-load cool-down
        // no longer applies: the next start must load its model again.
        lastHotLoad = nil
        if process == nil {
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
            // The pack python is only the trunk: the inference binary and pool
            // workers below it hold the weights, so the whole tree is signalled.
            killTree(pid, SIGINT)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                if let current = self.process, processPid(current) == pid {
                    self.logs.append("==> 服务未在 20 秒内退出，强制结束", level: .system)
                    killTree(pid, SIGKILL)
                }
            }
        }
    }

    enum ModelSwitchOutcome: Equatable {
        case ready
        case failed(String)
    }

    func restart(localModel: ModelInfo? = nil) async {
        if isRunning {
            guard await stopAndWait() else {
                state = .failed
                failureMessage = "旧服务（端口 \(port)）未能退出，已取消重启"
                onChange()
                return
            }
        }
        await start(localModel: localModel ?? runModel)
    }

    /// Stop the engine and return only once it is really gone — process
    /// reaped, port released. Never blocks the main actor: `stop()`'s SIGKILL
    /// backstop and `processExited` both arrive through the main queue, so a
    /// synchronous wait could never observe them.
    @discardableResult
    func stopAndWait(grace: Double = 12, timeout: Double = 90) async -> Bool {
        if process == nil && !portOpen(port) { return true }
        stop()
        let startedAt = Date()
        let pid = process.flatMap(processPid)
        var escalated = false
        while Date().timeIntervalSince(startedAt) < timeout {
            if process == nil && !portOpen(port) { return true }
            if !escalated, Date().timeIntervalSince(startedAt) > grace, let pid {
                escalated = true
                logs.append("==> \(id.displayName) 未在 \(Int(grace)) 秒内退出，强制结束（pid \(pid)）",
                            level: .system)
                killTree(pid, SIGKILL)
            }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return process == nil && !portOpen(port)
    }

    /// Wait for a freshly launched engine to report ready. The state machine
    /// advances through `processExited`/`poll`, which need the main actor.
    func waitForReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch state {
            case .ready: return true
            case .failed, .stopped: return false
            case .starting, .stopping: break
            }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return state == .ready
    }

    func toggle(localModel: ModelInfo? = nil) {
        if isRunning { stop() } else { Task { await start(localModel: localModel) } }
    }

    /// Runs at app termination. `applicationShouldTerminateAfterLastWindowClosed`
    /// and `applicationWillTerminate` both call it on the same quit, so the work
    /// must be idempotent. The whole tree is killed, not just the direct child:
    /// a quit while weights are still loading means the python is wedged inside
    /// a Metal call and cannot act on SIGINT, and its children would otherwise
    /// keep the model resident after the app is gone.
    private var disposed = false
    func dispose() {
        guard !disposed else { return }
        disposed = true
        pollTimer?.invalidate()
        pollTimer = nil
        if let process, let pid = processPid(process) {
            killTree(pid, SIGINT)
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline && process.isRunning { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { killTree(pid, SIGKILL) }
        }
        removePidFile()
        logs.close()
    }

    // MARK: orphan watchdog

    /// Detached last resort for a crashed or force-quit app — the paths where
    /// `dispose` never runs. A python from the pack itself watches the app's
    /// pid; once the app is gone it ends the engine's whole tree within
    /// seconds, instead of leaving a half-loaded 20 GB model resident until
    /// the next launch's sweep gets around to it. On a normal quit the
    /// watchdog finds its engine already dead, kills nothing and exits, so it
    /// needs no management from this side (splash additionally runs its own
    /// python-side watchdog from flashcat_serve.py; the two overlap harmlessly).
    private func spawnWatchdog(enginePid: Int32) {
        let task = Process()
        task.launchPath = installation.entrypoint.path
        task.arguments = ["-u", "-c", Self.watchdogScript,
                          String(enginePid),
                          String(ProcessInfo.processInfo.processIdentifier),
                          packMarkerDirectory]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            // Best effort only: dispose and the launch sweep remain the
            // primary cleanup, the watchdog just narrows the crash window.
            note("==> 未能启动引擎守护进程（不影响正常启停）：\(error)")
        }
    }

    /// Runs as `python -u -c <script> <engine-pid> <app-pid> <pack-marker>`.
    /// Every candidate is re-verified against the pack root through
    /// proc_pidpath before a signal is sent, so a pid that died and was reused
    /// in the polling gap is never hit. The descendant snapshot is taken while
    /// the engine root is still alive — after its death the children are
    /// re-parented to launchd and the chain would be lost.
    private static let watchdogScript = #"""
    import ctypes, os, signal, subprocess, sys, time

    engine = int(sys.argv[1])
    app = int(sys.argv[2])
    marker = os.path.realpath(sys.argv[3])

    libproc = None
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    except OSError:
        pass

    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def ours(pid):
        if libproc is None:
            return False
        try:
            buf = ctypes.create_string_buffer(4096)
            n = libproc.proc_pidpath(pid, buf, 4096)
            path = buf.value.decode("utf-8", "replace") if n > 0 else ""
        except Exception:
            return False
        return path.startswith(marker + "/")

    def tree(pid):
        pids, index = [pid], 0
        while index < len(pids):
            try:
                out = subprocess.run(["/usr/bin/pgrep", "-P", str(pids[index])],
                                     capture_output=True, text=True, timeout=5).stdout
                pids.extend(int(line) for line in out.split())
            except Exception:
                pass
            index += 1
        return pids

    snapshot = tree(engine)
    while alive(app) and alive(engine):
        snapshot = tree(engine)
        time.sleep(2)

    victims = [pid for pid in snapshot if alive(pid) and ours(pid)]
    for pid in victims:
        try:
            os.kill(pid, signal.SIGINT)
        except OSError:
            pass
    deadline = time.time() + 15
    while victims and time.time() < deadline:
        time.sleep(1)
        victims = [pid for pid in victims if alive(pid)]
    for pid in victims:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    """#

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
        if pollInFlight || process == nil { return }
        pollInFlight = true
        defer { pollInFlight = false }

        guard await probeHealth() else {
            // 503 while the weights load and the kernels warm: there is no
            // status document to read yet, but the console still has to tick —
            // the stage comes from the engine's log and the elapsed count from
            // the clock, and on a big MoE target both stay put for minutes.
            refreshStartupTick()
            return
        }

        if state == .starting {
            state = .ready
            onChange()
        }
        await applyTuningIfNeeded()
        await ensureDesiredModelLoaded()
        guard let payload = await fetchJSON(path: statusPath) else { return }
        let health = statusPath == healthPath ? nil : await fetchJSON(path: healthPath)
        var parsed = EngineStatusParser.parse(engine: id,
                                              status: payload,
                                              health: health,
                                              fallbackState: .ready)
        await adoptEngineReportedEfforts(into: &parsed)
        status = parsed
        stats = ServerStats(engineStatus: parsed, previous: stats)
        if process == nil { logs.pollFollow() }
        onChange()
    }

    private var healthPath: String {
        manifest.health.path
    }

    /// Keep the console alive while the engine is not answering yet. Nothing is
    /// polled from the engine here — a loading splash prints nothing for
    /// minutes — but republishing the snapshot each second is what makes the
    /// stage and the elapsed count move instead of freezing at one frame.
    private func refreshStartupTick() {
        guard state == .starting else { return }
        if process == nil { logs.pollFollow() }
        onChange()
    }

    /// First entry of the manifest's `status` array — splash reports everything
    /// on one `/status` document.
    private var statusPath: String {
        manifest.status?.first ?? manifest.health.path
    }

    private func probeHealth() async -> Bool {
        guard let response = await HTTP.get(port: port, path: healthPath, timeout: 1.5) else {
            return false
        }
        let ready = manifest.health.readyStatus
        if response.status == ready { return true }
        if let loading = manifest.health.loadingStatus, response.status == loading { return true }
        return false
    }

    private func fetchJSON(path: String) async -> [String: Any]? {
        guard let response = await HTTP.get(port: port, path: path, timeout: 1.8) else { return nil }
        guard (200..<300).contains(response.status) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) else { return nil }
        return object as? [String: Any]
    }

    /// oMLX 把每个模型支持的思考等级放在 `/v1/models/status` 的
    /// `reasoning_efforts` 里（`/api/status` 没有），所以这里补一次读取，
    /// 交给思考等级下拉框当数据源。其他引擎的等级已随状态文档解析
    /// （MTPLX），splash 不提供 → 保持 nil，上层用内置列表兜底。
    private func adoptEngineReportedEfforts(into parsed: inout EngineStatus) async {
        guard id == .omlx else { return }
        guard let wanted = parsed.model ?? desiredModel, !wanted.isEmpty else { return }
        guard let document = await fetchJSON(path: "/v1/models/status") else { return }
        let entries = (document["models"] as? [[String: Any]]) ?? []
        guard let entry = entries.first(where: { ($0["id"] as? String) == wanted }),
              let efforts = entry["reasoning_efforts"] as? [String], !efforts.isEmpty else { return }
        parsed.reasoningEfforts = efforts
    }

    // MARK: model switching

    /// Swap the loaded weights. Both engine kinds follow the same rule: the old
    /// model must be *confirmed* gone — process exited and port released, or the
    /// engine's own status no longer listing it — before the new weights
    /// allocate. Two 27B models do not fit in unified memory, and issuing the
    /// load while the previous weights were still resident is what left the app
    /// spinning on an engine that could not answer.
    func switchModel(_ target: String, stage: @escaping (String) -> Void) async -> ModelSwitchOutcome {
        let wanted = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return .failed("模型标识为空") }
        guard !switchInFlight else { return .failed("已有切换在进行") }
        switchInFlight = true
        defer { switchInFlight = false }

        if id.switchMode == .hot, isRunning {
            // Park the poller: nothing may nudge a load while we unload.
            desiredModel = nil
            stage("卸载旧模型")
            let cleared = await unloadLoadedModels(keeping: wanted)
            if Task.isCancelled {
                desiredModel = wanted
                onChange()
                return .failed("切换已取消")
            }
            if cleared {
                stage("加载新模型")
                desiredModel = wanted
                model = wanted
                let loaded = await loadModelHot(wanted)
                return loaded ? .ready : .failed(failureMessage ?? "加载 \(wanted) 失败")
            }
            // The engine would not let go of the weights. Restarting the process
            // is the only way to guarantee the memory is released before the new
            // model allocates, so fall back to the cold path instead of piling a
            // second 27B model on top of the first.
            logs.append("==> 就地卸载未能确认，改为重启服务释放显存", level: .system)
        }

        if isRunning {
            stage("停止旧模型")
            desiredModel = wanted
            model = wanted
            guard await stopAndWait() else {
                failureMessage = "旧模型（端口 \(port)）未能退出，已取消切换"
                logs.append("==> 切换已取消：端口 \(port) 仍被旧进程占用", level: .error)
                onChange()
                return .failed("旧模型未能退出")
            }
            stage("加载新模型")
            let local = catalog.machineModel(wanted)
            await start(localModel: local, requestedModel: wanted)
            let ready = await waitForReady(timeout: id.startupTimeout)
            return ready ? .ready : .failed(failureMessage ?? "\(id.displayName) 未能在预期时间内就绪")
        }

        // Nothing running: just remember the choice, the next start uses it.
        desiredModel = wanted
        model = wanted
        return .ready
    }

    private var id_engineSwitchIsHot: Bool { id.switchMode == .hot }

    /// Models the engine itself reports as resident. `nil` means the status
    /// document could not be read at all.
    private func residentModels() async -> [String]? {
        guard let payload = await fetchJSON(path: statusPath) else { return nil }
        let parsed = EngineStatusParser.parse(engine: id,
                                              status: payload,
                                              health: nil,
                                              fallbackState: .ready)
        return parsed.loadedModels
    }

    /// Ask the engine to drop every resident model except `target` and wait for
    /// its own status to agree. oMLX answers 202 while it drains in-flight
    /// streams, so the POST result alone is not a confirmation.
    private func unloadLoadedModels(keeping target: String, timeout: Double = 180) async -> Bool {
        guard let resident = await residentModels() else {
            logs.append("==> 读取 \(id.displayName) 状态失败，无法确认已加载的模型", level: .error)
            return false
        }
        let victims = resident.filter { $0 != target }
        if victims.isEmpty { return true }

        var pending = [String]()
        for victim in victims {
            let path = EngineRoutes.unload(victim)
            let response = await HTTP.post(port: port, path: path, timeout: 60)
            let status = response?.status ?? 0
            logs.append("==> 卸载 \(victim) → HTTP \(status)", level: status < 300 ? .system : .error)
            // 400 (not loaded) / 404 (unknown id) mean this id holds no weights,
            // so there is nothing left to wait for. Everything else — 202 queued,
            // 409 still loading, or no answer at all — has to be polled.
            if status == 400 || status == 404 { continue }
            pending.append(victim)
        }
        if pending.isEmpty { return true }

        let startedAt = Date()
        var lastNote = Date()
        var clearSince: Date?
        while Date().timeIntervalSince(startedAt) < timeout {
            let remaining = (await residentModels() ?? pending).filter { pending.contains($0) && $0 != target }
            if remaining.isEmpty {
                // The engine drops the model from `loaded_models` a moment before
                // its own gc/clear_cache settle barrier releases the Metal
                // buffers (engine_pool._stop_and_unload_engine), so hold a short
                // grace instead of racing the new allocation against the old one.
                let clear = clearSince ?? Date()
                clearSince = clear
                if Date().timeIntervalSince(clear) >= 1.5 {
                    logs.append("==> 旧模型已卸载（\(Int(Date().timeIntervalSince(startedAt))) 秒），开始加载 \(target)",
                                level: .system)
                    return true
                }
            } else {
                clearSince = nil
            }
            if Date().timeIntervalSince(lastNote) > 10 {
                lastNote = Date()
                logs.append("==> 仍在卸载 \(remaining.joined(separator: "、")) …", level: .system)
            }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }

    /// Model ids are directory names, so no slash survives, but a custom id may
    /// still carry characters the URL path cannot.
    private func loadModelHot(_ target: String) async -> Bool {
        guard loadInFlight != target else { return false }
        loadInFlight = target
        defer { loadInFlight = nil }
        // ServerState has no loading case on purpose: the switch stage text
        // owns the "加载中" presentation for both engine kinds.
        // Weight loads are slow (tens of seconds for 27B); the poller keeps the
        // dashboard alive while this awaits.
        // Settings only reach a model at load time, so push them first.
        if id == .omlx { await pushTuning(for: [target]) }
        let response = await HTTP.post(port: port,
                                       path: EngineRoutes.load(target),
                                       timeout: 600)
        let status = response?.status ?? 0
        logs.append("==> \(id.displayName) 切换到 \(target) → HTTP \(status)",
                    level: status < 300 ? .system : .error)
        if status >= 300 {
            failureMessage = status == 507
                ? "内存不足，无法加载 \(target)"
                : "加载 \(target) 失败（HTTP \(status)）"
            state = .ready
        } else {
            failureMessage = nil
            lastHotLoad = (target, Date())
        }
        onChange()
        return status < 300
    }

    /// oMLX starts with its own default model, so the requested one may still
    /// be cold once health turns green. Nudge it once per change — never while a
    /// switch owns the engine.
    private func ensureDesiredModelLoaded() async {
        guard !switchInFlight else { return }
        guard id.switchMode == .hot, let target = desiredModel, !target.isEmpty else { return }
        if let last = lastHotLoad, last.target == target,
           Date().timeIntervalSince(last.at) < 20 { return }
        if let loaded = status?.loadedModels, loaded.contains(target) { return }
        if status?.model == target { return }
        _ = await loadModelHot(target)
    }

    // MARK: port claim

    private var preferredPort: Int {
        EngineStore.shared.configuration(for: id).port ?? id.defaultPort
    }

    /// Port the engine may bind, or nil when every candidate in its range is
    /// taken. A leftover engine from an earlier session is reaped first — and
    /// the port being free proves nothing: a server killed mid-startup is still
    /// loading weights, holds its memory for minutes and binds its port only
    /// once the load finishes, exactly when a second engine would pile on top.
    private func claimPort(_ selectedModel: String) async -> Int? {
        let wanted = preferredPort
        if let stale = readPidFile() {
            if processAlive(stale), processBelongsToPack(stale) {
                guard await reclaimStaleEngine(stale) else {
                    failureMessage = "遗留的服务进程（pid \(stale)）未能退出，无法启动 \(id.displayName)"
                    onChange()
                    return nil
                }
            } else {
                // Stale bookkeeping: the pid is gone, or was reused by a
                // process that is not this pack's engine. Either way it must
                // not be signalled.
                removePidFile()
            }
        }
        if !portOpen(wanted) { return wanted }

        // Occupied with nothing on the pid file. This app has no evidence the
        // listener is its own leftover, so it never kills blind — it moves on.
        for candidate in id.portRange.dropFirst() where candidate <= 65535 {
            if !portOpen(candidate) {
                note("==> 端口 \(wanted) 被占用，自动改用 \(candidate)")
                EngineStore.shared.update(id) { $0.port = candidate }
                return candidate
            }
        }

        failureMessage = "端口 \(wanted) 及其后 19 个端口都被占用，请在引擎设置中换一个端口"
        return nil
    }

    /// The engine pack this controller runs, one level up so a leftover from a
    /// previous pack version (same engine, older directory) still matches.
    /// Symlinks are resolved because proc_pidpath reports the canonical path:
    /// a pack under /tmp would otherwise never match its own /private/tmp
    /// executable paths.
    private var packMarkerDirectory: String {
        (installation.root.deletingLastPathComponent().path as NSString).resolvingSymlinksInPath
    }

    /// Launch-time sweep for processes a crashed or force-quit session left
    /// behind. Nothing of this session runs yet, so any live executable inside
    /// this engine's pack directories is residue: the pack python and the
    /// binaries below it are started by nobody else. SIGKILL straight away —
    /// a leftover stuck inside a weight load cannot act on SIGINT, and its pid
    /// bookkeeping was already removed by the clean-quit path.
    func sweepOrphans() {
        let marker = packMarkerDirectory + "/"
        for entry in allProcesses() where entry.pid != ProcessInfo.processInfo.processIdentifier {
            guard let path = processExecutablePath(entry.pid), path.hasPrefix(marker) else { continue }
            note("==> 清扫上次会话遗留的引擎进程（pid \(entry.pid)）")
            killTree(entry.pid, SIGKILL)
        }
    }

    /// The pid's executable lives inside this engine's pack directories — the
    /// only processes this app ever starts there. Guards the reclaim against
    /// firing on a reused pid.
    private func processBelongsToPack(_ pid: Int32) -> Bool {
        guard let path = processExecutablePath(pid) else { return false }
        return path.hasPrefix(packMarkerDirectory + "/")
    }

    /// Ends a server left behind by an earlier session: SIGINT to the whole
    /// tree, SIGKILL after the grace, and "gone" means the *process* exited —
    /// not merely that the port came free, which a server still inside a Metal
    /// weight load never signals.
    private func reclaimStaleEngine(_ stale: Int32, grace: Double = 10) async -> Bool {
        note("==> 清理上次遗留的 \(id.displayName) 服务进程（pid \(stale)）…")
        killTree(stale, SIGINT)
        let startedAt = Date()
        var escalated = false
        while Date().timeIntervalSince(startedAt) < 90 {
            if !processAlive(stale) {
                removePidFile()
                note("==> 遗留进程已结束")
                return true
            }
            if !escalated, Date().timeIntervalSince(startedAt) > grace {
                escalated = true
                note("==> 遗留进程未在 \(Int(grace)) 秒内退出，强制结束整棵进程树")
                killTree(stale, SIGKILL)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return !processAlive(stale)
    }

    private func processAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    // MARK: tuning

    /// oMLX has no CLI switch for MTP/DFlash — they are per-model server
    /// settings, so they are pushed through its admin API once the engine is up.
    /// MTPLX and splash bake the same switches into their launch arguments.
    private func applyTuningIfNeeded() async {
        guard !tuningApplied else { return }
        tuningApplied = true
        let resident = await residentModels() ?? status?.loadedModels ?? []
        await pushTuning(for: resident)
    }

    /// Push the stored tuning again after the user edits it on the engine page.
    /// CLI engines only take new flags at launch, so this notes a restart instead
    /// of pretending an in-place change happened.
    func reapplyTuning() async {
        guard isRunning else { return }
        guard id == .omlx else {
            note("==> \(id.displayName) 的配置已保存，重启后生效")
            return
        }
        let resident = await residentModels() ?? status?.loadedModels ?? []
        guard !resident.isEmpty else { return }
        await pushTuning(for: resident)
        // A model keeps the settings it was loaded with, so the loaded one is
        // reloaded for the new depth/draft flags to take effect.
        if let current = resident.first(where: { $0 == model || $0 == desiredModel }) {
            _ = await unloadLoadedModels(keeping: "")
            _ = await loadModelHot(current)
        }
    }

    private func pushTuning(for targets: [String]) async {
        guard id == .omlx, !targets.isEmpty else { return }
        let tuning = EngineStore.shared.tuning(for: .omlx)
        var failures = 0
        for target in targets {
            // A model with an assigned draft gets `dflash_draft_model` merged
            // into its payload; everyone else takes the engine-level tuning.
            // The payload is push-ready: the resolved thinking budget rides in.
            let override = EngineStore.shared.draftAssignment(for: id, model: target)
            guard let settings = tuning.omlxSettings(id: id, draftOverride: override),
                  !settings.isEmpty else { continue }
            let payload = settings.mapValues { $0.jsonObject }
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            let response = await HTTP.put(port: port,
                                          path: EngineRoutes.modelSettings(target),
                                          json: data,
                                          timeout: 20)
            let status = response?.status ?? 0
            logs.append("==> \(target) 应用 MTP/DFlash 设置 -> HTTP \(status)",
                        level: status < 300 ? .system : .warning)
            if status >= 300 { failures += 1 }
        }
        if failures > 0 {
            failureMessage = "MTP/DFlash 设置未被 \(id.displayName) 接受（\(failures) 个模型失败）"
        }
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
        await send(method: "GET", port: port, path: path, body: nil, timeout: timeout)
    }

    /// POST with an empty body — enough for oMLX's load/unload switches.
    static func post(port: Int, path: String, timeout: TimeInterval) async -> HTTPResponse? {
        await send(method: "POST", port: port, path: path, body: nil, timeout: timeout)
    }

    /// PUT a JSON object, used for oMLX's per-model settings document.
    static func put(port: Int, path: String, json: Data, timeout: TimeInterval) async -> HTTPResponse? {
        await send(method: "PUT", port: port, path: path, body: json, timeout: timeout)
    }

    private static func send(method: String,
                             port: Int,
                             path: String,
                             body: Data?,
                             timeout: TimeInterval) async -> HTTPResponse? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            // FastAPI validates a JSON body only when the content type says so;
            // an unlabelled body comes back as 422 missing-field.
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
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
