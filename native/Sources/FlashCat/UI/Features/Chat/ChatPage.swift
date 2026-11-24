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
    @ObservedObject var draftStore: ChatDraftStore

    @State var showsParameters = false
    @State var atBottom = true
    /// 用户正在主动滚动时，内容长高不再把视图拽回底部。
    @State var userScrolling = false
    /// 「加载更早」按会话记：换一段会话各算各的，删掉会话也只是留个用不到的键。
    @State var earlierBatches: [String: Int] = [:]
    /// 输入框的第一响应者状态由 `ChatComposerField` 回报。
    @State var composerFocused = false
    @State var imageOptions = ImageOptionsStore.load()
    @State var videoOptions = VideoOptionsStore.load()
    @State var showsImageOptions = false
    /// 拖拽悬停在输入卡上时给出投放提示；图像/视频模型才接受文件。
    @State var isDropTargeted = false
    /// 正在编辑的用户消息；非 nil 时发送键改为「保存并重发」。
    @State var editingMessageID: UUID?
    /// 编辑会删掉后面的回答：先挂起，等壳层确认。
    @State var pendingEditMessage: ChatMessage?
    /// 上下文快满的提示按会话关一次；切会话重新计算。
    @State var contextWarningDismissed = false

    /// 用户拖出来的对话列宽。默认 744（Splash 的 680pt 内容列 + 两侧 32pt），
    /// 也是最小宽度：不拖的时候版式和 Splash 一致，列宽变了正文、气泡、输入卡
    /// 一起跟着变。
    @AppStorage("chat.columnWidth") private var storedColumnWidth: Double =
        Double(ChatColumn.defaultWidth)
    /// 页面量到的可用宽度：决定列最宽能撑到哪里、拖柄骑在哪条边上。
    @State var pageWidth: CGFloat = 0
    /// 拖动过程中的实时列宽。落盘放到松手时，拖一次只写一次 UserDefaults。
    @State var liveColumnWidth: CGFloat?
    /// 一次拖动开始时的列宽。列是居中的，边缘每挪 1pt 宽度要变 2pt。
    @State var columnDragOrigin: CGFloat?
    /// 拖柄的 hover 状态：竖条变宽、染上强调色。
    @State var hoveringColumnHandle = false
    /// 拖柄是否已经压上左右箭头光标，pop 必须和 push 成对。
    @State var columnCursorPushed = false

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.colorScheme) var colorScheme

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
    var draftKey: String { state.currentThreadID }

    var draft: String {
        get { draftStore.drafts[draftKey]?.text ?? "" }
        nonmutating set {
            var draft = draftStore.drafts[draftKey] ?? ChatDraft()
            draft.text = newValue
            // 用户一开始改字，上一次的附件回执就收起（Splash 的 `notice` 同理）。
            draft.notice = nil
            draftStore.drafts[draftKey] = draft
        }
    }

    func setDraftNotice(_ text: String) {
        draftStore.drafts[draftKey, default: ChatDraft()].notice = text
    }

    var imageAttachment: ChatImageAttachment? {
        get { draftStore.drafts[draftKey]?.imageAttachment }
        nonmutating set { draftStore.drafts[draftKey, default: ChatDraft()].imageAttachment = newValue }
    }

    var lastFrameAttachment: ChatImageAttachment? {
        get { draftStore.drafts[draftKey]?.lastFrameAttachment }
        nonmutating set { draftStore.drafts[draftKey, default: ChatDraft()].lastFrameAttachment = newValue }
    }

    var referenceImages: [ChatImageAttachment] {
        get { draftStore.drafts[draftKey]?.referenceImages ?? [] }
        nonmutating set { draftStore.drafts[draftKey, default: ChatDraft()].referenceImages = newValue }
    }

    var referenceClips: [VideoReferenceClip] {
        get { draftStore.drafts[draftKey]?.referenceClips ?? [] }
        nonmutating set { draftStore.drafts[draftKey, default: ChatDraft()].referenceClips = newValue }
    }

    var textBinding: Binding<String> {
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
    var columnWidth: CGFloat {
        ChatColumn.width(
            stored: liveColumnWidth ?? CGFloat(storedColumnWidth),
            pageWidth: pageWidth)
    }

    /// 气泡最宽。默认列宽下是 592pt（Splash 的 680 列再让出 88pt），列被拖宽后
    /// 气泡按同样的增量一起放开，否则拖宽只会把消息之间推开，回答还是原来那么窄。
    var bubbleMaxWidth: CGFloat {
        ChatColumn.bubbleWidth(column: columnWidth)
    }

    /// 列右边缘离页面右边的距离。拖柄骑在这条边上：列越宽，它越靠外。
    var columnEdgeInset: CGFloat {
        guard pageWidth > 0 else { return ChatColumn.defaultWidth / 2 }
        return max(0, (pageWidth - columnWidth) / 2)
    }

    // MARK: Header

    var currentThread: ChatThread? {
        chat.threads.first(where: { $0.id == state.currentThreadID })
    }

    /// 恢复启动时的旧会话可能还没进「最近对话」（旧版本按轮次存、清理过副本），
    /// 但正文已经在当前会话里。这种时候顶栏仍要显示标题，只是不挂操作菜单：
    /// 置顶 / 改名 / 删除都要求历史里有对应条目。
    var restoredTitle: String? {
        guard !chat.messages.isEmpty else { return nil }
        if let thread = currentThread { return thread.title }
        return ChatHistory.autoTitle(messages: chat.messages)
    }

    /// 顶栏只留 Splash 那样的会话标题：标题 + 下拉箭头，悬停高亮，点开是
    /// 置顶 / 重命名 / 删除。标题左侧常驻「对话历史」，点开就是最近对话的
    /// 搜索与分组列表；右侧常驻「新对话」。边栏收起、页面铺满窗口时不用把
    /// 边栏叫回来也能换会话、开新对话；边栏展开时这两颗按钮只是同一条捷径。
    var header: some View {
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
    var windowCount: Int {
        Self.budgetedMessageCount(chat.messages) + (earlierBatches[state.currentThreadID] ?? 0)
    }

    var visibleMessages: [ChatMessage] {
        guard chat.messages.count > windowCount else { return chat.messages }
        return Array(chat.messages.suffix(windowCount))
    }

    var streamingScrollKey: String {
        guard let last = chat.messages.last else { return "" }
        return
            "\(last.id.uuidString)-\(last.content.count)-\(last.reasoning?.count ?? 0)-\(last.imagePaths.count)-\(last.videoPath ?? "")-\(last.toolStage ?? "")-\(last.streaming)"
    }

    var transcript: some View {
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

    func messageRow(_ message: ChatMessage) -> some View {
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
        draft = message.content
        composerFocused = true
    }

    func cancelEditing() {
        editingMessageID = nil
        draft = ""
        focusComposer()
    }

    /// 接近上下文上限时在输入卡上方提示；按会话关一次，切走再回来会重新判断。
    var contextWarning: some View {
        Group {
            if let ratio = contextUsageRatio, ratio >= 0.8, !contextWarningDismissed {
                HStack(spacing: 8) {
                    Image(systemName: ratio >= 0.95 ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ratio >= 0.95 ? DS.warn : DS.text2)
                    Text(
                        L10n.format(
                            "上下文已用 %lld%%，再长就会顶到窗口上限。",
                            Int64((ratio * 100).rounded()))
                    )
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

    var contextUsageRatio: Double? {
        guard let ceiling = state.contextWindowCeiling, ceiling > 0 else { return nil }
        let used = state.contextUsedTokens
        guard used > 0 else { return nil }
        return min(1.5, Double(used) / Double(ceiling))
    }

    /// 把对话区落到底部。首次布局只量到一部分高度时，稍后再补一次，
    /// 让超大回答（长代码块）也停在最后一条上；读者自己往上翻时不抢位置。
    func restoreBottom(_ proxy: ScrollViewProxy, animated: Bool) {
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

    func scroll(_ proxy: ScrollViewProxy, animated: Bool, force: Bool = false) {
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
    var emptyState: some View {
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

    // MARK: Column resize handle

    /// 对话列右边那条可以拖的竖条：平时隐藏，悬停或拖动时柔和浮现。
    var columnResizeHandle: some View {
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

    var columnResizeGesture: some Gesture {
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
    func commitColumnWidth() {
        if let width = liveColumnWidth { storedColumnWidth = Double(width) }
        liveColumnWidth = nil
        columnDragOrigin = nil
        updateColumnCursor()
    }

    func resetColumnWidth() {
        withAnimation(reduceMotion ? nil : Motion.standard) {
            storedColumnWidth = Double(ChatColumn.defaultWidth)
            liveColumnWidth = nil
        }
        columnDragOrigin = nil
    }

    func updateColumnCursor() {
        pushColumnCursor(hoveringColumnHandle || columnDragOrigin != nil)
    }

    /// 左右箭头光标按栈压入 / 弹出。视图消失时必须弹掉，否则光标会一直
    /// 停在缩放态。`push` / `pop` 严格成对。
    func pushColumnCursor(_ on: Bool) {
        if on, !columnCursorPushed {
            NSCursor.resizeLeftRight.push()
            columnCursorPushed = true
        } else if !on, columnCursorPushed {
            NSCursor.pop()
            columnCursorPushed = false
        }
    }
}
