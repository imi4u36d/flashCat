// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AVKit
import AppKit
import FlashCatCore
import FlashCatKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 输入卡与它的即时状态：草稿绑定、附件粘贴 / 选择、参考素材、发送与停止、
/// 图像 / 视频参数入口。单独成文件是因为这一段有近九百行，和转录区的生命周期
/// 没有关系；`ChatPage` 本体只负责版式与把两块拼起来。
extension ChatPage {
    // MARK: Composer

    /// 未聚焦且草稿为空时只留一行高度；光标进来或已有内容才长到可写多行。
    /// 卡片因此是「安静时矮、要写字时高」，而不是一直占着一块空白。
    var composerFieldHeight: CGFloat {
        if composerFocused || !draft.isEmpty || hasAttachedMedia { return 40 }
        return 22
    }

    var editBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .font(.system(size: 10.5, weight: .semibold))
            Text(L10n.t("正在编辑这条消息，发送后重跑这一轮"))
                .font(DS.Font.prose(11.5))
            Spacer(minLength: 6)
            Button(L10n.t("取消")) { cancelEditing() }
                .buttonStyle(.dsGhost)
                .font(DS.Font.prose(11.5, weight: .medium))
        }
        .foregroundStyle(DS.text2)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(DS.rect(DS.Radius.sm).fill(DS.hover))
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editingMessageID != nil {
                editBanner
            }
            contextWarning

            if let notice = draftStore.drafts[draftKey]?.notice, !notice.isEmpty {
                // 和 Splash 的回执一样：警告图标 + 一句说明，压在输入文字上方。
                Label {
                    Text(notice).foregroundStyle(DS.text2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                .font(.system(size: 12))
                .lineLimit(2)
            }

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

            // 自绘输入框：回车发送、⇧回车换行，Escape 停止生成（见 `ChatComposerField`）。
            ZStack(alignment: .topLeading) {
                ChatComposerField(
                    text: textBinding,
                    isFocused: $composerFocused,
                    isEnabled: true,
                    conversation: draftKey,
                    onSend: send,
                    onCancel: {
                        guard chat.generating else { return false }
                        state.cancelGeneration()
                        return true
                    },
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
                    onPasteImage: { image in
                        attachPastedImage(image)
                    },
                    onDragTargetChange: { targeted in
                        withAnimation(reduceMotion ? nil : Motion.quick) {
                            isDropTargeted = targeted && supportsMedia
                        }
                    },
                    acceptsImageDrop: supportsMedia,
                    acceptsVideoDrop: supportsVideoReferences
                )
                // 光标进来就收起占位提示：聚焦后留着会和插入点抢位置，看起来像
                // 输入框里一直有字。清空草稿但还停在输入框里时同样不再显示。
                if draft.isEmpty && !composerFocused {
                    Text(L10n.t(composerPlaceholder))
                        .font(DS.Font.prose(ChatComposerField.fontSize))
                        .foregroundStyle(DS.text4)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: composerFieldHeight, alignment: .topLeading)
            .animation(reduceMotion ? nil : Motion.quick, value: composerFieldHeight)

            HStack(spacing: 4) {
                // 图像模型没有采样参数：同一个按钮换成图像设置，别再弹文本模型的
                // 温度/系统提示面板。
                ComposerIconButton(
                    systemName: supportsVideo
                        ? "video"
                        : (supportsImage ? "wand.and.stars" : "slider.horizontal.3"),
                    help: supportsVideo ? "视频参数" : (supportsImage ? "图像参数" : "生成参数")
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
                    ComposerIconButton(
                        systemName: state.imageToolEnabled
                            ? "paintbrush.pointed.fill" : "paintbrush.pointed",
                        help: state.imageToolEnabled
                            ? "模型可以直接画图（点一下关掉）"
                            : "打开后模型可以在这轮对话里直接画图",
                        active: state.imageToolEnabled
                    ) {
                        state.imageToolEnabled.toggle()
                    }
                }

                // 画图工具单独留一个模型选择器，只在「画」开着时出现。
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
                    ComposerIconButton(
                        systemName: "photo.badge.plus",
                        help: supportsVideoReferences
                            ? "添加参考图（最多 9 张）"
                            : (supportsVideo ? "添加首帧或尾帧" : "附上一张图片作重绘底图"),
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
                    ComposerIconButton(
                        systemName: "video.badge.plus",
                        help: "添加参考视频（最多 3 段，每段至少 5 帧）",
                        active: !referenceClips.isEmpty
                    ) {
                        pickReferenceClip()
                    }
                }

                ChatModelControl(state: state, chat: chat)

                Spacer(minLength: 12)

                if !supportsMedia {
                    ChatContextRing(
                        used: state.contextUsedTokens,
                        ceiling: state.contextWindowCeiling)
                }

                sendStopButton
            }
            // 第一个控件的字形与正文左缘对齐。
            .padding(.leading, -6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            DS.rect(22)
                .fill(colorScheme == .dark ? DS.raised : DS.surface)
        }
        .overlay {
            DS.rect(22).strokeBorder(DS.line, lineWidth: 1)
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.06),
            radius: 14, y: 4
        )
        .contentShape(DS.rect(22))
        .onTapGesture { focusComposer() }
        .overlay {
            if isDropTargeted {
                DS.rect(22)
                    .strokeBorder(DS.accent.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(DS.rect(22).fill(DS.accentSoft))
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
    }

    /// Splash 的发送键：一个实心圆，能发时用强调色，不能发时退成灰底；
    /// 生成中原地变成停止键。
    var sendStopButton: some View {
        let streaming = chat.generating
        let enabled = streaming || canSend
        return Button {
            if streaming {
                state.cancelGeneration()
            } else {
                send()
            }
        } label: {
            Image(systemName: streaming ? "stop.fill" : "arrow.up")
                .font(
                    .system(
                        size: streaming ? 9.5 : 12.5,
                        weight: streaming ? .bold : .semibold)
                )
                .foregroundStyle(enabled ? Color.white : DS.text3)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(enabled ? DS.accent : DS.hover)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plainHit)
        .disabled(!enabled)
        .help(streaming ? "停止生成 (Esc)" : "发送（回车）· ⇧回车换行")
        .accessibilityLabel(streaming ? L10n.t("停止生成") : L10n.t("发送"))
    }

    var supportsImage: Bool { state.activeModelSupportsImage }
    var supportsVideo: Bool { state.activeModelSupportsVideo }
    var supportsVideoReferences: Bool { state.activeModelSupportsVideoReferences }
    var supportsMedia: Bool { supportsImage || supportsVideo }

    var composerPlaceholder: String {
        if supportsVideoReferences { return "描述想生成的视频内容，或拖入参考图 / 视频…" }
        if supportsVideo { return "描述想生成的视频画面，可附首帧 / 尾帧…" }
        if supportsImage { return "描述想生成的画面，或拖入底图重绘…" }
        return "给 FlashCat 发消息"
    }

    /// 切换模型后清理不兼容的媒体附件，并收起旧模型的参数浮层。
    func pruneIncompatibleAttachments() {
        if !supportsMedia {
            imageAttachment = nil
            lastFrameAttachment = nil
            referenceImages = []
            referenceClips = []
            showsImageOptions = false
        } else if supportsImage && !supportsVideo {
            lastFrameAttachment = nil
            referenceImages = []
            referenceClips = []
        } else if supportsVideo && !supportsVideoReferences {
            referenceImages = []
            referenceClips = []
        } else if supportsVideoReferences {
            imageAttachment = nil
            lastFrameAttachment = nil
        }
    }

    /// REF2VA 的参考素材是否已经挂上至少一个。
    var hasReferenceMedia: Bool {
        !referenceImages.isEmpty || !referenceClips.isEmpty
    }

    /// 有没有挂上要跟这一轮一起发出去的素材：图像看底图，REF2VA 看参考素材，
    /// 普通视频模型看首帧或尾帧。
    var hasAttachedMedia: Bool {
        if supportsVideoReferences { return hasReferenceMedia }
        return imageAttachment != nil || (supportsVideo && lastFrameAttachment != nil)
    }

    var canSend: Bool {
        guard !chat.generating else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // REF2VA 必须至少有一个参考素材；文字可以后补，素材不能空。
        if supportsVideoReferences { return hasReferenceMedia }
        if supportsMedia { return hasText || hasAttachedMedia }
        return hasText
    }

    /// 点输入卡的留白也把光标交给输入框；生成中也可以继续写下一句。
    func focusComposer() {
        composerFocused = true
    }

    func send() {
        guard !chat.generating else { return }
        guard !state.needsEngineSetup else {
            setDraftNotice(L10n.t("还没有安装推理引擎，请先在启动页选择一个"))
            return
        }
        guard !state.selectedModel.isEmpty else {
            setDraftNotice(L10n.t("还没有选择模型"))
            return
        }
        // 编辑模式：发送键改为「保存并重发」，由 runner 截断后续回答再跑一轮。
        if let messageID = editingMessageID {
            let edited = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !edited.isEmpty else { return }
            draft = ""
            editingMessageID = nil
            state.editAndResend(messageID: messageID, text: edited)
            return
        }
        draftStore.drafts[draftKey]?.notice = nil
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if supportsVideo {
            // 只给首帧或尾帧也可以：引擎要求 prompt 非空，给它一句保守的运动描述。
            guard !text.isEmpty || hasAttachedMedia else { return }
            if supportsVideoReferences {
                // REF2VA 从参考素材生成新视频，不接受首尾帧；至少一个 ref 才能发。
                guard hasReferenceMedia else {
                    setDraftNotice("REF2VA 需要至少一张参考图或一段参考视频。")
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
    var lastImageSeed: Int? {
        chat.messages.last(where: { $0.imageSeed != nil })?.imageSeed
    }

    func pickImage(for slot: VideoFrameSlot?) {
        let panel = NSOpenPanel()
        panel.title = slot.map { "选择视频\($0.rawValue)" } ?? "选择一张图片"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attachImage(at: url, slot: slot)
    }

    /// REF2VA 的参考图一次可以挑多张；上限按服务端的 9 图 / 3 视频 / 12 总数。
    func pickReferenceImage() {
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

    func attachReferenceImage(at url: URL) {
        guard supportsVideoReferences else { return }
        guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return }
        guard referenceImages.count < 9 else {
            setDraftNotice("参考图最多 9 张。")
            return
        }
        guard referenceImages.count + referenceClips.count < 12 else {
            setDraftNotice("参考素材最多 12 个（9 张图 + 3 段视频）。")
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
    func pickReferenceClip() {
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

    /// 面板与拖拽共用。读头失败或超出上限都写在输入卡上方，不打断当前输入。
    func addReferenceClip(_ url: URL) {
        guard supportsVideoReferences else { return }
        guard Self.videoExtensions.contains(url.pathExtension.lowercased()) else { return }
        Task {
            do {
                let meta = try await VideoReferenceExtractor.metadata(url: url)
                guard supportsVideoReferences else { return }
                guard !referenceClips.contains(where: { $0.path == url.path }) else { return }
                guard referenceClips.count < 3 else {
                    setDraftNotice("参考视频最多 3 段。")
                    return
                }
                guard referenceImages.count + referenceClips.count < 12 else {
                    setDraftNotice("参考素材最多 12 个（9 张图 + 3 段视频）。")
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
                setDraftNotice(error.localizedDescription)
            }
        }
    }

    /// 拖拽入口要同步返回能不能接；真正的读头交给 `addReferenceClip`。
    @discardableResult
    func attachReferenceClip(at url: URL) -> Bool {
        guard supportsVideoReferences,
            Self.videoExtensions.contains(url.pathExtension.lowercased())
        else { return false }
        guard referenceClips.count < 3 else {
            setDraftNotice("参考视频最多 3 段。")
            return false
        }
        addReferenceClip(url)
        return true
    }

    /// Finder 拖入与面板选择共用一条入口：记路径、名字和像素尺寸，
    /// 发送时才把文件拷进作品目录。
    /// ⌘V 粘贴剪贴板图片：落成文件后走和拖拽相同的附件路径。临时文件放在
    /// 支持目录而不是系统 temp，发送前不会因为系统清理而丢。
    func attachPastedImage(_ image: NSImage) -> Bool {
        guard supportsMedia,
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return false }
        let directory = Paths.supportDirectory + "/pasted-images"
        Paths.ensureDirectory(directory)
        let url = URL(fileURLWithPath: directory)
            .appendingPathComponent("paste-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
        } catch {
            return false
        }
        attachImage(at: url)
        composerFocused = true
        return true
    }

    func attachImage(at url: URL, slot: VideoFrameSlot? = nil) {
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
    enum VideoFrameSlot: String {
        case first = "首帧"
        case last = "尾帧"
    }

    var videoFramesStrip: some View {
        HStack(spacing: 8) {
            videoFrameSlot(.first, attachment: imageAttachment)
            videoFrameSlot(.last, attachment: lastFrameAttachment)
        }
    }

    func videoFrameSlot(
        _ slot: VideoFrameSlot,
        attachment: ChatImageAttachment?
    ) -> some View {
        HStack(spacing: 7) {
            Button {
                pickImage(for: slot)
            } label: {
                Group {
                    if let attachment {
                        AsyncChatThumbnail(path: attachment.path, maxPixel: 96) {
                            Color.clear
                        } missingView: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DS.text3)
                        }
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
            .help(L10n.format("选择视频%@", L10n.t(slot.rawValue)))

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t(slot.rawValue))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(DS.text2)
                Text(attachment?.name ?? L10n.t("点击选择"))
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
    var referenceInputStrip: some View {
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
    }

    func referenceAddButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.ds(.secondary, size: .small))
    }

    func referenceImageTile(_ attachment: ChatImageAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            AsyncChatThumbnail(path: attachment.path, maxPixel: 96) {
                DS.bg
            } missingView: {
                Image(systemName: "photo")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.text3)
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
            .help(L10n.t("移除参考图"))
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
        .help(attachment.name)
    }

    func referenceClipTile(_ clip: VideoReferenceClip) -> some View {
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

    func attachmentStrip(_ attachment: ChatImageAttachment) -> some View {
        HStack(spacing: 10) {
            AsyncChatThumbnail(path: attachment.path, maxPixel: 96) {
                DS.bg
            } missingView: {
                Image(systemName: "photo")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.text3)
            }
            .frame(width: 46, height: 46)
            .background(DS.bg)
            .clipShape(DS.rect(DS.Radius.sm))
            .overlay {
                DS.rect(DS.Radius.sm).strokeBorder(DS.line, lineWidth: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .font(DS.Font.xs.weight(.medium))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                Text(L10n.format("重绘 · 强度 %lld%%", Int64((imageOptions.strength * 100).rounded())))
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
            .help(L10n.t("移除底图"))
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
    }
}
