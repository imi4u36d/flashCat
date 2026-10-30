import SwiftUI
import AppKit

// MARK: - Palette
//
// 设计方向：「精密仪器」（docs/ui/redesign-precision-instrument.html）。
// 画布退后，数据向前，状态即视觉 —— 页面底色是暖纸白（日）/ 暖石墨（夜），
// 卡片是纯色面板 + 1px 毛发描边，数字是等宽大读数，状态色是页面里
// 饱和度最高的颜色。品牌日出渐变只允许出现在三处（App 图标与侧栏 Logo、
// AI 消息头像、对话空状态），禁止扩散到画布和卡片。
//
// 两副皮肤共享同一套语义 token，取值随外观解析（见 Theme.swift），
// 视图层永远不分支判断当前皮肤。

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum Native {
    // Canvas —— 页面画布（暖纸白 / 暖石墨）
    static let surface = Color.adaptive(dark: 0x16130F, light: 0xF5F2EC)
    // Panel —— 卡片面板（纯色，靠描边分层而非玻璃+投影）
    static let canvas = Color.adaptive(dark: 0x1E1A15, light: 0xFFFFFF)
    static let sidebar = Color.adaptive(dark: 0x1A1611, light: 0xECE7DE)
    // 毛发描边：卡片 1px 分层线（hairline）与更强的分隔线（stroke）
    static let hairline = Color.adaptive(dark: 0x322B22, light: 0xE7E1D7)
    static let stroke = Color.adaptive(dark: 0x3E362A, light: 0xD8D0C3)
    // 比画布更暗一档的凹槽面（输入框、地址栏）
    static let recess = Color.adaptive(dark: 0x14110D, light: 0xEFEBE4)
    // 面板上的弱填充小件（日志页行内 chip 等）
    static let panel = Color.adaptive(dark: 0xFFFFFF, light: 0x221E1A,
                                      darkAlpha: 0.05, lightAlpha: 0.045)
    // 凹槽面板（日志正文区、输入框底）：比面板再沉一档
    static let raised = Color.adaptive(dark: 0x241F19, light: 0xFBFAF7)

    /// The colour AppKit paints behind the hidden title bar.
    static let windowBackground = NSColor.adaptive(dark: 0x16130F, light: 0xF5F2EC)

    // Type —— 三级暖灰阶，全部 AA 达标（tertiary 是最浅可用文字色）
    static let label = Color.adaptive(dark: 0xEFEAE1, light: 0x221E1A)
    static let secondary = Color.adaptive(dark: 0xA79E91, light: 0x5F594F)
    static let tertiary = Color.adaptive(dark: 0x8A8175, light: 0x736C64)

    // Brand + accents。accent 是唯一主强调色；accentSoft 是它的弱化底。
    // metricNum 专用于 ≥20pt 的仪表大读数，正文强调一律用 accent。
    static let accent = Color.adaptive(dark: 0xFF7A45, light: 0xC43E12)
    static let accentSoft = Color.adaptive(dark: 0x33231A, light: 0xFBEDE5)
    static let metricNum = Color.adaptive(dark: 0xFF9D6F, light: 0xB23A0F)
    static let pink = Color.adaptive(dark: 0xFF375F, light: 0xD81B45)
    static let violet = Color.adaptive(dark: 0x8B5CF6, light: 0x6D28D9)
    static let cyan = Color.adaptive(dark: 0x22D3EE, light: 0x0E7490)
    static let mint = Color.adaptive(dark: 0x4CC96B, light: 0x1E7F3C)
    static let amber = Color.adaptive(dark: 0xE8A33D, light: 0x9A6200)
    static let indigo = Color.adaptive(dark: 0x5E5CE6, light: 0x4338CA)

    // Status —— ok / warn / err / info，日间加深、夜间提亮保对比。
    static let green = Color.adaptive(dark: 0x4CC96B, light: 0x1E7F3C)
    static let yellow = Color.adaptive(dark: 0xE8A33D, light: 0x9A6200)
    static let orange = Color.adaptive(dark: 0xE8A33D, light: 0x9A6200)
    static let red = Color.adaptive(dark: 0xF26B58, light: 0xC03424)
    static let blue = Color.adaptive(dark: 0x6FA8F5, light: 0x1F5FBF)
    static let purple = Color.adaptive(dark: 0xBF5AF2, light: 0x8944AB)
    static let teal = Color.adaptive(dark: 0x40C8E0, light: 0x0E7490)
    static let gray = Color.adaptive(dark: 0x8A8175, light: 0x736C64)

    // 面板填充：日间纯白、夜间暖石墨，玻璃渐变已废弃；
    // glassTop/glassBottom 仅剩 ChatView 的两处旧调用点，取同一值即为纯色。
    static let glassTop = Color.adaptive(dark: 0x1E1A15, light: 0xFFFFFF)
    static let glassBottom = Color.adaptive(dark: 0x1E1A15, light: 0xFFFFFF)
    static let glassEdgeTop = Color.adaptive(dark: 0x322B22, light: 0xE7E1D7)
    static let glassEdgeBottom = Color.adaptive(dark: 0x322B22, light: 0xE7E1D7)
    static let panelShadow = Color.adaptive(dark: 0x000000, light: 0x000000,
                                            darkAlpha: 0.38, lightAlpha: 0.07)

    // 浮层基底（对话参数面板等）：直接用面板色。
    static let sheetBase = Color.adaptive(dark: 0x241F19, light: 0xFBFAF7)
    // 浮层（对话画布）唯一允许的一层投影 —— elevation 只到窗口级。
    static let sheetShadow = Color.adaptive(dark: 0x000000, light: 0x000000,
                                            darkAlpha: 0.35, lightAlpha: 0.10)
    /// Dimming layer behind floating panels.
    static let scrim = Color.adaptive(dark: 0x000000, light: 0x000000,
                                      darkAlpha: 0.12, lightAlpha: 0.10)

    // Primary（唯一主动作）胶囊：墨色底两副皮肤通用。
    static let pillFill = Color.adaptive(dark: 0xEFEAE1, light: 0x221E1A)
    static let pillText = Color.adaptive(dark: 0x16130F, light: 0xF5F2EC)

    // Toast capsule.
    static let toastFill = Color.adaptive(dark: 0x000000, light: 0xFFFFFF,
                                          darkAlpha: 0.35, lightAlpha: 0.92)

    /// Translucent overlay that flips direction with the skin: white lifts the
    /// night canvas, near-black recesses the daylight one.
    static func overlay(_ opacity: Double) -> Color {
        .adaptiveOverlay(opacity)
    }

    // Geometry —— 仪器化圆角：小控件 7 / 行内卡 9 / 面板 12 / 窗口级 16
    static let radiusSmall: CGFloat = 7
    static let radiusTile: CGFloat = 9
    static let radiusPanel: CGFloat = 12
    static let radiusHero: CGFloat = 16
    static let pagePadding: CGFloat = 20
    static let cardPadding: CGFloat = 14
    static let gap: CGFloat = 12

    // Type scale —— 数字是主角：大读数用等宽 + tabular
    static let pageTitle = Font.system(size: 28, weight: .bold)
    static let sectionTitle = Font.system(size: 19, weight: .bold)
    static let cardTitle = Font.system(size: 15, weight: .semibold)
    static let bodyFont = Font.system(size: 13)
    static let calloutFont = Font.system(size: 12)
    static let captionFont = Font.system(size: 11)
    static let metricFont = Font.system(size: 13, weight: .semibold)
    static let monoFont = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 10.5, design: .monospaced)
    /// 仪表大读数（≥20pt 专用，配 Native.metricNum 取色）。
    static let metricNumFont = Font.system(size: 30, weight: .bold, design: .monospaced)

    static let sidebarWidth: CGFloat = 244
    static let railWidth: CGFloat = 68
}

