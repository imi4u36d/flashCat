// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatKit
import SwiftUI

/// 控制台根视图：左侧 ZCode 风格实体导航边栏 + 1px 发丝分隔线 + 七个原生页面。
struct ConsoleView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var theme = AppState.shared.theme

    @State private var showCommand = false
    @State private var showDownloads = false
    @State private var showHub = false
    @State private var showFeedback = false
    @State private var islandExpanded = false
    @State private var sidebarToggleWidth: CGFloat = DS.Layout.controlHeight

    var body: some View {
        ZStack(alignment: .topLeading) {
            ConsoleBackdrop(accent: state.section.keyColor)

            HStack(spacing: 0) {
                if state.showsSidebar {
                    HStack(spacing: 0) {
                        ConsoleNavigationPanel(
                            state: state,
                            chat: state.chat,
                            openDownloads: { showDownloads = true },
                            openFeedback: { showFeedback = true }
                        )
                        .frame(width: DS.Layout.sidebarWidth)
                        DSDivider(vertical: true)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                ZStack {
                    pageContent
                        .id(state.section)
                        .transition(.dsPage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(DS.Motion.smooth, value: state.section)
                .clipped()
            }
            .animation(DS.Motion.smooth, value: state.showsSidebar)
        }
        .background { DesktopBackdrop().ignoresSafeArea() }
        // 换肤不在这里做。`.preferredColorScheme` 会让 SwiftUI 去改窗口外观，
        // 而深色窗口那条系统投影明显更重（见 ThemeController.apply(to:)）；
        // 皮肤改由窗口的 contentView 外观承担，SwiftUI 的 colorScheme 也跟着
        // 那一层解析，切换时和窗口一起重画，不必等激活事件。
        .overlay(alignment: .topLeading) {
            DSIconButton(
                systemName: "sidebar.left",
                help: state.showsSidebar ? "隐藏边栏" : "显示边栏",
                style: state.showsSidebar ? .ghost : .outlined
            ) {
                if islandExpanded && state.showsSidebar {
                    withAnimation(DS.Motion.bouncy) { islandExpanded = false }
                }
                state.toggleSidebar()
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                if width > 0 { sidebarToggleWidth = width }
            }
            .padding(.leading, sidebarToggleLeading)
            .padding(.top, 11)
        }
        .overlay(alignment: .bottomLeading) {
            if state.showsSidebar {
                DynamicIslandLayer(state: state, expanded: $islandExpanded, bottomOffset: 54)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.smooth, value: state.showsSidebar)
        .overlay {
            if isShowingOnboarding {
                LaunchPage(state: state)
                    .transition(.opacity.animation(Motion.pageCrossfade))
            }
        }
        .overlay {
            if showCommand {
                CommandPalette(
                    state: state,
                    openDownloads: { showDownloads = true },
                    openHub: {
                        showHub = true
                        state.section = .models
                    },
                    dismiss: { showCommand = false }
                )
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showDownloads) { DownloadCenterSheet(state: state) }
        .sheet(isPresented: $showHub) { HubSheet(state: state, engine: state.libraryEngine) }
        .sheet(isPresented: $showFeedback) { FeedbackSheet(state: state) }
        .onReceive(NotificationCenter.default.publisher(for: .flashCatOpenCommandPalette)) { _ in
            showCommand = true
        }
        .alert("切换模型？", isPresented: modelSwitchShown) {
            Button("取消", role: .cancel) { state.cancelModelSwitchRequest() }
            Button("停止并切换") { state.confirmModelSwitch() }
        } message: {
            Text(modelSwitchMessage)
        }
        .alert(
            "\(state.pendingEngineInstall?.displayName ?? "该引擎") 还没安装",
            isPresented: engineInstallShown,
            presenting: state.pendingEngineInstall
        ) { _ in
            Button("去安装") { state.confirmEngineInstall() }
            Button("取消", role: .cancel) { state.cancelEngineInstall() }
        } message: { engine in
            Text("这个模型由 \(engine.displayName) 引擎驱动，先安装 \(engine.displayName) 才能切换到它。")
        }
        .alert("切换引擎？", isPresented: libraryUseShown, presenting: state.pendingLibraryUse) { request in
            Button(L10n.t(request.needsDownload ? "切换并下载" : "切换并使用")) { state.confirmLibraryUse() }
            Button("取消", role: .cancel) { state.cancelLibraryUse() }
        } message: { request in
            Text(
                "\(request.model) 属于 \(request.engine.displayName)，切换会先停掉 \(state.activeEngine.displayName)，再以这个模型启动 \(request.engine.displayName)。"
            )
        }
        .alert("删除这段对话？", isPresented: threadDeleteShown, presenting: state.pendingThreadDelete) { _ in
            Button("删除", role: .destructive) { state.confirmThreadDelete() }
            Button("取消", role: .cancel) { state.cancelThreadDelete() }
        } message: { thread in
            Text("「\(thread.title)」里的 \(thread.messages.count) 条消息会一并删除，无法恢复。")
        }
    }

    private var isShowingOnboarding: Bool {
        state.isPresentingLaunchPage || state.showsRecommendationPage
    }

    /// 展开时右侧紧贴导航列内容右缘（`sidebarWidth - 10`），收起时退回红绿灯右侧安全位（`90pt`）。
    private var sidebarToggleLeading: CGFloat {
        state.showsSidebar
            ? max(90, DS.Layout.sidebarWidth - 10 - sidebarToggleWidth)
            : 90
    }

    @ViewBuilder private var pageContent: some View {
        switch state.section {
        case .overview: OverviewPage(state: state, chat: state.chat)
        case .chat: ChatPage(state: state, chat: state.chat)
        case .models:
            ModelsPage(
                state: state,
                engine: state.libraryEngine,
                showingHub: $showHub,
                showingDownloads: $showDownloads)
        case .engines: EnginesPage(state: state, installs: state.installs)
        case .logs: LogsPage(state: state)
        case .settings: SettingsPage(state: state)
        case .lab: LabPage(state: state)
        }
    }

    private var modelSwitchShown: Binding<Bool> {
        Binding(
            get: { state.confirmingModelSwitch != nil },
            set: { if !$0 { state.cancelModelSwitchRequest() } })
    }

    private var threadDeleteShown: Binding<Bool> {
        Binding(
            get: { state.pendingThreadDelete != nil },
            set: { if !$0 { state.cancelThreadDelete() } })
    }

    private var modelSwitchMessage: String {
        let next = state.shortModelName(state.confirmingModelSwitch ?? "")
        let running = state.shortModelName(state.selectedModel)
        return L10n.format("将停止 %@ 并加载 %@，切换期间引擎暂时无法应答。", running, next)
    }

    private var engineInstallShown: Binding<Bool> {
        Binding(
            get: { state.pendingEngineInstall != nil },
            set: { if !$0 { state.cancelEngineInstall() } })
    }

    private var libraryUseShown: Binding<Bool> {
        Binding(
            get: { state.pendingLibraryUse != nil },
            set: { if !$0 { state.cancelLibraryUse() } })
    }
}

// MARK: - ZCode Sidebar

/// ZCode 风格实体侧边栏：纯色基底 + 1px 发丝分隔，承载工作区、控制台、最近对话、状态面板与底栏。
struct ConsoleNavigationPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore
    var openDownloads: () -> Void = {}
    var openFeedback: () -> Void = {}

    @ObservedObject private var background = BackgroundSettings.shared
    @Namespace private var selection
    @State private var hoveringNewChat = false
    @State private var hoveringSettings = false

    private static let primaryPages: [Page] = [.chat, .lab]
    private static let consolePages: [Page] = [.overview, .models, .engines, .logs]

    private var downloadCount: Int {
        state.downloadTasks.count + (state.downloadingModel == nil ? 0 : 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部 48pt 留给系统红绿灯与侧栏折叠按钮，背景支持拖窗。
            Color.clear
                .frame(height: DS.Layout.titlebarHeight)
                .background(WindowDragArea())

            workspace
                .padding(.horizontal, 10)
                .padding(.top, 2)

            HStack(alignment: .center, spacing: 6) {
                DSSectionLabel(text: "最近对话")
                newChatButton
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.top, DS.Space.lg)
            .padding(.bottom, DS.Space.xs)

            recents
                .padding(.horizontal, 10)

            // 为左下角状态卡预留收起高度，避免列表滚动到底时被遮挡。
            Color.clear
                .frame(height: 46)

            sidebarFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            DS.bg
                .opacity(background.image != nil || background.revealsDesktop ? 0.86 : 1.0)
                .ignoresSafeArea()
        }
        .animation(DS.Motion.smooth, value: state.section)
    }

    private var newChatButton: some View {
        let shape = DS.rect(DS.Radius.sm)
        return Button {
            state.newConversation()
            state.section = .chat
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.accent)
                Text(L10n.t("新对话"))
                    .font(DS.Font.prose(11.5, weight: .medium))
                    .foregroundStyle(hoveringNewChat ? DS.text : DS.text2)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(shape.fill(hoveringNewChat ? DS.surface : DS.hover))
            .overlay(shape.strokeBorder(hoveringNewChat ? DS.line2 : DS.line, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(DSPressStyle(scale: 0.97))
        .fixedSize()
        .help(L10n.t("新对话"))
        .onHover { value in
            withAnimation(DS.Motion.snappy) { hoveringNewChat = value }
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.primaryPages) { page in
                SidebarNavRow(
                    page: page,
                    active: state.section == page,
                    badge: 0,
                    namespace: selection
                ) {
                    state.section = page
                }
            }

            DSSectionLabel(text: "控制台")
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 3)

            ForEach(Self.consolePages) { page in
                SidebarNavRow(
                    page: page,
                    active: state.section == page,
                    badge: page == .models ? modelCount : 0,
                    namespace: selection
                ) {
                    state.section = page
                }
            }
        }
    }

    private var modelCount: Int {
        EngineCatalog.allIDs
            .flatMap { state.libraryEntries(for: $0) }
            .filter(\.installed)
            .count
    }

    private func recentDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return Format.clock(date) }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private var recents: some View {
        ScrollView(.vertical) {
            if chat.threads.isEmpty {
                Text(L10n.t("暂无历史对话"))
                    .font(DS.Font.prose(12.5))
                    .foregroundStyle(DS.text3)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(chat.threads.prefix(14)) { thread in
                        SidebarRecentRow(
                            title: thread.title,
                            date: state.generatingThreadID == thread.id
                                ? L10n.t("生成中")
                                : recentDate(thread.updatedAt),
                            active: state.currentThreadID == thread.id && state.section == .chat,
                            generating: state.generatingThreadID == thread.id
                        ) {
                            state.openThread(thread)
                            state.section = .chat
                        } onDelete: {
                            state.requestThreadDelete(thread)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, DS.Space.sm)
            }
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            DSDivider()
                .padding(.horizontal, 10)

            HStack(spacing: 4) {
                settingsFooterButton

                Spacer(minLength: 4)

                if downloadCount > 0 {
                    Button(action: openDownloads) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 11, weight: .medium))
                            DSBadge(count: downloadCount)
                        }
                    }
                    .buttonStyle(.ds(.secondary, size: .small))
                    .help(L10n.t("下载中心"))
                    .accessibilityLabel(L10n.t("下载中心"))
                }

                DSIconButton(
                    systemName: "bubble.left.and.bubble.right",
                    help: "反馈与交流",
                    size: 26,
                    style: .ghost,
                    action: openFeedback
                )

                DSIconButton(
                    systemName: state.theme.isDark ? "sun.max" : "moon",
                    help: "切换外观",
                    size: 26,
                    style: .ghost
                ) {
                    state.theme.set(state.theme.isDark ? .light : .dark)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
        }
    }

    private var settingsFooterButton: some View {
        let active = state.section == .settings
        let shape = DS.rect(DS.Radius.sm)
        return Button {
            state.section = .settings
        } label: {
            HStack(spacing: 7) {
                Image(systemName: Page.settings.symbol)
                    .font(.system(size: 13.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? DS.accent : (hoveringSettings ? DS.text : DS.text2))
                    .frame(width: 16)
                Text(L10n.t(Page.settings.rawValue))
                    .font(DS.Font.prose(13, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? DS.text : (hoveringSettings ? DS.text : DS.text2))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background {
                if active {
                    shape
                        .fill(DS.selected)
                        .overlay(shape.strokeBorder(DS.line, lineWidth: 1))
                        .matchedGeometryEffect(id: "nav.selection", in: selection)
                } else if hoveringSettings {
                    shape.fill(DS.hover)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plainHit)
        .fixedSize()
        .help(L10n.t(Page.settings.rawValue))
        .onHover { value in
            withAnimation(DS.Motion.snappy) { hoveringSettings = value }
        }
    }
}

private struct SidebarNavRow: View {
    let page: Page
    let active: Bool
    let badge: Int
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rowShape: RoundedRectangle { DS.rect(DS.Radius.sm) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? DS.accent : (hovering ? DS.text : DS.text2))
                    .frame(width: 18)
                Text(L10n.t(page.rawValue))
                    .font(DS.Font.prose(13, weight: active ? .medium : .regular))
                Spacer(minLength: 4)
                if badge > 0 {
                    Text(verbatim: "\(badge)")
                        .font(DS.Font.proseNumber(11))
                        .foregroundStyle(active ? DS.text : DS.text3)
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(DS.rect(DS.Radius.sm).fill(DS.hover))
                }
            }
            .foregroundStyle(active ? DS.text : (hovering ? DS.text : DS.text2))
            .padding(.horizontal, 9)
            .frame(height: DS.Layout.rowHeight)
            .background {
                if active {
                    rowShape
                        .fill(DS.selected)
                        .overlay(rowShape.strokeBorder(DS.line, lineWidth: 1))
                        .matchedGeometryEffect(id: "nav.selection", in: namespace)
                } else if hovering {
                    rowShape.fill(DS.hover)
                }
            }
            .contentShape(rowShape)
        }
        .buttonStyle(.plainHit)
        .help(L10n.t(page.rawValue))
        .onHover { value in
            guard !reduceMotion else {
                hovering = value
                return
            }
            withAnimation(DS.Motion.snappy) { hovering = value }
        }
    }
}

private struct SidebarRecentRow: View {
    let title: String
    let date: String
    let active: Bool
    let generating: Bool
    let action: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var shape: RoundedRectangle { DS.rect(DS.Radius.sm) }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: action) {
                HStack(spacing: 7) {
                    if generating {
                        DSStatusDot(color: DS.accent, live: true, size: 5)
                    }
                    Text(title)
                        .font(DS.Font.prose(12.5, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? DS.text : (hovering ? DS.text : DS.text2))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(date)
                        .font(DS.Font.proseNumber(11))
                        .foregroundStyle(generating ? DS.accent : DS.text3)
                        .lineLimit(1)
                        .opacity(hovering ? 0 : 1)
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background {
                    if active {
                        shape
                            .fill(DS.selected)
                            .overlay(shape.strokeBorder(DS.line, lineWidth: 1))
                    } else if hovering {
                        shape.fill(DS.hover)
                    }
                }
                .contentShape(shape)
            }
            .buttonStyle(.plainHit)

            RowDeleteButton(action: onDelete)
                .padding(.trailing, 4)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .onHover { value in withAnimation(DS.Motion.snappy) { hovering = value } }
    }
}

// MARK: - Window chrome helpers

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
