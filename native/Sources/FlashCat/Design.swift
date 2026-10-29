import SwiftUI
import AppKit

// MARK: - Palette
//
// The visual language mirrors Apple's Games app: full-bleed gradient key art,
// glass panels with a soft top sheen, oversized rounded type, pill actions and
// colourful squircle icons. Two skins share that language — the original night
// canvas and a daylight one. Every token below resolves per appearance (see
// Theme.swift), so views never branch on the skin. Key art stays saturated with
// white type in both skins, the way a cover image does.

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
    // Canvas
    static let surface = Color.adaptive(dark: 0x07070A, light: 0xF2F2F5)
    static let canvas = Color.adaptive(dark: 0x0B0B10, light: 0xFFFFFF)
    static let sidebar = Color.adaptive(dark: 0x0B0B11, light: 0xECECF1)
    static let panel = Color.adaptive(dark: 0xFFFFFF, light: 0x101014,
                                      darkAlpha: 0.055, lightAlpha: 0.045)
    static let raised = Color.adaptive(dark: 0xFFFFFF, light: 0x101014,
                                       darkAlpha: 0.095, lightAlpha: 0.07)
    static let hairline = Color.adaptive(dark: 0xFFFFFF, light: 0x101014,
                                         darkAlpha: 0.10, lightAlpha: 0.10)
    static let stroke = Color.adaptive(dark: 0xFFFFFF, light: 0x101014,
                                       darkAlpha: 0.13, lightAlpha: 0.13)

    /// The colour AppKit paints behind the hidden title bar.
    static let windowBackground = NSColor.adaptive(dark: 0x07070A, light: 0xF2F2F5)

    // Type
    static let label = Color.adaptive(dark: 0xF5F5F7, light: 0x121216)
    static let secondary = Color.adaptive(dark: 0xA6A6B0, light: 0x56565F)
    static let tertiary = Color.adaptive(dark: 0x767680, light: 0x82828B)

    // Brand + accents. The daylight values are the same hues pushed deeper so
    // they stay legible as type and still read as fills/gradients on white.
    static let accent = Color.adaptive(dark: 0xFF6A3D, light: 0xDE4E1C)
    static let accentSoft = Color.adaptive(dark: 0xFF8E5C, light: 0xC2410C)
    static let pink = Color.adaptive(dark: 0xFF375F, light: 0xD81B45)
    static let violet = Color.adaptive(dark: 0x8B5CF6, light: 0x6D28D9)
    static let cyan = Color.adaptive(dark: 0x22D3EE, light: 0x0E7490)
    static let mint = Color.adaptive(dark: 0x30D158, light: 0x15803D)
    static let amber = Color.adaptive(dark: 0xFFB020, light: 0xA9600A)
    static let indigo = Color.adaptive(dark: 0x5E5CE6, light: 0x4338CA)

    // Status
    static let green = Color.adaptive(dark: 0x32D74B, light: 0x248A3D)
    static let yellow = Color.adaptive(dark: 0xFFD60A, light: 0xA16207)
    static let orange = Color.adaptive(dark: 0xFF9F0A, light: 0xC2410C)
    static let red = Color.adaptive(dark: 0xFF453A, light: 0xD01B22)
    static let blue = Color.adaptive(dark: 0x0A84FF, light: 0x0A6CD0)
    static let purple = Color.adaptive(dark: 0xBF5AF2, light: 0x8944AB)
    static let teal = Color.adaptive(dark: 0x40C8E0, light: 0x0E7490)
    static let gray = Color.adaptive(dark: 0x8E8E93, light: 0x8A8A8E)

    // Surfaces that sit on the canvas and swap direction with the skin.
    static let glassTop = Color.adaptive(dark: 0xFFFFFF, light: 0xFFFFFF,
                                         darkAlpha: 0.080, lightAlpha: 0.92)
    static let glassBottom = Color.adaptive(dark: 0xFFFFFF, light: 0xFFFFFF,
                                            darkAlpha: 0.032, lightAlpha: 0.72)
    static let glassEdgeTop = Color.adaptive(dark: 0xFFFFFF, light: 0x101014,
                                             darkAlpha: 0.20, lightAlpha: 0.07)
    static let glassEdgeBottom = Color.adaptive(dark: 0xFFFFFF, light: 0x101014,
                                                darkAlpha: 0.05, lightAlpha: 0.02)
    static let panelShadow = Color.adaptive(dark: 0x000000, light: 0x000000,
                                            darkAlpha: 0.38, lightAlpha: 0.07)

    // Backdrop vignette: darkens the night canvas, gently lifts the day one.
    static let backdropTop = Color.adaptive(dark: 0x000000, light: 0xFFFFFF,
                                            darkAlpha: 0.48, lightAlpha: 0.55)
    static let backdropTopSoft = Color.adaptive(dark: 0x000000, light: 0xFFFFFF,
                                                darkAlpha: 0.12, lightAlpha: 0.18)
    static let backdropBottom = Color.adaptive(dark: 0x000000, light: 0x101014,
                                               darkAlpha: 0.28, lightAlpha: 0.03)

    // Primary (leading) pill: white on night, ink on day.
    static let pillFill = Color.adaptive(dark: 0xF2F2F4, light: 0x17171B)
    static let pillText = Color.adaptive(dark: 0x0B0B10, light: 0xFFFFFF)

    // Glass chips that sit on key art.
    static let chipFill = Color.adaptive(dark: 0x000000, light: 0xFFFFFF,
                                         darkAlpha: 0.22, lightAlpha: 0.78)
    static let chipText = Color.adaptive(dark: 0xF5F5F7, light: 0x14141A)
    static let chipBorder = Color.adaptive(dark: 0xFFFFFF, light: 0xFFFFFF,
                                           darkAlpha: 0.20, lightAlpha: 0.55)

    // Toast capsule.
    static let toastFill = Color.adaptive(dark: 0x000000, light: 0xFFFFFF,
                                          darkAlpha: 0.35, lightAlpha: 0.92)

    // Large content sheets (chat canvas, parameter panel): a faint base under the
    // glass gradient so the panel separates from the page.
    static let sheetBase = Color.adaptive(dark: 0x000000, light: 0xFFFFFF,
                                         darkAlpha: 0.24, lightAlpha: 0.82)
    static let sheetShadow = Color.adaptive(dark: 0x000000, light: 0x000000,
                                           darkAlpha: 0.35, lightAlpha: 0.10)
    /// Dimming layer behind floating panels.
    static let scrim = Color.adaptive(dark: 0x000000, light: 0x000000,
                                      darkAlpha: 0.12, lightAlpha: 0.10)
    /// Recessed strip (live metrics bar): darker than the canvas both ways.
    static let recess = Color.adaptive(dark: 0x000000, light: 0x101014,
                                       darkAlpha: 0.22, lightAlpha: 0.04)

    /// Translucent overlay that flips direction with the skin: white lifts the
    /// night canvas, near-black recesses the daylight one.
    static func overlay(_ opacity: Double) -> Color {
        .adaptiveOverlay(opacity)
    }

    // Geometry
    static let radiusSmall: CGFloat = 10
    static let radiusTile: CGFloat = 16
    static let radiusPanel: CGFloat = 22
    static let radiusHero: CGFloat = 28
    static let pagePadding: CGFloat = 24
    static let cardPadding: CGFloat = 18
    static let gap: CGFloat = 16

    // Type scale
    static let pageTitle = Font.system(size: 30, weight: .bold)
    static let heroTitle = Font.system(size: 36, weight: .bold)
    static let sectionTitle = Font.system(size: 19, weight: .bold)
    static let cardTitle = Font.system(size: 15, weight: .semibold)
    static let bodyFont = Font.system(size: 13)
    static let calloutFont = Font.system(size: 12)
    static let captionFont = Font.system(size: 11)
    static let metricFont = Font.system(size: 13, weight: .semibold)
    static let monoFont = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 10.5, design: .monospaced)
    static let metricLarge = Font.system(size: 34, weight: .bold, design: .rounded)

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

