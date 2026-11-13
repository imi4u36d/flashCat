import Foundation

/// 灵动岛承载的一条通知。`toast()` 只是投递入口，展示、历史和详情都由它负责。
struct IslandNotice: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case info
        case success
        case warning
        case error

        init(message: String) {
            let text = message
            // Messages reach this initializer either in the source language or
            // already localized (the app formats interpolated toasts before
            // handing them over), so recognize both sets of keywords.
            let lower = text.lowercased()
            let failed = text.contains("失败") || text.contains("错误") || text.contains("无法")
                || text.contains("不能") || text.contains("异常")
                || lower.contains("failed") || lower.contains("failure")
                || lower.contains("error") || lower.contains("unable")
                || lower.contains("cannot") || lower.contains("can't")
            let waiting = text.contains("请先") || text.contains("正在") || text.contains("先等")
                || text.contains("暂停") || text.contains("稍候")
                || lower.contains("please") || lower.contains("wait")
                || lower.contains("in progress") || lower.contains("paused")
                || lower.contains("building") || lower.contains("switching")
            let succeeded = text.hasPrefix("已") || text.contains("成功")
                || ["done", "moved", "switched", "downloaded", "deleted",
                    "installed", "cleared", "set ", "removed", "model ready",
                    "stopped waiting"].contains { lower.hasPrefix($0) }
            if failed {
                self = .error
            } else if waiting {
                self = .warning
            } else if succeeded {
                self = .success
            } else {
                self = .info
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info"
            case .success: return "checkmark"
            case .warning: return "exclamationmark"
            case .error: return "xmark"
            }
        }

        /// 没有显式标题时的兜底标题，按通知类型取一个通用名称。
        var defaultTitle: String {
            switch self {
            case .info: return "提示"
            case .success: return "成功"
            case .warning: return "警告"
            case .error: return "错误"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let title: String
    let message: String
    let date: Date
    /// 一过性提示：只在胶囊上停几秒，不进历史、不计未读。模型加载、切换这类
    /// 过程本来就看得见（阶段行、模型选择器里的进度），把它留在通知列表里，
    /// 只是把读者刚看过的东西再写一遍。
    let transient: Bool

    init(title: String,
         message: String,
         kind: Kind? = nil,
         date: Date = Date(),
         transient: Bool = false) {
        self.id = UUID()
        self.kind = kind ?? Kind(message: message)
        self.title = title
        self.message = message
        self.date = date
        self.transient = transient
    }
}
