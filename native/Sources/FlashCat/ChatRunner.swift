// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import CoreGraphics
import FlashCatKit
import Foundation

/// 对话编排：一次发送的完整链路（准备会话、流式落地、收尾落盘、取消、后台
/// 续跑），以及「对话里主动画图」那条多轮工具调用循环。
///
/// 这些代码原来长在 `AppState` 上：`// MARK: chat`、`// MARK: - 对话里主动画图`、
/// `// MARK: - 对话里主动画图（工具调用）` 三段共一千六百多行，混着线程增删、
/// 模型准备与界面状态，改一处要读完四千行才能确认影响面。搬出来之后 `AppState`
/// 只留一行转发，SwiftUI 的调用点（`state.send(...)` 等）一个都不用改。
///
/// 状态没有复制：消息、线程、`generating` 仍住在 `ChatStore`，画图开关仍住在
/// `ChatSessionStore`，模型与引擎状态仍住在 `EngineSessionStore`——这里只保留
/// 「这一轮生成」自己的局部状态（代数、占位消息 id、后台那一份、三个 Task
/// 句柄、本次提示词估算），它们本来就只服务这条链路。
///
/// 要回头找 `AppState` 办的事（起引擎、换模型、写日志、弹提示、切页面）用
/// `Hooks` 闭包接回来：这里不认识 `AppState.shared`，才好在没有界面的地方单独
/// 构造出来跑。
@MainActor
final class ChatRunner {
    /// 外层能帮的事。用闭包注入而不是持有 `AppState`：外层已经持有本对象，
    /// 反向再持有就是循环引用；而且引擎控制器在切引擎时会整个换掉，闭包每次
    /// 现取才拿得到当前的那个。
    struct Hooks {
        /// 当前引擎控制器。
        var controller: @MainActor () -> EngineController? = { nil }
        /// 当前引擎 id。
        var activeEngine: @MainActor () -> EngineID = { .splash }
        /// 某个引擎上报的模型列表：能不能出图/出视频/读图全靠它。
        var engineModels: @MainActor (_ engine: EngineID) -> [EngineModel] = { _ in [] }
        /// 选中模型的目录信息，`start(localModel:)` 要它才能按本地路径起模型。
        var selectedModelInfo: @MainActor () -> ModelInfo? = { nil }
        /// 本次请求的最大生成 tokens（0 已按模型窗口换算过）。
        var effectiveMaxTokens: @MainActor () -> Int = { 0 }
        /// 现在能不能发：引擎就绪、模型就位、没在切模型。
        var canChat: @MainActor () -> Bool = { false }
        /// 等待引擎启动时对话页顶部那句阶段文案。
        var engineStageText: @MainActor () -> String = { "" }
        /// 网关端口。
        var port: @MainActor () -> Int = { 0 }
        /// 还没装引擎：先让用户去启动页选一个，而不是发出去等超时。
        var needsEngineSetup: @MainActor () -> Bool = { true }
        /// 网关侧模型准备（加载权重、必要时把别的模型换出去）。nil 表示成功，
        /// 否则是给用户看的原因。
        var prepareModel:
            @MainActor (_ model: String, _ allowingGeneration: Bool) async -> GatewayModelPreparationError? = {
                _, _ in nil
            }
        /// 这个模型现在是否已经驻留（已加载 / 就是当前模型）。
        var modelIsResident: @MainActor (_ model: String, _ controller: EngineController) -> Bool = { _, _ in false }
        /// 阻塞式错误横幅。
        var setNotice: @MainActor (_ message: String) -> Void = { _ in }
        /// 灵动岛提示：第二个参数是分类，第三个是一过性（只闪几秒、不进历史）。
        var toast: @MainActor (_ message: String, _ kind: IslandNotice.Kind?, _ transient: Bool) -> Void = { _, _, _ in
        }
        /// 引擎日志里的 warning 行（截断这类值得回看的告警）。
        var logWarning: @MainActor (_ line: String) -> Void = { _ in }
        /// 切到对话页：让用户看见回答在哪儿长。
        var showChat: @MainActor () -> Void = {}
    }

    var hooks = Hooks()

    /// 依赖全部构造时注入：这里不读单例，也就能在测试里塞替身。
    private let chat: ChatStore
    private let session: ChatSessionStore
    private let drafts: ChatDraftStore
    private let engineSession: EngineSessionStore
    private let settings: AppSettings
    private let history: ChatHistory
    private let conversation: ConversationStore
    private let chatClient: ChatClient
    private let imageClient: ImageClient
    private let videoClient: VideoClient
    private let metrics: MetricsStore

    init(
        chat: ChatStore,
        session: ChatSessionStore,
        drafts: ChatDraftStore,
        engineSession: EngineSessionStore,
        settings: AppSettings,
        history: ChatHistory,
        conversation: ConversationStore,
        chatClient: ChatClient,
        imageClient: ImageClient,
        videoClient: VideoClient,
        metrics: MetricsStore,
        hooks: Hooks = Hooks()
    ) {
        self.chat = chat
        self.session = session
        self.drafts = drafts
        self.engineSession = engineSession
        self.settings = settings
        self.history = history
        self.conversation = conversation
        self.chatClient = chatClient
        self.imageClient = imageClient
        self.videoClient = videoClient
        self.metrics = metrics
        self.hooks = hooks
    }

    // MARK: - store 转发

    /// 下面这些都是同名转发：搬过来的一千多行原样保留调用点，状态仍然只有
    /// store 里那一份，不在这里再存一遍。
    private var messages: [ChatMessage] {
        get { chat.messages }
        set { chat.messages = newValue }
    }
    private var threads: [ChatThread] {
        get { chat.threads }
        set { chat.threads = newValue }
    }
    private var generating: Bool {
        get { chat.generating }
        set { chat.generating = newValue }
    }
    private var generationStatus: String? {
        get { chat.generationStatus }
        set { chat.generationStatus = newValue }
    }
    private var chatStartupStage: String? {
        get { chat.chatStartupStage }
        set { chat.chatStartupStage = newValue }
    }
    private var pendingThreadDelete: ChatThread? {
        get { session.pendingThreadDelete }
        set { session.pendingThreadDelete = newValue }
    }
    private var pendingThreadRename: ChatThread? {
        get { session.pendingThreadRename }
        set { session.pendingThreadRename = newValue }
    }
    private var imageToolEnabled: Bool { session.imageToolEnabled }
    private var imageToolModelID: String { session.imageToolModelID }
    private var imageToolResident: Bool { session.imageToolResident }
    private var selectedModel: String { engineSession.selectedModel }
    private var serverState: ServerState { engineSession.serverState }

    /// 引擎控制器每次现取：切过引擎之后旧的那个已经没用了。
    private var controller: EngineController? { hooks.controller() }
    private var activeEngine: EngineID { hooks.activeEngine() }
    private var isSwitchingModel: Bool { engineSession.switchingModel != nil }
    private var isRunning: Bool { controller?.isRunning ?? false }
    private var canChat: Bool { hooks.canChat() }
    private var needsEngineSetup: Bool { hooks.needsEngineSetup() }
    private var effectiveMaxTokens: Int { hooks.effectiveMaxTokens() }
    private var engineStageText: String { hooks.engineStageText() }
    private var port: Int { hooks.port() }
    private var selectedModelInfo: ModelInfo? { hooks.selectedModelInfo() }

    private func engineModels(for engine: EngineID) -> [EngineModel] { hooks.engineModels(engine) }

    // MARK: - 线程标识

    /// 当前会话在「最近对话」里的 id。以前每轮生成结束都新建一条线程，同一段
    /// 对话会在侧栏堆成好几份（概览读到的上下文也可能来自旧副本）；现在这个 id
    /// 跟着 `conversation.json` 一起用，`history.save` 原地覆盖而不是 insert。
    /// 落在 UserDefaults，重启后续着同一条。
    private var threadID: String {
        get {
            let defaults = UserDefaults.standard
            if let existing = defaults.string(forKey: "chat.threadID"), !existing.isEmpty {
                return existing
            }
            let fresh = Self.newThreadID()
            defaults.set(fresh, forKey: "chat.threadID")
            return fresh
        }
        set { UserDefaults.standard.set(newValue, forKey: "chat.threadID") }
    }

    /// 侧栏「最近对话」用它高亮当前线程；threadID 本身只用于落盘。
    var currentThreadID: String { threadID }

    /// 正在生成的是哪一段对话——可能是读者已经切走、在后台继续跑的那一段。
    /// 侧栏据此把那一行标成「生成中」：不然切走后只剩下一个点不动的输入框，
    /// 看不出回答正在哪儿长。
    var generatingThreadID: String? {
        guard generating else { return nil }
        return background?.threadID ?? threadID
    }

    private static func newThreadID() -> String {
        String(Int(Date().timeIntervalSince1970 * 1_000_000))
    }

    // MARK: - 这一轮生成的局部状态

    /// 每次发送领一个号。取消或重开对话时推进，启动等待中的旧任务回来
    /// 发现代数不同就静默退出，不会在已经取消的回复里继续发请求。
    private var sendGeneration = 0
    /// 正在跑的图像请求。停止按钮先掐断它，再按对话同一套收尾。
    private var imageTask: Task<Void, Never>?
    /// 正在跑的视频请求（可能正在生成几十秒，也可能在封装 MP4）。
    private var videoTask: Task<Void, Never>?
    /// 正在跑的一整轮「对话 + 画图」：中间要换图像模型、画完再换回来，
    /// 可能持续几分钟，停止按钮要和上面两个一起掐断它。
    private var imageToolTask: Task<Void, Never>?
    /// The assistant message this generation owns, located by id.
    private var streamMessageID = ""
    /// 读者切走了、但还在后台生成的那一段对话。
    ///
    /// 生成一旦开始就不能靠「当前页面显示哪段对话」来决定回答写到哪：切走时
    /// 把整段对话连同它自己的 `threadID` 搬到这里，流式更新认这一份，跑完后
    /// 按自己的 id 落回历史，读者回到这段对话时再整体接回 `messages`。
    private struct BackgroundGeneration {
        let threadID: String
        var messages: [ChatMessage]
    }
    private var background: BackgroundGeneration?
    /// 本次请求的提示词 token 估算，生成期间用来实时刷新上下文占用。`AppState`
    /// 的 `contextUsedTokens` 还要读它（顶栏与概览卡的实时数字）。
    private(set) var livePromptTokens = 0

