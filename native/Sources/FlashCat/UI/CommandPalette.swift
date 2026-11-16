// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import SwiftUI

extension Notification.Name {
    /// 命令面板是视图自己的 `@State`，菜单通过这条通知请求打开它。
    static let flashCatOpenCommandPalette = Notification.Name("flashCat.openCommandPalette")
}

/// 命令面板：页面跳转与常用动作，一个输入框全都能到。
struct CommandPalette: View {
    @ObservedObject var state: AppState
    var openDownloads: () -> Void
    var openHub: () -> Void
    var dismiss: () -> Void

    @State private var query = ""
    @State private var hovered: String?
    @State private var selectedIndex = 0
    @State private var presented = false
    @FocusState private var focused: Bool

    private var items: [CommandItem] {
        let all = commands
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return all }
        return all.filter { "\($0.title) \($0.detail)".lowercased().contains(text) }
    }

    private var clampedSelection: Int {
        guard !items.isEmpty else { return -1 }
        return min(max(0, selectedIndex), items.count - 1)
    }

    var body: some View {
        ZStack {
            DS.scrim
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                searchRow
                DSDivider()
                results
                DSDivider()
                footer
            }
            .frame(width: 560)
            .dsFloating(radius: DS.Radius.lg)
            .scaleEffect(presented ? 1 : 0.97)
            .opacity(presented ? 1 : 0)
            .padding(.top, 108)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            selectedIndex = 0
            focused = true
            withAnimation(DS.Motion.bouncy) { presented = true }
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onExitCommand { dismiss() }
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.text3)
            TextField("跳转到页面或执行命令…", text: $query)
                .textFieldStyle(.plain)
                .font(DS.Font.lg)
                .foregroundStyle(DS.text)
                .focused($focused)
                .onSubmit { runSelected() }
                .onKeyPress(.upArrow) {
                    moveSelection(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
            DSKbd(text: "ESC")
            DSIconButton(systemName: "xmark", help: "关闭命令面板", size: 24) {
                dismiss()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var results: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if items.isEmpty {
                        Text("没有匹配的命令")
                            .font(DS.Font.sm)
                            .foregroundStyle(DS.text3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    } else {
                        let activeIndex = clampedSelection
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == activeIndex || hovered == item.id)
                                .id(item.id)
                                .onTapGesture { run(item) }
                                .onHover { inside in
                                    if inside {
                                        hovered = item.id
                                        selectedIndex = index
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
            .onChange(of: selectedIndex) { _, newValue in
                guard newValue >= 0, newValue < items.count else { return }
                withAnimation(DS.Motion.snappy) {
                    scroll.scrollTo(items[newValue].id, anchor: .center)
                }
            }
        }
    }

    private func moveSelection(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        hovered = nil
        selectedIndex = (clampedSelection + delta + count) % count
    }

    private func runSelected() {
        let idx = clampedSelection
        guard idx >= 0, idx < items.count else { return }
        run(items[idx])
    }

    private func row(_ item: CommandItem, selected: Bool) -> some View {
        let shape = DS.rect(DS.Radius.sm)
        return HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(selected ? DS.accent : DS.text3)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t(item.title))
                    .font(DS.Font.md.weight(selected ? .medium : .regular))
                    .foregroundStyle(selected ? DS.text : DS.text2)
                if !item.detail.isEmpty {
                    Text(L10n.t(item.detail))
                        .font(DS.Font.xs)
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                DSKbd(text: shortcut)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if selected {
                shape.fill(DS.hover)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(DS.accent)
                            .frame(width: 2, height: 14)
                            .padding(.leading, 1)
                    }
            }
        }
        .animation(DS.Motion.snappy, value: selected)
        .contentShape(shape)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("点击一行运行命令")
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
            Spacer(minLength: 0)
            Text("\(items.count) 个命令")
                .font(DS.Font.mono(10))
                .foregroundStyle(DS.text3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Commands

    private var engineToggleDetail: String {
        let stage = state.engineStageText
        guard !stage.isEmpty else { return state.activeEngine.displayName }
        return "\(state.activeEngine.displayName) · \(stage)"
    }

    private var commands: [CommandItem] {
        var list: [CommandItem] = Page.allCases.enumerated().map { index, page in
            CommandItem(
                id: "nav.\(page.rawValue)",
                title: L10n.format("打开%@", L10n.t(page.rawValue)),
                detail: page.detail,
                icon: page.symbol,
                shortcut: index < 6 ? "⌘\(index + 1)" : nil
            ) {
                state.section = page
            }
        }
        list.append(
            CommandItem(
                id: "engine.toggle",
                title: state.isRunning ? "停止推理引擎" : "启动推理引擎",
                detail: engineToggleDetail,
                icon: state.isRunning ? "stop.fill" : "play.fill"
            ) {
                state.toggleService()
            })
        list.append(
            CommandItem(
                id: "chat.new", title: "新对话", detail: "开一段新的本地会话",
                icon: "square.and.pencil", shortcut: "⌘N"
            ) {
                state.newConversation()
                state.section = .chat
            })
        list.append(
            CommandItem(
                id: "downloads", title: "打开下载中心", detail: "查看模型下载进度",
                icon: "arrow.down.circle", run: openDownloads))
        list.append(
            CommandItem(
                id: "hub", title: "模型广场", detail: "搜索 Hugging Face 并下载",
                icon: "sparkle.magnifyingglass", run: openHub))
        list.append(
            CommandItem(
                id: "theme", title: "切换外观",
                detail: L10n.format("当前：%@", L10n.t(state.theme.mode.label)),
                icon: state.theme.mode == .dark ? "sun.max" : "moon"
            ) {
                toggleAppearance()
            })
        list.append(
            CommandItem(
                id: "sidebar", title: state.showsSidebar ? "折叠边栏" : "展开边栏",
                detail: "显示 / 隐藏玻璃导航列",
                icon: "sidebar.left", shortcut: "⌃⌘S"
            ) {
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
    var shortcut: String? = nil
    let run: () -> Void
}

extension Page {
    fileprivate var detail: String {
        switch self {
        case .overview: return "引擎状态、实时指标与接口"
        case .chat: return "本地会话与生成"
        case .models: return "模型库、模型广场与下载"
        case .engines: return "安装、启停与调优"
        case .logs: return "实时输出与过滤"
        case .settings: return "外观、服务与默认参数"
        case .lab: return "对话中生成的图片与视频"
        }
    }
}
