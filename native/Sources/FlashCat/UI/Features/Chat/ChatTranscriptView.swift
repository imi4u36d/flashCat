// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import SwiftUI

/// 对话转录区：只订阅 `ChatStore`，与输入卡草稿和外层壳层解耦，
/// 避免逐字输入、指标每秒刷新或切页动画带动整份长对话重排。
struct ChatTranscriptView: View {
    @ObservedObject var chat: ChatStore
    let threadID: String
    let isActive: Bool
    let bubbleMaxWidth: CGFloat
    let activeEngineName: String
    let supportsVideo: Bool
    let shortModelName: (String) -> String
    let onEdit: (ChatMessage) -> Void
    let onBranch: (UUID) -> Void
    let onRegenerate: () -> Void

    @State private var atBottom = true
    /// 用户正在主动滚动时，内容长高不再把视图拽回底部。
    @State private var userScrolling = false
    /// 「加载更早」按会话记：换一段会话各算各的，删掉会话也只是留个用不到的键。
    /// 切到一段会话时清零：展开过的那几百行如果跟着带进下一次切换，每次都要
    /// 重排一遍，越展开越慢；回到会话时重新按窗口显示，需要再点一次「加载更早」。
    @State private var earlierBatches: [String: Int] = [:]
    /// 合并同一帧内的多次滚动请求，避免高度变化与状态变更连续两次触发 `scrollTo("bottom")`。
    @State private var scrollScheduled = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 转录一次排进布局的正文上限（UTF-8 字节）。使用 `utf8.count` O(1) 累加，
    /// 避免在长对话每次 `body` 求值时执行 O(N) 的 `String.count` 扫描。
    static let transcriptUTF8Budget = 24_000
    /// 「加载更早」一次补多少条。
    static let loadEarlierBatch = 40

    /// 按正文 UTF-8 预算从末尾往前数，能排多少条就排多少条。最后一条不算进预算：
    /// 它再长也得显示，而且流式输出时它一直在长——算进去会让窗口每来一批
    /// 字就缩一截，读者往上翻的位置也跟着跳。
    static func budgetedMessageCount(_ messages: [ChatMessage]) -> Int {
        var bytes = 0
        var count = 0
        for message in messages.reversed() {
            if count > 0 {
                bytes += message.content.utf8.count + (message.reasoning?.utf8.count ?? 0)
            }
            count += 1
            if bytes >= transcriptUTF8Budget { break }
        }
        return max(1, count)
    }

    private var windowCount: Int {
        Self.budgetedMessageCount(chat.messages) + (earlierBatches[threadID] ?? 0)
    }

