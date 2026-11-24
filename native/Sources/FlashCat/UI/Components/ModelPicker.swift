// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import SwiftUI

/// 模型选择菜单：ZCode 浮层卡片 + 引擎分组 + 勾选，不用系统 NSMenu。
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
    @State private var query = ""

    private var allGroups: [(engine: EngineID, models: [EngineModel])] {
        EngineCatalog.allIDs
            .filter { state.engineIsInstalled($0) }
            .compactMap { id in
                let models = state.engineModels(for: id)
                    .filter { !$0.hidden && !$0.helper && !ModelLibraryEntry.isDraftModel($0.id) }
                return models.isEmpty ? nil : (id, models)
            }
    }

    private var totalModelCount: Int {
        allGroups.reduce(0) { $0 + $1.models.count }
    }

    private var showsSearch: Bool { totalModelCount >= 6 }

    private var filteredGroups: [(engine: EngineID, models: [EngineModel])] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return allGroups }
        return allGroups.compactMap { group in
            if group.engine.displayName.localizedCaseInsensitiveContains(needle) {
                return group
            }
            let hits = group.models.filter { model in
                model.id.localizedCaseInsensitiveContains(needle)
                    || state.shortModelName(model.id).localizedCaseInsensitiveContains(needle)
            }
            return hits.isEmpty ? nil : (group.engine, hits)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsSearch {
                DSSearchField(query: $query, placeholder: "筛选模型…")
                    .padding(6)
                DSDivider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if filteredGroups.isEmpty {
                        Text(L10n.t(allGroups.isEmpty ? "暂无可用模型" : "没有匹配的模型"))
                            .font(DS.Font.sm)
                            .foregroundStyle(DS.text3)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 16)
                    } else {
                        ForEach(filteredGroups, id: \.engine) { group in
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
            .frame(height: min(max(contentHeight, 44), showsSearch ? 336 : 380))
        }
        .frame(width: 300)
        .dsPopoverSurface()
    }

    private func row(_ model: EngineModel, engine: EngineID) -> some View {
        let selected = model.id == state.selectedModel && engine == state.activeEngine
        let switching = state.switchingModel == model.id && engine == state.activeEngine
        let capability = capabilityBadge(for: model)
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
                } else if let capability {
                    Image(systemName: capability.symbol)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DS.text3)
                        .help(L10n.t(capability.help))
                        .accessibilityLabel(L10n.t(capability.help))
                }
            }
        }
        .disabled(switching)
    }

    private func capabilityBadge(for model: EngineModel) -> (symbol: String, help: String)? {
        if model.supportsVideo { return ("film", "视频模型") }
        if model.supportsImage { return ("photo", "图像模型") }
        if model.supportsVision { return ("eye", "视觉模型") }
        return nil
    }
}
