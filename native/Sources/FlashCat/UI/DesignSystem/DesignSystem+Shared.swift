// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import SwiftUI

// MARK: - Motion

enum Motion {
    static let quick = DS.Motion.snappy
    static let standard = DS.Motion.smooth
    static let entrance = DS.Motion.smooth
    static let settle = Animation.smooth(duration: 0.24)
    static let glide = Animation.smooth(duration: 0.4)
    static let pageCrossfade = Animation.smooth(duration: 0.36)
}

// MARK: - Buttons & Hit Area

/// `.plain` 的命中区修正版：把整块 label 背景都算作可点击区域。
struct PlainHitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PlainHitButtonStyle {
    static var plainHit: PlainHitButtonStyle { PlainHitButtonStyle() }
}

// MARK: - Icons & Brand

/// 扁平圆角图标方块：使用单色符号搭配柔和同色底。
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
    }
}

/// 品牌字形资源：Lobe Icons 的 PNG 以 alpha 遮罩保存。
@MainActor
enum BrandGlyph {
    private static var cache: [String: NSImage] = [:]
    private static var artworkCache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let original = load(named: name, cache: &artworkCache) else { return nil }
        let template = (original.copy() as? NSImage) ?? original
        template.isTemplate = true
        cache[name] = template
        return template
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

/// flashCat 应用图标。
struct BrandMark: View {
    var size: CGFloat = 38
    var glow: Bool = true

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
                    .foregroundStyle(DS.accent)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("flashCat")
    }

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
        if let url = Bundle.main.url(forResource: "app-icon", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        {
            return image
        }
        return NSApplication.shared.applicationIconImage
    }
}

// MARK: - Primitives

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
}

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
        .fixedSize()
    }
}

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

struct Meter: View {
    let fraction: Double
    var tint: Color = DS.accent
    var height: CGFloat = 5

    var body: some View {
        DSMeter(value: fraction, tint: tint)
    }
}

struct SkeletonBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 10
    var radius: CGFloat = 5
    var opacity: Double = 0.09

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.adaptiveOverlay(opacity))
            .frame(width: width, height: height)
    }
}

struct SkeletonBlock: View {
    var height: CGFloat? = nil
    var radius: CGFloat = 12
    var opacity: Double = 0.055

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.adaptiveOverlay(opacity))
            .frame(maxWidth: .infinity)
            .frame(height: height)
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
    case .ready: return DS.ok
    case .starting, .stopping: return DS.warn
    case .failed: return DS.err
    case .stopped: return DS.text3
    }
}

func levelColor(_ level: LogLevel) -> Color {
    switch level {
    case .error: return DS.err
    case .warning: return DS.warn
    case .success: return DS.ok
    case .system: return DS.info
    case .info: return DS.text2
    }
}

func healthTone(_ stats: ServerStats?) -> (label: String, tone: TagTone) {
    guard let stats else { return ("待机", .neutral) }
    if stats.memoryPressure == "critical" { return ("内存紧张", .danger) }
    if stats.memoryPressure == "warning" { return ("内存偏高", .warning) }
    if let thermal = stats.thermal, thermal != "nominal" { return (stats.thermalText, .warning) }
    return ("正常", .success)
}
