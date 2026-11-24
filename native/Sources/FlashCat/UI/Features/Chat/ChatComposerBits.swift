// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AVKit
import AppKit
import FlashCatKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 后台异步解码会话里的图片缩略图，并从内存缓存预填首帧，避免大 PNG/JPEG 阻塞主线程。
struct AsyncChatThumbnail<Placeholder: View, Missing: View>: View {
    let path: String
    let maxPixel: CGFloat
    var contentMode: ContentMode = .fill
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let missingView: () -> Missing

    @State private var image: NSImage?
    @State private var missing = false

    init(
        path: String,
        maxPixel: CGFloat,
        contentMode: ContentMode = .fill,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder missingView: @escaping () -> Missing
    ) {
        self.path = path
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        self.placeholder = placeholder
        self.missingView = missingView
        _image = State(initialValue: ImageStore.cachedThumbnail(atPath: path, maxPixel: maxPixel))
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if missing {
                missingView()
            } else {
                placeholder()
            }
        }
        .task(id: path) {
            missing = false
            if let cached = ImageStore.cachedThumbnail(atPath: path, maxPixel: maxPixel) {
                image = cached
                return
            }
            image = nil
            let loaded = await ImageStore.thumbnailAsync(atPath: path, maxPixel: maxPixel)
            image = loaded
            missing = loaded == nil
        }
    }
}

// MARK: - Chat stage layout

/// 把转录区与输入卡交给 `ChatStageLayout` 的容器。两个视图放进同一个
/// `Group`，布局按 `subviews[0]` / `subviews[1]` 取用。
struct ChatStageView<Content: View, Composer: View>: View {
    let newChat: Bool
    let column: CGFloat
    @ViewBuilder let content: Content
    @ViewBuilder let composer: Composer

    var body: some View {
        ChatStageLayout(newChat: newChat, column: column) {
            content
            composer
        }
    }
}

/// 转录区与输入卡的布局，对齐 Splash 的 `ChatColumn`：
/// - 有对话时，转录区占满输入卡上方的空间，输入卡贴在页脚上方 24pt；
/// - 新会话时，品牌标记与输入卡作为一组放在剩余空间约 1/3 处，下留 2/3。
///
/// 两种状态共用同一个输入卡视图，所以首条消息发出后它只是「移动」，不会
/// 重建——文本视图、输入法组字和光标都能原样保留。
struct ChatStageLayout: Layout {
    let newChat: Bool
    /// 列宽（含左右 32pt 内边距）。输入卡与转录区都按这个宽度居中。
    let column: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: column, height: 600))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }
        let content = subviews[0]
        let composer = subviews[1]
        let width = min(column, bounds.width)
        let composerSize = composer.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let bottom: CGFloat = 24

        if newChat {
            let contentSize = content.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let gap: CGFloat = 20
            let group = contentSize.height + gap + composerSize.height
            let room = bounds.height - group - bottom
            let top = max(0, min(room / 3, bounds.height - bottom - group))
            content.place(
                at: CGPoint(x: bounds.midX, y: bounds.minY + top),
                anchor: .top,
                proposal: ProposedViewSize(width: width, height: contentSize.height))
            composer.place(
                at: CGPoint(x: bounds.midX, y: bounds.minY + top + contentSize.height + gap),
                anchor: .top,
                proposal: ProposedViewSize(width: width, height: composerSize.height))
        } else {
            let contentHeight = max(0, bounds.height - composerSize.height - bottom)
            content.place(
                at: CGPoint(x: bounds.midX, y: bounds.minY),
                anchor: .top,
                proposal: ProposedViewSize(width: width, height: contentHeight))
            composer.place(
                at: CGPoint(x: bounds.midX, y: bounds.maxY - bottom - composerSize.height),
                anchor: .top,
                proposal: ProposedViewSize(width: width, height: composerSize.height))
        }
    }
}

// MARK: - Chat title

/// 顶栏的会话标题：文字 + 下拉箭头，悬停高亮，点开是置顶 / 重命名 / 删除。
/// 新会话没有标题，Splash 的工具栏也是这样留白。
struct ChatTitleMenu: View {
    @ObservedObject var state: AppState
    let thread: ChatThread
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Menu {
            Button(thread.pinned ? L10n.t("取消置顶") : L10n.t("置顶")) {
                state.setThreadPinned(thread, !thread.pinned)
            }
            Button(L10n.t("重命名…")) {
                state.requestThreadRename(thread)
            }
            Divider()
            Button(L10n.t("删除…"), role: .destructive) {
                state.requestThreadDelete(thread)
            }
        } label: {
            HStack(spacing: 5) {
                Text(thread.title.isEmpty ? L10n.t("新对话") : thread.title)
                    .font(DS.Font.prose(15, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.text3)
            }
            .foregroundStyle(DS.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DS.rect(7).fill(hovering ? DS.hover : .clear))
            .contentShape(DS.rect(7))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
        .help(L10n.t("置顶、重命名或删除这段对话"))
        .accessibilityLabel(thread.title.isEmpty ? L10n.t("新对话") : thread.title)
    }
}

// MARK: - Composer bits

/// 输入卡底排的图标按钮：Splash 的按钮是「无边框、悬停才浮出底色」，
/// 不是一枚枚描边小方块。
struct ComposerIconButton: View {
    let systemName: String
    let help: String
    var active: Bool = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(active ? DS.accent : (hovering ? DS.text : DS.text2))
                .frame(width: 28, height: 28)
                .background(DS.rect(7).fill(hovering || active ? DS.hover : .clear))
                .contentShape(DS.rect(7))
        }
        .buttonStyle(.plainHit)
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
        .help(L10n.t(help))
        .accessibilityLabel(L10n.t(help))
    }
}

/// 上下文占用环：Splash 输入卡右下角那枚 14pt 小环，悬停给出精确数字。
struct ChatContextRing: View {
    let used: Int
    let ceiling: Int?

    private var fraction: Double {
        guard let ceiling, ceiling > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(ceiling)))
    }

    private var tint: Color {
        if fraction >= 1 { return DS.err }
        if fraction > 0.8 { return DS.warn }
        return DS.text3
    }

    private var explanation: String {
        let usedText = Format.tokens(used)
        guard let ceiling, ceiling > 0 else {
            return L10n.format("上下文 %@ tokens", usedText)
        }
        return L10n.format(
            "上下文 %@ / %@（%.0f%%）",
            usedText,
            Format.tokensShort(ceiling),
            fraction * 100)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(DS.line2, lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
        // 环本身只有 14pt，周围留一圈命中区，悬停才容易碰到。
        .padding(5)
        .contentShape(Rectangle())
        .help(explanation)
        .accessibilityElement()
        .accessibilityLabel(L10n.t("上下文"))
        .accessibilityValue(explanation)
    }
}

/// 读者滚离底部后浮出的「回到最新」圆钮，位置与造型对齐 Splash。
struct LatestScrollButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.text)
                .frame(width: 30, height: 30)
                .background(Circle().fill(hovering ? DS.selected : DS.raised))
                .overlay(Circle().strokeBorder(DS.line, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plainHit)
        .onHover { value in
            withAnimation(DS.Motion.snappy) { hovering = value }
        }
        .help(L10n.t("回到最新"))
        .accessibilityLabel(L10n.t("回到最新"))
    }
}
