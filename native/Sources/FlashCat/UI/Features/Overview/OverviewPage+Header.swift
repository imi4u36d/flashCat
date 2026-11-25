// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

extension OverviewPage {
    // MARK: Page header

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
                    headerActions
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
                headerActions
            }
            .frame(height: Console.pageHeaderHeight)
        }
    }

    @ViewBuilder
    var headerActions: some View {
        modelPickerButton
        engineButton
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
                EngineGlyph(id: state.activeEngine, color: engineTint, size: 40)

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

            if isLiveDashboard {
                Spacer(minLength: 0)
                contextBlock
            } else if let failure = state.failureMessage, !failure.isEmpty {
                failureBanner(failure)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: isLiveDashboard ? .infinity : nil, alignment: .topLeading)
        .overviewCard()
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DS.err)
            Text(message)
                .font(DS.Font.prose(11.5))
                .foregroundStyle(DS.err)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(L10n.t("查看日志")) {
                state.section = .logs
            }
            .buttonStyle(.ds(.secondary, size: .small))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(DS.rect(10).fill(DS.dangerFill))
        .overlay(DS.rect(10).strokeBorder(DS.dangerStroke, lineWidth: 1))
    }

    var engineBadge: some View {
        Text(state.activeEngine.displayName.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(engineTint)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(DS.rect(5).fill(engineTint.opacity(0.11)))
            .overlay(DS.rect(5).strokeBorder(engineTint.opacity(0.24), lineWidth: 1))
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
                    .foregroundStyle(state.overviewContextUsedTokens > 0 ? engineTint : DS.text4)
                    .fixedSize()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.line2)
                    if contextProgress > 0 {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [engineTint.opacity(0.82), engineTint],
                                    startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, proxy.size.width * contextProgress))
                    }
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: First-run checklist

    var activeEngineHasLocalModels: Bool {
        state.libraryEntries(for: state.activeEngine).contains(where: \.installed)
    }

    var showsChecklist: Bool {
        !checklistDismissed && !state.isRunning
            && (state.runtimeMissing != nil || !activeEngineHasLocalModels)
    }

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
