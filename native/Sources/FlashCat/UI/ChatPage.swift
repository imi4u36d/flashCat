// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AVKit
import AppKit
import FlashCatKit
import SwiftUI
import UniformTypeIdentifiers

/// 对话页：对齐 Splash 的版式——单列转录、用户淡色气泡、助手无气泡、思考折叠行、
/// 悬停操作行，以及一张浮在页脚的输入卡。新会话只有品牌标记与输入卡，第一条消息
/// 之后输入卡移到页脚，转录在它上方淡入。
struct ChatPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore
    /// 每个会话的草稿。切会话、切页都只换一个键，草稿不会串。
    @ObservedObject private var draftStore: ChatDraftStore

    @State private var showsParameters = false
    @State private var atBottom = true
    /// 用户正在主动滚动时，内容长高不再把视图拽回底部。
    @State private var userScrolling = false
    /// 「加载更早」按会话记：换一段会话各算各的，删掉会话也只是留个用不到的键。
    @State private var earlierBatches: [String: Int] = [:]
    /// 输入框的第一响应者状态由 `ChatComposerField` 回报。
    @State private var composerFocused = false
    @State private var imageOptions = ImageOptionsStore.load()
    @State private var videoOptions = VideoOptionsStore.load()
    @State private var showsImageOptions = false
    /// 拖拽悬停在输入卡上时给出投放提示；图像/视频模型才接受文件。
    @State private var isDropTargeted = false
    /// 正在编辑的用户消息；非 nil 时发送键改为「保存并重发」。
    @State private var editingMessageID: UUID?
    /// 编辑会删掉后面的回答：先挂起，等壳层确认。
    @State private var pendingEditMessage: ChatMessage?
    /// 上下文快满的提示按会话关一次；切会话重新计算。
    @State private var contextWarningDismissed = false

    /// 用户拖出来的对话列宽。默认 744（Splash 的 680pt 内容列 + 两侧 32pt），
    /// 也是最小宽度：不拖的时候版式和 Splash 一致，列宽变了正文、气泡、输入卡
    /// 一起跟着变。
    @AppStorage("chat.columnWidth") private var storedColumnWidth: Double =
        Double(ChatColumn.defaultWidth)
    /// 页面量到的可用宽度：决定列最宽能撑到哪里、拖柄骑在哪条边上。
    @State private var pageWidth: CGFloat = 0
    /// 拖动过程中的实时列宽。落盘放到松手时，拖一次只写一次 UserDefaults。
    @State private var liveColumnWidth: CGFloat?
    /// 一次拖动开始时的列宽。列是居中的，边缘每挪 1pt 宽度要变 2pt。
    @State private var columnDragOrigin: CGFloat?
    /// 拖柄的 hover 状态：竖条变宽、染上强调色。
    @State private var hoveringColumnHandle = false
    /// 拖柄是否已经压上左右箭头光标，pop 必须和 push 成对。
    @State private var columnCursorPushed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    init(state: AppState, chat: ChatStore) {
        self.state = state
        self.chat = chat
        _draftStore = ObservedObject(wrappedValue: state.chatDrafts)
    }

    /// 转录一次排进布局的正文上限（字符）。懒加载列表要靠估算高度定位，
    /// 而一条长回答和一条短消息差着上百倍，估算值会在几十万点之间来回跳，
    /// 底部锚点跟着它跑，切页回来就是一路快速滚动、最后停在半截或空白。
    /// 换成精确布局后整段高度是量出来的，代价是要真的排每一行：9 万字排完
    /// 要一秒多，所以按字数只留最近一段，更早的交给「加载更早」。
    static let transcriptCharacterBudget = 16_000
    /// 「加载更早」一次补多少条。每次补的也是一个布局批次，40 条大约
    /// 300ms，够快，也不至于点很多次。
    static let loadEarlierBatch = 40

    /// 按正文预算从末尾往前数，能排多少条就排多少条。最后一条不算进预算：
    /// 它再长也得显示，而且流式输出时它一直在长——算进去会让窗口每来一批
    /// 字就缩一截，读者往上翻的位置也跟着跳。
    static func budgetedMessageCount(_ messages: [ChatMessage]) -> Int {
        var characters = 0
        var count = 0
        for message in messages.reversed() {
            if count > 0 {
                characters += message.content.count + (message.reasoning?.count ?? 0)
            }
            count += 1
            if characters >= transcriptCharacterBudget { break }
        }
        return max(1, count)
    }

    // MARK: Drafts

    /// 当前会话的草稿键。`currentThreadID` 在新会话开始时就已生成，首条消息前后
    /// 不会变，所以不需要像 Splash 那样把新会话的草稿「搬运」到会话 id 上。
    private var draftKey: String { state.currentThreadID }

    private var draft: String {
        get { draftStore.drafts[draftKey]?.text ?? "" }
        nonmutating set {
            var draft = draftStore.drafts[draftKey] ?? ChatDraft()
            draft.text = newValue
            // 用户一开始改字，上一次的附件回执就收起（Splash 的 `notice` 同理）。
            draft.notice = nil
            draftStore.drafts[draftKey] = draft
        }
    }

    private func setDraftNotice(_ text: String) {
        draftStore.drafts[draftKey, default: ChatDraft()].notice = text
    }

    private var imageAttachment: ChatImageAttachment? {
        get { draftStore.drafts[draftKey]?.imageAttachment }
        nonmutating set { draftStore.drafts[draftKey, default: ChatDraft()].imageAttachment = newValue }
    }

    private var lastFrameAttachment: ChatImageAttachment? {
        get { draftStore.drafts[draftKey]?.lastFrameAttachment }
        nonmutating set { draftStore.drafts[draftKey, default: ChatDraft()].lastFrameAttachment = newValue }
    }

    private var referenceImages: [ChatImageAttachment] {
        get { draftStore.drafts[draftKey]?.referenceImages ?? [] }
        nonmutating set { draftStore.drafts[draftKey, default: ChatDraft()].referenceImages = newValue }
    }

    private var referenceClips: [VideoReferenceClip] {
        get { draftStore.drafts[draftKey]?.referenceClips ?? [] }
        nonmutating set { draftStore.drafts[draftKey, default: ChatDraft()].referenceClips = newValue }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { draft },
            set: { draft = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ChatStageView(newChat: chat.messages.isEmpty, column: columnWidth) {
                ZStack {
                    if chat.messages.isEmpty {
                        emptyState
                            .transition(.opacity)
                    } else {
                        transcript
                            .transition(.opacity)
                    }
                }
            } composer: {
                composer
                    .padding(.horizontal, ChatColumn.contentInset)
            }
            .animation(reduceMotion ? nil : Motion.settle, value: chat.messages.isEmpty)
        }
        // 页面切换时外层用 transition 重新插入视图。这里显式铺满可用空间，
        // 保证转录区拿到确定高度；否则懒加载列表可能量到 0 高度，整页只剩顶部。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 页面宽度决定对话列最宽能撑到哪里。量在根视图上而不是对话区里：
        // 输入卡与转录区两边必须读同一个数才不会一宽一窄。
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            pageWidth = width
        }
        .overlay(alignment: .trailing) {
            columnResizeHandle
                .padding(.trailing, max(6, columnEdgeInset - 11))
                // 首帧还没量到页面宽度时先不画，免得竖条先落在页面中间再跳出去。
                .opacity(pageWidth > 0 ? 1 : 0)
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
        .onChange(of: state.selectedModel) { _, _ in
            pruneIncompatibleAttachments()
        }
        .onChange(of: imageOptions) { _, newValue in
            ImageOptionsStore.save(newValue)
        }
        .onChange(of: videoOptions) { _, newValue in
            VideoOptionsStore.save(newValue)
        }
        .onChange(of: chat.messages.isEmpty) { _, empty in
            // 新会话（新建 / 清空 / 删掉当前）把光标交回输入框，和 Splash 一致。
            if empty { focusComposer() }
        }
        // 切到另一段会话时 `messages[0]` 会换；把光标交回输入框，接着写那段的草稿。
        .onChange(of: chat.messages.first?.id) { _, _ in
            focusComposer()
        }
        // 换会话：滚动视图会按新的 `currentThreadID` 重建并从底部开始。
        // 「加载更早」的批次按会话记在 `earlierBatches` 里，不用在这里复位。
        .onChange(of: state.currentThreadID) { _, _ in
            atBottom = true
            editingMessageID = nil
            contextWarningDismissed = false
        }
        .onAppear { focusComposer() }
    }

    // MARK: Column width

    /// 当前生效的对话列宽：拖动中用实时值，其余时候读落盘值再按窗口夹一次。
    /// 夹紧不等于回写——窗口缩小时列跟着收窄，窗口再放大又能回到用户拖出来的宽度。
    private var columnWidth: CGFloat {
        ChatColumn.width(
            stored: liveColumnWidth ?? CGFloat(storedColumnWidth),
            pageWidth: pageWidth)
    }

    /// 气泡最宽。默认列宽下是 592pt（Splash 的 680 列再让出 88pt），列被拖宽后
    /// 气泡按同样的增量一起放开，否则拖宽只会把消息之间推开，回答还是原来那么窄。
    private var bubbleMaxWidth: CGFloat {
        ChatColumn.bubbleWidth(column: columnWidth)
    }

    /// 列右边缘离页面右边的距离。拖柄骑在这条边上：列越宽，它越靠外。
    private var columnEdgeInset: CGFloat {
        guard pageWidth > 0 else { return ChatColumn.defaultWidth / 2 }
        return max(0, (pageWidth - columnWidth) / 2)
    }

    // MARK: Header

    private var currentThread: ChatThread? {
        chat.threads.first(where: { $0.id == state.currentThreadID })
    }

    /// 恢复启动时的旧会话可能还没进「最近对话」（旧版本按轮次存、清理过副本），
    /// 但正文已经在当前会话里。这种时候顶栏仍要显示标题，只是不挂操作菜单：
    /// 置顶 / 改名 / 删除都要求历史里有对应条目。
    private var restoredTitle: String? {
        guard !chat.messages.isEmpty else { return nil }
        if let thread = currentThread { return thread.title }
        return ChatHistory.autoTitle(messages: chat.messages)
    }

    /// 顶栏只留 Splash 那样的会话标题：标题 + 下拉箭头，悬停高亮，点开是
    /// 置顶 / 重命名 / 删除。标题左侧常驻「对话历史」，点开就是最近对话的
    /// 搜索与分组列表；右侧常驻「新对话」。边栏收起、页面铺满窗口时不用把
    /// 边栏叫回来也能换会话、开新对话；边栏展开时这两颗按钮只是同一条捷径。
    private var header: some View {
        HStack(spacing: 8) {
            ChatHistoryButton(state: state, chat: chat)
            if let thread = currentThread, !chat.messages.isEmpty {
                ChatTitleMenu(state: state, thread: thread)
            } else if let title = restoredTitle {
                Text(title)
                    .font(DS.Font.prose(15, weight: .medium))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)

            DSIconButton(systemName: "square.and.pencil", help: "新对话", size: 26) {
                state.newConversation()
                state.section = .chat
            }
        }
        .padding(.leading, Console.topBarLeading(sidebarShown: state.showsSidebar, base: DS.Space.lg))
        .padding(.trailing, DS.Space.lg)
        .frame(height: DS.Layout.titlebarHeight)
        .padding(.top, Console.pageTopPadding)
        .background(WindowDragArea())
    }

    // MARK: Transcript

    /// 这次要排进布局的条数：预算窗口 + 这一段会话已经点开的批次。
    private var windowCount: Int {
        Self.budgetedMessageCount(chat.messages) + (earlierBatches[state.currentThreadID] ?? 0)
    }

    private var visibleMessages: [ChatMessage] {
        guard chat.messages.count > windowCount else { return chat.messages }
        return Array(chat.messages.suffix(windowCount))
    }

    private var streamingScrollKey: String {
        guard let last = chat.messages.last else { return "" }
        return
            "\(last.id.uuidString)-\(last.content.count)-\(last.reasoning?.count ?? 0)-\(last.imagePaths.count)-\(last.videoPath ?? "")-\(last.toolStage ?? "")-\(last.streaming)"
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if chat.messages.count > visibleMessages.count {
                        Button {
                            let anchor = visibleMessages.first?.id
                            earlierBatches[state.currentThreadID, default: 0] += Self.loadEarlierBatch
                            if let anchor {
                                DispatchQueue.main.async {
                                    proxy.scrollTo(anchor, anchor: .top)
                                }
                            }
                        } label: {
                            Label(
                                L10n.format(
                                    "加载更早的 %lld 条",
                                    Int64(min(Self.loadEarlierBatch, chat.messages.count - visibleMessages.count))),
                                systemImage: "arrow.up")
                        }
                        .buttonStyle(.ds(.ghost, size: .small))
                        .frame(maxWidth: .infinity)
                    }

                    ForEach(visibleMessages) { message in
                        messageRow(message)
                    }

                    // 底部哨兵：没有额外留白，输入卡在布局里自己占位。
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, ChatColumn.contentInset)
                .padding(.top, 28)
                // 输入卡是浮层，底部多留一段，最后一行不会贴到卡的阴影上。
                .padding(.bottom, 44)
                .animation(reduceMotion ? nil : Motion.entrance, value: chat.messages.count)
            }
            .scrollIndicators(.never)
            // 底部锚点兼两件事：首次布局直接按底部落位，内容长高时把底部锚在
            // 视口底部。落位不交给 `scrollTo`：它依赖列表此刻量出来的高度，
            // 切页回来时窗口外的行还没量，算出的偏移会落在内容中段，甚至落到
            // 内容之外（整块空白）。锚点不会跟用户抢滚动：往上翻时它只是保持
            // 偏移，人自己滚回底部后又自动接管。
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onScrollPhaseChange { _, newPhase in
                userScrolling = (newPhase == .interacting || newPhase == .tracking || newPhase == .decelerating)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height <= geometry.containerSize.height
                    || geometry.contentOffset.y + geometry.containerSize.height
                        >= geometry.contentSize.height - 40
            } action: { _, bottom in
                if bottom {
                    if !atBottom { withAnimation(reduceMotion ? nil : Motion.quick) { atBottom = true } }
                } else if !chat.generating || userScrolling {
                    // 生成过程中内容撑高不应误判成用户上翻；只有非生成态或
                    // 用户真的在滚动时，才退出「跟随底部」。
                    if atBottom { withAnimation(reduceMotion ? nil : Motion.quick) { atBottom = false } }
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { oldHeight, newHeight in
                guard chat.generating, atBottom, oldHeight > 0, newHeight > oldHeight + 1 else { return }
                DispatchQueue.main.async {
                    scroll(proxy, animated: false)
                }
            }
            .onChange(of: streamingScrollKey) { _, _ in
                guard chat.generating, atBottom else { return }
                DispatchQueue.main.async {
                    scroll(proxy, animated: false)
                }
            }
            .onChange(of: chat.messages.count) { _, count in
                // 同一段对话里追加 / 清空：等这一帧布局完成再定位，
                // 否则会滚到尚不存在的旧位置。换会话不经过这里——滚动视图
                // 随 `currentThreadID` 重建，初始锚点已经落到底部。
                DispatchQueue.main.async {
                    if count == 0 {
                        atBottom = true
                        proxy.scrollTo("top", anchor: .top)
                    } else {
                        restoreBottom(proxy, animated: true)
                    }
                }
            }
            .onChange(of: chat.generating) { _, generating in
                if !generating, atBottom {
                    DispatchQueue.main.async {
                        scroll(proxy, animated: false)
                    }
                }
            }
            // 换一段对话就换一个滚动视图：新视图按 `initialOffset` 重新落到
            // 底部，不用 `scrollTo` 猜位置（猜出来的位置会停在内容中段）。
            // 上面的滚动回调都挂在这个 id 里面，换会话时随旧视图退场，只对
            // 同一段对话里的增删生效。
            .id(state.currentThreadID)
            .overlay(alignment: .bottom) {
                if !atBottom {
                    LatestScrollButton {
                        scroll(proxy, animated: true, force: true)
                    }
                    .padding(.bottom, 20)
                    .transition(.opacity.animation(reduceMotion ? nil : Motion.quick))
                }
            }
        }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        MessageRow(
            message: message,
            modelName: message.model.map(state.shortModelName)
                ?? state.activeEngine.displayName,
            startupStage: chat.chatStartupStage,
            maxBubbleWidth: bubbleMaxWidth,
            isLast: message.id == chat.messages.last?.id,
            canRegenerate: !supportsVideo && !chat.generating,
            onEdit: { requestEdit(message) },
            onBranch: { state.branchThread(from: message.id) }
        ) {
            state.regenerate()
        }
        .equatable()
        .id(message.id)
        .transition(.opacity)
    }

    // MARK: Editing

    private var editConfirmationShown: Binding<Bool> {
        Binding(
            get: { pendingEditMessage != nil },
            set: { if !$0 { pendingEditMessage = nil } })
    }

    private func laterMessageCount(for message: ChatMessage) -> Int {
        guard let index = chat.messages.firstIndex(where: { $0.id == message.id }) else {
            return 0
        }
        return max(0, chat.messages.count - index - 1)
    }

    private func requestEdit(_ message: ChatMessage) {
        guard !chat.generating, message.role == "user" else { return }
        if laterMessageCount(for: message) > 0 {
            pendingEditMessage = message
        } else {
            startEditing(message)
        }
    }

    private func startEditing(_ message: ChatMessage) {
        editingMessageID = message.id
        draft = message.content
        composerFocused = true
    }

    private func cancelEditing() {
        editingMessageID = nil
        draft = ""
        focusComposer()
    }

    /// 接近上下文上限时在输入卡上方提示；按会话关一次，切走再回来会重新判断。
    private var contextWarning: some View {
        Group {
            if let ratio = contextUsageRatio, ratio >= 0.8, !contextWarningDismissed {
                HStack(spacing: 8) {
                    Image(systemName: ratio >= 0.95 ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ratio >= 0.95 ? DS.warn : DS.text2)
                    Text(
                        L10n.format(
                            "上下文已用 %lld%%，再长就会顶到窗口上限。",
                            Int64((ratio * 100).rounded())))
                        .font(DS.Font.prose(11.5))
                        .foregroundStyle(DS.text2)
                    Spacer(minLength: 6)
                    Button(L10n.t("新建对话")) {
                        state.newConversation()
                    }
                    .buttonStyle(.ds(.secondary, size: .small))
                    Button {
                        contextWarningDismissed = true
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.text3)
                    .accessibilityLabel(L10n.t("关闭通知"))
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(DS.rect(DS.Radius.sm).fill(DS.raised))
                .overlay(DS.rect(DS.Radius.sm).strokeBorder(DS.line, lineWidth: 1))
            }
        }
    }

    private var contextUsageRatio: Double? {
        guard let ceiling = state.contextWindowCeiling, ceiling > 0 else { return nil }
        let used = state.contextUsedTokens
        guard used > 0 else { return nil }
        return min(1.5, Double(used) / Double(ceiling))
    }

    /// 把对话区落到底部。首次布局只量到一部分高度时，稍后再补一次，
    /// 让超大回答（长代码块）也停在最后一条上；读者自己往上翻时不抢位置。
    private func restoreBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !chat.messages.isEmpty else {
            atBottom = true
            return
        }
        scroll(proxy, animated: false, force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard atBottom else { return }
            scroll(proxy, animated: false, force: true)
        }
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard atBottom else { return }
                scroll(proxy, animated: false, force: true)
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool, force: Bool = false) {
        guard force || atBottom else { return }
        if animated, !reduceMotion {
            withAnimation(Motion.glide) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
        atBottom = true
    }

    // MARK: Empty

    /// 新会话只留品牌标记与一行状态，不再摆快捷提示卡——Splash 的空态就是
    /// 这样，让输入卡成为页面唯一的动作入口。
    private var emptyState: some View {
        VStack(spacing: 0) {
            BrandMark(size: 44)
            Text(emptyStatusNote)
                .font(DS.Font.prose(13))
                .foregroundStyle(DS.text3)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 32)
                .frame(height: 28)
        }
    }

    private var emptyStatusNote: String {
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

    // MARK: Column resize handle

    /// 对话列右边那条可以拖的竖条：平时隐藏，悬停或拖动时柔和浮现。
    private var columnResizeHandle: some View {
        let active = hoveringColumnHandle || liveColumnWidth != nil
        return Capsule(style: .continuous)
            .fill(active ? Console.accent.opacity(0.65) : Console.tertiary.opacity(0.30))
            .frame(width: active ? 4 : 3, height: active ? 44 : 30)
            .opacity(active ? 1 : 0)
            // 命中区域比竖条宽得多，不用瞄准 3pt。
            .frame(width: 22, height: 96)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hoveringColumnHandle else { return }
                withAnimation(reduceMotion ? nil : Motion.quick) { hoveringColumnHandle = inside }
                updateColumnCursor()
            }
            .gesture(columnResizeGesture)
            .onTapGesture(count: 2) { resetColumnWidth() }
            .help("拖动调节对话宽度，双击回到默认")
            .accessibilityLabel("调节对话宽度")
            .onDisappear {
                hoveringColumnHandle = false
                pushColumnCursor(false)
            }
    }

    private var columnResizeGesture: some Gesture {
        // 位移必须用 `.global`：竖条自己也在跟着拖动跑，局部坐标会越拖越偏。
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if columnDragOrigin == nil {
                    columnDragOrigin = columnWidth
                    pushColumnCursor(true)
                }
                guard let origin = columnDragOrigin else { return }
                liveColumnWidth = ChatColumn.width(
                    stored: origin + value.translation.width * 2,
                    pageWidth: pageWidth)
            }
            .onEnded { _ in commitColumnWidth() }
    }

    /// 松手才落盘：拖动过程中只改 `liveColumnWidth`，不会每一帧都写一次
    /// UserDefaults，也不会有半截宽度被存下来。
    private func commitColumnWidth() {
        if let width = liveColumnWidth { storedColumnWidth = Double(width) }
        liveColumnWidth = nil
        columnDragOrigin = nil
        updateColumnCursor()
    }

    private func resetColumnWidth() {
        withAnimation(reduceMotion ? nil : Motion.standard) {
            storedColumnWidth = Double(ChatColumn.defaultWidth)
            liveColumnWidth = nil
        }
        columnDragOrigin = nil
    }

    private func updateColumnCursor() {
        pushColumnCursor(hoveringColumnHandle || columnDragOrigin != nil)
    }

    /// 左右箭头光标按栈压入 / 弹出。视图消失时必须弹掉，否则光标会一直
    /// 停在缩放态。`push` / `pop` 严格成对。
    private func pushColumnCursor(_ on: Bool) {
        if on, !columnCursorPushed {
            NSCursor.resizeLeftRight.push()
            columnCursorPushed = true
        } else if !on, columnCursorPushed {
            NSCursor.pop()
            columnCursorPushed = false
        }
    }

    // MARK: Composer

    /// 未聚焦且草稿为空时只留一行高度；光标进来或已有内容才长到可写多行。
    /// 卡片因此是「安静时矮、要写字时高」，而不是一直占着一块空白。
    private var composerFieldHeight: CGFloat {
        if composerFocused || !draft.isEmpty || hasAttachedMedia { return 40 }
        return 22
    }

    private var editBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .font(.system(size: 10.5, weight: .semibold))
            Text(L10n.t("正在编辑这条消息，发送后重跑这一轮"))
                .font(DS.Font.prose(11.5))
            Spacer(minLength: 6)
            Button(L10n.t("取消")) { cancelEditing() }
                .buttonStyle(.dsGhost)
                .font(DS.Font.prose(11.5, weight: .medium))
        }
        .foregroundStyle(DS.text2)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(DS.rect(DS.Radius.sm).fill(DS.hover))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editingMessageID != nil {
                editBanner
            }
            contextWarning

            if let notice = draftStore.drafts[draftKey]?.notice, !notice.isEmpty {
                // 和 Splash 的回执一样：警告图标 + 一句说明，压在输入文字上方。
                Label {
                    Text(notice).foregroundStyle(DS.text2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                .font(.system(size: 12))
                .lineLimit(2)
            }

            if supportsVideo {
                if supportsVideoReferences {
                    referenceInputStrip
                } else {
                    // 首尾帧两个槽位一直摆着：让「可以附两张图」在界面上看得见。
                    videoFramesStrip
                }
            } else if let imageAttachment {
                attachmentStrip(imageAttachment)
            }

            // 自绘输入框：回车发送、⇧回车换行，Escape 停止生成（见 `ChatComposerField`）。
            ZStack(alignment: .topLeading) {
                ChatComposerField(
                    text: textBinding,
                    isFocused: $composerFocused,
                    isEnabled: true,
                    conversation: draftKey,
                    onSend: send,
                    onCancel: {
                        guard chat.generating else { return false }
                        state.cancelGeneration()
                        return true
                    },
                    onDropImage: { url in
                        guard supportsMedia else { return false }
                        if supportsVideoReferences,
                            Self.videoExtensions.contains(url.pathExtension.lowercased())
                        {
                            let attached = attachReferenceClip(at: url)
                            if attached { composerFocused = true }
                            return attached
                        }
                        attachImage(at: url)
                        composerFocused = true
                        return true
                    },
                    onPasteImage: { image in
                        attachPastedImage(image)
                    },
                    onDragTargetChange: { targeted in
                        withAnimation(reduceMotion ? nil : Motion.quick) {
                            isDropTargeted = targeted && supportsMedia
                        }
                    },
                    acceptsImageDrop: supportsMedia,
                    acceptsVideoDrop: supportsVideoReferences
                )
                // 光标进来就收起占位提示：聚焦后留着会和插入点抢位置，看起来像
                // 输入框里一直有字。清空草稿但还停在输入框里时同样不再显示。
                if draft.isEmpty && !composerFocused {
                    Text(L10n.t(composerPlaceholder))
                        .font(DS.Font.prose(ChatComposerField.fontSize))
                        .foregroundStyle(DS.text4)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: composerFieldHeight, alignment: .topLeading)
            .animation(reduceMotion ? nil : Motion.quick, value: composerFieldHeight)

            HStack(spacing: 4) {
                // 图像模型没有采样参数：同一个按钮换成图像设置，别再弹文本模型的
                // 温度/系统提示面板。
                ComposerIconButton(
                    systemName: supportsVideo
                        ? "video"
                        : (supportsImage ? "wand.and.stars" : "slider.horizontal.3"),
                    help: supportsVideo ? "视频参数" : (supportsImage ? "图像参数" : "生成参数")
                ) {
                    if supportsMedia {
                        showsImageOptions = true
                    } else {
                        showsParameters = true
                    }
                }
                .popover(isPresented: $showsImageOptions, arrowEdge: .top) {
                    if supportsVideo {
                        VideoOptionsPopover(
                            options: $videoOptions,
                            hasSource: imageAttachment != nil
                                || lastFrameAttachment != nil,
                            supportsReferences: supportsVideoReferences,
                            referenceCount: referenceImages.count
                                + referenceClips.count)
                    } else {
                        ImageOptionsPopover(
                            options: $imageOptions,
                            model: state.activeModel,
                            hasSource: imageAttachment != nil,
                            lastSeed: lastImageSeed)
                    }
                }

                // 文本模型的「画」开关：开着就把画图工具挂进请求，模型自己决定
                // 画几张、写什么分镜。默认开，关掉后模型只写字。
                if state.supportsImageTool {
                    ComposerIconButton(
                        systemName: state.imageToolEnabled
                            ? "paintbrush.pointed.fill" : "paintbrush.pointed",
                        help: state.imageToolEnabled
                            ? "模型可以直接画图（点一下关掉）"
                            : "打开后模型可以在这轮对话里直接画图",
                        active: state.imageToolEnabled
                    ) {
                        state.imageToolEnabled.toggle()
                    }
                }

                // 画图工具单独留一个模型选择器，只在「画」开着时出现。
                if state.imageToolActive, !state.imageToolModels.isEmpty {
                    DSMenu(size: .small) {
                        DSMenuTriggerLabel(
                            title: state.imageToolModel.map { state.shortModelName($0.id) } ?? "画图模型",
                            systemImage: "photo",
                            imageTint: DS.accent,
                            size: .small
                        )
                    } content: {
                        ForEach(state.imageToolModels) { model in
                            Button {
                                state.imageToolModelID = model.id
                            } label: {
                                if model.id == state.imageToolModel?.id {
                                    Label(state.shortModelName(model.id), systemImage: "checkmark")
                                } else {
                                    Text(state.shortModelName(model.id))
                                }
                            }
                        }
                    }
                    .disabled(chat.generating)
                    .help("模型画图时用哪个图像模型")
                }

                if supportsMedia {
                    ComposerIconButton(
                        systemName: "photo.badge.plus",
                        help: supportsVideoReferences
                            ? "添加参考图（最多 9 张）"
                            : (supportsVideo ? "添加首帧或尾帧" : "附上一张图片作重绘底图"),
                        active: hasAttachedMedia
                    ) {
                        if supportsVideoReferences {
                            pickReferenceImage()
                        } else {
                            pickImage(for: nil)
                        }
                    }
                }

                if supportsVideoReferences {
                    ComposerIconButton(
                        systemName: "video.badge.plus",
                        help: "添加参考视频（最多 3 段，每段至少 5 帧）",
                        active: !referenceClips.isEmpty
                    ) {
                        pickReferenceClip()
                    }
                }

                ChatModelControl(state: state, chat: chat)

                Spacer(minLength: 12)

                if !supportsMedia {
                    ChatContextRing(
                        used: state.contextUsedTokens,
                        ceiling: state.contextWindowCeiling)
                }

                sendStopButton
            }
            // 第一个控件的字形与正文左缘对齐。
            .padding(.leading, -6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            DS.rect(22)
                .fill(colorScheme == .dark ? DS.raised : DS.surface)
        }
        .overlay {
            DS.rect(22).strokeBorder(DS.line, lineWidth: 1)
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.06),
            radius: 14, y: 4)
        .contentShape(DS.rect(22))
        .onTapGesture { focusComposer() }
        .overlay {
            if isDropTargeted {
                DS.rect(22)
                    .strokeBorder(DS.accent.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(DS.rect(22).fill(DS.accentSoft))
                    .overlay(alignment: .topTrailing) {
                        Label(
                            supportsVideoReferences
                                ? "松开添加参考图或参考视频"
                                : (supportsVideo ? "松开添加视频首帧或尾帧" : "松开作为重绘底图"),
                            systemImage: "photo.badge.arrow.down"
                        )
                        .font(DS.Font.xs.weight(.medium))
                        .foregroundStyle(DS.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(DS.rect(DS.Radius.md).fill(DS.raised))
                        .overlay(DS.rect(DS.Radius.md).strokeBorder(DS.line2, lineWidth: 1))
                        .padding(10)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard supportsMedia else { return false }
            if supportsVideoReferences,
                let clip = urls.first(where: { Self.videoExtensions.contains($0.pathExtension.lowercased()) })
            {
                guard attachReferenceClip(at: clip) else { return false }
                composerFocused = true
                return true
            }
            guard let url = urls.first(where: { Self.imageExtensions.contains($0.pathExtension.lowercased()) })
            else { return false }
            attachImage(at: url)
            composerFocused = true
            return true
        } isTargeted: { targeted in
            withAnimation(reduceMotion ? nil : DS.Motion.snappy) {
                isDropTargeted = targeted && supportsMedia
            }
        }
    }

    /// Splash 的发送键：一个实心圆，能发时用强调色，不能发时退成灰底；
    /// 生成中原地变成停止键。
    private var sendStopButton: some View {
        let streaming = chat.generating
        let enabled = streaming || canSend
        return Button {
            if streaming {
                state.cancelGeneration()
            } else {
                send()
            }
        } label: {
            Image(systemName: streaming ? "stop.fill" : "arrow.up")
                .font(
                    .system(
                        size: streaming ? 9.5 : 12.5,
                        weight: streaming ? .bold : .semibold))
                .foregroundStyle(enabled ? Color.white : DS.text3)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(enabled ? DS.accent : DS.hover))
                .contentShape(Circle())
        }
        .buttonStyle(.plainHit)
        .disabled(!enabled)
        .help(streaming ? "停止生成 (Esc)" : "发送（回车）· ⇧回车换行")
        .accessibilityLabel(streaming ? L10n.t("停止生成") : L10n.t("发送"))
    }

    private var supportsImage: Bool { state.activeModelSupportsImage }
    private var supportsVideo: Bool { state.activeModelSupportsVideo }
    private var supportsVideoReferences: Bool { state.activeModelSupportsVideoReferences }
    private var supportsMedia: Bool { supportsImage || supportsVideo }

    private var composerPlaceholder: String {
        if supportsVideoReferences { return "描述想生成的视频内容，或拖入参考图 / 视频…" }
        if supportsVideo { return "描述想生成的视频画面，可附首帧 / 尾帧…" }
        if supportsImage { return "描述想生成的画面，或拖入底图重绘…" }
        return "给 FlashCat 发消息"
    }

    /// 切换模型后清理不兼容的媒体附件，并收起旧模型的参数浮层。
    private func pruneIncompatibleAttachments() {
        if !supportsMedia {
            imageAttachment = nil
            lastFrameAttachment = nil
            referenceImages = []
            referenceClips = []
            showsImageOptions = false
        } else if supportsImage && !supportsVideo {
            lastFrameAttachment = nil
            referenceImages = []
            referenceClips = []
        } else if supportsVideo && !supportsVideoReferences {
            referenceImages = []
            referenceClips = []
        } else if supportsVideoReferences {
            imageAttachment = nil
            lastFrameAttachment = nil
        }
    }

    /// REF2VA 的参考素材是否已经挂上至少一个。
    private var hasReferenceMedia: Bool {
        !referenceImages.isEmpty || !referenceClips.isEmpty
    }

    /// 有没有挂上要跟这一轮一起发出去的素材：图像看底图，REF2VA 看参考素材，
    /// 普通视频模型看首帧或尾帧。
    private var hasAttachedMedia: Bool {
        if supportsVideoReferences { return hasReferenceMedia }
        return imageAttachment != nil || (supportsVideo && lastFrameAttachment != nil)
    }

    private var canSend: Bool {
        guard !chat.generating else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // REF2VA 必须至少有一个参考素材；文字可以后补，素材不能空。
        if supportsVideoReferences { return hasReferenceMedia }
        if supportsMedia { return hasText || hasAttachedMedia }
        return hasText
    }

    /// 点输入卡的留白也把光标交给输入框；生成中也可以继续写下一句。
    private func focusComposer() {
        composerFocused = true
    }

    private func send() {
        guard !chat.generating else { return }
        guard !state.needsEngineSetup else {
            setDraftNotice(L10n.t("还没有安装推理引擎，请先在启动页选择一个"))
            return
        }
        guard !state.selectedModel.isEmpty else {
            setDraftNotice(L10n.t("还没有选择模型"))
            return
        }
        // 编辑模式：发送键改为「保存并重发」，由 runner 截断后续回答再跑一轮。
        if let messageID = editingMessageID {
            let edited = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !edited.isEmpty else { return }
            draft = ""
            editingMessageID = nil
            state.editAndResend(messageID: messageID, text: edited)
            return
        }
        draftStore.drafts[draftKey]?.notice = nil
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if supportsVideo {
            // 只给首帧或尾帧也可以：引擎要求 prompt 非空，给它一句保守的运动描述。
            guard !text.isEmpty || hasAttachedMedia else { return }
            if supportsVideoReferences {
                // REF2VA 从参考素材生成新视频，不接受首尾帧；至少一个 ref 才能发。
                guard hasReferenceMedia else {
                    setDraftNotice("REF2VA 需要至少一张参考图或一段参考视频。")
                    return
                }
                let prompt = text.isEmpty ? "根据参考素材生成一段连贯的视频" : text
                let images = referenceImages
                let clips = referenceClips
                draft = ""
                imageAttachment = nil
                lastFrameAttachment = nil
                referenceImages = []
                referenceClips = []
                state.send(
                    prompt, referenceImages: images, referenceClips: clips,
                    video: videoOptions)
                return
            }
            let prompt = text.isEmpty ? "让画面自然地动起来" : text
            draft = ""
            let first = imageAttachment
            let last = lastFrameAttachment
            imageAttachment = nil
            lastFrameAttachment = nil
            state.send(prompt, attachment: first, lastFrame: last, video: videoOptions)
            return
        }
        if supportsImage {
            // 只挂图不写提示词也可以：引擎要求 prompt 非空，给它一句保底描述。
            guard !text.isEmpty || imageAttachment != nil else { return }
            let prompt = text.isEmpty ? "保持构图，重绘细节" : text
            draft = ""
            let attachment = imageAttachment
            imageAttachment = nil
            state.send(prompt, attachment: attachment, image: imageOptions)
            return
        }
        guard !text.isEmpty else { return }
        draft = ""
        state.send(text)
    }

    /// 最近一张图用的 seed：参数面板里给一个「用上次」的快捷入口。
    private var lastImageSeed: Int? {
        chat.messages.last(where: { $0.imageSeed != nil })?.imageSeed
    }

    private func pickImage(for slot: VideoFrameSlot?) {
        let panel = NSOpenPanel()
        panel.title = slot.map { "选择视频\($0.rawValue)" } ?? "选择一张图片"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attachImage(at: url, slot: slot)
    }

    /// REF2VA 的参考图一次可以挑多张；上限按服务端的 9 图 / 3 视频 / 12 总数。
    private func pickReferenceImage() {
        let panel = NSOpenPanel()
        panel.title = "选择参考图"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            attachReferenceImage(at: url)
        }
        composerFocused = true
    }

    private func attachReferenceImage(at url: URL) {
        guard supportsVideoReferences else { return }
        guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return }
        guard referenceImages.count < 9 else {
            setDraftNotice("参考图最多 9 张。")
            return
        }
        guard referenceImages.count + referenceClips.count < 12 else {
            setDraftNotice("参考素材最多 12 个（9 张图 + 3 段视频）。")
            return
        }
        guard !referenceImages.contains(where: { $0.path == url.path }) else { return }
        referenceImages.append(
            ChatImageAttachment(
                path: url.path,
                name: url.lastPathComponent,
                pixelSize: ImageStore.pixelSize(atPath: url.path)))
    }

    /// 选参考视频。面板一次最多挑三段，读头放到后台，缩略图出来后再进列表。
    private func pickReferenceClip() {
        let panel = NSOpenPanel()
        panel.title = "选择参考视频"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            addReferenceClip(url)
        }
    }

    /// 面板与拖拽共用。读头失败或超出上限都写在输入卡上方，不打断当前输入。
    private func addReferenceClip(_ url: URL) {
        guard supportsVideoReferences else { return }
        guard Self.videoExtensions.contains(url.pathExtension.lowercased()) else { return }
        Task {
            do {
                let meta = try await VideoReferenceExtractor.metadata(url: url)
                guard supportsVideoReferences else { return }
                guard !referenceClips.contains(where: { $0.path == url.path }) else { return }
                guard referenceClips.count < 3 else {
                    setDraftNotice("参考视频最多 3 段。")
                    return
                }
                guard referenceImages.count + referenceClips.count < 12 else {
                    setDraftNotice("参考素材最多 12 个（9 张图 + 3 段视频）。")
                    return
                }
                referenceClips.append(
                    VideoReferenceClip(
                        path: url.path,
                        name: url.lastPathComponent,
                        duration: meta.duration,
                        pixelSize: meta.pixelSize,
                        posterJPEG: meta.posterJPEG))
                composerFocused = true
            } catch {
                setDraftNotice(error.localizedDescription)
            }
        }
    }

    /// 拖拽入口要同步返回能不能接；真正的读头交给 `addReferenceClip`。
    @discardableResult
    private func attachReferenceClip(at url: URL) -> Bool {
        guard supportsVideoReferences,
            Self.videoExtensions.contains(url.pathExtension.lowercased())
        else { return false }
        guard referenceClips.count < 3 else {
            setDraftNotice("参考视频最多 3 段。")
            return false
        }
        addReferenceClip(url)
        return true
    }

    /// Finder 拖入与面板选择共用一条入口：记路径、名字和像素尺寸，
    /// 发送时才把文件拷进作品目录。
    /// ⌘V 粘贴剪贴板图片：落成文件后走和拖拽相同的附件路径。临时文件放在
    /// 支持目录而不是系统 temp，发送前不会因为系统清理而丢。
    private func attachPastedImage(_ image: NSImage) -> Bool {
        guard supportsMedia,
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return false }
        let directory = Paths.supportDirectory + "/pasted-images"
        Paths.ensureDirectory(directory)
        let url = URL(fileURLWithPath: directory)
            .appendingPathComponent("paste-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
        } catch {
            return false
        }
        attachImage(at: url)
        composerFocused = true
        return true
    }

    private func attachImage(at url: URL, slot: VideoFrameSlot? = nil) {        if supportsVideoReferences {
            attachReferenceImage(at: url)
            return
        }
        let attachment = ChatImageAttachment(
            path: url.path,
            name: url.lastPathComponent,
            pixelSize: ImageStore.pixelSize(atPath: url.path))
        guard supportsVideo else {
            imageAttachment = attachment
            return
        }
        switch slot {
        case .first?:
            imageAttachment = attachment
        case .last?:
            lastFrameAttachment = attachment
        default:
            // 没有指定槽位（拖拽、工具条上的图片按钮）就按首帧、尾帧的顺序填空。
            if imageAttachment == nil {
                imageAttachment = attachment
            } else if lastFrameAttachment == nil {
                lastFrameAttachment = attachment
            } else {
                imageAttachment = attachment
            }
        }
    }

    /// 视频模型的首帧 / 尾帧槽位。两个都空时也显示，让「可以附两张图」
    /// 在输入卡上看得见，而不是藏进参数面板。
    private enum VideoFrameSlot: String {
        case first = "首帧"
        case last = "尾帧"
    }

    private var videoFramesStrip: some View {
        HStack(spacing: 8) {
            videoFrameSlot(.first, attachment: imageAttachment)
            videoFrameSlot(.last, attachment: lastFrameAttachment)
        }
    }

    private func videoFrameSlot(
        _ slot: VideoFrameSlot,
        attachment: ChatImageAttachment?
    ) -> some View {
        HStack(spacing: 7) {
            Button {
                pickImage(for: slot)
            } label: {
                Group {
                    if let attachment {
                        AsyncChatThumbnail(path: attachment.path, maxPixel: 96) {
                            Color.clear
                        } missingView: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DS.text3)
                        }
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DS.text3)
                    }
                }
                .frame(width: 34, height: 34)
                .background {
                    DS.rect(DS.Radius.sm)
                        .fill(DS.bg)
                }
                .clipShape(DS.rect(DS.Radius.sm))
                .overlay {
                    DS.rect(DS.Radius.sm)
                        .strokeBorder(DS.line, lineWidth: 1)
                }
                .contentShape(DS.rect(DS.Radius.sm))
            }
            .buttonStyle(.plainHit)
            .help(L10n.format("选择视频%@", L10n.t(slot.rawValue)))

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t(slot.rawValue))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(DS.text2)
                Text(attachment?.name ?? L10n.t("点击选择"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(attachment == nil ? DS.text3 : DS.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if attachment != nil {
                Button {
                    if slot == .first {
                        imageAttachment = nil
                    } else {
                        lastFrameAttachment = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.text3)
                        .contentShape(Circle())
                }
                .buttonStyle(.plainHit)
                .help("移除\(slot.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            DS.rect(DS.Radius.md).fill(DS.bg)
        }
        .overlay {
            DS.rect(DS.Radius.md).strokeBorder(DS.line, lineWidth: 1)
        }
    }

    /// REF2VA 的素材区。参考图与参考视频都摆在同一行横向滚动里；
    /// 一个都没挂时也保留入口与一句说明，避免用户以为只能写文字。
    private var referenceInputStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("参考素材")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DS.text2)
                Text("\(referenceImages.count)/9 图 · \(referenceClips.count)/3 视频")
                    .font(DS.Font.mono(10))
                    .foregroundStyle(DS.text3)
                    .monospacedDigit()
                Spacer(minLength: 0)
                referenceAddButton("参考图", systemImage: "photo.badge.plus") {
                    pickReferenceImage()
                }
                referenceAddButton("参考视频", systemImage: "video.badge.plus") {
                    pickReferenceClip()
                }
            }

            if referenceImages.isEmpty && referenceClips.isEmpty {
                Text("REF2VA 从参考素材生成新视频：至少附一张图或一段视频，不再使用首帧/尾帧。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(referenceImages) { attachment in
                            referenceImageTile(attachment)
                        }
                        ForEach(referenceClips) { clip in
                            referenceClipTile(clip)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            DS.rect(DS.Radius.md)
                .fill(DS.bg)
        }
        .overlay {
            DS.rect(DS.Radius.md)
                .strokeBorder(DS.line, lineWidth: 1)
        }
    }

    private func referenceAddButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.ds(.secondary, size: .small))
    }

    private func referenceImageTile(_ attachment: ChatImageAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            AsyncChatThumbnail(path: attachment.path, maxPixel: 96) {
                DS.bg
            } missingView: {
                Image(systemName: "photo")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.text3)
            }
            .frame(width: 44, height: 44)
            .background(DS.bg)
            .clipShape(DS.rect(DS.Radius.sm))
            .overlay {
                DS.rect(DS.Radius.sm)
                    .strokeBorder(DS.line, lineWidth: 1)
            }

            Button {
                referenceImages.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
                    .contentShape(Circle())
            }
            .buttonStyle(.plainHit)
            .offset(x: 5, y: -5)
            .help(L10n.t("移除参考图"))
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
        .help(attachment.name)
    }

    private func referenceClipTile(_ clip: VideoReferenceClip) -> some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 6) {
                Group {
                    if let data = clip.posterJPEG, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "video.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.text3)
                    }
                }
                .frame(width: 34, height: 34)
                .background(DS.bg)
                .clipShape(DS.rect(DS.Radius.sm))
                .overlay {
                    DS.rect(DS.Radius.sm)
                        .strokeBorder(DS.line, lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(clip.name)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(clip.duration.map { String(format: "%.1f 秒", $0) } ?? "视频")
                        .font(.system(size: 9))
                        .foregroundStyle(DS.text3)
                }
                .frame(maxWidth: 105, alignment: .leading)
            }
            .padding(5)
            .background {
                DS.rect(DS.Radius.md).fill(DS.bg)
            }
            .overlay {
                DS.rect(DS.Radius.md).strokeBorder(DS.line, lineWidth: 1)
            }

            Button {
                referenceClips.removeAll { $0.id == clip.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
                    .contentShape(Circle())
            }
            .buttonStyle(.plainHit)
            .offset(x: 5, y: -5)
            .help("移除参考视频")
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
        .help(clip.name)
    }

    /// 只接受图片扩展名：拖进来的可能是一整个文件夹或 PDF。
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "tif", "tiff", "bmp", "gif",
    ]

    /// 参考视频的拖拽入口。真正能不能解由 AVFoundation 读头决定。
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mpeg",
    ]

    private func attachmentStrip(_ attachment: ChatImageAttachment) -> some View {
        HStack(spacing: 10) {
            AsyncChatThumbnail(path: attachment.path, maxPixel: 96) {
                DS.bg
            } missingView: {
                Image(systemName: "photo")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.text3)
            }
            .frame(width: 46, height: 46)
            .background(DS.bg)
            .clipShape(DS.rect(DS.Radius.sm))
            .overlay {
                DS.rect(DS.Radius.sm).strokeBorder(DS.line, lineWidth: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .font(DS.Font.xs.weight(.medium))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                Text(L10n.format("重绘 · 强度 %lld%%", Int64((imageOptions.strength * 100).rounded())))
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.text3)
            }
            Spacer(minLength: 0)
            Button {
                imageAttachment = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.text3)
                    .contentShape(Circle())
            }
            .buttonStyle(.plainHit)
            .help(L10n.t("移除底图"))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            DS.rect(DS.Radius.md)
                .fill(DS.bg)
        }
        .overlay {
            DS.rect(DS.Radius.md)
                .strokeBorder(DS.line, lineWidth: 1)
        }
    }
}

