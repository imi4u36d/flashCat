import SwiftUI
import AppKit

/// Native macOS chat page. Mirrors the behaviour of the Flutter chat page
/// (streaming, stop/regenerate, parameters, history) with a quiet AppKit look.
struct ChatView: View {
    @ObservedObject var state: AppState

    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var showParameters = false
    @State private var showClearConfirm = false
    @State private var showNewChatConfirm = false
    @State private var showClearHistoryConfirm = false

    @State private var temperature: Double = 0.7
    @State private var topP: Double = 0.95
    @State private var maxTokens: Int = 4096
    @State private var systemPrompt = ""
    @State private var thinkingMode: ThinkingMode = .automatic
    @State private var reasoningEffort: ReasoningEffort = .medium

    /// Timestamps are not part of ChatMessage, so they are tracked per view.
    /// Messages restored from disk carry no time and simply omit it.
    @State private var stamps: [UUID: Date] = [:]
    @State private var undated: Set<UUID> = []
    @State private var suppressDating = false

    @State private var generationStartedAt: Date?
    @State private var nearBottom = true

    private let bottomAnchor = "chat.bottom"

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = min(proxy.size.width, Native.contentMaxWidth)
            let inlinePanel = contentWidth - Native.pagePadding * 2 >= 1000
            VStack(alignment: .leading, spacing: 12) {
                header
                ZStack {
                    HStack(alignment: .top, spacing: Native.gap) {
                        chatSurface
                        if showParameters && inlinePanel {
                            parametersPanel
                                .frame(width: 300)
                                .frame(maxHeight: .infinity)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }

                    if showParameters && !inlinePanel {
                        Color.black.opacity(0.12)
                            .contentShape(Rectangle())
                            .onTapGesture { closeParameters() }
                            .transition(.opacity)
                        HStack(spacing: 0) {
                            Spacer(minLength: 80)
                            parametersPanel
                                .frame(width: min(320, max(260, proxy.size.width - 120)))
                                .frame(maxHeight: .infinity)
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .padding(Native.pagePadding)
            .frame(maxWidth: Native.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.16), value: showParameters)
        }
        .background(Native.surface)
        .onAppear(perform: prepare)
        .onChange(of: draft) { _, value in ChatDraftCache.text = value }
        .onChange(of: state.messages.map(\.id)) { _, _ in syncStamps() }
        .onChange(of: state.generating) { _, generating in
            if generating {
                generationStartedAt = Date()
            } else {
                generationStartedAt = nil
            }
        }
        .alert("清空当前对话？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { clearConversation() }
        } message: {
            Text("只会删除界面上的记录，不会影响模型或推理服务。")
        }
        .alert("开始新对话？", isPresented: $showNewChatConfirm) {
            Button("取消", role: .cancel) {}
            Button("新建对话") { startNewConversation() }
        } message: {
            Text("当前对话会记入侧栏的「最近」，可以随时重新打开；不会影响模型或推理服务。")
        }
        .alert("清空最近对话？", isPresented: $showClearHistoryConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空历史", role: .destructive) {
                state.clearThreads()
                state.toast("已清空最近对话")
            }
        } message: {
            Text("只会清空侧栏里的历史记录，当前对话与本地模型不受影响。")
        }
        .background(ChatKeyCatcher(onKey: handleKeyEvent))
    }

    // MARK: - Header

    private var header: some View {
        PageHeader(title: topicTitle,
                   subtitle: "\(state.selectedModel.isEmpty ? "—" : state.selectedModel) · 本地上下文") {
            Tag(text: readyText, tone: readyTone, icon: "circle.fill")

            HStack(spacing: 6) {
                historyMenu

                IconAction(systemName: "slider.horizontal.3",
                           help: "对话参数",
                           active: showParameters) {
                    toggleParameters()
                }

                IconAction(systemName: "doc.on.doc", help: "复制整段对话") {
                    copyConversation()
                }
                .disabled(state.messages.isEmpty)
                .opacity(state.messages.isEmpty ? 0.45 : 1)

                IconAction(systemName: "trash", help: "清空对话") {
                    requestClear()
                }
                .disabled(state.messages.isEmpty)
                .opacity(state.messages.isEmpty ? 0.45 : 1)

                IconAction(systemName: "square.and.pencil", help: "新对话（⌘N）") {
                    requestNewChat()
                }
            }
        }
    }

    private var historyMenu: some View {
        Menu {
            if state.threads.isEmpty {
                Text("暂无历史对话")
            } else {
                ForEach(state.threads) { thread in
                    Button {
                        open(thread)
                    } label: {
                        Text("\(thread.title) · \(Format.relative(thread.updatedAt))")
                    }
                }
                Divider()
                Menu("删除对话") {
                    ForEach(state.threads) { thread in
                        Button(thread.title, role: .destructive) {
                            state.deleteThread(thread)
                        }
                    }
                }
                Button("清空最近对话…") { showClearHistoryConfirm = true }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .fixedSize()
        .help("最近对话")
    }

    private var readyText: String {
        switch state.serverState {
        case .ready: return "就绪"
        case .starting: return "启动中"
        case .stopping: return "停止中"
        case .failed: return "异常"
        case .stopped: return "未就绪"
        }
    }

    private var readyTone: TagTone {
        switch state.serverState {
        case .ready: return .success
        case .starting, .stopping: return .warning
        case .failed: return .danger
        case .stopped: return .neutral
        }
    }

    // MARK: - Chat surface

    private var chatSurface: some View {
        Card(padded: false) {
            VStack(spacing: 0) {
                messageArea
                if !state.isReady {
                    serviceBanner
                }
                if state.generating, let message = state.messages.last, message.streaming {
                    LiveStrip(message: message,
                              startedAt: generationStartedAt ?? Date(),
                              status: state.generationStatus)
                }
                Hairline()
                composer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messageArea: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        VStack(spacing: 0) {
                            if state.messages.isEmpty {
                                ChatEmptyState { suggestion in
                                    draft = suggestion
                                    composerFocused = true
                                }
                                .frame(minHeight: max(proxy.size.height - 32, 280))
                            } else {
                                messageList
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchor)
                                .background(
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: ChatBottomKey.self,
                                            value: geometry.frame(in: .named("chatScroll")).maxY
                                        )
                                    }
                                )
                        }
                        .frame(maxWidth: 880)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 22)
                        .padding(.top, 16)
                        .padding(.bottom, 2)
                    }
                    .coordinateSpace(name: "chatScroll")
                    .onPreferenceChange(ChatBottomKey.self) { bottom in
                        let atBottom = bottom <= proxy.size.height + 64
                        if atBottom != nearBottom { nearBottom = atBottom }
                    }

                    if !nearBottom && !state.messages.isEmpty {
                        Button {
                            nearBottom = true
                            scrollToBottom(scrollProxy, animated: true)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("最新")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(Native.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Native.raised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Native.hairline, lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(14)
                        .help("跳到最新消息")
                        .transition(.opacity)
                    }
                }
                .onAppear {
                    scrollProxy.scrollTo(bottomAnchor, anchor: .bottom)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        scrollProxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
                .onChange(of: state.messages.map(\.id)) { _, _ in
                    nearBottom = true
                    DispatchQueue.main.async {
                        scrollProxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
                .onChange(of: state.messages.last?.content) { _, _ in
                    guard state.generating, nearBottom else { return }
                    scrollProxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
                .onChange(of: state.generating) { _, generating in
                    guard generating else { return }
                    nearBottom = true
                    DispatchQueue.main.async {
                        scrollProxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: nearBottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messageList: some View {
        ForEach(Array(state.messages.enumerated()), id: \.element.id) { index, message in
            MessageRow(
                message: message,
                modelName: modelLabel,
                stamp: undated.contains(message.id) ? nil : stamps[message.id],
                streamingStatus: message.streaming ? state.generationStatus : nil,
                canRegenerate: !state.generating
                    && index == state.messages.count - 1
                    && message.role == "assistant"
                    && !isError(message),
                onCopy: {
                    state.copy(message.content, label: "已复制消息")
                },
                onRegenerate: { regenerate() },
                onCopyCode: { code in
                    state.copy(code, label: "已复制代码")
                }
            )
            .equatable()
            .padding(.bottom, 18)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: - Service banner

    private var serviceBanner: some View {
        let starting = state.serverState == .starting
        let stopping = state.serverState == .stopping
        let busy = starting || stopping
        let missingRuntime = state.runtimeMissing != nil
        let title: String
        if missingRuntime {
            title = "未找到内置推理运行时，无法启动对话服务。"
        } else if starting {
            title = "正在启动服务，就绪后即可对话…"
        } else if stopping {
            title = "正在停止服务…"
        } else {
            title = "推理服务未运行，启动后即可继续对话。"
        }

        return HStack(spacing: 9) {
            if busy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: missingRuntime ? "exclamationmark.triangle" : "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(missingRuntime ? Native.red : Native.orange)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(missingRuntime ? Native.red : (busy ? Native.secondary : Native.orange))
                Text(verbatim: missingRuntime ? "请重新安装应用以恢复运行时" : "端口 \(state.port) · \(state.startupStage)")
                    .font(.system(size: 10))
                    .foregroundStyle(Native.tertiary)
            }

            Spacer(minLength: 8)

            if !missingRuntime {
                Button(busy ? (starting ? "启动中…" : "停止中…") : "启动服务") {
                    state.startService()
                }
                .controlSize(.small)
                .disabled(busy)

                if state.isRunning {
                    Button("停止") { state.stopService() }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background((missingRuntime ? Native.red : Native.orange).opacity(0.07))
        .overlay(alignment: .top) { Hairline() }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(composerPlaceholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Native.bodyFont)
                .lineLimit(1...6)
                .focused($composerFocused)
                .focusEffectDisabled()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Native.raised, in: RoundedRectangle(cornerRadius: Native.radiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Native.radiusSmall, style: .continuous)
                        .stroke(composerFocused ? Native.accent.opacity(0.55) : Native.hairline, lineWidth: 1)
                )

            HStack(spacing: 6) {
                modelChip
                temperatureChip
                thinkingChip

                Spacer(minLength: 8)

                Text("⌘↩ 发送 · ⇧↩ 换行")
                    .font(.system(size: 10))
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)

                sendButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var composerPlaceholder: String {
        state.isReady
            ? "输入消息，Enter 发送，Shift+Enter 换行"
            : "启动本地服务后即可发送消息"
    }

    private var modelChip: some View {
        Menu {
            if state.catalog.machine.isEmpty {
                Text("没有本地模型")
                Button("打开模型页…") { state.section = .models }
            } else {
                ForEach(state.catalog.machine) { model in
                    Button {
                        applyModel(model.id)
                    } label: {
                        if model.id == state.selectedModel {
                            Label(model.shortName, systemImage: "checkmark")
                        } else {
                            Text(model.shortName)
                        }
                    }
                }
                Divider()
                Button("管理模型…") { state.section = .models }
            }
        } label: {
            ComposerChipLabel(icon: "shippingbox",
                              text: state.selectedModel.isEmpty ? "选择模型" : modelLabel,
                              chevron: true,
                              maxWidth: 180)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(state.selectedModel.isEmpty ? "选择模型" : state.selectedModel)
    }

    private var temperatureChip: some View {
        Button {
            toggleParameters()
        } label: {
            ComposerChipLabel(icon: "thermometer.medium",
                              text: "温度 \(String(format: "%.2f", temperature))")
        }
        .buttonStyle(.plain)
        .help("调整对话参数")
    }

    private var thinkingChip: some View {
        Menu {
            ForEach(ThinkingMode.allCases, id: \.self) { mode in
                Button {
                    setThinking(mode)
                } label: {
                    if mode == thinkingMode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
            Divider()
            Button("更多参数…") { openParameters() }
        } label: {
            ComposerChipLabel(icon: "sparkles",
                              text: "思考 \(thinkingMode.label)",
                              chevron: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("思考模式")
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state.isReady
            && !state.selectedModel.isEmpty
    }

    private var sendButton: some View {
        Button {
            if state.generating {
                state.cancelGeneration()
                state.toast("已停止生成")
            } else {
                submitFromComposer()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(state.generating ? Native.red : Native.accent)
                Image(systemName: state.generating ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(!state.generating && !canSend)
        .opacity(state.generating || canSend ? 1 : 0.4)
        .help(state.generating ? "停止生成" : "发送消息（⌘↩）")
        .accessibilityLabel(state.generating ? "停止生成" : "发送消息")
    }

    // MARK: - Parameters panel

    private var parametersPanel: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("对话参数")
                        .font(.system(size: 13, weight: .semibold))
                    Text("参数会保存到本机设置")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Native.tertiary)
                }
                Spacer(minLength: 4)
                Button {
                    closeParameters()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Native.secondary)
                .help("关闭参数面板（Esc）")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    panelLabel("模型")
                    modelPicker

                    sliderBlock("Temperature",
                                value: Binding(get: { temperature },
                                               set: { setTemperature($0) }),
                                range: 0...2,
                                detail: "越低越稳定，越高越有创造性")

                    sliderBlock("Top P",
                                value: Binding(get: { topP },
                                               set: { setTopP($0) }),
                                range: 0.05...1,
                                detail: "只从概率最高的一部分词里采样")

                    VStack(alignment: .leading, spacing: 6) {
                        panelLabel("最大生成 tokens")
                        HStack(spacing: 6) {
                            TextField("", value: Binding(get: { maxTokens },
                                                        set: { setMaxTokens($0) }),
                                      format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(Native.monoFont)
                                .frame(width: 84)
                                .onChange(of: maxTokens) { _, value in
                                    state.settings.setMaxTokens(value)
                                }
                            Stepper("", value: Binding(get: { maxTokens },
                                                       set: { setMaxTokens($0) }),
                                    in: 128...131_072,
                                    step: 512)
                                .labelsHidden()
                            Spacer()
                        }
                        Text("单次回复允许生成的最大长度")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Native.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        panelLabel("思考模式")
                        Picker("", selection: Binding(get: { thinkingMode },
                                                      set: { setThinking($0) })) {
                            ForEach(ThinkingMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)

                        if thinkingMode == .on {
                            HStack(spacing: 8) {
                                Text("推理等级")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Native.secondary)
                                Picker("", selection: Binding(get: { reasoningEffort },
                                                              set: { setReasoningEffort($0) })) {
                                    ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                                        Text(effort.label).tag(effort)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .controlSize(.small)
                                .frame(maxWidth: 110)
                            }
                        }

                        Text(thinkingMode.detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Native.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        panelLabel("系统提示词")
                        ZStack(alignment: .topLeading) {
                            if systemPrompt.isEmpty {
                                Text("例如：回答保持简洁、准确。")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Native.tertiary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: Binding(get: { systemPrompt },
                                                     set: { setSystemPrompt($0) }))
                                .font(.system(size: 12))
                                .scrollContentBackground(.hidden)
                                .frame(height: 92)
                                .padding(4)
                        }
                        .background(Native.raised, in: RoundedRectangle(cornerRadius: Native.radiusSmall, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Native.radiusSmall, style: .continuous)
                                .stroke(Native.hairline, lineWidth: 1)
                        )
                    }

                    if !state.isRunning {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 10))
                            Text("参数可在服务未运行时调整，启动后生效。")
                                .font(.system(size: 10.5))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Native.tertiary)
                    }
                }
                .padding(14)
            }

            Hairline()

            HStack(spacing: 8) {
                Button("恢复默认") { restoreDefaults() }
                    .controlSize(.small)
                Spacer(minLength: 6)
                Button("完成") { closeParameters() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Native.panel, in: RoundedRectangle(cornerRadius: Native.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Native.radiusPanel, style: .continuous)
                .stroke(Native.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 18, y: 6)
    }

    private var modelPicker: some View {
        Group {
            if state.catalog.machine.isEmpty {
                HStack(spacing: 6) {
                    Text("没有可用模型")
                        .font(.system(size: 11))
                        .foregroundStyle(Native.tertiary)
                    Spacer()
                    Button("模型页") { state.section = .models }
                        .controlSize(.mini)
                }
            } else {
                Picker("", selection: Binding(get: { state.selectedModel },
                                              set: { applyModel($0) })) {
                    ForEach(state.catalog.machine) { model in
                        Text(model.shortName).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func sliderBlock(_ label: String,
                             value: Binding<Double>,
                             range: ClosedRange<Double>,
                             detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(Native.monoFont)
                    .foregroundStyle(Native.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(Native.tertiary)
        }
    }

    private func panelLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Native.secondary)
    }

    // MARK: - Actions

    private func prepare() {
        loadParameters()
        restoreStamps()
        seedStamps()
        draft = ChatDraftCache.text
        if state.generating { generationStartedAt = Date() }
    }

    private func restoreStamps() {
        stamps = ChatStampCache.stamps
        undated = ChatStampCache.undated
    }

    private func saveStamps() {
        ChatStampCache.stamps = stamps
        ChatStampCache.undated = undated
    }

    private func resetStamps() {
        stamps.removeAll()
        undated.removeAll()
        saveStamps()
    }

    private func loadParameters() {
        temperature = state.settings.temperature
        topP = state.settings.topP
        maxTokens = state.settings.maxTokens
        systemPrompt = state.settings.systemPrompt
        thinkingMode = state.settings.thinkingMode
        reasoningEffort = state.settings.reasoningEffort
    }

    private func toggleParameters() {
        if showParameters {
            closeParameters()
        } else {
            openParameters()
        }
    }

    private func openParameters() {
        loadParameters()
        showParameters = true
    }

    private func closeParameters() {
        persistParameters()
        showParameters = false
    }

    private func persistParameters() {
        state.settings.setTemperature(temperature)
        state.settings.setTopP(topP)
        state.settings.setMaxTokens(maxTokens)
        state.settings.setSystemPrompt(systemPrompt)
        state.settings.setThinkingMode(thinkingMode)
        state.settings.setReasoningEffort(reasoningEffort)
    }

    private func setTemperature(_ value: Double) {
        temperature = min(max(value, 0), 2)
        state.settings.setTemperature(temperature)
    }

    private func setTopP(_ value: Double) {
        topP = min(max(value, 0.05), 1)
        state.settings.setTopP(topP)
    }

    private func setMaxTokens(_ value: Int) {
        maxTokens = min(max(value, 128), 131_072)
        state.settings.setMaxTokens(maxTokens)
    }

    private func setSystemPrompt(_ value: String) {
        systemPrompt = value
        state.settings.setSystemPrompt(value)
    }

    private func setThinking(_ mode: ThinkingMode) {
        thinkingMode = mode
        state.settings.setThinkingMode(mode)
    }

    private func setReasoningEffort(_ effort: ReasoningEffort) {
        reasoningEffort = effort
        state.settings.setReasoningEffort(effort)
    }

    private func restoreDefaults() {
        state.resetChatParameters()
        loadParameters()
        temperature = 0.7
        topP = 0.95
        maxTokens = 4096
        systemPrompt = ""
        thinkingMode = .automatic
    }

    private func applyModel(_ id: String) {
        guard id != state.selectedModel else { return }
        guard !state.generating else {
            state.toast("正在生成，先停止再切换模型")
            return
        }
        state.applyModel(id)
        state.toast("已切换到 \(shortModel(id))")
    }

    private func submitFromComposer() {
        // Read the live editor text so the last keystroke before Return is not lost.
        var value = draft
        if composerFocused, !hasMarkedText,
           let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            value = editor.string
        }
        submit(value)
    }

    private func submit(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !state.generating else { return }
        guard state.isReady else {
            state.toast("推理服务未运行，请先启动服务")
            return
        }
        guard !state.selectedModel.isEmpty else {
            state.toast("请先选择模型")
            return
        }
        draft = ""
        composerFocused = true
        state.send(value)
        nearBottom = true
    }

    private func regenerate() {
        guard !state.generating else { return }
        guard state.isReady else {
            state.toast("服务未就绪，无法重新生成")
            return
        }
        guard state.messages.contains(where: { $0.role == "user" }) else { return }
        state.regenerate()
        nearBottom = true
    }

    private func requestClear() {
        guard !state.messages.isEmpty else {
            state.toast("当前没有对话记录")
            return
        }
        showClearConfirm = true
    }

    private func clearConversation() {
        state.newConversation()
        draft = ""
        resetStamps()
        composerFocused = true
        state.toast("对话已清空")
    }

    private func requestNewChat() {
        guard !state.generating else {
            state.toast("正在生成，先停止再新建对话")
            return
        }
        if state.messages.contains(where: { !$0.content.isEmpty }) {
            showNewChatConfirm = true
        } else {
            startNewConversation()
        }
    }

    private func startNewConversation() {
        state.newConversation()
        draft = ""
        resetStamps()
        composerFocused = true
        state.toast("已开始新对话")
    }

    private func open(_ thread: ChatThread) {
        guard !state.generating else {
            state.toast("正在生成，先停止再切换对话")
            return
        }
        let previousIDs = state.messages.map(\.id)
        suppressDating = true
        state.openThread(thread)
        if state.messages.map(\.id) == previousIDs {
            suppressDating = false
        }
        draft = ""
        state.toast("已打开「\(thread.title)」")
    }

    private func copyConversation() {
        let items = state.messages.filter {
            !$0.streaming && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !items.isEmpty else {
            state.toast("还没有可复制的对话")
            return
        }
        let body = items.map { message -> String in
            let who = message.role == "user" ? "你" : modelLabel
            let time = stamps[message.id].map { " · " + ChatFormat.clock($0) } ?? ""
            return "\(who)\(time)\n\(message.content)"
        }.joined(separator: "\n\n")
        state.copy(body, label: "已复制整段对话")
    }

    // MARK: - Keyboard

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard state.section == .chat,
              event.window?.isKeyWindow == true,
              NSApp.modalWindow == nil else { return false }

        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.keyCode
        let isReturn = key == 36 || key == 76
        let character = event.charactersIgnoringModifiers?.lowercased()

        // Let the input method commit marked text (pinyin, kana, ...) first.
        if isReturn, hasMarkedText { return false }

        if flags.contains(.command) && !flags.contains(.shift) && !flags.contains(.option) {
            if isReturn {
                if !state.generating { submitFromComposer() }
                return true
            }
            if character == "n" {
                requestNewChat()
                return true
            }
            if character == "o" {
                composerFocused = true
                return true
            }
        }

        if isReturn && flags.isEmpty && composerFocused {
            submitFromComposer()
            return true
        }

        if key == 53 && showParameters {
            closeParameters()
            return true
        }

        return false
    }

    private var hasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }

    // MARK: - Helpers

    private var modelLabel: String {
        if let info = state.selectedModelInfo { return info.shortName }
        let id = state.selectedModel
        if id.isEmpty { return "模型" }
        return id.split(separator: "/").last.map(String.init) ?? id
    }

    private var topicTitle: String {
        for message in state.messages where message.role == "user" {
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return topic(for: text) }
        }
        return "新对话"
    }

    private func topic(for text: String) -> String {
        let normalized = TextPattern.replace("\\s+", text, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return "新对话" }

        let rules: [(String, String)] = [
            ("(?i)(日志|延迟|ttft|首字|log)", "推理日志排查"),
            ("(?i)(flutter|dart|并发|下载器|代码)", "Flutter 并发下载"),
            ("(?i)(草稿|dflash|加速|投机)", "DFlash2 加速原理"),
            ("(?i)(sql|查询|索引|执行计划)", "SQL 查询优化"),
        ]
        for (pattern, title) in rules where TextPattern.test(pattern, normalized) {
            return title
        }
        return normalized.count > 18 ? String(normalized.prefix(18)) + "…" : normalized
    }

    private func shortModel(_ id: String) -> String {
        let value = id.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return "—" }
        return value.split(separator: "/").last.map(String.init) ?? value
    }

    private func isError(_ message: ChatMessage) -> Bool {
        message.content.hasPrefix("出错：")
    }

    private func seedStamps() {
        let now = Date()
        let ids = Set(state.messages.map(\.id))
        stamps = stamps.filter { ids.contains($0.key) }
        undated = undated.intersection(ids)
        for message in state.messages where stamps[message.id] == nil && !undated.contains(message.id) {
            stamps[message.id] = now
            undated.insert(message.id)
        }
        saveStamps()
    }

    private func syncStamps() {
        let now = Date()
        let ids = Set(state.messages.map(\.id))
        var nextStamps = stamps.filter { ids.contains($0.key) }
        var nextUndated = undated.intersection(ids)
        let suppress = suppressDating
        suppressDating = false

        for message in state.messages where nextStamps[message.id] == nil && !nextUndated.contains(message.id) {
            if suppress {
                nextUndated.insert(message.id)
            } else {
                nextStamps[message.id] = now
            }
        }

        stamps = nextStamps
        undated = nextUndated
        saveStamps()
    }
}

// MARK: - Key catcher

/// A local key monitor scoped to the lifetime of the chat page. Menu key
/// equivalents would otherwise steal ⌘N/⌘O and Return would insert newlines.
private struct ChatKeyCatcher: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView(frame: .zero)
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onKey = onKey
    }

    static func dismantleNSView(_ nsView: KeyView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class KeyView: NSView {
        var onKey: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                stopMonitoring()
            } else {
                startMonitoring()
            }
        }

        private func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let onKey = self.onKey,
                      self.window?.isKeyWindow == true else { return event }
                return onKey(event) ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

private struct ChatBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

private enum ChatFormat {
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func clock(_ date: Date) -> String { clock.string(from: date) }
}

/// ChatMessage has no creation date, so the page keeps its own in-session
/// stamps. The cache survives switching pages, not app relaunches.
private enum ChatStampCache {
    static var stamps: [UUID: Date] = [:]
    static var undated: Set<UUID> = []
}

/// Keeps a half-written message while the reader visits another page.
private enum ChatDraftCache {
    static var text = ""
}

// MARK: - Message row

private struct MessageRow: View {
    let message: ChatMessage
    let modelName: String
    let stamp: Date?
    let streamingStatus: String?
    let canRegenerate: Bool
    let onCopy: () -> Void
    let onRegenerate: () -> Void
    let onCopyCode: (String) -> Void

    @State private var hovered = false

    private var isUser: Bool { message.role == "user" }
    private var failed: Bool { message.content.hasPrefix("出错：") }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            if !isUser { assistantBadge }
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                meta
                content

                if failed {
                    Tag(text: "请求失败", tone: .danger, icon: "exclamationmark.triangle.fill")
                }

                if !isUser && !message.streaming && !failed {
                    metrics
                }

                if hovered && !message.streaming {
                    actions
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: isUser ? 620 : 690,
                   alignment: isUser ? .trailing : .leading)

            if isUser { userBadge }
            if !isUser { Spacer(minLength: 48) }
        }
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { hovered = hovering }
        }
        .contextMenu {
            Button("复制") { onCopy() }
            if canRegenerate {
                Button("重新生成") { onRegenerate() }
            }
        }
    }

    private var meta: some View {
        HStack(spacing: 7) {
            if isUser {
                if let stamp {
                    Text(ChatFormat.clock(stamp))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Native.tertiary)
                }
                Text("你")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Native.secondary)
            } else {
                Text(modelName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Native.secondary)
                    .lineLimit(1)
                if let stamp {
                    Text(ChatFormat.clock(stamp))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Native.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isUser {
            Text(message.content)
                .font(Native.bodyFont)
                .lineSpacing(3)
                .foregroundStyle(Native.label)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Native.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Native.hairline, lineWidth: 1)
                )
        } else if message.streaming && message.content.isEmpty {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.mini)
                Text(streamingStatus ?? "正在生成…")
                    .font(Native.calloutFont)
                    .foregroundStyle(Native.secondary)
            }
            .padding(.vertical, 3)
        } else if failed {
            Text(message.content)
                .font(Native.bodyFont)
                .lineSpacing(3)
                .foregroundStyle(Native.red)
                .textSelection(.enabled)
        } else {
            MarkdownText(text: message.content, onCopyCode: onCopyCode)
                .equatable()
        }
    }

    private var metrics: some View {
        HStack(spacing: 5) {
            if let rate = message.rateText {
                MetricChip(text: rate)
            }
            if message.tokenCount > 0 {
                MetricChip(text: "\(message.tokenCount) tokens")
            }
            if let seconds = message.seconds {
                MetricChip(text: String(format: "%.1fs", seconds))
            }
            if let first = message.firstTokenSeconds, first > 0 {
                MetricChip(text: String(format: "首字 %.0fms", first * 1000))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 3) {
            if canRegenerate {
                rowAction("arrow.clockwise", help: "重新生成", action: onRegenerate)
            }
            rowAction("doc.on.doc", help: "复制", action: onCopy)
        }
    }

    private func rowAction(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Native.secondary)
        .help(help)
    }

    private var assistantBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Native.accent.opacity(0.12))
            Image(systemName: "bolt.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Native.accent)
        }
        .frame(width: 22, height: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Native.accent.opacity(0.18), lineWidth: 1)
        )
        .help(modelName)
    }

    private var userBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Native.panel)
            Text("你")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Native.secondary)
        }
        .frame(width: 22, height: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Native.hairline, lineWidth: 1)
        )
    }
}

extension MessageRow: Equatable {
    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.content == rhs.message.content
            && lhs.message.streaming == rhs.message.streaming
            && lhs.message.usage?.completionTokens == rhs.message.usage?.completionTokens
            && lhs.message.seconds == rhs.message.seconds
            && lhs.message.tokensPerSecond == rhs.message.tokensPerSecond
            && lhs.message.firstTokenSeconds == rhs.message.firstTokenSeconds
            && lhs.modelName == rhs.modelName
            && lhs.stamp == rhs.stamp
            && lhs.streamingStatus == rhs.streamingStatus
            && lhs.canRegenerate == rhs.canRegenerate
    }
}

// MARK: - Empty state
private struct ChatEmptyState: View {
    let onSuggestion: (String) -> Void

