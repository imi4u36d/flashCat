// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest

@testable import FlashCatKit

final class ControlConfigGrammarTests: XCTestCase {

    // MARK: port

    func testPortNormalizationTreatsZeroAndNegativesAsUnset() {
        XCTAssertEqual(ControlConfigGrammar.port(0, fallback: 8100), 8100)
        XCTAssertEqual(ControlConfigGrammar.port(nil, fallback: 8000), 8000)
        XCTAssertEqual(ControlConfigGrammar.port(-1, fallback: 8100), 8100)
        XCTAssertEqual(ControlConfigGrammar.port(8123, fallback: 8000), 8123)
    }

    func testPortRanges() {
        XCTAssertEqual(ControlConfigGrammar.portRange, 1024...65535)
        XCTAssertEqual(ControlConfigGrammar.maxTokensRange, 0...1_000_000)
    }

    // MARK: thinkingMode

    func testThinkingModeAcceptsEveryHistoricalAlias() {
        XCTAssertEqual(try ControlConfigGrammar.thinkingMode("auto"), 0)
        XCTAssertEqual(try ControlConfigGrammar.thinkingMode("automatic"), 0)
        XCTAssertEqual(try ControlConfigGrammar.thinkingMode("off"), 1)
        // `none` 是这次要修的回归：离线解析器以前只认 off。
        XCTAssertEqual(try ControlConfigGrammar.thinkingMode("none"), 1)
        XCTAssertEqual(try ControlConfigGrammar.thinkingMode("on"), 2)
        XCTAssertEqual(try ControlConfigGrammar.thinkingMode("  NONE  "), 1)
        XCTAssertEqual(ControlConfigGrammar.thinkingModeTokens, ["auto", "automatic", "none", "off", "on"])
    }

    func testThinkingModeRejectsUnknownToken() {
        XCTAssertThrowsError(try ControlConfigGrammar.thinkingMode("always")) { error in
            guard let error = error as? ControlConfigError else {
                return XCTFail("期望 ControlConfigError，实际 \(error)")
            }
            XCTAssertEqual(error.kind, .usage)
            XCTAssertTrue(error.message.contains("thinkingMode"))
        }
    }

    func testThinkingModeTokenReadDirection() {
        XCTAssertEqual(ControlConfigGrammar.thinkingModeToken(0), "auto")
        XCTAssertEqual(ControlConfigGrammar.thinkingModeToken(1), "off")
        XCTAssertEqual(ControlConfigGrammar.thinkingModeToken(2), "on")
        // 未知值沿用历史口径回落到默认项，而不是显示一个文档里不存在的 token。
        XCTAssertEqual(ControlConfigGrammar.thinkingModeToken(9), "auto")
    }

    // MARK: appearance

    func testAppearanceRoundTrip() {
        XCTAssertEqual(try ControlConfigGrammar.appearance("system"), 0)
        XCTAssertEqual(try ControlConfigGrammar.appearance("light"), 1)
        XCTAssertEqual(try ControlConfigGrammar.appearance("dark"), 2)
        // 旧别名兼容映射到对应 3 档原生外观
        XCTAssertEqual(try ControlConfigGrammar.appearance("studio"), 1)
        XCTAssertEqual(try ControlConfigGrammar.appearance("studioDark"), 2)
        XCTAssertEqual(try ControlConfigGrammar.appearance("studioSystem"), 0)
        XCTAssertEqual(ControlConfigGrammar.appearanceToken(0), "system")
        XCTAssertEqual(ControlConfigGrammar.appearanceToken(1), "light")
        XCTAssertEqual(ControlConfigGrammar.appearanceToken(2), "dark")
        XCTAssertEqual(ControlConfigGrammar.appearanceToken(3), "light")
        XCTAssertEqual(ControlConfigGrammar.appearanceToken(4), "dark")
        XCTAssertEqual(ControlConfigGrammar.appearanceToken(5), "system")
        XCTAssertEqual(ControlConfigGrammar.appearanceToken(7), "system")
    }

    func testAppearanceRejectsUnknownToken() {
        XCTAssertThrowsError(try ControlConfigGrammar.appearance("sepia")) { error in
            XCTAssertEqual((error as? ControlConfigError)?.kind, .usage)
        }
    }

    // MARK: reasoningEffort

