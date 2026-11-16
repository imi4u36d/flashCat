// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatKit
import SwiftUI

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
        // 宽窗两列、窄窗自动折成单列，避免卡片被压扁。
        [GridItem(.adaptive(minimum: 400), spacing: 16, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Console.contentPadding)
                .padding(.top, Console.contentTopInset)
                .padding(.bottom, 22)

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(EngineCatalog.allIDs, id: \.self) { id in
                        engineCard(id)
                    }
                }
                .padding(.horizontal, Console.contentPadding)
            }
            .scrollIndicators(.never)
        }
        // 和侧栏玻璃同一条下边界，滚动视口不会一直贴到窗口底沿。
        .padding(.bottom, Console.contentBottomInset)
        .task {
            installs.refreshInstalled()
            await installs.loadIndexIfNeeded()
            await installs.checkUpstream(force: false)
        }
        .sheet(item: $configuring) { id in
            EngineConfigSheet(state: state, engine: id)
        }
        .alert(
            "删除 \(pendingRemoval?.displayName ?? "") 运行时？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } })
        ) {
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
                .font(DS.Font.title)
                .foregroundStyle(DS.text)
            DSStatusDot(color: runningCount > 0 ? DS.ok : DS.text4, live: runningCount > 0, size: 6)
            Text("\(runningCount) 运行中")
                .font(DS.Font.sm)
                .foregroundStyle(DS.text2)
                .monospacedDigit()
            DSDivider(vertical: true)
                .frame(height: 12)
            Text("\(installedCount) / \(EngineCatalog.allIDs.count) 已安装")
                .font(DS.Font.sm)
                .foregroundStyle(DS.text2)
                .monospacedDigit()
            Spacer(minLength: 0)
            DSIconButton(systemName: "arrow.clockwise", help: "检查更新") {
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
        let port = EngineStore.shared.configuration(for: id).port ?? id.defaultPort

        // 卡片保持无底色：引擎是否正在运行由状态胶囊表达，不再给整张卡染色。
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                EngineGlyph(id: id, color: accent, size: 36)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(id.displayName)
                            .font(DS.Font.lg.weight(.semibold))
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                        if busy, installed {
                            updateChip(id: id, tint: accent)
                        } else {
                            statusChip(installed: installed, active: isActive, busy: busy)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(id.descriptor.summary)
                        .font(DS.Font.xs)
                        .foregroundStyle(DS.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                HStack(spacing: 6) {
                    if installed, !busy, let newer {
                        updateHint(newer)
                            .padding(.trailing, 4)
                    }
                    if installed {
                        EngineIconButton(
                            systemImage: "arrow.clockwise",
                            help: updateHelp(id),
                            tint: newer != nil ? accent : DS.text2
                        ) {
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

            // 能力标签与版本读数分列左右，对齐视觉节奏。
            HStack(alignment: .center, spacing: 12) {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(id.descriptor.capabilities.prefix(5), id: \.rawValue) { capability in
                        ConsoleTag(text: capability.displayName)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                metaRow("版本", versions.first ?? "未安装")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DS.rect(DS.Radius.sm).fill(DS.bg))
                    .overlay(
                        DS.rect(DS.Radius.sm)
                            .strokeBorder(DS.line, lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 10) {
                DSDivider()

                if installed {
                    HStack(spacing: 10) {
                        HStack(spacing: 5) {
                            Image(systemName: "network")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DS.text3)
                            Text(verbatim: "127.0.0.1:\(port)")
                                .font(DS.Font.mono(11))
                                .foregroundStyle(DS.text2)
                        }
                        Spacer(minLength: 0)
                        if isActive {
                            Button {
                                state.toggleService()
                            } label: {
                                Label(
                                    L10n.t(state.isRunning ? "停止" : "启动"),
                                    systemImage: state.isRunning ? "stop.fill" : "play.fill")
                            }
                            .buttonStyle(.ds(state.isRunning ? .danger : .secondary, size: .small))
                            .disabled(state.isSwitchingModel || busy)
                        } else {
                            Button {
                                Task { @MainActor in
                                    _ = await state.switchEngine(id, start: true)
                                }
                            } label: {
                                Label("使用", systemImage: "play.fill")
                            }
                            .buttonStyle(.ds(.secondary, size: .small))
                            .disabled(state.isSwitchingModel || busy)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        if busy {
                            ProgressRing(
                                fraction: installs.progress[id] ?? 0,
                                tint: accent, size: 20, lineWidth: 3)
                            Text(L10n.t(installs.progressStep[id] ?? phase.label))
                                .font(DS.Font.xs)
                                .foregroundStyle(DS.text2)
                                .lineLimit(1)
                        } else {
                            Text(L10n.t("首次安装会从 GitHub 构建"))
                                .font(DS.Font.xs)
                                .foregroundStyle(DS.text3)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        if !busy {
                            Button {
                                install(id)
                            } label: {
                                Label("下载", systemImage: "arrow.down.circle.fill")
                            }
                            .buttonStyle(.ds(.primary, size: .small))
                        }
                    }
                }
            }
        }
        .padding(16)
        .dsSurface(
            radius: DS.Radius.lg,
            fill: DS.surface,
            stroke: isActive && state.isRunning ? DS.line2 : DS.line
        )
    }

    /// 新版本提示：紧贴在检查更新按钮左侧，刷新图标此时就是更新动作。
    /// 只留一行字——图标按钮已经是同色的强调动作，再加一枚箭头只会抢视线。
    private func updateHint(_ release: EngineUpstreamRelease) -> some View {
        Text(L10n.format("可更新至 %@", release.version))
            .font(DS.Font.xs.weight(.medium))
            .foregroundStyle(DS.text2)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            // 与 28pt 的图标按钮同高、对齐按钮中心，读起来像按钮的注解。
            .frame(height: 28)
            .help(L10n.format("更新到 %@", release.version))
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.t(label))
                .font(.system(size: 10, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(DS.text3)
                .fixedSize()
            Text(L10n.t(value))
                .font(DS.Font.mono(11))
                .foregroundStyle(DS.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func statusChip(installed: Bool, active: Bool, busy: Bool) -> some View {
        if busy {
            return StatusChip(text: "安装中", color: DS.warn, filled: true)
        }
        if !installed {
            return StatusChip(text: "未安装", color: DS.text3)
        }
        if active, state.serverState == .ready {
            return StatusChip(text: "运行中", color: DS.ok, filled: true)
        }
        if active, state.serverState == .starting {
            return StatusChip(text: "启动中", color: DS.warn, filled: true)
        }
        if active, state.serverState == .stopping {
            return StatusChip(text: "停止中", color: DS.warn, filled: true)
        }
        if active, state.serverState == .failed {
            return StatusChip(text: "异常", color: DS.warn, filled: true)
        }
        return StatusChip(text: "已停止", color: DS.text3)
    }

    /// 更新中的状态胶囊：进度环（百分比在环里）和当前步骤取代「安装中」，
    /// 卡片底部不再长出一行进度。步骤文案过长时截断，完整内容留给悬停提示。
    private func updateChip(id: EngineID, tint: Color) -> some View {
        let step = L10n.t(installs.progressStep[id] ?? "安装中")
        return HStack(spacing: 6) {
            ProgressRing(
                fraction: installs.progress[id] ?? 0,
                tint: tint, size: 20, lineWidth: 3)
            Text(step)
                .font(DS.Font.xs.weight(.medium))
                .foregroundStyle(DS.text2)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(DS.rect(DS.Radius.sm).fill(DS.warn.opacity(0.12)))
        .overlay(
            DS.rect(DS.Radius.sm)
                .strokeBorder(DS.warn.opacity(0.25), lineWidth: 1)
        )
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
                LetterTile(
                    letter: String(id.displayName.prefix(1)).uppercased(),
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
    var tint: Color = DS.text2
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(
                    DS.rect(DS.Radius.sm)
                        .fill(hovering && isEnabled ? DS.hover : DS.raised)
                )
                .overlay(
                    DS.rect(DS.Radius.sm)
                        .strokeBorder(DS.line, lineWidth: 1)
                )
        }
        .buttonStyle(DSPressStyle())
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { over in
            withAnimation(DS.Motion.snappy) { hovering = over }
        }
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
