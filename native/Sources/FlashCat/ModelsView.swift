import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Page

struct ModelsView: View {
    @ObservedObject var state: AppState

    @State private var query = ""
    @State private var filter: ModelsFilter = .all
    @State private var customID = ""
    @State private var customError: String?
    @State private var pendingImport: URL?
    @State private var deleteTarget: ModelInfo?
    @State private var downloadTarget: String?

    var body: some View {
        GeometryReader { proxy in
            let usable = max(320, proxy.size.width - Native.pagePadding * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeader(title: "模型", subtitle: subtitle, eyebrow: "MODEL LIBRARY")
                        .padding(.bottom, 14)

                    if state.activeEngine != .splash {
                        EngineModelsPanel(state: state)
                            .padding(.bottom, 18)
                    } else {
                        toolbar(width: usable)
                            .padding(.bottom, 10)

                        importBar
                            .padding(.bottom, 16)

                        modelGrid(width: usable)

                        customCard()
                            .padding(.top, 18)
                            .frame(maxWidth: 720)
                    }
                }
                .padding(.horizontal, Native.pagePadding)
                .padding(.top, 30)
                .padding(.bottom, Native.pagePadding)
                .pageColumn()
            }
            .scrollIndicators(.never)
        }
    }

    // MARK: Derived data

    private var allEntries: [ModelEntry] {
        let catalog = state.catalog
        var entries: [ModelEntry] = catalog.machine.map { model in
            ModelEntry(model: model,
                       draftRepository: catalog.draftRepository(model.id, family: model.family))
        }
        for id in catalog.missingRecommendations.prefix(8) {
            let model = ModelInfo(id: id, path: "", bytes: 0, origin: .recommended, targetName: "")
            entries.append(ModelEntry(model: model,
                                      draftRepository: catalog.draftRepository(id, family: nil)))
        }
        return entries
    }

    private var filteredEntries: [ModelEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allEntries.filter { entry in
            if filter == .local && !entry.installed { return false }
            if filter == .remote && entry.installed { return false }
            guard !needle.isEmpty else { return true }
            let model = entry.model
            return model.id.lowercased().contains(needle)
                || ModelMeta.owner(model).lowercased().contains(needle)
                || ModelMeta.family(model).lowercased().contains(needle)
        }
    }

    private var localCount: Int { allEntries.filter(\.installed).count }
    private var remoteCount: Int { allEntries.count - localCount }

    private var subtitle: String {
        "本地权重、DFlash2 草稿与 Hub 下载"
    }

    // MARK: Toolbar

    @ViewBuilder
    private func toolbar(width: CGFloat) -> some View {
        if width >= 880 {
            HStack(spacing: 8) {
                ModelsSearchField(text: $query)
                filterPicker.frame(width: 252)
                Spacer(minLength: 4)
                rescanButton
                openFolderButton
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ModelsSearchField(text: $query)
                HStack(spacing: 8) {
                    filterPicker.frame(width: 238)
                    Spacer(minLength: 4)
                    rescanButton
                    openFolderButton
                }
            }
        }
    }

    private var filterPicker: some View {
        Picker("筛选", selection: $filter) {
            Text(verbatim: "全部 \(allEntries.count)").tag(ModelsFilter.all)
            Text(verbatim: "本机 \(localCount)").tag(ModelsFilter.local)
            Text(verbatim: "可下载 \(remoteCount)").tag(ModelsFilter.remote)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }

    private var rescanButton: some View {
        IconAction(systemName: "arrow.clockwise", help: "重新扫描模型目录") {
            state.reloadModels()
            state.toast("已重新扫描模型目录")
        }
    }

    private var openFolderButton: some View {
        IconAction(systemName: "folder", help: "打开模型目录") {
            openModelsDirectory()
        }
    }

    // MARK: Grid

    @ViewBuilder
    private func modelGrid(width: CGFloat) -> some View {
        let entries = filteredEntries
        Group {
            if entries.isEmpty {
                Card {
                    EmptyHint(icon: emptyIcon, title: emptyTitle, detail: emptyDetail)
                }
            } else {
                LazyVGrid(columns: gridColumns(width: width), alignment: .leading, spacing: 14) {
                    ForEach(entries) { entry in
                        card(for: entry)
                    }
                }
            }
        }
        .alert("删除本地模型？",
               isPresented: deleteShown,
               presenting: deleteTarget) { model in
            Button("删除", role: .destructive) {
                state.deleteModel(model)
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { model in
            Text("\(model.id)\n\n这会删除 \(model.sizeText) 的权重，无法撤销。")
        }
    }

    private func gridColumns(width: CGFloat) -> [GridItem] {
        let count = width >= 1120 ? 3 : (width >= 600 ? 2 : 1)
        return Array(repeating: GridItem(.flexible(minimum: 0), spacing: 14, alignment: .top),
                     count: count)
    }

    private func card(for entry: ModelEntry) -> some View {
        let selected = entry.model.id == state.selectedModel
        let tokens = selected ? state.stats?.maximumContextTokens.flatMap { $0 > 0 ? $0 : nil } : nil
        return ModelCardView(
            state: state,
            model: entry.model,
            draftRepository: entry.draftRepository,
            selected: selected,
            contextTokens: tokens,
            onUse: { use(entry.model.id) },
            onReveal: entry.installed ? { reveal(entry.model) } : nil,
            onDelete: entry.model.origin == .local ? { deleteTarget = entry.model } : nil
        )
    }

    private var emptyIcon: String {
        allEntries.isEmpty ? "shippingbox" : "magnifyingglass"
    }

    private var emptyTitle: String {
        allEntries.isEmpty ? "还没有模型" : "没有匹配的模型"
    }

    private var emptyDetail: String {
        if allEntries.isEmpty {
            return "导入一个包含 .gguf 权重的文件夹，或从 Hub 下载推荐模型"
        }
        switch filter {
        case .local:
            return localCount == 0
                ? "还没有本机模型。导入一个文件夹，或切换到「可下载」"
                : "试试别的关键词"
        case .remote:
            return remoteCount == 0
                ? "没有可下载的推荐模型。检查运行时是否提供推荐列表"
                : "试试别的关键词"
        case .all:
            return "试试别的关键词，或清空搜索"
        }
    }

    // MARK: Import bar

    private var importBar: some View {
        ModelsImportBar(
            progress: state.importProgress,
            disabled: state.importProgress != nil,
            onPick: pickModelsFolder,
            onDropDirectory: { url in pendingImport = url },
            onReject: { state.notice = "请拖入包含 .gguf 或 MLX 权重的文件夹" }
        )
        .help("导入本地模型文件夹")
        .alert("导入模型",
               isPresented: pendingImportShown,
               presenting: pendingImport) { url in
            Button("复制") { startImport(url, move: false) }
            Button("移动") { startImport(url, move: true) }
            Button("取消", role: .cancel) { pendingImport = nil }
        } message: { url in
            Text("\(url.path)\n\n“移动到模型目录”适合同盘整理；“复制”会保留原文件。大模型可能需要较长时间。")
        }
    }

    private func customCard() -> some View {
        Card("自定义模型 ID",
             subtitle: "填写 Hub 上的 owner/repo，确认后下载",
             trailing: AnyView(Tag(text: "Hub", tone: .neutral, icon: "cube"))) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    TextField("owner/repo，例如 mlx-community/Qwen3.8-27B-4bit", text: $customID)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Native.raised,
                                    in: RoundedRectangle(cornerRadius: Native.radiusSmall, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Native.radiusSmall, style: .continuous)
                                .stroke(customError == nil ? Native.hairline : Native.red.opacity(0.7), lineWidth: 1)
                        )
                        .onSubmit { applyCustom(customID) }
                        .onChange(of: customID) { _, _ in customError = nil }

                    Button("使用") { applyCustom(customID) }
                        .buttonStyle(ArcadePillStyle(tone: .accent, compact: true))
                        .disabled(customID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || state.downloadingModel != nil)
                }

                Text("支持 owner/repo:VARIANT 形式，下载位置可在设置中修改。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)

                if let customError {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 10))
                        Text(customError).font(.system(size: 10.5))
                    }
                    .foregroundStyle(Native.red)
                }

                let recent = Array(state.settings.recentModels.prefix(3))
                if !recent.isEmpty {
                    Hairline()
                        .padding(.top, 4)
                    ModelsFlowLayout(spacing: 6, lineSpacing: 6) {
                        Text("最近使用")
                            .font(.system(size: 10))
                            .foregroundStyle(Native.tertiary)
                            .frame(height: 20)
                        ForEach(recent, id: \.self) { id in
                            Button(ModelMeta.recentLabel(id)) {
                                customID = id
                                applyCustom(id)
                            }
                            .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                            .font(.system(size: 10.5))
                            .disabled(state.downloadingModel != nil)
                            .help(id)
                        }
                    }
                }
            }
        }
        .alert("下载这个模型？",
               isPresented: downloadShown,
               presenting: downloadTarget) { id in
            Button("下载") { startDownload(id) }
            Button("取消", role: .cancel) { downloadTarget = nil }
        } message: { id in
            Text("\(id)\n\n模型会下载到 \(Paths.modelsDirectory)，可能需要几十 GB 磁盘空间。")
        }
    }

    // MARK: Bindings

    private var pendingImportShown: Binding<Bool> {
        Binding(get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } })
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } })
    }

    private var downloadShown: Binding<Bool> {
        Binding(get: { downloadTarget != nil },
                set: { if !$0 { downloadTarget = nil } })
    }

    // MARK: Actions

    private func use(_ id: String) {
        if state.catalog.machineModel(id) != nil {
            state.applyModel(id)
            return
        }
        downloadTarget = id
    }

    private func startDownload(_ id: String) {
        downloadTarget = nil
        state.downloadModel(id)
    }

    private func applyCustom(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard ModelPattern.test("^[\\w.-]+/[\\w.-]+(:\\w[\\w.-]*)?$", value) else {
            customError = "格式应为 owner/repo 或 owner/repo:VARIANT"
            return
        }
        customError = nil
        customID = ""
        use(value)
    }

    private func pickModelsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "选择模型文件夹"
        panel.message = "选择包含 .gguf 或 MLX 权重的文件夹"
        panel.directoryURL = URL(fileURLWithPath: Paths.home)
        if panel.runModal() == .OK, let url = panel.url {
            pendingImport = url
        }
    }

    private func startImport(_ url: URL, move: Bool) {
        pendingImport = nil
        state.importModel(url.path, move: move)
    }

    private func reveal(_ model: ModelInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.path)])
    }

    private func openModelsDirectory() {
        Paths.ensureDirectory(Paths.modelsDirectory)
        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.modelsDirectory))
    }
}

