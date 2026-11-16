// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Combine
import FlashCatKit
import SwiftUI

// MARK: - 主窗口

/// 主窗口的唯一入口。
///
/// 菜单栏面板由独立 `NSPanel` 承载（不在 SwiftUI 场景树里），因此不能直接用
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

// MARK: - 浮层控制状态

/// 驱动菜单栏浮层的显隐与进出场弹簧动画。
@MainActor
final class MenuBarPanelPresenter: ObservableObject {
    @Published var isPresented = false
}

/// 菜单栏专用无边框浮层窗口：
/// - `.nonactivatingPanel`：点击菜单栏图标不会强行激活主窗口或切换桌面空间；
/// - `canBecomeKey = true`：支持 Esc 关闭与失焦自动收起，同时保持不抢主应用焦点。
private final class MenuBarFloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - 菜单栏常驻项

/// 系统菜单栏的常驻入口：native `NSStatusItem` + 自定义无边框 `NSPanel`。
///
/// 相比系统 `NSPopover`：
/// 1. 去掉笨重的系统箭头与磨砂边框，直接复用应用的 `DS` 精密仪器浮层视觉；
/// 2. 展开/收起由 SwiftUI 弹簧曲线驱动，内部高度变化时顶部锚点锁定、平滑过渡；
/// 3. 点击 `.leftMouseDown` 即刻响应且不抢主窗口焦点，右键提供快捷上下文菜单。
@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {
    private enum Metrics {
        static let cardWidth: CGFloat = 356
        static let shadowHorizontal: CGFloat = 22
        static let shadowTop: CGFloat = 8
        static let shadowBottom: CGFloat = 28
        static let panelWidth: CGFloat = cardWidth + shadowHorizontal * 2
        static let screenEdgeMargin: CGFloat = 10
        static let menuBarGap: CGFloat = 6
        static let closeDuration: TimeInterval = 0.20
    }

    private let state: AppState
    private let statusItem: NSStatusItem
    private let presenter = MenuBarPanelPresenter()
    private let panel: MenuBarFloatingPanel
    private var hostingController: NSHostingController<MenuBarPanelContainer>?

    private var cancellables = Set<AnyCancellable>()
    private var pendingOrderOut: DispatchWorkItem?
    private var anchorTopY: CGFloat = 0
    private var currentCardHeight: CGFloat = 340
    private var lastResignUptime: TimeInterval = 0

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.panel = MenuBarFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 380),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        configureStatusButton()
        configurePanel()
        observeState()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = MenuBarIcon.statusImage(state: state.serverState)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(handleStatusClick)
        button.sendAction(on: [.leftMouseDown, .rightMouseUp])
        button.toolTip = "flashCat · \(L10n.t(state.serverState.rawValue))"
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        panel.appearance = state.theme.resolvedAppearance
        panel.onCancel = { [weak self] in
            self?.dismiss(animated: true)
        }

        let root = MenuBarPanelContainer(
            state: state,
            presenter: presenter,
            cardWidth: Metrics.cardWidth,
            shadowInsets: EdgeInsets(
                top: Metrics.shadowTop,
                leading: Metrics.shadowHorizontal,
                bottom: Metrics.shadowBottom,
                trailing: Metrics.shadowHorizontal
            ),
            onOpenMainWindow: { [weak self] targetPage in
                self?.dismiss(animated: true)
                if let targetPage {
                    self?.state.section = targetPage
                }
                MainWindow.show()
            },
            onDismiss: { [weak self] in
                self?.dismiss(animated: true)
            },
            onCardHeightChange: { [weak self] newHeight in
                self?.updatePanelHeight(cardHeight: newHeight)
            }
        )

        let hosting = NSHostingController(rootView: root)
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentViewController = hosting
        self.hostingController = hosting
    }

    private func observeState() {
        // 状态变化时换图标：运行中实心、过渡态压暗、停止描边、异常带告警点。
        // 服务状态已经搬进 `EngineSessionStore`；这里和下面 `theme.$mode` 一样，
        // 直接取 store 的发布者，避免为一个发布者在 AppState 上再开一条转发。
        state.engineSession.$serverState
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                guard let self else { return }
                self.statusItem.button?.image = MenuBarIcon.statusImage(state: newState)
                self.statusItem.button?.toolTip = "flashCat · \(L10n.t(newState.rawValue))"
            }
            .store(in: &cancellables)

        // 跟随应用皮肤与系统外观变化，确保浮层始终与主窗口一致。
        state.theme.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncAppearance()
            }
            .store(in: &cancellables)

        DistributedNotificationCenter.default()
            .publisher(for: NSNotification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncAppearance()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.dismiss(animated: false)
            }
            .store(in: &cancellables)
    }

    private func syncAppearance() {
        panel.appearance = state.theme.resolvedAppearance
    }

    // MARK: - 点击与菜单

    @objc private func handleStatusClick() {
        guard let button = statusItem.button else { return }

        if let event = NSApp.currentEvent,
            event.type == .rightMouseUp || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        {
            if presenter.isPresented {
                dismiss(animated: false)
            }
            showContextMenu(from: button)
            return
        }

        if presenter.isPresented {
            dismiss(animated: true)
            return
        }

        // 若刚刚因点击状态栏按钮触发了 windowDidResignKey 收起，避免同一点击立刻重开。
        if ProcessInfo.processInfo.systemUptime - lastResignUptime < 0.22 {
            return
        }

        showPanel(relativeTo: button)
    }

    private func showPanel(relativeTo button: NSStatusBarButton) {
        pendingOrderOut?.cancel()
        pendingOrderOut = nil

        syncAppearance()
        positionPanel(relativeTo: button)

        presenter.isPresented = false
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            withAnimation(DS.Motion.snappy) {
                self.presenter.isPresented = true
            }
        }
    }

    private func dismiss(animated: Bool) {
        pendingOrderOut?.cancel()
        pendingOrderOut = nil
        statusItem.button?.highlight(false)

        guard panel.isVisible else {
            presenter.isPresented = false
            return
        }

        if animated {
            withAnimation(DS.Motion.snappy) {
                presenter.isPresented = false
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.presenter.isPresented else { return }
                self.panel.orderOut(nil)
            }
            pendingOrderOut = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.closeDuration, execute: work)
        } else {
            presenter.isPresented = false
            panel.orderOut(nil)
        }
    }

    private func positionPanel(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenRect = buttonWindow.convertToScreen(buttonRectInWindow)
        let screenFrame =
            (buttonWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let totalHeight = max(220, currentCardHeight + Metrics.shadowTop + Metrics.shadowBottom)
        let topY = buttonScreenRect.minY - Metrics.menuBarGap + Metrics.shadowTop
        anchorTopY = topY

        var originX = buttonScreenRect.midX - Metrics.panelWidth / 2
        let minOriginX = screenFrame.minX + Metrics.screenEdgeMargin - Metrics.shadowHorizontal
        let maxOriginX = screenFrame.maxX - Metrics.screenEdgeMargin + Metrics.shadowHorizontal - Metrics.panelWidth
        originX = min(max(originX, minOriginX), maxOriginX)

        let frame = NSRect(
            x: round(originX),
            y: round(topY - totalHeight),
            width: Metrics.panelWidth,
            height: round(totalHeight)
        )
        panel.setFrame(frame, display: true)
    }

    private func updatePanelHeight(cardHeight: CGFloat) {
        guard cardHeight > 80 else { return }
        let rounded = ceil(cardHeight)
        guard abs(rounded - currentCardHeight) > 0.5 else { return }
        currentCardHeight = rounded

        guard panel.isVisible, anchorTopY > 0 else { return }
        let totalHeight = rounded + Metrics.shadowTop + Metrics.shadowBottom
        var frame = panel.frame
        frame.origin.y = round(anchorTopY - totalHeight)
        frame.size.height = round(totalHeight)
        panel.setFrame(frame, display: true, animate: false)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard presenter.isPresented else { return }
        lastResignUptime = ProcessInfo.processInfo.systemUptime
        dismiss(animated: true)
    }

    // MARK: - 右键快捷菜单

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let statusTitle = "flashCat · \(L10n.t(state.serverState.rawValue))"
        let headerItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        if state.isRunning {
            let stopItem = NSMenuItem(title: L10n.t("停止服务"), action: #selector(menuStopService), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)

            let restartItem = NSMenuItem(
                title: L10n.t("重启服务"), action: #selector(menuRestartService), keyEquivalent: "")
            restartItem.target = self
            menu.addItem(restartItem)
        } else {
            let startItem = NSMenuItem(title: L10n.t("启动服务"), action: #selector(menuStartService), keyEquivalent: "")
            startItem.target = self
            menu.addItem(startItem)
        }

        let copyItem = NSMenuItem(title: L10n.t("复制接口地址"), action: #selector(menuCopyEndpoint), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: L10n.t("打开主窗口"), action: #selector(menuOpenMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let quitItem = NSMenuItem(title: L10n.t("退出 flashCat"), action: #selector(menuQuitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuStartService() { state.startService() }
    @objc private func menuStopService() { state.stopService() }
    @objc private func menuRestartService() { state.restartService() }
    @objc private func menuCopyEndpoint() { state.copy(state.endpointURL, label: "接口地址已复制") }
    @objc private func menuOpenMainWindow() { MainWindow.show() }
    @objc private func menuQuitApp() { NSApp.terminate(nil) }
}
