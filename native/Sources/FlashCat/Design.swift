// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import SwiftUI

// MARK: - Palette
//
// 菜单栏面板、原生浮层与 AppKit 控件仍在读的旧 token 名。取值全部指向
// `DS`（UI/DesignSystem.swift）——那里才是唯一视觉源，新代码不要再写
// `Native.xxx`。保留这一层是因为视图树里还有大量旧引用，逐个改名的风险
// 大于收益；等新代码替换完就可以整块删掉。

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

/// 兼容别名：取值全部来自 `DS`（UI/DesignSystem.swift）。新代码直接用 `DS`。
enum Native {
    static let surface = DS.canvas
    static let surfaceDeep = DS.canvas
    static let canvas = DS.surface
    static let sidebar = DS.bg
    static let hairline = DS.line
    static let stroke = DS.line2
    static let recess = DS.bg
    static let panel = DS.raised
    static let raised = DS.raised

    /// The colour AppKit paints behind the hidden title bar.
    static let windowBackground = NSColor.adaptive(dark: 0x161616, light: 0xF8F8F8)

    static let label = DS.text
    static let secondary = DS.text2
    static let tertiary = DS.text3

    static let accent = DS.accent
    static let accentSoft = DS.accentSoft
    static let metricNum = Color(nsColor: .consoleText)
    static let pink = Color(nsColor: .consoleAccent)
    static let violet = Color.adaptive(dark: 0x9B87F5, light: 0x6D59C9)
    static let cyan = Color.adaptive(dark: 0x38BDF8, light: 0x0284C7)
    static let mint = Color.adaptive(dark: 0x34D399, light: 0x059669)
    static let amber = Color.adaptive(dark: 0xFBBF24, light: 0xD97706)
    static let indigo = Color.adaptive(dark: 0x818CF8, light: 0x4F46E5)

    // Status —— ok / warn / err / info，日间加深、夜间提亮保对比。
    static let green = DS.ok
    static let yellow = DS.warn
    static let orange = Color.adaptive(dark: 0xFB923C, light: 0xEA580C)
    static let red = DS.err
    static let blue = DS.info
    static let purple = Color.adaptive(dark: 0xC084FC, light: 0x7C3AED)
    static let teal = Color.adaptive(dark: 0x2DD4BF, light: 0x0D9488)
    static let gray = DS.text3

    static let glassEdgeTop = DS.line2
    static let glassEdgeBottom = DS.line
    static let panelShadow = DS.shadow

    static let sheetBase = DS.canvas
    static let sheetShadow = DS.shadow
    /// Dimming layer behind floating panels.
    static let scrim = DS.scrim

    // Primary（唯一主动作）：墨色底两副皮肤通用。
    static let pillFill = DS.ink
    static let pillText = DS.inkText

    // Toast capsule.
    static let toastFill = DS.floating

    /// Translucent overlay that flips direction with the skin: white lifts the
    /// night canvas, near-black recesses the daylight one.
    static func overlay(_ opacity: Double) -> Color {
        .adaptiveOverlay(opacity)
    }

    // Geometry —— ZCode 同心圆角：小控件 6 / 行内卡 8 / 面板 10 / 窗口级 12
    static let radiusSmall: CGFloat = DS.Radius.sm
    static let radiusTile: CGFloat = DS.Radius.md
    static let radiusPanel: CGFloat = DS.Radius.lg
    static let radiusHero: CGFloat = DS.Radius.xl
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

    static let sidebarWidth: CGFloat = 204
    // 收起后的图标栏。宽度要容得下红绿灯并留出右侧留白，
    // 否则侧栏右缘会紧贴绿灯，标题栏看起来像被切掉了一角。
    static let railWidth: CGFloat = 96
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

/// Page backdrop: clean, warm neutral wash without neon radial glow.
struct PageBackdrop: View {
    var accent: Color = Native.accent

