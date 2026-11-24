// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 模型页：每个引擎一个独立的模型目录，页面围绕「当前选中的引擎」讲清楚
/// 三件事——它已经有哪些权重、它自己推荐哪些档位、下载会落到哪里。
///
/// 引擎选择是一排固定的目录入口，不随内容出现或消失；「已安装」和「推荐」
/// 同时作为两个分区存在，切换引擎只换行，不换页面骨架。这样浏览其他引擎、
/// 后台网关换引擎、离开页面再回来，都不会让筛选器、模式或布局跳来跳去。
struct ModelsPage: View {
    @ObservedObject var state: AppState
    @Binding var showingHub: Bool
    @Binding var showingDownloads: Bool

    private enum LibrarySort: String, CaseIterable, Identifiable {
        case curated
        case size
        case memory
        case name

        var id: String { rawValue }

        var label: String {
            switch self {
            case .curated: return "默认顺序"
            case .size: return "体积"
            case .memory: return "内存下限"
            case .name: return "名称"
            }
        }
    }

    /// 排序与「能跑」跨页面保留：离开模型库再回来，读者不用重新选一遍。
    @AppStorage("models.sort") private var sortRaw = LibrarySort.curated.rawValue
    @AppStorage("models.fitsOnly") private var runnableOnly = false
    @State private var query = ""
    @State private var removeTarget: ModelLibraryEntry?
    @State private var device = DeviceProfile.current()
    @State private var rescanning = false

    private static let scrollTopAnchor = "models.scroll.top"

    // MARK: - State

