// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import SwiftUI

/// 标题栏顶部状态胶囊层。收起时居中展示当前引擎/实时速度或临时通知；
/// 点击平滑展开浮层卡片，点击外部或按 Esc 收起。
struct DynamicIslandLayer: View {
    @ObservedObject var state: AppState
    @Binding var expanded: Bool
    var leadingOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            if expanded {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { collapse() }
            }

            DynamicIsland(state: state, expanded: $expanded)
                .padding(.top, 7)
                .padding(.horizontal, 16)
                .padding(.leading, leadingOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onExitCommand {
            if expanded { collapse() }
        }
    }

    private func collapse() {
        withAnimation(DS.Motion.bouncy) { expanded = false }
    }
}

/// 标题栏中央的自适应状态胶囊。极简平面底 + 1px 描边，收起贴合 44pt 顶栏，展开即浮层卡。
struct DynamicIsland: View {
    @ObservedObject var state: AppState
    @Binding var expanded: Bool

    @State private var summaryWidth: CGFloat = 0
    @State private var hovering = false

    private var rate: Double {
        let reading = state.decodeReading
        guard reading.origin == .gatewayLive || reading.origin == .engineLive,
            let value = reading.value, value > 0
        else { return 0 }
        return value
    }

    private var hasNotices: Bool { !state.islandNotices.isEmpty }
    private var showsNotice: Bool { state.islandNotice != nil }

    private var collapsedWidth: CGFloat? {
        guard summaryWidth > 1 else { return nil }
        return max(168, min(summaryWidth + 62, 400))
    }

    private var cornerRadius: CGFloat { expanded ? DS.Radius.lg : 15 }
    private var shape: RoundedRectangle { DS.rect(cornerRadius) }

