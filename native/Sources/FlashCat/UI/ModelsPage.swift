import SwiftUI
import AppKit
import FlashCatKit

/// 模型页：按引擎浏览模型库、下载/使用权重、模型广场与下载中心。
struct ModelsPage: View {
    @ObservedObject var state: AppState
    let engine: EngineID
    @Binding var showingHub: Bool
    @Binding var showingDownloads: Bool

    @State private var filter: ModelsFilter = .all
    @State private var removeTarget: ModelLibraryEntry?
    @State private var device = DeviceProfile.current()

    private var entries: [ModelLibraryEntry] { state.libraryEntries(for: engine) }
    private var installedEntries: [ModelLibraryEntry] { entries.filter(\.installed) }
    private var downloadableEntries: [ModelLibraryEntry] {
        entries.filter(\.downloadable).sorted { deviceOrder($0) < deviceOrder($1) }
    }
    private var filteredEntries: [ModelLibraryEntry] {
        switch filter {
        case .all: return entries
        case .local: return installedEntries
        case .remote: return downloadableEntries
        }
    }

    private var engineInstalled: Bool { state.availableEngines.contains(engine) }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 330, maximum: 620), spacing: Native.gap, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "模型",
                           subtitle: "每个引擎一份模型库；没装的引擎也能先看它能跑什么",
                           eyebrow: "MODEL LIBRARY") {
                    Button {
                        showingHub = true
                        state.searchHub(state.hubQuery, sort: state.hubSort.rawValue,
                                        filter: state.hubFilter.rawValue, page: 0)
                    } label: {
                        Label("模型广场", systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(.arcadePill)

                    Button {
                        showingDownloads = true
                    } label: {
                        Label(downloadCenterTitle, systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.arcadeGlass)
                }
                .padding(.top, 30)

                engineScope
                toolbar

                if !engineInstalled {
                    installHint
                }

                if filter != .remote && installedEntries.isEmpty && !downloadableEntries.isEmpty {
                    startCard
                }

                if filteredEntries.isEmpty {
                    EmptyHint(icon: "shippingbox",
                              title: installedEntries.isEmpty ? "还没有模型" : "没有符合条件的模型",
                              detail: installedEntries.isEmpty
                                ? "从「可下载」里挑一个，或点右上「模型广场」搜一个"
                                : "换个筛选条件试试")
                        .padding(.vertical, 30)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Native.gap) {
                        ForEach(filteredEntries) { entry in
                            ModelCard(state: state,
                                      entry: entry,
                                      selected: isSelected(entry),
                                      device: device,
                                      remove: { removeTarget = entry })
                        }
                    }
                }
            }
            .padding(.horizontal, Native.pagePadding)
            .padding(.bottom, 30)
            .pageColumn()
            .animation(.easeOut(duration: 0.18), value: engine)
        }
        .scrollIndicators(.never)
        .onChange(of: state.libraryEngine) { _, _ in filter = .all }
        .sheet(isPresented: $showingHub) {
            HubSheet(state: state, engine: engine)
        }
        .sheet(isPresented: $showingDownloads) {
            DownloadCenterSheet(state: state)
        }
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

    private var downloadCenterTitle: String {
        if let fraction = state.downloadFraction, state.downloadingModel != nil {
            return "下载中 \(Int((fraction * 100).rounded()))%"
        }
        let count = state.downloadTasks.count
        return count > 0 ? "下载中心 \(count)" : "下载中心"
    }

    private func isSelected(_ entry: ModelLibraryEntry) -> Bool {
        entry.installed && entry.engine == state.activeEngine && entry.model.id == state.selectedModel
    }

    private func deviceOrder(_ entry: ModelLibraryEntry) -> (Int, Int) {
        guard let recommendation = entry.recommendation else { return (1, -entry.model.bytes) }
        switch device.fit(recommendation) {
        case .good: return (0, -recommendation.minimumMemory)
        case .unknown: return (1, recommendation.minimumMemory)
        case .tight: return (2, recommendation.minimumMemory)
        case .diskShort: return (3, recommendation.bytes)
        }
    }

    // MARK: Scope + toolbar

    private var engineScope: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(EngineCatalog.allIDs, id: \.self) { id in
                    engineChip(id)
                }
            }
            .padding(3)
            .background(Capsule().fill(Native.overlay(0.05)))

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
            } else if engineInstalled {
                Button {
                    Task { @MainActor in await state.switchEngine(engine) }
                } label: {
                    Label("切到 \(engine.displayName)", systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            } else {
                Button {
                    state.section = .engines
                } label: {
                    Label("去安装 \(engine.displayName)", systemImage: "arrow.down.circle")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            }
        }
    }

    private func engineChip(_ id: EngineID) -> some View {
        let active = id == engine
        let running = id == state.activeEngine && state.isRunning
        let installed = state.availableEngines.contains(id)
        return Button {
            state.browseEngine(id)
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(running ? Native.mint : (installed ? Native.overlay(0.3) : Native.overlay(0.14)))
                    .frame(width: 5, height: 5)
                Text(id.displayName)
                    .font(.system(size: 11, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? Native.label : (installed ? Native.secondary : Native.tertiary))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(active ? Native.raised : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(installed ? "查看 \(id.displayName) 的模型库" : "\(id.displayName) 还没安装，先看它能跑什么")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $filter) {
                ForEach(ModelsFilter.allCases) { item in
                    Text("\(item.label) \(count(item))").tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            HStack(spacing: 5) {
                Image(systemName: "memorychip")
                    .font(.system(size: 9.5, weight: .bold))
                Text("\(device.chipName) · \(device.memoryGB) GB")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(Native.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Native.overlay(0.05)))

            Spacer(minLength: 4)

            Button {
                _ = EngineModelStore.adoptExistingWeights(engine)
                state.reloadModels()
                Task { @MainActor in
                    await state.engines?.controller(engine)?.rescanModels()
                    state.reloadModels()
                }
                state.toast("已重新扫描 \(engine.displayName) 的模型目录")
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            .help("重新扫描模型目录")

            Button {
                let directory = EnginePaths.modelsDirectory(engine)
                Paths.ensureDirectory(directory)
                NSWorkspace.shared.open(URL(fileURLWithPath: directory))
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            .help("打开模型目录")
        }
    }

    private func count(_ item: ModelsFilter) -> Int {
        switch item {
        case .all: return entries.count
        case .local: return installedEntries.count
        case .remote: return downloadableEntries.count
        }
    }

    private var installHint: some View {
        Card("\(engine.displayName) 还没安装",
             subtitle: "可以先浏览它的模型库；装好运行时才能启动和解码",
             tint: Native.orange) {
            HStack(spacing: 10) {
                Text(engine.descriptor.summary)
                    .font(Native.bodyFont)
                    .foregroundStyle(Native.secondary)
                Spacer(minLength: 8)
                Button("去引擎页安装") { state.section = .engines }
                    .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            }
        }
    }

    private var startCard: some View {
        Card("\(engine.displayName) 的推荐档位",
             subtitle: "按这台 Mac 的内存与磁盘排序，点一下开始下载") {
            VStack(spacing: 0) {
                ForEach(downloadableEntries.prefix(4)) { entry in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.model.shortName)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Native.label)
                            Text(entry.recommendation?.summary ?? entry.model.id)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Native.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Tag(text: fitLabel(entry), tone: fitTone(entry))
                        Text(entry.model.sizeText)
                            .font(Native.monoSmall)
                            .foregroundStyle(Native.secondary)
                        Button("下载") { state.downloadModel(entry.model.id, engine: entry.engine) }
                            .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                    }
                    .padding(.vertical, 7)
                    if entry.id != downloadableEntries.prefix(4).last?.id { Hairline() }
                }
            }
        }
    }

    private func fitLabel(_ entry: ModelLibraryEntry) -> String {
        guard let recommendation = entry.recommendation else { return "未标注" }
        switch device.fit(recommendation) {
        case .good: return "适配本机"
        case .unknown: return "未知"
        case .tight: return "内存紧"
        case .diskShort: return "磁盘不足"
        }
    }

    private func fitTone(_ entry: ModelLibraryEntry) -> TagTone {
        guard let recommendation = entry.recommendation else { return .neutral }
        switch device.fit(recommendation) {
        case .good: return .success
        case .unknown: return .neutral
        case .tight: return .warning
        case .diskShort: return .danger
        }
    }

    private var removalMessage: String {
        guard let entry = removeTarget else { return "" }
        if entry.model.path.isEmpty { return entry.model.id }
        return "会从 \(entry.engine.displayName) 的模型目录里删除 \(entry.model.sizeText) 的权重，无法恢复。"
    }
}

enum ModelsFilter: String, CaseIterable, Identifiable {
    case all, local, remote
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "全部"
        case .local: return "本机"
        case .remote: return "可下载"
        }
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
        guard state.downloadingModel != nil,
              state.downloadingEngine == entry.engine,
              let running = state.downloadingModel,
              ModelSharing.canonical(running) == ModelSharing.canonical(entry.id) else { return nil }
        return state.downloadFraction ?? 0
    }

    var body: some View {
        HoverSurface(radius: Native.radiusPanel,
                     accent: familyColor,
                     active: selected,
                     padding: Native.cardPadding) {
            VStack(alignment: .leading, spacing: 10) {
                header
                tags
                if entry.installed {
                    installedActions
                } else {
                    downloadActions
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(familyColor.opacity(0.16))
                Text(String(model.shortName.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(familyColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.shortName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Native.label)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.id)
                    .font(Native.monoSmall)
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(specLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if selected {
                Tag(text: "使用中", tone: .success, icon: "checkmark")
            }
        }
    }

    private var familyColor: Color {
        if let family = model.family, !family.isEmpty {
            switch family.lowercased() {
            case "qwen": return Native.violet
            case "mimo", "xiaomi": return Native.orange
            case "deepseek": return Native.blue
            case "llama": return Native.indigo
            case "gemma": return Native.mint
            case "kimi": return Native.purple
            case "glm": return Native.cyan
            default: return Native.accent
            }
        }
        return Native.accent
    }

    private var specLine: String {
        var parts: [String] = []
        if model.bytes > 0 { parts.append(model.sizeText) }
        if let memory = entry.recommendation?.minimumMemory, memory > 0 {
            parts.append("\(memory) GB 内存起")
        }
        parts.append(entry.installed ? "本机" : "未下载")
        return parts.joined(separator: " · ")
    }

    private var tags: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            if entry.recommendation != nil {
                Tag(text: fitLabel, tone: fitTone)
            }
            if let tag = state.recommendationTag(for: entry.model.id, engine: entry.engine) {
                Tag(text: tag, tone: .accent)
            }
            ForEach(entry.recommendation?.tags.prefix(3) ?? [], id: \.self) { tag in
                Tag(text: tag, tone: .neutral)
            }
            if entry.draftRepository != nil {
                Tag(text: "DFlash2", tone: .warning, icon: "bolt.fill")
            }
            if entry.uncatalogued {
                Tag(text: "未收录", tone: .neutral)
            }
            if ModelSharing.isShared(entry.model.id) {
                Tag(text: "共享", tone: .success, icon: "link")
            }
        }
    }

    private var fitLabel: String {
        guard let recommendation = entry.recommendation else { return "未标注" }
        switch device.fit(recommendation) {
        case .good: return "适配本机"
        case .unknown: return "未知"
        case .tight: return "内存紧"
        case .diskShort: return "磁盘不足"
        }
    }

    private var fitTone: TagTone {
        guard let recommendation = entry.recommendation else { return .neutral }
        switch device.fit(recommendation) {
        case .good: return .success
        case .unknown: return .neutral
        case .tight: return .warning
        case .diskShort: return .danger
        }
    }

    // MARK: Actions

    private var installedActions: some View {
        HStack(spacing: 8) {
            if selected && entry.engine == state.activeEngine {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("正在使用")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(state.activeEngine.displayName)
                        .font(Native.monoSmall)
                        .foregroundStyle(Native.accent.opacity(0.75))
                }
                .foregroundStyle(Native.accent)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .frame(maxWidth: .infinity)
                .background {
                    Capsule().fill(Native.accent.opacity(0.10))
                        .overlay(Capsule().strokeBorder(Native.accent.opacity(0.22), lineWidth: 0.8))
                }
            } else {
                Button {
                    state.useModel(model.id, engine: entry.engine)
                } label: {
                    Text("使用")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.arcadePill)
            }

            if entry.engine == .omlx, !state.installedDraftIds(for: entry.engine).isEmpty {
                draftMenu
            }

            Menu {
                if ModelSharing.isShared(model.id) {
                    Menu("授权给引擎") {
                        ForEach(EngineCatalog.allIDs, id: \.self) { id in
                            Toggle(id.displayName, isOn: Binding(
                                get: { ModelSharing.engines(for: model.id).contains(id) },
                                set: { on in
                                    var engines = ModelSharing.engines(for: model.id)
                                    if on { engines.insert(id) } else { engines.remove(id) }
                                    state.setSharedEngines(Array(engines), repo: model.id)
                                }))
                        }
                    }
                }
                if !model.path.isEmpty {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.path)])
                    }
                }
                Button("复制模型 ID") { state.copy(model.id, label: "模型 ID 已复制") }
                Divider()
                Button("删除权重…", role: .destructive, action: remove)
            } label: {
                IconMenuLabel(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var draftMenu: some View {
        Menu {
            Button("跟随引擎默认") {
                state.setDraftAssignment(nil, engine: entry.engine, model: model.id)
            }
            ForEach(state.installedDraftIds(for: entry.engine), id: \.self) { draft in
                Button(state.draftAssignment(for: entry.engine, model: model.id) == draft
                       ? "✓ \(draft)" : draft) {
                    state.setDraftAssignment(draft, engine: entry.engine, model: model.id)
                }
            }
        } label: {
            IconMenuLabel(systemName: "bolt.badge.automatic")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("选择这条模型使用的 DFlash2 草稿")
    }

    @ViewBuilder private var downloadActions: some View {
        if let fraction = activeFraction {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("下载中 \(Int((fraction * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Native.accent)
                        Spacer(minLength: 0)
                        Text(Format.rate(state.downloadSpeed))
                            .font(Native.monoSmall)
                            .foregroundStyle(Native.tertiary)
                    }
                    Meter(fraction: fraction, tint: Native.accent)
                }
                Button("暂停") { state.pauseDownload() }
                    .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            }
        } else if let task {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.status == .paused ? "已暂停" : "下载失败")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(task.status == .paused ? Native.secondary : Native.red)
                    Text(progressText(task))
                        .font(Native.monoSmall)
                        .foregroundStyle(Native.tertiary)
                }
                Spacer(minLength: 4)
                Button("继续") { state.resumeDownload(task) }
                    .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                Button {
                    state.cancelDownload(task)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(ArcadePillStyle(tone: .quietDanger, compact: true))
                .help("取消并清理半成品")
            }
        } else {
            HStack(spacing: 8) {
                Button {
                    state.downloadModel(model.id, engine: entry.engine)
                } label: {
                    Label("下载", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.arcadePill)
                .disabled(state.downloadingModel != nil)
            }
        }
    }

    private func progressText(_ task: ModelDownloadTask) -> String {
        var parts: [String] = []
        if task.downloadedBytes > 0 { parts.append(Format.bytes(task.downloadedBytes)) }
        if task.totalBytes > 0 { parts.append("共 \(Format.bytes(task.totalBytes))") }
        if let fraction = task.fraction { parts.append("\(Int((fraction * 100).rounded()))%") }
        return parts.isEmpty ? task.model : parts.joined(separator: " · ")
    }
}
