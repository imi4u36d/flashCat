// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import Foundation

/// 把 Hugging Face 的 README 模型卡洗成能直接渲染的 Markdown。
///
/// README 里混着大量 HTML：`<div align="center">`、shields.io 徽章、`<img>`。
/// `MarkdownView` 只认 Markdown 语法，这些标签会原样显示成一堆尖括号，
/// 所以先在入口处把 HTML 折叠成链接/文字，再交给 Markdown 渲染。
enum ModelCardText {
    private enum Block {
        case prose(String)
        case codeBlock(String)
    }

    static func normalized(_ raw: String) -> String {
        let content = stripFrontMatter(raw)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var blocks = splitBlocks(content).map { block -> Block in
            switch block {
            case .codeBlock:
                return block
            case .prose(let prose):
                return .prose(normalizeProse(prose))
            }
        }
        // 仅清理整篇文档首尾由剥离 front-matter 或 HTML 标签留下的空行；代码围栏内部原样保留。
        while let first = blocks.first, case .prose(let prose) = first {
            let trimmed = stripLeadingBlankLines(prose)
            if trimmed.isEmpty {
                blocks.removeFirst()
            } else {
                blocks[0] = .prose(trimmed)
                break
            }
        }
        while let last = blocks.last, case .prose(let prose) = last {
            let trimmed = stripTrailingBlankLines(prose)
            if trimmed.isEmpty {
                blocks.removeLast()
            } else {
                blocks[blocks.count - 1] = .prose(trimmed)
                break
            }
        }
        return blocks.map {
            switch $0 {
            case .prose(let text), .codeBlock(let text): return text
            }
        }
        .joined(separator: "\n")
    }

    private static func splitBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var fenceChar: Character?
        var fenceLength = 0

        func flushProse() {
            guard !proseLines.isEmpty else { return }
            blocks.append(.prose(proseLines.joined(separator: "\n")))
            proseLines.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            guard !codeLines.isEmpty else { return }
            blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
            codeLines.removeAll(keepingCapacity: true)
        }

