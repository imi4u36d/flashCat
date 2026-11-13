import Foundation

/// 对话列宽度的换算。
///
/// 对话页原来是写死的三档宽度：消息列 820pt、气泡 660pt、输入卡 780pt。现在
/// 列可以拖宽，这三个数必须一起跟着走——只放开外层，气泡还是原来那么窄，拖出
/// 来的就只是一圈空白。默认列宽同时是最小列宽，所以「没拖」和「拖到头又拖回
/// 来」看到的是同一套尺寸，不调宽的用户看不出任何变化。
enum ChatColumn {
    /// 默认列宽，也是最小列宽。
    static let defaultWidth: CGFloat = 820

    /// 页面给列留的左右边距。输入卡在页面级已经让出 40pt，列最宽只能到
    /// 「页面宽度 − 40」，否则输入卡会顶到窗口边上。
    static let pageMargin: CGFloat = 40

    /// 列到气泡之间的留白，左右各 40pt。
    static let contentInset: CGFloat = 40

    /// 气泡额外让出的呼吸空间：820 − 40×2 − 80 = 660，和改版前一模一样。
    static let bubbleInset: CGFloat = 80

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

    /// 气泡最宽。列每放宽 1pt 气泡也放宽 1pt，两侧的留白保持不变。
    static func bubbleWidth(column: CGFloat) -> CGFloat {
        max(1, column - contentInset * 2 - bubbleInset)
    }

    /// 输入卡宽度，恒比列窄 `pageMargin`（默认 820 → 780）。
    static func composerWidth(column: CGFloat) -> CGFloat {
        max(1, column - pageMargin)
    }
}
