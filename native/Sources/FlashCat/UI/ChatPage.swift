import SwiftUI
import AppKit
import FlashCatKit

/// 对话页：流式输出、思考块、Markdown 正文、生成参数与最近会话。
struct ChatPage: View {
    @ObservedObject var state: AppState

    @State private var draft = ""
    @State private var showsParameters = false
    @State private var showsThreads = false
    @FocusState private var composerFocused: Bool

    private var title: String {
        if let first = state.messages.first(where: { $0.role == "user" && !$0.content.isEmpty }) {
            return String(first.content.prefix(40))
        }
        return "新对话"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            transcript
            Hairline()
            composer
        }
        .sheet(isPresented: $showsParameters) {
            ChatParametersSheet(state: state)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Native.label)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            modelMenu

            Button {
                showsThreads.toggle()
            } label: {
                Label("最近对话", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            .popover(isPresented: $showsThreads, arrowEdge: .bottom) {
                threadList
            }

            Button {
                showsParameters = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            .help("生成参数")

            Button {
                state.newConversation()
            } label: {
                Label("新对话", systemImage: "square.and.pencil")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(ArcadePillStyle(tone: .light, compact: true))
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.top, 26)
        .padding(.bottom, 12)
    }

    private var subtitle: String {
        let model = state.selectedModel.isEmpty ? "未选择模型" : state.shortModelName(state.selectedModel)
        let engine = state.activeEngine.displayName
        let context = state.contextWindowCeiling.map { " · 窗口 \(Format.tokens($0))" } ?? ""
        return "\(engine) · \(model)\(context)"
    }

    private var modelMenu: some View {
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
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(.system(size: 9.5))
                Text(state.selectedModel.isEmpty ? "选择模型" : state.shortModelName(state.selectedModel))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
            }
            .foregroundStyle(Native.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Native.overlay(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(state.generating)
    }

    private var threadList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("最近对话")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Native.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if state.threads.isEmpty {
                Text("还没有保存的对话")
                    .font(Native.captionFont)
                    .foregroundStyle(Native.tertiary)
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
                                .foregroundStyle(Native.label)
                                .lineLimit(1)
                            Text("\(thread.messages.count) 条 · \(Format.relative(thread.updatedAt))")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Native.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Hairline().padding(.vertical, 4)
            Button("清空历史") { state.clearThreads() }
                .buttonStyle(ArcadePillStyle(tone: .quietDanger, compact: true))
                .padding(10)
        }
        .frame(width: 260)
        .background(Native.canvas)
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
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Native.pagePadding)
                .padding(.vertical, 20)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .onChange(of: state.messages.count) { _, _ in
                scroll(proxy, animated: true)
            }
            .onChange(of: state.messages.last?.content.count ?? 0) { _, _ in
                if state.generating { scroll(proxy, animated: false) }
            }
            .onChange(of: state.currentThreadID) { _, _ in
                scroll(proxy, animated: false)
            }
            .onAppear { scroll(proxy, animated: false) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            BrandMark(size: 54)
            Text("问点什么")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Native.label)
            Text("回答由 \(state.activeEngine.displayName) 在本机生成，会话只留在本机。")
                .font(.system(size: 11.5))
                .foregroundStyle(Native.tertiary)
            HStack(spacing: 8) {
                ForEach(["解释一下什么是统一内存", "帮我写一个 Swift 并发示例", "总结这段日志里的错误"], id: \.self) { suggestion in
                    Button(suggestion) {
                        draft = suggestion
                        composerFocused = true
                    }
                    .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(composerPlaceholder,
                          text: $draft,
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .disabled(!state.isRunning || state.generating)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Native.recess)
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(composerFocused ? Native.accent.opacity(0.5) : Native.hairline,
                                                  lineWidth: 1)
                            }
                    }

                if state.generating {
                    Button {
                        state.cancelGeneration()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Native.red))
                    }
                    .buttonStyle(.plain)
                    .help("停止生成")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(canSend ? Native.pillText : Native.tertiary)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(canSend ? Native.pillFill : Native.overlay(0.06)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("发送（⌘↩）")
                }
            }

            HStack(spacing: 8) {
                Button {
                    state.regenerate()
                } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Native.tertiary)
                .disabled(!state.isRunning || state.generating || state.messages.isEmpty)

                Button {
                    state.copy(conversationText, label: "已复制整段对话")
                } label: {
                    Label("复制对话", systemImage: "doc.on.doc")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Native.tertiary)
                .disabled(state.messages.isEmpty)

                Spacer(minLength: 0)

                if !draft.isEmpty {
                    Text("≈ \(AppState.estimateTokens(draft)) tokens")
                        .font(Native.monoSmall)
                        .foregroundStyle(Native.tertiary)
                }
                Text("⌘↩ 发送")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Native.tertiary.opacity(0.8))
            }
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 12)
        .background(Native.surface)
    }

    private var composerPlaceholder: String {
        state.isRunning
            ? "给 \(state.activeEngine.displayName) 发一条消息…"
            : "启动本地服务后即可发送消息"
    }

    private var canSend: Bool {
        state.isRunning && !state.generating && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var conversationText: String {
        state.messages
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.role == "user" ? "你" : "AI")\n\($0.content)" }
            .joined(separator: "\n\n")
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state.isRunning, !state.generating else { return }
        draft = ""
        state.send(text)
    }
}

// MARK: - Message row

