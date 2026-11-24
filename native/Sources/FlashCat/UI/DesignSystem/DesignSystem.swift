// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import SwiftUI

// MARK: - flashCat Design System (macOS Liquid Glass)
//
// 唯一的设计源。颜色、字号、间距、圆角、动效全部从 `DS` 取；旧的 `Native` /
// `Console` token 只是指向这里的兼容别名，新代码不要再引用它们。
//
// 原则：
// - macOS Liquid Glass：粉彩 / 极光壁纸铺满窗口，玻璃层贴着窗口边缘铺开，
//   卡片是磨砂玻璃 + 顶部高光 + 极轻投影，主动作仍是高对比墨块按钮。
// - 三副皮肤：浅色琉璃（slate / indigo）、深色液态（夜空 / 极光）、
//   极简纯白（关掉模糊与折射的实色分层）。颜色一律经 `Color.glass(...)`
//   按 `GlassSkin` 解析，视图不判断当前是哪一副。
// - 数字一律等宽对齐（`.monospacedDigit()`），地址 / 代码用等宽字体。
// - 圆角层级：pill 胶囊 / window 22 / card 16 / control 10 / sm 8 / xs 6。
// - 动效只有四种曲线：snappy（反馈）、smooth（布局 / 页面）、bouncy（强调）、fade。

enum DS {
    // MARK: Color

    /// 窗口外圈的壁纸底色（`BackgroundSurface` 与 SwiftUI 壁纸的兜底色）。
    static let wallpaperEdge = Color.glass(light: 0xDCE6F5, dark: 0x070A14, studio: 0xEEF0F4)

    /// 控制台窗口的玻璃底：贴着窗口边缘铺满，由背后的 `GlassWallpaper` 透出颜色。
    static let windowFill = Color.glass(
        light: 0xF6F8FD, dark: 0x111420, studio: 0xF8F9FB,
        lightAlpha: 0.44, darkAlpha: 0.58, studioAlpha: 1, studioDarkAlpha: 1)
    static let windowBorder = Color.glass(
        light: 0xFFFFFF, dark: 0xFFFFFF, studio: 0x0F172A,
        lightAlpha: 0.72, darkAlpha: 0.14, studioAlpha: 0.09)
    static let windowShadow = Color.glass(
        light: 0x1F2D50, dark: 0x000000, studio: 0x0F172A,
        lightAlpha: 0.30, darkAlpha: 0.62, studioAlpha: 0.14)

    /// 侧栏（贴在玻璃窗口左侧的竖条）。
    static let sidebarFill = Color.glass(
        light: 0xF2F5FC, dark: 0x0C0F19, studio: 0xF2F4F7,
        lightAlpha: 0.42, darkAlpha: 0.52, studioAlpha: 1, studioDarkAlpha: 1)
    static let sidebarBorder = Color.glass(
        light: 0x0F172A, dark: 0xFFFFFF, studio: 0x0F172A,
        lightAlpha: 0.07, darkAlpha: 0.08, studioAlpha: 0.07)

    /// 卡片 / 面板。
    static let surface = Color.glass(
        light: 0xFFFFFF, dark: 0x1C2134, studio: 0xFFFFFF,
        lightAlpha: 0.58, darkAlpha: 0.54, studioAlpha: 1, studioDarkAlpha: 1)
    /// 悬停 / 抬升一档的卡片。
    static let raised = Color.glass(
        light: 0xFFFFFF, dark: 0x262D46, studio: 0xFCFDFF,
        lightAlpha: 0.76, darkAlpha: 0.66, studioAlpha: 1, studioDarkAlpha: 1)
    /// 卡片内凹槽（输入框底、代码块、规格小格）。
    static let bg = Color.glass(
        light: 0xFFFFFF, dark: 0xFFFFFF, studio: 0xF5F7FA,
        lightAlpha: 0.38, darkAlpha: 0.05, studioAlpha: 1)
    /// 主画布 / 表单底。控制台页本身透明，只有 sheet 与空态用它兜底。
    static let canvas = Color.glass(light: 0xEEF2F9, dark: 0x0B0F1C, studio: 0xEEF0F4)
    /// 选中块、侧栏选中行、分段控件滑块。
    static let selected = Color.glass(
        light: 0xFFFFFF, dark: 0x6366F1, studio: 0xFFFFFF,
        lightAlpha: 0.94, darkAlpha: 0.26, studioAlpha: 1)
    /// 窗口级浮层（命令面板、弹出卡、菜单栏面板）。留足够高的不透明度保证可读。
    static let floating = Color.glass(
        light: 0xFBFCFE, dark: 0x1C2133, studio: 0xFFFFFF,
        lightAlpha: 0.94, darkAlpha: 0.94, studioAlpha: 1, studioDarkAlpha: 1)
    /// 行悬停底。
    static let hover = Color.glass(
        light: 0xFFFFFF, dark: 0xFFFFFF, studio: 0xF8FAFC,
        lightAlpha: 0.54, darkAlpha: 0.06, studioAlpha: 1)

