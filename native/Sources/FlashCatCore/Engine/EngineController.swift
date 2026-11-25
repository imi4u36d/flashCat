// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation

package enum ServerState: String {
    case stopped = "已停止"
    case starting = "启动中"
    case ready = "运行中"
    case stopping = "停止中"
    case failed = "异常"

    package init(_ state: EngineRunState) {
        switch state {
        case .stopped: self = .stopped
        case .starting, .loading: self = .starting
        case .ready: self = .ready
        case .stopping: self = .stopping
        case .failed: self = .failed
        }
    }
}

/// 进程退出留下的结构化诊断：退出码，或未捕获的信号。
///
/// `failureMessage` 已经把它写进一句给人看的话里，但菜单栏的异常卡还要把
/// 「9」翻成 `SIGKILL` 并解释原因。从本地化文案里正则抠数字既脆弱，又会被
/// 英文翻译改坏，所以退出那一刻顺手留一份机器可读的。
package struct EngineExitDiagnostic: Equatable {
    package let code: Int32
    package let isSignal: Bool

    package init(code: Int32, isSignal: Bool) {
        self.code = code
        self.isSignal = isSignal
    }

    /// POSIX 信号名。普通退出码没有名字；未知信号退回 `SIG<n>`，
    /// 比只显示一个裸数字更能让人搜到答案。
    package var signalName: String? {
        guard isSignal else { return nil }
        switch code {
        case 1: return "SIGHUP"
        case 2: return "SIGINT"
        case 3: return "SIGQUIT"
        case 4: return "SIGILL"
        case 5: return "SIGTRAP"
        case 6: return "SIGABRT"
        case 7: return "SIGEMT"
        case 8: return "SIGFPE"
        case 9: return "SIGKILL"
        case 10: return "SIGBUS"
        case 11: return "SIGSEGV"
        case 12: return "SIGSYS"
        case 13: return "SIGPIPE"
        case 14: return "SIGALRM"
        case 15: return "SIGTERM"
        default: return "SIG\(code)"
        }
    }
}

/// What the app hands a launch after looking at the model first.
///
/// Splash needs the model's DFlash2 draft next to it; when the assembly was
/// installed by a build that did not fetch one, the app fetches it before the
/// engine starts and passes the refreshed model (the draft path only exists
/// after a rescan).
package enum StartPreparation {
    case ready(ModelInfo?)
    case failed(String)
}

