// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import SwiftUI

// MARK: - Console palette (compatibility aliases)
//
// 控制台页面还在引用的旧 token 名。取值全部来自 `DS`
// （UI/DesignSystem.swift）；旧版的粉强调与大圆角已经退役，当前是
// Liquid Glass 的 slate / indigo 色阶。新代码直接用 `DS`。

extension Color {
    init(console hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

/// 兼容别名：取值全部来自 `DS`（UI/DesignSystem.swift）。新代码直接用 `DS`。
enum Console {
    static let backgroundTop = DS.canvas
    static let backgroundBottom = DS.canvas
    static let sidebar = DS.bg
    static let sidebarEdge = DS.line

    static let card = DS.surface
    static let cardStrong = DS.raised
    static let cardStroke = DS.line
    static let inset = Color.adaptive(dark: 0xFFFFFF, light: 0x09090B, darkAlpha: 0.04, lightAlpha: 0.04)
    static let insetStroke = DS.line

    static let text = DS.text
    static let secondary = DS.text2
    static let tertiary = DS.text3

    static let accent = DS.accent
    static let accentDeep = Color.adaptive(dark: 0x2563EB, light: 0x0969DA)
    static let accentSoft = DS.accentSoft

    static let userBubble = Color.adaptive(dark: 0x262626, light: 0xEFEFEF)
    static let userBubbleStroke = DS.line
    static let assistantBubble = Color.clear
    static let assistantBubbleStroke = Color.clear

    static let ok = DS.ok
    static let warn = DS.warn
    static let danger = DS.err
    static let info = DS.info

    static let glassFill = DS.raised
    static let glassGroup = DS.hover
    static let glassStroke = DS.line2
    static let glassSelected = DS.raised
    static let ink = DS.ink
    static let inkForeground = DS.inkText

    static let shadow = DS.shadow

    // Geometry
    static let cardRadius: CGFloat = DS.Radius.lg
    static let heroRadius: CGFloat = DS.Radius.lg
    static let pillRadius: CGFloat = DS.Radius.md
    static let sidebarWidth: CGFloat = DS.Layout.sidebarWidth
    static let titlebarHeight: CGFloat = DS.Layout.titlebarHeight
    static let contentPadding: CGFloat = DS.Space.xxl
    /// 主视口的上下边界（顶栏悬浮在页面之上，内容区从顶栏下方 8pt 起步，滚动时平滑滑入顶栏玻璃之下）。
    static let titlebarGap: CGFloat = DS.Space.xl
    static let contentTopInset: CGFloat = DS.Layout.titlebarHeight + DS.Space.sm
    static let contentBottomInset: CGFloat = DS.Space.xxl
    /// 页面顶栏（无全局标题栏占位，紧贴顶部窗口区域，与红绿灯保持 `25pt` 同一中线）。
    static let pageTopPadding: CGFloat = 1
    /// 侧栏隐藏时页面顶部行首需避让左上角红绿灯与展开按钮（按钮止于 `110pt`，留 `16pt` 间距）。
    static func topBarLeading(sidebarShown: Bool, base: CGFloat = contentPadding) -> CGFloat {
        sidebarShown ? base : max(base, 126)
    }
    /// 无顶部工具栏的纯滚动页面顶部留白：展开侧栏时紧凑贴顶，收起时让出红绿灯与折叠按钮高度。
    static func scrollTopInset(sidebarShown: Bool) -> CGFloat {
        sidebarShown ? DS.Space.lg : contentTopInset
    }
    /// 内容区宽度低于这个值时，多栏页面切换为单栏纵向排布。
    static let compactContentWidth: CGFloat = 900

    // Type
    static let heroTitle = DS.Font.title
    static let cardTitle = DS.Font.md.weight(.medium)
    static let body = DS.Font.md
    static let small = DS.Font.sm
    static let tiny = DS.Font.xs
    static let mono = DS.Font.mono(12)
    static let metric = DS.Font.number(22)

    /// 日志级别色统一走控制台调色板，避免和页面其余状态色出现两套色阶。
    static func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .error: return danger
        case .warning: return warn
        case .success: return ok
        case .system: return info
        case .info: return secondary
        }
    }
}

// MARK: - Card surface

/// 全应用兼容卡片表面：转发到原生 Liquid Glass `dsSurface`。
private struct ConsoleCardSurfaceModifier: ViewModifier {
    var radius: CGFloat
    var tint: Color?
    var interactive: Bool