    private var engine: EngineID { state.libraryEngine }
    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .curated }
    private var installedAll: [ModelLibraryEntry] {
        state.libraryEntries(for: engine).filter(\.installed)
    }
    private var recommendedAll: [ModelLibraryEntry] {
        state.libraryEntries(for: engine).filter { !$0.installed }
    }
    private var hasRecommendationList: Bool {
        !state.libraryRecommendations(for: engine).isEmpty
    }
    private var filteredInstalled: [ModelLibraryEntry] { filtered(installedAll) }
    private var filteredRecommended: [ModelLibraryEntry] { filtered(recommendedAll) }
    private var queryText: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var isFiltering: Bool { !queryText.isEmpty || runnableOnly }
    private var noMatches: Bool {
        !queryText.isEmpty && filteredInstalled.isEmpty && filteredRecommended.isEmpty
    }
    private var downloadCount: Int {
        let pending = state.downloadTasks.filter { task in
            !(task.model == state.downloadingModel && task.engine == state.downloadingEngine)
        }.count
        return pending + (state.downloadingModel == nil ? 0 : 1)
    }

    private func installedCount(_ id: EngineID) -> Int {
        state.libraryEntries(for: id).filter(\.installed).count
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= Console.compactContentWidth
            VStack(alignment: .leading, spacing: 0) {
                header

                if wide {
                    HStack(alignment: .top, spacing: 0) {
                        engineRail
                            .frame(width: 204)
                            .padding(.leading, Console.topBarLeading(sidebarShown: state.showsSidebar))
                            .padding(.trailing, 16)
                        DSDivider(vertical: true)
                        contentPane
                            .padding(.leading, 20)
                            .padding(.trailing, Console.contentPadding)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        engineTabs
                            .padding(.leading, Console.topBarLeading(sidebarShown: state.showsSidebar))
                            .padding(.trailing, Console.contentPadding)
                        DSDivider()
                        contentPane
                            .padding(.horizontal, Console.contentPadding)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .dsPageColumn()
        .padding(.bottom, Console.contentBottomInset)
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

    // MARK: - Header

    private var header: some View {
        DSPageHeader(
            title: "模型库",
            subtitle: L10n.t("按引擎分开的模型目录")
        ) {
            actionControls
        }
        .padding(.leading, Console.topBarLeading(sidebarShown: state.showsSidebar))
        .padding(.trailing, Console.contentPadding)
        .padding(.top, Console.pageTopPadding)
        .padding(.bottom, 10)
        .background(WindowDragArea())
    }

    private var actionControls: some View {
        HStack(spacing: 8) {
            Button {
                showingDownloads = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(state.downloadingModel != nil ? DS.accent : DS.text2)
                    Text(
                        downloadCount > 0
                            ? L10n.format("下载 %lld", Int64(downloadCount))
                            : L10n.t("下载中心")
                    )
                }
            }
            .buttonStyle(.ds(.secondary, size: .regular))
            .help(L10n.t("下载中心"))

            Button(action: openHub) {
                Label(L10n.t("模型广场"), systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(.dsSecondary)

            DSIconButton(
                systemName: "arrow.clockwise",
                help: rescanning ? "正在扫描…" : "重新扫描这个引擎的模型目录",
                style: .outlined
            ) {
                rescan()
            }
            .disabled(rescanning || !state.engineIsInstalled(engine))
        }
    }

    // MARK: - Engine selector

    private var engineRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("引擎目录"))
                .font(DS.Font.mono(10.5, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(DS.text3)
                .padding(.leading, 8)
                .padding(.top, 4)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(EngineCatalog.allIDs, id: \.self) { id in
                        EngineRailRow(
                            engine: id,
                            installed: state.engineIsInstalled(id),
                            installedCount: installedCount(id),
                            selected: id == engine,
                            active: id == state.activeEngine,
                            running: id == state.activeEngine && state.isRunning
                        ) {
                            select(id)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .padding(.top, 2)
    }

    private var engineTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(EngineCatalog.allIDs, id: \.self) { id in
                    EngineTabPill(
                        engine: id,
                        installed: state.engineIsInstalled(id),
                        installedCount: installedCount(id),
                        selected: id == engine,
                        active: id == state.activeEngine,
                        running: id == state.activeEngine && state.isRunning
                    ) {
                        select(id)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
    }

    private func select(_ id: EngineID) {
        guard id != engine else { return }
        state.libraryEngine = id
        // 搜索词保留：换引擎后仍然在同一个查询下比较两个目录。
        // 滚动回到顶部由 contentPane 的 onChange 处理。
    }

    // MARK: - Content

    private var contentPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            contextBar

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Color.clear
                            .frame(height: 0)
                            .id(Self.scrollTopAnchor)

                        if !state.engineIsInstalled(engine) {
                            uninstalledState
                        } else if noMatches {
                            noMatchesState
                        } else {
                            installedSection
                            recommendedSection
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.never)
                .onChange(of: engine) { _, _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo(Self.scrollTopAnchor, anchor: .top)
                    }
                }
            }
        }
    }

    private var contextBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    engineIdentity
                    Spacer(minLength: 8)
                    folderLink
                }
                VStack(alignment: .leading, spacing: 6) {
                    engineIdentity
                    folderLink
                }
            }

            HStack(spacing: 8) {
                DSSearchField(
                    query: $query,
                    placeholder: L10n.format("在 %@ 中搜索模型", engine.displayName),
                    width: 220)

                sortMenu
                fitsToggle

                if isFiltering {
                    Button(L10n.t("清除筛选")) { clearFilters() }
                        .buttonStyle(.ds(.ghost, size: .small))
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var engineIdentity: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(engine.displayName)
                .font(DS.Font.lg.weight(.semibold))
                .foregroundStyle(DS.text)
                .lineLimit(1)

            engineStatusTag

            Text(verbatim: L10n.format("%lld 个已安装", Int64(installedAll.count)))
                .font(DS.Font.mono(10.5))
                .foregroundStyle(DS.text3)
                .monospacedDigit()
                .lineLimit(1)

            if !recommendedAll.isEmpty {
                Text(verbatim: "·")
                    .font(DS.Font.mono(10.5))
                    .foregroundStyle(DS.text3)
                Text(verbatim: L10n.format("%lld 个可下载", Int64(recommendedAll.count)))
                    .font(DS.Font.mono(10.5))
                    .foregroundStyle(DS.text3)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var engineStatusTag: some View {
        if !state.engineIsInstalled(engine) {
            Tag(text: L10n.t("未安装"), tone: .warning)
        } else if engine == state.activeEngine {
            Tag(text: L10n.t(state.isRunning ? "运行中" : "已停止"), tone: state.isRunning ? .success : .neutral)
        } else {
            Tag(text: L10n.t("已安装"), tone: .neutral)
        }
    }

    private var folderLink: some View {
        Button(action: revealModelFolder) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.text3)
                Text(verbatim: displayPath(EnginePaths.modelsDirectory(engine)))
                    .font(DS.Font.mono(10))
                    .foregroundStyle(DS.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.text3)
            }
            .frame(maxWidth: 340, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .help(L10n.format("在 Finder 中打开 %@", EnginePaths.modelsDirectory(engine)))
    }

    private var sortMenu: some View {
        DSMenu(kind: .icon, size: .regular) {
            DSMenuTriggerLabel(
                systemImage: "arrow.up.arrow.down",
                kind: .icon,
                size: .regular)
        } content: {
            ForEach(LibrarySort.allCases) { option in
                Button {
                    sortRaw = option.rawValue
                } label: {
                    if sort == option {
                        Label(L10n.t(option.label), systemImage: "checkmark")
                    } else {
                        Text(L10n.t(option.label))
                    }
                }
            }
        }
        .help(L10n.t("排序"))
        .accessibilityLabel(L10n.t("排序"))
    }

    private var fitsToggle: some View {
        Button {
            runnableOnly.toggle()
        } label: {
            Label(
                L10n.t("能跑"),
                systemImage: runnableOnly ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.ds(runnableOnly ? .primary : .secondary, size: .small))
        .help(L10n.t("只看本机内存能跑的模型"))
        .accessibilityLabel(L10n.t("只看本机内存能跑的模型"))
    }

    // MARK: - Sections

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: L10n.t("已安装"),
                count: filteredInstalled.count,
                caption: L10n.format(
                    "这些权重由 %@ 加载；点「使用」会切换到该引擎并加载它。",
                    engine.displayName))

            if filteredInstalled.isEmpty {
                installedEmpty
            } else {
                listSurface(filteredInstalled)
            }
        }
    }

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: L10n.t("推荐"),
                count: filteredRecommended.count,
                caption: recommendationCaption)

            if filteredRecommended.isEmpty {
                // 没有官方推荐、或者推荐都装好时，不摆一张重复的空卡：标题下的
                // 那句话已经解释了原因，页头的「模型广场」也仍是可走的下一步。
                if isFiltering {
                    emptyCard(
                        icon: "line.3.horizontal.decrease.circle",
                        title: L10n.t("当前筛选下没有推荐"),
                        detail: L10n.t("换一个搜索词，或关掉「能跑」再试。"),
                        actionTitle: L10n.t("清除筛选"),
                        action: clearFilters)
                }
            } else {
                listSurface(filteredRecommended)
            }
        }
    }

    private var recommendationCaption: String {
        guard hasRecommendationList else {
            return L10n.format(
                "%@ 不提供官方推荐；用模型广场下载的权重会存进这个目录。",
                engine.displayName)
        }
        if recommendedAll.isEmpty {
            return L10n.t("引擎自带的推荐档位都已经在本机，或不在本机内存范围内。")
        }
        switch engine {
        case .splash:
            return L10n.t("来自 Splash 引擎包；每个家族只列本机内存装得下的最高一档。")
        case .mtplx:
            return L10n.t("来自 MTPLX 官方目录；按本机芯片与内存筛选。")
        default:
            return L10n.t("来自引擎包自带的推荐目录。")
        }
    }

    private func sectionHeader(title: String, count: Int, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(title)
                    .font(DS.Font.prose(13, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text(verbatim: "\(count)")
                    .font(DS.Font.mono(10.5))
                    .foregroundStyle(DS.text3)
                    .monospacedDigit()
            }
            Text(caption)
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
                .fixedSize(horizontal: false, vertical: true)
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
                    DSDivider()
                        .padding(.leading, 46)
                }
            }
        }
        .dsSurface(radius: DS.Radius.lg)
        .clipShape(DS.rect(DS.Radius.lg))
    }

    // MARK: - Empty states

    private var installedEmpty: some View {
        Group {
            if isFiltering {
                emptyCard(
                    icon: "line.3.horizontal.decrease.circle",
                    title: L10n.t("当前筛选下没有已安装模型"),
                    detail: L10n.t("换一个搜索词，或关掉「能跑」再试。"),
                    actionTitle: L10n.t("清除筛选"),
                    action: clearFilters)
            } else {
                emptyCard(
                    icon: "internaldrive",
                    title: L10n.t("这个目录还没有模型"),
                    detail: recommendedAll.isEmpty
                        ? L10n.t("打开模型广场；下载时会让你选存到哪个引擎的目录。")
                        : L10n.t("从下面的推荐下载，或打开模型广场下载到这个引擎。"),
                    actionTitle: L10n.t("模型广场"),
                    action: openHub)
            }
        }
    }

    private func emptyCard(
        icon: String, title: String, detail: String,
        actionTitle: String?, action: (() -> Void)?
    ) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: icon, color: DS.text3, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DS.Font.sm.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text(detail)
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.ds(.secondary, size: .small))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(radius: DS.Radius.lg)
    }

    private var noMatchesState: some View {
        VStack(spacing: 14) {
            EmptyHint(
                icon: "magnifyingglass",
                title: L10n.t("没有匹配的模型"),
                detail: L10n.t("换个关键词，或清除筛选后再试。")
            )
            Button(L10n.t("清除筛选"), action: clearFilters)
                .buttonStyle(.ds(.secondary, size: .regular))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private var uninstalledState: some View {
        VStack(spacing: 14) {
            IconTile(symbol: engineSymbol(engine), color: engineAccent(engine), size: 44)
            Text(L10n.format("%@ 还没安装", engine.displayName))
                .font(DS.Font.md.weight(.semibold))
                .foregroundStyle(DS.text)
            Text(L10n.t("安装后，这里会显示它的模型目录，以及引擎包里自带的推荐档位。"))
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 8) {
                Button(L10n.t("安装引擎")) { state.requestEngineInstall(engine) }
                    .buttonStyle(.ds(.primary, size: .regular))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }

    // MARK: - Filtering

    private func filtered(_ entries: [ModelLibraryEntry]) -> [ModelLibraryEntry] {
        var result = entries
        if !queryText.isEmpty {
            let text = queryText.lowercased()
            result = result.filter { entry in
                let family = ModelFamily.resolve(
                    id: entry.model.id,
                    hint: entry.model.family,
                    tags: entry.recommendation?.tags ?? [])
                let tags = (entry.recommendation?.tags ?? []).joined(separator: " ")
                let summary = entry.recommendation?.summary ?? ""
                let quant = entry.model.quantization ?? ""
                let haystack =
                    "\(entry.model.shortName) \(entry.model.id) \(family.name) \(summary) \(tags) \(quant)"
                return haystack.lowercased().contains(text)
            }
        }
        if runnableOnly, device.memoryGB > 0 {
            result = result.filter {
                let required = modelRequiredMemoryGB($0)
                return required == 0 || required <= device.memoryGB
            }
        }

        switch sort {
        case .curated:
            return result.enumerated()
                .sorted { lhs, rhs in
                    let l = rank(lhs.element)
                    let r = rank(rhs.element)
                    return l == r ? lhs.offset < rhs.offset : l < r
                }
                .map(\.element)
        case .size:
            return result.sorted { lhs, rhs in
                sortByMetric(lhs, rhs, lhs.model.bytes, rhs.model.bytes)
            }
        case .memory:
            return result.sorted { lhs, rhs in
                sortByMetric(lhs, rhs, modelRequiredMemoryGB(lhs), modelRequiredMemoryGB(rhs))
            }
        case .name:
            return result.sorted {
                $0.model.shortName.localizedStandardCompare($1.model.shortName) == .orderedAscending
            }
        }
    }

    /// 未知值（0）排在最后；相等时按名称，避免每次刷新顺序乱跳。
    private func sortByMetric(
        _ lhs: ModelLibraryEntry, _ rhs: ModelLibraryEntry, _ l: Int, _ r: Int
    ) -> Bool {
        if l == 0 && r == 0 {
            return lhs.model.shortName.localizedStandardCompare(rhs.model.shortName)
                == .orderedAscending
        }
        if l == 0 { return false }
        if r == 0 { return true }
        if l == r {
            return lhs.model.shortName.localizedStandardCompare(rhs.model.shortName)
                == .orderedAscending
        }
        return l < r
    }

    private func rank(_ entry: ModelLibraryEntry) -> Int {
        if isSelected(entry) { return 0 }
        if entry.installed { return 1 }
        return 2
    }

    private func isSelected(_ entry: ModelLibraryEntry) -> Bool {
        entry.installed && entry.engine == state.activeEngine && entry.model.id == state.selectedModel
    }

    private func clearFilters() {
        query = ""
        runnableOnly = false
    }

    // MARK: - Actions

    private func openHub() {
        showingHub = true
        state.searchHub(
            state.hubQuery, sort: state.hubSort.rawValue,
            filter: state.hubFilter.rawValue, page: 0)
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
            state.toast(L10n.t("模型列表已刷新"))
        }
    }

    private func revealModelFolder() {
        let path = EnginePaths.modelsDirectory(engine)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: EnginePaths.modelsRoot))
        }
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var removalMessage: String {
        guard let entry = removeTarget else { return "" }
        if entry.model.path.isEmpty { return entry.model.id }
        return L10n.format("会删除 %@ 的权重，无法恢复。", entry.model.sizeText)
    }
}