/// 后台异步解码会话里的图片缩略图，并从内存缓存预填首帧，避免大 PNG/JPEG 阻塞主线程。
private struct AsyncChatThumbnail<Placeholder: View, Missing: View>: View {
    let path: String
    let maxPixel: CGFloat
    var contentMode: ContentMode = .fill
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let missingView: () -> Missing

    @State private var image: NSImage?
    @State private var missing = false

    init(
        path: String,
        maxPixel: CGFloat,
        contentMode: ContentMode = .fill,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder missingView: @escaping () -> Missing
    ) {
        self.path = path
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        self.placeholder = placeholder
        self.missingView = missingView
        _image = State(initialValue: ImageStore.cachedThumbnail(atPath: path, maxPixel: maxPixel))
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if missing {
                missingView()
            } else {
                placeholder()
            }
        }
        .task(id: path) {
            missing = false
            if let cached = ImageStore.cachedThumbnail(atPath: path, maxPixel: maxPixel) {
                image = cached
                return
            }
            image = nil
            let loaded = await ImageStore.thumbnailAsync(atPath: path, maxPixel: maxPixel)
            image = loaded
            missing = loaded == nil
        }
    }
}

// MARK: - Chat stage layout

/// 把转录区与输入卡交给 `ChatStageLayout` 的容器。两个视图放进同一个
/// `Group`，布局按 `subviews[0]` / `subviews[1]` 取用。
private struct ChatStageView<Content: View, Composer: View>: View {
    let newChat: Bool
    let column: CGFloat
    @ViewBuilder let content: Content
    @ViewBuilder let composer: Composer

