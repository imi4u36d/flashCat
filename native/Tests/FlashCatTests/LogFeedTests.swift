// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest

@testable import FlashCat

/// 「全部日志」的合并：每台引擎的尾巴都按时间升序，页面要的是合成后的
/// 一份「最新在前」的视图，和跨来源唯一的行身份。
final class LogFeedTests: XCTestCase {
    private func line(_ id: Int, at second: TimeInterval, _ text: String? = nil) -> LogLine {
        LogLine(
            id: id,
            time: Date(timeIntervalSince1970: second),
            text: text ?? "line \(id)",
            level: .info)
    }

    private func group(_ key: String, tag: String? = nil, _ lines: [LogLine]) -> LogFeed.Group {
        LogFeed.Group(key: key, tag: tag, lines: lines)
    }

    func testMergesEverySourceByTime() {
        let entries = LogFeed.entries(from: [
            group("splash", tag: "splash", [line(1, at: 10), line(3, at: 30)]),
            group("omlx", tag: "omlx", [line(2, at: 20), line(4, at: 40)]),
        ])

        XCTAssertEqual(entries.map(\.text), ["line 4", "line 3", "line 2", "line 1"])
        XCTAssertEqual(entries.map(\.origin), ["omlx", "splash", "omlx", "splash"])
    }

    /// 同一时刻的两行按来源顺序取，结果稳定：页面每秒重算也不会跳来跳去。
    func testEqualTimesKeepSourceOrder() {
        let stamp: TimeInterval = 10
        let entries = LogFeed.entries(from: [
            group("splash", tag: "splash", [line(1, at: stamp)]),
            group("omlx", tag: "omlx", [line(2, at: stamp)]),
        ])

        XCTAssertEqual(entries.map(\.origin), ["splash", "omlx"])
    }

    /// 每个 `LogStore` 的行 id 都从 0 数起，合并后必须仍然唯一。
    func testRowIdsStayUniqueAcrossEngines() {
        let entries = LogFeed.entries(from: [
            group("splash", tag: "splash", [line(1, at: 10)]),
            group("omlx", tag: "omlx", [line(1, at: 20)]),
        ])

        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
        XCTAssertEqual(entries[0].origin, "omlx")
    }

    func testSingleSourceRowsCarryNoTag() {
        let entries = LogFeed.entries(from: [group("splash", [line(1, at: 10)])])

        XCTAssertNil(entries[0].tag)
        XCTAssertEqual(entries[0].origin, "splash")
    }

    func testLimitKeepsOnlyTheNewestRows() {
        let entries = LogFeed.entries(
            from: [group("splash", (1...6).map { line($0, at: TimeInterval($0)) })],
            limit: 3)

        XCTAssertEqual(entries.map(\.text), ["line 6", "line 5", "line 4"])
    }

    func testLimitZeroProducesNothing() {
        let entries = LogFeed.entries(from: [group("splash", [line(1, at: 10)])], limit: 0)

        XCTAssertTrue(entries.isEmpty)
    }

    func testEmptySourcesProduceNothing() {
        XCTAssertTrue(LogFeed.entries(from: []).isEmpty)
        XCTAssertTrue(LogFeed.entries(from: [group("splash", [])]).isEmpty)
    }

    /// 合并视图复制出去要带来源；单引擎视图保持和以前一样的纯正文。
    func testClipboardTextMarksSourcesOnlyInMergedView() {
        let entries = LogFeed.entries(from: [
            group("splash", tag: "splash", [line(1, at: 10, "引擎已启动")]),
            group("omlx", tag: "omlx", [line(2, at: 20, "模型已就绪")]),
        ])

        XCTAssertEqual(
            LogFeed.clipboardText(entries, tagged: true),
            "[omlx] 模型已就绪\n[splash] 引擎已启动")
        XCTAssertEqual(
            LogFeed.clipboardText(entries, tagged: false),
            "模型已就绪\n引擎已启动")
    }
}
