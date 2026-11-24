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
struct DSPanel<Accessory: View, Content: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                Text(L10n.t(title))
                    .font(DS.Font.md.weight(.medium))
                    .foregroundStyle(DS.text)
                if let subtitle {
                    Text(L10n.t(subtitle))
                        .font(DS.Font.sm)
                        .foregroundStyle(DS.text3)
                }
                Spacer(minLength: DS.Space.sm)
                accessory()
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Rectangle().fill(DS.line).frame(height: 1)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .dsSurface()
        .clipShape(DS.rect(DS.Radius.lg))
    }
}

extension DSPanel where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = { EmptyView() }
        self.content = content
    }
}

// MARK: - Page header
/// 页头里的一枚状态：颜色 + 文案，需要时可以呼吸。
struct DSPageStatus {
    var text: String
    var color: Color
    var live: Bool = false

    init(_ text: String, color: Color, live: Bool = false) {
        self.text = text
        self.color = color
        self.live = live
    }
}

/// 七个页面共用的页头语法：页名 + 一行状态 + 页面级动作。
///
/// 之前每页开头都不一样——概览把模型名当标题、引擎页写「运行时」、模型/日志/
/// 实验只有筛选条、设置直接是卡片。切页时第一眼没有锚点，用户只能靠侧栏高亮
/// 判断自己在哪。这里把「页名回到导航、状态说一句现场」固定成一套版式。
struct DSPageHeader<Actions: View>: View {
    var title: String
    var subtitle: String?
    var status: DSPageStatus?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t(title))
                    .font(DS.Font.title)
                    .tracking(-0.3)
                    .foregroundStyle(DS.text)
                    .lineLimit(1)

                if subtitle != nil || status != nil {
                    HStack(spacing: 6) {
                        if let status {
                            DSStatusDot(color: status.color, live: status.live, size: 6)
                        }
                        if let subtitle {
                            Text(verbatim: subtitle)
                                .font(DS.Font.prose(12))
                                .foregroundStyle(DS.text3)
                                .lineLimit(1)
                        }
                        if let status {
                            if subtitle != nil {
                                Text(verbatim: "·")
                                    .font(DS.Font.prose(12))
                                    .foregroundStyle(DS.text4)
                            }
                            Text(verbatim: status.text)
                                .font(DS.Font.prose(12))
                                .foregroundStyle(status.color)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: DS.Space.md)

            HStack(spacing: DS.Space.sm) {
                actions()
            }
            .fixedSize()
        }
        .frame(minHeight: 44)
        .padding(.vertical, 2)
    }
}

extension DSPageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, status: DSPageStatus? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.actions = { EmptyView() }
    }
}

// MARK: - Buttons

/// ZCode 风格按钮：直角小圆角（`Radius.sm` / `Radius.md`）、1px 发丝边与单色高对比主按钮。
struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    enum Size { case small, regular, large }

    var kind: Kind = .secondary
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: kind, size: size)
    }
}