    private var surfaceFill: Color {
        if expanded { return DS.raised }
        return hovering ? DS.surface : DS.bg
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedBar

            if expanded {
                detail
                    .transition(detailTransition)
            }
        }
        .frame(width: expanded ? 400 : collapsedWidth)
        .fixedSize(horizontal: !expanded, vertical: false)
        .background(shape.fill(surfaceFill))
        .overlay(shape.strokeBorder(expanded || hovering ? DS.line2 : DS.line, lineWidth: 1))
        .clipShape(shape)
        .shadow(
            color: expanded ? DS.shadow : .clear,
            radius: expanded ? 24 : 0,
            y: expanded ? 12 : 0
        )
        .contentShape(shape)
        .onHover { inside in
            withAnimation(DS.Motion.snappy) { hovering = inside }
        }
        .onChange(of: expanded) { _, value in
            if value { state.markIslandNoticesRead() }
        }
        .onChange(of: state.islandNotices.count) { _, _ in
            if expanded { state.markIslandNoticesRead() }
        }
        .animation(DS.Motion.bouncy, value: expanded)
        .animation(DS.Motion.smooth, value: showsNotice)
        .animation(DS.Motion.bouncy, value: summaryWidth)
        .animation(DS.Motion.bouncy, value: state.islandNotice?.id)
        .animation(DS.Motion.bouncy, value: state.islandNotices)
    }

    // MARK: - Collapsed

    private var collapsedBar: some View {
        HStack(spacing: DS.Space.sm) {
            summaryContent
                .layoutPriority(1)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !expanded else { return }
                    withAnimation(DS.Motion.bouncy) { expanded = true }
                }

            Spacer(minLength: 0)

            trailingControl
        }
        .padding(.horizontal, 11)
        .padding(.vertical, showsNotice ? 6 : 0)
        .frame(minHeight: 30)
        .contentShape(shape)
    }

    private var summaryContent: some View {
        ZStack(alignment: .leading) {
            if let notice = state.islandNotice {
                HStack(spacing: DS.Space.sm) {
                    noticeBadge(notice.kind, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.t(notice.title))
                            .font(DS.Font.sm.weight(.semibold))
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(notice.message)
                            .font(DS.Font.xs)
                            .foregroundStyle(DS.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: 320, alignment: .leading)
                    if state.islandUnread > 1 {
                        unreadBadge
                    }
                }
                .transition(summaryTransition)
            } else {
                HStack(spacing: 6) {
                    engineDot
                    Text(state.activeEngine.displayName)
                        .font(DS.Font.sm.weight(.semibold))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(state.engineStageText)
                        .font(DS.Font.xs)
                        .foregroundStyle(DS.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if rate > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(Format.compact(rate))
                                .font(DS.Font.mono(11, weight: .semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundStyle(DS.ok)
                            Text("tok/s")
                                .font(DS.Font.mono(9.5))
                                .foregroundStyle(DS.text3)
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(DS.rect(DS.Radius.sm).fill(DS.ok.opacity(0.12)))
                    }
                    if state.islandUnread > 0 {
                        unreadBadge
                    }
                }
                .transition(summaryTransition)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: IslandSummaryWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(IslandSummaryWidthKey.self) { width in
            guard width > 1 else { return }
            summaryWidth = width
        }
        .animation(DS.Motion.bouncy, value: state.islandNotice?.id)
    }

    private var lifecycleTint: Color {
        if state.serverState == .failed { return DS.err }
        if state.canChat { return DS.ok }
        if state.isModelBusy { return DS.warn }
        return DS.text4
    }

    @ViewBuilder
    private var engineDot: some View {
        if state.isModelBusy {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.55)
                .frame(width: 10, height: 10)
                .tint(DS.warn)
        } else {
            DSStatusDot(color: lifecycleTint, live: state.canChat, size: 6)
                .padding(.horizontal, 1)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if expanded {
            Button {
                withAnimation(DS.Motion.bouncy) { expanded = false }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(DS.text3)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(DSPressStyle())
            .help("收起")
        } else if state.islandNotice != nil {
            Button {
                withAnimation(DS.Motion.bouncy) { expanded = true }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(DS.text3)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(DSPressStyle())
            .help(L10n.t(hasNotices ? "查看通知" : "引擎详情"))
        } else {
            Button {
                state.toggleService()
            } label: {
                Image(systemName: state.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(state.isRunning ? DS.err : DS.text2)
                    .frame(width: 20, height: 20)
                    .background(DS.rect(DS.Radius.sm).fill(state.isRunning ? DS.err.opacity(0.14) : DS.surface))
                    .contentShape(DS.rect(DS.Radius.sm))
            }
            .buttonStyle(DSPressStyle())
            .disabled(state.isSwitchingModel || state.runtimeMissing != nil)
            .help(L10n.t(state.isRunning ? "停止引擎" : "启动引擎"))
        }
    }

    private var unreadBadge: some View {
        DSBadge(count: min(state.islandUnread, 99))
    }

    private func noticeBadge(_ kind: IslandNotice.Kind, size: CGFloat) -> some View {
        ZStack {
            DS.rect(DS.Radius.sm)
                .fill(kind.tint.opacity(0.16))
                .frame(width: size, height: size)
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(kind.tint)
        }
    }

    // MARK: - Expanded

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSDivider()
            detailHeader
            DSDivider()

            if hasNotices {
                noticeList
                    .transition(summaryTransition)
            } else {
                engineDetail
                    .transition(summaryTransition)
            }

            DSDivider()
            footer
        }
        .animation(DS.Motion.smooth, value: hasNotices)
    }

    private var detailHeader: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: hasNotices ? "bell.badge.fill" : "cpu.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.text3)
            Text(L10n.t(hasNotices ? "通知" : "引擎详情"))
                .font(DS.Font.sm.weight(.medium))
                .foregroundStyle(DS.text)
                .contentTransition(.opacity)

            if hasNotices {
                Text(verbatim: "\(state.islandNotices.count)")
                    .font(DS.Font.mono(10, weight: .semibold))
                    .foregroundStyle(DS.text2)
                    .contentTransition(.numericText())
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(DS.rect(4).fill(DS.surface))
                    .overlay(DS.rect(4).strokeBorder(DS.line, lineWidth: 1))
            }

            Spacer(minLength: 8)

            if hasNotices {
                Button("清空") {
                    state.clearIslandNotices()
                }
                .buttonStyle(.ds(.ghost, size: .small))
                .help("清空通知历史")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    private var noticeList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(state.islandNotices) { notice in
                    VStack(spacing: 0) {
                        noticeRow(notice)
                        if notice.id != state.islandNotices.last?.id {
                            DSDivider()
                                .padding(.leading, 40)
                        }
                    }
                    .transition(noticeRowTransition)
                }
            }
            .animation(DS.Motion.bouncy, value: state.islandNotices)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: 240)
    }

    private func noticeRow(_ notice: IslandNotice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(notice.kind.tint)
                .frame(width: 2)

            noticeBadge(notice.kind, size: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(L10n.t(notice.title))
                        .font(DS.Font.sm.weight(.medium))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Format.relative(notice.date))
                        .font(DS.Font.mono(10))
                        .foregroundStyle(DS.text4)
                }
                Text(notice.message)
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var engineDetail: some View {
        VStack(spacing: 8) {
            detailRow("模型", state.selectedModel.isEmpty ? "—" : state.shortModelName(state.selectedModel))
            detailRow("接口", "127.0.0.1:\(state.port)")
            detailRow("版本", state.engineVersion)
            detailRow("实时速度", state.canChat ? "\(Format.compact(rate)) tok/s" : "—")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L10n.t(label))
                .font(DS.Font.sm)
                .foregroundStyle(DS.text3)
                .frame(width: 60, alignment: .leading)
            Spacer(minLength: 8)
            Text(L10n.t(value))
                .font(DS.Font.mono(12))
                .foregroundStyle(DS.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            engineDot
            Text(state.activeEngine.displayName)
                .font(DS.Font.xs.weight(.semibold))
                .foregroundStyle(DS.text2)
            Text(state.engineStageText)
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button("日志") {
                state.section = .logs
                withAnimation(DS.Motion.bouncy) { expanded = false }
            }
            .buttonStyle(.ds(.secondary, size: .small))

            Button(L10n.t(state.isRunning ? "停止" : "启动")) {
                state.toggleService()
            }
            .buttonStyle(.ds(state.isRunning ? .danger : .primary, size: .small))
            .disabled(state.isSwitchingModel || state.runtimeMissing != nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var summaryTransition: AnyTransition {
        AnyTransition.modifier(
            active: IslandMotion(active: true, scale: 0.94, blur: 4, anchor: .leading),
            identity: IslandMotion(active: false, scale: 1, blur: 0, anchor: .leading)
        )
    }

    private var detailTransition: AnyTransition {
        AnyTransition.modifier(
            active: IslandMotion(active: true, scale: 0.96, blur: 4, anchor: .top),
            identity: IslandMotion(active: false, scale: 1, blur: 0, anchor: .top)
        )
    }

    private var noticeRowTransition: AnyTransition {
        AnyTransition.modifier(
            active: IslandMotion(active: true, scale: 0.98, blur: 2, anchor: .top),
            identity: IslandMotion(active: false, scale: 1, blur: 0, anchor: .top)
        )
    }
}

private struct IslandSummaryWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct IslandMotion: ViewModifier {
    let active: Bool
    let scale: CGFloat
    let blur: CGFloat
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? scale : 1, anchor: anchor)
            .blur(radius: active ? blur : 0)
    }
}

extension IslandNotice.Kind {
    var tint: Color {
        switch self {
        case .info: return DS.info
        case .success: return DS.ok
        case .warning: return DS.warn
        case .error: return DS.err
        }
    }
}