    private var visibleMessages: [ChatMessage] {
        guard chat.messages.count > windowCount else { return chat.messages }
        return Array(chat.messages.suffix(windowCount))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 懒加载：切会话时只实例化视口附近的行。用 `VStack` 时窗口内的
                // 每一行（含几百行的代码块）都要在首帧完整排版，大对话切换实测
                // 150ms 级；`LazyVStack` 把同一场景压到 30ms 以内。
                LazyVStack(alignment: .leading, spacing: 28) {
                    if chat.messages.count > visibleMessages.count {
                        Button {
                            let anchor = visibleMessages.first?.id
                            earlierBatches[threadID, default: 0] += Self.loadEarlierBatch
                            if let anchor {
                                DispatchQueue.main.async {
                                    proxy.scrollTo(anchor, anchor: .top)
                                }
                            }
                        } label: {
                            Label(
                                L10n.format(
                                    "加载更早的 %lld 条",
                                    Int64(min(Self.loadEarlierBatch, chat.messages.count - visibleMessages.count))),
                                systemImage: "arrow.up")
                        }
                        .buttonStyle(.ds(.ghost, size: .small))
                        .frame(maxWidth: .infinity)
                    }

                    ForEach(visibleMessages) { message in
                        messageRow(message)
                    }

                    // 底部哨兵：没有额外留白，输入卡在布局里自己占位。
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, ChatColumn.contentInset)
                .padding(.top, 28)
                // 输入卡是浮层，底部多留一段，最后一行不会贴到卡的阴影上。
                .padding(.bottom, 44)
            }
            .scrollIndicators(.never)
            // 底部锚点兼两件事：首次布局直接按底部落位，内容长高时把底部锚在
            // 视口底部。落位不交给 `scrollTo`：它依赖列表此刻量出来的高度，
            // 切页回来时窗口外的行还没量，算出的偏移会落在内容中段，甚至落到
            // 内容之外（整块空白）。锚点不会跟用户抢滚动：往上翻时它只是保持
            // 偏移，人自己滚回底部后又自动接管。
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onScrollPhaseChange { _, newPhase in
                userScrolling = (newPhase == .interacting || newPhase == .tracking || newPhase == .decelerating)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height <= geometry.containerSize.height
                    || geometry.contentOffset.y + geometry.containerSize.height
                        >= geometry.contentSize.height - 40
            } action: { _, bottom in
                guard isActive else { return }
                if bottom {
                    if !atBottom { withAnimation(reduceMotion ? nil : Motion.quick) { atBottom = true } }
                } else if !chat.generating || userScrolling {
                    // 生成过程中内容撑高不应误判成用户上翻；只有非生成态或
                    // 用户真的在滚动时，才退出「跟随底部」。
                    if atBottom { withAnimation(reduceMotion ? nil : Motion.quick) { atBottom = false } }
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { oldHeight, newHeight in
                guard isActive, chat.generating, atBottom, oldHeight > 0, newHeight > oldHeight + 1 else { return }
                scheduleScroll(proxy)
            }
            .onChange(of: chat.messages.count) { _, count in
                guard isActive else { return }
                // 同一段对话里追加 / 清空：等这一帧布局完成再定位，
                // 否则会滚到尚不存在的旧位置。换会话不经过这里——滚动视图
                // 随 `threadID` 重建，初始锚点已经落到底部。
                DispatchQueue.main.async {
                    if count == 0 {
                        atBottom = true
                        proxy.scrollTo("top", anchor: .top)
                    } else {
                        restoreBottom(proxy, animated: true)
                    }
                }
            }
            .onChange(of: chat.generating) { _, generating in
                if isActive, !generating, atBottom {
                    scheduleScroll(proxy)
                }
            }
            .onChange(of: isActive) { _, active in
                if active, atBottom {
                    scheduleScroll(proxy, force: true)
                }
            }
            // 换一段对话就换一个滚动视图：新视图按 `initialOffset` 重新落到
            // 底部，不用 `scrollTo` 猜位置（猜出来的位置会停在内容中段）。
            // 上面的滚动回调都挂在这个 id 里面，换会话时随旧视图退场，只对
            // 同一段对话里的增删生效。
            .id(threadID)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                    Rectangle().fill(Color.black)
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                }
            }
            .overlay(alignment: .bottom) {
                if !atBottom {
                    LatestScrollButton {
                        scroll(proxy, animated: true, force: true)
                    }
                    .padding(.bottom, 20)
                    .transition(.opacity.animation(reduceMotion ? nil : Motion.quick))
                }
            }
        }
        // 挂在 `id(threadID)` 外面：里面那层换会话时整个被替换，收不到变化。
        // 切进来的会话从「只按字节窗口」开始，别把上次展开的几百行带进来；
        // `atBottom` 也得跟着复位——在上一段里往上翻过的话，它还是 false，
        // 新会话就会顶着一个「回到底部」按钮、也不跟随新内容。
        .onChange(of: threadID) { _, newID in
            earlierBatches.removeValue(forKey: newID)
            atBottom = true
        }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        MessageRow(
            message: message,
            modelName: message.model.map(shortModelName) ?? activeEngineName,
            startupStage: chat.chatStartupStage,
            maxBubbleWidth: bubbleMaxWidth,
            isLast: message.id == chat.messages.last?.id,
            canRegenerate: !supportsVideo && !chat.generating,
            canBranch: !chat.generating,
            animateStreaming: isActive && message.streaming,
            onEdit: { onEdit(message) },
            onBranch: { onBranch(message.id) },
            onRegenerate: onRegenerate
        )
        .equatable()
        .id(message.id)
    }

    private func scheduleScroll(_ proxy: ScrollViewProxy, animated: Bool = false, force: Bool = false) {
        guard force || atBottom else { return }
        guard !scrollScheduled else { return }
        scrollScheduled = true
        DispatchQueue.main.async {
            scrollScheduled = false
            scroll(proxy, animated: animated, force: force)
        }
    }

    /// 把对话区落到底部。首次布局只量到一部分高度时，稍后再补一次，
    /// 让超大回答（长代码块）也停在最后一条上；读者自己往上翻时不抢位置。
    private func restoreBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !chat.messages.isEmpty else {
            atBottom = true
            return
        }
        scroll(proxy, animated: false, force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard atBottom else { return }
            scroll(proxy, animated: false, force: true)
        }
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard atBottom else { return }
                scroll(proxy, animated: false, force: true)
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool, force: Bool = false) {
        guard force || atBottom else { return }
        if animated, !reduceMotion {
            withAnimation(Motion.glide) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
        atBottom = true
    }
}
