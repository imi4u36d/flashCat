import SwiftUI
import AppKit

/// Native macOS design vocabulary: system colors, SF type, hairline separators,
/// quiet inset cards. No gradient blobs, no pill soup, no oversized hero art.
enum Native {
    static let accent = Color.accentColor
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let raised = Color(nsColor: .textBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let label = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)

    static let green = Color(nsColor: .systemGreen)
    static let yellow = Color(nsColor: .systemYellow)
    static let orange = Color(nsColor: .systemOrange)
    static let red = Color(nsColor: .systemRed)
    static let blue = Color(nsColor: .systemBlue)
    static let purple = Color(nsColor: .systemPurple)
    static let teal = Color(nsColor: .systemTeal)
    static let gray = Color(nsColor: .systemGray)

    static let radiusSmall: CGFloat = 6
    static let radiusPanel: CGFloat = 10
    static let pagePadding: CGFloat = 20
    static let cardPadding: CGFloat = 16
    static let gap: CGFloat = 14

    static let pageTitle = Font.system(size: 20, weight: .semibold)
    static let sectionTitle = Font.system(size: 11, weight: .semibold)
    static let bodyFont = Font.system(size: 13)
    static let calloutFont = Font.system(size: 12)
    static let metricFont = Font.system(size: 13, weight: .semibold)
    static let monoFont = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let metricLarge = Font.system(size: 28, weight: .semibold, design: .rounded)

    static let sidebarWidth: CGFloat = 240
    static let contentMaxWidth: CGFloat = 1180
}

// MARK: - Primitives

/// Thin, native-looking separator used instead of card borders everywhere.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Native.hairline)
            .frame(height: 1)
    }
}

/// Vertical hairline for inline splits.
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

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay(Circle().stroke(color.opacity(0.25), lineWidth: 3))
    }
}

enum TagTone {
    case neutral, accent, success, warning, danger

    var foreground: Color {
        switch self {
        case .neutral: return Native.secondary
        case .accent: return Native.accent
        case .success: return Color(nsColor: .systemGreen)
        case .warning: return Color(nsColor: .systemOrange)
        case .danger: return Color(nsColor: .systemRed)
        }
    }

    var background: Color {
        switch self {
        case .neutral: return Color(nsColor: .quaternaryLabelColor).opacity(0.35)
        case .accent: return Native.accent.opacity(0.12)
        case .success: return Color(nsColor: .systemGreen).opacity(0.12)
        case .warning: return Color(nsColor: .systemOrange).opacity(0.14)
        case .danger: return Color(nsColor: .systemRed).opacity(0.12)
        }
    }
}

/// Small inline label. Square-ish corners, no full pill shape.
struct Tag: View {
    let text: String
    var tone: TagTone = .neutral
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tone.background, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Quiet inset card: hairline border, small radius, no shadow.
struct Card<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    var trailing: AnyView? = nil
    var padded: Bool = true
    let content: Content

    init(_ title: String? = nil,
         subtitle: String? = nil,
         trailing: AnyView? = nil,
         padded: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.padded = padded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || subtitle != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title {
                            Text(title).font(.system(size: 13, weight: .semibold))
                        }
                        if let subtitle {
                            Text(subtitle).font(Native.calloutFont).foregroundStyle(Native.tertiary)
                        }
                    }
                    Spacer(minLength: 8)
                    if let trailing { trailing }
                }
            }
            content
        }
        .padding(padded ? Native.cardPadding : 0)
        .background(Native.panel, in: RoundedRectangle(cornerRadius: Native.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Native.radiusPanel, style: .continuous)
                .stroke(Native.hairline.opacity(0.8), lineWidth: 1)
        )
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label)
                    .font(Native.calloutFont)
                    .foregroundStyle(Native.secondary)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Native.tertiary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Native.label)
                if let unit {
                    Text(unit).font(Native.calloutFont).foregroundStyle(Native.tertiary)
                }
            }
            if let progress {
                Meter(fraction: progress, tint: progressTint ?? tint)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Native.panel, in: RoundedRectangle(cornerRadius: Native.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Native.radiusPanel, style: .continuous)
                .stroke(Native.hairline.opacity(0.8), lineWidth: 1)
        )
    }
}

struct Meter: View {
    let fraction: Double
    var tint: Color = Native.accent
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
        .frame(height: height)
    }
}

/// Label on the left, monospaced or plain value on the right.
struct KeyValueRow: View {
    let label: String
    var value: String
    var detail: String? = nil
    var mono: Bool = false
    var valueColor: Color = Native.label

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(Native.calloutFont)
                .foregroundStyle(Native.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? Native.monoFont : Native.bodyFont)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
    }
}

struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Native.pageTitle)
                if let subtitle {
                    Text(subtitle).font(Native.calloutFont).foregroundStyle(Native.tertiary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { actions() }
        }
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.actions = { EmptyView() }
    }
}

/// Square icon button that matches the native toolbar look.
struct IconAction: View {
    let systemName: String
    var help: String = ""
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(active ? Native.accent : nil)
        .help(help)
    }
}

struct EmptyHint: View {
    var icon: String = "tray"
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Native.tertiary)
            Text(title).font(Native.bodyFont).foregroundStyle(Native.secondary)
            if let detail {
                Text(detail)
                    .font(Native.calloutFont)
                    .foregroundStyle(Native.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

/// Bottom-center transient notice, replacing the Material snackbar.
struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Native.secondary)
            Text(message).font(Native.bodyFont)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Native.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(.bottom, 18)
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