// MARK: - Filter

private enum ModelsFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case local = "本机"
    case remote = "可下载"

    var id: String { rawValue }
}

private struct ModelEntry: Identifiable {
    let model: ModelInfo
    let draftRepository: String?

    var id: String { model.id }
    var installed: Bool { model.origin != .recommended }
}

// MARK: - Search field

private struct ModelsSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Native.tertiary)

            TextField("搜索模型、机构或参数规模", text: $text)
                .textFieldStyle(.plain)
                .font(Native.bodyFont)
                .focused($focused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Native.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Capsule().fill(Native.overlay(0.075)))
        .overlay(
            Capsule().stroke(focused ? Native.accent.opacity(0.8) : Native.overlay(0.11),
                             lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

// MARK: - Card

private struct ModelCardView: View {
    @ObservedObject var state: AppState
    let model: ModelInfo
    let draftRepository: String?
    let selected: Bool
    let contextTokens: Int?
    let onUse: () -> Void
    let onReveal: (() -> Void)?
    let onDelete: (() -> Void)?

    @State private var hovering = false

    private var local: Bool { model.origin == .local }
    private var splash: Bool { model.origin == .splash }
    private var installed: Bool { model.origin != .recommended }
    private var downloading: Bool { state.downloadingModel == model.id }
    private var busy: Bool { state.downloadingModel != nil }
    private var draftReady: Bool { installed && model.draftPath != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Text(ModelMeta.specLine(model, contextTokens: contextTokens))
                .font(.system(size: 11.5))
                .foregroundStyle(Native.secondary)
                .lineLimit(2)
                .padding(.top, 9)

            let tags = tagSpecs
            if !tags.isEmpty {
                ModelsFlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(tags.indices, id: \.self) { index in
                        let tag = tags[index]
                        Tag(text: tag.text, tone: tag.tone, icon: tag.icon)
                    }
                }
                .padding(.top, 8)
            }

            Spacer(minLength: 12)

            if downloading {
                downloadBlock
            } else {
                actions
            }
        }
        .padding(Native.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 164, alignment: .topLeading)
        .background {
            GlassSurface(radius: Native.radiusPanel,
                         tint: selected ? ModelMeta.avatarTint(model.id) : .clear)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Native.radiusPanel, style: .continuous)
                .strokeBorder(
                    selected
                        ? AnyShapeStyle(LinearGradient(colors: [Native.accent.opacity(0.9), Native.pink.opacity(0.45)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Native.overlay(hovering ? 0.20 : 0.06)),
                    lineWidth: selected ? 1.4 : 1)
        )
        .shadow(color: selected ? Native.accent.opacity(0.22) : .clear, radius: 20, y: 8)
        .scaleEffect(hovering ? 1.008 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                Text(ModelMeta.displayName(model))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(model.id)
                Text(ModelMeta.owner(model))
                    .font(Native.monoSmall)
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)
        }
    }

    private var avatar: some View {
        let tint = ModelMeta.avatarTint(model.id)
        return ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [tint, tint.opacity(0.55)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                     startPoint: .top, endPoint: .center))
            Text(ModelMeta.avatarLabel(ModelMeta.displayName(model)))
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
        }
        .frame(width: 38, height: 38)
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
        )
        .shadow(color: tint.opacity(0.45), radius: 9, y: 4)
    }

    private var tagSpecs: [ModelTagSpec] {
        var result: [ModelTagSpec] = []
        if draftReady {
            result.append(ModelTagSpec(text: "DFlash2 就绪", tone: .success, icon: "bolt.fill"))
        } else if draftRepository != nil {
            result.append(ModelTagSpec(text: "DFlash2 可下载", tone: .accent, icon: "bolt"))
        } else {
            result.append(ModelTagSpec(text: "标准解码", tone: .neutral, icon: nil))
        }
        if ModelMeta.isVision(model) {
            result.append(ModelTagSpec(text: "视觉", tone: .accent, icon: "eye"))
        }
        if ModelMeta.isMoE(model) {
            result.append(ModelTagSpec(text: "MoE", tone: .accent, icon: nil))
        }
        if let active = ModelMeta.activeParams(model) {
            result.append(ModelTagSpec(text: "\(active) 激活", tone: .neutral, icon: nil))
        }
        if model.bytes > 0 && model.bytes < 6_000_000_000 {
            result.append(ModelTagSpec(text: "轻量", tone: .neutral, icon: nil))
        }
        if local {
            result.append(ModelTagSpec(text: "本机", tone: .neutral, icon: nil))
        }
        if splash {
            result.append(ModelTagSpec(text: "Splash", tone: .neutral, icon: nil))
        }
        return result
    }

    @ViewBuilder
    private var actions: some View {
        if installed {
            HStack(spacing: 7) {
                if selected {
                    // A state chip occupies the primary slot instead of a disabled
                    // button repeating the old header tag.
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("使用中")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Native.mint)
                    .frame(maxWidth: .infinity)
                    .frame(height: 33)
                    .background(Capsule().fill(Native.mint.opacity(0.14)))
                    .overlay(Capsule().stroke(Native.mint.opacity(0.32), lineWidth: 0.8))
                    .help("当前正在使用这个模型")
                } else {
                    Button {
                        onUse()
                    } label: {
                        Label("使用", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ArcadePillStyle(tone: .light))
                    .disabled(busy)
                }

                if onReveal != nil || onDelete != nil {
                    Menu {
                        if let onReveal {
                            Button {
                                onReveal()
                            } label: {
                                Label("在 Finder 中显示", systemImage: "folder")
                            }
                        }
                        if onReveal != nil && onDelete != nil {
                            Divider()
                        }
                        if let onDelete {
                            Button(role: .destructive) {
                                onDelete()
                            } label: {
                                Label("删除模型", systemImage: "trash")
                            }
                        }
                    } label: {
                        IconMenuLabel(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(busy)
                    .help("更多操作")
                    .accessibilityLabel("更多操作")
                }
            }
        } else {
            Button {
                onUse()
            } label: {
                Label {
                    Text("下载")
                } icon: {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Native.accentSoft)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ArcadePillStyle(tone: .glass))
            .disabled(busy)
        }
    }

    private var downloadBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Native.accent)
                Text("正在下载")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                Text(ModelMeta.percent(state.downloadFraction))
                    .font(Native.monoSmall)
                    .foregroundStyle(Native.secondary)
            }
            Meter(fraction: state.downloadFraction ?? 0, tint: Native.accent)
            Text("完成后自动切换")
                .font(.system(size: 10))
                .foregroundStyle(Native.tertiary)
        }
    }

}

