import XCTest
@testable import FlashCat

/// 背景两个滑杆的取值映射。
///
/// 这里守的是「值 → 实际画出来什么」：透明度和模糊互相牵连的那次 bug 里，
/// 滑杆的值是对的，但一半行程映射到同一个结果，看起来就像拖动没有生效。
final class BackgroundMathTests: XCTestCase {
    func testBlurAlphaCoversTheWholeSlider() {
        XCTAssertEqual(BackgroundMath.blurAlpha(0), 0, accuracy: 0.0001)
        XCTAssertEqual(BackgroundMath.blurAlpha(10), 0.25, accuracy: 0.0001)
        XCTAssertEqual(BackgroundMath.blurAlpha(20), 0.5, accuracy: 0.0001)
        XCTAssertEqual(BackgroundMath.blurAlpha(40), 1, accuracy: 0.0001)
    }

    func testBlurAlphaClampsOutOfRangeStoredValues() {
        // 手改 UserDefaults 可能留下越界值，不能让毛玻璃层变成负 alpha 或超范围。
        XCTAssertEqual(BackgroundMath.blurAlpha(-8), 0, accuracy: 0.0001)
        XCTAssertEqual(BackgroundMath.blurAlpha(120), 1, accuracy: 0.0001)
    }

    func testVeilOpacityKeepsBothEnds() {
        // 0 = 图片完全被遮住；1 = 只剩保底那一层，文字对比度不塌。
        for dark in [true, false] {
            let floor = dark ? 0.42 : 0.36
            XCTAssertEqual(BackgroundMath.veilOpacity(0, dark: dark), 1, accuracy: 0.0001)
            XCTAssertEqual(BackgroundMath.veilOpacity(1, dark: dark), floor, accuracy: 0.0001)
        }
    }

    func testVeilOpacityHasNoDeadZone() {
        // 旧实现是 max(1 - opacity, floor)：深色下 58% 到 100% 整段都停在 0.42，
        // 滑杆最后近一半行程没有任何变化。现在整段都要有可见差异。
        let samples = stride(from: 0.0, through: 1.0, by: 0.1)
            .map { BackgroundMath.veilOpacity($0, dark: true) }
        for (lower, higher) in zip(samples, samples.dropFirst()) {
            XCTAssertLessThan(higher, lower - 0.01, "每一档都必须带来可见变化")
        }
        XCTAssertEqual(samples.last ?? 0, 0.42, accuracy: 0.0001, "保底值只在最清晰的一端")
    }

    func testVeilOpacityIsMonotonic() {
        var previous = BackgroundMath.veilOpacity(0, dark: true)
        for step in 1...100 {
            let value = BackgroundMath.veilOpacity(Double(step) / 100, dark: true)
            XCTAssertLessThan(value, previous)
            previous = value
        }
    }

    func testDesktopFrostIgnoresBlurWhenAnImageIsSet() {
        // 有图片时窗口是不透明的，桌面层没有意义，强度必须归零。
        XCTAssertEqual(BackgroundMath.desktopFrost(blur: 40, hasImage: true), 0, accuracy: 0.0001)
        XCTAssertEqual(BackgroundMath.desktopFrost(blur: 40, hasImage: false), 1, accuracy: 0.0001)
        XCTAssertEqual(BackgroundMath.desktopFrost(blur: 0, hasImage: false), 0, accuracy: 0.0001)
    }
}