    // MARK: - 回到 AppState 的动作

    private func toast(_ message: String, kind: IslandNotice.Kind? = nil, transient: Bool = false) {
        hooks.toast(message, kind, transient)
    }

    /// 流式回复的本地测速委托给指标 store：低通估计器跟着指标一起搬走了，
    /// 对话页直播条读到的还是同一条曲线。
    private func recordStreamDelta(_ piece: String, at event: Date) {
        metrics.recordStreamDelta(piece, at: event)
    }

    private func gatewayModelIsResident(_ target: String, in controller: EngineController) -> Bool {
        hooks.modelIsResident(target, controller)
    }

    private func prepareModelForGateway(
        _ model: String, allowingGeneration: Bool
    ) async -> GatewayModelPreparationError? {
        await hooks.prepareModel(model, allowingGeneration)
    }

    // MARK: chat

    /// Mutate the assistant message this generation owns, located by id.
    ///
    /// The stream used to hold an array index from the moment `send` started.
    /// `messages` is replaced wholesale by `newConversation` / `openThread`, so
    /// by the time a token arrived that index could still be in bounds while
    /// pointing at a different conversation — the reply was silently appended to
    /// somebody else's message. Ids survive the replacement; indices do not.
    @discardableResult
    private func updateStreamingMessage(_ body: (inout ChatMessage) -> Void) -> Bool {
        guard !streamMessageID.isEmpty else { return false }
        // 读者切走后回答继续长在后台那一份里，不能写进他现在看的对话。
        if var running = background {
            guard let index = running.messages.firstIndex(where: { $0.id.uuidString == streamMessageID })
            else { return false }
            body(&running.messages[index])
            background = running
            return true
        }
        guard let index = messages.firstIndex(where: { $0.id.uuidString == streamMessageID })
        else { return false }
        body(&messages[index])
        return true
    }

