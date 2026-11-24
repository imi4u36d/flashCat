// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore

/// 窗口画布背景表面：壁纸外圈的兜底色（浅色琉璃 `#DCE6F5` /
/// 深色液态 `#070A14` / 极简纯白 `#EEF0F4`）。
///
/// 主窗口本身为了压低阴影始终保持 Aqua 外观，因此先把动态壁纸色解析成静态
/// sRGB 再写进 `window.backgroundColor`，避免圆角外缘与切换皮肤瞬间闪白。
/// 真正的粉彩 / 极光 mesh 由窗口内的 `GlassWallpaper` 绘制。
@MainActor
final class BackgroundSurface {
    static let shared = BackgroundSurface()

    /// 壁纸兜底色，与 `GlassWallpaper` 的边角颜色一致。
    static let canvasColor = NSColor.glass(
        light: 0xDCE6F5, dark: 0x070A14, studio: 0xEEF0F4)

    /// 按给定外观给出壁纸兜底色。窗口外观与皮肤分开：studio / studioDark
    /// 也会落到浅色或深色外观上，但外层兜底只负责窗口边缘，取对应的壁纸边角色。
    static func canvasColor(for appearance: NSAppearance) -> NSColor {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) != .aqua
        let hex: UInt32 = isDark ? 0x070A14 : 0xDCE6F5
        return NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }

    private init() {}

    /// 保持窗口不透明并用当前皮肤对应的纯色画布填充窗口底色。
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
