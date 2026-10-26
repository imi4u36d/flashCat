import Foundation

enum ServerState: String {
    case stopped = "已停止"
    case starting = "启动中"
    case ready = "运行中"
    case stopping = "停止中"
    case failed = "异常"
}

/// Owns the splash inference process: the pid file, the port claim, the log stream.
@MainActor
final class ServerController {
    let runtime: EngineRuntime
    let settings: AppSettings
    var catalog: ModelCatalog
    let logs = LogStore()

    var onChange: () -> Void = {}

    private(set) var state: ServerState = .stopped
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
    private var lineBuffers = [Data(), Data()]

    init(runtime: EngineRuntime, settings: AppSettings, catalog: ModelCatalog) {
        self.runtime = runtime
        self.settings = settings
        self.catalog = catalog
        self.port = settings.port
    }

    var isRunning: Bool { process != nil || attachedPid != nil }
    var isReady: Bool { state == .ready }

    // MARK: startup stage, derived from the engine's own log lines

    var startupStage: String {
        if state == .ready { return "就绪" }
        let recent = logs.tail(60)
        for line in recent {
            let text = line.text
            if text.contains("Ready ·") { return "就绪" }
            if text.lowercased().contains("downloading") || text.contains("%") { return "下载模型" }
            if text.lowercased().contains("warm") { return "预热" }
            if text.lowercased().contains("load") { return "加载权重" }
            if text.lowercased().contains("kv") || text.lowercased().contains("context") { return "准备上下文" }
        }
        return state == .starting ? "启动中" : state.rawValue
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

    func start(localModel: ModelInfo? = nil, requestedModel: String? = nil) async {
        if process != nil { return }
        let selected = requestedModel ?? (settings.model.isEmpty ? nil : settings.model)
        if selected == nil || selected!.isEmpty {
            state = .failed
            failureMessage = "还没有选择模型"
            onChange()
            return
        }
        port = settings.port
        model = selected!

        let outcome = await claimPort(selected!)
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

        let serveScript = Paths.fileExists(runtime.serveScriptPath)
            ? runtime.serveScriptPath
            : (EngineRuntime.bundledResourcesDirectory ?? runtime.root) + "/flashcat_serve.py"

        var arguments: [String] = []
        if let localModel {
            if !Paths.fileExists(serveScript) {
                state = .failed
                failureMessage = "缺少 flashcat_serve.py，无法启动本地模型"
                onChange()
                return
            }
            arguments += ["-u", serveScript, "--runtime", runtime.root,
                          "--models-dir", Paths.modelsDirectory,
                          "--target", localModel.targetName,
                          "--model", localModel.id,
                          "--port", String(port)]
            if let draft = localModel.draftPath { arguments += ["--draft", draft] }
            if let mmproj = localModel.mmprojPath, !settings.languageOnly {
                arguments += ["--mmproj", mmproj]
            }
            arguments += settings.serveArguments().filter { $0 != "--offline" }
        } else {
            arguments += ["-u", runtime.launcherPath, "serve", "--model", selected!,
                          "--port", String(port)]
            arguments += settings.serveArguments()
        }

        logs.openFile()
        logs.append("==> flashCat 启动服务：\(selected!) · 端口 \(port)", level: .system)
        logs.append("==> \(runtime.pythonPath) \(arguments.joined(separator: " "))", level: .system)

        let task = Process()
        task.launchPath = runtime.pythonPath
        task.arguments = arguments
        task.currentDirectoryURL = URL(fileURLWithPath: runtime.root)

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["FLASHCAT_PID_FILE"] = Paths.pidFile
        let cache = settings.hfCache.trimmingCharacters(in: .whitespaces)
        if !cache.isEmpty { environment["HF_HUB_CACHE"] = cache }
        task.environment = environment

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
        } else if line.contains("Error ·") {
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

        if await LocalAPI.ready(port: port) {
            if state == .starting {
                state = .ready
                onChange()
            }
            if let value = await LocalAPI.status(port: port) {
                stats = value
                if process == nil { logs.pollFollow() }
                onChange()
            }
        } else if process == nil && attachedPid != nil {
            if !portOpen(port) {
                attachedPid = nil
                removePidFile()
                pollTimer?.invalidate()
                pollTimer = nil
                if state != .stopping {
                    state = .stopped
                    onChange()
                }
            }
        }
    }

    // MARK: port claim

    struct PortOutcome {
        let port: Int
        let attached: ServerStats?
    }

    private func claimPort(_ selectedModel: String) async -> PortOutcome? {
        let wanted = settings.port
        if !portOpen(wanted) {
            if let stale = readPidFile() {
                note("==> 清理上次遗留的服务进程（pid \(stale)）…")
                sendSignal(stale, SIGINT)
                _ = waitForPortFree(wanted, 10)
            }
            return PortOutcome(port: wanted, attached: nil)
        }

        let listener = await LocalAPI.status(port: wanted)
        if let listener {
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

        for candidate in (wanted + 1)...(wanted + 10) {
            if candidate > 65535 { break }
            if !portOpen(candidate) {
                note("==> 端口 \(wanted) 被其它程序占用，自动改用 \(candidate)")
                settings.setPort(candidate)
                return PortOutcome(port: candidate, attached: nil)
            }
        }

        failureMessage = "端口 \(wanted) 已被占用，请在设置中选择其它端口"
        return nil
    }

    private func attach(_ listener: ServerStats) {
        attachedPid = Int32(listener.instancePid ?? 0)
        isStopping = false
        stats = listener
        failureMessage = nil
        busySince = Date()
        state = .ready
        logs.openFile()
        logs.append("==> flashCat 接入已有服务：\(listener.model ?? "?") · 端口 \(port) · pid \(listener.instancePid ?? -1)", level: .system)
        if let pid = attachedPid, pid > 0 { writePidFile(pid) }
        startPolling()
        onChange()
    }

    private func writePidFile(_ pid: Int32) {
        Paths.ensureDirectory(Paths.supportDirectory)
        try? String(pid).write(toFile: Paths.pidFile, atomically: true, encoding: .utf8)
    }

    private func removePidFile() {
        try? FileManager.default.removeItem(atPath: Paths.pidFile)
    }

    private func readPidFile() -> Int32? {
        guard let text = try? String(contentsOfFile: Paths.pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespaces),
            let pid = Int32(text), pid > 0 else { return nil }
        return pid
    }
}
