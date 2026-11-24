// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import SwiftUI

extension AnyTransition {
    /// 页面切换：淡入 + 4pt 上移；离开只淡出。
    static var dsPage: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 4)),
            removal: .opacity)
    }

    /// 新条目：从上方 6pt 滑入并淡入。
    static var dsRowInsert: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -6)),
            removal: .opacity)
    }

    /// 浮层：轻微缩放 + 淡入。
    static var dsPopover: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
    }
}

// MARK: - Animated Grid

/// 支持列数切换平滑重排的原生网格 `Layout`：
/// 在 `columns` 变化时配合 `withAnimation(DS.Motion.smooth)` 为每张卡片插值位置与宽度，
/// 弥补 `LazyVGrid(.adaptive)` 在侧栏收放与窗口缩放时生硬跳变的不足。
struct DSAnimatedGrid: Layout {
    var columns: Int
    var minWidth: CGFloat
    var maxWidth: CGFloat? = nil
    var spacing: CGFloat = 12
    var maxColumns: Int? = nil

    static func columnCount(
        for width: CGFloat,
        minWidth: CGFloat,
        spacing: CGFloat,
        maxColumns: Int? = nil
    ) -> Int {
        let usable = max(1, width)
        let raw = max(1, Int((usable + spacing) / (minWidth + spacing)))
        if let maxColumns { return min(maxColumns, raw) }
        return raw
    }

    private func resolvedColumns(for width: CGFloat) -> Int {
        columns > 0
            ? columns
            : Self.columnCount(for: width, minWidth: minWidth, spacing: spacing, maxColumns: maxColumns)
    }

    private func cellWidth(totalWidth: CGFloat, cols: Int) -> CGFloat {
        let raw = max(1, (totalWidth - spacing * CGFloat(max(0, cols - 1))) / CGFloat(cols))
        return maxWidth.map { min(raw, $0) } ?? raw
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let fallbackCols = max(1, columns)
        let totalWidth =
            proposal.width
            ?? (minWidth * CGFloat(fallbackCols) + spacing * CGFloat(max(0, fallbackCols - 1)))
        let cols = max(1, resolvedColumns(for: totalWidth))
        let itemWidth = cellWidth(totalWidth: totalWidth, cols: cols)
        let itemProposal = ProposedViewSize(width: itemWidth, height: nil)

        var totalHeight: CGFloat = 0
        var index = 0
        while index < subviews.count {
            let end = min(index + cols, subviews.count)
            var rowHeight: CGFloat = 0
            for i in index..<end {
                rowHeight = max(rowHeight, subviews[i].sizeThatFits(itemProposal).height)
            }
            if index > 0 { totalHeight += spacing }
            totalHeight += rowHeight
            index = end
        }
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let totalWidth = bounds.width
        let cols = max(1, resolvedColumns(for: totalWidth))
        let itemWidth = cellWidth(totalWidth: totalWidth, cols: cols)
        let measureProposal = ProposedViewSize(width: itemWidth, height: nil)

        var y = bounds.minY
        var index = 0
        while index < subviews.count {
            let end = min(index + cols, subviews.count)
            var rowHeight: CGFloat = 0
            for i in index..<end {
                rowHeight = max(rowHeight, subviews[i].sizeThatFits(measureProposal).height)
            }
            for offset in 0..<(end - index) {
                let x = bounds.minX + CGFloat(offset) * (itemWidth + spacing)
                subviews[index + offset].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: itemWidth, height: rowHeight)
                )
            }
            y += rowHeight + spacing
            index = end
        }
    }
}

private struct DSTrackColumnsModifier: ViewModifier {
    @Binding var columns: Int
    let minWidth: CGFloat
    let spacing: CGFloat
    let maxColumns: Int?
    let horizontalPadding: CGFloat

    @State private var measuredWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                max(1, proxy.size.width - horizontalPadding * 2)
            } action: { width in
                measuredWidth = width
                updateColumns(for: width, animate: columns > 0)
            }
            .onChange(of: minWidth) { _, _ in
                guard measuredWidth > 1 else { return }
                updateColumns(for: measuredWidth, animate: columns > 0)
            }
    }

    private func updateColumns(for width: CGFloat, animate: Bool) {
        let next = DSAnimatedGrid.columnCount(
            for: width,
            minWidth: minWidth,
            spacing: spacing,
            maxColumns: maxColumns)
        guard next != columns else { return }
        if animate && !reduceMotion {
            withAnimation(DS.Motion.smooth) { columns = next }
        } else {
            columns = next
        }
    }
}

extension View {
    /// 监听容器可用宽度并在跨越列数断点时以平滑动画更新列数。
    func dsTrackColumns(
        _ columns: Binding<Int>,
        minWidth: CGFloat,
        spacing: CGFloat,
        maxColumns: Int? = nil,
        horizontalPadding: CGFloat = Console.contentPadding
    ) -> some View {
        modifier(
            DSTrackColumnsModifier(
                columns: columns,
                minWidth: minWidth,
                spacing: spacing,
                maxColumns: maxColumns,
                horizontalPadding: horizontalPadding))
    }
}