    var body: some View {
        ChatStageLayout(newChat: newChat, column: column) {
            content
            composer
        }
    }
}

/// 转录区与输入卡的布局，对齐 Splash 的 `ChatColumn`：
/// - 有对话时，转录区占满输入卡上方的空间，输入卡贴在页脚上方 24pt；
/// - 新会话时，品牌标记与输入卡作为一组放在剩余空间约 1/3 处，下留 2/3。
///
/// 两种状态共用同一个输入卡视图，所以首条消息发出后它只是「移动」，不会
/// 重建——文本视图、输入法组字和光标都能原样保留。
private struct ChatStageLayout: Layout {
    let newChat: Bool
    /// 列宽（含左右 32pt 内边距）。输入卡与转录区都按这个宽度居中。
    let column: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: column, height: 600))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }
        let content = subviews[0]
        let composer = subviews[1]
        let width = min(column, bounds.width)
        let composerSize = composer.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let bottom: CGFloat = 24

        if newChat {
            let contentSize = content.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let gap: CGFloat = 20
            let group = contentSize.height + gap + composerSize.height
            let room = bounds.height - group - bottom
            let top = max(0, min(room / 3, bounds.height - bottom - group))
            content.place(
                at: CGPoint(x: bounds.midX, y: bounds.minY + top),
                anchor: .top,
                proposal: ProposedViewSize(width: width, height: contentSize.height))
            composer.place(
                at: CGPoint(x: bounds.midX, y: bounds.minY + top + contentSize.height + gap),
                anchor: .top,
                proposal: ProposedViewSize(width: width, height: composerSize.height))
        } else {
            let contentHeight = max(0, bounds.height - composerSize.height - bottom)
            content.place(
                at: CGPoint(x: bounds.midX, y: bounds.minY),
                anchor: .top,
                proposal: ProposedViewSize(width: width, height: contentHeight))
            composer.place(
                at: CGPoint(x: bounds.midX, y: bounds.maxY - bottom - composerSize.height),
                anchor: .top,
                proposal: ProposedViewSize(width: width, height: composerSize.height))
        }
    }
}