// MARK: - Page key colours

extension Page {
    /// Two-stop key colour used for the hero wash, page glow and nav icon.
    var keyColors: [Color] {
        switch self {
        case .overview:
            return [Color(hex: 0xFF9F0A), Color(hex: 0xFF375F), Color(hex: 0x7B2CBF)]
        case .chat:
            return [Color(hex: 0x7C5CFF), Color(hex: 0x0A84FF), Color(hex: 0x00C7BE)]
        case .models:
            return [Color(hex: 0x30D158), Color(hex: 0x00C7BE), Color(hex: 0x0A84FF)]
        case .engines:
            return [Color(hex: 0x22D3EE), Color(hex: 0x5E5CE6), Color(hex: 0xBF5AF2)]
        case .logs:
            return [Color(hex: 0xFFD60A), Color(hex: 0xFF9F0A), Color(hex: 0xFF453A)]
        case .settings:
            return [Color(hex: 0x5E5CE6), Color(hex: 0xBF5AF2), Color(hex: 0xFF375F)]
        }
    }

    var keyColor: Color { keyColors[0] }

    var iconColors: [Color] { [keyColors[0], keyColors[1]] }
}

// MARK: - Texture

/// One shared noise tile; blended at a few percent it removes gradient banding
/// and gives glass panels a physical, printed feel.
enum Grain {
    static let image: NSImage = {
        let side = 160
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: side,
                                         pixelsHigh: side,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let data = rep.bitmapData else { return NSImage() }
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt8 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return UInt8(truncatingIfNeeded: seed >> 24)
        }
        for y in 0..<side {
            for x in 0..<side {
                let value = next()
                let index = (y * side + x) * 4
                data[index] = value
                data[index + 1] = value
                data[index + 2] = value
                data[index + 3] = 255
            }
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }()
}