    func body(content: Content) -> some View {
        content
            .dsSurface(
                radius: radius,
                tint: tint,
                hoverable: interactive)
    }
}

extension View {
    /// 套上模型页卡片那层表面。默认圆角与模型卡一致，内边距由调用方自己加。
    func consoleCardSurface(
        radius: CGFloat = Console.cardRadius,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(ConsoleCardSurfaceModifier(radius: radius, tint: tint, interactive: interactive))
    }
}

struct GlassCard<Content: View>: View {
    var radius: CGFloat = Console.cardRadius
    var padding: CGFloat = 20
    var tint: Color = .clear
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .consoleCardSurface(
                radius: radius,
                tint: tint == .clear ? nil : tint.opacity(0.16))
    }
}

// MARK: - Buttons

/// 兼容别名：转发到 `DSButtonStyle`。
struct ConsolePillStyle: PrimitiveButtonStyle {
    enum Tone { case primary, secondary, soft, danger, success }

    var tone: Tone = .secondary
    var compact: Bool = false

    private var kind: DSButtonStyle.Kind {
        switch tone {
        case .primary: return .primary
        case .danger: return .danger
        case .soft: return .ghost
        case .secondary, .success: return .secondary
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
        }
        .buttonStyle(DSButtonStyle(kind: kind, size: compact ? .small : .regular))
    }
}

extension PrimitiveButtonStyle where Self == ConsolePillStyle {
    static var consolePrimary: ConsolePillStyle { ConsolePillStyle(tone: .primary) }
    static var consoleSecondary: ConsolePillStyle { ConsolePillStyle(tone: .secondary) }
    static var consoleSoft: ConsolePillStyle { ConsolePillStyle(tone: .soft) }
    static var consoleDanger: ConsolePillStyle { ConsolePillStyle(tone: .danger) }
    static var consoleSuccess: ConsolePillStyle { ConsolePillStyle(tone: .success) }
}

/// 引擎主按钮：ZCode 风格圆角矩形实色按钮，底色跟引擎强调色走。
struct EngineColorButton: ButtonStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        EngineColorButtonBody(configuration: configuration, color: color)
    }
}

private struct EngineColorButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let color: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var activeHover: Bool { hovering && isEnabled }

    var body: some View {
        let shape = DS.rect(DS.Radius.md)
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(shape.fill(activeHover ? color.opacity(0.88) : color))
            .contentShape(shape)
            .scaleEffect((!reduceMotion && configuration.isPressed && isEnabled) ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(reduceMotion ? nil : DS.Motion.snappy, value: configuration.isPressed)
            .animation(reduceMotion ? nil : DS.Motion.snappy, value: activeHover)
            .onHover { hovering = $0 }
    }
}