    /// 描边三档：分隔线 / 控件边 / 强调边。
    static let line = Color.glass(
        light: 0x0F172A, dark: 0xFFFFFF, studio: 0x0F172A,
        lightAlpha: 0.07, darkAlpha: 0.09, studioAlpha: 0.07)
    static let line2 = Color.glass(
        light: 0x0F172A, dark: 0xFFFFFF, studio: 0x0F172A,
        lightAlpha: 0.13, darkAlpha: 0.16, studioAlpha: 0.09)
    static let line3 = Color.glass(
        light: 0x0F172A, dark: 0xFFFFFF, studio: 0x0F172A,
        lightAlpha: 0.24, darkAlpha: 0.26, studioAlpha: 0.18)

    /// 玻璃卡片的高光边：上缘亮、下缘淡。
    static let glassBorder = Color.glass(
        light: 0xFFFFFF, dark: 0xFFFFFF, studio: 0x0F172A,
        lightAlpha: 0.72, darkAlpha: 0.13, studioAlpha: 0.07)
    static let glassSpecular = Color.glass(
        light: 0xFFFFFF, dark: 0xFFFFFF, studio: 0xFFFFFF,
        lightAlpha: 0.92, darkAlpha: 0.24, studioAlpha: 0.9)
    static let glassShadow = Color.glass(
        light: 0x18274B, dark: 0x000000, studio: 0x0F172A,
        lightAlpha: 0.16, darkAlpha: 0.42, studioAlpha: 0.08)

    /// 文字四档：正文 / 次要 / 说明 / 占位。
    static let text = Color.glass(light: 0x0F172A, dark: 0xF8FAFC, studio: 0x111827)
    static let text2 = Color.glass(light: 0x475569, dark: 0xCBD5E1, studio: 0x4B5563)
    static let text3 = Color.glass(light: 0x64748B, dark: 0x94A3B8, studio: 0x6B7280)
    static let text4 = Color.glass(light: 0x94A3B8, dark: 0x64748B, studio: 0x9CA3AF)

    static let accent = Color.glass(light: 0x4F46E5, dark: 0x818CF8, studio: 0x4F46E5)
    static let accentBlue = Color.glass(light: 0x2563EB, dark: 0x60A5FA, studio: 0x2563EB)
    static let accentSoft = Color.glass(
        light: 0x4F46E5, dark: 0x818CF8, studio: 0x4F46E5,
        lightAlpha: 0.12, darkAlpha: 0.18, studioAlpha: 0.10)

    static let ok = Color.glass(light: 0x059669, dark: 0x34D399, studio: 0x059669)
    static let okSoft = Color.glass(
        light: 0x10B981, dark: 0x34D399, studio: 0x10B981,
        lightAlpha: 0.12, darkAlpha: 0.14, studioAlpha: 0.10)
    static let warn = Color.glass(light: 0xD97706, dark: 0xF59E0B, studio: 0xD97706)
    static let err = Color.glass(light: 0xDC2626, dark: 0xFCA5A5, studio: 0xDC2626)
    static let info = Color.glass(light: 0x2563EB, dark: 0x60A5FA, studio: 0x2563EB)

    /// 状态胶囊：浅色底 + 同色描边 + 高对比文字。
    static let successFill = Color.glass(
        light: 0x10B981, dark: 0x34D399, studio: 0x10B981,
        lightAlpha: 0.12, darkAlpha: 0.14, studioAlpha: 0.10)
    static let successStroke = Color.glass(
        light: 0x10B981, dark: 0x34D399, studio: 0x10B981,
        lightAlpha: 0.24, darkAlpha: 0.28, studioAlpha: 0.22)
    static let dangerFill = Color.glass(
        light: 0xEF4444, dark: 0xF87171, studio: 0xEF4444,
        lightAlpha: 0.10, darkAlpha: 0.14, studioAlpha: 0.08)
    static let dangerStroke = Color.glass(
        light: 0xEF4444, dark: 0xF87171, studio: 0xEF4444,
        lightAlpha: 0.24, darkAlpha: 0.28, studioAlpha: 0.22)
    static let dangerText = Color.glass(light: 0xDC2626, dark: 0xFCA5A5, studio: 0xDC2626)

