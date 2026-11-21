// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import XCTest

@testable import FlashCat

/// 纯实色 ZCode 窗口画布：始终保持不透明，并按 `contentView` 的皮肤解析出静态 sRGB 底色。
@MainActor
final class BackgroundSurfaceTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
    }

    func testWindowStaysOpaqueWithSolidCanvasColor() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let window = makeWindow()
        window.appearance = light
        window.contentView?.appearance = light
        window.isOpaque = false
        window.backgroundColor = .clear

        BackgroundSurface.shared.applyWindowSurface(to: window)
        XCTAssertTrue(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, BackgroundSurface.canvasColor(for: light))

        window.contentView?.appearance = dark
        BackgroundSurface.shared.applyWindowSurface(to: window)
        XCTAssertTrue(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, BackgroundSurface.canvasColor(for: dark))
    }

    func testLightAndDarkCanvasColorsAreDistinctStaticSRGB() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let lightColor = BackgroundSurface.canvasColor(for: light)
        let darkColor = BackgroundSurface.canvasColor(for: dark)

        XCTAssertNotEqual(lightColor, darkColor)
        XCTAssertGreaterThan(lightColor.redComponent, 0.9)
        XCTAssertLessThan(darkColor.redComponent, 0.15)
    }
}
