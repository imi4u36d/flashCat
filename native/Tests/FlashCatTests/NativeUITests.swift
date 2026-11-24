// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

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

    func testNoLiquidGlassRemainsInAppSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/FlashCatTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // native/
            .appendingPathComponent("Sources/FlashCat")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]))
        let files: [URL] = enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
        XCTAssertGreaterThan(files.count, 30, "源码目录扫描异常")

        let banned = [
            #"\.glassEffect\("#,
            #"GlassEffectContainer"#,
            #"\.buttonStyle\(\s*\.glass"#,
            #"\.scrollEdgeEffectStyle"#,
            #"\.regularMaterial"#,
            #"\.ultraThinMaterial"#,
            #"\.thinMaterial"#,
            #"\.thickMaterial"#,
            #"LiquidGlass"#,
        ]
        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for pattern in banned {
                let expression = try NSRegularExpression(pattern: pattern)
                if expression.firstMatch(in: source, range: range) != nil {
                    offenders.append(file.lastPathComponent + " ← " + pattern)
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "系统内不应再使用 Liquid Glass / 材质模糊：\(offenders.joined(separator: " | "))")
    }

    func testModelCardTextPreservesCodeFencesAndIndentation() {
        let raw = """
            ---
            license: apache-2.0
            ---

            <p><a href="https://example.com"><img alt="License"></a></p>

            Use `<div>` inline &amp; keep nested lists:

            - top item
              - nested item
                - deep item

            ```python
            def render():
                return "<span>&amp;</span>"


            class Sample:
                pass
            ```

            ~~~bash
            echo "<p>hello</p>"
            ~~~
            """
        let normalized = ModelCardText.normalized(raw)
        XCTAssertFalse(normalized.contains("license: apache-2.0"))
        XCTAssertTrue(normalized.contains("[License](https://example.com)"))
        XCTAssertTrue(normalized.contains("Use `<div>` inline & keep nested lists:"))
        XCTAssertTrue(normalized.contains("\n  - nested item\n    - deep item\n"))
        XCTAssertTrue(
            normalized.contains(
                "```python\ndef render():\n    return \"<span>&amp;</span>\"\n\n\nclass Sample:\n    pass\n```"
            )
        )
        XCTAssertTrue(normalized.contains("~~~bash\necho \"<p>hello</p>\"\n~~~"))
    }

    func testModelDownloadTaskCodableBackwardCompatibility() throws {
        let legacyJSON = """
            {
              "engine": "omlx",
              "model": "Qwen/Qwen3-8B-MLX-4bit",
              "status": "paused",
              "totalBytes": 1000,
              "downloadedBytes": 250,
              "addedAt": 1000000,
              "shared": ["omlx", "mtplx"]
            }
            """
        let decodedLegacy = try JSONDecoder().decode(
            ModelDownloadTask.self,
            from: Data(legacyJSON.utf8))
        XCTAssertEqual(decodedLegacy.engine, .omlx)
        XCTAssertEqual(decodedLegacy.model, "Qwen/Qwen3-8B-MLX-4bit")
        XCTAssertEqual(decodedLegacy.status, .paused)
        XCTAssertEqual(decodedLegacy.totalBytes, 1000)
        XCTAssertEqual(decodedLegacy.downloadedBytes, 250)
        XCTAssertEqual(decodedLegacy.shared, [.omlx, .mtplx])
        XCTAssertNil(decodedLegacy.source)
        XCTAssertNil(decodedLegacy.include)

        let task = ModelDownloadTask(
            engine: .splash,
            model: "Qwen/Qwen3-8B-GGUF",
            status: .downloading,
            totalBytes: 4096,
            downloadedBytes: 512,
            shared: [.splash],
            source: .modelScope,
            include: ["*Q4_K_M*.gguf"]
        )
        let encoded = try JSONEncoder().encode(task)
        let roundTripped = try JSONDecoder().decode(ModelDownloadTask.self, from: encoded)
        XCTAssertEqual(roundTripped.source, .modelScope)
        XCTAssertEqual(roundTripped.include, ["*Q4_K_M*.gguf"])
    }

    func testPageCommandPaletteOrderAndShortcutsMatchApp() throws {
        XCTAssertEqual(Page.primaryPages, [.chat, .lab])
        XCTAssertEqual(Page.consolePages, [.overview, .models, .engines, .logs, .settings])
        XCTAssertEqual(Page.orderedForCommandPalette, Page.primaryPages + Page.consolePages)
        XCTAssertEqual(Set(Page.orderedForCommandPalette), Set(Page.allCases))
        XCTAssertEqual(Page.orderedForCommandPalette.count, Page.allCases.count)

        let appURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/FlashCatTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // native/
            .appendingPathComponent("Sources/FlashCat/App/App.swift")
        let appSource = try String(contentsOf: appURL, encoding: .utf8)
        let pattern = #"state\.section\s*=\s*\.(\w+)\s*\}\s*\.keyboardShortcut\("([0-9,])",\s*modifiers:\s*\.command\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(appSource.startIndex..., in: appSource)
        var appShortcuts: [String: String] = [:]
        for match in regex.matches(in: appSource, range: range) {
            guard let pageRange = Range(match.range(at: 1), in: appSource),
                let digitRange = Range(match.range(at: 2), in: appSource)
            else { continue }
            appShortcuts[String(appSource[pageRange])] = "⌘" + String(appSource[digitRange])
        }

        XCTAssertEqual(appShortcuts.count, Page.allCases.count)
        for page in Page.orderedForCommandPalette {
            XCTAssertFalse(page.shortcutDisplay.isEmpty)
            let caseName = "\(page)"
            XCTAssertEqual(
                page.shortcutDisplay,
                appShortcuts[caseName],
                "\(page) shortcutDisplay mismatches App.swift")
        }
    }

    func testTildeCodeFenceAndNestedBulletListParsing() {
        let codeBlocks = MarkdownBlock.parse("~~~bash\necho hi\n~~~")
        XCTAssertEqual(codeBlocks.count, 1)
        guard case .code(let language, let code) = codeBlocks[0].kind else {
            return XCTFail("波浪线围栏应当解析为代码块")
        }
        XCTAssertEqual(language, "bash")
        XCTAssertEqual(code, "echo hi")

        let bullets = MarkdownBlock.parse("- top\n  - child\n    - grandchild")
        XCTAssertEqual(bullets.count, 1)
        guard case .bullet(let items) = bullets[0].kind else {
            return XCTFail("应当解析为无序列表")
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.indent), [0, 1, 2])
        XCTAssertEqual(items.map { String($0.content.characters) }, ["top", "child", "grandchild"])
    }

    func testLogsDigestCountsAndFilteringMatchAllLevels() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            LogFeedEntry(
                origin: "omlx",
                tag: "omlx",
                line: LogLine(id: 1, time: now, text: "Engine ready on port 8000", level: .system)),
            LogFeedEntry(
                origin: "omlx",
                tag: "omlx",
                line: LogLine(id: 2, time: now, text: "Slow token generation warning", level: .warning)),
            LogFeedEntry(
                origin: "splash",
                tag: "splash",
                line: LogLine(id: 3, time: now, text: "Failed to load Draft weights", level: .error)),
            LogFeedEntry(
                origin: "splash",
                tag: "splash",
                line: LogLine(id: 4, time: now, text: "Request completed in 42ms", level: .success)),
            LogFeedEntry(
                origin: "splash",
                tag: "splash",
                line: LogLine(id: 5, time: now, text: "Loaded model weights", level: .info)),
        ]

        let all = LogsDigest.make(from: entries, level: .all, query: "")
        XCTAssertEqual(all.lines.count, 5)
        XCTAssertEqual(all.counts[.all], 5)
        XCTAssertEqual(all.counts[.info], 3)
        XCTAssertEqual(all.counts[.warning], 1)
        XCTAssertEqual(all.counts[.error], 1)

        let warnings = LogsDigest.make(from: entries, level: .warning, query: "")
        XCTAssertEqual(warnings.lines.map(\.text), ["Slow token generation warning"])
        XCTAssertEqual(warnings.counts[.all], 5)

        let queryMatch = LogsDigest.make(from: entries, level: .all, query: "WEIGHTS")
        XCTAssertEqual(queryMatch.lines.map(\.id), ["splash#3", "splash#5"])
        XCTAssertEqual(queryMatch.counts[.all], 5)
    }
}
