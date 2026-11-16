import SwiftUI

/// 侧栏左下角状态胶囊层。收起时停在侧栏底部「设置」栏上方；
/// 点击平滑向上展开为适配侧栏宽高的 Liquid Glass 浮层卡，点击外部或按 Esc 收起。
struct DynamicIslandLayer: View {
    @ObservedObject var state: AppState
    @Binding var expanded: Bool
    var bottomOffset: CGFloat = 54

    var body: some View {
        GeometryReader { proxy in
            let maxListHeight = max(120, min(240, proxy.size.height - bottomOffset - 220))

            ZStack(alignment: .bottomLeading) {
                if expanded {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { collapse() }
                }

                DynamicIsland(state: state,
                              expanded: $expanded,
                              maxListHeight: maxListHeight)
                    .padding(.leading, 10)
                    .padding(.bottom, bottomOffset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .onExitCommand {
            if expanded { collapse() }
        }
    }

    private func collapse() {
        withAnimation(DS.Motion.bouncy) { expanded = false }
    }
}

/// 侧栏底部的自适应 Liquid Glass 状态胶囊。收起与展开均严格适配侧栏宽度（196pt），
/// 向上展开时根据窗口高度自适应内容与通知列表高度。
struct DynamicIsland: View {
    @ObservedObject var state: AppState
    @Binding var expanded: Bool
    var maxListHeight: CGFloat = 200

    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    private var rate: Double {
        let reading = state.decodeReading
        guard reading.origin == .gatewayLive || reading.origin == .engineLive,
              let value = reading.value, value > 0 else { return 0 }
        return value
    }

    private var hasNotices: Bool { !state.islandNotices.isEmpty }
    private var showsNotice: Bool { state.islandNotice != nil }

    private var sidebarIslandWidth: CGFloat {
        DS.Layout.sidebarWidth - 20
    }

    private var cornerRadius: CGFloat { expanded ? 14 : DS.Radius.md }
    private var shape: RoundedRectangle { DS.rect(cornerRadius) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expanded {
                detail
                    .transition(detailTransition)
                DSDivider()
            }

            collapsedBar
        }
        .frame(width: sidebarIslandWidth)
        .glassEffect(expanded ? .regular : .regular.interactive(), in: shape)
        .shadow(color: Color.black.opacity(scheme == .dark ? (expanded ? 0.42 : 0.16)
                                                           : (expanded ? 0.12 : 0.04)),
                radius: expanded ? 20 : 8,
                y: expanded ? -4 : 2)
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
        .animation(DS.Motion.bouncy, value: state.islandNotice?.id)
        .animation(DS.Motion.bouncy, value: state.islandNotices)
    }

    // MARK: - Collapsed

    private var collapsedBar: some View {
        HStack(spacing: 6) {
            summaryContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(DS.Motion.bouncy) { expanded.toggle() }
                }

            trailingControl
        }
        .padding(.horizontal, 9)
        .padding(.vertical, showsNotice ? 6 : 0)
        .frame(minHeight: 34)
        .contentShape(shape)
    }

    private var summaryContent: some View {
        ZStack(alignment: .leading) {
            if let notice = state.islandNotice {
                HStack(spacing: 6) {
                    noticeBadge(notice.kind, size: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.t(notice.title))
                            .font(DS.Font.xs.weight(.semibold))
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(notice.message)
                            .font(.system(size: 10.5))
                            .foregroundStyle(DS.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if state.islandUnread > 1 {
                        unreadBadge
                    }
                }
                .transition(summaryTransition)
            } else {
                HStack(spacing: 5) {
                    engineDot
                    Text(state.activeEngine.displayName)
                        .font(DS.Font.xs.weight(.semibold))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if rate > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(Format.compact(rate))
                                .font(DS.Font.mono(10.5, weight: .semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundStyle(DS.ok)
                            Text("tok/s")
                                .font(DS.Font.mono(9))
                                .foregroundStyle(DS.text3)
                        }
                        .padding(.horizontal, 5)
                        .frame(height: 17)
                        .background(DS.rect(DS.Radius.sm).fill(DS.ok.opacity(0.12)))
                        .fixedSize()
                    } else {
                        Text(state.engineStageText)
                            .font(DS.Font.xs)
                            .foregroundStyle(DS.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if state.islandUnread > 0 {
                        unreadBadge
                    }
                }
                .transition(summaryTransition)
            }
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
                Image(systemName: "chevron.down")
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
                Image(systemName: "chevron.up")
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
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(state.isRunning ? DS.err.opacity(0.14) : DS.hover))
                    .contentShape(Circle())
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
        HStack(spacing: 6) {
            Image(systemName: hasNotices ? "bell.badge.fill" : "cpu.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DS.text3)
            Text(L10n.t(hasNotices ? "通知" : "引擎详情"))
                .font(DS.Font.xs.weight(.semibold))
                .foregroundStyle(DS.text)
                .contentTransition(.opacity)
                .lineLimit(1)

            if hasNotices {
                Text(verbatim: "\(state.islandNotices.count)")
                    .font(DS.Font.mono(9.5, weight: .semibold))
                    .foregroundStyle(DS.text2)
                    .contentTransition(.numericText())
                    .padding(.horizontal, 4)
                    .frame(height: 15)
                    .background(DS.rect(4).fill(DS.surface))
                    .overlay(DS.rect(4).strokeBorder(DS.line, lineWidth: 1))
            }

            Spacer(minLength: 4)

            if hasNotices {
                Button("清空") {
                    state.clearIslandNotices()
                }
                .buttonStyle(.ds(.ghost, size: .small))
                .help("清空通知历史")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var noticeList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(state.islandNotices) { notice in
                    VStack(spacing: 0) {
                        noticeRow(notice)
                        if notice.id != state.islandNotices.last?.id {
                            DSDivider()
                                .padding(.leading, 18)
                        }
                    }
                    .transition(noticeRowTransition)
                }
            }
            .animation(DS.Motion.bouncy, value: state.islandNotices)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: maxListHeight)
    }

    private func noticeRow(_ notice: IslandNotice) -> some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(notice.kind.tint)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    noticeBadge(notice.kind, size: 14)
                    Text(L10n.t(notice.title))
                        .font(DS.Font.xs.weight(.semibold))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(Format.relative(notice.date))
                        .font(DS.Font.mono(9.5))
                        .foregroundStyle(DS.text4)
                        .fixedSize()
                }
                Text(notice.message)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.text2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var engineDetail: some View {
        let modelName = state.selectedModel.isEmpty ? "—" : state.shortModelName(state.selectedModel)
        return VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("模型"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.text3)
                Text(L10n.t(modelName))
                    .font(DS.Font.mono(11, weight: .medium))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(modelName)
            }
            detailRow("接口", "127.0.0.1:\(state.port)")
            detailRow("版本", state.engineVersion)
            detailRow("实时速度", state.canChat ? "\(Format.compact(rate)) tok/s" : "—")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.t(label))
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
                .fixedSize()
            Spacer(minLength: 6)
            Text(L10n.t(value))
                .font(DS.Font.mono(11))
                .foregroundStyle(DS.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button("日志") {
                state.section = .logs
                withAnimation(DS.Motion.bouncy) { expanded = false }
            }
            .buttonStyle(.ds(.secondary, size: .small))

            Spacer(minLength: 4)

            Button(L10n.t(state.isRunning ? "停止" : "启动")) {
                state.toggleService()
            }
            .buttonStyle(.ds(state.isRunning ? .danger : .primary, size: .small))
            .disabled(state.isSwitchingModel || state.runtimeMissing != nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var summaryTransition: AnyTransition {
        AnyTransition.modifier(
            active: IslandMotion(active: true, scale: 0.94, blur: 4, anchor: .leading),
            identity: IslandMotion(active: false, scale: 1, blur: 0, anchor: .leading)
        )
    }

    private var detailTransition: AnyTransition {
        AnyTransition.modifier(
            active: IslandMotion(active: true, scale: 0.96, blur: 4, anchor: .bottom),
            identity: IslandMotion(active: false, scale: 1, blur: 0, anchor: .bottom)
        )
    }

    private var noticeRowTransition: AnyTransition {
        AnyTransition.modifier(
            active: IslandMotion(active: true, scale: 0.98, blur: 2, anchor: .bottom),
            identity: IslandMotion(active: false, scale: 1, blur: 0, anchor: .bottom)
        )
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
