import SwiftUI
import AppKit

// MARK: - Console palette (paper & ink)
//
// One quiet, warm-neutral palette for every console page: an opaque paper
// canvas, hairline rules instead of nested cards, and a single burnt-orange
// accent reserved for the primary action, the selected row marker and live
// readings. No gradients, no glass, no per-page colour themes.

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
    // One opaque paper canvas. The two stops are kept only because
    // `BackgroundSettings` still layers a user image over a gradient; both are
    // the same colour so the page reads flat.
    static let backgroundTop = Color.adaptive(dark: 0x16130F, light: 0xF7F4EE)
    static let backgroundBottom = Color.adaptive(dark: 0x16130F, light: 0xF7F4EE)
    static let sidebar = Color.adaptive(dark: 0x16130F, light: 0xF2EEE6)
    static let sidebarEdge = Color.adaptive(dark: 0x2E2921, light: 0xE1DACC)

    /// A raised sheet. Used sparingly: terminals, dialogs and the few places
    /// where content genuinely needs a boundary. Lists use hairlines instead.
    static let card = Color.adaptive(dark: 0x1D1A15, light: 0xFCFAF6)
    static let cardStrong = Color.adaptive(dark: 0x232019, light: 0xFFFFFF)
    static let cardStroke = Color.adaptive(dark: 0x332D25, light: 0xE1DACC)
    static let panel = Color.adaptive(dark: 0x1A1712, light: 0xFBF9F4)
    static let hairline = Color.adaptive(dark: 0x2C2720, light: 0xE4DED2)
    static let inset = Color.adaptive(dark: 0xFFFFFF, light: 0x1B1B22, darkAlpha: 0.05, lightAlpha: 0.035)
    static let insetStroke = Color.adaptive(dark: 0xFFFFFF, light: 0x1B1B22, darkAlpha: 0.06, lightAlpha: 0.05)
    static let rowHover = Color.adaptive(dark: 0xFFFFFF, light: 0x1B1B22, darkAlpha: 0.045, lightAlpha: 0.035)
    static let rowSelected = Color.adaptive(dark: 0xFFFFFF, light: 0x1B1B22, darkAlpha: 0.075, lightAlpha: 0.055)

    static let text = Color(nsColor: .consoleText)
    static let secondary = Color.adaptive(dark: 0xA8A195, light: 0x5F5A50)
    static let tertiary = Color.adaptive(dark: 0x7D766A, light: 0x8C8578)
    static let quaternary = Color.adaptive(dark: 0x625C51, light: 0xABA394)

    static let accent = Color(nsColor: .consoleAccent)
    static let accentDeep = Color.adaptive(dark: 0xF5A176, light: 0x8C3410)
    static let accentSoft = Color.adaptive(dark: 0x34231A, light: 0xF2E2D6)

    // Chat: the user's message is a plain neutral block, the answer is bare
    // text on the canvas. Neither derives from the accent.
    static let userBubble = Color.adaptive(dark: 0x2A2620, light: 0xEDE7DB)
    static let userBubbleStroke = Color.adaptive(dark: 0x37322B, light: 0xDED6C7)
    static let assistantBubble = Color.adaptive(dark: 0x16130F, light: 0xF7F4EE)
    static let assistantBubbleStroke = Color.adaptive(dark: 0x16130F, light: 0xF7F4EE)

    static let ok = Color.adaptive(dark: 0x72B98D, light: 0x3F7D52)
    static let warn = Color.adaptive(dark: 0xD7A04B, light: 0x94660F)
    static let danger = Color.adaptive(dark: 0xE07A68, light: 0xA63B2F)
    static let info = Color.adaptive(dark: 0x82A9C5, light: 0x3B6382)

    static let glassFill = Color.adaptive(dark: 0xFFFFFF, light: 0xFFFFFF,
                                          darkAlpha: 0.05, lightAlpha: 0.5)
    static let glassGroup = Color.adaptive(dark: 0xFFFFFF, light: 0x000000,
                                           darkAlpha: 0.05, lightAlpha: 0.04)
    static let glassStroke = Color.adaptive(dark: 0xFFFFFF, light: 0x000000,
                                            darkAlpha: 0.08, lightAlpha: 0.05)
    static let glassSelected = Color.adaptive(dark: 0xFFFFFF, light: 0x000000,
                                              darkAlpha: 0.10, lightAlpha: 0.06)
    static let ink = Color.adaptive(dark: 0xEFEAE0, light: 0x22201C)
    static let inkForeground = Color.adaptive(dark: 0x16130F, light: 0xFFFFFF)

    static let shadow = Color.adaptive(dark: 0x000000, light: 0x2C2822,
                                       darkAlpha: 0.50, lightAlpha: 0.10)

    // Geometry
    static let cardRadius: CGFloat = 10
    static let heroRadius: CGFloat = 12
    static let pillRadius: CGFloat = 999
    static let sidebarWidth: CGFloat = 200
    static let titlebarHeight: CGFloat = 54
    static let contentPadding: CGFloat = 24
    /// 主视口的上下边界。导航列和六个页面都读这两个值，窗口一缩放，
    /// 侧栏边和右侧内容的起止线始终是同一条，不会一高一低。
    static let titlebarGap: CGFloat = 12
    static let contentTopInset: CGFloat = titlebarHeight + titlebarGap
    static let contentBottomInset: CGFloat = contentPadding
    /// 内容区宽度低于这个值时，多栏页面切换为单栏纵向排布。
    static let compactContentWidth: CGFloat = 980

    // Type
    static let heroTitle = Font.system(size: 28, weight: .semibold)
    static let cardTitle = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let small = Font.system(size: 11.5)
    static let tiny = Font.system(size: 10.5)
    static let mono = Font.system(size: 11.5, design: .monospaced)
    static let metric = Font.system(size: 24, weight: .semibold, design: .monospaced)
    /// Small uppercase label used above values and as section eyebrows.
    static let eyebrow = Font.system(size: 10, weight: .semibold)

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
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var background = BackgroundSettings.shared

    var body: some View {
        ZStack {
            // 画布始终保留原来的渐变与页面强调色，自定义图片只是叠在渐变之上，
            // 不会改动页面、表面和文字的观感。没有图片时，渐变按「APP 透明度」
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

/// 安静的面板表面：一层接近画布的实色 + 1px 发丝边，没有玻璃、投影或
/// 强调色洗底。只在终端、弹层和确实需要边界的块上使用；列表用分隔线分组。
///
/// 参数 `tint` 仅为兼容旧调用保留，会被忽略。
private struct ConsoleCardSurfaceModifier: ViewModifier {
    var radius: CGFloat
    var tint: Color?
    var interactive: Bool

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(interactive && hovering ? Console.inset : Console.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Console.cardStroke, lineWidth: 1)
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
    var padding: CGFloat = 16
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
        case .danger: return Console.danger
        case .success: return Console.ok
        case .secondary, .soft: return Console.text
        }
    }

    private var fill: Color {
        switch tone {
        case .primary: return Console.accent
        case .danger: return Console.danger.opacity(0.10)
        case .success: return Console.ok.opacity(0.10)
        case .secondary: return .clear
        case .soft: return Console.inset
        }
    }

    private var stroke: Color {
        switch tone {
        case .primary, .soft: return .clear
        case .danger: return Console.danger.opacity(0.30)
        case .success: return Console.ok.opacity(0.28)
        case .secondary: return Console.cardStroke
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 11 : 14)
            .frame(height: compact ? 26 : 30)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.38)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// 轻量分段组：一条 inset 底 + 选中项实色小方块，不用玻璃和投影。
struct GamesSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var width: CGFloat? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let active = selection == option.value
                Button {
                    withAnimation(.smooth(duration: 0.18)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Console.text : Console.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Console.cardStrong)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(Console.cardStroke, lineWidth: 1)
                                    }
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plainHit)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Console.inset))
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
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Console.inkForeground)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Console.accent))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.38)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// macOS 26 原生分段按钮组（Liquid Glass）。按钮组类控件统一走系统样式，
/// 不再自绘胶囊，避免每个页面各有一套「选中态」。
/// 文字分段：一排标签，选中项只改文字颜色并画一条短下划线。
/// 不用系统 segmented 的玻璃轨道——一排设置页里叠三块灰底会让页面重新变“重”。
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
        HStack(spacing: 14) {
            ForEach(Array(zip(options, labels).enumerated()), id: \.offset) { _, pair in
                let selected = selection == pair.0
                Button {
                    selection = pair.0
                } label: {
                    VStack(spacing: 4) {
                        Text(L10n.t(pair.1))
                            .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                            .foregroundStyle(selected ? Console.text : Console.tertiary)
                        Rectangle()
                            .fill(selected ? Console.accent : .clear)
                            .frame(height: 1.5)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plainHit)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(Motion.quick, value: selection)
        .frame(width: width, alignment: .leading)
    }
}

// MARK: - Small parts

struct IconTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(Console.secondary)
            .frame(width: size, height: size)
    }
}