        for line in text.components(separatedBy: "\n") {
            if let activeChar = fenceChar {
                codeLines.append(line)
                if isClosingFence(line, char: activeChar, minLength: fenceLength) {
                    flushCode()
                    fenceChar = nil
                    fenceLength = 0
                }
            } else if let opening = openingFence(in: line) {
                flushProse()
                fenceChar = opening.char
                fenceLength = opening.length
                codeLines.append(line)
            } else {
                proseLines.append(line)
            }
        }
        flushProse()
        flushCode()
        return blocks
    }

    private static func openingFence(in line: String) -> (char: Character, length: Int)? {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " ", leadingSpaces < 3 {
            leadingSpaces += 1
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return nil }
        let char = line[index]
        guard char == "`" || char == "~" else { return nil }
        var count = 0
        while index < line.endIndex, line[index] == char {
            count += 1
            index = line.index(after: index)
        }
        guard count >= 3 else { return nil }
        if char == "`", line[index...].contains("`") { return nil }
        return (char, count)
    }

    private static func isClosingFence(_ line: String, char: Character, minLength: Int) -> Bool {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " ", leadingSpaces < 3 {
            leadingSpaces += 1
            index = line.index(after: index)
        }
        var count = 0
        while index < line.endIndex, line[index] == char {
            count += 1
            index = line.index(after: index)
        }
        guard count >= minLength else { return false }
        return line[index...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func normalizeProse(_ rawProse: String) -> String {
        let (masked, placeholders) = maskInlineCode(rawProse)
        var text = linkedBadges(masked)
        text = standaloneImages(text)
        text = text.replacingOccurrences(
            of: "<br\\b[^>]*>", with: "\n",
            options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: "<p\\b[^>]*>", with: "\n\n",
            options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: "</p>", with: "\n\n",
            options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: "<(a|div|center|blockquote)\\b[^>]*>", with: "",
            options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: "</(a|div|center|blockquote)>", with: "",
            options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: "<[^>]+>", with: "",
            options: [.regularExpression, .caseInsensitive])
        text = decodeEntities(text)
        text = joinBadgeLines(text)
        text = unmaskInlineCode(text, placeholders: placeholders)
        return tidyLines(text)
    }

    private static func maskInlineCode(_ text: String) -> (String, [(token: String, value: String)]) {
        var sentinelBase = "\u{E000}FC_CODE_"
        while text.contains(sentinelBase) { sentinelBase += "_" }

        var masked = ""
        var placeholders: [(token: String, value: String)] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            if text[cursor] == "`" {
                var tickEnd = cursor
                var tickCount = 0
                while tickEnd < text.endIndex, text[tickEnd] == "`" {
                    tickCount += 1
                    tickEnd = text.index(after: tickEnd)
                }
                if let closingEnd = findClosingBackticks(in: text, from: tickEnd, count: tickCount) {
                    let token = "\(sentinelBase)\(placeholders.count)\u{E001}"
                    placeholders.append((token, String(text[cursor..<closingEnd])))
                    masked += token
                    cursor = closingEnd
                } else {
                    masked += String(text[cursor..<tickEnd])
                    cursor = tickEnd
                }
            } else {
                masked.append(text[cursor])
                cursor = text.index(after: cursor)
            }
        }
        return (masked, placeholders)
    }

    private static func findClosingBackticks(
        in text: String,
        from start: String.Index,
        count: Int
    ) -> String.Index? {
        var index = start
        while index < text.endIndex {
            if text[index] == "\n" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "\n" {
                    return nil
                }
            }
            if text[index] == "`" {
                var end = index
                var run = 0
                while end < text.endIndex, text[end] == "`" {
                    run += 1
                    end = text.index(after: end)
                }
                if run == count { return end }
                index = end
            } else {
                index = text.index(after: index)
            }
        }
        return nil
    }

    private static func unmaskInlineCode(
        _ text: String,
        placeholders: [(token: String, value: String)]
    ) -> String {
        var result = text
        for (token, value) in placeholders {
            result = result.replacingOccurrences(of: token, with: value)
        }
        return result
    }

    private static func stripLeadingBlankLines(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    private static func stripTrailingBlankLines(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func stripFrontMatter(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
            let end = lines.dropFirst().firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "---"
            })
        else { return text }
        return lines[(end + 1)...].joined(separator: "\n")
    }

    /// `<a href="…"><img alt="…"></a>` 是 shields.io 徽章，折成普通链接，
    /// 别让一张图撑成三行尖括号。
    private static func linkedBadges(_ text: String) -> String {
        replace(
            text,
            pattern: "<a\\b[^>]*href\\s*=\\s*\"([^\"]*)\"[^>]*>\\s*<img\\b[^>]*alt\\s*=\\s*\"([^\"]*)\"[^>]*>\\s*</a>",
            template: "[$2]($1)")
    }

    private static func standaloneImages(_ text: String) -> String {
        replace(text, pattern: "<img\\b[^>]*alt\\s*=\\s*\"([^\"]*)\"[^>]*>", template: "$1")
    }

    private static func replace(_ text: String, pattern: String, template: String) -> String {
        guard
            let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators])
        else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// 连续一整行的徽章链接合成一行，用 `·` 隔开，别把首屏全占满。
    private static func joinBadgeLines(_ text: String) -> String {
        let linkLine = try? NSRegularExpression(pattern: "^\\s*(?:\\[[^\\]]*\\]\\([^)]*\\)\\s*)+$")
        var output: [String] = []
        var badges: [String] = []

        func flush() {
            guard !badges.isEmpty else { return }
            output.append(badges.joined(separator: " · "))
            badges.removeAll()
        }

        for line in text.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            let isBadge = linkLine.map { $0.firstMatch(in: line, range: range) != nil } ?? false
            if isBadge {
                badges.append(line.trimmingCharacters(in: .whitespaces))
            } else {
                flush()
                output.append(line)
            }
        }
        flush()
        return output.joined(separator: "\n")
    }

    private static func tidyLines(_ text: String) -> String {
        var lines: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let trimmedRight = trimTrailingHorizontalWhitespace(rawLine)
            if trimmedRight.isEmpty {
                if lines.last?.isEmpty == false { lines.append("") }
            } else {
                lines.append(trimmedRight)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func trimTrailingHorizontalWhitespace(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex {
            let prev = line.index(before: end)
            guard line[prev] == " " || line[prev] == "\t" else { break }
            end = prev
        }
        return String(line[..<end])
    }

    private static func decodeEntities(_ text: String) -> String {
        var text = text
        let pairs: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
        ]
        for (entity, value) in pairs {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let range = NSRange(text.startIndex..., in: text)
            var decoded = ""
            var cursor = text.startIndex
            for match in regex.matches(in: text, range: range) {
                guard let full = Range(match.range, in: text),
                    let radixRange = Range(match.range(at: 1), in: text),
                    let valueRange = Range(match.range(at: 2), in: text)
                else { continue }
                decoded += text[cursor..<full.lowerBound]
                let radix = text[radixRange].isEmpty ? 10 : 16
                if let value = Int(text[valueRange], radix: radix),
                    let scalar = Unicode.Scalar(value)
                {
                    decoded += String(Character(scalar))
                }
                cursor = full.upperBound
            }
            decoded += text[cursor...]
            text = decoded
        }
        return text
    }
}