extension View {
    /// The page column every workspace page shares: full width, so cards,
    /// headers and grids keep the same edges when switching pages and grow
    /// with the window instead of leaving a gutter on the right.
    func pageColumn(maxHeight: CGFloat? = nil) -> some View {
        frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
    }
}

// MARK: - Page backdrop

/// Page backdrop: a single warm canvas — the instrument direction keeps the
/// page quiet so status and numbers are the loudest elements.
struct ArcadeBackdrop: View {
    var colors: [Color]

    var body: some View {
        Native.surface
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

// MARK: - Surface

/// 面板表面：纯色填充 + 1px 毛发描边。以「描边分层」替代旧版的
/// 玻璃渐变 + 投影分层；卡内不再用投影，投影只保留在窗口级浮层。
struct GlassSurface: View {
    var radius: CGFloat = Native.radiusPanel
    var tint: Color = .clear
    var elevated: Bool = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(tint == .clear ? Native.canvas : tint.opacity(0.10))
            .overlay {
                if tint != .clear {
                    shape.fill(tint.opacity(0.06))
                }
            }
            .overlay(
                shape.strokeBorder(Native.hairline, lineWidth: 1)
            )
    }
}

// MARK: - Buttons

/// Wrapper that tracks pointer hover for a button style's body, so pill
/// buttons get the same hover feedback `IconAction` already has.
private struct HoverObserving<Content: View>: View {
    @State private var hovering = false
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        content(hovering)
            .onHover { hovering = $0 }
    }
}

