// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import SwiftUI

// MARK: - Layout & shared chrome

extension View {
    /// 概览卡片：16pt 圆角磨砂玻璃 + 14pt 内边距。
    func overviewCard(padding: CGFloat = 14) -> some View {
        self.padding(padding).dsSurface(radius: DS.Radius.card)
    }
}

/// 固定比例的横向布局：概览的 5/12 + 7/12 与 64% + 36% 都走这一条。
struct SplitRow<Leading: View, Trailing: View>: View {
    var fraction: CGFloat
    var spacing: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(
        fraction: CGFloat,
        spacing: CGFloat = 12,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.fraction = fraction
        self.spacing = spacing
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        SplitLayout(fraction: fraction, spacing: spacing) {
            leading
            trailing
        }
    }
}

private struct SplitLayout: Layout {
    var fraction: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let (leading, trailing) = widths(for: width)
        let leadingHeight = subviews[0]
            .sizeThatFits(ProposedViewSize(width: leading, height: proposal.height)).height
        let trailingHeight = subviews[1]
            .sizeThatFits(ProposedViewSize(width: trailing, height: proposal.height)).height
        return CGSize(width: width, height: max(leadingHeight, trailingHeight))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count >= 2 else { return }
        let (leading, trailing) = widths(for: bounds.width)
        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: leading, height: bounds.height))
        subviews[1].place(
            at: CGPoint(x: bounds.origin.x + leading + spacing, y: bounds.origin.y),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: trailing, height: bounds.height))
    }

    private func widths(for width: CGFloat) -> (CGFloat, CGFloat) {
        let usable = max(0, width - spacing)
        let leading = usable * min(max(fraction, 0), 1)
        return (leading, usable - leading)
    }
}

// MARK: - KPI bits

/// 小角标：AVG / 极速 / 稳定。
struct OverviewBadge: View {
    var text: String
    var tint: Color
    var dot: Bool = false
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if dot {
                Circle().fill(tint).frame(width: 4, height: 4)
            }
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .bold))
            }
            Text(L10n.t(text))
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.4)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(DS.rect(5).fill(tint.opacity(0.10)))
        .overlay(DS.rect(5).strokeBorder(tint.opacity(0.22), lineWidth: 1))
        .fixedSize()
    }
}

/// 解码趋势的迷你面积图：只负责形状，坐标按自身峰值缩放。
struct OverviewSparkline: View {
    var values: [Double]
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            let points = scaledPoints(in: proxy.size)
            if points.count > 1 {
                let line = path(points)
                ZStack {
                    line
                        .area(in: proxy.size)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.30), color.opacity(0)],
                                startPoint: .top, endPoint: .bottom))
                    line
                        .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
            } else {
                Capsule()
                    .fill(color.opacity(0.25))
                    .frame(height: 1.5)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private func scaledPoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let peak = max(values.max() ?? 0, 1)
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            CGPoint(
                x: CGFloat(index) * step,
                y: size.height - 1 - CGFloat(max(0, value) / peak) * (size.height - 3))
        }
    }

    private func path(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
    }
}

private extension Path {
    func area(in size: CGSize) -> Path {
        var copy = self
        let bounds = copy.boundingRect
        copy.addLine(to: CGPoint(x: bounds.maxX, y: size.height))
        copy.addLine(to: CGPoint(x: bounds.minX, y: size.height))
        copy.closeSubpath()
        return copy
    }
}

/// 预填充的上升微柱：只表达趋势，数值在左侧大字里。
struct OverviewMicroBars: View {
    var tint: Color = DS.accentBlue
    private let heights: [CGFloat] = [0.42, 0.55, 0.48, 0.68, 0.75, 0.84, 0.96]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(
                        index == heights.count - 1
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [DS.accentBlue, DS.accent],
                                    startPoint: .bottom, endPoint: .top))
                            : AnyShapeStyle(tint.opacity(0.18 + Double(index) * 0.10))
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 24 * height)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(height: 24)
    }
}

/// 首字延迟的横向进度：满格按 500ms 算，极速区间用绿色。
struct OverviewLatencyBar: View {
    var milliseconds: Double

    private var fraction: Double {
        min(1, max(0, milliseconds / 500))
    }

    private var label: String {
        milliseconds > 0 ? "<\(Int(max(250, milliseconds.rounded())))ms" : "—"
    }

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.line2)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [DS.ok.opacity(0.65), DS.ok],
                                startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(3, proxy.size.width * fraction))
                }
            }
            .frame(height: 5)

            Text(verbatim: label)
                .font(DS.Font.mono(9.5))
                .foregroundStyle(DS.text4)
                .fixedSize()
        }
        .frame(height: 24)
    }
}

/// 着色状态胶囊：在线 / 离线 / 运行中 / 已停止。
struct OverviewTintPill: View {
    var text: String
    var tint: Color
    var live: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            DSStatusDot(color: tint, live: live, size: 5)
            Text(L10n.t(text))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(tint.opacity(0.10)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 1))
        .fixedSize()
    }
}

/// 1.5pt 细进度条：缓存命中率 / 内存压力。
struct OverviewMiniBar: View {
    var value: Double
    var tint: Color
    var gradientTo: Color? = nil

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.line2)
                if value > 0 {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint, gradientTo ?? tint],
                                startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(2, proxy.size.width * min(1, max(0, value))))
                }
            }
        }
        .frame(height: 4)
    }
}

/// 页头的着色动作按钮：启动引擎是绿色玻璃，停止引擎是红色玻璃。
struct OverviewTintActionStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        OverviewTintActionBody(configuration: configuration, tint: tint)
    }
}

private struct OverviewTintActionBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let shape = DS.rect(10)
        let active = hovering && isEnabled
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(shape.fill(tint.opacity(active ? 0.17 : 0.11)))
            .overlay(shape.strokeBorder(tint.opacity(active ? 0.36 : 0.24), lineWidth: 1))
            .contentShape(shape)
            .scaleEffect((!reduceMotion && configuration.isPressed && isEnabled) ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(reduceMotion ? nil : DS.Motion.snappy, value: configuration.isPressed)
            .animation(reduceMotion ? nil : DS.Motion.snappy, value: active)
            .onHover { hovering = $0 }
    }
}

// MARK: - Status pill

/// 页头的现场胶囊：引擎名 · 端口 · 真实阶段。
struct OverviewStatusPill: View {
    var engine: String
    var port: Int?
    var stage: String
    var tint: Color
    var live: Bool

    var body: some View {
        HStack(spacing: 6) {
            DSStatusDot(color: tint, live: live, size: 6)
            Text(engine)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(DS.text)
            if let port {
                Text(verbatim: "·")
                    .font(DS.Font.prose(11))
                    .foregroundStyle(DS.text4)
                Text(verbatim: "127.0.0.1:\(port)")
                    .font(DS.Font.mono(10.5))
                    .foregroundStyle(DS.text2)
            }
            Text(verbatim: "·")
                .font(DS.Font.prose(11))
                .foregroundStyle(DS.text4)
            Text(stage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .dsGlassPill()
    }
}
