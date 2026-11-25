// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import XCTest

@testable import FlashCat
@testable import FlashCatCore

final class ChatPerformanceTests: XCTestCase {
    func testProseFontCacheReturnsSameInstanceForMatchingInputs() {
        let first = DS.Font.proseNS(15, weight: .regular)
        let second = DS.Font.proseNS(15, weight: .regular)
        let bold = DS.Font.proseNS(15, weight: .semibold)
        let monoDigits = DS.Font.proseNS(15, weight: .regular, monospacedDigits: true)

        XCTAssertTrue(first === second)
        XCTAssertFalse(first === bold)
        XCTAssertFalse(first === monoDigits)
    }

    func testMarkdownRenderCacheProducesDeterministicListIDsAndCachesSegments() {
        let markdown = """
            # 标题

            第一段包含 **粗体** 和 `code`。

            - 项目一
            - 项目二

            > 引用第一行
            > 引用第二行

            | 列A | 列B |
            |---|---|
            | 1 | **2** |

            ```swift
            let x = 42
            ```
            """
        let first = MarkdownRenderCache.segments(for: markdown, style: .chat, caching: true)
        let second = MarkdownRenderCache.segments(for: markdown, style: .chat, caching: true)
        XCTAssertEqual(first.count, second.count)
        XCTAssertEqual(first.count, 5)

        if case .list(let itemsA) = first[1], case .list(let itemsB) = second[1] {
            XCTAssertEqual(itemsA.map(\.id), [0, 1])
            XCTAssertEqual(itemsB.map(\.id), [0, 1])
        } else {
            XCTFail("第二段应当是列表")
        }

        if case .table(let rows) = first[3] {
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(String(rows[1][1].characters), "2")
        } else {
            XCTFail("第四段应当是表格")
        }

        let streaming = MarkdownRenderCache.segments(for: "- streaming", style: .chat, caching: false)
        XCTAssertEqual(streaming.count, 1)
    }

    func testBudgetedMessageCountAlwaysKeepsLastAndCapsOlderMessages() {
        XCTAssertEqual(ChatTranscriptView.budgetedMessageCount([]), 1)

        let hugeLast = ChatMessage(
            role: "assistant",
            content: String(repeating: "a", count: 50_000))
        let older = ChatMessage(role: "user", content: "hi")
        XCTAssertEqual(ChatTranscriptView.budgetedMessageCount([older, hugeLast]), 2)

        let heavyOlder = ChatMessage(
            role: "assistant",
            content: String(repeating: "b", count: ChatTranscriptView.transcriptUTF8Budget))
        let oldest = ChatMessage(role: "user", content: "oldest")
        let latest = ChatMessage(role: "user", content: "latest")
        XCTAssertEqual(ChatTranscriptView.budgetedMessageCount([oldest, heavyOlder, latest]), 2)
    }
}