/// 胶囊按钮。`light` 是墨色主胶囊（唯一主动作样式）；`glass` 是描边次级；
/// `accent` 是强调色胶囊；`quietDanger` 是弱化的红字危险操作。
/// 交互规则：hover 不缩放不上浮，只轻提亮 —— 动效收敛到 120ms ease-out。
struct ArcadePillStyle: ButtonStyle {
    enum Tone { case light, glass, accent, danger, quietDanger }

    @Environment(\.isEnabled) private var isEnabled

    var tone: Tone = .glass
    var compact: Bool = false

    private var foreground: Color {
        switch tone {
        case .light: return Native.pillText
        case .glass: return Native.label
        case .accent, .danger: return .white
        case .quietDanger: return Native.red
        }
    }

    private var background: AnyShapeStyle {
        switch tone {
        case .light:
            return AnyShapeStyle(Native.pillFill)
        case .glass:
            return AnyShapeStyle(Native.overlay(0.10))
        case .quietDanger:
            return AnyShapeStyle(Native.red.opacity(0.12))
        case .accent:
            return AnyShapeStyle(Native.accent)
        case .danger:
            return AnyShapeStyle(Native.red.opacity(0.92))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        HoverObserving { hovering in
            configuration.label
                .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, compact ? 12 : 15)
                .frame(height: compact ? 28 : 32)
                .background(background, in: Capsule())
                .overlay(Capsule().stroke(Native.overlay(0.14).opacity(tone == .light ? 0 : 1), lineWidth: 0.8))
                .brightness(hovering && isEnabled && tone != .light ? 0.06 : 0)
                .opacity(!isEnabled ? 0.34 : (configuration.isPressed ? 0.9 : 1))
                .scaleEffect(configuration.isPressed && isEnabled ? 0.975 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Capsule())
        }
    }
}

extension ButtonStyle where Self == ArcadePillStyle {
    static var arcadePill: ArcadePillStyle { ArcadePillStyle(tone: .light) }
    static var arcadeGlass: ArcadePillStyle { ArcadePillStyle(tone: .glass) }
    static var arcadeAccent: ArcadePillStyle { ArcadePillStyle(tone: .accent) }
    static var arcadeDanger: ArcadePillStyle { ArcadePillStyle(tone: .danger) }
    static var arcadePillCompact: ArcadePillStyle { ArcadePillStyle(tone: .light, compact: true) }
    static var arcadeGlassCompact: ArcadePillStyle { ArcadePillStyle(tone: .glass, compact: true) }
}

