// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

// MARK: - Page title in the native toolbar

/// toolbar 三类槽位的稳定标识。切页时每个页面都会重建自己的 `ToolbarItem`；
/// 不给 id 的话 AppKit 会把三枚 item 整排删掉再插回去（状态胶囊、动作按钮都会
/// 跟着走一段进出场），给了 id 才会原地更新内容。
enum DSToolbarSlot {
    static let title = "flashCat.toolbar.title"
    static let anchor = "flashCat.toolbar.anchor"
    static let actions = "flashCat.toolbar.actions"
}

/// 原生 toolbar 的页名：左对齐、贴住内容左缘。
/// 页名不承载页面统计或全局状态；统计留在内容区，全局状态在右端仪表胶囊里。
/// 窄窗口同样只留页名。
struct DSToolbarPageTitle: View {
    var title: String

    var body: some View {
        Text(L10n.t(title))
            .font(DS.Font.prose(15, weight: .semibold))
            .tracking(-0.2)
            .foregroundStyle(DS.text)
            .lineLimit(1)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Toolbar action row

/// macOS 26 的 toolbar 在没有 principal 槽时，会把 trailing 动作紧贴在页名后面；
/// 放一枚 1pt 的透明锚点占住 principal，动作与仪表胶囊才会贴住内容右缘。
struct DSToolbarAnchor: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
    }
}

/// 页面动作在左、仪表胶囊在右；动作之间 6pt，动作组与胶囊 12pt。
/// 所有控制台页面共用这一条结构，右侧不再各写一套。
struct DSToolbarActionRow<Actions: View>: View {
    @ObservedObject var state: AppState
    var compact: Bool = false
    var showsSpeed: Bool = true
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                actions()
            }
            DSGlobalStatusCluster(state: state, compact: compact, showsSpeed: showsSpeed)
        }
        .fixedSize()
        // toolbar 自带 trailing 内缩；补 15pt 让胶囊右缘落在内容右缘（20pt 留白）。
        .padding(.trailing, 15)
    }
}

// MARK: - Global status cluster

/// 原生 toolbar 最右端的「仪表胶囊」：引擎 / 下载 / 通知。
/// 每段都能点开一张小卡；正则宽、窄则只留引擎状态与铃铛。
struct DSGlobalStatusCluster: View {
    @ObservedObject var state: AppState
    @ObservedObject private var metrics: MetricsStore
    var compact: Bool = false
    var showsSpeed: Bool = true

    @State private var engineOpen = false
    @State private var activityOpen = false
    @State private var hovered: Segment?

    private enum Segment: Hashable {
        case engine, download, notices
    }

    init(state: AppState, compact: Bool = false, showsSpeed: Bool = true) {
        self.state = state
        self.compact = compact
        self.showsSpeed = showsSpeed
        self._metrics = ObservedObject(wrappedValue: state.metrics)
    }

    // MARK: Derived state

    private var status: (text: String, color: Color, live: Bool) {
        switch state.serverState {
        case .failed:
            return (L10n.t("异常"), DS.err, false)
        case .ready where state.canChat:
            return (L10n.t("运行中"), DS.ok, true)
        case .starting, .stopping:
            let stage = state.engineStageText
            return (stage.isEmpty ? L10n.t(state.serverState.rawValue) : stage, DS.warn, true)
        case .ready:
            let stage = state.engineStageText
            return (stage.isEmpty ? L10n.t("准备中") : stage, DS.warn, true)
        case .stopped:
            return (L10n.t("已停止"), DS.text3, false)
        }
    }

    /// 平均解码。芯片上只放稳定读数，实时波动交给概览与弹层里的详细指标。
    private var speed: Double? {
        guard state.isRunning,
            let value = metrics.averageDecodeReading(isRunning: true).value,
            value > 0
        else { return nil }
        return value
    }

    private var activeDownload: ModelDownloadTask? {
        state.downloadTasks.first { $0.status == .downloading }
    }

    private var downloadFraction: Double? {
        if let fraction = activeDownload?.fraction { return fraction }
        return state.downloadFraction
    }

    private var showsDownload: Bool {
        !compact
            && (state.downloadingModel != nil
                || state.downloadTasks.contains { $0.status == .downloading })
    }

    private var downloadPercent: Int {
        Int((min(max(downloadFraction ?? 0, 0), 1) * 100).rounded())
    }

    private var noticeIsError: Bool {
        state.islandNotices.prefix(state.islandUnread).contains { $0.kind == .error }
    }

    private var noticeTint: Color {
        noticeIsError ? DS.err : DS.accentFill
    }

    // MARK: Body

    private var shape: RoundedRectangle { DS.rect(DS.Radius.sm) }