struct LetterTile: View {
    var letter: String
    var color: Color
    var size: CGFloat = 44

    var body: some View {
        Text(letter)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(Console.secondary)
            .frame(width: size, height: size)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Console.cardStroke, lineWidth: 1)
            }
    }
}

/// 规格标签：不再做成彩色胶囊，只是一段小字；多个标签之间靠间距分隔。
struct ConsoleTag: View {
    var text: String
    var tone: TagTone = .neutral
    var fontSize: CGFloat = 10.5

    private var isNeutral: Bool {
        if case .neutral = tone { return true }
        return false
    }

    var body: some View {
        Text(L10n.t(text))
            .font(.system(size: fontSize, weight: .regular))
            .foregroundStyle(isNeutral ? Console.tertiary : tone.foreground)
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
        .overlay(alignment: .top) {
            Rectangle().fill(Console.hairline).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Console.hairline).frame(height: 1)
        }
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
        .fixedSize()
    }
}

/// 「最近对话」每一行行尾的删除按钮：平时让位给时间读数，行悬停时才显形。
///
/// 常驻垃圾桶会让六行历史各顶一个红色标记，和行尾读数抢注意力；只留右键
/// 菜单又少了能看见的入口。所以它占的是行尾本来就空着的那一格：读数淡出、
/// 它淡入，行宽与基线都不动。着色分两级——挂在这一行上是中性的，真指着
/// 按钮才转红，避免鼠标扫过列表时一片警报色。
struct RowDeleteButton: View {
    var action: () -> Void

    @State private var overButton = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(overButton ? Console.danger : Console.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .help("删除这段对话")
        .accessibilityLabel(Text("删除这段对话"))
        .onHover { value in
            withAnimation(Motion.quick) { overButton = value }
        }
    }
}



// MARK: - Quiet chrome

/// 28pt 一类的裸图标按钮：平时没有底，只在悬停时浮出一层极淡的圆角。
struct QuietHover: ViewModifier {
    var cornerRadius: CGFloat = 6
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(hovering ? Console.rowHover : .clear)
            }
            .onHover { hovering = $0 }
    }
}

extension View {
    func quietHover(cornerRadius: CGFloat = 6) -> some View {
        modifier(QuietHover(cornerRadius: cornerRadius))
    }
}