// MARK: - Chat title

/// 顶栏的会话标题：文字 + 下拉箭头，悬停高亮，点开是置顶 / 重命名 / 删除。
/// 新会话没有标题，Splash 的工具栏也是这样留白。
private struct ChatTitleMenu: View {
    @ObservedObject var state: AppState
    let thread: ChatThread
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Menu {
            Button(thread.pinned ? L10n.t("取消置顶") : L10n.t("置顶")) {
                state.setThreadPinned(thread, !thread.pinned)
            }
            Button(L10n.t("重命名…")) {
                state.requestThreadRename(thread)
            }
            Divider()
            Button(L10n.t("删除…"), role: .destructive) {
                state.requestThreadDelete(thread)
            }
        } label: {
            HStack(spacing: 5) {
                Text(thread.title.isEmpty ? L10n.t("新对话") : thread.title)
                    .font(DS.Font.prose(15, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.text3)
            }
            .foregroundStyle(DS.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DS.rect(7).fill(hovering ? DS.hover : .clear))
            .contentShape(DS.rect(7))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
        .help(L10n.t("置顶、重命名或删除这段对话"))
        .accessibilityLabel(thread.title.isEmpty ? L10n.t("新对话") : thread.title)
    }
}

// MARK: - Composer bits

/// 输入卡底排的图标按钮：Splash 的按钮是「无边框、悬停才浮出底色」，
/// 不是一枚枚描边小方块。
private struct ComposerIconButton: View {
    let systemName: String
    let help: String
    var active: Bool = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(active ? DS.accent : (hovering ? DS.text : DS.text2))
                .frame(width: 28, height: 28)
                .background(DS.rect(7).fill(hovering || active ? DS.hover : .clear))
                .contentShape(DS.rect(7))
        }
        .buttonStyle(.plainHit)
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
        .help(L10n.t(help))
        .accessibilityLabel(L10n.t(help))
    }
}

