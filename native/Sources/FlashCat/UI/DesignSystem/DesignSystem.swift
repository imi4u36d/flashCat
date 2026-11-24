// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import SwiftUI

// MARK: - flashCat Design System (ZCode / Zai Light & Zai Dark)
//
// 唯一的设计源。颜色、字号、间距、圆角、动效全部从 `DS` 取；旧的 `Native` /
// `Console` token 只是指向这里的兼容别名，新代码不要再引用它们。
//
// 原则：
// - 克制、高信息密度、操作导向的桌面工作台美学（对标 ZCode）。
// - 停止使用 Liquid Glass 与半透明玻璃折射；采用实色分层表面 + 1px 发丝边框。
// - 明暗两套皮肤对应 Zai Light（#F8F8F8 / #F0F0F0 / #FFFFFF）与 Zai Dark
//   （#161616 / #1C1C1C / #222222），主动作采用高对比单色墨块按钮，聚焦与链接使用 ZCode 蓝。
// - 数字一律等宽对齐（`.monospacedDigit()`），地址 / 代码用等宽字体。
// - 同心圆角四档：sm 6 / md 8 / lg 10 / xl 12（逐层递减，不使用大胶囊圆角）。
// - 动效只有四种曲线：snappy（反馈）、smooth（布局 / 页面）、bouncy（强调）、fade。

enum DS {
    // MARK: Color

    /// 侧栏、凹槽（输入框底、代码块）——Zai Light #F0F0F0 / Zai Dark #1C1C1C。
    static let bg = Color.adaptive(dark: 0x1C1C1C, light: 0xF0F0F0)
    /// 主画布——Zai Light #F8F8F8 / Zai Dark #161616。
    static let canvas = Color.adaptive(dark: 0x161616, light: 0xF8F8F8)
    /// 卡片 / 面板 / 输入卡——Zai Light #FFFFFF / Zai Dark #222222。
    static let surface = Color.adaptive(dark: 0x222222, light: 0xFFFFFF)
    /// 浮层、次级控件底、表头。
    static let raised = Color.adaptive(dark: 0x292929, light: 0xFFFFFF)
    /// 凹槽（`DS.bg`）上的选中块、侧栏选中行。
    static let selected = Color.adaptive(dark: 0x2E2E2E, light: 0xE4E4E4)
    /// 窗口级浮层（命令面板、弹出卡、菜单栏面板）。
    static let floating = Color.adaptive(dark: 0x282828, light: 0xFFFFFF)
    /// 悬停底——ZCode 5%–6% 中性叠层。
    static let hover = Color.adaptive(dark: 0xFFFFFF, light: 0x0D0D0D, darkAlpha: 0.06, lightAlpha: 0.05)

    /// 描边三档：分隔线 / 控件边 / 强调边。
    static let line = Color.adaptive(dark: 0xFFFFFF, light: 0x0D0D0D, darkAlpha: 0.10, lightAlpha: 0.09)
    static let line2 = Color.adaptive(dark: 0xFFFFFF, light: 0x0D0D0D, darkAlpha: 0.16, lightAlpha: 0.15)
    static let line3 = Color.adaptive(dark: 0xFFFFFF, light: 0x0D0D0D, darkAlpha: 0.25, lightAlpha: 0.24)

    /// 文字四档：正文 / 次要 / 说明 / 占位。
    static let text = Color(nsColor: .consoleText)
    static let text2 = Color.adaptive(dark: 0xA3A3A3, light: 0x262626, darkAlpha: 1, lightAlpha: 0.65)
    static let text3 = Color.adaptive(dark: 0x8C8C8C, light: 0x262626, darkAlpha: 1, lightAlpha: 0.56)
    static let text4 = Color.adaptive(dark: 0x6B6B6B, light: 0x262626, darkAlpha: 1, lightAlpha: 0.38)

    static let accent = Color(nsColor: .consoleAccent)
    static let accentSoft = Color.adaptive(dark: 0x3B82F6, light: 0xEBF4FF, darkAlpha: 0.16, lightAlpha: 1.0)

    static let ok = Color.adaptive(dark: 0x3DD68C, light: 0x1E8A3E)
    static let warn = Color.adaptive(dark: 0xF59E0B, light: 0xE07B00)
    static let err = Color.adaptive(dark: 0xF87171, light: 0xE03131)
    static let info = Color.adaptive(dark: 0x38BDF8, light: 0x0B7FFF)

    /// 主动作按钮：ZCode 高对比单色墨块（浅色黑底白字，深色白底黑字）。
    static let ink = Color.adaptive(dark: 0xEDEDED, light: 0x171717)
    static let inkText = Color.adaptive(dark: 0x161616, light: 0xFFFFFF)

    static let scrim = Color.adaptive(dark: 0x000000, light: 0x0D0D0D, darkAlpha: 0.55, lightAlpha: 0.22)
    static let shadow = Color.adaptive(dark: 0x000000, light: 0x0D0D0D, darkAlpha: 0.40, lightAlpha: 0.08)

    // MARK: Type — 11 / 12 / 13 / 15 / 22 / 30

    enum Font {
        static let xs = SwiftUI.Font.system(size: 11)
        static let sm = SwiftUI.Font.system(size: 12)
        static let md = SwiftUI.Font.system(size: 13)
        static let lg = SwiftUI.Font.system(size: 15)
        static let title = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let display = SwiftUI.Font.system(size: 30, weight: .semibold)

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

    // MARK: Radius — ZCode 4 concentric levels (6 / 8 / 10 / 12)

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 12
    }

    // MARK: Layout

    enum Layout {
        static let sidebarWidth: CGFloat = 216
        static let titlebarHeight: CGFloat = 48
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
        let resolvedStroke: Color =
            stroke ?? (active ? DS.accent.opacity(0.40) : ((hoverable && hovering) ? DS.line2 : DS.line))
        content
            .background {
                ZStack {
                    shape.fill(baseFill)
                    if hoverable && hovering {
                        shape.fill(DS.hover)
                    }
                    if let resolvedTint {
                        shape.fill(resolvedTint)
                    }
                }
            }
            .overlay(shape.strokeBorder(resolvedStroke, lineWidth: 1))
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
    /// 内容卡片表面：ZCode 实色分层表面 + 1px 发丝边框。
    func dsSurface(
        radius: CGFloat = DS.Radius.lg,
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

    /// 窗口级浮层（弹出菜单、命令面板）：实色分层表面 + 1px 描边 + 轻阴影。
    func dsFloating(radius: CGFloat = DS.Radius.xl) -> some View {
        let shape = DS.rect(radius)
        return background(shape.fill(DS.floating))
            .clipShape(shape)
            .overlay(shape.strokeBorder(DS.line2, lineWidth: 1))
            .shadow(color: DS.shadow, radius: 18, y: 8)
    }

    /// 弹出框表面：实色浮层底色，替代 macOS 原生玻璃材质。
    func dsPopoverSurface() -> some View {
        background(DS.floating)
            .presentationBackground(DS.floating)
    }

    /// 弹层画布：实色 ZCode 画布，替代半透明毛玻璃。
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

    /// 输入框 / 文本域表面：实色输入底 + 1px 描边（聚焦时亮起强调色描边）。
    func dsInputSurface(radius: CGFloat = DS.Radius.md, focused: Bool = false) -> some View {
        background(DS.rect(radius).fill(DS.surface))
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
