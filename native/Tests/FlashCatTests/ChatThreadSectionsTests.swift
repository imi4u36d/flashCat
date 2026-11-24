// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest

@testable import FlashCat
@testable import FlashCatCore

/// 「最近对话」的分组、搜索与排序。版式对齐 Splash：置顶在最前，其余按
/// 今天 / 昨天 / 最近 7 天 / 最近 30 天 / 更早分组。
final class ChatThreadSectionsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private let now = Date(timeIntervalSince1970: 1_765_000_800)  // 2025-12-06 06:00 UTC

    private func thread(
        _ title: String,
        daysAgo: Int = 0,
        pinnedDaysAgo: Int? = nil,
        content: String = ""
    ) -> ChatThread {
        let updated = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        return ChatThread(
            id: title,
            title: title,
            updatedAt: updated,
            pinnedAt: pinnedDaysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) },
            messages: content.isEmpty
                ? []
                : [ChatMessage(role: "user", content: content)])
    }

    func testMatchingSearchesTitleAndMessageContent() {
        let threads = [
            thread("马里奥", content: "帮我写一个游戏"),
            thread("旅行计划", content: "去京都看枫叶"),
            thread("代码审查", content: "把马里奥的碰撞逻辑再看一遍"),
        ]

        XCTAssertEqual(
            ChatThreadSections.matching(threads, query: "马里奥").map(\.title),
            ["马里奥", "代码审查"])
        XCTAssertEqual(
            ChatThreadSections.matching(threads, query: "京都").map(\.title),
            ["旅行计划"])
        XCTAssertEqual(ChatThreadSections.matching(threads, query: "   ").count, 3)
    }

    func testSectionsGroupByAgeAndKeepOrder() {
        let threads = [
            thread("更早", daysAgo: 40),
            thread("最近 30 天", daysAgo: 10),
            thread("最近 7 天", daysAgo: 3),
            thread("昨天", daysAgo: 1),
            thread("今天", daysAgo: 0),
        ]

        let sections = ChatThreadSections.sections(threads, now: now, calendar: calendar)
        XCTAssertEqual(
            sections.map(\.group),
            [.today, .yesterday, .week, .month, .older])
        XCTAssertEqual(sections.first?.threads.map(\.title), ["今天"])
        XCTAssertEqual(sections.last?.threads.map(\.title), ["更早"])
    }

    func testPinnedThreadsComeFirstWithMostRecentPinOnTop() {
        let threads = [
            thread("今天", daysAgo: 0),
            thread("旧置顶", pinnedDaysAgo: 5),
            thread("新置顶", pinnedDaysAgo: 1),
        ]

        let sections = ChatThreadSections.sections(threads, now: now, calendar: calendar)
        XCTAssertEqual(sections.first?.group, .pinned)
        XCTAssertEqual(sections.first?.threads.map(\.title), ["新置顶", "旧置顶"])
        XCTAssertEqual(sections.dropFirst().first?.group, .today)
    }

    func testNonPinnedThreadsAreNewestFirstInsideAGroup() {
        let threads = [
            thread("今天早上", daysAgo: 0),
            thread("今天中午", daysAgo: 0),
        ]

        let sections = ChatThreadSections.sections(threads, now: now, calendar: calendar)
        let today = sections.first?.threads ?? []
        XCTAssertEqual(today.count, 2)
        for pair in zip(today, today.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.0.updatedAt, pair.1.updatedAt)
        }
    }
}