    var body: some View {
        LinearGradient(
            colors: [Native.surface, Native.surfaceDeep],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// 旧调用点兼容：忽略颜色，只保留画布。
struct ArcadeBackdrop: View {
    var colors: [Color]

    var body: some View {
        PageBackdrop()
    }
}

// MARK: - Surface

/// 面板表面：ZCode 实色分层表面 + 1px 发丝边框。
struct GlassSurface: View {
    var radius: CGFloat = DS.Radius.lg
    var tint: Color = .clear
    var elevated: Bool = true

    var body: some View {
        let shape = DS.rect(radius)
        ZStack {
            shape.fill(elevated ? DS.surface : DS.bg)
            if tint != .clear {
                shape.fill(tint.opacity(0.12))
            }
        }
        .overlay(shape.strokeBorder(DS.line, lineWidth: 1))
    }
}

// MARK: - Motion

/// 统一的动效节奏。交互反馈 140 ms，页面/浮层 220 ms，入场用轻弹簧。
/// 所有自定义动画都从这里取，避免每个视图各写一套时长。
/// 兼容别名：映射到 `DS.Motion` 的四种曲线。
enum Motion {
    static let quick = DS.Motion.snappy
    static let standard = DS.Motion.smooth
    static let entrance = DS.Motion.smooth
    /// 灵动岛展开/收起：轻微过冲再回弹。
    static let island = DS.Motion.bouncy
    /// 引导页与控制台之间的交叉淡入淡出。
    static let pageCrossfade = Animation.smooth(duration: 0.36)
    static let pulse = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)
}

/// 运行中的呼吸点：转发到 `DSStatusDot`。
struct LiveDot: View {
    var color: Color = DS.ok
    var diameter: CGFloat = 7

    var body: some View {
        DSStatusDot(color: color, live: true, size: diameter)
            .accessibilityHidden(true)
    }
}

/// 可交互的卡片表面：hover 时轻微提亮、描边染上强调色并浮起 1–2 pt；
/// `active` 用更强的强调色边与底色标记「当前」。动效服从 reduce-motion。
struct HoverSurface<Content: View>: View {
    var radius: CGFloat = DS.Radius.lg
    var accent: Color = DS.accent
    var active: Bool = false
    var padding: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding ?? 0)
            .dsSurface(
                radius: radius,
                tint: active ? accent.opacity(0.14) : nil,
                stroke: active ? accent.opacity(0.45) : nil,
                hoverable: true,
                active: active
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

/// `.plain` 的命中区修正版：把整块 label 背景都算作可点击区域。
/// 原生 `.plain` 只按 label 实际绘制的字形算命中区，玻璃底和 padding
/// 往往点不到，表现为「必须点到图标才会触发」。
struct PlainHitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PlainHitButtonStyle {
    static var plainHit: PlainHitButtonStyle { PlainHitButtonStyle() }
}

/// 胶囊按钮。`light` 是墨色主胶囊（唯一主动作样式）；`glass` 是描边次级；
/// `accent` 是强调色胶囊；`quietDanger` 是弱化的红字危险操作。
/// 交互规则：hover 不缩放不上浮，只轻提亮 —— 动效收敛到 120ms ease-out。
struct ArcadePillStyle: PrimitiveButtonStyle {
    enum Tone { case light, glass, accent, danger, quietDanger }

    var tone: Tone = .glass
    var compact: Bool = false

    private var mappedKind: DSButtonStyle.Kind {
        switch tone {
        case .light, .accent: return .primary
        case .glass: return .secondary
        case .danger, .quietDanger: return .danger
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
        }
        .buttonStyle(DSButtonStyle(kind: mappedKind, size: compact ? .small : .regular))
    }
}

extension PrimitiveButtonStyle where Self == ArcadePillStyle {
    static var arcadePill: ArcadePillStyle { ArcadePillStyle(tone: .light) }
    static var arcadeGlass: ArcadePillStyle { ArcadePillStyle(tone: .glass) }
    static var arcadeAccent: ArcadePillStyle { ArcadePillStyle(tone: .accent) }
    static var arcadeDanger: ArcadePillStyle { ArcadePillStyle(tone: .danger) }
    static var arcadePillCompact: ArcadePillStyle { ArcadePillStyle(tone: .light, compact: true) }
    static var arcadeGlassCompact: ArcadePillStyle { ArcadePillStyle(tone: .glass, compact: true) }
}

/// 克制的扁平圆角图标方块：使用单色符号搭配柔和同色底，替代糖果渐变与立体高光。
struct ArcadeIcon: View {
    var symbol: String
    var colors: [Color]
    var brandAsset: String? = nil
    var size: CGFloat = 28
    var glyphScale: CGFloat = 0.46
    var glow: Bool = true

    private var primaryColor: Color {
        colors.first ?? DS.accent
    }

    var body: some View {
        let shape = DS.rect(size <= 28 ? DS.Radius.sm : DS.Radius.md)
        ZStack {
            shape.fill(primaryColor.opacity(0.12))
            if let brandAsset, let artwork = BrandGlyph.image(named: brandAsset) {
                Image(nsImage: artwork)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(primaryColor)
                    .frame(width: size * 0.56, height: size * 0.56)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * glyphScale, weight: .semibold))
                    .foregroundStyle(primaryColor)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            shape.strokeBorder(primaryColor.opacity(0.22), lineWidth: 1)
        )
    }
}

/// 品牌字形资源：Lobe Icons 的 PNG 以 alpha 遮罩保存，渲染时统一染成白色。
@MainActor
enum BrandGlyph {
    private static var cache: [String: NSImage] = [:]
    private static var artworkCache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        guard let original = load(named: name, cache: &artworkCache) else { return nil }
        if let cached = cache[name] { return cached }
        original.isTemplate = true
        cache[name] = original
        return original
    }

    /// 原始配色的品牌图，用于引擎官方 app icon，不能当模板染色。
    static func artwork(named name: String) -> NSImage? {
        load(named: name, cache: &artworkCache)
    }

    private static func load(named name: String, cache: inout [String: NSImage]) -> NSImage? {
        if let cached = cache[name] { return cached }

        let bundleName = "FlashCat_FlashCat.bundle"
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            roots.append(executable)
        }
        roots.append(Bundle.main.bundleURL)

        var url: URL?
        for root in roots {
            let bundleURL = root.appendingPathComponent(bundleName)
            if let resources = Bundle(url: bundleURL),
                let found = resources.url(forResource: name, withExtension: "png")
            {
                url = found
                break
            }
        }
        if url == nil {
            url = Bundle.main.url(forResource: name, withExtension: "png")
        }
        guard let url, let artwork = NSImage(contentsOf: url) else { return nil }
        cache[name] = artwork
        return artwork
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

    /// The artwork's silhouette spans ~83 % of the canvas (ears to chin), so
    /// draw it slightly oversized to fill the requested frame.
    private static let artworkScale: CGFloat = 1.19

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
                let image = NSImage(contentsOf: url)
            {
                return image
            }
        }
        // Copy the build script drops straight into Contents/Resources.
        if let url = Bundle.main.url(forResource: "app-icon", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        {
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
        DSStatusDot(color: color, live: pulsing, size: diameter)
    }
}

enum TagTone {
    case neutral, accent, success, warning, danger