// MARK: - Engine selector rows

private struct EngineRailRow: View {
    let engine: EngineID
    let installed: Bool
    let installedCount: Int
    let selected: Bool
    let active: Bool
    let running: Bool
    let action: () -> Void

    @State private var hovering = false

    private var accent: Color { engineAccent(engine) }

    private var statusText: String {
        guard installed else { return L10n.t("未安装") }
        if active { return L10n.t(running ? "运行中" : "已停止") }
        return L10n.t("已安装")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IconTile(symbol: engineSymbol(engine), color: accent, size: 26)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(engine.displayName)
                            .font(DS.Font.sm.weight(.semibold))
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                        if active {
                            Circle()
                                .fill(running ? DS.ok : DS.text3)
                                .frame(width: 5, height: 5)
                        }
                    }
                    Text(statusText)
                        .font(DS.Font.mono(10))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if installed {
                    Text(verbatim: "\(installedCount)")
                        .font(DS.Font.mono(10))
                        .foregroundStyle(DS.text3)
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(DS.rect(4).fill(DS.hover))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                DS.rect(DS.Radius.md)
                    .fill(selected ? accent.opacity(0.12) : (hovering ? DS.hover : .clear))
            }
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(accent)
                        .frame(width: 2, height: 22)
                        .padding(.leading, 1)
                }
            }
            .contentShape(DS.rect(DS.Radius.md))
        }
        .buttonStyle(.plainHit)
        .onHover { hovering = $0 }
        .help("\(engine.displayName) · \(statusText)")
    }
}

