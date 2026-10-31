import SwiftUI
import AppKit

@main
struct FlashCatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Scene 层的 `if state.isPresentingLaunchPage` 依赖这里的状态订阅：
    // 普通 let 不会让 SwiftUI 重新求值 body，点击「开始使用」就永远切不进控制台。
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        Window("flashCat", id: "main") {
            // SwiftUI 只当壳：窗口内容（含启动页）全部是 WebUI 网页。
            webConsole
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 flashCat") { delegate.showAbout() }
            }
            CommandGroup(after: .newItem) {
                Button("打开对话") { state.section = .chat }
                    .keyboardShortcut("o", modifiers: .command)
                Button("新建对话") { state.newConversation() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("服务") {
                Button("启动服务") { state.startService() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(state.isRunning)
                Button("停止服务") { state.stopService() }
                    .disabled(!state.isRunning)
                Button("重启服务") { state.restartService() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!state.isRunning)
                Divider()
                Button("复制接口地址") { state.copy(state.endpointURL, label: "接口地址已复制") }
                Button("打开日志文件") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Paths.logFile))
                }
            }
            CommandMenu("页面") {
                Button("概览") { state.section = .overview }.keyboardShortcut("1", modifiers: .command)
                Button("对话") { state.section = .chat }.keyboardShortcut("2", modifiers: .command)
                Button("模型") { state.section = .models }.keyboardShortcut("3", modifiers: .command)
                Button("引擎") { state.section = .engines }.keyboardShortcut("4", modifiers: .command)
                Button("日志") { state.section = .logs }.keyboardShortcut("5", modifiers: .command)
                Button("设置") { state.section = .settings }.keyboardShortcut("6", modifiers: .command)
                Divider()
                Button(state.showsSidebar ? "折叠侧边栏" : "展开侧边栏") { state.toggleSidebar() }
                    .keyboardShortcut("\\", modifiers: .command)
            }
        }

    }

    /// WebUI 控制台壳：启动页、下载中心、引擎配置、确认弹窗都在网页里渲染，
    /// 窗口内不再挂任何原生 sheet / alert。
    private var webConsole: some View {
        WebViewShell(state: state)
            .overlay(MainWindow.bridge())
            // 网页自己画标题栏那一行（红绿灯 + 侧栏折叠手柄）：不忽略安全区，
            // WebView 会被压到 28pt 的原生 titlebar 下面，网页永远没法跟红绿灯对齐。
            .ignoresSafeArea()
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
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for target in NSApp.windows { self.configure(target) }
            }
        }
    }

    private func configure(_ target: NSWindow) {
        // 只处理主窗口。状态栏项的按钮也活在一个内部窗口里（层级更高的 panel），
        // 给它套主窗口的外观和标题栏设置，会让系统给菜单栏图标补一块浅色底板。
        guard target.canBecomeMain, target is NSPanel == false else { return }
        target.title = "flashCat"
        target.titleVisibility = .hidden
        target.titlebarAppearsTransparent = true
        target.styleMask.insert(.fullSizeContentView)
        // The window paints its own chrome: the system toolbar's translucent
        // titlebar strip would otherwise sit above the sidebar artwork and pick
        // up the desktop tint, breaking the seamless dark sidebar.
        target.toolbar = nil
        target.titlebarSeparatorStyle = .none
        target.isMovableByWindowBackground = false
        // Both the canvas colour and the appearance follow the selected skin so
        // the strip above the sidebar matches instead of flashing dark.
        AppState.shared.theme.apply(to: target)
        target.contentMinSize = NSSize(width: 1040, height: 700)
        if target.frameAutosaveName.isEmpty {
            target.setFrameAutosaveName("flashCatWindow")
            target.setContentSize(NSSize(width: 1280, height: 820))
            target.center()
        }
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
        let state = AppState.shared
        state.gateway.stop()
        state.controller?.dispose()
    }

    @MainActor
    func showAbout() {
        let state = AppState.shared
        let engine = state.controller
        let installed = state.installedEngineIDs
            .map { EngineInstallations.newest($0, version: nil).map { "\($0.id.displayName) \($0.manifest.version)" } ?? $0.displayName }
            .joined(separator: "、")
        let alert = NSAlert()
        alert.messageText = "flashCat"
        alert.informativeText = """
        本地推理控制台 · v\(SPLASH_VERSION)
        当前引擎：\(engine.map { "\($0.id.displayName) \($0.installation.version)" } ?? "未选择")
        已安装：\(installed.isEmpty ? "无" : installed)
        模型目录：\(Paths.modelsDirectory)
        """
        alert.runModal()
    }
}
