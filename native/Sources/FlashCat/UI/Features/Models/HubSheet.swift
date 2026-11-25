// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 模型广场：搜索 Hugging Face，查看模型卡，下载到公共目录。
///
/// 查询、排序、格式筛选和翻页都走 `AppState`；这里不直接发网络请求。
struct HubSheet: View {
    @ObservedObject var state: AppState
    @ObservedObject var hub: HubStore
    /// 打开广场时正在浏览的引擎：只作为存放目录的默认选项，不再决定「推荐用谁」。
    let engine: EngineID

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var sort: HubSort = .trending
    @State private var filter: HubFilter = .all
    @State private var directRepo = ""
    /// 量化选择按仓库名记：`nil` 表示用默认（最小的那档）。
    @State private var pickedVariant: String?
    @State private var lastSelectedRepo: String?
    /// 已点「下载」、还没选定落盘引擎的仓库。
    @State private var pendingDownload: PendingDownload?
    @AppStorage("hubSource") private var storedSource = HubSource.huggingFace.rawValue
    @FocusState private var searchFocused: Bool
    @FocusState private var directRepoFocused: Bool

    private var models: [HubModel] { hub.hubResults }

    private var source: HubSource {
        HubSource(rawValue: storedSource) ?? .huggingFace
    }

    /// 一次下载在弹窗里需要的全部信息：仓库、挑中的量化（名字给下载器，
    /// 标签给人看）和文件白名单。落盘引擎在弹窗里才确定，Splash 的量化写进
    /// 模型 id，其他引擎走 include。
    private struct PendingDownload: Identifiable {
        let repo: String
        let variantName: String?
        let variantLabel: String?
        let include: [String]

