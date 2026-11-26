// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Combine
import FlashCatCore
import SwiftUI

/// 对话页顶栏的历史入口与会话弹层：按日期分组的会话行与搜索。
///
/// 会话行只留一份：置顶、重命名、删除、生成中小圆点与选中态都在这里实现，
/// 弹层内不再另起一套。

// MARK: - Thread row

/// 弹层里的一段历史会话：标题、生成中小圆点，悬停（或选中时）浮出置顶 /
/// 删除两枚微操作，右键提供同一组动作。
struct ChatThreadRow: View {
    let thread: ChatThread
    let active: Bool
    let generating: Bool
    /// 后台生成完成、还没点开：标题前点一颗强调色圆点。
    let unread: Bool
    let onOpen: () -> Void
    let onPin: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle { DS.rect(DS.Radius.sm) }
    /// 行尾操作：悬停时浮出，选中的那一行常驻（和设计稿的 active 态一致）。
    private var showsActions: Bool { hovering || active }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    if generating {
                        DSStatusDot(color: DS.accent, live: true, size: 5)
                    } else if unread {
                        DSStatusDot(color: DS.accent, live: false, size: 5)
                            .help(L10n.t("后台生成已完成"))
                    }
                    Text(thread.title.isEmpty ? L10n.t("新对话") : thread.title)
                        .font(DS.Font.prose(12.5, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? DS.text : (hovering ? DS.text : DS.text2))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 9)
                // 悬停 / 选中时给行尾两枚微操作让位，标题仍占满剩余宽度，行宽不跳。
                .padding(.trailing, showsActions ? 48 : 9)
                .frame(height: 28)
                .background {
                    if active {
                        shape.fill(DS.selected)
                    } else if hovering {
                        shape.fill(DS.hover)
                    }
                }
                .contentShape(shape)
            }
            .buttonStyle(.plainHit)
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityAction(named: Text(thread.pinned ? L10n.t("取消置顶") : L10n.t("置顶"))) {
                onPin()
            }
            .accessibilityAction(named: Text(L10n.t("重命名对话"))) { onRename() }
            .accessibilityAction(named: Text(L10n.t("删除对话"))) { onDelete() }
            .contextMenu { menuItems }

            if showsActions {
                HStack(spacing: 1) {
                    Button(action: onPin) {
                        Image(systemName: thread.pinned ? "pin.fill" : "pin")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(thread.pinned ? DS.accent : DS.text3)
                            .frame(width: 20, height: 20)
                            .background {
                                if thread.pinned {
                                    DS.rect(6).fill(DS.accentSoft)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plainHit)
                    .help(thread.pinned ? L10n.t("取消置顶") : L10n.t("置顶对话"))

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(DS.text3)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plainHit)
                    .help(L10n.t("删除对话"))
                }
                .padding(.trailing, 3)
            }
        }
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
    }

    /// 悬停菜单与右键菜单共用同一组动作，和 Splash 的会话行一致。
    @ViewBuilder private var menuItems: some View {
        Button(thread.pinned ? L10n.t("取消置顶") : L10n.t("置顶")) { onPin() }
        Button(L10n.t("重命名…")) { onRename() }
        Divider()
        Button(L10n.t("删除…"), role: .destructive) { onDelete() }
    }
}

// MARK: - History popover

/// 对话页顶栏的历史入口。边栏收起时没有别的地方能换会话，这一颗按钮把
/// 「最近对话 + 新建对话」装回页面里；边栏展开时它仍是同一条捷径，少一次
/// 把目光挪到侧栏。
struct ChatHistoryButton: View {
    @ObservedObject var state: AppState
    let chat: ChatStore

    @State private var open = false

    var body: some View {
        DSIconButton(
            systemName: "clock.arrow.circlepath",
            help: "对话历史",
            size: 26,
            active: open
        ) {
            open.toggle()
        }
        .popover(isPresented: $open, arrowEdge: .top) {
            ChatRecentsPopover(state: state, chat: chat) { open = false }
        }
    }
}

/// 顶栏历史弹层：标题「工作区」+ 新对话、搜索、按日期分组的会话列表，
/// 收进 300pt 宽的浮层里，不占正文宽度。
struct ChatRecentsPopover: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore
    /// 选中会话、新建对话或进入改名 / 删除时收起弹层，把下一屏让出来。
    var dismiss: () -> Void

    /// 会话列表的搜索词；Esc 清空。
    @State private var query = ""
    /// 日期分组用的「今天」。跨过午夜后重新分组，不用重启应用。
    @State private var today = Date()
    /// 搜索 + 分组的结果。流式输出时 `ChatStore` 每秒会发布很多次，
    /// 但线程列表没变；把结果存成状态，避免每帧都扫一遍历史正文。
    @State private var sections: [ChatThreadSections.Section]?
    /// 列表内容的实际高度。`ScrollView` 在 SwiftUI 里最小高度为 0，
    /// 不量出内容再撑开，弹层第一次布局后会塌成一条线。
    @State private var contentHeight: CGFloat = 240

    private var shownSections: [ChatThreadSections.Section] {
        if let sections { return sections }
        return ChatThreadSections.sections(
            ChatThreadSections.matching(chat.threads, query: query),
            now: today)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                DSSectionLabel(text: "最近对话")
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.top, 12)
            .padding(.bottom, 8)

            DSSearchField(query: $query, placeholder: "搜索对话")
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            recents
        }
        .frame(width: 300)
        .dsPopoverSurface()
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

    private var recents: some View {
        let shown = shownSections
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if chat.threads.isEmpty {
                    hint(title: "暂无历史对话", detail: nil)
                } else if shown.isEmpty {
                    hint(title: "没有匹配的对话", detail: "换个关键词，或清除搜索。")
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
                                    active: state.currentThreadID == thread.id,
                                    generating: state.generatingThreadID == thread.id,
                                    unread: state.unreadThreadIDs.contains(thread.id)
                                ) {
                                    state.openThread(thread)
                                    dismiss()
                                } onPin: {
                                    state.setThreadPinned(thread, !thread.pinned)
                                } onRename: {
                                    dismiss()
                                    state.requestThreadRename(thread)
                                } onDelete: {
                                    dismiss()
                                    state.requestThreadDelete(thread)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                if height > 0, abs(height - contentHeight) > 0.5 {
                    contentHeight = height
                }
            }
        }
        .scrollIndicators(.never)
        .frame(height: min(max(contentHeight, 1), 360))
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

    private func refreshSections(_ threads: [ChatThread]? = nil) {
        let matched = ChatThreadSections.matching(threads ?? chat.threads, query: query)
        sections = ChatThreadSections.sections(matched, now: today)
    }
}
