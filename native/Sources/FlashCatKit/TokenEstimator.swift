// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 统一的 token 估算。
///
/// 之前应用内对话和网关各有一套整数版 token 估算（`other / 4` 与
/// `(other + 3) / 4`，CJK 判定区间还不一样）。一个 SSE 分片常常只有一两个
/// 字符：整数除法把它估成 0 token 后整片丢弃，计数就完全由网络分片边界决定。
///
/// 字符估算收成一条口径：**字符按小数权重累加**，一两个字符的分片也留下
/// 0.25 这样的贡献，计数不再由 SSE 切分方式决定。
///
/// 解码速率只有一路估计：网关的 `DecodeWindowMeter`（墙钟窗口总量）。应用内
/// 对话、曲线与「最近请求」都读同一份按请求打点，不再有第二套低通/计数器
/// 差分。
public enum TokenEstimator {
    /// 字符级 token 权重。CJK/全角约 1 token/字，其余脚本约 4 字符/token。
    /// 返回 Double 是刻意的：短分片也能留下 0.25 这样的贡献，不会被抹成 0。
    public static func fractional(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var weighted = 0.0
        for scalar in text.unicodeScalars {
            weighted += isWide(scalar.value) ? 1.0 : 0.25
        }
        return weighted
    }

    /// 需要整数 token 数时（消息计数、prompt 长度）用。向上取整，短文本不会
    /// 被算成 0；长文本的误差最多 1 token。
    public static func estimate(_ text: String) -> Int {
        Int(fractional(text).rounded(.up))
    }

    /// 从 OpenAI 的 `messages` 里估出输入侧长度（含 system 和工具描述的量级）。
    public static func promptTokens(messages: Any?) -> Int {
        guard let list = messages as? [[String: Any]] else { return 0 }
        var total = 0
        for message in list {
            if let text = message["content"] as? String {
                total += estimate(text)
            } else if let parts = message["content"] as? [[String: Any]] {
                for part in parts {
                    switch part["type"] as? String {
                    case "text":
                        if let text = part["text"] as? String { total += estimate(text) }
                    case "image_url":
                        total += approximateImageTokens
                    default:
                        break
                    }
                }
            }
        }
        // 每条消息的角色/分隔开销，量级参考 OpenAI 的 4 token/条。
        return total + list.count * 4
    }

    /// 一张 1024px 图在 Qwen 系视觉塔上的量级。只用于界面上的上下文估算，
    /// 引擎回报的真实 usage 会覆盖它；不同视觉塔会差几百 token，不必精确。
    public static let approximateImageTokens = 1024

    /// CJK 表意文字与假名、韩文、全角标点/字母。两处旧实现的分段在这里合并。
    private static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }
}
