import SwiftUI
import AppKit
import FlashCatKit

/// Drives pack installs for the engine page: loads the release index once, then
/// runs one install at a time (they write into the same folder tree).
@MainActor
final class EngineInstallCenter: ObservableObject {
    @Published private(set) var releases: [EngineID: [EnginePackRelease]] = [:]
    @Published private(set) var phases: [EngineID: EngineInstallPhase] = [:]
    @Published private(set) var installed: [EngineID: [String]] = [:]
    /// Versions that live under flashCat's own installs directory, i.e. the ones
    /// with a delete button. Bundled / checked-out packs are listed separately.
    @Published private(set) var removable: [EngineID: Set<String>] = [:]
    @Published private(set) var indexError: String?
    @Published private(set) var indexLoaded = false
    /// One GitHub probe per engine, so a card can say "newer than what you have".
    @Published private(set) var upstream: [EngineID: EngineUpstreamStatus] = [:]
    @Published private(set) var upstreamCheckedAt: Date?
    /// The engine whose pack is being built right now (builds run one at a time).
    @Published private(set) var building: EngineID?
    @Published private(set) var buildStep: [EngineID: String] = [:]
    @Published private(set) var buildTail: [EngineID: [String]] = [:]

    private let checker = EngineUpstreamChecker()
    /// Last GitHub answer per engine, kept so a finished install can be compared
    /// again without spending another API call.
    private var upstreamReleases: [EngineID: EngineUpstreamRelease] = [:]
    private var installer: EngineInstaller?
    private var onChange: (() -> Void)?
    /// Called after a pack finished installing; the launch page uses it to make
    /// the freshly installed engine the active one.
    var onInstalled: ((EngineID) -> Void)?

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
        var deletable: [EngineID: Set<String>] = [:]
        for id in EngineID.allCases {
            result[id] = EngineInstallations.installed(id).map(\.version)
            deletable[id] = EngineInstallations.removableVersions(id)
        }
        installed = result
        removable = deletable
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

