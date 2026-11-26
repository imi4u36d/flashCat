// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

private enum MainWindowGeometry {
    static let defaultSize = NSSize(width: 1360, height: 856)
    /// 页面在窄窗口下会切成单栏纵向排布，因此可以把下限继续放低；
    /// 再小则侧栏和标题栏控件会互相挤压。
    static let minimumSize = NSSize(width: 680, height: 560)
}

@main
struct FlashCatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Scene 层的 `if state.isPresentingLaunchPage` 依赖这里的状态订阅：
    // 普通 let 不会让 SwiftUI 重新求值 body，点击「开始使用」就永远切不进控制台。
    @ObservedObject private var state = AppState.shared
    /// 外观模式只在设置页与窗口 chrome 之间共享；单独观察控制器，
    /// 让 `preferredColorScheme` 在切换时立刻重算。
    @ObservedObject private var theme = AppState.shared.theme

    var body: some Scene {
        Window("flashCat", id: "main") {
            // 窗口内容全部是 SwiftUI 原生视图（含启动页），没有网页层。
            console
        }
        .defaultSize(
            width: MainWindowGeometry.defaultSize.width,
            height: MainWindowGeometry.defaultSize.height
        )
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 flashCat") { delegate.showAbout() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置") { state.section = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("打开对话") { state.section = .chat }
                Button("新建对话") {
                    state.newConversation()
                    state.section = .chat
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("服务") {
                Button("启动服务") { state.startService() }
                    .disabled(state.isRunning)
                Button("停止服务") { state.stopService() }
                    .disabled(!state.isRunning)
                Button("重启服务") { state.restartService() }
                    .disabled(!state.isRunning)
                Divider()
                Button("复制接口地址") { state.copy(state.endpointURL) }
                Button("打开日志文件") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Paths.logFile))
                }
            }
            CommandGroup(after: .sidebar) {
                Button(L10n.t(state.showsSidebar ? "隐藏边栏" : "显示边栏")) {
                    state.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                Button("切换浅色 / 深色") {
                    state.theme.toggleLightDark()
                }
            }
            CommandMenu("页面") {
                Button("搜索对话") { state.focusChatSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                Divider()
                Button("对话") { state.section = .chat }
                    .keyboardShortcut("1", modifiers: .command)
                Button("画廊") { state.section = .lab }
                    .keyboardShortcut("2", modifiers: .command)
                Button("概览") { state.section = .overview }
                    .keyboardShortcut("3", modifiers: .command)
                Button("模型库") { state.section = .models }
                    .keyboardShortcut("4", modifiers: .command)
                Button("引擎") { state.section = .engines }
                    .keyboardShortcut("5", modifiers: .command)
                Button("日志") { state.section = .logs }
                    .keyboardShortcut("6", modifiers: .command)
                Button("设置") { state.section = .settings }
            }
        }

    }

    /// 原生控制台：六个页面、启动页、下载中心、引擎配置与确认弹窗都是
    /// SwiftUI / AppKit 视图。
    private var console: some View {
        ConsoleView(state: state)
            .frame(
                minWidth: MainWindowGeometry.minimumSize.width,
                minHeight: MainWindowGeometry.minimumSize.height
            )
            // 系统控件（分段、开关、Picker、菜单）统一跟随主题色；
            // 显式 `.tint` 的控件仍以局部设置为准。
            .tint(DS.accent)
            // SwiftUI 内容也显式跟随外观模式：只靠 window.appearance 时，
            // 冷启动会先按系统浅色解析一遍，窗口内容要等用户重新激活才刷新。
            .preferredColorScheme(preferredColorScheme)
            .overlay(MainWindow.bridge())
    }

    private var preferredColorScheme: ColorScheme? {
        switch theme.mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 常驻菜单栏项。必须由 AppDelegate 强引用持有，否则状态栏项会被回收。
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply the stored skin before anything paints: `nil` appearance means
        // "follow macOS", so the app opens in whatever the reader picked.
        let state = AppState.shared
        state.theme.apply()
        state.bootstrap()

        statusBar = StatusBarController(state: state)

        for target in NSApp.windows {
            configure(target)
        }
        // SwiftUI creates the window (and installs its toolbar) after the
        // delegate in some builds, so re-apply the chrome once layout settles.
        for delay in [0.3, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for target in NSApp.windows { self.configure(target) }
            }
        }
        // 持久化的深色外观如果只在这里应用一次，窗口晚于 delegate 创建时会被
        // SwiftUI 的默认外观覆盖：图标显示深色、页面却是浅色。窗口每次成为
        // key window 时再套一次，成本可以忽略。
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.configure(window) }
        }
    }

    private func configure(_ target: NSWindow) {
        // 只处理主窗口。状态栏项的按钮也活在一个内部窗口里（层级更高的 panel），
        // 给它套主窗口的外观和标题栏设置，会让系统给菜单栏图标补一块浅色底板。
        guard target.canBecomeMain, target is NSPanel == false else {
            if target.sheetParent != nil {
                AppState.shared.theme.apply(to: target)
            }
            return
        }
        target.title = "flashCat"
        target.titleVisibility = .hidden
        AppState.shared.theme.apply(to: target)
        SidebarToggleChrome.restyle(in: target)
        let minimumWindowSize = MainWindowGeometry.minimumSize
        target.minSize = minimumWindowSize
        target.contentMinSize = minimumWindowSize
        if target.frameAutosaveName.isEmpty {
            target.setFrameAutosaveName("flashCatWindow")
            target.setContentSize(MainWindowGeometry.defaultSize)
            target.center()
        } else if target.frame.width < minimumWindowSize.width
            || target.frame.height < minimumWindowSize.height
        {
            target.setContentSize(
                NSSize(
                    width: max(target.contentLayoutRect.width, MainWindowGeometry.defaultSize.width),
                    height: max(target.contentLayoutRect.height, MainWindowGeometry.defaultSize.height))
            )
        }
        Self.clampToVisibleScreen(target)
        // frame autosave 的还原发生在窗口创建之后：同步那一次夹到的可能还是
        // "还原前"的 frame，等这一轮 runloop 收尾再夹一次才夹得住真正显示的版本。
        DispatchQueue.main.async { [weak target] in
            guard let target else { return }
            Self.clampToVisibleScreen(target)
        }
    }

    /// autosave 的窗口坐标可能属于一块已经拔掉的副屏：恢复出来的 frame 整体在
    /// 可见区域之外，用户点了图标却什么都看不到，只能以为应用没启动。这里的
    /// 判据是"和任意一块屏幕有足够的重叠"，没有就挪回主屏居中。
    private static func clampToVisibleScreen(_ window: NSWindow) {
        let frame = window.frame
        let onScreen = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.width >= 160 && overlap.height >= 120
        }
        guard !onScreen, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = NSSize(
            width: min(max(frame.width, MainWindowGeometry.minimumSize.width), visible.width),
            height: min(max(frame.height, MainWindowGeometry.minimumSize.height), visible.height))
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 菜单栏常驻：关掉主窗口应用继续留在菜单栏，引擎照常对外服务，
        // 从面板上的"打开主窗口"或 Dock 图标随时回到窗口。彻底退出走
        // 面板里的"退出 flashCat"。
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.show() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Nothing to do: the engines are reaped in `applicationShouldTerminate`
        // while AppKit is still holding the process alive. Doing it here would
        // be too late — by this point a `kill` may already have detached the
        // children from us.
    }

    /// Quit is where "the app is gone but the engine is not" gets decided.
    ///
    /// The old code waited for the engine inside an unbounded `Thread.sleep`
    /// loop on the main actor, so a 20 GB model load could freeze the quit for
    /// seconds. The current version signals first and waits at most 1.5 s
    /// before SIGKILL: long enough for a healthy engine, short enough that
    /// Force Quit never becomes the expected next step (and leaves weights
    /// resident).
    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else {
            // A second quit request while the first teardown is still in flight: refuse
            // rather than quit early and strand the engines. The window is
            // bounded (1.5 s grace), so this never feels stuck.
            return .terminateCancel
        }
        isTerminating = true
        // Do the teardown inline and answer `.terminateNow`. Returning
        // `.terminateLater` and letting a Task reply was not reliable: AppKit
        // destroys the process before the task is scheduled, which leaves the
        // engines resident and the last history write in flight. The wait below
        // is bounded by the engine grace (1.5 s), so this never becomes the old
        // multi-second freeze.
        let state = AppState.shared
        // Gateway first (it answers requests), then every installed engine,
        // then whatever ignored the first signal.
        state.prepareForTermination()
        state.engines?.shutdownEngines()
        state.finishTermination()
        // 历史/当前会话改为后台写盘，退出前把队列排空。
        state.history.flushPendingWrites()
        state.conversation.flushPendingWrites()
        return .terminateNow
    }

    @MainActor
    func showAbout() {
        let state = AppState.shared
        let engine = state.controller
        let installed = state.installedEngineIDs
            .map {
                EngineInstallations.newest($0, version: nil).map { "\($0.id.displayName) \($0.manifest.version)" }
                    ?? $0.displayName
            }
            .joined(separator: "、")
        let alert = NSAlert()
        alert.messageText = "flashCat"
        alert.informativeText = L10n.format(
            "本地推理控制台 · v%@\n当前引擎：%@\n已安装：%@\n模型目录：%@",
            splashVersion,
            engine.map { "\($0.id.displayName) \($0.installation.version)" } ?? L10n.t("未选择"),
            installed.isEmpty ? L10n.t("无") : installed,
            EnginePaths.modelsRoot
        )
        alert.runModal()
    }
}
