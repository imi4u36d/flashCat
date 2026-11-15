import SwiftUI
import AppKit
import FlashCatKit

/// 引擎页：顶部是运行时总览（当前引擎 + 安装/更新统计），
/// 下面是一张按行分隔的运行时清单；每个引擎一行，说明与版本落在同一行里。
struct EnginesPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var installs: EngineInstallCenter

    @State private var configuring: EngineID?
    @State private var pendingRemoval: EngineID?
    @State private var checking: Set<EngineID> = []

    private var installedCount: Int {
        EngineCatalog.allIDs.filter { state.engineIsInstalled($0) }.count
    }

    private var runningCount: Int {
        state.isRunning ? 1 : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Console.contentPadding)
                .padding(.top, Console.contentTopInset)
                .padding(.bottom, 22)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(EngineCatalog.allIDs, id: \.self) { id in
                        engineCard(id)
                    }
                }
                .padding(.horizontal, Console.contentPadding)
            }
            .scrollIndicators(.never)
        }
        // 和侧栏同一条下边界，滚动视口不会一直贴到窗口底沿。
        .padding(.bottom, Console.contentBottomInset)
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
                        state.toast(L10n.format("%@ 运行时已删除", id.displayName))
                    } else {
                        state.toast(L10n.format("%@ 没有可删除的运行时", id.displayName))
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

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("运行时")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Console.text)
            Circle()
                .fill(runningCount > 0 ? Console.ok : Console.tertiary)
                .frame(width: 6, height: 6)
            Text("\(runningCount) 运行中")
                .font(.system(size: 12))
                .foregroundStyle(Console.secondary)
            Rectangle().fill(Console.cardStroke).frame(width: 1, height: 14)
            Text("\(installedCount) / \(EngineCatalog.allIDs.count) 已安装")
                .font(.system(size: 12))
                .foregroundStyle(Console.secondary)
            Spacer(minLength: 0)
            IconAction(systemName: "arrow.clockwise", help: "检查更新") {
                Task { @MainActor in
                    installs.refreshInstalled()
                    await installs.loadIndexIfNeeded(force: true)
                    await installs.checkUpstream(force: true)
                }
            }
        }
    }

    // MARK: - Engine cards

    private func engineCard(_ id: EngineID) -> some View {
        let installed = state.engineIsInstalled(id)
        let isActive = state.activeEngine == id
        let versions = installs.installed[id] ?? []
        let phase = installs.phases[id] ?? .idle
        let busy = phase.isBusy || installs.building == id
        let accent = engineAccent(id)
        let newer = installs.upstream[id]?.newerRelease

        // 一行一个运行时：没有卡面，只有行底的发丝线。
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                EngineGlyph(id: id, color: accent, size: 32)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(id.displayName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Console.text)
                            .lineLimit(1)

                        if busy, installed {
                            updateChip(id: id, tint: accent)
                        } else {
                            statusChip(installed: installed, active: isActive, busy: busy)
                        }

                        Spacer(minLength: 12)

                        Text(versions.first ?? L10n.t("未安装"))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Console.tertiary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 7) {
                        ForEach(Array(id.descriptor.capabilities.prefix(5).enumerated()), id: \.offset) { index, capability in
                            Text(L10n.t(capability.displayName))
                            if index < min(5, id.descriptor.capabilities.count) - 1 {
                                Text("·").foregroundStyle(Console.quaternary)
                            }
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Console.secondary)
                    .lineLimit(1)
                }

                HStack(spacing: 2) {
                    if installed, !busy, let newer {
                        updateHint(newer)
                            .padding(.trailing, 2)
                    }
                    if installed {
                        EngineIconButton(systemImage: "arrow.clockwise",
                                         help: updateHelp(id),
                                         tint: newer != nil ? accent : Console.secondary) {
                            performUpdateAction(id)
                        }
                        .disabled(busy || checking.contains(id))
                    }
                    EngineIconButton(systemImage: "slider.horizontal.3", help: "配置") {
                        configuring = id
                    }
                    .disabled(versions.isEmpty)
                    EngineIconButton(systemImage: "trash", help: "删除") {
                        pendingRemoval = id
                    }
                    .disabled(busy || versions.isEmpty || (isActive && state.isRunning))
                }
            }

            if !installed {
                HStack(spacing: 10) {
                    if busy {
                        ProgressRing(fraction: installs.progress[id] ?? 0,
                                     tint: accent, size: 18, lineWidth: 2.5)
                        Text(L10n.t(installs.progressStep[id] ?? phase.label))
                            .font(.system(size: 11))
                            .foregroundStyle(Console.secondary)
                            .lineLimit(1)
                    } else {
                        Text(L10n.t("首次安装会从 GitHub 构建"))
                            .font(.system(size: 11))
                            .foregroundStyle(Console.tertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    if !busy {
                        Button {
                            install(id)
                        } label: {
                            Label("下载", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.consolePrimary)
                    }
                }
                .padding(.leading, 44)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Console.hairline).frame(height: 1)
        }
    }

    /// 新版本提示：紧贴在检查更新按钮左侧，刷新图标此时就是更新动作。
    /// 只留一行字——图标按钮已经是同色的强调动作，再加一枚箭头只会抢视线。
    private func updateHint(_ release: EngineUpstreamRelease) -> some View {
        Text(L10n.format("可更新至 %@", release.version))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Console.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            // 与 30pt 的图标按钮同高、对齐按钮中心，读起来像按钮的注解。
            .frame(height: 30)
            .help(L10n.format("更新到 %@", release.version))
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.t(label))
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Console.tertiary)
                .frame(width: 26, alignment: .leading)
            Text(L10n.t(value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Console.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func statusChip(installed: Bool, active: Bool, busy: Bool) -> some View {
        if busy {
            return StatusChip(text: "安装中", color: Console.warn, filled: true)
        }
        if !installed {
            return StatusChip(text: "未安装", color: Console.tertiary)
        }
        if active, state.serverState == .ready {
            return StatusChip(text: "运行中", color: Console.ok, filled: true)
        }
        if active, state.serverState == .starting {
            return StatusChip(text: "启动中", color: Console.warn, filled: true)
        }
        if active, state.serverState == .stopping {
            return StatusChip(text: "停止中", color: Console.warn, filled: true)
        }
        if active, state.serverState == .failed {
            return StatusChip(text: "异常", color: Console.warn, filled: true)
        }
        return StatusChip(text: "已停止", color: Console.tertiary)
    }

    /// 更新中的状态胶囊：进度环（百分比在环里）和当前步骤取代「安装中」，
    /// 卡片底部不再长出一行进度。步骤文案过长时截断，完整内容留给悬停提示。
    private func updateChip(id: EngineID, tint: Color) -> some View {
        let step = L10n.t(installs.progressStep[id] ?? "安装中")
        return HStack(spacing: 6) {
            ProgressRing(fraction: installs.progress[id] ?? 0,
                         tint: tint, size: 20, lineWidth: 3)
            Text(step)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Console.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Console.warn.opacity(0.10)))
        .help(step)
    }

    private func updateHelp(_ id: EngineID) -> String {
        if let release = installs.upstream[id]?.newerRelease {
            return L10n.format("更新到 %@", release.version)
        }
        return "检查更新"
    }

    private func performUpdateAction(_ id: EngineID) {
        if installs.upstream[id]?.newerRelease != nil {
            Task { @MainActor in
                _ = await installs.installFromUpstream(id)
            }
        } else {
            guard !checking.contains(id) else { return }
            checking.insert(id)
            Task { @MainActor in
                await installs.checkUpstream(for: id, force: true)
                checking.remove(id)
            }
        }
    }

    private func install(_ id: EngineID) {
        guard installs.building == nil else {
            state.toast(L10n.format("正在构建 %@，完成后再试", installs.building?.displayName ?? L10n.t("引擎")))
            return
        }
        // Build from the engine's newest GitHub release. The bundled pack index
        // cannot serve archives (flashCat does not redistribute engine binaries),
        // so downloading a pack would resolve to a missing local file.
        Task { @MainActor in
            _ = await installs.installFromUpstream(id)
        }
    }
}