private struct EngineTabPill: View {
    let engine: EngineID
    let installed: Bool
    let installedCount: Int
    let selected: Bool
    let active: Bool
    let running: Bool
    let action: () -> Void

    private var accent: Color { engineAccent(engine) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: engineSymbol(engine))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(selected ? accent : DS.text2)
                Text(engine.displayName)
                    .font(DS.Font.sm.weight(selected ? .semibold : .medium))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                if active {
                    Circle()
                        .fill(running ? DS.ok : DS.text3)
                        .frame(width: 5, height: 5)
                }
                if installed {
                    Text(verbatim: "\(installedCount)")
                        .font(DS.Font.mono(10))
                        .foregroundStyle(DS.text3)
                        .monospacedDigit()
                } else {
                    Text(L10n.t("未安装"))
                        .font(DS.Font.mono(9.5))
                        .foregroundStyle(DS.text3)
                }
            }
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                DS.rect(DS.Radius.md)
                    .fill(selected ? accent.opacity(0.12) : DS.raised)
            }
            .overlay {
                DS.rect(DS.Radius.md)
                    .strokeBorder(selected ? accent.opacity(0.40) : DS.line, lineWidth: 1)
            }
            .contentShape(DS.rect(DS.Radius.md))
        }
        .buttonStyle(.plainHit)
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
    private var progressValue: Double? {
        if let activeFraction { return activeFraction }
        if let task { return task.fraction }
        return nil
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
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ModelFamilyIcon(family: family, size: 22)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(titleName)
                            .font(DS.Font.prose(13, weight: .medium))
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
                        if exceedsMemory {
                            Image(systemName: "memorychip")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(DS.warn)
                                .help(memoryText)
                                .accessibilityLabel(memoryText)
                        }
                    }
                    Text(metaLine)
                        .font(DS.Font.mono(10.5))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                action

                DSMenu(kind: .icon, size: .small) {
                    DSMenuTriggerLabel(systemImage: "ellipsis", kind: .icon, size: .small)
                        .opacity(hovering || selected ? 1 : 0.45)
                        .accessibilityLabel(L10n.t("更多操作"))
                } content: {
                    menuItems
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 52)

            if let progressValue {
                DSMeter(value: progressValue, tint: engineTint)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .background(selected ? engineTint.opacity(0.07) : (hovering ? DS.hover : .clear))
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(engineTint)
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
        Button(L10n.t("复制模型 ID")) { state.copy(model.id, label: L10n.t("模型 ID 已复制")) }
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

    private var metaLine: String {
        var parts: [String] = [quantizationLabel ?? formatName]
        if model.bytes > 0 { parts.append(model.sizeText) }
        if requiredMemoryGB > 0 { parts.append(memoryText) }
        return parts.joined(separator: " · ")
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

    private var formatName: String {
        if entry.engine == .mtplx { return "MTPLX" }
        let id = model.id.lowercased()
        if id.contains("gguf") || (entry.recommendation?.tags.contains("GGUF") ?? false) { return "GGUF" }
        if entry.engine == .omlx || entry.engine == .mlxServe { return "MLX" }
        return "GGUF"
    }

    private var engineTint: Color { engineAccent(entry.engine) }
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
                Label(
                    preparing
                        ? L10n.t("准备中…")
                        : L10n.format("下载 %@", fraction.formatted(.percent.precision(.fractionLength(0)))),
                    systemImage: "pause.fill")
            }
            .buttonStyle(.ds(.secondary, size: .small))
        } else if let task {
            let busy = state.downloadingModel != nil
            Button {
                state.resumeDownload(task)
            } label: {
                Label(
                    task.status == .paused
                        ? L10n.format("继续 %@", (task.fraction ?? 0).formatted(.percent.precision(.fractionLength(0))))
                        : L10n.t("重试"),
                    systemImage: "play.fill")
            }
            .buttonStyle(.ds(.secondary, size: .small))
            .disabled(busy)
            .help(
                busy
                    ? L10n.t("已有下载任务进行中，请稍候")
                    : L10n.t(task.status == .paused ? "继续下载" : "重试")
            )
        } else if entry.installed {
            if isSwitchingThis {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                    Text(L10n.t(state.switchStage.isEmpty ? "加载中" : state.switchStage))
                        .font(DS.Font.xs.weight(.medium))
                        .foregroundStyle(DS.warn)
                }
            } else if selected {
                DSChip(text: "使用中", dot: engineTint, live: true, tint: engineTint)
            } else {
                Button {
                    state.useModel(model.id, engine: entry.engine)
                } label: {
                    Text(L10n.t("使用"))
                }
                .buttonStyle(.ds(.secondary, size: .small))
                .disabled(state.isSwitchingModel)
            }
        } else {
            Button {
                state.downloadModel(model.id, engine: entry.engine)
            } label: {
                Label(L10n.t("下载"), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.ds(.secondary, size: .small))
            .disabled(state.downloadingModel != nil)
            .help(
                state.downloadingModel != nil
                    ? L10n.t("已有下载任务进行中，请稍候")
                    : L10n.format("下载到 %@ 的模型目录", entry.engine.displayName))
        }
    }
}

/// 一个模型需要的内存下限：目录推荐值与权重体积取较大者。「能跑」过滤、
/// 内存排序与行内徽标共用这一处口径。
private func modelRequiredMemoryGB(_ entry: ModelLibraryEntry) -> Int {
    let catalog = entry.recommendation?.minimumMemory ?? 0
    let weightsGB =
        entry.model.bytes > 0
        ? Int((Double(entry.model.bytes) / 1_000_000_000).rounded(.up))
        : 0
    return max(catalog, weightsGB)
}