    private static let suggestions: [(icon: String, title: String, detail: String, prompt: String)] = [
        ("terminal", "解释这段日志", "排查首字延迟",
         "帮我解释一下这段推理日志里的首字延迟为什么偏高"),
        ("bolt.fill", "写一个并发下载器", "Flutter · Dart",
         "用 Flutter 写一个并发下载器，限制最多 4 个并发，并显示进度"),
        ("sparkles", "草稿模型如何加速", "DFlash2 原理",
         "DFlash2 草稿模型是怎么加速解码的？用通俗的语言解释"),
        ("cylinder.split.1x2", "优化一段 SQL", "查询与执行计划",
         "帮我把这段 SQL 查询优化一下，并解释执行计划"),
    ]

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Native.accent.opacity(0.12))
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Native.accent)
            }
            .frame(width: 46, height: 46)

            VStack(spacing: 4) {
                Text("开始一次本地对话")
                    .font(.system(size: 17, weight: .semibold))
                Text("所有推理都在这台设备上完成。没有账号，没有云端，也没有内容上传。")
                    .font(Native.calloutFont)
                    .foregroundStyle(Native.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(Self.suggestions, id: \.title) { item in
                    SuggestionButton(icon: item.icon,
                                     title: item.title,
                                     detail: item.detail) {
                        onSuggestion(item.prompt)
                    }
                }
            }
            .frame(maxWidth: 520)
            .padding(.top, 4)

            HStack(spacing: 5) {
                KeyCap("↵")
                Text("发送 ·").font(.system(size: 10)).foregroundStyle(Native.tertiary)
                KeyCap("⇧")
                KeyCap("↵")
                Text("换行 ·").font(.system(size: 10)).foregroundStyle(Native.tertiary)
                KeyCap("⌘")
                KeyCap("↩")
                Text("发送").font(.system(size: 10)).foregroundStyle(Native.tertiary)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }
}

