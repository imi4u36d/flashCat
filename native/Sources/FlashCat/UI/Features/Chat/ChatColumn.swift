// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 对话列宽度的换算。
///
/// 版式对齐 Splash 的对话页：正文与输入卡共用一条 680pt 内容列，左右各留
/// 32pt；用户消息再让出 88pt 的左侧空白，所以气泡最宽 592pt。默认列宽
/// 744 = 680 + 2×32，仍然可以向右拖宽——拖宽时正文、气泡、输入卡按同一条
/// 列宽一起变化，缩回窗口时只夹不改，窗口再放大还能回到用户拖出来的宽度。
enum ChatColumn {
    /// 默认列宽（含左右 32pt 内边距），也是最小列宽。
    static let defaultWidth: CGFloat = 744

    /// 页面给列留的左右边距。列最宽只能到「页面宽度 − 40」，否则会顶到窗口边。
    static let pageMargin: CGFloat = 40

    /// 正文与输入卡的左右内边距，对应 Splash 的 `padding: 28px 32px`。
    static let contentInset: CGFloat = 32

    /// 用户消息在列内再让出的左侧空白（Splash 的 88px），
    /// 让提问不会横贯整列、和助手长回答抢视觉重心。
    static let bubbleInset: CGFloat = 88

    /// 内容列宽：正文可用宽，也是输入卡的最大宽度。
    static func contentWidth(column: CGFloat) -> CGFloat {
        max(1, column - contentInset * 2)
    }

    /// 列能撑到的最宽值。页面还没量出宽度时先给默认值，避免首帧夹成 0。
    static func maximum(pageWidth: CGFloat) -> CGFloat {
        guard pageWidth.isFinite, pageWidth > 0 else { return defaultWidth }
        return max(defaultWidth, pageWidth - pageMargin)
    }

    /// 落盘宽度按窗口夹一次。只夹、不回写：窗口缩小时列跟着收窄，窗口再放大
    /// 又能回到用户拖出来的宽度。
    static func width(stored: CGFloat, pageWidth: CGFloat) -> CGFloat {
        guard stored.isFinite else { return defaultWidth }
        return min(max(stored, defaultWidth), maximum(pageWidth: pageWidth))
    }

    /// 用户气泡最宽。列每放宽 1pt 气泡也放宽 1pt，两侧的留白保持不变。
    static func bubbleWidth(column: CGFloat) -> CGFloat {
        max(1, column - contentInset * 2 - bubbleInset)
    }

    /// 输入卡宽度：和正文同宽，默认 744 → 680。
    static func composerWidth(column: CGFloat) -> CGFloat {
        contentWidth(column: column)
    }
}
