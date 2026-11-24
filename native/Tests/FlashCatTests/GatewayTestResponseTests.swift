// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest

@testable import FlashCat

final class GatewayTestResponseTests: XCTestCase {
    func testOpenAIStyleChoice() throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"你好"}}]}"#
        let parsed = GatewayTestResponse.parse(data: Data(json.utf8), status: 200)
        XCTAssertTrue(parsed.ok)
        XCTAssertEqual(parsed.reply, "你好")
    }

    func testErrorBodyWinsOverStatus() throws {
        let json = #"{"error":{"message":"引擎未运行"}}"#
        let parsed = GatewayTestResponse.parse(data: Data(json.utf8), status: 200)
        XCTAssertFalse(parsed.ok)
        XCTAssertEqual(parsed.reply, "引擎未运行")
    }

    func testPlainTextBodyIsKeptAsEvidence() {
        let parsed = GatewayTestResponse.parse(data: Data("upstream timeout".utf8), status: 504)
        XCTAssertFalse(parsed.ok)
        XCTAssertEqual(parsed.reply, "upstream timeout")
    }

    func testEmptyBodyDoesNotBecomeBlankPopover() {
        let parsed = GatewayTestResponse.parse(data: Data(), status: 200)
        XCTAssertTrue(parsed.ok)
        XCTAssertEqual(parsed.reply, "—")
    }
}
