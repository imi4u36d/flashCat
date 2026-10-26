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
        .defaultSize(width: 1180, height: 780)
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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.bootstrap()

        for target in NSApp.windows {
            configure(target)
        }
        // SwiftUI creates the window after the delegate in some builds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            for target in NSApp.windows { self.configure(target) }
        }
    }

    private func configure(_ target: NSWindow) {
        target.title = "flashCat"
        target.contentMinSize = NSSize(width: 980, height: 660)
        if target.frameAutosaveName.isEmpty {
            target.setFrameAutosaveName("flashCatWindow")
            target.setContentSize(NSSize(width: 1180, height: 780))
            target.center()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppState.shared.controller?.dispose()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.controller?.dispose()
    }

    @MainActor
    func showAbout() {
        let version = AppState.shared.runtime?.version ?? SPLASH_VERSION
        let alert = NSAlert()
        alert.messageText = "flashCat"
        alert.informativeText = """
        本地推理控制台 · v\(SPLASH_VERSION)
        运行时：splash \(version)
        模型目录：\(Paths.modelsDirectory)
        """
        alert.runModal()
    }
}
