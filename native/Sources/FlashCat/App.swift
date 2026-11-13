import SwiftUI
import AppKit
import FlashCatKit

private enum MainWindowGeometry {
    static let defaultSize = NSSize(width: 1280, height: 820)
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

    var body: some Scene {
        Window("flashCat", id: "main") {
            // 窗口内容全部是 SwiftUI 原生视图（含启动页），没有网页层。
            console
        }
        .defaultSize(width: MainWindowGeometry.defaultSize.width,
                     height: MainWindowGeometry.defaultSize.height)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 flashCat") { delegate.showAbout() }
            }
            // 应用不注册任何键盘快捷键：每个动作都有可点击的菜单项或按钮，
            // 键盘用户通过随应用安装的 `flashcat` 命令行完成同样的事。
            CommandGroup(after: .newItem) {
                Button("打开对话") { state.section = .chat }
                Button("新建对话") { state.newConversation() }
            }
            CommandMenu("服务") {
                Button("启动服务") { state.startService() }
                    .disabled(state.isRunning)
                Button("停止服务") { state.stopService() }
                    .disabled(!state.isRunning)
                Button("重启服务") { state.restartService() }
                    .disabled(!state.isRunning)
                Divider()
                Button("复制接口地址") { state.copy(state.endpointURL, label: "接口地址已复制") }
                Button("打开日志文件") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Paths.logFile))
                }
            }
            // 标准「显示 / 隐藏边栏」菜单位置；不带按键，点击即执行。
            CommandGroup(after: .sidebar) {
                Button(L10n.t(state.showsSidebar ? "隐藏边栏" : "显示边栏")) {
                    state.toggleSidebar()
                }
                Button("切换浅色 / 深色") {
                    state.theme.set(state.theme.mode.resolvedIsDark ? .light : .dark)
                }
            }
            CommandMenu("页面") {
                Button("命令面板") {
                    NotificationCenter.default.post(name: .flashCatOpenCommandPalette, object: nil)
                }
                Divider()
                Button("概览") { state.section = .overview }
                Button("对话") { state.section = .chat }
                Button("模型") { state.section = .models }
                Button("引擎") { state.section = .engines }
                Button("日志") { state.section = .logs }
                Button("设置") { state.section = .settings }
                Button("实验室") { state.section = .lab }
            }
        }

    }

    /// 原生控制台：六个页面、启动页、下载中心、引擎配置与确认弹窗都是
    /// SwiftUI / AppKit 视图。
    private var console: some View {
        ConsoleView(state: state)
            .frame(minWidth: MainWindowGeometry.minimumSize.width,
                   minHeight: MainWindowGeometry.minimumSize.height)
            .overlay(MainWindow.bridge())
            // 原生视图自己排标题栏那一行（红绿灯留白 + 侧栏折叠手柄），
            // 因此要吃掉安全区，让内容从窗口最顶端开始画。
            .ignoresSafeArea()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 常驻菜单栏项。必须由 AppDelegate 强引用持有，否则状态栏项会被回收。
    private var statusBar: StatusBarController?
    /// 红绿灯的默认位置，只记录一次；重复 configure 不会把按钮越推越远。
    private var trafficLightOrigins: [Int: NSPoint] = [:]

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
        // 缩放窗口时 AppKit 会重新排红绿灯，重新套一次偏移。
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.offsetTrafficLights(in: window) }
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
        // 登记主窗口：之后透明度 / 模糊一变，窗口表面立刻跟着变，不再等
        // 某个视图碰巧重建（见 BackgroundSurface）。
        BackgroundSurface.shared.attach(window: target)
        // The console has a compact layout down to this point. Below it the
        // navigation rail and one-column content no longer have a stable
        // readable width, so stop the window instead of letting it collapse
        // into a stack of clipped cards.
        let minimumWindowSize = MainWindowGeometry.minimumSize
        target.minSize = minimumWindowSize
        target.contentMinSize = minimumWindowSize
        if target.frameAutosaveName.isEmpty {
            target.setFrameAutosaveName("flashCatWindow")
            target.setContentSize(MainWindowGeometry.defaultSize)
            target.center()
        } else if target.frame.width < minimumWindowSize.width
                    || target.frame.height < minimumWindowSize.height {
            // Older builds allowed the window to be shrunk below the layout's
            // floor. Recover to a usable size the next time the app launches.
            target.setContentSize(
                NSSize(width: max(target.contentLayoutRect.width, MainWindowGeometry.defaultSize.width),
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
        offsetTrafficLights(in: target)
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
        let size = NSSize(width: min(max(frame.width, MainWindowGeometry.minimumSize.width), visible.width),
                          height: min(max(frame.height, MainWindowGeometry.minimumSize.height), visible.height))
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// 红绿灯往右下挪 6pt，让自绘标题栏可以稍微离开窗口上沿，
    /// 同时保持和红绿灯同一水平线。
    private func offsetTrafficLights(in window: NSWindow) {
        guard window.canBecomeMain, window is NSPanel == false else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in types.enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            if trafficLightOrigins[index] == nil {
                trafficLightOrigins[index] = button.frame.origin
            }
            guard let origin = trafficLightOrigins[index] else { continue }
            let dy: CGFloat = button.superview?.isFlipped == true ? 6 : -6
            button.setFrameOrigin(NSPoint(x: origin.x + 6, y: origin.y + dy))
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
            .map { EngineInstallations.newest($0, version: nil).map { "\($0.id.displayName) \($0.manifest.version)" } ?? $0.displayName }
            .joined(separator: "、")
        let alert = NSAlert()
        alert.messageText = "flashCat"
        alert.informativeText = L10n.format(
            "本地推理控制台 · v%@\n当前引擎：%@\n已安装：%@\n模型目录：%@",
            SPLASH_VERSION,
            engine.map { "\($0.id.displayName) \($0.installation.version)" } ?? L10n.t("未选择"),
            installed.isEmpty ? L10n.t("无") : installed,
            EnginePaths.modelsRoot
        )
        alert.runModal()
    }
}
