import Foundation
import FlashCatKit

extension ServerStats {
    /// Host facts are process-wide constants; reading them once keeps the 1 s
    /// poll from re-running sysctl on every refresh.
    private static let hostChipName = DeviceProfile.current().chipName
    private static let hostPhysicalMemory = Int(ProcessInfo.processInfo.physicalMemory)

    /// Bridge the engine-neutral status into the shape the dashboards already
    /// render. Fields the other engines do not report keep their last value.
    init(engineStatus status: EngineStatus, previous: ServerStats?) {
        self.init()
        decodeTokensPerSecond = status.decodeTokensPerSecond
        prefillTokensPerSecond = status.prefillTokensPerSecond
        decodeRateKind = status.decodeRateKind
        prefillRateKind = status.prefillRateKind
        draftAcceptance = status.draftAcceptance
        ttftMilliseconds = status.ttftMilliseconds
        activeRequests = status.activeRequests
        queuedRequests = status.queuedRequests
        memoryBytes = status.memoryBytes
        peakMemoryBytes = status.peakMemoryBytes
        cacheHitRate = Self.cacheHitRate(from: status.extras)
        maximumContextTokens = status.maximumContextTokens
        model = status.model
        requestsCompleted = status.requestsCompleted
        requestsFailed = status.requestsFailed
        startedAt = status.startedAt
        instancePid = status.processIdentifier.map(Int.init)
        // Every engine runs on this machine, so device facts come straight
        // from the host. The old `previous?` hand-down could never be filled
        // (ServerStats.parse is not on this path), which left 内存压力 and
        // 设备 showing "—" forever.
        deviceName = Self.hostChipName
        physicalMemoryBytes = Self.hostPhysicalMemory
        gpuCores = previous?.gpuCores
        vision = previous?.vision
        kvFormat = previous?.kvFormat
        if let thermal = status.extras["thermal_state"] {
            self.thermal = thermal == 0 ? "nominal" : "fair"
        }
        if let pressure = status.extras["memory_pressure_warn"] {
            memoryPressure = pressure == 0 ? "normal" : "warning"
        }
    }

    /// 引擎自报的缓存命中率（0…1）：命中量与提示词总量都是引擎自己的累计
    /// 计数器，相除才是「命中量 / 提示词总量」的按代平均。
    ///
    /// - mlx-serve：`counters.prefix_cache_tokens_total / counters.prompt_tokens_total`
    /// - MTPLX：`lifetime.cached_tokens_total / lifetime.prompt_tokens_total`
    /// - oMLX：`total_cached_tokens / total_prompt_tokens`（它另给一个百分数
    ///   `cache_efficiency`，本质是同一个比值，所以统一用计数器算，少一套单位）
    ///
    /// 分母为 0（进程刚起、还没有请求）时返回 nil，界面画「—」而不是 0%。
    private static func cacheHitRate(from extras: [String: Double]) -> Double? {
        guard let prompt = extras["prompt_tokens_total"], prompt > 0,
              let cached = extras["total_cached_tokens"] else { return nil }
        return min(1, max(0, cached / prompt))
    }
}

/// Owns every engine, remembers which one is active, and makes sure only one
/// runs at a time: two MLX engines on one GPU would fight for the same memory.
@MainActor
final class EngineManager {
    private(set) var controllers: [EngineController] = []
    private(set) var activeID: EngineID = .splash

    let settings: AppSettings
    private(set) var catalog: ModelCatalog

    var onChange: () -> Void = {}

    /// Handed to every controller, so a launch (start, restart, hot switch)
    /// can be held back until the app has what the model needs on disk.
    var prepareForStart: (@MainActor (ModelInfo?) async -> StartPreparation)? {
        didSet {
            for controller in controllers { controller.prepareForStart = prepareForStart }
        }
    }

    init(settings: AppSettings, catalog: ModelCatalog) {
        self.settings = settings
        self.catalog = catalog
        rebuild(preferring: EngineStore.shared.preferredEngine)
    }

    var active: EngineController? {
        controllers.first { $0.id == activeID } ?? controllers.first
    }

    var available: [EngineController] { controllers }
    var installedIDs: [EngineID] { controllers.map(\.id) }

    func controller(_ id: EngineID) -> EngineController? {
        controllers.first { $0.id == id }
    }

