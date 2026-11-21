// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import SwiftUI

// MARK: - Appearance
//
// The console ships two skins — the original near-black night look and a light
// daylight look built from the same layout, key art and spacing. `AppAppearance`
// is what the user picks; everything else in the app reads the dynamic colours in
// `Native`, which resolve per appearance. That means no view has to know which
// skin is on screen: set the content view's appearance and the whole canvas
// re-resolves. The window itself stays Aqua — see `ThemeController.apply(to:)`
// for why the skin never touches the window appearance.

/// User-facing appearance choice. Persisted by `AppSettings`, applied to AppKit by
/// `ThemeController` so AppKit-backed controls (rounded text fields, menus,
/// switches) flip together with the SwiftUI canvas.
enum AppAppearance: Int, CaseIterable, Identifiable, Hashable {
    case system = 0
    case light = 1
    case dark = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var detail: String {
        switch self {
        case .system: return "随 macOS 外观自动切换日间 / 夜间皮肤"
        case .light: return "始终使用日间皮肤"
        case .dark: return "始终使用夜间皮肤"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    /// Whether macOS itself is in dark mode, before any in-app override.
    /// Reading `NSApp.effectiveAppearance` here would echo back whatever
    /// override is installed (and stays stale for a moment after clearing it),
    /// so the system-wide setting is read straight from the global defaults.
    @MainActor static var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    @MainActor var resolvedIsDark: Bool {
        switch self {
        case .light: return false
        case .dark: return true
        case .system: return AppAppearance.systemIsDark
        }
    }
}

// MARK: - Controller

/// Owns the appearance choice: persists it, applies it to AppKit, and publishes the
/// change so the settings UI can highlight the selected option.
@MainActor
final class ThemeController: ObservableObject {
    @Published private(set) var mode: AppAppearance
    /// 系统当前是不是深色。跟随系统时皮肤由它决定；发布出来还有第二个用处：
    /// 换肤时 SwiftUI 能跟着重画，不必等窗口激活事件把整棵树叫醒。
    @Published private(set) var systemIsDark: Bool

    private let settings: AppSettings
    /// Observation tokens are written on the main actor and read once in
    /// `deinit`, where no other reference exists. `nonisolated(unsafe)` is the
    /// narrow promise that lets the nonisolated deinit unregister them without
    /// a Swift 6 data-race diagnostic.
    ///
    /// macOS posts this when the reader flips the system appearance.
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?
    /// sheet / 提示框是独立窗口，出现那一刻还没有外观（`appearance == nil`），
    /// 会按主窗口的浅色外观画成浅色。AppKit 没有"子窗口已挂上"的公开通知
    /// （`willBeginSheetNotification` 发得太早，`attachedSheet` 还是 nil），
    /// 所以在每个 update 循环末尾补一次：只挑真正没皮肤的 sheet 窗口。
    nonisolated(unsafe) private var sheetObserver: NSObjectProtocol?

    init(settings: AppSettings) {
        self.settings = settings
        self.mode = settings.appearance
        self.systemIsDark = AppAppearance.systemIsDark
        AppAppearance.current = mode
        observeSystemAppearance()
    }

    deinit {
        if let themeObserver { DistributedNotificationCenter.default().removeObserver(themeObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
    }

    func set(_ value: AppAppearance) {
        guard value != mode else { return }
        mode = value
        AppAppearance.current = value
        settings.appearance = value
        apply()
    }

    /// 当前皮肤是不是深色。跟随系统时读的是发布出来的 `systemIsDark`，
    /// 而不是现场去翻系统默认值——换肤时要的是"这次通知里的系统状态"。
    var isDark: Bool {
        switch mode {
        case .light: return false
        case .dark: return true
        case .system: return systemIsDark
        }
    }

    /// 复用的外观实例。每次切换都新建 `NSAppearance(name:)` 会迫使窗口
    /// 重新解析整棵树，窗口从后台回到前台时甚至会让 SwiftUI 重排一次，
    /// 表现为界面整体上移。这里固定两个实例，只在真正换皮肤时赋值。
    private static let aquaAppearance = NSAppearance(named: .aqua)
    private static let darkAppearance = NSAppearance(named: .darkAqua)

    /// 皮肤本身的外观。它落在 contentView 上，而不是窗口上：窗口外观决定的是
    /// 系统画的那层 chrome（红绿灯、投影），见 `apply(to:)`。
    var skinAppearance: NSAppearance? {
        isDark ? Self.darkAppearance : Self.aquaAppearance
    }

    /// Applies the choice to the app's windows: AppKit-backed controls, the
    /// SwiftUI canvas (whose `colorScheme` derives from the content view's
    /// appearance) and the canvas colour behind the hidden title bar.
    ///
    /// 刻意**不设** `NSApp.appearance`：全局外观会把菜单栏常驻项也染成皮肤色，
    /// 浅色菜单栏项落在深色菜单栏上时，系统会给它补一块浅色底板（图标因此带
    /// 白底）。菜单栏图标应当始终跟随系统菜单栏着色，所以皮肤只作用到窗口。
    func apply() {
        AppAppearance.current = mode
        for window in NSApp.windows where window.canBecomeMain || window.sheetParent != nil {
            apply(to: window)
        }
    }

    /// 当前皮肤对应的具体外观，供 popover 这类不在窗口列表里的界面使用。
    var resolvedAppearance: NSAppearance? { skinAppearance }

    func apply(to window: NSWindow) {
        if window.canBecomeMain, window is NSPanel == false {
            // 窗口自己恒定用浅色外观。WindowServer 是按窗口外观画投影的：同一个
            // 窗口切成 darkAqua 后，投影贴边处几乎全黑、扩散距离也翻倍（实测
            // 边缘 alpha 247 对 121），铺在浅色桌面上就是用户看到的那圈黑影。
            // 窗口外观回到浅色后投影恢复正常，而皮肤照旧由 contentView 承担——
            // 深色皮肤下 AppKit / SwiftUI 的颜色仍然按深色解析。
            if window.appearance !== Self.aquaAppearance {
                window.appearance = Self.aquaAppearance
            }
            let skin = skinAppearance
            if window.contentView?.appearance !== skin {
                window.contentView?.appearance = skin
            }
            // 主窗口始终保持不透明纯实色 ZCode 画布，底色随 contentView 外观同步更新。
            BackgroundSurface.shared.applyWindowSurface(to: window)
        } else if window.appearance !== skinAppearance {
            // sheet / 提示框这类独立窗口没有承载皮肤的层级，也不跟主窗口共享
            // 外观：只换它自己的外观，画布色留给系统——把窗口背景染成主窗口的
            // 颜色会把系统给 sheet 的圆角和材质盖掉。
            window.appearance = skinAppearance
        }
    }

    /// Keeps "跟随系统" honest: re-resolve when macOS flips, and (as a backstop
    /// for a missed notification) whenever the app comes back to the front.
    private func observeSystemAppearance() {
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemAppearance() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemAppearance() }
        }
        sheetObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.skinUnstyledSheets() }
        }
    }

