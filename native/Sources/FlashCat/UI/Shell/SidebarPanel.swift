// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Combine
import FlashCatCore
import FlashCatKit
import SwiftUI

// MARK: - Native Sidebar

/// 原生 macOS 侧栏：上层固定（导航 / 工作区标题 / 搜索），中间是会话列表，
/// 底部固定设置。滚动只发生在会话列表里，导航和主行动不会被长历史顶走。
///
/// - 导航与会话是两层：导航用强调色选中，会话用中性底 + 左侧竖条；
/// - 会话按「置顶 / 今天 / 昨天 / 最近 7 天…」分组，分组名直接画出来；
/// - 每行行尾给紧凑时间，悬停时让位给「…」菜单；
/// - 搜索在「工作区」标题行原地展开，不再向列表插行；
/// - 新对话与搜索并排收在工作区标题右侧，保持为两颗 22pt 图标按钮。
struct ConsoleNavigationPanel: View {
    @ObservedObject var state: AppState
    let chat: ChatStore

    @State private var query = ""
    @State private var showsSearch = false
    @State private var today = Date()
    @State private var sections: [ChatThreadSections.Section]?
    @State private var threadCount = 0
    @State private var isGenerating = false
    @FocusState private var searchFocused: Bool

    private var shownSections: [ChatThreadSections.Section] {
        if let sections { return sections }
        let matched = ChatThreadSections.matching(chat.threads, query: query)
        return ChatThreadSections.sections(matched, now: today)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                LazyVStack(spacing: 0) {
                    threadRows
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            // 原生 ScrollView 默认给内容留了一圈边距；侧栏的
            // 18pt 左缘、8pt 行底都由行内 padding 决定，这里必须归零。
            .contentMargins(.all, 0, for: .scrollContent)
            footer
        }
        .onReceive(chat.$threads) { threads in
            threadCount = threads.count
            refreshSections(threads)
        }
        .onReceive(chat.$generating) { value in
            if isGenerating != value { isGenerating = value }
        }
        .onChange(of: query) { _, _ in refreshSections() }
        .onChange(of: today) { _, _ in refreshSections() }
        .onChange(of: state.chatSearchFocusTick) { _, _ in
            revealSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            today = .now
        }
    }

    // MARK: - Threads

    @ViewBuilder
    private var threadRows: some View {
        if threadCount == 0 {
            emptyState
        } else if shownSections.isEmpty {
            noResults
        } else {
            ForEach(shownSections) { section in
                groupLabel(section, first: section.id == shownSections.first?.id)
                ForEach(section.threads) { thread in
                    SidebarThreadRow(
                        thread: thread,
                        active: state.currentThreadID == thread.id && state.section == .chat,
                        generating: isGenerating && state.generatingThreadID == thread.id,
                        unread: state.unreadThreadIDs.contains(thread.id),
                        timeText: Format.sidebarTime(thread.updatedAt, now: today),
                        onOpen: { state.openThread(thread) },
                        onPin: { state.setThreadPinned(thread, !thread.pinned) },
                        onRename: { state.requestThreadRename(thread) },
                        onDelete: { state.requestThreadDelete(thread) }
                    )
                    .padding(.top, 1)
                }
            }
        }
    }

    // MARK: - Fixed top

    private var topBar: some View {
        VStack(spacing: 0) {
            navigation
            Rectangle()
                .fill(DS.line)
                .frame(height: 1)
                .padding(.horizontal, 10)
                .padding(.top, 12)
            workspaceBar
                .padding(.top, 8)
        }
        .padding(.top, 8)
    }