    var foreground: Color {
        switch self {
        case .neutral: return DS.text2
        case .accent: return DS.accent
        case .success: return DS.ok
        case .warning: return DS.warn
        case .danger: return DS.err
        }
    }

    var background: Color {
        switch self {
        case .neutral: return DS.bg
        case .accent: return DS.accentSoft
        case .success: return DS.ok.opacity(0.12)
        case .warning: return DS.warn.opacity(0.12)
        case .danger: return DS.err.opacity(0.12)
        }
    }

    var stroke: Color {
        switch self {
        case .neutral: return DS.line
        case .accent: return DS.accent.opacity(0.25)
        case .success: return DS.ok.opacity(0.25)
        case .warning: return DS.warn.opacity(0.25)
        case .danger: return DS.err.opacity(0.25)
        }
    }
}

/// Inline status or metadata tag.
struct Tag: View {
    let text: String
    var tone: TagTone = .neutral
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(L10n.t(text))
                .font(DS.Font.xs.weight(.medium))
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tone.background, in: DS.rect(DS.Radius.sm))
        .overlay(
            DS.rect(DS.Radius.sm)
                .strokeBorder(tone.stroke, lineWidth: 1)
        )
        .fixedSize()
    }
}

struct Eyebrow: View {
    var text: String
    var color: Color = Native.tertiary

    var body: some View {
        Text(L10n.t(text))
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

    init(
        _ title: String? = nil,
        subtitle: String? = nil,
        trailing: AnyView? = nil,
        padded: Bool = true,
        tint: Color = .clear,
        @ViewBuilder content: () -> Content
    ) {
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
                            Text(L10n.t(title))
                                .font(DS.Font.md.weight(.semibold))
                                .foregroundStyle(DS.text)
                        }
                        if let subtitle {
                            Text(L10n.t(subtitle))
                                .font(DS.Font.xs)
                                .foregroundStyle(DS.text3)
                        }
                    }
                    Spacer(minLength: 8)
                    if let trailing { trailing }
                }
            }
            content
        }
        .padding(padded ? 16 : 0)
        .dsSurface(
            radius: DS.Radius.lg,
            tint: tint == .clear ? nil : tint.opacity(0.14),
            stroke: tint == .clear ? nil : tint.opacity(0.30)
        )
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
                Text(L10n.t(label))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Native.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !loading, let badge {
                    Text(L10n.t(badge))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint.opacity(0.9))
                }
            }

            if loading {
                SkeletonBar(width: 86, height: 24, radius: 7, opacity: 0.10)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(L10n.t(value))
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
                Text(L10n.t(detail))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .dsSurface(
            radius: Native.radiusPanel,
            tint: tint == .clear ? nil : tint.opacity(0.10)
        )
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
                Text(L10n.t(label))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Native.secondary)
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
                    Text(L10n.t(value))
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
        .dsSurface(
            radius: Native.radiusPanel,
            tint: hero ? DS.accentSoft : nil,
            stroke: hero ? DS.accent.opacity(0.35) : nil,
            hoverable: true,
            active: hero
        )
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
        .dsSurface(radius: Native.radiusPanel)
        .animation(.easeOut(duration: 0.16), value: statusText)
        .animation(.easeOut(duration: 0.16), value: failure)
    }
}

