import XCTest
import AppKit
@testable import FlashCat

/// 背景参数要真的落到窗口和毛玻璃层上。
///
/// 这是那条「拖一个条，另一个条的改动才生效」的回归测试：窗口表面以前只在
/// `DesktopBackdrop.updateNSView` 里更新，而入参只有 `blur`，所以只改透明度时
/// 窗口一直是不透明的，桌面永远不出现，直到下一次拖模糊把它顺带刷出来。
/// 现在参数一变（`didSet`）就必须立刻可见。
@MainActor
final class BackgroundSurfaceTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                 styleMask: [.titled], backing: .buffered, defer: false)
    }

    func testOpacityAloneFlipsTheWindowSurface() {
        let settings = BackgroundSettings.shared
        let originalOpacity = settings.opacity
        let originalBlur = settings.blur
        defer {
            settings.opacity = originalOpacity
            settings.blur = originalBlur
        }

        let window = makeWindow()
        BackgroundSurface.shared.attach(window: window)

        settings.opacity = 0
        XCTAssertTrue(window.isOpaque, "透明度 0 时整窗按画布画，不该有桌面透出")

        // 只动透明度：窗口必须立刻让位给桌面，不等任何视图重建。
        settings.opacity = 0.85
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)

        // 再收回去：画布重新不透明。
        settings.opacity = 0
        XCTAssertTrue(window.isOpaque)
        XCTAssertNotEqual(window.backgroundColor, .clear)
    }

    func testBlurAloneReachesTheFrostLayer() {
        let settings = BackgroundSettings.shared
        let originalOpacity = settings.opacity
        let originalBlur = settings.blur
        defer {
            settings.opacity = originalOpacity
            settings.blur = originalBlur
        }

        let effect = NSVisualEffectView()
        BackgroundSurface.shared.attach(effectView: effect)

        settings.opacity = 0.5

        settings.blur = 0
        XCTAssertEqual(effect.alphaValue, 0, accuracy: 0.001)

        // 只动模糊：毛玻璃强度立刻跟上。
        settings.blur = 20
        XCTAssertEqual(effect.alphaValue, 0.5, accuracy: 0.001)

        settings.blur = 40
        XCTAssertEqual(effect.alphaValue, 1, accuracy: 0.001)
    }
}
