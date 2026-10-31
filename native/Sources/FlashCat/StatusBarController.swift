import SwiftUI
import AppKit
import Combine

// MARK: - 主窗口

/// 主窗口的唯一入口。
///
/// 菜单栏面板可能由 NSPopover 承载（不在 SwiftUI 场景树里），因此不能直接用
/// `@Environment(\.openWindow)`。这里在场景里挂一个零尺寸的桥接视图，把
/// `openWindow` 动作存下来，面板、菜单命令都通过 `MainWindow.show()` 调用。
@MainActor
enum MainWindow {
    static var opener: (() -> Void)?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        // 窗口还在（只是被关到后台）时直接抬到前面，避免重复开窗。
        if let window = NSApp.windows.first(where: { $0.title == "flashCat" && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        opener?()
    }

    /// 挂在主窗口内容里，负责捕获 openWindow 动作，不参与布局。
    static func bridge() -> some View { WindowActionBridge() }
}

private struct WindowActionBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear {
                MainWindow.opener = { openWindow(id: "main") }
            }
    }
}

// MARK: - 菜单栏常驻项

/// 系统菜单栏的常驻入口：native `NSStatusItem` + `NSPopover`。
///
/// 为什么不用 SwiftUI 的 `MenuBarExtra`：这一版 macOS 会给自定义 label 画一块
/// 浅色底板（图标因此变成黑线 + 白方块），而 `NSStatusItem` 只按模板图着色，
/// 菜单栏明暗自动适配，永远是干净的单色剪影。
@MainActor
final class StatusBarController: NSObject {
    private let state: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = MenuBarIcon.statusImage(state: state.serverState)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "flashCat · \(state.serverState.rawValue)"
        }

        let root = MenuBarPanel(state: state, onOpenMainWindow: { MainWindow.show() })
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        // popover 不在窗口列表里，自己带上当前皮肤的外观；菜单栏图标本身不跟随皮肤。
        popover.appearance = state.theme.resolvedAppearance

        // 状态变化时换图标：运行中实心、过渡态压暗、停止描边、异常带告警点。
        state.$serverState
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                guard let self else { return }
                self.statusItem.button?.image = MenuBarIcon.statusImage(state: newState)
                self.statusItem.button?.toolTip = "flashCat · \(newState.rawValue)"
            }
            .store(in: &cancellables)
    }

    @objc private func handleClick() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
