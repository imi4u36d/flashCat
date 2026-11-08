import SwiftUI
import FlashCatKit

extension Notification.Name {
    /// 命令面板是视图自己的 `@State`，菜单通过这条通知请求打开它。
    static let flashCatOpenCommandPalette = Notification.Name("flashCat.openCommandPalette")
}

/// 命令面板：页面跳转与常用动作，一个输入框全都能到。
///
/// 面板刻意只支持鼠标：应用不注册任何键盘快捷键，也不接管方向键、
/// 回车或 esc。搜索框仍然可以输入（那是文本编辑，不是快捷键），
/// 运行命令则点一行或点底部的按钮。
struct CommandPalette: View {
    @ObservedObject var state: AppState
    var openDownloads: () -> Void
    var openHub: () -> Void
    var dismiss: () -> Void

    @State private var query = ""
    @State private var hovered: String?
    @FocusState private var focused: Bool

    private var items: [CommandItem] {
        let all = commands
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return all }
        return all.filter { "\($0.title) \($0.detail)".lowercased().contains(text) }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                searchRow
                Hairline()
                results
                Hairline()
                footer
            }
            .frame(width: 560)
            .background {
                LiquidGlassSurface(
                    shape: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            .padding(.top, 120)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear { focused = true }
    }

    private var searchRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Native.tertiary)
            TextField("跳转到页面或执行命令…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Native.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Native.overlay(0.07)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plainHit)
            .help("关闭命令面板")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                if items.isEmpty {
                    Text("没有匹配的命令")
                        .font(Native.captionFont)
                        .foregroundStyle(Native.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ForEach(items) { item in
                        row(item, selected: hovered == item.id)
                            .id(item.id)
                            .onTapGesture { run(item) }
                            .onHover { inside in
                                if inside {
                                    hovered = item.id
                                } else if hovered == item.id {
                                    hovered = nil
                                }
                            }
                    }
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 340)
    }

    private func row(_ item: CommandItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Native.accent : Native.secondary)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t(item.title))
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Native.label)
                if !item.detail.isEmpty {
                    Text(L10n.t(item.detail))
                        .font(.system(size: 10))
                        .foregroundStyle(Native.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Native.accent.opacity(0.10) : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("点击一行运行命令")
                .font(.system(size: 9.5))
                .foregroundStyle(Native.tertiary)
            Spacer(minLength: 0)
            Text("\(items.count) 个命令")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Native.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Commands

    private var commands: [CommandItem] {
        var list: [CommandItem] = Page.allCases.map { page in
            CommandItem(id: "nav.\(page.rawValue)",
                        title: L10n.format("打开%@", L10n.t(page.rawValue)),
                        detail: page.detail,
                        icon: page.symbol) {
                state.section = page
            }
        }
        list.append(CommandItem(id: "engine.toggle",
                                title: state.isRunning ? "停止推理引擎" : "启动推理引擎",
                                detail: "\(state.activeEngine.displayName) · \(state.engineStageText)",
                                icon: state.isRunning ? "stop.fill" : "play.fill") {
            state.toggleService()
        })
        list.append(CommandItem(id: "chat.new", title: "新对话", detail: "开一段新的本地会话",
                                icon: "square.and.pencil") {
            state.newConversation()
            state.section = .chat
        })
        list.append(CommandItem(id: "downloads", title: "打开下载中心", detail: "查看模型下载进度",
                                icon: "arrow.down.circle", run: openDownloads))
        list.append(CommandItem(id: "hub", title: "模型广场", detail: "搜索 Hugging Face 并下载",
                                icon: "sparkle.magnifyingglass", run: openHub))
        list.append(CommandItem(id: "theme", title: "切换外观",
                                detail: L10n.format("当前：%@", L10n.t(state.theme.mode.label)),
                                icon: state.theme.mode == .dark ? "sun.max" : "moon") {
            toggleAppearance()
        })
        list.append(CommandItem(id: "sidebar", title: state.showsSidebar ? "折叠边栏" : "展开边栏",
                                detail: "显示 / 隐藏玻璃导航列",
                                icon: "sidebar.left") {
            state.toggleSidebar()
        })
        return list
    }

    private func toggleAppearance() {
        let dark = state.theme.mode.resolvedIsDark
        state.theme.set(dark ? .light : .dark)
    }

    private func run(_ item: CommandItem) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { item.run() }
    }
}

struct CommandItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let run: () -> Void
}

private extension Page {
    var detail: String {
        switch self {
        case .overview: return "引擎状态、实时指标与接口"
        case .chat: return "本地会话与生成"
        case .models: return "模型库、模型广场与下载"
        case .engines: return "安装、启停与调优"
        case .logs: return "实时输出与过滤"
        case .settings: return "外观、服务与默认参数"
        }
    }
}