/// 引擎官方图标：优先使用上游仓库的 app icon，找不到时回落到字母占位块。
private struct EngineGlyph: View {
    let id: EngineID
    var color: Color
    var size: CGFloat = 42

    var body: some View {
        Group {
            if let asset = engineArtwork(id), let image = BrandGlyph.artwork(named: asset) {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            } else {
                LetterTile(letter: String(id.displayName.prefix(1)).uppercased(),
                           color: color, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

func engineArtwork(_ id: EngineID) -> String? {
    switch id {
    case .splash: return "engine-splash"
    case .omlx: return "engine-omlx"
    case .mtplx: return "engine-mtplx"
    case .mlxServe: return "engine-mlxserve"
    case .strata: return "engine-strata"
    default: return nil
    }
}

/// 引擎卡上的圆形图标按钮：配置、删除、检查/安装更新都只用图标，
/// 不占按钮文字宽度。禁用时整体降透明度。
private struct EngineIconButton: View {
    let systemImage: String
    let help: String
    var tint: Color = Console.secondary
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Console.text : tint)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Console.rowHover : .clear)
                }
        }
        .buttonStyle(.plainHit)
        .onHover { hovering = $0 }
        .opacity(isEnabled ? 1 : 0.4)
        .help(help)
    }
}

// MARK: - Engine identity

/// 运行时统一用同一个橙色强调：引擎之间的差异靠名字和图标，不靠五种品牌色。
func engineAccent(_ id: EngineID) -> Color {
    Console.accent
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
