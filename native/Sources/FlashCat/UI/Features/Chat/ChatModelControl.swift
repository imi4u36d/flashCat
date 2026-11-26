// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import SwiftUI

/// 模型选择器：引擎图标 + 完整模型 id。没有胶囊底色、没有描边、没有箭头；
/// 点名字本身就是「换模型」的唯一动作，右侧紧邻的是思考级别控件。
/// 底排按位置传入高度。
struct ChatModelControl: View {
    @ObservedObject var state: AppState
    let chat: ChatStore
    var height: CGFloat = 26
    var isActive: Bool = true
    /// 模型列表是否正从输入卡里展开。
    var isPickerOpen: Bool = false
    var onTogglePicker: () -> Void

    @State private var generating = false

    private var modelText: String {
        let raw = state.selectedModel.trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? L10n.t("选择模型") : raw
    }

    var body: some View {
        Button {
            onTogglePicker()
        } label: {
            HStack(spacing: 6) {
                engineBadge

                Text(modelText)
                    .font(DS.Font.prose(12, weight: .medium))
                    .foregroundStyle(isPickerOpen ? DS.accent : DS.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 300, alignment: .leading)
            }
            .padding(.horizontal, 5)
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .disabled(generating)
        .opacity(generating ? 0.55 : 1)
        .onAppear { generating = chat.generating }
        .onReceive(chat.$generating) { value in
            if generating != value { generating = value }
        }
        // 底排只放得下 id；完整仓库 id 就是文案本身，引擎名留在悬停提示里。
        .help(
            isPickerOpen
                ? L10n.t("收起模型列表")
                : (state.selectedModel.isEmpty
                    ? L10n.t("切换模型")
                    : "\(state.activeEngine.displayName) · \(state.selectedModel)")
        )
        .accessibilityLabel(L10n.t("模型"))
        .accessibilityValue(modelText)
    }

    /// 引擎图标上的状态角标：只在异常或加载中提示，正常运行时不再留一颗
    /// 孤立的灰点。停机的可发送状态由发送键自己表达。
    private var engineBadge: some View {
        ZStack(alignment: .bottomTrailing) {
            EngineMark(id: state.activeEngine, size: 16)
            if showsStatusBadge {
                DSStatusDot(color: statusColor, live: false, size: 5)
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: 18, height: 18)
    }

    private var showsStatusBadge: Bool {
        isActive && (state.serverState == .failed || state.isModelBusy)
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

/// 输入卡底排的思考级别：脑图标 + 当前档位，点开切换。
/// 六档和生成参数面板里的模式 / 等级一一对应：
/// 自动、关闭，以及开启后的低 / 中 / 高 / 极高。
struct ChatThinkingControl: View {
    let settings: AppSettings

    @AppStorage("thinkingMode") private var storedMode = ThinkingMode.automatic.rawValue
    @AppStorage("reasoningEffort") private var storedEffort = ReasoningEffort.medium.rawValue
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: ThinkingMode {
        ThinkingMode(rawValue: storedMode) ?? .automatic
    }

    private var effort: ReasoningEffort {
        ReasoningEffort.stored(storedEffort)
    }

    private var choice: ChatThinkingChoice {
        switch mode {
        case .automatic: return .automatic
        case .off: return .off
        case .on: return ChatThinkingChoice(effort: effort)
        }
    }

    private var ink: Color {
        hovering ? DS.text : choice.tint
    }

    var body: some View {
        Menu {
            ForEach(ChatThinkingChoice.allCases) { option in
                Button {
                    apply(option)
                } label: {
                    if option == choice {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain")
                    .font(.system(size: 11.5, weight: .medium))
                Text(choice.title)
                    .font(DS.Font.prose(12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 5)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
        .help("切换思考级别")
        .accessibilityLabel(L10n.t("思考级别"))
        .accessibilityValue(choice.title)
    }

    private func apply(_ option: ChatThinkingChoice) {
        switch option {
        case .automatic:
            storedMode = ThinkingMode.automatic.rawValue
            settings.setThinkingMode(.automatic)
        case .off:
            storedMode = ThinkingMode.off.rawValue
            settings.setThinkingMode(.off)
        case .low, .medium, .high, .xhigh:
            let target = option.effort ?? .medium
            storedMode = ThinkingMode.on.rawValue
            storedEffort = target.rawValue
            settings.setThinkingMode(.on)
            settings.setReasoningEffort(target)
        }
    }
}

/// 底排的六档思考级别。文案用短中文，和「自动 / 关闭」并排时不至于
/// 把 id 挤掉；设置页仍保留 Low / Medium / High / XHigh。
enum ChatThinkingChoice: String, CaseIterable, Identifiable {
    case automatic
    case off
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    init(effort: ReasoningEffort) {
        switch effort {
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        case .xhigh: self = .xhigh
        }
    }

    var effort: ReasoningEffort? {
        switch self {
        case .automatic, .off: return nil
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case .xhigh: return .xhigh
        }
    }

    var title: String {
        switch self {
        case .automatic: return L10n.t("自动")
        case .off: return L10n.t("关闭")
        case .low: return L10n.t("低")
        case .medium: return L10n.t("中")
        case .high: return L10n.t("高")
        case .xhigh: return L10n.t("极高")
        }
    }

    var tint: Color {
        switch self {
        case .off: return DS.text4
        case .automatic, .low: return DS.text3
        case .medium, .high: return DS.text2
        case .xhigh: return DS.accent
        }
    }
}
