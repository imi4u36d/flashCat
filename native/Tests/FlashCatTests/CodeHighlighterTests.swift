// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest

@testable import FlashCat
@testable import FlashCatCore

final class CodeHighlighterTests: XCTestCase {
    private func color(_ text: NSAttributedString, at index: Int) -> NSColor? {
        text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    func testSwiftKeywordAndStringUseDifferentColors() {
        let code = #"let name = "return" // 说明"#
        let highlighted = CodeHighlighter.highlighted(code, language: "swift")
        let keyword = color(highlighted, at: 0)  // let
        let identifier = color(highlighted, at: 4)  // name
        let string = color(highlighted, at: 11)  // "return"
        let comment = color(highlighted, at: 24)  // // 说明
        XCTAssertNotEqual(keyword, identifier)
        XCTAssertNotEqual(string, keyword, "字符串里的关键字不能按关键字着色")
        XCTAssertNotEqual(comment, string)
    }

    func testPythonCommentWinsOverKeyword() {
        let code = "# if return\nprint(1)"
        let highlighted = CodeHighlighter.highlighted(code, language: "python")
        let comment = color(highlighted, at: 2)
        let afterComment = color(highlighted, at: code.count - 1)
        XCTAssertNotEqual(comment, afterComment, "注释整行应压过关键字颜色")
    }

    func testJSONKeysDifferFromValues() {
        let code = #"{"model": "qwen", "n": 3}"#
        let highlighted = CodeHighlighter.highlighted(code, language: "json")
        let key = color(highlighted, at: 2)  // model
        let value = color(highlighted, at: 12)  // qwen
        XCTAssertNotEqual(key, value)
    }

    func testLinesKeepTextAndIndentation() {
        let code = "func f() {\n    let x = 1\n}"
        let lines = CodeHighlighter.lines(code, language: "swift")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(String(lines[1].characters), "    let x = 1")
    }

    func testUnknownLanguageAndNonASCIIDoNotCrash() {
        let code = "你好，世界 👋\nplain text 123"
        let lines = CodeHighlighter.lines(code, language: nil)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(lines[0].characters), "你好，世界 👋")
        XCTAssertEqual(String(lines[1].characters), "plain text 123")
    }

    /// 行缓存命中后结果必须与首次计算一致；`HighlightedCode` 的每一行都从这里取文本。
    func testRepeatedLineExtractionStaysStable() {
        let code = (1...120)
            .map { "let value\($0) = \"\($0)\" // 行 \($0)" }
            .joined(separator: "\n")
        let first = CodeHighlighter.lines(code, language: "swift")
        let second = CodeHighlighter.lines(code, language: "swift")
        XCTAssertEqual(first.count, 120)
        XCTAssertEqual(first.map { String($0.characters) }, second.map { String($0.characters) })
    }

    /// 缓存键必须带上代码本身：两段不同的代码不能互相串行。
    func testLineCacheKeepsDifferentBlocksApart() {
        let a = CodeHighlighter.lines("let a = 1", language: "swift")
        let b = CodeHighlighter.lines("let b = 2", language: "swift")
        XCTAssertEqual(String(a[0].characters), "let a = 1")
        XCTAssertEqual(String(b[0].characters), "let b = 2")
    }
}
