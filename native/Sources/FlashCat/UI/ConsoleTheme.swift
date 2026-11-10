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

    static let glassFill = Color.adaptive(dark: 0xFFFFFF, light: 0xFFFFFF,
                                          darkAlpha: 0.14, lightAlpha: 0.72)
    static let glassGroup = Color.adaptive(dark: 0xFFFFFF, light: 0x000000,
                                           darkAlpha: 0.08, lightAlpha: 0.045)
    static let glassStroke = Color.adaptive(dark: 0xFFFFFF, light: 0x000000,
                                            darkAlpha: 0.12, lightAlpha: 0.06)
    static let glassSelected = Color.adaptive(dark: 0xFFFFFF, light: 0xFFFFFF,
                                              darkAlpha: 0.22, lightAlpha: 0.96)
    static let ink = Color.adaptive(dark: 0xF5F3F8, light: 0x1B1B20)
    static let inkForeground = Color.adaptive(dark: 0x16151B, light: 0xFFFFFF)

    static let shadow = Color.adaptive(dark: 0x000000, light: 0x43506E,
                                       darkAlpha: 0.45, lightAlpha: 0.10)

    // Geometry
    static let cardRadius: CGFloat = 20
    static let heroRadius: CGFloat = 24
    static let pillRadius: CGFloat = 999
    static let sidebarWidth: CGFloat = 200
    static let titlebarHeight: CGFloat = 54
    static let contentPadding: CGFloat = 24
    /// 内容区宽度低于这个值时，多栏页面切换为单栏纵向排布。
    /// 侧栏展开时对应约 1180pt 的窗口宽度，缩放窗口时页面会先于内容被挤坏前重排。
    static let compactContentWidth: CGFloat = 980

    // Type
    static let heroTitle = Font.system(size: 30, weight: .bold)
    static let cardTitle = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let small = Font.system(size: 11.5)
    static let tiny = Font.system(size: 10.5)
    static let mono = Font.system(size: 11.5, design: .monospaced)
    static let metric = Font.system(size: 24, weight: .bold, design: .monospaced)

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
                            // SwiftUI 会复用 `.blur` 产生的滤镜图层，只改半径时
                            // 不重绘；把半径并进身份，半径一变就重建图层。
                            // 见 `BackgroundSettings.blurIdentity`。
                            .id(background.blurIdentity)
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

// MARK: - Card surface

/// 全应用唯一的卡片表面。模型页的模型卡是基准：20pt 连续圆角 + Liquid Glass，
/// 选中或悬停时只叠一层很淡的强调色，不再另加实心底色、描边或投影。
///
/// 这里只管“表面”，不管尺寸：卡片的内边距、整体大小与内容排版仍由调用方决定。
private struct ConsoleCardSurfaceModifier: ViewModifier {
    var radius: CGFloat
    var tint: Color?
    var interactive: Bool

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var glassTint: Color? {
        if let tint { return tint }
        guard interactive, hovering else { return nil }
        return Console.accent.opacity(0.05)
    }

    func body(content: Content) -> some View {
        content
            .background {
                LiquidGlassSurface(
                    shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
                    tint: glassTint
                )
            }
            .onHover { value in
                guard interactive else { return }
                if reduceMotion {
                    hovering = value
                } else {
                    withAnimation(Motion.quick) { hovering = value }
                }
            }
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

struct ConsolePillStyle: ButtonStyle {
    enum Tone { case primary, secondary, soft, danger, success }

    @Environment(\.isEnabled) private var isEnabled
    var tone: Tone = .secondary
    var compact: Bool = false

    private var foreground: Color {
        switch tone {
        case .primary: return Console.inkForeground
        case .danger: return Native.red
        case .success: return Console.text
        case .secondary, .soft: return Console.text
        }
    }

    private var glassTint: Color? {
        switch tone {
        case .primary: return Console.ink
        case .danger: return Native.red.opacity(0.55)
        case .success: return Console.ok.opacity(0.32)
        case .secondary, .soft: return nil
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 11 : 14)
            .frame(height: compact ? 28 : 32)
            .background {
                LiquidGlassSurface(shape: Capsule(), tint: glassTint, interactive: true)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.42)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Games app 风格的玻璃分段组：浅色/白色选中胶囊，未选中是灰字，选中态不用强调色。
struct GamesSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var width: CGFloat? = nil

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let active = selection == option.value
                Button {
                    withAnimation(.smooth(duration: 0.22)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Console.text : Console.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background {
                            if active {
                                Capsule()
                                    .fill(Console.glassSelected)
                                    .overlay(Capsule().strokeBorder(Console.glassStroke, lineWidth: 0.6))
                                    .shadow(color: Console.shadow.opacity(0.7), radius: 6, y: 2)
                                    .matchedGeometryEffect(id: "games.segment", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plainHit)
            }
        }
        .padding(3)
        .background(Capsule().fill(Console.glassGroup))
        .overlay(Capsule().strokeBorder(Console.glassStroke, lineWidth: 0.8))
        .frame(width: width)
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
            .contentShape(Capsule())
    }
}

/// macOS 26 原生分段按钮组（Liquid Glass）。按钮组类控件统一走系统样式，
/// 不再自绘胶囊，避免每个页面各有一套「选中态」。
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
        Group {
            if #available(macOS 27.0, *) {
                // `.tabs` 是 macOS 27 的原生“标签式分段控件”，视觉上刻意区别
                // 于普通 `.segmented` 值选择器：玻璃胶囊选中态、按压拖动选中、
                // 系统动画都由 AppKit 绘制（Games app 用的就是这一种），
                // 不能再叠 `.tint` 强调色。
                //
                // 不要再套 `.clipShape(Capsule())`：裁剪会连同 AppKit 在按住时
                // 画在轨道边缘外的玻璃高光/透镜一起裁掉，表现为「按下后玻璃消失」。
                picker.pickerStyle(.tabs)
            } else {
                picker.pickerStyle(.segmented)
                    // 旧系统的轨道默认是圆角矩形，裁成胶囊才能和 macOS 27 的外观一致。
                    .clipShape(Capsule())
            }
        }
        .labelsHidden()
        .controlSize(.large)
        .frame(width: width)
    }

    private var picker: some View {
        Picker("", selection: $selection) {
            ForEach(Array(zip(options, labels)), id: \.0) { value, label in
                Text(L10n.t(label)).tag(value)
            }
        }
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
    var fontSize: CGFloat = 10.5

    var body: some View {
        Text(L10n.t(text))
            .font(.system(size: fontSize, weight: .medium))
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
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t(item.label))
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Console.tertiary)
                    Text(L10n.t(item.value))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Console.text)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
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
            Text(L10n.t(text))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(filled ? color : Console.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(filled ? color.opacity(0.10) : Console.inset))
    }
}
