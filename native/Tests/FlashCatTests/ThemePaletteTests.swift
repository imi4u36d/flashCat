// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import XCTest

@testable import FlashCat
@testable import FlashCatCore

@MainActor
final class ThemePaletteTests: XCTestCase {
    private let lightCard = ThemeRGBA(hex: 0xFFFFFF)
    private let lightSidebar = ThemeRGBA(hex: 0xF2F4F8)
    private let darkCard = ThemeRGBA(hex: 0x1A1F30)
    private let darkSidebar = ThemeRGBA(hex: 0x0E1220)

    override func tearDown() {
        ThemeRuntime.palette = .iconOrange
    }

    func testDefaultPaletteMatchesDesignValues() {
        let palette = ThemePalette.iconOrange
        XCTAssertEqual(palette.accent, ThemeTone(light: 0xC23608, dark: 0xFFB067))
        XCTAssertEqual(
            palette.accentSoft,
            ThemeTone(light: 0xFF862F, dark: 0xFFB067, lightAlpha: 0.12, darkAlpha: 0.20))
        XCTAssertEqual(palette.accentFill, ThemeTone(light: 0xFF862F, dark: 0xFF8A3D))
        XCTAssertEqual(palette.onAccent, ThemeTone(light: 0x2A1A12, dark: 0x1B130E))
        XCTAssertEqual(palette.accentPeach, ThemeTone(light: 0xFFB861, dark: 0xFFC98F))
        XCTAssertEqual(palette.accentPeachText, ThemeTone(light: 0xB45309, dark: 0xFFC98F))
        XCTAssertEqual(palette.chartLine, ThemeTone(light: 0xF26B1D, dark: 0xFF8A3D))
        XCTAssertEqual(palette.selected, ThemeTone(light: 0xFFFFFF, dark: 0xFF8A3D, lightAlpha: 1, darkAlpha: 0.24))
        XCTAssertEqual(palette.pillActive, ThemeTone(light: 0xFFFFFF, dark: 0xFF8A3D, lightAlpha: 1, darkAlpha: 0.26))
    }

    func testDefaultPaletteMeetsContrast() {
        assertContrasts(ThemePalette.iconOrange)
    }

    func testPresetsMeetContrast() {
        for preset in ThemePreset.swatches {
            assertContrasts(
                ThemePalette.resolve(preset: preset, customSeed: nil),
                message: preset.rawValue)
        }
    }

    func testCustomSeedsMeetContrast() {
        let seeds: [UInt32] = [
            0xFFEB3B,  // 极亮黄
            0x000000,  // 黑
            0xFFFFFF,  // 白
            0x808080,  // 中灰
            0xE11D48,  // 玫瑰
            0x0D9488,  // 青瓷
            0x4F46E5,  // 靛蓝
            0x7C3AED,  // 紫罗兰
            0xFF862F,  // 图标深橙
        ]
        for seed in seeds {
            assertContrasts(ThemePalette.derive(seed: seed), message: String(format: "#%06X", seed))
        }
    }

    func testThemeControllerPersistsPreset() throws {
        let suite = "flashcat-theme-palette-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        let first = ThemeController(settings: settings)
        XCTAssertEqual(first.preset, .iconOrange)

        first.selectPreset(.rose)
        XCTAssertEqual(first.preset, .rose)
        XCTAssertEqual(settings.themePreset, .rose)
        XCTAssertEqual(ThemeRuntime.palette, ThemePalette.resolve(preset: .rose, customSeed: nil))

        let second = ThemeController(settings: settings)
        XCTAssertEqual(second.preset, .rose)
        XCTAssertEqual(second.palette, ThemePalette.resolve(preset: .rose, customSeed: nil))

        second.resetThemeColor()
        XCTAssertEqual(second.preset, .iconOrange)
        XCTAssertEqual(second.palette, .iconOrange)
    }

