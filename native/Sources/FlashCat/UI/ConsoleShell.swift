// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatKit
import SwiftUI

/// 控制台根视图：固定左侧导航栏 + 44pt 顶栏 + 页面区 + 标题栏中央状态胶囊。
struct ConsoleView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var theme = AppState.shared.theme

    @State private var showCommand = false
    @State private var showDownloads = false
    @State private var showHub = false
    @State private var showFeedback = false
    @State private var islandExpanded = false

    private var sidebarReservedWidth: CGFloat {
        state.showsSidebar ? DS.Layout.sidebarWidth + 1 : 0
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ConsoleBackdrop(accent: state.section.keyColor)

            HStack(spacing: 0) {
                if state.showsSidebar {
                    HStack(spacing: 0) {
                        ConsoleNavigationPanel(state: state, chat: state.chat)
                            .frame(width: DS.Layout.sidebarWidth)
                        DSDivider(vertical: true)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                VStack(spacing: 0) {
                    ConsoleTitlebar(
                        state: state,
                        chat: state.chat,
                        openCommand: { showCommand = true },
                        openDownloads: { showDownloads = true },
                        openFeedback: { showFeedback = true }
                    )
                    .frame(height: DS.Layout.titlebarHeight)

                    DSDivider()

                    ZStack {
                        pageContent
                            .id(state.section)
                            .transition(.dsPage)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .animation(DS.Motion.smooth, value: state.section)
                    .clipped()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .animation(DS.Motion.smooth, value: state.showsSidebar)
        }
        .background { DesktopBackdrop().ignoresSafeArea() }
        .tint(DS.accent)
        .preferredColorScheme(preferredScheme)
        .overlay(alignment: .top) {
            DynamicIslandLayer(
                state: state,
                expanded: $islandExpanded,
                leadingOffset: sidebarReservedWidth)
        }
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

    private var preferredScheme: ColorScheme? {
        switch theme.mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
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

// MARK: - Docked Sidebar

/// 固定在左侧的平面导航栏：`DS.bg` 底 + 1px 右边线，承载工作区、控制台与最近对话。
struct ConsoleNavigationPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore
    @ObservedObject private var background = BackgroundSettings.shared

    @Namespace private var selection
    @State private var hoveringNewChat = false

    private static let primaryPages: [Page] = [.chat, .lab]
    private static let consolePages: [Page] = [.overview, .models, .engines, .logs]

    private var sidebarFill: Color {
        let transparent = background.image != nil || background.desktopReveal > 0
        return DS.bg.opacity(transparent ? 0.88 : 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部 44pt 留给系统红绿灯，背景支持拖窗。
            Color.clear
                .frame(height: DS.Layout.titlebarHeight)
                .background(WindowDragArea())

            newChatButton
                .padding(.horizontal, 10)
                .padding(.bottom, DS.Space.sm)

            workspace
                .padding(.horizontal, 10)

            DSSectionLabel(text: "最近对话")
                .padding(.horizontal, 18)
                .padding(.top, DS.Space.lg)
                .padding(.bottom, DS.Space.xs)

            recents
                .padding(.horizontal, 10)

            sidebarFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(sidebarFill)
        .animation(DS.Motion.smooth, value: state.section)
    }

    private var newChatButton: some View {
        let shape = DS.rect(DS.Radius.md)
        return Button {
            state.newConversation()
            state.section = .chat
        } label: {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DS.text2)
                Text(L10n.t("新对话"))
                    .font(DS.Font.md.weight(.medium))
                    .foregroundStyle(DS.text)
                Spacer(minLength: 4)
                DSKbd(text: "⌘N")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(shape.fill(hoveringNewChat ? DS.raised : DS.surface))
            .overlay(shape.strokeBorder(hoveringNewChat ? DS.line3 : DS.line2, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(DSPressStyle(scale: 0.98))
        .onHover { value in
            withAnimation(DS.Motion.snappy) { hoveringNewChat = value }
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.primaryPages) { page in
                GlassNavRow(
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
                GlassNavRow(
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
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text4)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(chat.threads.prefix(14)) { thread in
                        GlassRecentRow(
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

            HStack(spacing: 6) {
                Spacer(minLength: 4)

                DSIconButton(
                    systemName: state.theme.mode.resolvedIsDark ? "sun.max" : "moon",
                    help: "切换外观"
                ) {
                    state.theme.set(state.theme.mode.resolvedIsDark ? .light : .dark)
                }

                DSIconButton(
                    systemName: Page.settings.symbol,
                    help: "设置",
                    tint: state.section == .settings ? DS.accent : nil
                ) {
                    state.section = .settings
                }
                .background(
                    DS.rect(DS.Radius.sm + 1)
                        .fill(state.section == .settings ? DS.raised : .clear)
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

private struct GlassNavRow: View {
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
                    .font(.system(size: 13, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? DS.text : (hovering ? DS.text : DS.text2))
                    .frame(width: 18)
                Text(L10n.t(page.rawValue))
                    .font(.system(size: 13, weight: active ? .medium : .regular))
                Spacer(minLength: 4)
                if badge > 0 {
                    Text(verbatim: "\(badge)")
                        .font(DS.Font.mono(10))
                        .foregroundStyle(active ? DS.text2 : DS.text3)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(DS.rect(4).fill(DS.surface))
                        .overlay(DS.rect(4).strokeBorder(DS.line, lineWidth: 1))
                }
            }
            .foregroundStyle(active ? DS.text : (hovering ? DS.text : DS.text2))
            .padding(.horizontal, 8)
            .frame(height: DS.Layout.rowHeight)
            .background {
                if active {
                    rowShape
                        .fill(DS.selected)
                        .overlay(rowShape.strokeBorder(DS.line, lineWidth: 1))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(DS.accent)
                                .frame(width: 2, height: 14)
                                .padding(.leading, 1)
                        }
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

private struct GlassRecentRow: View {
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
                        .font(DS.Font.sm)
                        .foregroundStyle(active ? DS.text : (hovering ? DS.text : DS.text2))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(date)
                        .font(DS.Font.mono(10))
                        .foregroundStyle(generating ? DS.accent : DS.text4)
                        .lineLimit(1)
                        .opacity(hovering ? 0 : 1)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background {
                    if active {
                        shape.fill(DS.selected)
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

// MARK: - Titlebar

struct ConsoleTitlebar: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore
    var openCommand: () -> Void = {}
    var openDownloads: () -> Void
    var openFeedback: () -> Void

    @State private var titlebarWidth: CGFloat = 1000
    @State private var hoveringCommand = false

    private var downloadCount: Int {
        state.downloadTasks.count + (state.downloadingModel == nil ? 0 : 1)
    }

    private var currentThreadTitle: String? {
        guard state.section == .chat else { return nil }
        return chat.threads.first(where: { $0.id == state.currentThreadID })?.title
    }

    private var isCompact: Bool { titlebarWidth < 740 }

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            DSIconButton(
                systemName: "sidebar.left",
                help: state.showsSidebar ? "隐藏边栏" : "显示边栏"
            ) {
                state.toggleSidebar()
            }
            .padding(.leading, state.showsSidebar ? 12 : 78)

            if !isCompact {
                breadcrumb
            }

            Spacer(minLength: DS.Space.sm)

            if isCompact {
                DSIconButton(systemName: "magnifyingglass", help: "命令面板", action: openCommand)
            } else {
                commandButton
            }

            downloadButton

            DSDivider(vertical: true)
                .frame(height: 14)

            DSIconButton(
                systemName: "bubble.left.and.bubble.right",
                help: "反馈与交流",
                action: openFeedback
            )
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragArea())
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            titlebarWidth = width
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            let hasThread = currentThreadTitle != nil
            Text(L10n.t(state.section.rawValue))
                .font(DS.Font.md.weight(hasThread ? .regular : .medium))
                .foregroundStyle(hasThread ? DS.text2 : DS.text)
                .lineLimit(1)
            if let title = currentThreadTitle {
                Text("/")
                    .font(DS.Font.sm)
                    .foregroundStyle(DS.text4)
                Text(title)
                    .font(DS.Font.md.weight(.medium))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 160, alignment: .leading)
            }
        }
    }

    private var commandButton: some View {
        let shape = DS.rect(DS.Radius.md)
        return Button(action: openCommand) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.text3)
                Text(L10n.t("命令面板"))
                    .font(DS.Font.sm)
                    .foregroundStyle(DS.text3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                DSKbd(text: "⌘K")
            }
            .padding(.horizontal, 8)
            .frame(width: 156, height: DS.Layout.controlHeight)
            .background(shape.fill(hoveringCommand ? DS.raised : DS.surface))
            .overlay(shape.strokeBorder(hoveringCommand ? DS.line3 : DS.line2, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(DSPressStyle(scale: 0.98))
        .onHover { value in withAnimation(DS.Motion.snappy) { hoveringCommand = value } }
        .help(L10n.t("命令面板"))
    }

    private var downloadButton: some View {
        ZStack(alignment: .topTrailing) {
            DSIconButton(systemName: "arrow.down.circle", help: "下载中心", action: openDownloads)
            if downloadCount > 0 {
                DSBadge(count: downloadCount)
                    .offset(x: 3, y: -2)
                    .allowsHitTesting(false)
            }
        }
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
