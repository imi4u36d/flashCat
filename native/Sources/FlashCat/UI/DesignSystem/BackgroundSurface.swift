// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore

/// 窗口画布背景表面：按当前外观为窗口填充静态不透明 sRGB 兜底底色。
@MainActor
final class BackgroundSurface {
    static let shared = BackgroundSurface()

    static let canvasColor = NSColor.adaptive(dark: 0x0F1117, light: 0xF5F6F8)

    static func canvasColor(for appearance: NSAppearance) -> NSColor {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) != .aqua
        let hex: UInt32 = isDark ? 0x0F1117 : 0xF5F6F8
        return NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }

    private init() {}

    func applyWindowSurface(to window: NSWindow) {
        if !window.isOpaque {
            window.isOpaque = true
        }
        let targetColor = Self.canvasColor(
            for: window.contentView?.effectiveAppearance ?? window.effectiveAppearance)
        if window.backgroundColor != targetColor {
            window.backgroundColor = targetColor
        }
    }
}
