// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AVKit
import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI
import UniformTypeIdentifiers

/// 对话页：单列转录、用户淡色气泡、助手无气泡、思考折叠行、悬停操作行与页脚输入卡。
struct ChatPage: View {
    @ObservedObject var state: AppState
    let chat: ChatStore
    /// 壳层在布局这一拍量到的详情区尺寸。对话列宽与宽 / 窄版式都由它直接
    /// 算出，切页回来时第一帧就是最终版式，不会再缩一下。
    let pageSize: CGSize
    var isActive: Bool = true

    @State private var hasMessages: Bool
    @State private var firstMessageID: UUID?
    @State private var threads: [ChatThread]
    @State var composerFocused = false
    @State var editingMessageID: UUID?
    @State var pendingEditMessage: ChatMessage?
    @State private var showsModelPicker = false

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.colorScheme) var colorScheme

    init(state: AppState, chat: ChatStore, pageSize: CGSize, isActive: Bool = true) {
        self.state = state
        self.chat = chat
        self.pageSize = pageSize
        self.isActive = isActive
        // 切页会把页面重建一次；这些首帧状态必须从 store 直接取当前值。
        // 否则进入已有对话时会先按「新会话」排一版，`onAppear` 再翻成转录
        // 版式，输入卡和标题那一拍就会上下弹一下。
        _hasMessages = State(initialValue: !chat.messages.isEmpty)
        _firstMessageID = State(initialValue: chat.messages.first?.id)
        _threads = State(initialValue: chat.threads)
    }

    private var isWide: Bool {
        pageSize.width >= Console.compactContentWidth
    }

    /// 对话列宽：默认宽度按页面宽度夹一次。只夹、不回写。
    private var columnWidth: CGFloat {
        ChatColumn.width(stored: ChatColumn.defaultWidth, pageWidth: pageSize.width)
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatStageView(newChat: !hasMessages, column: columnWidth) {
                ZStack {
                    if !hasMessages {
                        emptyState
                            .transition(.opacity)
                    } else {
                        ChatTranscriptView(
                            chat: chat,
                            threadID: state.currentThreadID,
                            isActive: isActive,
                            bubbleMaxWidth: bubbleMaxWidth,
                            activeEngineName: state.activeEngine.displayName,
                            supportsVideo: state.activeModelSupportsVideo,
                            shortModelName: state.shortModelName,
                            onEdit: { requestEdit($0) },
                            onBranch: { state.branchThread(from: $0) },
                            onRegenerate: { state.regenerate() }
                        )
                        .transition(.opacity)
                    }
                }
            } composer: {
                ChatComposerHost(
                    state: state,
                    draftStore: state.chatDrafts,
                    chat: chat,
                    isActive: isActive,
                    editingMessageID: $editingMessageID,
                    composerFocused: $composerFocused,
                    showsModelPicker: $showsModelPicker
                )
                .padding(.horizontal, ChatColumn.contentInset)
            }
            .animation(reduceMotion ? nil : Motion.settle, value: !hasMessages)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem(id: DSToolbarSlot.title, placement: .navigation) {
                chatToolbarTitle
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(id: DSToolbarSlot.anchor, placement: .principal) {
                DSToolbarAnchor()
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(id: DSToolbarSlot.actions, placement: .primaryAction) {
                DSToolbarActionRow(state: state, compact: !isWide) {
                    chatToolbarActions
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .alert("编辑并重发？", isPresented: editConfirmationShown, presenting: pendingEditMessage) {
            message in
            Button(L10n.t("重发")) {
                pendingEditMessage = nil
                startEditing(message)
            }
            Button(L10n.t("取消"), role: .cancel) { pendingEditMessage = nil }
        } message: { message in
            Text(
                L10n.format(
                    "发送后会删除这条消息之后的 %lld 条回答，再按新内容重新生成。",
                    Int64(laterMessageCount(for: message))))
        }
        .onChange(of: hasMessages) { _, has in
            if !has, isActive { focusComposer() }
        }
        .onChange(of: firstMessageID) { _, _ in
            if isActive { focusComposer() }
        }
        .onChange(of: state.currentThreadID) { _, _ in
            editingMessageID = nil
        }
        .onChange(of: isActive) { _, active in
            if active {
                focusComposer()
            } else {
                composerFocused = false
            }
        }
        .onReceive(chat.$messages) { messages in
            syncMessageSummary(messages)
        }
        .onReceive(chat.$threads) { newThreads in
            threads = newThreads
        }
        .onAppear {
            syncMessageSummary(chat.messages)
            threads = chat.threads
            if isActive { focusComposer() }
        }
    }

    private func syncMessageSummary(_ messages: [ChatMessage]) {
        let nonEmpty = !messages.isEmpty
        if hasMessages != nonEmpty { hasMessages = nonEmpty }
        let firstID = messages.first?.id
        if firstMessageID != firstID { firstMessageID = firstID }
    }

    private func focusComposer() {
        guard isActive else { return }
        composerFocused = true
    }

    var bubbleMaxWidth: CGFloat {
        ChatColumn.bubbleWidth(column: columnWidth)
    }

    // MARK: Header

    var currentThread: ChatThread? {
        threads.first(where: { $0.id == state.currentThreadID })
    }

    var restoredTitle: String? {
        guard hasMessages else { return nil }
        if let thread = currentThread { return thread.title }
        return ChatHistory.autoTitle(messages: chat.messages)
    }

    @ViewBuilder
    private var chatToolbarTitle: some View {
        if let thread = currentThread, hasMessages {
            ChatTitleMenu(state: state, thread: thread)
                .frame(maxWidth: isWide ? 360 : 220, alignment: .leading)
                .padding(.leading, 11)
        } else if let title = restoredTitle {
            Text(title)
                .font(DS.Font.prose(15, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(DS.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: isWide ? 360 : 220, alignment: .leading)
                .padding(.leading, 15)
        } else {
            Text(L10n.t("对话"))
                .font(DS.Font.prose(15, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(DS.text)
                .frame(maxWidth: isWide ? 360 : 220, alignment: .leading)
                .padding(.leading, 15)
        }
    }

    @ViewBuilder
    private var chatToolbarActions: some View {
        if !state.showsSidebar {
            ChatHistoryButton(state: state, chat: chat)

            if isWide {
                Button {
                    state.newConversation()
                    state.section = .chat
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(DS.accent)
                        Text(L10n.t("新对话"))
                    }
                }
                .buttonStyle(.ds(.secondary, size: .regular))
                .help(L10n.t("新对话"))
            } else {
                DSIconButton(
                    systemName: "square.and.pencil",
                    help: "新对话",
                    size: 28,
                    style: .outlined
                ) {
                    state.newConversation()
                    state.section = .chat
                }
            }
        }
    }

    // MARK: Editing

    var editConfirmationShown: Binding<Bool> {
        Binding(
            get: { pendingEditMessage != nil },
            set: { if !$0 { pendingEditMessage = nil } })
    }

    func laterMessageCount(for message: ChatMessage) -> Int {
        guard let index = chat.messages.firstIndex(where: { $0.id == message.id }) else {
            return 0
        }
        return max(0, chat.messages.count - index - 1)
    }

    func requestEdit(_ message: ChatMessage) {
        guard !chat.generating, message.role == "user" else { return }
        if laterMessageCount(for: message) > 0 {
            pendingEditMessage = message
        } else {
            startEditing(message)
        }
    }

    func startEditing(_ message: ChatMessage) {
        editingMessageID = message.id
        var draft = state.chatDrafts.drafts[state.currentThreadID] ?? ChatDraft()
        draft.text = message.content
        draft.notice = nil
        state.chatDrafts.drafts[state.currentThreadID] = draft
        composerFocused = true
    }

    // MARK: Empty

    var emptyState: some View {
        VStack(spacing: 14) {
            BrandMark(size: 46)
                .frame(width: 64, height: 64)
                .dsSurface(radius: 18)

            Text(L10n.t("有什么可以帮你的？"))
                .font(DS.Font.prose(22, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(DS.text)
        }
    }
}
