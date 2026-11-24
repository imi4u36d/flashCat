// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

package enum AppAppearance: Int, CaseIterable, Identifiable, Hashable {
    case system = 0
    case light = 1
    case dark = 2
    /// 无模糊、无折射的纯白工作室皮肤。外观仍是 Aqua（浅色），
    /// 只在 `DS` 的玻璃 token 上换成实色分层。
    case studio = 3
    /// 极简纯白的夜间版本：实色深灰表面，仍然关闭模糊与折射。
    case studioDark = 4

    package var id: Int { rawValue }

    package var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色琉璃"
        case .dark: return "深色液态"
        case .studio: return "极简纯白"
        case .studioDark: return "极简纯黑"
        }
    }

    package var detail: String {
        switch self {
        case .system: return "随 macOS 外观自动切换日间 / 夜间皮肤"
        case .light: return "柔和粉彩壁纸与半透明玻璃层"
        case .dark: return "深色极光壁纸与低亮度玻璃层"
        case .studio: return "实色纯白表面，关闭模糊与折射"
        case .studioDark: return "实色深灰表面，关闭模糊与折射"
        }
    }

    package var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        case .studio: return "square.fill"
        case .studioDark: return "square.fill"
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
        case .light, .studio: return false
        case .dark, .studioDark: return true
        case .system: return AppAppearance.systemIsDark
        }
    }
}