    /// 发送前把引擎带到「真的能用」：先等正在进行的切换结束，引擎没起就启动，
    /// 再等权重加载完成。启动阶段实时写进 `chatStartupStage`，占位回复据此显示
    /// 「模型正在启动中」。返回 false 表示启动失败或已被取消。
    private func prepareChatSession(generation: Int) async -> Bool {
        if isSwitchingModel {
            let switchDeadline = Date().addingTimeInterval(activeEngine.startupTimeout)
            while isSwitchingModel, Date() < switchDeadline {
                if sendGeneration != generation || Task.isCancelled { return false }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if isSwitchingModel { return false }
        }
        guard let controller else { return false }
        guard !canChat else { return true }
        if !controller.isRunning {
            await controller.start(localModel: selectedModelInfo, requestedModel: selectedModel)
        }
        // 启动本身可能包含较长的准备（比如补下 draft 权重），从真正开跑之后再
        // 计时，别让准备阶段吃掉等待权重的预算。
        let deadline = Date().addingTimeInterval(activeEngine.startupTimeout)
        while Date() < deadline {
            if sendGeneration != generation || Task.isCancelled { return false }
            if canChat { return true }
            if serverState == .failed { return false }
            if !isRunning, serverState == .stopped { return false }
            let stage = engineStageText
            if !stage.isEmpty, stage != "已停止" { chatStartupStage = stage }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return canChat
    }

    func send(
        _ text: String,
        attachment: ChatImageAttachment? = nil,
        lastFrame: ChatImageAttachment? = nil,
        referenceImages: [ChatImageAttachment] = [],
        referenceClips: [VideoReferenceClip] = [],
        image: ImageOptions = ImageOptions(),
        video: VideoOptions = VideoOptions()
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || generating { return }
        guard !needsEngineSetup else {
            hooks.setNotice("还没有安装推理引擎，请先在启动页选择一个")
            return
        }
        guard !selectedModel.isEmpty else {
            hooks.setNotice("还没有选择模型")
            return
        }
        if activeModelSupportsVideo {
            sendVideo(
                trimmed, attachment: attachment, lastFrame: lastFrame,
                referenceImages: referenceImages, referenceClips: referenceClips,
                options: video)
            return
        }
        if activeModelSupportsImage {
            sendImage(trimmed, attachment: attachment, options: image)
            return
        }
        // 文本模型 + 开了「画」+ 引擎里有图像模型：这一轮把画图当工具交给它，
        // 由模型自己决定画几张、写什么分镜。
        if imageToolActive, let imageModel = imageToolModel {
            sendWithImageTool(trimmed, imageModel: imageModel)
            return
        }
        // 引擎没就绪也允许发送：先把这句话摆进对话，回复气泡里显示启动状态，
        // 等引擎真的能用之后 `prepareChatSession` 再继续跑这次生成。
        let needsStartup = !canChat

        // 被「停止」的空回答留在界面上，但不该当成一轮空 assistant 发给引擎。
        var turns: [ChatTurn] =
            messages
            .filter { !$0.streaming && !$0.content.isEmpty }
            .map { ChatTurn(role: $0.role, content: $0.content) }
        var openingTurn = ChatTurn(role: "user", content: trimmed)
        if activeModelSupportsVision {
            // 工具结果里只有路径，历史回放拿不到像素。视觉模型提问时把最近
            // 一组成品重新挂上，它才能接着回答「这张图哪里不对」。
            openingTurn.imageURLs = imageURLs(for: recentGeneratedImagePaths())
        }
        turns.append(openingTurn)

        messages.append(ChatMessage(role: "user", content: trimmed, model: selectedModel, createdAt: Date()))
        messages.append(
            ChatMessage(role: "assistant", content: "", model: selectedModel, createdAt: Date(), streaming: true))
        streamMessageID = messages[messages.count - 1].id.uuidString
        // 先把「问题」这条写进最近对话：这样切走之后它在列表里就有自己的
        // 一行（标着「生成中」），后台跑完再原地覆盖成完整的一问一答。
        // 不给占位的话，一段刚开始的对话在跑完之前根本点不回来。
        history.save(messages: messages, threadID: threadID)
        threads = history.load()
        generating = true
        generationStatus = "生成中"
        sendGeneration &+= 1
        let generation = sendGeneration
        chatStartupStage = needsStartup ? "模型正在启动中…" : nil
        metrics.resetStreamMeter()

        // 最大生成 tokens：思考与正文共享的总输出上限。留空时取模型自身上限
        // 并按引擎生效窗口封顶（见 effectiveMaxTokens），4096 那种小默认会让
        // 思考模型一开思考就被 finish_reason=length 硬截断。
        let maxTokensLimit = effectiveMaxTokens
        // 系统提示按这一轮的附件补齐后再定稿：`options` 保持 `let`，各个
        // `@Sendable` 回调里捕获的就是一份不再变化的值，跨隔离域读也安全。
        var systemPrompt = settings.systemPrompt
        if !openingTurn.imageURLs.isEmpty {
            systemPrompt += "\n\n随这条消息附上的是你最近生成的成品；先看图再回答，不要只凭对话里的路径猜。"
        }
        let options = ChatOptions(
            temperature: settings.temperature,
            topP: settings.topP,
            maxTokens: maxTokensLimit,
            reasoningEffort: settings.effectiveReasoningEffort,
            systemPrompt: systemPrompt,
            thinkingBudget: EngineStore.shared
                .tuning(for: activeEngine)
                .effectiveThinkingBudget(for: activeEngine))
        let model = selectedModel
        // 上下文实时估算的基数：本轮提示词（含系统提示）的 token 数。回复结束
        // 后仍会回落到引擎回报的真实 usage。
        let promptTokens =
            TokenEstimator.promptTokens(
                messages: turns.map { ["role": $0.role, "content": $0.content] })
            + TokenEstimator.estimate(options.systemPrompt)
            + turns.reduce(0) { $0 + $1.imageURLs.count } * TokenEstimator.approximateImageTokens
        livePromptTokens = promptTokens
        // 应用内对话直接连引擎端口，不经过网关；概览页的「最近请求」与会话
        // 计数统一读 GatewayMeter，所以这里也要打点，否则对话页的请求在
        // 概览里永远是 0 条。
        let meterID = GatewayMeter.shared.begin(
            model: model,
            dialect: "chat",
            promptTokens: promptTokens)

        Task {
            if needsStartup {
                let ready = await self.prepareChatSession(generation: generation)
                // 等启动的这段时间被「停止」停掉时，这次打点还没人收尾；
                // 直接 return 会让概览里的请求永远停在「运行中」。
                guard self.sendGeneration == generation else {
                    GatewayMeter.shared.finish(meterID, failed: true)
                    return
                }
                guard ready else {
                    GatewayMeter.shared.finish(meterID, failed: true)
                    let reason = self.controller?.failureMessage ?? "模型未能启动，请查看日志"
                    self.hooks.setNotice(reason)
                    self.updateStreamingMessage { message in
                        message.content = "出错：\(reason)"
                        message.streaming = false
                    }
                    self.chatStartupStage = nil
                    self.generating = false
                    self.persistStreamingConversation()
                    return
                }
                self.chatStartupStage = nil
            }
            // 启动等待不算进首字时长，否则「思考了 N 秒」会把引擎启动时间也算上。
            let started = Date()
            // 网关侧的打点也要从这里起算：`begin` 发生在 prepareChatSession
            // 之前，冷启动时那段加载几十 GB 权重的时间不能摊进预填充。
            GatewayMeter.shared.markStarted(meterID, at: started)
            let endpointPort = self.port
            let result = await chatClient.send(
                port: endpointPort, model: model, turns: turns, options: options,
                onDelta: { piece, at in
                    GatewayMeter.shared.addTokens(meterID, TokenEstimator.fractional(piece), at: at)
                    Task { @MainActor in
                        guard self.sendGeneration == generation else { return }
                        let found = self.updateStreamingMessage { message in
                            if message.firstTokenSeconds == nil {
                                let ttft = at.timeIntervalSince(started)
                                message.firstTokenSeconds = ttft
                                // 正文首字之前的这段时间就是思考阶段；记下来，回答结束后
                                // 折叠的思考块仍能给出真实时长。
                                message.thinkingSeconds = ttft
                            }
                            message.content += piece
                        }
                        guard found else { return }
                        self.recordStreamDelta(piece, at: at)
                    }
                },
                onReasoning: { piece, at in
                    GatewayMeter.shared.addTokens(meterID, TokenEstimator.fractional(piece), at: at)
                    Task { @MainActor in
                        guard self.sendGeneration == generation else { return }
                        let found = self.updateStreamingMessage { message in
                            message.reasoning = (message.reasoning ?? "") + piece
                            if message.content.isEmpty {
                                self.generationStatus = "思考中"
                            }
                        }
                        guard found else { return }
                        // 思考流同样计入本地测速：思考模型的输出大头在 reasoning，
                        // 不计的话思考阶段的直播条一直是空的，只能显示「— tok/s」。
                        self.recordStreamDelta(piece, at: at)
                    }
                },
                onUsage: { usage in
                    GatewayMeter.shared.noteUsage(
                        meterID,
                        promptTokens: usage.promptTokens,
                        completionTokens: usage.completionTokens,
                        cachedPromptTokens: usage.cachedPromptTokens)
                    Task { @MainActor in
                        guard self.sendGeneration == generation else { return }
                        guard self.updateStreamingMessage({ $0.usage = usage }) else { return }
                        // 思考截断可见性：引擎按预算收束思考时，reasoning_tokens
                        // 正好落在预算上，用「≥ 预算」判定这次思考被截断。
                        if let budget = options.thinkingBudget,
                            let reasoning = usage.reasoningTokens,
                            reasoning >= budget
                        {
                            self.hooks.logWarning(
                                "==> 思考截断：本次思考 \(reasoning) tokens 触及预算 \(budget)，已被强制收束；如需更长思考请在引擎配置调大「思考截断」")
                        }
                        // max_tokens 是思考与正文共享的总输出上限，打满即硬截断
                        //（finish_reason=length），思考模型默认值下最容易撞上。
                        if usage.finishReason == "length" {
                            let reasoning = usage.reasoningTokens.map { "，其中思考 \($0) tokens" } ?? ""
                            self.hooks.logWarning(
                                "==> 输出截断：本次生成触及最大生成长度 \(options.maxTokens) tokens 的上限\(reasoning)，思考与正文共享该上限；如需更长思考/回答请在聊天参数调大「最大生成 tokens」"
                            )
                        }
                    }
                },
                onStatus: { status in
                    Task { @MainActor in
                        guard self.sendGeneration == generation else { return }
                        self.generationStatus = status
                    }
                })

            let elapsed = Date().timeIntervalSince(started)
            // 这一轮已经被「停止」收掉（或被新的一轮顶掉）：打点照常收尾，
            // 消息不再动——收尾由 cancelGeneration 做，这里再写一次会把刚标上
            // 的「已停止生成」覆盖成「出错：已取消」。
            let stale = self.sendGeneration != generation
            switch result {
            case .success(let text):
                GatewayMeter.shared.finish(meterID)
                guard !stale else { return }
                self.updateStreamingMessage { message in
                    message.content = text
                    message.seconds = elapsed
                    let finalUsage = chatClient.lastUsage
                    if finalUsage.completionTokens > 0 { message.usage = finalUsage }
                    var tokens = finalUsage.completionTokens
                    if tokens == 0 {
                        // Streaming responses often omit usage; fall back to the
                        // accumulated fraction-weighted estimate so the message
                        // still shows a token count and rate.
                        tokens = Int(metrics.streamTotalTokens.rounded())
                        if tokens > 0 {
                            message.usage = ChatUsage(promptTokens: 0, completionTokens: tokens)
                        }
                    }
                    // 分母取「首分片 → 末分片」，不再把 TTFT / prefill 混进
                    // decode 时长：旧口径让消息下方的总平均天生比直播条低一大截，
                    // 两个数字看起来像彼此矛盾。
                    if tokens > 0, metrics.streamDecodingSeconds > 0 {
                        message.tokensPerSecond = Double(tokens) / metrics.streamDecodingSeconds
                    }
                }
            case .failure(let error):
                GatewayMeter.shared.finish(meterID, failed: !error.isCancellation)
                guard !stale else { return }
                self.updateStreamingMessage { message in
                    if message.content.isEmpty {
                        message.content = "出错：\(error.message)"
                    }
                }
                if !error.isCancellation { hooks.setNotice(error.message) }
            }
            updateStreamingMessage { $0.streaming = false }
            // 这一轮已经被取消时不要再落盘：`messages` 现在可能已经是另一段
            // 对话，按新的 `threadID` 写回会把那段对话整条覆盖掉。取消路径
            // 自己负责把这一轮存盘。
            guard self.sendGeneration == generation else { return }
            generating = false
            // 读者早就切走了：回答落回它自己的会话，再冒一条通知告诉他落在哪。
            if let finished = self.persistStreamingConversation(),
                let thread = self.threads.first(where: { $0.id == finished })
            {
                self.toast(
                    L10n.format("「%@」已在后台生成完成", thread.title),
                    kind: .success)
            }
        }
    }

    /// 当前选中的模型本身。图像参数面板要用它上报的架构来选分辨率预设、
    /// 判断步数是否被蒸馏权重固定；找不到时返回 nil，面板退回通用预设。
    var activeModel: EngineModel? {
        guard !selectedModel.isEmpty else { return nil }
        return engineModels(for: activeEngine).first { $0.id == selectedModel }
    }

    /// 当前选中的模型能不能出图。能力跟着模型走：同一个 mlx-serve 进程里
    /// 对话模型和图像模型可以同时挂着，所以按模型 id 找它自己上报的能力。
    var activeModelSupportsImage: Bool { activeModel?.supportsImage ?? false }

    /// 当前选中的模型能不能出视频。和图像一样按模型 id 查它自己上报的能力。
    var activeModelSupportsVideo: Bool { activeModel?.supportsVideo ?? false }

    /// 当前选中的模型能不能读图（图进文出）。它决定画完的成品要不要以
    /// 像素形式回传给模型；纯文本模型只能拿到路径，硬塞 image_url 会 400。
    var activeModelSupportsVision: Bool { activeModel?.supportsVision ?? false }

    // MARK: - 对话里主动画图

    /// 当前引擎会不会说工具调用协议。只挂在支持工具的引擎上：给别的引擎
    /// 发 `tools` 字段，轻则被忽略，重则 400。
    private var activeEngineSupportsToolUse: Bool {
        activeEngine.capabilities.contains(.toolUse)
    }

    /// 工具可借用的图像模型：当前引擎里报了 image 能力、且没被隐藏的。
    var imageToolModels: [EngineModel] {
        engineModels(for: activeEngine).filter { $0.supportsImage && !$0.hidden && !$0.helper }
    }

    /// 这次画图用哪个图像模型。用户没选过时退回第一个能出图的模型。
    var imageToolModel: EngineModel? {
        let models = imageToolModels
        if !imageToolModelID.isEmpty,
            let chosen = models.first(where: { $0.id == imageToolModelID })
        {
            return chosen
        }
        return models.first
    }

    /// 对话页显不显示「画」这个开关：文本模型 + 引擎支持工具 + 引擎里有图像
    /// 模型，三者同时成立才有意义。图像/视频模型本身就是画图链路，不需要工具。
    var supportsImageTool: Bool {
        guard activeEngineSupportsToolUse else { return false }
        guard activeModel?.supportsChat == true else { return false }
        guard !activeModelSupportsImage, !activeModelSupportsVideo else { return false }
        return imageToolModel != nil
    }

    /// 这一轮发送要不要真的把工具挂进请求。
    var imageToolActive: Bool { imageToolEnabled && supportsImageTool }

    /// 当前视频模型是不是 REF2VA：只有它吃参考图/参考视频，且不接受首尾帧。
    var activeModelSupportsVideoReferences: Bool {
        activeModel?.supportsVideoReferences ?? false
    }

    /// 图像模型的发送链路：和对话共用消息列表、历史与打点，只把
    /// `/v1/chat/completions` 换成 `/v1/images/generations`。
    ///
    /// 编排复用 `prepareModelForGateway(allowingGeneration:)`：加载几十 GB 的
    /// 图像权重、把对话模型换出去，都走网关那条已经验证过冷启动的路径。
    private func sendImage(
        _ prompt: String,
        attachment: ChatImageAttachment?,
        options: ImageOptions
    ) {
        let model = selectedModel
        // 蒸馏包的采样表写在权重里：引擎只认那个步数，个别包收到别的值会直接
        // 拒绝。面板已经把滑杆换成固定值，这里再把请求对齐一次，别让旧设置
        // （比如上一次的 20 步）带进一个只跑 8 步的模型。
        let fixedSteps = activeModel.flatMap { ImageModelProfile(model: $0).fixedSteps }
        let requestSteps = fixedSteps ?? options.steps
        // 引擎在没收到 seed 时会用固定的 42：每次一样，用户也没法复现。
        // 这里先落一个具体值，图注里能看见、能复制，也能原样再发一次。
        let seed = options.seed ?? Int.random(in: 1...1_000_000_000)
        var sourcePath: String?
        var sourceBase64: String?
        if let attachment {
            guard let imported = ImageStore.importImage(atPath: attachment.path),
                let encoded = ImageStore.base64(atPath: imported)
            else {
                hooks.setNotice("读取图片失败：\(attachment.name)")
                return
            }
            sourcePath = imported
            sourceBase64 = encoded
        }

        messages.append(
            ChatMessage(
                role: "user", content: prompt, model: model,
                createdAt: Date(), imagePath: sourcePath))
        let placeholder = ChatMessage(
            role: "assistant", content: "", model: model,
            createdAt: Date(), streaming: true,
            imageProgress: "正在准备图像模型")
        messages.append(placeholder)
        streamMessageID = placeholder.id.uuidString
        history.save(messages: messages, threadID: threadID)
        threads = history.load()
        generating = true
        generationStatus = "正在准备图像模型"
        sendGeneration &+= 1
        let generation = sendGeneration
        chatStartupStage = nil
        imageTask?.cancel()
        imageTask = Task { [weak self] in
            guard let self else { return }
            let preparation = await self.prepareModelForGateway(
                model,
                allowingGeneration: true)
            guard self.sendGeneration == generation else { return }
            if let preparation {
                self.failImage(preparation.message)
                return
            }

            let meterID = GatewayMeter.shared.begin(
                model: model, dialect: "image",
                promptTokens: 0)
            GatewayMeter.shared.markStarted(meterID, at: Date())
            self.generationStatus = sourceBase64 == nil ? "正在生成图像" : "正在重绘图像"
            let request = ImageGenerationRequest(
                model: model,
                prompt: prompt,
                size: options.size,
                seed: seed,
                steps: requestSteps,
                sourceBase64: sourceBase64,
                strength: sourceBase64 == nil ? nil : options.strength,
                mode: sourceBase64 == nil ? nil : "variation")
            let outcome = await self.imageClient.generate(
                port: self.port,
                request: request
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.sendGeneration == generation else { return }
                    self.updateStreamingMessage { $0.imageProgress = progress }
                }
            }
            guard self.sendGeneration == generation else {
                GatewayMeter.shared.finish(meterID, failed: true)
                return
            }
            switch outcome {
            case .success(let result):
                GatewayMeter.shared.finish(meterID)
                let path = ImageStore.save(result.png)
                // 图注用引擎实际跑的步数：Turbo 这类蒸馏包会把 20 步请求
                // 改写成自己的 8 步 sigma 表，写请求值会让图注和面板打架。
                let note = self.imageNote(
                    options: options,
                    attachment: attachment,
                    path: path,
                    actualSteps: result.steps)
                self.updateStreamingMessage { message in
                    message.streaming = false
                    message.imageProgress = nil
                    message.seconds = result.seconds
                    message.imagePath = path
                    message.imageSeed = seed
                    message.imageNote = note
                    if path == nil {
                        message.content = "图像已生成，但写入磁盘失败"
                    }
                }
                if let path {
                    // 只登记模型生成的成品；用户底图挂在前面那条 user 消息的
                    // imagePath 上，不会走到这里。历史只保留六段对话，图库自己
                    // 留一份索引，删掉对话也不会把已保存的作品一起抹掉。
                    ImageGalleryStore.shared.record(
                        GalleryImage(
                            path: path,
                            prompt: prompt,
                            model: model,
                            createdAt: Date(),
                            note: note,
                            seed: seed))
                }
                if path == nil { self.hooks.setNotice("图像已生成，但写入磁盘失败") }
            case .failure(let error):
                GatewayMeter.shared.finish(meterID, failed: true)
                self.failImage(error.message)
            }
            self.imageTask = nil
            self.generating = false
            self.persistStreamingConversation()
        }
    }

    // MARK: - 对话里主动画图（工具调用）

    /// 一次「文本模型主动画图」的完整一轮：模型写分镜 → 换图像模型逐张画 →
    /// 换回对话模型把结果交还给它接着写。
    ///
    /// 整轮共用一条占位消息：正文由最后一轮聊天写，图片按张追加，阶段行显示
    /// 「正在画第 2/3 张 · 去噪 8/20」。引擎换模型的几十秒里，用户看得见在做什么。
    private func sendWithImageTool(_ text: String, imageModel: EngineModel) {
        let chatModel = selectedModel
        let needsStartup = !canChat
        let turnStarted = Date()
        // 能力在发车前定死：画图过程中 activeModel 会跟着换到图像模型，
        // 回来后再查就变成「图像模型能不能读图」了。
        let seesImages = activeModelSupportsVision

        var sent = conversationTurns()
        var openingTurn = ChatTurn(role: "user", content: text)
        if seesImages {
            // 历史里的工具结果只有路径，补上最近一组成品的像素，模型才能
            // 接住「把刚才那张改一下」这类追问。
            openingTurn.imageURLs = imageURLs(for: recentGeneratedImagePaths())
        }
        sent.append(openingTurn)

        messages.append(ChatMessage(role: "user", content: text, model: chatModel, createdAt: Date()))
        messages.append(
            ChatMessage(role: "assistant", content: "", model: chatModel, createdAt: Date(), streaming: true))
        streamMessageID = messages[messages.count - 1].id.uuidString
        // 先把这一问摆进最近对话：换模型要几十秒，用户中途切走也点得回来。
        history.save(messages: messages, threadID: threadID)
        threads = history.load()
        generating = true
        generationStatus = "生成中"
        sendGeneration &+= 1
        let generation = sendGeneration
        chatStartupStage = needsStartup ? "模型正在启动中…" : nil
        metrics.resetStreamMeter()

        var options = ChatOptions(
            temperature: settings.temperature,
            topP: settings.topP,
            maxTokens: effectiveMaxTokens,
            reasoningEffort: settings.effectiveReasoningEffort,
            systemPrompt: settings.systemPrompt,
            thinkingBudget: EngineStore.shared
                .tuning(for: activeEngine)
                .effectiveThinkingBudget(for: activeEngine))
        // 工具描述已经写清用途，系统提示只补一句「别光描述、直接画」。
        options.systemPrompt =
            options.systemPrompt.isEmpty
            ? ImageTool.guidance
            : options.systemPrompt + "\n\n" + ImageTool.guidance
        options.systemPrompt +=
            seesImages
            ? "\n\n画完的成品会作为图片回传给你。先看清画面再回答或继续改，不要只凭提示词猜。"
            : "\n\n你看不到图片本身，只拿得到路径与尺寸。不要编造画面里没确认的细节。"
        let tools = ChatToolSchema(
            ImageTool.schema(sizeOptions: ImageModelProfile(model: imageModel).presets.map(\.id)))
        let imageOptions = ImageOptionsStore.load()
        // 整组图共用一个 seed：同一条提示词重发能复现，图注里也能看见。
        let seriesSeed = Int.random(in: 1...1_000_000_000)

        imageToolTask?.cancel()
        imageToolTask = Task { [weak self] in
            guard let self else { return }
            defer { self.imageToolTask = nil }

            if needsStartup {
                let ready = await self.prepareChatSession(generation: generation)
                guard self.sendGeneration == generation else { return }
                guard ready else {
                    let reason = self.controller?.failureMessage ?? "模型未能启动，请查看日志"
                    self.finishImageToolTurn(failure: reason, generation: generation)
                    return
                }
                self.chatStartupStage = nil
            }

            // 引擎可能还停在上一轮画图用的图像模型上（用户中途停止过），
            // 直接发聊天请求会 503。先把对话模型换回显存，已经在了就是空操作。
            if let problem = await self.ensureResidentModel(
                chatModel,
                stage: { stage in
                    self.setToolStage(stage, generation: generation)
                })
            {
                self.finishImageToolTurn(failure: problem, generation: generation)
                return
            }

            var transcript = ""
            var usage = ChatUsage()
            var rounds = 0
            var drawn = 0
            self.setToolStage("正在规划画面…", generation: generation)

            // 每一趟都是一次完整的对话请求：模型要么交出画图调用，要么给出最终
            // 回答。画完把「调用 + 结果」追加回上下文，下一趟它就能接着写。
            while true {
                guard self.sendGeneration == generation, !Task.isCancelled else { return }
                // 轮次用完、或这一轮已经画满：最后一趟不带工具，模型只能把
                // 这一组图讲完，不会又画一轮把对话卡在这里。
                let roundTools =
                    (rounds >= ImageTool.maximumRounds || drawn >= ImageTool.maximumImagesPerTurn)
                    ? ChatToolSchema() : tools
                let started = Date()
                let promptTokens =
                    TokenEstimator.promptTokens(
                        messages: sent.map { ["role": $0.role, "content": $0.content] })
                    + TokenEstimator.estimate(options.systemPrompt)
                    + sent.reduce(0) { $0 + $1.imageURLs.count } * TokenEstimator.approximateImageTokens
                self.livePromptTokens = promptTokens
                let meterID = GatewayMeter.shared.begin(
                    model: chatModel, dialect: "chat",
                    promptTokens: promptTokens)
                GatewayMeter.shared.markStarted(meterID, at: started)

                let result = await self.chatClient.send(
                    port: self.port,
                    model: chatModel,
                    turns: sent,
                    options: options,
                    tools: roundTools,
                    onDelta: { piece, at in
                        GatewayMeter.shared.addTokens(meterID, TokenEstimator.fractional(piece), at: at)
                        Task { @MainActor in
                            guard self.sendGeneration == generation else { return }
                            let found = self.updateStreamingMessage { message in
                                if message.firstTokenSeconds == nil {
                                    let ttft = at.timeIntervalSince(started)
                                    message.firstTokenSeconds = ttft
                                    message.thinkingSeconds = ttft
                                }
                                // 模型已经开口了，阶段行让位给正文。
                                message.toolStage = nil
                                message.content += piece
                            }
                            guard found else { return }
                            self.recordStreamDelta(piece, at: at)
                        }
                    },
                    onReasoning: { piece, at in
                        GatewayMeter.shared.addTokens(meterID, TokenEstimator.fractional(piece), at: at)
                        Task { @MainActor in
                            guard self.sendGeneration == generation else { return }
                            let found = self.updateStreamingMessage { message in
                                message.reasoning = (message.reasoning ?? "") + piece
                                if message.content.isEmpty { self.generationStatus = "思考中" }
                            }
                            guard found else { return }
                            self.recordStreamDelta(piece, at: at)
                        }
                    },
                    onUsage: { reported in
                        GatewayMeter.shared.noteUsage(
                            meterID,
                            promptTokens: reported.promptTokens,
                            completionTokens: reported.completionTokens,
                            cachedPromptTokens: reported.cachedPromptTokens)
                    },
                    onStatus: { status in
                        Task { @MainActor in
                            guard self.sendGeneration == generation else { return }
                            self.generationStatus = status
                        }
                    },
                    onToolCall: { piece, at in
                        // 工具参数也是模型真写出来的字，和网关的统计口径一致。
                        GatewayMeter.shared.addTokens(meterID, TokenEstimator.fractional(piece), at: at)
                        Task { @MainActor in
                            guard self.sendGeneration == generation else { return }
                            self.recordStreamDelta(piece, at: at)
                        }
                    })

                // 收尾先看代数：被「停止」或被新的一轮顶掉时，打点收掉即可，
                // 消息由 cancelGeneration 负责，这里再写一次会盖掉「已停止生成」。
                let stale = self.sendGeneration != generation
                var answer = ""
                switch result {
                case .failure(let error):
                    GatewayMeter.shared.finish(meterID, failed: !error.isCancellation)
                    if stale || error.isCancellation { return }
                    self.finishImageToolTurn(failure: error.message, generation: generation)
                    return
                case .success(let text):
                    GatewayMeter.shared.finish(meterID)
                    if stale { return }
                    answer = text
                    transcript += text
                }

                let reported = self.chatClient.lastUsage
                usage.promptTokens += reported.promptTokens
                usage.completionTokens += reported.completionTokens
                usage.cachedPromptTokens += reported.cachedPromptTokens
                if let reasoning = reported.reasoningTokens {
                    usage.reasoningTokens = (usage.reasoningTokens ?? 0) + reasoning
                }
                usage.finishReason = reported.finishReason

                let calls =
                    roundTools.isEmpty
                    ? []
                    : self.chatClient.lastToolCalls.filter { $0.name == ImageTool.name }
                guard !calls.isEmpty else {
                    self.finishImageToolTurn(
                        content: transcript, usage: usage,
                        generation: generation, started: turnStarted)
                    return
                }

                sent.append(ChatTurn(role: "assistant", content: answer, toolCalls: calls))
                var results: [ChatToolResult] = []
                var drawnPaths: [String] = []
                for call in calls {
                    guard self.sendGeneration == generation, !Task.isCancelled else { return }
                    let outcome = await self.runImageTool(
                        call,
                        imageModel: imageModel,
                        chatModel: chatModel,
                        generation: generation,
                        allowance: ImageTool.maximumImagesPerTurn - drawn,
                        seed: seriesSeed,
                        options: imageOptions)
                    drawn += outcome.drawn
                    results.append(outcome.result)
                    drawnPaths.append(contentsOf: outcome.imagePaths)
                    sent.append(
                        ChatTurn(
                            role: "tool", content: outcome.result.content,
                            toolCallID: outcome.result.callID))
                }
                self.recordToolExchange(calls: calls, results: results, generation: generation)
                rounds += 1
                // 视觉模型：把刚落盘的成品按生成顺序回传，让它在同一轮里
                // 真正「看见」自己画了什么，再决定补画还是收尾。这是一条
                // 只存在于内存里的 user 轮，不写进 messages，也不落盘。
                if seesImages, !drawnPaths.isEmpty {
                    let urls = self.imageURLs(for: drawnPaths)
                    if !urls.isEmpty {
                        self.setToolStage("正在看刚画的图…", generation: generation)
                        sent.append(
                            ChatTurn(
                                role: "user",
                                content: self.visionFeedback(
                                    count: urls.count,
                                    canDrawMore: rounds < ImageTool.maximumRounds
                                        && drawn < ImageTool.maximumImagesPerTurn),
                                imageURLs: urls))
                    }
                }
                // 常驻时没有「换回」这一步，阶段行已经在 runImageTool 里清掉。
                if !self.imageToolResident {
                    self.setToolStage("正在换回对话模型…", generation: generation)
                }
            }
        }
    }

    private struct ImageToolOutcome {
        let result: ChatToolResult
        let drawn: Int
        /// 本轮成功落盘的图片，按生成顺序。视觉模型要把它们回传成像素。
        var imagePaths: [String] = []
    }

    /// 执行一次画图调用：把图像模型换进来、逐张画完、再换回对话模型。
    /// 结果无论成败都写一段 JSON 回给模型——失败也要让它知道为什么，
    /// 它才能向用户解释或者少画两张。
    private func runImageTool(
        _ call: ChatToolCall,
        imageModel: EngineModel,
        chatModel: String,
        generation: Int,
        allowance: Int,
        seed: Int,
        options: ImageOptions
    ) async -> ImageToolOutcome {
        let parsed: ImageTool.Call
        switch ImageTool.parse(call) {
        case .success(let value):
            parsed = value
        case .failure(let error):
            return ImageToolOutcome(
                result: ChatToolResult(
                    callID: call.id,
                    content: ImageTool.failure(error.message)),
                drawn: 0, imagePaths: [])
        }
        guard allowance > 0 else {
            return ImageToolOutcome(
                result: ChatToolResult(
                    callID: call.id,
                    content: ImageTool.failure("这一轮已经画满 \(ImageTool.maximumImagesPerTurn) 张了，先把这组图交给用户。")),
                drawn: 0, imagePaths: [])
        }
        let prompts =
            parsed.prompts.count > allowance
            ? Array(parsed.prompts.prefix(allowance))
            : parsed.prompts

        let profile = ImageModelProfile(model: imageModel)
        // 蒸馏包只认自己的采样表，面板也把步数固定住了；工具沿用同一套规则。
        let steps = profile.fixedSteps ?? options.steps
        let size = Self.sanitizedCanvas(parsed.size, profile: profile, fallback: options.size)

        setToolStage("正在准备图像模型 \(imageModel.shortName)…", generation: generation)
        if let error = await ensureResidentModel(
            imageModel.id,
            stage: { [weak self] stage in
                self?.setToolStage(stage, generation: generation)
            },
            alongside: imageToolResident)
        {
            _ = await ensureResidentModel(chatModel, stage: { _ in })
            return ImageToolOutcome(
                result: ChatToolResult(
                    callID: call.id,
                    content: ImageTool.failure("图像模型没能加载：\(error)")),
                drawn: 0, imagePaths: [])
        }

        var images: [(path: String, note: String)] = []
        var failureMessage: String?
        for (index, prompt) in prompts.enumerated() {
            if Task.isCancelled || sendGeneration != generation { break }
            setToolStage("正在画第 \(index + 1)/\(prompts.count) 张…", generation: generation)
            let meterID = GatewayMeter.shared.begin(
                model: imageModel.id, dialect: "image",
                promptTokens: TokenEstimator.estimate(prompt))
            GatewayMeter.shared.markStarted(meterID)
            let request = ImageGenerationRequest(
                model: imageModel.id,
                prompt: prompt,
                size: size,
                seed: seed,
                steps: steps,
                sourceBase64: nil,
                strength: nil,
                mode: nil)
            let outcome = await imageClient.generate(port: port, request: request) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.sendGeneration == generation else { return }
                    self.setToolStage(
                        "正在画第 \(index + 1)/\(prompts.count) 张 · \(progress)",
                        generation: generation)
                }
            }
            switch outcome {
            case .success(let result):
                GatewayMeter.shared.finish(meterID)
                guard let path = ImageStore.save(result.png) else {
                    failureMessage = "图片已经生成，但写入磁盘失败"
                    continue
                }
                let requestOptions = ImageOptions(
                    size: size, steps: steps, seed: seed,
                    strength: options.strength)
                let note = imageNote(
                    options: requestOptions,
                    attachment: nil,
                    path: path,
                    actualSteps: result.steps)
                images.append((path, note))
                appendToolImage(path: path, note: note, seed: seed, generation: generation)
                ImageGalleryStore.shared.record(
                    GalleryImage(
                        path: path,
                        prompt: prompt,
                        model: imageModel.id,
                        createdAt: Date(),
                        note: note,
                        seed: seed))
            case .failure(let error):
                // 三个客户端错误类型现在都有自己的 `isCancellation`，判据不再看文案；
                // `Task.isCancelled` 仍然要留：任务在错误交回来之前就被撤销时，
                // 拿到的可能是 `.transport`。
                let cancelled = error.isCancellation || Task.isCancelled
                GatewayMeter.shared.finish(meterID, failed: !cancelled)
                failureMessage = error.message
                if cancelled { break }
            }
        }

