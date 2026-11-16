// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation
import XCTest
@testable import FlashCatCLICore

/// `tailLines` 直接从文件尾分块倒读，边界都在换行/块接缝上：多要一个换行、
/// 丢掉被截断的首行、末尾没有换行时也要给出最后 N 行。这些用大文件不好复现，
/// 用小文件精确钉住。
final class LogsTailTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-logs-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func write(_ lines: [String], trailingNewline: Bool = true) throws -> String {
        let path = directory.appendingPathComponent("engine.log").path
        let body = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testTailsOnlyTheRequestedNumberOfLines() throws {
        let lines = (1...500).map { "line \($0)" }
        let path = try write(lines)
        XCTAssertEqual(LogsCommand.tailLines(path, limit: 10), Array(lines.suffix(10)))
    }

    func testHandlesAFileWithoutATrailingNewline() throws {
        let lines = (1...20).map { "line \($0)" }
        let path = try write(lines, trailingNewline: false)
        XCTAssertEqual(LogsCommand.tailLines(path, limit: 3), ["line 18", "line 19", "line 20"])
    }

    func testReturnsEverythingWhenTheFileIsShorterThanTheLimit() throws {
        let lines = ["only one", "only two"]
        let path = try write(lines)
        XCTAssertEqual(LogsCommand.tailLines(path, limit: 200), lines)
    }

    /// 文件大于一个 64 KiB 读块时才真正走「从中间开始」的分支：被块边界截断的首行
    /// 必须整行丢掉，输出里不能出现半行。
    func testDropsThePartialFirstLineWhenReadingAcrossChunks() throws {
        let padding = String(repeating: "x", count: 600)
        let lines = (1...200).map { "line \($0) \(padding)" }
        let path = try write(lines)
        let tail = LogsCommand.tailLines(path, limit: 5)
        XCTAssertEqual(tail, Array(lines.suffix(5)))
        XCTAssertTrue(tail.allSatisfy { $0.hasPrefix("line ") && $0.hasSuffix("x") })
    }

    func testEmptyFileIsEmpty() throws {
        let path = directory.appendingPathComponent("empty.log").path
        FileManager.default.createFile(atPath: path, contents: Data())
        XCTAssertEqual(LogsCommand.tailLines(path, limit: 10), [])
    }
}
