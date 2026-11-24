// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore

/// 窗口画布背景表面：始终维持不透明纯实色 ZCode 画布（日间 `#F8F8F8` / 夜间 `#161616`）。
///
/// 主窗口本身为了压低阴影始终保持 Aqua 外观，因此必须先按 `contentView` 的
/// 实际外观把动态画布色解析成静态 sRGB 再写进 `window.backgroundColor`，
/// 避免圆角外缘与切换皮肤瞬间闪白。
@MainActor
final class BackgroundSurface {
    static let shared = BackgroundSurface()

    /// 主画布底色：Zai Dark `#161616` / Zai Light `#F8F8F8`。
    static let canvasColor = NSColor.adaptive(dark: 0x161616, light: 0xF8F8F8)

    /// 按给定外观把画布底色解析成静态 sRGB 颜色。
    static func canvasColor(for appearance: NSAppearance) -> NSColor {
        var resolved = canvasColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = canvasColor.usingColorSpace(.sRGB) ?? canvasColor
        }
        return resolved
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