    func testThemeControllerPersistsCustomSeed() throws {
        let suite = "flashcat-theme-custom-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        let first = ThemeController(settings: settings)
        // 避开预设色，才能验证 .custom 分支；0F766E 是 teal 旁边的一档。
        first.setCustomColor(ThemeColorHex.color(hex: 0x0F766E))
        XCTAssertEqual(first.preset, .custom)
        XCTAssertEqual(first.customSeed, 0x0F766E)
        XCTAssertEqual(settings.themePreset, .custom)
        XCTAssertEqual(settings.themeSeed, 0x0F766E)

        let second = ThemeController(settings: settings)
        XCTAssertEqual(second.preset, .custom)
        XCTAssertEqual(second.customSeed, 0x0F766E)
        XCTAssertEqual(second.palette, ThemePalette.derive(seed: 0x0F766E))
    }

    func testMatchingPresetSeedSelectsPreset() throws {
        let suite = "flashcat-theme-match-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        let theme = ThemeController(settings: settings)
        theme.setCustomColor(ThemeColorHex.color(hex: ThemePreset.iconOrange.displayHex))
        XCTAssertEqual(theme.preset, .iconOrange)
        XCTAssertEqual(theme.palette, .iconOrange)
    }

    // MARK: - Contrast

    private func assertContrasts(
        _ palette: ThemePalette,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let lightAccent = palette.accent.resolved(dark: false)
        let lightSoftOnSidebar = ThemeRGBA(
            hex: palette.accentSoft.light,
            alpha: palette.accentSoft.lightAlpha
        ).composited(over: lightSidebar)
        let lightSoftOnCard = ThemeRGBA(
            hex: palette.accentSoft.light,
            alpha: palette.accentSoft.lightAlpha
        ).composited(over: lightCard)

        XCTAssertGreaterThanOrEqual(
            lightAccent.contrast(with: lightCard), 4.5,
            "\(message): light accent on card", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            lightAccent.contrast(with: lightSidebar), 4.5,
            "\(message): light accent on sidebar", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            lightAccent.contrast(with: lightSoftOnSidebar), 4.5,
            "\(message): light accent on soft sidebar", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            lightAccent.contrast(with: lightSoftOnCard), 4.5,
            "\(message): light accent on soft card", file: file, line: line)

        let lightFill = palette.accentFill.resolved(dark: false)
        XCTAssertGreaterThanOrEqual(
            palette.onAccent.resolved(dark: false).contrast(with: lightFill), 4.5,
            "\(message): light onAccent", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            palette.chartLine.resolved(dark: false).contrast(with: lightCard), 3.0,
            "\(message): light chart line", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            palette.accentPeachText.resolved(dark: false).contrast(with: lightCard), 4.5,
            "\(message): light secondary text", file: file, line: line)

        let darkAccent = palette.accent.resolved(dark: true)
        let darkSoftOnSidebar = ThemeRGBA(
            hex: palette.accentSoft.dark,
            alpha: palette.accentSoft.darkAlpha
        ).composited(over: darkSidebar)
        let darkSoftOnCard = ThemeRGBA(
            hex: palette.accentSoft.dark,
            alpha: palette.accentSoft.darkAlpha
        ).composited(over: darkCard)

        XCTAssertGreaterThanOrEqual(
            darkAccent.contrast(with: darkCard), 4.5,
            "\(message): dark accent on card", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            darkAccent.contrast(with: darkSidebar), 4.5,
            "\(message): dark accent on sidebar", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            darkAccent.contrast(with: darkSoftOnSidebar), 4.5,
            "\(message): dark accent on soft sidebar", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            darkAccent.contrast(with: darkSoftOnCard), 4.5,
            "\(message): dark accent on soft card", file: file, line: line)

        let darkFill = palette.accentFill.resolved(dark: true)
        XCTAssertGreaterThanOrEqual(
            palette.onAccent.resolved(dark: true).contrast(with: darkFill), 4.5,
            "\(message): dark onAccent", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            palette.chartLine.resolved(dark: true).contrast(with: darkCard), 3.0,
            "\(message): dark chart line", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            palette.accentPeachText.resolved(dark: true).contrast(with: darkCard), 4.5,
            "\(message): dark secondary text", file: file, line: line)
    }
}