    /// 主按钮 / 段落控件轨道。
    static let pillFill = Color.glass(
        light: 0xFFFFFF, dark: 0xFFFFFF, studio: 0xEEF1F6,
        lightAlpha: 0.64, darkAlpha: 0.07, studioAlpha: 1)
    static let pillActive = Color.glass(
        light: 0xFFFFFF, dark: 0x6366F1, studio: 0xFFFFFF,
        lightAlpha: 0.94, darkAlpha: 0.26, studioAlpha: 1)
    static let pillBorder = Color.glass(
        light: 0xFFFFFF, dark: 0xFFFFFF, studio: 0x0F172A,
        lightAlpha: 0.70, darkAlpha: 0.12, studioAlpha: 0.07)

    /// 图表数据色。默认取强调色；概览仍可按引擎覆盖。
    static let chartLine = Color.glass(light: 0x4F46E5, dark: 0x818CF8, studio: 0x4F46E5)
    static let chartFill = Color.glass(
        light: 0x4F46E5, dark: 0x818CF8, studio: 0x4F46E5,
        lightAlpha: 0.22, darkAlpha: 0.30, studioAlpha: 0.14)
    static let chartGrid = Color.glass(
        light: 0x0F172A, dark: 0xFFFFFF, studio: 0x0F172A,
        lightAlpha: 0.07, darkAlpha: 0.08, studioAlpha: 0.06)

    /// 高对比单色墨块按钮。
    static let ink = Color.glass(light: 0x171717, dark: 0xEDEDED, studio: 0x171717)
    static let inkText = Color.glass(light: 0xFFFFFF, dark: 0x161616, studio: 0xFFFFFF)

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

        /// 对话长文排版字体：西文与数字走系统 SF Pro，中文优先直连 PingFang SC 正文体
        /// （避开系统默认 UI 控件字重偏粗、字距偏紧的 `.PingFangUITextSC`）。
        static func proseNS(
            _ size: CGFloat,
            weight: NSFont.Weight = .regular,
            monospacedDigits: Bool = false
        ) -> NSFont {
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
            return NSFont(descriptor: descriptor, size: size) ?? base
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

    // MARK: Radius — Liquid Glass 6 levels

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 10
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        /// 概览 / 表格 / 侧栏卡片用的标准玻璃圆角。
        static let card: CGFloat = 16
        /// 浮起的控制台窗口。
        static let window: CGFloat = 22
        /// 真实胶囊（状态胶囊、分段控件的轨道）。
        static let pill: CGFloat = 999
    }

    // MARK: Layout

    enum Layout {
        static let sidebarWidth: CGFloat = 224
        static let titlebarHeight: CGFloat = 48
        /// 玻璃窗口与 AppKit 窗口边缘之间的壁纸留白。
        static let windowInset: CGFloat = 10
        static let sidebarHeaderHeight: CGFloat = 44
        static let rowHeight: CGFloat = 30
        static let controlHeight: CGFloat = 28
        static let pageMaxWidth: CGFloat = 1180
        static let chatColumn: CGFloat = 720
    }

    // MARK: Motion — 4 curves