/// ZCode 风格圆角矩形分段控件：实体浅凹槽轨道 + 内层滑块卡片，与 `DSSearchField` 同高同圆角语言。
struct NativeSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [Value]
    var labels: [String]
    var width: CGFloat? = nil
    var size: DSButtonStyle.Size = .regular

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator
    @State private var hoveredIndex: Int?

    init(
        selection: Binding<Value>, options: [Value], labels: [String], width: CGFloat? = nil,
        size: DSButtonStyle.Size = .regular
    ) {
        self._selection = selection
        self.options = options
        self.labels = labels
        self.width = width
        self.size = size
    }

    init(
        selection: Binding<Value>, options: [(value: Value, label: String)], width: CGFloat? = nil,
        size: DSButtonStyle.Size = .regular
    ) {
        self._selection = selection
        self.options = options.map(\.value)
        self.labels = options.map(\.label)
        self.width = width
        self.size = size
    }

    private var height: CGFloat {
        switch size {
        case .small: return 24
        case .regular: return DS.Layout.controlHeight
        case .large: return 34
        }
    }

    private var fontSize: CGFloat {
        switch size {
        case .small: return 11.5
        case .regular: return 12
        case .large: return 13
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .small: return 8
        case .regular: return 11
        case .large: return 14
        }
    }

    private var trackFill: Color { DS.pillFill }

    private var activeFill: Color { DS.pillActive }

    var body: some View {
        let trackShape = DS.rect(DS.Radius.md)
        let segmentShape = DS.rect(DS.Radius.sm)
        HStack(spacing: 2) {
            ForEach(Array(zip(options, labels).enumerated()), id: \.offset) { index, pair in
                let isSelected = selection == pair.0
                let isHovered = isEnabled && hoveredIndex == index && !isSelected
                Button {
                    guard isEnabled, !isSelected else { return }
                    if reduceMotion {
                        selection = pair.0
                    } else {
                        withAnimation(DS.Motion.snappy) {
                            selection = pair.0
                        }
                    }
                } label: {
                    Text(L10n.t(pair.1))
                        .font(.system(size: fontSize, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? DS.text : (isHovered ? DS.text : DS.text2))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, horizontalPadding)
                        .frame(maxWidth: width != nil ? .infinity : nil, maxHeight: .infinity)
                        .background {
                            if isSelected {
                                segmentShape
                                    .fill(activeFill)
                                    .overlay(segmentShape.strokeBorder(DS.pillBorder, lineWidth: 1))
                                    .shadow(color: DS.glassShadow.opacity(0.7), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "activeSegment", in: indicator)
                            } else if isHovered {
                                segmentShape
                                    .fill(DS.hover)
                            }
                        }
                        .contentShape(segmentShape)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .onHover { inside in
                    let next = inside ? index : (hoveredIndex == index ? nil : hoveredIndex)
                    if reduceMotion {
                        hoveredIndex = next
                    } else {
                        withAnimation(DS.Motion.snappy) {
                            hoveredIndex = next
                        }
                    }
                }
            }
        }
        .padding(2)
        .frame(width: width, height: height)
        .background(trackShape.fill(trackFill))
        .overlay(trackShape.strokeBorder(DS.line, lineWidth: 1))
        .opacity(isEnabled ? 1 : 0.45)
        .animation(reduceMotion ? nil : DS.Motion.snappy, value: selection)
    }
}

// MARK: - Small parts

struct IconTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 32

    var body: some View {
        DS.rect(DS.Radius.md)
            .fill(color.opacity(0.12))
            .frame(width: size, height: size)
            .overlay(DS.rect(DS.Radius.md).strokeBorder(color.opacity(0.22), lineWidth: 1))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(color)
            }
    }
}

struct LetterTile: View {
    var letter: String
    var color: Color
    var size: CGFloat = 32

    var body: some View {
        DS.rect(DS.Radius.md)
            .fill(color.opacity(0.12))
            .frame(width: size, height: size)
            .overlay(DS.rect(DS.Radius.md).strokeBorder(color.opacity(0.22), lineWidth: 1))
            .overlay {
                Text(letter)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
            }
    }
}

struct ConsoleTag: View {
    var text: String
    var tone: TagTone = .neutral
    var fontSize: CGFloat = 11

    var body: some View {
        Text(L10n.t(text))
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(DS.rect(DS.Radius.sm).fill(tone.background))
            .overlay(DS.rect(DS.Radius.sm).strokeBorder(tone.stroke, lineWidth: 1))
            .fixedSize()
    }
}

/// 卡片里的规格表（ENGINE / FORMAT / QUANT / SIZE）：细分隔线横向排版。
struct SpecTable: View {
    var items: [(label: String, value: String)]

    var body: some View {
        VStack(spacing: 0) {
            DSDivider()
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.t(item.label))
                            .font(DS.Font.mono(9, weight: .medium))
                            .tracking(0.5)
                            .foregroundStyle(DS.text3)
                        Text(L10n.t(item.value))
                            .font(DS.Font.mono(11.5, weight: .medium))
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, index == 0 ? 2 : 10)
                    .padding(.vertical, 8)
                    if index != items.count - 1 {
                        DSDivider(vertical: true)
                            .padding(.vertical, 6)
                    }
                }
            }
            DSDivider()
        }
    }
}

/// 兼容状态标签：转发到 `DSChip`。
struct StatusChip: View {
    var text: String
    var color: Color
    var filled: Bool = false

    var body: some View {
        DSChip(
            text: text,
            dot: color,
            live: filled && color == DS.ok,
            tint: filled ? color : nil)
    }
}

/// 「最近对话」每一行行尾的删除按钮：平时让位给时间读数，行悬停时才显形。
struct RowDeleteButton: View {
    var action: () -> Void

    @State private var overButton = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(overButton ? DS.err : DS.text3)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .help("删除这段对话")
        .accessibilityLabel(Text("删除这段对话"))
        .onHover { value in
            withAnimation(DS.Motion.snappy) { overButton = value }
        }
    }
}
