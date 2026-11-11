import SwiftUI
import AppKit
import FlashCatKit

/// 对话页：按 WebUI 版式——顶部模型行、居中空态、悬浮输入卡。
struct ChatPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore

    @State private var draft = ""
    @State private var showsParameters = false
    @State private var showsThreads = false
    @State private var atBottom = true
    /// 超长对话只渲染最近这些消息，往上翻时再按批放出来。
    @State private var messageLimit = 80
    /// 对话区量到的真实高度。切页回来的头一两帧它是 0，那时候不能 scrollTo。
    @State private var transcriptHeight: CGFloat = 0
    /// 欠着一次「落到底部」：等对话区量出高度再补。
    @State private var needsBottomRestore = false
    /// 输入框的第一响应者状态由 `ChatComposerField` 回报。
    @State private var composerFocused = false
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
        .padding(.top, 60)
        .overlay(alignment: .bottom) {
            composer
                .padding(.horizontal, 40)
                .padding(.bottom, 18)
        }
        .sheet(isPresented: $showsParameters) { ChatParametersSheet(state: state) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
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
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Console.accent)
                    Text(L10n.t(state.selectedModel.isEmpty ? "选择模型" : state.shortModelName(state.selectedModel)))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Console.text)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Console.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(chat.generating)

            Text("\(Format.tokens(state.contextUsedTokens)) / \(state.contextWindowCeiling.map { shortTokens($0) } ?? "—")")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Console.tertiary)

            Spacer(minLength: 0)

            Button {
                showsThreads.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Console.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plainHit)
            .popover(isPresented: $showsThreads, arrowEdge: .bottom) { threadList }

            Button {
                state.newConversation()
            } label: {
                Label("新对话", systemImage: "square.and.pencil")
            }
            .buttonStyle(.consoleSecondary)
        }
        .padding(.horizontal, Console.contentPadding + 8)
        .frame(height: 44)
    }

    private func shortTokens(_ value: Int) -> String {
        value >= 1000 ? "\(Int((Double(value) / 1000).rounded()))K" : "\(value)"
    }

    private var threadList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("最近对话")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Console.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if chat.threads.isEmpty {
                Text("还没有保存的对话")
                    .font(.system(size: 11))
                    .foregroundStyle(Console.tertiary)
                    .padding(12)
            } else {
                ForEach(chat.threads) { thread in
                    Button {
                        state.openThread(thread)
                        showsThreads = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(thread.title)
                                .font(.system(size: 12))
                                .foregroundStyle(Console.text)
                                .lineLimit(1)
                            Text("\(thread.messages.count) 条 · \(Format.relative(thread.updatedAt))")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Console.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plainHit)
                }
            }
            Divider().overlay(Console.insetStroke).padding(.vertical, 4)
            Button("清空历史") { state.clearThreads() }
                .buttonStyle(.consoleSoft)
                .padding(10)
        }
        .frame(width: 260)
        .background {
            LiquidGlassSurface(shape: Rectangle())
        }
    }

    // MARK: Transcript

    private var visibleMessages: [ChatMessage] {
        guard chat.messages.count > messageLimit else { return chat.messages }
        return Array(chat.messages.suffix(messageLimit))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
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
                                Label("加载更早的 \(min(80, chat.messages.count - visibleMessages.count)) 条",
                                      systemImage: "arrow.up")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .padding(.horizontal, 14)
                                    .frame(height: 30)
                            }
                            .buttonStyle(.consoleSoft)
                            .frame(maxWidth: .infinity)
                        }
                        ForEach(visibleMessages) { message in
                            MessageRow(message: message,
                                       modelName: message.model.map(state.shortModelName)
                                           ?? state.activeEngine.displayName,
                                       startupStage: chat.chatStartupStage)
                                .equatable()
                                .id(message.id)
                                .transition(.opacity.combined(with: .offset(y: 10)))
                        }
                    }
                    Color.clear.frame(height: 140).id("bottom")
                }
                .padding(.horizontal, 40)
                .padding(.top, 8)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .id("top")
                .animation(Motion.entrance, value: chat.messages.count)
            }
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 90
            } action: { _, bottom in
                if atBottom != bottom { withAnimation(Motion.quick) { atBottom = bottom } }
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
            .onChange(of: chat.messages.last?.content.count ?? 0) { _, _ in
                if chat.generating, atBottom { scroll(proxy, animated: false) }
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
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background {
                                LiquidGlassSurface(shape: Capsule(), interactive: true)
                            }
                    }
                    .buttonStyle(.plainHit)
                    .padding(.bottom, 150)
                }
            }
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

    /// 空会话只留一句问候：不放品牌图、副标题与快捷提示，
    /// 输入卡上方只有这一行字，页面安静，也更快把视线交回输入框。
    private var emptyState: some View {
        Text("需要我为你做些什么?")
            .font(.system(size: 36, weight: .regular))
            .foregroundStyle(Console.text)
            .multilineTextAlignment(.center)
            .padding(.bottom, 96)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 10) {
            // 自绘输入框：回车发送、⌘回车换行（见 `ChatComposerField`）。
            ChatComposerField(text: $draft,
                              isFocused: $composerFocused,
                              isEnabled: !chat.generating,
                              onSend: send)
                .padding(.horizontal, 10)
                // 聚焦时输入区向上扩展一块，让正在编辑的输入卡比空闲态更高。
                .padding(.top, composerFocused ? 24 : 6)
                .padding(.bottom, 6)

            HStack(spacing: 10) {
                Button {
                    showsParameters = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Console.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plainHit)
                .help("生成参数")

                Spacer(minLength: 0)

                if !draft.isEmpty {
                    Text("≈ \(AppState.estimateTokens(draft)) tokens")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                }

                ChatModelThinkingControl(state: state, chat: chat)

                if chat.generating {
                    Button {
                        state.cancelGeneration()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background {
                                LiquidGlassSurface(shape: Circle(),
                                                   tint: Native.red.opacity(0.75),
                                                   interactive: true)
                            }
                    }
                    .buttonStyle(.plainHit)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background {
                                LiquidGlassSurface(shape: Circle(),
                                                   tint: Console.accent,
                                                   interactive: true)
                            }
                    }
                    .buttonStyle(.plainHit)
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.45)
                    .help("回车发送 · ⌘回车换行")
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 780)
        .consoleCardSurface()
        .animation(reduceMotion ? nil : Motion.standard, value: composerFocused)
    }

    private var canSend: Bool {
        !chat.generating && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var conversationText: String {
        chat.messages
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.role == "user" ? "你" : "AI")\n\($0.content)" }
            .joined(separator: "\n\n")
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.generating else { return }
        draft = ""
        state.send(text)
    }
}

