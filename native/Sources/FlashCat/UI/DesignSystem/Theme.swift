// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import SwiftUI

/// 主题控制器：管理「跟随系统 / 日间 / 夜间」外观选择并应用到主窗口与弹层。
@MainActor
final class ThemeController: ObservableObject {
    @Published private(set) var mode: AppAppearance
    /// 系统当前是不是深色，供跟随系统时驱动 SwiftUI 重解动态颜色。
    @Published private(set) var systemIsDark: Bool

    private let settings: AppSettings
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?

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
    static let consoleText = adaptive(dark: 0xF8FAFC, light: 0x0F172A)
    static let consoleAccent = adaptive(dark: 0x818CF8, light: 0x4F46E5)
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
