// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 模型库：一列引擎目录 + 一列当前引擎的权重目录。
///
/// 页面按新版 Liquid Glass 高保真重排：左列是贴着窗口边缘的引擎栏，底部钉一张
/// 本地存储卡；右列把「引擎身份 → 搜索/排序 → 已安装 → 推荐」收进同一条滚动流，
/// 每一条权重都是玻璃卡里的一行，行内动作统一成胶囊按钮。
///
/// 浏览与操作的口径保持不变：换引擎只换右列内容，搜索词与「能跑」筛选跨引擎保留；
/// 已安装与推荐共用一套筛选、排序与下载状态，后台换引擎也不会让页面跳骨架。
struct ModelsPage: View {
    @ObservedObject var state: AppState
    @Binding var showingHub: Bool
    @Binding var showingDownloads: Bool

    private enum LibrarySort: String, CaseIterable, Identifiable {
        case curated
        case sizeAscending = "size"
        case sizeDescending = "sizeDesc"
        case memory
        case name

        var id: String { rawValue }

        var label: String {
            switch self {
            case .curated: return "默认排序"
            case .sizeAscending: return "体积从小到大"
            case .sizeDescending: return "体积从大到小"
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
    @State private var disk = DiskSpace.current()
    @State private var rescanning = false

    private static let scrollTopAnchor = "models.scroll.top"
    private static let railWidth: CGFloat = 206

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
    private var countsSummary: String {
        var parts = [L10n.format("%lld 个已安装", Int64(installedAll.count))]
        if !recommendedAll.isEmpty {
            parts.append(L10n.format("%lld 个可下载", Int64(recommendedAll.count)))
        }
        return parts.joined(separator: " · ")
    }
    /// 全部引擎已落盘的权重，供左列底部的本地存储卡使用。
    private var storageUsage: (count: Int, bytes: Int) {
        var count = 0
        var bytes = 0
        for id in EngineCatalog.allIDs {
            for entry in state.libraryEntries(for: id) where entry.installed {
                count += 1
                bytes += entry.model.bytes
            }
        }
        return (count, bytes)
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
        GeometryReader { proxy in
            let wide = proxy.size.width >= Console.compactContentWidth
            VStack(alignment: .leading, spacing: 0) {
                header

                if wide {
                    HStack(alignment: .top, spacing: 0) {
                        engineRail
                            .frame(width: Self.railWidth)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .background(DS.bg)
                            .overlay(alignment: .trailing) {
                                Rectangle()
                                    .fill(DS.line)
                                    .frame(width: 1)
                            }
                        contentPane
                            .padding(.leading, 20)
                            .padding(.trailing, Console.contentPadding)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        engineTabs
                            .padding(.horizontal, Console.contentPadding)
                        DSDivider()
                        contentPane
                            .padding(.horizontal, Console.contentPadding)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .dsPageColumn()
        .onAppear { disk = .current() }
        .onChange(of: state.downloadTasks.count) { _, _ in
            disk = .current()
        }
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
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DS.line)
                .frame(height: 1)
        }
    }

    private var actionControls: some View {
        HStack(spacing: 8) {
            Button {
                showingDownloads = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11.5, weight: .semibold))
                        .opacity(0.8)
                    Text(L10n.t("下载中心"))
                    if downloadCount > 0 {
                        DSBadge(count: downloadCount)
                    }
                }
            }
            .buttonStyle(PillButtonStyle(height: 30))
            .help(L10n.t("下载中心"))

            Button(action: openHub) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5, weight: .semibold))
                        .opacity(0.8)
                    Text(L10n.t("模型广场"))
                }
            }
            .buttonStyle(PillButtonStyle(height: 30))