struct GrainOverlay: View {
    var opacity: Double = 0.045

    var body: some View {
        Image(nsImage: Grain.image)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .blendMode(.softLight)
            .allowsHitTesting(false)
    }
}

// MARK: - Key art

/// Radiating light streaks, the signature backdrop of the Games app hero.
struct RayField: View {
    var origin: UnitPoint = UnitPoint(x: 0.8, y: 0.38)
    var intensity: Double = 1

    var body: some View {
        Canvas { context, size in
            let anchor = CGPoint(x: size.width * origin.x, y: size.height * origin.y)
            let reach = hypot(size.width, size.height) * 1.35
            var seed: UInt64 = 0xA24BAED4963EE407
            func next() -> Double {
                seed ^= seed << 13
                seed ^= seed >> 7
                seed ^= seed << 17
                return Double(seed % 1000) / 1000
            }
            for index in 0..<72 {
                let angle = Double(index) / 72 * Double.pi * 2 + (next() - 0.5) * 0.035
                let width = 0.6 + next() * 2.6
                let alpha = (0.04 + next() * 0.18) * intensity
                var path = Path()
                path.move(to: anchor)
                path.addLine(to: CGPoint(x: anchor.x + cos(angle) * reach,
                                         y: anchor.y + sin(angle) * reach))
                context.stroke(path,
                               with: .color(.white.opacity(alpha)),
                               lineWidth: width)
            }
        }
        .blur(radius: 1.1)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

struct KeyArt: View {
    var colors: [Color]
    var rays: Bool = true

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            ZStack {
                LinearGradient(colors: colors.isEmpty ? [Native.canvas] : colors,
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)

                RadialGradient(colors: [.white.opacity(0.38), .clear],
                               center: UnitPoint(x: 0.82, y: 0.22),
                               startRadius: 0,
                               endRadius: width * 0.72)
                    .blendMode(.softLight)

                RadialGradient(colors: [colors.first?.opacity(0.55) ?? .clear, .clear],
                               center: UnitPoint(x: 0.1, y: 0.95),
                               startRadius: 0,
                               endRadius: width * 0.7)
                    .blendMode(.plusLighter)

                if rays {
                    RayField()
                        .opacity(0.9)
                }

                LinearGradient(stops: [
                    .init(color: .black.opacity(0.55), location: 0.0),
                    .init(color: .black.opacity(0.12), location: 0.52),
                    .init(color: .black.opacity(0.48), location: 1.0),
                ], startPoint: .bottomLeading, endPoint: .topTrailing)

                GrainOverlay(opacity: 0.07)
            }
            .frame(width: width, height: height)
        }
        .clipped()
    }
}

