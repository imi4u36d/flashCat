import SwiftUI
import AppKit
import FlashCatKit

/// 对话页：按 WebUI 版式——顶部模型行、居中空态、悬浮输入卡。
struct ChatPage: View {
    @ObservedObject var state: AppState

    @State private var draft = ""
    @State private var showsParameters = false
    @State private var showsThreads = false
    @State private var atBottom = true
    @State private var keyMonitor: Any?
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
        }
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
            .disabled(state.generating)

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
            if state.threads.isEmpty {
                Text("还没有保存的对话")
                    .font(.system(size: 11))
                    .foregroundStyle(Console.tertiary)
                    .padding(12)
            } else {
                ForEach(state.threads) { thread in
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

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if state.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(state.messages) { message in
                            MessageRow(state: state, message: message)
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
                .animation(Motion.entrance, value: state.messages.count)
            }
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 90
            } action: { _, bottom in
                if atBottom != bottom { withAnimation(Motion.quick) { atBottom = bottom } }
            }
            .onChange(of: state.messages.count) { _, _ in scroll(proxy, animated: true, force: true) }
            .onChange(of: state.messages.last?.content.count ?? 0) { _, _ in
                if state.generating, atBottom { scroll(proxy, animated: false) }
            }
            .onChange(of: state.currentThreadID) { _, _ in scroll(proxy, animated: false, force: true) }
            .onAppear { scroll(proxy, animated: false, force: true) }
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

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool, force: Bool = false) {
        guard force || atBottom else { return }
        if animated {
            withAnimation(Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
        atBottom = true
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 24)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Console.accent.opacity(0.28), .clear],
                                         center: .center, startRadius: 4, endRadius: 56))
                    .frame(width: 120, height: 120)
                BrandMark(size: 76)
            }
            Text("把推理留在这台 Mac 上")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Console.text)
            Text("当前由 **\(state.activeEngine.displayName)** 加载 **\(state.selectedModel.isEmpty ? "未选择模型" : state.shortModelName(state.selectedModel))**。数据不出本机，离线也能用。")
                .font(.system(size: 13.5))
                .foregroundStyle(Console.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            HStack(spacing: 10) {
                suggestion("用三句话介绍本地大模型的优势")
                suggestion("总结这段对话的要点")
            }
            .padding(.top, 6)
            Spacer(minLength: 120)
        }
        .frame(maxWidth: .infinity)
    }

    private func suggestion(_ text: String) -> some View {
        Button {
            draft = text
            composerFocused = true
        } label: {
            Text(L10n.t(text))
                .font(.system(size: 12))
                .foregroundStyle(Console.secondary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background {
                    LiquidGlassSurface(shape: Capsule(), interactive: true)
                }
        }
        .buttonStyle(.plainHit)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 10) {
            // 用竖向 TextField 代替 TextEditor：没有自带滚动条，点击即可聚焦并显示光标。
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($composerFocused)
                .disabled(!state.canChat || state.generating)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .onKeyPress(phases: .down) { press in
                    guard press.key == .return else { return .ignored }
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }

            HStack(spacing: 10) {
                Menu {
                    ForEach(EngineCatalog.allIDs.filter { state.engineIsInstalled($0) }, id: \.self) { id in
                        Section(id.displayName) {
                            ForEach(state.engineModels(for: id).filter { !$0.hidden && !$0.helper }) { model in
                                Button(state.shortModelName(model.id)) {
                                    state.applyModelFromAnyEngine(model.id, engine: id)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Console.secondary)
                        Text(L10n.t(state.selectedModel.isEmpty ? "选择模型" : state.shortModelName(state.selectedModel)))
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(Console.tertiary)
                    }
                    .foregroundStyle(Console.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tint(Console.secondary)

                Button {
                    showsParameters = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10, weight: .semibold))
                        Text("参数")
                            .font(.system(size: 11.5))
                    }
                    .foregroundStyle(Console.secondary)
                }
                .buttonStyle(.plainHit)

                Menu {
                    Button {
                        state.settings.setThinkingMode(.automatic)
                    } label: {
                        if state.settings.thinkingMode == .automatic {
                            Label(ThinkingMode.automatic.label, systemImage: "checkmark")
                        } else {
                            Text(ThinkingMode.automatic.label)
                        }
                    }
                    Button {
                        state.settings.setThinkingMode(.off)
                    } label: {
                        if state.settings.thinkingMode == .off {
                            Label(ThinkingMode.off.label, systemImage: "checkmark")
                        } else {
                            Text(ThinkingMode.off.label)
                        }
                    }
                    Divider()
                    ForEach(availableEfforts, id: \.self) { effort in
                        Button {
                            state.settings.setReasoningEffort(effort)
                            state.settings.setThinkingMode(.on)
                        } label: {
                            if state.settings.thinkingMode == .on, state.settings.reasoningEffort == effort {
                                Label(effort.label, systemImage: "checkmark")
                            } else {
                                Text(effort.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "brain")
                            .font(.system(size: 10, weight: .semibold))
                        Text("思考 · \(thinkingLabel)")
                            .font(.system(size: 11.5))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7.5, weight: .bold))
                    }
                    .foregroundStyle(Console.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tint(Console.secondary)

                Spacer(minLength: 0)

                if !draft.isEmpty {
                    Text("≈ \(AppState.estimateTokens(draft)) tokens")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                }

                if state.generating {
                    Button {
                        state.cancelGeneration()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
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
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background {
                                LiquidGlassSurface(shape: Circle(),
                                                   tint: Console.accent,
                                                   interactive: true)
                            }
                    }
                    .buttonStyle(.plainHit)
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.45)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 780)
        .background {
            LiquidGlassSurface(
                shape: RoundedRectangle(cornerRadius: 18, style: .continuous),
                tint: nil
            )
        }
    }

    private var thinkingLabel: String {
        switch state.settings.thinkingMode {
        case .automatic: return "自动"
        case .off: return "关闭"
        case .on: return state.settings.reasoningEffort.label
        }
    }

    /// 引擎会报出当前模型支持的思考等级；没报就退回内置全集。
    private var availableEfforts: [ReasoningEffort] {
        guard let tokens = state.controller?.status?.reasoningEfforts, !tokens.isEmpty else {
            return ReasoningEffort.allCases
        }
        let mapped = tokens.compactMap { token in
            ReasoningEffort.allCases.first { $0.token == token.lowercased() }
        }
        return mapped.isEmpty ? ReasoningEffort.allCases : mapped
    }

    private var canSend: Bool {
        state.canChat && !state.generating && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var conversationText: String {
        state.messages
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.role == "user" ? "你" : "AI")\n\($0.content)" }
            .joined(separator: "\n\n")
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state.canChat, !state.generating else { return }
        draft = ""
        state.send(text)
    }
}

// MARK: - Message row

private struct MessageRow: View {
    @ObservedObject var state: AppState
    let message: ChatMessage
    @State private var manualThinking: Bool?
    @State private var caretVisible = false

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
                        Text(message.model.map(state.shortModelName) ?? state.activeEngine.displayName)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Console.secondary)
                        if message.streaming {
                            Text("生成中")
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
                            Text(L10n.t(message.reasoning?.isEmpty == false ? "思考中…" : "等待首个 token…"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Console.tertiary)
                        }
                    } else {
                        ZStack(alignment: .bottomTrailing) {
                            MarkdownView(text: message.content)
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

    private var footer: some View {
        HStack(spacing: 10) {
            if let rate = message.rateText { Text(rate) }
            if message.tokenCount > 0 { Text("\(message.tokenCount) tokens") }
            if let ttft = message.firstTokenSeconds, ttft > 0 {
                Text(L10n.format("首字 %.0f ms", ttft * 1000))
            }
            Spacer(minLength: 4)
            if !message.streaming {
                Button {
                    state.copy(message.content, label: "已复制回答")
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 9.5))
                }
                .buttonStyle(.plainHit)
                .foregroundStyle(Console.tertiary)
            }
        }
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(Console.tertiary)
    }
}

// MARK: - Parameters

struct ChatParametersSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("生成参数")
                        .font(.system(size: 15, weight: .semibold))
                    Text("这些默认值会随每条消息一起发送")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Console.tertiary)
                }
                Spacer(minLength: 8)
                IconAction(systemName: "xmark", help: "关闭") { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider().overlay(Console.insetStroke)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GlassCard(padding: 16) {
                        VStack(spacing: 14) {
                            slider("温度", value: state.settings.temperature, range: 0...2,
                                   format: "%.2f") { state.settings.setTemperature($0) }
                            slider("top-p", value: state.settings.topP, range: 0...1,
                                   format: "%.2f") { state.settings.setTopP($0) }
                            HStack(spacing: 10) {
                                Text("最大输出")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Console.secondary)
                                    .frame(width: 70, alignment: .leading)
                                TextField("模型上限", text: Binding(
                                    get: { state.settings.maxTokens > 0 ? String(state.settings.maxTokens) : "" },
                                    set: { state.settings.setMaxTokens(Int($0) ?? 0) }))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .frame(width: 110)
                                Text("生效 \(state.effectiveMaxTokens)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Console.tertiary)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    GlassCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("系统提示")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Console.text)
                            TextEditor(text: Binding(
                                get: { state.settings.systemPrompt },
                                set: { state.settings.setSystemPrompt($0) }))
                                .font(.system(size: 12))
                                .scrollContentBackground(.hidden)
                                .frame(height: 100)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Console.inset))
                        }
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.never)
            Divider().overlay(Console.insetStroke)
            HStack(spacing: 10) {
                Button("恢复默认") { state.resetChatParameters() }
                    .buttonStyle(.consoleSoft)
                Spacer(minLength: 0)
                Button("完成") { dismiss() }
                    .buttonStyle(.consolePrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 500, height: 500)
        .background(Console.cardStrong)
    }

    private func slider(_ label: String, value: Double, range: ClosedRange<Double>,
                        format: String, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(L10n.t(label))
                .font(.system(size: 12))
                .foregroundStyle(Console.secondary)
                .frame(width: 70, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
            Text(String(format: format, value))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Console.tertiary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
