import AppKit
import SwiftUI

/// 背景参数的「执行器」：把透明度 / 模糊落到窗口表面和毛玻璃层上。
///
/// 这两件事以前挂在 `DesktopBackdrop.updateNSView` 里。NSViewRepresentable 只在
/// 自己的入参变化时才会被 SwiftUI 回调，而这个代表视图的入参只有 `blur`——
/// 于是「只拖 APP 透明度」这一路一步都跑不到窗口表面：`isOpaque` 与
/// `backgroundColor` 还是旧值，桌面根本不露出来；反过来拖模糊时它才顺带
/// 把上一步的透明度一起落下去。用户看到的就是「拖一个条没反应，拖另一个条
/// 上一个改动才生效」。
///
/// 现在改由 `BackgroundSettings` 的 `didSet` 直接驱动：参数一变，窗口和毛玻璃
/// 层立刻跟着变，不依赖任何视图的更新时机。`refresh()` 是幂等的，重复调用没有
/// 副作用。
@MainActor
final class BackgroundSurface {
    static let shared = BackgroundSurface()

    /// 窗口自己的底色。自定义背景图片时是它，透出桌面时让位给 `.clear`。
    static let canvasColor = NSColor.adaptive(dark: 0x14131A, light: 0xEAEEF7)

    private weak var window: NSWindow?
    private weak var effectView: NSVisualEffectView?

    private init() {}

    /// 主窗口登记一次；之后参数一变就会直接落到它身上。
    /// 挑窗口是调用方的事（`AppDelegate.configure` 已经滤掉面板和状态栏窗口），
    /// 这里只记住最近一个。
    func attach(window: NSWindow) {
        guard window !== self.window else { return }
        self.window = window
        refresh()
    }

    func attach(effectView: NSVisualEffectView) {
        guard effectView !== self.effectView else { return }
        self.effectView = effectView
        refresh()
    }

    /// 把当前参数落到窗口与毛玻璃层上。幂等。
    func refresh() {
        if let window {
            applyWindowSurface(to: window)
        }

        guard let effectView else { return }
        let settings = BackgroundSettings.shared
        let alpha = CGFloat(BackgroundMath.desktopFrost(blur: settings.blur,
                                                        hasImage: settings.image != nil))
        if abs(effectView.alphaValue - alpha) > 0.0005 {
            effectView.alphaValue = alpha
        }
        // `alphaValue` 只改合成参数，层内容本身不一定会重新解析。显式标脏，
        // 保证拖动滑杆时毛玻璃跟着走，而不是等下一次别的重绘顺手带出来。
        effectView.needsDisplay = true
        effectView.layer?.setNeedsDisplay()
    }

    /// 只改窗口这一层：透出桌面时非不透明 + 清空底色，否则回到不透明画布。
    ///
    /// `isOpaque` 与 `backgroundColor` 必须成对改：只清底色不设非不透明，
    /// 桌面不会透上来；只设非不透明不清底色，切壁纸后旧画面会挂在窗口上。
    func applyWindowSurface(to window: NSWindow) {
        let revealsDesktop = BackgroundSettings.shared.revealsDesktop
        if window.isOpaque == revealsDesktop {
            window.isOpaque = !revealsDesktop
        }
        let targetColor: NSColor = revealsDesktop ? .clear : Self.canvasColor
        if window.backgroundColor != targetColor {
            window.backgroundColor = targetColor
        }
    }
}
