// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 模型页：本地库与推荐分成两种模式，各自按家族列出紧凑的变体行。
/// 默认只看本地库（已装权重）；没有下载的推荐不再和本地权重同格混排。
struct ModelsPage: View {
    @ObservedObject var state: AppState
    let engine: EngineID
    @Binding var showingHub: Bool
    @Binding var showingDownloads: Bool

    /// 本地库模式只列已落盘的权重；推荐模式只列尚未下载的精选条目。
    private enum LibraryMode: String, CaseIterable, Identifiable {
        case installed
        case recommended

        var id: String { rawValue }

        var label: String {
            switch self {
            case .installed: return "本地库"
            case .recommended: return "推荐"
            }
        }
    }

    private enum LibrarySort: String, CaseIterable, Identifiable {
        case curated
        case size
        case memory
        case name

        var id: String { rawValue }

        var label: String {
            switch self {
            case .curated: return "推荐顺序"
            case .size: return "体积"
            case .memory: return "内存下限"
            case .name: return "名称"
            }
        }
    }

    @State private var scope: ModelScope = .all
    @State private var mode: LibraryMode = .installed
    @State private var sort: LibrarySort = .curated
    @State private var runnableOnly = false
    @State private var query = ""
    @State private var removeTarget: ModelLibraryEntry?
    @State private var device = DeviceProfile.current()
    @State private var rescanning = false

    private static let scrollTopAnchor = "models.scroll.top"

    private var scopedEntries: [ModelLibraryEntry] {
        switch scope {
        case .all:
            return EngineCatalog.allIDs.flatMap { state.libraryEntries(for: $0) }
        case .engine(let id):
            return state.libraryEntries(for: id)
        }
    }

    private var entries: [ModelLibraryEntry] {
        let base = scopedEntries
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var filtered =
            text.isEmpty
            ? base
            : base.filter { entry in
                let tags = (entry.recommendation?.tags ?? []).joined(separator: " ")
                let summary = entry.recommendation?.summary ?? ""
                return "\(entry.model.shortName) \(entry.model.id) \(entry.engine.displayName) \(summary) \(tags)"
                    .lowercased()
                    .contains(text)
            }
        if runnableOnly, device.memoryGB > 0 {
            filtered = filtered.filter {
                let required = modelRequiredMemoryGB($0)
                return required == 0 || required <= device.memoryGB
            }
        }
        switch sort {
        case .curated:
            // 使用中的模型置顶，其次是已下载的，最后是待下载的；组内保持原顺序。
            return filtered.enumerated()
                .sorted { lhs, rhs in
                    let l = rank(lhs.element)
                    let r = rank(rhs.element)
                    return l == r ? lhs.offset < rhs.offset : l < r
                }
                .map(\.element)
        case .size:
            return filtered.sorted { lhs, rhs in
                sortByMetric(lhs, rhs, lhs.model.bytes, rhs.model.bytes)
            }
        case .memory:
            return filtered.sorted { lhs, rhs in
                sortByMetric(
                    lhs, rhs,
                    modelRequiredMemoryGB(lhs), modelRequiredMemoryGB(rhs))
            }
        case .name:
            return filtered.sorted {
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

    private var visibleEntries: [ModelLibraryEntry] {
        entries.filter { entry in
            switch mode {
            case .installed: return entry.installed
            case .recommended: return !entry.installed
            }
        }
    }

    private var downloadCount: Int {
        let pending = state.downloadTasks.filter { task in
            !(task.model == state.downloadingModel && task.engine == state.downloadingEngine)
        }.count
        return pending + (state.downloadingModel == nil ? 0 : 1)
    }

    /// 模式切换上的计数按引擎筛选算，不跟着搜索词跳动。
    private var installedEntries: [ModelLibraryEntry] {
        scopedEntries.filter(\.installed)
    }

    private var availableEntries: [ModelLibraryEntry] {
        scopedEntries.filter { !$0.installed }
    }

    private func rank(_ entry: ModelLibraryEntry) -> Int {
        if isSelected(entry) { return 0 }
        if entry.installed { return 1 }
        return 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSPageHeader(title: "模型库", subtitle: librarySummary) {
                actionControls
            }
            .padding(.leading, Console.topBarLeading(sidebarShown: state.showsSidebar))
            .padding(.trailing, Console.contentPadding)
            .padding(.top, Console.pageTopPadding)
            .padding(.bottom, 10)
            .background(WindowDragArea())

            filterRow
                .padding(.leading, Console.topBarLeading(sidebarShown: state.showsSidebar))
                .padding(.trailing, Console.contentPadding)
                .padding(.bottom, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Color.clear
                            .frame(height: 0)
                            .id(Self.scrollTopAnchor)

                        if mode == .installed, downloadCount > 0 {
                            downloadingBanner
                        }

                        ForEach(familyGroups) { group in
                            familySection(group)
                        }
                        if visibleEntries.isEmpty {
                            emptyState
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                        }
                    }
                    .padding(.horizontal, Console.contentPadding)
                    .padding(.top, 2)
                }
                .scrollIndicators(.never)
                .onChange(of: scope) { _, _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo(Self.scrollTopAnchor, anchor: .top)
                    }
                }
                .onChange(of: mode) { _, _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo(Self.scrollTopAnchor, anchor: .top)
                    }
                }
            }
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

