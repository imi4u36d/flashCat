import SwiftUI
import AppKit
import FlashCatKit

/// 引擎页：五台平级引擎的安装、启停、切换、版本与配置入口。
///
/// 所有差异都来自 descriptor（名称、强调色、端口、切换方式、能力位），
/// 页面不按引擎 id 分支。
struct EnginesPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var installs: EngineInstallCenter

    @State private var configuring: EngineID?
    @State private var pendingRemoval: EngineID?

    private let columns = [GridItem(.adaptive(minimum: 340, maximum: 620), spacing: Native.gap)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "引擎",
                       subtitle: "五台引擎平级并存：装哪台、跑哪台、端口与调优都在这里",
                       eyebrow: "ENGINES") {
                Button {
                    state.showsLaunchPage = true
                } label: {
                    Label("启动页", systemImage: "rectangle.stack.badge.plus")
                }
                .buttonStyle(.arcadeGlass)

                Button {
                    Task { @MainActor in
                        installs.refreshInstalled()
                        await installs.loadIndexIfNeeded(force: true)
                        await installs.checkUpstream(force: true)
                    }
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.arcadePill)
            }
            .padding(.horizontal, Native.pagePadding)
            .padding(.top, 30)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: Native.gap) {
                    if let error = installs.indexError, !error.isEmpty {
                        Card("发布索引不可用",
                             subtitle: "暂时拿不到可安装版本，已安装的引擎不受影响",
                             tint: Native.orange) {
                            Text(error)
                                .font(Native.bodyFont)
                                .foregroundStyle(Native.orange)
                                .textSelection(.enabled)
                        }
                    }

                    LazyVGrid(columns: columns, alignment: .leading, spacing: Native.gap) {
                        ForEach(EngineCatalog.allIDs, id: \.self) { id in
                            EngineCard(state: state,
                                       installs: installs,
                                       id: id,
                                       configure: { configuring = id },
                                       remove: { pendingRemoval = id })
                        }
                    }

                    storageCard
                }
                .padding(.horizontal, Native.pagePadding)
                .padding(.bottom, 30)
                .pageColumn()
            }
            .scrollIndicators(.never)
        }
        .task {
            installs.refreshInstalled()
            await installs.loadIndexIfNeeded()
            await installs.checkUpstream(force: false)
        }
        .sheet(item: $configuring) { id in
            EngineConfigSheet(state: state, engine: id)
        }
        .alert("删除 \(pendingRemoval?.displayName ?? "") 运行时？",
               isPresented: Binding(get: { pendingRemoval != nil },
                                    set: { if !$0 { pendingRemoval = nil } })) {
            Button("删除", role: .destructive) {
                guard let id = pendingRemoval else { return }
                pendingRemoval = nil
                Task { @MainActor in
                    if await installs.removeRuntime(id) {
                        state.toast("\(id.displayName) 运行时已删除")
                    } else {
                        state.toast("\(id.displayName) 没有可删除的运行时")
                    }
                }
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("会删除 \(pendingRemoval.map(removableVersionsText) ?? "可删除的运行时")，模型与配置不受影响。")
        }
    }

    private func removableVersionsText(_ id: EngineID) -> String {
        let versions = EngineInstallations.removableVersions(id)
        guard !versions.isEmpty else { return "可删除的运行时" }
        return versions.sorted().joined(separator: "、")
    }

    private var storageCard: some View {
        Card("运行时与模型目录", subtitle: "pack 与权重都在用户目录里，删应用不会删模型") {
            VStack(spacing: 0) {
                pathRow("引擎运行时", EnginePaths.enginesDirectory) {
                    Paths.ensureDirectory(EnginePaths.enginesDirectory)
                    NSWorkspace.shared.open(URL(fileURLWithPath: EnginePaths.enginesDirectory))
                }
                Hairline()
                pathRow("模型总目录", EnginePaths.modelsRoot) {
                    Paths.ensureDirectory(EnginePaths.modelsRoot)
                    NSWorkspace.shared.open(URL(fileURLWithPath: EnginePaths.modelsRoot))
                }
                Hairline()
                pathRow("日志目录", EnginePaths.logsDirectory) {
                    Paths.ensureDirectory(EnginePaths.logsDirectory)
                    NSWorkspace.shared.open(URL(fileURLWithPath: EnginePaths.logsDirectory))
                }
            }
        }
    }

    private func pathRow(_ label: String, _ path: String, reveal: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Native.bodyFont)
                .foregroundStyle(Native.secondary)
            Spacer(minLength: 10)
            Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                .font(Native.monoFont)
                .foregroundStyle(Native.label)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button("打开", action: reveal)
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Card

