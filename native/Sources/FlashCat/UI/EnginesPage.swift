import SwiftUI
import AppKit
import FlashCatKit

/// 引擎页：顶部是运行时总览（当前引擎 + 安装/更新统计），
/// 下面用自适应网格排布引擎卡；卡片内部改成左右两栏，
/// 说明和能力标签在左、接口与版本在右，尽量把横向空间吃满。
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

    private var columns: [GridItem] {
        // 固定两列：引擎卡数量不多，两列比自适应更稳定。
        [GridItem(.flexible(), spacing: 16, alignment: .top),
         GridItem(.flexible(), spacing: 16, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Console.contentPadding)
                .padding(.top, 78)
                .padding(.bottom, 22)

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(EngineCatalog.allIDs, id: \.self) { id in
                        engineCard(id)
                    }
                }
                .padding(.horizontal, Console.contentPadding)
                .padding(.bottom, 26)
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
            Button {
                Task { @MainActor in
                    installs.refreshInstalled()
                    await installs.loadIndexIfNeeded(force: true)
                    await installs.checkUpstream(force: true)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Console.secondary)
                    .frame(width: 32, height: 32)
                    .background {
                        LiquidGlassSurface(shape: Circle(), interactive: true)
                    }
            }
            .buttonStyle(.plainHit)
            .help("检查更新")
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

        // 卡片保持无底色：引擎是否正在运行由状态胶囊表达，不再给整张卡染色。
        return GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    EngineGlyph(id: id, color: accent, size: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(id.displayName)
                                .font(.system(size: 16.5, weight: .semibold))
                                .foregroundStyle(Console.text)
                                .lineLimit(1)
                            statusChip(installed: installed, active: isActive, busy: busy)
                            Spacer(minLength: 0)
                        }
                    }

                    HStack(spacing: 6) {
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

                // 能力标签与版本读数分列左右，去掉重复的描述与接口信息。
                HStack(alignment: .top, spacing: 16) {
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(id.descriptor.capabilities.prefix(5), id: \.rawValue) { capability in
                            ConsoleTag(text: capability.displayName)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 7) {
                        metaRow("版本", versions.last ?? "未安装")
                    }
                    .frame(width: 148, alignment: .leading)
                    .padding(.vertical, 2)
                }

                // 页脚只在真有话说的时候出现：安装进度、可更新、还没装。
                // 「已安装」三个字已写在页头（5 / 5 已安装），再占一行只是空白。
                // 一行两张卡：页脚有内容的那张会长高，旁边那张底下就空出一个洞。
                // 所以页脚占位恒定，空闲时只是空白（不画分割线），高度对齐。
                Group {
                  if showsFooter(busy: busy, newer: newer, installed: installed) {
                    VStack(alignment: .leading, spacing: 10) {
                    Rectangle()
                        .fill(Console.insetStroke)
                        .frame(height: 1)

                    HStack(spacing: 10) {
                        if busy {
                        ProgressRing(fraction: installs.progress[id] ?? 0,
                                     tint: accent, size: 20, lineWidth: 3)
                        Text(L10n.t(installs.progressStep[id] ?? phase.label))
                            .font(.system(size: 11))
                            .foregroundStyle(Console.secondary)
                            .lineLimit(1)
                    } else if let newer {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accent)
                        Text(L10n.format("可更新至 %@", newer.version))
                            .font(.system(size: 11))
                            .foregroundStyle(Console.secondary)
                            .lineLimit(1)
                        } else if !installed {
                            Text(L10n.t("首次安装会从 GitHub 构建"))
                                .font(.system(size: 11))
                                .foregroundStyle(Console.tertiary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        if !busy && newer != nil {
                            Button("更新") { performUpdateAction(id) }
                                .buttonStyle(.consolePrimary)
                                .disabled(checking.contains(id))
                        }

                        if !busy && !installed {
                            Button {
                                install(id)
                            } label: {
                                Label("下载", systemImage: "arrow.down.circle.fill")
                            }
                            .buttonStyle(.consolePrimary)
                        }
                    }
                    }
                  }
                }
                .frame(height: 40, alignment: .bottom)
            }
        }
    }

    private func showsFooter(busy: Bool, newer: EngineUpstreamRelease?, installed: Bool) -> Bool {
        busy || newer != nil || !installed
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

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background {
                    LiquidGlassSurface(shape: Circle(), interactive: true)
                }
        }
        .buttonStyle(.plainHit)
        .opacity(isEnabled ? 1 : 0.4)
        .help(help)
    }
}

// MARK: - Engine identity

func engineAccent(_ id: EngineID) -> Color {
    switch id {
    case .splash: return Color(console: 0xE0893F)
    case .omlx: return Color(console: 0x2F8C99)
    case .mtplx: return Color(console: 0x5B57C9)
    case .mlxServe: return Color(console: 0x2F7CF6)
    case .strata: return Color(console: 0x3FAE7A)
    default: return Console.accent
    }
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
