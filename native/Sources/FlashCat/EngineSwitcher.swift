import SwiftUI
import FlashCatKit

/// Compact engine picker. Shown in the sidebar card whenever more than one
/// runtime pack is installed; splash is always present.
struct EngineSwitcherRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 3) {
            ForEach(state.availableEngines, id: \.self) { id in
                chip(id)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Native.overlay(0.045))
        }
    }

    private func chip(_ id: EngineID) -> some View {
        let active = state.activeEngine == id
        return Button {
            state.switchEngine(id)
        } label: {
            Text(id.displayName)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(active ? Native.pillText : Native.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Native.accent : .clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(active ? "当前引擎" : "切换到 \(id.displayName)")
        .accessibilityLabel("切换到 \(id.displayName)")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

/// Model list for pack-based engines. These weights are symlinks into folders
/// the user already had, so there is no download UI here — only what is on disk.
struct EngineModelsPanel: View {
    @ObservedObject var state: AppState
    @State private var query = ""

    private var models: [EngineModel] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = state.engineModels()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.id.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Native.cyan)
                Text("这些模型来自你本机已有的权重目录，flashCat 只建立链接，不复制、不下载。")
                    .font(.system(size: 11))
                    .foregroundStyle(Native.tertiary)
                Spacer(minLength: 4)
                Button("重新扫描") {
                    EngineModelLinker.synchronize(state.activeEngine)
                    state.reloadModels()
                    state.objectWillChange.send()
                    state.toast("已重新扫描 \(state.activeEngine.displayName) 模型")
                }
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            }
            .padding(12)
            .background { GlassSurface(radius: 14, tint: .clear, elevated: false) }

            if models.isEmpty {
                Text("在 \(EnginePaths.modelsDirectory(state.activeEngine)) 里没有找到可用模型。点「重新扫描」从你已有的模型目录建立链接。")
                    .font(.system(size: 12))
                    .foregroundStyle(Native.tertiary)
                    .padding(.vertical, 20)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    ForEach(models, id: \.id) { model in
                        card(model)
                    }
                }
            }
        }
    }

    private func card(_ model: EngineModel) -> some View {
        let selected = state.selectedModel == model.id
        return Button {
            state.applyModel(model.id)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(model.id)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Native.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    if selected { Tag(text: "已选", tone: .success) }
                }
                HStack(spacing: 10) {
                    Text(verbatim: EngineFormat.bytes(model.bytes ?? 0))
                    if let context = model.maximumContextTokens {
                        Text(verbatim: Format.tokens(context))
                    }
                    if let kind = model.kind { Text(kind) }
                }
                .font(Native.monoSmall)
                .foregroundStyle(Native.tertiary.opacity(0.9))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GlassSurface(radius: 14, tint: selected ? Native.accent.opacity(0.18) : .clear, elevated: false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("切换 \(model.id)")
    }
}