/// Colourful squircle icon tile — reserved for content illustration
/// (empty states, engine tiles). Never used for page navigation.
struct ArcadeIcon: View {
    var symbol: String
    var colors: [Color]
    var size: CGFloat = 28
    var glyphScale: CGFloat = 0.46
    var glow: Bool = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: colors.isEmpty ? [Native.violet, Native.blue] : colors,
                                      startPoint: .topLeading,
                                      endPoint: .bottomTrailing))
            shape.fill(
                LinearGradient(colors: [.white.opacity(0.30), .clear],
                               startPoint: .top,
                               endPoint: .center)
            )
            Image(systemName: symbol)
                .font(.system(size: size * glyphScale, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.28), radius: 1.5, x: 0, y: 1)
        }
        .frame(width: size, height: size)
        .overlay(
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.8)
        )
    }
}

/// The flashCat mark — the shipped app icon itself, not a redraw of it.
///
/// `Sources/FlashCat/Resources/app-icon.png` is the single master artwork: the
/// build script compiles it into `Contents/Resources/AppIcon.icns` and embeds
/// the same PNG, so the sidebar header, the assistant bubbles and the Dock all
/// show one icon. Lookup walks the SwiftPM resource bundle by hand instead of
/// `Bundle.module`, whose accessor traps when an un-bundled binary is run.
struct BrandMark: View {
    var size: CGFloat = 38
    var glow: Bool = true

    /// The artwork carries the macOS icon-grid padding (~20 % of the canvas on
    /// every side), so draw it oversized to fill the requested frame.
    private static let artworkScale: CGFloat = 1.24

    var body: some View {
        Group {
            if let icon = BrandMark.artwork {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .scaleEffect(BrandMark.artworkScale)
            } else {
                Image(systemName: "bolt.fill")
                    .font(.system(size: size * 0.52, weight: .bold))
                    .foregroundStyle(Native.accent)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("flashCat")
    }

    /// Resolved once: the artwork is a 1024 px PNG, and every bubble badge
    /// would otherwise re-decode it. Shared with the menu bar status icon.
    @MainActor static let artwork: NSImage? = loadArtwork()

    @MainActor private static func loadArtwork() -> NSImage? {
        let bundleName = "FlashCat_FlashCat.bundle"
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            roots.append(executable)
        }
        roots.append(Bundle.main.bundleURL)

        for root in roots {
            let bundleURL = root.appendingPathComponent(bundleName)
            guard let resources = Bundle(url: bundleURL) else { continue }
            if let url = resources.url(forResource: "app-icon", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        // Copy the build script drops straight into Contents/Resources.
        if let url = Bundle.main.url(forResource: "app-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApplication.shared.applicationIconImage
    }
}

// MARK: - Primitives

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Native.hairline)
            .frame(height: 1)
    }
}

struct VHairline: View {
    var body: some View {
        Rectangle()
            .fill(Native.hairline)
            .frame(width: 1)
    }
}

struct StatusDot: View {
    var color: Color
    var diameter: CGFloat = 8
    var pulsing: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay(Circle().stroke(color.opacity(0.22), lineWidth: 3))
            .shadow(color: color.opacity(pulsing ? 0.9 : 0.55),
                    radius: pulsing ? 7 : 4)
    }
}

enum TagTone {
    case neutral, accent, success, warning, danger

    var foreground: Color {
        switch self {
        case .neutral: return Color.adaptive(dark: 0xC9C1B6, light: 0x5F594F)
        case .accent: return Color.adaptive(dark: 0xFF9D6F, light: 0xB23A0F)
        case .success: return Color.adaptive(dark: 0x4CC96B, light: 0x1E7F3C)
        case .warning: return Color.adaptive(dark: 0xE8A33D, light: 0x8A5A08)
        case .danger: return Color.adaptive(dark: 0xF26B58, light: 0xBC1F1B)
        }
    }