private struct MessageRow: View {
    @ObservedObject var state: AppState
    let message: ChatMessage
    @State private var showsReasoning = false

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 70) }
            if !isUser { avatar }
            VStack(alignment: .leading, spacing: 6) {
                if !isUser {
                    header
                    if let reasoning = message.reasoning, !reasoning.isEmpty {
                        reasoningBlock(reasoning)
                    }
                }
                content
                if !isUser { footer }
            }
            if !isUser { Spacer(minLength: 40) }
            if isUser { avatarUser }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var avatar: some View {
        BrandMark(size: 24)
    }

    private var avatarUser: some View {
        ZStack {
            Circle().fill(Native.overlay(0.08))
            Image(systemName: "person.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Native.secondary)
        }
        .frame(width: 24, height: 24)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(message.model.map(state.shortModelName) ?? state.activeEngine.displayName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Native.secondary)
            if message.streaming {
                Text("生成中")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Native.accent)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if isUser {
            Text(message.content)
                .font(.system(size: 13))
                .foregroundStyle(Native.pillText)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Native.pillFill)
                }
        } else if message.content.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message.reasoning?.isEmpty == false ? "思考中…" : "等待首个 token…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Native.tertiary)
            }
            .padding(.vertical, 4)
        } else {
            MarkdownView(text: message.content)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Native.overlay(0.035))
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(Native.hairline, lineWidth: 1)
                        }
                }
        }
    }

    private func reasoningBlock(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showsReasoning.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showsReasoning ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(thinkingLabel)
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(Native.tertiary)
            }
            .buttonStyle(.plain)

            if showsReasoning {
                Text(reasoning)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Native.secondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Native.overlay(0.04))
                    }
            }
        }
    }

    private var thinkingLabel: String {
        if let seconds = message.thinkingSeconds, seconds > 0 {
            return String(format: "思考了 %.1f 秒", seconds)
        }
        return "思考过程"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let rate = message.rateText {
                Text(rate)
            }
            if message.tokenCount > 0 {
                Text("\(message.tokenCount) tokens")
            }
            if let ttft = message.firstTokenSeconds, ttft > 0 {
                Text(String(format: "首字 %.0f ms", ttft * 1000))
            }
            Spacer(minLength: 4)
            if !message.streaming {
                Button {
                    state.copy(message.content, label: "已复制回答")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Native.tertiary)
                .help("复制回答")
            }
        }
        .font(Native.monoSmall)
        .foregroundStyle(Native.tertiary)
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
                        .foregroundStyle(Native.tertiary)
                }
                Spacer(minLength: 8)
                IconAction(systemName: "xmark", help: "关闭") { dismiss() }
            }
            .padding(.horizontal, Native.pagePadding)
            .padding(.vertical, 14)
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: Native.gap) {
                    Card("采样", subtitle: "越高越发散；留空的最大输出表示模型自身上限") {
                        VStack(spacing: 12) {
                            slider("温度", value: state.settings.temperature, range: 0...2,
                                   format: "%.2f") { state.settings.setTemperature($0) }
                            slider("top-p", value: state.settings.topP, range: 0...1,
                                   format: "%.2f") { state.settings.setTopP($0) }
                            HStack(spacing: 10) {
                                Text("最大输出")
                                    .font(Native.bodyFont)
                                    .foregroundStyle(Native.secondary)
                                    .frame(width: 76, alignment: .leading)
                                TextField("模型上限", text: Binding(
                                    get: { state.settings.maxTokens > 0 ? String(state.settings.maxTokens) : "" },
                                    set: { state.settings.setMaxTokens(Int($0) ?? 0) }))
                                    .textFieldStyle(.roundedBorder)
                                    .font(Native.monoFont)
                                    .frame(width: 120)
                                Text("实际生效 \(state.effectiveMaxTokens) tokens")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Native.tertiary)
                                Spacer(minLength: 0)
                            }
                        }
                    }

                    Card("思考", subtitle: "思考模式的默认值与推理等级") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("", selection: Binding(
                                get: { state.settings.thinkingMode },
                                set: { state.settings.setThinkingMode($0) })) {
                                ForEach(ThinkingMode.allCases, id: \.self) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Picker("推理等级", selection: Binding(
                                get: { state.settings.reasoningEffort },
                                set: { state.settings.setReasoningEffort($0) })) {
                                ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                                    Text(effort.label).tag(effort)
                                }
                            }
                            .disabled(state.settings.thinkingMode != .on)

                            Text("思考 token 预算由引擎配置决定（引擎页 → 配置…）")
                                .font(.system(size: 10))
                                .foregroundStyle(Native.tertiary)
                        }
                    }

                    Card("系统提示", subtitle: "留空则不附加系统消息") {
                        TextEditor(text: Binding(
                            get: { state.settings.systemPrompt },
                            set: { state.settings.setSystemPrompt($0) }))
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .frame(height: 90)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Native.recess))
                    }
                }
                .padding(Native.pagePadding)
            }
            .scrollIndicators(.never)
            Hairline()
            HStack(spacing: 10) {
                Button("恢复默认") { state.resetChatParameters() }
                    .buttonStyle(.arcadeGlass)
                Spacer(minLength: 0)
                Button("完成") { dismiss() }
                    .buttonStyle(.arcadePill)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Native.pagePadding)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 560)
        .background(Native.canvas)
    }

    private func slider(_ label: String, value: Double, range: ClosedRange<Double>,
                        format: String, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Native.bodyFont)
                .foregroundStyle(Native.secondary)
                .frame(width: 76, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
            Text(String(format: format, value))
                .font(Native.monoSmall)
                .foregroundStyle(Native.tertiary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