    @ViewBuilder
    private var emptyState: some View {
        let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(spacing: 14) {
            if hasQuery {
                EmptyHint(
                    icon: "magnifyingglass",
                    title: "没有匹配的模型",
                    detail: "换个关键词，或切换引擎 / 本地库模式试试。"
                )
                Button(L10n.t("清除筛选")) { query = "" }
                    .buttonStyle(.ds(.secondary, size: .regular))
            } else if mode == .installed {
                EmptyHint(
                    icon: "square.stack.3d.up",
                    title: "还没有本地模型",
                    detail: "本地库只列已经落盘的权重；推荐里是还没下载的精选档位。"
                )
                HStack(spacing: 8) {
                    Button(L10n.t("看看推荐")) {
                        mode = .recommended
                    }
                    .buttonStyle(.ds(.primary, size: .regular))
                    Button(L10n.t("打开模型广场"), action: openHub)
                        .buttonStyle(.ds(.secondary, size: .regular))
                }
            } else {
                EmptyHint(
                    icon: "sparkle.magnifyingglass",
                    title: "没有待下载的推荐",
                    detail: "模型广场可以搜索 Hugging Face / ModelScope 的权重。"
                )
                Button(L10n.t("打开模型广场"), action: openHub)
                    .buttonStyle(.ds(.primary, size: .regular))
            }
        }
    }

    private var librarySummary: String {
        var parts = ["\(L10n.t("已安装")) \(installedEntries.count)"]
        let available = availableEntries.count
        if available > 0 { parts.append("\(L10n.t("未下载")) \(available)") }
        return parts.joined(separator: " · ")
    }

    /// 按家族聚合：同一个家族的不同量化并排放在一起，读者比较的是「哪一档
    /// 能在本机跑」，而不是在几十张同名卡片里认 `Q4_K_M` 和 `oQ4e`。
    /// 家族顺序沿用已排好序的条目（使用中的模型所在家族自然排在最前）。
    private var familyGroups: [FamilyGroup] {
        var order: [ModelFamily] = []
        var buckets: [ModelFamily: [ModelLibraryEntry]] = [:]
        for entry in visibleEntries {
            let family = ModelFamily.resolve(
                id: entry.model.id,
                hint: entry.model.family,
                tags: entry.recommendation?.tags ?? [])
            if buckets[family] == nil { order.append(family) }
            buckets[family, default: []].append(entry)
        }
        return order.map { FamilyGroup(family: $0, entries: buckets[$0] ?? []) }
    }

