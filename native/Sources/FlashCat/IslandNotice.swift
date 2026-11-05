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
            if text.contains("失败") || text.contains("错误") || text.contains("无法")
                || text.contains("不能") || text.contains("异常") {
                self = .error
            } else if text.contains("请先") || text.contains("正在") || text.contains("先等")
                || text.contains("暂停") || text.contains("稍候") {
                self = .warning
            } else if text.hasPrefix("已") || text.contains("成功") {
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
    }

    let id: UUID
    let kind: Kind
    let message: String
    let date: Date

    init(message: String, kind: Kind? = nil, date: Date = Date()) {
        self.id = UUID()
        self.kind = kind ?? Kind(message: message)
        self.message = message
        self.date = date
    }
}
