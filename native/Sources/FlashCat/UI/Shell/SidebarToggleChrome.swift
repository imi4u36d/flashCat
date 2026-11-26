// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import SwiftUI

/// 顶栏左上的侧栏开关。
///
/// 这颗按钮原本由 `NavigationSplitView` 自动插进 toolbar；macOS 26 会给它
/// 套一圈玻璃胶囊，和设计系统的实色图标按钮不是一套语言。
/// `.toolbar(removing: .sidebarToggle)` 在这一版上是空操作，自定义
/// `ToolbarItem` 又只能排到页面一侧，所以这里保留系统 item（位置仍归
/// AppKit），只把 item 的内容换成 `DSIconButton`。
///
/// 折叠动作走 `NSSplitViewController.toggleSidebar(_:)`：系统按钮的收起
/// 动画就是它带的，直接改 `showsSidebar` 则会一步到位。AppKit 改完列宽后，
/// SwiftUI 会把新的 `columnVisibility` 写回绑定，落盘照旧。
@MainActor
enum SidebarToggleChrome {
    /// 已经换过的视图打这个标记。窗口每次成为 key window 都会重走一遍
    /// `configure`，靠它避免反复重建 hosting view。
    private static let marker = NSUserInterfaceItemIdentifier("flashCat.sidebarToggle")

    /// SwiftUI 给自动侧栏开关用的标识。匹配不到就原样保留系统按钮：
    /// 样式退回玻璃胶囊，功能不受影响。
    private static let itemIdentifier = "com.apple.SwiftUI.navigationSplitView.toggleSidebar"

    private static let size = NSSize(width: 28, height: 28)

    static func restyle(in window: NSWindow) {
        guard let toolbar = window.toolbar,
            let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue == itemIdentifier }),
            item.view?.identifier != marker
        else { return }

        let button = SidebarToggleButton(state: AppState.shared) { [weak window] in
            toggle(in: window)
        }
        let host = NSHostingView(rootView: button)
        host.identifier = marker
        host.frame = NSRect(origin: .zero, size: size)
        // 关掉 item 自带的胶囊底，按钮的底色交给设计系统的 hover。
        item.isBordered = false
        item.view = host
    }

    /// 优先让 AppKit 做原生折叠；拿不到分栏控制器时退回状态驱动，
    /// 少一段动画但不至于点不动。
    private static func toggle(in window: NSWindow?) {
        guard let split = window.flatMap({ splitViewController(in: $0.contentView) }) else {
            AppLog.debug(.app, "侧栏开关没找到分栏控制器，退回状态驱动")
            AppState.shared.toggleSidebar()
            return
        }
        split.toggleSidebar(nil)
    }

    private static func splitViewController(in view: NSView?) -> NSSplitViewController? {
        guard let view else { return nil }
        if let split = view.nextResponder as? NSSplitViewController { return split }
        for subview in view.subviews {
            if let split = splitViewController(in: subview) { return split }
        }
        return nil
    }
}

/// 侧栏开关：和顶栏其余图标按钮同一档（28pt、悬停才给底色）。
private struct SidebarToggleButton: View {
    @ObservedObject var state: AppState
    var action: () -> Void

    private var title: String {
        L10n.t(state.showsSidebar ? "隐藏边栏" : "显示边栏")
    }

    var body: some View {
        DSIconButton(
            systemName: "sidebar.leading",
            help: "\(title)  ⌃⌘S",
            action: action
        )
    }
}