private struct ModelTagSpec {
    let text: String
    let tone: TagTone
    let icon: String?
}

// MARK: - Wrapping tag row

private struct ModelsFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
            if rowWidth > 0 && needed > maxWidth {
                widestRow = max(widestRow, rowWidth)
                totalHeight += rowHeight + lineSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = needed
                rowHeight = max(rowHeight, size.height)
            }
        }
        if rowWidth > 0 {
            widestRow = max(widestRow, rowWidth)
            totalHeight += rowHeight
        }
        return CGSize(width: proposal.width ?? widestRow, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subviews[index].place(at: CGPoint(x: x, y: y),
                                  anchor: .topLeading,
                                  proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Import bar

/// One import affordance: the toolbar's old "导入模型" button, the dashed drop
/// zone and the click-to-choose area were three copies of the same action.
private struct ModelsImportBar: View {
    let progress: AppState.ImportProgress?
    let disabled: Bool
    let onPick: () -> Void
    let onDropDirectory: (URL) -> Void
    let onReject: () -> Void

    @State private var targeted = false
    @State private var hovering = false

    private var fraction: Double {
        guard let progress else { return 0 }
        return min(1, max(0, progress.fraction))
    }

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 12) {
                ArcadeIcon(symbol: progress == nil ? "folder.badge.plus" : "arrow.down.doc",
                           colors: [Native.accent, Native.pink],
                           size: 34,
                           glyphScale: 0.44,
                           glow: false)

                VStack(alignment: .leading, spacing: 3) {
                    Text(progress == nil ? "导入本地模型" : "正在导入模型")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(progress?.message
                         ?? "把包含 .gguf 或 MLX 权重的文件夹拖到这里，或点击选择")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Native.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 10)

                if let progress {
                    HStack(spacing: 10) {
                        Meter(fraction: fraction, tint: Native.accent)
                            .frame(width: 120)
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(Native.monoSmall)
                            .foregroundStyle(Native.secondary)
                    }
                    .help(progress.message)
                } else {
                    Text(targeted ? "松开以导入" : "选择文件夹…")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(targeted ? Native.accent : Native.label.opacity(0.85))
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background(Capsule().fill(Native.overlay(0.10)))
                        .overlay(Capsule().stroke(Native.overlay(0.14), lineWidth: 0.8))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(background)
            .overlay(border)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.95 : 1)
        .onHover { hovering = $0 }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            accept(providers)
        }
        .animation(.easeOut(duration: 0.14), value: targeted)
        .animation(.easeOut(duration: 0.14), value: hovering)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(targeted ? Native.accent.opacity(0.12)
                  : Native.overlay(hovering ? 0.055 : 0.025))
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
    }

    private var borderColor: Color {
        if targeted || progress != nil { return Native.accent }
        if hovering { return Native.accent.opacity(0.55) }
        return Native.tertiary.opacity(0.35)
    }

    private func accept(_ providers: [NSItemProvider]) -> Bool {
        guard !disabled else { return false }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let value = item as? URL {
                url = value
            } else if let string = item as? String {
                url = URL(fileURLWithPath: string)
            } else {
                url = nil
            }
            guard let url else { return }
            let directory = Self.directoryURL(for: url)
            DispatchQueue.main.async {
                if let directory {
                    onDropDirectory(directory)
                } else {
                    onReject()
                }
            }
        }
        return true
    }

    private static func directoryURL(for url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return url }
        if url.pathExtension.lowercased() == "gguf" { return url.deletingLastPathComponent() }
        return nil
    }
}

