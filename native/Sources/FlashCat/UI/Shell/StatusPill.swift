// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

// 侧栏收起后的常驻状态、通知出口与引擎详情弹层。
//
// 侧栏展开时不再有常驻状态块：状态、阶段与实时读数只在收起态以紧凑胶囊出现，
// 点开是这里共用的详情弹层。`UIStateStore.toast` 发布的通知由
// `FloatingNoticeToast` 在窗口左下角承担，侧栏展开与收起都是同一个出口。

// MARK: - Detail popover

private struct StatusDetailPopover: View {
    @ObservedObject var state: AppState
    @ObservedObject private var gateway = GatewayController.shared
    var dismiss: () -> Void

    private var notices: [IslandNotice] { Array(state.islandNotices.prefix(6)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            DSDivider()
            facts
            actions
            DSDivider()
            noticeHistory
        }
        .padding(14)
        .frame(width: 322)
        .dsPopoverSurface()
    }

    private var header: some View {
        HStack(spacing: 9) {
            EngineMark(
                id: state.activeEngine, size: 30,
                ring: engineAccent(state.activeEngine))
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t(state.activeEngine.displayName))
                    .font(DS.Font.md.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text(verbatim: "\(state.engineVersion.isEmpty ? "—" : state.engineVersion) · 127.0.0.1:\(state.port)")
                    .font(DS.Font.mono(10.5))
                    .foregroundStyle(DS.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            DSChip(
                text: state.canChat ? "运行中" : state.serverState.rawValue,
                dot: state.canChat ? DS.ok : (state.isModelBusy ? DS.warn : DS.text4),
                live: state.canChat)
        }
    }

    private var facts: some View {
        VStack(spacing: 0) {
            factRow("当前模型", state.selectedModelInfo?.shortName ?? state.shortModelName(state.selectedModel))
            DSDivider()
            factRow(
                "上下文",
                contextText)
            DSDivider()
            factRow(
                "网关",
                gateway.isRunning
                    ? "\(state.gatewayURL) · \(L10n.t("在线"))"
                    : L10n.t("离线"))
            DSDivider()
            factRow("活跃会话", "\(state.stats?.activeRequests ?? 0)")
        }
    }

    private var contextText: String {
        let used = Format.tokens(state.overviewContextUsedTokens)
        guard let ceiling = state.contextWindowCeiling else { return used }
        return "\(used) / \(Format.tokensShort(ceiling))"
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(L10n.t(label))
                .font(DS.Font.prose(11.5))
                .foregroundStyle(DS.text3)
                .frame(width: 64, alignment: .leading)
            Text(verbatim: value)
                .font(DS.Font.proseNumber(11.5))
                .foregroundStyle(DS.text2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 27)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                state.toggleService()
                dismiss()
            } label: {
                Label(
                    L10n.t(state.isRunning ? "停止引擎" : "启动引擎"),
                    systemImage: state.isRunning ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.ds(state.isRunning ? .danger : .primary, size: .small))
            .disabled(state.isModelBusy || (!state.isRunning && state.selectedModel.isEmpty))

            Button {
                state.section = .logs
                dismiss()
            } label: {
                Text(L10n.t("查看日志"))
            }
            .buttonStyle(.ds(.secondary, size: .small))

            Button {
                state.copy(state.gatewayURL, label: L10n.t("接口地址已复制"))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.ds(.secondary, size: .small))
            .help(L10n.t("复制网关地址"))
        }
    }

    private var noticeHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t("通知"))
                    .font(DS.Font.xs.weight(.medium))
                    .foregroundStyle(DS.text3)
                Spacer()
                if !state.islandNotices.isEmpty {
                    Button(L10n.t("清空")) { state.clearIslandNotices() }
                        .buttonStyle(.dsGhost)
                        .font(DS.Font.xs)
                }
            }

            if notices.isEmpty {
                Text(L10n.t("暂无通知"))
                    .font(DS.Font.prose(11.5))
                    .foregroundStyle(DS.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(notices) { notice in
                            HStack(alignment: .top, spacing: 7) {
                                Circle()
                                    .fill(color(notice.kind))
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(notice.message)
                                        .font(DS.Font.prose(11.5))
                                        .foregroundStyle(DS.text2)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(Format.clock(notice.date))
                                        .font(DS.Font.mono(9.5))
                                        .foregroundStyle(DS.text4)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 132)
                .scrollIndicators(.never)
            }
        }
    }

    private func color(_ kind: IslandNotice.Kind) -> Color {
        switch kind {
        case .info: return DS.info
        case .success: return DS.ok
        case .warning: return DS.warn
        case .error: return DS.err
        }
    }
}

