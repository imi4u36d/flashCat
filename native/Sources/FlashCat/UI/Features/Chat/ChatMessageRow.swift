// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AVKit
import AppKit
import FlashCatCore
import FlashCatKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Message row

/// 一条消息：用户消息是右侧淡色气泡，助手消息直接铺在画布上——上方是思考行，
/// 中间是 Markdown / 图片 / 视频，下面悬停时浮出复制与重新生成。版式对齐
/// Splash 的 `transcript.js`。
struct MessageRow: View, Equatable {
    let message: ChatMessage
    let modelName: String
    let startupStage: String?
    /// 用户气泡最宽。列宽被拖开时父视图会传更大的值。
    let maxBubbleWidth: CGFloat
    let isLast: Bool
    let canRegenerate: Bool
    let onEdit: () -> Void
    let onBranch: () -> Void
    let onRegenerate: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// nil = 跟随状态：思考流式输出、正文还没开始时自动展开；true/false = 用户手动开关。
    @State private var manualThinking: Bool?
    @State private var hoveringRow = false
    @State private var hoveringToggle = false
    @State private var copied = false
    @State private var seedCopied = false
    /// 等待行在开始后 0.5 秒才出现，快速回答不会闪一下「读取提示词」。
    @State private var waitingLineVisible = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var seedResetTask: Task<Void, Never>?

    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.modelName == rhs.modelName
            && lhs.startupStage == rhs.startupStage
            && lhs.maxBubbleWidth == rhs.maxBubbleWidth
            && lhs.isLast == rhs.isLast
            && lhs.canRegenerate == rhs.canRegenerate
    }

    private var isUser: Bool { message.role == "user" }
    private var reasoning: String { message.reasoning ?? "" }
    private var contentEmpty: Bool { message.content.isEmpty }
    private var waiting: Bool { message.streaming && contentEmpty && reasoning.isEmpty }

    private var isThinkingOpen: Bool {
        manualThinking ?? (message.streaming && contentEmpty && !reasoning.isEmpty)
    }

    private var mediaWaiting: Bool {
        message.imageProgress?.isEmpty == false
            || message.videoProgress?.isEmpty == false
            || message.toolStage?.isEmpty == false
    }

    private var showsThinkingLine: Bool {
        if message.streaming && contentEmpty {
            if !reasoning.isEmpty { return true }
            // 图像 / 视频 / 工具进度已经有自己的阶段行，别再叠一句「读取提示词」。
            if mediaWaiting { return false }
            return waitingLineVisible || startupStage?.isEmpty == false
        }
        return !reasoning.isEmpty
    }

    private var showsActions: Bool {
        // 最后一轮常显（流式期间也显示）：复制是最高频动作，不该等鼠标悬停；
        // 更早的消息仍然悬停才浮出，免得整页挂满操作行。
        hoveringRow || isLast
    }

    private var waitingKey: String {
        "\(message.streaming)-\(contentEmpty)-\(reasoning.isEmpty)-\(startupStage ?? "")"
    }

    var body: some View {
        Group {
            if isUser {
                userBody
            } else {
                assistantBody
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onHover { value in
            withAnimation(reduceMotion ? nil : Motion.quick) { hoveringRow = value }
        }
        .task(id: waitingKey) {
            guard waiting else {
                waitingLineVisible = true
                return
            }
            waitingLineVisible = false
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, waiting else { return }
            withAnimation(reduceMotion ? nil : Motion.quick) { waitingLineVisible = true }
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
            seedResetTask?.cancel()
            seedResetTask = nil
        }
    }

    // MARK: User

    private var userBubbleFill: Color {
        DS.accent.opacity(colorScheme == .dark ? 0.17 : 0.12)
    }

    private var userBody: some View {
        VStack(alignment: .trailing, spacing: 8) {
            userAttachments

            if !message.content.isEmpty {
                Text(message.content)
                    .font(DS.Font.prose(15))
                    .lineSpacing(3)
                    .foregroundStyle(DS.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8.5)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(userBubbleFill))
            }

            if !message.streaming {
                userActionsRow
                    .opacity(hoveringRow || isLast ? 1 : 0)
                    .allowsHitTesting(hoveringRow || isLast)
                    .animation(reduceMotion ? nil : Motion.quick, value: hoveringRow)
            }
        }
        .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var userActionsRow: some View {
        HStack(spacing: 2) {
            MessageActionButton(
                systemName: copied ? "checkmark" : "doc.on.doc",
                help: copied ? L10n.t("已复制") : L10n.t("复制问题"),
                tint: copied ? DS.accent : DS.text2,
                action: copyMessage)
            MessageActionButton(
                systemName: "pencil",
                help: L10n.t("编辑并重发"),
                action: onEdit)
            MessageActionButton(
                systemName: "arrow.triangle.branch",
                help: L10n.t("从这里分支"),
                action: onBranch)
        }
        .frame(height: 20)
    }

    @ViewBuilder private var userAttachments: some View {
        if hasReferences {
            referenceMessageStrip
        } else if let path = message.imagePath {
            if let last = message.videoLastFramePath {
                HStack(alignment: .top, spacing: 8) {
                    labeledThumb(path: path, label: L10n.t("首帧"), maxWidth: 120)
                    labeledThumb(path: last, label: L10n.t("尾帧"), maxWidth: 120)
                }
            } else {
                imageThumb(path: path, maxWidth: 120)
            }
        } else if let last = message.videoLastFramePath {
            labeledThumb(path: last, label: L10n.t("尾帧"), maxWidth: 120)
        }
    }

    // MARK: Assistant

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsThinkingLine {
                thinkingLine
            }

            messageBody

            if hasMediaNotes {
                mediaNotes
            }

            if !isUser, !message.streaming, showsActions || isLast {
                actionsRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var messageBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            let series =
                message.imagePaths.isEmpty
                ? (message.imagePath.map { [$0] } ?? [])
                : message.imagePaths
            if !series.isEmpty {
                imageSeries(series)
            }
            if let path = message.videoPath {
                VideoBubble(path: path)
            }

            if message.content.isEmpty {
                if message.interrupted {
                    stoppedLine
                } else if message.streaming {
                    if let stage = message.toolStage, !stage.isEmpty {
                        progressLine(stage)
                    } else if let progress = message.imageProgress, !progress.isEmpty {
                        progressLine(progress)
                    } else if let progress = message.videoProgress, !progress.isEmpty {
                        progressLine(progress)
                    }
                }
            } else {
                StreamingMarkdownView(
                    text: message.content,
                    streaming: message.streaming,
                    fillsWidth: true,
                    style: .chat)
            }
        }
    }

    private var stoppedLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "stop.circle")
                .font(.system(size: 11))
            Text(L10n.t("已停止生成"))
                .font(.system(size: 12))
        }
        .foregroundStyle(DS.text3)
    }

    private func progressLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(L10n.t(text))
                .font(.system(size: 12))
                .foregroundStyle(DS.text3)
                .lineLimit(1)
        }
    }

    // MARK: Thinking line

    private var thinkingVerb: String {
        if message.streaming && contentEmpty {
            if !reasoning.isEmpty { return L10n.t("思考中") }
            if startupStage?.isEmpty == false { return L10n.t("加载模型") }
            return L10n.t("读取提示词")
        }
        return L10n.t("思考")
    }

    private var finishedThinkingFacts: String? {
        var parts: [String] = []
        if let tokens = message.usage?.reasoningTokens, tokens > 0 {
            parts.append(L10n.format("%@ tokens", Format.tokens(tokens)))
        }
        if let seconds = message.thinkingSeconds, seconds > 0 {
            parts.append(String(format: "%.1f 秒", seconds))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var thinkingLine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !reasoning.isEmpty else { return }
                withAnimation(reduceMotion ? nil : Motion.settle) {
                    manualThinking = !isThinkingOpen
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(isThinkingOpen ? 90 : 0))
                        .opacity(reasoning.isEmpty ? 0 : 1)
                        .frame(width: 10)

                    Text(thinkingVerb)

                    if message.streaming {
                        ElapsedThinkingSeconds(since: message.createdAt ?? Date())
                    } else if let facts = finishedThinkingFacts {
                        Text("·").foregroundStyle(DS.text3)
                        Text(facts).foregroundStyle(DS.text3)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(DS.text2)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    DS.rect(7).fill(
                        hoveringToggle && !reasoning.isEmpty ? DS.hover : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)
            .onHover { value in
                withAnimation(reduceMotion ? nil : Motion.quick) { hoveringToggle = value }
            }
            .disabled(reasoning.isEmpty)
            .help(reasoning.isEmpty ? "" : (isThinkingOpen ? L10n.t("收起思考") : L10n.t("展开思考")))
            .accessibilityLabel(thinkingVerb)
            .accessibilityValue(isThinkingOpen ? L10n.t("已展开") : L10n.t("已收起"))

            if isThinkingOpen, !reasoning.isEmpty {
                reasoningBlock
                    .transition(.opacity)
            }
        }
        .padding(.leading, -6)
        .animation(reduceMotion ? nil : Motion.settle, value: isThinkingOpen)
    }

    private var reasoningBlock: some View {
        // 模型还在想、读者也没手动打开时，只显示最新几行并淡出顶部；一旦开始
        // 回答或读者点开，就展开全文（Splash 的 `.latest` / `.thought`）。
        let latest = message.streaming && contentEmpty && manualThinking == nil
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(DS.text3.opacity(0.45))
                .frame(width: 2)

            PacedText(
                text: reasoning,
                streaming: message.streaming,
                tail: latest
            )
            .font(.system(size: 13))
            .lineSpacing(3)
            .foregroundStyle(DS.text2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: latest ? 96 : nil, alignment: .bottom)
            .clipped()
            .mask {
                if latest {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75), .black],
                        startPoint: .top, endPoint: .bottom)
                } else {
                    Rectangle()
                }
            }
        }
        .padding(.leading, 14)
        .padding(.top, 8)
    }

    // MARK: Actions

    private var detailsText: String {
        var parts: [String] = []
        if !modelName.isEmpty { parts.append(modelName) }
        if let rate = message.rateText { parts.append(rate) }
        if message.tokenCount > 0 { parts.append("\(message.tokenCount) tokens") }
        if let ttft = message.firstTokenSeconds, ttft > 0 {
            parts.append(L10n.format("首字 %.0f ms", ttft * 1000))
        }
        if message.interrupted { parts.append(L10n.t("已停止")) }
        return parts.joined(separator: " · ")
    }

    private var actionsRow: some View {
        HStack(spacing: 2) {
            if !message.content.isEmpty {
                MessageActionButton(
                    systemName: copied ? "checkmark" : "doc.on.doc",
                    help: copied ? L10n.t("已复制") : L10n.t("复制回答"),
                    tint: copied ? DS.accent : DS.text2,
                    action: copyMessage)
            }

            if isLast, canRegenerate {
                MessageActionButton(
                    systemName: "arrow.clockwise",
                    help: L10n.t("重新生成这轮回答"),
                    tint: DS.text2,
                    action: onRegenerate)
            }

            if !detailsText.isEmpty {
                Text(detailsText)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.text3)
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.leading, 6)
            }

            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .opacity(showsActions ? 1 : 0)
        .allowsHitTesting(showsActions)
        .animation(reduceMotion ? nil : Motion.quick, value: showsActions)
    }

    // MARK: Media

    private var hasMediaNotes: Bool {
        message.imageNote?.isEmpty == false
            || message.videoNote?.isEmpty == false
            || message.imageSeed != nil
    }

    private var mediaNotes: some View {
        HStack(spacing: 10) {
            if let note = message.imageNote, !note.isEmpty {
                Text(note)
            }
            if let seed = message.imageSeed {
                seedBadge(seed)
            }
            if let note = message.videoNote, !note.isEmpty {
                Text(note)
            }
        }
        .font(DS.Font.proseNumber(11.5))
        .foregroundStyle(DS.text3)
        .lineLimit(1)
    }

    /// 一次工具调用画出的整组图：横排缩略图，单张仍按大图显示。
    @ViewBuilder private func imageSeries(_ paths: [String]) -> some View {
        if paths.count == 1 {
            imageBubble(path: paths[0])
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                        imageBubble(path: path, maxWidth: 240, maxHeight: 240)
                            .overlay(alignment: .topLeading) {
                                Text("\(index + 1)")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(.black.opacity(0.42), in: Capsule())
                                    .padding(6)
                            }
                    }
                }
            }
        }
    }

    /// 助手出的图：点开用「预览」，右键可存到访达或复制。
    @ViewBuilder
    private func imageBubble(
        path: String,
        maxWidth: CGFloat = 420,
        maxHeight: CGFloat = 420
    ) -> some View {
        if MediaFiles.exists(path) {
            AsyncChatThumbnail(
                path: path,
                maxPixel: maxWidth * 2,
                contentMode: .fit
            ) {
                DS.rect(DS.Radius.lg)
                    .fill(DS.bg)
                    .frame(width: min(maxWidth, 240), height: min(maxHeight, 180))
                    .overlay(ProgressView().controlSize(.small))
            } missingView: {
                Text(L10n.format("图片已被移除：%@", path))
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.text3)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            .clipShape(DS.rect(DS.Radius.lg))
            .overlay {
                DS.rect(DS.Radius.lg)
                    .strokeBorder(DS.line, lineWidth: 1)
            }
            .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            .help(L10n.t("点击用「预览」打开"))
            .contextMenu {
                Button(L10n.t("在访达中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Button(L10n.t("复制图像")) { copyImage(path: path) }
            }
        } else {
            Text(L10n.format("图片已被移除：%@", path))
                .font(.system(size: 10.5))
                .foregroundStyle(DS.text3)
                .textSelection(.enabled)
        }
    }

    /// 用户提问里附的图：和 Splash 一样 120pt 见方、圆角 12、内侧一圈发丝线。
    @ViewBuilder
    private func imageThumb(path: String, maxWidth: CGFloat) -> some View {
        if MediaFiles.exists(path) {
            AsyncChatThumbnail(
                path: path,
                maxPixel: maxWidth * 2,
                contentMode: .fill
            ) {
                DS.rect(DS.Radius.xl)
                    .fill(DS.bg)
                    .frame(width: maxWidth, height: maxWidth)
            } missingView: {
                EmptyView()
            }
            .frame(width: maxWidth, height: maxWidth)
            .clipShape(DS.rect(DS.Radius.xl))
            .overlay {
                DS.rect(DS.Radius.xl)
                    .strokeBorder(DS.line, lineWidth: 1)
            }
        }
    }

    /// 首尾帧缩略图下面跟一行小字说明，避免两张图并排时分不清先后。
    private func labeledThumb(path: String, label: String, maxWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            imageThumb(path: path, maxWidth: maxWidth)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(DS.text3)
        }
    }

    private var referenceImagePaths: [String] { message.videoReferenceImagePaths ?? [] }
    private var referenceClipPaths: [String] { message.videoReferenceClipPaths ?? [] }
    private var hasReferences: Bool {
        !referenceImagePaths.isEmpty || !referenceClipPaths.isEmpty
    }

    /// 参考素材留在提问里：图片给缩略图，视频给带编号的占位卡（原片可能很大，
    /// 不复制进作品目录，历史里只记路径）。
    private var referenceMessageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(referenceImagePaths.enumerated()), id: \.offset) { item in
                    labeledThumb(
                        path: item.element,
                        label: L10n.format("参考图 %lld", Int64(item.offset + 1)),
                        maxWidth: 120)
                }
                ForEach(Array(referenceClipPaths.enumerated()), id: \.offset) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        ZStack {
                            DS.rect(DS.Radius.xl)
                                .fill(DS.bg)
                            Image(systemName: "film")
                                .font(.system(size: 18))
                                .foregroundStyle(DS.text3)
                        }
                        .frame(width: 120, height: 68)
                        .overlay {
                            DS.rect(DS.Radius.xl)
                                .strokeBorder(DS.line, lineWidth: 1)
                        }
                        Text(L10n.format("参考视频 %lld", Int64(item.offset + 1)))
                            .font(.system(size: 9))
                            .foregroundStyle(DS.text3)
                    }
                    .help((item.element as NSString).lastPathComponent)
                }
            }
        }
        .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
    }

    private func copyImage(path: String) {
        guard let image = NSImage(contentsOfFile: path) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// 图注里的 seed：点一下复制整数值，短暂变成「已复制」。
    private func seedBadge(_ seed: Int) -> some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(String(seed), forType: .string)
            seedResetTask?.cancel()
            withAnimation(reduceMotion ? nil : Motion.quick) { seedCopied = true }
            seedResetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : Motion.quick) { seedCopied = false }
            }
        } label: {
            Text(verbatim: seedCopied ? L10n.t("已复制") : "seed " + String(seed))
                .font(DS.Font.mono(10.5))
                .foregroundStyle(seedCopied ? DS.accent : DS.text2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(DS.rect(DS.Radius.sm).fill(DS.raised))
                .overlay(DS.rect(DS.Radius.sm).strokeBorder(DS.line, lineWidth: 1))
                .contentShape(DS.rect(DS.Radius.sm))
        }
        .buttonStyle(.plainHit)
        .help(L10n.t("点击复制 seed"))
        .animation(reduceMotion ? nil : Motion.quick, value: seedCopied)
    }

    /// 复制成功只让按钮短暂变成对号，不弹通知，避免打断连续选取与复制。
    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        copyResetTask?.cancel()
        withAnimation(reduceMotion ? nil : Motion.quick) { copied = true }
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : Motion.quick) { copied = false }
        }
    }
}

/// 回复操作行里的小按钮：无边框，悬停浮出底色。
struct MessageActionButton: View {
    let systemName: String
    let help: String
    var tint: Color = DS.text2
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(DS.rect(6).fill(hovering ? DS.hover : .clear))
                .contentShape(DS.rect(6))
        }
        .buttonStyle(.plainHit)
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 流式等待时每秒更新的 `· 3s`；不足一秒不显示，避免刚发出就闪一个 0。
struct ElapsedThinkingSeconds: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            if seconds >= 1 {
                // 闭包里直接返回两个 Text 会变成 TupleView，SwiftUI 按纵向排，
                // 「·」和「1s」各占一行、标题行凭空长高一截。收进 HStack 再固定
                // 单行宽度，秒数始终跟在动词后面。
                HStack(spacing: 4) {
                    Text("·")
                    Text("\(seconds)s").monospacedDigit()
                }
                .foregroundStyle(DS.text3)
                .lineLimit(1)
                .fixedSize()
            }
        }
    }
}
