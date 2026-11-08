import SwiftUI

/// 标题栏顶部的灵动岛层。收起时只有中间那颗胶囊；展开时盖一层透明遮罩，
/// 点击胶囊以外的任何地方都会收回，和 iPhone 灵动岛的交互一致。
struct DynamicIslandLayer: View {
    @ObservedObject var state: AppState
    @Binding var expanded: Bool

    var body: some View {
        ZStack(alignment: .top) {
            if expanded {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { collapse() }
            }

            DynamicIsland(state: state, expanded: $expanded)
                .padding(.top, 6)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func collapse() {
        withAnimation(Motion.island) { expanded = false }
    }
}

/// 标题栏中央的常驻胶囊。没有通知时保持原来的引擎状态；有通知时短暂展示消息，
/// 点开后在原位展开通知历史与引擎详情。
struct DynamicIsland: View {
    @ObservedObject var state: AppState
    @Binding var expanded: Bool

    /// 收起态的实测内容宽度。用真实宽度做插值，展开/收起才能像灵动岛一样连续变形，
    /// 而不是先跳到固定宽度再淡入。
    @State private var summaryWidth: CGFloat = 0

    /// 鼠标悬停时的「果冻」缩放：先弹到略大，再回落到一个轻微的放大值。
    @State private var hoverScale: CGFloat = 1
    @State private var hoverResetTask: Task<Void, Never>?

    /// 灵动岛自己的语义色：深色模式是黑底白字，浅色模式是浅玻璃底深色字。
    private var ink: Color {
        Color.adaptive(dark: 0xF2F0F6, light: 0x15151D)
    }

    private var islandFillTop: Color {
        Color.adaptive(dark: 0x1D1C22, light: 0xF8F9FD)
    }

    private var islandFillBottom: Color {
        Color.adaptive(dark: 0x0A0A0D, light: 0xE6EAF2)
    }

    private var islandShadow: Color {
        Color.adaptive(dark: 0x000000, light: 0x000000, darkAlpha: 0.35, lightAlpha: 0.16)
    }

    private var rate: Double {
        // 引擎能给出真实时计数时优先用它：它覆盖所有会话（含直连引擎端口的
        // agent 请求），不会被「应用内这一路」或「上一轮请求的均值」带偏。
        if state.stats?.decodeRateKind == .live,
           let engine = state.stats?.decodeTokensPerSecond, engine > 0 {
            return engine
        }
        // 岛上显示的是「正在跑多快」，所以绝不回落到引擎的上一请求值或累计
        // 均值——那会让胶囊在完全空闲时也显示一个不是当前速度的数字。
        if let live = state.liveDecodeRate, live > 0 { return live }
        return 0
    }

    private var hasNotices: Bool { !state.islandNotices.isEmpty }

    private var showsNotice: Bool { state.islandNotice != nil }

    /// 收起态宽度：摘要实测宽度 + 2 段间距 + 右侧控件 + 左右内边距，
    /// 并限制在展开宽度以内，内容再长也不会把胶囊撑成一条。
    private var collapsedWidth: CGFloat? {
        guard summaryWidth > 1 else { return nil }
        return max(160, min(summaryWidth + 62, 400))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: expanded ? 26 : 16, style: .continuous)
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
        // 收起态必须按内容收敛。父级 overlay 会提出整窗宽度，不加这一行
        // 摘要会把「整窗宽度」量成自己的内容宽度，胶囊就永远停在最大宽度。
        .fixedSize(horizontal: !expanded, vertical: false)
        .background {
            shape
                .fill(
                    LinearGradient(colors: [islandFillTop, islandFillBottom],
                                   startPoint: .top, endPoint: .bottom)
                )
        }
        .overlay {
            shape.strokeBorder(
                LinearGradient(colors: [ink.opacity(0.22), ink.opacity(0.04)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 0.8
            )
        }
        .clipShape(shape)
        .shadow(color: islandShadow, radius: 18, y: 8)
        .scaleEffect(hoverScale)
        .contentShape(shape)
        .onHover(perform: handleHover)
        .onDisappear { hoverResetTask?.cancel() }
        .onChange(of: expanded) { _, value in
            if value { state.markIslandNoticesRead() }
        }
        .onChange(of: state.islandNotices.count) { _, _ in
            if expanded { state.markIslandNoticesRead() }
        }
        .animation(Motion.island, value: expanded)
        .animation(Motion.island, value: showsNotice)
        .animation(Motion.entrance, value: summaryWidth)
        .animation(Motion.entrance, value: state.islandNotice?.id)
        .animation(Motion.entrance, value: state.islandNotices)
    }

    // MARK: - Hover

    /// 鼠标移入时先快速放大（低阻尼弹簧会自然过冲），随后回落到轻微放大；
    /// 移出时再弹回原尺寸，做出果冻般「放大—回弹」的手感。
    private func handleHover(_ inside: Bool) {
        hoverResetTask?.cancel()

        guard inside else {
            withAnimation(Motion.island) { hoverScale = 1 }
            return
        }

        withAnimation(Motion.island) { hoverScale = 1.035 }
        hoverResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.island) { hoverScale = 1.012 }
        }
    }

    // MARK: - Collapsed

    private var collapsedBar: some View {
        HStack(spacing: 8) {
            summaryContent
                .layoutPriority(1)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !expanded else { return }
                    withAnimation(Motion.island) { expanded = true }
                }

            Spacer(minLength: 0)

            trailingControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, showsNotice ? 6 : 0)
        .frame(minHeight: 32)
        .contentShape(Capsule())
    }

