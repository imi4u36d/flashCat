// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation

/// 概览页「最近客户端」的一行：按 `User-Agent` 把网关会话聚起来。
///
/// 网关只监听回环，客户端身份只能来自请求头；内置对话登记为 `flashCat`。
/// 纯函数放在 View 之外，分组顺序、计数与「最近活动」都能在无窗口的测试里钉住。
package struct GatewayClientSummary: Identifiable {
    package let id: String
    package let name: String
    package let dialect: String
    package let count: Int
    package let last: Date
    package let active: Bool

    /// 按首次出现的顺序保留客户端（会话表本身已按时间排好），最多 `limit` 个。
    package static func group(
        _ sessions: [GatewaySessionSnapshot],
        limit: Int = 4
    ) -> [GatewayClientSummary] {
        var order: [String] = []
        var buckets: [String: (dialect: String, count: Int, last: Date, active: Bool)] = [:]
        for session in sessions {
            let raw = session.client.trimmingCharacters(in: .whitespacesAndNewlines)
            if buckets[raw] == nil { order.append(raw) }
            let previous = buckets[raw]
            buckets[raw] = (
                dialect: previous?.dialect ?? session.dialect,
                count: (previous?.count ?? 0) + 1,
                last: max(previous?.last ?? .distantPast, session.lastActivity),
                active: (previous?.active ?? false)
                    || session.state == .decode
                    || session.state == .prefill
            )
        }
        return Array(order.prefix(limit)).compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            return GatewayClientSummary(
                id: key.isEmpty ? "__unknown__" : key,
                name: displayName(key),
                dialect: bucket.dialect,
                count: bucket.count,
                last: bucket.last,
                active: bucket.active)
        }
    }

    /// `OpenAI/Python 1.40.0`、`curl/8.7.1` 这类 UA 只保留产品/运行时一段，
    /// 后面的注释段在两三百点宽的面板里放不下。
    package static func displayName(_ raw: String) -> String {
        if raw.isEmpty { return L10n.t("未知客户端") }
        if raw == "flashCat" { return L10n.t("内置对话") }
        return raw.split(separator: " ", maxSplits: 1).first.map(String.init) ?? raw
    }
}