/// 上下文占用环：Splash 输入卡右下角那枚 14pt 小环，悬停给出精确数字。
private struct ChatContextRing: View {
    let used: Int
    let ceiling: Int?

    private var fraction: Double {
        guard let ceiling, ceiling > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(ceiling)))
    }

    private var tint: Color {
        if fraction >= 1 { return DS.err }
        if fraction > 0.8 { return DS.warn }
        return DS.text3
    }

    private var explanation: String {
        let usedText = Format.tokens(used)
        guard let ceiling, ceiling > 0 else {
            return L10n.format("上下文 %@ tokens", usedText)
        }
        return L10n.format(
            "上下文 %@ / %@（%.0f%%）",
            usedText,
            Format.tokensShort(ceiling),
            fraction * 100)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(DS.line2, lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
        // 环本身只有 14pt，周围留一圈命中区，悬停才容易碰到。
        .padding(5)
        .contentShape(Rectangle())
        .help(explanation)
        .accessibilityElement()
        .accessibilityLabel(L10n.t("上下文"))
        .accessibilityValue(explanation)
    }
}

/// 读者滚离底部后浮出的「回到最新」圆钮，位置与造型对齐 Splash。
private struct LatestScrollButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.text)
                .frame(width: 30, height: 30)
                .background(Circle().fill(hovering ? DS.selected : DS.raised))
                .overlay(Circle().strokeBorder(DS.line, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plainHit)
        .onHover { value in
            withAnimation(DS.Motion.snappy) { hovering = value }
        }
        .help(L10n.t("回到最新"))
        .accessibilityLabel(L10n.t("回到最新"))
    }
}

// MARK: - Message row

