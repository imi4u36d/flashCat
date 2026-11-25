// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

package enum AppAppearance: Int, CaseIterable, Identifiable, Hashable {
    case system = 0
    case light = 1
    case dark = 2

    package var id: Int { rawValue }

    /// 兼容旧版 6 档存储值（0/5 → system，1/3 → light，2/4 → dark）。
    package static func normalized(rawValue: Int) -> AppAppearance {
        switch rawValue {
        case 1, 3: return .light
        case 2, 4: return .dark
        default: return .system
        }
    }

    package var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "日间"
        case .dark: return "夜间"
        }
    }

    package var detail: String {
        switch self {
        case .system: return "随 macOS 外观自动切换日间与夜间"
        case .light: return "固定使用浅色外观"
        case .dark: return "固定使用深色外观"
        }
    }

    package var symbol: String {
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
    @MainActor package static var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    @MainActor package var resolvedIsDark: Bool {
        switch self {
        case .light: return false
        case .dark: return true
        case .system: return AppAppearance.systemIsDark
        }
    }
}
