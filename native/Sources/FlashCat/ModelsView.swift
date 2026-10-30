import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FlashCatKit

// MARK: - Page

struct ModelsView: View {
    @ObservedObject var state: AppState

    @State private var filter: ModelsFilter = .all
    @State private var dropTargeted = false
    @State private var pendingImport: URL?
    @State private var removeTarget: ModelLibraryEntry?
    @State private var downloadTarget: ModelLibraryEntry?
    @State private var showingDownloadCenter = false
    /// Chip, memory and free disk, read once per visit to the page.
    @State private var device = DeviceProfile.current()

    /// The library the page is showing. It is *not* the running engine: browsing
    /// (and downloading, importing, deleting) stays available for every engine,
    /// installed or not, running or not.
    private var engine: EngineID { state.libraryEngine }

    var body: some View {
        GeometryReader { proxy in
            let usable = max(320, proxy.size.width - Native.pagePadding * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeader(title: "模型", eyebrow: "MODEL LIBRARY")
                        .padding(.bottom, 14)

                    engineScope
                        .padding(.bottom, 14)

                    toolbar
                        .padding(.bottom, 14)

                    if showsStartCard {
                        LibraryStartCard(state: state,
                                         engine: engine,
                                         installed: engineIsInstalled,
                                         device: device,
                                         entries: recommendedEntries,
                                         onDownload: { entry in downloadTarget = entry })
                            .padding(.bottom, 16)
                    }

                    // The start card already lists every suggestion, so the
                    // grid would just repeat it; it appears with the first
                    // model on disk.
                    if !showsStartCard {
                        modelGrid(width: usable)
                    }
                }
                .padding(.horizontal, Native.pagePadding)
                .padding(.top, 30)
                .padding(.bottom, Native.pagePadding)
                .pageColumn()
                .animation(.easeOut(duration: 0.18), value: engine)
            }
            .scrollIndicators(.never)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Native.accent.opacity(0.6), lineWidth: 1.5)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                acceptDrop(providers)
            }
        }
        .onChange(of: state.libraryEngine) { _, _ in
            filter = .all
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .alert("导入到 \(engine.displayName)？",
               isPresented: pendingImportShown,
               presenting: pendingImport) { url in
            Button("复制") { startImport(url, move: false) }
            Button("移动") { startImport(url, move: true) }
            Button("取消", role: .cancel) { pendingImport = nil }
        } message: { url in
            Text("\(url.path)\n\n会放进 \(EnginePaths.modelsDirectory(engine))。“移动”适合同盘整理，“复制”保留原文件。大模型可能需要较长时间。")
        }
        .alert("切换引擎？",
               isPresented: pendingLibraryUseShown,
               presenting: state.pendingLibraryUse) { request in
            Button(request.needsDownload ? "切换并下载" : "切换并使用") {
                state.confirmLibraryUse()
            }
            Button("取消", role: .cancel) { state.cancelLibraryUse() }
        } message: { request in
            Text(libraryUseMessage(request))
        }
        .sheet(isPresented: $showingDownloadCenter) {
            DownloadCenterSheet(state: state)
        }
    }

    // MARK: Engine scope

    /// Every engine's library is reachable, not only the installed ones: the
    /// page is a catalogue first, and a missing runtime is a reason to offer the
    /// install, not a reason to hide what that runtime can serve.
    private var engineList: [EngineID] { [.splash, .omlx, .mtplx] }

    private var engineIsInstalled: Bool { state.availableEngines.contains(engine) }

    private var engineScope: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(engineList, id: \.self) { id in
                    engineChip(id)
                }
            }
            .padding(3)
            .background(Capsule().fill(Native.overlay(0.05)))
            .overlay(Capsule().strokeBorder(Native.overlay(0.08), lineWidth: 1))

            Spacer(minLength: 4)

            if engine == state.activeEngine {
                HStack(spacing: 5) {
                    Circle()
                        .fill(state.isRunning ? Native.mint : Native.overlay(0.25))
                        .frame(width: 5, height: 5)
                    Text(state.isRunning ? "正在运行" : "未启动")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Native.tertiary)
                }
            } else if !engineIsInstalled {
                HStack(spacing: 6) {
                    Text("\(engine.displayName) 还没安装")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Native.tertiary)
                    Button {
                        state.section = .settings
                    } label: {
                        Label("去安装", systemImage: "arrow.down.circle")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                }
            } else {
                HStack(spacing: 6) {
                    Text("运行中：\(state.activeEngine.displayName)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Native.tertiary)

                    Button {
                        state.switchEngine(engine)
                    } label: {
                        Label("切到 \(engine.displayName)", systemImage: "arrow.left.arrow.right")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                    .help("切换运行中的引擎，模型列表不受影响")
                }
            }
        }
    }

    private func engineChip(_ id: EngineID) -> some View {
        let active = id == engine
        let running = id == state.activeEngine && state.isRunning
        let installed = state.availableEngines.contains(id)
        return Button {
            withAnimation(.easeOut(duration: 0.2)) {
                state.browseEngine(id)
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(running ? Native.mint : (installed ? Native.overlay(0.3) : Native.overlay(0.14)))
                    .frame(width: 5, height: 5)
                Text(id.displayName)
                    .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? Native.label : (installed ? Native.secondary : Native.tertiary))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(active ? Native.raised : Color.clear))
            .overlay(Capsule().strokeBorder(active ? Native.overlay(0.14) : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(installed ? "查看 \(id.displayName) 的模型库" : "\(id.displayName) 还没安装，先看它能跑什么")
    }

    // MARK: Derived data

    private var entries: [ModelLibraryEntry] { state.libraryEntries(for: engine) }
    private var installedEntries: [ModelLibraryEntry] { entries.filter(\.installed) }

    /// Suggestions for this engine, best fit for this Mac first: among the
    /// ones the machine can carry, the tier that uses the most of its memory
    /// leads; the ones it cannot run sink to the end.
    private var recommendedEntries: [ModelLibraryEntry] {
        entries.filter(\.downloadable).sorted { deviceOrder($0) < deviceOrder($1) }
    }

    private func deviceOrder(_ entry: ModelLibraryEntry) -> (Int, Int) {
        guard let recommendation = entry.recommendation else {
            return (DeviceFit.good.rawValue, -entry.model.bytes)
        }
        switch device.fit(recommendation) {
        case .good: return (0, -recommendation.minimumMemory)
        case .unknown: return (1, recommendation.minimumMemory)
        case .tight: return (2, recommendation.minimumMemory)
        case .diskShort: return (3, recommendation.bytes)
        }
    }

    private var filteredEntries: [ModelLibraryEntry] {
        entries.filter { entry in
            switch filter {
            case .all: return true
            case .local: return entry.installed
            case .remote: return !entry.installed
            }
        }
    }

    private var localCount: Int { installedEntries.count }
    private var remoteCount: Int { recommendedEntries.count }

    /// Nothing installed for this engine, so the suggestions get the top of the
    /// page instead of a quiet row at the bottom of the grid.
    private var showsStartCard: Bool {
        installedEntries.isEmpty && !recommendedEntries.isEmpty
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            filterPicker
            deviceChip
            Spacer(minLength: 4)
            importButton
            downloadCenterButton
            rescanButton
            openFolderButton
        }
    }

    private var filterPicker: some View {
        ModelsFilterPicker(selection: $filter,
                           counts: [.all: entries.count,
                                    .local: localCount,
                                    .remote: remoteCount])
    }

    /// What this Mac offers, so the fit tags on the cards are explainable.
    private var deviceChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "memorychip")
                .font(.system(size: 9.5, weight: .bold))
            Text(device.summary)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Native.secondary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Native.overlay(0.05)))
        .overlay(Capsule().strokeBorder(Native.overlay(0.08), lineWidth: 1))
        .help("推荐模型会按本机内存与磁盘可用空间标注是否适配")
    }

    /// The download center entrance. While a transfer runs it shows the live
    /// percentage; otherwise it is a plain pill with the paused/failed count.
    @ViewBuilder
    private var downloadCenterButton: some View {
        if state.downloadingModel != nil {
            Button {
                showingDownloadCenter = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("下载中 \(Int(((state.downloadFraction ?? 0) * 100).rounded()))%")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Native.accent)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(Native.accent.opacity(0.14)))
                .overlay(Capsule().stroke(Native.accent.opacity(0.3), lineWidth: 0.8))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("打开下载中心：暂停、继续或取消下载")
        } else {
            let count = state.downloadTasks.count
            Button {
                showingDownloadCenter = true
            } label: {
                HStack(spacing: 5) {
                    Text("下载中心")
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(Native.accent.opacity(0.18)))
                            .foregroundStyle(Native.accent)
                    }
                }
            }
            .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            .help("查看下载任务：进度、暂停、断点续传")
        }
    }

    private var rescanButton: some View {
        IconAction(systemName: "arrow.clockwise", help: "重新扫描 \(engine.displayName) 的模型目录") {
            _ = EngineModelLinker.synchronize(engine)
            state.reloadModels()
            state.toast("已重新扫描 \(engine.displayName) 的模型目录")
        }
    }

    private var openFolderButton: some View {
        IconAction(systemName: "folder", help: "打开模型目录") {
            openModelsDirectory()
        }
    }

    /// Import lives in the toolbar as one small pill: it opens the folder
    /// picker while importing, and collapses into an accent progress chip
    /// while a copy/move is running. Drag & drop onto the page stays active
    /// everywhere (see `acceptDrop`).
    @ViewBuilder
    private var importButton: some View {
        if let progress = state.importProgress {
            let fraction = min(1, max(0, progress.fraction))
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 11, weight: .semibold))
                Text("导入中 \(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(Native.accent)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Native.accent.opacity(0.14)))
            .overlay(Capsule().stroke(Native.accent.opacity(0.3), lineWidth: 0.8))
            .help(progress.message)
        } else {
            Button {
                pickModelsFolder()
            } label: {
                Label("导入", systemImage: "folder.badge.plus")
            }
            .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            .help("导入本地模型文件夹，或直接把文件夹拖进页面")
        }
    }

    // MARK: Grid

    @ViewBuilder
    private func modelGrid(width: CGFloat) -> some View {
        let shown = filteredEntries
        Group {
            if shown.isEmpty {
                Card {
                    EmptyHint(icon: emptyIcon, title: emptyTitle, detail: emptyDetail)
                }
            } else {
                LazyVGrid(columns: gridColumns(width: width), alignment: .leading, spacing: 14) {
                    ForEach(shown) { entry in
                        card(for: entry)
                    }
                }
            }
        }
        .alert("删除这个模型？",
               isPresented: removeShown,
               presenting: removeTarget) { entry in
            Button("删除", role: .destructive) {
                state.removeModel(entry.model.id, engine: entry.engine)
                removeTarget = nil
            }
            Button("取消", role: .cancel) { removeTarget = nil }
        } message: { entry in
            Text(removalMessage(entry))
        }
        .alert("下载这个模型？",
               isPresented: downloadShown,
               presenting: downloadTarget) { entry in
            Button("下载") {
                downloadTarget = nil
                state.downloadModel(entry.model.id, engine: entry.engine)
            }
            Button("取消", role: .cancel) { downloadTarget = nil }
        } message: { entry in
            Text(downloadMessage(entry))
        }
    }

    private func gridColumns(width: CGFloat) -> [GridItem] {
        let count = width >= 1120 ? 3 : (width >= 600 ? 2 : 1)
        return Array(repeating: GridItem(.flexible(minimum: 0), spacing: 14, alignment: .top),
                     count: count)
    }

    private func card(for entry: ModelLibraryEntry) -> some View {
        let selected = entry.installed
            && entry.engine == state.activeEngine
            && entry.model.id == state.selectedModel
        let tokens = selected ? state.stats?.maximumContextTokens.flatMap { $0 > 0 ? $0 : nil } : nil
        return ModelCardView(
            state: state,
            entry: entry,
            selected: selected,
            contextTokens: tokens,
            device: device,
            draftChoices: entry.engine == .omlx ? state.installedDraftIds(for: entry.engine) : [],
            onUse: { state.useModel(entry.model.id, engine: entry.engine) },
            onReveal: entry.installed && !entry.model.path.isEmpty
                ? { reveal(entry) }
                : nil,
            onRemove: entry.installed
                ? { removeTarget = entry }
                : nil
        )
    }

    private var emptyIcon: String {
        entries.isEmpty ? "shippingbox" : "tray"
    }

    private var emptyTitle: String {
        entries.isEmpty ? "还没有模型" : "没有符合条件的模型"
    }

    private var emptyDetail: String {
        if entries.isEmpty {
            return "\(engine.displayName) 还找不到可用的权重：从「可下载」里挑一个，或点右上「导入」放一个本地文件夹"
        }
        switch filter {
        case .local:
            return localCount == 0
                ? "\(engine.displayName) 下还没有本机模型。切到「可下载」挑一个，或点上方「重新扫描」"
                : "换个筛选条件试试"
        case .remote:
            return remoteCount == 0 ? "推荐模型都已下载到本机" : "换个筛选条件试试"
        case .all:
            return "换个筛选条件试试"
        }
    }

    // MARK: Import

    /// The old dashed import card is gone; the whole page is the drop zone.
    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard state.importProgress == nil,
              let provider = providers.first(where: {
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
            let directory = Self.dropDirectory(url)
            DispatchQueue.main.async {
                if let directory {
                    pendingImport = directory
                } else {
                    state.notice = "请拖入包含 .gguf 或 MLX 权重的文件夹"
                }
            }
        }
        return true
    }

    private static func dropDirectory(_ url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return url }
        if url.pathExtension.lowercased() == "gguf" { return url.deletingLastPathComponent() }
        return nil
    }

    // MARK: Bindings

    private var pendingImportShown: Binding<Bool> {
        Binding(get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } })
    }

    private var removeShown: Binding<Bool> {
        Binding(get: { removeTarget != nil },
                set: { if !$0 { removeTarget = nil } })
    }

    private var downloadShown: Binding<Bool> {
        Binding(get: { downloadTarget != nil },
                set: { if !$0 { downloadTarget = nil } })
    }

    private var pendingLibraryUseShown: Binding<Bool> {
        Binding(get: { state.pendingLibraryUse != nil },
                set: { if !$0 { state.cancelLibraryUse() } })
    }

    // MARK: Messages

    private func downloadMessage(_ entry: ModelLibraryEntry) -> String {
        let model = entry.model
        let destination = entry.engine == .splash
            ? Paths.modelsDirectory
            : ModelInstaller.destination(engine: entry.engine, repo: model.id)
        var lines = [model.id, ""]
        if model.bytes > 0 {
            let size = model.sizeText.trimmingCharacters(in: CharacterSet(charactersIn: "≈"))
            lines.append("下载约 \(size)")
        }
        if let memory = entry.recommendation?.memoryText {
            lines.append("建议 \(memory)")
        }
        lines.append("会放进 \(destination)")
        return lines.joined(separator: "\n")
    }

    private func removalMessage(_ entry: ModelLibraryEntry) -> String {
        if entry.model.path.isEmpty {
            return entry.model.id
        }
        let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.model.path)) != nil
        if isLink {
            return "\(entry.model.id)\n\n这是指向 \(engine.displayName) 权重目录的一个链接，删除只移除链接，原始权重保留。"
        }
        return "\(entry.model.id)\n\n这会删除 \(entry.model.sizeText) 的权重，无法撤销。"
    }

    private func libraryUseMessage(_ request: LibraryUseRequest) -> String {
        let action = request.needsDownload ? "下载到" : "在"
        return "\(request.model) 属于 \(request.engine.displayName)，\(action)\(request.engine.displayName) 的模型库。\n\n切换会先停掉 \(state.activeEngine.displayName)，再以这个模型启动 \(request.engine.displayName)。"
    }

    // MARK: Actions

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
        state.importModel(url.path, move: move, engine: engine)
    }

    private func reveal(_ entry: ModelLibraryEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.model.path)])
    }

    private func openModelsDirectory() {
        let directory = EnginePaths.modelsDirectory(engine)
        Paths.ensureDirectory(directory)
        NSWorkspace.shared.open(URL(fileURLWithPath: directory))
    }
}

