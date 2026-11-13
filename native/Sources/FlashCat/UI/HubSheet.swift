import SwiftUI
import AppKit
import FlashCatKit

/// 模型广场：搜索 Hugging Face，查看模型卡，下载到公共目录。
///
/// 查询、排序、格式筛选和翻页都走 `AppState`；这里不直接发网络请求。
struct HubSheet: View {
    @ObservedObject var state: AppState
    /// 打开广场时正在浏览的引擎：没有格式归属时退到它。
    let engine: EngineID

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var sort: HubSort = .trending
    @State private var filter: HubFilter = .all
    @State private var directRepo = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var directRepoFocused: Bool

    private var models: [HubModel] { state.hubResults }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            HStack(spacing: 0) {
                listPane.frame(width: 430)
                Rectangle().fill(Native.hairline).frame(width: 1)
                detailPane.frame(maxWidth: .infinity)
            }
            Hairline()
            if !state.repoProbeRepo.isEmpty {
                probeRow
                Hairline()
            }
            footer
        }
        .frame(width: 1020, height: 700)
        .sheetCanvas()
        .onAppear {
            if state.hubResults.isEmpty {
                state.searchHub("", sort: sort.rawValue, filter: filter.rawValue, page: 0)
            }
        }
        .onDisappear { state.closeHubDetail() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ArcadeIcon(symbol: "sparkle.magnifyingglass",
                       colors: [Native.violet, Native.blue],
                       size: 30,
                       glyphScale: 0.46,
                       glow: false)
            VStack(alignment: .leading, spacing: 2) {
                Text("模型广场")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Native.label)
                Text("搜 Hugging Face 上的权重，下载到公共目录，再决定哪个引擎看得见")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
            }
            Spacer(minLength: 8)
            IconAction(systemName: "xmark", help: "关闭模型广场") { dismiss() }
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 14)
    }

    // MARK: Left

    private var listPane: some View {
        VStack(spacing: 0) {
            searchBar
            Hairline()
            ScrollView {
                LazyVStack(spacing: 10) {
                    if state.hubLoading && models.isEmpty {
                        loadingRows
                    } else if let error = state.hubError, models.isEmpty {
                        errorState(error)
                    } else if models.isEmpty {
                        EmptyHint(icon: "magnifyingglass",
                                  title: "搜一个模型仓库",
                                  detail: "输入关键词后点「搜索」，或留空看热门；也可以直接填 owner/repo 下载。")
                            .padding(.vertical, 30)
                    } else {
                        ForEach(models) { model in
                            resultRow(model)
                        }
                        if state.hubHasMore {
                            Button {
                                state.searchHub(query, sort: sort.rawValue,
                                                filter: filter.rawValue,
                                                page: state.hubPage + 1)
                            } label: {
                                Text(L10n.t(state.hubLoading ? "加载中…" : "加载更多"))
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background {
                                        LiquidGlassSurface(shape: Capsule(), interactive: true)
                                    }
                            }
                            .buttonStyle(.plainHit)
                            .foregroundStyle(Native.accent)
                            .disabled(state.hubLoading)
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
                    .foregroundStyle(Native.tertiary)
                TextField("搜索模型仓库，例如 Qwen3 Coder", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                        runSearch(page: 0)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Native.tertiary)
                    }
                    .buttonStyle(.plainHit)
                }
                Button("搜索") { runSearch(page: 0) }
                    .buttonStyle(.consolePrimary)
                    .disabled(state.hubLoading)
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background {
                LiquidGlassSurface(
                    shape: RoundedRectangle(cornerRadius: 9, style: .continuous),
                    tint: searchFocused ? Native.accent.opacity(0.08) : nil
                )
            }

            HStack(spacing: 8) {
                NativeSegmented(selection: $filter,
                                options: HubFilter.allCases.map { ($0, filterLabel($0)) },
                                width: 210)
                    .onChange(of: filter) { _, _ in runSearch(page: 0) }

                Spacer(minLength: 0)

                Menu {
                    Button("趋势") { sort = .trending; runSearch(page: 0) }
                    Button("下载量") { sort = .downloads; runSearch(page: 0) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 9, weight: .bold))
                        Text(L10n.t(sort == .trending ? "趋势" : "下载量"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Native.secondary)
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background {
                        LiquidGlassSurface(shape: Capsule(), interactive: true)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
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
        state.searchHub(query, sort: sort.rawValue, filter: filter.rawValue, page: page)
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
                .foregroundStyle(Native.orange)
            Text("搜不到 Hugging Face")
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(Native.captionFont)
                .foregroundStyle(Native.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("重试") { runSearch(page: 0) }
                .buttonStyle(.consoleSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func resultRow(_ model: HubModel) -> some View {
        HubModelRowCard(
            model: model,
            selected: state.hubDetail?.id == model.id,
            local: state.repoIsLocal(model.id),
            shortName: shortName(model.id),
            sizeText: {
                guard let size = model.sizeBytes, size > 0 else { return nil }
                return Format.size(Int(clamping: size))
            }(),
            memoryText: model.memoryRange.map(memoryRangeText),
            downloadsText: downloadsText(model.downloads)
        ) {
            state.loadHubDetail(model.id)
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
        if state.hubDetailLoading {
            VStack(spacing: 12) {
                SkeletonBlock(height: 26, radius: 8).frame(width: 240)
                SkeletonBlock(height: 14, radius: 6).frame(width: 320)
                SkeletonBlock(height: 140, radius: 10)
            }
            .padding(24)
        } else if let detail = state.hubDetail {
            detailContent(detail)
        } else {
            EmptyHint(icon: "doc.text.magnifyingglass",
                      title: "选一个仓库查看详情",
                      detail: "文件清单、体积、许可与 README 原文都在这里；确认后再下载。")
                .frame(maxHeight: .infinity)
        }
    }

    private func detailContent(_ detail: HubModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    ModelFamilyIcon(family: ModelFamily.resolve(id: detail.id, tags: detail.tags),
                                    size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(shortName(detail.id))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Native.label)
                        Text(detail.id)
                            .font(Native.monoFont)
                            .foregroundStyle(Native.tertiary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        if let size = detail.sizeBytes, size > 0 {
                            Text(Format.size(Int(clamping: size)))
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Native.metricNum)
                        }
                        Text(downloadsText(detail.downloads))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Native.tertiary)
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
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Native.secondary)
                        MarkdownView(text: ModelCardText.normalized(card))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { GlassSurface(radius: Native.radiusTile) }
                }

                if !detail.files.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("文件")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Native.secondary)
                            .padding(.bottom, 6)
                        ForEach(detail.files.prefix(40), id: \.name) { file in
                            HStack(spacing: 8) {
                                Image(systemName: "doc")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Native.tertiary)
                                Text(file.name)
                                    .font(Native.monoSmall)
                                    .foregroundStyle(Native.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                if let size = file.size {
                                    Text(Format.size(Int(clamping: size)))
                                        .font(Native.monoSmall)
                                        .foregroundStyle(Native.tertiary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        if detail.files.count > 40 {
                            Text("另有 \(detail.files.count - 40) 个文件")
                                .font(.system(size: 10))
                                .foregroundStyle(Native.tertiary)
                                .padding(.top, 4)
                        }
                    }
                    .padding(12)
                    .background { GlassSurface(radius: Native.radiusTile) }
                }

            }
            .padding(20)
        }
        .scrollIndicators(.never)
    }

    /// 详情页的标签行：量化、内存下限、许可与 Hub 标签。推荐引擎不再占一枚
    /// 标签——归属由下面下载条里的「默认授权给 …」交代，重复一遍只会抢注意力。
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
        let target = targetEngine(for: detail)
        let busy = state.downloadingModel != nil
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t(local ? "已在本机" : "下载到公共目录"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Native.label)
                Text(local
                     ? "公共目录里已有这份权重，可直接在模型页使用"
                     : "一份权重供引擎共用，默认授权给 \(target.displayName)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
            }
            Spacer(minLength: 8)
            if local {
                Button("在模型页查看") {
                    state.libraryEngine = target
                    state.section = .models
                    dismiss()
                }
                .buttonStyle(.consoleSecondary)
            } else {
                Button {
                    state.downloadShared(detail.id, engines: [target])
                    dismiss()
                } label: {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.consolePrimary)
                .disabled(busy)
            }
        }
        .padding(12)
        .background { GlassSurface(radius: Native.radiusTile, tint: Native.accentSoft) }
    }

    private func targetEngine(for model: HubModel) -> EngineID {
        if let id = EngineID(rawValue: model.recommendedEngine.id) { return id }
        return engine
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Native.tertiary)
                TextField("直接填 owner/repo 下载", text: $directRepo)
                    .textFieldStyle(.plain)
                    .font(Native.monoFont)
                    .focused($directRepoFocused)
                Button("下载", action: downloadDirect)
                    .buttonStyle(.consoleSecondary)
                    .disabled(directRepo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                LiquidGlassSurface(
                    shape: RoundedRectangle(cornerRadius: 8, style: .continuous),
                    tint: directRepoFocused ? Native.accent.opacity(0.08) : nil
                )
            }
            .frame(maxWidth: 360)

            Spacer(minLength: 8)

            if !models.isEmpty {
                Text("第 \(state.hubPage + 1) 页 · \(models.count) 条")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Native.tertiary)
                IconAction(systemName: "chevron.left", help: "上一页") {
                    runSearch(page: max(0, state.hubPage - 1))
                }
                .disabled(state.hubPage == 0 || state.hubLoading)

                IconAction(systemName: "chevron.right", help: "下一页") {
                    runSearch(page: state.hubPage + 1)
                }
                .disabled(!state.hubHasMore || state.hubLoading)
            }
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 12)
    }

    private var probeRow: some View {
        HStack(spacing: 8) {
            if state.repoProbeLoading {
                ProgressView().controlSize(.small)
                Text("检查 \(state.repoProbeRepo)…")
                    .font(Native.monoSmall)
                    .foregroundStyle(Native.secondary)
            } else if let error = state.repoProbeError, !error.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Native.orange)
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.orange)
                    .lineLimit(1)
            } else if let probe = state.repoProbe {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Native.green)
                Text(probe.id)
                    .font(Native.monoSmall)
                    .foregroundStyle(Native.secondary)
                if let size = probe.sizeBytes, size > 0 {
                    Tag(text: Format.size(Int(clamping: size)), tone: .neutral)
                }
                Tag(text: probe.recommendedEngine.label, tone: .accent)
                if state.repoIsLocal(probe.id) {
                    Tag(text: "已在本机", tone: .success)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 6)
        .background(Native.recess.opacity(0.6))
        .task(id: directRepo) {
            let repo = directRepo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard repo.contains("/") else {
                state.clearRepoProbe()
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            state.probeRepo(repo)
        }
    }

    private func downloadDirect() {
        let repo = directRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else { return }
        state.downloadShared(repo, engines: [engine])
        directRepo = ""
        state.clearRepoProbe()
        dismiss()
    }
}

/// 模型广场左侧的结果卡。
///
/// 纯白画布上单独一层玻璃会发灰、压低正文对比度，所以卡片把玻璃压在
/// 一层足够白的面板上，再用细描边勾出边界；选中态才用强调色底 + 色边。
private struct HubModelRowCard: View {
    let model: HubModel
    let selected: Bool
    let local: Bool
    let shortName: String
    let sizeText: String?
    let memoryText: String?
    let downloadsText: String
    let action: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Console.cardRadius, style: .continuous)
    }

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
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Native.label)
                            .lineLimit(1)
                        Text(model.id)
                            .font(Native.monoSmall)
                            .foregroundStyle(Native.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(selected ? Native.accent : Native.tertiary.opacity(0.6))
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
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .consoleCardSurface(tint: selected ? Console.accent.opacity(0.10) : nil,
                                interactive: true)
            .contentShape(shape)
        }
        .buttonStyle(.plainHit)
    }

    private func metric(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Native.tertiary)
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Native.secondary)
                .lineLimit(1)
        }
    }
}
