// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatKit
import SwiftUI

/// 模型页：单行筛选操作栏 + ZCode 风格实色卡片网格。
struct ModelsPage: View {
    @ObservedObject var state: AppState
    let engine: EngineID
    @Binding var showingHub: Bool
    @Binding var showingDownloads: Bool

    @State private var scope: ModelScope = .all
    @State private var query = ""
    @State private var removeTarget: ModelLibraryEntry?
    @State private var device = DeviceProfile.current()
    @State private var gridColumns = 0
    @State private var rescanning = false

    private static let scrollTopAnchor = "models.scroll.top"
    private static let cardMinWidth: CGFloat = 320
    private static let cardSpacing: CGFloat = 12

    private var entries: [ModelLibraryEntry] {
        let base: [ModelLibraryEntry]
        switch scope {
        case .all:
            base = EngineCatalog.allIDs.flatMap { state.libraryEntries(for: $0) }
        case .engine(let id):
            base = state.libraryEntries(for: id)
        }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered =
            text.isEmpty
            ? base
            : base.filter { entry in
                let tags = (entry.recommendation?.tags ?? []).joined(separator: " ")
                let summary = entry.recommendation?.summary ?? ""
                return "\(entry.model.shortName) \(entry.model.id) \(entry.engine.displayName) \(summary) \(tags)"
                    .lowercased()
                    .contains(text)
            }
        // 使用中的模型置顶，其次是已下载的，最后是待下载的；组内保持原顺序。
        return filtered.enumerated()
            .sorted { lhs, rhs in
                let l = rank(lhs.element)
                let r = rank(rhs.element)
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

    private var installedEntries: [ModelLibraryEntry] {
        entries.filter(\.installed)
    }

    private var availableEntries: [ModelLibraryEntry] {
        entries.filter { !$0.installed }
    }

    private func rank(_ entry: ModelLibraryEntry) -> Int {
        if isSelected(entry) { return 0 }
        if entry.installed { return 1 }
        return 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
                .padding(.top, Console.pageTopPadding)
                .padding(.bottom, 12)
                .background(WindowDragArea())

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Color.clear
                            .frame(height: 0)
                            .id(Self.scrollTopAnchor)

                        let installed = installedEntries
                        let available = availableEntries
                        let splitSections = !installed.isEmpty && !available.isEmpty

                        if !installed.isEmpty {
                            modelSection(title: splitSections ? "已安装" : nil, items: installed)
                        }
                        if !available.isEmpty {
                            modelSection(title: splitSections ? "未下载" : nil, items: available)
                        }
                        if entries.isEmpty {
                            emptyState
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                        }
                    }
                    .padding(.horizontal, Console.contentPadding)
                    .padding(.top, 2)
                }
                .scrollIndicators(.never)
                .dsTrackColumns($gridColumns, minWidth: Self.cardMinWidth, spacing: Self.cardSpacing)
                .onChange(of: scope) { _, _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo(Self.scrollTopAnchor, anchor: .top)
                    }
                }
            }
        }
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
                    detail: "换个关键词或切换引擎筛选试试。"
                )
                Button(L10n.t("清除筛选")) { query = "" }
                    .buttonStyle(.ds(.secondary, size: .regular))
            } else {
                EmptyHint(
                    icon: "square.stack.3d.up",
                    title: "还没有本地模型",
                    detail: "可以从模型广场浏览 Hugging Face / ModelScope 权重并下载。"
                )
                Button(L10n.t("打开模型广场"), action: openHub)
                    .buttonStyle(.ds(.primary, size: .regular))
            }
        }
    }

    @ViewBuilder
    private func modelSection(title: String?, items: [ModelLibraryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    Text(L10n.t(title))
                        .font(DS.Font.xs.weight(.medium))
                        .foregroundStyle(DS.text3)
                    Text("\(items.count)")
                        .font(DS.Font.mono(10.5))
                        .foregroundStyle(DS.text3)
                }
                .padding(.horizontal, 2)
            }
            DSAnimatedGrid(
                columns: gridColumns,
                minWidth: Self.cardMinWidth,
                maxWidth: 540,
                spacing: Self.cardSpacing
            ) {
                ForEach(items, id: \.identity) { entry in
                    ModelCard(
                        state: state,
                        entry: entry,
                        selected: isSelected(entry),
                        device: device,
                        remove: { removeTarget = entry })
                }
            }
        }
    }

    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                filterControl
                Spacer(minLength: 0)
                actionControls
            }
            .frame(height: DS.Layout.titlebarHeight)
            .padding(.leading, Console.topBarLeading(sidebarShown: state.showsSidebar))
            .padding(.trailing, Console.contentPadding)

            VStack(alignment: .leading, spacing: 10) {
                filterControl
                    .frame(height: DS.Layout.titlebarHeight)
                    .padding(.leading, Console.topBarLeading(sidebarShown: state.showsSidebar))
                    .padding(.trailing, Console.contentPadding)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    actionControls
                }
                .padding(.horizontal, Console.contentPadding)
            }
        }
    }

    private var filterControl: some View {
        DSFilterBar(
            selection: $scope,
            options: [(ModelScope.all, "全部")]
                + EngineCatalog.allIDs.map { (ModelScope.engine($0), $0.displayName) },
            query: $query,
            placeholder: "搜索模型",
            maxSearchWidth: 160)
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

private struct ModelCard: View {
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
        VStack(alignment: .leading, spacing: 12) {
            header

            if let progressValue {
                DSMeter(value: progressValue, tint: DS.accent)
            }

            footer
        }
        .padding(14)
        .dsSurface(
            radius: DS.Radius.lg,
            stroke: selected ? DS.accent.opacity(0.45) : nil,
            hoverable: true,
            active: selected
        )
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

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ModelFamilyIcon(family: family, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(titleName)
                        .font(DS.Font.md.weight(.semibold))
                        .tracking(-0.15)
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(titleHelp)
                    if let capability = capabilityBadge {
                        Image(systemName: capability.symbol)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(DS.text3)
                            .help(L10n.t(capability.help))
                            .accessibilityLabel(L10n.t(capability.help))
                    }
                }
                Text(metaLine)
                    .font(DS.Font.mono(11))
                    .foregroundStyle(DS.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            DSMenu(kind: .icon, size: .small) {
                DSMenuTriggerLabel(systemImage: "ellipsis", kind: .icon, size: .small)
                    .opacity(hovering || selected ? 1 : 0.45)
                    .accessibilityLabel(L10n.t("更多操作"))
            } content: {
                menuItems
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if requiredMemoryGB > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(exceedsMemory ? DS.warn : DS.text3)
                    Text(memoryText)
                        .font(DS.Font.xs)
                        .foregroundStyle(exceedsMemory ? DS.warn : DS.text2)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            action
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

    private var family: ModelFamily {
        ModelFamily.resolve(
            id: model.id,
            hint: model.family,
            tags: entry.recommendation?.tags ?? [])
    }

    private var requiredMemoryGB: Int {
        let catalog = entry.recommendation?.minimumMemory ?? 0
        let weightsGB = model.bytes > 0 ? Int((Double(model.bytes) / 1_000_000_000).rounded(.up)) : 0
        return max(catalog, weightsGB)
    }

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
                DSChip(text: "使用中", dot: DS.ok, live: true, tint: DS.ok)
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
