// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCatCore

final class AppSettingsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "flashcat-settings-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsWhenNothingWasStored() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.port, 8000)
        XCTAssertEqual(settings.model, "")
        XCTAssertEqual(settings.thinkingMode, .automatic)
        XCTAssertEqual(settings.reasoningEffort, .medium)
        XCTAssertEqual(settings.hubSource, .huggingFace)
        XCTAssertEqual(settings.gatewayPort, 9000)
        XCTAssertEqual(settings.controlPort, 9100)
        XCTAssertEqual(settings.temperature, 0.7, accuracy: 0.0001)
    }

    func testEverySettingRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        settings.setPort(8123)
        settings.setModel("owner/repo")
        settings.setMaxMemory("24G")
        settings.setMaxContext("256K")
        settings.setIdleReleaseOff(true)
        settings.setLanguageOnly(true)
        settings.setThinkingMode(.on)
        settings.setReasoningEffort(.high)
        settings.setExtraArgs("--foo")
        settings.setAutoStart(true)
        settings.setLaunchAtLogin(true)
        settings.setHfCache("/tmp/hf")
        settings.setHfEndpoint("https://hf.example")
        settings.setHfToken("token")
        settings.setHubSource(.modelScope)
        settings.appearance = .dark
        settings.rememberModel("a")
        settings.rememberModel("b")
        settings.setTemperature(0.3)
        settings.setTopP(0.8)
        settings.setSystemPrompt("你是助手")
        settings.setMaxTokens(2048)
        settings.setGatewayPort(9200)
        settings.setControlPort(9300)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.port, 8123)
        XCTAssertEqual(reloaded.model, "owner/repo")
        XCTAssertEqual(reloaded.maxMemory, "24G")
        XCTAssertEqual(reloaded.maxContext, "256K")
        XCTAssertTrue(reloaded.idleReleaseOff)
        XCTAssertTrue(reloaded.languageOnly)
        XCTAssertEqual(reloaded.thinkingMode, .on)
        XCTAssertEqual(reloaded.reasoningEffort, .high)
        XCTAssertEqual(reloaded.effectiveReasoningEffort, "high")
        XCTAssertEqual(reloaded.extraArgs, "--foo")
        XCTAssertTrue(reloaded.autoStart)
        XCTAssertTrue(reloaded.launchAtLogin)
        XCTAssertEqual(reloaded.hfCache, "/tmp/hf")
        XCTAssertEqual(reloaded.hfEndpoint, "https://hf.example")
        XCTAssertEqual(reloaded.hfToken, "token")
        XCTAssertEqual(reloaded.hubSource, .modelScope)
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertEqual(reloaded.recentModels, ["b", "a"])
        XCTAssertEqual(reloaded.temperature, 0.3, accuracy: 0.0001)
        XCTAssertEqual(reloaded.topP, 0.8, accuracy: 0.0001)
        XCTAssertEqual(reloaded.systemPrompt, "你是助手")
        XCTAssertEqual(reloaded.maxTokens, 2048)
        XCTAssertEqual(reloaded.gatewayPort, 9200)
        XCTAssertEqual(reloaded.controlPort, 9300)
    }

    func testThinkingModesDriveServeArguments() {
        let settings = AppSettings(defaults: defaults)
        settings.setThinkingMode(.automatic)
        XCTAssertNil(settings.effectiveReasoningEffort)

        settings.setThinkingMode(.off)
        settings.setReasoningEffort(.xhigh)
        XCTAssertEqual(settings.effectiveReasoningEffort, "none")
        XCTAssertTrue(settings.serveArguments().contains("--default-reasoning-effort"))
        XCTAssertTrue(settings.serveArguments().contains("none"))

        settings.setThinkingMode(.on)
        XCTAssertEqual(settings.effectiveReasoningEffort, "xhigh")
        XCTAssertTrue(settings.serveArguments().contains("xhigh"))
    }

    func testLegacyFlutterPreferencesAreImportedOnce() {
        defaults.set("8199", forKey: "flutter.port")
        defaults.set("0.55", forKey: "flutter.chat.temperature")
        defaults.set("legacy-model", forKey: "flutter.model")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.port, 8199)
        XCTAssertEqual(settings.temperature, 0.55, accuracy: 0.0001)
        XCTAssertEqual(settings.model, "legacy-model")

        defaults.set("9999", forKey: "flutter.port")
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.port, 8199, "导入只应发生一次")
    }

    func testLegacyMaxTokensDefaultIsClearedOnce() {
        defaults.set(4096, forKey: "chat.maxTokens")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.maxTokens, 0)

        defaults.set(4096, forKey: "chat.maxTokens")
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.maxTokens, 4096, "迁移只应发生一次")
    }
}
