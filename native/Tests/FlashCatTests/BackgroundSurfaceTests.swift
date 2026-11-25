// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import XCTest

@testable import FlashCat
@testable import FlashCatCore

/// Liquid Glass 壁纸兜底：窗口始终保持不透明，并按 `contentView` 的皮肤解析出静态 sRGB 边角色。
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
        XCTAssertGreaterThan(lightColor.redComponent, 0.8)
        XCTAssertLessThan(darkColor.redComponent, 0.15)
    }

    func testThemeControllerSwitchesSystemLightAndDarkAppearance() throws {
        let suite = "flashcat-theme-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        let theme = ThemeController(settings: settings)

        theme.set(.light)
        XCTAssertFalse(theme.isDark)
        XCTAssertEqual(theme.resolvedAppearance?.name, .aqua)

        theme.set(.dark)
        XCTAssertTrue(theme.isDark)
        XCTAssertEqual(theme.resolvedAppearance?.name, .darkAqua)

        theme.toggleLightDark()
        XCTAssertEqual(theme.mode, .light)
        theme.toggleLightDark()
        XCTAssertEqual(theme.mode, .dark)

        theme.set(.system)
        XCTAssertEqual(theme.isDark, theme.systemIsDark)
    }

    func testUIStateStorePersistsSidebarVisibility() throws {
        let suite = "flashcat-uistate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: "sidebarVisible")
        let hidden = UIStateStore(defaults: defaults)
        XCTAssertFalse(hidden.showsSidebar)

        let shown = UIStateStore(defaults: UserDefaults())
        shown.setShowsSidebar(false)
        XCTAssertFalse(shown.showsSidebar)
        shown.toggleSidebar()
        XCTAssertTrue(shown.showsSidebar)
    }
}
