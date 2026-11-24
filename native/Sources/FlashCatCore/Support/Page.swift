// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

/// 主工作区的页面。它只是导航用的枚举，不是 AppState 的状态：`section` 存的是
/// 这个值，视图按 case 换页、按 `symbol` 画侧栏图标，所以单独放一份比塞在
/// 装配根里更好找。
package enum Page: String, CaseIterable, Identifiable {
    case overview = "概览"
    case chat = "对话"
    case models = "模型库"
    case engines = "引擎"
    case logs = "日志"
    case settings = "设置"
    /// 画廊是设置之后的一页，进去再用顶部分段切换图片和视频。
    case lab = "画廊"

    package var id: String { rawValue }

    package var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .chat: return "bubble.left"
        case .models: return "square.stack.3d.up"
        case .engines: return "cpu"
        case .logs: return "doc.plaintext"
        case .settings: return "slider.horizontal.3"
        case .lab: return "flask"
        }
    }

    /// 侧栏主工作区入口。
    package static let primaryPages: [Page] = [.chat, .lab]

    /// 侧栏控制台分区入口。设置是系统级的一页，放在控制台列表末尾——它不参与
    /// 日常操作，但也不能只藏在 ⌘, 和菜单里（侧栏曾经漏掉过它）。
    package static let consolePages: [Page] = [.overview, .models, .engines, .logs, .settings]

    /// 与 `App.swift` 菜单栏快捷键完全一致的命令面板排序。
    package static let orderedForCommandPalette: [Page] = [.chat, .lab, .overview, .models, .engines, .logs, .settings]

    /// 与 `App.swift` `.keyboardShortcut` 对应的快捷键展示文案。
    package var shortcutDisplay: String {
        switch self {
        case .chat: return "⌘1"
        case .lab: return "⌘2"
        case .overview: return "⌘3"
        case .models: return "⌘4"
        case .engines: return "⌘5"
        case .logs: return "⌘6"
        case .settings: return "⌘,"
        }
    }

    /// 主工作区七页：画廊紧跟在设置后面。
    package static let workspace: [Page] = [.overview, .chat, .models, .engines, .logs, .settings, .lab]
}
