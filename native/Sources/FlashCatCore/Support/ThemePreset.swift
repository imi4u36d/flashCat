// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 主题色的固定预设。`iconOrange` 是手调的默认值，和设计稿逐值一致；
/// 其余预设只存一个种子色，浅色 / 夜间的 accent 家族由运行时推导。
///
/// `custom` 不参与色板行（自定义入口是系统取色器），但需要和预设一起落盘。
package enum ThemePreset: String, CaseIterable, Identifiable, Hashable, Sendable {
    case iconOrange
    case peach
    case rose
    case teal
    case indigo
    case violet
    case custom

    package var id: String { rawValue }

    /// 设置页里排成一行色点的预设；`custom` 由取色器承担。
    package static var swatches: [ThemePreset] {
        [.iconOrange, .peach, .rose, .teal, .indigo, .violet]
    }

    package var title: String {
        switch self {
        case .iconOrange: return "图标橙"
        case .peach: return "杏桃"
        case .rose: return "玫瑰"
        case .teal: return "青瓷"
        case .indigo: return "靛蓝"
        case .violet: return "紫罗兰"
        case .custom: return "自定义"
        }
    }

    /// 推导用的种子色。`iconOrange` 有完整的手调 palette，不用种子。
    package var seed: UInt32? {
        switch self {
        case .iconOrange, .custom: return nil
        case .peach: return 0xFDBA74
        case .rose: return 0xE11D48
        case .teal: return 0x0D9488
        case .indigo: return 0x4F46E5
        case .violet: return 0x7C3AED
        }
    }

    /// 色点 / 取色器里显示的色块。`custom` 在运行时用落盘的种子色替换。
    package var displayHex: UInt32 {
        switch self {
        case .iconOrange: return 0xFF862F
        case .peach: return 0xFDBA74
        case .rose: return 0xE11D48
        case .teal: return 0x0D9488
        case .indigo: return 0x4F46E5
        case .violet: return 0x7C3AED
        case .custom: return 0xFF862F
        }
    }
}