// MARK: - Start card

/// What an engine's page shows while it holds nothing to serve: the three Qwen
/// tiers that engine is tuned for, one click each, instead of an empty grid.
private struct LibraryStartCard: View {
    @ObservedObject var state: AppState
    let engine: EngineID
    let installed: Bool
    let device: DeviceProfile
    let entries: [ModelLibraryEntry]
    let onDownload: (ModelLibraryEntry) -> Void

    private var busy: Bool { state.downloadingModel != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                ArcadeIcon(symbol: "sparkles",
                           colors: [Native.accent, Native.pink],
                           size: 38,
                           glyphScale: 0.42)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(engine.displayName) 还没有模型")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Native.label)
                    Text(installed
                         ? "按本机配置挑的 \(engine.displayName) Qwen 档位，下载完就能直接启动。"
                         : "\(engine.displayName) 还没安装，先看看它适配的 Qwen 档位；装好引擎后在这里一键下载。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Native.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("本机：\(device.summary)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Native.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Tag(text: "推荐", tone: .accent, icon: "sparkles")
            }

            VStack(spacing: 8) {
                ForEach(entries.prefix(3)) { entry in
                    row(entry)
                }
            }
        }
        .padding(Native.cardPadding)
        .background {
            GlassSurface(radius: Native.radiusPanel, tint: Native.accent)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Native.radiusPanel, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(Native.accent.opacity(0.28))
        )
    }

    private func row(_ entry: ModelLibraryEntry) -> some View {
        let model = entry.model
        let downloading = state.downloadingModel == model.id && state.downloadingEngine == engine
        let task = state.downloadTasks.first { $0.engine == engine && $0.model == model.id }
        let paused = !downloading && task?.status == .paused
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ModelMeta.displayName(model))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Native.label)
                    .lineLimit(1)
                Text(entry.recommendation?.summary ?? ModelMeta.specLine(model, contextTokens: nil))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if model.bytes > 0 {
                Tag(text: model.sizeText, tone: .neutral, icon: nil)
            }
            if let memory = entry.recommendation?.memoryText {
                Tag(text: memory, tone: .neutral, icon: "memorychip")
            }
            if let recommendation = entry.recommendation {
                switch device.fit(recommendation) {
                case .good:
                    Tag(text: "适配本机", tone: .success, icon: "checkmark")
                case .tight:
                    Tag(text: "内存吃紧", tone: .warning, icon: "exclamationmark.triangle")
                case .diskShort:
                    Tag(text: "空间不足", tone: .danger, icon: "externaldrive.badge.exclamationmark")
                case .unknown:
                    EmptyView()
                }
            }

            if downloading {
                HStack(spacing: 5) {
                    Text(ModelMeta.percent(state.downloadFraction))
                        .font(Native.monoSmall)
                        .foregroundStyle(Native.secondary)
                    ProgressView(value: state.downloadFraction ?? 0)
                        .progressViewStyle(.linear)
                        .frame(width: 56)
                    Button {
                        state.pauseDownload()
                    } label: {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 9.5, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Native.overlay(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("暂停下载（断点续传）")
                }
            } else if paused, let task {
                HStack(spacing: 5) {
                    Text(ModelMeta.percent(task.fraction))
                        .font(Native.monoSmall)
                        .foregroundStyle(Native.secondary)
                    ProgressView(value: task.fraction ?? 0)
                        .progressViewStyle(.linear)
                        .frame(width: 56)
                    Button {
                        state.resumeDownload(task)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9.5, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Native.overlay(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("继续下载")
                }
            } else {
                Button {
                    onDownload(entry)
                } label: {
                    Text("下载")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(ArcadePillStyle(tone: .accent, compact: true))
                .disabled(busy || !installed)
                .help(installed ? "下载到 \(engine.displayName) 的模型库" : "先在「引擎」页安装 \(engine.displayName)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Native.radiusSmall, style: .continuous)
                .fill(Native.overlay(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Native.radiusSmall, style: .continuous)
                .strokeBorder(Native.overlay(0.07), lineWidth: 1)
        )
        .help(model.id)
    }
}

// MARK: - Filter

private enum ModelsFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case local = "本机"
    case remote = "可下载"

    var id: String { rawValue }
}

/// Capsule segmented control for the 全部 / 本机 / 可下载 filter. It replaces the
/// native `.segmented` picker so the toolbar reads in the same glass language
/// as the engine chips above it; the active segment gets the raised pill.
private struct ModelsFilterPicker: View {
    @Binding var selection: ModelsFilter
    let counts: [ModelsFilter: Int]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ModelsFilter.allCases) { item in
                let active = item == selection
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { selection = item }
                } label: {
                    HStack(spacing: 4) {
                        Text(item.rawValue)
                            .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                        if let count = counts[item] {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(active ? Native.label.opacity(0.55) : Native.tertiary)
                        }
                    }
                    .foregroundStyle(active ? Native.label : Native.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Capsule().fill(active ? Native.raised : Color.clear))
                    .overlay(Capsule().strokeBorder(active ? Native.overlay(0.14) : Color.clear, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Native.overlay(0.05)))
        .overlay(Capsule().strokeBorder(Native.overlay(0.08), lineWidth: 1))
    }
}

// MARK: - Card

private struct ModelCardView: View {
    @ObservedObject var state: AppState
    let entry: ModelLibraryEntry
    let selected: Bool
    let contextTokens: Int?
    let device: DeviceProfile
    /// Locally installed DFlash2 draft heads a main model can pair with.
    /// Empty outside oMLX, the only engine with a per-model draft setting.
    var draftChoices: [String] = []
    let onUse: () -> Void
    let onReveal: (() -> Void)?
    let onRemove: (() -> Void)?

    @State private var hovering = false

    private var model: ModelInfo { entry.model }
    private var engine: EngineID { entry.engine }
    private var recommendation: ModelRecommendation? { entry.recommendation }
    private var draftRepository: String? { entry.draftRepository }

    private var installed: Bool { entry.installed }
    private var downloading: Bool {
        state.downloadingModel == model.id && state.downloadingEngine == engine
    }
    /// This card's center row, when the transfer is not running right now.
    private var task: ModelDownloadTask? {
        state.downloadTasks.first { $0.engine == engine && $0.model == model.id }
    }
    private var paused: Bool { !downloading && task?.status == .paused }
    private var busy: Bool { state.downloadingModel != nil }
    private var draftReady: Bool {
        installed && (model.draftPath != nil || draftRepository != nil)
    }
    /// The draft this card's model is bound to, if any.
    private var assignedDraft: String? {
        state.draftAssignment(for: engine, model: model.id)
    }
    /// Whether the draft pairing can be edited from this card: only oMLX has a
    /// per-model draft setting, and a draft never pairs with another draft.
    private var supportsDraftAssignment: Bool {
        engine == .omlx && installed && !entry.isDraft && !draftChoices.isEmpty
    }
    /// A suggestion from another engine can only be used by switching to it, so
    /// the primary action says which engine it will start.
    private var useTitle: String {
        engine == state.activeEngine ? "使用" : "切到 \(engine.displayName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Text(specLine)
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
            } else if paused, let task {
                pausedBlock(task)
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

    private var specLine: String {
        // A suggestion's size and memory floor come from the Hub page, and its
        // MoE/dense nature from the curation table rather than from a folder
        // name, so the heuristics that read installed folders would mislead.
        if let recommendation {
            var parts: [String] = []
            if let params = ModelMeta.params(model) { parts.append(params) }
            if model.bytes > 0 { parts.append(model.sizeText) }
            let quant = ModelMeta.quant(model)
            if !quant.isEmpty { parts.append(quant) }
            if let memory = recommendation.memoryText { parts.append(memory) }
            return parts.joined(separator: " · ")
        }
        return ModelMeta.specLine(model, contextTokens: contextTokens)
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
        var seen = Set<String>()
        func add(_ text: String, _ tone: TagTone, _ icon: String?) {
            guard seen.insert(text.lowercased()).inserted else { return }
            result.append(ModelTagSpec(text: text, tone: tone, icon: icon))
        }

        // Device fit first: it is the verdict the page is asked for.
        if let recommendation, !installed {
            switch device.fit(recommendation) {
            case .good:
                add("适配本机", .success, "memorychip")
            case .tight:
                add("内存吃紧", .warning, "exclamationmark.triangle")
            case .diskShort:
                add("空间不足", .danger, "externaldrive.badge.exclamationmark")
            case .unknown:
                break
            }
        }
        if draftReady {
            add("DFlash2 就绪", .success, "bolt.fill")
        } else if let assigned = assignedDraft {
            add("辅助 \(shortName(assigned))", .accent, "bolt.fill")
        } else if draftRepository != nil {
            add("DFlash2 可下载", .accent, "bolt")
        } else if engine == .splash {
            add("标准解码", .neutral, nil)
        } else {
            // The pack engines decode with the model's own MTP head, so their
            // weights never need a separate draft repository.
            add("MTP 解码", .neutral, "bolt")
        }
        let vision = ModelMeta.isVision(model)
            || (recommendation?.tags.contains { $0.contains("视觉") } ?? false)
        if vision { add("视觉", .neutral, "eye") }
        let moe = ModelMeta.isMoE(model)
            || (recommendation?.tags.contains { $0.lowercased().contains("moe") } ?? false)
        if moe { add("MoE", .neutral, nil) }
        if let active = ModelMeta.activeParams(model) {
            add("\(active) 激活", .neutral, nil)
        }
        if model.bytes > 0 && model.bytes < 6_000_000_000 {
            add("轻量", .neutral, nil)
        }
        // The pack's own labels (quant, MTP, DFlash2) last, minus whatever the
        // heuristics above already said in different words.
        for tag in recommendation?.tags ?? [] where !tagIsCovered(tag) {
            add(tag, .neutral, nil)
        }
        if installed {
            add(model.origin == .splash ? "Splash" : "本机", .neutral, nil)
        }
        return result
    }

    /// Tags the heuristic rows above already cover, so a card does not repeat
    /// itself: `DFlash2` is the draft tag, `MoE`/`视觉` their own tags, and the
    /// format labels duplicate the spec line.
    private func tagIsCovered(_ tag: String) -> Bool {
        let lower = tag.lowercased()
        if lower.contains("dflash") || lower == "moe" || lower == "视觉" || lower == "mtp" { return true }
        return lower.contains("mlx") || lower.contains("bit") || lower == "gguf"
    }

    @ViewBuilder
    private var actions: some View {
        if installed {
            HStack(spacing: 7) {
                if entry.isDraft {
                    // Draft weights cannot be served on their own — they ride
                    // along with the main model they are paired with.
                    HStack(spacing: 5) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("辅助模型 · 依附主模型")
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Native.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 33)
                    .background(Capsule().fill(Native.overlay(0.05)))
                    .overlay(Capsule().stroke(Native.overlay(0.10), lineWidth: 0.8))
                    .help("这是投机解码的 draft 权重，由主模型在「… → DFlash2 辅助模型」里指定后随其加载，不单独启动")
                } else if selected {
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
                        Label(useTitle, systemImage: "play.fill")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ArcadePillStyle(tone: .light))
                    .disabled(busy)
                }

                if onReveal != nil || onRemove != nil {
                    Menu {
                        if let onReveal {
                            Button {
                                onReveal()
                            } label: {
                                Label("在 Finder 中显示", systemImage: "folder")
                            }
                        }
                        if onReveal != nil && onRemove != nil {
                            Divider()
                        }
                        if let onRemove {
                            Button(role: .destructive) {
                                onRemove()
                            } label: {
                                Label("删除模型", systemImage: "trash")
                            }
                        }
                        if supportsDraftAssignment {
                            Divider()
                            draftMenu
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
            HStack(spacing: 7) {
                Button {
                    onUse()
                } label: {
                    Label {
                        Text("下载")
                    } icon: {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ArcadePillStyle(tone: .accent))
                .disabled(busy)
                .help("下载到 \(engine.displayName) 的模型库")
            }
        }
    }

    /// Pick which DFlash2 draft head runs with this model. "跟随引擎设置" clears
    /// the override; a named draft binds it, and oMLX reloads to apply.
    @ViewBuilder
    private var draftMenu: some View {
        Menu {
            Button {
                state.setDraftAssignment(nil, engine: engine, model: model.id)
            } label: {
                Label(assignedDraft == nil ? "✓ 跟随引擎设置" : "跟随引擎设置",
                      systemImage: "wand.and.stars")
            }
            if !draftChoices.isEmpty {
                Divider()
            }
            ForEach(draftChoices, id: \.self) { draft in
                Button {
                    state.setDraftAssignment(draft, engine: engine, model: model.id)
                } label: {
                    Label(assignedDraft == draft ? "✓ \(shortName(draft))" : shortName(draft),
                          systemImage: assignedDraft == draft ? "checkmark" : "bolt.fill")
                }
            }
        } label: {
            Label("DFlash2 辅助模型", systemImage: "bolt.badge.clock")
        }
    }

    /// Last path segment of a model id, for menus and tags.
    private func shortName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
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
                miniIcon("pause.fill", "暂停下载（断点续传）") { state.pauseDownload() }
                miniIcon("xmark", "取消下载") {
                    if let task { state.cancelDownload(task) }
                }
            }
            Meter(fraction: state.downloadFraction ?? 0, tint: Native.accent)
            Text(downloadStatusLine)
                .font(.system(size: 10))
                .foregroundStyle(Native.tertiary)
        }
    }

    /// Paused transfers keep the meter on the card, in the progress recorded
    /// when the downloader was stopped.
    private func pausedBlock(_ task: ModelDownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Native.orange)
                Text("已暂停 · 断点续传")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                Text(ModelMeta.percent(task.fraction))
                    .font(Native.monoSmall)
                    .foregroundStyle(Native.secondary)
                miniIcon("play.fill", "继续下载") { state.resumeDownload(task) }
                miniIcon("xmark", "从下载中心移除") { state.cancelDownload(task) }
            }
            Meter(fraction: task.fraction ?? 0, tint: Native.orange)
            Text(downloadStatusLine(for: task))
                .font(.system(size: 10))
                .foregroundStyle(Native.tertiary)
        }
    }

    private func miniIcon(_ systemName: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Native.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Native.overlay(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var downloadStatusLine: String {
        if let task {
            return downloadStatusLine(for: task)
        }
        return engine == state.activeEngine ? "完成后自动切换" : "完成后可在 \(engine.displayName) 里启动"
    }

    private func downloadStatusLine(for task: ModelDownloadTask) -> String {
        var parts: [String] = []
        if task.totalBytes > 0 {
            parts.append("\(Format.bytes(task.downloadedBytes)) / \(Format.bytes(task.totalBytes))")
        }
        if downloading, state.downloadSpeed > 0 {
            parts.append(Format.rate(state.downloadSpeed))
        }
        if parts.isEmpty {
            return engine == state.activeEngine ? "完成后自动切换" : "完成后可在 \(engine.displayName) 里启动"
        }
        return parts.joined(separator: " · ")
    }
}

private struct ModelTagSpec {
    let text: String
    let tone: TagTone
    let icon: String?
}

// MARK: - Download center

/// Every model download flashCat knows about: the running transfer with live
/// progress, plus paused and failed rows that can be resumed or dropped.
/// Paused rows survive relaunches — the Hub's partial files stay in the
/// destination's `.cache`, so 继续 never starts from zero.
private struct DownloadCenterSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Native.accent)
                Text("下载中心")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 6)
                if state.downloadingModel != nil {
                    Text("同时只进行一个下载，其余任务可暂停后排队")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Native.tertiary)
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Native.overlay(0.08)))
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider().overlay(Native.overlay(0.08))

            if state.downloadTasks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 22))
                        .foregroundStyle(Native.tertiary)
                    Text("没有下载任务")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("在模型卡片或「可下载」里点下载，进度会显示在这里")
                        .font(.system(size: 11))
                        .foregroundStyle(Native.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(state.downloadTasks) { task in
                            DownloadTaskRow(state: state, task: task)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 560, height: state.downloadTasks.isEmpty ? 240 : 420)
        .background(GlassSurface(radius: Native.radiusPanel))
    }
}

