// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

package enum AppAppearance: Int, CaseIterable, Identifiable, Hashable {
    case system = 0
    case light = 1
    case dark = 2

    package var id: Int { rawValue }

    package var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    package var detail: String {
        switch self {
        case .system: return "随 macOS 外观自动切换日间 / 夜间皮肤"
        case .light: return "始终使用日间皮肤"
        case .dark: return "始终使用夜间皮肤"
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
