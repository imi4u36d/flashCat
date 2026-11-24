// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Combine
import FlashCatKit
import SwiftUI

/// 控制台根视图：左侧 ZCode 风格实体导航边栏 + 1px 发丝分隔线 + 七个原生页面。
struct ConsoleView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var theme = AppState.shared.theme

    @State private var showCommand = false
    @State private var showDownloads = false
    @State private var showHub = false
    @State private var sidebarToggleWidth: CGFloat = DS.Layout.controlHeight
    /// 重命名弹窗里的输入。线程本身挂在 `pendingThreadRename` 上，壳层只负责
    /// 把输入框和落点接起来。
    @State private var renameText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

                ZStack {
                    pageContent
                        .id(state.section)
                        .transition(reduceMotion ? .opacity : .dsPage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(reduceMotion ? nil : DS.Motion.smooth, value: state.section)
                .clipped()
            }
            .animation(reduceMotion ? nil : DS.Motion.smooth, value: state.showsSidebar)
        }
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

// MARK: - ZCode Sidebar

/// ZCode 风格实体侧边栏：纯色基底 + 1px 发丝分隔，承载工作区、控制台与最近对话。
struct ConsoleNavigationPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore

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

            searchField
                .padding(.horizontal, 10)
                .padding(.bottom, DS.Space.xs)

            recents
                .padding(.horizontal, 10)
                .padding(.bottom, DS.Space.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            DS.bg.ignoresSafeArea()
        }
        .animation(reduceMotion ? nil : DS.Motion.smooth, value: state.section)
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

            DSSectionLabel(text: "控制台")
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 3)

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
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(DS.rect(7).fill(DS.hover))
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