/// Full-width hero card with key art behind arbitrary content.
struct HeroPanel<Content: View>: View {
    var colors: [Color]
    var rays: Bool = true
    var padding: CGFloat = 24
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                KeyArt(colors: colors, rays: rays)
                    .clipShape(RoundedRectangle(cornerRadius: Native.radiusHero, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: Native.radiusHero, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            )
            .shadow(color: (colors.first ?? .clear).opacity(0.28),
                    radius: 32, x: 0, y: 16)
    }
}

/// Ambient page backdrop: canvas, two soft colour washes, fine grain.
struct ArcadeBackdrop: View {
    var colors: [Color]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Native.surface
                RadialGradient(colors: [(colors.first ?? .clear).opacity(0.15), .clear],
                               center: UnitPoint(x: 0.02, y: -0.05),
                               startRadius: 0,
                               endRadius: max(proxy.size.width, 900) * 0.7)
                RadialGradient(colors: [(colors.count > 1 ? colors[1] : colors.first ?? .clear).opacity(0.075), .clear],
                               center: UnitPoint(x: 0.95, y: 0.05),
                               startRadius: 0,
                               endRadius: max(proxy.size.width, 800) * 0.55)
                LinearGradient(stops: [
                    .init(color: Native.backdropTop, location: 0),
                    .init(color: Native.backdropTopSoft, location: 0.16),
                    .init(color: .clear, location: 0.42),
                    .init(color: Native.backdropBottom, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                GrainOverlay(opacity: 0.03)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Glass

/// Translucent panel fill with a top sheen and hairline edge — the core surface
/// of the whole app.
struct GlassSurface: View {
    var radius: CGFloat = Native.radiusPanel
    var tint: Color = .clear
    var elevated: Bool = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(
                LinearGradient(colors: [Native.glassTop, Native.glassBottom],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay {
                if tint != .clear {
                    shape.fill(tint.opacity(0.12))
                }
            }
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [Native.glassEdgeTop, Native.glassEdgeBottom],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            )
            .shadow(color: Native.panelShadow.opacity(elevated ? 1 : 0),
                    radius: elevated ? 20 : 0,
                    x: 0,
                    y: elevated ? 10 : 0)
    }
}

/// Small glass capsule used for tags, chips and status labels. They normally sit
/// on key art, so they keep a dark-glass look at night and a frosted light one by
/// day — both are readable because the label colour flips with the fill.
struct GlassChip: View {
    var icon: String? = nil
    var text: String
    var tint: Color = .white
    var solid: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(solid ? Native.pillText.opacity(0.75) : tint)
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(solid ? Native.pillText.opacity(0.9) : Native.chipText)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(solid ? Native.pillFill : Native.chipFill)
        }
        .overlay(Capsule().stroke(Native.chipBorder.opacity(solid ? 0 : 1), lineWidth: 0.8))
    }
}

// MARK: - Buttons

/// Games-style pill button. `light` is the white primary action; `glass` is the
/// translucent secondary; `accent` is the coloured call to action.
struct ArcadePillStyle: ButtonStyle {
    enum Tone { case light, glass, accent, danger }

    @Environment(\.isEnabled) private var isEnabled

    var tone: Tone = .glass
    var compact: Bool = false

    private var foreground: Color {
        switch tone {
        case .light: return Native.pillText
        case .glass: return Native.label
        case .accent, .danger: return .white
        }
    }

    private var background: AnyShapeStyle {
        switch tone {
        case .light:
            return AnyShapeStyle(Native.pillFill)
        case .glass:
            return AnyShapeStyle(Native.overlay(0.12))
        case .accent:
            return AnyShapeStyle(LinearGradient(colors: [Native.accent, Native.pink],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        case .danger:
            return AnyShapeStyle(Native.red.opacity(0.92))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 12 : 15)
            .frame(height: compact ? 28 : 33)
            .background(background, in: Capsule())
            .overlay(Capsule().stroke(Native.overlay(0.16).opacity(tone == .light ? 0 : 1), lineWidth: 0.8))
            .shadow(color: tone == .accent ? Native.accent.opacity(0.35) : .black.opacity(0.18),
                    radius: tone == .accent ? 12 : 6,
                    x: 0,
                    y: tone == .accent ? 5 : 2)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.965 : 1)
            .opacity(!isEnabled ? 0.34 : (configuration.isPressed ? 0.9 : 1))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
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

/// Colourful squircle icon tile, like the app icons on a game shelf.
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
        .shadow(color: glow ? (colors.first ?? .clear).opacity(0.45) : .clear,
                radius: glow ? size * 0.42 : 0,
                x: 0,
                y: glow ? size * 0.16 : 0)
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
        .shadow(color: glow ? Native.accent.opacity(0.35) : .clear,
                radius: glow ? size * 0.32 : 0,
                x: 0,
                y: glow ? size * 0.12 : 0)
        .accessibilityLabel("flashCat")
    }

    /// Resolved once: the artwork is a 1024 px PNG, and every bubble badge
    /// would otherwise re-decode it.
    @MainActor private static let artwork: NSImage? = loadArtwork()

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
        case .neutral: return Color.adaptive(dark: 0xC9C9D3, light: 0x4C4C55)
        case .accent: return Color.adaptive(dark: 0xFFA07A, light: 0xB23A11)
        case .success: return Color.adaptive(dark: 0x5BE38B, light: 0x18743A)
        case .warning: return Color.adaptive(dark: 0xFFD166, light: 0x8A5A08)
        case .danger: return Color.adaptive(dark: 0xFF7A72, light: 0xBC1F1B)
        }
    }

    var background: Color {
        switch self {
        case .neutral: return Native.overlay(0.09)
        case .accent: return Native.accent.opacity(0.20)
        case .success: return Native.green.opacity(0.18)
        case .warning: return Native.orange.opacity(0.20)
        case .danger: return Native.red.opacity(0.20)
        }
    }
}

/// Inline capsule label. Replaces the old squared tag.
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
    var color: Color = Native.secondary.opacity(0.9)

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .tracking(1.7)
            .foregroundStyle(color)
            .textCase(.uppercase)
    }
}