            CircleGlassButton(
                systemName: "arrow.clockwise",
                help: rescanning ? L10n.t("正在扫描…") : L10n.t("重新扫描这个引擎的模型目录"),
                spinning: rescanning
            ) {
                rescan()
            }
            .disabled(rescanning || !state.engineIsInstalled(engine))
        }
    }

    // MARK: - Engine rail

    private var engineRail: some View {
        let usage = storageUsage
        return VStack(alignment: .leading, spacing: 0) {
            Text(L10n.t("引擎目录"))
                .font(DS.Font.prose(11, weight: .semibold))
                .foregroundStyle(DS.text3)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 4) {
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
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)

            StorageSummaryCard(
                count: usage.count,
                bytes: usage.bytes,
                disk: disk
            )
            .padding(12)
        }
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

                    engineHeader
                    toolbar

                    if noMatches {
                        noMatchesState
                    } else {
                        installedSection
                        recommendedSection
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
            .onChange(of: engine) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo(Self.scrollTopAnchor, anchor: .top)
                }
            }
        }
    }

    private var engineHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                engineIdentity
                Spacer(minLength: 8)
                pathChip
            }
            VStack(alignment: .leading, spacing: 8) {
                engineIdentity
                pathChip
            }
        }
    }

    private var engineIdentity: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(engine.displayName)
                .font(DS.Font.prose(17, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(DS.text)
                .lineLimit(1)

            engineStatusPill

            Text(verbatim: countsSummary)
                .font(DS.Font.mono(11.5))
                .foregroundStyle(DS.text3)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var engineStatusPill: some View {
        if !state.engineIsInstalled(engine) {
            DSChip(text: L10n.t("未安装"), dot: DS.warn, tint: DS.warn)
        } else if engine == state.activeEngine {
            DSChip(
                text: L10n.t(state.isRunning ? "运行中" : "已停止"),
                dot: state.isRunning ? DS.ok : DS.text4,
                live: state.isRunning,
                tint: state.isRunning ? DS.ok : nil)
        } else {
            DSChip(text: L10n.t("已安装"), dot: DS.text4)
        }
    }

    /// 模型目录路径：点路径复制，尾部箭头在访达中打开。
    private var pathChip: some View {
        let path = EnginePaths.modelsDirectory(engine)
        return HStack(spacing: 2) {
            Button {
                state.copy(path, label: L10n.t("模型目录路径已复制"))
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DS.text3)
                    Text(verbatim: displayPath(path))
                        .font(DS.Font.mono(11))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)
            .help(L10n.t("复制路径"))

            Button(action: revealModelFolder) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(DS.text3)
                    .frame(width: 22, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)
            .help(L10n.format("在 Finder 中打开 %@", path))
            .accessibilityLabel(L10n.t("在 Finder 中显示"))
            .padding(.trailing, 4)
        }
        .background(Capsule().fill(DS.pillFill))
        .overlay(Capsule().strokeBorder(DS.pillBorder, lineWidth: 1))
        .frame(maxWidth: 460)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ModelsSearchField(
                query: $query,
                placeholder: L10n.format("在 %@ 中搜索模型", engine.displayName))
                .frame(minWidth: 150, idealWidth: 230, maxWidth: 260)

            PillMenu(title: L10n.t(sort.label), systemImage: "arrow.up.arrow.down") {
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

            FitsPill(active: runnableOnly, memoryGB: device.memoryGB) {
                runnableOnly.toggle()
            }
            .help(L10n.t("只看本机内存能跑的模型"))

            Spacer(minLength: 0)
        }
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
                if isFiltering {
                    emptyRow(L10n.t("没有匹配当前筛选条件的已安装模型"))
                } else {
                    installedEmpty
                }
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
                    emptyRow(L10n.t("没有匹配当前筛选条件的推荐模型"))
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
            HStack(spacing: 6) {
                Text(title)
                    .font(DS.Font.prose(13.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text(verbatim: "\(count)")
                    .font(DS.Font.mono(11.5))
                    .foregroundStyle(DS.text3)
                    .monospacedDigit()
            }
            Text(caption)
                .font(DS.Font.prose(11.5))
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
                    Rectangle()
                        .fill(DS.line)
                        .frame(height: 1)
                }
            }
        }
        .clipShape(DS.rect(DS.Radius.card))
        .dsSurface(radius: DS.Radius.card)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.prose(12))
            .foregroundStyle(DS.text3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .dsSurface(radius: DS.Radius.card)
    }

    // MARK: - Empty states

    private var installedEmpty: some View {
        emptyCard(
            icon: "internaldrive",
            title: L10n.t("这个目录还没有模型"),
            detail: recommendedAll.isEmpty
                ? L10n.t("打开模型广场；下载时会让你选存到哪个引擎的目录。")
                : L10n.t("从下面的推荐下载，或打开模型广场下载到这个引擎。"),
            actionTitle: L10n.t("模型广场"),
            action: openHub)
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
                    .buttonStyle(PillButtonStyle(height: 26, horizontalPadding: 10))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(radius: DS.Radius.card)
    }

    private var noMatchesState: some View {
        VStack(spacing: 14) {
            EmptyHint(
                icon: "magnifyingglass",
                title: L10n.t("没有匹配的模型"),
                detail: L10n.t("换个关键词，或清除筛选后再试。")
            )
            Button(L10n.t("清除筛选"), action: clearFilters)
                .buttonStyle(PillButtonStyle(height: 30))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private var uninstalledState: some View {
        VStack(spacing: 14) {
            EngineBadge(engine: engine, size: 56)
            Text(L10n.format("%@ 引擎尚未安装", engine.displayName))
                .font(DS.Font.prose(16, weight: .semibold))
                .foregroundStyle(DS.text)
            Text(
                L10n.format(
                    "安装 %@ 后即可浏览并下载对应格式的 Apple Silicon 量化权重模型。",
                    engine.displayName)
            )
            .font(DS.Font.prose(12.5))
            .foregroundStyle(DS.text3)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 380)

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
        case .sizeAscending:
            return result.sorted { lhs, rhs in
                sortByMetric(lhs, rhs, lhs.model.bytes, rhs.model.bytes)
            }
        case .sizeDescending:
            return result.sorted { lhs, rhs in
                sortByMetric(lhs, rhs, lhs.model.bytes, rhs.model.bytes, descending: true)
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
        _ lhs: ModelLibraryEntry, _ rhs: ModelLibraryEntry, _ l: Int, _ r: Int,
        descending: Bool = false
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
        return descending ? l > r : l < r
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
            disk = .current()
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var statusText: String {
        guard installed else { return L10n.t("未安装") }
        if active { return L10n.t(running ? "运行中" : "已停止") }
        return L10n.t("已安装")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                EngineBadge(engine: engine, size: 32)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(engine.displayName)
                            .font(DS.Font.prose(13, weight: .semibold))
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                        if active {
                            DSStatusDot(
                                color: running ? DS.ok : DS.text4,
                                live: running,
                                size: 5)
                        }
                    }
                    Text(statusText)
                        .font(DS.Font.mono(10.5))
                        .foregroundStyle(running ? DS.ok : DS.text3)
                        .lineLimit(1)
                }

                Spacer(minLength: 2)

                if installed, installedCount > 0 {
                    Text(verbatim: "\(installedCount)")
                        .font(DS.Font.mono(10.5, weight: .semibold))
                        .foregroundStyle(selected ? DS.accent : DS.text3)
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(
                            Capsule().fill(selected ? DS.accent.opacity(0.16) : DS.pillFill)
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                selected ? DS.accent.opacity(0.25) : DS.pillBorder,
                                lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    DS.rect(14)
                        .fill(DS.accentSoft)
                        .shadow(color: DS.accent.opacity(0.14), radius: 7, y: 2)
                } else if hovering {
                    DS.rect(14).fill(DS.hover)
                }
            }
            .overlay {
                if selected {
                    DS.rect(14).strokeBorder(DS.accent.opacity(0.30), lineWidth: 1)
                }
            }
            .contentShape(DS.rect(14))
        }
        .buttonStyle(.plainHit)
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
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

    @State private var hovering = false

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
                if active {
                    Circle()
                        .fill(running ? DS.ok : DS.text3)
                        .frame(width: 5, height: 5)
                }
                if installed, installedCount > 0 {
                    Text(verbatim: "\(installedCount)")
                        .font(DS.Font.mono(9.5))
                        .foregroundStyle(selected ? DS.accent : DS.text3)
                        .monospacedDigit()
                } else if !installed {
                    Text(L10n.t("未安装"))
                        .font(DS.Font.mono(9.5))
                        .foregroundStyle(DS.text3)
                }
            }
            .fixedSize()
            .padding(.horizontal, 11)
            .frame(height: 30)
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
                        selected ? accent.opacity(0.34) : DS.pillBorder,
                        lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plainHit)
        .onHover { hovering = $0 }
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
        .overlay(alignment: .leading) {
            if selected {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 3,
                    topTrailingRadius: 3,
                    style: .continuous)
                .fill(DS.accent)
                .frame(width: 3)
                .padding(.vertical, 10)
            }
        }
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

    /// 一行元信息：量化档位（玻璃小胶囊）· 体积 · 内存下限（超出本机时标红）。
    private var metaRow: some View {
        HStack(spacing: 5) {
            Text(verbatim: quantChipLabel)
                .font(DS.Font.mono(10, weight: .medium))
                .foregroundStyle(DS.text2)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(DS.rect(4).fill(DS.pillFill))
                .overlay(DS.rect(4).strokeBorder(DS.line, lineWidth: 1))

            separatorDot

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

    private var quantChipLabel: String {
        quantizationLabel ?? formatName
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
                .overlay(Capsule().strokeBorder(DS.warn.opacity(0.24), lineWidth: 1))
            } else if selected {
                HStack(spacing: 5) {
                    DSStatusDot(color: DS.accent, live: true, size: 5)
                    Text(L10n.t("使用中"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.accent)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(DS.accent.opacity(0.14)))
                .overlay(Capsule().strokeBorder(DS.accent.opacity(0.30), lineWidth: 1))
            } else {
                Button {
                    state.useModel(model.id, engine: entry.engine)
                } label: {
                    Text(L10n.t("使用"))
                }
                .buttonStyle(PillButtonStyle(height: 26, horizontalPadding: 12, fontSize: 12))
                .disabled(state.isSwitchingModel)
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
        .overlay(Capsule().strokeBorder(DS.successStroke, lineWidth: 1))
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

// MARK: - Storage summary

private struct DiskSpace: Equatable {
    var totalBytes: Int
    var availableBytes: Int

    static func current() -> DiskSpace {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard
            let values = try? url.resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ])
        else { return DiskSpace(totalBytes: 0, availableBytes: 0) }
        return DiskSpace(
            totalBytes: values.volumeTotalCapacity ?? 0,
            availableBytes: Int(values.volumeAvailableCapacityForImportantUsage ?? 0))
    }
}

/// 引擎栏底部的本地存储卡：所有引擎已落盘的权重 + 本机磁盘容量。
private struct StorageSummaryCard: View {
    let count: Int
    let bytes: Int
    let disk: DiskSpace

    private var fraction: Double {
        guard disk.totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(disk.totalBytes)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L10n.t("本地存储"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.text3)
                Spacer(minLength: 4)
                Text(verbatim: L10n.format("%lld 个权重", Int64(count)))
                    .font(DS.Font.mono(10.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: sizeText(bytes))
                    .font(DS.Font.mono(14, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Text(L10n.t("已占用"))
                    .font(.system(size: 10))
                    .foregroundStyle(DS.text3)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.line2)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [DS.accent, DS.accentBlue],
                                startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(3, proxy.size.width * fraction))
                }
            }
            .frame(height: 5)

            HStack(spacing: 4) {
                Text(verbatim: "SSD " + wholeGBText(disk.totalBytes))
                Spacer(minLength: 4)
                Text(verbatim: L10n.format("可用 %@", sizeText(disk.availableBytes)))
            }
            .font(DS.Font.mono(9.5))
            .foregroundStyle(DS.text4)
            .lineLimit(1)
        }
        .padding(12)
        .dsSurface(radius: DS.Radius.card)
    }

    private func sizeText(_ value: Int) -> String {
        value > 0 ? Format.size(value) : "0 GB"
    }

    private func wholeGBText(_ value: Int) -> String {
        value > 0
            ? String(format: "%.0f GB", Double(value) / 1_000_000_000)
            : "—"
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
            DS.rect(radius).strokeBorder(color.opacity(0.26), lineWidth: 1)
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
        case .glass: return activeHover ? DS.line3 : DS.pillBorder
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
            .shadow(color: DS.accent.opacity(0.28), radius: 8, y: 3)
            .contentShape(Capsule())
            .scaleEffect((!reduceMotion && configuration.isPressed && isEnabled) ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(reduceMotion ? nil : DS.Motion.snappy, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

private struct CircleGlassButton: View {
    var systemName: String
    var help: String
    var size: CGFloat = 30
    var spinning: Bool = false
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(hovering && isEnabled ? DS.text : DS.text2)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(
                    spinning
                        ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                        : .easeOut(duration: 0.2),
                    value: spinning
                )
                .frame(width: size, height: size)
                .background(Circle().fill(hovering && isEnabled ? DS.raised : DS.pillFill))
                .overlay(Circle().strokeBorder(DS.pillBorder, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(DSPressStyle(scale: 0.94))
        .opacity(isEnabled ? 1 : 0.4)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

/// 胶囊下拉触发器：图标 + 当前值，点击展开完整选项。
private struct PillMenu<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DS.text3)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(hovering ? DS.raised : DS.pillFill))
            .overlay(Capsule().strokeBorder(DS.pillBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

/// 「能跑」筛选：勾选态是强调色胶囊，右侧常驻本机内存上限。
private struct FitsPill: View {
    var active: Bool
    var memoryGB: Int
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .strokeBorder(active ? DS.accent : DS.text4, lineWidth: 1.25)
                    if active {
                        Circle().fill(DS.accent)
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .black))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 14, height: 14)

                Text(L10n.t("能跑"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? DS.accent : DS.text2)

                if memoryGB > 0 {
                    Text(verbatim: "≤\(memoryGB)G")
                        .font(DS.Font.mono(10))
                        .foregroundStyle((active ? DS.accent : DS.text3).opacity(0.8))
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background {
                Capsule()
                    .fill(
                        active
                            ? DS.accent.opacity(hovering ? 0.20 : 0.15)
                            : (hovering ? DS.raised : DS.pillFill))
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        active ? DS.accent.opacity(0.32) : DS.pillBorder,
                        lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(DSPressStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// 胶囊搜索框：与工具栏其他控件同高同圆角，聚焦时点亮强调色描边。
private struct ModelsSearchField: View {
    @Binding var query: String
    var placeholder: String

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(focused ? DS.accent : DS.text3)

            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(DS.Font.prose(12))
                .foregroundStyle(DS.text)
                .focused($focused)
                .onExitCommand {
                    query = ""
                    focused = false
                }
                .onSubmit { focused = false }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.text3)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plainHit)
                .help(L10n.t("清除搜索"))
                .accessibilityLabel(L10n.t("清除搜索"))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(DS.bg))
        .overlay(
            Capsule().strokeBorder(
                focused ? DS.accent.opacity(0.60) : DS.line2,
                lineWidth: 1)
        )
        .overlay(
            Capsule()
                .strokeBorder(focused ? DS.accent.opacity(0.14) : .clear, lineWidth: 3)
                .padding(-1)
        )
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .animation(DS.Motion.snappy, value: focused)
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
                .overlay(Circle().strokeBorder(DS.pillBorder, lineWidth: 1))
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
