import SwiftUI
import AppKit

// MARK: - Appearance
//
// The console ships two skins — the original near-black night look and a light
// daylight look built from the same layout, key art and spacing. `AppAppearance`
// is what the user picks; everything else in the app reads the dynamic colours in
// `Native`, which resolve per appearance. That means no view has to know which
// skin is on screen: flip `NSApp.appearance` and the whole canvas re-resolves.

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

    private let settings: AppSettings
    /// macOS posts this when the reader flips the system appearance; the app is
    /// no longer following `nil` (see `resolved`), so it has to listen.
    private var themeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    /// 桌面壁纸变化没有一个稳定的公开通知名，但系统实际会广播这个；
    /// 监听它只是为了在壁纸切换后强制窗口重画，避免透明/玻璃层留下残影。
    private var desktopObserver: NSObjectProtocol?

    init(settings: AppSettings) {
        self.settings = settings
        self.mode = settings.appearance
        AppAppearance.current = mode
        observeSystemAppearance()
    }

    deinit {
        if let themeObserver { DistributedNotificationCenter.default().removeObserver(themeObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let desktopObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(desktopObserver)
        }
    }

    func set(_ value: AppAppearance) {
        guard value != mode else { return }
        mode = value
        AppAppearance.current = value
        settings.appearance = value
        apply()
    }

    /// The skin to hand AppKit. `.system` is resolved to a concrete light / dark
    /// appearance instead of `nil` (which would mean "ask macOS"): clearing an
    /// override does not repaint a running app — the window keeps the skin it
    /// already draws until the next activation change, which is why "跟随系统"
    /// used to take effect only after clicking outside the app. A concrete value
    /// repaints on assignment, in either direction.
    /// 复用的外观实例。每次切换都新建 `NSAppearance(name:)` 会迫使窗口
    /// 重新解析整棵树，窗口从后台回到前台时甚至会让 SwiftUI 重排一次，
    /// 表现为界面整体上移。这里固定两个实例，只在真正换皮肤时赋值。
    private static let aquaAppearance = NSAppearance(named: .aqua)
    private static let darkAppearance = NSAppearance(named: .darkAqua)
    private static let canvasColor = NSColor.adaptive(dark: 0x14131A, light: 0xEAEEF7)

    private var resolved: NSAppearance? {
        switch mode {
        case .light: return Self.aquaAppearance
        case .dark: return Self.darkAppearance
        case .system: return AppAppearance.systemIsDark ? Self.darkAppearance : Self.aquaAppearance
        }
    }

    /// Applies the choice to the app's windows: AppKit-backed controls, the
    /// SwiftUI canvas (whose `colorScheme` derives from the window) and the
    /// canvas colour behind the hidden title bar.
    ///
    /// 刻意**不设** `NSApp.appearance`：全局外观会把菜单栏常驻项也染成皮肤色，
    /// 浅色菜单栏项落在深色菜单栏上时，系统会给它补一块浅色底板（图标因此带
    /// 白底）。菜单栏图标应当始终跟随系统菜单栏着色，所以皮肤只作用到窗口。
    func apply() {
        AppAppearance.current = mode
        for window in NSApp.windows where window.canBecomeMain {
            apply(to: window)
        }
    }

    /// 当前皮肤对应的具体外观，供 popover 这类不在窗口列表里的界面使用。
    var resolvedAppearance: NSAppearance? { resolved }

    func apply(to window: NSWindow) {
        let appearance = resolved
        if window.appearance !== appearance {
            window.appearance = appearance
        }
        // 没有自定义图片时，透明度滑杆代表「透出桌面」。此时窗口需要非不透明，
        // 但必须由全窗口的 NSVisualEffectView 兜底（见 DesktopBackdrop），
        // 否则切换壁纸/外观后会残留旧画面。有图片时保持不透明画布，
        // 避免桌面和图片叠在一起。
        let revealsDesktop = BackgroundSettings.shared.revealsDesktop
        if window.isOpaque == revealsDesktop {
            window.isOpaque = !revealsDesktop
        }
        let targetColor: NSColor = revealsDesktop ? .clear : Self.canvasColor
        if window.backgroundColor != targetColor {
            window.backgroundColor = targetColor
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
        desktopObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSNotification.Name("NSWorkspaceDesktopImageChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWindowSurface() }
        }
    }

    private func refreshSystemAppearance() {
        guard mode == .system else { return }
        apply()
    }

    /// 壁纸切换后让主窗口重新解析外观并重排一次，清掉窗口服务器留下的旧画面。
    private func refreshWindowSurface() {
        for window in NSApp.windows where window.canBecomeMain {
            apply(to: window)
            window.contentView?.needsLayout = true
            window.contentView?.needsDisplay = true
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
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
    static func adaptive(dark: UInt32,
                         light: UInt32,
                         darkAlpha: Double = 1,
                         lightAlpha: Double = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) != .aqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
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
}

extension Color {
    static func adaptive(dark: UInt32,
                         light: UInt32,
                         darkAlpha: Double = 1,
                         lightAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor.adaptive(dark: dark, light: light,
                                        darkAlpha: darkAlpha, lightAlpha: lightAlpha))
    }

    /// See `NSColor.adaptiveOverlay(_:)`.
    static func adaptiveOverlay(_ opacity: Double) -> Color {
        Color(nsColor: NSColor.adaptiveOverlay(opacity))
    }
}