    var background: Color {
        switch self {
        case .neutral: return Native.overlay(0.07)
        case .accent: return Native.accent.opacity(0.14)
        case .success: return Native.green.opacity(0.14)
        case .warning: return Native.orange.opacity(0.14)
        case .danger: return Native.red.opacity(0.14)
        }
    }
}

/// Inline capsule label.
struct Tag: View {
    let text: String
    var tone: TagTone = .neutral
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .bold))
            }
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(tone.background, in: Capsule())
        .overlay(Capsule().stroke(tone.foreground.opacity(0.16), lineWidth: 0.8))
        .fixedSize()
    }
}

struct Eyebrow: View {
    var text: String
    var color: Color = Native.tertiary

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .tracking(1.7)
            .foregroundStyle(color)
            .textCase(.uppercase)
    }
}

/// Quiet instrument card: flat panel fill + 1px hairline. Header, optional
/// trailing view, body.
struct Card<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    var trailing: AnyView? = nil
    var padded: Bool = true
    var tint: Color = .clear
    let content: Content

    init(_ title: String? = nil,
         subtitle: String? = nil,
         trailing: AnyView? = nil,
         padded: Bool = true,
         tint: Color = .clear,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.padded = padded
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || subtitle != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let title {
                            Text(title).font(Native.cardTitle)
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(Native.tertiary)
                        }
                    }
                    Spacer(minLength: 8)
                    if let trailing { trailing }
                }
            }
            content
        }
        .padding(padded ? Native.cardPadding : 0)
        .background { GlassSurface(radius: Native.radiusPanel, tint: tint) }
    }
}

/// One number plus a caption. 仪表读数：等宽数字 + Native.metricNum。
struct StatTile: View {
    let label: String
    let value: String
    var unit: String? = nil
    var detail: String? = nil
    var badge: String? = nil
    var tint: Color = Native.accent
    var progress: Double? = nil
    var progressTint: Color? = nil
    var loading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Native.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !loading, let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint.opacity(0.9))
                }
            }

            if loading {
                SkeletonBar(width: 86, height: 24, radius: 7, opacity: 0.10)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundStyle(Native.metricNum)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                    if let unit {
                        Text(unit)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Native.tertiary)
                    }
                }
            }

            if loading {
                SkeletonBar(height: 5, radius: 2.5, opacity: 0.07)
            } else if let progress {
                Meter(fraction: progress, tint: progressTint ?? tint)
            }

            if loading {
                SkeletonBar(width: 96, height: 8, radius: 4, opacity: 0.07)
            } else if let detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background { GlassSurface(radius: Native.radiusPanel, tint: tint) }
        .animation(.easeOut(duration: 0.2), value: loading)
    }
}

/// 仪表指标卡（高保真稿 MOCKUP A 的指标带单元）。
/// `hero` 变体用 accentSoft 底 + accent 描边，是页面里唯一大声的数字。
struct MetricCard: View {
    let label: String
    var tag: String? = nil
    let value: String
    var unit: String? = nil
    var hint: String? = nil
    var hero: Bool = false
    var loading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hero ? Native.secondary : Native.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let tag {
                    Text(tag)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Native.tertiary)
                }
            }

            if loading {
                SkeletonBar(width: 104, height: 30, radius: 7, opacity: 0.10)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: hero ? 30 : 23, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Native.metricNum)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                    if let unit {
                        Text(unit)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Native.tertiary)
                    }
                }
            }

            if loading {
                SkeletonBar(width: 90, height: 9, radius: 4, opacity: 0.07)
            } else if let hint {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background {
            let shape = RoundedRectangle(cornerRadius: Native.radiusPanel, style: .continuous)
            shape.fill(hero ? Native.accentSoft : Native.canvas)
                .overlay {
                    shape.strokeBorder(hero ? Native.accent.opacity(0.28) : Native.hairline,
                                       lineWidth: 1)
                }
        }
        .animation(.easeOut(duration: 0.2), value: loading)
    }
}