    private var navigation: some View {
        VStack(spacing: 1) {
            ForEach(Page.sidebarPages) { page in
                SidebarNavRow(
                    page: page,
                    active: state.section == page,
                    accessory: navAccessory(for: page, active: state.section == page),
                    action: { state.section = page }
                )
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var workspaceBar: some View {
        if showsSearch {
            searchBar
        } else {
            workspaceHeader
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 2) {
            Text(L10n.t("工作区"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(DS.text3)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: "(\(threadCount))")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(DS.text4)
                .padding(.leading, 1)
            Spacer(minLength: 4)
            SidebarHeaderButton(
                systemName: "square.and.pencil",
                help: "\(L10n.t("新对话"))  ⌘N",
                tint: DS.accent
            ) {
                newConversation()
            }
            SidebarHeaderButton(
                systemName: "magnifyingglass",
                help: "\(L10n.t("搜索对话"))  ⌘F"
            ) {
                toggleSearch()
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .frame(height: 28)
    }

    private var searchBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DS.text3)

            TextField(L10n.t("搜索对话"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($searchFocused)
                .onExitCommand {
                    hideSearch()
                }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.text3)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("清除搜索"))
            }

            Text(verbatim: "esc")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(DS.text3.opacity(0.7))
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(searchFocused ? DS.accent.opacity(0.55) : .clear, lineWidth: 1)
        )
        .padding(.horizontal, 10)
    }

    // MARK: - Rows

    private func groupLabel(
        _ section: ChatThreadSections.Section,
        first: Bool
    ) -> some View {
        Text(L10n.t(ChatThreadSections.title(section.group)))
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.2)
            .foregroundStyle(DS.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 22)
            .padding(.leading, 10)
            .padding(.top, first ? 2 : 8)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func navAccessory(for page: Page, active: Bool) -> some View {
        switch page {
        case .models:
            if state.installedModelCount > 0 {
                Text(verbatim: "\(state.installedModelCount)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(active ? DS.accent : DS.text3)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .frame(minWidth: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(active ? DS.accentSoft : Color.primary.opacity(0.06))
                    )
            }
        default:
            EmptyView()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 22))
                .foregroundStyle(DS.text4)
                .padding(.bottom, 2)
            Text(L10n.t("还没有对话"))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.text2)
            Text(L10n.t("输入一句话就可以开始。"))
                .font(.system(size: 11))
                .foregroundStyle(DS.text3)
            Button {
                newConversation()
            } label: {
                Text(L10n.t("开始第一段对话") + "  ⌘N")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.accent)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 52)
    }

    private var noResults: some View {
        VStack(spacing: 6) {
            Text(L10n.t("没有匹配的对话"))
                .font(.system(size: 12))
                .foregroundStyle(DS.text2)
            Button {
                query = ""
                refreshSections()
                searchFocused = true
            } label: {
                Text(L10n.t("清除搜索"))
                    .font(.system(size: 11))
                    .foregroundStyle(DS.accent)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 34)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DS.line)
                .frame(height: 1)
                .padding(.horizontal, 10)
            SidebarSettingsRow(active: state.section == .settings) {
                state.section = .settings
            }
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Search

    private func newConversation() {
        state.newConversation()
        state.section = .chat
    }

    private func toggleSearch() {
        if showsSearch {
            hideSearch()
        } else {
            revealSearch()
        }
    }

    /// 展开搜索并要焦点；⌘F 和放大镜走同一条路。
    private func revealSearch() {
        if showsSearch {
            searchFocused = true
            return
        }
        withAnimation(DS.Motion.snappy) { showsSearch = true }
        // 输入框这一帧才换进来，焦点等下一轮布局。
        DispatchQueue.main.async { searchFocused = true }
    }

    /// 收起时顺手清空，免得列表挂着一个看不见的过滤词。
    private func hideSearch() {
        query = ""
        searchFocused = false
        withAnimation(DS.Motion.snappy) { showsSearch = false }
    }

    private func refreshSections(_ threads: [ChatThread]? = nil) {
        let matched = ChatThreadSections.matching(threads ?? chat.threads, query: query)
        sections = ChatThreadSections.sections(matched, now: today)
    }
}

// MARK: - Nav row

/// 导航页一行：图标 + 名称 + 行尾读数。选中是页面级语义，
/// 用 `accentSoft` 底和强调色图标，与会话行的中性选中区分开。
private struct SidebarNavRow<Accessory: View>: View {
    let page: Page
    let active: Bool
    let accessory: Accessory
    let action: () -> Void

