// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import CoreGraphics
import FlashCatCore
import FlashCatKit
import Foundation

extension ChatRunner {
    func sendVideo(
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
                setNotice("读取首帧图片失败：\(attachment.name)")
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
                setNotice("读取尾帧图片失败：\(lastFrame.name)")
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
                setNotice("读取参考图失败：\(item.name)")
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
                promptTokens: 0, client: "flashCat")
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
                    self.setNotice("视频已生成，但写入磁盘失败")
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
    func failVideo(_ raw: String) {
        let message = Self.friendlyVideoError(raw)
        updateStreamingMessage { item in
            item.streaming = false
            item.videoProgress = nil
            if item.content.isEmpty { item.content = "出错：\(message)" }
        }
        setNotice(message)
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

    func videoNote(
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
    func failImage(_ raw: String) {
        let message = Self.friendlyImageError(raw)
        updateStreamingMessage { item in
            item.streaming = false
            item.imageProgress = nil
            if item.content.isEmpty { item.content = "出错：\(message)" }
        }
        setNotice(message)
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

    func imageNote(
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
}
