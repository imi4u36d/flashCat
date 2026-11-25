// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Combine
import FlashCatCore
import FlashCatKit
import SwiftUI

// MARK: - Navigation panel

/// Liquid Glass 侧边栏：标题栏避让、工作区 / 控制台导航、最近对话与底部内联运行时状态栏。
struct ConsoleNavigationPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore
    var onCollapse: () -> Void

    @Namespace private var selection
    /// 会话列表的搜索词；Esc 清空。
    @State private var query = ""
    /// 日期分组用的「今天」。跨过午夜后重新分组，不需要重启应用。
    @State private var today = Date()
    /// 搜索 + 分组的结果。流式输出时 `ChatStore` 每秒会发布很多次，
    /// 但线程列表没变；把结果存成状态，避免每帧都扫一遍历史正文。
    @State private var sections: [ChatThreadSections.Section]?
    /// 控制台分组是否折叠。窄栏里始终展开——那里只有图标，没有折叠的意义。
    @State private var consoleCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var style: SidebarStyle { state.sidebarStyle }
    private var compact: Bool { style == .compact }
    private var sidebarWidth: CGFloat {
        compact ? DS.Layout.sidebarCompactWidth : DS.Layout.sidebarWidth
    }

    var body: some View {
        Group {
            switch style {
            case .edge:
                panelBody
                    .frame(width: DS.Layout.sidebarWidth)
                    .background(DS.sidebarFill)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(DS.sidebarBorder)
                            .frame(width: 1)
                    }
            case .floating, .compact:
                card
            }
        }
        .animation(reduceMotion ? nil : DS.Motion.smooth, value: style)
    }

    /// 悬浮 / 窄栏共用的玻璃卡片外壳。宽度、圆角、顶部留白和阴影都跟 `style` 走；
    /// 窄栏下移到红绿灯下方起始，顶部区域留给红绿灯与拖窗手柄。
    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
        return
            panelBody
            .frame(width: sidebarWidth)
            .clipShape(shape)
            .background {
                shape
                    .fill(DS.sidebarCardFill)
                    .shadow(color: DS.glassShadow.opacity(0.9), radius: 18, x: 0, y: 8)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [DS.glassSpecular, DS.sidebarCardBorder],
                        startPoint: .top,
                        endPoint: .bottom),
                    lineWidth: 1)
            }
            .padding(.leading, DS.Layout.sidebarInset)
            .padding(.top, compact ? DS.Layout.sidebarCompactTopClearance : DS.Layout.sidebarInset)
            .padding(.bottom, DS.Layout.sidebarInset)
            .overlay(alignment: .top) {
                if compact {
                    WindowDragArea()
                        .frame(height: DS.Layout.sidebarCompactTopClearance)
                }
            }
    }

    private var panelBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    creativeSection

                    if compact {
                        DSDivider()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 8)
                    }

                    consoleSection

                    if !compact {
                        DSDivider()
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                        recentsSection
                    }
                }
                .padding(.horizontal, compact ? 8 : 10)
                .padding(.top, compact ? 8 : 2)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)

            dock
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : DS.Motion.smooth, value: state.section)
    }

    // MARK: Header

    /// 顶部一行：真实红绿灯留在窗口坐标里。
    /// 宽栏与红绿灯同区并向右避让；窄栏整体下移到红绿灯下方，卡片顶部居中放展开按钮。
    @ViewBuilder private var header: some View {
        if compact {
            VStack(spacing: 0) {
                collapseButton(size: 30)
                    .padding(.top, 9)
                    .padding(.bottom, 6)
                DSDivider()
                    .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity)
        } else {
            ZStack(alignment: .topLeading) {
                WindowDragArea()

                HStack(spacing: 6) {
                    // 系统红绿灯画在窗口坐标里，这里让出它们的位置。
                    Color.clear.frame(width: 72)
                    Spacer(minLength: 0)
                    collapseButton(size: 24)
                }
                .padding(.horizontal, 10)
                // 红绿灯中线固定在窗口顶下 26pt。悬浮卡的顶边在 10pt，
                // 卡内 4pt 让按钮中心落在 26pt；贴边卡下移 14pt 对齐。
                .padding(.top, style == .edge ? 14 : 4)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(height: style == .edge ? 48 : DS.Layout.sidebarHeaderHeight)
        }
    }

    private func collapseButton(size: CGFloat) -> some View {
        DSIconButton(
            systemName: "sidebar.left",
            help: compact ? "展开侧栏" : "折叠为窄栏",
            size: size
        ) {
            onCollapse()
        }
    }

    // MARK: Navigation sections

    private var creativeSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Page.primaryPages) { page in
                SidebarNavRow(
                    page: page,
                    active: state.section == page,
                    accessory: .none,
                    compact: compact,
                    namespace: selection
                ) {
                    state.section = page
                }
            }
        }
    }

    private var consoleSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !compact {
                consoleGroupHeader
            }

            if compact || !consoleCollapsed {
                ForEach(Page.consolePages) { page in
                    SidebarNavRow(
                        page: page,
                        active: state.section == page,
                        accessory: accessory(for: page),
                        compact: compact,
                        namespace: selection
                    ) {
                        state.section = page
                    }
                }
            }
        }
        .padding(.top, compact ? 0 : 12)
    }

    private var consoleGroupHeader: some View {
        Button {
            if reduceMotion {
                consoleCollapsed.toggle()
            } else {
                withAnimation(DS.Motion.smooth) { consoleCollapsed.toggle() }
            }
        } label: {
            HStack(spacing: 4) {
                Text(L10n.t("控制台"))
                    .font(DS.Font.prose(11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(DS.text3)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DS.text4)
                    .rotationEffect(.degrees(consoleCollapsed ? -90 : 0))
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .help(consoleCollapsed ? L10n.t("展开控制台") : L10n.t("折叠控制台"))
        .accessibilityLabel(Text(L10n.t("控制台")))
        .accessibilityHint(
            Text(consoleCollapsed ? L10n.t("展开控制台") : L10n.t("折叠控制台")))
    }

    private func accessory(for page: Page) -> SidebarNavAccessory {
        switch page {
        case .models:
            return .count(modelCount)
        case .engines:
            return .engine(
                running: state.isRunning,
                name: state.activeEngine.displayName)
        case .logs:
            return .liveLog(running: state.isRunning)
        default:
            return .none
        }
    }

    private var modelCount: Int {
        Set(
            EngineCatalog.allIDs
                .flatMap { state.libraryEntries(for: $0) }
                .filter(\.installed)
                .map { ModelSharing.canonical($0.model.id) }
        ).count
    }

    // MARK: Recents

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(L10n.t("最近对话"))
                    .font(DS.Font.prose(11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(DS.text3)

                Text(verbatim: "\(chat.threads.count)")
                    .font(DS.Font.mono(9.5, weight: .medium))
                    .foregroundStyle(DS.text3)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18)
                    .frame(height: 16)
                    .background(Capsule().fill(DS.pillFill))
                    .overlay(Capsule().strokeBorder(DS.line, lineWidth: 1))
                    .accessibilityLabel(
                        Text(L10n.format("共 %d 段对话", chat.threads.count)))

                Spacer(minLength: 4)

                ChatNewConversationButton {
                    state.newConversation()
                    state.section = .chat
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 6)

            DSSearchField(
                query: $query,
                placeholder: "搜索对话",
                shortcut: "⌘F",
                focusTrigger: state.chatSearchFocusTick
            )
            .padding(.bottom, 6)

            recents
        }
    }

    private var recents: some View {
        let shown = shownSections
        return Group {
            if chat.threads.isEmpty {
                hint(title: "暂无历史对话", detail: nil)
            } else if shown.isEmpty {
                hint(title: "没有匹配的对话", detail: "换个关键词，或清除搜索。")
            } else {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(shown) { section in
                        chatSectionHeader(section, first: section.id == shown.first?.id)

                        ForEach(section.threads) { thread in
                            ChatThreadRow(
                                thread: thread,
                                active: state.currentThreadID == thread.id && state.section == .chat,
                                generating: state.generatingThreadID == thread.id
                            ) {
                                state.openThread(thread)
                                state.section = .chat
                            } onPin: {
                                state.setThreadPinned(thread, !thread.pinned)
                            } onRename: {
                                state.requestThreadRename(thread)
                            } onDelete: {
                                state.requestThreadDelete(thread)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }
        }
        .onAppear {
            today = .now
            refreshSections()
        }
        // 只在会话列表本身变化时重算；流式 token 更新 `messages` 不会触发。
        // `@Published` 在 willSet 里发值，所以直接用闭包收到的新数组，
        // 不要回读 `chat.threads`——那一刻它还是旧值。
        .onReceive(chat.$threads) { threads in refreshSections(threads) }
        .onChange(of: query) { _, _ in refreshSections() }
        .onChange(of: today) { _, _ in refreshSections() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            today = .now
        }
    }

    private func chatSectionHeader(
        _ section: ChatThreadSections.Section,
        first: Bool
    ) -> some View {
        HStack(spacing: 3) {
            if section.group == .pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DS.accent)
            }
            Text(L10n.t(ChatThreadSections.title(section.group)))
                .font(DS.Font.prose(10.5, weight: .medium))
                .foregroundStyle(DS.text3)
        }
        .padding(.horizontal, 8)
        .padding(.top, first ? 4 : 10)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }

    private func hint(title: String, detail: String?) -> some View {
        VStack(spacing: 3) {
            Text(L10n.t(title))
                .font(DS.Font.prose(12.5, weight: detail == nil ? .regular : .medium))
                .foregroundStyle(detail == nil ? DS.text3 : DS.text2)
            if let detail {
                Text(L10n.t(detail))
                    .font(DS.Font.prose(11))
                    .foregroundStyle(DS.text3)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Dock

    private var dock: some View {
        Group {
            if compact {
                SidebarCompactFooter(state: state)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)
            } else {
                SidebarRuntimeFooter(state: state)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .padding(.top, 4)
    }

    // MARK: Thread sections

    private var shownSections: [ChatThreadSections.Section] {
        if let sections { return sections }
        let matched = ChatThreadSections.matching(chat.threads, query: query)
        return ChatThreadSections.sections(matched, now: today)
    }

    private func refreshSections(_ threads: [ChatThread]? = nil) {
        let matched = ChatThreadSections.matching(threads ?? chat.threads, query: query)
        sections = ChatThreadSections.sections(matched, now: today)
    }
}

// MARK: - Nav row

private enum SidebarNavAccessory {
    case none
    case count(Int)
    case engine(running: Bool, name: String)
    case liveLog(running: Bool)
}

private struct SidebarNavRow: View {
    let page: Page
    let active: Bool
    let accessory: SidebarNavAccessory
    let compact: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rowShape: RoundedRectangle { DS.rect(10) }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 9) {
                    Image(systemName: page.symbol)
                        .font(.system(size: 13, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? DS.accent : (hovering ? DS.text : DS.text3))
                        .frame(width: 18)

                    if !compact {
                        Text(L10n.t(page.rawValue))
                            .font(DS.Font.prose(13, weight: active ? .medium : .regular))
                            .foregroundStyle(active ? DS.text : (hovering ? DS.text : DS.text2))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        accessoryView
                    }
                }
                .padding(.horizontal, compact ? 0 : 9)
                .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                .frame(height: compact ? 36 : DS.Layout.rowHeight)

                if compact {
                    compactDot
                        .padding(.top, 6)
                        .padding(.trailing, 7)
                }
            }
            .background {
                if active {
                    SidebarLens(radius: 10)
                        .matchedGeometryEffect(id: "nav.selection", in: namespace)
                } else if hovering {
                    rowShape.fill(DS.hover)
                }
            }
            .contentShape(rowShape)
        }
        .buttonStyle(.plainHit)
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(L10n.t(page.rawValue))
        .onHover { value in
            guard !reduceMotion else {
                hovering = value
                return
            }
            withAnimation(DS.Motion.snappy) { hovering = value }
        }
    }

    @ViewBuilder private var accessoryView: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .count(let count):
            Text(verbatim: "\(count)")
                .font(DS.Font.mono(9.5, weight: .medium))
                .foregroundStyle(DS.text3)
                .padding(.horizontal, 5)
                .frame(minWidth: 18)
                .frame(height: 16)
                .background(Capsule().fill(DS.pillFill))
                .overlay(Capsule().strokeBorder(DS.line, lineWidth: 1))
        case .engine(let running, let name):
            HStack(spacing: 5) {
                DSStatusDot(
                    color: running ? DS.ok : DS.text4,
                    live: running,
                    size: 5)
                Text(verbatim: name)
                    .font(DS.Font.mono(9.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(running ? DS.ok : DS.text3)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(running ? DS.successFill : DS.pillFill))
            .overlay(
                Capsule().strokeBorder(
                    running ? DS.successStroke : DS.line, lineWidth: 1))
        case .liveLog(let running):
            Circle()
                .fill(running ? DS.info : DS.text4.opacity(0.6))
                .frame(width: 5, height: 5)
                .shadow(
                    color: running ? DS.info.opacity(0.8) : .clear,
                    radius: 3
                )
                .padding(.trailing, 2)
        }
    }

    @ViewBuilder private var compactDot: some View {
        switch accessory {
        case .engine(let running, _):
            DSStatusDot(
                color: running ? DS.ok : DS.text4,
                live: running,
                size: 6)
        case .liveLog(let running):
            Circle()
                .fill(running ? DS.info : DS.text4.opacity(0.6))
                .frame(width: 5, height: 5)
        case .none, .count:
            EmptyView()
        }
    }
}

/// 选中行的液态玻璃透镜：选中底 + 顶部高光描边 + 极轻投影。
struct SidebarLens: View {
    var radius: CGFloat = DS.Radius.sm

    var body: some View {
        let shape = DS.rect(radius)
        shape
            .fill(DS.pillActive)
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [
                            DS.accent.opacity(0.10),
                            DS.accent.opacity(0.02),
                            .clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
            )
            .overlay(shape.strokeBorder(DS.pillBorder, lineWidth: 1))
            .shadow(color: DS.glassShadow.opacity(0.7), radius: 6, x: 0, y: 2)
    }
}

// MARK: - Runtime footer (inline)

/// 侧栏底部运行时状态的共享读数：状态文案、当前模型、实时速度与统一内存水位。
@MainActor
private struct SidebarRuntimeMetrics {
    let state: AppState

    var tint: Color { sidebarStatusTint(state) }
    var live: Bool { state.isRunning && !state.isModelBusy }

    var statusText: String {
        if state.isSwitchingModel { return L10n.t("切换中") }
        if state.isModelBusy { return L10n.t("加载中") }
        return L10n.t(state.serverState.rawValue)
    }

    var modelName: String {
        if let info = state.selectedModelInfo { return info.shortName }
        let name = state.shortModelName(state.selectedModel)
        return name.isEmpty ? L10n.t("未选择模型") : name
    }

    var speedReading: MetricReading { state.menuBarDecodeReading }

    var hasSpeedValue: Bool {
        state.isRunning && (speedReading.value ?? 0) > 0
    }

    var speedText: String {
        guard state.isRunning, let value = speedReading.value, value > 0 else {
            return "— tok/s"
        }
        return "\(Format.compact(value)) tok/s"
    }

    var speedBadge: String? {
        hasSpeedValue && speedReading.origin == .gatewayMean ? "AVG" : nil
    }

    var memoryUsed: Int { state.stats?.memoryBytes ?? 0 }
    var memoryTotal: Int {
        state.stats?.physicalMemoryBytes ?? Int(ProcessInfo.processInfo.physicalMemory)
    }

    var memoryFraction: Double {
        guard memoryTotal > 0 else { return 0 }
        return min(1, max(0, Double(memoryUsed) / Double(memoryTotal)))
    }

    var memoryText: String {
        let total = Int((Double(memoryTotal) / 1_073_741_824).rounded())
        guard let used = state.stats?.memoryBytes else { return "— / \(total) GB" }
        return String(format: "%.1f / %d GB", Double(used) / 1_073_741_824, total)
    }
}

/// 侧栏底部内联运行时状态栏：引擎与模型摘要（点击直达概览）+ 直接启停按钮 + 速度与内存水位条。
private struct SidebarRuntimeFooter: View {
    @ObservedObject var state: AppState

    @State private var hoveringInfo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var metrics: SidebarRuntimeMetrics { SidebarRuntimeMetrics(state: state) }
    private var dockShape: RoundedRectangle { DS.rect(12) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    state.section = .overview
                } label: {
                    HStack(spacing: 8) {
                        EngineMark(
                            id: state.activeEngine,
                            size: 24,
                            ring: engineAccent(state.activeEngine))

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(verbatim: state.activeEngine.displayName)
                                    .font(DS.Font.prose(12, weight: .semibold))
                                    .foregroundStyle(DS.text)
                                    .lineLimit(1)
                                DSStatusDot(color: metrics.tint, live: metrics.live, size: 5.5)
                                Text(verbatim: metrics.statusText)
                                    .font(DS.Font.prose(10, weight: .medium))
                                    .foregroundStyle(metrics.tint)
                                    .lineLimit(1)
                            }
                            Text(verbatim: metrics.modelName)
                                .font(DS.Font.prose(10.5))
                                .foregroundStyle(hoveringInfo ? DS.text2 : DS.text3)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer(minLength: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plainHit)
                .onHover { value in
                    if reduceMotion {
                        hoveringInfo = value
                    } else {
                        withAnimation(DS.Motion.snappy) { hoveringInfo = value }
                    }
                }
                .help(L10n.t("查看概览"))
                .accessibilityLabel(L10n.t("查看概览"))

                SidebarEngineToggleButton(state: state, width: 26, height: 26)
            }

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    HStack(spacing: 3) {
                        Text(verbatim: metrics.speedText)
                            .font(DS.Font.mono(10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(metrics.hasSpeedValue ? DS.text2 : DS.text3)
                            .contentTransition(.numericText())
                        if let speedBadge = metrics.speedBadge {
                            Text(verbatim: speedBadge)
                                .font(DS.Font.mono(8, weight: .semibold))
                                .tracking(0.3)
                                .foregroundStyle(DS.text4)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(verbatim: metrics.memoryText)
                        .font(DS.Font.mono(10))
                        .monospacedDigit()
                        .foregroundStyle(DS.text3)
                }
                SidebarMemoryBar(fraction: metrics.memoryFraction)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            dockShape
                .fill(DS.sidebarDockFill)
                .shadow(color: DS.glassShadow.opacity(0.45), radius: 6, x: 0, y: 2)
        }
        .overlay {
            dockShape.strokeBorder(
                LinearGradient(
                    colors: [DS.glassSpecular.opacity(0.75), DS.glassBorder],
                    startPoint: .top,
                    endPoint: .bottom),
                lineWidth: 1)
        }
    }
}

/// 窄栏底栏：引擎徽标与状态点（点击进概览）+ 独立内联启停按钮，无弹窗。
private struct SidebarCompactFooter: View {
    @ObservedObject var state: AppState

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var metrics: SidebarRuntimeMetrics { SidebarRuntimeMetrics(state: state) }

    private var compactHelpText: String {
        "\(state.activeEngine.displayName) · \(metrics.statusText)\n\(metrics.modelName) · \(metrics.speedText)"
    }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                state.section = .overview
            } label: {
                ZStack(alignment: .topTrailing) {
                    DS.rect(10)
                        .fill(hovering ? DS.raised : DS.sidebarDockFill)
                        .overlay {
                            DS.rect(10).strokeBorder(
                                hovering ? DS.line2 : DS.glassBorder,
                                lineWidth: 1)
                        }

                    EngineMark(
                        id: state.activeEngine,
                        size: 20,
                        ring: engineAccent(state.activeEngine)
                    )
                    .frame(width: 38, height: 34)

                    DSStatusDot(
                        color: metrics.tint,
                        live: metrics.live,
                        size: 5.5
                    )
                    .padding(5)
                }
                .frame(width: 38, height: 34)
                .contentShape(DS.rect(10))
            }
            .buttonStyle(.plainHit)
            .onHover { value in
                if reduceMotion {
                    hovering = value
                } else {
                    withAnimation(DS.Motion.snappy) { hovering = value }
                }
            }
            .help(compactHelpText)
            .accessibilityLabel(L10n.t("查看概览"))

            SidebarEngineToggleButton(state: state, width: 38, height: 26)
        }
    }
}

/// 内联引擎启停键：宽栏 26×26 方钮与窄栏 38×26 胶囊共用同一套状态配色与禁用逻辑。
private struct SidebarEngineToggleButton: View {
    @ObservedObject var state: AppState
    var width: CGFloat
    var height: CGFloat

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var disabled: Bool {
        state.isModelBusy || (!state.isRunning && state.selectedModel.isEmpty)
    }

    private var shape: RoundedRectangle { DS.rect(8) }

    private var helpText: String {
        L10n.t(state.isRunning ? "停止引擎" : "启动引擎")
    }

    private var fillColor: Color {
        if state.isModelBusy { return DS.pillFill }
        if state.isRunning {
            return hovering && !disabled ? DS.err.opacity(0.18) : DS.dangerFill
        }
        return hovering && !disabled ? DS.ok.opacity(0.18) : DS.successFill
    }

    private var borderColor: Color {
        if state.isModelBusy { return DS.line }
        return state.isRunning ? DS.dangerStroke : DS.successStroke
    }

    var body: some View {
        Button {
            state.toggleService()
        } label: {
            Group {
                if state.isModelBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: state.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(state.isRunning ? DS.dangerText : DS.ok)
                }
            }
            .frame(width: width, height: height)
            .background(shape.fill(fillColor))
            .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(DSPressStyle(scale: 0.95))
        .disabled(disabled)
        .opacity(disabled && !state.isModelBusy ? 0.42 : 1)
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
        .help(helpText)
        .accessibilityLabel(helpText)
    }
}

/// 内存水位条：indigo → violet → cyan 的细渐变，与设计稿一致。
private struct SidebarMemoryBar: View {
    var fraction: Double

    private var clamped: Double { min(1, max(0, fraction)) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.line2)
                if clamped > 0 {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    DS.accent,
                                    Color.adaptive(dark: 0xA78BFA, light: 0x8B5CF6),
                                    Color.adaptive(dark: 0x67E8F9, light: 0x22D3EE),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing)
                        )
                        .frame(width: max(3, proxy.size.width * clamped))
                }
            }
        }
        .frame(height: 4)
        .animation(DS.Motion.smooth, value: clamped)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int((clamped * 100).rounded()))%")
    }
}

/// 引擎状态色。与页面状态条同口径，只是停止态用更淡的灰。
@MainActor
private func sidebarStatusTint(_ state: AppState) -> Color {
    if state.isModelBusy { return DS.warn }
    switch state.serverState {
    case .ready: return DS.ok
    case .starting, .stopping: return DS.warn
    case .failed: return DS.err
    case .stopped: return DS.text4
    }
}
