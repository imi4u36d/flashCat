// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest

@testable import FlashCat

final class GatewayClientSummaryTests: XCTestCase {
    /// 同一个客户端的多条请求并成一行；首次出现的顺序就是列表顺序。
    func testGroupsByClientInFirstSeenOrder() {
        let meter = GatewayMeter()
        let start = Date(timeIntervalSince1970: 1_000)
        let first = meter.begin(
            model: "m", dialect: "openai", promptTokens: 0,
            client: "curl/8.7.1", at: start)
        meter.begin(
            model: "m", dialect: "claude", promptTokens: 0,
            client: "OpenAI/Python 1.40.0", at: start.addingTimeInterval(1))
        let id = meter.begin(
            model: "m", dialect: "openai", promptTokens: 0,
            client: "curl/8.7.1", at: start.addingTimeInterval(2))
        meter.finish(first, at: start.addingTimeInterval(2))
        meter.finish(id, at: start.addingTimeInterval(3))

        let rows = GatewayClientSummary.group(
            meter.snapshot(now: start.addingTimeInterval(10)))
        XCTAssertEqual(rows.map(\.name), ["curl/8.7.1", "OpenAI/Python"])
        XCTAssertEqual(rows[0].count, 2)
        XCTAssertEqual(rows[0].dialect, "openai")
        XCTAssertEqual(rows[0].last, start.addingTimeInterval(3))
    }

    /// 在跑请求算「活跃」；结束后退回灰点。
    func testActiveFlagFollowsRunningSessions() {
        let meter = GatewayMeter()
        let start = Date(timeIntervalSince1970: 2_000)
        let id = meter.begin(
            model: "m", dialect: "openai", promptTokens: 0,
            client: "curl/8.7.1", at: start)

        var rows = GatewayClientSummary.group(meter.snapshot(now: start))
        XCTAssertEqual(rows.first?.active, true)

        meter.finish(id, at: start.addingTimeInterval(1))
        rows = GatewayClientSummary.group(
            meter.snapshot(now: start.addingTimeInterval(2)))
        XCTAssertEqual(rows.first?.active, false)
    }

    func testDisplayNameMapsInternalAndUnknownClients() {
        XCTAssertEqual(GatewayClientSummary.displayName("flashCat"), L10n.t("内置对话"))
        XCTAssertEqual(GatewayClientSummary.displayName(""), L10n.t("未知客户端"))
        XCTAssertEqual(GatewayClientSummary.displayName("curl/8.7.1"), "curl/8.7.1")
        XCTAssertEqual(
            GatewayClientSummary.displayName("Anthropic/Python 0.34.0 (comment)"),
            "Anthropic/Python")
    }
}
