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
        draftAcceptance = status.draftAcceptance
        ttftMilliseconds = status.ttftMilliseconds
        activeRequests = status.activeRequests
        queuedRequests = status.queuedRequests
        memoryBytes = status.memoryBytes
        peakMemoryBytes = status.peakMemoryBytes
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

    init(settings: AppSettings, catalog: ModelCatalog) {
        self.settings = settings
        self.catalog = catalog
        rebuild()
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
    func rebuild() {
        let previous = controllers
        var next: [EngineController] = []
        for id in EngineID.allCases {
            guard let installation = EngineInstallations.newest(id, version: nil) else { continue }
            let port = EngineStore.shared.configuration(for: id).port ?? id.defaultPort
            let controller = EngineController(id: id,
                                              installation: installation,
                                              settings: settings,
                                              catalog: catalog,
                                              port: port)
            controller.onChange = { [weak self] in self?.onChange() }
            next.append(controller)
        }
        // Keep the previous instance when nothing changed, so a running process
        // is not orphaned by a rebuild.
        controllers = next.map { fresh in
            previous.first { $0.id == fresh.id && $0.installation.root == fresh.installation.root } ?? fresh
        }
        let preferred = EngineStore.shared.preferredEngine
        if controllers.contains(where: { $0.id == preferred }), preferred != activeID {
            activeID = preferred
        }
        if !controllers.contains(where: { $0.id == activeID }) {
            activeID = controllers.first?.id ?? .splash
        }
    }

    func activate(_ id: EngineID) {
        guard id != activeID else { return }
        guard let target = controller(id) else { return }
        for controller in controllers where controller.id != id {
            if controller.isRunning { controller.stop() }
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
        _ = target
        onChange()
    }

    /// Engines other than splash run with their own model names, so the global
    /// `settings.model` is only meaningful for the active engine.
    func setModel(_ id: String, for engine: EngineID) {
        EngineStore.shared.update(engine) { $0.lastModel = id }
        if engine == activeID { settings.setModel(id) }
    }

    func dispose() {
        for controller in controllers { controller.dispose() }
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