/// 一条消息：用户消息是右侧淡色气泡，助手消息直接铺在画布上——上方是思考行，
/// 中间是 Markdown / 图片 / 视频，下面悬停时浮出复制与重新生成。版式对齐
/// Splash 的 `transcript.js`。
private struct MessageRow: View, Equatable {
    let message: ChatMessage
    let modelName: String
    let startupStage: String?
    /// 用户气泡最宽。列宽被拖开时父视图会传更大的值。
    let maxBubbleWidth: CGFloat
    let isLast: Bool
    let canRegenerate: Bool
    let onEdit: () -> Void
    let onBranch: () -> Void
    let onRegenerate: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// nil = 跟随状态：思考流式输出、正文还没开始时自动展开；true/false = 用户手动开关。
    @State private var manualThinking: Bool?
    @State private var hoveringRow = false
    @State private var hoveringToggle = false
    @State private var copied = false
    @State private var seedCopied = false
    /// 等待行在开始后 0.5 秒才出现，快速回答不会闪一下「读取提示词」。
    @State private var waitingLineVisible = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var seedResetTask: Task<Void, Never>?

    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.modelName == rhs.modelName
            && lhs.startupStage == rhs.startupStage
            && lhs.maxBubbleWidth == rhs.maxBubbleWidth
            && lhs.isLast == rhs.isLast
            && lhs.canRegenerate == rhs.canRegenerate
    }

    private var isUser: Bool { message.role == "user" }
    private var reasoning: String { message.reasoning ?? "" }
    private var contentEmpty: Bool { message.content.isEmpty }
    private var waiting: Bool { message.streaming && contentEmpty && reasoning.isEmpty }

    private var isThinkingOpen: Bool {
        manualThinking ?? (message.streaming && contentEmpty && !reasoning.isEmpty)
    }

    private var mediaWaiting: Bool {
        message.imageProgress?.isEmpty == false
            || message.videoProgress?.isEmpty == false
            || message.toolStage?.isEmpty == false
    }

    private var showsThinkingLine: Bool {
        if message.streaming && contentEmpty {
            if !reasoning.isEmpty { return true }
            // 图像 / 视频 / 工具进度已经有自己的阶段行，别再叠一句「读取提示词」。
            if mediaWaiting { return false }
            return waitingLineVisible || startupStage?.isEmpty == false
        }
        return !reasoning.isEmpty
    }

    private var showsActions: Bool {
        // 最后一轮常显（流式期间也显示）：复制是最高频动作，不该等鼠标悬停；
        // 更早的消息仍然悬停才浮出，免得整页挂满操作行。
        hoveringRow || isLast
    }

    private var waitingKey: String {
        "\(message.streaming)-\(contentEmpty)-\(reasoning.isEmpty)-\(startupStage ?? "")"
    }

    var body: some View {
        Group {
            if isUser {
                userBody
            } else {
                assistantBody
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onHover { value in
            withAnimation(reduceMotion ? nil : Motion.quick) { hoveringRow = value }
        }
        .task(id: waitingKey) {
            guard waiting else {
                waitingLineVisible = true
                return
            }
            waitingLineVisible = false
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, waiting else { return }
            withAnimation(reduceMotion ? nil : Motion.quick) { waitingLineVisible = true }
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
            seedResetTask?.cancel()
            seedResetTask = nil
        }
    }

    // MARK: User

    private var userBubbleFill: Color {
        DS.accent.opacity(colorScheme == .dark ? 0.17 : 0.12)
    }

    private var userBody: some View {
        VStack(alignment: .trailing, spacing: 8) {
            userAttachments

            if !message.content.isEmpty {
                Text(message.content)
                    .font(DS.Font.prose(15))
                    .lineSpacing(3)
                    .foregroundStyle(DS.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8.5)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(userBubbleFill))
            }

            if !message.streaming {
                userActionsRow
                    .opacity(hoveringRow || isLast ? 1 : 0)
                    .allowsHitTesting(hoveringRow || isLast)
                    .animation(reduceMotion ? nil : Motion.quick, value: hoveringRow)
            }
        }
        .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var userActionsRow: some View {
        HStack(spacing: 2) {
            MessageActionButton(
                systemName: copied ? "checkmark" : "doc.on.doc",
                help: copied ? L10n.t("已复制") : L10n.t("复制问题"),
                tint: copied ? DS.accent : DS.text2,
                action: copyMessage)
            MessageActionButton(
                systemName: "pencil",
                help: L10n.t("编辑并重发"),
                action: onEdit)
            MessageActionButton(
                systemName: "arrow.triangle.branch",
                help: L10n.t("从这里分支"),
                action: onBranch)
        }
        .frame(height: 20)
    }

    @ViewBuilder private var userAttachments: some View {
        if hasReferences {
            referenceMessageStrip
        } else if let path = message.imagePath {
            if let last = message.videoLastFramePath {
                HStack(alignment: .top, spacing: 8) {
                    labeledThumb(path: path, label: L10n.t("首帧"), maxWidth: 120)
                    labeledThumb(path: last, label: L10n.t("尾帧"), maxWidth: 120)
                }
            } else {
                imageThumb(path: path, maxWidth: 120)
            }
        } else if let last = message.videoLastFramePath {
            labeledThumb(path: last, label: L10n.t("尾帧"), maxWidth: 120)
        }
    }

    // MARK: Assistant

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsThinkingLine {
                thinkingLine
            }

            messageBody

            if hasMediaNotes {
                mediaNotes
            }

            if !isUser, !message.streaming, showsActions || isLast {
                actionsRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var messageBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            let series =
                message.imagePaths.isEmpty
                ? (message.imagePath.map { [$0] } ?? [])
                : message.imagePaths
            if !series.isEmpty {
                imageSeries(series)
            }
            if let path = message.videoPath {
                VideoBubble(path: path)
            }

            if message.content.isEmpty {
                if message.interrupted {
                    stoppedLine
                } else if message.streaming {
                    if let stage = message.toolStage, !stage.isEmpty {
                        progressLine(stage)
                    } else if let progress = message.imageProgress, !progress.isEmpty {
                        progressLine(progress)
                    } else if let progress = message.videoProgress, !progress.isEmpty {
                        progressLine(progress)
                    }
                }
            } else {
                StreamingMarkdownView(
                    text: message.content,
                    streaming: message.streaming,
                    fillsWidth: true,
                    style: .chat)
            }
        }
    }

    private var stoppedLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "stop.circle")
                .font(.system(size: 11))
            Text(L10n.t("已停止生成"))
                .font(.system(size: 12))
        }
        .foregroundStyle(DS.text3)
    }

    private func progressLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(L10n.t(text))
                .font(.system(size: 12))
                .foregroundStyle(DS.text3)
                .lineLimit(1)
        }
    }

    // MARK: Thinking line

    private var thinkingVerb: String {
        if message.streaming && contentEmpty {
            if !reasoning.isEmpty { return L10n.t("思考中") }
            if startupStage?.isEmpty == false { return L10n.t("加载模型") }
            return L10n.t("读取提示词")
        }
        return L10n.t("思考")
    }

    private var finishedThinkingFacts: String? {
        var parts: [String] = []
        if let tokens = message.usage?.reasoningTokens, tokens > 0 {
            parts.append(L10n.format("%@ tokens", Format.tokens(tokens)))
        }
        if let seconds = message.thinkingSeconds, seconds > 0 {
            parts.append(String(format: "%.1f 秒", seconds))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var thinkingLine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !reasoning.isEmpty else { return }
                withAnimation(reduceMotion ? nil : Motion.settle) {
                    manualThinking = !isThinkingOpen
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(isThinkingOpen ? 90 : 0))
                        .opacity(reasoning.isEmpty ? 0 : 1)
                        .frame(width: 10)

                    Text(thinkingVerb)

                    if message.streaming {
                        ElapsedThinkingSeconds(since: message.createdAt ?? Date())
                    } else if let facts = finishedThinkingFacts {
                        Text("·").foregroundStyle(DS.text3)
                        Text(facts).foregroundStyle(DS.text3)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(DS.text2)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    DS.rect(7).fill(
                        hoveringToggle && !reasoning.isEmpty ? DS.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)
            .onHover { value in
                withAnimation(reduceMotion ? nil : Motion.quick) { hoveringToggle = value }
            }
            .disabled(reasoning.isEmpty)
            .help(reasoning.isEmpty ? "" : (isThinkingOpen ? L10n.t("收起思考") : L10n.t("展开思考")))
            .accessibilityLabel(thinkingVerb)
            .accessibilityValue(isThinkingOpen ? L10n.t("已展开") : L10n.t("已收起"))

            if isThinkingOpen, !reasoning.isEmpty {
                reasoningBlock
                    .transition(.opacity)
            }
        }
        .padding(.leading, -6)
        .animation(reduceMotion ? nil : Motion.settle, value: isThinkingOpen)
    }

    private var reasoningBlock: some View {
        // 模型还在想、读者也没手动打开时，只显示最新几行并淡出顶部；一旦开始
        // 回答或读者点开，就展开全文（Splash 的 `.latest` / `.thought`）。
        let latest = message.streaming && contentEmpty && manualThinking == nil
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(DS.text3.opacity(0.45))
                .frame(width: 2)

            PacedText(
                text: reasoning,
                streaming: message.streaming,
                tail: latest)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(DS.text2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: latest ? 96 : nil, alignment: .bottom)
                .clipped()
                .mask {
                    if latest {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.75), .black],
                            startPoint: .top, endPoint: .bottom)
                    } else {
                        Rectangle()
                    }
                }
        }
        .padding(.leading, 14)
        .padding(.top, 8)
    }

    // MARK: Actions

    private var detailsText: String {
        var parts: [String] = []
        if !modelName.isEmpty { parts.append(modelName) }
        if let rate = message.rateText { parts.append(rate) }
        if message.tokenCount > 0 { parts.append("\(message.tokenCount) tokens") }
        if let ttft = message.firstTokenSeconds, ttft > 0 {
            parts.append(L10n.format("首字 %.0f ms", ttft * 1000))
        }
        if message.interrupted { parts.append(L10n.t("已停止")) }
        return parts.joined(separator: " · ")
    }

    private var actionsRow: some View {
        HStack(spacing: 2) {
            if !message.content.isEmpty {
                MessageActionButton(
                    systemName: copied ? "checkmark" : "doc.on.doc",
                    help: copied ? L10n.t("已复制") : L10n.t("复制回答"),
                    tint: copied ? DS.accent : DS.text2,
                    action: copyMessage)
            }

            if isLast, canRegenerate {
                MessageActionButton(
                    systemName: "arrow.clockwise",
                    help: L10n.t("重新生成这轮回答"),
                    tint: DS.text2,
                    action: onRegenerate)
            }

            if !detailsText.isEmpty {
                Text(detailsText)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.text3)
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.leading, 6)
            }

            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .opacity(showsActions ? 1 : 0)
        .allowsHitTesting(showsActions)
        .animation(reduceMotion ? nil : Motion.quick, value: showsActions)
    }

    // MARK: Media

    private var hasMediaNotes: Bool {
        message.imageNote?.isEmpty == false
            || message.videoNote?.isEmpty == false
            || message.imageSeed != nil
    }

    private var mediaNotes: some View {
        HStack(spacing: 10) {
            if let note = message.imageNote, !note.isEmpty {
                Text(note)
            }
            if let seed = message.imageSeed {
                seedBadge(seed)
            }
            if let note = message.videoNote, !note.isEmpty {
                Text(note)
            }
        }
        .font(DS.Font.proseNumber(11.5))
        .foregroundStyle(DS.text3)
        .lineLimit(1)
    }

    /// 一次工具调用画出的整组图：横排缩略图，单张仍按大图显示。
    @ViewBuilder private func imageSeries(_ paths: [String]) -> some View {
        if paths.count == 1 {
            imageBubble(path: paths[0])
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                        imageBubble(path: path, maxWidth: 240, maxHeight: 240)
                            .overlay(alignment: .topLeading) {
                                Text("\(index + 1)")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(.black.opacity(0.42), in: Capsule())
                                    .padding(6)
                            }
                    }
                }
            }
        }
    }

    /// 助手出的图：点开用「预览」，右键可存到访达或复制。
    @ViewBuilder
    private func imageBubble(
        path: String,
        maxWidth: CGFloat = 420,
        maxHeight: CGFloat = 420
    ) -> some View {
        if FileManager.default.fileExists(atPath: path) {
            AsyncChatThumbnail(
                path: path,
                maxPixel: maxWidth * 2,
                contentMode: .fit
            ) {
                DS.rect(DS.Radius.lg)
                    .fill(DS.bg)
                    .frame(width: min(maxWidth, 240), height: min(maxHeight, 180))
                    .overlay(ProgressView().controlSize(.small))
            } missingView: {
                Text(L10n.format("图片已被移除：%@", path))
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.text3)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            .clipShape(DS.rect(DS.Radius.lg))
            .overlay {
                DS.rect(DS.Radius.lg)
                    .strokeBorder(DS.line, lineWidth: 1)
            }
            .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            .help(L10n.t("点击用「预览」打开"))
            .contextMenu {
                Button(L10n.t("在访达中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Button(L10n.t("复制图像")) { copyImage(path: path) }
            }
        } else {
            Text(L10n.format("图片已被移除：%@", path))
                .font(.system(size: 10.5))
                .foregroundStyle(DS.text3)
                .textSelection(.enabled)
        }
    }

    /// 用户提问里附的图：和 Splash 一样 120pt 见方、圆角 12、内侧一圈发丝线。
    @ViewBuilder
    private func imageThumb(path: String, maxWidth: CGFloat) -> some View {
        if FileManager.default.fileExists(atPath: path) {
            AsyncChatThumbnail(
                path: path,
                maxPixel: maxWidth * 2,
                contentMode: .fill
            ) {
                DS.rect(DS.Radius.xl)
                    .fill(DS.bg)
                    .frame(width: maxWidth, height: maxWidth)
            } missingView: {
                EmptyView()
            }
            .frame(width: maxWidth, height: maxWidth)
            .clipShape(DS.rect(DS.Radius.xl))
            .overlay {
                DS.rect(DS.Radius.xl)
                    .strokeBorder(DS.line, lineWidth: 1)
            }
        }
    }

    /// 首尾帧缩略图下面跟一行小字说明，避免两张图并排时分不清先后。
    private func labeledThumb(path: String, label: String, maxWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            imageThumb(path: path, maxWidth: maxWidth)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(DS.text3)
        }
    }

    private var referenceImagePaths: [String] { message.videoReferenceImagePaths ?? [] }
    private var referenceClipPaths: [String] { message.videoReferenceClipPaths ?? [] }
    private var hasReferences: Bool {
        !referenceImagePaths.isEmpty || !referenceClipPaths.isEmpty
    }

    /// 参考素材留在提问里：图片给缩略图，视频给带编号的占位卡（原片可能很大，
    /// 不复制进作品目录，历史里只记路径）。
    private var referenceMessageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(referenceImagePaths.enumerated()), id: \.offset) { item in
                    labeledThumb(
                        path: item.element,
                        label: L10n.format("参考图 %lld", Int64(item.offset + 1)),
                        maxWidth: 120)
                }
                ForEach(Array(referenceClipPaths.enumerated()), id: \.offset) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        ZStack {
                            DS.rect(DS.Radius.xl)
                                .fill(DS.bg)
                            Image(systemName: "film")
                                .font(.system(size: 18))
                                .foregroundStyle(DS.text3)
                        }
                        .frame(width: 120, height: 68)
                        .overlay {
                            DS.rect(DS.Radius.xl)
                                .strokeBorder(DS.line, lineWidth: 1)
                        }
                        Text(L10n.format("参考视频 %lld", Int64(item.offset + 1)))
                            .font(.system(size: 9))
                            .foregroundStyle(DS.text3)
                    }
                    .help((item.element as NSString).lastPathComponent)
                }
            }
        }
        .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
    }

    private func copyImage(path: String) {
        guard let image = NSImage(contentsOfFile: path) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// 图注里的 seed：点一下复制整数值，短暂变成「已复制」。
    private func seedBadge(_ seed: Int) -> some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(String(seed), forType: .string)
            seedResetTask?.cancel()
            withAnimation(reduceMotion ? nil : Motion.quick) { seedCopied = true }
            seedResetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : Motion.quick) { seedCopied = false }
            }
        } label: {
            Text(verbatim: seedCopied ? L10n.t("已复制") : "seed " + String(seed))
                .font(DS.Font.mono(10.5))
                .foregroundStyle(seedCopied ? DS.accent : DS.text2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(DS.rect(DS.Radius.sm).fill(DS.raised))
                .overlay(DS.rect(DS.Radius.sm).strokeBorder(DS.line, lineWidth: 1))
                .contentShape(DS.rect(DS.Radius.sm))
        }
        .buttonStyle(.plainHit)
        .help(L10n.t("点击复制 seed"))
        .animation(reduceMotion ? nil : Motion.quick, value: seedCopied)
    }

    /// 复制成功只让按钮短暂变成对号，不弹通知，避免打断连续选取与复制。
    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        copyResetTask?.cancel()
        withAnimation(reduceMotion ? nil : Motion.quick) { copied = true }
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : Motion.quick) { copied = false }
        }
    }
}

/// 回复操作行里的小按钮：无边框，悬停浮出底色。
private struct MessageActionButton: View {
    let systemName: String
    let help: String
    var tint: Color = DS.text2
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(DS.rect(6).fill(hovering ? DS.hover : .clear))
                .contentShape(DS.rect(6))
        }
        .buttonStyle(.plainHit)
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 流式等待时每秒更新的 `· 3s`；不足一秒不显示，避免刚发出就闪一个 0。
private struct ElapsedThinkingSeconds: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            if seconds >= 1 {
                // 闭包里直接返回两个 Text 会变成 TupleView，SwiftUI 按纵向排，
                // 「·」和「1s」各占一行、标题行凭空长高一截。收进 HStack 再固定
                // 单行宽度，秒数始终跟在动词后面。
                HStack(spacing: 4) {
                    Text("·")
                    Text("\(seconds)s").monospacedDigit()
                }
                .foregroundStyle(DS.text3)
                .lineLimit(1)
                .fixedSize()
            }
        }
    }
}

