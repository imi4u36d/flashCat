// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import CoreGraphics
import FlashCatCore
import FlashCatKit
import Foundation

extension ChatRunner {
    // MARK: - 对话里主动画图

    /// 当前引擎会不会说工具调用协议。只挂在支持工具的引擎上：给别的引擎
    /// 发 `tools` 字段，轻则被忽略，重则 400。
    var activeEngineSupportsToolUse: Bool {
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
    func sendImage(
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
                setNotice("读取图片失败：\(attachment.name)")
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
                promptTokens: 0, client: "flashCat")
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
                if path == nil { self.setNotice("图像已生成，但写入磁盘失败") }
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
    func sendWithImageTool(_ text: String, imageModel: EngineModel) {
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
                    promptTokens: promptTokens, client: "flashCat")
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

    struct ImageToolOutcome {
        let result: ChatToolResult
        let drawn: Int
        /// 本轮成功落盘的图片，按生成顺序。视觉模型要把它们回传成像素。
        var imagePaths: [String] = []
    }

    /// 执行一次画图调用：把图像模型换进来、逐张画完、再换回对话模型。
    /// 结果无论成败都写一段 JSON 回给模型——失败也要让它知道为什么，
    /// 它才能向用户解释或者少画两张。
    func runImageTool(
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
                promptTokens: TokenEstimator.estimate(prompt), client: "flashCat")
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
    func ensureResidentModel(
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
    func conversationTurns() -> [ChatTurn] {
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
    func setToolStage(_ stage: String?, generation: Int) {
        guard sendGeneration == generation else { return }
        updateStreamingMessage { $0.toolStage = stage }
    }

    /// 一张图画完就挂到消息上：用户不用等整组画完才看到第一张。
    func appendToolImage(path: String, note: String, seed: Int, generation: Int) {
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
    func recentGeneratedImagePaths(within distance: Int = 6) -> [String] {
        for message in messages.suffix(distance).reversed() where message.role == "assistant" {
            if !message.imagePaths.isEmpty { return message.imagePaths }
            if let path = message.imagePath { return [path] }
        }
        return []
    }

    /// 落盘路径 → OpenAI 的 data URL。读不到/解码失败的直接跳过，不让一张
    /// 坏图把整轮对话卡死。
    func imageURLs(for paths: [String]) -> [String] {
        paths.compactMap { ImageStore.chatImageURL(atPath: $0) }
    }

    /// 画完后紧跟着的一条「用户」消息：把成品递到模型眼前，并明确告诉它
    /// 该看什么、还能不能继续画。只放在本轮的内存上下文里，不落盘。
    func visionFeedback(count: Int, canDrawMore: Bool) -> String {
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
    func recordToolExchange(
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
    func finishImageToolTurn(
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
    func finishImageToolTurn(failure: String, generation: Int) {
        guard sendGeneration == generation else { return }
        updateStreamingMessage { message in
            message.streaming = false
            message.toolStage = nil
            if message.content.isEmpty { message.content = "出错：\(failure)" }
        }
        setNotice(failure)
        chatStartupStage = nil
        generationStatus = "失败"
        generating = false
        persistStreamingConversation()
    }

    /// 视频模型的发送链路：对话、历史、打点都复用，只把端点换成
    /// `/v1/video/generations`。服务端回的是 rgb8 原始帧，VideoClient 在客户端
    /// 封装成 MP4 后落盘，消息里只留路径。
}
