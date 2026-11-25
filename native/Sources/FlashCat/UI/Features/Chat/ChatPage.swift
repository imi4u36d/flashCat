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
    var isActive: Bool = true

    @State var showsParameters = false
    @State var showsEmptyModelPicker = false
    @State private var hasMessages = false
    @State private var firstMessageID: UUID?
    @State private var threads: [ChatThread] = []
    @State var composerFocused = false
    @State var editingMessageID: UUID?
    @State var pendingEditMessage: ChatMessage?
    @State var columnWidth: CGFloat = ChatColumn.defaultWidth

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.colorScheme) var colorScheme

    init(state: AppState, chat: ChatStore, isActive: Bool = true) {
        self.state = state
        self.chat = chat
        self.isActive = isActive
    }

    var body: some View {
        VStack(spacing: 0) {
            header
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
                    showsParameters: $showsParameters
                )
                .padding(.horizontal, ChatColumn.contentInset)
            }
            .animation(reduceMotion ? nil : Motion.settle, value: !hasMessages)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { proxy in
            guard isActive else { return -1 }
            return ChatColumn.width(
                stored: ChatColumn.defaultWidth,
                pageWidth: proxy.size.width
            ).rounded()
        } action: { clamped in
            guard clamped > 0 else { return }
            columnWidth = clamped
        }
        .sheet(isPresented: $showsParameters) { ChatParametersSheet(state: state) }
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
                showsParameters = false
                showsEmptyModelPicker = false
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

    /// 侧栏展开时顶栏只保留当前会话标题；侧栏收起时补上历史与新对话捷径。
    var header: some View {
        HStack(spacing: 8) {
            if !state.showsSidebar {
                ChatHistoryButton(state: state, chat: chat)
            }
            if let thread = currentThread, hasMessages {
                ChatTitleMenu(state: state, thread: thread)
            } else if let title = restoredTitle {
                Text(title)
                    .font(DS.Font.prose(14.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)

            if !state.showsSidebar {
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
        .padding(.leading, Console.topBarLeading(sidebarShown: state.showsSidebar, base: Console.contentPadding))
        .padding(.trailing, Console.contentPadding)
        .frame(height: DS.Layout.titlebarHeight)
        .padding(.top, Console.pageTopPadding)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            if hasMessages {
                Rectangle()
                    .fill(DS.line.opacity(0.55))
                    .frame(height: 1)
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

            HStack(spacing: 8) {
                Button {
                    showsEmptyModelPicker = true
                } label: {
                    HStack(spacing: 7) {
                        EngineMark(id: state.activeEngine, size: 15)
                        DSStatusDot(color: emptyStatusTint, live: isActive && state.canChat, size: 6)
                        Text(emptyStatusNote)
                            .font(DS.Font.prose(12, weight: .medium))
                            .foregroundStyle(DS.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(DS.text3)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .dsGlassPill()
                    .contentShape(Capsule())
                }
                .buttonStyle(DSPressStyle(scale: 0.98))
                .disabled(chat.generating)
                .popover(isPresented: $showsEmptyModelPicker, arrowEdge: .bottom) {
                    ModelPickerPopover(state: state) { showsEmptyModelPicker = false }
                }
                .help(L10n.t("切换模型"))

                if !state.isRunning && !state.isModelBusy && !state.selectedModel.isEmpty {
                    Button {
                        state.startService()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text(L10n.t("启动"))
                                .font(DS.Font.prose(12, weight: .medium))
                        }
                        .foregroundStyle(DS.ok)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(Capsule().fill(DS.successFill))
                        .overlay(Capsule().strokeBorder(DS.successStroke, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(DSPressStyle(scale: 0.97))
                    .help(L10n.t("启动引擎"))
                }
            }
        }
    }

    var emptyStatusTint: Color {
        if state.serverState == .failed { return DS.err }
        if state.isModelBusy { return DS.warn }
        return state.canChat ? DS.ok : DS.text4
    }

    var emptyStatusNote: String {
        if state.selectedModel.isEmpty { return L10n.t("还没有选择模型") }
        if state.isModelBusy {
            if let stage = state.chatStartupStage, !stage.isEmpty { return stage }
            return L10n.t("模型正在启动…")
        }
        if state.canChat {
            return "\(state.activeEngine.displayName) · \(state.shortModelName(state.selectedModel))"
        }
        return L10n.t("模型未运行")
    }
}
