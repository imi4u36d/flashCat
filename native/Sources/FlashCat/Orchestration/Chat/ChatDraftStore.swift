// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import Foundation

/// 一段会话里还没发出去的内容。每个会话各存一份，切走再切回来不会串稿，
/// 也不会把上一段对话的附件带进下一段——Splash 的 `Draft` 就是按会话隔离的。
struct ChatDraft: Equatable {
    var text = ""
    /// 图像模型的底图；视频模型下它是首帧。
    var imageAttachment: ChatImageAttachment?
    /// 视频模型的尾帧。图像模型只用一张底图，这里始终为空。
    var lastFrameAttachment: ChatImageAttachment?
    /// REF2VA 的参考图与参考视频。
    var referenceImages: [ChatImageAttachment] = []
    var referenceClips: [VideoReferenceClip] = []
    /// 输入卡上方那句解释（附件读不出来、模型限制之类）。
    var notice: String?
    /// 文本 / 视觉对话挂的图片与文件；与图像 / 视频生成的媒体槽位分开。
    var chatImages: [ChatImageAttachment] = []
    var chatFiles: [ChatFileAttachment] = []
    /// 生成中按回车排进来、等这一轮结束再发的后续消息。
    var queuedTexts: [String] = []

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && imageAttachment == nil
            && lastFrameAttachment == nil
            && referenceImages.isEmpty
            && referenceClips.isEmpty
            && chatImages.isEmpty
            && chatFiles.isEmpty
            && queuedTexts.isEmpty
    }
}

/// 每个会话的草稿。单独一个 store、且**不**桥回 AppState：草稿每敲一个字都会
/// 发布，桥回去会让整个控制台壳层跟着逐字重绘。只有对话页直接订阅它；切会话、
/// 切页、新建对话都只是换一个键。
@MainActor
final class ChatDraftStore: ObservableObject {
    @Published var drafts: [String: ChatDraft] = [:]

    /// 会话被删除 / 清空时把它的草稿一起丢掉。
    func forget(_ threadID: String) {
        drafts[threadID] = nil
    }
}
