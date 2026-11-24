// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Combine
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 控制台根视图：左侧 ZCode 风格实体导航边栏 + 1px 发丝分隔线 + 七个原生页面。
struct ConsoleView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var theme = AppState.shared.theme

    @State private var showCommand = false
    @State private var showDownloads = false
    @State private var showHub = false
    /// 重命名弹窗里的输入。线程本身挂在 `pendingThreadRename` 上，壳层只负责
    /// 把输入框和落点接起来。
    @State private var renameText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 壁纸铺满 AppKit 窗口；玻璃窗口以 10pt 留白浮在上面。
            GlassWallpaper(skin: theme.skin)

            HStack(spacing: 0) {
                if state.showsSidebar {
                    ConsoleNavigationPanel(state: state, chat: state.chat) {
                        state.toggleSidebar()
                    }
                    .frame(width: DS.Layout.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                ZStack {
                    pageContent
                        .id(state.section)
                        .transition(reduceMotion ? .opacity : .dsPage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(reduceMotion ? nil : DS.Motion.smooth, value: state.section)
                .clipped()
            }
            .background { GlassWindowBackground(skin: theme.skin) }
            .animation(reduceMotion ? nil : DS.Motion.smooth, value: state.showsSidebar)
        }
        // 换肤不在这里做。`.preferredColorScheme` 会让 SwiftUI 去改窗口外观，
        // 而深色窗口那条系统投影明显更重（见 ThemeController.apply(to:)）；
        // 皮肤改由窗口的 contentView 外观承担，SwiftUI 的 colorScheme 也跟着
        // 那一层解析，切换时和窗口一起重画，不必等激活事件。
        // 侧栏展开时折叠按钮活在侧栏头里；收起时退回红绿灯右侧的浮层位置。
        .overlay(alignment: .topLeading) {
            if !state.showsSidebar && !isShowingOnboarding {
                DSIconButton(
                    systemName: "sidebar.left",
                    help: "显示边栏",
                    style: .outlined
                ) {
                    state.toggleSidebar()
                }
                .padding(.leading, 90)
                .padding(.top, 11)
            }
        }
        .overlay {
            if isShowingOnboarding {
                LaunchPage(state: state, installs: state.installs)
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
        // 侧栏收起时窗口左下角常驻一枚紧凑状态；通知到达时原地换成 toast。
        // 侧栏展开时没有状态脊柱，通知同样浮在左下角，不再有第二个出口。
        .overlay(alignment: .bottomLeading) {
            if !isShowingOnboarding {
                if let notice = state.islandNotice {
                    FloatingNoticeToast(notice: notice) { state.dismissToast() }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if !state.showsSidebar {
                    CompactStatusPill(state: state)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                        .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : DS.Motion.smooth, value: state.islandNotice?.id)
        .sheet(isPresented: $showDownloads) { DownloadCenterSheet(state: state) }
        .sheet(isPresented: $showHub) { HubSheet(state: state, engine: state.libraryEngine) }
        .onReceive(NotificationCenter.default.publisher(for: .flashCatOpenCommandPalette)) { _ in
            guard !isShowingOnboarding else { return }
            showCommand.toggle()
        }
        .alert("切换模型？", isPresented: modelSwitchShown) {
            Button("取消", role: .cancel) { state.cancelModelSwitchRequest() }
            Button("停止并切换") { state.confirmModelSwitch() }
        } message: {
            Text(modelSwitchMessage)
        }
        .alert(
            L10n.format(
                "%@ 还没安装",
                state.pendingEngineInstall?.displayName ?? L10n.t("该引擎")),
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
        .alert("重命名对话", isPresented: threadRenameShown, presenting: state.pendingThreadRename) { _ in
            TextField("名称", text: $renameText)
            Button("重命名") { state.confirmThreadRename(renameText) }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) { state.cancelThreadRename() }
        } message: { thread in
            Text("给「\(thread.title)」换一个名字。")
        }
        .onChange(of: state.pendingThreadRename) { _, thread in
            if let thread { renameText = thread.title }
        }
    }

    private var isShowingOnboarding: Bool {
        state.isPresentingLaunchPage || state.showsRecommendationPage
    }

    @ViewBuilder private var pageContent: some View {
        switch state.section {
        case .overview: OverviewPage(state: state, chat: state.chat)
        case .chat: ChatPage(state: state, chat: state.chat)
        case .models:
            ModelsPage(
                state: state,
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

    private var threadRenameShown: Binding<Bool> {
        Binding(
            get: { state.pendingThreadRename != nil },
            set: { if !$0 { state.cancelThreadRename() } })
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

// MARK: - Glass Sidebar

/// Liquid Glass 侧边栏：半透明玻璃底 + 1px 分隔，承载模式切换、工作区、
/// 控制台与最近对话。
struct ConsoleNavigationPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore
    var onCollapse: () -> Void

    @Namespace private var selection
    /// 会话列表的搜索词；Esc 清空。
    @State private var query = ""
    /// 日期分组用的「今天」。跨过午夜后重新分组，不需要重启应用。
    @State private var today = Date()
    /// 搜索 + 分组的结果。对话流式输出时 `ChatStore` 每秒会发布很多次，
    /// 但线程列表没变；把结果存成状态，避免每帧都扫一遍 200 条历史正文。
    /// nil 表示还没算过，首帧用下面的 `shownSections` 现算一次。
    @State private var sections: [ChatThreadSections.Section]?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader

            workspace
                .padding(.horizontal, 10)
                .padding(.top, 4)

            DSDivider()
                .padding(.horizontal, 12)
                .padding(.top, 12)

            HStack(alignment: .center, spacing: 6) {
                Text(L10n.t("最近对话"))
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(DS.text3)
                Spacer(minLength: 4)
                newChatButton
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.top, 12)
            .padding(.bottom, 6)

            searchField
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            recents
                .padding(.horizontal, 10)
                .padding(.bottom, DS.Space.sm)

            hardwarePill
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.sidebarFill)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(DS.sidebarBorder)
                .frame(width: 1)
        }
        .animation(reduceMotion ? nil : DS.Motion.smooth, value: state.section)
    }

    /// 顶部一行：红绿灯留白 + 对话/控制台模式切换 + 折叠按钮。整行可拖窗。
    private var sidebarHeader: some View {
        ZStack(alignment: .leading) {
            WindowDragArea()

            HStack(spacing: 6) {
                // 系统红绿灯画在窗口坐标里，这里让出它们的位置。
                Color.clear.frame(width: 64)

                modeSwitcher
                Spacer(minLength: 0)
                DSIconButton(systemName: "sidebar.left", help: "隐藏边栏", size: 24) {
                    onCollapse()
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: DS.Layout.sidebarHeaderHeight)
    }

    private var modeSwitcher: some View {
        let chatActive = state.section == .chat
        return HStack(spacing: 1) {
            modeButton(
                symbol: "bubble.left",
                active: chatActive,
                help: "对话模式"
            ) {
                state.section = .chat
            }
            modeButton(
                symbol: "square.grid.2x2",
                active: !chatActive,
                help: "控制台模式"
            ) {
                state.section = .overview
            }
        }
        .padding(2)
        .dsGlassPill()
    }

    private func modeButton(
        symbol: String,
        active: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? DS.accent : DS.text3)
                .frame(width: 24, height: 20)
                .background {
                    if active {
                        Capsule()
                            .fill(DS.pillActive)
                            .shadow(color: DS.glassShadow.opacity(0.5), radius: 3, y: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(DSPressStyle(scale: 0.94))
        .help(L10n.t(help))
        .accessibilityLabel(L10n.t(help))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var newChatButton: some View {
        ChatNewConversationButton {
            state.newConversation()
            state.section = .chat
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Page.primaryPages) { page in
                SidebarNavRow(
                    page: page,
                    active: state.section == page,
                    badge: 0,
                    namespace: selection
                ) {
                    state.section = page
                }
            }

            Text(L10n.t("控制台"))
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DS.text3)
                .padding(.horizontal, 9)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ForEach(Page.consolePages) { page in
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
        Set(
            EngineCatalog.allIDs
                .flatMap { state.libraryEntries(for: $0) }
                .filter(\.installed)
                .map { ModelSharing.canonical($0.model.id) }
        ).count
    }

    /// 会话列表的搜索框：标题与消息正文都搜，Esc 清空。
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(DS.text3)

            TextField(L10n.t("搜索对话"), text: $query)
                .textFieldStyle(.plain)
                .font(DS.Font.prose(12))
                .onExitCommand { query = "" }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.text3)
                }
                .buttonStyle(.plainHit)
                .help(L10n.t("清除搜索"))
                .accessibilityLabel(L10n.t("清除搜索"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(DS.rect(10).fill(DS.bg))
        .overlay(DS.rect(10).strokeBorder(DS.line, lineWidth: 1))
    }

    /// 窗口底部的硬件事实条。
    private var hardwarePill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(DS.accent)
                .frame(width: 6, height: 6)
            Text(verbatim: "Apple Silicon")
                .font(DS.Font.prose(11, weight: .medium))
                .foregroundStyle(DS.text3)
            Spacer(minLength: 4)
            Text(verbatim: "MLX Metal")
                .font(DS.Font.mono(10.5))
                .foregroundStyle(DS.text3.opacity(0.85))
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .dsSubcard(radius: 10)
    }

    private var recents: some View {
        let shown = shownSections
        return ScrollView(.vertical) {
            if chat.threads.isEmpty {
                Text(L10n.t("暂无历史对话"))
                    .font(DS.Font.prose(12.5))
                    .foregroundStyle(DS.text3)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if shown.isEmpty {
                VStack(spacing: 3) {
                    Text(L10n.t("没有匹配的对话"))
                        .font(DS.Font.prose(12.5, weight: .medium))
                        .foregroundStyle(DS.text2)
                    Text(L10n.t("换个关键词，或清除搜索。"))
                        .font(DS.Font.prose(11))
                        .foregroundStyle(DS.text3)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .frame(maxWidth: .infinity, alignment: .top)
            } else {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(shown) { section in
                        Text(L10n.t(ChatThreadSections.title(section.group)))
                            .font(DS.Font.prose(10.5, weight: .medium))
                            .foregroundStyle(DS.text3)
                            .padding(.horizontal, 8)
                            .padding(.top, section.id == shown.first?.id ? 4 : 12)
                            .padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)

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
                .padding(.bottom, DS.Space.sm)
            }
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity, alignment: .top)
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

private struct SidebarNavRow: View {
    let page: Page
    let active: Bool
    let badge: Int
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rowShape: RoundedRectangle { DS.rect(10) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? DS.accent : (hovering ? DS.text : DS.text3))
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
                        .background(Capsule().fill(DS.pillFill))
                        .overlay(Capsule().strokeBorder(DS.pillBorder, lineWidth: 1))
                }
            }
            .foregroundStyle(active ? DS.text : (hovering ? DS.text : DS.text2))
            .padding(.horizontal, 9)
            .frame(height: DS.Layout.rowHeight)
            .background {
                if active {
                    rowShape
                        .fill(DS.pillActive)
                        .overlay(rowShape.strokeBorder(DS.pillBorder, lineWidth: 1))
                        .shadow(color: DS.glassShadow.opacity(0.7), radius: 6, y: 2)
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
