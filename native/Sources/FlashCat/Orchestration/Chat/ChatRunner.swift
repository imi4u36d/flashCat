// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import CoreGraphics
import FlashCatCore
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
    /// 只认识 `ChatHost` 协议。弱引用：外层持有本对象，强引用回去就是一个环；
    /// 引擎控制器每次现取，切过引擎之后旧的那个已经没用了。
    weak var host: (any ChatHost)?

    /// 依赖全部构造时注入：这里不读单例，也就能在测试里塞替身。
    let chat: ChatStore
    let session: ChatSessionStore
    let drafts: ChatDraftStore
    let engineSession: EngineSessionStore
    let settings: AppSettings
    let history: ChatHistory
    let conversation: ConversationStore
    let chatClient: any ChatStreaming
    let imageClient: any ImageGenerating
    let videoClient: any VideoGenerating

    init(
        chat: ChatStore,
        session: ChatSessionStore,
        drafts: ChatDraftStore,
        engineSession: EngineSessionStore,
        settings: AppSettings,
        history: ChatHistory,
        conversation: ConversationStore,
        chatClient: any ChatStreaming,
        imageClient: any ImageGenerating,
        videoClient: any VideoGenerating
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
    }

    // MARK: - store 转发

    /// 下面这些都是同名转发：搬过来的一千多行原样保留调用点，状态仍然只有
    /// store 里那一份，不在这里再存一遍。
    var messages: [ChatMessage] {
        get { chat.messages }
        set { chat.messages = newValue }
    }
    var threads: [ChatThread] {
        get { chat.threads }
        set { chat.threads = newValue }
    }
    var generating: Bool {
        get { chat.generating }
        set { chat.generating = newValue }
    }
    var generationStatus: String? {
        get { chat.generationStatus }
        set { chat.generationStatus = newValue }
    }
    var chatStartupStage: String? {
        get { chat.chatStartupStage }
        set { chat.chatStartupStage = newValue }
    }
    var pendingThreadDelete: ChatThread? {
        get { session.pendingThreadDelete }
        set { session.pendingThreadDelete = newValue }
    }
    var pendingThreadRename: ChatThread? {
        get { session.pendingThreadRename }
        set { session.pendingThreadRename = newValue }
    }
    var imageToolEnabled: Bool { session.imageToolEnabled }
    var imageToolModelID: String { session.imageToolModelID }
    var imageToolResident: Bool { session.imageToolResident }
    var selectedModel: String { engineSession.selectedModel }
    var serverState: ServerState { engineSession.serverState }

    /// 引擎控制器每次现取：切过引擎之后旧的那个已经没用了。
    var controller: EngineController? { host?.controller }
    var activeEngine: EngineID { host?.activeEngine ?? .splash }
    var isSwitchingModel: Bool { engineSession.switchingModel != nil }
    var isRunning: Bool { controller?.isRunning ?? false }
    var canChat: Bool { host?.canChat ?? false }
    var needsEngineSetup: Bool { host?.needsEngineSetup ?? true }
    var effectiveMaxTokens: Int { host?.effectiveMaxTokens ?? 0 }
    var engineStageText: String { host?.engineStageText ?? "" }
    var port: Int { host?.port ?? 0 }
    var selectedModelInfo: ModelInfo? { host?.selectedModelInfo }

    func engineModels(for engine: EngineID) -> [EngineModel] {
        host?.engineModels(for: engine) ?? []
    }

    // MARK: - 线程标识

    /// 当前会话在「最近对话」里的 id。以前每轮生成结束都新建一条线程，同一段
    /// 对话会在侧栏堆成好几份（概览读到的上下文也可能来自旧副本）；现在这个 id
    /// 跟着 `conversation.json` 一起用，`history.save` 原地覆盖而不是 insert。
    /// 落在 UserDefaults，重启后续着同一条。
    var threadID: String {
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
    var sendGeneration = 0
    /// 正在跑的图像请求。停止按钮先掐断它，再按对话同一套收尾。
    var imageTask: Task<Void, Never>?
    /// 正在跑的视频请求（可能正在生成几十秒，也可能在封装 MP4）。
    var videoTask: Task<Void, Never>?
    /// 正在跑的一整轮「对话 + 画图」：中间要换图像模型、画完再换回来，
    /// 可能持续几分钟，停止按钮要和上面两个一起掐断它。
    var imageToolTask: Task<Void, Never>?
    /// The assistant message this generation owns, located by id.
    var streamMessageID = ""
    /// 读者切走了、但还在后台生成的那一段对话。
    ///
    /// 生成一旦开始就不能靠「当前页面显示哪段对话」来决定回答写到哪：切走时
    /// 把整段对话连同它自己的 `threadID` 搬到这里，流式更新认这一份，跑完后
    /// 按自己的 id 落回历史，读者回到这段对话时再整体接回 `messages`。
    struct BackgroundGeneration {
        let threadID: String
        var messages: [ChatMessage]
    }
    var background: BackgroundGeneration?
    /// 本次请求的提示词 token 估算，生成期间用来实时刷新上下文占用。`AppState`
    /// 的 `contextUsedTokens` 还要读它（顶栏与概览卡的实时数字）。
    var livePromptTokens = 0

    // MARK: - 回到 AppState 的动作

    func toast(_ message: String, kind: IslandNotice.Kind? = nil, transient: Bool = false) {
        host?.toast(message, kind: kind, transient: transient)
    }

    /// 阻塞式错误横幅。`host.notice` 的写入路径只有这一处，方便以后换成更明确的
    /// 通知类型而不必再改十几个调用点。
    func setNotice(_ message: String) {
        host?.notice = message
    }

    /// 本轮生成在网关打点里的请求 id。消息 tok/s、usage 缺席时的 token 数与
    /// 生成期间的上下文估算都按它读 `GatewaySessionMeter.progress(_:)`——和
    /// 概览曲线同一份数据，不再在本地维护第二套 token 累计。
    private(set) var activeMeterID: Int?

    /// 画图链路在另一个文件里，`private(set)` 的 setter 只在本文件可见，
    /// 所以登记走这个方法。
    func adoptMeter(_ id: Int) {
        activeMeterID = id
    }

    /// 本轮已生成的小数权重 token 数（网关会话的读数）。
    var liveCompletionTokens: Double {
        guard let id = activeMeterID else { return 0 }
        return GatewayMeter.shared.progress(id)?.tokens ?? 0
    }

    func gatewayModelIsResident(_ target: String, in controller: EngineController) -> Bool {
        host?.gatewayModelIsResident(target, in: controller) ?? false
    }

    func prepareModelForGateway(
        _ model: String, allowingGeneration: Bool
    ) async -> GatewayModelPreparationError? {
        await host?.prepareModelForGateway(model, allowingGeneration: allowingGeneration)
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
    func updateStreamingMessage(_ body: (inout ChatMessage) -> Void) -> Bool {
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
    func prepareChatSession(generation: Int) async -> Bool {
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
            setNotice("还没有安装推理引擎，请先在启动页选择一个")
            return
        }
        guard !selectedModel.isEmpty else {
            setNotice("还没有选择模型")
            return
        }
        // 新一轮开始：上一轮的打点 id 立刻失效，上下文估算不能读到旧会话。
        activeMeterID = nil
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
            promptTokens: promptTokens,
            client: "flashCat")
        activeMeterID = meterID

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
                    self.setNotice(reason)
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
                        self.updateStreamingMessage { message in
                            if message.firstTokenSeconds == nil {
                                let ttft = at.timeIntervalSince(started)
                                message.firstTokenSeconds = ttft
                                // 正文首字之前的这段时间就是思考阶段；记下来，回答结束后
                                // 折叠的思考块仍能给出真实时长。
                                message.thinkingSeconds = ttft
                            }
                            message.content += piece
                        }
                    }
                },
                onReasoning: { piece, at in
                    GatewayMeter.shared.addTokens(meterID, TokenEstimator.fractional(piece), at: at)
                    Task { @MainActor in
                        guard self.sendGeneration == generation else { return }
                        self.updateStreamingMessage { message in
                            message.reasoning = (message.reasoning ?? "") + piece
                            if message.content.isEmpty {
                                self.generationStatus = "思考中"
                            }
                        }
                    }
                },
                onUsage: { usage in
                    GatewayMeter.shared.noteUsage(
                        meterID,
                        promptTokens: usage.promptTokens,
                        completionTokens: usage.completionTokens,
                        cachedPromptTokens: usage.cachedPromptTokens)
                    if let timings = usage.timings {
                        GatewayMeter.shared.noteTimings(meterID, timings)
                    }
                    Task { @MainActor in
                        guard self.sendGeneration == generation else { return }
                        guard self.updateStreamingMessage({ $0.usage = usage }) else { return }
                        // 思考截断可见性：引擎按预算收束思考时，reasoning_tokens
                        // 正好落在预算上，用「≥ 预算」判定这次思考被截断。
                        if let budget = options.thinkingBudget,
                            let reasoning = usage.reasoningTokens,
                            reasoning >= budget
                        {
                            self.host?.logWarning(
                                "==> 思考截断：本次思考 \(reasoning) tokens 触及预算 \(budget)，已被强制收束；如需更长思考请在引擎配置调大「思考截断」")
                        }
                        // max_tokens 是思考与正文共享的总输出上限，打满即硬截断
                        //（finish_reason=length），思考模型默认值下最容易撞上。
                        if usage.finishReason == "length" {
                            let reasoning = usage.reasoningTokens.map { "，其中思考 \($0) tokens" } ?? ""
                            self.host?.logWarning(
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
                // 消息级读数与概览曲线同一份打点：usage 缺席时用网关会话的
                // 估算 token 兜底，分母取首分片 → 末分片的真实解码时长。
                let progress = GatewayMeter.shared.progress(meterID)
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
                        tokens = Int((progress?.tokens ?? 0).rounded())
                        if tokens > 0 {
                            message.usage = ChatUsage(promptTokens: 0, completionTokens: tokens)
                        }
                    }
                    // 分母取「首分片 → 末分片」，不再把 TTFT / prefill 混进
                    // decode 时长：旧口径把预填充也摊进分母，消息下方的平均
                    // 天生低一大截。
                    if tokens > 0, let seconds = progress?.decodingSeconds, seconds > 0 {
                        message.tokensPerSecond = Double(tokens) / seconds
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
                if !error.isCancellation { setNotice(error.message) }
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

    /// 还在前台的就照旧写当前会话。
    /// - Returns: 写回的是后台那一段时返回它的 `threadID`，前台返回 nil。
    @discardableResult
    func persistStreamingConversation() -> String? {
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
    func settleStreamingMessage() {
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
    func detachGenerationForThreadSwitch() {
        guard generating, background == nil else { return }
        background = BackgroundGeneration(threadID: threadID, messages: messages)
    }

    func newConversation() {
        detachGenerationForThreadSwitch()
        messages.removeAll()
        conversation.clear()
        threadID = Self.newThreadID()
    }

    /// 编辑一条用户消息并重发：删掉它以及之后的回答，再用新文本跑一轮。
    /// 编辑会丢掉后续上下文，界面侧会先确认「这之后的 N 条会被删除」。
    func editAndResend(messageID: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !generating, !trimmed.isEmpty,
            let index = messages.firstIndex(where: { $0.id == messageID }),
            messages[index].role == "user"
        else { return }
        messages.removeSubrange(index...)
        history.save(messages: messages, threadID: threadID)
        threads = history.load()
        send(trimmed)
    }

    /// 从某条消息处分叉：把到这条为止的对话复制到新会话，原会话不动。
    func branchThread(from messageID: UUID) {
        guard !generating,
            let index = messages.firstIndex(where: { $0.id == messageID })
        else { return }
        let prefix = Array(messages.prefix(through: index))
        newConversation()
        messages = prefix
        history.save(messages: messages, threadID: threadID)
        threads = history.load()
    }

    func openThread(_ thread: ChatThread) {
        // 点回正在生成的那一段：把后台那份接回前台，后面的分片继续往这里写。
        if let running = background, running.threadID == thread.id {
            background = nil
            messages = running.messages
            threadID = thread.id
            host?.showChat()
            return
        }
        guard thread.id != threadID else {
            // 点的就是当前这段：别用历史里的旧快照把正在流的回答盖掉，
            // 也绝对不能先 detach 到 background（否则前台 messages 不再收到流式分片）。
            host?.showChat()
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
        host?.showChat()
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