        // 允许常驻且对话模型还在显存里：图像模型留着，下一轮画图直接复用；
        // 否则（设置关掉、或引擎为了腾内存把对话模型挤掉了）必须换回来——
        // 不换的话下一趟聊天要等引擎重新加载，用户看到的是「模型正在启动」。
        if imageToolResident,
            let controller,
            gatewayModelIsResident(chatModel, in: controller)
        {
            setToolStage(nil, generation: generation)
        } else {
            setToolStage("正在换回对话模型…", generation: generation)
            _ = await ensureResidentModel(chatModel, stage: { _ in })
            setToolStage(nil, generation: generation)
        }

        guard !images.isEmpty else {
            return ImageToolOutcome(
                result: ChatToolResult(
                    callID: call.id,
                    content: ImageTool.failure(failureMessage ?? "没有画出图片")),
                drawn: 0, imagePaths: [])
        }
        var content = ImageTool.result(images: images, seed: seed, size: size)
        if let failureMessage {
            content += "（有 \(prompts.count - images.count) 张失败：\(failureMessage)）"
        }
        return ImageToolOutcome(
            result: ChatToolResult(callID: call.id, content: content),
            drawn: images.count,
            imagePaths: images.map(\.path))
    }

    /// 把某个模型换进显存，但不改 `selectedModel`：工具只是借用图像模型，
    /// 对话的模式和模型选择都不该跟着变（那会把输入框切到「提示词 → 图像」）。
    ///
    /// `alongside` 为真时只加载、不卸载已经常驻的模型：图像模型进来时对话模型
    /// 还要接着把这一轮写完，换掉它就得再花几十秒加载回来。
    private func ensureResidentModel(
        _ target: String,
        stage: @escaping (String) -> Void,
        alongside: Bool = false
    ) async -> String? {
        guard let controller else { return "推理引擎未就绪" }
        if gatewayModelIsResident(target, in: controller) { return nil }
        if !controller.isRunning {
            await controller.start()
        }
        let outcome =
            alongside
            ? await controller.loadModelKeepingResident(target, stage: stage)
            : await controller.switchModel(target, stage: stage)
        switch outcome {
        case .ready:
            return nil
        case .failed(let message):
            return message
        }
    }

    /// 组装回放给引擎的上下文。画过图的 assistant 轮要带着 tool_calls，
    /// 紧接着按 call_id 补 tool 结果——只留最终文字的话，模型会忘记自己画了
    /// 什么，用户追问「第二张换个光线」时它接不上。
    private func conversationTurns() -> [ChatTurn] {
        var turns: [ChatTurn] = []
        for message in messages where !message.streaming {
            if !message.toolCalls.isEmpty {
                let answered = Set(message.toolResults.map(\.callID))
                if message.toolCalls.allSatisfy({ answered.contains($0.id) }) {
                    turns.append(
                        ChatTurn(
                            role: "assistant", content: message.content,
                            toolCalls: message.toolCalls))
                    for result in message.toolResults {
                        turns.append(
                            ChatTurn(
                                role: "tool", content: result.content,
                                toolCallID: result.callID))
                    }
                    continue
                }
            }
            guard !message.content.isEmpty else { continue }
            turns.append(ChatTurn(role: message.role, content: message.content))
        }
        return turns
    }

    /// 模型可能忽略枚举自己编尺寸：解析成宽高后用这一族的规则校一遍，
    /// 不合格就退回用户当前设置；连用户设置都不适用时（换了图像模型家族），
    /// 取这一族的第一个预设，而不是让引擎去拒绝一个它画不了的长宽比。
    private static func sanitizedCanvas(
        _ raw: String?,
        profile: ImageModelProfile,
        fallback: String
    ) -> String {
        func acceptable(_ value: String) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let parts = trimmed.split(separator: "x")
            guard parts.count == 2,
                let width = Int(parts[0]),
                let height = Int(parts[1]),
                profile.isValidCanvas(width: width, height: height)
            else { return false }
            return profile.allowsCustomCanvas || profile.presets.contains { $0.id == trimmed }
        }
        if let raw, acceptable(raw) { return raw.lowercased() }
        if acceptable(fallback) { return fallback.lowercased() }
        return profile.presets.first?.id ?? fallback
    }

    /// 阶段行（「正在画第 2/3 张 · 去噪 8/20」）写进占位消息，代替正文位置。
    private func setToolStage(_ stage: String?, generation: Int) {
        guard sendGeneration == generation else { return }
        updateStreamingMessage { $0.toolStage = stage }
    }

    /// 一张图画完就挂到消息上：用户不用等整组画完才看到第一张。
    private func appendToolImage(path: String, note: String, seed: Int, generation: Int) {
        guard sendGeneration == generation else { return }
        updateStreamingMessage { message in
            message.imagePaths.append(path)
            if message.imagePath == nil { message.imagePath = path }
            if message.imageNote == nil { message.imageNote = note }
            message.imageSeed = seed
        }
    }

    /// 最近一组成品。只回看紧邻的几条消息：再往前追，用户已经在聊别的了，
    /// 把旧图塞进请求既费上下文，也容易让模型答非所问。
    private func recentGeneratedImagePaths(within distance: Int = 6) -> [String] {
        for message in messages.suffix(distance).reversed() where message.role == "assistant" {
            if !message.imagePaths.isEmpty { return message.imagePaths }
            if let path = message.imagePath { return [path] }
        }
        return []
    }

    /// 落盘路径 → OpenAI 的 data URL。读不到/解码失败的直接跳过，不让一张
    /// 坏图把整轮对话卡死。
    private func imageURLs(for paths: [String]) -> [String] {
        paths.compactMap { ImageStore.chatImageURL(atPath: $0) }
    }

    /// 画完后紧跟着的一条「用户」消息：把成品递到模型眼前，并明确告诉它
    /// 该看什么、还能不能继续画。只放在本轮的内存上下文里，不落盘。
    private func visionFeedback(count: Int, canDrawMore: Bool) -> String {
        var text = "你刚画好了这 \(count) 张图，下面按生成顺序附上成品。"
        text += "先逐张看清画面：主体、构图、文字、手部这些细节，是否达到你在提示词里写的要求。"
        text += "描述时只说你真正看到的，不要照着提示词编。"
        text +=
            canDrawMore
            ? "达到要求就用一两句话向用户交代；需要改就继续调用 \(ImageTool.name) 补画，只补要改的，别重复画已经满意的。"
            : "这一轮的画图次数已经用完，直接根据看到的画面收尾；还需要改的地方，用文字告诉用户。"
        return text
    }

    /// 调用与结果留在消息里，下一轮（甚至重启后）还要按原样回放给引擎。
    private func recordToolExchange(
        calls: [ChatToolCall],
        results: [ChatToolResult],
        generation: Int
    ) {
        guard sendGeneration == generation else { return }
        updateStreamingMessage { message in
            message.toolCalls.append(contentsOf: calls)
            message.toolResults.append(contentsOf: results)
        }
    }

    /// 这一轮画完：压上累计用量、收掉「生成中」，再落盘。
    private func finishImageToolTurn(
        content: String,
        usage: ChatUsage,
        generation: Int,
        started: Date
    ) {
        guard sendGeneration == generation else { return }
        let elapsed = Date().timeIntervalSince(started)
        updateStreamingMessage { message in
            if !content.isEmpty { message.content = content }
            message.streaming = false
            message.toolStage = nil
            message.seconds = elapsed
            if usage.completionTokens > 0 {
                message.usage = usage
                if metrics.streamDecodingSeconds > 0 {
                    message.tokensPerSecond = Double(usage.completionTokens) / metrics.streamDecodingSeconds
                }
            } else {
                // 流式响应常省略 usage，退回按分片估的数字，消息右下角不至于是空的。
                let tokens = Int(metrics.streamTotalTokens.rounded())
                if tokens > 0 {
                    message.usage = ChatUsage(promptTokens: 0, completionTokens: tokens)
                    if metrics.streamDecodingSeconds > 0 {
                        message.tokensPerSecond = Double(tokens) / metrics.streamDecodingSeconds
                    }
                }
            }
        }
        chatStartupStage = nil
        generationStatus = "完成"
        generating = false
        persistStreamingConversation()
    }

    /// 失败收尾：和文本链路同一口径，气泡里写原因、顶部再冒一条。
    private func finishImageToolTurn(failure: String, generation: Int) {
        guard sendGeneration == generation else { return }
        updateStreamingMessage { message in
            message.streaming = false
            message.toolStage = nil
            if message.content.isEmpty { message.content = "出错：\(failure)" }
        }
        hooks.setNotice(failure)
        chatStartupStage = nil
        generationStatus = "失败"
        generating = false
        persistStreamingConversation()
    }

    /// 视频模型的发送链路：对话、历史、打点都复用，只把端点换成
    /// `/v1/video/generations`。服务端回的是 rgb8 原始帧，VideoClient 在客户端
    /// 封装成 MP4 后落盘，消息里只留路径。
    private func sendVideo(
        _ prompt: String,
        attachment: ChatImageAttachment?,
        lastFrame: ChatImageAttachment?,
        referenceImages: [ChatImageAttachment],
        referenceClips: [VideoReferenceClip],
        options: VideoOptions
    ) {
        let model = selectedModel
        let seed = options.seed ?? Int.random(in: 1...1_000_000_000)
        var sourcePath: String?
        var sourceBase64: String?
        if let attachment {
            guard let imported = ImageStore.importImage(atPath: attachment.path),
                let encoded = ImageStore.base64(atPath: imported)
            else {
                hooks.setNotice("读取首帧图片失败：\(attachment.name)")
                return
            }
            sourcePath = imported
            sourceBase64 = encoded
        }
        var lastFramePath: String?
        var lastFrameBase64: String?
        if let lastFrame {
            guard let imported = ImageStore.importImage(atPath: lastFrame.path),
                let encoded = ImageStore.base64(atPath: imported)
            else {
                hooks.setNotice("读取尾帧图片失败：\(lastFrame.name)")
                return
            }
            lastFramePath = imported
            lastFrameBase64 = encoded
        }
        // REF2VA 的参考图先拷进作品目录，base64 留到 Task 里再读：一次挑
        // 九张相机原图，主线程不能停在文件读取上。
        var referenceImagePaths: [String] = []
        for item in referenceImages {
            guard let imported = ImageStore.importImage(atPath: item.path) else {
                hooks.setNotice("读取参考图失败：\(item.name)")
                return
            }
            referenceImagePaths.append(imported)
        }
        let referenceClipPaths = referenceClips.map(\.path)
        let usesReferences = !referenceImagePaths.isEmpty || !referenceClipPaths.isEmpty

        messages.append(
            ChatMessage(
                role: "user", content: prompt, model: model,
                createdAt: Date(),
                imagePath: usesReferences ? nil : sourcePath,
                videoLastFramePath: usesReferences ? nil : lastFramePath,
                videoReferenceImagePaths:
                    referenceImagePaths.isEmpty ? nil : referenceImagePaths,
                videoReferenceClipPaths:
                    referenceClipPaths.isEmpty ? nil : referenceClipPaths))
        let placeholder = ChatMessage(
            role: "assistant", content: "", model: model,
            createdAt: Date(), streaming: true,
            videoProgress: "正在准备视频模型")
        messages.append(placeholder)
        streamMessageID = placeholder.id.uuidString
        history.save(messages: messages, threadID: threadID)
        threads = history.load()
        generating = true
        generationStatus = "正在准备视频模型"
        sendGeneration &+= 1
        let generation = sendGeneration
        chatStartupStage = nil
        videoTask?.cancel()
        videoTask = Task { [weak self] in
            guard let self else { return }
            // 参考素材先读完再加载模型：文件有问题就早点报错，不必让用户等
            // 几十 GB 的权重加载完才发现参考视频读不了。
            var referenceImagesBase64: [String] = []
            let referencePixel =
                options.referenceDetail == .max
                ? 1280
                : max(options.dimensions.width, options.dimensions.height)
            for path in referenceImagePaths {
                guard self.sendGeneration == generation else { return }
                guard
                    let encoded = ImageStore.jpegBase64(
                        atPath: path,
                        maximumPixel: CGFloat(referencePixel))
                else {
                    self.failVideo("读取参考图失败：\((path as NSString).lastPathComponent)")
                    return
                }
                referenceImagesBase64.append(encoded)
            }
            var referencePayloads: [VideoReferencePayload] = []
            if !referenceClipPaths.isEmpty {
                let canvas = options.dimensions
                let maximum =
                    options.referenceDetail == .max
                    ? CGSize(width: 1280, height: 1280)
                    : CGSize(width: canvas.width, height: canvas.height)
                for (index, path) in referenceClipPaths.enumerated() {
                    guard self.sendGeneration == generation else { return }
                    let label = "正在读取参考视频 \(index + 1)/\(referenceClipPaths.count)"
                    self.generationStatus = label
                    self.updateStreamingMessage { $0.videoProgress = label }
                    do {
                        let frames = try await VideoReferenceExtractor.frames(
                            url: URL(fileURLWithPath: path),
                            maximumSize: maximum
                        ) { [weak self] text in
                            Task { @MainActor in
                                guard let self, self.sendGeneration == generation else { return }
                                self.updateStreamingMessage { $0.videoProgress = text }
                            }
                        }
                        referencePayloads.append(VideoReferencePayload(framesBase64: frames))
                    } catch is CancellationError {
                        return
                    } catch {
                        self.failVideo(error.localizedDescription)
                        return
                    }
                }
            }
            let preparation = await self.prepareModelForGateway(
                model,
                allowingGeneration: true)
            guard self.sendGeneration == generation else { return }
            if let preparation {
                self.failVideo(preparation.message)
                return
            }

            let meterID = GatewayMeter.shared.begin(
                model: model, dialect: "video",
                promptTokens: 0)
            GatewayMeter.shared.markStarted(meterID, at: Date())
            if usesReferences {
                self.generationStatus = "正在生成视频（\(referenceImagesBase64.count) 张参考图 · \(referencePayloads.count) 段参考视频）"
            } else {
                switch (sourceBase64, lastFrameBase64) {
                case (nil, nil): self.generationStatus = "正在生成视频"
                case (.some, .some): self.generationStatus = "正在生成视频（首尾帧）"
                case (.some, nil): self.generationStatus = "正在生成视频（首帧）"
                case (nil, .some): self.generationStatus = "正在生成视频（尾帧）"
                }
            }
            let dimensions = options.dimensions
            let request = VideoGenerationRequest(
                model: model,
                prompt: prompt,
                size: "\(dimensions.width)x\(dimensions.height)",
                frames: options.frames,
                steps: options.steps,
                seed: seed,
                firstFrameBase64: usesReferences ? nil : sourceBase64,
                lastFrameBase64: usesReferences ? nil : lastFrameBase64,
                referenceImagesBase64: referenceImagesBase64,
                referenceVideos: referencePayloads,
                referenceDetail: options.referenceDetail)
            let outcome = await self.videoClient.generate(
                port: self.port,
                request: request
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.sendGeneration == generation else { return }
                    self.updateStreamingMessage { $0.videoProgress = progress }
                }
            }
            guard self.sendGeneration == generation else {
                GatewayMeter.shared.finish(meterID, failed: true)
                return
            }
            switch outcome {
            case .success(let result):
                GatewayMeter.shared.finish(meterID)
                let mp4 = result.mp4
                let path = await Task.detached(priority: .userInitiated) {
                    VideoStore.save(mp4)
                }.value
                guard self.sendGeneration == generation else { return }
                let note = self.videoNote(
                    options: options, source: sourcePath,
                    lastFrame: lastFramePath,
                    referenceImages: referenceImagePaths.count,
                    referenceClips: referencePayloads.count,
                    result: result, seed: seed)
                self.updateStreamingMessage { message in
                    message.streaming = false
                    message.videoProgress = nil
                    message.seconds = result.seconds
                    message.videoPath = path
                    message.videoSourcePath = sourcePath
                    message.videoNote = note
                    if path == nil {
                        message.content = "视频已生成，但写入磁盘失败"
                    }
                }
                if path == nil {
                    self.hooks.setNotice("视频已生成，但写入磁盘失败")
                } else if let path {
                    // 和图片一样单独记一份：历史只留最近六段，删对话也不该丢作品。
                    VideoGalleryStore.shared.record(
                        GalleryVideo(
                            path: path,
                            prompt: prompt,
                            model: model,
                            createdAt: Date(),
                            note: note,
                            seed: seed))
                }
            case .failure(let error):
                GatewayMeter.shared.finish(meterID, failed: true)
                self.failVideo(error.message)
            }
            self.videoTask = nil
            self.generating = false
            self.persistStreamingConversation()
        }
    }

    /// 视频链路的失败收尾。显存不够和帧数过大是最常见的两类，直接说怎么改。
    private func failVideo(_ raw: String) {
        let message = Self.friendlyVideoError(raw)
        updateStreamingMessage { item in
            item.streaming = false
            item.videoProgress = nil
            if item.content.isEmpty { item.content = "出错：\(message)" }
        }
        hooks.setNotice(message)
        chatStartupStage = nil
        videoTask = nil
        generating = false
        persistStreamingConversation()
    }

    private static func friendlyVideoError(_ raw: String) -> String {
        let lowered = raw.lowercased()
        if lowered.contains("does not support references")
            || lowered.contains("declares no 'ref2va'")
            || lowered.contains("ref2va pack cannot serve")
        {
            return "这个视频模型不支持参考素材。参考图/参考视频需要 REF2VA 视频包；首尾帧请换用 FL2VA/LTX 包。"
        }
        if lowered.contains("attach at least one image or video") {
            return "REF2VA 必须至少附一张参考图或一段参考视频。"
        }
        if lowered.contains("too many reference") || lowered.contains("too many references") {
            return "参考素材超出上限：最多 9 张参考图、3 段参考视频，合计 12 个。"
        }
        if lowered.contains("60 mib") || lowered.contains("upload budget") {
            return "参考素材太大，超过 60 MB 上传上限。减少参考图数量，或把参考细节改成「匹配画布」。"
        }
        if lowered.contains("at least 5 frames") || lowered.contains("needs at least 5") {
            return "参考视频太短：至少需要 5 帧（约 0.2 秒）。换一段更长的视频。"
        }
        if lowered.contains("ref_videos") || lowered.contains("ref_images")
            || lowered.contains("ref_image_size")
        {
            return "参考素材没有被接受（\(raw)）。参考图请用 PNG/JPEG，参考视频至少 5 帧。"
        }
        if lowered.contains("out of memory") || lowered.contains("oom")
            || lowered.contains("insufficient memory") || lowered.contains("memory")
        {
            return "显存不够生成这段视频。把分辨率或帧数调小一些再试（例如 512×384、49 帧）。"
        }
        if lowered.contains("vae_encoder") || lowered.contains("last frame conditioning") {
            return "这个视频模型没有带尾帧条件需要的 VAE 编码器：去掉尾帧，只留首帧或纯文字再试。"
        }
        if lowered.contains("last_frame") || lowered.contains("last frame") {
            if lowered.contains("9 frames") || lowered.contains("at least 9") {
                return "尾帧要求至少 9 帧：把帧数调到 9 以上（例如 49 帧）再试。"
            }
            return "尾帧图片没有被接受：换一张 PNG/JPEG，或去掉尾帧重试。"
        }
        if lowered.contains("first_frame") || lowered.contains("first frame") {
            return "首帧图片没有被接受：换一张 PNG/JPEG，或去掉附件改为纯文字生成。"
        }
        if lowered.contains("num_frames") || lowered.contains("too many frames") {
            return "帧数超出这个模型的范围：把帧数调小后重试。"
        }
        if lowered.contains("does not load") || lowered.contains("failed to load") {
            return "这个视频模型加载失败（\(raw)）。请确认权重完整、显存够用后重试。"
        }
        return raw
    }

    private func videoNote(
        options: VideoOptions,
        source: String?,
        lastFrame: String?,
        referenceImages: Int = 0,
        referenceClips: Int = 0,
        result: VideoGenerationResult,
        seed: Int
    ) -> String {
        var parts = [
            "\(result.width)×\(result.height)",
            "\(result.frames) 帧",
            "\(result.fps)fps",
            "\(options.steps) 步",
        ]
        if source != nil, lastFrame != nil {
            parts.append("首尾帧生视频")
        } else if source != nil {
            parts.append("首帧生视频")
        } else if lastFrame != nil {
            parts.append("尾帧生视频")
        }
        var references: [String] = []
        if referenceImages > 0 { references.append("\(referenceImages) 张参考图") }
        if referenceClips > 0 { references.append("\(referenceClips) 段参考视频") }
        if !references.isEmpty {
            parts.append(references.joined(separator: " + "))
        }
        parts.append("seed \(seed)")
        return parts.joined(separator: " · ")
    }

    /// 图像链路的失败收尾：气泡里写原因，顶部再冒一条，和对话的错误口径一致。
    private func failImage(_ raw: String) {
        let message = Self.friendlyImageError(raw)
        updateStreamingMessage { item in
            item.streaming = false
            item.imageProgress = nil
            if item.content.isEmpty { item.content = "出错：\(message)" }
        }
        hooks.setNotice(message)
        chatStartupStage = nil
        imageTask = nil
        generating = false
        persistStreamingConversation()
    }

    /// 把引擎的原始报错翻译成能照着做的建议。本地 Qwen 转换包没带视觉塔，
    /// 指令编辑必然 400，这不算用户操作错。
    private static func friendlyImageError(_ raw: String) -> String {
        let lowered = raw.lowercased()
        if lowered.contains("vision tower") || lowered.contains("re-convert") {
            return "当前图像模型缺少视觉塔，不能按指令改图。去掉附件、只发提示词可以重绘，或换用带视觉塔的转换包。"
        }
        if lowered.contains("does not load") {
            return "这个图像模型加载失败（\(raw)）。请确认权重完整后重试。"
        }
        return raw
    }

    private func imageNote(
        options: ImageOptions,
        attachment: ChatImageAttachment?,
        path: String?,
        actualSteps: Int? = nil
    ) -> String {
        var parts: [String] = []
        if let path, let pixels = ImageStore.pixelSize(atPath: path) {
            parts.append("\(Int(pixels.width))×\(Int(pixels.height))")
        } else {
            parts.append(options.size.replacingOccurrences(of: "x", with: "×"))
        }
        if let actualSteps, actualSteps > 0, actualSteps != options.steps {
            parts.append("\(actualSteps) 步（引擎实际）")
        } else {
            parts.append("\(options.steps) 步")
        }
        if attachment != nil {
            parts.append("重绘 \(Int((options.strength * 100).rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    /// 把刚跑完的这一轮落盘：切到后台的那一轮按它自己的 `threadID` 写回历史，
    /// 还在前台的就照旧写当前会话。
    /// - Returns: 写回的是后台那一段时返回它的 `threadID`，前台返回 nil。
    @discardableResult
    private func persistStreamingConversation() -> String? {
        if let running = background {
            background = nil
            history.save(messages: running.messages, threadID: running.threadID)
            threads = history.load()
            return running.threadID
        }
        conversation.save(messages)
        history.save(messages: messages, threadID: threadID)
        threads = history.load()
        return nil
    }

    /// 与网关共用 Kit 里的同一套估算，避免两个页面对同一段文本给出不同 token 数。
    static func estimateTokens(_ text: String) -> Int {
        TokenEstimator.estimate(text)
    }

    func cancelGeneration() {
        sendGeneration &+= 1
        chatStartupStage = nil
        chatClient.cancel()
        imageTask?.cancel()
        imageTask = nil
        videoTask?.cancel()
        videoTask = nil
        imageToolTask?.cancel()
        imageToolTask = nil
        generating = false
        generationStatus = "已取消"
        settleStreamingMessage()
        // 这一轮的分片还可能在路上：断开落点之后迟到的分片找不到消息，
        // 不会写进紧接着发出的下一轮。
        streamMessageID = ""
        // 后台那一轮也按它自己的会话收尾：点「停止」不该让它的半截回答消失。
        persistStreamingConversation()
    }

    /// 把还在流式的那条收掉：保留已经吐出的正文与思考，正文为空也不删，
    /// 由消息行显示「已停止生成」。前台与后台都认。
    private func settleStreamingMessage() {
        if var running = background {
            settleStreamingOnStop(&running.messages)
            background = running
            return
        }
        settleStreamingOnStop(&messages)
    }

    /// Drop the trailing answer and ask again with the same prompt.
    func regenerate() {
        guard !generating else { return }
        guard let lastUser = messages.last(where: { $0.role == "user" }) else { return }
        while let last = messages.last, last.role == "assistant" { messages.removeLast() }
        if messages.last?.role == "user" { messages.removeLast() }
        // 图生图那一轮：底图是用户消息的一部分，重来一次也要带着它。
        let attachment = lastUser.imagePath.map { path in
            ChatImageAttachment(
                path: path,
                name: (path as NSString).lastPathComponent,
                pixelSize: ImageStore.pixelSize(atPath: path))
        }
        send(lastUser.content, attachment: attachment)
    }

    /// 切走会话：把正在生成的那一段连人带消息搬到后台，别中断、也别写串。
    ///
    /// 以前这里直接 `cancelGeneration()`，而它只写 `conversation.json`——
    /// 「最近对话」里留着的还是上一轮的快照。于是「回复到一半切去概览 /
    /// 从列表点回同一段对话」看到的就是：刚才那条回答不见了。现在生成继续
    /// 在后台跑完，跑完按它自己的 `threadID` 落回历史。
    private func detachGenerationForThreadSwitch() {
        guard generating, background == nil else { return }
        background = BackgroundGeneration(threadID: threadID, messages: messages)
    }

    func newConversation() {
        detachGenerationForThreadSwitch()
        messages.removeAll()
        conversation.clear()
        threadID = Self.newThreadID()
    }

    func openThread(_ thread: ChatThread) {
        // 点回正在生成的那一段：把后台那份接回前台，后面的分片继续往这里写。
        if let running = background, running.threadID == thread.id {
            background = nil
            messages = running.messages
            threadID = thread.id
            hooks.showChat()
            return
        }
        guard thread.id != threadID else {
            // 点的就是当前这段：别用历史里的旧快照把正在流的回答盖掉，
            // 也绝对不能先 detach 到 background（否则前台 messages 不再收到流式分片）。
            hooks.showChat()
            return
        }
        detachGenerationForThreadSwitch()
        messages = thread.messages.map {
            ChatMessage(
                role: $0.role, content: $0.content, model: $0.model,
                createdAt: $0.createdAt, usage: $0.usage,
                seconds: $0.seconds, tokensPerSecond: $0.tokensPerSecond,
                firstTokenSeconds: $0.firstTokenSeconds,
                thinkingSeconds: $0.thinkingSeconds,
                reasoning: $0.reasoning,
                interrupted: $0.interrupted,
                imagePath: $0.imagePath,
                imageNote: $0.imageNote,
                imageSourcePath: $0.imageSourcePath,
                imageStrength: $0.imageStrength,
                imageSeed: $0.imageSeed,
                imagePaths: $0.imagePaths,
                toolCalls: $0.toolCalls,
                toolResults: $0.toolResults,
                videoPath: $0.videoPath,
                videoNote: $0.videoNote,
                videoSourcePath: $0.videoSourcePath,
                videoLastFramePath: $0.videoLastFramePath,
                videoReferenceImagePaths: $0.videoReferenceImagePaths,
                videoReferenceClipPaths: $0.videoReferenceClipPaths)
        }
        threadID = thread.id
        // 打开的这段对话就是「当前对话」：不写回 `conversation.json` 的话，
        // 下次启动会拿 list 里旧的正文配上这里新的 `threadID`，下一轮保存
        // 还会把旧正文写到新 id 名下。
        conversation.save(messages)
        hooks.showChat()
    }

    /// 删除按钮只负责挂起：确认弹窗在壳层，两个列表用的是同一段文案与同一个落点。
    func requestThreadDelete(_ thread: ChatThread) {
        pendingThreadDelete = thread
    }

    func cancelThreadDelete() {
        pendingThreadDelete = nil
    }

    func confirmThreadDelete() {
        guard let thread = pendingThreadDelete else { return }
        pendingThreadDelete = nil
        deleteThread(thread)
    }

    /// 改名同样只挂起，壳层统一弹输入框；侧栏与对话页标题菜单共用这一条。
    func requestThreadRename(_ thread: ChatThread) {
        pendingThreadRename = thread
    }

    func cancelThreadRename() {
        pendingThreadRename = nil
    }

    func confirmThreadRename(_ title: String) {
        guard let thread = pendingThreadRename else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingThreadRename = nil
        guard !trimmed.isEmpty else { return }
        history.rename(id: thread.id, title: trimmed)
        threads = history.load()
    }

    /// 置顶 / 取消置顶，和历史一起落盘。
    func setThreadPinned(_ thread: ChatThread, _ pinned: Bool) {
        history.pin(id: thread.id, pinned)
        threads = history.load()
    }

    func deleteThread(_ thread: ChatThread) {
        // 删掉的正是在生成的那段（前台或后台）：先停掉，别让它跑完再把这条写回来。
        if generating, thread.id == generatingThreadID { cancelGeneration() }
        history.delete(id: thread.id)
        drafts.forget(thread.id)
        threads = history.load()
        // 删掉的是当前这段对话：清空正文、换一条新会话。只换 id 不换正文的话，
        // 下一轮保存会把刚删掉的内容写到新 id 名下，界面上也还停在已删除的对话里。
        if thread.id == threadID {
            messages.removeAll()
            conversation.clear()
            threadID = Self.newThreadID()
        }
        toast(L10n.format("已删除对话「%@」", thread.title))
    }

    func clearThreads() {
        if generating { cancelGeneration() }
        for thread in threads {
            history.delete(id: thread.id)
            drafts.forget(thread.id)
        }
        threads = history.load()
        // 清空历史等于把当前这段也删了：正文和草稿一起回到新会话。
        messages.removeAll()
        conversation.clear()
        threadID = Self.newThreadID()
    }

    func resetChatParameters() {
        settings.setTemperature(0.7)
        settings.setTopP(0.95)
        // 0 = 留空，交回「模型自身上限」；写死 4096 会让思考模型连正文都发不出来。
        settings.setMaxTokens(0)
        settings.setSystemPrompt("")
        settings.setThinkingMode(.automatic)
        toast("已恢复默认对话参数", transient: true)
    }
}