/// Owns one engine process: its pid file, port claim, log stream and health
/// polling. Every engine — splash included — is driven entirely by the runtime
/// pack manifest it was installed from, so adding an engine never means
/// touching this file again.
@MainActor
package final class EngineController {
    package let id: EngineID
    package let settings: AppSettings
    package var catalog: ModelCatalog

    /// The installed pack this controller runs. The launch command, health and
    /// status paths all come from its manifest.
    package let installation: EngineInstallation
    package let logs: LogStore

    package var onChange: () -> Void = {}

    /// Runs before every launch, including restarts and hot switches. Nil means
    /// the app has nothing to prepare and the launch goes ahead as asked.
    package var prepareForStart: (@MainActor (ModelInfo?) async -> StartPreparation)?

    /// 唯一的生命周期状态。所有写点都经过 `transition(to:)`：状态机只有一处
    /// 真相，越界的迁移也只有一处能拦（见 `isTransitionAllowed`）。
    var phase: Phase = .idle
    /// 对外可见的五态，由 `phase` 派生。名字与语义和原来的存储属性一致，调用方
    /// （`AppState`、`ControlServer`、菜单栏）一行都不用改。
    package var state: ServerState { phase.serverState }
    /// Engine-neutral view of the engine's own status document.
    package var status: EngineStatus?
    /// Splash-shaped view for the existing dashboards.
    package var stats: ServerStats?
    package private(set) var port: Int
    package var model: String = ""
    package var failureMessage: String?
    /// 最近一次进程退出的结构化诊断；正常停止或尚未跑过为 nil。
    /// setter 留在本模块：生命周期写点分散在 `EngineController+Process` 等扩展里。
    package internal(set) var exitDiagnostic: EngineExitDiagnostic?
    /// 「已等待」的起点。原来是独立存储的 `Date?`，只由生命周期写点维护，谁清过
    /// 它全靠约定；现在它跟着 `phase` 走，读的人（`busySeconds`）不必再关心。
    var busySince: Date? { phase.busySince }
    /// 正在搬权重的起点。`busySince` 是进程的起点：引擎已经跑了几个小时、模型又被
    /// 重新加载时，用它算「加载权重」的秒数会给出几个小时。只在加载期间非 nil。
    var hotLoadSince: Date?

    var process: Process?
    /// Model the reader started the current run with; splash needs it again for
    /// a restart so the local serve path keeps its assembly/target arguments.
    var runModel: ModelInfo?
    /// oMLX applies MTP/DFlash through its own settings API, once per run.
    var tuningApplied = false
    var pollTimer: Timer?
    /// mlx-serve 只报预填充累计计数器，实时预填充速率靠相邻 1 Hz 轮询差分。
    /// 每个引擎进程一份基线；换进程或退出时清掉，避免拿上一轮计数当起点。
    var liveRates = EngineLiveRates()
    var pollInFlight = false
    var lastError: String?
    /// Moves `.starting` out of limbo when the engine neither binds its port nor
    /// exits. Nothing else does: the poller only ever promotes to `.ready`.
    var startupWatchdog: Task<Void, Never>?
    /// Process tree captured at quit time, kept so the SIGKILL escalation can
    /// reach children that outlived their parent. See `ProcessTree`.
    var terminationTree: ProcessTree?
    /// Log id the current start began at: history from earlier sessions must
    /// not name this run's stage.
    var stageBaseline = 0
    /// 阶段与下载进度都从日志尾部推导；UI 一帧内可能问多次，按日志 id 缓存，
    /// 避免每帧都复制 40/60 行再跑一遍正则。
    var stageLogCache: (latest: Int, baseline: Int, stage: String)?
    var downloadProgressCache: (latest: Int, value: Double?)?
    /// oMLX 的思考等级是模型静态属性，没必要每秒都去 `/v1/models/status` 问一次。
    var reasoningEffortsCache: (model: String, at: Date, efforts: [String]?)?
    var lineBuffers = [Data(), Data()]
    /// Model the reader asked for. Hot engines load it without a restart, so it
    /// is tracked separately from whatever the engine happens to have loaded.
    var desiredModel: String?
    /// Guards against firing a load on every poll while one is in flight.
    var loadInFlight: String?
    /// A model switch owns the engine until it finishes: the 1 s poller must not
    /// race it with its own "make sure the desired model is loaded" nudge, or a
    /// load is issued while the previous weights are still being unloaded.
    var switchInFlight = false
    /// Most recent successful hot load. `/api/status` lags a beat behind the
    /// load response, so without this the poller re-issues the same load the
    /// switch already completed (a second, pointless HTTP 200 in the log).
    var lastHotLoad: (target: String, at: Date)?

    package init(
        id: EngineID,
        installation: EngineInstallation,
        settings: AppSettings,
        catalog: ModelCatalog,
        port: Int
    ) {
        self.id = id
        self.installation = installation
        self.settings = settings
        self.catalog = catalog
        self.port = port
        self.logs = LogStore(path: EnginePaths.logFile(id))
    }

    /// 「有进程」和「能聊天」是两件事：`.failed` 也可能带着一个还活着的进程
    /// （启动超时、健康检查一直不过），那时仍然要让读者点得到「停止」。
    package var isRunning: Bool { process != nil }
    package var isReady: Bool { phase == .ready }
    package var isInstalled: Bool { true }

    // MARK: phase

    /// 一次运行会经过的全部阶段。
    ///
    /// 这些信息原来散在 `state`、`isStopping`、`preparing`、`terminating`、
    /// `busySince` 五个互相牵制的值里、二十多处写点，互斥关系全靠约定：写得出来
    /// 的组合里有「正在停」和「还在启」同时为真，只有界面看得见。收成一个值之后
    /// 同一时刻只可能在一处，越界的迁移由 `isTransitionAllowed` 拦下并留日志。
    package enum Phase: Equatable, Sendable {
        /// 控制器建好、还没被要求启动过。对外和 `.stopped` 同义。
        case idle
        /// 运行时包正在安装。保留位：装包发生在控制器创建之前，正常流程不会
        /// 进来；留着是为了让状态机对「引擎还没装好」这一阶段有话说。
        case installing
        /// 从点下启动到引擎自报就绪之间。`since` 是「已等待」的起点：预下载
        /// draft、等端口都算同一次等待，否则界面上的计时会先归零再从头数。
        case starting(since: Date)
        /// 进程在跑、健康检查也通了，但权重还没搬完。保留位：对外的五态里
        /// 没有 loading（`ServerState` 刻意只给读者五个词），热加载引擎的这段
        /// 准备目前由 `startupStage`/`weightLoadSeconds` 报，生产路径暂不进入。
        case loading
        /// 可以聊天。
        case ready
        /// 已经发过 SIGINT（超时再升级成 SIGKILL），等进程树退干净。
        case stopping(since: Date)
        /// 没有进程，也没有错误。
        case stopped
        /// 进程不会提供服务了：拉不起来、异常退出或启动超时。`reason` 是给读者
        /// 看的正文（退出码之外的那一句话）。
        case failed(reason: String?)
        /// 用户在退出应用，`prepareForTermination` 已经收过信号。
        case terminating

        /// 对外可见的五态。界面、CLI、菜单栏都只认这个。
        var serverState: ServerState {
            switch self {
            case .idle, .stopped: return .stopped
            case .installing, .starting, .loading: return .starting
            case .ready: return .ready
            case .stopping, .terminating: return .stopping
            case .failed: return .failed
            }
        }

        /// 「已等待」的起点，nil 表示没有正在计时的等待。
        var busySince: Date? {
            switch self {
            case .starting(let since), .stopping(let since): return since
            case .idle, .installing, .loading, .ready, .stopped, .failed, .terminating:
                return nil
            }
        }
    }

    /// 状态迁移的唯一入口。
    ///
    /// 返回这次迁移是否被接受，调用方靠它决定要不要继续往下走。同一阶段的重复
    /// 通知直接吞掉：`poll()` 每秒都会喊一次就绪，那不是一次迁移。
    ///
    /// 这里**不**调 `onChange`：发布要发生在一次事件的改动都写完之后
    /// （`process`、`failureMessage`、日志），否则界面会先看到「已就绪」，
    /// 再看到失败正文。
    @discardableResult
    func transition(
        to next: Phase,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> Bool {
        guard next != phase else { return false }
        guard isTransitionAllowed(from: phase, to: next) else {
            // 悄悄接受是这类 bug 最难查的地方：状态自己走到不该到的位置，
            // 界面上只表现为「点了没反应」。留在日志里，排查至少有线索。
            logs.append(
                "==> 忽略非法的状态迁移：\(phase) → \(next)（\(file):\(line)）",
                level: .warning)
            return false
        }
        phase = next
        return true
    }

    /// 迁移表。写成「允许什么」而不是「禁止什么」：阶段只有九个，允许的组合少
    /// 得多，读一遍就能看出某次写入合不合法。
    func isTransitionAllowed(from current: Phase, to next: Phase) -> Bool {
        switch next {
        case .ready:
            // 就绪必须有一个活着的进程撑着。这条是上一轮那个竞态的根：进程已经
            // 退出、`Ready ·` 才被读进来（读线程与退出回调都排在主队列上，先后
            // 没有保证），于是 `isRunning` 为假而 `isReady` 为真，聊天请求打到
            // 一个已经关掉的回环端口。从 `.stopping`/`.terminating` 进来同样要
            // 拒：那意味着退出过程中界面又亮起「可聊天」。
            guard process != nil else { return false }
            switch current {
            case .starting, .loading: return true
            default: return false
            }
        case .starting:
            // 一次新的启动只能在没有进程、也没有在退出的时候开始：否则两个启动
            // 会抢同一个控制器，后一个覆盖前一个的 `process`，前一个的退出被
            // `finished === process` 静默丢掉。
            guard process == nil else { return false }
            switch current {
            case .stopping, .terminating: return false
            default: return true
            }
        case .stopping:
            // 没有进程就没有「正在停」：那只是已经停了。退出流程已经接管时也
            // 不许改写：`.terminating` 是 `markReady` 判断迟到信号的依据。
            guard process != nil else { return false }
            switch current {
            case .terminating: return false
            default: return true
            }
        case .failed:
            return true
        case .stopped:
            // 收敛点：任何阶段都可能退到一个干净的「已停止」。
            return true
        case .terminating:
            return true
        case .idle, .installing, .loading:
            // 生产路径不进入这三个值（见 `Phase` 上的注释），所以不该有迁移走到
            // 这里；真要进来，说明有新代码在乱写，留日志比放行好。
            return false
        }
    }

    /// 正在启动。第二只引擎会覆盖第一个的 `process`，前一个的退出被
    /// `finished === process` 静默丢掉，所以启动期间控制器是独占的。
    var isLaunching: Bool {
        if case .starting = phase { return true }
        return false
    }

    var isStopping: Bool {
        if case .stopping = phase { return true }
        return false
    }

    /// 退出流程已经接管。`markReady` 的守卫靠它挡住「退出中又亮起可聊天」。
    var isTerminating: Bool {
        if case .terminating = phase { return true }
        return false
    }

    package var manifest: EngineManifest { installation.manifest }
    package var descriptor: EngineDescriptor { installation.descriptor }

    /// Move to a new port while idle. A running engine keeps its socket, so this
    /// only takes effect on the next start.
    package func updatePort(_ value: Int) {
        guard value != port else { return }
        port = value
    }

    /// Absolute path handed to the engine: splash's existing model folder, or
    /// that engine's own folder inside flashCat's support directory.
    package var modelsDirectory: String { EnginePaths.modelsDirectory(id) }

    package var endpoint: EngineEndpoint { EngineEndpoint(engine: id, port: port) }

    // MARK: startup stage, derived from the engine's own log lines

    package var startupStage: String {
        switch state {
        case .ready:
            // 热加载引擎的 HTTP 壳子先绿、权重后到：uvicorn 打出 application
            // startup complete 的那一刻 /health 就 200 了，而 oMLX 往往要到下
            // 一秒才开始搬权重。这时报「就绪」，界面会在权重还在往显存里搬的
            // 时候显示运行中，用户再点一个模型就会把加载中的进程 SIGINT 掉。
            // 要的模型还没进 loaded_models，就仍然按「加载权重」报阶段。
            if descriptor.switchMode == .hot, let wanted = desiredModel, !wanted.isEmpty,
                let live = status, live.model != wanted,
                live.loadedModels.contains(wanted) == false
            {
                return EngineStartupStage.loadingWeights.rawValue
            }
            return EngineStartupStage.ready.rawValue
        case .failed: return "启动失败"
        case .stopped: return "已停止"
        case .stopping: return "停止中"
        case .starting: break
        }
        if status?.state == .loading { return EngineStartupStage.loadingWeights.rawValue }
        // The stage comes from the engine's own lines only: the app's banner
        // echoes the whole command line, `--max-context` included, and names no
        // phase — scanning it reported a stage for a server that had exited.
        let latest = logs.latestId
        if let cached = stageLogCache, cached.latest == latest, cached.baseline == stageBaseline {
            return cached.stage
        }
        let recent = logs.tail(60)
            .filter { $0.id > stageBaseline && $0.level != .system }
            .map(\.text)
        let stage = EngineStartupStage.derive(from: recent).rawValue
        stageLogCache = (latest, stageBaseline, stage)
        return stage
    }

    /// Seconds the current start has been running, nil while idle. The console
    /// shows it beside the stage: a warmup that takes minutes then reads as
    /// progress that is still moving, not as a spinner that hung.
    package var busySeconds: Int? {
        guard let busySince else { return nil }
        return max(0, Int(Date().timeIntervalSince(busySince)))
    }

    /// Seconds the current weight load has been running, nil when no load is in
    /// flight. 热加载引擎的 HTTP 壳子先绿、权重后到，那一段等待也要能报秒数。
    package var weightLoadSeconds: Int? {
        guard let hotLoadSince else { return nil }
        return max(0, Int(Date().timeIntervalSince(hotLoadSince)))
    }

    package var downloadProgress: Double? {
        let latest = logs.latestId
        if let cached = downloadProgressCache, cached.latest == latest {
            return cached.value
        }
        var value: Double?
        for line in logs.tail(40).reversed() {
            if let match = TextPattern.firstMatch("(\\d{1,3}(?:\\.\\d)?)%", line.text),
                let parsed = Double(match[0])
            {
                value = min(max(parsed, 0), 100)
                break
            }
        }
        downloadProgressCache = (latest, value)
        return value
    }

    // MARK: start / stop

    /// Bumped by every `stop()`, so a launch that was waiting on a preparation
    /// can tell that the user changed their mind and must not start after all.
    var stopRequests = 0

    /// `localModel` only matters for splash, whose serve script takes an
    /// assembly/target pair. Other engines take a model identifier.
    package func start(localModel: ModelInfo? = nil, requestedModel: String? = nil) async {
        // A start that is still preparing (fetching the model's DFlash2 draft)
        // owns the controller: a second click must not launch a second engine
        // behind it, and must not be told the launch failed either.
        guard process == nil, !isLaunching, !isTerminating else { return }
        let attempt = stopRequests
        // 预约要覆盖整个启动过程，不能只盖准备阶段：`claimPort` 为了回收上一次
        // 遗留的引擎可能等上 90 秒，这段时间里第二次点击（或 CLI 的并发启动）
        // 必须看到「正在启动」，否则两个 `start()` 会各起一个进程，后一个覆盖
        // 前一个的 `process`，前一个的退出被 `finished === process` 静默丢掉。
        // 起点也记在这里：「已等待」从点下启动这一刻起表，准备阶段（下载 draft
        // 草稿、等端口）也算同一次等待——之前要等进程真的拉起来才记起点，几 GB
        // 的预下载全程显示「已等待 0:00」，之后又开始从零数，计数器像坏了。
        guard transition(to: .starting(since: Date())) else { return }
        // 上一轮异常退出的诊断只属于上一轮；这次启动可能是端口失败，
        // 不能让旧信号继续挂在异常卡上解释一个不相干的失败。
        exitDiagnostic = nil
        onChange()
        var localModel = localModel
        if let prepareForStart {
            switch await prepareForStart(localModel) {
            case .ready(let refreshed):
                // Stopped while the preparation ran: the engines page already
                // said 已停止 and must stay that way. `stop()` 已经把阶段收成
                // 「已停止」，这次启动不能再装作没发生过，把进程拉起来。
                guard attempt == stopRequests else { return }
                localModel = refreshed ?? localModel
            case .failed(let message):
                // Nothing was launched, so the engines page must show why the
                // click did not turn into a running engine.
                logs.openFile()
                logs.append("==> 启动取消：\(message)", level: .error)
                fail(message)
                return
            }
        }
        guard let plan = launchPlan(localModel: localModel, requestedModel: requestedModel) else { return }

        desiredModel = plan.model
        runModel = localModel
        guard let claimed = await claimPort(plan.model) else {
            // 端口申请不上时 `claimPort` 已经把原因写进 `failureMessage`；
            // 这里只负责把状态和正文一起收进 failed。
            fail(failureMessage ?? "无法为 \(id.displayName) 申请端口")
            return
        }
        // 等端口的这段时间里用户点了停止：`stop()` 已经把状态改成「已停止」，
        // 这次启动不能再装作没发生过，把进程拉起来。
        guard attempt == stopRequests else {
            transition(to: .stopped)
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
            failureMessage = nil
            stats = nil
            status = nil
            liveRates.reset()
            // 阶段还是 start() 开头那个 `.starting`：从这里到 `task.run()` 之间
            // 没有 await，中途插不进 `stop()`，所以不必再迁一次（再迁一次会把
            // 起点刷成现在，「已等待」就把预下载和等端口的那几分钟丢了）。
            startReader(stdout, index: 0)
            startReader(stderr, index: 1)
            startPolling()
            startStartupDeadline(for: task)
            onChange()
        } catch {
            // `process` 还没赋值（赋值在 `run()` 之后），所以这里失败一定没有
            // 留下半启动的进程；正文与阶段由 `fail` 一起写。
            logs.close()
            fail("无法启动服务：\(error)")
        }
    }

    package struct LaunchPlan {
        let executable: String
        let arguments: [String]
        let workingDirectory: String
        let environment: [String: String]
        let model: String
    }

    func launchPlan(localModel: ModelInfo?, requestedModel: String?) -> LaunchPlan? {
        let selected =
            requestedModel
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
        guard
            let profile = profileNames.compactMap({ manifest.launchProfiles[$0] }).first
                ?? manifest.launchProfiles.values.first
        else {
            fail("\(id.displayName) 的运行时包没有启动模板")
            return nil
        }

        // The manifest decides how the model is handed over. An engine only ever
        // sees a path inside flashCat's own models folder — the weights live
        // there, not in the user's upstream caches.
        let modelPath =
            LocalEngineModels.scan(engine: id, directory: modelsDirectory)
            .first(where: { $0.id == selected })?.path
            ?? EnginePaths.modelPath(for: id, model: selected)
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
            "modelID": selected,
            "modelPath": modelPath,
            "support": Paths.supportDirectory,
            "home": Paths.home,
        ]
        let tuning = EngineStore.shared.tuning(for: id)
        var arguments = EngineTemplate.expand(profile.args, context: values)

        if descriptor.adapter == .splash, let localModel {
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
        if descriptor.adapter == .splash, let budget = tuning.effectiveThinkingBudget(for: .splash) {
            arguments += ["--thinking-token-budget", String(budget)]
        }
        if descriptor.adapter == .splash, let effort = settings.effectiveReasoningEffort {
            arguments += ["--default-reasoning-effort", effort]
        }

        // 对话里画图要同时挂着对话模型和图像模型，mlx-serve 的包模板却把常驻
        // 上限钉在 1。这里抬到 2：它只是上限，不会因此多加载任何权重，真正的
        // 占用仍由 --max-resident-mem 按本机内存把关。包是下载来的，改本机的
        // manifest 只能修开发机，所以在装配参数时统一纠正；放在调优参数之后，
        // 自定义参数里写下的旧上限也会被这一行盖掉。
        if descriptor.adapter == .mlxServe {
            arguments = EngineTemplate.raisingIntegerFlag(
                "--max-resident-models",
                toAtLeast: 2,
                in: arguments)
        }

        if !arguments.contains(String(port)) {
            // A manifest that forgot `{port}` would silently bind its default.
            logs.append("==> 警告：\(id.displayName) 的启动模板未包含 {port}", level: .warning)
        }

        var environment = baseEnvironment(root: installation.root.path)
        // The disk tier needs its directory to exist before the engine starts;
        // mlx-serve's fixed path is linked into the shared root here too.
        if tuning.effectivePrefixCacheDiskGB(for: id) != nil {
            FlashCatPaths.preparePrefixCacheDirectory(id)
        }
        for (key, raw) in profile.environment ?? [:] {
            environment[key] = EngineTemplate.expand(raw, context: values)
        }
        // MTPLX 的思考截断走 ThinkingGuard 的环境变量：引擎默认关、且默认
        // 只覆盖 agent 工具循环，这里显式开启并把范围放宽到普通聊天，
        // 与 splash/oMLX 的截断语义对齐。重启后生效。
        if descriptor.adapter == .mtplx, let budget = tuning.effectiveThinkingBudget(for: .mtplx) {
            environment["MTPLX_THINKING_BUDGET"] = String(budget)
            environment["MTPLX_THINKING_GUARD_SCOPE"] = "all"
        }
        // MTPLX 的 session bank 预算是「空闲上限」，但内存紧张时会先掉到
        // 1 GiB 下限。它的 GDN boundary 记录每次约 90 MB、默认最多 8 个，
        // 于是一个 19K token 的条目光 boundary 就要 700 MB 以上——put() 把
        // 这笔开销算进 entry_nbytes 后整个条目被 skipped_oversized_snapshot
        // 拒绝，bank 里只剩不含 boundary 的条目；而
        // recurrent_boundary_at_or_below() 对无 boundary 条目返回 None，
        // 近前缀恢复因此永远失败，报出来的却是 ssd_prefix_miss，把
        // admission 的真因掩盖成了「SSD 没命中」。
        //
        // boundary 记录本身是可丢弃的加速件（重新 prefill 即可重建），
        // 丢弃整个条目等于用一个 0.5 秒的恢复换一次 15.8 秒的冷预填充。
        // 打开 shedding 后「能留下几条 boundary 就留几条」，条目得以进入
        // bank。默认关；开关读在 SessionBank 构造时，一次启动一个策略。
        if descriptor.adapter == .mtplx {
            environment["MTPLX_SESSION_BANK_SHED_BOUNDARIES"] = "1"
        }
        // flashcat_serve.py detaches a watchdog that ends the server when the
        // app is gone; it finds this app through the pid file.
        if descriptor.adapter == .splash {
            environment["FLASHCAT_PID_FILE"] = EnginePaths.pidFile(.splash)
        }

        return LaunchPlan(
            executable: installation.entrypoint.path,
            arguments: arguments,
            workingDirectory: installation.root.path,
            environment: environment,
            model: selected)
    }

    /// 就绪即撤掉启动看门狗。它只为「这一次启动」计时；跑完之后还挂着的话，
    /// 之后一次热切换（`state` 又回到 `.starting`，`process` 还是同一个）会在
    /// 计时器到期时被误判成启动超时，把一个健康的引擎标成失败。
    ///
    /// 还要确认进程仍在：`Ready ·` 那行日志由读线程经主队列送进来，而
    /// `processExited` 的 terminationHandler 也排在主队列上，两者的先后没有保证。
    /// 引擎快速崩退时，退出回调可能先到——进程已经清空，随后到达的 Ready 行再把
    /// `state` 改成 `.ready`。`isReady` 只看 state、`isRunning` 只看 process，于是
    /// 两个都为真、`AppState.canChat` 放行，请求会打到一个已经关掉的回环端口，
    /// 读的人看到的是「连接失败」而不是「引擎退出了」。
    // internal 而不是 private：这是读线程那行 `Ready ·` 落到状态机上的唯一入口，
    // 测试要能在进程已经清空之后单独喂它一次，验证迟到信号被丢掉
    // （`EngineControllerPhaseTests.testLateReadySignalIsDropped`）。
    package func markReady() {
        startupWatchdog?.cancel()
        startupWatchdog = nil
        guard process != nil, !isTerminating else {
            // 迟到的就绪信号直接丢掉，并留一行日志：日志页是这套系统唯一的
            // 排查入口，这条竞态真发生时得有人能看见它是怎么被处理的。
            logs.append("==> 忽略迟到的就绪信号（进程已退出）", level: .warning)
            return
        }
        // 「什么算就绪」交给迁移表：重复的就绪不是一次迁移（`poll()` 每秒都会
        // 喊一次），停止中的就绪会被拦下并留一条告警。
        guard transition(to: .ready) else { return }
        onChange()
    }

    func fail(_ message: String) {
        // 正文先进 `failureMessage` 再迁阶段：界面上「异常 + 原因」是一个东西，
        // 分两次写会让读者看到一帧只有「异常」的界面。
        failureMessage = message
        transition(to: .failed(reason: message))
        onChange()
    }

    /// A pack must never inherit the user's Python environment: a stray
    /// `PYTHONPATH` would load a different mlx and break the precompiled metal
    /// kernels, so those variables are cleared rather than overridden.
    func baseEnvironment(root: String) -> [String: String] {
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

    package func stop() {
        // Whatever was resident dies with the process, so the hot-load cool-down
        // no longer applies: the next start must load its model again.
        lastHotLoad = nil
        stopRequests += 1
        // 退出流程已经在收尾：再走一遍只会重复打信号，还会把 `.terminating`
        // 改写成 `.stopping`，`markReady` 判断迟到信号就失去了依据。
        if isTerminating { return }
        if process == nil {
            // 已经不在跑了（典型是点「停止」时还在准备阶段）：阶段收成
            // 「已停止」，等待计时也跟着结束，下一次启动重新起表。
            transition(to: .stopped)
            onChange()
            return
        }
        if isStopping { return }
        transition(to: .stopping(since: Date()))
        logs.append("==> 正在停止服务…", level: .system)
        onChange()

        if let process, let pid = processPid(process) {
            // The pack python is only the trunk: the inference binary and pool
            // workers below it hold the weights, so the whole tree is signalled.
            // The tree is captured once, while the root is still alive — the
            // escalation below must reuse it, because 20 seconds later the root
            // is gone and a fresh walk would come up empty.
            let tree = snapshotProcessTree(pid)
            tree.signal(SIGINT)
            let grace: TimeInterval = 20
            DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
                guard let self else { return }
                // 不能用 `self.process` 当门：python 主干收到 SIGINT 就先退了，
                // `processExited` 会把 `self.process` 清空，而下面的推理二进制
                // 和池 worker 可能还在抱着权重。只看快照里仍然活着、并且确实
                // 属于本引擎 pack 的 pid（pid 被复用时不误杀别人）。
                let survivors = tree.pids.filter {
                    $0 > 1 && self.processAlive($0) && self.processBelongsToPack($0)
                }
                guard !survivors.isEmpty else { return }
                self.logs.append(
                    "==> 服务未在 \(Int(grace)) 秒内完全退出，强制结束残留进程（\(survivors.count) 个）",
                    level: .system)
                for victim in survivors { kill(victim, SIGKILL) }
            }
        }
    }

    package enum ModelSwitchOutcome: Equatable {
        case ready
        case failed(String)
    }

    package func restart(localModel: ModelInfo? = nil) async {
        if isRunning {
            guard await stopAndWait() else {
                // 进程可能还活着，所以先写正文再迁阶段：读者点完「重启」看到
                // 的第一句话就是这次为什么没重启。
                failureMessage = "旧服务（端口 \(port)）未能退出，已取消重启"
                transition(to: .failed(reason: failureMessage))
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
    package func stopAndWait(grace: Double = 12, timeout: Double = 90) async -> Bool {
        if process == nil && !portOpen(port) { return true }
        stop()
        let startedAt = Date()
        let pid = process.flatMap(processPid)
        var escalated = false
        while Date().timeIntervalSince(startedAt) < timeout {
            if process == nil && !portOpen(port) { return true }
            if !escalated, Date().timeIntervalSince(startedAt) > grace, let pid {
                escalated = true
                logs.append(
                    "==> \(id.displayName) 未在 \(Int(grace)) 秒内退出，强制结束（pid \(pid)）",
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
    package func waitForReady(timeout: TimeInterval) async -> Bool {
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

    /// 切换/跳引擎的「真的就绪」判据，比 `waitForReady` 严一档。
    /// 健康检查 200 只说明 HTTP 壳子起来了：oMLX 的 uvicorn 在权重还没搬完的
    /// 时候就返回 200（日志实测：22:02:06 application startup complete，
    /// 22:02:07 才开始 Loading model）。只看健康检查会把一次 27B 的加载在开头
    /// 就判成完成——界面退出「切换中」，读者接着再点一个模型，那台还在搬权重的
    /// 进程就被 SIGINT，要等 20 秒强杀才让出显存。热加载引擎必须等它自己把要的
    /// 模型列进 loaded_models。
    package func waitForSwitchReady(_ target: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        // `startService()` 把启动丢进一个 Task，控制器要到下一次 actor 跳转才
        // 进 `.starting`；调用方紧接着来等就绪，第一眼看到的还是 `.stopped`。
        // 旧实现把这一眼当成「启动失败」，于是 `flashcat engines start` 在引擎
        // 正常加载时报「未能就绪：等待超时」——命令失败、引擎其实起来了。
        let began = Date()
        let startGrace: TimeInterval = 5
        var sawStarting = false
        while Date() < deadline {
            if Task.isCancelled { return false }
            switch state {
            case .failed: return false
            case .stopped:
                // 宽限期内允许「还没开始」；见过 `.starting` 之后再停就是真的停了。
                if sawStarting || Date().timeIntervalSince(began) > startGrace { return false }
            case .starting, .stopping:
                sawStarting = true
            case .ready:
                if descriptor.switchMode != .hot { return true }
                if status?.model == target { return true }
                if status?.loadedModels.contains(target) == true { return true }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    package func toggle(localModel: ModelInfo? = nil) {
        if isRunning { stop() } else { Task { await start(localModel: localModel) } }
    }

    /// App-quit teardown, in two halves so nothing blocks the main actor.
    ///
    /// The old single `dispose()` sat in a `Thread.sleep` loop for up to eight
    /// seconds waiting for the engine to exit. On `@MainActor` that froze the
    /// quit — `processExited` could not even be delivered — and a frozen quit is
    /// what makes readers force-kill the app, which is precisely what leaves
    /// engines resident. Now the quit path is: signal, await a short grace
    /// off the main actor, then kill whatever ignored the signal.
    ///
    /// First half: snapshot the tree and ask it to stop.
    ///
    /// Returns whether anything was signalled. The quit path uses it to skip
    /// the grace period when no engine is running — waiting 1.5 s for nothing
    /// is exactly the kind of fixed delay that makes quitting feel broken.
    @discardableResult
    package func prepareForTermination() -> Bool {
        guard !isTerminating else { return false }
        pollTimer?.invalidate()
        pollTimer = nil
        startupWatchdog?.cancel()
        startupWatchdog = nil
        var signalled = false
        if let process, let pid = processPid(process) {
            let tree = snapshotProcessTree(pid)
            terminationTree = tree
            tree.signal(SIGINT)
            // 退出也是状态机的一个阶段：进程还活着，但已经不该被当成「能聊天」，
            // 也不能被迟到的 `Ready ·` 拉回 ready。只在真有进程时迁——空闲的
            // 控制器保持 `.stopped`，免得退出瞬间把「这个引擎本来没在跑」这件事
            // 说成「正在停止」。
            transition(to: .terminating)
            signalled = true
        }
        removePidFile()
        return signalled
    }

    /// True while anything from the termination snapshot is still running.
    package var hasLiveEngineProcesses: Bool {
        terminationTree?.anyAlive ?? false
    }

    /// Second half, after the grace period. Uses the snapshot from
    /// `prepareForTermination`: by now the root has exited and its children
    /// belong to launchd, so a fresh traversal would find nothing.
    package func finishTermination() {
        terminationTree?.signal(SIGKILL)
        terminationTree = nil
        logs.close()
    }

}

// MARK: - small HTTP client

package struct HTTPResponse {
    package let status: Int
    package let body: Data
}

package enum HTTP {
    /// 复用同一个会话。以前每个请求都新建 `URLSession` 再 `invalidate`，
    /// 每秒的健康探测加上多个 telemetry 端点会不断创建/销毁连接池和线程。
    /// 会话本身是线程安全的，超时改用 request 级的 `timeoutInterval`。
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 8
        // 资源级超时必须覆盖最长的请求：热加载一个 27B 模型会传 600s，
        // 这里若设得比它小，per-request timeout 再大也会被会话提前掐断。
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1800
        return URLSession(configuration: configuration)
    }()

    /// Loopback JSON GET with a hard timeout. `URLSession` is replaced by a
    /// delegate-configured session so a wedged engine cannot hang the poller.
    package static func get(port: Int, path: String, timeout: TimeInterval) async -> HTTPResponse? {
        await send(method: "GET", port: port, path: path, body: nil, timeout: timeout)
    }

    /// POST with an empty body — enough for oMLX's load/unload switches.
    package static func post(port: Int, path: String, timeout: TimeInterval) async -> HTTPResponse? {
        await send(method: "POST", port: port, path: path, body: nil, timeout: timeout)
    }

    package static func request(
        method: EngineHTTPMethod,
        port: Int,
        path: String,
        json: Data?,
        timeout: TimeInterval
    ) async -> HTTPResponse? {
        await send(method: method.rawValue, port: port, path: path, body: json, timeout: timeout)
    }

    /// PUT a JSON object, used for oMLX's per-model settings document.
    package static func put(port: Int, path: String, json: Data, timeout: TimeInterval) async -> HTTPResponse? {
        await send(method: "PUT", port: port, path: path, body: json, timeout: timeout)
    }

    static func send(
        method: String,
        port: Int,
        path: String,
        body: Data?,
        timeout: TimeInterval
    ) async -> HTTPResponse? {
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
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return HTTPResponse(status: status, body: data)
        } catch {
            return nil
        }
    }
}
