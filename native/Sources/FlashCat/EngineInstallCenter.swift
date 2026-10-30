import SwiftUI
import AppKit
import FlashCatKit

/// Drives pack installs: loads the release index once, then runs one install at
/// a time (they write into the same folder tree). Consumed by the WebUI bridge
/// (WebViewShell) for the launch page and the engine page install buttons.
@MainActor
final class EngineInstallCenter: ObservableObject {
    @Published private(set) var releases: [EngineID: [EnginePackRelease]] = [:]
    @Published private(set) var phases: [EngineID: EngineInstallPhase] = [:]
    @Published private(set) var installed: [EngineID: [String]] = [:]
    @Published private(set) var indexError: String?
    @Published private(set) var indexLoaded = false
    /// One GitHub probe per engine, so a card can say "newer than what you have".
    @Published private(set) var upstream: [EngineID: EngineUpstreamStatus] = [:]
    @Published private(set) var upstreamCheckedAt: Date?
    /// The engine whose pack is being built right now (builds run one at a time).
    @Published private(set) var building: EngineID?
    /// One continuous 0…1 fraction per engine covering the whole build-then-install
    /// run, plus the step happening right now. The scrolling per-line build log
    /// was dropped: the ring on the card and the percent on the button carry the
    /// same information without a console.
    @Published private(set) var progress: [EngineID: Double] = [:]
    @Published private(set) var progressStep: [EngineID: String] = [:]
    /// When the running build step began; feeds the within-step creep estimate.
    private var stepStartedAt: [EngineID: Date] = [:]
    /// Zero-based index of the build step currently running.
    private var runningStepIndex: [EngineID: Int] = [:]

    private let checker = EngineUpstreamChecker()
    /// Last GitHub answer per engine, kept so a finished install can be compared
    /// again without spending another API call.
    private var upstreamReleases: [EngineID: EngineUpstreamRelease] = [:]
    private var installer: EngineInstaller?
    private var onChange: (() -> Void)?
    /// Called after a pack finished installing; the launch page uses it to make
    /// the freshly installed engine the active one.
    var onInstalled: ((EngineID) -> Void)?
    /// Success/failure bubbles surface through the app-wide toast.
    var onToast: ((String) -> Void)?

    func configure(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let environment = EngineInstallEnvironment(
            packsDirectory: EnginePaths.enginesDirectory,
            indexURL: ProcessInfo.processInfo.environment["FLASHCAT_PACK_INDEX_URL"]
                .flatMap { $0.isEmpty ? nil : URL(string: $0) },
            bundledIndexPath: Bundle.main.url(forResource: "pack-index", withExtension: "json")?.path)
        installer = EngineInstaller(environment: environment)
        // The launch page can appear before bootstrap() has configured us, so the
        // index load is kicked here instead of relying on a view task that may
        // already have run.
        Task { await loadIndexIfNeeded() }
    }

    func refreshInstalled() {
        var result: [EngineID: [String]] = [:]
        for id in EngineID.allCases {
            result[id] = EngineInstallations.installed(id).map(\.version)
        }
        installed = result
        // A pack that just landed must stop showing up as "update available"
        // without waiting for the next GitHub check.
        for (id, release) in upstreamReleases {
            upstream[id] = EngineUpstreamComparison.status(installed: result[id] ?? [], release: release)
        }
    }

    func loadIndexIfNeeded(force: Bool = false) async {
        guard let installer, force || !indexLoaded else { return }
        indexLoaded = true
        do {
            let index = try await installer.loadIndex()
            var result: [EngineID: [EnginePackRelease]] = [:]
            for id in EngineID.allCases {
                result[id] = index.releases(for: id)
            }
            releases = result
            indexError = nil
        } catch {
            indexError = error.localizedDescription
        }
    }