    enum Motion {
        /// hover / press / toggle：短、利落，不过冲。
        static let snappy = Animation.snappy(duration: 0.18)
        /// 布局、页面、展开收起、选中块滑动。
        static let smooth = Animation.smooth(duration: 0.28)
        /// 需要被注意到的强调：灵动岛、命令面板、新条目。
        static let bouncy = Animation.bouncy(duration: 0.42, extraBounce: 0.06)
        /// 纯透明度变化（交叉淡入淡出）。
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

private struct DSSurfaceModifier: ViewModifier {
    var radius: CGFloat
    var fill: Color
    var tint: Color?
    var stroke: Color?
    var hoverable: Bool
    var active: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shape = DS.rect(radius)
        let baseFill = (hoverable && hovering) ? DS.raised : fill
        let resolvedTint: Color? = tint ?? (active ? DS.accent.opacity(0.08) : nil)
        content
            .background {
                ZStack {
                    shape
                        .fill(baseFill)
                        .shadow(color: DS.glassShadow, radius: 10, x: 0, y: 4)
                    if hoverable && hovering {
                        shape.fill(DS.hover)
                    }
                    if let resolvedTint {
                        shape.fill(resolvedTint)
                    }
                }
            }
            .overlay {
                if let stroke {
                    shape.strokeBorder(stroke, lineWidth: 1)
                } else if active {
                    shape.strokeBorder(DS.accent.opacity(0.42), lineWidth: 1)
                } else {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [DS.glassSpecular, DS.glassBorder],
                            startPoint: .top,
                            endPoint: .bottom),
                        lineWidth: 1)
                }
            }
            .onHover { value in
                guard hoverable else { return }
                if reduceMotion {
                    hovering = value
                } else {
                    withAnimation(DS.Motion.snappy) { hovering = value }
                }
            }
    }
}

extension View {
    /// 内容卡片表面：磨砂玻璃 + 顶部高光边 + 极轻投影。
    func dsSurface(
        radius: CGFloat = DS.Radius.card,
        fill: Color = DS.surface,
        tint: Color? = nil,
        stroke: Color? = nil,
        hoverable: Bool = false,
        active: Bool = false
    ) -> some View {
        modifier(
            DSSurfaceModifier(
                radius: radius,
                fill: fill,
                tint: tint,
                stroke: stroke,
                hoverable: hoverable,
                active: active))
    }

    /// 窗口级浮层（弹出菜单、命令面板）：高不透明度玻璃 + 高光描边 + 投影。
    func dsFloating(radius: CGFloat = DS.Radius.xl) -> some View {
        let shape = DS.rect(radius)
        return background(shape.fill(DS.floating))
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [DS.glassSpecular, DS.glassBorder],
                    startPoint: .top,
                    endPoint: .bottom),
                lineWidth: 1))
        .shadow(color: DS.glassShadow, radius: 22, y: 10)
    }

    /// 弹出框表面：玻璃浮层，替代系统默认的纯色 popover 底。
    func dsPopoverSurface() -> some View {
        background(DS.floating)
            .presentationBackground(DS.floating)
    }

    /// 弹层画布：玻璃窗口外的画布色，sheet 不继承主窗口的壁纸。
    func sheetCanvas() -> some View {
        background(DS.canvas.ignoresSafeArea())
            .presentationBackground(DS.canvas)
    }

    /// 超宽窗口下的内容列：页头、筛选条与主体一起收在
    /// `DS.Layout.pageMaxWidth` 内并居中。窗口窄于这个宽度时保持铺满。
    func dsPageColumn() -> some View {
        frame(maxWidth: DS.Layout.pageMaxWidth)
            .frame(maxWidth: .infinity)
    }

    /// 卡片内部的次级小格：更淡的玻璃底 + 发丝边，不叠投影。
    func dsSubcard(radius: CGFloat = DS.Radius.md) -> some View {
        let shape = DS.rect(radius)
        return background(shape.fill(DS.bg))
            .overlay(shape.strokeBorder(DS.line, lineWidth: 1))
    }

    /// 玻璃胶囊：状态角标、筛选条、分段控件轨道。
    func dsGlassPill(active: Bool = false) -> some View {
        background(Capsule().fill(active ? DS.pillActive : DS.pillFill))
            .overlay(Capsule().strokeBorder(DS.pillBorder, lineWidth: 1))
            .shadow(color: active ? DS.glassShadow.opacity(0.6) : .clear, radius: 6, y: 2)
    }

    /// 输入框 / 文本域表面：半透明凹槽 + 1px 描边（聚焦时亮起强调色描边）。
    func dsInputSurface(radius: CGFloat = DS.Radius.md, focused: Bool = false) -> some View {
        background(DS.rect(radius).fill(DS.bg))
            .overlay(DS.rect(radius).strokeBorder(focused ? DS.accent.opacity(0.70) : DS.line2, lineWidth: 1))
            .overlay(
                DS.rect(radius + 1)
                    .strokeBorder(focused ? DS.accent.opacity(0.16) : .clear, lineWidth: 2)
                    .padding(-1)
            )
            .animation(DS.Motion.snappy, value: focused)
    }
}

// MARK: - Panel

/// 带标题行的面板：40pt 标题 + 1px 分隔 + 内容。
