// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import SwiftUI

/// 主题控制器：管理「跟随系统 / 日间 / 夜间」外观选择、
/// 主题色预设 / 自定义种子，并应用到主窗口与弹层。
@MainActor
final class ThemeController: ObservableObject {
    @Published private(set) var mode: AppAppearance
    /// 系统当前是不是深色，供跟随系统时驱动 SwiftUI 重解动态颜色。
    @Published private(set) var systemIsDark: Bool
    /// 当前主题色预设。`.custom` 用 `customSeed` 推导。
    @Published private(set) var preset: ThemePreset
    /// 自定义主题色的种子；选预设时保留，方便回到自定义。
    @Published private(set) var customSeed: UInt32?
    /// accent 家族每次变化都自增；根视图与菜单栏面板据此重绘。
    @Published private(set) var paletteRevision = 0
    /// 当前运行的 accent 家族；`DS` 的 accent token 从这里取。
    private(set) var palette: ThemePalette

    private let settings: AppSettings
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?

    init(settings: AppSettings) {
        let storedPreset = settings.themePreset
        let storedSeed = settings.themeSeed == 0 ? nil : settings.themeSeed
        let resolvedPreset: ThemePreset =
            (storedPreset == .custom && storedSeed == nil) ? .iconOrange : storedPreset

        self.settings = settings
        self.mode = settings.appearance
        self.systemIsDark = AppAppearance.systemIsDark
        self.preset = resolvedPreset
        self.customSeed = storedSeed
        self.palette = ThemePalette.resolve(preset: resolvedPreset, customSeed: storedSeed)
        ThemeRuntime.palette = palette
        if resolvedPreset != storedPreset {
            settings.setThemePreset(resolvedPreset)
        }
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

    func toggleLightDark() {
        set(isDark ? .light : .dark)
    }

    // MARK: Theme colour

    /// 取色器 / 色点当前应显示的种子色。
    var seedColor: Color {
        switch preset {
        case .iconOrange:
            return ThemeColorHex.color(hex: ThemePreset.iconOrange.displayHex)
        case .custom:
            return ThemeColorHex.color(hex: customSeed ?? ThemePalette.pickerSeed)
        default:
            return ThemeColorHex.color(hex: preset.seed ?? ThemePalette.pickerSeed)
        }
    }

    func selectPreset(_ value: ThemePreset) {
        guard value != .custom, value != preset else { return }
        preset = value
        settings.setThemePreset(value)
        applyPalette(ThemePalette.resolve(preset: value, customSeed: customSeed))
    }

    func setCustomColor(_ color: Color) {
        guard let seed = ThemeColorHex.hex(from: color) else { return }
        // 取到和预设完全一样的颜色时直接选预设，别让默认色走推导后出现细微偏差。
        if let matched = ThemePreset.swatches.first(where: { $0.displayHex == seed }) {
            selectPreset(matched)
            return
        }
        guard preset != .custom || customSeed != seed else { return }
        preset = .custom
        customSeed = seed
        settings.setThemePreset(.custom)
        settings.setThemeSeed(seed)
        applyPalette(.derive(seed: seed))
    }

    func resetThemeColor() {
        selectPreset(.iconOrange)
    }

    private func applyPalette(_ value: ThemePalette) {
        palette = value
        ThemeRuntime.palette = value
        paletteRevision &+= 1
        NSApp?.windows.forEach { $0.contentView?.needsDisplay = true }
    }

    var isDark: Bool {
        switch mode {
        case .light: return false
        case .dark: return true
        case .system: return systemIsDark
        }
    }

    private static let aquaAppearance = NSAppearance(named: .aqua)
    private static let darkAppearance = NSAppearance(named: .darkAqua)

    var resolvedAppearance: NSAppearance? {
        isDark ? Self.darkAppearance : Self.aquaAppearance
    }

    /// 刻意不设 `NSApp.appearance`，避免状态栏图标被强制染色。
    func apply() {
        AppAppearance.current = mode
        guard let windows = NSApp?.windows else { return }
        for window in windows where window.canBecomeMain || window.sheetParent != nil {
            apply(to: window)
        }
    }

    func apply(to window: NSWindow) {
        let targetAppearance = mode == .system ? nil : resolvedAppearance
        if window.appearance !== targetAppearance {
            window.appearance = targetAppearance
        }
        if window.canBecomeMain, window is NSPanel == false {
            if window.contentView?.appearance != nil {
                window.contentView?.appearance = nil
            }
            BackgroundSurface.shared.applyWindowSurface(to: window)
        }
        window.contentView?.needsDisplay = true
    }

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
        let dark = AppAppearance.systemIsDark
        if dark != systemIsDark {
            systemIsDark = dark
        }
        guard mode == .system else { return }
        apply()
    }
}

extension AppAppearance {
    @MainActor static var current: AppAppearance = .system
    @MainActor static var isDark: Bool { current.resolvedIsDark }
}

// MARK: - Dynamic colour

extension NSColor {
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

    static func adaptiveOverlay(_ opacity: Double) -> NSColor {
        adaptive(dark: 0xFFFFFF, light: 0x101014, darkAlpha: opacity, lightAlpha: opacity)
    }

    /// 控制台正文与强调色，供 AppKit 文本宿主（对话输入框）使用。
    /// 正文保持中性；强调色每次都从运行时 palette 取，换主题后新输入框即生效。
    static let consoleText = adaptive(dark: 0xF8FAFC, light: 0x0F172A)
    static var consoleAccent: NSColor { ThemeRuntime.palette.accent.nsColor }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }

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

    static func adaptiveOverlay(_ opacity: Double) -> Color {
        Color(nsColor: NSColor.adaptiveOverlay(opacity))
    }
}