    /// Rebuild the controller list. Every engine is now an installed pack —
    /// splash included — so an engine without a pack simply has no controller
    /// and the launch page offers to download one.
    ///
    /// `preference` may move `activeID` only on launch and first adoption. A
    /// background rebuild (an install or uninstall landing) must leave the
    /// engine that is currently running exactly where it is; otherwise writing
    /// a startup default in Settings would silently move the active engine.
    func rebuild(preferring preference: EngineID? = nil) {
        let previous = controllers
        var next: [EngineController] = []
        for id in EngineCatalog.allIDs {
            guard let installation = EngineInstallations.newest(id, version: nil) else { continue }
            let port = EngineStore.shared.configuration(for: id).port
                ?? installation.descriptor.defaultPort
            let controller = EngineController(id: id,
                                              installation: installation,
                                              settings: settings,
                                              catalog: catalog,
                                              port: port)
            controller.onChange = { [weak self] in self?.onChange() }
            controller.prepareForStart = prepareForStart
            next.append(controller)
        }
        // Keep the previous instance when nothing changed, so a running process
        // is not orphaned by a rebuild.
        controllers = next.map { fresh in
            previous.first { $0.id == fresh.id && $0.installation.root == fresh.installation.root } ?? fresh
        }
        if let preference, controllers.contains(where: { $0.id == preference }) {
            activeID = preference
        }
        if !controllers.contains(where: { $0.id == activeID }) {
            activeID = controllers.first?.id ?? .splash
        }
    }

    /// Serialises engine handoffs: two selections in quick succession must not
    /// each stop the engine the other one is about to start.
    private var handoffInFlight = false

    /// Make `id` the running engine and return only once every other engine has
    /// really let go of its weights — process reaped and port released.
    ///
    /// `stop()` alone is fire-and-forget: the old python keeps its Metal buffers
    /// for another beat (SIGINT grace, then SIGKILL). Starting the next engine
    /// inside that window puts two models in unified memory at once, which is
    /// exactly how a switch between two 27B checkpoints runs out of memory or
    /// wedges the machine. Waiting here also means the caller can rely on
    /// "nothing else is loaded" before it starts the new engine.
    @discardableResult
    func activate(_ id: EngineID) async -> Bool {
        guard controller(id) != nil else { return false }

        // A handoff already owns the stop; queue behind it instead of racing it.
        // The check has to come before the id comparison: a handoff may be in
        // the middle of stopping the engine that is still `activeID`, and
        // returning "already active" there would let the caller start it again
        // while it is being torn down.
        while handoffInFlight {
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // Another handoff may have landed on this engine while we waited.
        guard id != activeID else { return true }
        handoffInFlight = true
        defer { handoffInFlight = false }

        for controller in controllers where controller.id != id && controller.isRunning {
            controller.logs.append("==> 切换引擎：等待 \(controller.id.displayName) 卸载模型并退出…",
                                   level: .system)
            let stopped = await controller.stopAndWait()
            if !stopped {
                controller.logs.append("==> \(controller.id.displayName) 未能在切换前退出，仍将继续切换",
                                       level: .error)
            }
        }

        activeID = id
        EngineStore.shared.update(id) { $0.enabled = true }
        EngineStore.shared.rememberActive(id)
        // Point the engine at flashCat's own model folder. Nothing is linked in
        // from outside, so this only settles any folder an older build left.
        EngineModelStore.adoptExistingWeights(id)
        let saved = EngineStore.shared.configuration(for: id).lastModel
        if let saved, !saved.isEmpty, saved != settings.model {
            settings.setModel(saved)
        }
        onChange()
        return true
    }

    /// Engines other than splash run with their own model names, so the global
    /// `settings.model` is only meaningful for the active engine.
    func setModel(_ id: String, for engine: EngineID) {
        EngineStore.shared.update(engine) { $0.lastModel = id }
        if engine == activeID { settings.setModel(id) }
    }

    /// App-quit teardown for every engine, not just the active one. A reader who
    /// installed three engines and switched between them has three processes to
    /// reap; disposing only `active` left the rest holding their weights after
    /// the app was gone.
    ///
    /// Synchronous on purpose. `applicationShouldTerminate` runs on the main
    /// thread; returning `.terminateLater` and finishing in a `Task` looked
    /// right, but AppKit tears the process down before that task is scheduled
    /// on current macOS — the engines and the history flush never ran. The
    /// whole wait is bounded (a healthy engine exits in tens of milliseconds;
    /// the grace only covers a wedged one), so the quit cannot hang.
    func shutdownEngines(grace: TimeInterval = 1.5) {
        let all = controllers
        let signalled = all.map { $0.prepareForTermination() }.contains(true)
        if grace > 0 && signalled {
            let deadline = Date().addingTimeInterval(grace)
            while Date() < deadline && all.contains(where: { $0.hasLiveEngineProcesses }) {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        for controller in all { controller.finishTermination() }
    }

    /// Runs once at launch, before this session starts anything: reaps engine
    /// processes a crashed or force-quit previous session left resident. Each
    /// controller only touches its own pack's directories.
    func sweepOrphanEngines() {
        for controller in controllers where controller.isInstalled {
            controller.sweepOrphans()
        }
    }
}
