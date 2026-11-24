// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Charts
import FlashCatCore
import FlashCatKit
import SwiftUI

extension OverviewPage {
    // MARK: Page header & model strip

    /// 页名回到「概览」，模型名降为页内的当前模型条：切页时先看到自己在哪，
    /// 再看到现在跑的是什么。窄窗口省掉端口，把宽度留给引擎名与阶段。
    func pageHeader(compact: Bool) -> some View {
        DSPageHeader(
            title: "概览",
            subtitle: compact
                ? state.activeEngine.displayName
                : "\(state.activeEngine.displayName) · 127.0.0.1:\(state.port)",
            status: DSPageStatus(stageTitle, color: statusColor, live: state.canChat)
        ) {
            Button {
                state.toggleService()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: state.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(L10n.t(state.isRunning ? "停止引擎" : "启动引擎"))
                }
            }
            .buttonStyle(.ds(state.isRunning ? .danger : .primary))
            .disabled(engineToggleDisabled)
            .help(engineToggleHelp)

            ModelPickerButton(state: state, kind: .secondary) {
                DSMenuTriggerLabel(
                    title: "切换模型",
                    systemImage: "square.stack.3d.up.fill",
                    kind: .secondary,
                    size: .regular
                )
            }
            .disabled(state.isSwitchingModel)
        }
    }

    var stageTitle: String {
        if state.serverState == .failed { return L10n.t("异常") }
        let stage = state.engineStageText
        return stage.isEmpty ? L10n.t(state.serverState.rawValue) : stage
    }

    var statusColor: Color {
        if state.serverState == .failed { return DS.err }
        if state.canChat { return DS.ok }
        if state.isModelBusy || state.isRunning { return DS.warn }
        return DS.text4
    }

    /// 当前模型条：模型名 + 引擎/量化/体积 + 上下文占用。
    /// 宽版把上下文放在右侧；窄版放到名称下方并让进度条占满整行，
    /// 否则 150pt 的固定宽度会把模型名挤成 `Qwen3...ed-Speed`。
    @ViewBuilder
    func modelHero(compact: Bool) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ModelFamilyIcon(family: modelFamily, size: 30)
                    modelNameRow
                    Spacer(minLength: 0)
                }
                Text(modelMetaLine)
                    .font(DS.Font.proseNumber(11))
                    .foregroundStyle(DS.text3)
                    .lineLimit(1)
                contextBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .dsSurface(radius: DS.Radius.lg)
        } else {
            HStack(alignment: .center, spacing: 12) {
                ModelFamilyIcon(family: modelFamily, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    modelNameRow
                    Text(modelMetaLine)
                        .font(DS.Font.proseNumber(11))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                contextBlock
                    .frame(width: 132)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .dsSurface(radius: DS.Radius.lg)
        }
    }

    var modelNameRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.t(modelTitleParts.name))
                .font(DS.Font.prose(20, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(state.selectedModel.isEmpty ? DS.text3 : DS.text)
                .lineLimit(1)
                .truncationMode(.middle)

            if let variant = modelTitleParts.variant {
                Text(variant)
                    .font(DS.Font.mono(10.5, weight: .medium))
                    .foregroundStyle(DS.text2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(DS.rect(DS.Radius.sm).fill(DS.hover))
                    .fixedSize()
            }
        }
    }

    var contextBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(L10n.t("当前上下文"))
                    .font(DS.Font.prose(10.5))
                    .foregroundStyle(DS.text3)
                Spacer(minLength: 4)
                Text(verbatim: contextFractionText)
                    .font(DS.Font.proseNumber(12, weight: .medium))
                    .foregroundStyle(state.overviewContextUsedTokens > 0 ? DS.text : DS.text3)
            }
            DSMeter(value: contextProgress, tint: engineTint)
                .opacity(contextProgress > 0 ? 1 : 0.45)
        }
    }

    var modelFamily: ModelFamily {
        ModelFamily.resolve(id: state.selectedModel, hint: state.selectedModelInfo?.family)
    }

    // MARK: First-run checklist

    var activeEngineHasLocalModels: Bool {
        state.libraryEntries(for: state.activeEngine).contains(where: \.installed)
    }

    var showsChecklist: Bool {
        !checklistDismissed && !state.isRunning
            && (state.runtimeMissing != nil || !activeEngineHasLocalModels)
    }

    /// 首次使用的三步清单：装引擎 → 下模型 → 启动。三步都完成或用户关掉后不再出现。
    var setupChecklist: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                checklistStep(
                    index: 1, title: "安装引擎", detail: "先在引擎页装一个运行时",
                    done: state.runtimeMissing == nil
                ) { state.section = .engines }
                checklistArrow
                checklistStep(
                    index: 2, title: "下载模型", detail: "在模型库下载一个能跑的权重",
                    done: activeEngineHasLocalModels
                ) { state.section = .models }
                checklistArrow
                checklistStep(
                    index: 3, title: "启动引擎", detail: "装好后回到这里启动",
                    done: false
                ) { state.toggleService() }
                Spacer(minLength: 8)
                dismissChecklistButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.t("三步开跑"))
                        .font(DS.Font.prose(12.5, weight: .medium))
                        .foregroundStyle(DS.text2)
                    Spacer()
                    dismissChecklistButton
                }
                checklistStep(
                    index: 1, title: "安装引擎", detail: "先在引擎页装一个运行时",
                    done: state.runtimeMissing == nil
                ) { state.section = .engines }
                checklistStep(
                    index: 2, title: "下载模型", detail: "在模型库下载一个能跑的权重",
                    done: activeEngineHasLocalModels
                ) { state.section = .models }
                checklistStep(
                    index: 3, title: "启动引擎", detail: "装好后回到这里启动",
                    done: false
                ) { state.toggleService() }
            }
            .padding(14)
        }
        .dsSurface(radius: DS.Radius.lg)
    }

    var checklistArrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(DS.text4)
    }

    var dismissChecklistButton: some View {
        Button {
            checklistDismissed = true
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DS.text3)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(L10n.t("关闭三步清单"))
        .accessibilityLabel(L10n.t("关闭三步清单"))
    }

    func checklistStep(
        index: Int,
        title: String,
        detail: String,
        done: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(done ? DS.ok.opacity(0.16) : DS.hover)
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DS.ok)
                    } else {
                        Text(verbatim: "\(index)")
                            .font(DS.Font.mono(10, weight: .semibold))
                            .foregroundStyle(DS.text2)
                    }
                }
                .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.t(title))
                        .font(DS.Font.prose(12, weight: .medium))
                        .foregroundStyle(done ? DS.text3 : DS.text)
                    Text(L10n.t(detail))
                        .font(DS.Font.prose(10.5))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var modelMetaLine: String {
        var parts = [state.activeEngine.displayName]
        if let info = state.selectedModelInfo {
            if let quant = info.quantization, !quant.isEmpty { parts.append(quant) }
            if info.bytes > 0 { parts.append(Format.size(info.bytes)) }
        }
        if state.selectedModel.isEmpty { parts.append(L10n.t("从模型库选择一个模型")) }
        return parts.joined(separator: " · ")
    }

    var contextFractionText: String {
        let used = Format.tokens(state.overviewContextUsedTokens)
        guard let ceiling = state.contextWindowCeiling else { return used }
        return "\(used) / \(Format.tokensShort(ceiling))"
    }
}
