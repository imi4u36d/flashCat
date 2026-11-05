import XCTest
@testable import FlashCat

/// 界面层里可以脱离窗口断言的部分：Markdown 分块与日志筛选。
/// 视图本身的版式仍然只能手工回归（见 `UI-SPEC.md`）。
final class NativeUITests: XCTestCase {
    func testHeadingAndParagraphBlocks() {
        let blocks = MarkdownBlock.parse("# 标题\n\n这是正文。\n第二行。")
        XCTAssertEqual(blocks.count, 2)
        if case .heading(let level, let text) = blocks[0].kind {
            XCTAssertEqual(level, 1)
            XCTAssertEqual(String(text.characters), "标题")
        } else {
            XCTFail("第一块应当是标题")
        }
        if case .paragraph(let text) = blocks[1].kind {
            XCTAssertTrue(String(text.characters).contains("这是正文。"))
        } else {
            XCTFail("第二块应当是段落")
        }
    }

    func testCodeFenceKeepsLanguageAndLines() {
        let blocks = MarkdownBlock.parse("```swift\nlet a = 1\nprint(a)\n```")
        XCTAssertEqual(blocks.count, 1)
        guard case .code(let language, let code) = blocks[0].kind else {
            return XCTFail("应当是代码块")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let a = 1\nprint(a)")
    }

    func testBulletAndOrderedLists() {
        let bullets = MarkdownBlock.parse("- 一\n- 二\n- 三")
        guard case .bullet(let items) = bullets[0].kind else {
            return XCTFail("应当是无序列表")
        }
        XCTAssertEqual(items.count, 3)

        let ordered = MarkdownBlock.parse("1. 甲\n2. 乙")
        guard case .ordered(let entries) = ordered[0].kind else {
            return XCTFail("应当是有序列表")
        }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1].number, 2)
    }

    func testTableSkipsSeparatorRow() {
        let blocks = MarkdownBlock.parse("| 名称 | 值 |\n|---|---|\n| A | 1 |")
        guard case .table(let rows) = blocks[0].kind else {
            return XCTFail("应当是表格")
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], ["名称", "值"])
        XCTAssertEqual(rows[1], ["A", "1"])
    }

    func testUnclosedFenceDoesNotLoseText() {
        let blocks = MarkdownBlock.parse("```\n仍有的内容")
        guard case .code(_, let code) = blocks[0].kind else {
            return XCTFail("未闭合的围栏仍按代码块呈现")
        }
        XCTAssertEqual(code, "仍有的内容")
    }

    func testLogsFilterMapping() {
        XCTAssertTrue(LogsFilter.all.matches(.error))
        XCTAssertTrue(LogsFilter.info.matches(.system))
        XCTAssertTrue(LogsFilter.info.matches(.success))
        XCTAssertFalse(LogsFilter.info.matches(.warning))
        XCTAssertTrue(LogsFilter.warning.matches(.warning))
        XCTAssertFalse(LogsFilter.error.matches(.info))
    }
}
