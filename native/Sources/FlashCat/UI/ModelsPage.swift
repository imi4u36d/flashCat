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

    private var entries: [ModelLibraryEntry] {
        let base: [ModelLibraryEntry]
        switch scope {
        case .all:
            base = EngineCatalog.allIDs.flatMap { state.libraryEntries(for: $0) }
        case .engine(let id):
            base = state.libraryEntries(for: id)
        }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return base }
        return base.filter { "\($0.model.shortName) \($0.model.id)".lowercased().contains(text) }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 440, maximum: 720), spacing: 18, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                topBar
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(entries) { entry in
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
            .padding(.top, 78)
            .padding(.bottom, 26)
        }
        .scrollIndicators(.never)
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
            NativeSegmented(selection: $scope, options: [ModelScope.all] + EngineCatalog.allIDs.map { ModelScope.engine($0) },
                            labels: ["全部"] + EngineCatalog.allIDs.map(\.displayName))
                .frame(maxWidth: 560)
            .background(Capsule().fill(Console.card.opacity(0.72)))
            .overlay(Capsule().strokeBorder(Console.cardStroke, lineWidth: 0.8))

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Console.tertiary)
                TextField("搜索模型", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Console.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Capsule().fill(Console.card.opacity(0.72)))
            .overlay(Capsule().strokeBorder(Console.cardStroke, lineWidth: 0.8))
            .frame(maxWidth: 380)

            Spacer(minLength: 0)

            Button {
                showingHub = true
                state.searchHub(state.hubQuery, sort: state.hubSort.rawValue,
                                filter: state.hubFilter.rawValue, page: 0)
            } label: {
                Label("模型广场", systemImage: "sparkle.magnifyingglass")
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
                    .background(Circle().fill(Console.card.opacity(0.75)))
                    .overlay(Circle().strokeBorder(Console.cardStroke, lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .help("重新扫描")
        }
    }

    private func isSelected(_ entry: ModelLibraryEntry) -> Bool {
        entry.installed && entry.engine == state.activeEngine && entry.model.id == state.selectedModel
    }

    private var removalMessage: String {
        guard let entry = removeTarget else { return "" }
        if entry.model.path.isEmpty { return entry.model.id }
        return "会删除 \(entry.model.sizeText) 的权重，无法恢复。"
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
    private var accent: Color { engineAccent(entry.engine) }
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
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(alignment: .leading, spacing: 6) {
                Text(displayTitle)
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(Console.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.id)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Console.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            SpecTable(items: [
                ("ENGINE", entry.engine.displayName),
                ("FORMAT", formatName),
                ("SIZE", model.bytes > 0 ? model.sizeText : "—"),
            ])
            tags
            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Console.tertiary)
                Text(memoryText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Console.secondary)
                Spacer(minLength: 0)
                action
            }
        }
        .padding(20)
        .background {
            let shape = RoundedRectangle(cornerRadius: Console.cardRadius, style: .continuous)
            shape
                .fill(Console.card)
                .overlay {
                    shape.fill(LinearGradient(colors: [cardTint.opacity(selected ? 0.16 : 0.10), .clear],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay { shape.strokeBorder(cardEdge, lineWidth: 1) }
                .shadow(color: Console.shadow, radius: hovering ? 26 : 18, y: hovering ? 12 : 8)
        }
        .onHover { value in withAnimation(Motion.quick) { hovering = value } }
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

    private var formatName: String {
        if entry.engine == .mtplx { return "MTPLX" }
        let id = model.id.lowercased()
        if id.contains("gguf") || (entry.recommendation?.tags.contains("GGUF") ?? false) { return "GGUF" }
        if entry.engine == .omlx || entry.engine == .mlxServe { return "MLX" }
        return "GGUF"
    }

    private var cardTint: Color {
        if selected { return Console.accent }
        if activeFraction != nil || task != nil { return Console.warn }
        return .clear
    }

    private var cardEdge: Color {
        if selected { return Console.accent.opacity(0.45) }
        if activeFraction != nil || task != nil { return Console.warn.opacity(0.35) }
        return Console.cardStroke
    }

    private var header: some View {
        HStack(spacing: 10) {
            LetterTile(letter: String(entry.engine.displayName.prefix(1)).uppercased(),
                       color: accent, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.engine.displayName)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Console.text)
                Text(familyName)
                    .font(.system(size: 10.5))
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
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Console.inset))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var familyName: String {
        let id = model.id.lowercased()
        if id.contains("qwen") { return "Qwen" }
        if id.contains("mimo") { return "Xiaomi MiMo" }
        if id.contains("deepseek") { return "DeepSeek" }
        if id.contains("llama") { return "Llama" }
        if let family = model.family, !family.isEmpty, family != "GGUF", family != "MLX" { return family }
        return entry.recommendation?.tags.first ?? "本地权重"
    }

    private var tags: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            ForEach(tagTexts.prefix(5), id: \.self) { tag in
                ConsoleTag(text: tag)
            }
        }
    }

    private var tagTexts: [String] {
        var values: [String] = []
        if let quant = entry.recommendation?.tags.first(where: { $0.contains("Q") || $0.contains("bpw") }) {
            values.append(quant)
        }
        if let tags = entry.recommendation?.tags {
            values.append(contentsOf: tags.filter { !values.contains($0) })
        }
        if entry.draftRepository != nil { values.append("DFlash2") }
        if ModelSharing.isShared(model.id) { values.append("共享") }
        if entry.uncatalogued { values.append("未收录") }
        return values.isEmpty ? ["本地"] : values
    }

    private var memoryText: String {
        if let memory = entry.recommendation?.minimumMemory, memory > 0 {
            return "\(memory) GB 内存起"
        }
        return "内存需求未标注"
    }

    @ViewBuilder private var action: some View {
        if let fraction = activeFraction {
            Button {
                state.pauseDownload()
            } label: {
                Label("下载 \(Int((fraction * 100).rounded()))%", systemImage: "pause.fill")
            }
            .buttonStyle(ConsolePillStyle(tone: .secondary))
        } else if let task {
            Button {
                state.resumeDownload(task)
            } label: {
                Label(task.status == .paused ? "继续 \(Int((task.fraction ?? 0) * 100))%" : "重试",
                      systemImage: "play.fill")
            }
            .buttonStyle(ConsolePillStyle(tone: .secondary))
        } else if entry.installed {
            if selected {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .semibold))
                    Text("使用中")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Console.accent)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(Console.accent.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Console.accent.opacity(0.25), lineWidth: 0.8))
            } else {
                Button {
                    state.useModel(model.id, engine: entry.engine)
                } label: {
                    Label("使用", systemImage: "play.fill")
                }
                .buttonStyle(ConsolePillStyle(tone: .success))
            }
        } else {
            Button {
                state.downloadModel(model.id, engine: entry.engine)
            } label: {
                Label("下载", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.consoleSecondary)
            .disabled(state.downloadingModel != nil)
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
