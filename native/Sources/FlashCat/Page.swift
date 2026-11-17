// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

/// 主工作区的页面。它只是导航用的枚举，不是 AppState 的状态：`section` 存的是
/// 这个值，视图按 case 换页、按 `symbol` 画侧栏图标，所以单独放一份比塞在
/// 装配根里更好找。
enum Page: String, CaseIterable, Identifiable {
    case overview = "概览"
    case chat = "对话"
    case models = "模型"
    case engines = "引擎"
    case logs = "日志"
    case settings = "设置"
    /// 实验是设置之后的一页，进去再用顶部分段切换图片和视频。
    case lab = "实验"

    var id: String { rawValue }

    var symbol: String {
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

    /// 主工作区七页：实验紧跟在设置后面。
    static let workspace: [Page] = [.overview, .chat, .models, .engines, .logs, .settings, .lab]
}
