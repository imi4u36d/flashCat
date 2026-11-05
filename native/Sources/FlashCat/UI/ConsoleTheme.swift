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

enum Console {
    // Canvas: #EAEEF7 → #F7F9FE, with a pink wash top-right and blue bottom-left.
    static let backgroundTop = Color.adaptive(dark: 0x14131A, light: 0xEAEEF7)
    static let backgroundBottom = Color.adaptive(dark: 0x0F0E14, light: 0xF7F9FE)
    static let sidebar = Color.adaptive(dark: 0x18171F, light: 0xF2F5FC, darkAlpha: 0.86, lightAlpha: 0.92)
    static let sidebarEdge = Color.adaptive(dark: 0x2A2833, light: 0xE1E5EF)

    static let card = Color.adaptive(dark: 0x201E27, light: 0xFFFFFF, darkAlpha: 0.72, lightAlpha: 0.78)
    static let cardStrong = Color.adaptive(dark: 0x262430, light: 0xFFFFFF, darkAlpha: 0.9, lightAlpha: 0.92)
    static let cardStroke = Color.adaptive(dark: 0x2E2B38, light: 0xE3E7F1, darkAlpha: 1, lightAlpha: 0.9)
    static let inset = Color.adaptive(dark: 0xFFFFFF, light: 0x1B1B22, darkAlpha: 0.05, lightAlpha: 0.035)
    static let insetStroke = Color.adaptive(dark: 0xFFFFFF, light: 0x1B1B22, darkAlpha: 0.06, lightAlpha: 0.05)

    static let text = Color.adaptive(dark: 0xF2F0F6, light: 0x15151D)
    static let secondary = Color.adaptive(dark: 0xA8A5B2, light: 0x5F606B)
    static let tertiary = Color.adaptive(dark: 0x807D8A, light: 0x9294A0)

    static let accent = Color.adaptive(dark: 0xF06B96, light: 0xD1487A)
    static let accentDeep = Color.adaptive(dark: 0xD94A7C, light: 0xBE3568)
    static let accentSoft = Color.adaptive(dark: 0x3A2230, light: 0xFBE8F0)

    static let ok = Color.adaptive(dark: 0x4CC96B, light: 0x2F9E5B)
    static let warn = Color.adaptive(dark: 0xE8A33D, light: 0xB97A16)
    static let danger = Color.adaptive(dark: 0xF26B58, light: 0xC43A2F)
    static let info = Color.adaptive(dark: 0x6FA8F5, light: 0x2F6FD0)

    static let shadow = Color.adaptive(dark: 0x000000, light: 0x43506E,
                                       darkAlpha: 0.45, lightAlpha: 0.10)

    // Geometry
    static let cardRadius: CGFloat = 20
    static let heroRadius: CGFloat = 24
    static let pillRadius: CGFloat = 999
    static let sidebarWidth: CGFloat = 200
    static let titlebarHeight: CGFloat = 54
    static let contentPadding: CGFloat = 24

    // Type
    static let heroTitle = Font.system(size: 30, weight: .bold)
    static let cardTitle = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let small = Font.system(size: 11.5)
    static let tiny = Font.system(size: 10.5)
    static let mono = Font.system(size: 11.5, design: .monospaced)
    static let metric = Font.system(size: 24, weight: .bold, design: .monospaced)
}

// MARK: - Page background

struct ConsoleBackdrop: View {
    var accent: Color = Console.accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LinearGradient(colors: [Console.backgroundTop, Console.backgroundBottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [accent.opacity(scheme == .dark ? 0.12 : 0.10), .clear],
                           center: UnitPoint(x: 0.82, y: -0.05),
                           startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Console.info.opacity(scheme == .dark ? 0.06 : 0.05), .clear],
                           center: UnitPoint(x: -0.05, y: 1.02),
                           startRadius: 0, endRadius: 620)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Glass card

struct GlassCard<Content: View>: View {
    var radius: CGFloat = Console.cardRadius
    var strong: Bool = false
    var padding: CGFloat = 20
    var tint: Color = .clear
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background {
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                shape
                    .fill(strong ? Console.cardStrong : Console.card)
                    .overlay {
                        if tint != .clear {
                            shape.fill(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.02)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                    }
                    .overlay {
                        shape.strokeBorder(Console.cardStroke, lineWidth: 1)
                    }
                    .shadow(color: Console.shadow, radius: 22, x: 0, y: 10)
            }
    }
}

// MARK: - Buttons

struct ConsolePillStyle: ButtonStyle {
    enum Tone { case primary, secondary, soft, danger, success }

    @Environment(\.isEnabled) private var isEnabled
    var tone: Tone = .secondary
    var compact: Bool = false

    private var foreground: Color {
        switch tone {
        case .primary, .danger, .success: return .white
        case .secondary: return Console.text
        case .soft: return Console.secondary
        }
    }

    private var background: AnyShapeStyle {
        switch tone {
        case .primary:
            return AnyShapeStyle(LinearGradient(colors: [Console.accent, Console.accentDeep],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        case .danger:
            return AnyShapeStyle(Native.red.opacity(0.14))
        case .success:
            return AnyShapeStyle(Native.green.opacity(0.16))
        case .secondary:
            return AnyShapeStyle(Console.inset)
        case .soft:
            return AnyShapeStyle(Console.inset.opacity(0.7))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
            .foregroundStyle(tone == .danger ? Native.red : (tone == .success ? Native.green : foreground))
            .padding(.horizontal, compact ? 11 : 14)
            .frame(height: compact ? 28 : 34)
            .background(background, in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    tone == .primary ? Color.white.opacity(0.22) : Console.insetStroke,
                    lineWidth: 0.8)
            }
            .shadow(color: tone == .primary ? Console.accent.opacity(0.28) : .clear,
                    radius: 10, x: 0, y: 4)
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.42)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
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
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Capsule().fill(color))
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.8))
            .shadow(color: color.opacity(0.28), radius: 8, y: 3)
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.42)
    }
}

// MARK: - Small parts

struct IconTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
            .fill(color.opacity(0.14))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(color)
            }
    }
}

struct LetterTile: View {
    var letter: String
    var color: Color
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.opacity(0.13))
            .frame(width: size, height: size)
            .overlay {
                Text(letter)
                    .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(color.opacity(0.20), lineWidth: 1)
            }
    }
}

struct ConsoleTag: View {
    var text: String
    var tone: TagTone = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tone.background))
            .overlay(Capsule().strokeBorder(tone.foreground.opacity(0.12), lineWidth: 0.8))
            .fixedSize()
    }
}

/// 卡片里的三段式规格表（ENGINE / FORMAT / SIZE）。
struct SpecTable: View {
    var items: [(label: String, value: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.label)
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Console.tertiary)
                    Text(item.value)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Console.text)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                if index != items.count - 1 {
                    Rectangle()
                        .fill(Console.insetStroke)
                        .frame(width: 1)
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Console.inset)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 环形/圆点状态标签（WebUI 的 ● 已停止）。
struct StatusChip: View {
    var text: String
    var color: Color
    var filled: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(filled ? color : Console.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(filled ? color.opacity(0.10) : Console.inset))
    }
}
