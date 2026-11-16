import SwiftUI
import FlashCatKit

/// Games 风格的模型选择菜单：玻璃卡片 + 分组行 + 勾选，不用系统 NSMenu。
struct ModelPickerButton<Label: View>: View {
    @ObservedObject var state: AppState
    var kind: DSButtonStyle.Kind = .primary
    @ViewBuilder var label: () -> Label

    @State private var open = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            label()
        }
        .buttonStyle(.ds(kind))
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
                            .font(DS.Font.xs.weight(.medium))
                            .tracking(0.4)
                            .foregroundStyle(DS.text3)
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
        .dsPopoverSurface()
    }

    private func row(_ model: EngineModel, engine: EngineID) -> some View {
        let selected = model.id == state.selectedModel && engine == state.activeEngine
        let switching = state.switchingModel == model.id && engine == state.activeEngine
        return DSMenuRow(selected: selected) {
            state.applyModelFromAnyEngine(model.id, engine: engine)
            onPick()
        } content: {
            HStack(spacing: 8) {
                if switching {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? DS.accent : DS.text4)
                }
                Text(state.shortModelName(model.id))
                    .font(DS.Font.sm.weight(selected ? .medium : .regular))
                    .foregroundStyle(selected ? DS.text : DS.text2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if switching {
                    Text(L10n.t(state.switchStage.isEmpty ? "加载中" : state.switchStage))
                        .font(DS.Font.xs)
                        .foregroundStyle(DS.warn)
                        .lineLimit(1)
                }
            }
        }
    }
}
