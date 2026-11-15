import SwiftUI
import AppKit
import FlashCatKit

/// 模型页：顶部引擎分段 + 搜索，下面是一张按行分隔的模型清单。
/// 每个模型只占一行，不再有卡片边框；下载中只在行底多一条进度线。
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
                .padding(.horizontal, Console.contentPadding)
                .padding(.top, Console.contentTopInset)
                .padding(.bottom, 18)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .id(Self.scrollTopAnchor)

                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(entries, id: \.identity) { entry in
                                ModelCard(state: state,
                                          entry: entry,
                                          selected: isSelected(entry),
                                          device: device,
                                          remove: { removeTarget = entry })
                            }
                        }
                        if entries.isEmpty {
                            Text("没有匹配的模型")
                                .font(.system(size: 12))
                                .foregroundStyle(Console.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
                        }
                    }
                    .padding(.horizontal, Console.contentPadding)
                    .padding(.top, 2)
                }
                .scrollIndicators(.never)
                // 切换引擎后内容高度会骤减；不回到顶部时滚动位置可能落在
                // 新内容之外，整页看起来是空白的。必须等这一帧布局完成再定位：
                // 同步 scrollTo 用的还是旧内容的高度，滚完仍然停在空白区。
                .onChange(of: scope) { _, _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo(Self.scrollTopAnchor, anchor: .top)
                    }
                }
            }
        }
        // 网格的滚动视口止于这条线：和侧栏的底边同高，
        // 滚到底时最后一行卡片也不会糊在窗口边缘上。
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
        HStack(spacing: 14) {
            GlassFilterBar(selection: $scope,
                           options: [(ModelScope.all, "全部")]
                               + EngineCatalog.allIDs.map { (ModelScope.engine($0), $0.displayName) },
                           query: $query,
                           placeholder: "搜索模型")

            Spacer(minLength: 0)

            Button {
                showingHub = true
                state.searchHub(state.hubQuery, sort: state.hubSort.rawValue,
                                filter: state.hubFilter.rawValue, page: 0)
            } label: {
                Text("模型广场")
            }
            .buttonStyle(.consoleSecondary)

            IconAction(systemName: "arrow.clockwise", help: "重新扫描") {
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
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(displayTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(selected ? Console.accent : Console.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.id)

                    }

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5, design: monoSubtitle ? .monospaced : .default))
                            .foregroundStyle(Console.tertiary)
                            .lineLimit(1)
                            .truncationMode(monoSubtitle ? .middle : .tail)
                            .help(model.id)
                    }

                    HStack(spacing: 6) {
                        ForEach(Array(metaTexts.enumerated()), id: \.offset) { index, value in
                            Text(L10n.t(value))
                            if index < metaTexts.count - 1 {
                                Text("·").foregroundStyle(Console.quaternary)
                            }
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Console.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 16)

                Text(memoryText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Console.tertiary)
                    .lineLimit(1)
                    .frame(width: 108, alignment: .trailing)

                action
                    .frame(width: 72, alignment: .trailing)

                Menu {
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
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Console.tertiary)
                }
                .tint(Console.tertiary)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .padding(.vertical, 13)
            .padding(.leading, 10)
            .background(selected ? Console.rowSelected : Color.clear)
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle()
                        .fill(Console.accent)
                        .frame(width: 2)
                        .padding(.vertical, 10)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Console.hairline).frame(height: 1)
            }
            .contentShape(Rectangle())
            .contextMenu { contextMenu }

            if let fraction = activeFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Console.accent)
                    .frame(height: 2)
                    .padding(.bottom, 1)
            }
        }
    }

    @ViewBuilder private var contextMenu: some View {
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

    private var metaTexts: [String] {
        var values = [entry.engine.displayName, formatName]
        if let quant = quantizationLabel { values.append(quant) }
        if model.bytes > 0 { values.append(model.sizeText) }
        values.append(contentsOf: tagTexts.prefix(2))
        return values
    }

    private var displayTitle: String {
        model.shortName
    }

    /// 卡片副标题。仓库 id 经常和标题逐字相同（"owner/Repo" → "Repo"），
    /// 那样印两遍只是占位；改用目录里的说明，完整 id 留在悬停提示里。
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

    /// Quantization for the spec row. Scanned weights carry their own label;
    /// a suggestion falls back to the catalog's chosen variant or tag, then to
    /// whatever the repository id happens to spell out.
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

    /// 卡面只在下载中铺一层暖色底。使用中的卡不再整块染色——「正在用哪个模型」
    /// 由卡片右下角的「使用中」标识说明，行面本身和其他行保持同一种表面。
    private var cardTint: Color? {
        if selected { return nil }
        if activeFraction != nil || task != nil { return Console.warn.opacity(0.10) }
        return nil
    }

    private var family: ModelFamily {
        ModelFamily.resolve(id: model.id,
                            hint: model.family,
                            tags: entry.recommendation?.tags ?? [])
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
        // Quantization already has its own spec row; keeping it here too would
        // print the same label twice.
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

    private var memoryText: String {
        let catalog = entry.recommendation?.minimumMemory ?? 0
        // SIZE 格是实测、内存是目录里的估算。估算值不可能低于权重本身，
        // 否则同一张卡片自相矛盾（68.5 GB 的权重配"64 GB 内存起"）。
        let weightsGB = model.bytes > 0 ? Int((Double(model.bytes) / 1_000_000_000).rounded(.up)) : 0
        let memory = max(catalog, weightsGB)
        if memory > 0 { return L10n.format("%lld GB 内存起", memory) }
        return L10n.t("内存需求未标注")
    }

    @ViewBuilder private var action: some View {
        if let fraction = activeFraction {
            Button {
                state.pauseDownload()
            } label: {
                Label(L10n.format("下载 %@", fraction.formatted(.percent.precision(.fractionLength(0)))), systemImage: "pause.fill")
            }
            .buttonStyle(CardActionStyle(tone: .neutral))
        } else if let task {
            Button {
                state.resumeDownload(task)
            } label: {
                Label(task.status == .paused ? L10n.format("继续 %@", (task.fraction ?? 0).formatted(.percent.precision(.fractionLength(0)))) : L10n.t("重试"),
                      systemImage: "play.fill")
            }
            .buttonStyle(CardActionStyle(tone: .neutral))
        } else if entry.installed {
            if selected {
                HStack(spacing: 5) {
                    Image(systemName: "waveform")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("使用中")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(Console.accent)
            } else {
                Button {
                    state.useModel(model.id, engine: entry.engine)
                } label: {
                    Label("使用", systemImage: "play.fill")
                }
                .buttonStyle(CardActionStyle(tone: .neutral))
            }
        } else {
            Button {
                state.downloadModel(model.id, engine: entry.engine)
            } label: {
                Label("下载", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(CardActionStyle(tone: .neutral))
            .disabled(state.downloadingModel != nil)
        }
    }
}


/// 模型行里的按钮不铺底色。行本身已经很安静，按钮再叠一个描边胶囊会在
/// 卡面上多出一块更亮的椭圆；现在按钮只留文字和图标，悬停时提亮、按下时轻微
/// 收缩，命中区仍覆盖整块内边距。
private struct CardActionStyle: ButtonStyle {
    enum Tone { case accent, neutral }

    var tone: Tone = .neutral

    func makeBody(configuration: Configuration) -> some View {
        CardActionBody(configuration: configuration, tone: tone)
    }
}

private struct CardActionBody: View {
    let configuration: ButtonStyleConfiguration
    let tone: CardActionStyle.Tone

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var tint: Color {
        switch tone {
        case .accent: return Console.accent
        case .neutral: return Console.text
        }
    }

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(isEnabled ? tint.opacity(hovering ? 1 : 0.82)
                                       : Console.tertiary.opacity(0.6))
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
            .animation(Motion.quick, value: hovering)
            .onHover { hovering = $0 }
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
