// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import SwiftUI

// MARK: - flashCat Design System
//
// 唯一的设计源。颜色、字号、间距、圆角、动效全部从 `DS` 取。
// 使用原生浅/深实色分层表面与 1px 描边，避免离屏材质模糊带来的开销。

enum DS {
    // MARK: Color

    static let windowFill = Color.adaptive(dark: 0x111420, light: 0xF6F8FC)
    static let sidebarFill = Color.adaptive(dark: 0x0E1220, light: 0xF2F4F8)
    static let sidebarBorder = Color.adaptive(
        dark: 0xFFFFFF, light: 0x0F172A, darkAlpha: 0.08, lightAlpha: 0.07)

    /// 卡片 / 面板。
    static let surface = Color.adaptive(dark: 0x1A1F30, light: 0xFFFFFF)
    /// 悬停 / 抬升一档的卡片。
    static let raised = Color.adaptive(dark: 0x22283D, light: 0xFCFDFF)
    /// 卡片内凹槽（输入框底、代码块、规格小格）。
    static let bg = Color.adaptive(
        dark: 0xFFFFFF, light: 0xF4F6FA, darkAlpha: 0.05, lightAlpha: 1)
    /// 主画布 / 表单底。
    static let canvas = Color.adaptive(dark: 0x0E111B, light: 0xF2F4F8)
    /// 选中块、侧栏选中行、分段控件滑块。浅色是白色；夜间跟主题强调色走。
    static var selected: Color { ThemeRuntime.palette.selected.color }
    /// 窗口级浮层（弹出卡、菜单栏面板）。
    static let floating = Color.adaptive(dark: 0x1A1F30, light: 0xFFFFFF)
    /// 菜单栏面板底色。
    static let panelFill = Color.adaptive(dark: 0x1A1F30, light: 0xFFFFFF)
    /// 行悬停底。
    static let hover = Color.adaptive(
        dark: 0xFFFFFF, light: 0x0F172A, darkAlpha: 0.06, lightAlpha: 0.04)
    /// 侧栏会话行选中底：中性色，和导航页的 `accentSoft` 分工，
    /// 让「当前页面」和「当前会话」在扫视时是两种记号。
    static let rowSelected = Color.adaptive(
        dark: 0xFFFFFF, light: 0x0F172A, darkAlpha: 0.095, lightAlpha: 0.065)

    /// 描边两档：分隔线 / 控件边。
    static let line = Color.adaptive(
        dark: 0xFFFFFF, light: 0x0F172A, darkAlpha: 0.09, lightAlpha: 0.07)
    static let line2 = Color.adaptive(
        dark: 0xFFFFFF, light: 0x0F172A, darkAlpha: 0.16, lightAlpha: 0.12)

    static let glassBorder = Color.adaptive(
        dark: 0xFFFFFF, light: 0x0F172A, darkAlpha: 0.12, lightAlpha: 0.08)
    static let glassSpecular = Color.adaptive(
        dark: 0xFFFFFF, light: 0xFFFFFF, darkAlpha: 0.18, lightAlpha: 0.85)
    static let glassShadow = Color.adaptive(
        dark: 0x000000, light: 0x0F172A, darkAlpha: 0.40, lightAlpha: 0.10)

    /// 文字四档：正文 / 次要 / 说明 / 占位。
    static let text = Color.adaptive(dark: 0xF8FAFC, light: 0x0F172A)
    static let text2 = Color.adaptive(dark: 0xCBD5E1, light: 0x475569)
    static let text3 = Color.adaptive(dark: 0x94A3B8, light: 0x64748B)
    static let text4 = Color.adaptive(dark: 0x64748B, light: 0x94A3B8)

    /// 主题强调色家族。全部从 `ThemeRuntime.palette` 取：
    /// `accent` 用于文字 / 图标，`accentFill` 用于实心块，`onAccent` 是橙底前景。
    static var accent: Color { ThemeRuntime.palette.accent.color }
    static var accentSoft: Color { ThemeRuntime.palette.accentSoft.color }
    static var accentFill: Color { ThemeRuntime.palette.accentFill.color }
    static var onAccent: Color { ThemeRuntime.palette.onAccent.color }
    /// 次级数据色：缓存 / 内存条的第二色与 claude 方言标签。
    static var accentPeach: Color { ThemeRuntime.palette.accentPeach.color }
    static var accentPeachText: Color { ThemeRuntime.palette.accentPeachText.color }

    static let ok = Color.adaptive(dark: 0x34D399, light: 0x059669)
    static let okSoft = Color.adaptive(
        dark: 0x34D399, light: 0x10B981, darkAlpha: 0.14, lightAlpha: 0.10)
    static let warn = Color.adaptive(dark: 0xF59E0B, light: 0xD97706)
    static let err = Color.adaptive(dark: 0xFCA5A5, light: 0xDC2626)
    static let info = Color.adaptive(dark: 0x60A5FA, light: 0x2563EB)

