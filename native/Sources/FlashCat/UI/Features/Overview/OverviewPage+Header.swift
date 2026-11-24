// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Charts
import FlashCatCore
import FlashCatKit
import SwiftUI

extension OverviewPage {
    // MARK: Page header

    /// 页头：页名 + 现场胶囊；右侧三段皮肤切换、模型下拉与启停按钮。
    /// 窄版把动作折到第二行，避免 224pt 侧栏展开时把模型名挤掉。
    @ViewBuilder
    func pageHeader(compact: Bool) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    pageTitle
                    OverviewStatusPill(
                        engine: state.activeEngine.displayName,
                        port: nil,
                        stage: stageTitle,
                        tint: statusColor,
                        live: state.canChat)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    modelPickerButton
                    engineButton
                }
            }
        } else {
            HStack(spacing: 10) {
                pageTitle
                OverviewStatusPill(
                    engine: state.activeEngine.displayName,
                    port: state.port,
                    stage: stageTitle,
                    tint: statusColor,
                    live: state.canChat)
                Spacer(minLength: 12)
                modelPickerButton
                engineButton
            }
            .frame(height: 34)
        }
    }

    var pageTitle: some View {
        Text(L10n.t("概览"))
            .font(DS.Font.prose(20, weight: .bold))
            .tracking(-0.3)
            .foregroundStyle(DS.text)
            .fixedSize()
    }

    // MARK: Header actions

    var modelPickerButton: some View {
        ModelPickerButton(state: state, kind: .secondary) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.accent)
                Text(L10n.t("切换模型"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.text)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(DS.text3)
            }
        }
        .disabled(state.isSwitchingModel)
    }

    var engineButton: some View {
        Button {
            state.toggleService()
        } label: {
            HStack(spacing: 6) {
                if state.isRunning {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.dangerText)
                        .frame(width: 7, height: 7)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8.5, weight: .bold))
                }
                Text(L10n.t(state.isRunning ? "停止引擎" : "启动引擎"))
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .buttonStyle(OverviewTintActionStyle(tint: state.isRunning ? DS.dangerText : DS.ok))
        .disabled(engineToggleDisabled)
        .help(engineToggleHelp)
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

    // MARK: Current model card

    var modelHeroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                modelIcon

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        engineBadge
                        Text(L10n.t("当前加载模型"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(DS.text4)
                    }
                    Text(modelTitle)
                        .font(DS.Font.prose(14.5, weight: .bold))
                        .tracking(-0.2)
                        .foregroundStyle(state.selectedModel.isEmpty ? DS.text3 : DS.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(modelMetaLine)
                        .font(DS.Font.proseNumber(10.5))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)
            contextBlock
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overviewCard()
    }

    var modelIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [DS.accentBlue.opacity(0.22), DS.accent.opacity(0.30)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DS.accentBlue.opacity(0.30), lineWidth: 1)
            Image(systemName: "cube.fill")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [DS.accentBlue, DS.accent],
                        startPoint: .top, endPoint: .bottom))
        }
        .frame(width: 40, height: 40)
        .shadow(color: DS.accentBlue.opacity(0.28), radius: 8, y: 2)
    }

    var engineBadge: some View {
        Text(state.activeEngine.displayName.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(DS.accentBlue)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(DS.rect(5).fill(DS.accentBlue.opacity(0.10)))
            .overlay(DS.rect(5).strokeBorder(DS.accentBlue.opacity(0.22), lineWidth: 1))
            .fixedSize()
    }

    var contextBlock: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(L10n.t("上下文窗口"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.text3)
                Spacer(minLength: 4)
                Text(verbatim: contextUsedText)
                    .font(DS.Font.number(11.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text(verbatim: "/")
                    .font(DS.Font.prose(11))
                    .foregroundStyle(DS.text4)
                Text(verbatim: contextTotalText)
                    .font(DS.Font.number(11, weight: .medium))
                    .foregroundStyle(DS.text2)
                Text(verbatim: "(\(contextPercentText))")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DS.accent)
                    .fixedSize()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.line2)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [DS.accentBlue, DS.accent, Color(red: 0.55, green: 0.36, blue: 0.96)],
                                startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, proxy.size.width * contextProgress))
                        .shadow(color: DS.accent.opacity(0.35), radius: 3)
                }
            }
            .frame(height: 6)
            .opacity(state.overviewContextUsedTokens > 0 ? 1 : 0.45)
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
        .dsSurface(radius: DS.Radius.card)
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

    var contextUsedText: String {
        Format.tokens(state.overviewContextUsedTokens)
    }

    var contextTotalText: String {
        guard let ceiling = state.contextWindowCeiling else { return "—" }
        return Format.tokensShort(ceiling)
    }

    var contextPercentText: String {
        guard let ceiling = state.contextWindowCeiling, ceiling > 0,
            state.overviewContextUsedTokens > 0
        else { return "0%" }
        let percent = min(100, Double(state.overviewContextUsedTokens) / Double(ceiling) * 100)
        return percent < 1
            ? String(format: "%.2f%%", percent)
            : String(format: "%.1f%%", percent)
    }
}