    func testReasoningEffortMapsToStoredRawValues() {
        XCTAssertEqual(try ControlConfigGrammar.reasoningEffort("low"), 1)
        XCTAssertEqual(try ControlConfigGrammar.reasoningEffort("medium"), 2)
        XCTAssertEqual(try ControlConfigGrammar.reasoningEffort("high"), 3)
        XCTAssertEqual(try ControlConfigGrammar.reasoningEffort("xhigh"), 4)
        XCTAssertEqual(ControlConfigGrammar.reasoningEffortToken(1), "low")
        XCTAssertEqual(ControlConfigGrammar.reasoningEffortToken(4), "xhigh")
        XCTAssertEqual(ControlConfigGrammar.reasoningEffortToken(0), "low")
        XCTAssertEqual(ControlConfigGrammar.reasoningEffortToken(9), "xhigh")
    }

    func testReasoningEffortRejectsUnknownToken() {
        XCTAssertThrowsError(try ControlConfigGrammar.reasoningEffort("max")) { error in
            XCTAssertEqual((error as? ControlConfigError)?.kind, .usage)
        }
    }

    // MARK: bool / int / double

    func testBoolAcceptsDocumentedSpellings() {
        for raw in ["true", "1", "yes", "on", " TRUE "] {
            XCTAssertEqual(try ControlConfigGrammar.bool(raw, key: "autoStart"), true)
        }
        for raw in ["false", "0", "no", "off", " No "] {
            XCTAssertEqual(try ControlConfigGrammar.bool(raw, key: "autoStart"), false)
        }
    }

    func testBoolRejectsOtherValuesWithKeyInMessage() {
        XCTAssertThrowsError(try ControlConfigGrammar.bool("maybe", key: "autoStart")) { error in
            guard let error = error as? ControlConfigError else {
                return XCTFail("期望 ControlConfigError，实际 \(error)")
            }
            XCTAssertEqual(error.kind, .usage)
            XCTAssertEqual(error.message, "autoStart 需要 true / false")
        }
    }

    func testIntEnforcesRangeAndReportsIt() {
        XCTAssertEqual(try ControlConfigGrammar.int("1024", key: "port", range: ControlConfigGrammar.portRange), 1024)
        XCTAssertThrowsError(try ControlConfigGrammar.int("80", key: "port", range: ControlConfigGrammar.portRange)) {
            XCTAssertEqual(
                ($0 as? ControlConfigError)?.message,
                "port 需要 1024…65535 的整数")
        }
        XCTAssertThrowsError(try ControlConfigGrammar.int("abc", key: "port", range: ControlConfigGrammar.portRange))
    }

    func testDoubleEnforcesRangeAndReportsIt() {
        XCTAssertEqual(try ControlConfigGrammar.double("0.5", key: "temperature", range: 0...2), 0.5)
        XCTAssertThrowsError(try ControlConfigGrammar.double("3", key: "temperature", range: 0...2)) {
            XCTAssertEqual(
                ($0 as? ControlConfigError)?.message,
                "temperature 需要 0.0…2.0 的数字")
        }
        XCTAssertThrowsError(try ControlConfigGrammar.double("hot", key: "temperature", range: 0...2))
    }

    // MARK: format

    func testFormatUsesDocumentSpellings() {
        XCTAssertEqual(ControlConfigGrammar.format(.bool(true)), "true")
        XCTAssertEqual(ControlConfigGrammar.format(.bool(false)), "false")
        XCTAssertEqual(ControlConfigGrammar.format(.int(8200)), "8200")
        XCTAssertEqual(ControlConfigGrammar.format(.int(0)), "0")
        XCTAssertEqual(ControlConfigGrammar.format(.double(0.5)), "0.50")
        XCTAssertEqual(ControlConfigGrammar.format(.double(2)), "2.00")
        // 固定小数点，跟随地区会变成 "0,50"。
        XCTAssertEqual(ControlConfigGrammar.format(.double(1.005)), "1.00")
    }

    // MARK: errors

    func testErrorDefaultsToUsageKindAndCarriesHint() {
        let plain = ControlConfigError("未知设置项：x")
        XCTAssertEqual(plain.kind, .usage)
        XCTAssertNil(plain.hint)
        XCTAssertEqual(plain.errorDescription, "未知设置项：x")

        let conflicting = ControlConfigError("引擎端口需要应用在运行", kind: .conflict, hint: "先 flashcat app open")
        XCTAssertEqual(conflicting.kind, .conflict)
        XCTAssertEqual(conflicting.hint, "先 flashcat app open")
    }
}
