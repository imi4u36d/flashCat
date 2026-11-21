// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import SwiftUI

/// 输入卡底排的模型槽：状态点 + 模型名 + 下拉箭头，悬停才浮出底色。
/// 点开仍是原来的两级菜单（模型列表 / 图像工具模型），但外观对齐 Splash 的
/// `EngineSlot`，不再是一枚描边胶囊。
struct ChatModelControl: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore

    @State private var open = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(modelName)
                    .font(DS.Font.prose(13))
                    .foregroundStyle(DS.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.text3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DS.rect(7).fill(hovering ? DS.hover : .clear))
            .contentShape(DS.rect(7))
        }
        .buttonStyle(.plainHit)
        .disabled(chat.generating)
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
        .help(L10n.t("切换模型"))
        .accessibilityLabel(L10n.t("模型"))
        .accessibilityValue(modelName)
        .popover(isPresented: $open, arrowEdge: .top) {
            ModelPickerPopover(state: state) { open = false }
        }
    }

    private var modelName: String {
        state.selectedModel.isEmpty ? L10n.t("选择模型") : state.shortModelName(state.selectedModel)
    }

    private var statusColor: Color {
        if state.isModelBusy { return DS.warn }
        return state.canChat ? DS.ok : DS.text4
    }
}

/// 输入卡底排的思考等级：一行小字 + 箭头，点开是自动 / 关闭 / 各档位。
/// Splash 把「模型」和「思考」拆成并排的两个菜单，而不是塞进同一枚胶囊。
struct ChatEffortControl: View {
    @ObservedObject var state: AppState

    @State private var open = false
    @State private var hovering = false
    @AppStorage("thinkingMode") private var storedThinkingMode = ThinkingMode.automatic.rawValue
    @AppStorage("reasoningEffort") private var storedEffort = ReasoningEffort.medium.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: ThinkingMode { ThinkingMode(rawValue: storedThinkingMode) ?? .automatic }
    private var effort: ReasoningEffort { ReasoningEffort.stored(storedEffort) }

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(ChatThinkingLevel.text(mode: mode, effort: effort))
                    .font(DS.Font.prose(13))
                    .foregroundStyle(DS.text2)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.text3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DS.rect(7).fill(hovering ? DS.hover : .clear))
            .contentShape(DS.rect(7))
        }
        .buttonStyle(.plainHit)
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
        .help(L10n.t("模型思考多久再回答"))
        .accessibilityLabel(L10n.t("思考等级"))
        .accessibilityValue(ChatThinkingLevel.text(mode: mode, effort: effort))
        .popover(isPresented: $open, arrowEdge: .top) {
            menu
        }
    }

    private var menu: some View {
        VStack(spacing: 2) {
            levelRow(L10n.t("自动"), selected: mode == .automatic) { select(.automatic) }
            levelRow(L10n.t("关闭"), selected: mode == .off) { select(.off) }
            DSDivider()
                .padding(.vertical, 3)
            ForEach(ReasoningEffort.allCases, id: \.self) { level in
                levelRow(level.label, selected: mode == .on && effort == level) {
                    select(level)
                }
            }
        }
        .padding(6)
        .frame(width: 220)
        .dsPopoverSurface()
    }

    private func levelRow(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        DSMenuRow(selected: selected, action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(DS.Font.sm.weight(selected ? .medium : .regular))
                    .foregroundStyle(DS.text)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.accent)
                }
            }
        }
    }

    private func select(_ mode: ThinkingMode) {
        state.settings.setThinkingMode(mode)
        storedThinkingMode = mode.rawValue
        open = false
    }

    /// 选具体档位就是在要求「按这个等级想」，所以顺手把模式切成开启。
    private func select(_ level: ReasoningEffort) {
        state.settings.setReasoningEffort(level)
        state.settings.setThinkingMode(.on)
        storedEffort = level.rawValue
        storedThinkingMode = ThinkingMode.on.rawValue
        open = false
    }
}

/// 思考等级怎么读成一句话：输入卡的思考菜单与无障碍读数共用。
enum ChatThinkingLevel {
    static func text(mode: ThinkingMode, effort: ReasoningEffort) -> String {
        switch mode {
        case .automatic: return "自动"
        case .off: return "关闭"
        case .on: return effort.label
        }
    }
}
