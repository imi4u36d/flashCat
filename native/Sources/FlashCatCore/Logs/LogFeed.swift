// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation

/// 日志页可以看的一个来源。默认是 `all`：每台已装引擎的尾巴并成一份，出问题
/// 时先看「全部」，不用先猜是哪台引擎写的；排查具体一台时再从菜单里挑。
package enum LogFeedSource: Hashable, Identifiable {
    case all
    case engine(EngineID)

    package var id: String {
        switch self {
        case .all: return "all"
        case .engine(let id): return id.rawValue
        }
    }

    /// 下拉菜单与标题里的名字。`全部日志` 走本地化，引擎名就是它的日志文件名。
    package var title: String {
        switch self {
        case .all: return L10n.t("全部日志")
        case .engine(let id): return "\(id.rawValue).log"
        }
    }

    /// 合并视图没有单一文件；单引擎来源指向它自己的日志文件。
    package var filePath: String? {
        switch self {
        case .all: return nil
        case .engine(let id): return EnginePaths.logFile(id)
        }
    }
}

/// 日志页展示的一行。每个 `LogStore` 的行 id 都从 0 数起，合并视图里同一个
/// id 会出现两次，SwiftUI 会认错行——身份必须带上来源。
package struct LogFeedEntry: Identifiable {
    /// 来源 + 行 id。只挑单台引擎时也带来源：视图随时可能切回来，身份不能变。
    package let id: String
    /// 写出这一行的引擎（`rawValue`）。
    package let origin: String
    /// 合并视图里行首显示的来源；单来源视图为空，标题已经写着了。
    package let tag: String?
    package let time: Date
    package let clockText: String
    package let level: LogLevel
    package let text: String

    package init(origin: String, tag: String?, line: LogLine) {
        self.id = origin + "#" + String(line.id)
        self.origin = origin
        self.tag = tag
        self.time = line.time
        self.clockText = line.clockText
        self.level = line.level
        self.text = line.text
    }
}

/// 把几条日志尾巴合成一份阅读顺序。每个 `LogStore` 都是按时间追加的，所以
/// 不用为整个文件排序：从各自末尾往前翻，每次挑时间最大的那条，取满就行。
package enum LogFeed {
    /// 一路来源：`key` 保证跨来源的行 id 唯一，`tag` 是合并视图里显示的名字
    /// （单来源传 nil），`lines` 必须按时间升序。
    package struct Group {
        let key: String
        let tag: String?
        let lines: [LogLine]

        package init(key: String, tag: String?, lines: [LogLine]) {
            self.key = key
            self.tag = tag
            self.lines = lines
        }
    }

    /// 合并成「最新在前」的行，取满 `limit` 行就停。同一时刻的多条按来源
    /// 顺序取，结果可复现，不会在重新求值时闪一下。
    package static func entries(from groups: [Group], limit: Int = 4000) -> [LogFeedEntry] {
        guard limit > 0 else { return [] }
        // 每个来源下一次该读的位置，从末尾开始往前翻。
        var heads = groups.map { $0.lines.count - 1 }
        var result: [LogFeedEntry] = []
        result.reserveCapacity(min(limit, groups.reduce(0) { $0 + $1.lines.count }))
        while result.count < limit {
            var picked = -1
            for index in groups.indices where heads[index] >= 0 {
                guard picked >= 0 else {
                    picked = index
                    continue
                }
                let candidate = groups[index].lines[heads[index]].time
                let current = groups[picked].lines[heads[picked]].time
                if candidate > current { picked = index }
            }
            guard picked >= 0 else { break }
            let group = groups[picked]
            let line = group.lines[heads[picked]]
            heads[picked] -= 1
            result.append(LogFeedEntry(origin: group.key, tag: group.tag, line: line))
        }
        return result
    }

    /// 复制出去的文本。合并视图每行带来源，贴到别处还能看出是哪台引擎写的；
    /// 单来源视图保持纯正文，和以前一样。
    package static func clipboardText(_ entries: [LogFeedEntry], tagged: Bool) -> String {
        guard tagged else { return entries.map(\.text).joined(separator: "\n") }
        return entries.map { "[\($0.origin)] \($0.text)" }.joined(separator: "\n")
    }
}