struct Meter: View {
    let fraction: Double
    var tint: Color = DS.accent
    var height: CGFloat = 5

    var body: some View {
        DSMeter(value: fraction, tint: tint)
    }
}

/// Determinate circular progress with the percent in the middle. Used by the
/// engine cards so build + install read as one continuous run; the step text
/// lives beside the ring, not inside it.
struct ProgressRing: View {
    let fraction: Double
    var tint: Color = DS.accent
    var size: CGFloat = 30
    var lineWidth: CGFloat = 3.5

    private var clamped: Double { min(max(fraction, 0), 1) }
    private var percent: Int { Int((clamped * 100).rounded()) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(DS.line2, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(clamped))
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text(verbatim: "\(percent)%")
                .font(DS.Font.mono(size * 0.28, weight: .semibold))
                .foregroundStyle(DS.text2)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .frame(width: size, height: size)
        .animation(DS.Motion.smooth, value: clamped)
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
                LinearGradient(
                    colors: [.clear, Native.overlay(0.22), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
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
            Text(L10n.t(label))
                .font(.system(size: 11.5))
                .foregroundStyle(Native.secondary)
            Spacer(minLength: 8)
            if loading {
                SkeletonBar(width: 68, height: 9, opacity: 0.10)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.5 }
            } else {
                Text(L10n.t(value))
                    .font(mono ? Native.monoFont : Native.bodyFont)
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(L10n.t(detail))
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

    init(
        title: String,
        subtitle: String? = nil,
        eyebrow: String? = nil,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
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
                Text(L10n.t(title))
                    .font(Native.pageTitle)
                    .tracking(-0.6)
                    .foregroundStyle(Native.label)
                if let subtitle {
                    Text(L10n.t(subtitle))
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

/// Icon button used in headers and toolbars.
struct IconAction: View {
    let systemName: String
    var help: String = ""
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        DSIconButton(
            systemName: systemName,
            help: help,
            size: 28,
            style: .outlined,
            active: active,
            action: action
        )
    }
}

/// Circular label for a `Menu`, so a menu reads exactly like `IconAction`.
struct IconMenuLabel: View {
    let systemName: String
    var active: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? DS.inkText : DS.text)
            .frame(width: 18, height: 18)
    }
}

struct EmptyHint: View {
    var icon: String = "tray"
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(DS.text3)
                .frame(width: 44, height: 44)
                .dsSurface(radius: DS.Radius.lg)
            Text(L10n.t(title))
                .font(DS.Font.md.weight(.medium))
                .foregroundStyle(DS.text2)
            if let detail {
                Text(L10n.t(detail))
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
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
        let shape = DS.rect(DS.Radius.md)
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.accent)
            Text(message)
                .font(DS.Font.sm.weight(.medium))
                .foregroundStyle(DS.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(shape.fill(DS.floating))
        .overlay(shape.strokeBorder(DS.line2, lineWidth: 1))
        .shadow(color: DS.shadow, radius: 14, y: 6)
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

// MARK: - Page identity

extension Page {
    /// Two-stop key colour used by the sidebar selection, the page wash and the
    /// empty-state illustration. The canvas itself stays neutral.
    var keyColors: [Color] {
        switch self {
        case .overview:
            return [Color(hex: 0xFF9F0A), Color(hex: 0xFF375F), Color(hex: 0x7B2CBF)]
        case .chat:
            return [Color(hex: 0x7C5CFF), Color(hex: 0x0A84FF), Color(hex: 0x00C7BE)]
        case .models:
            return [Color(hex: 0x30D158), Color(hex: 0x00C7BE), Color(hex: 0x0A84FF)]
        case .engines:
            return [Color(hex: 0x0A84FF), Color(hex: 0x30D158), Color(hex: 0x00C7BE)]
        case .logs:
            return [Color(hex: 0xFFD60A), Color(hex: 0xFF9F0A), Color(hex: 0xFF453A)]
        case .settings:
            return [Color(hex: 0x5E5CE6), Color(hex: 0xBF5AF2), Color(hex: 0xFF375F)]
        case .lab:
            return [Color(hex: 0xFF9F0A), Color(hex: 0xBF5AF2), Color(hex: 0x0A84FF)]
        }
    }

    var keyColor: Color { keyColors.first ?? Native.accent }
}
