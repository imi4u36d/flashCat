// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 侧栏「工作区」的分组、搜索与排序规则。
///
/// 版式对齐 Splash 的会话列表：置顶的排在最前（最后置顶的在上），其余按
/// 最后修改时间分成今天 / 昨天 / 最近 7 天 / 最近 30 天 / 更早。规则放在
/// 纯函数里，侧栏只负责画。
package enum ChatThreadSections {
    package enum Group: CaseIterable {
        case pinned, today, yesterday, week, month, older
    }

    package struct Section: Identifiable {
        package let group: Group
        package let threads: [ChatThread]
        package var id: Group { group }

        package init(group: Group, threads: [ChatThread]) {
            self.group = group
            self.threads = threads
        }
    }

    /// 搜索同时看标题与消息正文；空查询返回全部。
    package static func matching(_ threads: [ChatThread], query: String) -> [ChatThread] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return threads }
        return threads.filter { thread in
            if thread.title.localizedStandardContains(needle) { return true }
            return thread.messages.contains { message in
                message.content.localizedStandardContains(needle)
                    || (message.reasoning?.localizedStandardContains(needle) ?? false)
            }
        }
    }

    package static func sections(
        _ threads: [ChatThread],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Section] {
        let today = calendar.startOfDay(for: now)
        let grouped = Dictionary(grouping: threads) { thread -> Group in
            guard thread.pinnedAt == nil else { return .pinned }
            let days =
                calendar.dateComponents(
                    [.day], from: calendar.startOfDay(for: thread.updatedAt), to: today
                ).day ?? 0
            switch days {
            case ...0: return .today
            case 1: return .yesterday
            case 2...7: return .week
            case 8...30: return .month
            default: return .older
            }
        }
        return Group.allCases.compactMap { group in
            guard let items = grouped[group], !items.isEmpty else { return nil }
            let sorted: [ChatThread]
            if group == .pinned {
                sorted = items.sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
            } else {
                sorted = items.sorted { $0.updatedAt > $1.updatedAt }
            }
            return Section(group: group, threads: sorted)
        }
    }

    package static func title(_ group: Group) -> String {
        switch group {
        case .pinned: return "置顶"
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .week: return "最近 7 天"
        case .month: return "最近 30 天"
        case .older: return "更早"
        }
    }
}