private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: DSButtonStyle.Kind
    let size: DSButtonStyle.Size

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var activeHover: Bool { hovering && isEnabled }

    private var height: CGFloat {
        switch size {
        case .small: return 24
        case .regular: return 28
        case .large: return 34
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .small: return 10
        case .regular: return 12
        case .large: return 16
        }
    }

    private var fontSize: CGFloat {
        switch size {
        case .small: return 11.5
        case .regular: return 12.5
        case .large: return 13
        }
    }

    private var radius: CGFloat {
        size == .small ? DS.Radius.sm : DS.Radius.md
    }

    private var shape: RoundedRectangle { DS.rect(radius) }

    private var foreground: Color {
        switch kind {
        case .primary: return DS.inkText
        case .secondary: return DS.text
        case .ghost: return activeHover ? DS.text : DS.text2
        case .danger: return DS.err
        }
    }

    private var background: Color {
        switch kind {
        case .primary:
            return activeHover ? DS.ink.opacity(0.88) : DS.ink
        case .secondary:
            return activeHover ? DS.raised : DS.surface
        case .ghost:
            return activeHover ? DS.hover : .clear
        case .danger:
            return DS.err.opacity(activeHover ? 0.17 : 0.10)
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: return .clear
        case .secondary: return activeHover ? DS.line3 : DS.line2
        case .ghost: return .clear
        case .danger: return DS.err.opacity(activeHover ? 0.42 : 0.26)
        }
    }

    var body: some View {
        configuration.label
            .font(.system(size: fontSize, weight: size == .large ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background {
                ZStack {
                    shape.fill(background)
                    if kind == .secondary && activeHover {
                        shape.fill(DS.hover)
                    }
                }
            }
            .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
            .contentShape(shape)
            .scaleEffect((!reduceMotion && configuration.isPressed && isEnabled) ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(reduceMotion ? nil : DS.Motion.snappy, value: configuration.isPressed)
            .animation(reduceMotion ? nil : DS.Motion.snappy, value: activeHover)
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsSecondary: DSButtonStyle { DSButtonStyle(kind: .secondary) }
    static var dsGhost: DSButtonStyle { DSButtonStyle(kind: .ghost) }
    static var dsDanger: DSButtonStyle { DSButtonStyle(kind: .danger) }
    static func ds(_ kind: DSButtonStyle.Kind, size: DSButtonStyle.Size = .regular) -> DSButtonStyle {
        DSButtonStyle(kind: kind, size: size)
    }
}

/// ZCode 风格圆角矩形图标按钮：支持幽灵、描边与高对比主按钮三种形态。
struct DSIconButton: View {
    enum Style { case ghost, outlined, primary }

    var systemName: String
    var help: String
    var size: CGFloat = 28
    var style: Style = .ghost
    var active: Bool = false
    var tint: Color? = nil
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var activeHover: Bool { hovering && isEnabled }

    private var shape: RoundedRectangle {
        DS.rect(size <= 24 ? DS.Radius.sm : DS.Radius.md)
    }

    private var foreground: Color {
        switch style {
        case .primary:
            return tint != nil ? .white : DS.inkText
        case .outlined:
            if active { return tint != nil ? .white : DS.inkText }
            return tint ?? (activeHover ? DS.text : DS.text2)
        case .ghost:
            return tint ?? (active ? DS.accent : (activeHover ? DS.text : DS.text2))
        }
    }

    private var background: Color {
        switch style {
        case .primary:
            let base = tint ?? DS.ink
            return activeHover ? base.opacity(0.88) : base
        case .outlined:
            if active {
                let base = tint ?? DS.ink
                return activeHover ? base.opacity(0.90) : base
            }
            return activeHover ? DS.raised : DS.surface
        case .ghost:
            return active ? DS.accentSoft : (activeHover ? DS.hover : .clear)
        }
    }

    private var border: Color {
        switch style {
        case .primary:
            return .clear
        case .outlined:
            if active { return .clear }
            return activeHover ? DS.line3 : DS.line2
        case .ghost:
            return .clear
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.43, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background {
                    ZStack {
                        shape.fill(background)
                        if style == .outlined && !active && activeHover {
                            shape.fill(DS.hover)
                        }
                    }
                }
                .overlay(shape.strokeBorder(border, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(DSPressStyle(scale: 0.96))
        .opacity(isEnabled ? 1 : 0.4)
        .help(L10n.t(help))
        .accessibilityLabel(L10n.t(help))
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
    }
}

/// 只有按压缩放、没有任何底色的按钮样式。
struct DSPressStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect((!reduceMotion && configuration.isPressed) ? scale : 1)
            .animation(reduceMotion ? nil : DS.Motion.snappy, value: configuration.isPressed)
    }
}

/// 计数角标：全应用唯一的胶囊数字徽标（下载数量、未读通知）。
struct DSBadge: View {
    var count: Int
    var tint: Color = DS.accent

    var body: some View {
        Text(verbatim: "\(count)")
            .font(DS.Font.mono(9.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 15)
            .frame(height: 15)
            .background(Capsule().fill(tint))
            .fixedSize()
    }
}

// MARK: - Small parts

/// 键盘提示：⌘K。
struct DSKbd: View {
    var text: String
    var onInk = false

    var body: some View {
        Text(verbatim: text)
            .font(DS.Font.mono(10.5, weight: .medium))
            .foregroundStyle(onInk ? DS.inkText.opacity(0.65) : DS.text3)
            .padding(.horizontal, 4)
    }
}

/// 读数来源角标：LIVE / LAST / AVG / P50。只有 LIVE 着色。
struct DSSourceBadge: View {
    var text: String
    var live: Bool = false

    var body: some View {
        Text(verbatim: text)
            .font(DS.Font.mono(9, weight: .medium))
            .tracking(0.4)
            .foregroundStyle(live ? DS.ok : DS.text3)
            .padding(.horizontal, 4)
            .frame(height: 15)
            .overlay(DS.rect(3).strokeBorder(live ? DS.ok.opacity(0.35) : DS.line2, lineWidth: 1))
            .contentTransition(.opacity)
    }
}

/// 状态圆点；`live` 时外圈呼吸扩散。
struct DSStatusDot: View {
    var color: Color = DS.ok
    var live: Bool = false
    var size: CGFloat = 7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if live && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = (t.truncatingRemainder(dividingBy: 1.8)) / 1.8
                    Circle()
                        .fill(color)
                        .frame(width: size, height: size)
                        .scaleEffect(1 + phase * 1.4)
                        .opacity(0.45 * (1 - phase))
                }
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

/// 小标签：圆点 + 文字，ZCode 圆角徽标形态。
struct DSChip: View {
    var text: String
    var dot: Color? = nil
    var live: Bool = false
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let dot {
                DSStatusDot(color: dot, live: live, size: 6)
                    .accessibilityHidden(true)
            }
            Text(L10n.t(text))
                .font(DS.Font.xs.weight(.medium))
                .foregroundStyle(tint ?? DS.text2)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(DS.rect(DS.Radius.sm).fill(tint?.opacity(0.12) ?? DS.hover))
        .overlay(DS.rect(DS.Radius.sm).strokeBorder(tint?.opacity(0.26) ?? DS.line, lineWidth: 1))
        .fixedSize()
    }
}

/// 3pt 细进度条。值为 0 时保持空轨，不画多余的 2px 小点。
struct DSMeter: View {
    var value: Double
    var tint: Color = DS.text2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { min(max(value, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.line2)
                if clamped > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, proxy.size.width * clamped))
                }
            }
        }
        .frame(height: 3)
        .animation(reduceMotion ? nil : DS.Motion.smooth, value: clamped)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int((clamped * 100).rounded()))%")
    }
}