    /// 状态胶囊：浅色底 + 同色描边 + 高对比文字。
    static let successFill = Color.adaptive(
        dark: 0x34D399, light: 0x10B981, darkAlpha: 0.14, lightAlpha: 0.10)
    static let successStroke = Color.adaptive(
        dark: 0x34D399, light: 0x10B981, darkAlpha: 0.28, lightAlpha: 0.22)
    static let dangerFill = Color.adaptive(
        dark: 0xF87171, light: 0xEF4444, darkAlpha: 0.14, lightAlpha: 0.08)
    static let dangerStroke = Color.adaptive(
        dark: 0xF87171, light: 0xEF4444, darkAlpha: 0.28, lightAlpha: 0.22)
    static let dangerText = Color.adaptive(dark: 0xFCA5A5, light: 0xDC2626)

    /// 主按钮 / 段落控件轨道。
    static let pillFill = Color.adaptive(
        dark: 0xFFFFFF, light: 0xEEF1F6, darkAlpha: 0.07, lightAlpha: 1)
    static var pillActive: Color { ThemeRuntime.palette.pillActive.color }
    static let pillActiveNeutral = Color.adaptive(
        dark: 0xFFFFFF, light: 0xFFFFFF, darkAlpha: 0.12, lightAlpha: 1)

    /// 图表兜底色；接上引擎后仍用引擎识别色。
    static var chartLine: Color { ThemeRuntime.palette.chartLine.color }
    static var chartFill: Color { ThemeRuntime.palette.chartFill.color }
    static let chartGrid = Color.adaptive(
        dark: 0xFFFFFF, light: 0x0F172A, darkAlpha: 0.08, lightAlpha: 0.06)

    /// 高对比单色墨块按钮。
    static let ink = Color.adaptive(dark: 0xEDEDED, light: 0x171717)
    static let inkText = Color.adaptive(dark: 0x161616, light: 0xFFFFFF)

    static let scrim = Color.adaptive(dark: 0x000000, light: 0x0D0D0D, darkAlpha: 0.55, lightAlpha: 0.22)
    static let shadow = Color.adaptive(dark: 0x000000, light: 0x0D0D0D, darkAlpha: 0.40, lightAlpha: 0.08)

    // MARK: Type — 11 / 12 / 13 / 15 / 20 / 28

    enum Font {
        static let xs = SwiftUI.Font.system(size: 11)
        static let sm = SwiftUI.Font.system(size: 12)
        static let md = SwiftUI.Font.system(size: 13)
        static let lg = SwiftUI.Font.system(size: 15)
        static let title = SwiftUI.Font.system(size: 20, weight: .bold)
        static let display = SwiftUI.Font.system(size: 28, weight: .bold)

        static func mono(_ size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .monospaced)
        }

        /// 读数：系统字体 + 等宽数字，比纯等宽字体更紧凑好读。
        static func number(_ size: CGFloat, weight: SwiftUI.Font.Weight = .medium) -> SwiftUI.Font {
            .system(size: size, weight: weight).monospacedDigit()
        }

        private struct ProseFontKey: Hashable {
            let sizeBits: UInt
            let weightRaw: CGFloat
            let monospacedDigits: Bool
        }

        private static let proseFontLock = NSLock()
        nonisolated(unsafe) private static var proseFontCache: [ProseFontKey: NSFont] = [:]

        /// 对话长文排版字体：西文与数字走系统 SF Pro，中文优先直连 PingFang SC 正文体。
        static func proseNS(
            _ size: CGFloat,
            weight: NSFont.Weight = .regular,
            monospacedDigits: Bool = false
        ) -> NSFont {
            let key = ProseFontKey(
                sizeBits: size.bitPattern,
                weightRaw: weight.rawValue,
                monospacedDigits: monospacedDigits)
            proseFontLock.lock()
            if let cached = proseFontCache[key] {
                proseFontLock.unlock()
                return cached
            }
            proseFontLock.unlock()

            let scName: String
            let tcName: String
            switch weight {
            case .semibold, .bold, .heavy, .black:
                scName = "PingFangSC-Semibold"
                tcName = "PingFangTC-Semibold"
            case .medium:
                scName = "PingFangSC-Medium"
                tcName = "PingFangTC-Medium"
            default:
                scName = "PingFangSC-Regular"
                tcName = "PingFangTC-Regular"
            }
            let base =
                monospacedDigits
                ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
            let descriptor = base.fontDescriptor.addingAttributes([
                .cascadeList: [
                    NSFontDescriptor(fontAttributes: [.name: scName]),
                    NSFontDescriptor(fontAttributes: [.name: tcName]),
                ]
            ])
            let resolved = NSFont(descriptor: descriptor, size: size) ?? base

            proseFontLock.lock()
            proseFontCache[key] = resolved
            proseFontLock.unlock()
            return resolved
        }