    @ViewBuilder
    private func familySection(_ group: FamilyGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ModelFamilyIcon(family: group.family, size: 18)
                Text(verbatim: group.family.name)
                    .font(DS.Font.prose(13, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text(verbatim: "\(group.entries.count)")
                    .font(DS.Font.mono(10.5))
                    .foregroundStyle(DS.text3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)

            VStack(spacing: 0) {
                ForEach(Array(group.entries.enumerated()), id: \.element.identity) { index, entry in
                    ModelRow(
                        state: state,
                        entry: entry,
                        selected: isSelected(entry),
                        device: device,
                        remove: { removeTarget = entry })
                    if index != group.entries.count - 1 {
                        DSDivider()
                            .padding(.leading, 12)
                    }
                }
            }
            .dsSurface(radius: DS.Radius.lg)
            .clipShape(DS.rect(DS.Radius.lg))
        }
    }

    /// 一行放得下时把模式、引擎、排序与搜索并排；窄窗口折成两行。
    private var filterRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                modeControl
                engineFilter
                sortMenu
                runnableToggle
                DSSearchField(query: $query, placeholder: "搜索模型", width: 180)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    modeControl
                    engineMenu
                }
                HStack(spacing: 8) {
                    sortMenu
                    runnableToggle
                    DSSearchField(query: $query, placeholder: "搜索模型", width: 180)
                }
            }
        }
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
                    sort = option
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

    private var runnableToggle: some View {
        Button {
            runnableOnly.toggle()
        } label: {
            Label(
                "能跑",
                systemImage: runnableOnly ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.ds(runnableOnly ? .primary : .secondary, size: .small))
        .help(L10n.t("只看本机内存能跑的模型"))
        .accessibilityLabel(L10n.t("只看本机内存能跑的模型"))
    }

    /// 下载中的条目属于「推荐」模式，停在本地库的人看不到进度；给一条常驻入口。
    private var downloadingBanner: some View {
        Button {
            showingDownloads = true
        } label: {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                Text(L10n.format("正在下载 %lld 项", Int64(downloadCount)))
                    .font(DS.Font.prose(12))
                    .foregroundStyle(DS.text2)
                Spacer(minLength: 8)
                Text(L10n.t("查看"))
                    .font(DS.Font.prose(11.5, weight: .medium))
                    .foregroundStyle(DS.text2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.text3)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(DS.rect(DS.Radius.md).fill(DS.raised))
            .overlay(DS.rect(DS.Radius.md).strokeBorder(DS.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var modeControl: some View {
        DSSegmented(
            selection: $mode,
            options: [
                (.installed, "\(L10n.t("本地库")) \(installedEntries.count)"),
                (.recommended, "\(L10n.t("推荐")) \(availableEntries.count)"),
            ])
    }

    private var engineFilter: some View {
        DSSegmented(
            selection: $scope,
            options: [(ModelScope.all, "全部")]
                + EngineCatalog.allIDs.map { (ModelScope.engine($0), $0.displayName) })
    }

    /// 窄窗口下的引擎筛选：分段控件会把 `Splash / oMLX / MTPLX…` 压成
    /// `Sp… / o… / M…`，换成下拉菜单，菜单里始终是完整名字。
    private var engineMenu: some View {
        DSMenu(size: .regular) {
            DSMenuTriggerLabel(
                title: scope.engine?.displayName ?? L10n.t("全部引擎"),
                systemImage: "cpu",
                kind: .secondary,
                size: .regular)
        } content: {
            Button {
                scope = .all
            } label: {
                if scope == .all {
                    Label(L10n.t("全部引擎"), systemImage: "checkmark")
                } else {
                    Text(L10n.t("全部引擎"))
                }
            }
            Divider()
            ForEach(EngineCatalog.allIDs, id: \.self) { id in
                Button {
                    scope = .engine(id)
                } label: {
                    if scope == .engine(id) {
                        Label(id.displayName, systemImage: "checkmark")
                    } else {
                        Text(id.displayName)
                    }
                }
            }
        }
        .help(L10n.t("按引擎筛选"))
        .accessibilityLabel(L10n.t("按引擎筛选"))
    }

    @ViewBuilder
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
                help: rescanning ? "正在扫描…" : "重新扫描",
                style: .outlined
            ) {
                guard !rescanning else { return }
                rescanning = true
                let target = scope.engine ?? engine
                _ = EngineModelStore.adoptExistingWeights(target)
                state.reloadModels()
                Task { @MainActor in
                    defer { rescanning = false }
                    await state.engines?.controller(target)?.rescanModels()
                    state.reloadModels()
                    state.toast(L10n.t("模型列表已刷新"))
                }
            }
            .disabled(rescanning)
        }
    }

    private func openHub() {
        state.libraryEngine = scope.engine ?? engine
        showingHub = true
        state.searchHub(
            state.hubQuery, sort: state.hubSort.rawValue,
            filter: state.hubFilter.rawValue, page: 0)
    }

    private func isSelected(_ entry: ModelLibraryEntry) -> Bool {
        entry.installed && entry.engine == state.activeEngine && entry.model.id == state.selectedModel
    }

    private var removalMessage: String {
        guard let entry = removeTarget else { return "" }
        if entry.model.path.isEmpty { return entry.model.id }
        return L10n.format("会删除 %@ 的权重，无法恢复。", entry.model.sizeText)
    }
}

// MARK: - Card

private struct ModelRow: View {
    @ObservedObject var state: AppState
    let entry: ModelLibraryEntry
    let selected: Bool
    let device: DeviceProfile
    let remove: () -> Void

    @State private var hovering = false

    private var model: ModelInfo { entry.model }
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
                    HStack(spacing: 6) {
                        Text(metaLine)
                            .font(DS.Font.mono(10.5))
                            .foregroundStyle(DS.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(L10n.t(entry.source == .recommended ? "推荐" : "个人下载"))
                            .font(DS.Font.mono(10))
                            .foregroundStyle(DS.text2)
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background(DS.rect(4).fill(DS.hover))
                            .fixedSize()
                    }
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
            .frame(minHeight: 46)

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

    private var displayTitle: String {
        model.shortName
    }

    private var titleName: String {
        let title = displayTitle
        guard let colon = title.lastIndex(of: ":") else { return title }
        let name = String(title[title.startIndex..<colon])
        let variant = String(title[title.index(after: colon)...])
        guard !name.isEmpty, !variant.isEmpty, variant.count <= 16 else { return title }
        return name
    }

    private var titleHelp: String {
        if let summary = entry.recommendation?.summary, !summary.isEmpty {
            return "\(model.id)\n\(summary)"
        }
        return model.id
    }

    private var metaLine: String {
        var parts = [entry.engine.displayName, quantizationLabel ?? formatName]
        if model.bytes > 0 {
            parts.append(model.sizeText)
        }
        if requiredMemoryGB > 0 {
            parts.append(memoryText)
        }
        return parts.joined(separator: " · ")
    }

    private var quantizationLabel: String? {
        if let quant = model.quantization, !quant.isEmpty { return quant }
        if let variant = entry.recommendation?.variant,
            let quant = ModelQuantization.detect(in: variant)
        {
            return quant
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

    /// 选中的卡片用引擎色而不是通用蓝：同一份权重可能由多台引擎驱动，
    /// 颜色要回答「它属于谁」，不是「它被选中了」。
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
            .help(state.downloadingModel != nil ? L10n.t("已有下载任务进行中，请稍候") : L10n.t("下载模型"))
        }
    }
}

enum ModelScope: Hashable {
    case all
    case engine(EngineID)

    var engine: EngineID? {
        if case .engine(let id) = self { return id }
        return nil
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

/// 模型页的一个家族分组。家族内部保留原有排序（使用中 → 已安装 → 待下载）。
private struct FamilyGroup: Identifiable {
    let family: ModelFamily
    let entries: [ModelLibraryEntry]

    var id: String { family.rawValue }
}