private struct EngineCard: View {
    @ObservedObject var state: AppState
    @ObservedObject var installs: EngineInstallCenter
    let id: EngineID
    let configure: () -> Void
    let remove: () -> Void

    private var isActive: Bool { state.activeEngine == id }
    private var installed: Bool { state.engineIsInstalled(id) }
    private var versions: [String] { installs.installed[id] ?? [] }
    private var phase: EngineInstallPhase { installs.phases[id] ?? .idle }
    private var busy: Bool { phase.isBusy || installs.building == id }
    private var accent: Color { engineAccent(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            identityRow
            Text(id.descriptor.summary)
                .font(.system(size: 11.5))
                .foregroundStyle(Native.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            capabilityRow
            Hairline()
            runtimeRow
            upstreamRow
            if busy { progressRow }
            actionRow
        }
        .padding(Native.cardPadding)
        .background { GlassSurface(radius: Native.radiusPanel) }
        .overlay {
            RoundedRectangle(cornerRadius: Native.radiusPanel, style: .continuous)
                .strokeBorder(isActive ? accent.opacity(0.5) : .clear, lineWidth: 1)
        }
    }

    private var identityRow: some View {
        HStack(spacing: 10) {
            ArcadeIcon(symbol: engineSymbol(id),
                       colors: [accent, accent.opacity(0.62)],
                       size: 30,
                       glyphScale: 0.44,
                       glow: false)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(id.displayName)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Native.label)
                    if isActive {
                        Tag(text: state.isRunning ? "运行中" : "当前",
                            tone: state.isRunning ? .success : .neutral)
                    }
                }
                Text(versionText)
                    .font(Native.monoSmall)
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Toggle(isOn: Binding(
                get: { isActive && state.isRunning },
                set: { on in
                    if isActive {
                        on ? state.startService() : state.stopService()
                    } else if on {
                        Task { @MainActor in await state.switchEngine(id) }
                    }
                })) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(!installed || state.isSwitchingModel)
            .help(isActive ? (state.isRunning ? "停止引擎" : "启动引擎") : "切换到 \(id.displayName)")
        }
    }

    private var versionText: String {
        if busy { return installs.progressStep[id] ?? phase.label }
        if versions.isEmpty { return "未安装" }
        return versions.sorted().joined(separator: "、")
    }

    private var capabilityRow: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            Tag(text: "端口 \(portValue)", tone: .neutral, icon: "number")
            Tag(text: id.descriptor.switchMode == .hot ? "热切换" : "重启切换",
                tone: id.descriptor.switchMode == .hot ? .success : .neutral,
                icon: id.descriptor.switchMode == .hot ? "arrow.triangle.2.circlepath" : "power")
            ForEach(id.descriptor.capabilities.prefix(4), id: \.rawValue) { capability in
                Tag(text: capability.displayName, tone: .neutral)
            }
        }
    }

    private var portValue: Int {
        EngineStore.shared.configuration(for: id).port ?? id.defaultPort
    }

    private var runtimeRow: some View {
        HStack(spacing: 8) {
            StatusDot(color: isActive ? statusColor(state.serverState) : Native.gray,
                      diameter: 6,
                      pulsing: isActive && state.serverState == .starting)
            Text(isActive ? state.startupStage : (installed ? "待切换" : "未安装"))
                .font(.system(size: 11))
                .foregroundStyle(isActive ? Native.secondary : Native.tertiary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button("配置…", action: configure)
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                .disabled(versions.isEmpty)
        }
    }

    @ViewBuilder private var upstreamRow: some View {
        switch installs.upstream[id] {
        case .update(_, let release):
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Native.blue)
                Text("上游有新版本 \(release.version)")
                    .font(.system(size: 11))
                    .foregroundStyle(Native.secondary)
                Spacer(minLength: 4)
                Button("更新") { install(release.version) }
                    .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                    .disabled(busy)
            }
        case .current(let version):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Native.green)
                Text("已是最新 \(version)")
                    .font(.system(size: 11))
                    .foregroundStyle(Native.tertiary)
                Spacer(minLength: 0)
            }
        case .unavailable(let reason):
            Text(reason.isEmpty ? "未检查上游版本" : reason)
                .font(.system(size: 11))
                .foregroundStyle(Native.tertiary)
                .lineLimit(1)
        case .none:
            Text("未检查上游版本")
                .font(.system(size: 11))
                .foregroundStyle(Native.tertiary)
        }
    }

    private var progressRow: some View {
        HStack(spacing: 9) {
            ProgressRing(fraction: installs.progress[id] ?? 0, tint: accent, size: 26, lineWidth: 3)
            Text(installs.progressStep[id] ?? phase.label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Native.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            primaryButton
            Spacer(minLength: 4)
            Menu {
                Button("启用 / 切换到此引擎") {
                    Task { @MainActor in await state.switchEngine(id) }
                }
                .disabled(isActive)
                Button("打开模型目录") {
                    let directory = EnginePaths.modelsDirectory(id)
                    Paths.ensureDirectory(directory)
                    NSWorkspace.shared.open(URL(fileURLWithPath: directory))
                }
                Button("显示日志文件") {
                    let path = EnginePaths.logFile(id)
                    guard Paths.fileExists(path) else {
                        state.toast("该引擎还没有日志文件")
                        return
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Divider()
                Button("删除运行时…", role: .destructive, action: remove)
                    .disabled(busy || versions.isEmpty)
            } label: {
                IconMenuLabel(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @ViewBuilder private var primaryButton: some View {
        if !installed {
            Button {
                install(nil)
            } label: {
                Text(busy ? (installs.progressStep[id] ?? "安装中…") : "安装")
            }
            .buttonStyle(.arcadePill)
            .disabled(busy || installs.building != nil)
        } else if isActive {
            Button {
                state.toggleService()
            } label: {
                Text(state.isRunning ? "停止引擎" : "启动引擎")
            }
            .buttonStyle(state.isRunning ? ArcadePillStyle(tone: .quietDanger) : .arcadePill)
            .disabled(state.isSwitchingModel)
        } else {
            Button {
                Task { @MainActor in await state.switchEngine(id) }
            } label: {
                Text("切换到此引擎")
            }
            .buttonStyle(.arcadePill)
            .disabled(state.isSwitchingModel || busy)
        }
    }

    /// 发布索引里优先；没有归档时退回上游构建。
    private func install(_ version: String?) {
        if let release = installs.releases[id]?.first(where: { $0.version == version }) {
            installs.install(release, for: id)
            return
        }
        if version == nil,
           let latest = installs.releases[id]?.max(by: { EngineVersionOrder.isNewer($1.version, than: $0.version) }) {
            installs.install(latest, for: id)
            return
        }
        if case .update(_, let release) = installs.upstream[id] {
            guard installs.building == nil else {
                state.toast("正在构建 \(installs.building?.displayName ?? "引擎")，完成后再试")
                return
            }
            _ = installs.buildAndInstall(release, for: id)
            return
        }
        state.toast("暂时没有 \(id.displayName) 的可用安装版本")
    }
}

// MARK: - Engine helpers

func engineAccent(_ id: EngineID) -> Color {
    let hex = id.descriptor.accentColor.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return Native.accent }
    return Color(hex: value)
}

func engineSymbol(_ id: EngineID) -> String {
    switch id {
    case .splash: return "bolt.fill"
    case .omlx: return "cpu"
    case .mtplx: return "square.stack.3d.up.fill"
    case .mlxServe: return "shippingbox.fill"
    case .strata: return "externaldrive.fill"
    default: return "cpu"
    }
}