/// 引擎状态条（高保真稿 MOCKUP A 第一行）：
/// 色点 + 状态词 + mono 元信息 + 右侧弱提示。状态色是页面里饱和度最高的颜色。
/// 启停唯一入口在侧栏引擎卡（R1），这里只做诚实的状态播报。
struct StatusStrip: View {
    var dotColor: Color
    var statusText: String
    var pulsing: Bool = false
    var meta: [String] = []
    var hint: String? = nil
    var failure: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    StatusDot(color: dotColor, diameter: 8, pulsing: pulsing)
                    Text(statusText)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Native.label)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }

                HStack(spacing: 14) {
                    ForEach(meta, id: \.self) { item in
                        Text(verbatim: item)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Native.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(Native.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let failure {
                VStack(alignment: .leading, spacing: 0) {
                    Hairline()
                    Text(failure)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Native.red)
                        .lineLimit(2)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                }
                .transition(.opacity)
            }
        }
        .background {
            let shape = RoundedRectangle(cornerRadius: Native.radiusPanel, style: .continuous)
            shape.fill(Native.canvas)
                .overlay { shape.strokeBorder(Native.hairline, lineWidth: 1) }
        }
        .animation(.easeOut(duration: 0.16), value: statusText)
        .animation(.easeOut(duration: 0.16), value: failure)
    }
}

struct Meter: View {
    let fraction: Double
    var tint: Color = Native.accent
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Native.overlay(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.24), value: fraction)
    }
}

/// Determinate circular progress with the percent in the middle. Used by the
/// engine cards so build + install read as one continuous run; the step text
/// lives beside the ring, not inside it.
struct ProgressRing: View {
    let fraction: Double
    var tint: Color = Native.accent
    var size: CGFloat = 30
    var lineWidth: CGFloat = 3.5

    private var clamped: Double { min(max(fraction, 0), 1) }
    private var percent: Int { Int((clamped * 100).rounded()) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Native.overlay(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(clamped))
                .stroke(tint,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verbatim: "\(percent)%")
                .font(.system(size: size * 0.28, weight: .semibold, design: .monospaced))
                .foregroundStyle(Native.secondary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.25), value: clamped)
    }
}

/// A single sweeping highlight reused by every skeleton placeholder. The
/// TimelineView only ticks while a placeholder is actually on screen.
struct ShimmerSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let sweep = max(width * 0.55, 28)
                let period: Double = 1.35
                let time = timeline.date.timeIntervalSinceReferenceDate
                let phase = CGFloat(time.truncatingRemainder(dividingBy: period) / period)
                LinearGradient(colors: [.clear, Native.overlay(0.22), .clear],
                               startPoint: .leading,
                               endPoint: .trailing)
                    .frame(width: sweep)
                    .offset(x: -sweep + phase * (width + sweep))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Text-shaped loading placeholder.
struct SkeletonBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 10
    var radius: CGFloat = 5
    var opacity: Double = 0.09

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(Native.overlay(opacity))
            .frame(width: width, height: height)
            .overlay { ShimmerSweep() }
            .clipShape(shape)
    }
}

/// Panel-shaped loading placeholder, used for charts and media areas.
struct SkeletonBlock: View {
    var height: CGFloat? = nil
    var radius: CGFloat = 12
    var opacity: Double = 0.055

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(Native.overlay(opacity))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay { ShimmerSweep() }
            .clipShape(shape)
    }
}