// MARK: - Metadata heuristics
//
// Mirrors lib/features/models/models_page.dart: parameters come from the last
// path component, active parameters from an A<n>B token in the id, family from
// gguf / moe / A<n>B, precision from UD-Q…, n-bit or GGUF, vision from mmproj or
// a VL-style repo name. MLX is only used as a precision fallback when the id
// carries no explicit bit width.

/// Local regex helper. `TextPattern` in Support.swift indexes eight capture
/// groups unconditionally, which raises an ObjC exception for patterns with
/// fewer ranges; this variant walks `match.numberOfRanges` instead.
private enum ModelPattern {
    static func firstMatch(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = expression.firstMatch(in: text, options: [], range: range) else { return nil }
        var groups: [String] = []
        for index in 0..<match.numberOfRanges {
            let groupRange = match.range(at: index)
            if groupRange.location == NSNotFound {
                groups.append("")
            } else if let swiftRange = Range(groupRange, in: text) {
                groups.append(String(text[swiftRange]))
            } else {
                groups.append("")
            }
        }
        return groups
    }

    static func test(_ pattern: String, _ text: String) -> Bool {
        firstMatch(pattern, text) != nil
    }
}

private enum ModelMeta {
    static func owner(_ model: ModelInfo) -> String {
        if let first = model.id.split(separator: "/").first {
            return String(first)
        }
        switch model.origin {
        case .local: return "flashCat"
        case .splash: return "Splash"
        case .recommended: return "Hub"
        }
    }

