import SwiftUI
import FlashCatKit

/// Drives pack installs for the engine page: loads the release index once, then
/// runs one install at a time (they write into the same folder tree).
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

// MARK: - Engine section (embedded in Settings)

/// 引擎管理区块：内嵌在设置页「模型」卡片之后。
/// 引擎随模型自动切换，这里只负责上游版本的检测与更新，引擎自己的参数在「配置…」面板里。
struct EngineRuntimeSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var installs: EngineInstallCenter
    @State private var configuring: EngineID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            // 三个引擎卡片横向并排，等宽分列；内容各自在卡内纵向排布。
            HStack(alignment: .top, spacing: 12) {
                ForEach(EngineID.allCases, id: \.self) { id in
                    card(id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            footer
        }
        .task {
            installs.refreshInstalled()
            await installs.loadIndexIfNeeded()
            // Auto-check on entry: the manual "重新检查" button was removed, so
            // opening the settings page is now the only trigger.
            await installs.checkUpstream(force: true)
        }
        .sheet(item: $configuring) { id in
            EngineConfigView(state: state, engine: id)
        }
    }

    /// 与设置页其他卡片的头部同一版式：图标 + 标题 + 说明，右侧放低频动作。
    private var header: some View {
        HStack(alignment: .center, spacing: 11) {
            ArcadeIcon(symbol: "shippingbox.and.arrow.backward",
                       colors: [Native.cyan, Native.cyan.opacity(0.55)],
                       size: 32,
                       glyphScale: 0.44,
                       glow: false)
            VStack(alignment: .leading, spacing: 2) {
                Text("引擎")
                    .font(.system(size: 15, weight: .semibold))
                Text("引擎随选择的模型自动切换；这里负责各引擎的版本更新")
                    .font(Native.calloutFont)
                    .foregroundStyle(Native.tertiary)
            }
            Spacer(minLength: 8)
            Button("启动页…") { state.showsLaunchPage = true }
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                .help("重新打开首次启动时的引擎选择页")
        }
        .padding(.top, 8)
    }

    private func card(_ id: EngineID) -> some View {
        let isActive = state.activeEngine == id
        let versions = installs.installed[id] ?? []
        let phase = installs.phases[id] ?? .idle

        return VStack(alignment: .leading, spacing: 0) {
            // Header: identity on the left, actions on the right.
            HStack(spacing: 8) {
                Circle()
                    .fill(isActive ? statusColor(state.serverState) : Native.overlay(0.18))
                    .frame(width: 7, height: 7)
                Text(id.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Native.label)
                Spacer(minLength: 6)
                Button("配置…") { configuring = id }
                    .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                    .disabled(versions.isEmpty)
            }
            .padding(.bottom, 12)

            // Install / build progress sits right under the header so a long
            // download never pushes the rest of the card around visually. One
            // ring covers the whole run; the step text beside it says what is
            // happening right now (构建 / 下载中 / 解包 / …).
            if let fraction = installs.progress[id], let step = installs.progressStep[id] {
                HStack(spacing: 9) {
                    ProgressRing(fraction: fraction, tint: Native.cyan, size: 30, lineWidth: 3.5)
                    Text(verbatim: step)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Native.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 10)
            } else if phase.isFailure {
                Text(phase.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.red.opacity(0.9))
                    .lineLimit(2)
                    .padding(.bottom, 10)
            } else if phase != .idle, !phase.isSettled {
                Text(phase.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.secondary)
                    .lineLimit(2)
                    .padding(.bottom, 10)
            }

            cardDivider

            // 上游
            upstreamSection(id)

            // 尚未安装且上游暂时不可用时给出一条提示，避免卡片看起来像坏了。
            if versions.isEmpty, installs.upstream[id]?.newerRelease == nil {
                cardDivider
                Text("尚未安装。检测到可用版本后可在此安装；也可以用 scripts/engines/build-\(id.rawValue)-pack.sh 在本机构建。")
                    .font(.system(size: 11))
                    .foregroundStyle(Native.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GlassSurface(radius: 18, tint: isActive ? Native.mint : .clear, elevated: false)
        }
    }

    /// Hairline separator between the card's 配置 / 上游 / 版本 sections.
    private var cardDivider: some View {
        Rectangle()
            .fill(Native.overlay(0.08))
            .frame(height: 1)
            .padding(.vertical, 12)
    }

    /// "What does GitHub have?" — status text on the left, and when a newer
    /// release exists the 安装 action on the right (which builds the pack here
    /// and installs it). The upstream check runs automatically when the settings
    /// page opens, so there is no manual re-check button.
    @ViewBuilder
    private func upstreamSection(_ id: EngineID) -> some View {
        let status = installs.upstream[id]
        // Busy covers both halves of a run: the source build and the pack
        // install that follows it.
        let busy = installs.building != nil || (installs.phases[id]?.isBusy ?? false)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Eyebrow(text: "上游版本 (GitHub)", color: Native.tertiary)
                if case .update(let installed, let release) = status {
                    Text(verbatim: "新版本 \(release.version)")
                        .font(Native.monoSmall)
                        .foregroundStyle(Native.cyan)
                    if release.isPrerelease {
                        Tag(text: "预发布", tone: .warning)
                    }
                    Text(verbatim: installed.map { "已装 \($0)" } ?? "尚未安装")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Native.tertiary)
                } else {
                    switch status {
                    case .current(let version):
                        Text(verbatim: "分支最新版 \(version)，本地已是最新。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Native.tertiary)
                    case .unavailable(let reason):
                        Text(reason)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Native.tertiary)
                            .lineLimit(1)
                    default:
                        EmptyView()
                    }
                }
                Spacer(minLength: 4)
                if case .update(_, let release) = status {
                    // The button itself carries the percent while a build or
                    // install is running; the ring on the card holds the detail.
                    Button(self.installButtonLabel(id, busy: busy)) {
                        installs.buildAndInstall(release, for: id)
                    }
                    .buttonStyle(ArcadePillStyle(tone: .accent, compact: true))
                    .disabled(busy)
                }
            }
        }
    }

    /// Percent-only label while this engine's run is active, plain 安装 otherwise.
    private func installButtonLabel(_ id: EngineID, busy: Bool) -> String {
        guard busy, let fraction = installs.progress[id] else { return "安装" }
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        return "\(percent)%"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "说明", color: Native.tertiary)
            Text("引擎随选择的模型自动切换，不需要手动指定；模型在各引擎自己的模型目录里管理，不在这里下载。")
                .font(.system(size: 11))
                .foregroundStyle(Native.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }
}

private extension EngineInstallPhase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// 安装已完成（成功落地的终态），此时不再在卡片上重复展示「已安装」文案。
    var isSettled: Bool {
        if case .installed = self { return true }
        return false
    }
}
