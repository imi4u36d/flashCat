// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 引擎页：macOS Liquid Glass 的运行时控制台。
///
/// 版式按高保真稿重排：页头是引擎总数 / 运行中 + 格式筛选；下面依次是
/// 活跃运行时主卡（监听端点、加载模型、统一内存、投机解码四格读数）、
/// 双列引擎目录，以及底部的能力对比矩阵。皮肤由设置页决定，这里只读 `DS`
/// 令牌，不提供第二套换肤入口。
struct EnginesPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var installs: EngineInstallCenter

    private enum Filter: String, CaseIterable, Identifiable {
        case all
        case installed
        case mlx
        case gguf

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "全部"
            case .installed: return "已安装"
            case .mlx: return "支持 MLX"
            case .gguf: return "支持 GGUF"
            }
        }
    }

    @State private var configuring: EngineID?
    @State private var pendingRemoval: EngineID?
    @State private var gridColumns = 0
    @State private var refreshing = false
    @State private var hoveringEngine: EngineID?
    @State private var filter: Filter = .all

    private static let cardMinWidth: CGFloat = 400
    private static let cardSpacing: CGFloat = 14

    private var installedCount: Int {
        EngineCatalog.allIDs.filter { state.engineIsInstalled($0) }.count
    }

    private var runningCount: Int {
        state.isRunning ? 1 : 0
    }

    private var filteredEngines: [EngineID] {
        EngineCatalog.allIDs.filter { id in
            switch filter {
            case .all: return true
            case .installed: return state.engineIsInstalled(id)
            case .mlx: return id.modelFormats.contains(.mlx)
            case .gguf: return id.modelFormats.contains(.gguf)
            }
        }
    }

    private var installedEngines: [EngineID] {
        EngineCatalog.allIDs.filter { state.engineIsInstalled($0) }
    }

    private var activeBusy: Bool {
        let phase = installs.phases[state.activeEngine] ?? .idle
        return phase.isBusy || installs.building == state.activeEngine
    }

    /// 引擎实际加载的模型。优先用应用选中的模型；用户绕过界面、由网关
    /// 直接热加载时，退回引擎上报的 model，避免主卡显示「未选择模型」。
    private var loadedModelID: String {
        if !state.selectedModel.isEmpty { return state.selectedModel }
        return state.stats?.model ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    runtimeSection
                    catalogSection
                    EngineMatrixCard(
                        installed: Set(installedEngines),
                        active: state.engineIsInstalled(state.activeEngine)
                            ? state.activeEngine : nil,
                        running: state.isRunning)
                }
                .padding(.horizontal, Console.contentPadding)
                .padding(.top, 12)
                .padding(.bottom, Console.contentBottomInset)
                .dsPageColumn()
            }
            .scrollIndicators(.never)
            .dsTrackColumns(
                $gridColumns,
                minWidth: Self.cardMinWidth,
                spacing: Self.cardSpacing,
                maxColumns: 2)
        }
        .dsPageColumn()
        .task {
            installs.refreshInstalled()
            await installs.loadIndexIfNeeded()
            await installs.checkUpstream(force: false)
        }
        .sheet(item: $configuring) { id in
            EngineConfigSheet(state: state, engine: id)
        }
        .alert(
            L10n.format("删除 %@ 运行时？", pendingRemoval?.displayName ?? ""),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } })
        ) {
            Button(L10n.t("删除"), role: .destructive) {
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
            Button(L10n.t("取消"), role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(
                L10n.format(
                    "会删除 %@，模型与配置不受影响。",
                    pendingRemoval.map(removableVersionsText) ?? L10n.t("可删除的运行时")
                )
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    headerIdentity
                    Spacer(minLength: 10)
                    headerControls
                }
                VStack(alignment: .leading, spacing: 9) {
                    headerIdentity
                    headerControls
                }
            }
        }
        .padding(.leading, Console.topBarLeading(sidebarShown: state.showsSidebar))
        .padding(.trailing, Console.contentPadding)
        .padding(.top, Console.pageTopPadding)
        .padding(.bottom, 10)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DS.line)
                .frame(height: 1)
        }
    }

    private var headerIdentity: some View {
        HStack(spacing: 9) {
            Text(L10n.t("引擎"))
                .font(DS.Font.prose(20, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(DS.text)
                .fixedSize()

            summaryPill
        }
        .fixedSize()
    }

    private var summaryPill: some View {
        let live = runningCount > 0
        return HStack(spacing: 7) {
            DSStatusDot(color: live ? DS.ok : DS.text4, live: live, size: 6)
            Text(
                L10n.format(
                    "%lld / %lld 已安装",
                    Int64(installedCount), Int64(EngineCatalog.allIDs.count))
            )
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(DS.text2)
            .monospacedDigit()

            Text(verbatim: "·")
                .font(DS.Font.prose(11))
                .foregroundStyle(DS.text4)

            Text(L10n.format("%lld 运行中", Int64(runningCount)))
                .font(.system(size: 11.5, weight: live ? .semibold : .medium))
                .foregroundStyle(live ? DS.ok : DS.text3)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .dsGlassPill()
        .fixedSize()
    }

    private var headerControls: some View {
        HStack(spacing: 8) {
            filterBar
            refreshButton
        }
        .fixedSize()
    }

    private var filterBar: some View {
        HStack(spacing: 2) {
            ForEach(Filter.allCases) { item in
                EngineFilterButton(
                    title: item.label,
                    selected: filter == item
                ) {
                    guard filter != item else { return }
                    withAnimation(DS.Motion.smooth) {
                        filter = item
                    }
                }
            }
        }
        .padding(2)
        .background(Capsule().fill(DS.pillFill))
        .overlay(Capsule().strokeBorder(DS.pillBorder, lineWidth: 1))
    }

    private var refreshButton: some View {
        Button(action: refreshEngines) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(refreshing ? DS.accent : DS.text2)
                .rotationEffect(.degrees(refreshing ? 360 : 0))
                .animation(
                    refreshing
                        ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                        : .easeOut(duration: 0.2),
                    value: refreshing
                )
                .frame(width: 28, height: 28)
                .background(DS.rect(DS.Radius.md).fill(DS.surface))
                .overlay(
                    DS.rect(DS.Radius.md)
                        .strokeBorder(refreshing ? DS.accent.opacity(0.4) : DS.line2, lineWidth: 1))
                .contentShape(DS.rect(DS.Radius.md))
        }
        .buttonStyle(DSPressStyle())
        .disabled(refreshing)
        .help(L10n.t(refreshing ? "正在检查更新…" : "刷新并检查引擎更新"))
        .accessibilityLabel(L10n.t("刷新并检查引擎更新"))
    }

    // MARK: - Runtime hero

    @ViewBuilder
    private var runtimeSection: some View {
        if state.isRunning {
            EngineRuntimeCard(
                engine: state.activeEngine,
                version: installedVersion(state.activeEngine).map(versionText),
                status: state.serverState,
                port: state.port,
                modelName: loadedModelID.isEmpty
                    ? "" : state.shortModelName(loadedModelID),
                modelID: loadedModelID,
                stats: state.stats,
                decodeRate: state.averageDecodeReading.value ?? 0,
                busy: activeBusy,
                actions: EngineRuntimeCard.Actions(
                    configure: { configuring = state.activeEngine },
                    logs: { state.section = .logs },
                    restart: { state.restartService() },
                    stop: { state.toggleService() },
                    copyEndpoint: {
                        state.copy(
                            "127.0.0.1:\(state.port)",
                            label: L10n.format("%@ 监听端点已复制", state.activeEngine.displayName))
                    }
                )
            )
        } else {
            EngineIdleRuntimeCard(
                installed: installedEngines,
                active: state.activeEngine,
                hasSelection: !state.selectedModel.isEmpty,
                switching: state.isSwitchingModel,
                failureMessage: state.failureMessage,
                start: startEngine
            )
        }
    }

    // MARK: - Catalog

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L10n.t("可用推理引擎"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.text2)
                Text(L10n.format("%lld 项", Int64(filteredEngines.count)))
                    .font(DS.Font.mono(10.5))
                    .foregroundStyle(DS.text4)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(L10n.t("支持原生 Apple Silicon Metal 加速 · 单引擎独占显存调度"))
                    .font(.system(size: 11))
                    .foregroundStyle(DS.text4)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if filteredEngines.isEmpty {
                emptyCatalog
            } else {
                DSAnimatedGrid(
                    columns: gridColumns,
                    minWidth: Self.cardMinWidth,
                    spacing: Self.cardSpacing,
                    maxColumns: 2
                ) {
                    ForEach(filteredEngines, id: \.self) { id in
                        engineCard(id)
                            .transition(.dsRowInsert)
                    }
                }
                .animation(DS.Motion.smooth, value: filteredEngines)
            }
        }
    }

    private var emptyCatalog: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(DS.text4)
            Text(L10n.t("当前筛选条件下暂无匹配的引擎。"))
                .font(DS.Font.prose(12.5))
                .foregroundStyle(DS.text3)
            Button(L10n.t("显示全部")) {
                withAnimation(DS.Motion.smooth) { filter = .all }
            }
            .buttonStyle(.ds(.secondary, size: .small))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .dsSurface(radius: DS.Radius.card)
    }

    // MARK: - Engine card

    private func engineCard(_ id: EngineID) -> some View {
        let installed = state.engineIsInstalled(id)
        let isActive = state.activeEngine == id && installed
        let versions = installs.installed[id] ?? []
        let phase = installs.phases[id] ?? .idle
        let busy = phase.isBusy || installs.building == id
        let failureMessage: String? = {
            if case .failed(let message) = phase { return message }
            return nil
        }()
        let accent = engineAccent(id)
        let newer = installs.upstream[id]?.newerRelease

        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                EngineGlyph(id: id, color: accent, size: 44)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(id.displayName)
                            .font(DS.Font.prose(14.5, weight: .bold))
                            .foregroundStyle(DS.text)
                            .lineLimit(1)

                        cardStatusChip(
                            installed: installed,
                            active: isActive,
                            busy: busy,
                            failed: failureMessage != nil,
                            accent: accent)
                    }

                    HStack(spacing: 6) {
                        Text(
                            metaText(
                                id: id,
                                installed: installed,
                                versions: versions)
                        )
                        .font(DS.Font.mono(10.5))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)

                        if installed, !busy, let newer {
                            Button {
                                updateEngine(id)
                            } label: {
                                Text(L10n.format("更新至 %@", versionText(newer.version)))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(accent)
                                    .lineLimit(1)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(L10n.format("更新到 %@", versionText(newer.version)))
                        } else if !busy, newer == nil, let error = installs.upstreamErrors[id] {
                            HStack(spacing: 3) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 8.5))
                                Text(L10n.t("检查失败"))
                                    .font(DS.Font.xs)
                            }
                            .foregroundStyle(DS.warn)
                            .lineLimit(1)
                            .help(error)
                        }
                    }
                }

                Spacer(minLength: 8)

                cardActions(
                    id: id,
                    installed: installed,
                    active: isActive,
                    busy: busy,
                    versions: versions,
                    accent: accent)
            }

            Text(L10n.t(id.descriptor.summary))
                .font(DS.Font.prose(12.5))
                .foregroundStyle(DS.text2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(L10n.t(id.descriptor.summary))

            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(id.tagTexts, id: \.self) { text in
                    EngineTag(text: text)
                }
            }

            if let failureMessage, !busy {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .padding(.top, 1)
                    Text(failureMessage)
                        .font(DS.Font.prose(10.5))
                        .lineLimit(2)
                }
                .foregroundStyle(DS.err)
                .help(failureMessage)
            }

            if busy {
                DSDivider()
                installProgress(id: id, phase: phase, accent: accent)
            }
        }
        .padding(16)
        .dsSurface(
            radius: DS.Radius.card,
            tint: isActive && state.isRunning ? accent.opacity(0.08) : nil,
            stroke: isActive ? accent.opacity(state.isRunning ? 0.42 : 0.24) : nil,
            hoverable: true,
            active: isActive
        )
        .onHover { inside in
            hoveringEngine = inside ? id : (hoveringEngine == id ? nil : hoveringEngine)
        }
    }

    @ViewBuilder
    private func cardStatusChip(
        installed: Bool,
        active: Bool,
        busy: Bool,
        failed: Bool,
        accent: Color
    ) -> some View {
        if busy {
            DSChip(
                text: installed ? "更新中" : "安装中",
                dot: DS.warn, tint: DS.warn)
        } else if failed {
            DSChip(
                text: installed ? "更新失败" : "安装失败",
                dot: DS.err, tint: DS.err)
        } else if active, state.isRunning {
            switch state.serverState {
            case .ready:
                DSChip(text: "运行中", dot: DS.ok, live: true, tint: DS.ok)
            case .starting:
                DSChip(text: "启动中", dot: DS.warn, tint: DS.warn)
            case .stopping:
                DSChip(text: "停止中", dot: DS.warn, tint: DS.warn)
            case .failed:
                DSChip(text: "异常", dot: DS.err, tint: DS.err)
            case .stopped:
                DSChip(text: "已安装", dot: accent, tint: accent)
            }
        } else if installed {
            DSChip(text: "已安装", dot: accent, tint: accent)
        } else {
            DSChip(text: "未安装", dot: DS.text4)
        }
    }

    private func metaText(id: EngineID, installed: Bool, versions: [String]) -> String {
        let license = id.descriptor.license ?? "—"
        if installed, let version = versions.first ?? installedVersion(id) {
            return "\(versionText(version)) · \(license)"
        }
        if let version = knownUpstreamVersion(id) {
            return L10n.format("最新 %@ · 未安装", versionText(version))
        }
        return L10n.t("未安装")
    }

    @ViewBuilder
    private func cardActions(
        id: EngineID,
        installed: Bool,
        active: Bool,
        busy: Bool,
        versions: [String],
        accent: Color
    ) -> some View {
        if busy {
            Text(verbatim: "\(installPercent(id))%")
                .font(DS.Font.mono(11.5, weight: .semibold))
                .foregroundStyle(accent)
                .monospacedDigit()
                .padding(.top, 4)
        } else if !installed {
            Button {
                installEngine(id)
            } label: {
                Label(L10n.t("下载"), systemImage: "arrow.down")
            }
            .buttonStyle(.ds(.primary, size: .regular))
            .disabled(installs.building != nil)
            .help(
                installs.building.map { L10n.format("正在构建 %@，完成后再试", $0.displayName) }
                    ?? L10n.t("下载并安装引擎")
            )
        } else {
            HStack(spacing: 6) {
                DSIconButton(
                    systemName: "slider.horizontal.3",
                    help: "配置与调优",
                    size: 28,
                    style: .outlined
                ) {
                    configuring = id
                }
                .disabled(versions.isEmpty)

                if active, state.isRunning {
                    DSIconButton(
                        systemName: "arrow.clockwise",
                        help: "重启引擎",
                        size: 28,
                        style: .outlined
                    ) {
                        state.restartService()
                    }
                    .disabled(state.serverState == .starting || state.serverState == .stopping)
                }

                engineMenu(id: id, active: active, busy: busy, versions: versions)

                if active {
                    if state.isRunning {
                        Button {
                            state.toggleService()
                        } label: {
                            Label(L10n.t("停止"), systemImage: "stop.fill")
                        }
                        .buttonStyle(.ds(.danger, size: .small))
                        .disabled(state.serverState == .starting || state.serverState == .stopping)
                        .help(L10n.t("停止引擎"))
                    } else {
                        Button {
                            state.toggleService()
                        } label: {
                            Label(L10n.t("启动"), systemImage: "play.fill")
                        }
                        .buttonStyle(OverviewTintActionStyle(tint: DS.ok))
                        .disabled(activeToggleDisabled)
                        .help(
                            state.selectedModel.isEmpty && !state.isRunning
                                ? L10n.t("请先选择模型")
                                : L10n.t("启动引擎"))
                    }
                } else {
                    Button {
                        switchEngine(id)
                    } label: {
                        Label(L10n.t("启动"), systemImage: "play.fill")
                    }
                    .buttonStyle(OverviewTintActionStyle(tint: DS.ok))
                    .disabled(state.isSwitchingModel)
                    .help(L10n.format("切换到 %@ 并启动", id.displayName))
                }
            }
            .padding(.top, 2)
        }
    }

    private func engineMenu(
        id: EngineID,
        active: Bool,
        busy: Bool,
        versions: [String]
    ) -> some View {
        DSMenu(kind: .icon, size: .regular) {
            DSMenuTriggerLabel(
                systemImage: "ellipsis",
                kind: .icon,
                size: .regular
            )
            .opacity(hoveringEngine == id ? 1 : 0.5)
        } content: {
            Button(L10n.t("配置…")) {
                configuring = id
            }
            .disabled(versions.isEmpty)

            if let repository = id.descriptor.upstreamRepository,
                let url = URL(string: "https://github.com/\(repository)")
            {
                Button(L10n.t("打开上游仓库")) {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider()

            Button(
                active && state.isRunning
                    ? L10n.t("请先停止引擎再删除")
                    : L10n.t("删除运行时…"),
                role: .destructive
            ) {
                pendingRemoval = id
            }
            .disabled(busy || versions.isEmpty || (active && state.isRunning))
        }
        .help(L10n.t("更多操作"))
        .accessibilityLabel(L10n.t("更多操作"))
    }

    private func installProgress(id: EngineID, phase: EngineInstallPhase, accent: Color) -> some View {
        let step = L10n.t(installs.progressStep[id] ?? phase.label)
        let fraction = installs.progress[id] ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(step)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(verbatim: "\(installPercent(id))%")
                    .font(DS.Font.mono(10.5))
                    .foregroundStyle(DS.text3)
                    .monospacedDigit()
            }
            EngineProgressBar(fraction: fraction, tint: accent)
        }
        .help(step)
    }

    private func installPercent(_ id: EngineID) -> Int {
        Int((min(max(installs.progress[id] ?? 0, 0), 1) * 100).rounded())
    }

    // MARK: - Actions

    private func startEngine(_ id: EngineID) {
        if id == state.activeEngine {
            state.toggleService()
        } else {
            Task { @MainActor in
                _ = await state.switchEngine(id, start: true)
            }
        }
    }

    private func switchEngine(_ id: EngineID) {
        Task { @MainActor in
            _ = await state.switchEngine(id, start: true)
        }
    }

    private var activeToggleDisabled: Bool {
        state.isSwitchingModel
            || state.serverState == .starting
            || state.serverState == .stopping
            || (!state.isRunning && state.selectedModel.isEmpty)
    }

    private func refreshEngines() {
        guard !refreshing else { return }
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false }
            installs.refreshInstalled()
            await installs.loadIndexIfNeeded(force: true)
            await installs.checkUpstream(force: true)
            let failures = installs.upstreamErrors
            if failures.isEmpty {
                state.toast(L10n.t("已刷新引擎目录，全部版本均与远端同步"))
            } else {
                let first =
                    EngineCatalog.allIDs.compactMap { id in
                        failures[id].map { "\(id.displayName)：\($0)" }
                    }.first ?? ""
                state.toast(
                    L10n.format(
                        "已检查引擎更新，%lld 个引擎失败：%@",
                        Int64(failures.count), first))
            }
        }
    }

    private func updateEngine(_ id: EngineID) {
        Task { @MainActor in
            _ = await installs.installFromUpstream(id)
        }
    }

    private func installEngine(_ id: EngineID) {
        guard installs.building == nil else {
            state.toast(
                L10n.format(
                    "正在构建 %@，完成后再试",
                    installs.building?.displayName ?? L10n.t("引擎")))
            return
        }
        // 从引擎的最新 GitHub Release 构建。随包索引不能分发引擎二进制，
        // 走 pack 索引只会解析到不存在的本地文件。
        Task { @MainActor in
            _ = await installs.installFromUpstream(id)
        }
    }

    private func removableVersionsText(_ id: EngineID) -> String {
        let versions = EngineInstallations.removableVersions(id)
        guard !versions.isEmpty else { return L10n.t("可删除的运行时") }
        return versions.sorted().joined(separator: "、")
    }

    private func installedVersion(_ id: EngineID) -> String? {
        installs.installed[id]?.first ?? state.engines?.controller(id)?.installation.version
    }

    private func knownUpstreamVersion(_ id: EngineID) -> String? {
        if let installed = installs.installed[id]?.first { return installed }
        switch installs.upstream[id] {
        case .current(let version): return version
        case .update(_, let release): return release.version
        default: return installs.releases[id]?.first?.version
        }
    }

    private func versionText(_ version: String) -> String {
        version.hasPrefix("v") ? version : "v\(version)"
    }
}