/// 小节标题（侧栏分组、表单分组）。
struct DSSectionLabel: View {
    var text: String
    var body: some View {
        Text(L10n.t(text))
            .font(DS.Font.prose(11.5, weight: .medium))
            .foregroundStyle(DS.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DSDivider: View {
    var vertical = false
    var body: some View {
        if vertical {
            Rectangle().fill(DS.line).frame(width: 1)
        } else {
            Rectangle().fill(DS.line).frame(height: 1)
        }
    }
}

/// 迷你折线：最近若干个点，自动按峰值缩放。
struct DSSparkline: View {
    var values: [Double]
    var color: Color = DS.accent
    var floor: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let peak = max(values.max() ?? 0, floor)
            Path { path in
                guard values.count > 1 else { return }
                let step = proxy.size.width / CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let point = CGPoint(
                        x: CGFloat(index) * step,
                        y: proxy.size.height - 1 - CGFloat(value / peak) * (proxy.size.height - 2))
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Segmented & Button Groups

/// ZCode 风格分段控件。
struct DSSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var size: DSButtonStyle.Size = .regular

    var body: some View {
        NativeSegmented(selection: $selection, options: options, size: size)
    }
}

/// 按钮组容器：紧凑间距排布一组按钮。
struct DSButtonGroup<Content: View>: View {
    var radius: CGFloat = DS.Radius.md
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
        }
    }
}

// MARK: - Menus & Popovers

/// 统一下拉菜单触发器标签（纯内容排版，外层底色与边框由 `DSMenu` 提供）。
struct DSMenuTriggerLabel: View {
    enum Kind { case primary, secondary, ghost, icon }

    var title: String? = nil
    var systemImage: String? = nil
    var imageTint: Color? = nil
    var badge: String? = nil
    var trailingChevron: Bool = true
    var kind: Kind = .secondary
    var size: DSButtonStyle.Size = .regular

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size == .small ? 10.5 : 11.5, weight: .semibold))
                    .foregroundStyle(imageTint ?? (kind == .primary ? DS.inkText : DS.text2))
            }
            if let title {
                Text(L10n.t(title))
                    .font(.system(size: size == .small ? 11.5 : 12.5, weight: .medium))
                    .foregroundStyle(kind == .primary ? DS.inkText : DS.text)
                    .lineLimit(1)
            }
            if let badge {
                Text(L10n.t(badge))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(kind == .primary ? DS.inkText.opacity(0.82) : DS.text2)
                    .lineLimit(1)
                    .fixedSize()
            }
            if trailingChevron && kind != .icon {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(kind == .primary ? DS.inkText.opacity(0.75) : DS.text3)
            }
        }
    }
}