private struct SuggestionButton: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Native.accent)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Native.label)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Native.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Native.raised : Native.panel,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Native.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct KeyCap: View {
    let label: String

    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(Native.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Native.panel, in: RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Native.hairline, lineWidth: 1)
            )
    }
}

// MARK: - Metric chip

private struct MetricChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Native.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Native.panel, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Native.hairline, lineWidth: 1)
            )
    }
}

// MARK: - Live strip

private struct LiveStrip: View {
    let message: ChatMessage
    let startedAt: Date
    let status: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            let tokens = Self.estimateTokens(message.content)
            let firstToken = message.firstTokenSeconds
            let decodeSpan = max(elapsed - (firstToken ?? elapsed), 0)
            let rate: Double? = firstToken != nil && decodeSpan > 0.15
                ? Double(tokens) / decodeSpan
                : nil

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text(status ?? "生成中")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Native.accent)
                    .lineLimit(1)

                Spacer(minLength: 6)

                MetricChip(text: rate.map { String(format: "%.1f tok/s", $0) } ?? "— tok/s")
                MetricChip(text: firstToken.map { String(format: "首字 %.0fms", $0 * 1000) } ?? "首字 —")
                MetricChip(text: "≈\(tokens) tokens")
                MetricChip(text: String(format: "%.1fs", elapsed))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Native.panel)
            .overlay(alignment: .top) { Hairline() }
        }
    }

    private static func estimateTokens(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if scalar.value > 0x2E80 { cjk += 1 } else { other += 1 }
        }
        return max(1, cjk + other / 4)
    }
}

