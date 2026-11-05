import SwiftUI
import FlashCatKit

/// Games 风格的模型选择菜单：玻璃卡片 + 分组行 + 勾选，不用系统 NSMenu。
struct ModelPickerButton<Label: View>: View {
    @ObservedObject var state: AppState
    @ViewBuilder var label: () -> Label

    @State private var open = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ModelPickerPopover(state: state) { open = false }
        }
    }
}

struct ModelPickerPopover: View {
    @ObservedObject var state: AppState
    var onPick: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(EngineCatalog.allIDs.filter { state.engineIsInstalled($0) }, id: \.self) { id in
                    let models = state.engineModels(for: id)
                        .filter { !$0.hidden && !$0.helper && !ModelLibraryEntry.isDraftModel($0.id) }
                    if !models.isEmpty {
                        Text(id.displayName)
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Console.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(models) { model in
                            row(model, engine: id)
                        }
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 300)
        .frame(maxHeight: 380)
        .background(Console.cardStrong)
    }

    private func row(_ model: EngineModel, engine: EngineID) -> some View {
        let selected = model.id == state.selectedModel && engine == state.activeEngine
        return Button {
            state.applyModelFromAnyEngine(model.id, engine: engine)
            onPick()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? Console.accent : Console.tertiary.opacity(0.5))
                Text(state.shortModelName(model.id))
                    .font(.system(size: 12))
                    .foregroundStyle(Console.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Console.inset : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
