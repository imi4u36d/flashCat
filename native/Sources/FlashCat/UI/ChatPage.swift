// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AVKit
import AppKit
import FlashCatKit
import SwiftUI
import UniformTypeIdentifiers

/// 对话页：按 WebUI 版式——顶部模型行、居中空态、悬浮输入卡。
struct ChatPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore

    @State private var draft = ""
    @State private var showsParameters = false
    @State private var atBottom = true
    @State private var userScrolling = false
    /// 超长对话只渲染最近这些消息，往上翻时再按批放出来。
    @State private var messageLimit = 80
    /// 对话区量到的真实高度。切页回来的头一两帧它是 0，那时候不能 scrollTo。
    @State private var transcriptHeight: CGFloat = 0
    /// 欠着一次「落到底部」：等对话区量出高度再补。
    @State private var needsBottomRestore = false
    /// 输入框的第一响应者状态由 `ChatComposerField` 回报。
    @State private var composerFocused = false
    /// 图像模型的底图；视频模型下它是首帧。对话模型用不到这些。
    @State private var imageAttachment: ChatImageAttachment?
    /// 视频模型的尾帧。图像模型只用一张底图，这里始终为空。
    @State private var lastFrameAttachment: ChatImageAttachment?
    /// REF2VA 的参考图与参考视频。参考视频发送时只抽帧，原文件仍留在原处。
    @State private var referenceImages: [ChatImageAttachment] = []
    @State private var referenceClips: [VideoReferenceClip] = []
    @State private var imageOptions = ImageOptionsStore.load()
    @State private var videoOptions = VideoOptionsStore.load()
    @State private var showsImageOptions = false
    /// 拖拽悬停在输入卡上时给出投放提示；图像/视频模型才接受文件。
    @State private var isDropTargeted = false

    /// 用户拖出来的对话列宽。默认 820 同时是最小宽度：不拖的时候版式
    /// 和以前完全一样，列宽变了才跟着变。
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

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
        }
        // 页面切换时外层用 transition 重新插入视图。这里显式铺满可用空间，
        // 保证 ScrollView 拿到确定高度；否则懒加载列表可能量到 0 高度，
        // 整页只剩顶部模型行，看起来就是空白。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 页面宽度决定对话列最宽能撑到哪里。量在根视图上而不是对话区里：
        // 输入卡是页面级浮层，两边必须读同一个数才不会一宽一窄。
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            pageWidth = width
        }
        .overlay(alignment: .bottom) {
            composer
                .padding(.horizontal, 40)
                .padding(.bottom, Console.contentBottomInset)
        }
        .sheet(isPresented: $showsParameters) { ChatParametersSheet(state: state) }
        .onChange(of: imageOptions) { _, newValue in
            ImageOptionsStore.save(newValue)
        }
        .onChange(of: videoOptions) { _, newValue in
            VideoOptionsStore.save(newValue)
        }
    }

    // MARK: Column width

    /// 当前生效的对话列宽：拖动中用实时值，其余时候读落盘值再按窗口夹一次。
    /// 夹紧不等于回写——窗口缩小时列跟着收窄，窗口再放大又能回到用户拖出来的宽度。
    private var columnWidth: CGFloat {
        ChatColumn.width(
            stored: liveColumnWidth ?? CGFloat(storedColumnWidth),
            pageWidth: pageWidth)
    }

    /// 气泡最宽。默认列宽下是 660pt，列被拖宽后气泡按同样的增量一起放开，
    /// 否则拖宽只会把消息之间推开，回答本身还是原来那么窄。
    private var bubbleMaxWidth: CGFloat {
        ChatColumn.bubbleWidth(column: columnWidth)
    }

    /// 输入卡宽度，恒比列窄 40pt（默认 820 → 780），跟着同一条列边收放。
    private var composerMaxWidth: CGFloat {
        ChatColumn.composerWidth(column: columnWidth)
    }

    /// 列右边缘离页面右边的距离。拖柄骑在这条边上：列越宽，它越靠外。
    private var columnEdgeInset: CGFloat {
        guard pageWidth > 0 else { return ChatColumn.defaultWidth / 2 }
        return max(0, (pageWidth - columnWidth) / 2)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            DSMenu(size: .small) {
                DSMenuTriggerLabel(
                    title: state.selectedModel.isEmpty ? "选择模型" : state.shortModelName(state.selectedModel),
                    systemImage: "sparkles",
                    imageTint: DS.accent,
                    badge: state.activeModelSupportsVideo ? "视频" : (state.activeModelSupportsImage ? "图像" : nil),
                    size: .small
                )
            } content: {
                ForEach(EngineCatalog.allIDs.filter { state.engineIsInstalled($0) }, id: \.self) { id in
                    let models = state.engineModels(for: id)
                        .filter { !$0.hidden && !$0.helper && !ModelLibraryEntry.isDraftModel($0.id) }
                    if !models.isEmpty {
                        Section(id.displayName) {
                            ForEach(models) { model in
                                Button {
                                    state.applyModelFromAnyEngine(model.id, engine: id)
                                } label: {
                                    if model.id == state.selectedModel, id == state.activeEngine {
                                        Label(state.shortModelName(model.id), systemImage: "checkmark")
                                    } else {
                                        Text(state.shortModelName(model.id))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .disabled(chat.generating)

            if state.activeModelSupportsVideo {
                Text(L10n.t("提示词 → 视频"))
                    .font(DS.Font.mono(11))
                    .foregroundStyle(DS.text3)
            } else if state.activeModelSupportsImage {
                Text(L10n.t("提示词 → 图像"))
                    .font(DS.Font.mono(11))
                    .foregroundStyle(DS.text3)
            } else {
                Text(
                    "\(Format.tokens(state.contextUsedTokens)) / \(state.contextWindowCeiling.map { Format.tokensShort($0) } ?? "—")"
                )
                .font(DS.Font.mono(11))
                .foregroundStyle(DS.text3)
            }

            Spacer(minLength: 0)

            Button {
                state.newConversation()
            } label: {
                Label(L10n.t("新对话"), systemImage: "square.and.pencil")
            }
            .buttonStyle(.ds(.secondary, size: .small))
        }
        .padding(.leading, Console.topBarLeading(sidebarShown: state.showsSidebar, base: DS.Space.lg))
        .padding(.trailing, DS.Space.lg)
        .frame(height: DS.Layout.titlebarHeight)
        .padding(.top, Console.pageTopPadding)
        .background(WindowDragArea())
        .padding(.bottom, 4)
    }

    // MARK: Transcript

    private var visibleMessages: [ChatMessage] {
        guard chat.messages.count > messageLimit else { return chat.messages }
        return Array(chat.messages.suffix(messageLimit))
    }

    private var streamingScrollKey: String {
        guard let last = chat.messages.last else { return "" }
        return
            "\(last.id.uuidString)-\(last.content.count)-\(last.reasoning?.count ?? 0)-\(last.imagePaths.count)-\(last.videoPath ?? "")-\(last.toolStage ?? "")-\(last.streaming)"
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !chat.messages.isEmpty {
                        if chat.messages.count > visibleMessages.count {
                            Button {
                                let anchor = visibleMessages.first?.id
                                messageLimit += 80
                                if let anchor {
                                    DispatchQueue.main.async {
                                        proxy.scrollTo(anchor, anchor: .top)
                                    }
                                }
                            } label: {
                                Label(
                                    "加载更早的 \(min(80, chat.messages.count - visibleMessages.count)) 条",
                                    systemImage: "arrow.up")
                            }
                            .buttonStyle(.ds(.ghost, size: .small))
                            .frame(maxWidth: .infinity)
                        }
                        ForEach(visibleMessages) { message in
                            MessageRow(
                                message: message,
                                modelName: message.model.map(state.shortModelName)
                                    ?? state.activeEngine.displayName,
                                startupStage: chat.chatStartupStage,
                                maxBubbleWidth: bubbleMaxWidth
                            )
                            .equatable()
                            .id(message.id)
                            .transition(.opacity.combined(with: .offset(y: 10)))
                        }
                    }
                    Color.clear.frame(height: 140).id("bottom")
                }
                .padding(.horizontal, 40)
                .padding(.top, 8)
                .frame(maxWidth: columnWidth)
                .frame(maxWidth: .infinity)
                .id("top")
                .animation(Motion.entrance, value: chat.messages.count)
            }
            .scrollIndicators(.never)
            // 内容长高时把底部锚在视口底部。贴底交给布局本身完成，不再只靠
            // 布局之后一帧才执行的 scrollTo——那一帧的延迟会让整列内容（含
            // 底部那行 tok/s、tokens、首字）在每次长高时上下颤一下。
            //
            // 只取 .sizeChanges 这一个角色：初始落位仍按默认（顶部），内容不
            // 满一屏时的对齐也保持默认，否则新会话的第一句话会被按到对话区
            // 底部、再往上长。锚点不会跟用户抢滚动：往上翻时它只是保持当前
            // 偏移，人自己滚回底部后又自动接管。
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onScrollPhaseChange { _, newPhase in
                userScrolling = (newPhase == .interacting || newPhase == .tracking || newPhase == .decelerating)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height <= geometry.containerSize.height
                    || geometry.contentOffset.y + geometry.containerSize.height
                        >= geometry.contentSize.height - 90
            } action: { _, bottom in
                if bottom {
                    if !atBottom { withAnimation(Motion.quick) { atBottom = true } }
                } else if !needsBottomRestore, !chat.generating || userScrolling {
                    // 只有非生成态或用户主动滚动离开底部时，才退出「跟随底部」；
                    // 生成过程中内容撑高超过 90pt 或正在恢复底部时不应误判为用户上翻。
                    if atBottom { withAnimation(Motion.quick) { atBottom = false } }
                }
            }
            // 对话区量出真实高度之后才补「落到底部」。切页回来时 ChatPage 刚
            // 重建、过渡动画还在跑，ScrollView 报的是 0 高度；这时候 scrollTo
            // 会按 0 视口算偏移，等高度补齐就落到内容之外——整块对话区空白。
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.height
            } action: { _, height in
                transcriptHeight = height
                guard height > 0, needsBottomRestore, !chat.messages.isEmpty else { return }
                restoreBottom(proxy)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { oldHeight, newHeight in
                guard chat.generating, atBottom, !needsBottomRestore,
                    oldHeight > 0, newHeight > oldHeight + 1
                else { return }
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
                // 换会话 / 清空后内容高度骤变，等这一帧布局完成再定位，
                // 否则会滚到尚不存在的旧位置。
                DispatchQueue.main.async {
                    if count == 0 {
                        atBottom = true
                        proxy.scrollTo("top", anchor: .top)
                    } else {
                        scroll(proxy, animated: true, force: true)
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
            .onChange(of: state.currentThreadID) { _, _ in
                messageLimit = 80
                if chat.messages.isEmpty {
                    atBottom = true
                    proxy.scrollTo("top", anchor: .top)
                } else {
                    restoreBottom(proxy)
                }
            }
            .onAppear {
                // 切页回来时 ChatPage 会重建，此刻对话区还没有高度：先挂上
                // 「等高度出来再落到底部」，由上面的几何回调补这一次滚动。
                restoreBottom(proxy)
            }
            .overlay {
                // 空会话只留一句问候，压在输入卡上方的视觉中心。
                if chat.messages.isEmpty {
                    emptyState
                }
            }
            .overlay(alignment: .bottom) {
                if !atBottom {
                    Button {
                        scroll(proxy, animated: true, force: true)
                    } label: {
                        Label("回到最新", systemImage: "arrow.down")
                    }
                    .buttonStyle(.ds(.secondary, size: .regular))
                    .padding(.bottom, 150)
                }
            }
        }
        // 宽度拖柄是页面级的：对话区滚动时它不能跟着上下跑，所以挂在
        // ScrollView 外面，再用「列右边缘离页面右边多少」把它摆到边上。
        .overlay(alignment: .trailing) {
            columnResizeHandle
                .padding(.trailing, max(6, columnEdgeInset - 11))
                // 首帧还没量到页面宽度时先不画，免得竖条先落在页面中间再跳出去。
                .opacity(pageWidth > 0 ? 1 : 0)
        }
    }

    /// 把对话区落到底部。
    ///
    /// 高度还是 0 时不能动手：`scrollTo` 会按 0 视口算偏移，等布局补齐后整块
    /// 对话区落在内容之外——看起来就是空白。这种情况先记一笔，由几何回调在
    /// 高度出来之后补上。超大回答（长代码块）首次布局只量到一部分高度，滚动
    /// 位置会在布局补齐后落回内容中段，所以再补一次，让人真的停在最后一条上。
    private func restoreBottom(_ proxy: ScrollViewProxy) {
        guard !chat.messages.isEmpty else {
            atBottom = true
            needsBottomRestore = false
            return
        }
        guard transcriptHeight > 0 else {
            needsBottomRestore = true
            return
        }
        needsBottomRestore = false
        DispatchQueue.main.async {
            scroll(proxy, animated: false, force: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                // 这 150ms 里读者自己往上翻了，就别把位置抢回来。
                guard atBottom else { return }
                scroll(proxy, animated: false, force: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                // 等切页过渡动画（DS.Motion.smooth）完全落定后再补一次，
                // 确保 LazyVStack 已真实展开底部消息而不是停在空白估算区。
                guard atBottom else { return }
                scroll(proxy, animated: false, force: true)
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool, force: Bool = false) {
        guard force || atBottom else { return }
        if animated {
            withAnimation(Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
        atBottom = true
    }

    /// 空会话：品牌徽记 + 问候语 + 当前引擎与模型胶囊，压在输入卡上方的视觉中心。
    private var emptyState: some View {
        VStack(spacing: 14) {
            BrandMark(size: 38)
            Text("需要我为你做些什么?")
                .font(DS.Font.title)
                .tracking(-0.35)
                .foregroundStyle(DS.text)
                .multilineTextAlignment(.center)
            DSChip(
                text:
                    "\(state.activeEngine.displayName) · \(state.selectedModel.isEmpty ? L10n.t("未选择模型") : state.shortModelName(state.selectedModel))",
                dot: state.canChat ? DS.ok : (state.isModelBusy ? DS.warn : DS.text4),
                live: state.canChat)
        }
        .padding(.bottom, 96)
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

    private var composer: some View {
        VStack(spacing: 10) {
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
            // 自绘输入框：回车发送、⌘回车换行（见 `ChatComposerField`）。
            ChatComposerField(
                text: $draft,
                isFocused: $composerFocused,
                isEnabled: !chat.generating,
                onSend: send,
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
                onDragTargetChange: { targeted in
                    withAnimation(reduceMotion ? nil : Motion.quick) {
                        isDropTargeted = targeted && supportsMedia
                    }
                },
                acceptsImageDrop: supportsMedia
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    // 图像模型没有采样参数：同一个按钮换成图像设置，别再弹文本模型的
                    // 温度/系统提示面板。
                    DSIconButton(
                        systemName: supportsVideo
                            ? "video"
                            : (supportsImage ? "wand.and.stars" : "slider.horizontal.3"),
                        help: supportsVideo ? "视频参数" : (supportsImage ? "图像参数" : "生成参数"),
                        size: 28,
                        style: .outlined
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
                        DSIconButton(
                            systemName: state.imageToolEnabled
                                ? "paintbrush.pointed.fill" : "paintbrush.pointed",
                            help: state.imageToolEnabled
                                ? "模型可以直接画图（点一下关掉）"
                                : "打开后模型可以在这轮对话里直接画图",
                            size: 28,
                            style: .outlined,
                            active: state.imageToolEnabled
                        ) {
                            state.imageToolEnabled.toggle()
                        }
                    }

                    // 画图模型就没法在页头选：页头那一栏一旦选中图像模型，这一轮
                    // 对话本身就变成图像模式了。所以给工具单独留一个选择器，只在
                    // 「画」开着时出现。
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
                        DSIconButton(
                            systemName: "photo.badge.plus",
                            help: supportsVideoReferences
                                ? "添加参考图（最多 9 张）"
                                : (supportsVideo ? "添加首帧或尾帧" : "附上一张图片作重绘底图"),
                            size: 28,
                            style: .outlined,
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
                        DSIconButton(
                            systemName: "video.badge.plus",
                            help: "添加参考视频（最多 3 段，每段至少 5 帧）",
                            size: 28,
                            style: .outlined,
                            active: !referenceClips.isEmpty
                        ) {
                            pickReferenceClip()
                        }
                    }

                    Spacer(minLength: 0)

                    if !draft.isEmpty {
                        Text("≈ \(AppState.estimateTokens(draft)) tokens")
                            .font(DS.Font.mono(10.5))
                            .foregroundStyle(DS.text3)
                    }

                    if !supportsMedia {
                        ChatModelThinkingControl(state: state, chat: chat)
                    }

                    if chat.generating {
                        DSIconButton(
                            systemName: "stop.fill",
                            help: "停止生成",
                            size: 28,
                            style: .outlined,
                            tint: DS.err
                        ) {
                            state.cancelGeneration()
                        }
                    } else {
                        DSIconButton(
                            systemName: "arrow.up",
                            help: "回车发送 · ⌘回车换行",
                            size: 28,
                            style: canSend ? .primary : .outlined,
                            action: send
                        )
                        .disabled(!canSend)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: composerMaxWidth)
        .glassEffect(.regular, in: DS.rect(DS.Radius.xl))
        .overlay {
            if composerFocused {
                DS.rect(DS.Radius.xl)
                    .strokeBorder(DS.accent.opacity(0.42), lineWidth: 1)
            }
        }
        .shadow(color: DS.shadow, radius: 20, y: 8)
        .contentShape(DS.rect(DS.Radius.xl))
        .onTapGesture { focusComposer() }
        .overlay {
            if isDropTargeted {
                DS.rect(DS.Radius.xl)
                    .strokeBorder(DS.accent.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(
                        DS.rect(DS.Radius.xl)
                            .fill(DS.accentSoft)
                    )
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
        .animation(reduceMotion ? nil : DS.Motion.smooth, value: composerFocused)
    }

    private var supportsImage: Bool { state.activeModelSupportsImage }
    private var supportsVideo: Bool { state.activeModelSupportsVideo }
    private var supportsVideoReferences: Bool { state.activeModelSupportsVideoReferences }
    private var supportsMedia: Bool { supportsImage || supportsVideo }

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

    /// 点输入卡的留白也把光标交给输入框；生成中不收输入，直接忽略。
    private func focusComposer() {
        guard !chat.generating else { return }
        composerFocused = true
    }

    private var conversationText: String {
        chat.messages
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.role == "user" ? "你" : "AI")\n\($0.content)" }
            .joined(separator: "\n\n")
    }

    private func send() {
        guard !chat.generating else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if supportsVideo {
            // 只给首帧或尾帧也可以：引擎要求 prompt 非空，给它一句保守的运动描述。
            guard !text.isEmpty || hasAttachedMedia else { return }
            if supportsVideoReferences {
                // REF2VA 从参考素材生成新视频，不接受首尾帧；至少一个 ref 才能发。
                guard hasReferenceMedia else {
                    state.notice = "REF2VA 需要至少一张参考图或一段参考视频。"
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
            state.notice = "参考图最多 9 张。"
            return
        }
        guard referenceImages.count + referenceClips.count < 12 else {
            state.notice = "参考素材最多 12 个（9 张图 + 3 段视频）。"
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

    /// 面板与拖拽共用。读头失败或超出上限都走顶部提示，不打断当前输入。
    private func addReferenceClip(_ url: URL) {
        guard supportsVideoReferences else { return }
        guard Self.videoExtensions.contains(url.pathExtension.lowercased()) else { return }
        Task {
            do {
                let meta = try await VideoReferenceExtractor.metadata(url: url)
                guard supportsVideoReferences else { return }
                guard !referenceClips.contains(where: { $0.path == url.path }) else { return }
                guard referenceClips.count < 3 else {
                    state.notice = "参考视频最多 3 段。"
                    return
                }
                guard referenceImages.count + referenceClips.count < 12 else {
                    state.notice = "参考素材最多 12 个（9 张图 + 3 段视频）。"
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
                state.notice = error.localizedDescription
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
            state.notice = "参考视频最多 3 段。"
            return false
        }
        addReferenceClip(url)
        return true
    }

    /// Finder 拖入与面板选择共用一条入口：记路径、名字和像素尺寸，
    /// 发送时才把文件拷进作品目录。
    private func attachImage(at url: URL, slot: VideoFrameSlot? = nil) {
        if supportsVideoReferences {
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
        .padding(.horizontal, 10)
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
                    if let attachment,
                        let image = ImageStore.thumbnail(atPath: attachment.path, maxPixel: 96)
                    {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
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
            .help("选择视频\(slot.rawValue)")

            VStack(alignment: .leading, spacing: 1) {
                Text(slot.rawValue)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(DS.text2)
                Text(attachment?.name ?? "点击选择")
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
        .padding(.horizontal, 10)
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
            Group {
                if let image = ImageStore.thumbnail(atPath: attachment.path, maxPixel: 96) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.text3)
                }
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
            .help("移除参考图")
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
            if let image = ImageStore.thumbnail(atPath: attachment.path, maxPixel: 96) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 46, height: 46)
                    .clipShape(DS.rect(DS.Radius.sm))
                    .overlay {
                        DS.rect(DS.Radius.sm).strokeBorder(DS.line, lineWidth: 1)
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .font(DS.Font.xs.weight(.medium))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                Text("重绘 · 强度 \(Int((imageOptions.strength * 100).rounded()))%")
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
            .help("移除底图")
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
        .padding(.horizontal, 10)
    }
}

// MARK: - Message row

private struct MessageRow: View, Equatable {
    /// 行内需要的状态由父视图算好传入，配合 `Equatable` 让未变化的旧消息
    /// 在流式期间跳过 body 求值。
    let message: ChatMessage
    let modelName: String
    let startupStage: String?
    /// 气泡最宽。列宽被拖开时父视图会传更大的值，行必须跟着重算，
    /// 否则拖宽只多出空白，回答还是原来那么窄。
    let maxBubbleWidth: CGFloat
    @State private var manualThinking: Bool?
    @State private var hoveringRow = false
    @State private var copied = false
    @State private var seedCopied = false
    @State private var copyResetTask: Task<Void, Never>?

    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.modelName == rhs.modelName
            && lhs.startupStage == rhs.startupStage
            && lhs.maxBubbleWidth == rhs.maxBubbleWidth
    }

    private var isUser: Bool { message.role == "user" }
    private var showsReasoning: Bool {
        manualThinking ?? (message.streaming && message.content.isEmpty)
    }

    private var bubbleBackground: some View {
        DS.rect(DS.Radius.lg)
            .fill(isUser ? DS.raised : .clear)
            .overlay(
                DS.rect(DS.Radius.lg)
                    .strokeBorder(isUser ? DS.line2 : .clear, lineWidth: 1)
            )
    }

    var body: some View {
        Group {
            if isUser {
                HStack(alignment: .bottom, spacing: 8) {
                    Spacer(minLength: 64)
                    if !message.content.isEmpty {
                        Button(action: copyMessage) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: copied ? .semibold : .regular))
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plainHit)
                        .foregroundStyle(copied ? DS.accent : DS.text3)
                        .opacity(hoveringRow || copied ? 1 : 0)
                        .help(copied ? "已复制" : "复制提问")
                        .animation(DS.Motion.snappy, value: copied)
                    }
                    VStack(alignment: .trailing, spacing: 8) {
                        if hasReferences {
                            referenceMessageStrip
                        } else if let path = message.imagePath {
                            if let last = message.videoLastFramePath {
                                // 首尾帧一起发出去的：两张都留在这一问里，标清楚哪张是尾帧。
                                HStack(alignment: .top, spacing: 8) {
                                    labeledThumb(path: path, label: "首帧", maxWidth: 104)
                                    labeledThumb(path: last, label: "尾帧", maxWidth: 104)
                                }
                            } else {
                                imageThumb(path: path, maxWidth: 220)
                            }
                        } else if let last = message.videoLastFramePath {
                            // 只给了尾帧：也把这张留在提问里，别让它只存在于引擎请求。
                            labeledThumb(path: last, label: "尾帧", maxWidth: 220)
                        }
                        if !message.content.isEmpty {
                            Text(message.content)
                                .font(.system(size: 14))
                                .lineSpacing(4)
                                .foregroundStyle(DS.text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 10)
                                .background { bubbleBackground }
                                .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    // 说话人行：轻标 + 模型名，回复正文直接铺在画布上，去掉外框。
                    HStack(spacing: 6) {
                        BrandMark(size: 16)
                        Text(modelName)
                            .font(DS.Font.sm.weight(.medium))
                            .foregroundStyle(DS.text2)
                        if message.streaming {
                            DSStatusDot(color: DS.accent, live: true, size: 5)
                            Text(startupStage == nil ? "生成中" : "启动中")
                                .font(DS.Font.xs)
                                .foregroundStyle(DS.accent)
                        } else if message.interrupted, !message.content.isEmpty {
                            Text("已停止生成")
                                .font(DS.Font.xs)
                                .foregroundStyle(DS.text3)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if let reasoning = message.reasoning, !reasoning.isEmpty {
                            reasoningBlock(reasoning)
                        }
                        // 一轮工具调用可能画出一整组图：series 是这组，单图时
                        // 只有一张，仍按原来那张大图显示。
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
                        if message.content.isEmpty, !series.isEmpty || message.videoPath != nil {
                            // 一组图是逐张画的：第一张落地后正文还是空的，但后面几张
                            // 的进度不能就此消失，否则看上去像卡在图上了。
                            if let stage = message.toolStage, !stage.isEmpty {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(L10n.t(stage))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(DS.text3)
                                }
                            }
                        } else if message.content.isEmpty, message.interrupted {
                            // 一个字都没来时也得留下这一轮：换掉转圈，说清楚是用户
                            // 停掉的，而不是让回答气泡凭空消失。
                            HStack(spacing: 6) {
                                Image(systemName: "stop.circle")
                                    .font(.system(size: 11))
                                Text("已停止生成")
                                    .font(.system(size: 11.5))
                            }
                            .foregroundStyle(DS.text3)
                        } else if message.content.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(L10n.t(placeholderText))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(DS.text3)
                            }
                        } else {
                            StreamingMarkdownView(
                                text: message.content,
                                streaming: message.streaming,
                                fillsWidth: false)
                        }
                        if hasFooter {
                            footer
                        }
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onHover { value in
            withAnimation(DS.Motion.snappy) { hoveringRow = value }
        }
    }

    private func reasoningBlock(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DS.Motion.smooth) { manualThinking = !showsReasoning }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(showsReasoning ? 90 : 0))
                    Text(thinkingLabel)
                        .font(DS.Font.xs.weight(.medium))
                    if message.streaming {
                        DSStatusDot(color: DS.accent, live: true, size: 5)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DS.text3)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)

            if showsReasoning {
                DSDivider()
                Text(reasoning)
                    .font(DS.Font.sm)
                    .lineSpacing(4)
                    .foregroundStyle(DS.text2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DS.rect(DS.Radius.md).fill(DS.surface))
        .overlay(DS.rect(DS.Radius.md).strokeBorder(DS.line, lineWidth: 1))
        .clipShape(DS.rect(DS.Radius.md))
    }

    private var thinkingLabel: String {
        if let seconds = message.thinkingSeconds, seconds > 0 {
            return L10n.format("思考了 %.1f 秒", seconds)
        }
        return "思考过程"
    }

    /// 引擎还没就绪时优先显示启动阶段，就绪后才回到「思考中 / 等待首个 token」。
    private var placeholderText: String {
        if let stage = startupStage, !stage.isEmpty { return stage }
        // 工具调用的阶段（「正在画第 2/3 张 · 去噪 8/20」）比静态提示有用得多：
        // 换模型、画图的几十秒里，用户能看出停在哪一步。
        if let stage = message.toolStage, !stage.isEmpty { return stage }
        if let progress = message.imageProgress, !progress.isEmpty { return progress }
        if let progress = message.videoProgress, !progress.isEmpty { return progress }
        return message.reasoning?.isEmpty == false ? "思考中…" : "等待首个 token…"
    }

    /// 一次工具调用画出的一组图：横排缩略图，点开预览、右键存到访达。
    /// 单张仍走原来的大图，别让「只画了一张」看起来像缩水的样子。
    @ViewBuilder
    private func imageSeries(_ paths: [String]) -> some View {
        if paths.count == 1 {
            imageBubble(path: paths[0])
        } else {
            VStack(alignment: .leading, spacing: 6) {
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
                if let note = message.imageNote {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(Console.tertiary)
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
        // 420pt 显示，取 840px 够用；原图只在你点开预览时由系统加载。
        if let image = ImageStore.thumbnail(atPath: path, maxPixel: maxWidth * 2) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Console.cardStroke, lineWidth: 1)
                }
                .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                .help("点击用「预览」打开")
                .contextMenu {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    Button("复制图像") { copyImage(path: path) }
                }
        } else {
            Text("图片已被移除：\(path)")
                .font(.system(size: 10.5))
                .foregroundStyle(Console.tertiary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func imageThumb(path: String, maxWidth: CGFloat) -> some View {
        if let image = ImageStore.thumbnail(atPath: path, maxPixel: maxWidth * 2) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: maxWidth)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Console.cardStroke, lineWidth: 1)
                }
        }
    }

    /// 首尾帧缩略图下面跟一行小字说明，避免两张图并排时分不清先后。
    private func labeledThumb(path: String, label: String, maxWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            imageThumb(path: path, maxWidth: maxWidth)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Console.tertiary)
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
                        label: "参考图 \(item.offset + 1)",
                        maxWidth: 104)
                }
                ForEach(Array(referenceClipPaths.enumerated()), id: \.offset) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Console.inset)
                            Image(systemName: "film")
                                .font(.system(size: 18))
                                .foregroundStyle(Console.tertiary)
                        }
                        .frame(width: 104, height: 62)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Console.cardStroke, lineWidth: 1)
                        }
                        Text("参考视频 \(item.offset + 1)")
                            .font(.system(size: 9))
                            .foregroundStyle(Console.tertiary)
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

    /// 没有统计值、也没到可复制的时候，气泡里不额外留一行空白。
    private var hasFooter: Bool {
        message.rateText != nil
            || message.tokenCount > 0
            || message.imageNote?.isEmpty == false
            || message.imageSeed != nil
            || message.videoNote?.isEmpty == false
            || (message.firstTokenSeconds ?? 0) > 0
            || (!message.streaming && !message.content.isEmpty)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let rate = message.rateText { Text(rate) }
            if message.tokenCount > 0 { Text("\(message.tokenCount) tokens") }
            if let note = message.imageNote, !note.isEmpty { Text(note) }
            if let seed = message.imageSeed { seedBadge(seed) }
            if let note = message.videoNote, !note.isEmpty { Text(note) }
            if let ttft = message.firstTokenSeconds, ttft > 0 {
                Text(L10n.format("首字 %.0f ms", ttft * 1000))
            }
            if !message.streaming, !message.content.isEmpty {
                Button(action: copyMessage) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: copied ? .semibold : .regular))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plainHit)
                .foregroundStyle(copied ? DS.accent : DS.text3)
                .opacity(hoveringRow || copied ? 1 : 0)
                .help(copied ? "已复制" : "复制回答")
                .animation(DS.Motion.snappy, value: copied)
            }
        }
        .font(DS.Font.mono(11))
        .foregroundStyle(DS.text3)
    }

    /// 图注里的 seed：点一下复制整数值，短暂变成「已复制」。
    private func seedBadge(_ seed: Int) -> some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(String(seed), forType: .string)
            seedCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                seedCopied = false
            }
        } label: {
            Text(verbatim: seedCopied ? "已复制" : "seed " + String(seed))
                .font(DS.Font.mono(10.5))
                .foregroundStyle(seedCopied ? DS.accent : DS.text2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(DS.rect(DS.Radius.sm).fill(DS.raised))
                .overlay(DS.rect(DS.Radius.sm).strokeBorder(DS.line, lineWidth: 1))
                .contentShape(DS.rect(DS.Radius.sm))
        }
        .buttonStyle(.plainHit)
        .help("点击复制 seed")
        .animation(DS.Motion.snappy, value: seedCopied)
    }

    /// 复制成功只让按钮短暂变成对号，不弹通知，避免打断连续选取与复制。
    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        copyResetTask?.cancel()
        withAnimation(DS.Motion.snappy) { copied = true }
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(DS.Motion.snappy) { copied = false }
        }
    }
}

// MARK: - Parameters

struct ChatParametersSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            DSDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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

    /// 采样参数：卡片里放两行滑杆和一个托底输入框。
    private var samplingCard: some View {
        Card("采样", subtitle: "每条消息都会带上这组默认值") {
            VStack(spacing: 14) {
                SamplingSlider(
                    label: "温度", value: state.settings.temperature, range: 0...2,
                    format: "%.2f"
                ) { state.settings.setTemperature($0) }
                SamplingSlider(
                    label: "top-p", value: state.settings.topP, range: 0...1,
                    format: "%.2f"
                ) { state.settings.setTopP($0) }
                HStack(spacing: 10) {
                    Text("最大输出")
                        .font(DS.Font.md)
                        .foregroundStyle(DS.text2)
                        .frame(width: 72, alignment: .leading)
                    TextField(
                        "模型上限",
                        text: Binding(
                            get: { state.settings.maxTokens > 0 ? String(state.settings.maxTokens) : "" },
                            set: { state.settings.setMaxTokens(Int($0) ?? 0) })
                    )
                    .textFieldStyle(.plain)
                    .font(DS.Font.mono(11.5))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .dsInputSurface()
                    .frame(width: 120)
                    Text("生效 \(state.effectiveMaxTokens)")
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
                    get: { state.settings.systemPrompt },
                    set: { state.settings.setSystemPrompt($0) })
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
/// 读数跟着滑杆走，靠的是本地 `@State`——`AppSettings` 直接把值写进
/// UserDefaults，不会触发 SwiftUI 重绘；早先把 `value` 当常量传进来时，
/// 拖动滑杆数字要等别的刷新才更新，看起来像「读数卡住了」。
private struct SamplingSlider: View {
    let label: String
    let range: ClosedRange<Double>
    let format: String
    let commit: (Double) -> Void
    @State private var current: Double

    init(
        label: String, value: Double, range: ClosedRange<Double>,
        format: String, commit: @escaping (Double) -> Void
    ) {
        self.label = label
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
        .onChange(of: current) { _, value in commit(value) }
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

    private let sizes = ["512x384", "768x512", "1024x576", "1280x704"]
    private let framePresets: [(frames: Int, label: String)] = [
        (49, "2 秒"), (97, "4 秒"), (121, "5 秒"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("视频参数")
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
                        options.referenceDetail == .max
                            ? "参考帧长边按 1280 发送：细节更多，上传与预处理更慢。"
                            : "参考帧按生成画布缩放：上传更快，适合先试效果。"
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
                    Text("\(options.frames) 帧")
                        .font(DS.Font.mono(12, weight: .medium))
                        .foregroundStyle(DS.text)
                        .monospacedDigit()
                        .frame(minWidth: 54, alignment: .leading)
                    Stepper("", value: $options.frames, in: 9...249, step: 4)
                        .labelsHidden()
                    Spacer(minLength: 0)
                    Text(String(format: "%.1f 秒", Double(options.frames) / 24.0))
                        .font(DS.Font.mono(10.5))
                        .foregroundStyle(DS.text3)
                        .monospacedDigit()
                }
            }

            section("步数") {
                StepsControl(steps: $options.steps, range: 4...50)
                Text("蒸馏 LTX 8 步够用；H3 一般给到 20 步。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.text3)
            }

            section("seed") {
                HStack(spacing: 8) {
                    TextField("留空则每次随机", text: $seedText)
                        .textFieldStyle(.plain)
                        .font(DS.Font.mono(11))
                        .padding(.horizontal, 8)
                        .frame(width: 126, height: 26)
                        .background(DS.rect(DS.Radius.sm).fill(DS.bg))
                        .overlay(DS.rect(DS.Radius.sm).strokeBorder(DS.line2, lineWidth: 1))
                    Button("随机") { seedText = "" }
                        .buttonStyle(.link)
                        .font(DS.Font.xs)
                    Spacer(minLength: 0)
                }
                Text(
                    options.seed == nil
                        ? "留空时每段视频随机一个 seed；生成后视频下方会显示实际值。"
                        : "固定 seed：提示词与参数相同时，结果基本可复现。"
                )
                .font(.system(size: 9.5))
                .foregroundStyle(DS.text3)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text("分辨率与帧数越大越吃显存；显存不足时先降尺寸，再减帧数。")
                .font(.system(size: 9.5))
                .foregroundStyle(DS.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 344)
        .onChange(of: seedText) { _, text in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            options.seed = trimmed.isEmpty ? nil : Int(trimmed)
        }
        .onAppear { seedText = options.seed.map(String.init) ?? "" }
    }

    private var headerSubtitle: String {
        if supportsReferences {
            return referenceCount > 0
                ? "已附 \(referenceCount) 个参考素材：REF2VA 会从素材生成新视频"
                : "REF2VA 需要至少一个参考素材；首帧/尾帧不适用于这个包"
        }
        return hasSource
            ? "已附参考帧：首帧定开头、尾帧定结尾，只给一边也可以"
            : "不附帧直接按提示词生成；附首帧/尾帧可约束开头和结尾"
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
            Text(title)
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
                Text("\(frames) 帧")
                    .font(DS.Font.mono(10, weight: selected ? .semibold : .regular))
                Text(label)
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
    @Binding var options: ImageOptions
    let model: EngineModel?
    let hasSource: Bool
    let lastSeed: Int?
    @State private var seedText = ""
    @State private var widthText = ""
    @State private var heightText = ""

    private var profile: ImageModelProfile { ImageModelProfile(model: model) }
    private var presets: [ImageSizePreset] { profile.presets }
    private var isCustomSize: Bool { !presets.contains { $0.id == options.size } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("图像参数")
                    .font(DS.Font.md.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text(hasSource ? "以附件为底图重绘，强度决定离原图多远" : "不附底图，直接按提示词出图")
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
                    Text("也可以直接填宽高（256–\(profile.maximumSide)）；引擎会按 \(profile.alignment) 对齐，非预设画布也能出图。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.text3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Mage 的采样器只认上面的固定画布，不能自定宽高。")
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
                        Text("固定 \(fixed) 步")
                            .font(DS.Font.mono(11, weight: .medium))
                            .foregroundStyle(DS.text)
                    }
                    Text("这个模型是蒸馏加速版，采样表由权重写死；拖步数不会改变结果，出图就按 \(fixed) 步算。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.text3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    StepsControl(steps: $options.steps)
                    Text("8 步能出草稿，20 步细节更稳；越高越慢。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.text3)
                }
            }

            section("seed") {
                HStack(spacing: 8) {
                    TextField("留空则每次随机", text: $seedText)
                        .textFieldStyle(.plain)
                        .font(DS.Font.mono(11))
                        .padding(.horizontal, 8)
                        .frame(width: 126, height: 26)
                        .background(DS.rect(DS.Radius.sm).fill(DS.bg))
                        .overlay(DS.rect(DS.Radius.sm).strokeBorder(DS.line2, lineWidth: 1))
                    Button("随机") { seedText = "" }
                        .buttonStyle(.link)
                        .font(DS.Font.xs)
                    if let lastSeed {
                        Button("用上次 #\(lastSeed)") { seedText = String(lastSeed) }
                            .buttonStyle(.link)
                            .font(DS.Font.xs)
                    }
                    Spacer(minLength: 0)
                }
                Text(
                    options.seed == nil
                        ? "留空时每张图随机一个 seed；生成后点图下方的 seed 复制，贴回这里即可复现。"
                        : "固定 seed：提示词与参数相同时，结果基本可复现。"
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
                    Text("越低越贴近原图，越高越放飞；0.55–0.65 适合换风格。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(width: 330)
        .onChange(of: seedText) { _, text in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            options.seed = trimmed.isEmpty ? nil : Int(trimmed)
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
            Text(title)
                .font(DS.Font.xs.weight(.medium))
                .foregroundStyle(DS.text3)
            content()
        }
    }

    /// 自定宽高和预设放在同一栏：预设是常用比例，字段留给 1328×1328 这类
    /// 引擎能算、但没进预设表的画布。
    private var customSizeRow: some View {
        HStack(spacing: 6) {
            TextField("宽", text: $widthText)
                .textFieldStyle(.plain)
                .font(DS.Font.mono(10.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
                .frame(width: 58, height: 26)
                .background(DS.rect(DS.Radius.sm).fill(DS.bg))
                .overlay(DS.rect(DS.Radius.sm).strokeBorder(DS.line2, lineWidth: 1))
            Text("×")
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
            TextField("高", text: $heightText)
                .textFieldStyle(.plain)
                .font(DS.Font.mono(10.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
                .frame(width: 58, height: 26)
                .background(DS.rect(DS.Radius.sm).fill(DS.bg))
                .overlay(DS.rect(DS.Radius.sm).strokeBorder(DS.line2, lineWidth: 1))
            Text("px")
                .font(.system(size: 9.5))
                .foregroundStyle(DS.text3)
            Spacer(minLength: 0)
            if isCustomSize {
                Text("自定义")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(DS.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DS.rect(DS.Radius.sm).fill(DS.accentSoft))
                    .overlay(DS.rect(DS.Radius.sm).strokeBorder(DS.accent.opacity(0.25), lineWidth: 1))
            }
            Button("应用") { commitCustomCanvas() }
                .buttonStyle(.plain)
                .font(DS.Font.xs.weight(.medium))
                .foregroundStyle(DS.accent)
                .help("把宽高限制在引擎支持的范围内并应用")
        }
        .onChange(of: widthText) { _, _ in applyCustomCanvas() }
        .onChange(of: heightText) { _, _ in applyCustomCanvas() }
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
                Text("步")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.text3)
            }
            .padding(.horizontal, 7)
            .frame(width: 58, height: 24)
            .background {
                DS.rect(DS.Radius.sm).fill(DS.bg)
            }
            .overlay {
                DS.rect(DS.Radius.sm)
                    .strokeBorder(
                        editing ? DS.line3 : DS.line2,
                        lineWidth: 1)
            }
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
            // 输入过程中只要已经是范围内的数字就即时同步，滑块跟着一起走。
            if let number = Int(value), range.contains(number) {
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