    /// 收起态只保留标题与信息两行：有通知时是通知标题 + 正文，否则是引擎名。
    /// 详细状态、速度留到展开后的 detail 里，避免胶囊被撑得过长。
    private var summaryContent: some View {
        ZStack(alignment: .leading) {
            if let notice = state.islandNotice {
                HStack(spacing: 8) {
                    noticeBadge(notice.kind, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.t(notice.title))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(notice.message)
                            .font(.system(size: 11))
                            .foregroundStyle(ink.opacity(0.6))
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
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(state.engineStageText)
                        .font(.system(size: 11))
                        .foregroundStyle(ink.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if state.islandUnread > 0 {
                        unreadBadge
                    }
                }
                .transition(summaryTransition)
            }
        }
        // 摘要始终按内容取宽。展开态外层有 400pt 的固定宽度，如果不锁住这里，
        // 摘要把多出来的空间也吃进去，收起后就会记成「最宽」。
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
        .animation(Motion.entrance, value: state.islandNotice?.id)
    }

    /// 灵动岛里的模型生命周期指示灯：加载中一律黄色，成功绿色，失败红色，
    /// 停止灰色。和菜单栏面板、概览页共用同一套语义色。
    private var lifecycleTint: Color {
        if state.serverState == .failed { return Console.danger }
        if state.canChat { return Console.ok }
        if state.isModelBusy { return Console.warn }
        return ink.opacity(0.32)
    }

    @ViewBuilder
    private var engineDot: some View {
        if state.isModelBusy {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.55)
                .frame(width: 10, height: 10)
                .tint(Console.warn)
        } else {
            Circle()
                .fill(lifecycleTint)
                .frame(width: 6, height: 6)
                .shadow(color: state.canChat ? Console.ok.opacity(0.8) : .clear, radius: 3)
                .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if expanded {
            Button {
                withAnimation(Motion.island) { expanded = false }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(ink.opacity(0.55))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plainHit)
            .help("收起")
        } else if state.islandNotice != nil {
            Button {
                withAnimation(Motion.island) { expanded = true }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(ink.opacity(0.45))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plainHit)
            .help("查看通知")
        } else {
            Button {
                state.toggleService()
            } label: {
                Image(systemName: state.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(state.isRunning ? Console.danger : ink.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(ink.opacity(0.10)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plainHit)
            .disabled(state.isSwitchingModel || state.runtimeMissing != nil)
            .help(L10n.t(state.isRunning ? "停止引擎" : "启动引擎"))
        }
    }

    private var unreadBadge: some View {
        Text(verbatim: "\(min(state.islandUnread, 99))")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Console.accent))
    }

    private func noticeBadge(_ kind: IslandNotice.Kind, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(kind.tint.opacity(0.18))
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
            separator

            if hasNotices {
                noticeList
                    .transition(summaryTransition)
            } else {
                engineDetail
                    .transition(summaryTransition)
            }

            separator
            footer
        }
        .animation(Motion.entrance, value: hasNotices)
    }

    private var detailHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: hasNotices ? "bell.badge.fill" : "cpu.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ink.opacity(0.55))
            Text(L10n.t(hasNotices ? "通知" : "引擎详情"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink.opacity(0.85))
                .contentTransition(.opacity)

            if hasNotices {
                Text(verbatim: "\(state.islandNotices.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.55))
                    .contentTransition(.numericText())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(ink.opacity(0.10)))
            }

            Spacer(minLength: 8)

            if hasNotices {
                Button {
                    state.clearIslandNotices()
                } label: {
                    Text("清空")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(ink.opacity(0.5))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(ink.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plainHit)
                .help("清空通知历史")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    private var noticeList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(state.islandNotices) { notice in
                    VStack(spacing: 0) {
                        noticeRow(notice)
                        if notice.id != state.islandNotices.last?.id {
                            Rectangle()
                                .fill(ink.opacity(0.06))
                                .frame(height: 1)
                                .padding(.leading, 42)
                        }
                    }
                    .transition(noticeRowTransition)
                }
            }
            .animation(Motion.entrance, value: state.islandNotices)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: 250)
    }

    private func noticeRow(_ notice: IslandNotice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(notice.kind.tint)
                .frame(width: 2.5)

            noticeBadge(notice.kind, size: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t(notice.title))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.92))
                    .lineLimit(1)
                Text(notice.message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(ink.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Text(Format.relative(notice.date))
                    .font(.system(size: 10))
                    .foregroundStyle(ink.opacity(0.38))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var engineDetail: some View {
        VStack(spacing: 9) {
            detailRow("模型", state.selectedModel.isEmpty ? "—" : state.shortModelName(state.selectedModel))
            detailRow("接口", "127.0.0.1:\(state.port)")
            detailRow("版本", state.engineVersion)
            detailRow("实时速度", state.canChat ? "\(Format.compact(rate)) tok/s" : "—")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L10n.t(label))
                .font(.system(size: 11))
                .foregroundStyle(ink.opacity(0.42))
                .frame(width: 56, alignment: .leading)
            Text(L10n.t(value))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ink.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            engineDot
            Text(state.activeEngine.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink.opacity(0.7))
            Text(state.engineStageText)
                .font(.system(size: 10.5))
                .foregroundStyle(ink.opacity(0.38))
                .lineLimit(1)

            Spacer(minLength: 8)

            footerButton("日志") {
                state.section = .logs
                withAnimation(Motion.island) { expanded = false }
            }
            footerButton(state.isRunning ? "停止" : "启动",
                         tint: state.isRunning ? Console.danger : Console.ok) {
                state.toggleService()
            }
            .disabled(state.isSwitchingModel || state.runtimeMissing != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func footerButton(_ title: String,
                              tint: Color? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L10n.t(title))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? ink.opacity(0.72))
                .padding(.horizontal, 10)
                .frame(height: 25)
                .background(Capsule().fill(ink.opacity(0.10)))
                .overlay(Capsule().strokeBorder(ink.opacity(0.08), lineWidth: 0.6))
                .contentShape(Capsule())
        }
        .buttonStyle(.plainHit)
    }

    private var separator: some View {
        Rectangle()
            .fill(ink.opacity(0.08))
            .frame(height: 1)
    }

    /// 收起态内容切换：透明度 + 轻微缩放 + 一点模糊，接近灵动岛换内容的质感。
    private var summaryTransition: AnyTransition {
        AnyTransition.modifier(
            active: IslandMotion(active: true, scale: 0.92, blur: 5, anchor: .leading),
            identity: IslandMotion(active: false, scale: 1, blur: 0, anchor: .leading)
        )
    }

    /// 展开面板从胶囊上缘生长出来，而不是整块闪一下。
    private var detailTransition: AnyTransition {
        AnyTransition.modifier(
            active: IslandMotion(active: true, scale: 0.94, blur: 6, anchor: .top),
            identity: IslandMotion(active: false, scale: 1, blur: 0, anchor: .top)
        )
    }

    /// 新通知从列表顶部淡入，让历史的增长也有方向感。
    private var noticeRowTransition: AnyTransition {
        AnyTransition.modifier(
            active: IslandMotion(active: true, scale: 0.97, blur: 4, anchor: .top),
            identity: IslandMotion(active: false, scale: 1, blur: 0, anchor: .top)
        )
    }
}

/// 收起态内容的实测宽度。只测量摘要本身，不受展开态固定宽度影响。
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
        case .info: return Console.info
        case .success: return Console.ok
        case .warning: return Console.warn
        case .error: return Console.danger
        }
    }
}