// MARK: - Composer chip label

private struct ComposerChipLabel: View {
    let icon: String
    let text: String
    var chevron = false
    var maxWidth: CGFloat = 220

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Native.tertiary)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Native.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: maxWidth, alignment: .leading)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Native.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(hovered ? Native.raised : Native.panel,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Native.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

// MARK: - Markdown-ish renderer

private enum MarkdownBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String, text: String)
    case quote(String)
    case bullet(marker: String, text: String)
    case rule
}

private struct MarkdownText: View {
    let text: String
    let onCopyCode: (String) -> Void

    var body: some View {
        let blocks = parseMarkdownBlocks(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let value):
                    inlineText(value)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .heading(let level, let value):
                    inlineText(value)
                        .font(.system(size: level == 1 ? 16 : (level == 2 ? 14.5 : 13.5),
                                      weight: .semibold))
                        .textSelection(.enabled)
                        .padding(.top, 2)

                case .code(let language, let value):
                    CodeBlockView(language: language, code: value, onCopy: onCopyCode)

                case .quote(let value):
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle()
                            .fill(Native.accent.opacity(0.4))
                            .frame(width: 2)
                        inlineText(value)
                            .lineSpacing(3)
                            .foregroundStyle(Native.secondary)
                            .textSelection(.enabled)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                case .bullet(let marker, let value):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker)
                            .font(Native.monoSmall)
                            .foregroundStyle(Native.tertiary)
                            .frame(minWidth: 12, alignment: .trailing)
                        inlineText(value)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                case .rule:
                    Hairline()
                        .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineText(_ source: String) -> Text {
        guard !source.isEmpty else { return Text("") }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard var attributed = try? AttributedString(markdown: source, options: options) else {
            return Text(source).font(Native.bodyFont).foregroundStyle(Native.label)
        }
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attributed[run.range].font = .system(size: 11.5, design: .monospaced)
            }
        }
        return Text(attributed)
            .font(Native.bodyFont)
            .foregroundStyle(Native.label)
    }
}