// MARK: - Compact status (sidebar hidden)

/// 侧栏收起后的常驻状态：窗口左下角一枚小胶囊，引擎 / 模型 / 实时解码与网关。
/// 不抢页面顶部的工具栏，也不像 toast 一样消失；点开仍是同一张详情弹层。
struct CompactStatusPill: View {
    @ObservedObject var state: AppState
    @ObservedObject private var gateway = GatewayController.shared

    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
            if showing { state.markIslandNoticesRead() }
        } label: {
            HStack(spacing: 7) {
                EngineMark(
                    id: state.activeEngine, size: 16,
                    ring: engineAccent(state.activeEngine))
                DSStatusDot(color: statusColor, live: state.canChat, size: 5)
                Text(stageText)
                    .font(DS.Font.prose(10.5))
                    .foregroundStyle(DS.text2)
                    .lineLimit(1)
                    .frame(maxWidth: 110, alignment: .leading)
                Text(modelName)
                    .font(DS.Font.proseNumber(11))
                    .foregroundStyle(DS.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                Text(decodeText)
                    .font(DS.Font.proseNumber(11, weight: .medium))
                    .foregroundStyle(decodeText == "—" ? DS.text4 : DS.text)
                    .contentTransition(.numericText())
                DSStatusDot(color: gateway.isRunning ? DS.ok : DS.text4, size: 4)
                if state.islandUnread > 0 {
                    DSBadge(count: state.islandUnread)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(DS.rect(DS.Radius.sm).fill(DS.raised))
            .overlay(DS.rect(DS.Radius.sm).strokeBorder(DS.line, lineWidth: 1))
            .contentShape(DS.rect(DS.Radius.sm))
        }
        .buttonStyle(.plain)
        .help(L10n.t("引擎状态"))
        .accessibilityLabel(L10n.t("引擎状态"))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            StatusDetailPopover(state: state, dismiss: { showing = false })
        }
    }

    private var statusColor: Color {
        if state.serverState == .failed { return DS.err }
        if state.canChat { return DS.ok }
        if state.isModelBusy || state.isRunning { return DS.warn }
        return DS.text4
    }

    private var stageText: String {
        if state.serverState == .failed { return L10n.t("异常") }
        let stage = state.engineStageText
        return stage.isEmpty ? L10n.t(state.serverState.rawValue) : stage
    }

    private var modelName: String {
        state.selectedModelInfo?.shortName
            ?? (state.selectedModel.isEmpty
                ? L10n.t("未选择模型")
                : state.shortModelName(state.selectedModel))
    }

    private var decodeText: String {
        guard let value = state.menuBarDecodeReading.value, value > 0 else { return "—" }
        return Format.compact(value)
    }
}

// MARK: - Floating toast (sidebar hidden)
/// 侧栏收起时的通知出口：同一份 `islandNotice`，浮在窗口左下角。
struct FloatingNoticeToast: View {
    let notice: IslandNotice
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: notice.kind.symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
                .background(DS.rect(DS.Radius.sm).fill(color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(DS.Font.prose(11.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text(notice.message)
                    .font(DS.Font.prose(11.5))
                    .foregroundStyle(DS.text2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.text3)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("关闭通知"))
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .dsFloating(radius: DS.Radius.lg)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    private var color: Color {
        switch notice.kind {
        case .info: return DS.info
        case .success: return DS.ok
        case .warning: return DS.warn
        case .error: return DS.err
        }
    }
}

// MARK: - Engine mark

/// 引擎图标：优先用 pack 里的上游 app icon，没有资产时退回引擎强调色的字母块。
struct EngineMark: View {
    let id: EngineID
    var size: CGFloat = 20
    /// 引擎识别色描边：官方图标本身的配色不能改，靠这一圈把「当前是哪台」
    /// 带到中性侧栏里。
    var ring: Color? = nil

    var body: some View {
        Group {
            if let asset = engineArtwork(id), let image = BrandGlyph.artwork(named: asset) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            } else {
                Text(String(id.displayName.prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                            .fill(engineAccent(id)))
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if let ring {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(ring.opacity(0.45), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}
