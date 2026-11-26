// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCatCore

final class UsageSummaryTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(
            from: DateComponents(
                year: year, month: month, day: day, hour: hour))!
    }

    private func message(
        _ role: String,
        at date: Date?,
        model: String? = nil,
        prompt: Int = 0,
        completion: Int = 0,
        rate: Double? = nil
    ) -> ChatMessage {
        ChatMessage(
            role: role,
            content: "",
            model: model,
            createdAt: date,
            usage: ChatUsage(promptTokens: prompt, completionTokens: completion),
            tokensPerSecond: rate)
    }

    private func thread(_ id: String, _ messages: [ChatMessage]) -> ChatThread {
        ChatThread(
            id: id,
            title: id,
            updatedAt: messages.last?.createdAt ?? Date(timeIntervalSince1970: 0),
            messages: messages)
    }

    private var now: Date { date(2026, 11, 26) }

    func testTotalsAndWindowFiltering() {
        let a = thread(
            "a",
            [
                message("user", at: date(2026, 11, 24)),
                message("assistant", at: date(2026, 11, 24), model: "M1", prompt: 100, completion: 20, rate: 50),
                message("user", at: date(2026, 11, 25)),
                message("assistant", at: date(2026, 11, 25), model: "M1", prompt: 80, completion: 10, rate: 60),
            ])
        let b = thread(
            "b",
            [
                message("user", at: date(2026, 10, 1)),
                message("assistant", at: date(2026, 10, 1), model: "M2", prompt: 200, completion: 40, rate: 100),
            ])
        let c = thread(
            "c",
            [
                message("assistant", at: date(2026, 11, 25), model: "M2", prompt: 10, completion: 2, rate: 30)
            ])

        let all = UsageSummary.make(
            threads: [a, b, c], window: .all, now: now, calendar: calendar)
        XCTAssertEqual(all.sessions, 3)
        XCTAssertEqual(all.messages, 7)
        XCTAssertEqual(all.userMessages, 3)
        XCTAssertEqual(all.assistantMessages, 4)
        XCTAssertEqual(all.promptTokens, 390)
        XCTAssertEqual(all.completionTokens, 72)
        XCTAssertEqual(all.totalTokens, 462)
        XCTAssertEqual(all.activeDays, 3)
        XCTAssertEqual(all.longestStreak, 2)
        XCTAssertEqual(all.recentSessions, 2, "最近 30 天只算 11-24 / 11-25 两段")
        XCTAssertEqual(all.firstActivity, date(2026, 10, 1))
        XCTAssertEqual(all.averageTokensPerSecond!, 5660.0 / 72.0, accuracy: 0.0001)
        XCTAssertEqual(all.models.map(\.name), ["M2", "M1"])
        XCTAssertEqual(all.models[0].tokens, 252)
        XCTAssertEqual(all.models[0].sessions, 2)
        XCTAssertEqual(all.models[1].tokens, 210)
        XCTAssertEqual(all.models[1].sessions, 1)
        XCTAssertEqual(all.days.map(\.sessions), [1, 1, 2], "10-01 一段，11-24 一段，11-25 两段")

        let week = UsageSummary.make(
            threads: [a, b, c], window: .week, now: now, calendar: calendar)
        XCTAssertEqual(week.sessions, 2)
        XCTAssertEqual(week.messages, 5)
        XCTAssertEqual(week.totalTokens, 222)
        XCTAssertEqual(week.activeDays, 2)
        XCTAssertEqual(week.longestStreak, 2)
        XCTAssertEqual(week.recentSessions, 2)
        XCTAssertEqual(week.models.first?.name, "M1")
        XCTAssertEqual(week.averageTokensPerSecond!, 1660.0 / 32.0, accuracy: 0.0001)

        let month = UsageSummary.make(
            threads: [a, b, c], window: .month, now: now, calendar: calendar)
        XCTAssertEqual(month.sessions, 2, "10-01 已在 30 天窗口之外")
        XCTAssertEqual(month.totalTokens, 222)
    }

    func testDominantModelAttributionAndTieBreak() {
        let mixed = thread(
            "mixed",
            [
                message("assistant", at: date(2026, 11, 20), model: "M2", prompt: 10, completion: 1),
                message("assistant", at: date(2026, 11, 20), model: "M2", prompt: 10, completion: 1),
                message("assistant", at: date(2026, 11, 21), model: "M1", prompt: 10, completion: 1),
            ])
        let tie = thread(
            "tie",
            [
                message("assistant", at: date(2026, 11, 22), model: "M2", prompt: 10, completion: 1),
                message("assistant", at: date(2026, 11, 22), model: "M1", prompt: 10, completion: 1),
            ])

        let summary = UsageSummary.make(
            threads: [mixed, tie], window: .all, now: now, calendar: calendar)
        XCTAssertEqual(summary.sessions, 2)
        XCTAssertEqual(summary.models.first(where: { $0.name == "M2" })?.sessions, 1)
        XCTAssertEqual(summary.models.first(where: { $0.name == "M1" })?.sessions, 1)
        XCTAssertEqual(
            summary.models.first(where: { $0.name == "M1" })?.tokens, 22,
            "并列时按名字定序，M1 拿到 tie 会话——但 Token 仍逐条累加")
    }

    func testLegacyMessagesWithoutDates() {
        let legacy = thread(
            "legacy",
            [
                message("user", at: nil),
                message("assistant", at: nil, model: "M1", prompt: 10, completion: 5),
            ])
        let all = UsageSummary.make(
            threads: [legacy], window: .all, now: now, calendar: calendar)
        XCTAssertEqual(all.sessions, 1)
        XCTAssertEqual(all.messages, 2)
        XCTAssertEqual(all.totalTokens, 15)
        XCTAssertEqual(all.activeDays, 0)
        XCTAssertEqual(all.days, [])
        XCTAssertNil(all.firstActivity)

        let week = UsageSummary.make(
            threads: [legacy], window: .week, now: now, calendar: calendar)
        XCTAssertTrue(week.isEmpty)
        XCTAssertEqual(week.totalTokens, 0, "没有时间戳的旧消息无法证明在窗口内")
    }

    func testEmptyStore() {
        let summary = UsageSummary.make(
            threads: [], window: .all, now: now, calendar: calendar)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.messages, 0)
        XCTAssertEqual(summary.activeDays, 0)
        XCTAssertEqual(summary.longestStreak, 0)
        XCTAssertNil(summary.averageTokensPerSecond)
        XCTAssertEqual(summary.averageTokensPerSession, 0)
        XCTAssertEqual(summary.days, [])
    }

    func testFormatting() {
        XCTAssertEqual(UsageFormat.tokens(351_100_000), "351.1M")
        XCTAssertEqual(UsageFormat.tokens(1_500_000_000), "1.5B")
        XCTAssertEqual(UsageFormat.tokens(1_234), "1.2K")
        XCTAssertEqual(UsageFormat.tokens(999), "999")
        XCTAssertEqual(UsageFormat.count(2_115), "2,115")
        XCTAssertEqual(UsageFormat.percent(0.611), "61.1%")
        XCTAssertEqual(UsageFormat.percent(0.0001), "<0.1%")
        XCTAssertEqual(UsageFormat.percent(0), "0%")
        XCTAssertEqual(UsageFormat.rate(nil), "—")
        XCTAssertEqual(UsageFormat.rate(47.16), "47.2")
    }
}
