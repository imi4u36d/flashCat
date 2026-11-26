// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import SwiftUI

// MARK: - Colour primitives

/// 一个 sRGB 颜色。主题推导全部在这个值类型上做，测试不依赖 AppKit 的外观解析。
struct ThemeRGBA: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(hex: UInt32, alpha: Double = 1) {
        self.red = Double((hex >> 16) & 0xFF) / 255
        self.green = Double((hex >> 8) & 0xFF) / 255
        self.blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hsb: (h: Double, s: Double, b: Double), alpha: Double = 1) {
        let h = hsb.h.truncatingRemainder(dividingBy: 1)
        let hue = h < 0 ? h + 1 : h
        let saturation = min(max(hsb.s, 0), 1)
        let brightness = min(max(hsb.b, 0), 1)
        let sector = floor(hue * 6)
        let fraction = hue * 6 - sector
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))

        let rgb: (Double, Double, Double)
        switch Int(sector) % 6 {
        case 0: rgb = (brightness, t, p)
        case 1: rgb = (q, brightness, p)
        case 2: rgb = (p, brightness, t)
        case 3: rgb = (p, q, brightness)
        case 4: rgb = (t, p, brightness)
        default: rgb = (brightness, p, q)
        }
        self.red = rgb.0
        self.green = rgb.1
        self.blue = rgb.2
        self.alpha = alpha
    }

    static let white = ThemeRGBA(hex: 0xFFFFFF)
    static let black = ThemeRGBA(hex: 0x000000)
    static let cocoa = ThemeRGBA(hex: 0x2A1A12)
    static let darkCocoa = ThemeRGBA(hex: 0x1B130E)

    var hex: UInt32 {
        let r = UInt32((min(max(red, 0), 1) * 255).rounded())
        let g = UInt32((min(max(green, 0), 1) * 255).rounded())
        let b = UInt32((min(max(blue, 0), 1) * 255).rounded())
        return (r << 16) | (g << 8) | b
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrast(with other: ThemeRGBA) -> Double {
        let first = luminance
        let second = other.luminance
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    func composited(over background: ThemeRGBA) -> ThemeRGBA {
        let outAlpha = alpha + background.alpha * (1 - alpha)
        guard outAlpha > 0 else { return ThemeRGBA(red: 0, green: 0, blue: 0, alpha: 0) }
        let r = (red * alpha + background.red * background.alpha * (1 - alpha)) / outAlpha
        let g = (green * alpha + background.green * background.alpha * (1 - alpha)) / outAlpha
        let b = (blue * alpha + background.blue * background.alpha * (1 - alpha)) / outAlpha
        return ThemeRGBA(red: r, green: g, blue: b, alpha: outAlpha)
    }

    var contrastingText: ThemeRGBA {
        contrast(with: .black) >= contrast(with: .white) ? .black : .white
    }

    var hsb: (h: Double, s: Double, b: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        var hue = 0.0
        if delta > 0 {
            if maximum == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maximum == 0 ? 0 : delta / maximum
        return (hue, saturation, maximum)
    }
}

/// 一个随外观切换的 tone。浅色和夜间各自保存 hex 与 alpha，默认色板就能和设计稿逐值对齐。
struct ThemeTone: Equatable {
    var light: UInt32
    var dark: UInt32
    var lightAlpha: Double = 1
    var darkAlpha: Double = 1

    var color: Color {
        .adaptive(dark: dark, light: light, darkAlpha: darkAlpha, lightAlpha: lightAlpha)
    }

    var nsColor: NSColor {
        .adaptive(dark: dark, light: light, darkAlpha: darkAlpha, lightAlpha: lightAlpha)
    }

    func resolved(dark: Bool) -> ThemeRGBA {
        ThemeRGBA(hex: dark ? self.dark : light, alpha: dark ? darkAlpha : lightAlpha)
    }
}

// MARK: - Palette

/// accent 家族的全部角色。基础表面、状态色和引擎色不在这里：
/// 它们不参与主题化，避免用户换色后破坏语义。
struct ThemePalette: Equatable {
    var accent: ThemeTone
    var accentSoft: ThemeTone
    var accentFill: ThemeTone
    var onAccent: ThemeTone
    var accentPeach: ThemeTone
    var accentPeachText: ThemeTone
    var chartLine: ThemeTone
    var chartFill: ThemeTone
    var selected: ThemeTone
    var pillActive: ThemeTone

    /// 默认主题：从应用图标取色，浅色压深保证文字对比度，夜间用杏色提亮。
    static let iconOrange = ThemePalette(
        accent: ThemeTone(light: 0xC23608, dark: 0xFFB067),
        accentSoft: ThemeTone(
            light: 0xFF862F, dark: 0xFFB067, lightAlpha: 0.12, darkAlpha: 0.20),
        accentFill: ThemeTone(light: 0xFF862F, dark: 0xFF8A3D),
        onAccent: ThemeTone(light: 0x2A1A12, dark: 0x1B130E),
        accentPeach: ThemeTone(light: 0xFFB861, dark: 0xFFC98F),
        accentPeachText: ThemeTone(light: 0xB45309, dark: 0xFFC98F),
        chartLine: ThemeTone(light: 0xF26B1D, dark: 0xFF8A3D),
        chartFill: ThemeTone(
            light: 0xF26B1D, dark: 0xFF8A3D, lightAlpha: 0.16, darkAlpha: 0.28),
        selected: ThemeTone(light: 0xFFFFFF, dark: 0xFF8A3D, lightAlpha: 1, darkAlpha: 0.24),
        pillActive: ThemeTone(light: 0xFFFFFF, dark: 0xFF8A3D, lightAlpha: 1, darkAlpha: 0.26)
    )

    static let pickerSeed = ThemePreset.iconOrange.displayHex

    static func resolve(preset: ThemePreset, customSeed: UInt32?) -> ThemePalette {
        switch preset {
        case .iconOrange:
            return .iconOrange
        case .custom:
            return .derive(seed: customSeed ?? pickerSeed)
        default:
            return .derive(seed: preset.seed ?? pickerSeed)
        }
    }

    /// 自定义色的推导：保留色相，按对比度目标调整明度；不再暴露 7 个滑块。
    static func derive(seed: UInt32) -> ThemePalette {
        let seedColor = ThemeRGBA(hex: seed)
        let lightCard = ThemeRGBA(hex: 0xFFFFFF)
        let lightSidebar = ThemeRGBA(hex: 0xF2F4F8)
        let darkCard = ThemeRGBA(hex: 0x1A1F30)
        let darkSidebar = ThemeRGBA(hex: 0x0E1220)

        // 填充色先保证在自身表面上可见；极端白 / 黑会被轻微压深或提亮。
        let lightFill = fit(seedColor, mode: .fillLight, backgrounds: [lightCard], target: 1.8)
        let darkFill = fit(seedColor, mode: .fillDark, backgrounds: [darkCard], target: 2.5)

        // 文字强调同时要压过白底、侧栏底和 12% / 20% 的软强调底。
        let lightSoftOverCard = ThemeRGBA(hex: lightFill.hex, alpha: 0.12)
            .composited(over: lightCard)
        let lightSoftOverSidebar = ThemeRGBA(hex: lightFill.hex, alpha: 0.12)
            .composited(over: lightSidebar)
        let darkSoftOverCard = ThemeRGBA(hex: darkFill.hex, alpha: 0.20)
            .composited(over: darkCard)
        let darkSoftOverSidebar = ThemeRGBA(hex: darkFill.hex, alpha: 0.20)
            .composited(over: darkSidebar)

        let lightAccent = fit(
            seedColor,
            mode: .textLight,
            backgrounds: [lightCard, lightSidebar, lightSoftOverCard, lightSoftOverSidebar],
            target: 4.5)
        let darkAccent = fit(
            seedColor,
            mode: .textDark,
            backgrounds: [darkCard, darkSidebar, darkSoftOverCard, darkSoftOverSidebar],
            target: 4.5)

        let lightChart = fit(lightFill, mode: .fillLight, backgrounds: [lightCard], target: 3.0)
        let darkChart = fit(darkFill, mode: .fillDark, backgrounds: [darkCard], target: 3.0)

        let lightPeach = secondary(from: lightFill, dark: false)
        let darkPeach = secondary(from: darkFill, dark: true)
        let lightPeachText = fit(lightPeach, mode: .textLight, backgrounds: [lightCard], target: 4.5)
        let darkPeachText = fit(darkPeach, mode: .textDark, backgrounds: [darkCard], target: 4.5)

        let lightOnAccent = onAccent(for: lightFill, preferred: .cocoa)
        let darkOnAccent = onAccent(for: darkFill, preferred: .darkCocoa)

        return ThemePalette(
            accent: ThemeTone(light: lightAccent.hex, dark: darkAccent.hex),
            accentSoft: ThemeTone(
                light: lightFill.hex, dark: darkFill.hex,
                lightAlpha: 0.12, darkAlpha: 0.20),
            accentFill: ThemeTone(light: lightFill.hex, dark: darkFill.hex),
            onAccent: ThemeTone(light: lightOnAccent.hex, dark: darkOnAccent.hex),
            accentPeach: ThemeTone(light: lightPeach.hex, dark: darkPeach.hex),
            accentPeachText: ThemeTone(light: lightPeachText.hex, dark: darkPeachText.hex),
            chartLine: ThemeTone(light: lightChart.hex, dark: darkChart.hex),
            chartFill: ThemeTone(
                light: lightChart.hex, dark: darkChart.hex,
                lightAlpha: 0.16, darkAlpha: 0.28),
            selected: ThemeTone(
                light: 0xFFFFFF, dark: darkFill.hex, lightAlpha: 1, darkAlpha: 0.24),
            pillActive: ThemeTone(
                light: 0xFFFFFF, dark: darkFill.hex, lightAlpha: 1, darkAlpha: 0.26)
        )
    }

    // MARK: Derivation helpers

    private enum FitMode {
        case textLight
        case textDark
        case fillLight
        case fillDark
    }

    /// 保持色相，只沿明度轴寻找第一个满足全部背景对比度目标的颜色。
    private static func fit(
        _ seed: ThemeRGBA,
        mode: FitMode,
        backgrounds: [ThemeRGBA],
        target: Double
    ) -> ThemeRGBA {
        // 留一点余量：推导结果最后会 round 到 8-bit hex，贴着阈值的颜色
        // 可能因为取整掉到 4.5 以下。
        let threshold = target + 0.06
        func passes(_ color: ThemeRGBA) -> Bool {
            backgrounds.allSatisfy { color.contrast(with: $0) >= threshold }
        }
        if passes(seed) { return seed }

        let components = seed.hsb
        switch mode {
        case .textLight, .fillLight:
            var brightness = components.b
            while brightness > 0 {
                brightness = max(0, brightness - 0.005)
                let candidate = ThemeRGBA(hsb: (components.h, components.s, brightness))
                if passes(candidate) { return candidate }
            }
            return .black
        case .textDark, .fillDark:
            var brightness = components.b
            while brightness < 1 {
                brightness = min(1, brightness + 0.005)
                let candidate = ThemeRGBA(hsb: (components.h, components.s, brightness))
                if passes(candidate) { return candidate }
            }
            return .white
        }
    }

    /// 橙底上的前景：优先用可可棕（和图标里的眼睛同色），它不达标才退黑 / 白。
    private static func onAccent(for fill: ThemeRGBA, preferred: ThemeRGBA) -> ThemeRGBA {
        for candidate in [preferred, ThemeRGBA.black, ThemeRGBA.white]
        where candidate.contrast(with: fill) >= 4.5 {
            return candidate
        }
        return fill.contrastingText
    }

    /// 次级数据色：同色相、低饱和的亮一档，默认橙正好落到 #FFB861 / #FFC98F。
    private static func secondary(from fill: ThemeRGBA, dark: Bool) -> ThemeRGBA {
        var components = fill.hsb
        components.s = min(components.s, dark ? 0.55 : 0.62)
        components.b = max(components.b, dark ? 0.86 : 0.78)
        if !dark, components.b > 0.95, components.s < 0.12 {
            components.b = 0.86
        }
        return ThemeRGBA(hsb: components)
    }
}

// MARK: - Runtime

/// 当前运行时调色板。`DS` 的 accent 家族每次求值都读它；
/// `ThemeController` 在主题变化时写入新值并 bump revision，根视图重绘后即生效。
enum ThemeRuntime {
    nonisolated(unsafe) static var palette: ThemePalette = .iconOrange
}

// MARK: - Colour conversion

enum ThemeColorHex {
    static func hex(from color: Color) -> UInt32? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let red = UInt32((min(max(rgb.redComponent, 0), 1) * 255).rounded())
        let green = UInt32((min(max(rgb.greenComponent, 0), 1) * 255).rounded())
        let blue = UInt32((min(max(rgb.blueComponent, 0), 1) * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }

    static func color(hex: UInt32) -> Color {
        ThemeRGBA(hex: hex).color
    }
}