    var body: some View {
        HStack(spacing: 0) {
            engineSegment
            if showsDownload {
                clusterDivider
                downloadSegment
            }
            clusterDivider
            noticeSegment
        }
        .frame(height: 28)
        .background(shape.fill(DS.pillFill))
        .overlay(shape.strokeBorder(DS.line, lineWidth: 1))
        .clipShape(shape)
        .accessibilityElement(children: .contain)
    }

    private var clusterDivider: some View {
        Rectangle()
            .fill(DS.line2)
            .frame(width: 1, height: 14)
            .accessibilityHidden(true)
    }

    private var engineSegment: some View {
        Button {
            activityOpen = false
            engineOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                DSStatusDot(color: status.color, live: status.live, size: 6)
                Text(status.text)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(status.color)
                    .lineLimit(1)
                if !compact, showsSpeed, let speed {
                    Text(verbatim: "\(Format.compact(speed)) tok/s")
                        .font(DS.Font.number(11.5, weight: .semibold))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                }
                if !compact {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DS.text4)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(hovered == .engine ? DS.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? .engine : nil }
        .help(L10n.t("引擎状态与快速操作"))
        .popover(isPresented: $engineOpen, arrowEdge: .top) {
            DSEngineToolbarPopover(state: state)
        }
    }

    private var downloadSegment: some View {
        Button {
            engineOpen = false
            activityOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                Text(verbatim: "\(downloadPercent)%")
                    .font(DS.Font.number(11, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(DS.accent)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovered == .download ? DS.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? .download : nil }
        .help(L10n.t("下载进度"))
    }

    private var noticeSegment: some View {
        Button {
            engineOpen = false
            activityOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "bell")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(state.islandUnread > 0 ? DS.text2 : DS.text3)
                if state.islandUnread > 0 {
                    DSBadge(
                        count: state.islandUnread,
                        tint: noticeTint,
                        foreground: noticeIsError ? .white : DS.onAccent)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovered == .notices ? DS.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? .notices : nil }
        .help(L10n.t("下载与通知"))
        .popover(isPresented: $activityOpen, arrowEdge: .top) {
            DSActivityToolbarPopover(state: state, isPresented: $activityOpen)
        }
    }
}

// MARK: - Engine popover

private struct DSEngineToolbarPopover: View {
    @ObservedObject var state: AppState

    private var status: (text: String, color: Color, live: Bool) {
        switch state.serverState {
        case .failed: return ("异常", DS.err, false)
        case .ready where state.canChat: return ("运行中", DS.ok, true)
        case .starting, .stopping:
            let stage = state.engineStageText
            return (stage.isEmpty ? state.serverState.rawValue : stage, DS.warn, true)
        case .ready:
            let stage = state.engineStageText
            return (stage.isEmpty ? "准备中" : stage, DS.warn, true)
        case .stopped: return ("已停止", DS.text3, false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                EngineMark(id: state.activeEngine, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.activeEngine.displayName)
                        .font(DS.Font.prose(13, weight: .semibold))
                        .foregroundStyle(DS.text)
                    HStack(spacing: 4) {
                        Text(verbatim: "127.0.0.1:\(state.port)")
                            .font(DS.Font.mono(10.5))
                            .foregroundStyle(DS.text3)
                        Button {
                            state.copy("127.0.0.1:\(state.port)")
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(DS.text3)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("复制接口地址"))
                    }
                }
                Spacer(minLength: 6)
                DSChip(
                    text: status.text,
                    dot: status.color,
                    live: status.live,
                    tint: status.color)
            }

            Rectangle().fill(DS.line).frame(height: 1)

            HStack(spacing: 6) {
                Button {
                    state.toggleService()
                } label: {
                    Label(
                        state.isRunning ? L10n.t("停止") : L10n.t("启动"),
                        systemImage: state.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.ds(state.isRunning ? .danger : .secondary, size: .small))

                Button {
                    state.restartService()
                } label: {
                    Label(L10n.t("重启"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.ds(.secondary, size: .small))
                .disabled(!state.isRunning)

                Button {
                    state.section = .logs
                } label: {
                    Label(L10n.t("日志"), systemImage: "doc.text")
                }
                .buttonStyle(.ds(.ghost, size: .small))
            }
        }
        .padding(12)
        .frame(width: 320)
        .dsPopoverSurface()
    }
}

// MARK: - Activity popover

private struct DSActivityToolbarPopover: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool

    private var tasks: [ModelDownloadTask] {
        Array(
            state.downloadTasks
                .filter { $0.status == .downloading || $0.status == .paused || $0.status == .failed }
                .prefix(2))
    }

    private var notices: [IslandNotice] {
        Array(state.islandNotices.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.t("活动"))
                    .font(DS.Font.prose(13.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text(L10n.t(activitySubtitle))
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
                Spacer(minLength: 8)
                if state.islandUnread > 0 {
                    Button(L10n.t("全部已读")) {
                        state.markIslandNoticesRead()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.accent)
                }
            }
            .padding(.bottom, 9)

            if !tasks.isEmpty {
                sectionLabel("进行中")
                VStack(spacing: 6) {
                    ForEach(tasks) { task in
                        downloadRow(task)
                    }
                }
            }

            sectionLabel("通知")
            if notices.isEmpty {
                Text(L10n.t("暂无阻塞通知"))
                    .font(DS.Font.prose(11.5))
                    .foregroundStyle(DS.text3)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(notices) { notice in
                        noticeRow(notice)
                    }
                }
            }

            Rectangle().fill(DS.line).frame(height: 1).padding(.top, 8)

            HStack(spacing: 6) {
                Button(L10n.t("打开下载中心")) {
                    isPresented = false
                    DispatchQueue.main.async {
                        state.showsDownloadCenter = true
                    }
                }
                .buttonStyle(.ds(.ghost, size: .small))

                Button(L10n.t("查看日志")) {
                    isPresented = false
                    state.section = .logs
                }
                .buttonStyle(.ds(.ghost, size: .small))
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(width: 340)
        .dsPopoverSurface()
    }

    private var activitySubtitle: String {
        var parts: [String] = []
        if !tasks.isEmpty { parts.append(L10n.format("%lld 个下载", Int64(tasks.count))) }
        if state.islandUnread > 0 {
            parts.append(L10n.format("%lld 条未读", Int64(state.islandUnread)))
        }
        return parts.isEmpty ? L10n.t("暂无后台任务") : parts.joined(separator: " · ")
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(L10n.t(text))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(DS.text3)
            .padding(.top, 2)
            .padding(.bottom, 5)
    }

    private func downloadRow(_ task: ModelDownloadTask) -> some View {
        let fraction = task.fraction ?? (task.status == .downloading ? state.downloadFraction : nil)
        let speed = task.status == .downloading ? state.downloadSpeed : 0
        let percent = Int(((fraction ?? 0) * 100).rounded())
        let statusText: String =
            switch task.status {
            case .downloading: "\(percent)%"
            case .paused: L10n.t("已暂停")
            case .failed: L10n.t("失败")
            }

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.down")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(DS.accent)
                .frame(width: 22, height: 22)
                .background(DS.rect(6).fill(DS.accentSoft))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(state.shortModelName(task.model))
                        .font(DS.Font.prose(11.5, weight: .medium))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(verbatim: statusText)
                        .font(DS.Font.number(10.5, weight: .semibold))
                        .foregroundStyle(task.status == .failed ? DS.err : DS.accent)
                }

                DSMeter(value: fraction ?? 0, tint: DS.accent)
                    .frame(height: 3)

                HStack(spacing: 8) {
                    Text(verbatim: downloadDetail(task, fraction: fraction, speed: speed))
                        .font(.system(size: 10.5))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    downloadControls(task)
                }
            }
        }
        .padding(9)
        .background(DS.rect(DS.Radius.md).fill(DS.bg))
    }

    private func downloadDetail(
        _ task: ModelDownloadTask,
        fraction: Double?,
        speed: Double
    ) -> String {
        if task.status == .paused {
            return L10n.format(
                "已下载 %@ / %@",
                Format.size(task.downloadedBytes),
                task.totalBytes > 0 ? Format.size(task.totalBytes) : "—")
        }
        if task.status == .failed {
            return L10n.t("传输中断，可继续")
        }
        let speedText = Format.rate(speed)
        if task.totalBytes > 0 {
            return "\(speedText) · \(Format.size(task.downloadedBytes)) / \(Format.size(task.totalBytes))"
        }
        return speedText
    }

    @ViewBuilder
    private func downloadControls(_ task: ModelDownloadTask) -> some View {
        HStack(spacing: 1) {
            if task.status == .downloading {
                iconButton("pause.fill", help: "暂停下载") {
                    state.pauseDownload()
                }
            } else {
                iconButton("play.fill", help: "继续下载") {
                    state.resumeDownload(task)
                }
            }
            iconButton("xmark", help: "取消下载") {
                state.cancelDownload(task)
            }
        }
    }

    private func iconButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(DS.text3)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t(help))
    }

    private func noticeRow(_ notice: IslandNotice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(noticeColor(notice.kind))
                .frame(width: 6, height: 6)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title)
                    .font(DS.Font.prose(11.5, weight: .medium))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                Text(notice.message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.text3)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Text(verbatim: Format.clock(notice.date))
                .font(.system(size: 10))
                .foregroundStyle(DS.text4)
                .monospacedDigit()
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
    }

    private func noticeColor(_ kind: IslandNotice.Kind) -> Color {
        switch kind {
        case .info: return DS.info
        case .success: return DS.ok
        case .warning: return DS.warn
        case .error: return DS.err
        }
    }
}
