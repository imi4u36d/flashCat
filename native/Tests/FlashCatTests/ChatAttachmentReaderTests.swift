// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation
import XCTest

@testable import FlashCat
@testable import FlashCatCore

final class ChatAttachmentReaderTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-attachments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    func testReadsPlainText() throws {
        let url = scratch.appendingPathComponent("需求说明.txt")
        try "第一段\n第二段".write(to: url, atomically: true, encoding: .utf8)

        let attachment = try ChatAttachmentReader.read(url)
        XCTAssertEqual(attachment.name, "需求说明.txt")
        XCTAssertEqual(attachment.text, "第一段\n第二段")
        XCTAssertEqual(attachment.kindLabel, "TXT")
        XCTAssertFalse(attachment.truncated)
    }

    func testRejectsBinaryBlob() throws {
        let url = scratch.appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0x02, 0x03, 0xFF]).write(to: url)
        XCTAssertThrowsError(try ChatAttachmentReader.read(url))
    }

    func testTruncatesLongText() throws {
        let url = scratch.appendingPathComponent("long.txt")
        let text = String(repeating: "a", count: ChatAttachmentReader.maxCharacters + 10)
        try text.write(to: url, atomically: true, encoding: .utf8)

        let attachment = try ChatAttachmentReader.read(url)
        XCTAssertTrue(attachment.truncated)
        XCTAssertEqual(attachment.text.count, ChatAttachmentReader.maxCharacters)
    }

    func testPromptBlockCarriesFileName() throws {
        let url = scratch.appendingPathComponent("spec.md")
        try "# 标题".write(to: url, atomically: true, encoding: .utf8)
        let attachment = try ChatAttachmentReader.read(url)

        let block = ChatAttachmentReader.promptBlock(for: attachment)
        XCTAssertTrue(block.contains("[附件：spec.md]"))
        XCTAssertTrue(block.contains("# 标题"))
        XCTAssertTrue(block.contains("[/附件]"))
    }

    func testTurnContentFallsBackToVisibleContent() {
        let plain = ChatMessage(role: "user", content: "看看这个")
        XCTAssertEqual(plain.turnContent, "看看这个")

        let withFiles = ChatMessage(
            role: "user", content: "看看这个",
            attachmentNames: ["spec.md"],
            engineContent: "看看这个\n[附件：spec.md]\n正文")
        XCTAssertEqual(withFiles.turnContent, "看看这个\n[附件：spec.md]\n正文")
    }
}