        var id: String { repo + "|" + (variantName ?? "") }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            DSDivider()
            HStack(spacing: 0) {
                listPane.frame(width: 430)
                DSDivider(vertical: true)
                detailPane.frame(maxWidth: .infinity)
            }
            DSDivider()
            if !hub.repoProbeRepo.isEmpty {
                probeRow
                DSDivider()
            }
            footer
        }
        .frame(width: 1020, height: 700)
        .sheetCanvas()
        .onAppear {
            if hub.hubResults.isEmpty || hub.hubSource != source {
                state.searchHub(
                    "", sort: sort.rawValue, filter: filter.rawValue, page: 0,
                    source: source)
            }
        }
        .onChange(of: hub.hubDetail?.id) { _, _ in pickedVariant = nil }
        .onDisappear { state.closeHubDetail() }
        .onExitCommand { dismiss() }
        .sheet(item: $pendingDownload) { pending in
            EngineDownloadSheet(
                state: state,
                repo: pending.repo,
                variant: pending.variantLabel,
                preferred: engine,
                source: source
            ) { target in
                // Splash reads the quant out of the model id; the snapshot
                // engines take it as include patterns and keep the repo id.
                let modelID =
                    target.adapter == .splash
                    ? pending.variantName.map { pending.repo + ":" + $0 } ?? pending.repo
                    : pending.repo
                let started = state.downloadModel(
                    modelID, engine: target,
                    source: source, include: pending.include,
                    activate: false)
                if started {
                    pendingDownload = nil
                    dismiss()
                }
            }
        }
        .task(id: directRepo + "|" + source.rawValue) {
            let repo = directRepo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard repo.contains("/") else {
                state.clearRepoProbe()
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            state.probeRepo(repo, source: source)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "sparkle.magnifyingglass", color: DS.accent, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("模型广场")
                    .font(DS.Font.lg.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text(source.subtitle)
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
            }
            Spacer(minLength: 8)
            DSMenu {
                DSMenuTriggerLabel(
                    title: source.displayName,
                    systemImage: "globe",
                    size: .regular
                )
            } content: {
                ForEach(HubSource.allCases) { item in
                    Button {
                        switchSource(item)
                    } label: {
                        if item == source {
                            Label(item.displayName, systemImage: "checkmark")
                        } else {
                            Text(item.displayName)
                        }
                    }
                }
            }
            DSIconButton(systemName: "xmark", help: "关闭模型广场") { dismiss() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Left

    private var listPane: some View {
        VStack(spacing: 0) {
            searchBar
            DSDivider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    if hub.hubLoading && models.isEmpty {
                        loadingRows
                    } else if let error = hub.hubError, models.isEmpty {
                        errorState(error)
                    } else if models.isEmpty {
                        EmptyHint(
                            icon: "magnifyingglass",
                            title: "搜一个模型仓库",
                            detail: "输入关键词后点「搜索」，或留空看热门；也可以直接填 owner/repo 下载。"
                        )
                        .padding(.vertical, 30)
                    } else {
                        ForEach(models) { model in
                            resultRow(model)
                        }
                        if hub.hubHasMore {
                            Button {
                                state.searchHub(
                                    query, sort: sort.rawValue,
                                    filter: filter.rawValue,
                                    page: hub.hubPage + 1,
                                    source: source)
                            } label: {
                                Text(L10n.t(hub.hubLoading ? "加载中…" : "加载更多"))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.ds(.secondary, size: .regular))
                            .disabled(hub.hubLoading)
                            .padding(.top, 2)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.never)
        }
    }

    private var searchBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.text3)
                TextField("搜索模型仓库，例如 Qwen3 Coder", text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.Font.md)
                    .focused($searchFocused)
                    .onSubmit { runSearch(page: 0) }
                if !query.isEmpty {
                    Button {
                        query = ""
                        runSearch(page: 0)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DS.text3)
                    }
                    .buttonStyle(.plainHit)
                }
                Button("搜索") { runSearch(page: 0) }
                    .buttonStyle(.ds(.primary, size: .small))
                    .disabled(hub.hubLoading)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .dsInputSurface(radius: DS.Radius.md, focused: searchFocused)

            HStack(spacing: 8) {
                DSSegmented(
                    selection: $filter,
                    options: HubFilter.allCases.map { ($0, filterLabel($0)) }
                )
                .onChange(of: filter) { _, _ in runSearch(page: 0) }

                Spacer(minLength: 0)

                DSMenu {
                    DSMenuTriggerLabel(
                        title: sortLabel(sort),
                        systemImage: "arrow.up.arrow.down",
                        size: .regular
                    )
                } content: {
                    Button(sortLabel(.trending)) {
                        sort = .trending
                        runSearch(page: 0)
                    }
                    Button("下载量") {
                        sort = .downloads
                        runSearch(page: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func filterLabel(_ filter: HubFilter) -> String {
        switch filter {
        case .all: return "全部"
        case .mlx: return "MLX"
        case .gguf: return "GGUF"
        }
    }

    private func runSearch(page: Int) {
        state.searchHub(
            query, sort: sort.rawValue, filter: filter.rawValue, page: page,
            source: source)
    }

    private func switchSource(_ next: HubSource) {
        guard next != source else { return }
        storedSource = next.rawValue
        state.closeHubDetail()
        pickedVariant = nil
        query = ""
        // 两家仓库的 id 与排序词不通用，换源从空查询重新起步。
        state.searchHub(
            "", sort: sort.rawValue, filter: filter.rawValue, page: 0,
            source: next)
    }

    private func sortLabel(_ value: HubSort) -> String {
        switch value {
        case .trending: return source.defaultSortLabel
        case .downloads: return "下载量"
        }
    }

    private var loadingRows: some View {
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: 10) {
                    SkeletonBlock(height: 30, radius: 7).frame(width: 30)
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBar(width: 150, height: 10)
                        SkeletonBar(width: 210, height: 8, opacity: 0.06)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DS.warn)
            Text(L10n.format("搜不到 %@", source.displayName))
                .font(DS.Font.md.weight(.semibold))
                .foregroundStyle(DS.text)
            Text(message)
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("重试") { runSearch(page: 0) }
                .buttonStyle(.ds(.secondary, size: .regular))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func resultRow(_ model: HubModel) -> some View {
        HubModelRowCard(
            model: model,
            selected: hub.hubDetail?.id == model.id,
            local: state.repoIsLocal(model.id),
            shortName: shortName(model.id),
            sizeText: {
                guard let size = model.sizeBytes, size > 0 else { return nil }
                return Format.size(Int(clamping: size))
            }(),
            memoryText: model.memoryRange.map(memoryRangeText),
            downloadsText: downloadsText(model.downloads)
        ) {
            lastSelectedRepo = model.id
            state.loadHubDetail(model.id, source: source)
        }
    }

    private func shortName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    private func memoryRangeText(_ range: ClosedRange<Int>) -> String {
        range.lowerBound == range.upperBound
            ? "≈\(range.lowerBound) GB 内存"
            : "≈\(range.lowerBound)–\(range.upperBound) GB 内存"
    }

    private func downloadsText(_ value: Int) -> String {
        if value >= 1_000_000 {
            let millions = (Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(1)))
            return L10n.format("%@M 下载", millions)
        }
        if value >= 1000 {
            let thousands = (Double(value) / 1000).formatted(.number.precision(.fractionLength(0)))
            return L10n.format("%@K 下载", thousands)
        }
        return L10n.format("%lld 下载", value)
    }

    // MARK: Right

    @ViewBuilder private var detailPane: some View {
        if hub.hubDetailLoading {
            VStack(spacing: 12) {
                SkeletonBlock(height: 26, radius: 8).frame(width: 240)
                SkeletonBlock(height: 14, radius: 6).frame(width: 320)
                SkeletonBlock(height: 140, radius: 10)
            }
            .padding(24)
        } else if let detail = hub.hubDetail {
            detailContent(detail)
        } else if let error = hub.hubError, !error.isEmpty {
            VStack(spacing: 12) {
                EmptyHint(
                    icon: "wifi.exclamationmark",
                    title: "模型详情加载失败",
                    detail: error
                )
                if let repo = lastSelectedRepo {
                    Button(L10n.t("重试")) {
                        state.loadHubDetail(repo, source: source)
                    }
                    .buttonStyle(.ds(.secondary, size: .regular))
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            EmptyHint(
                icon: "doc.text.magnifyingglass",
                title: "选一个仓库查看详情",
                detail: "文件清单、体积、许可与 README 原文都在这里；确认后再下载。"
            )
            .frame(maxHeight: .infinity)
        }
    }

    private func detailContent(_ detail: HubModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    ModelFamilyIcon(
                        family: ModelFamily.resolve(id: detail.id, tags: detail.tags),
                        size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(shortName(detail.id))
                            .font(DS.Font.title)
                            .foregroundStyle(DS.text)
                        Text(detail.id)
                            .font(DS.Font.mono(11.5))
                            .foregroundStyle(DS.text3)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        if let size = detail.sizeBytes, size > 0 {
                            Text(Format.size(Int(clamping: size)))
                                .font(DS.Font.mono(15, weight: .semibold))
                                .foregroundStyle(DS.text)
                                .monospacedDigit()
                        }
                        Text(downloadsText(detail.downloads))
                            .font(DS.Font.xs)
                            .foregroundStyle(DS.text3)
                            .monospacedDigit()
                    }
                }

                let tags = detailTagTexts(detail)
                if !tags.isEmpty {
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                            Tag(text: tag, tone: .neutral)
                        }
                    }
                }

                downloadBar(detail)

                if let card = detail.modelCard, !card.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("模型卡")
                            .font(DS.Font.sm.weight(.semibold))
                            .foregroundStyle(DS.text2)
                        MarkdownView(text: ModelCardText.normalized(card))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsSurface(radius: DS.Radius.md)
                }

                if !detail.files.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("文件")
                            .font(DS.Font.sm.weight(.semibold))
                            .foregroundStyle(DS.text2)
                            .padding(.bottom, 6)
                        ForEach(detail.files.prefix(40), id: \.name) { file in
                            HStack(spacing: 8) {
                                Image(systemName: "doc")
                                    .font(.system(size: 9))
                                    .foregroundStyle(DS.text3)
                                Text(file.name)
                                    .font(DS.Font.mono(10.5))
                                    .foregroundStyle(DS.text2)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                if let size = file.size {
                                    Text(Format.size(Int(clamping: size)))
                                        .font(DS.Font.mono(10.5))
                                        .foregroundStyle(DS.text3)
                                        .monospacedDigit()
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        if detail.files.count > 40 {
                            Text("另有 \(detail.files.count - 40) 个文件")
                                .font(DS.Font.xs)
                                .foregroundStyle(DS.text3)
                                .padding(.top, 4)
                        }
                    }
                    .padding(12)
                    .dsSurface(radius: DS.Radius.md)
                }

            }
            .padding(20)
        }
        .scrollIndicators(.never)
    }

    /// 详情页的标签行：量化、内存下限、许可与 Hub 标签。落盘引擎由下载时的
    /// 目录选择决定，标签行不再替用户预设一个运行引擎。
    private func detailTagTexts(_ detail: HubModel) -> [String] {
        var values: [String] = []
        if let quantization = detail.quantization { values.append(quantization) }
        if let memory = detail.memoryRange { values.append(memoryRangeText(memory)) }
        if let license = detail.license { values.append(license) }
        values.append(contentsOf: detail.tags.filter { !$0.hasPrefix("license:") }.prefix(6))
        return values
    }

    private func downloadBar(_ detail: HubModel) -> some View {
        let local = state.repoIsLocal(detail.id)
        let busy = state.downloadingModel != nil
        let variants = detail.layoutKind == .gguf ? detail.ggufVariants : []
        let variant = chosenVariant(detail, variants: variants)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t(local ? "已在本机" : "下载模型"))
                    .font(DS.Font.sm.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text(
                    local
                        ? "本机已有这份权重，可直接在模型库使用"
                        : variant.map {
                            L10n.format("只下 %@，其余量化不占盘；下载时选择存放的引擎目录", variantLabel($0))
                        }
                            ?? L10n.t("下载时选择存放到哪个引擎的模型目录")
                )
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
            }
            Spacer(minLength: 8)
            if local {
                Button("在模型页查看") {
                    state.libraryEngine = state.engineHolding(detail.id) ?? engine
                    state.section = .models
                    dismiss()
                }
                .buttonStyle(.ds(.secondary, size: .regular))
            } else {
                if variants.count > 1 {
                    DSMenu {
                        DSMenuTriggerLabel(
                            title: variant.map(variantLabel) ?? L10n.t("全部量化"),
                            systemImage: "square.stack.3d.up",
                            size: .small
                        )
                    } content: {
                        ForEach(Array(variants.enumerated()), id: \.offset) { _, item in
                            Button {
                                pickedVariant = item.name ?? ""
                            } label: {
                                Text(variantLabel(item) + "  ·  " + memoryText(item))
                            }
                        }
                    }
                }
                Button {
                    let includes = variant.map { detail.downloadIncludes(for: $0) } ?? []
                    pendingDownload = PendingDownload(
                        repo: detail.id,
                        variantName: variant.flatMap(\.name),
                        variantLabel: variant.map(variantLabel),
                        include: includes)
                } label: {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.ds(.primary, size: .regular))
                .disabled(busy)
            }
        }
        .padding(12)
        .dsSurface(radius: DS.Radius.md, tint: DS.accent.opacity(0.14), stroke: DS.accent.opacity(0.30))
    }