    static func displayName(_ model: ModelInfo) -> String {
        shortName(model.id)
    }

    static func shortName(_ id: String) -> String {
        let last = id.split(separator: "/").last.map(String.init) ?? id
        return last.split(separator: ":").first.map(String.init) ?? last
    }

    static func recentLabel(_ id: String) -> String {
        shortName(id)
    }

    static func params(_ model: ModelInfo) -> String? {
        guard let match = ModelPattern.firstMatch(
            "([0-9]+(?:\\.[0-9]+)?)\\s*B(?![a-zA-Z])",
            model.shortName
        ) else { return nil }
        return match[1] + "B"
    }

    static func activeParams(_ model: ModelInfo) -> String? {
        guard let match = ModelPattern.firstMatch(
            "A([0-9]+(?:\\.[0-9]+)?)B",
            model.id
        ) else { return nil }
        return match[1] + "B"
    }

    static func family(_ model: ModelInfo) -> String {
        let id = model.id.lowercased()
        if id.contains("gguf") { return "GGUF" }
        if isMoE(model) { return "MoE" }
        return "Dense"
    }

    /// MoE is a property of the weights, not of the container format, so a GGUF
    /// MoE model still gets the MoE badge even though its family label is GGUF.
    static func isMoE(_ model: ModelInfo) -> Bool {
        let id = model.id.lowercased()
        return id.contains("moe") || ModelPattern.test("a[0-9]+(?:\\.[0-9]+)?b", id)
    }