struct KeyValueRow: View {
    let label: String
    var value: String
    var detail: String? = nil
    var mono: Bool = false
    var valueColor: Color = Native.label
    var loading: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Native.secondary)
            Spacer(minLength: 8)
            if loading {
                SkeletonBar(width: 68, height: 9, opacity: 0.10)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.5 }
            } else {
                Text(value)
                    .font(mono ? Native.monoFont : Native.bodyFont)
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Native.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    var eyebrow: String? = nil
    @ViewBuilder let actions: () -> Actions

    init(title: String,
         subtitle: String? = nil,
         eyebrow: String? = nil,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.eyebrow = eyebrow
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                if let eyebrow {
                    Eyebrow(text: eyebrow)
                }
                Text(title)
                    .font(Native.pageTitle)
                    .tracking(-0.6)
                    .foregroundStyle(Native.label)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Native.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) { actions() }
        }
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, eyebrow: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.eyebrow = eyebrow
        self.actions = { EmptyView() }
    }
}

/// Round icon button used in headers and toolbars.
struct IconAction: View {
    let systemName: String
    var help: String = ""
    var active: Bool = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color.white : Native.label.opacity(hovering ? 1 : 0.82))
                .frame(width: 30, height: 30)
                .background {
                    Circle()
                        .fill(active ? AnyShapeStyle(Native.accent)
                                     : AnyShapeStyle(Native.overlay(hovering ? 0.12 : 0.07)))
                }
                .overlay(Circle().stroke(Native.hairline.opacity(active ? 0 : 1), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(isEnabled ? 1 : 0.38)
        .help(help)
    }
}

/// Circular label for a `Menu`, so a menu reads exactly like `IconAction`.
struct IconMenuLabel: View {
    let systemName: String
    var active: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(active ? Color.white : Native.label.opacity(0.82))
            .frame(width: 30, height: 30)
            .background {
                Circle()
                    .fill(active ? AnyShapeStyle(Native.accent)
                                 : AnyShapeStyle(Native.overlay(0.07)))
            }
            .overlay(Circle().stroke(Native.hairline.opacity(active ? 0 : 1), lineWidth: 1))
            .contentShape(Circle())
    }
}

struct EmptyHint: View {
    var icon: String = "tray"
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            ArcadeIcon(symbol: icon,
                       colors: [Native.violet, Native.blue],
                       size: 54,
                       glyphScale: 0.4)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Native.label)
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Native.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

/// Bottom-center transient notice.
struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Native.accent)
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Native.label)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Capsule().fill(Native.toastFill))
        .overlay(Capsule().stroke(Native.overlay(0.16), lineWidth: 0.8))
        .shadow(color: Native.panelShadow, radius: 18, y: 8)
        .padding(.bottom, 20)
    }
}

/// Minimal wrapping layout for tag rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0 && lineWidth + spacing + size.width > width {
                totalHeight += lineHeight + lineSpacing
                maxWidth = max(maxWidth, lineWidth)
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
                lineHeight = max(lineHeight, size.height)
            }
        }
        totalHeight += lineHeight
        maxWidth = max(maxWidth, lineWidth)
        return CGSize(width: min(maxWidth, width == .infinity ? maxWidth : width), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Status helpers

func statusColor(_ state: ServerState) -> Color {
    switch state {
    case .ready: return Native.green
    case .starting, .stopping: return Native.yellow
    case .failed: return Native.red
    case .stopped: return Native.gray
    }
}

func levelColor(_ level: LogLevel) -> Color {
    switch level {
    case .error: return Native.red
    case .warning: return Native.orange
    case .success: return Native.green
    case .system: return Native.blue
    case .info: return Native.secondary
    }
}

func healthTone(_ stats: ServerStats?) -> (label: String, tone: TagTone) {
    guard let stats else { return ("待机", .neutral) }
    if stats.memoryPressure == "critical" { return ("内存紧张", .danger) }
    if stats.memoryPressure == "warning" { return ("内存偏高", .warning) }
    if let thermal = stats.thermal, thermal != "nominal" { return (stats.thermalText, .warning) }
    return ("正常", .success)
}