    func install(_ release: EnginePackRelease, for id: EngineID) {
        guard phases[id]?.isBusy != true, let installer else { return }
        let isFirstInstall = (installed[id] ?? []).isEmpty
        phases[id] = .resolving
        Task { [weak self] in
            do {
                _ = try await installer.install(release, for: id) { phase in
                    Task { @MainActor in self?.phases[id] = phase }
                }
                await MainActor.run {
                    self?.phases[id] = .installed(version: release.version)
                    self?.refreshInstalled()
                    self?.onChange?()
                    // Only a first install makes the engine the active one; an
                    // update must leave whatever the user was running alone.
                    if isFirstInstall { self?.onInstalled?(id) }
                }
            } catch {
                await MainActor.run {
                    self?.phases[id] = .failed(message: error.localizedDescription)
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
    /// (see `EnginePackBuildPlanner`); every output line is surfaced so a slow
    /// `uv pip install` or `brew upgrade` is not a silent hang.
    func buildAndInstall(_ release: EngineUpstreamRelease, for id: EngineID) {
        guard building == nil, installer != nil else { return }
        guard let repository = EnginePackBuildRunner.locateRepository() else {
            phases[id] = .failed(message: EnginePackBuildError.repositoryNotFound.localizedDescription)
            return
        }
        building = id
        buildTail[id] = []
        buildStep[id] = "准备"
        phases[id] = .idle

        Task { [weak self] in
            guard let self else { return }
            do {
                let steps = EnginePackBuildPlanner.steps(for: id, version: release.version, release: release)
                try await EnginePackBuildRunner.run(steps: steps, in: repository) { step in
                    Task { @MainActor in self.buildStep[id] = step.title }
                } onLine: { line in
                    Task { @MainActor in
                        var tail = self.buildTail[id] ?? []
                        tail.append(line)
                        if tail.count > 8 { tail.removeFirst(tail.count - 8) }
                        self.buildTail[id] = tail
                    }
                }
                let path = repository + "/" + EnginePackBuildPlanner.releaseFile(for: id, version: release.version)
                let pack = try EnginePackBuildRunner.loadRelease(at: path)
                await self.loadIndexIfNeeded(force: true)
                await MainActor.run {
                    self.building = nil
                    self.buildStep[id] = nil
                    self.buildTail[id] = []
                    self.install(pack, for: id)
                }
            } catch {
                await MainActor.run {
                    self.building = nil
                    self.buildStep[id] = nil
                    self.phases[id] = .failed(message: error.localizedDescription)
                }
            }
        }
    }

    func uninstall(_ id: EngineID, version: String) {
        guard let installer else { return }
        Task {
            do {
                let removed = try await installer.uninstall(id, version: version)
                await MainActor.run {
                    // Only the installs directory belongs to us; a pack that ships
                    // inside the app (or a checkout) cannot be removed and used to
                    // fail without saying so.
                    self.phases[id] = removed ? .idle : .failed(message: "\(version) 随应用内置，删不掉")
                    self.refreshInstalled()
                    self.onChange?()
                }
            } catch {
                await MainActor.run {
                    self.phases[id] = .failed(message: error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Page

struct EnginesView: View {
    @ObservedObject var state: AppState
    @ObservedObject var installs: EngineInstallCenter
    @State private var configuring: EngineID?

    var body: some View {
        GeometryReader { proxy in
            let usable = max(320, proxy.size.width - Native.pagePadding * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(title: "引擎",
                               subtitle: "同一时刻只运行一个推理引擎；每个引擎有自己的端口、模型目录与参数。",
                               eyebrow: "RUNTIME PACKS") {
                        Button("启动页…") { state.showsLaunchPage = true }
                    }
                    .padding(.bottom, 4)

                    ForEach(EngineID.allCases, id: \.self) { id in
                        card(id, width: usable)
                    }

                    footer
                }
                .padding(.horizontal, Native.pagePadding)
                .padding(.top, 30)
                .padding(.bottom, Native.pagePadding)
                .pageColumn()
            }
            .scrollIndicators(.never)
        }
        .task {
            installs.refreshInstalled()
            await installs.loadIndexIfNeeded()
            await installs.checkUpstream()
        }
        .sheet(item: $configuring) { id in
            EngineConfigView(state: state, engine: id)
        }
    }

    private func card(_ id: EngineID, width: CGFloat) -> some View {
        let isActive = state.activeEngine == id
        let versions = installs.installed[id] ?? []
        let phase = installs.phases[id] ?? .idle
        let offers = EnginePackOffers.offers(installed: versions, releases: installs.releases[id] ?? [])

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isActive ? statusColor(state.serverState) : Native.overlay(0.18))
                    .frame(width: 7, height: 7)
                Text(id.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Native.label)
                if isActive {
                    Tag(text: "当前引擎", tone: .success)
                }
                Text(verbatim: "端口 \(String(enginePort(id)))")
                    .font(Native.monoSmall)
                    .foregroundStyle(Native.tertiary)
                Spacer(minLength: 6)
                if versions.isEmpty {
                    Tag(text: "未安装", tone: .neutral)
                } else {
                    Text(verbatim: "已装 \(versions.joined(separator: ", "))")
                        .font(Native.monoSmall)
                        .foregroundStyle(Native.tertiary)
                        .lineLimit(1)
                }
                if !isActive {
                    Button("设为当前") { state.switchEngine(id) }
                        .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                        .disabled(versions.isEmpty)
                }
                Button("配置…") { configuring = id }
                    .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                    .disabled(versions.isEmpty)
            }

            portField(id)

            if let controller = state.engines?.controller(id), !versions.isEmpty {
                engineSummary(controller)
            }

            upstreamSection(id)

            if phase.isBusy {
                Meter(fraction: phase.fraction ?? 0, tint: Native.cyan)
            }
            if phase != .idle {
                Text(phase.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(phase.isFailure ? Native.red.opacity(0.9) : Native.secondary)
                    .lineLimit(2)
            }

            if versions.contains(where: { $0 != version(id) }) {
                let deletable = installs.removable[id] ?? []
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "已安装版本", color: Native.tertiary)
                    ForEach(versions, id: \.self) { installedVersion in
                        HStack(spacing: 8) {
                            Text(installedVersion)
                                .font(Native.monoSmall)
                                .foregroundStyle(Native.secondary)
                            if installedVersion == version(id) {
                                Tag(text: "使用中", tone: .success)
                            }
                            if !deletable.contains(installedVersion) {
                                // Shipped in the app bundle / checkout: usable, not ours.
                                Tag(text: "内置", tone: .neutral)
                            }
                            Spacer(minLength: 4)
                            if deletable.contains(installedVersion) {
                                Button("删除") {
                                    installs.uninstall(id, version: installedVersion)
                                }
                                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                                .disabled(isActive && state.isRunning)
                                .help(isActive && state.isRunning
                                      ? "正在运行的引擎不能删除，先停止"
                                      : "删除 \(installedVersion)")
                            }
                        }
                    }
                }
            }

            if !offers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "运行时包", color: Native.tertiary)
                    ForEach(offers, id: \.release.version) { offer in
                        let release = offer.release
                        HStack(spacing: 8) {
                            Text(release.version)
                                .font(Native.monoSmall)
                                .foregroundStyle(Native.secondary)
                            if offer.action == .reinstall {
                                Tag(text: "已装此版本", tone: .neutral)
                            }
                            if let bytes = release.bytes {
                                Text(verbatim: Format.bytes(bytes))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Native.tertiary)
                            }
                            if let notes = release.notes, !notes.isEmpty {
                                Text(notes)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Native.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Button(offer.action.label) { installs.install(release, for: id) }
                                .buttonStyle(ArcadePillStyle(tone: offer.action == .reinstall ? .glass : .accent,
                                                             compact: true))
                                .disabled(phase.isBusy)
                        }
                    }
                }
            } else if versions.isEmpty {
                Text(installs.indexError.map { "没有可安装的版本：\($0)" }
                     ?? "没有可安装的版本。用 scripts/engines/build-\(id.rawValue)-pack.sh 在本机构建，或配置 FLASHCAT_PACK_INDEX_URL。")
                    .font(.system(size: 11))
                    .foregroundStyle(Native.tertiary)
            }

            HStack(spacing: 8) {
                Button("打开目录") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: EnginePaths.enginesDirectory))
                }
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                Button("查看日志") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: EnginePaths.logFile(id)))
                }
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: width, alignment: .leading)
        .background {
            GlassSurface(radius: 18, tint: isActive ? Native.mint : .clear, elevated: false)
        }
    }

    /// "What does GitHub have?" — the newest release, whether it is newer than
    /// anything installed, and the two actions that follow from that: open the
    /// release page, or build the pack here and install it.
    @ViewBuilder
    private func upstreamSection(_ id: EngineID) -> some View {
        let status = installs.upstream[id]
        let busy = installs.building != nil
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Eyebrow(text: "上游版本 (GitHub)", color: Native.tertiary)
                Spacer(minLength: 4)
                if let checkedAt = installs.upstreamCheckedAt {
                    Text(verbatim: "检查于 \(Self.clock.string(from: checkedAt))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Native.tertiary.opacity(0.8))
                }
                Button(status == nil ? "检查更新" : "重新检查") {
                    Task { await installs.checkUpstream(force: true) }
                }
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            }

            switch status {
            case .current(let version):
                Text(verbatim: "分支最新版 \(version)，本地已是最新。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
            case .update(let installed, let release):
                HStack(spacing: 8) {
                    Text(verbatim: "新版本 \(release.version)")
                        .font(Native.monoSmall)
                        .foregroundStyle(Native.cyan)
                    if release.isPrerelease {
                        Tag(text: "预发布", tone: .warning)
                    }
                    Text(verbatim: installed.map { "已装 \($0)" } ?? "尚未安装")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Native.tertiary)
                    Spacer(minLength: 4)
                    Button("发布说明") { NSWorkspace.shared.open(release.pageURL) }
                        .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                    Button(installs.building == id ? "构建中…" : "构建并安装") {
                        installs.buildAndInstall(release, for: id)
                    }
                    .buttonStyle(ArcadePillStyle(tone: .accent, compact: true))
                    .disabled(busy)
                }
            case .unavailable(let reason):
                Text(verbatim: "无法检查上游：\(reason)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.red.opacity(0.8))
            case nil:
                Text("尚未检查上游版本。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary.opacity(0.9))
            }

            if installs.building == id, let step = installs.buildStep[id] {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: "\(step)…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Native.secondary)
                }
            }
            if let tail = installs.buildTail[id], !tail.isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(tail.enumerated()), id: \.offset) { entry in
                            Text(verbatim: entry.element)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Native.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 62)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Native.recess)
                }
            }
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Editable port. Kept as a text field so the reader can type any free port;
    /// the value only lands in the store when it parses.
    private func portField(_ id: EngineID) -> some View {
        HStack(spacing: 8) {
            Text("端口")
                .font(.system(size: 10.5))
                .foregroundStyle(Native.tertiary)
            TextField("", text: portBinding(id))
                .textFieldStyle(.plain)
                .font(Native.monoSmall)
                .foregroundStyle(Native.label.opacity(0.9))
                .frame(width: 70)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Native.overlay(0.06))
                }
                .disabled(state.activeEngine == id && state.isRunning)
            Text(verbatim: state.activeEngine == id && state.isRunning
                 ? "运行中不能改端口"
                 : "默认 \(id.defaultPort)，可顺延 \(id.portRange.count) 个")
                .font(.system(size: 9.5))
                .foregroundStyle(Native.tertiary.opacity(0.85))
            Spacer(minLength: 0)
        }
    }

    private func portBinding(_ id: EngineID) -> Binding<String> {
        Binding(
            get: { String(enginePort(id)) },
            set: { text in
                guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(value) else {
                    return
                }
                EngineStore.shared.update(id) { $0.port = value }
                state.switchEnginePort(id, port: value)
            }
        )
    }

    private func enginePort(_ id: EngineID) -> Int {
        EngineStore.shared.configuration(for: id).port ?? id.defaultPort
    }

    private func version(_ id: EngineID) -> String? {
        state.engines?.controller(id)?.installation.version
    }

    /// One line of what the engine is configured to do, so the page says more
    /// than "installed".
    private func engineSummary(_ controller: EngineController) -> some View {
        let tuning = EngineStore.shared.tuning(for: controller.id).sanitized()
        var parts: [String] = []
        switch controller.id {
        case .omlx:
            if tuning.dflash == true { parts.append("DFlash2") }
            if tuning.mtp == true { parts.append(tuning.mtpDepth.map { "MTP 深度 \($0)" } ?? "MTP 自适应") }
        case .mtplx:
            if tuning.mtp != false { parts.append("MTP") }
            if let bits = tuning.mtpQuantBits { parts.append("MTP \(bits)-bit") }
        case .splash:
            if tuning.dflash != false { parts.append(tuning.draftModel == nil ? "DFlash2 自动" : "DFlash2 指定") }
            if tuning.languageOnly == true { parts.append("仅语言") }
        }
        if let memory = tuning.maxMemory, !memory.isEmpty { parts.append("内存 \(memory)") }
        if let context = tuning.maxContext, !context.isEmpty { parts.append("上下文 \(context)") }
        return VStack(alignment: .leading, spacing: 3) {
            Eyebrow(text: "当前配置", color: Native.tertiary)
            Text(parts.isEmpty ? "使用引擎默认值" : parts.joined(separator: " · "))
                .font(.system(size: 10.5))
                .foregroundStyle(Native.tertiary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "说明", color: Native.tertiary)
            Text("三个引擎地位相同，都从运行时包安装、都不随应用打包：splash 也只是其中一个引擎，不再内置。首次启动时启动页会让你选一个下载。运行时包是自管的 Python + 引擎依赖，和 Homebrew / 系统里已装的应用互不影响。安装走 SHA256 校验、解包到 .staging、验证 manifest 后才激活。模型在各引擎自己的模型目录里，不在这里下载。")
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
}
