// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import SwiftUI

/// 模型胶囊选择器：引擎图标 + 状态点 + 模型短名 + 下拉箭头，采用 Liquid Glass 胶囊语言。
/// 输入卡底排与对话顶栏共用同一个控件，按位置传入高度与弹出方向。
struct ChatModelControl: View {
    @ObservedObject var state: AppState
    let chat: ChatStore
    var height: CGFloat = 26
    var arrowEdge: Edge = .top
    var isActive: Bool = true

    @State private var open = false
    @State private var hovering = false
    @State private var generating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                EngineMark(id: state.activeEngine, size: 14)
                DSStatusDot(color: statusColor, live: isActive && state.canChat, size: 5.5)
                Text(modelName)
                    .font(DS.Font.prose(12, weight: .medium))
                    .foregroundStyle(hovering || open ? DS.text : DS.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(DS.text3)
            }
            .padding(.horizontal, 9)
            .frame(height: height)
            .background(Capsule().fill(hovering || open ? DS.raised : DS.pillFill))
            .overlay(Capsule().strokeBorder(hovering || open ? DS.line2 : DS.pillBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plainHit)
        .disabled(generating)
        .onAppear { generating = chat.generating }
        .onReceive(chat.$generating) { value in
            if generating != value { generating = value }
        }
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
        // 底排与顶栏只放得下短名；完整仓库 id 与引擎在悬停时给出。
        .help(
            state.selectedModel.isEmpty
                ? L10n.t("切换模型")
                : "\(state.activeEngine.displayName) · \(state.selectedModel)"
        )
        .accessibilityLabel(L10n.t("模型"))
        .accessibilityValue(modelName)
        .popover(isPresented: $open, arrowEdge: arrowEdge) {
            ModelPickerPopover(state: state) { open = false }
        }
    }

    private var modelName: String {
        state.selectedModel.isEmpty ? L10n.t("选择模型") : state.shortModelName(state.selectedModel)
    }

    private var statusColor: Color {
        if state.serverState == .failed { return DS.err }
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