/// Quiet inset card with a glass surface. Header, optional trailing view, body.
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

/// One number plus a caption, used on the overview grid.
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
                    .font(.system(size: 11, weight: .semibold))
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
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Native.label)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                    if let unit {
                        Text(unit)
                            .font(.system(size: 10.5, weight: .semibold))
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
        .padding(16)
        .background { GlassSurface(radius: Native.radiusTile, tint: tint) }
        .animation(.easeOut(duration: 0.2), value: loading)
    }
}

struct Meter: View {
    let fraction: Double
    var tint: Color = Native.accent
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Native.overlay(0.10))
                Capsule()
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.62)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
                    .shadow(color: tint.opacity(0.55), radius: 5, x: 0, y: 0)
            }
        }
        .frame(height: height)
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
        .padding(.vertical, 7)
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
                    .tracking(-0.7)
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

/// Round glass icon button used in headers and toolbars.
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
                        .fill(active ? AnyShapeStyle(LinearGradient(colors: [Native.accent, Native.pink],
                                                                    startPoint: .topLeading,
                                                                    endPoint: .bottomTrailing))
                                     : AnyShapeStyle(Native.overlay(hovering ? 0.14 : 0.08)))
                }
                .overlay(Circle().stroke(Native.overlay(0.12).opacity(active ? 0 : 1), lineWidth: 0.8))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(isEnabled ? 1 : 0.38)
        .help(help)
    }
}

/// Circular glass label for a `Menu`, so a menu reads exactly like `IconAction`.
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
                    .fill(active
                          ? AnyShapeStyle(LinearGradient(colors: [Native.accent, Native.pink],
                                                         startPoint: .topLeading,
                                                         endPoint: .bottomTrailing))
                          : AnyShapeStyle(Native.overlay(0.08)))
            }
            .overlay(Circle().stroke(Native.overlay(0.12).opacity(active ? 0 : 1), lineWidth: 0.8))
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
                .foregroundStyle(Native.accentSoft)
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
