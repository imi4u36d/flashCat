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
/// 思考级别与排队消息。独立成结构体并只观察 `AppState` 与 `ChatDraftStore`，
/// 流式正文增量（`chat.messages`）不会触发输入卡重排。
struct ChatComposerHost: View {
    @ObservedObject var state: AppState
    @ObservedObject var draftStore: ChatDraftStore
    let chat: ChatStore
    let isActive: Bool
    @Binding var editingMessageID: UUID?
    @Binding var composerFocused: Bool
    @Binding var showsModelPicker: Bool

    @State private var imageOptions = ImageOptionsStore.load()
    @State private var videoOptions = VideoOptionsStore.load()
    @State private var showsImageOptions = false
    /// 卡片上挂的浮层（模型选择、参数）开着期间，卡片保持打开前的聚焦外观：
    /// 浮层会把键盘焦点从输入框带走，边框、投影、留白和占位提示不该跟着闪。
    @State private var keepsFocusedLook = false
    /// 拖拽悬停在输入卡上时给出投放提示；图像/视频模型才接受文件。
    @State private var isDropTargeted = false
    /// 上下文快满的提示按会话关一次；切会话重新计算。
    @State private var contextWarningDismissed = false
    @State private var generating = false
    /// 模型列表以整张输入卡为锚点：面板贴在卡片上沿，宽度也跟着卡片。
    @State private var composerAnchor: NSView?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        composer
            .background(ModelPickerAnchorReader { composerAnchor = $0 })
            .onAppear {
                generating = chat.generating
                DispatchQueue.main.async { flushQueueIfNeeded() }
            }
            .onReceive(chat.$generating) { value in
                if generating != value { generating = value }
                // 一轮结束后把队列里的下一条接着发出去。挪到下一个循环，
                // 避免在视图更新期间再改 generating。
                if !value {
                    DispatchQueue.main.async { flushQueueIfNeeded() }
                }
            }
            .onChange(of: state.selectedModel) { _, _ in
                // 旧模型留下的能力提示（比如「不支持图片」）不能带到新模型上。
                clearDraftNotice()
                pruneIncompatibleAttachments()
            }
            .onChange(of: supportsChatImages) { _, canSeeImages in
                // 引擎刚启动时模型能力可能还没扫出来；等扫描到视觉能力后
                // 把那条误报撤掉。用户手动贴过别的内容则取决于下一句输入。
                if canSeeImages { clearDraftNotice() }
            }
            .onChange(of: imageOptions) { _, newValue in
                ImageOptionsStore.save(newValue)
            }
            .onChange(of: videoOptions) { _, newValue in
                VideoOptionsStore.save(newValue)
            }
            .onChange(of: state.currentThreadID) { _, _ in
                contextWarningDismissed = false
            }
            .onDisappear {
                ModelPickerInlinePanelController.shared.dismiss(animated: false)
            }
            .onChange(of: isActive) { _, active in
                if !active {
                    showsImageOptions = false
                    keepsFocusedLook = false
                    isDropTargeted = false
                } else {
                    // 页面切回来时，如果排队消息等的那一轮已经结束了，接着发。
                    DispatchQueue.main.async { flushQueueIfNeeded() }
                }
            }
            // 浮层收起后撤销冻结，并把光标还给输入框。
            .onChange(of: showsImageOptions) { _, shown in
                if !shown { endPopover() }
            }
    }

    // MARK: Drafts

    private var draftKey: String { state.currentThreadID }

    private var draft: String {
        get { draftStore.drafts[draftKey]?.text ?? "" }
        nonmutating set {
            var draft = draftStore.drafts[draftKey] ?? ChatDraft()
            draft.text = newValue
            // 用户一开始改字，上一次的附件回执就收起（Splash 的 `notice` 同理）。
            draft.notice = nil
            draftStore.drafts[draftKey] = draft
        }
    }

    private func setDraftNotice(_ text: String) {
        draftStore.drafts[draftKey, default: ChatDraft()].notice = text
    }

    private func clearDraftNotice() {
        guard var draft = draftStore.drafts[draftKey], draft.notice != nil else { return }
        draft.notice = nil
        draftStore.drafts[draftKey] = draft
    }

    private var imageAttachment: ChatImageAttachment? {
        get { draftStore.drafts[draftKey]?.imageAttachment }
        nonmutating set { draftStore.drafts[draftKey, default: ChatDraft()].imageAttachment = newValue }
    }

    private var lastFrameAttachment: ChatImageAttachment? {
        get { draftStore.drafts[draftKey]?.lastFrameAttachment }
        nonmutating set { draftStore.drafts[draftKey, default: ChatDraft()].lastFrameAttachment = newValue }
    }

    private var referenceImages: [ChatImageAttachment] {
        get { draftStore.drafts[draftKey]?.referenceImages ?? [] }
        nonmutating set { draftStore.drafts[draftKey, default: ChatDraft()].referenceImages = newValue }
    }

    private var referenceClips: [VideoReferenceClip] {
        get { draftStore.drafts[draftKey]?.referenceClips ?? [] }
        nonmutating set { draftStore.drafts[draftKey, default: ChatDraft()].referenceClips = newValue }
    }

    /// 生成中按回车排队的后续消息，跟草稿一起按会话隔离。
    private var queuedTexts: [String] {
        get { draftStore.drafts[draftKey]?.queuedTexts ?? [] }
        nonmutating set { draftStore.drafts[draftKey, default: ChatDraft()].queuedTexts = newValue }
    }

    /// 文本 / 视觉对话的图片与文件附件；媒体生成仍走上面的专门槽位。
    private var chatImages: [ChatImageAttachment] {
        get { draftStore.drafts[draftKey]?.chatImages ?? [] }
        nonmutating set { draftStore.drafts[draftKey, default: ChatDraft()].chatImages = newValue }
    }

    private var chatFiles: [ChatFileAttachment] {
        get { draftStore.drafts[draftKey]?.chatFiles ?? [] }
        nonmutating set { draftStore.drafts[draftKey, default: ChatDraft()].chatFiles = newValue }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { draft },
            set: { draft = $0 })
    }

    private func cancelEditing() {
        editingMessageID = nil
        draft = ""
        focusComposer()
    }

    /// 接近上下文上限时在输入卡上方提示；按会话关一次，切走再回来会重新判断。
    private var contextWarning: some View {
        Group {
            if let ratio = contextUsageRatio, ratio >= 0.8, !contextWarningDismissed {
                HStack(spacing: 8) {
                    Image(systemName: ratio >= 0.95 ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ratio >= 0.95 ? DS.warn : DS.text2)
                    Text(
                        L10n.format(
                            "上下文已用 %lld%%，再长就会顶到窗口上限。",
                            Int64((ratio * 100).rounded()))
                    )
                    .font(DS.Font.prose(11.5))
                    .foregroundStyle(DS.text2)
                    Spacer(minLength: 6)
                    Button(L10n.t("新建对话")) {
                        state.newConversation()
                    }
                    .buttonStyle(.dsGhost)
                    Button {
                        contextWarningDismissed = true
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.text3)
                    .accessibilityLabel(L10n.t("关闭通知"))
                }
                .padding(.horizontal, 2)
                .frame(height: 28)
            }
        }
    }

    private var contextUsageRatio: Double? {
        guard let ceiling = state.contextWindowCeiling, ceiling > 0 else { return nil }
        let used = state.contextUsedTokens
        guard used > 0 else { return nil }
        return min(1.5, Double(used) / Double(ceiling))
    }

    // MARK: Composer

    /// 卡片是不是显示成「正在使用」。除了输入框自己拿着焦点，卡片上的浮层
    /// 开着时也沿用打开前的样子：焦点只是临时借给了浮层，卡片不该在这一
    /// 瞬间换一套边框、投影和留白。
    private var composerActive: Bool {
        keepsFocusedLook || composerFocused
    }

    /// 浮层打开前记下卡片此刻的样子。
    private func beginPopover() {
        keepsFocusedLook = composerFocused
    }

    /// 浮层收起：打开前卡片拿着焦点的话，把光标还回输入框。浮层是卡片的
    /// 一部分，收起后就该回到点它之前的状态——和原生 popover 一样，关掉
    /// 之后还能接着写。
    private func endPopover() {
        if keepsFocusedLook { focusComposer() }
        keepsFocusedLook = false
    }

    /// 输入区固定 44pt 行高：未聚焦时不再矮一档，光标进出、附件加减都不会
    /// 让卡片跳高度。未聚焦只去掉强调色焦点环，形状和已聚焦时一致。
    var composerFieldHeight: CGFloat {
        44
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
                // 给一个关闭键：模型能力还没扫出来时误报的提示不能一直钉着。
                HStack(alignment: .top, spacing: 8) {
                    Label {
                        Text(notice).foregroundStyle(DS.text2)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                    .font(.system(size: 12))
                    .lineLimit(2)
                    Spacer(minLength: 6)
                    Button {
                        clearDraftNotice()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DS.text3)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plainHit)
                    .accessibilityLabel(L10n.t("关闭通知"))
                }
            }

            if !queuedTexts.isEmpty {
                queueStrip
            }

            if hasAttachedMedia || hasChatAttachments {
                composerAttachments
            } else if supportsVideoReferences {
                referenceHint
            }

            // 自绘输入框：回车发送、⇧回车换行，Escape 停止生成（见 `ChatComposerField`）。
            ZStack(alignment: .topLeading) {
                ChatComposerField(
                    text: textBinding,
                    isFocused: $composerFocused,
                    isEnabled: true,
                    isActive: isActive,
                    conversation: draftKey,
                    onSend: send,
                    onCancel: {
                        guard generating else { return false }
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
                    onPasteFiles: { urls in
                        attachPastedFiles(urls)
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
                if draft.isEmpty && !composerActive {
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
                // 左下角只留附件入口；文本参数收进设置页，思考级别挪到模型右侧。
                if !attachMenuItems.isEmpty {
                    ComposerAttachMenu(items: attachMenuItems)
                }

                // 图像 / 视频模型仍从底排进参数面板；文本模型的生成参数
                // 已经在设置页的「对话参数」里，不再占输入卡的位置。
                if supportsMedia {
                    ComposerIconButton(
                        systemName: supportsVideo ? "video" : "wand.and.stars",
                        help: supportsVideo ? "视频参数" : "图像参数"
                    ) {
                        beginPopover()
                        showsImageOptions = true
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
                    .disabled(generating)
                    .help("模型画图时用哪个图像模型")
                }

                Spacer(minLength: 12)

                if !supportsMedia, state.contextUsedTokens > 0 {
                    ChatContextRing(
                        used: state.contextUsedTokens,
                        ceiling: state.contextWindowCeiling)
                        .padding(.trailing, 2)
                }

                modelPickerTrigger

                if ChatComposerControls.showsThinkingLevel(for: state.activeModel) {
                    ChatThinkingControl(settings: state.settings)
                }

                sendStopButton
            }
            // 第一个控件的字形与正文左缘协调。
            .padding(.leading, -4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 10)
        .background {
            composerCardShape.fill(DS.floating)
        }
        .overlay {
            composerBorder
        }
        .shadow(
            color: DS.accent.opacity(composerActive ? 0.16 : 0),
            radius: 14,
            x: 0,
            y: 3
        )
        .shadow(
            color: DS.glassShadow.opacity(composerActive ? 1.0 : 0.78),
            radius: composerActive ? 20 : 14,
            x: 0,
            y: composerActive ? 8 : 5
        )
        .animation(reduceMotion ? nil : DS.Motion.snappy, value: composerActive)
        .contentShape(composerCardShape)
        .onTapGesture { if !showsModelPicker { focusComposer() } }
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

    private var composerCardShape: ComposerCardShape {
        ComposerCardShape(
            topRadius: showsModelPicker ? 0 : 22,
            bottomRadius: 22)
    }

    @ViewBuilder private var composerBorder: some View {
        if composerActive {
            composerCardShape.strokeBorder(DS.accent.opacity(0.52), lineWidth: 1)
        } else if showsModelPicker {
            // 展开态与列表共用一条 1px 的发丝缝。
            composerCardShape.strokeBorder(DS.line2, lineWidth: 1)
        } else {
            composerCardShape.strokeBorder(
                LinearGradient(
                    colors: [DS.glassSpecular, DS.glassBorder],
                    startPoint: .top,
                    endPoint: .bottom),
                lineWidth: 1)
        }
    }

    private var modelPickerTrigger: some View {
        ChatModelControl(
            state: state,
            chat: chat,
            isActive: isActive,
            isPickerOpen: showsModelPicker,
            onTogglePicker: toggleModelPicker)
    }

    private func toggleModelPicker() {
        ModelPickerInlinePanelController.shared.toggle(
            state: state,
            from: composerAnchor,
            onPresent: {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
                    showsModelPicker = true
                }
                // 列表接管键盘：输入框让出第一响应者，卡片换成去焦外观。
                NSApp.keyWindow?.makeFirstResponder(nil)
            },
            onDismiss: {
                withAnimation(reduceMotion ? nil : .easeIn(duration: 0.22)) {
                    showsModelPicker = false
                }
                focusComposer()
            })
    }

    /// 发送 / 停止圆钮：能发时用强调色并带轻微投影，生成中原地变成高对比停止键。
    var sendStopButton: some View {
        ComposerSendButton(
            streaming: generating,
            enabled: generating || canSend
        ) {
            if generating {
                state.cancelGeneration()
            } else {
                send()
            }
        }
    }

    /// 左下角加号里能挂的附件类型，跟当前模型的能力走。
    var attachMenuItems: [ComposerAttachMenu.Item] {
        if supportsMedia {
            if supportsVideoReferences {
                return [
                    .init(title: "参考图", systemImage: "photo.badge.plus") { pickReferenceImage() },
                    .init(title: "参考视频", systemImage: "video.badge.plus") { pickReferenceClip() },
                ]
            }
            if supportsVideo {
                return [
                    .init(title: "首帧", systemImage: "photo.badge.plus") { pickImage(for: .first) },
                    .init(title: "尾帧", systemImage: "photo.badge.plus") { pickImage(for: .last) },
                ]
            }
            return [
                .init(title: "底图", systemImage: "photo.badge.plus") { pickImage(for: nil) },
            ]
        }
        var items: [ComposerAttachMenu.Item] = []
        if supportsChatImages {
            items.append(
                .init(title: "图片", systemImage: "photo.badge.plus") { pickChatImages() })
        }
        items.append(
            .init(title: "文件", systemImage: "doc.badge.plus") { pickChatFiles() })
        return items
    }

    /// 视觉对话模型才收图片；文本模型只收能抽文字的附件。
    var supportsChatImages: Bool {
        !supportsMedia && state.activeModelSupportsVision
    }

    var supportsChatFiles: Bool { !supportsMedia }

    var hasChatAttachments: Bool {
        !chatFiles.isEmpty || !chatImages.isEmpty
    }

    /// 图片被拒时到底缺什么：Splash 的 GGUF 安装可能只是没带视觉投影
    /// （mmproj），和「模型本身不支持图片」不是一回事。
    var imageInputNotice: String {
        if state.activeEngine == .splash {
            return "这份 Splash 模型安装没有视觉投影（mmproj），当前不能读图；重新安装模型并包含视觉投影后再试。"
        }
        return "当前模型不支持图片输入，换一个视觉模型再试。"
    }

    var supportsImage: Bool { state.activeModelSupportsImage }
    var supportsVideo: Bool { state.activeModelSupportsVideo }
    var supportsVideoReferences: Bool { state.activeModelSupportsVideoReferences }
    var supportsMedia: Bool { supportsImage || supportsVideo }

    var composerPlaceholder: String {
        if supportsVideoReferences { return "描述想生成的视频内容，或拖入参考图 / 视频…" }
        if supportsVideo { return "描述想生成的视频画面，可附首帧 / 尾帧…" }
        if supportsImage { return "描述想生成的画面，或拖入底图重绘…" }
        return "问问 FlashCat"
    }

    /// 切换模型后清理不兼容的媒体附件，并收起旧模型的参数浮层。
    func pruneIncompatibleAttachments() {
        if supportsMedia {
            // 媒体生成用不到聊天附件，文件正文也没有对应的引擎输入。
            chatImages = []
            chatFiles = []
        } else if !supportsChatImages {
            // 换成不支持视觉的文本模型：图片留下也没有引擎能看。
            chatImages = []
        }
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
        guard !generating else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // REF2VA 必须至少有一个参考素材；文字可以后补，素材不能空。
        if supportsVideoReferences { return hasReferenceMedia }
        if supportsMedia { return hasText || hasAttachedMedia }
        return hasText || hasChatAttachments
    }

    /// 点输入卡的留白也把光标交给输入框；生成中也可以继续写下一句。
    func focusComposer() {
        guard isActive else { return }
        composerFocused = true
    }

    func send() {
        // 生成中再按回车：不打断当前回复，把这句话排进队列。
        if generating {
            enqueueDraftForGeneration()
            return
        }
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
        guard !text.isEmpty || hasChatAttachments else { return }
        let files = chatFiles
        let images = chatImages
        // 只挂附件不写字也可以：给一句保守的可见文案，引擎侧再补文件正文。
        let visible = text.isEmpty
            ? (files.isEmpty ? "看看这张图。" : "请阅读附件。")
            : text
        var engine = visible
        if !files.isEmpty {
            engine +=
                "\n\n" + files.map(ChatAttachmentReader.promptBlock(for:)).joined(separator: "\n\n")
        }
        let names = files.map(\.name)
        let imagePaths = images.map(\.path)
        draft = ""
        chatFiles = []
        chatImages = []
        state.send(
            engine,
            transcriptText: visible,
            attachmentNames: names,
            userImagePaths: imagePaths)
    }

    /// 生成中按回车：把当前草稿排到队尾，输入框立刻清空；等这一轮结束再发。
    /// 带附件的消息不排队，等这一轮结束再手动发，避免把媒体参数也复制一份。
    private func enqueueDraftForGeneration() {
        guard !supportsMedia, editingMessageID == nil else { return }
        if hasChatAttachments {
            setDraftNotice("生成中，带附件的消息等这一轮结束再发。")
            return
        }
        guard !state.needsEngineSetup, !state.selectedModel.isEmpty else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queuedTexts.append(text)
        draft = ""
        focusComposer()
    }

    private func removeQueued(at index: Int) {
        var queue = queuedTexts
        guard queue.indices.contains(index) else { return }
        queue.remove(at: index)
        queuedTexts = queue
    }

    /// 一轮生成结束后把队首发出去；发出去后 generating 会再次变 true，
    /// 剩下的排队消息继续等下一轮。
    func flushQueueIfNeeded() {
        // 页面不在前台时先压住，等切回来再发；否则回来的时候队列可能已经
        // 悄悄跑掉了。
        guard isActive, !generating, editingMessageID == nil else { return }
        guard !state.needsEngineSetup, !state.selectedModel.isEmpty else { return }
        var queue = queuedTexts
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        queuedTexts = queue
        state.send(next)
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

    /// 视觉对话模型的图片附件：可以一次挑多张，发送时随提问一起给模型。
    func pickChatImages() {
        guard supportsChatImages else { return }
        let panel = NSOpenPanel()
        panel.title = "选择图片"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            addChatImage(at: url)
        }
        composerFocused = true
    }

    @discardableResult
    func addChatImage(at url: URL) -> Bool {
        guard supportsChatImages else { return false }
        guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        guard chatImages.count < ChatAttachmentReader.maxImages else {
            setDraftNotice("图片最多 \(ChatAttachmentReader.maxImages) 张。")
            return false
        }
        guard !chatImages.contains(where: { $0.path == url.path }) else { return true }
        chatImages.append(
            ChatImageAttachment(
                path: url.path,
                name: url.lastPathComponent,
                pixelSize: ImageStore.pixelSize(atPath: url.path)))
        clearDraftNotice()
        return true
    }

    /// 文本 / 视觉对话的文件附件：文件内容在挂上时抽成文字，发送时并进提示词。
    func pickChatFiles() {
        guard supportsChatFiles else { return }
        let panel = NSOpenPanel()
        panel.title = "选择文件"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            addChatFile(at: url)
        }
        composerFocused = true
    }

    /// 文件 URL 究竟是不是图片：扩展名之外再看 UTI；没有扩展名的临时文件
    /// （微信 / QQ 截图常见）按内容 sniff 一次，只嗅 20 MB 以内。
    func isImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if Self.imageExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            return true
        }
        if ext.isEmpty,
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size < 20_000_000 {
            return NSImage(contentsOf: url) != nil
        }
        return false
    }

    @discardableResult
    func addChatFile(at url: URL) -> Bool {
        guard supportsChatFiles else { return false }
        if isImageURL(url) {
            if supportsChatImages {
                return addChatImage(at: url)
            }
            setDraftNotice(imageInputNotice)
            return true
        }
        let ext = url.pathExtension.lowercased()
        if Self.videoExtensions.contains(ext) {
            setDraftNotice("对话附件暂不支持视频，改用参考视频模型或先截取一段画面。")
            return true
        }
        guard chatFiles.count < ChatAttachmentReader.maxFiles else {
            setDraftNotice("文件最多 \(ChatAttachmentReader.maxFiles) 个。")
            return true
        }
        guard !chatFiles.contains(where: { $0.path == url.path }) else { return true }
        do {
            chatFiles.append(try ChatAttachmentReader.read(url))
            clearDraftNotice()
            return true
        } catch {
            setDraftNotice(error.localizedDescription)
            return false
        }
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
        let destination: (URL) -> Void
        if supportsMedia {
            destination = { attachImage(at: $0) }
        } else if supportsChatImages {
            destination = { addChatImage(at: $0) }
        } else {
            setDraftNotice(imageInputNotice)
            return true
        }
        guard let tiff = image.tiffRepresentation,
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
        destination(url)
        composerFocused = true
        return true
    }

    /// ⌘V 粘贴 Finder 里复制的文件。图片按模型能力走媒体槽位或视觉附件；
    /// 能抽出文字的文本 / PDF 挂成聊天附件，发出去时并进提示词。
    func attachPastedFiles(_ urls: [URL]) -> Bool {
        var handled = false
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if isImageURL(url) {
                if supportsMedia {
                    attachImage(at: url)
                    handled = true
                } else if supportsChatImages {
                    handled = addChatImage(at: url) || handled
                } else {
                    setDraftNotice(imageInputNotice)
                    handled = true
                }
            } else if Self.videoExtensions.contains(ext), supportsMedia {
                if supportsVideoReferences { attachReferenceClip(at: url) }
                handled = true
            } else if supportsChatFiles, addChatFile(at: url) {
                handled = true
            }
        }
        if handled { composerFocused = true }
        return handled
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

    /// 生成中排队的后续消息：一行一条，等这一轮结束自动发。
    var queueStrip: some View {
        VStack(spacing: 6) {
            ForEach(Array(queuedTexts.enumerated()), id: \.offset) { index, text in
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DS.text3)
                    Text(L10n.t("排队中"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DS.text3)
                    Circle()
                        .fill(DS.text4)
                        .frame(width: 2, height: 2)
                    Text(text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DS.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Button {
                        removeQueued(at: index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DS.text3)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plainHit)
                    .help(L10n.t("取消这条排队消息"))
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(DS.rect(8).fill(DS.bg))
            }
        }
    }

    /// 附件统一成一行 chip：底图 / 首尾帧 / 参考图 / 参考视频 / 对话图片与文件
    /// 都走同一种形状。
    var composerAttachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if supportsMedia {
                    mediaAttachmentChips
                } else {
                    chatAttachmentChips
                }
            }
            .padding(.vertical, 2)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    var mediaAttachmentChips: some View {
        if supportsVideoReferences {
            ForEach(referenceImages) { attachment in
                attachmentChip(
                    attachment,
                    role: L10n.t("参考图"),
                    remove: { referenceImages.removeAll { $0.id == attachment.id } })
            }
            ForEach(referenceClips) { clip in
                referenceClipChip(clip)
            }
        } else {
            if let imageAttachment {
                attachmentChip(
                    imageAttachment,
                    role: L10n.t(supportsVideo ? "首帧" : "底图"),
                    remove: { self.imageAttachment = nil })
            }
            if supportsVideo, let lastFrameAttachment {
                attachmentChip(
                    lastFrameAttachment,
                    role: L10n.t("尾帧"),
                    remove: { self.lastFrameAttachment = nil })
            }
        }
    }

    @ViewBuilder
    var chatAttachmentChips: some View {
        ForEach(chatImages) { attachment in
            attachmentChip(
                attachment,
                role: L10n.t("图片"),
                remove: { chatImages.removeAll { $0.id == attachment.id } })
        }
        ForEach(chatFiles) { file in
            ComposerAttachmentChip(
                title: file.name,
                meta: file.metaText,
                remove: { chatFiles.removeAll { $0.id == file.id } }
            ) {
                Image(systemName: file.kindLabel == "PDF" ? "doc.richtext" : "doc.text")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.text3)
            }
        }
    }

    var referenceHint: some View {
        Text("REF2VA 从参考素材生成新视频：从加号添加至少一张参考图或一段参考视频。")
            .font(.system(size: 9.5))
            .foregroundStyle(DS.text3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .padding(.bottom, 6)
    }

    func attachmentChip(
        _ attachment: ChatImageAttachment,
        role: String,
        remove: @escaping () -> Void
    ) -> some View {
        ComposerAttachmentChip(
            title: attachment.name,
            meta: attachmentMeta(role: role, size: attachment.pixelSize),
            remove: remove
        ) {
            AsyncChatThumbnail(path: attachment.path, maxPixel: 96) {
                DS.bg
            } missingView: {
                Image(systemName: "photo")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.text3)
            }
        }
    }

    func referenceClipChip(_ clip: VideoReferenceClip) -> some View {
        ComposerAttachmentChip(
            title: clip.name,
            meta: clipMeta(clip),
            remove: { referenceClips.removeAll { $0.id == clip.id } }
        ) {
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
        }
    }

    func attachmentMeta(role: String, size: CGSize?) -> String {
        guard let size, size.width > 0, size.height > 0 else { return role }
        return "\(role) · \(Int(size.width))×\(Int(size.height))"
    }

    func clipMeta(_ clip: VideoReferenceClip) -> String {
        var parts = [L10n.t("参考视频")]
        if let duration = clip.duration { parts.append(String(format: "%.1f 秒", duration)) }
        if let size = clip.pixelSize, size.width > 0, size.height > 0 {
            parts.append("\(Int(size.width))×\(Int(size.height))")
        }
        return parts.joined(separator: " · ")
    }

    /// 只接受图片扩展名：拖进来的可能是一整个文件夹或 PDF。
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "tif", "tiff", "bmp", "gif",
    ]

    /// 参考视频的拖拽入口。真正能不能解由 AVFoundation 读头决定。
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mpeg",
    ]

}

/// 输入卡的外形：展开模型列表时顶边拉直，和列表拼成一张卡。
private struct ComposerCardShape: InsettableShape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var inset: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        return UnevenRoundedRectangle(
            topLeadingRadius: max(0, topRadius - inset),
            bottomLeadingRadius: max(0, bottomRadius - inset),
            bottomTrailingRadius: max(0, bottomRadius - inset),
            topTrailingRadius: max(0, topRadius - inset),
            style: .continuous
        ).path(in: box)
    }

    func inset(by amount: CGFloat) -> ComposerCardShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}
