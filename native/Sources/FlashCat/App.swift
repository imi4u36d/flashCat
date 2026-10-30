import SwiftUI
import AppKit

@main
struct FlashCatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let state = AppState.shared

    var body: some Scene {
        Window("flashCat", id: "main") {
            ShellView(state: state)
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
                Button("日志") { state.section = .logs }.keyboardShortcut("4", modifiers: .command)
                Button("设置") { state.section = .settings }.keyboardShortcut("5", modifiers: .command)
                Divider()
                Button("折叠/展开侧边栏") { state.toggleSidebar() }
                    .keyboardShortcut("\\", modifiers: .command)
            }
        }

        // 系统菜单栏常驻入口：点击弹出当前模型与运行信息面板。
        MenuBarExtra {
            MenuBarPanel(state: state)
        } label: {
            MenuBarStatusLabel(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply the stored skin before anything paints: `nil` appearance means
        // "follow macOS", so the app opens in whatever the reader picked.
        let state = AppState.shared
        state.theme.apply()
        state.bootstrap()

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
