// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import SwiftUI

/// 输入卡右下角的「模型 + 思考等级」入口：一枚胶囊，点开是两级菜单。
///
/// 胶囊对**所有**模型常显——选中图像 / 视频模型时它要是也没了，对话页就再没有
/// 切回文本模型的入口（设置页之外没有第二处能换模型）。思考等级只在纯对话模型上
/// 出现，可见性见 `ChatComposerControls`。
struct ChatModelControl: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore

    @State private var open = false
    @AppStorage("thinkingMode") private var storedThinkingMode = ThinkingMode.automatic.rawValue
    @AppStorage("reasoningEffort") private var storedEffort = ReasoningEffort.medium.rawValue

    var body: some View {
        Button {
            open.toggle()
        } label: {
            DSMenuTriggerLabel(title: modelName, badge: badge, size: .regular)
        }
        .buttonStyle(.ds(.secondary, size: .regular))
        .disabled(chat.generating)
        .help(L10n.t("切换模型"))
        .popover(isPresented: $open, arrowEdge: .top) {
            ChatComposerMenu(state: state) { open = false }
        }
    }

    private var modelName: String {
        state.selectedModel.isEmpty ? "选择模型" : state.shortModelName(state.selectedModel)
    }

    /// 胶囊上的读数：自动 / 关闭 / 具体档位。图像与视频模型没有思考这回事，连读数一起去掉。
    private var badge: String? {
        guard ChatComposerControls.showsThinkingLevel(for: state.activeModel) else { return nil }
        return ChatThinkingLevel.text(mode: ThinkingMode(rawValue: storedThinkingMode) ?? .automatic, effort: effort)
    }

    private var effort: ReasoningEffort { ReasoningEffort.stored(storedEffort) }
}

/// 胶囊点开后的两级菜单：第一屏只列「模型」「思考等级」，各自再进一屏列表。
private struct ChatComposerMenu: View {
    private enum Screen {
        case root
        case models
        case thinking
    }

    @ObservedObject var state: AppState
    var onDismiss: () -> Void

    @State private var screen: Screen = .root
    @AppStorage("thinkingMode") private var storedThinkingMode = ThinkingMode.automatic.rawValue
    @AppStorage("reasoningEffort") private var storedEffort = ReasoningEffort.medium.rawValue

    private var thinkingMode: ThinkingMode {
        ThinkingMode(rawValue: storedThinkingMode) ?? .automatic
    }

    private var effort: ReasoningEffort { ReasoningEffort.stored(storedEffort) }

    private var showsThinking: Bool {
        ChatComposerControls.showsThinkingLevel(for: state.activeModel)
    }

    var body: some View {
        Group {
            if !showsThinking {
                // 图像 / 视频模型没有思考等级，第一屏就只剩一行「模型」；直接进列表省一步点击。
                ModelPickerPopover(state: state) {
                    onDismiss()
                }
            } else {
                switch screen {
                case .root: root
                case .models: models
                case .thinking: thinking
                }
            }
        }
        .frame(width: 300)
        .dsPopoverSurface()
        .onAppear { screen = .root }
        .onChange(of: showsThinking) { _, show in
            if !show, screen == .thinking {
                screen = .root
            }
        }
    }

    // MARK: 第一屏

    private var root: some View {
        VStack(spacing: 2) {
            DSMenuRow(action: { screen = .models }) {
                entryRow(title: "模型", value: modelName)
            }
            if showsThinking {
                DSMenuRow(action: { screen = .thinking }) {
                    entryRow(title: "思考等级", value: ChatThinkingLevel.text(mode: thinkingMode, effort: effort))
                }
            }
        }
        .padding(6)
    }

    // MARK: 模型

    private var models: some View {
        VStack(spacing: 0) {
            backHeader("模型")
            DSDivider()
            ModelPickerPopover(state: state) {
                onDismiss()
            }
        }
    }

    // MARK: 思考等级

    private var thinking: some View {
        VStack(spacing: 0) {
            backHeader("思考等级")
            DSDivider()
            VStack(spacing: 2) {
                levelRow(title: "自动", selected: thinkingMode == .automatic) { select(.automatic) }
                levelRow(title: "关闭", selected: thinkingMode == .off) { select(.off) }
                DSDivider()
                    .padding(.vertical, 3)
                ForEach(ReasoningEffort.allCases, id: \.self) { level in
                    let selected = thinkingMode == .on && effort == level
                    levelRow(title: level.label, selected: selected) { select(level) }
                }
            }
            .padding(6)
        }
    }

    // MARK: 行

    private func entryRow(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(L10n.t(title))
                .font(DS.Font.sm)
                .foregroundStyle(DS.text2)
            Spacer(minLength: 8)
            Text(L10n.t(value))
                .font(DS.Font.sm.weight(.medium))
                .foregroundStyle(DS.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DS.text3)
        }
    }

    private func levelRow(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        DSMenuRow(selected: selected, action: action) {
            HStack(spacing: 8) {
                Text(L10n.t(title))
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

    private func backHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Button {
                screen = .root
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.text2)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)

            Text(L10n.t(title))
                .font(DS.Font.sm.weight(.medium))
                .foregroundStyle(DS.text)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: 选择

    private var modelName: String {
        state.selectedModel.isEmpty ? "选择模型" : state.shortModelName(state.selectedModel)
    }

    private func select(_ mode: ThinkingMode) {
        state.settings.setThinkingMode(mode)
        storedThinkingMode = mode.rawValue
        onDismiss()
    }

    /// 选具体档位就是在要求「按这个等级想」，所以顺手把模式切成开启。
    private func select(_ level: ReasoningEffort) {
        state.settings.setReasoningEffort(level)
        state.settings.setThinkingMode(.on)
        storedEffort = level.rawValue
        storedThinkingMode = ThinkingMode.on.rawValue
        onDismiss()
    }
}

/// 思考等级怎么读成一句话：胶囊上的读数与菜单里的当前值共用。
enum ChatThinkingLevel {
    static func text(mode: ThinkingMode, effort: ReasoningEffort) -> String {
        switch mode {
        case .automatic: return "自动"
        case .off: return "关闭"
        case .on: return effort.label
        }
    }
}
