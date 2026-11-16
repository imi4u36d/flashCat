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
    @State private var gridColumns = 0

    private static let cardMinWidth: CGFloat = 400
    private static let cardSpacing: CGFloat = 14

    private var installedCount: Int {
        EngineCatalog.allIDs.filter { state.engineIsInstalled($0) }.count
    }

    private var runningCount: Int {
        state.isRunning ? 1 : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: DS.Layout.titlebarHeight)
                .padding(.leading, Console.topBarLeading(sidebarShown: state.showsSidebar))
                .padding(.trailing, Console.contentPadding)
                .padding(.top, Console.pageTopPadding)
                .padding(.bottom, 12)
                .background(WindowDragArea())

            ScrollView {
                DSAnimatedGrid(
                    columns: gridColumns,
                    minWidth: Self.cardMinWidth,
                    spacing: Self.cardSpacing
                ) {
                    ForEach(EngineCatalog.allIDs, id: \.self) { id in
                        engineCard(id)
                    }
                }
                .padding(.horizontal, Console.contentPadding)
            }
            .scrollIndicators(.never)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .dsTrackColumns($gridColumns, minWidth: Self.cardMinWidth, spacing: Self.cardSpacing)
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
            DSIconButton(systemName: "arrow.clockwise", help: "检查更新", style: .outlined) {
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

        // 极简引擎卡：仅保留图标、名称/版本、运行状态（运行中/更新/异常时显形）与右侧操作。
        return HStack(alignment: .center, spacing: 12) {
            EngineGlyph(id: id, color: accent, size: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(id.displayName)
                        .font(DS.Font.lg.weight(.semibold))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    if busy, installed {
                        updateChip(id: id, tint: accent)
                    } else {
                        statusChip(installed: installed, active: isActive, busy: busy)
                    }
                }

                if busy, !installed {
                    HStack(spacing: 6) {
                        ProgressRing(
                            fraction: installs.progress[id] ?? 0,
                            tint: accent, size: 14, lineWidth: 2)
                        Text(L10n.t(installs.progressStep[id] ?? phase.label))
                            .font(DS.Font.xs)
                            .foregroundStyle(DS.text2)
                            .lineLimit(1)
                    }
                } else if installed {
                    HStack(spacing: 5) {
                        if let version = versions.first {
                            Text(version)
                                .font(DS.Font.mono(11))
                                .foregroundStyle(DS.text3)
                                .lineLimit(1)
                        }
                        if !busy, let newer {
                            Text(L10n.format("可更新至 %@", newer.version))
                                .font(DS.Font.xs.weight(.medium))
                                .foregroundStyle(accent)
                                .lineLimit(1)
                                .help(L10n.format("更新到 %@", newer.version))
                        }
                    }
                } else {
                    Text(L10n.t("未安装"))
                        .font(DS.Font.xs)
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if installed {
                    DSIconButton(
                        systemName: "arrow.clockwise",
                        help: updateHelp(id),
                        size: 28,
                        style: .outlined,
                        tint: newer != nil ? accent : DS.text2
                    ) {
                        performUpdateAction(id)
                    }
                    .disabled(busy || checking.contains(id))

                    DSIconButton(
                        systemName: "slider.horizontal.3",
                        help: "配置",
                        size: 28,
                        style: .outlined
                    ) {
                        configuring = id
                    }
                    .disabled(versions.isEmpty)

                    DSIconButton(
                        systemName: "trash",
                        help: "删除",
                        size: 28,
                        style: .outlined
                    ) {
                        pendingRemoval = id
                    }
                    .disabled(busy || versions.isEmpty || (isActive && state.isRunning))

                    Group {
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
                    .padding(.leading, 4)
                } else if !busy {
                    Button {
                        install(id)
                    } label: {
                        Label("下载", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.ds(.primary, size: .small))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .dsSurface(
            radius: DS.Radius.lg,
            tint: isActive && state.isRunning ? accent.opacity(0.08) : nil,
            stroke: isActive ? accent.opacity(state.isRunning ? 0.42 : 0.24) : nil,
            hoverable: true,
            active: isActive
        )
    }

    @ViewBuilder
    private func statusChip(installed: Bool, active: Bool, busy: Bool) -> some View {
        if busy {
            StatusChip(text: "安装中", color: DS.warn, filled: true)
        } else if active, state.serverState == .ready {
            StatusChip(text: "运行中", color: DS.ok, filled: true)
        } else if active, state.serverState == .starting {
            StatusChip(text: "启动中", color: DS.warn, filled: true)
        } else if active, state.serverState == .stopping {
            StatusChip(text: "停止中", color: DS.warn, filled: true)
        } else if active, state.serverState == .failed {
            StatusChip(text: "异常", color: DS.warn, filled: true)
        }
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
