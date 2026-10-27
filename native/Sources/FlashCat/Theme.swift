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

    init(settings: AppSettings) {
        self.settings = settings
        self.mode = settings.appearance
        AppAppearance.current = mode
        observeSystemAppearance()
    }

    deinit {
        if let themeObserver { DistributedNotificationCenter.default().removeObserver(themeObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
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
    private var resolved: NSAppearance? {
        switch mode {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return NSAppearance(named: AppAppearance.systemIsDark ? .darkAqua : .aqua)
        }
    }

    /// Applies the choice to the whole app: AppKit-backed controls, the SwiftUI
    /// canvas (whose `colorScheme` derives from the window) and the canvas colour
    /// behind the hidden title bar.
    func apply() {
        AppAppearance.current = mode
        NSApp.appearance = resolved
        for window in NSApp.windows where window.canBecomeMain {
            apply(to: window)
        }
    }

    func apply(to window: NSWindow) {
        window.appearance = resolved
        window.backgroundColor = Native.windowBackground
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
    }

    private func refreshSystemAppearance() {
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