// MARK: - Message row

private struct MessageRow: View, Equatable {
    /// 行内需要的状态由父视图算好传入，配合 `Equatable` 让未变化的旧消息
    /// 在流式期间跳过 body 求值。
    let message: ChatMessage
    let modelName: String
    let startupStage: String?
    @State private var manualThinking: Bool?
    @State private var caretVisible = false
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.modelName == rhs.modelName
            && lhs.startupStage == rhs.startupStage
    }

    private var isUser: Bool { message.role == "user" }
    private var showsReasoning: Bool {
        manualThinking ?? (message.streaming && message.content.isEmpty)
    }

    var body: some View {
        Group {
            if isUser {
                HStack {
                    Spacer(minLength: 80)
                    Text(message.content)
                        .font(.system(size: 13))
                        .foregroundStyle(Console.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Console.accent.opacity(0.10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Console.accent.opacity(0.16), lineWidth: 0.8)
                                }
                        }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(modelName)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Console.secondary)
                        if message.streaming {
                            Text(startupStage == nil ? "生成中" : "启动中")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Console.accent)
                        }
                    }
                    if let reasoning = message.reasoning, !reasoning.isEmpty {
                        reasoningBlock(reasoning)
                    }
                    if message.content.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(L10n.t(placeholderText))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Console.tertiary)
                        }
                    } else {
                        ZStack(alignment: .bottomTrailing) {
                            MarkdownView(text: message.content, caching: !message.streaming)
                            if message.streaming {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Console.accent)
                                    .frame(width: 6, height: 14)
                                    .opacity(caretVisible ? 1 : 0.15)
                                    .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true),
                                               value: caretVisible)
                                    .onAppear { caretVisible = true }
                            }
                        }
                    }
                    footer
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func reasoningBlock(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(Motion.standard) { manualThinking = !showsReasoning }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showsReasoning ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(thinkingLabel)
                        .font(.system(size: 10.5, weight: .medium))
                    if message.streaming { LiveDot(color: Console.accent, diameter: 4) }
                }
                .foregroundStyle(Console.tertiary)
            }
            .buttonStyle(.plainHit)
            if showsReasoning {
                Text(reasoning)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Console.secondary)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Console.inset)
                    }
            }
        }
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
        return message.reasoning?.isEmpty == false ? "思考中…" : "等待首个 token…"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let rate = message.rateText { Text(rate) }
            if message.tokenCount > 0 { Text("\(message.tokenCount) tokens") }
            if let ttft = message.firstTokenSeconds, ttft > 0 {
                Text(L10n.format("首字 %.0f ms", ttft * 1000))
            }
            Spacer(minLength: 4)
            if !message.streaming {
                Button(action: copyAnswer) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9.5, weight: copied ? .semibold : .regular))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plainHit)
                .foregroundStyle(copied ? Console.accent : Console.tertiary)
                .help(copied ? "已复制" : "复制回答")
                .animation(Motion.quick, value: copied)
            }
        }
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(Console.tertiary)
    }

    /// 复制成功只让按钮短暂变成对号，不弹通知，避免打断连续选取与复制。
    private func copyAnswer() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        copyResetTask?.cancel()
        withAnimation(Motion.quick) { copied = true }
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.quick) { copied = false }
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
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: Native.gap) {
                    samplingCard
                    systemPromptCard
                }
                .padding(Native.pagePadding)
            }
            .scrollIndicators(.never)

            Hairline()
            footer
        }
        .frame(width: 500, height: 500)
        .sheetCanvas()
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("生成参数")
                    .font(Native.cardTitle)
                    .foregroundStyle(Native.label)
                Text("这些默认值会随每条消息一起发送")
                    .font(.system(size: 11))
                    .foregroundStyle(Native.tertiary)
            }
            Spacer(minLength: 8)
            IconAction(systemName: "xmark", help: "关闭") { dismiss() }
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 14)
    }

    /// 采样参数：玻璃卡里放两行滑杆和一个托底凹槽的数字输入。
    private var samplingCard: some View {
        Card("采样", subtitle: "每条消息都会带上这组默认值") {
            VStack(spacing: 14) {
                slider("温度", value: state.settings.temperature, range: 0...2,
                       format: "%.2f") { state.settings.setTemperature($0) }
                slider("top-p", value: state.settings.topP, range: 0...1,
                       format: "%.2f") { state.settings.setTopP($0) }
                HStack(spacing: 10) {
                    Text("最大输出")
                        .font(Native.bodyFont)
                        .foregroundStyle(Native.secondary)
                        .frame(width: 72, alignment: .leading)
                    TextField("模型上限", text: Binding(
                        get: { state.settings.maxTokens > 0 ? String(state.settings.maxTokens) : "" },
                        set: { state.settings.setMaxTokens(Int($0) ?? 0) }))
                        .textFieldStyle(.plain)
                        .font(Native.monoFont)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background {
                            RoundedRectangle(cornerRadius: Native.radiusSmall, style: .continuous)
                                .fill(Native.recess)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: Native.radiusSmall, style: .continuous)
                                .strokeBorder(Native.hairline, lineWidth: 0.8)
                        }
                        .frame(width: 120)
                    Text("生效 \(state.effectiveMaxTokens)")
                        .font(Native.monoSmall)
                        .foregroundStyle(Native.tertiary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 系统提示：玻璃卡 + 凹槽文本域，让长文本仍保持可读的非玻璃底。
    private var systemPromptCard: some View {
        Card("系统提示", subtitle: "作为系统消息置于每段对话之前") {
            TextEditor(text: Binding(
                get: { state.settings.systemPrompt },
                set: { state.settings.setSystemPrompt($0) }))
                .font(Native.bodyFont)
                .foregroundStyle(Native.label)
                .scrollContentBackground(.hidden)
                .frame(height: 120)
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: Native.radiusTile, style: .continuous)
                        .fill(Native.recess)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Native.radiusTile, style: .continuous)
                        .strokeBorder(Native.hairline, lineWidth: 0.8)
                }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("恢复默认") { state.resetChatParameters() }
                .buttonStyle(.arcadeGlass)
            Spacer(minLength: 0)
            Button("完成") { dismiss() }
                .buttonStyle(.arcadePill)
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 12)
    }

    private func slider(_ label: String, value: Double, range: ClosedRange<Double>,
                        format: String, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(L10n.t(label))
                .font(Native.bodyFont)
                .foregroundStyle(Native.secondary)
                .frame(width: 72, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
                .tint(Native.accent)
            Text(String(format: format, value))
                .font(Native.monoSmall)
                .foregroundStyle(Native.tertiary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