    @State private var hovering = false

    private var background: Color {
        if active { return DS.accentSoft }
        if hovering { return DS.hover }
        return .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: page.symbol)
                    .font(.system(size: 14.5, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? DS.accent : DS.text2)
                    .frame(width: 20)

                Text(L10n.t(page.rawValue))
                    .font(.system(size: 13.5, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? DS.text : DS.text2)
                    .lineLimit(1)

                Spacer(minLength: 4)

                accessory
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .help("\(L10n.t(page.rawValue))  \(page.shortcutDisplay)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Thread row

/// 会话行：标题 + 行尾时间槽。悬停时时间淡出、同一位置淡入「…」，
/// 宽度不变、不跳行；菜单与右键菜单共用同一组动作。
private struct SidebarThreadRow: View {
    let thread: ChatThread
    let active: Bool
    let generating: Bool
    /// 后台生成完成、还没点开：时间让位给一颗强调色圆点。
    let unread: Bool
    let timeText: String
    let onOpen: () -> Void
    let onPin: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var background: Color {
        if active { return DS.rowSelected }
        if hovering { return DS.hover }
        return .clear
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Text(thread.title.isEmpty ? L10n.t("新对话") : thread.title)
                        .font(.system(size: 13, weight: active ? .medium : .regular))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    meta
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(height: 30)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hovering {
                moreMenu
                    .padding(.trailing, 8)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(background)
        )
        .overlay(alignment: .leading) {
            if active {
                Capsule()
                    .fill(DS.accent)
                    .frame(width: 2.5, height: 14)
                    .padding(.leading, 4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .contextMenu { menuItems }
        .help(thread.title.isEmpty ? L10n.t("新对话") : thread.title)
    }

    /// 固定 32pt 的时间槽：时间 / 生成中呼吸点和「…」共用同一个落点。
    private var meta: some View {
        ZStack(alignment: .trailing) {
            if generating {
                DSStatusDot(color: DS.accent, live: true, size: 6)
                    .opacity(hovering ? 0 : 1)
            } else if unread {
                DSStatusDot(color: DS.accent, live: false, size: 6)
                    .opacity(hovering ? 0 : 1)
                    .help(L10n.t("后台生成已完成"))
            } else {
                Text(verbatim: timeText)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(DS.text3)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(hovering ? 0 : 1)
            }
        }
        .frame(width: 32, height: 20, alignment: .trailing)
    }

    private var moreMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DS.text3)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("\(L10n.t("置顶对话")) / \(L10n.t("重命名对话")) / \(L10n.t("删除对话"))")
        .accessibilityLabel(Text("更多操作"))
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(thread.pinned ? L10n.t("取消置顶") : L10n.t("置顶对话")) {
            onPin()
        }
        Button(L10n.t("重命名对话")) {
            onRename()
        }
        Divider()
        Button(L10n.t("删除对话"), role: .destructive) {
            onDelete()
        }
    }
}

// MARK: - Settings row

/// 底栏设置行：保持中性单色，不染强调色；快捷键只在悬停时显形，
/// 让行尾和上方会话读数落在同一条导轨上。
private struct SidebarSettingsRow: View {
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: Page.settings.symbol)
                    .font(.system(size: 14.5, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? DS.text : DS.text2)
                    .frame(width: 20)

                Text(L10n.t(Page.settings.rawValue))
                    .font(.system(size: 13, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? DS.text : DS.text2)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(verbatim: Page.settings.shortcutDisplay)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DS.text3)
                    .opacity(hovering ? 0.85 : 0)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Color.primary.opacity(0.07) : (hovering ? DS.hover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .help("\(L10n.t(Page.settings.rawValue))  \(Page.settings.shortcutDisplay)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Header button

/// 工作区标题右侧的小图标按钮：新对话与搜索并排，悬停才给底色。
private struct SidebarHeaderButton: View {
    let systemName: String
    let help: String
    var tint: Color?
    let action: () -> Void

    @State private var hovering = false

    private var foreground: Color {
        tint ?? (hovering ? DS.text : DS.text2)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.07) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}