/// 统一 Menu 包装：ZCode 风格实体/描边/幽灵下拉按钮，不使用 Liquid Glass。
struct DSMenu<Label: View, Content: View>: View {
    var kind: DSMenuTriggerLabel.Kind = .secondary
    var size: DSButtonStyle.Size = .regular
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var activeHover: Bool { hovering && isEnabled }

    private var height: CGFloat {
        switch size {
        case .small: return 24
        case .regular: return DS.Layout.controlHeight
        case .large: return 34
        }
    }

    private var horizontalPadding: CGFloat {
        if kind == .icon { return 0 }
        return size == .small ? 9 : 11
    }

    private var radius: CGFloat {
        size == .small ? DS.Radius.sm : DS.Radius.md
    }

    private var shape: RoundedRectangle { DS.rect(radius) }

    private var backgroundColor: Color {
        switch kind {
        case .primary: return activeHover ? DS.ink.opacity(0.88) : DS.ink
        case .secondary: return activeHover ? DS.raised : DS.surface
        case .icon: return activeHover ? DS.raised : DS.surface
        case .ghost: return activeHover ? DS.hover : .clear
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary, .ghost: return .clear
        case .secondary, .icon: return activeHover ? DS.line3 : DS.line2
        }
    }

    var body: some View {
        Menu {
            content()
        } label: {
            label()
                .padding(.horizontal, horizontalPadding)
                .frame(width: kind == .icon ? height : nil, height: height)
                .background {
                    ZStack {
                        shape.fill(backgroundColor)
                        if (kind == .secondary || kind == .icon) && activeHover {
                            shape.fill(DS.hover)
                        }
                    }
                }
                .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
                .contentShape(shape)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.42)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : DS.Motion.snappy, value: activeHover)
    }
}

/// 弹出菜单单行：选中态用 `accentSoft`，悬停态用 `hover`，30pt 高度 + `Radius.sm`。
struct DSMenuRow<Content: View>: View {
    var selected: Bool = false
    var action: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 10)
                .frame(height: DS.Layout.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    DS.rect(DS.Radius.sm)
                        .fill(selected ? DS.accentSoft : (hovering ? DS.hover : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(DS.Motion.snappy) { hovering = inside }
        }
    }
}

// MARK: - Search & Filter

/// 统一 28pt 搜索框：ZCode 风格圆角输入框，实色底 + 1px 边框 + 聚焦微环。
struct DSSearchField: View {
    @Binding var query: String
    var placeholder: String = "搜索"
    var width: CGFloat? = nil

    @FocusState private var focused: Bool

    var body: some View {
        let shape = DS.rect(DS.Radius.md)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(focused ? DS.accent : DS.text3)
            TextField(L10n.t(placeholder), text: $query)
                .textFieldStyle(.plain)
                .font(DS.Font.sm)
                .foregroundStyle(DS.text)
                .focused($focused)
                .onExitCommand {
                    query = ""
                    focused = false
                }
                .onSubmit {
                    focused = false
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.text3)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("清除搜索"))
                .accessibilityLabel(L10n.t("清除搜索"))
            }
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: DS.Layout.controlHeight)
        .background(shape.fill(DS.surface))
        .overlay(shape.strokeBorder(focused ? DS.accent.opacity(0.70) : DS.line2, lineWidth: 1))
        .overlay(
            DS.rect(DS.Radius.md + 1)
                .strokeBorder(focused ? DS.accent.opacity(0.16) : .clear, lineWidth: 2)
                .padding(-1)
        )
        .contentShape(shape)
        .onTapGesture { focused = true }
        .animation(DS.Motion.snappy, value: focused)
    }
}

/// 一行筛选栏：ZCode 分段控件 + 搜索框。
struct DSFilterBar<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    @Binding var query: String
    var placeholder: String
    var maxSearchWidth: CGFloat = 200

    var body: some View {
        HStack(spacing: 8) {
            DSSegmented(selection: $selection, options: options)
            DSSearchField(query: $query, placeholder: placeholder, width: maxSearchWidth)
        }
    }
}

// MARK: - Transitions

extension AnyTransition {
    /// 页面切换：淡入 + 4pt 上移；离开只淡出。
    static var dsPage: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 4)),
            removal: .opacity)
    }

    /// 新条目：从上方 6pt 滑入并淡入。
    static var dsRowInsert: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -6)),
            removal: .opacity)
    }

    /// 浮层：轻微缩放 + 淡入。
    static var dsPopover: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
    }
}

// MARK: - Animated Grid