    static func quant(_ model: ModelInfo) -> String {
        let name = model.shortName
        if let match = ModelPattern.firstMatch("(UD-Q[0-9]+[A-Za-z0-9_]*)", name) {
            return match[1].uppercased()
        }
        if let match = ModelPattern.firstMatch("([0-9]+)\\s*-?\\s*bit", name) {
            return match[1] + "-bit"
        }
        let id = model.id.lowercased()
        if id.contains("gguf") { return "GGUF" }
        if id.contains("mlx") { return "MLX" }
        return ""
    }

    static func specLine(_ model: ModelInfo, contextTokens: Int?) -> String {
        var parts: [String] = []
        if let params = params(model) { parts.append(params) }
        if model.bytes > 0 { parts.append(model.sizeText) }
        let family = family(model)
        let quant = quant(model)
        if !quant.isEmpty && quant != family { parts.append(quant) }
        parts.append(family)
        if let tokens = contextTokens, tokens > 0 {
            parts.append(shortTokens(tokens) + " 上下文")
        }
        return parts.joined(separator: " · ")
    }

    static func isVision(_ model: ModelInfo) -> Bool {
        if model.mmprojPath != nil { return true }
        let haystack = (model.id + " " + model.targetName + " " + model.path).lowercased()
        if haystack.contains("mmproj") || haystack.contains("vision") || haystack.contains("llava") {
            return true
        }
        return ModelPattern.test("(?:^|[-_./])vl(?:[-_./]|$)", haystack)
    }

    static func avatarLabel(_ name: String) -> String {
        var label = "#"
        if let match = ModelPattern.firstMatch("[A-Za-z]", name), let first = match[0].first {
            label = String(first).uppercased()
        }
        if let digit = ModelPattern.firstMatch("-(\\d)B(?:-|$)", name) {
            label += digit[1]
        }
        return label
    }

    static func avatarIndex(_ id: String) -> Int {
        var hash = 0
        for unit in id.utf16 {
            hash = (hash + Int(unit) * 31) % 5
        }
        return hash
    }

    static func avatarTint(_ id: String) -> Color {
        let palette: [Color] = [Native.blue, Native.orange, Native.teal, Native.purple, Native.gray]
        return palette[avatarIndex(id) % palette.count]
    }

    static func shortTokens(_ tokens: Int) -> String {
        guard tokens >= 1000 else { return "\(tokens)" }
        let value = Double(tokens) / 1000
        if value >= 100 { return String(format: "%.0fK", value) }
        return String(format: value >= 10 ? "%.0fK" : "%.1fK", value)
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "准备中" }
        return "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
    }
}