    /// 多量化仓库默认选体积最小的那档；用户从菜单里挑了就用那档。
    private func chosenVariant(_ detail: HubModel, variants: [GGUFVariant]) -> GGUFVariant? {
        guard variants.count > 1 else { return nil }
        if let pickedVariant,
            let hit = variants.first(where: { ($0.name ?? "") == pickedVariant })
        {
            return hit
        }
        return variants.min { $0.bytes < $1.bytes }
    }

    private func variantLabel(_ variant: GGUFVariant) -> String {
        variant.name ?? L10n.t("默认")
    }

    private func memoryText(_ variant: GGUFVariant) -> String {
        L10n.format(
            "%@ · ≈%lld GB 内存", Format.size(variant.bytes),
            Int64(HubModelLayout.estimatedMemoryGB(bytes: variant.bytes)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.text3)
                TextField(source.directRepoPlaceholder, text: $directRepo)
                    .textFieldStyle(.plain)
                    .font(DS.Font.mono(11.5))
                    .focused($directRepoFocused)
                    .onSubmit(downloadDirect)
                Button("下载", action: downloadDirect)
                    .buttonStyle(.ds(.secondary, size: .small))
                    .disabled(
                        directRepo.trimmingCharacters(in: .whitespaces).isEmpty
                            || state.downloadingModel != nil
                    )
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                DS.rect(DS.Radius.md)
                    .fill(DS.bg)
            }
            .overlay {
                DS.rect(DS.Radius.md)
                    .strokeBorder(directRepoFocused ? DS.line3 : DS.line2, lineWidth: 1)
            }
            .frame(maxWidth: 360)

            Spacer(minLength: 8)

            if !models.isEmpty {
                Text("第 \(hub.hubPage + 1) 页 · \(models.count) 条")
                    .font(DS.Font.mono(10.5))
                    .foregroundStyle(DS.text3)
                    .monospacedDigit()
                HStack(spacing: 6) {
                    DSIconButton(systemName: "chevron.left", help: "上一页", style: .outlined) {
                        runSearch(page: max(0, hub.hubPage - 1))
                    }
                    .disabled(hub.hubPage == 0 || hub.hubLoading)

                    DSIconButton(systemName: "chevron.right", help: "下一页", style: .outlined) {
                        runSearch(page: hub.hubPage + 1)
                    }
                    .disabled(!hub.hubHasMore || hub.hubLoading)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var probeRow: some View {
        HStack(spacing: 8) {
            if hub.repoProbeLoading {
                ProgressView().controlSize(.small)
                Text("检查 \(hub.repoProbeRepo)…")
                    .font(DS.Font.mono(10.5))
                    .foregroundStyle(DS.text2)
            } else if let error = hub.repoProbeError, !error.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.warn)
                Text(error)
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.warn)
                    .lineLimit(1)
            } else if let probe = hub.repoProbe {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.ok)
                Text(probe.id)
                    .font(DS.Font.mono(10.5))
                    .foregroundStyle(DS.text2)
                if let size = probe.sizeBytes, size > 0 {
                    Tag(text: Format.size(Int(clamping: size)), tone: .neutral)
                }
                if state.repoIsLocal(probe.id) {
                    Tag(text: "已在本机", tone: .success)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(DS.bg)
    }

    private func downloadDirect() {
        let repo = directRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty, state.downloadingModel == nil else { return }
        // 手填仓库同样先问落盘目录；探测结果只用来确认仓库存在。
        pendingDownload = PendingDownload(
            repo: repo, variantName: nil, variantLabel: nil, include: [])
    }
}

/// 模型广场左侧的结果卡。
private struct HubModelRowCard: View {
    let model: HubModel
    let selected: Bool
    let local: Bool
    let shortName: String
    let sizeText: String?
    let memoryText: String?
    let downloadsText: String
    let action: () -> Void

    private var family: ModelFamily {
        ModelFamily.resolve(id: model.id, tags: model.tags)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 11) {
                    ModelFamilyIcon(family: family, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(shortName)
                            .font(DS.Font.md.weight(.semibold))
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                        Text(model.id)
                            .font(DS.Font.mono(10.5))
                            .foregroundStyle(DS.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(selected ? DS.accent : DS.text3.opacity(0.6))
                        .padding(.top, 4)
                }

                if model.quantization != nil || local {
                    HStack(spacing: 5) {
                        if let quantization = model.quantization {
                            Tag(text: quantization, tone: .neutral)
                        }
                        if local {
                            Tag(text: "已在本机", tone: .success, icon: "checkmark")
                        }
                        Spacer(minLength: 0)
                    }
                }

                HStack(spacing: 14) {
                    if let sizeText {
                        metric("externaldrive", sizeText)
                    }
                    if let memoryText {
                        metric("memorychip", memoryText)
                    }
                    Spacer(minLength: 4)
                    metric("arrow.down", downloadsText)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsSurface(
                radius: DS.Radius.lg,
                stroke: selected ? DS.accent.opacity(0.45) : nil,
                hoverable: true,
                active: selected
            )
            .contentShape(DS.rect(DS.Radius.lg))
        }
        .buttonStyle(.plainHit)
    }

    private func metric(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(DS.text3)
            Text(text)
                .font(DS.Font.mono(10, weight: .medium))
                .foregroundStyle(DS.text2)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

/// 下载前选一个落盘目录：权重进某个引擎自己的模型目录，由那次下载决定，
/// 不再由广场替用户猜「该用哪台引擎」。
private struct EngineDownloadSheet: View {
    @ObservedObject var state: AppState
    let repo: String
    let variant: String?
    let preferred: EngineID
    let source: HubSource
    let start: (EngineID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picked: EngineID?

    private var installed: [EngineID] {
        EngineCatalog.allIDs.filter { state.engineIsInstalled($0) }
    }

    /// Splash's installer only speaks Hugging Face; with ModelScope selected,
    /// its row stays visible but cannot be picked.
    private func compatible(_ id: EngineID) -> Bool {
        source.isHuggingFaceCompatible || id.adapter != .splash
    }

    init(
        state: AppState, repo: String, variant: String?, preferred: EngineID,
        source: HubSource, start: @escaping (EngineID) -> Void
    ) {
        self.state = state
        self.repo = repo
        self.variant = variant
        self.preferred = preferred
        self.source = source
        self.start = start
        let installed = EngineCatalog.allIDs.filter {
            state.engineIsInstalled($0)
                && (source.isHuggingFaceCompatible || $0.adapter != .splash)
        }
        let initial =
            installed.first(where: { $0 == state.activeEngine })
            ?? installed.first(where: { $0 == preferred })
            ?? installed.first
        _picked = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            DSDivider()
            if installed.isEmpty {
                empty
            } else {
                VStack(spacing: 8) {
                    ForEach(installed, id: \.self) { id in
                        row(id)
                    }
                }
                .padding(16)
            }
            DSDivider()
            footer
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .sheetCanvas()
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "internaldrive", color: DS.accent, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("选择模型目录"))
                    .font(DS.Font.lg.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text(
                    variant.map {
                        L10n.format("%@ · %@ 的权重会存进所选引擎自己的目录", repo, $0)
                    } ?? L10n.format("%@ 的权重会存进所选引擎自己的目录", repo)
                )
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
                .lineLimit(2)
            }
            Spacer(minLength: 8)
            DSIconButton(systemName: "xmark", help: "关闭", style: .outlined) { dismiss() }
        }
        .padding(16)
    }

    private func row(_ id: EngineID) -> some View {
        let isPicked = picked == id
        let allowed = compatible(id)
        return Button {
            if allowed { picked = id }
        } label: {
            HStack(spacing: 10) {
                IconTile(symbol: engineSymbol(id), color: engineAccent(id), size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(id.displayName)
                            .font(DS.Font.sm.weight(.semibold))
                            .foregroundStyle(DS.text)
                        if id == state.activeEngine {
                            Tag(text: "当前引擎", tone: .accent)
                        }
                        if !allowed {
                            Tag(text: "仅 Hugging Face", tone: .neutral)
                        }
                    }
                    Text(displayPath(id))
                        .font(DS.Font.mono(10))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isPicked ? DS.accent : DS.text3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                DS.rect(DS.Radius.md)
                    .fill(isPicked ? DS.accent.opacity(0.10) : DS.raised)
            }
            .overlay {
                DS.rect(DS.Radius.md)
                    .strokeBorder(isPicked ? DS.accent.opacity(0.45) : DS.line, lineWidth: 1)
            }
            .contentShape(DS.rect(DS.Radius.md))
            .opacity(allowed ? 1 : 0.5)
        }
        .buttonStyle(.plainHit)
        .disabled(!allowed)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(DS.text3)
            Text(L10n.t("还没有安装引擎"))
                .font(DS.Font.md.weight(.semibold))
                .foregroundStyle(DS.text)
            Text(L10n.t("权重需要一个引擎的模型目录；先到「引擎」页安装一个，再回来下载。"))
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(L10n.t("取消")) { dismiss() }
                .buttonStyle(.ds(.secondary, size: .regular))
            Button {
                if let picked { start(picked) }
            } label: {
                Label(L10n.t("下载"), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.ds(.primary, size: .regular))
            .disabled(picked == nil || state.downloadingModel != nil)
        }
        .padding(16)
    }

    private func displayPath(_ id: EngineID) -> String {
        let path = EnginePaths.modelsDirectory(id)
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
