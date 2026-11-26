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
    /// 壳层在布局这一拍量到的详情区尺寸；宽 / 窄版式直接由它决定。
    let pageSize: CGSize

    @State private var configuring: EngineID?
    @State private var pendingRemoval: EngineID?
    @State private var gridColumns = 0
    @State private var refreshing = false
    @State private var refreshHovering = false
    @StateObject private var refreshFlash = ActionFlashState()
    @StateObject private var endpointFlash = ActionFlashState()
    /// 刷新失败时的原因，挂在刷新钮的悬停提示上；成功时清空。
    @State private var refreshNote: String?
    @State private var hoveringEngine: EngineID?

    private var isWide: Bool {
        pageSize.width >= Console.compactContentWidth
    }

    private static let cardMinWidth: CGFloat = 400
    private static let cardSpacing: CGFloat = 14

    private var loadedModelID: String {
        if !state.selectedModel.isEmpty { return state.selectedModel }
        return state.stats?.model ?? ""
    }

    var body: some View {
        let horizontal = Console.pageHorizontalPadding(compact: !isWide)
        ScrollView {
            VStack(alignment: .leading, spacing: Console.pageSectionGap) {
                if state.isRunning {
                    runtimeSection
                }
                catalogSection
            }
            .padding(.horizontal, horizontal)
            .padding(.top, Console.scrollTopInset(sidebarShown: state.showsSidebar))
            .padding(.bottom, Console.contentBottomInset)
        }
        .scrollIndicators(.never)
        .dsTrackColumns(
            $gridColumns,
            minWidth: Self.cardMinWidth,
            spacing: Self.cardSpacing,
            maxColumns: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItem(id: DSToolbarSlot.title, placement: .navigation) {
                DSToolbarPageTitle(
                    title: "引擎")
                    .padding(.leading, 15)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(id: DSToolbarSlot.anchor, placement: .principal) {
                DSToolbarAnchor()
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(id: DSToolbarSlot.actions, placement: .primaryAction) {
                DSToolbarActionRow(state: state, compact: !isWide) {
                    enginesToolbarAction
                }
            }
            .sharedBackgroundVisibility(.hidden)
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
                // 删除结果直接反映在引擎卡的版本与安装态上，不再补一张回执卡。
                Task { @MainActor in
                    _ = await installs.removeRuntime(id)
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

    /// 工具栏上的「检查更新」。刷新完成用图标短暂变成对勾 / 感叹号收口，
    /// 有上游新版时在文字后补一枚计数角标。
    @ViewBuilder
    private var enginesToolbarAction: some View {
        let updates = availableUpdateCount

        if isWide {
            Button(action: refreshEngines) {
                HStack(spacing: 5) {
                    if refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        ActionFlashIcon(
                            systemName: "arrow.clockwise",
                            flash: refreshFlash.value,
                            size: 12,
                            baseColor: DS.text2)
                    }
                    Text(L10n.t("检查更新"))
                    if updates > 0 {
                        DSBadge(count: updates)
                    }
                }
            }
            .buttonStyle(.ds(.secondary, size: .regular))
            .disabled(refreshing)
            .help(refreshHelp)
        } else {
            Button(action: refreshEngines) {
                Group {
                    if refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        ActionFlashIcon(
                            systemName: "arrow.clockwise",
                            flash: refreshFlash.value,
                            size: 12,
                            baseColor: updates > 0 ? DS.accent : DS.text2)
                    }
                }
                .frame(width: 28, height: 28)
                .background(DS.rect(DS.Radius.md).fill(DS.surface))
                .overlay(DS.rect(DS.Radius.md).strokeBorder(DS.line2, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if updates > 0 {
                        Circle().fill(DS.accent)
                            .frame(width: 6, height: 6)
                            .padding(4)
                    }
                }
                .contentShape(DS.rect(DS.Radius.md))
            }
            .buttonStyle(.plain)
            .disabled(refreshing)
            .help(refreshHelp)
        }
    }

    private var availableUpdateCount: Int {
        EngineCatalog.allIDs.filter { id in
            state.engineIsInstalled(id) && installs.upstream[id]?.newerRelease != nil
        }.count
    }

    private var refreshHelp: String {
        if refreshing { return L10n.t("正在检查更新…") }
        if let refreshNote { return refreshNote }
        return L10n.t("刷新并检查引擎更新")
    }

    // MARK: - Runtime hero

    private var runtimeSection: some View {
        EngineRuntimeStrip(
            engine: state.activeEngine,
            port: state.port,
            modelName: loadedModelID.isEmpty ? "" : state.shortModelName(loadedModelID),
            copyFlash: endpointFlash.value,
            actions: EngineRuntimeStrip.Actions(
                logs: { state.section = .logs },
                copyEndpoint: {
                    state.copy("127.0.0.1:\(state.port)")
                    endpointFlash.succeed()
                }
            )
        )
    }

    // MARK: - Catalog

    private var catalogSection: some View {
        DSAnimatedGrid(
            columns: gridColumns,
            minWidth: Self.cardMinWidth,
            spacing: Self.cardSpacing,
            maxColumns: 2
        ) {
            ForEach(EngineCatalog.allIDs, id: \.self) { id in
                engineCard(id)
            }
        }
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
            return L10n.format("最新 %@", versionText(version))
        }
        return license
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
                    style: .ghost
                ) {
                    configuring = id
                }
                .disabled(versions.isEmpty)

                if active, state.isRunning {
                    DSIconButton(
                        systemName: "arrow.clockwise",
                        help: "重启引擎",
                        size: 28,
                        style: .ghost
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
            if let repository = id.descriptor.upstreamRepository,
                let url = URL(string: "https://github.com/\(repository)")
            {
                Button(L10n.t("打开上游仓库")) {
                    NSWorkspace.shared.open(url)
                }
                Divider()
            }

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
                refreshNote = nil
                refreshFlash.succeed()
            } else {
                let first =
                    EngineCatalog.allIDs.compactMap { id in
                        failures[id].map { "\(id.displayName)：\($0)" }
                    }.first ?? ""
                // 失败原因跟着按钮走：图标变感叹号，悬停就能读到第一个错误。
                refreshNote = L10n.format(
                    "已检查引擎更新，%lld 个引擎失败：%@",
                    Int64(failures.count), first)
                refreshFlash.warn()
            }
        }
    }

    private func updateEngine(_ id: EngineID) {
        Task { @MainActor in
            _ = await installs.installFromUpstream(id)
        }
    }

    private func installEngine(_ id: EngineID) {
        // 正在构建时按钮本身是禁用的，这里只防御其他入口；不再弹提示。
        guard installs.building == nil else { return }
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

// MARK: - Small parts

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
