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
        .buttonStyle(.plainHit)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ModelPickerPopover(state: state) { open = false }
        }
    }
}

struct ModelPickerPopover: View {
    @ObservedObject var state: AppState
    var onPick: () -> Void

    @State private var hoveredID: String?

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
                            row(model, engine: id, hovered: hoveredID == model.id) { inside in
                                if inside {
                                    hoveredID = model.id
                                } else if hoveredID == model.id {
                                    hoveredID = nil
                                }
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 300)
        .frame(maxHeight: 380)
    }

    private func row(_ model: EngineModel,
                     engine: EngineID,
                     hovered: Bool,
                     onHover: @escaping (Bool) -> Void) -> some View {
        let selected = model.id == state.selectedModel && engine == state.activeEngine
        let switching = state.switchingModel == model.id && engine == state.activeEngine
        return Button {
            state.applyModelFromAnyEngine(model.id, engine: engine)
            onPick()
        } label: {
            HStack(spacing: 8) {
                if switching {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? Console.accent : Console.tertiary.opacity(0.5))
                }
                Text(state.shortModelName(model.id))
                    .font(.system(size: 12))
                    .foregroundStyle(Console.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if switching {
                    Text(L10n.t(state.switchStage.isEmpty ? "加载中" : state.switchStage))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Console.warn)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                LiquidGlassSurface(
                    shape: RoundedRectangle(cornerRadius: 8, style: .continuous),
                    tint: selected ? Console.accent.opacity(0.12) : nil,
                    interactive: true
                )
                .opacity(selected || hovered ? 1 : 0)
            }
            .animation(Motion.quick, value: selected || hovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .onHover(perform: onHover)
    }
}
