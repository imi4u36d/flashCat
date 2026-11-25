// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Combine
import FlashCatCore
import FlashCatKit
import SwiftUI

// MARK: - Native Sidebar

/// 原生 macOS 边栏：基于 `List(.sidebar)` 与 `Section(isExpanded:)`，
/// 由外层 `NavigationSplitView` 承担 120Hz 展开与收起动画。
///
/// - 玻璃外观：沿用系统原生半透明材质与悬浮边栏质感；
/// - 纯净外观：隐藏列表底板，改为 `DS.sidebarFill` 实色背景与 1px 右分隔线；
/// - 底部「设置」按钮保持中性单色，不染强调色。
struct ConsoleNavigationPanel: View {
    @ObservedObject var state: AppState
    let chat: ChatStore

    @State private var query = ""
    @State private var today = Date()
    @State private var sections: [ChatThreadSections.Section]?
    @State private var threadCount = 0
    @State private var isGenerating = false
    @AppStorage("sidebarConsoleExpanded") private var consoleExpanded = true
    @FocusState private var searchFocused: Bool

    private var consolePages: [Page] { Page.consolePages.filter { $0 != .settings } }

    private var shownSections: [ChatThreadSections.Section] {
        if let sections { return sections }
        let matched = ChatThreadSections.matching(chat.threads, query: query)
        return ChatThreadSections.sections(matched, now: today)
    }

    var body: some View {
        sidebarList
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
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
                searchFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                today = .now
            }
    }

    private var sidebarList: some View {
        List {
            Section {
                newChatButton
                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 4, trailing: 6))
                    .listRowSeparator(.hidden)

                ForEach(Page.primaryPages) { page in
                    navRow(page)
                }
            }

            Section(isExpanded: $consoleExpanded) {
                ForEach(consolePages) { page in
                    navRow(page)
                }
            } header: {
                Text(L10n.t("控制台"))
            }

            Section {
                searchField
                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 4, trailing: 6))
                    .listRowSeparator(.hidden)

                if threadCount == 0 {
                    Text(L10n.t("暂无历史对话"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else if shownSections.isEmpty {
                    Text(L10n.t("没有匹配的对话"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(shownSections) { section in
                        Text(L10n.t(ChatThreadSections.title(section.group)))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .padding(.top, section.id == shownSections.first?.id ? 2 : 8)

                        ForEach(section.threads) { thread in
                            threadRow(thread)
                        }
                    }
                }
            } header: {
                HStack(spacing: 4) {
                    Text(L10n.t("最近对话"))
                    if threadCount > 0 {
                        Text(verbatim: "(\(threadCount))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private var newChatButton: some View {
        Button {
            state.newConversation()
            state.section = .chat
        } label: {
            Label {
                HStack {
                    Text(L10n.t("新对话"))
                        .fontWeight(.medium)
                    Spacer()
                    Text(verbatim: "⌘N")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            } icon: {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(DS.accent)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t("新对话"))
    }

    private func navRow(_ page: Page) -> some View {
        let active = state.section == page
        return Button {
            state.section = page
        } label: {
            HStack(spacing: 8) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? DS.accent : .secondary)
                    .frame(width: 18)

                Text(L10n.t(page.rawValue))
                    .fontWeight(active ? .medium : .regular)
                    .foregroundStyle(active ? .primary : .secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                navAccessory(for: page)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Color.primary.opacity(0.09) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .listRowSeparator(.hidden)
        .help("\(L10n.t(page.rawValue))  \(page.shortcutDisplay)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder
    private func navAccessory(for page: Page) -> some View {
        switch page {
        case .models:
            if state.installedModelCount > 0 {
                Text(verbatim: "\(state.installedModelCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        case .engines:
            HStack(spacing: 4) {
                DSStatusDot(
                    color: state.isModelBusy ? DS.warn : (state.isRunning ? DS.ok : DS.text4),
                    live: state.isRunning && !state.isModelBusy,
                    size: 5)
                Text(verbatim: state.activeEngine.displayName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(state.isRunning ? DS.ok : .secondary)
                    .lineLimit(1)
            }
        default:
            EmptyView()
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(L10n.t("搜索对话"), text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFocused)
                .onExitCommand {
                    query = ""
                    searchFocused = false
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.t("清除搜索"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private func threadRow(_ thread: ChatThread) -> some View {
        let active = state.currentThreadID == thread.id && state.section == .chat
        let generating = isGenerating && state.generatingThreadID == thread.id
        return Button {
            state.openThread(thread)
            state.section = .chat
        } label: {
            HStack(spacing: 6) {
                if generating {
                    DSStatusDot(color: DS.accent, live: true, size: 5)
                } else if thread.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Text(thread.title.isEmpty ? L10n.t("新对话") : thread.title)
                    .font(.callout)
                    .fontWeight(active ? .medium : .regular)
                    .foregroundStyle(active ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Color.primary.opacity(0.09) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .listRowSeparator(.hidden)
        .contextMenu {
            Button(thread.pinned ? L10n.t("取消置顶") : L10n.t("置顶对话")) {
                state.setThreadPinned(thread, !thread.pinned)
            }
            Button(L10n.t("重命名对话")) {
                state.requestThreadRename(thread)
            }
            Divider()
            Button(L10n.t("删除对话"), role: .destructive) {
                state.requestThreadDelete(thread)
            }
        }
    }

    // MARK: - Footer (Monochrome Settings)

    private var footer: some View {
        let active = state.section == .settings
        return VStack(spacing: 0) {
            Divider()
            Button {
                state.section = .settings
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Page.settings.symbol)
                        .font(.system(size: 13, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? DS.text : DS.text2)
                        .frame(width: 18)

                    Text(L10n.t(Page.settings.rawValue))
                        .font(.callout)
                        .fontWeight(active ? .medium : .regular)
                        .foregroundStyle(active ? DS.text : DS.text2)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(verbatim: Page.settings.shortcutDisplay)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .help("\(L10n.t(Page.settings.rawValue))  \(Page.settings.shortcutDisplay)")
            .accessibilityAddTraits(active ? .isSelected : [])
        }
    }

    private func refreshSections(_ threads: [ChatThread]? = nil) {
        let matched = ChatThreadSections.matching(threads ?? chat.threads, query: query)
        sections = ChatThreadSections.sections(matched, now: today)
    }
}
