import SwiftUI
import AppKit
import FlashCatKit

/// ⌘K 命令面板：页面跳转与常用动作，一个输入框全都能到。
struct CommandPalette: View {
    @ObservedObject var state: AppState
    var openDownloads: () -> Void
    var openHub: () -> Void
    var dismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @State private var keyMonitor: Any?
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
        .onExitCommand { dismiss() }
        .background {
            Button("") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .onAppear {
            focused = true
            selection = 0
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    dismiss()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
        }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private var searchRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "command")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Native.tertiary)
            TextField("跳转到页面或执行命令…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(runSelected)
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
            Text("esc")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Native.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Native.overlay(0.06)))
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    if items.isEmpty {
                        Text("没有匹配的命令")
                            .font(Native.captionFont)
                            .foregroundStyle(Native.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == selection)
                                .id(item.id)
                                .onTapGesture {
                                    selection = index
                                    runSelected()
                                }
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 340)
            .onChange(of: selection) { _, value in
                guard items.indices.contains(value) else { return }
                withAnimation(Motion.quick) {
                    proxy.scrollTo(items[value].id, anchor: .center)
                }
            }
        }
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
            if let shortcut = item.shortcut, !shortcut.isEmpty {
                Text(shortcut)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Native.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Native.overlay(0.05)))
            }
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
            hint("↑", "↓", "选择")
            hint("↵", nil, "打开")
            Spacer(minLength: 0)
            Text("\(items.count) 个命令")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Native.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func hint(_ key: String, _ second: String?, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Native.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 3.5).fill(Native.overlay(0.07)))
            if let second {
                Text(second)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Native.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 3.5).fill(Native.overlay(0.07)))
            }
            Text(L10n.t(label))
                .font(.system(size: 9.5))
                .foregroundStyle(Native.tertiary)
        }
    }

    // MARK: Commands

    private var commands: [CommandItem] {
        var list: [CommandItem] = Page.allCases.map { page in
            CommandItem(id: "nav.\(page.rawValue)",
                        title: L10n.format("打开%@", L10n.t(page.rawValue)),
                        detail: page.detail,
                        icon: page.symbol,
                        shortcut: "⌘\(pageIndex(page))") {
                state.section = page
            }
        }
        list.append(CommandItem(id: "engine.toggle",
                                title: state.isRunning ? "停止推理引擎" : "启动推理引擎",
                                detail: "\(state.activeEngine.displayName) · \(state.engineStageText)",
                                icon: state.isRunning ? "stop.fill" : "play.fill",
                                shortcut: nil) {
            state.toggleService()
        })
        list.append(CommandItem(id: "chat.new", title: "新对话", detail: "开一段新的本地会话",
                                icon: "square.and.pencil", shortcut: "⌘N") {
            state.newConversation()
            state.section = .chat
        })
        list.append(CommandItem(id: "downloads", title: "打开下载中心", detail: "查看模型下载进度",
                                icon: "arrow.down.circle", shortcut: nil, run: openDownloads))
        list.append(CommandItem(id: "hub", title: "模型广场", detail: "搜索 Hugging Face 并下载",
                                icon: "sparkle.magnifyingglass", shortcut: nil, run: openHub))
        list.append(CommandItem(id: "theme", title: "切换外观",
                                detail: L10n.format("当前：%@", L10n.t(state.theme.mode.label)),
                                icon: state.theme.mode == .dark ? "sun.max" : "moon", shortcut: "⌘⇧A") {
            toggleAppearance()
        })
        list.append(CommandItem(id: "sidebar", title: state.showsSidebar ? "折叠边栏" : "展开边栏",
                                detail: "切换图标导航模式",
                                icon: "sidebar.left", shortcut: "⌘\\") {
            state.toggleSidebar()
        })
        return list
    }

    private func pageIndex(_ page: Page) -> Int {
        (Page.allCases.firstIndex(of: page) ?? 0) + 1
    }

    private func toggleAppearance() {
        let dark = state.theme.mode.resolvedIsDark
        state.theme.set(dark ? .light : .dark)
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = min(max(0, selection + delta), items.count - 1)
    }

    private func runSelected() {
        guard items.indices.contains(selection) else { return }
        let item = items[selection]
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { item.run() }
    }
}

struct CommandItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    var shortcut: String? = nil
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