    func install(_ release: EnginePackRelease, for id: EngineID, afterBuild: Bool = false) {
        guard phases[id]?.isBusy != true, let installer else { return }
        let isFirstInstall = (installed[id] ?? []).isEmpty
        phases[id] = .resolving
        progress[id] = Self.installProgress(.resolving, afterBuild: afterBuild)
        progressStep[id] = Self.stepLabel(.resolving)
        Task { [weak self] in
            do {
                _ = try await installer.install(release, for: id) { phase in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.phases[id] = phase
                        self.progress[id] = Self.installProgress(phase, afterBuild: afterBuild)
                        if let label = Self.stepLabel(phase) {
                            self.progressStep[id] = label
                        }
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    phases[id] = .installed(version: release.version)
                    progress[id] = nil
                    progressStep[id] = nil
                    refreshInstalled()
                    onChange?()
                    onToast?("\(id.displayName) \(release.version) 安装成功")
                    // Only a first install makes the engine the active one; an
                    // update must leave whatever the user was running alone.
                    if isFirstInstall { onInstalled?(id) }
                    // An update replaces the engine, so the previous removable
                    // versions are pruned automatically to reclaim disk.
                    pruneOldVersions(id, keeping: release.version)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    phases[id] = .failed(message: error.localizedDescription)
                    progress[id] = nil
                    progressStep[id] = nil
                    onToast?("\(id.displayName) 安装失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Unified build + install progress

    /// The build occupies 0…0.85 of the whole run; the pack install that follows
    /// squeezes into the 0.85…1 tail. A direct install (no build) uses the full
    /// span. Every phase lands on the curve — including 解包, 校验包 and 激活,
    /// which have no measurable bytes — so the ring never drops back to a
    /// frozen or indeterminate state mid-run.
    private static func installProgress(_ phase: EngineInstallPhase, afterBuild: Bool) -> Double {
        let base = afterBuild ? 0.85 : 0.0
        let span = afterBuild ? 0.15 : 1.0
        let local: Double
        switch phase {
        case .idle, .failed:
            return base
        case .resolving:
            local = 0.04
        case .downloading(let fraction, _, _):
            local = 0.08 + 0.80 * min(max(fraction, 0), 1)
        case .verifying:
            local = 0.90
        case .unpacking:
            local = 0.93
        case .validating:
            local = 0.96
        case .activating:
            local = 0.985
        case .installed:
            local = 1.0
        }
        return base + span * local
    }

    /// Short label for the step shown beside the progress ring. Downloading
    /// leaves the percent to the ring instead of repeating it in text.
    private static func stepLabel(_ phase: EngineInstallPhase) -> String? {
        switch phase {
        case .resolving: "解析版本"
        case .downloading: "下载中"
        case .verifying: "校验 SHA256"
        case .unpacking: "解包"
        case .validating: "校验包"
        case .activating: "激活"
        case .idle, .installed, .failed: nil
        }
    }

    /// Fraction for the build half. Steps are equally weighted and there is no
    /// measurable sub-step progress, so the running step creeps forward on a
    /// decaying time curve (capped below its slice end) — the percent always
    /// moves instead of freezing for minutes, then snaps to the exact value
    /// when the step completes.
    private static func buildProgress(completed: Int, total: Int, elapsed: TimeInterval) -> Double {
        let weight = 0.85
        let slice = weight / Double(max(total, 1))
        let within = (1 - exp(-elapsed / 75)) * 0.85
        return min((Double(completed) + within) * slice, weight)
    }

    private func clearProgress(_ id: EngineID) {
        progress[id] = nil
        progressStep[id] = nil
        stepStartedAt[id] = nil
    }

    // MARK: Old-version pruning

    /// After an install/update lands, the previous removable versions are no
    /// longer useful and only cost disk, so they are dropped automatically.
    /// Bundled or checkout packs are never touched — `removableVersions`
    /// excludes them, so the guard below leaves them in place.
    private func pruneOldVersions(_ id: EngineID, keeping version: String) {
        let deletable = EngineInstallations.removableVersions(id)
        let stale = (installed[id] ?? []).filter { $0 != version && deletable.contains($0) }
        guard !stale.isEmpty, let installer else { return }
        Task { [weak self] in
            for old in stale {
                do {
                    _ = try await installer.uninstall(id, version: old)
                    await MainActor.run {
                        self?.refreshInstalled()
                        self?.onChange?()
                    }
                } catch {
                    // A failed prune must not disturb the freshly installed
                    // version's state; leave the old pack where it is.
                }
            }
        }
    }

    // MARK: Upstream check

    /// Probes GitHub for the newest release of every engine. Unauthenticated and
    /// rate limited (60/h), so the result is reused for a few hours unless the
    /// user explicitly asks to check again.
    func checkUpstream(force: Bool = false) async {
        if !force, let checkedAt = upstreamCheckedAt,
           Date().timeIntervalSince(checkedAt) < 6 * 3600, !upstream.isEmpty {
            return
        }
        refreshInstalled()
        var result: [EngineID: EngineUpstreamStatus] = [:]
        for id in EngineID.allCases {
            do {
                let release = try await checker.latest(for: id)
                upstreamReleases[id] = release
                result[id] = EngineUpstreamComparison.status(installed: installed[id] ?? [], release: release)
            } catch {
                result[id] = .unavailable(error.localizedDescription)
            }
        }
        upstream = result
        upstreamCheckedAt = Date()
    }

    // MARK: Build from source

    /// Builds the runtime pack for `release` on this machine and installs it.
    /// The three engines have different sources, so the plan differs per engine
    /// (see `EnginePackBuildPlanner`); progress streams into one ring instead of
    /// a log so a slow `uv pip install` (bootstrapped by the scripts) is not a
    /// silent hang.
    func buildAndInstall(_ release: EngineUpstreamRelease, for id: EngineID) {
        guard building == nil, installer != nil else { return }
        guard let repository = EnginePackBuildRunner.locateRepository() else {
            phases[id] = .failed(message: EnginePackBuildError.repositoryNotFound.localizedDescription)
            onToast?("构建失败：\(EnginePackBuildError.repositoryNotFound.localizedDescription)")
            return
        }
        building = id
        stepStartedAt[id] = Date()
        progressStep[id] = "准备"
        progress[id] = 0
        phases[id] = .idle

        Task { [weak self] in
            guard let self else { return }
            do {
                let steps = EnginePackBuildPlanner.steps(for: id, version: release.version, release: release)
                let total = max(steps.count, 1)
                let order = Dictionary(uniqueKeysWithValues: steps.enumerated().map { ($1.id, $0) })
                try await EnginePackBuildRunner.run(steps: steps, in: repository) { step in
                    let index = order[step.id] ?? 0
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.runningStepIndex[id] = index
                        self.stepStartedAt[id] = Date()
                        self.progressStep[id] = step.title
                        self.progress[id] = Self.buildProgress(completed: index, total: total, elapsed: 0)
                    }
                } onLine: { _ in
                    // Output lines no longer surface as a log; they only nudge
                    // the within-step creep forward so the percent keeps moving.
                    Task { @MainActor [weak self] in
                        guard let self, let started = self.stepStartedAt[id] else { return }
                        let elapsed = Date().timeIntervalSince(started)
                        let index = self.runningStepIndex[id] ?? 0
                        self.progress[id] = Self.buildProgress(completed: index, total: total, elapsed: elapsed)
                    }
                }
                let path = repository + "/" + EnginePackBuildPlanner.releaseFile(for: id, version: release.version)
                let pack = try EnginePackBuildRunner.loadRelease(at: path)
                await self.loadIndexIfNeeded(force: true)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    building = nil
                    runningStepIndex[id] = nil
                    // Hand the remaining span to the install phase.
                    progress[id] = Self.installProgress(.resolving, afterBuild: true)
                    progressStep[id] = Self.stepLabel(.resolving)
                    stepStartedAt[id] = nil
                    install(pack, for: id, afterBuild: true)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    building = nil
                    runningStepIndex[id] = nil
                    clearProgress(id)
                    phases[id] = .failed(message: error.localizedDescription)
                    onToast?("\(id.displayName) \(release.version) 构建失败：\(error.localizedDescription)")
                }
            }
        }
    }

}