    /// 给刚出现、还没套皮肤的 sheet 窗口补上外观。判断条件只有两个属性，
    /// 主窗口每帧扫一遍可以忽略不计；套过一次之后 `appearance` 就不再是
    /// nil，不会重复进入。
    private func skinUnstyledSheets() {
        for window in NSApp.windows where window.sheetParent != nil && window.appearance == nil {
            apply(to: window)
        }
    }

    private func refreshSystemAppearance() {
        // 系统状态变了就先记下来：既让跟随系统这一档立刻换肤，也让之后切回
        // 「跟随系统」时手上已经是最新的系统状态，不必再等一次通知。
        let dark = AppAppearance.systemIsDark
        if dark != systemIsDark {
            systemIsDark = dark
        }
        guard mode == .system else { return }
        apply()
    }
}

extension AppAppearance {
    /// Last applied choice, for the rare call site that needs to branch on the
    /// skin (key art keeps white type in both, but a few overlays differ).
    @MainActor static var current: AppAppearance = .system

    @MainActor static var isDark: Bool { current.resolvedIsDark }
}

// MARK: - Dynamic colour

extension NSColor {
    /// A colour that resolves against the *current* appearance every time AppKit
    /// asks for it, instead of freezing to whatever was active at creation time.
    static func adaptive(
        dark: UInt32,
        light: UInt32,
        darkAlpha: Double = 1,
        lightAlpha: Double = 1
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) != .aqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha)
        }
    }

    /// Translucent overlay that flips with the skin: white over the night canvas,
    /// near-black over the daylight one. Keeps relative emphasis identical.
    static func adaptiveOverlay(_ opacity: Double) -> NSColor {
        adaptive(dark: 0xFFFFFF, light: 0x101014, darkAlpha: opacity, lightAlpha: opacity)
    }

    /// 控制台正文与强调色。SwiftUI 侧的 `DS.text` / `DS.accent`
    /// 就是这两个颜色的包装，因此 AppKit 文本宿主（对话输入框）和卡片是同一组值。
    /// 配色对齐 ZCode（Zai Dark / Zai Light）。
    static let consoleText = adaptive(dark: 0xEDEDED, light: 0x262626)
    static let consoleAccent = adaptive(dark: 0x3B82F6, light: 0x0B7FFF)
}

extension Color {
    static func adaptive(
        dark: UInt32,
        light: UInt32,
        darkAlpha: Double = 1,
        lightAlpha: Double = 1
    ) -> Color {
        Color(
            nsColor: NSColor.adaptive(
                dark: dark, light: light,
                darkAlpha: darkAlpha, lightAlpha: lightAlpha))
    }

    /// See `NSColor.adaptiveOverlay(_:)`.
    static func adaptiveOverlay(_ opacity: Double) -> Color {
        Color(nsColor: NSColor.adaptiveOverlay(opacity))
    }
}
