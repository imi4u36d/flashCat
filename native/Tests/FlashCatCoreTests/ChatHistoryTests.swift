// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCatCore

final class ChatHistoryTests: XCTestCase {
    private var directory: URL!
    private var historyPath: String!
    private var conversationPath: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        historyPath = directory.appendingPathComponent("history.json").path
        conversationPath = directory.appendingPathComponent("conversation.json").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSaveAndLoadThreadsUpdatesInPlace() {
        let history = ChatHistory(filePath: historyPath)
        let first = [
            ChatMessage(role: "user", content: "第一行\n第二行"),
            ChatMessage(role: "assistant", content: "回答"),
        ]
        history.save(messages: first, threadID: "t1", updatedAt: Date(timeIntervalSince1970: 100))
        history.waitForWrites()

        var threads = history.load()
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].id, "t1")
        XCTAssertEqual(threads[0].title, "第一行")
        XCTAssertEqual(threads[0].messages.map(\.content), ["第一行\n第二行", "回答"])

        history.save(
            messages: first + [ChatMessage(role: "user", content: "追加")],
            threadID: "t1", updatedAt: Date(timeIntervalSince1970: 200))
        history.waitForWrites()

        threads = history.load()
        XCTAssertEqual(threads.count, 1, "同一 threadID 应原地覆盖")
        XCTAssertEqual(threads[0].messages.count, 3)
        XCTAssertEqual(threads[0].updatedAt.timeIntervalSince1970, 200)
    }

    func testConversationRoundTripAndClear() {
        let store = ConversationStore(filePath: conversationPath)
        let messages = [
            ChatMessage(role: "user", content: "问题"),
            ChatMessage(role: "assistant", content: "回答", reasoning: "思考"),
        ]
        store.save(messages)
        store.waitForWrites()

        XCTAssertEqual(store.load().map(\.content), ["问题", "回答"])
        XCTAssertEqual(store.load().last?.reasoning, "思考")

        store.clear()
        store.waitForWrites()
        XCTAssertTrue(store.load().isEmpty)
    }

    func testPruneLegacyDropsPrefixDuplicates() {
        let history = ChatHistory(filePath: historyPath)
        let short = [
            ChatMessage(role: "user", content: "同一个问题"),
            ChatMessage(role: "assistant", content: "短回答"),
        ]
        let long = short + [ChatMessage(role: "user", content: "继续"), ChatMessage(role: "assistant", content: "长回答")]
        history.save(messages: short, threadID: "short", updatedAt: Date(timeIntervalSince1970: 100))
        history.save(messages: long, threadID: "long", updatedAt: Date(timeIntervalSince1970: 200))
        history.waitForWrites()

        let pruned = history.load(pruneLegacy: true)

        XCTAssertEqual(pruned.map(\.id), ["long"])
    }

    func testAutoTitleFallsBackToPlaceholder() {
        XCTAssertEqual(ChatHistory.autoTitle(messages: []), "未命名对话")
        XCTAssertEqual(
            ChatHistory.autoTitle(messages: [
                ChatMessage(role: "assistant", content: "先说话的是助手"),
                ChatMessage(role: "user", content: "  标题  \n正文"),
            ]),
            "  标题  ")
    }
}
