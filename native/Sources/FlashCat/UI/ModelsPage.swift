import SwiftUI
import AppKit
import FlashCatKit

/// 模型页：按 WebUI 版式——顶部引擎分段 + 搜索，下面是两列大模型卡。
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
        // 单列也能在窄内容区完整显示，宽窗口再自动并排。
        [GridItem(.adaptive(minimum: 300, maximum: 720), spacing: 18, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
                .padding(.horizontal, Console.contentPadding)
                .padding(.top, Console.contentTopInset)
                .padding(.bottom, 18)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Color.clear
                            .frame(height: 0)
                            .id(Self.scrollTopAnchor)

                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
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
        // 网格的滚动视口止于这条线：和侧栏玻璃的底边同高，
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

            Button {
                let target = scope.engine ?? engine
                _ = EngineModelStore.adoptExistingWeights(target)
                state.reloadModels()
                Task { @MainActor in
                    await state.engines?.controller(target)?.rescanModels()
                    state.reloadModels()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Console.secondary)
                    .frame(width: 34, height: 34)
                    .background {
                        LiquidGlassSurface(shape: Circle(), interactive: true)
                    }
            }
            .buttonStyle(.plainHit)
            .help("重新扫描")
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
                Text(displayTitle)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Console.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, design: monoSubtitle ? .monospaced : .default))
                        .foregroundStyle(Console.secondary)
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
            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Console.tertiary)
                Text(memoryText)
                    .font(.system(size: 11))
                    .foregroundStyle(Console.secondary)
                Spacer(minLength: 0)
                action
            }
        }
        .padding(18)
        .consoleCardSurface(tint: cardTint, interactive: true)
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
    /// 由卡片右下角的「使用中」标识说明，卡面本身和普通卡保持同一种玻璃。
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

    private var header: some View {
        HStack(spacing: 10) {
            ModelFamilyIcon(family: family, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.engine.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Console.text)
                Text(familyName)
                    .font(.system(size: 10))
                    .foregroundStyle(Console.tertiary)
            }
            Spacer(minLength: 0)
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Console.secondary)
            }
            // 无边框 Menu 把标签当模板压平：标签里的 frame / background 会被丢掉，
            // 图标颜色也得靠 .tint 而不是 foregroundStyle。所以 28pt 的玻璃圆底
            // 挂在外层的 frame 上，Menu 本身只负责那三个点。
            .tint(Console.secondary)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 28, height: 28)
            .contentShape(Circle())
            .background { LiquidGlassSurface(shape: Circle(), interactive: true) }
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
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("使用中")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Console.accent)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(Console.accent.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Console.accent.opacity(0.25), lineWidth: 0.8))
            } else {
                Button {
                    state.useModel(model.id, engine: entry.engine)
                } label: {
                    Label("使用", systemImage: "play.fill")
                }
                .buttonStyle(CardActionStyle(tone: .accent))
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


/// 模型卡上的按钮不铺底色。卡片本身就是一层玻璃，按钮再叠一个玻璃胶囊会在
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
