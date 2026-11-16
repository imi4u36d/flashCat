// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import SwiftUI

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

    /// `ScrollView` 在 SwiftUI 里最小高度为 0：挂在从短菜单切换过来的 `NSPopover`
    /// 里时，只写 `maxHeight` 会把列表压进旧高度里而不撑开弹层。量出内容实际高度
    /// 再夹到 380pt 上限，既能贴合少数模型，也能撑开 `NSPopover` 并正常滚动。
    @State private var contentHeight: CGFloat = 120

    private var groups: [(engine: EngineID, models: [EngineModel])] {
        EngineCatalog.allIDs
            .filter { state.engineIsInstalled($0) }
            .compactMap { id in
                let models = state.engineModels(for: id)
                    .filter { !$0.hidden && !$0.helper && !ModelLibraryEntry.isDraftModel($0.id) }
                return models.isEmpty ? nil : (id, models)
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if groups.isEmpty {
                    Text(L10n.t("暂无可用模型"))
                        .font(DS.Font.sm)
                        .foregroundStyle(DS.text3)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                } else {
                    ForEach(groups, id: \.engine) { group in
                        Text(group.engine.displayName)
                            .font(DS.Font.xs.weight(.medium))
                            .tracking(0.4)
                            .foregroundStyle(DS.text3)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(group.models) { model in
                            row(model, engine: group.engine)
                        }
                    }
                }
            }
            .padding(6)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                if height > 0, abs(height - contentHeight) > 0.5 {
                    contentHeight = height
                }
            }
        }
        .frame(width: 300, height: min(max(contentHeight, 44), 380))
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