// MARK: - Filter button

private struct EngineFilterButton: View {
    var title: String
    var selected: Bool
    var action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text(L10n.t(title))
                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? DS.text : (hovering ? DS.text : DS.text3))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background {
                    if selected {
                        Capsule()
                            .fill(DS.pillActive)
                            .overlay(Capsule().strokeBorder(DS.pillBorder, lineWidth: 1))
                            .shadow(color: DS.glassShadow.opacity(0.6), radius: 4, y: 1)
                    } else if hovering {
                        Capsule().fill(DS.hover)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if reduceMotion {
                hovering = inside
            } else {
                withAnimation(DS.Motion.snappy) { hovering = inside }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Small parts

/// 目录卡上的微标签：格式与能力，一行可换行。
struct EngineTag: View {
    var text: String

    var body: some View {
        Text(L10n.t(text))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DS.text2)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(DS.rect(DS.Radius.sm).fill(DS.bg))
            .overlay(DS.rect(DS.Radius.sm).strokeBorder(DS.line, lineWidth: 1))
            .fixedSize()
    }
}

/// 安装进度条：3pt 高、蓝→靛→紫的短渐变，和目录卡的强调色一致。
struct EngineProgressBar: View {
    var fraction: Double
    var tint: Color

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.line2)
                if clamped > 0 {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.72), tint, DS.accent],
                                startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, proxy.size.width * clamped))
                }
            }
        }
        .frame(height: 3)
        .animation(DS.Motion.smooth, value: clamped)
    }
}

/// 引擎官方图标：优先使用上游仓库的 app icon，找不到时回落到字母占位块。
struct EngineGlyph: View {
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
        // 官方图标本身的配色不动，用一圈引擎色描边把「这台是谁」带出来。
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(color.opacity(0.28), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

func engineArtwork(_ id: EngineID) -> String? {
    switch id {
    case .splash: return "engine-splash"
    case .omlx: return "engine-omlx"
    case .mtplx: return "engine-mtplx"
    case .mlxServe: return "engine-mlxserve"
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
    default: return DS.accent
    }
}

func engineSymbol(_ id: EngineID) -> String {
    switch id {
    case .splash: return "bolt.fill"
    case .omlx: return "cpu"
    case .mtplx: return "square.stack.3d.up.fill"
    case .mlxServe: return "shippingbox.fill"
    default: return "cpu"
    }
}
