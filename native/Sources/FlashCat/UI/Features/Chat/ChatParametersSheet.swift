// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AVKit
import AppKit
import FlashCatCore
import FlashCatKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Parameters

struct ChatParametersSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chat.temperature") private var storedTemperature = 0.7
    @AppStorage("chat.topP") private var storedTopP = 0.95
    @AppStorage("chat.maxTokens") private var storedMaxTokens = 0
    @AppStorage("chat.system") private var storedSystemPrompt = ""
    @AppStorage("thinkingMode") private var storedThinkingMode = ThinkingMode.automatic.rawValue
    @AppStorage("reasoningEffort") private var storedReasoningEffort = ReasoningEffort.medium.rawValue

    private var thinkingMode: ThinkingMode {
        ThinkingMode(rawValue: storedThinkingMode) ?? .automatic
    }

    private var reasoningEffort: ReasoningEffort {
        ReasoningEffort.stored(storedReasoningEffort)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            DSDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if ChatComposerControls.showsThinkingLevel(for: state.activeModel) {
                        thinkingCard
                    }
                    samplingCard
                    systemPromptCard
                }
                .padding(18)
            }
            .scrollIndicators(.never)

            DSDivider()
            footer
        }
        .frame(width: 500, height: 500)
        .sheetCanvas()
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("生成参数")
                    .font(DS.Font.lg.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text("这些默认值会随每条消息一起发送")
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
            }
            Spacer(minLength: 8)
            DSIconButton(systemName: "xmark", help: "关闭") { dismiss() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// 思考设置从输入卡底排收进这里：底排只留模型、上下文与发送，
    /// 思考模式与等级是「偶尔调一次」的参数，不该和每轮都要点的发送键抢位置。
    private var thinkingCard: some View {
        Card("思考", subtitle: "回答前是否输出推理过程") {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Text("模式")
                        .font(DS.Font.sm)
                        .foregroundStyle(DS.text3)
                    Spacer(minLength: 8)
                    NativeSegmented(
                        selection: Binding(
                            get: { thinkingMode },
                            set: { mode in
                                storedThinkingMode = mode.rawValue
                                state.settings.setThinkingMode(mode)
                            }),
                        options: ThinkingMode.allCases.map { ($0, $0.label) }
                    )
                    .accessibilityLabel(L10n.t("思考等级"))
                    .accessibilityValue(
                        ChatThinkingLevel.text(mode: thinkingMode, effort: reasoningEffort))
                }
                if thinkingMode == .on {
                    HStack(spacing: 12) {
                        Text("等级")
                            .font(DS.Font.sm)
                            .foregroundStyle(DS.text3)
                        Spacer(minLength: 8)
                        NativeSegmented(
                            selection: Binding(
                                get: { reasoningEffort },
                                set: { effort in
                                    storedReasoningEffort = effort.rawValue
                                    state.settings.setReasoningEffort(effort)
                                }),
                            options: ReasoningEffort.allCases.map { ($0, $0.label) })
                    }
                } else {
                    Text(L10n.t(thinkingMode.detail))
                        .font(DS.Font.xs)
                        .foregroundStyle(DS.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// 采样参数：卡片里放两行滑杆和一个托底输入框。
    private var samplingCard: some View {
        Card("采样", subtitle: "每条消息都会带上这组默认值") {
            VStack(spacing: 14) {
                SamplingSlider(
                    label: "温度", value: storedTemperature, range: 0...2,
                    format: "%.2f"
                ) {
                    storedTemperature = $0
                    state.settings.setTemperature($0)
                }
                SamplingSlider(
                    label: "top-p", value: storedTopP, range: 0...1,
                    format: "%.2f"
                ) {
                    storedTopP = $0
                    state.settings.setTopP($0)
                }
                HStack(spacing: 10) {
                    Text("最大输出")
                        .font(DS.Font.md)
                        .foregroundStyle(DS.text2)
                        .frame(width: 72, alignment: .leading)
                    TextField(
                        "模型上限",
                        text: Binding(
                            get: { storedMaxTokens > 0 ? String(storedMaxTokens) : "" },
                            set: { raw in
                                let digits = raw.filter(\.isNumber)
                                let value = Int(digits) ?? 0
                                storedMaxTokens = value
                                state.settings.setMaxTokens(value)
                            })
                    )
                    .textFieldStyle(.plain)
                    .font(DS.Font.mono(11.5))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .dsInputSurface()
                    .frame(width: 120)
                    Text("生效 \(storedMaxTokens > 0 ? storedMaxTokens : (state.contextWindowTokens ?? 32_768))")
                        .font(DS.Font.mono(11))
                        .foregroundStyle(DS.text3)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 系统提示：面板内嵌输入底与细描边，保证长文本可读性。
    private var systemPromptCard: some View {
        Card("系统提示", subtitle: "作为系统消息置于每段对话之前") {
            TextEditor(
                text: Binding(
                    get: { storedSystemPrompt },
                    set: {
                        storedSystemPrompt = $0
                        state.settings.setSystemPrompt($0)
                    })
            )
            .font(DS.Font.md)
            .foregroundStyle(DS.text)
            .scrollContentBackground(.hidden)
            .frame(height: 120)
            .padding(8)
            .dsInputSurface()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("恢复默认") { state.resetChatParameters() }
                .buttonStyle(.ds(.secondary, size: .regular))
            Spacer(minLength: 0)
            Button("完成") { dismiss() }
                .buttonStyle(.ds(.primary, size: .regular))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

}

/// 采样参数的一行：滑杆 + 右侧实时读数。
///
/// 读数跟着滑杆走，靠的是本地 `@State`——并在外层 `@AppStorage` 重置时同步回滑块。
struct SamplingSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let format: String
    let commit: (Double) -> Void
    @State private var current: Double

    init(
        label: String, value: Double, range: ClosedRange<Double>,
        format: String, commit: @escaping (Double) -> Void
    ) {
        self.label = label
        self.value = value
        self.range = range
        self.format = format
        self.commit = commit
        _current = State(initialValue: value)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(L10n.t(label))
                .font(DS.Font.md)
                .foregroundStyle(DS.text2)
                .frame(width: 72, alignment: .leading)
            Slider(value: $current, in: range)
                .tint(DS.accent)
            Text(String(format: format, current))
                .font(DS.Font.mono(11))
                .foregroundStyle(DS.text3)
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(width: 40, alignment: .trailing)
        }
        .onChange(of: current) { _, newValue in commit(newValue) }
        .onChange(of: value) { _, newValue in
            if abs(current - newValue) > 0.0001 {
                current = newValue
            }
        }
    }
}