/// 支持列数切换平滑重排的原生网格 `Layout`：
/// 在 `columns` 变化时配合 `withAnimation(DS.Motion.smooth)` 为每张卡片插值位置与宽度，
/// 弥补 `LazyVGrid(.adaptive)` 在侧栏收放与窗口缩放时生硬跳变的不足。
struct DSAnimatedGrid: Layout {
    var columns: Int
    var minWidth: CGFloat
    var maxWidth: CGFloat? = nil
    var spacing: CGFloat = 12
    var maxColumns: Int? = nil

    static func columnCount(
        for width: CGFloat,
        minWidth: CGFloat,
        spacing: CGFloat,
        maxColumns: Int? = nil
    ) -> Int {
        let usable = max(1, width)
        let raw = max(1, Int((usable + spacing) / (minWidth + spacing)))
        if let maxColumns { return min(maxColumns, raw) }
        return raw
    }

    private func resolvedColumns(for width: CGFloat) -> Int {
        columns > 0
            ? columns
            : Self.columnCount(for: width, minWidth: minWidth, spacing: spacing, maxColumns: maxColumns)
    }

    private func cellWidth(totalWidth: CGFloat, cols: Int) -> CGFloat {
        let raw = max(1, (totalWidth - spacing * CGFloat(max(0, cols - 1))) / CGFloat(cols))
        return maxWidth.map { min(raw, $0) } ?? raw
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let fallbackCols = max(1, columns)
        let totalWidth =
            proposal.width
            ?? (minWidth * CGFloat(fallbackCols) + spacing * CGFloat(max(0, fallbackCols - 1)))
        let cols = max(1, resolvedColumns(for: totalWidth))
        let itemWidth = cellWidth(totalWidth: totalWidth, cols: cols)
        let itemProposal = ProposedViewSize(width: itemWidth, height: nil)

        var totalHeight: CGFloat = 0
        var index = 0
        while index < subviews.count {
            let end = min(index + cols, subviews.count)
            var rowHeight: CGFloat = 0
            for i in index..<end {
                rowHeight = max(rowHeight, subviews[i].sizeThatFits(itemProposal).height)
            }
            if index > 0 { totalHeight += spacing }
            totalHeight += rowHeight
            index = end
        }
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let totalWidth = bounds.width
        let cols = max(1, resolvedColumns(for: totalWidth))
        let itemWidth = cellWidth(totalWidth: totalWidth, cols: cols)
        let measureProposal = ProposedViewSize(width: itemWidth, height: nil)

        var y = bounds.minY
        var index = 0
        while index < subviews.count {
            let end = min(index + cols, subviews.count)
            var rowHeight: CGFloat = 0
            for i in index..<end {
                rowHeight = max(rowHeight, subviews[i].sizeThatFits(measureProposal).height)
            }
            for offset in 0..<(end - index) {
                let x = bounds.minX + CGFloat(offset) * (itemWidth + spacing)
                subviews[index + offset].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: itemWidth, height: rowHeight)
                )
            }
            y += rowHeight + spacing
            index = end
        }
    }
}

private struct DSTrackColumnsModifier: ViewModifier {
    @Binding var columns: Int
    let minWidth: CGFloat
    let spacing: CGFloat
    let maxColumns: Int?
    let horizontalPadding: CGFloat

    @State private var measuredWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                max(1, proxy.size.width - horizontalPadding * 2)
            } action: { width in
                measuredWidth = width
                updateColumns(for: width, animate: columns > 0)
            }
            .onChange(of: minWidth) { _, _ in
                guard measuredWidth > 1 else { return }
                updateColumns(for: measuredWidth, animate: columns > 0)
            }
    }

    private func updateColumns(for width: CGFloat, animate: Bool) {
        let next = DSAnimatedGrid.columnCount(
            for: width,
            minWidth: minWidth,
            spacing: spacing,
            maxColumns: maxColumns)
        guard next != columns else { return }
        if animate && !reduceMotion {
            withAnimation(DS.Motion.smooth) { columns = next }
        } else {
            columns = next
        }
    }
}

extension View {
    /// 监听容器可用宽度并在跨越列数断点时以平滑动画更新列数。
    func dsTrackColumns(
        _ columns: Binding<Int>,
        minWidth: CGFloat,
        spacing: CGFloat,
        maxColumns: Int? = nil,
        horizontalPadding: CGFloat = Console.contentPadding
    ) -> some View {
        modifier(
            DSTrackColumnsModifier(
                columns: columns,
                minWidth: minWidth,
                spacing: spacing,
                maxColumns: maxColumns,
                horizontalPadding: horizontalPadding))
    }
}
