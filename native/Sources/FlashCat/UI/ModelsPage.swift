// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import SwiftUI
import AppKit
import FlashCatKit

/// 模型页：顶部平面分段 + 常驻搜索 + 操作带，下方自适应两列模型卡网格。
struct ModelsPage: View {
    @ObservedObject var state: AppState
    let engine: EngineID
    @Binding var showingHub: Bool
    @Binding var showingDownloads: Bool

    @State private var scope: ModelScope = .all
    @State private var query = ""
    @State private var removeTarget: ModelLibraryEntry?
    @State private var device = DeviceProfile.current()

    private static let scrollTopAnchor = "models.scroll.top"

    private var entries: [ModelLibraryEntry] {
        let base: [ModelLibraryEntry]
        switch scope {
        case .all:
            base = EngineCatalog.allIDs.flatMap { state.libraryEntries(for: $0) }
        case .engine(let id):
            base = state.libraryEntries(for: id)
        }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = text.isEmpty
            ? base
            : base.filter { "\($0.model.shortName) \($0.model.id)".lowercased().contains(text) }
        // 使用中的模型置顶，其次是已下载的，最后是待下载的；组内保持原顺序。
        return filtered.enumerated()
            .sorted { lhs, rhs in
                let l = rank(lhs.element), r = rank(rhs.element)
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
    }

    private func rank(_ entry: ModelLibraryEntry) -> Int {
        if isSelected(entry) { return 0 }
        if entry.installed { return 1 }
        return 2
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 320, maximum: 720), spacing: 14, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
                .padding(.horizontal, Console.contentPadding)
                .padding(.top, Console.contentTopInset)
                .padding(.bottom, 16)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Color.clear
                            .frame(height: 0)
                            .id(Self.scrollTopAnchor)

                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(entries, id: \.identity) { entry in
                                ModelCard(state: state,
                                          entry: entry,
                                          selected: isSelected(entry),
                                          device: device,
                                          remove: { removeTarget = entry })
                            }
                        }
                        if entries.isEmpty {
                            Text(L10n.t("没有匹配的模型"))
                                .font(DS.Font.sm)
                                .foregroundStyle(DS.text3)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
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
            }
        }
        .padding(.bottom, Console.contentBottomInset)
        .sheet(isPresented: $showingHub) { HubSheet(state: state, engine: scope.engine ?? engine) }
        .sheet(isPresented: $showingDownloads) { DownloadCenterSheet(state: state) }
        .alert("删除 \(removeTarget?.model.shortName ?? "")？",
               isPresented: Binding(get: { removeTarget != nil },
                                    set: { if !$0 { removeTarget = nil } })) {
            Button("删除", role: .destructive) {
                if let entry = removeTarget {
                    state.removeModel(entry.model.id, engine: entry.engine)
                }
                removeTarget = nil
            }
            Button("取消", role: .cancel) { removeTarget = nil }
        } message: {
            Text(removalMessage)
        }
    }

    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                filterControl
                Spacer(minLength: 0)
                actionControls
            }
            VStack(alignment: .leading, spacing: 10) {
                filterControl
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    actionControls
                }
            }
        }
    }

    private var filterControl: some View {
        DSFilterBar(selection: $scope,
                    options: [(ModelScope.all, "全部")]
                        + EngineCatalog.allIDs.map { (ModelScope.engine($0), $0.displayName) },
                    query: $query,
                    placeholder: "搜索模型")
    }

    @ViewBuilder
    private var actionControls: some View {
        HStack(spacing: 8) {
            Button {
                showingDownloads = true
            } label: {
                let count = state.downloadTasks.count + (state.downloadingModel == nil ? 0 : 1)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11, weight: .medium))
                    Text(L10n.t("下载中心"))
                    if count > 0 {
                        DSBadge(count: count)
                    }
                }
            }
            .buttonStyle(.dsSecondary)

            Button {
                showingHub = true
                state.searchHub(state.hubQuery, sort: state.hubSort.rawValue,
                                filter: state.hubFilter.rawValue, page: 0)
            } label: {
                Label(L10n.t("模型广场"), systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(.dsSecondary)

            DSIconButton(systemName: "arrow.clockwise", help: "重新扫描") {
                let target = scope.engine ?? engine
                _ = EngineModelStore.adoptExistingWeights(target)
                state.reloadModels()
                Task { @MainActor in
                    await state.engines?.controller(target)?.rescanModels()
                    state.reloadModels()
                }
            }
        }
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
              ModelSharing.canonical(running) == ModelSharing.canonical(entry.id) else { return nil }
        return state.downloadFraction ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(titleParts.name)
                        .font(DS.Font.lg.weight(.semibold))
                        .tracking(-0.2)
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let variant = titleParts.variant {
                        Text(variant)
                            .font(DS.Font.mono(10, weight: .medium))
                            .foregroundStyle(DS.text2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DS.rect(DS.Radius.sm).fill(DS.raised))
                            .overlay(DS.rect(DS.Radius.sm).strokeBorder(DS.line2, lineWidth: 1))
                            .fixedSize()
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(monoSubtitle ? DS.Font.mono(11) : DS.Font.xs)
                        .foregroundStyle(DS.text2)
                        .lineLimit(monoSubtitle ? 1 : 2)
                        .truncationMode(monoSubtitle ? .middle : .tail)
                        .fixedSize(horizontal: false, vertical: !monoSubtitle)
                        .help(model.id)
                }
            }
            SpecTable(items: [
                ("ENGINE", entry.engine.displayName),
                ("FORMAT", formatName),
                ("QUANT", quantizationLabel ?? "—"),
                ("SIZE", model.bytes > 0 ? model.sizeText : "—"),
            ])
            tags
            DSDivider()
            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(exceedsMemory ? DS.warn : DS.text3)
                Text(memoryText)
                    .font(DS.Font.xs)
                    .foregroundStyle(exceedsMemory ? DS.warn : DS.text2)
                Spacer(minLength: 0)
                action
            }
        }
        .padding(16)
        .dsSurface(radius: DS.Radius.lg,
                   fill: DS.surface,
                   stroke: selected ? DS.accent.opacity(0.45) : DS.line,
                   hoverable: true)
        .contextMenu {
            if !model.path.isEmpty {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.path)])
                }
            }
            Button("复制模型 ID") { state.copy(model.id, label: "模型 ID 已复制") }
            if entry.installed {
                Divider()
                Button("删除权重…", role: .destructive, action: remove)
            }
        }
    }

    private var displayTitle: String {
        model.shortName
    }

    private var titleParts: (name: String, variant: String?) {
        let title = displayTitle
        guard let colon = title.lastIndex(of: ":") else { return (title, nil) }
        let name = String(title[title.startIndex..<colon])
        let variant = String(title[title.index(after: colon)...])
        guard !name.isEmpty, !variant.isEmpty, variant.count <= 16 else { return (title, nil) }
        return (name, variant)
    }

    private var subtitlePair: (text: String, mono: Bool) {
        if let summary = entry.recommendation?.summary, !summary.isEmpty {
            return (summary, false)
        }
        if model.id != displayTitle { return (model.id, true) }
        return ("", false)
    }

    private var subtitle: String? {
        let pair = subtitlePair
        return pair.text.isEmpty ? nil : pair.text
    }

    private var monoSubtitle: Bool { subtitlePair.mono }

    private var quantizationLabel: String? {
        if let quant = model.quantization, !quant.isEmpty { return quant }
        if let variant = entry.recommendation?.variant,
           let quant = ModelQuantization.detect(in: variant) {
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
        ModelFamily.resolve(id: model.id,
                            hint: model.family,
                            tags: entry.recommendation?.tags ?? [])
    }

    private var header: some View {
        HStack(spacing: 10) {
            ModelFamilyIcon(family: family, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.engine.displayName)
                    .font(DS.Font.md.weight(.medium))
                    .foregroundStyle(DS.text)
                Text(familyName)
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
            }
            Spacer(minLength: 0)
            DSMenu {
                DSMenuTriggerLabel(systemImage: "ellipsis", kind: .icon, size: .small)
            } content: {
                if !model.path.isEmpty {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.path)])
                    }
                }
                Button("复制模型 ID") { state.copy(model.id, label: "模型 ID 已复制") }
                if entry.installed {
                    Divider()
                    Button("删除权重…", role: .destructive, action: remove)
                }
            }
        }
    }

    private var familyName: String {
        if family != .other { return family.name }
        if let family = model.family, !family.isEmpty, family != "GGUF", family != "MLX" { return family }
        return entry.recommendation?.tags.first ?? "本地权重"
    }

    private var tags: some View {
        FlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(tagTexts.prefix(5), id: \.self) { tag in
                ConsoleTag(text: tag, fontSize: 10)
            }
        }
    }

    private var tagTexts: [String] {
        var values: [String] = []
        if let tags = entry.recommendation?.tags {
            values.append(contentsOf: tags.filter {
                ModelQuantization.detect(in: $0) == nil && !values.contains($0)
            })
        }
        if entry.draftRepository != nil { values.append("DFlash2") }
        if ModelSharing.isShared(model.id) { values.append("共享") }
        if entry.uncatalogued { values.append("未收录") }
        return values.isEmpty ? ["本地"] : values
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
        if memory > 0 {
            if exceedsMemory {
                return L10n.format("%lld GB 内存起 · 超出本机", memory)
            }
            return L10n.format("%lld GB 内存起", memory)
        }
        return L10n.t("内存需求未标注")
    }

    @ViewBuilder private var action: some View {
        if let fraction = activeFraction {
            Button {
                state.pauseDownload()
            } label: {
                Label(L10n.format("下载 %@", fraction.formatted(.percent.precision(.fractionLength(0)))),
                      systemImage: "pause.fill")
            }
            .buttonStyle(.ds(.secondary, size: .small))
        } else if let task {
            Button {
                state.resumeDownload(task)
            } label: {
                Label(task.status == .paused
                      ? L10n.format("继续 %@", (task.fraction ?? 0).formatted(.percent.precision(.fractionLength(0))))
                      : L10n.t("重试"),
                      systemImage: "play.fill")
            }
            .buttonStyle(.ds(.secondary, size: .small))
        } else if entry.installed {
            if selected {
                DSChip(text: "使用中", dot: DS.ok, live: true, tint: DS.ok)
            } else {
                Button {
                    state.useModel(model.id, engine: entry.engine)
                } label: {
                    Label(L10n.t("使用"), systemImage: "play.fill")
                }
                .buttonStyle(.ds(.primary, size: .small))
            }
        } else {
            Button {
                state.downloadModel(model.id, engine: entry.engine)
            } label: {
                Label(L10n.t("下载"), systemImage: "arrow.down.circle.fill")
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
