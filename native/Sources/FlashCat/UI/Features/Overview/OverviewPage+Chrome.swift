// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import SwiftUI

// MARK: - Layout & shared chrome

extension View {
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

// MARK: - KPI & Status bits

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
        .fixedSize()
    }
}

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