// MARK: - Parameters

struct ChatParametersSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chat.temperature") private var storedTemperature = 0.7
    @AppStorage("chat.topP") private var storedTopP = 0.95
    @AppStorage("chat.maxTokens") private var storedMaxTokens = 0
    @AppStorage("chat.system") private var storedSystemPrompt = ""
    @AppStorage("thinkingMode") private var storedThinkingMode = ThinkingMode.automatic.rawValue
    @AppStorage("reasoningEffort") private var storedReasoningEffort = ReasoningEffort.medium.rawValue

    private var thinkingMode: ThinkingMode {
        ThinkingMode(rawValue: storedThinkingMode) ?? .automatic
    }

    private var reasoningEffort: ReasoningEffort {
        ReasoningEffort.stored(storedReasoningEffort)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            DSDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if ChatComposerControls.showsThinkingLevel(for: state.activeModel) {
                        thinkingCard
                    }
                    samplingCard
                    systemPromptCard
                }
                .padding(18)
            }
            .scrollIndicators(.never)

            DSDivider()
            footer
        }
        .frame(width: 500, height: 500)
        .sheetCanvas()
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("生成参数")
                    .font(DS.Font.lg.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text("这些默认值会随每条消息一起发送")
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
            }
            Spacer(minLength: 8)
            DSIconButton(systemName: "xmark", help: "关闭") { dismiss() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// 思考设置从输入卡底排收进这里：底排只留模型、上下文与发送，
    /// 思考模式与等级是「偶尔调一次」的参数，不该和每轮都要点的发送键抢位置。
    private var thinkingCard: some View {
        Card("思考", subtitle: "回答前是否输出推理过程") {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Text("模式")
                        .font(DS.Font.sm)
                        .foregroundStyle(DS.text3)
                    Spacer(minLength: 8)
                    NativeSegmented(
                        selection: Binding(
                            get: { thinkingMode },
                            set: { mode in
                                storedThinkingMode = mode.rawValue
                                state.settings.setThinkingMode(mode)
                            }),
                        options: ThinkingMode.allCases.map { ($0, $0.label) })
                    .accessibilityLabel(L10n.t("思考等级"))
                    .accessibilityValue(
                        ChatThinkingLevel.text(mode: thinkingMode, effort: reasoningEffort))
                }
                if thinkingMode == .on {
                    HStack(spacing: 12) {
                        Text("等级")
                            .font(DS.Font.sm)
                            .foregroundStyle(DS.text3)
                        Spacer(minLength: 8)
                        NativeSegmented(
                            selection: Binding(
                                get: { reasoningEffort },
                                set: { effort in
                                    storedReasoningEffort = effort.rawValue
                                    state.settings.setReasoningEffort(effort)
                                }),
                            options: ReasoningEffort.allCases.map { ($0, $0.label) })
                    }
                } else {
                    Text(L10n.t(thinkingMode.detail))
                        .font(DS.Font.xs)
                        .foregroundStyle(DS.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// 采样参数：卡片里放两行滑杆和一个托底输入框。
    private var samplingCard: some View {
        Card("采样", subtitle: "每条消息都会带上这组默认值") {
            VStack(spacing: 14) {
                SamplingSlider(
                    label: "温度", value: storedTemperature, range: 0...2,
                    format: "%.2f"
                ) {
                    storedTemperature = $0
                    state.settings.setTemperature($0)
                }
                SamplingSlider(
                    label: "top-p", value: storedTopP, range: 0...1,
                    format: "%.2f"
                ) {
                    storedTopP = $0
                    state.settings.setTopP($0)
                }
                HStack(spacing: 10) {
                    Text("最大输出")
                        .font(DS.Font.md)
                        .foregroundStyle(DS.text2)
                        .frame(width: 72, alignment: .leading)
                    TextField(
                        "模型上限",
                        text: Binding(
                            get: { storedMaxTokens > 0 ? String(storedMaxTokens) : "" },
                            set: { raw in
                                let digits = raw.filter(\.isNumber)
                                let value = Int(digits) ?? 0
                                storedMaxTokens = value
                                state.settings.setMaxTokens(value)
                            })
                    )
                    .textFieldStyle(.plain)
                    .font(DS.Font.mono(11.5))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .dsInputSurface()
                    .frame(width: 120)
                    Text("生效 \(storedMaxTokens > 0 ? storedMaxTokens : (state.contextWindowTokens ?? 32_768))")
                        .font(DS.Font.mono(11))
                        .foregroundStyle(DS.text3)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 系统提示：面板内嵌输入底与细描边，保证长文本可读性。
    private var systemPromptCard: some View {
        Card("系统提示", subtitle: "作为系统消息置于每段对话之前") {
            TextEditor(
                text: Binding(
                    get: { storedSystemPrompt },
                    set: {
                        storedSystemPrompt = $0
                        state.settings.setSystemPrompt($0)
                    })
            )
            .font(DS.Font.md)
            .foregroundStyle(DS.text)
            .scrollContentBackground(.hidden)
            .frame(height: 120)
            .padding(8)
            .dsInputSurface()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("恢复默认") { state.resetChatParameters() }
                .buttonStyle(.ds(.secondary, size: .regular))
            Spacer(minLength: 0)
            Button("完成") { dismiss() }
                .buttonStyle(.ds(.primary, size: .regular))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

}

/// 采样参数的一行：滑杆 + 右侧实时读数。
///
/// 读数跟着滑杆走，靠的是本地 `@State`——并在外层 `@AppStorage` 重置时同步回滑块。
private struct SamplingSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let format: String
    let commit: (Double) -> Void
    @State private var current: Double

    init(
        label: String, value: Double, range: ClosedRange<Double>,
        format: String, commit: @escaping (Double) -> Void
    ) {
        self.label = label
        self.value = value
        self.range = range
        self.format = format
        self.commit = commit
        _current = State(initialValue: value)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(L10n.t(label))
                .font(DS.Font.md)
                .foregroundStyle(DS.text2)
                .frame(width: 72, alignment: .leading)
            Slider(value: $current, in: range)
                .tint(DS.accent)
            Text(String(format: format, current))
                .font(DS.Font.mono(11))
                .foregroundStyle(DS.text3)
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(width: 40, alignment: .trailing)
        }
        .onChange(of: current) { _, newValue in commit(newValue) }
        .onChange(of: value) { _, newValue in
            if abs(current - newValue) > 0.0001 {
                current = newValue
            }
        }
    }
}

// MARK: - Video bubble

/// 视频结果直接内嵌播放：mp4 已经落在本地作品目录，AVPlayer 按需读文件。
/// 播放器只在行出现时创建，滚出屏幕就暂停，避免十几条历史视频同时解码。
private struct VideoBubble: View {
    let path: String
    @State private var player: AVPlayer?
    @State private var aspect: CGFloat = 16.0 / 9.0
    @State private var missing = false

    private var displaySize: CGSize {
        if aspect >= 1 {
            return CGSize(width: 440, height: 440 / max(aspect, 0.1))
        }
        return CGSize(width: 440 * max(aspect, 0.1), height: 440)
    }

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .clipShape(DS.rect(DS.Radius.lg))
                    .overlay {
                        DS.rect(DS.Radius.lg)
                            .strokeBorder(DS.line, lineWidth: 1)
                    }
                    .contextMenu {
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        Button("用 QuickTime 打开") {
                            VideoPlayback.openInQuickTime(path)
                        }
                    }
                    .help("视频已保存在本地，可直接播放")
            } else if missing {
                Text("视频已被移除：\(path)")
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
                    .textSelection(.enabled)
            } else {
                DS.rect(DS.Radius.lg)
                    .fill(DS.bg)
                    .overlay {
                        DS.rect(DS.Radius.lg)
                            .strokeBorder(DS.line, lineWidth: 1)
                    }
                    .frame(width: displaySize.width, height: displaySize.height)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: path) {
            guard VideoStore.exists(atPath: path) else {
                missing = true
                return
            }
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
                let size = try? await track.load(.naturalSize),
                size.width > 0, size.height > 0
            {
                aspect = size.width / size.height
            }
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - Video options

/// 视频模型专用面板。分辨率和帧数都直接换算成显存，所以把常用档位做成
/// 一键选项，并在底部写清楚 24fps 下的时长。
private struct VideoOptionsPopover: View {
    @Binding var options: VideoOptions
    let hasSource: Bool
    var supportsReferences = false
    var referenceCount = 0
    @State private var seedText = ""
    @FocusState private var seedFocused: Bool

    private let sizes = ["512x384", "768x512", "1024x576", "1280x704"]
    private let framePresets: [(frames: Int, label: String)] = [
        (49, "2 秒"), (97, "4 秒"), (121, "5 秒"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("视频参数"))
                    .font(DS.Font.md.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text(headerSubtitle)
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
            }

            section("尺寸") {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                    ],
                    spacing: 8
                ) {
                    ForEach(sizes, id: \.self) { size in
                        sizeChip(size)
                    }
                }
            }

            if supportsReferences {
                section("参考细节") {
                    NativeSegmented(
                        selection: detailBinding,
                        options: VideoReferenceDetail.allCases.map { ($0, $0.title) },
                        size: .small)
                    Text(
                        L10n.t(
                            options.referenceDetail == .max
                                ? "参考帧长边按 1280 发送：细节更多，上传与预处理更慢。"
                                : "参考帧按生成画布缩放：上传更快，适合先试效果。"
                        )
                    )
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.text3)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            section("时长（24fps）") {
                HStack(spacing: 8) {
                    ForEach(framePresets, id: \.frames) { preset in
                        frameChip(preset.frames, label: preset.label)
                    }
                }
                HStack(spacing: 10) {
                    Text(L10n.format("%lld 帧", Int64(options.frames)))
                        .font(DS.Font.mono(12, weight: .medium))
                        .foregroundStyle(DS.text)
                        .monospacedDigit()
                        .frame(minWidth: 54, alignment: .leading)
                    Stepper("", value: $options.frames, in: 9...249, step: 4)
                        .labelsHidden()
                    Spacer(minLength: 0)
                    Text(L10n.format("%.1f 秒", Double(options.frames) / 24.0))
                        .font(DS.Font.mono(10.5))
                        .foregroundStyle(DS.text3)
                        .monospacedDigit()
                }
            }

            section("步数") {
                StepsControl(steps: $options.steps, range: 4...50)
                Text(L10n.t("蒸馏 LTX 8 步够用；H3 一般给到 20 步。"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.text3)
            }

            section("seed") {
                HStack(spacing: 8) {
                    TextField(L10n.t("留空则每次随机"), text: $seedText)
                        .textFieldStyle(.plain)
                        .font(DS.Font.mono(11))
                        .focused($seedFocused)
                        .padding(.horizontal, 8)
                        .frame(width: 126, height: 26)
                        .dsInputSurface(radius: DS.Radius.sm, focused: seedFocused)
                    Button(L10n.t("随机")) { seedText = "" }
                        .buttonStyle(.link)
                        .font(DS.Font.xs)
                    Spacer(minLength: 0)
                }
                Text(
                    L10n.t(
                        options.seed == nil
                            ? "留空时每段视频随机一个 seed；生成后视频下方会显示实际值。"
                            : "固定 seed：提示词与参数相同时，结果基本可复现。"
                    )
                )
                .font(.system(size: 9.5))
                .foregroundStyle(DS.text3)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(L10n.t("分辨率与帧数越大越吃显存；显存不足时先降尺寸，再减帧数。"))
                .font(.system(size: 9.5))
                .foregroundStyle(DS.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 344)
        .dsPopoverSurface()
        .onChange(of: seedText) { _, text in
            let digits = text.filter(\.isNumber)
            if digits != text { seedText = digits }
            options.seed = digits.isEmpty ? nil : Int(digits)
        }
        .onAppear { seedText = options.seed.map(String.init) ?? "" }
    }

    private var headerSubtitle: String {
        if supportsReferences {
            return referenceCount > 0
                ? L10n.format("已附 %lld 个参考素材：REF2VA 会从素材生成新视频", Int64(referenceCount))
                : L10n.t("REF2VA 需要至少一个参考素材；首帧/尾帧不适用于这个包")
        }
        return L10n.t(
            hasSource
                ? "已附参考帧：首帧定开头、尾帧定结尾，只给一边也可以"
                : "不附帧直接按提示词生成；附首帧/尾帧可约束开头和结尾"
        )
    }

    private var detailBinding: Binding<VideoReferenceDetail> {
        Binding(
            get: { options.referenceDetail ?? .match },
            set: { options.referenceDetail = $0 == .match ? nil : $0 })
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.t(title))
                .font(DS.Font.xs.weight(.medium))
                .foregroundStyle(DS.text3)
            content()
        }
    }

    private func sizeChip(_ size: String) -> some View {
        let selected = options.size == size
        let label = size.replacingOccurrences(of: "x", with: " × ")
        return Button {
            options.size = size
        } label: {
            HStack(spacing: 5) {
                Text(label)
                    .font(DS.Font.mono(10.5, weight: selected ? .semibold : .regular))
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(selected ? DS.text : DS.text2)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background {
                DS.rect(DS.Radius.md)
                    .fill(selected ? DS.accentSoft : DS.bg)
            }
            .overlay {
                DS.rect(DS.Radius.md)
                    .strokeBorder(
                        selected ? DS.accent.opacity(0.55) : DS.line,
                        lineWidth: 1)
            }
            .contentShape(DS.rect(DS.Radius.md))
        }
        .buttonStyle(.plainHit)
    }

    private func frameChip(_ frames: Int, label: String) -> some View {
        let selected = options.frames == frames
        return Button {
            options.frames = frames
        } label: {
            VStack(spacing: 1) {
                Text(L10n.format("%lld 帧", Int64(frames)))
                    .font(DS.Font.mono(10, weight: selected ? .semibold : .regular))
                Text(L10n.t(label))
                    .font(.system(size: 9))
            }
            .foregroundStyle(selected ? DS.text : DS.text2)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
                DS.rect(DS.Radius.md)
                    .fill(selected ? DS.accentSoft : DS.bg)
            }
            .overlay {
                DS.rect(DS.Radius.md)
                    .strokeBorder(
                        selected ? DS.accent.opacity(0.55) : DS.line,
                        lineWidth: 1)
            }
            .contentShape(DS.rect(DS.Radius.md))
        }
        .buttonStyle(.plainHit)
    }
}

// MARK: - Image options

/// 图像模型专用的小面板。只影响下一次发送，不做持久化：尺寸/步数这类
/// 参数每次出图都可能想换，记住上次的值反而容易在没注意时多等几十秒。
private struct ImageOptionsPopover: View {
    private enum FocusField {
        case seed, width, height
    }

    @Binding var options: ImageOptions
    let model: EngineModel?
    let hasSource: Bool
    let lastSeed: Int?
    @State private var seedText = ""
    @State private var widthText = ""
    @State private var heightText = ""
    @FocusState private var focusedField: FocusField?

    private var profile: ImageModelProfile { ImageModelProfile(model: model) }
    private var presets: [ImageSizePreset] { profile.presets }
    private var isCustomSize: Bool { !presets.contains { $0.id == options.size } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("图像参数"))
                    .font(DS.Font.md.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text(L10n.t(hasSource ? "以附件为底图重绘，强度决定离原图多远" : "不附底图，直接按提示词出图"))
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
            }

            section("尺寸") {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                    ],
                    spacing: 8
                ) {
                    ForEach(presets) { preset in
                        sizeChip(preset)
                    }
                }
                if profile.allowsCustomCanvas {
                    customSizeRow
                    Text(
                        L10n.format(
                            "也可以直接填宽高（256–%lld）；引擎会按 %lld 对齐，非预设画布也能出图。",
                            Int64(profile.maximumSide),
                            Int64(profile.alignment)
                        )
                    )
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.text3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L10n.t("Mage 的采样器只认上面的固定画布，不能自定宽高。"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            section("步数") {
                if let fixed = profile.fixedSteps {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(DS.text3)
                        Text(L10n.format("固定 %lld 步", Int64(fixed)))
                            .font(DS.Font.mono(11, weight: .medium))
                            .foregroundStyle(DS.text)
                    }
                    Text(L10n.format("这个模型是蒸馏加速版，采样表由权重写死；拖步数不会改变结果，出图就按 %lld 步算。", Int64(fixed)))
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.text3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    StepsControl(steps: $options.steps)
                    Text(L10n.t("8 步能出草稿，20 步细节更稳；越高越慢。"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.text3)
                }
            }

            section("seed") {
                HStack(spacing: 8) {
                    TextField(L10n.t("留空则每次随机"), text: $seedText)
                        .textFieldStyle(.plain)
                        .font(DS.Font.mono(11))
                        .focused($focusedField, equals: .seed)
                        .padding(.horizontal, 8)
                        .frame(width: 126, height: 26)
                        .dsInputSurface(radius: DS.Radius.sm, focused: focusedField == .seed)
                    Button(L10n.t("随机")) { seedText = "" }
                        .buttonStyle(.link)
                        .font(DS.Font.xs)
                    if let lastSeed {
                        Button(L10n.format("用上次 #%lld", Int64(lastSeed))) { seedText = String(lastSeed) }
                            .buttonStyle(.link)
                            .font(DS.Font.xs)
                    }
                    Spacer(minLength: 0)
                }
                Text(
                    L10n.t(
                        options.seed == nil
                            ? "留空时每张图随机一个 seed；生成后点图下方的 seed 复制，贴回这里即可复现。"
                            : "固定 seed：提示词与参数相同时，结果基本可复现。"
                    )
                )
                .font(.system(size: 9.5))
                .foregroundStyle(DS.text3)
                .fixedSize(horizontal: false, vertical: true)
            }

            if hasSource {
                section("重绘强度") {
                    HStack(spacing: 10) {
                        Slider(value: $options.strength, in: 0.1...0.95)
                            .tint(DS.accent)
                        Text("\(Int((options.strength * 100).rounded()))%")
                            .font(DS.Font.mono(10.5))
                            .foregroundStyle(DS.text2)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    Text(L10n.t("越低越贴近原图，越高越放飞；0.55–0.65 适合换风格。"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(width: 330)
        .dsPopoverSurface()
        .onChange(of: seedText) { _, text in
            let digits = text.filter(\.isNumber)
            if digits != text { seedText = digits }
            options.seed = digits.isEmpty ? nil : Int(digits)
        }
        .onAppear {
            seedText = options.seed.map(String.init) ?? ""
            syncSizeText()
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.t(title))
                .font(DS.Font.xs.weight(.medium))
                .foregroundStyle(DS.text3)
            content()
        }
    }

    /// 自定宽高和预设放在同一栏：预设是常用比例，字段留给 1328×1328 这类
    /// 引擎能算、但没进预设表的画布。
    private var customSizeRow: some View {
        HStack(spacing: 6) {
            TextField(L10n.t("宽"), text: $widthText)
                .textFieldStyle(.plain)
                .font(DS.Font.mono(10.5))
                .multilineTextAlignment(.center)
                .focused($focusedField, equals: .width)
                .padding(.horizontal, 6)
                .frame(width: 58, height: 26)
                .dsInputSurface(radius: DS.Radius.sm, focused: focusedField == .width)
            Text("×")
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
            TextField(L10n.t("高"), text: $heightText)
                .textFieldStyle(.plain)
                .font(DS.Font.mono(10.5))
                .multilineTextAlignment(.center)
                .focused($focusedField, equals: .height)
                .padding(.horizontal, 6)
                .frame(width: 58, height: 26)
                .dsInputSurface(radius: DS.Radius.sm, focused: focusedField == .height)
            Text("px")
                .font(.system(size: 9.5))
                .foregroundStyle(DS.text3)
            Spacer(minLength: 0)
            if isCustomSize {
                Text(L10n.t("自定义"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(DS.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DS.rect(DS.Radius.sm).fill(DS.accentSoft))
                    .overlay(DS.rect(DS.Radius.sm).strokeBorder(DS.accent.opacity(0.25), lineWidth: 1))
            }
            Button(L10n.t("应用")) { commitCustomCanvas() }
                .buttonStyle(.plain)
                .font(DS.Font.xs.weight(.medium))
                .foregroundStyle(DS.accent)
                .help(L10n.t("把宽高限制在引擎支持的范围内并应用"))
        }
        .onChange(of: widthText) { _, text in
            let digits = text.filter(\.isNumber)
            if digits != text { widthText = digits }
            applyCustomCanvas()
        }
        .onChange(of: heightText) { _, text in
            let digits = text.filter(\.isNumber)
            if digits != text { heightText = digits }
            applyCustomCanvas()
        }
    }

    private func chooseSize(_ preset: ImageSizePreset) {
        options.size = preset.id
        widthText = String(preset.width)
        heightText = String(preset.height)
    }

    private func applyCustomCanvas() {
        guard let width = Int(widthText), let height = Int(heightText),
            profile.isValidCanvas(width: width, height: height)
        else { return }
        let size = "\(width)x\(height)"
        if options.size != size { options.size = size }
    }

    private func commitCustomCanvas() {
        guard let width = Int(widthText), let height = Int(heightText) else { return }
        let clamped = profile.clampedCanvas(width: width, height: height)
        options.size = "\(clamped.width)x\(clamped.height)"
        widthText = String(clamped.width)
        heightText = String(clamped.height)
    }

    private func syncSizeText() {
        let normalized = options.size.lowercased().replacingOccurrences(of: "×", with: "x")
        let parts = normalized.split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else {
            widthText = ""
            heightText = ""
            return
        }
        widthText = String(width)
        heightText = String(height)
    }

    private func sizeChip(_ preset: ImageSizePreset) -> some View {
        let selected = options.size == preset.id
        return Button {
            chooseSize(preset)
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text(preset.title)
                        .font(DS.Font.mono(10.5, weight: selected ? .semibold : .regular))
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                Text(preset.orientation)
                    .font(.system(size: 8.5))
                    .foregroundStyle(DS.text3)
            }
            .foregroundStyle(selected ? DS.text : DS.text2)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background {
                DS.rect(DS.Radius.md)
                    .fill(selected ? DS.accentSoft : DS.bg)
            }
            .overlay {
                DS.rect(DS.Radius.md)
                    .strokeBorder(
                        selected ? DS.accent.opacity(0.55) : DS.line,
                        lineWidth: 1)
            }
            .contentShape(DS.rect(DS.Radius.md))
        }
        .buttonStyle(.plainHit)
    }
}

/// 步数一条滑块加一个可编辑数字：拖动快，手动输入能精确落到想要的数字。
/// 视频和图像的参数面板共用，所以范围由调用方给。
private struct StepsControl: View {
    @Binding var steps: Int
    var range: ClosedRange<Int> = 1...50

    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { Double(steps) },
                    set: { steps = clamp(Int($0.rounded())) }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .tint(DS.accent)

            HStack(spacing: 4) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(DS.Font.mono(11, weight: .medium))
                    .multilineTextAlignment(.trailing)
                    .focused($editing)
                Text(L10n.t("步"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.text3)
            }
            .padding(.horizontal, 7)
            .frame(width: 58, height: 24)
            .dsInputSurface(radius: DS.Radius.sm, focused: editing)
        }
        .onAppear { text = String(steps) }
        .onDisappear { commit() }
        .onChange(of: steps) { _, value in
            // 非编辑状态下以 model 为准，比如预设按钮改了步数。
            if !editing { text = String(value) }
        }
        .onChange(of: editing) { _, focused in
            if !focused { commit() }
        }
        .onChange(of: text) { _, value in
            let digits = value.filter(\.isNumber)
            if digits != value { text = digits }
            // 输入过程中只要已经是范围内的数字就即时同步，滑块跟着一起走。
            if let number = Int(digits), range.contains(number) {
                steps = number
            }
        }
    }

    private func commit() {
        if let number = Int(text.trimmingCharacters(in: .whitespaces)) {
            steps = clamp(number)
        }
        text = String(steps)
    }

    private func clamp(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
