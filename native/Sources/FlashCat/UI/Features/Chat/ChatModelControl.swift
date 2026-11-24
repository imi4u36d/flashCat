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
        // 底排只放得下短名；完整仓库 id 与引擎在悬停时给出。
        .help(
            state.selectedModel.isEmpty
                ? L10n.t("切换模型")
                : "\(state.activeEngine.displayName) · \(state.selectedModel)"
        )
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

/// 思考等级怎么读成一句话：生成参数弹层的无障碍读数与测试共用。
enum ChatThinkingLevel {
    static func text(mode: ThinkingMode, effort: ReasoningEffort) -> String {
        switch mode {
        case .automatic: return "自动"
        case .off: return "关闭"
        case .on: return effort.label
        }
    }
}
