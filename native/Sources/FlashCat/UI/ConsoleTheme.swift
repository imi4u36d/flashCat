// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import SwiftUI
import AppKit

// MARK: - Console palette (matches the shipped WebUI's visual language)
//
// The WebUI is the visual source of truth: a cool, very light glass canvas,
// white translucent cards with 20 pt corners, pink accent (#D1487A), soft blue
// shadows, and 13–15 pt type. These tokens replace the older warm "instrument"
// palette for the console pages; the menu bar panel keeps `Native`.

extension Color {
    init(console hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
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
    static let accentDeep = Color.adaptive(dark: 0xE8590C, light: 0xC2410C)
    static let accentSoft = DS.accentSoft

    static let userBubble = DS.raised
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
    /// 主视口的上下边界（标题栏已上提为顶栏，内容只需保留正常顶边距）。
    static let titlebarGap: CGFloat = DS.Space.xl
    static let contentTopInset: CGFloat = DS.Space.xl
    static let contentBottomInset: CGFloat = DS.Space.xxl
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

// MARK: - Page background

struct ConsoleBackdrop: View {
    var accent: Color = Console.accent
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var background = BackgroundSettings.shared

    var body: some View {
        ZStack {
            // 画布始终保留原来的渐变与页面强调色，自定义图片只是叠在渐变之上，
            // 不会改动页面、玻璃卡片和文字的观感。没有图片时，渐变按「APP 透明度」
            // 让出桌面：0 = 完全不透明，1 = 完全透出桌面。
            LinearGradient(colors: [Console.backgroundTop, Console.backgroundBottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(background.image == nil ? 1 - background.desktopReveal : 1)

            if let image = background.image {
                // 用透明视图定尺寸、图片只做 overlay：避免 `scaledToFill` 的图片把
                // 画布撑高，进而把整个界面顶上去。
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            // 柔化：保留照片质感，又不让细节和高对比线条
                            // 直接和侧栏、页面文字抢视觉。半径可在设置里调整。
                            .blur(radius: background.blur)
                            .scaleEffect(1.1)
                            // 不要给这一层加 `.id`：半径一变就换身份，SwiftUI 会
                            // 把整块图片图层销毁重建，拖动时窗口出帧掉到一半、
                            // 画面整块跳变（用户看到的就是「拖模糊条闪屏」）。
                            // 现在的 `.blur` 会跟着半径重绘，不需要抖身份。
                    }
                    .clipped()

                // 无论图片多清晰，都盖一层画布渐变保底，保证文字始终有足够对比度。
                // 「APP 透明度」越高，这层越淡，但不低于保底值；剩下的行程
                // 线性铺开，滑杆不会有一半是空的。见 `BackgroundMath.veilOpacity`。
                LinearGradient(colors: [Console.backgroundTop, Console.backgroundBottom],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(BackgroundMath.veilOpacity(background.opacity,
                                                        dark: scheme == .dark))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Card surface

/// 全应用唯一的卡片表面：转发到 `dsSurface`（纯色 + 1px 描边，无玻璃无阴影）。
private struct ConsoleCardSurfaceModifier: ViewModifier {
    var radius: CGFloat
    var tint: Color?
    var interactive: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if let tint {
                    DS.rect(min(radius, DS.Radius.lg)).fill(tint.opacity(0.35))
                }
            }
            .dsSurface(radius: min(radius, DS.Radius.lg),
                       fill: DS.surface,
                       stroke: tint == nil ? DS.line : DS.line2,
                       hoverable: interactive)
    }
}

extension View {
    /// 套上模型页卡片那层表面。默认圆角与模型卡一致，内边距由调用方自己加。
    func consoleCardSurface(radius: CGFloat = Console.cardRadius,
                            tint: Color? = nil,
                            interactive: Bool = false) -> some View {
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
            .consoleCardSurface(radius: radius,
                                tint: tint == .clear ? nil : tint.opacity(0.16))
    }
}

// MARK: - Buttons

/// 兼容别名：转发到 `DSButtonStyle`。
struct ConsolePillStyle: ButtonStyle {
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
        DSButtonStyle(kind: kind, size: compact ? .small : .regular).makeBody(configuration: configuration)
    }
}

extension ButtonStyle where Self == ConsolePillStyle {
    static var consolePrimary: ConsolePillStyle { ConsolePillStyle(tone: .primary) }
    static var consoleSecondary: ConsolePillStyle { ConsolePillStyle(tone: .secondary) }
    static var consoleSoft: ConsolePillStyle { ConsolePillStyle(tone: .soft) }
    static var consoleDanger: ConsolePillStyle { ConsolePillStyle(tone: .danger) }
    static var consoleSuccess: ConsolePillStyle { ConsolePillStyle(tone: .success) }
}

/// 引擎主按钮：底色跟引擎强调色走（Splash 橙、oMLX 青、MTPLX 紫、MLX 蓝、Strata 绿）。
struct EngineColorButton: ButtonStyle {
    var color: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: DS.Layout.controlHeight)
            .background(DS.rect(DS.Radius.md).fill(color))
            .overlay(DS.rect(DS.Radius.md).strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.4)
            .animation(DS.Motion.snappy, value: configuration.isPressed)
            .contentShape(DS.rect(DS.Radius.md))
    }
}

/// 分段控件：转发到 `DSSegmented`。
struct NativeSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [Value]
    var labels: [String]
    var width: CGFloat? = nil

    init(selection: Binding<Value>, options: [Value], labels: [String], width: CGFloat? = nil) {
        self._selection = selection
        self.options = options
        self.labels = labels
        self.width = width
    }

    init(selection: Binding<Value>, options: [(value: Value, label: String)], width: CGFloat? = nil) {
        self._selection = selection
        self.options = options.map(\.value)
        self.labels = options.map(\.label)
        self.width = width
    }

    var body: some View {
        DSSegmented(selection: $selection,
                    options: Array(zip(options, labels)).map { (value: $0.0, label: $0.1) })
            .frame(width: width, alignment: .leading)
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
        DSChip(text: text,
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