        static func prose(_ size: CGFloat, weight: NSFont.Weight = .regular) -> SwiftUI.Font {
            SwiftUI.Font(proseNS(size, weight: weight))
        }

        static func proseNumber(_ size: CGFloat, weight: NSFont.Weight = .regular) -> SwiftUI.Font {
            SwiftUI.Font(proseNS(size, weight: weight, monospacedDigits: true))
        }
    }

    // MARK: Space — 4pt grid

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: Radius

    enum Radius {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 10
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let card: CGFloat = 16
        static let window: CGFloat = 22
        static let pill: CGFloat = 999
    }

    // MARK: Layout

    enum Layout {
        static let sidebarWidth: CGFloat = 208
        static let titlebarHeight: CGFloat = 48
        static let rowHeight: CGFloat = 30
        static let controlHeight: CGFloat = 28
        static let pageMaxWidth: CGFloat = 1180
        static let chatColumn: CGFloat = 720
    }

    // MARK: Motion — 4 curves

    enum Motion {
        static let snappy = Animation.snappy(duration: 0.18)
        static let smooth = Animation.smooth(duration: 0.28)
        static let bouncy = Animation.bouncy(duration: 0.42, extraBounce: 0.06)
        static let fade = Animation.linear(duration: 0.15)
    }
}

// MARK: - Shapes

extension DS {
    static func rect(_ radius: CGFloat = Radius.md) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

// MARK: - Surface

extension View {
    /// 内容卡片表面：原生实色分层底 + 1px 发丝边框。
    func dsSurface(
        radius: CGFloat = DS.Radius.card,
        fill: Color = DS.surface,
        tint: Color? = nil,
        stroke: Color? = nil,
        hoverable: Bool = false,
        active: Bool = false
    ) -> some View {
        let shape = DS.rect(radius)
        let resolvedTint: Color? = tint ?? (active ? DS.accent.opacity(0.08) : nil)
        let resolvedStroke: Color = stroke ?? (active ? DS.accent.opacity(0.42) : DS.line)
        return background {
            ZStack {
                shape.fill(fill)
                if let resolvedTint {
                    shape.fill(resolvedTint)
                }
            }
        }
        .overlay {
            shape.strokeBorder(resolvedStroke, lineWidth: 1)
        }
    }

    /// 窗口级浮层（弹出菜单、通知浮层）。
    func dsFloating(radius: CGFloat = DS.Radius.xl) -> some View {
        let shape = DS.rect(radius)
        return background(shape.fill(DS.floating))
            .clipShape(shape)
            .overlay(shape.strokeBorder(DS.line2, lineWidth: 1))
    }

    /// 弹出框表面：替代系统默认的纯色 popover 底。
    func dsPopoverSurface() -> some View {
        background(DS.floating)
            .presentationBackground(DS.floating)
    }

    /// 弹层画布。
    func sheetCanvas() -> some View {
        background(DS.canvas.ignoresSafeArea())
            .presentationBackground(DS.canvas)
    }

    /// 超宽窗口下的内容列：页头、筛选条与主体一起收在 `maxWidth` 内并居中。
    func dsPageColumn(maxWidth: CGFloat = DS.Layout.pageMaxWidth) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }

    /// 卡片内部的次级分组：只有底色，不再叠描边。
    /// 卡内分组由留白、底色和 `DSDivider` 表达，边框只留给页面级卡片。
    func dsWell(radius: CGFloat = DS.Radius.md, fill: Color = DS.bg) -> some View {
        background(DS.rect(radius).fill(fill))
    }

    /// 兼容旧调用点：`dsSubcard` 已收敛为无描边的 well。
    func dsSubcard(radius: CGFloat = DS.Radius.md) -> some View {
        dsWell(radius: radius)
    }

    /// 胶囊标签底：状态角标、筛选条、分段控件轨道。
    func dsGlassPill(active: Bool = false) -> some View {
        background(Capsule().fill(active ? DS.pillActive : DS.pillFill))
            .overlay(Capsule().strokeBorder(DS.line, lineWidth: 1))
    }

    /// 卡内 / 输入区里的安静胶囊：只有底色，不再描边。
    func dsQuietPill(fill: Color = DS.pillFill) -> some View {
        background(Capsule().fill(fill))
    }

    /// 输入框 / 文本域表面：凹槽 + 1px 描边（聚焦时亮起强调色描边）。
    func dsInputSurface(radius: CGFloat = DS.Radius.md, focused: Bool = false) -> some View {
        background(DS.rect(radius).fill(DS.bg))
            .overlay(DS.rect(radius).strokeBorder(focused ? DS.accent.opacity(0.70) : DS.line2, lineWidth: 1))
    }
}