extension MarkdownText: Equatable {
    static func == (lhs: MarkdownText, rhs: MarkdownText) -> Bool {
        lhs.text == rhs.text
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String
    let onCopy: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(language)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Native.tertiary)
                Spacer(minLength: 4)
                Button {
                    onCopy(code)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                        Text("复制")
                            .font(.system(size: 9.5))
                    }
                    .foregroundStyle(Native.secondary)
                }
                .buttonStyle(.plain)
                .help("复制代码")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Native.panel)

            Hairline()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Native.label)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Native.raised)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Native.hairline, lineWidth: 1)
        )
    }
}

private func parseMarkdownBlocks(_ source: String) -> [MarkdownBlock] {
    let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.components(separatedBy: "\n")
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var index = 0

    func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        paragraph.removeAll()
    }

    while index < lines.count {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            flushParagraph()
            index += 1
            continue
        }

        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            flushParagraph()
            let marker = String(trimmed.prefix(3))
            let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            index += 1
            var code: [String] = []
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                if candidate.hasPrefix(marker) {
                    index += 1
                    break
                }
                code.append(lines[index])
                index += 1
            }
            blocks.append(.code(language: language.isEmpty ? "CODE" : language.uppercased(),
                                text: code.joined(separator: "\n")))
            continue
        }

        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            let value = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
            if (1...4).contains(hashes), !value.isEmpty {
                flushParagraph()
                blocks.append(.heading(level: hashes, text: value))
                index += 1
                continue
            }
        }

        if trimmed.hasPrefix(">") {
            flushParagraph()
            var quote: [String] = []
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                guard candidate.hasPrefix(">") else { break }
                quote.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                index += 1
            }
            blocks.append(.quote(quote.joined(separator: "\n")))
            continue
        }

        if let bullet = bulletMarker(trimmed) {
            flushParagraph()
            blocks.append(.bullet(marker: bullet.marker, text: bullet.text))
            index += 1
            continue
        }

        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            flushParagraph()
            blocks.append(.rule)
            index += 1
            continue
        }

        paragraph.append(line)
        index += 1
    }

    flushParagraph()
    return blocks.isEmpty ? [.paragraph("")] : blocks
}

private func bulletMarker(_ line: String) -> (marker: String, text: String)? {
    for prefix in ["- ", "* ", "+ ", "• "] where line.hasPrefix(prefix) {
        let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if !value.isEmpty { return ("•", value) }
    }

    var digits = ""
    var rest = Substring(line)
    while let first = rest.first, first.isNumber, digits.count < 3 {
        digits.append(first)
        rest = rest.dropFirst()
    }
    if !digits.isEmpty, let separator = rest.first, separator == "." || separator == ")" {
        let value = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        if !value.isEmpty { return (digits + ".", value) }
    }
    return nil
}
