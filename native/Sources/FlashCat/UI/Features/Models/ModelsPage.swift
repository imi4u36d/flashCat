// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 模型库：按引擎切换并浏览已安装与推荐的模型权重。
struct ModelsPage: View {
    @ObservedObject var state: AppState
    @Binding var showingHub: Bool
    @Binding var showingDownloads: Bool
    /// 壳层在布局这一拍量到的详情区尺寸；宽 / 窄版式直接由它决定。
    let pageSize: CGSize

    @State private var removeTarget: ModelLibraryEntry?
    @State private var device = DeviceProfile.current()
    @State private var rescanning = false
    @StateObject private var rescanFlash = ActionFlashState()

    private static let scrollTopAnchor = "models.scroll.top"

    private var isWide: Bool {
        pageSize.width >= Console.compactContentWidth
    }

    // MARK: - State

    private var engine: EngineID { state.libraryEngine }
    private var installedAll: [ModelLibraryEntry] {
        state.libraryEntries(for: engine).filter(\.installed)
    }
    private var recommendedAll: [ModelLibraryEntry] {
        state.libraryEntries(for: engine).filter { !$0.installed }
    }
    private var orderedInstalled: [ModelLibraryEntry] {
        installedAll.enumerated()
            .sorted { lhs, rhs in
                let l = isSelected(lhs.element) ? 0 : 1
                let r = isSelected(rhs.element) ? 0 : 1
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
    }
    private var downloadCount: Int {
        let pending = state.downloadTasks.filter { task in
            !(task.model == state.downloadingModel && task.engine == state.downloadingEngine)
        }.count
        return pending + (state.downloadingModel == nil ? 0 : 1)
    }
    /// 未安装引擎的空态里「返回」的落点：优先正在运行的引擎，其次第一台装好的。
    private var installedFallback: EngineID? {
        if state.engineIsInstalled(state.activeEngine) { return state.activeEngine }
        return EngineCatalog.allIDs.first { state.engineIsInstalled($0) }
    }

    private func installedCount(_ id: EngineID) -> Int {
        state.libraryEntries(for: id).filter(\.installed).count
    }

    // MARK: - Body

    var body: some View {
        let horizontal = Console.pageHorizontalPadding(compact: !isWide)
        VStack(alignment: .leading, spacing: 0) {
            engineBar
                .padding(.horizontal, horizontal)
                .padding(.top, Console.scrollTopInset(sidebarShown: state.showsSidebar))
                .padding(.bottom, Console.pageSectionGap)

            contentPane
                .padding(.horizontal, horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItem(id: DSToolbarSlot.title, placement: .navigation) {
                DSToolbarPageTitle(
                    title: "模型库"
                )
                .padding(.leading, 15)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(id: DSToolbarSlot.anchor, placement: .principal) {
                DSToolbarAnchor()
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(id: DSToolbarSlot.actions, placement: .primaryAction) {
                DSToolbarActionRow(state: state, compact: !isWide) {
                    if isWide {
                        Button(action: openHub) {
                            HStack(spacing: 5) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text(L10n.t("模型广场"))
                            }
                        }
                        .buttonStyle(OverviewTintActionStyle(tint: DS.accent))
                    } else {
                        DSIconButton(
                            systemName: "magnifyingglass",
                            help: "模型广场",
                            size: 28,
                            style: .outlined,
                            tint: DS.accent,
                            action: openHub)
                    }

                    DSMenu(kind: .toolbarIcon, size: .regular) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.text2)
                    } content: {
                        Button(downloadCenterLabel) {
                            showingDownloads = true
                        }
                        Divider()
                        Button(rescanLabel) {
                            rescan()
                            rescanFlash.succeed()
                        }
                        .disabled(rescanning || !state.engineIsInstalled(engine))
                        Divider()
                        Button(L10n.t("在 Finder 中显示")) {
                            revealModelFolder()
                        }
                        .disabled(!state.engineIsInstalled(engine))
                    }
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .dsPageColumn()
        .alert(
            L10n.format("删除 %@？", removeTarget?.model.shortName ?? ""),
            isPresented: Binding(
                get: { removeTarget != nil },
                set: { if !$0 { removeTarget = nil } })
        ) {
            Button(L10n.t("删除"), role: .destructive) {
                if let entry = removeTarget {
                    state.removeModel(entry.model.id, engine: entry.engine)
                }
                removeTarget = nil
            }
            Button(L10n.t("取消"), role: .cancel) { removeTarget = nil }
        } message: {
            Text(removalMessage)
        }
    }

    private var downloadCenterLabel: String {
        downloadCount > 0
            ? L10n.format("下载中心（%lld）", Int64(downloadCount))
            : L10n.t("下载中心")
    }

    private var rescanLabel: String {
        rescanning ? L10n.t("正在扫描…") : L10n.t("重新扫描这个引擎的模型目录")
    }

    // MARK: - Engine switcher

    private var engineBar: some View {
        ViewThatFits(in: .horizontal) {
            engineButtons
            ScrollView(.horizontal) {
                engineButtons
            }
            .scrollIndicators(.never)
        }
    }

    private var engineButtons: some View {
        HStack(spacing: 6) {
            ForEach(EngineCatalog.allIDs, id: \.self) { id in
                EngineTabPill(
                    engine: id,
                    installed: state.engineIsInstalled(id),
                    installedCount: installedCount(id),
                    selected: id == engine
                ) {
                    select(id)
                }
            }
        }
    }

    private func select(_ id: EngineID) {
        guard id != engine else { return }
        state.libraryEngine = id
    }

    // MARK: - Content

    @ViewBuilder
    private var contentPane: some View {
        if !state.engineIsInstalled(engine) {
            uninstalledState
        } else {
            libraryPane
        }
    }

    private var libraryPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Color.clear
                        .frame(height: 0)
                        .id(Self.scrollTopAnchor)

                    installedSection

                    if !recommendedAll.isEmpty {
                        recommendedSection
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, Console.contentBottomInset)
            }
            .scrollIndicators(.never)
            .onChange(of: engine) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo(Self.scrollTopAnchor, anchor: .top)
                }
            }
        }
    }

    // MARK: - Sections

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: L10n.t("已安装"),
                count: orderedInstalled.count)

            if orderedInstalled.isEmpty {
                installedEmpty
            } else {
                listSurface(orderedInstalled)
            }
        }
    }

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: L10n.t("推荐"),
                count: recommendedAll.count)

            listSurface(recommendedAll)
        }
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(DS.Font.prose(13.5, weight: .semibold))
                .foregroundStyle(DS.text)
            Text(verbatim: "\(count)")
                .font(DS.Font.mono(11.5))
                .foregroundStyle(DS.text3)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listSurface(_ entries: [ModelLibraryEntry]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.identity) { index, entry in
                LibraryRow(
                    state: state,
                    entry: entry,
                    selected: isSelected(entry),
                    device: device,
                    remove: { removeTarget = entry })
                if index != entries.count - 1 {
                    Rectangle()
                        .fill(DS.line)
                        .frame(height: 1)
                }
            }
        }
        .clipShape(DS.rect(DS.Radius.card))
        .dsSurface(radius: DS.Radius.card)
    }

    // MARK: - Empty states

    private var installedEmpty: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "internaldrive", color: DS.text3, size: 30)
            Text(L10n.t("这个目录还没有模型"))
                .font(DS.Font.sm.weight(.semibold))
                .foregroundStyle(DS.text)
            Spacer(minLength: 8)
            Button(L10n.t("模型广场"), action: openHub)
                .buttonStyle(PillButtonStyle(height: 26, horizontalPadding: 10))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(radius: DS.Radius.card)
    }

    private var uninstalledState: some View {
        VStack(spacing: 14) {
            EngineBadge(engine: engine, size: 56)
            Text(L10n.format("%@ 引擎尚未安装", engine.displayName))
                .font(DS.Font.prose(16, weight: .semibold))
                .foregroundStyle(DS.text)

            HStack(spacing: 8) {
                Button {
                    state.requestEngineInstall(engine)
                } label: {
                    Text(L10n.format("一键安装 %@", engine.displayName))
                }
                .buttonStyle(AccentPillButtonStyle(height: 32))

                if let fallback = installedFallback, fallback != engine {
                    Button {
                        select(fallback)
                    } label: {
                        Text(L10n.format("返回 %@", fallback.displayName))
                    }
                    .buttonStyle(PillButtonStyle(height: 32))
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 30)
        .frame(maxWidth: 460)
        .dsSurface(radius: DS.Radius.window)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isSelected(_ entry: ModelLibraryEntry) -> Bool {
        entry.installed && entry.engine == state.activeEngine && entry.model.id == state.selectedModel
    }

    // MARK: - Actions

    private func openHub() {
        showingHub = true
        state.searchHub(
            state.hub.hubQuery, sort: state.hub.hubSort.rawValue,
            filter: state.hub.hubFilter.rawValue, page: 0)
    }

    private func rescan() {
        guard !rescanning else { return }
        rescanning = true
        let target = engine
        _ = EngineModelStore.adoptExistingWeights(target)
        state.reloadModels()
        Task { @MainActor in
            defer { rescanning = false }
            await state.engines?.controller(target)?.rescanModels()
            state.reloadModels()
            // 列表已经换过一轮，回执只落在刷新按钮上：对勾停一秒多再还原。
            rescanFlash.succeed()
        }
    }

    private func revealModelFolder() {
        state.revealModelFolder(for: engine)
    }

    private var removalMessage: String {
        guard let entry = removeTarget else { return "" }
        if entry.model.path.isEmpty { return entry.model.id }
        return L10n.format("会删除 %@ 的权重，无法恢复。", entry.model.sizeText)
    }
}

// MARK: - Engine selector pills

private struct EngineTabPill: View {
    let engine: EngineID
    let installed: Bool
    let installedCount: Int
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { engineAccent(engine) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: engineSymbol(engine))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(selected ? accent : DS.text2)
                Text(engine.displayName)
                    .font(DS.Font.prose(12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                if installed, installedCount > 0 {
                    Text(verbatim: "\(installedCount)")
                        .font(DS.Font.mono(9.5))
                        .foregroundStyle(selected ? accent : DS.text3)
                        .monospacedDigit()
                } else if !installed {
                    Text(L10n.t("未安装"))
                        .font(DS.Font.mono(9.5))
                        .foregroundStyle(DS.text3)
                }
            }
            .fixedSize()
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background {
                Capsule()
                    .fill(
                        selected
                            ? accent.opacity(0.12)
                            : (hovering ? DS.raised : DS.pillFill))
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        selected ? accent.opacity(0.34) : DS.line,
                        lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plainHit)
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
    }
}

// MARK: - Model rows

private struct LibraryRow: View {
    @ObservedObject var state: AppState
    let entry: ModelLibraryEntry
    let selected: Bool
    let device: DeviceProfile
    let remove: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var model: ModelInfo { entry.model }
    private var family: ModelFamily {
        ModelFamily.resolve(
            id: model.id,
            hint: model.family,
            tags: entry.recommendation?.tags ?? [])
    }
    private var task: ModelDownloadTask? {
        let key = ModelSharing.canonical(entry.id)
        return state.downloadTasks.first {
            $0.engine == entry.engine && ModelSharing.canonical($0.model) == key
        }
    }
    private var activeFraction: Double? {
        guard let running = state.downloadingModel,
            state.downloadingEngine == entry.engine,
            ModelSharing.canonical(running) == ModelSharing.canonical(entry.id)
        else { return nil }
        return state.downloadFraction ?? 0
    }
    private var isSwitchingThis: Bool {
        state.switchingModel == model.id && state.activeEngine == entry.engine
    }
    private var capabilityBadge: (symbol: String, help: String)? {
        let matched = state.engineModels(for: entry.engine).first(where: { $0.id == model.id })
        if matched?.supportsVideo == true { return ("film", "视频模型") }
        if matched?.supportsImage == true { return ("photo", "图像模型") }
        if matched?.supportsVision == true || model.mmprojPath != nil { return ("eye", "视觉模型") }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            ModelFamilyIcon(family: family, size: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(titleName)
                        .font(DS.Font.prose(13.5, weight: .semibold))
                        .tracking(-0.1)
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(titleHelp)
                    if let capability = capabilityBadge {
                        Image(systemName: capability.symbol)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(DS.text3)
                            .help(L10n.t(capability.help))
                            .accessibilityLabel(L10n.t(capability.help))
                    }
                }
                metaRow
            }

            Spacer(minLength: 8)

            action

            RowActionsMenu {
                menuItems
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(selected ? DS.accentSoft : (hovering ? DS.hover : .clear))
        .contentShape(Rectangle())
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
        .contextMenu {
            menuItems
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if !model.path.isEmpty {
            Button(L10n.t("在 Finder 中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.path)])
            }
        }
        Button(L10n.t("复制模型 ID")) { state.copy(model.id) }
        if entry.installed {
            Divider()
            Button(L10n.t("删除权重…"), role: .destructive, action: remove)
        }
    }

    private var titleName: String {
        var title = model.shortName
        if let colon = title.lastIndex(of: ":") {
            let name = String(title[title.startIndex..<colon])
            let variant = String(title[title.index(after: colon)...])
            if !name.isEmpty, !variant.isEmpty, variant.count <= 16 {
                title = name
            }
        }
        // 仓库名里的 -GGUF 只是包装格式，量化已经在下面一行了。
        for suffix in ["-GGUF", "-gguf"] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
            break
        }
        return title
    }

    private var titleHelp: String {
        if let summary = entry.recommendation?.summary, !summary.isEmpty {
            return "\(model.id)\n\(summary)"
        }
        return model.id
    }

    /// 一行元信息：真实量化档位 · 体积 · 内存下限（超出本机时标红）。
    private var metaRow: some View {
        HStack(spacing: 5) {
            if let quantization = quantizationLabel {
                Text(verbatim: quantization)
                    .font(DS.Font.mono(10, weight: .medium))
                    .foregroundStyle(DS.text2)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(DS.rect(4).fill(DS.pillFill))

                separatorDot
            }

            if model.bytes > 0 {
                Text(verbatim: model.sizeText)
                    .font(DS.Font.mono(11))
                    .foregroundStyle(DS.text3)
                if requiredMemoryGB > 0 {
                    separatorDot
                }
            }
            if requiredMemoryGB > 0 {
                Text(verbatim: memoryText)
                    .font(DS.Font.mono(11))
                    .foregroundStyle(exceedsMemory ? DS.err : DS.text3)
                    .lineLimit(1)
                    .help(memoryText)
            }
        }
        .lineLimit(1)
    }

    private var separatorDot: some View {
        Text(verbatim: "·")
            .font(DS.Font.mono(11))
            .foregroundStyle(DS.text4)
    }

    private var quantizationLabel: String? {
        if let quant = model.quantization, !quant.isEmpty { return quant }
        if let variant = entry.recommendation?.variant {
            if let quant = ModelQuantization.detect(in: variant) { return quant }
            // `PQ2_0` and other engine-specific names are still the most
            // precise label the row can show; don't fall back to the format.
            if !variant.isEmpty, variant.count <= 20 { return variant }
        }
        if let quant = ModelQuantization.detect(in: model.id) { return quant }
        if let quant = ModelQuantization.detect(in: model.targetName) { return quant }
        return entry.recommendation?.tags.first { ModelQuantization.detect(in: $0) != nil }
    }

    private var requiredMemoryGB: Int { modelRequiredMemoryGB(entry) }
    private var exceedsMemory: Bool {
        device.memoryGB > 0 && requiredMemoryGB > device.memoryGB
    }
    private var memoryText: String {
        let memory = requiredMemoryGB
        if exceedsMemory {
            return L10n.format("%lld GB 内存起 · 超出本机", memory)
        }
        return L10n.format("%lld GB 内存起", memory)
    }

    @ViewBuilder private var action: some View {
        if let fraction = activeFraction {
            let preparing = state.downloadFraction == nil || (fraction == 0 && state.downloadSpeed == 0)
            Button {
                state.pauseDownload()
            } label: {
                HStack(spacing: 5) {
                    MiniProgressRing(fraction: fraction)
                    Text(verbatim: preparing ? "…" : percentText(fraction))
                        .font(DS.Font.mono(10.5, weight: .medium))
                        .monospacedDigit()
                }
            }
            .buttonStyle(PillButtonStyle(tone: .accent, height: 26, horizontalPadding: 10))
            .help(preparing ? L10n.t("准备中…") : L10n.t("暂停下载"))
        } else if let task = task {
            let done = (task.fraction ?? 0) >= 0.999
            if done {
                downloadedPill
            } else {
                let busy = state.downloadingModel != nil
                Button {
                    state.resumeDownload(task)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: task.status == .paused ? "play.fill" : "arrow.clockwise")
                            .font(.system(size: 8.5, weight: .bold))
                        Text(verbatim: taskLabel(task))
                            .font(DS.Font.mono(10.5, weight: .medium))
                            .monospacedDigit()
                    }
                }
                .buttonStyle(PillButtonStyle(height: 26, horizontalPadding: 10))
                .disabled(busy)
                .help(
                    busy
                        ? L10n.t("已有下载任务进行中，请稍候")
                        : L10n.t(task.status == .paused ? "继续下载" : "重试")
                )
            }
        } else if entry.installed {
            if isSwitchingThis {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                    Text(L10n.t(state.switchStage.isEmpty ? "加载中" : state.switchStage))
                        .font(DS.Font.xs.weight(.medium))
                        .foregroundStyle(DS.warn)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(DS.warn.opacity(0.10)))
            } else if selected {
                Text(L10n.t("使用中"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(DS.accent.opacity(0.14)))
            } else {
                Button {
                    state.useModel(model.id, engine: entry.engine)
                } label: {
                    Text(L10n.t("使用"))
                }
                .buttonStyle(PillButtonStyle(height: 26, horizontalPadding: 12, fontSize: 12))
                // 生成期间换模型会被拒；按钮先灰掉，别让读者点完才看到提示。
                .disabled(state.isSwitchingModel || state.generating)
                .help(
                    state.generating
                        ? L10n.t("正在生成，先停止再切换模型") : L10n.t("使用这个模型"))
            }
        } else {
            Button {
                state.downloadModel(model.id, engine: entry.engine)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.8)
                    Text(L10n.t("下载"))
                }
            }
            .buttonStyle(PillButtonStyle(height: 26, horizontalPadding: 11, fontSize: 12))
            .disabled(state.downloadingModel != nil)
            .help(
                state.downloadingModel != nil
                    ? L10n.t("已有下载任务进行中，请稍候")
                    : L10n.format("下载到 %@ 的模型目录", entry.engine.displayName))
        }
    }

    private var downloadedPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 8.5, weight: .bold))
            Text(L10n.t("已下载"))
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(DS.ok)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(DS.successFill))
    }

    private func taskLabel(_ task: ModelDownloadTask) -> String {
        guard task.status == .paused else { return L10n.t("重试") }
        guard let fraction = task.fraction else { return L10n.t("继续") }
        return L10n.format("继续 %@", percentText(fraction))
    }

    private func percentText(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

// MARK: - Shared bits

private struct EngineBadge: View {
    let engine: EngineID
    var size: CGFloat = 32

    var body: some View {
        let color = engineAccent(engine)
        let radius = min(size * 0.35, 16)
        ZStack {
            DS.rect(radius).fill(color.opacity(0.13))
            Image(systemName: engineSymbol(engine))
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 胶囊玻璃按钮：页头动作与行内动作共用。`accent` 是浅强调底，用于下载进度。
private struct PillButtonStyle: ButtonStyle {
    enum Tone { case glass, accent }

    var tone: Tone = .glass
    var height: CGFloat = 30
    var horizontalPadding: CGFloat = 12
    var fontSize: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(
            configuration: configuration,
            tone: tone,
            height: height,
            horizontalPadding: horizontalPadding,
            fontSize: fontSize)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tone: PillButtonStyle.Tone
    let height: CGFloat
    let horizontalPadding: CGFloat
    let fontSize: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var activeHover: Bool { hovering && isEnabled }

    private var fill: Color {
        switch tone {
        case .glass: return activeHover ? DS.raised : DS.pillFill
        case .accent: return DS.accent.opacity(activeHover ? 0.20 : 0.13)
        }
    }

    private var stroke: Color {
        switch tone {
        case .glass: return activeHover ? DS.line2 : DS.line
        case .accent: return DS.accent.opacity(activeHover ? 0.40 : 0.28)
        }
    }

    private var foreground: Color {
        switch tone {
        case .glass: return DS.text
        case .accent: return DS.accent
        }
    }

    var body: some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
            .contentShape(Capsule())
            .scaleEffect((!reduceMotion && configuration.isPressed && isEnabled) ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(reduceMotion ? nil : DS.Motion.snappy, value: configuration.isPressed)
            .animation(reduceMotion ? nil : DS.Motion.snappy, value: activeHover)
            .onHover { hovering = $0 }
    }
}

/// 实心强调胶囊：安装引擎这类页面上唯一的大声动作。
private struct AccentPillButtonStyle: ButtonStyle {
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        AccentPillButtonBody(configuration: configuration, height: height)
    }
}

private struct AccentPillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: height)
            .background(
                Capsule().fill(DS.accent.opacity(hovering && isEnabled ? 0.88 : 1))
            )
            .contentShape(Capsule())
            .scaleEffect((!reduceMotion && configuration.isPressed && isEnabled) ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(reduceMotion ? nil : DS.Motion.snappy, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// 行尾的更多操作：28pt 玻璃圆钮，与行内胶囊动作同高。
private struct RowActionsMenu<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? DS.text : DS.text3)
                .frame(width: 28, height: 28)
                .background(Circle().fill(hovering ? DS.raised : DS.pillFill))
                .overlay(Circle().strokeBorder(DS.line, lineWidth: 1))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

/// 下载进度的迷你圆环：在胶囊里与百分比并排，不占额外一行。
private struct MiniProgressRing: View {
    var fraction: Double
    var tint: Color = DS.accent
    var size: CGFloat = 13

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.22), lineWidth: 2)
            if clamped > 0 {
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : DS.Motion.smooth, value: clamped)
        .accessibilityHidden(true)
    }
}

/// 一个模型需要的内存下限：目录推荐值与权重体积取较大者，供行内徽标使用。
private func modelRequiredMemoryGB(_ entry: ModelLibraryEntry) -> Int {
    let catalog = entry.recommendation?.minimumMemory ?? 0
    let weightsGB =
        entry.model.bytes > 0
        ? Int((Double(entry.model.bytes) / 1_000_000_000).rounded(.up))
        : 0
    return max(catalog, weightsGB)
}