private struct DownloadTaskRow: View {
    @ObservedObject var state: AppState
    let task: ModelDownloadTask

    private var running: Bool {
        state.downloadingModel == task.model && state.downloadingEngine == task.engine
    }
    private var fraction: Double? {
        running ? state.downloadFraction : task.fraction
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(ModelMeta.shortName(ModelMeta.displayID(task.model)))
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .help(task.model)
                    Tag(text: task.engine.displayName, tone: .neutral, icon: nil)
                    statusTag
                }
                if let fraction {
                    Meter(fraction: fraction,
                          tint: running ? Native.accent : (task.status == .failed ? Native.red : Native.orange))
                }
                Text(detailLine)
                    .font(.system(size: 10))
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if running {
                    rowButton("pause.fill", "暂停（断点续传）") { state.pauseDownload() }
                    rowButton("xmark", "取消下载") { state.cancelDownload(task) }
                } else if task.status == .paused {
                    rowButton("play.fill", "继续下载") { state.resumeDownload(task) }
                    rowButton("xmark", "从下载中心移除") { state.cancelDownload(task) }
                } else if task.status == .failed {
                    rowButton("arrow.clockwise", "重试") { state.resumeDownload(task) }
                    rowButton("xmark", "从下载中心移除") { state.removeTask(task) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Native.radiusSmall, style: .continuous)
                .fill(Native.overlay(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Native.radiusSmall, style: .continuous)
                .strokeBorder(Native.overlay(0.07), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusTag: some View {
        if running {
            Tag(text: "下载中", tone: .accent, icon: nil)
        } else {
            switch task.status {
            case .paused: Tag(text: "已暂停", tone: .warning, icon: "pause")
            case .failed: Tag(text: "失败", tone: .danger, icon: "exclamationmark.triangle")
            case .downloading: Tag(text: "排队", tone: .neutral, icon: "clock")
            }
        }
    }

    private var detailLine: String {
        var parts: [String] = []
        if task.totalBytes > 0 {
            parts.append("\(Format.bytes(running ? Int((state.downloadFraction ?? 0) * Double(task.totalBytes)) : task.downloadedBytes)) / \(Format.bytes(task.totalBytes))")
        }
        if running, state.downloadSpeed > 0 {
            parts.append(Format.rate(state.downloadSpeed))
        }
        if parts.isEmpty {
            if running {
                // A running Splash transfer reports nothing until the Hub
                // resolver finishes and tqdm starts redrawing; say that
                // instead of the queued-row text.
                parts.append("已启动，等待下载器报告进度…")
            } else {
                switch task.status {
                case .paused: parts.append("已暂停，继续后从断点接着下")
                case .failed: parts.append("上次下载失败，可重试")
                case .downloading: parts.append("等待当前下载结束")
                }
            }
        }
        return parts.joined(separator: " · ")
    }

    private func rowButton(_ systemName: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Native.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Native.overlay(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
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
    /// Pack engines name models `owner--repo` (their flat link folders); show
    /// them the way the Hub writes them.
    static func displayID(_ id: String) -> String {
        id.replacingOccurrences(of: "--", with: "/")
    }

    static func owner(_ model: ModelInfo) -> String {
        if let first = displayID(model.id).split(separator: "/").first {
            return String(first)
        }
        switch model.origin {
        case .local: return "flashCat"
        case .splash: return "Splash"
        case .recommended: return "Hub"
        }
    }

    static func displayName(_ model: ModelInfo) -> String {
        shortName(displayID(model.id))
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
        if id.contains("moe") || id.contains("flash-next") { return true }
        return ModelPattern.test("a[0-9]+(?:\\.[0-9]+)?b", id)
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
