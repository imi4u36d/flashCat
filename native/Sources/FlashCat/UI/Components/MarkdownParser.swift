// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatKit
import Foundation
import SwiftUI

/// 纯解析层：把 Markdown 文本切成块，并把块合成 `AttributedString`。
///
/// 与视图分开后，`MarkdownBlock.parse` 与 `MarkdownComposer` 可以在无窗口的
/// 测试里直接跑；`MarkdownView` 只负责决定用哪种渲染方式。
// MARK: - Composer

/// 把解析出的块合成一个 `AttributedString`，以单个 `Text` 渲染。
/// 行内样式（粗体、斜体、行内代码、链接）由 Foundation 的 Markdown
/// 解析器产出，这里只负责补上块级字体、颜色与块之间的间距。
enum MarkdownComposer {
    private static let inlineCodeBackground = Color.adaptive(dark: 0x26262E, light: 0xEEF0F4)

    static func compose(
        _ blocks: [MarkdownBlock],
        style: MarkdownStyle = .standard,
        tailFadeAlpha: Double? = nil
    ) -> AttributedString {
        var result = AttributedString()
        for block in blocks {
            if !result.characters.isEmpty {
                if case .heading = block.kind {
                    result += blockGap(style.headingSpacing, style: style)
                } else {
                    result += blockGap(style.paragraphSpacing, style: style)
                }
            }
            result += content(for: block.kind, style: style)
        }
        if let tailFadeAlpha, tailFadeAlpha < 0.99, !result.characters.isEmpty {
            let count = min(2, result.characters.count)
            let start = result.index(result.endIndex, offsetByCharacters: -count)
            let baseColor = result[start..<result.endIndex].foregroundColor ?? DS.text
            result[start..<result.endIndex].foregroundColor = baseColor.opacity(tailFadeAlpha)
        }
        return result
    }

    static func inlineTableCell(
        _ text: String,
        isHeader: Bool,
        size: CGFloat = 12.5
    ) -> AttributedString {
        let parsed: AttributedString
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            parsed = attributed
        } else {
            parsed = AttributedString(text)
        }
        return inline(
            parsed,
            size: size,
            weight: isHeader ? (size >= 15 ? .semibold : .medium) : .regular,
            color: isHeader ? DS.text : DS.text2,
            emphasisWeight: size >= 15 ? .semibold : .medium)
    }

    private static func content(
        for kind: MarkdownBlock.Kind,
        style: MarkdownStyle
    ) -> AttributedString {
        let size = style.bodySize
        let emphasis: NSFont.Weight = style.chat ? .semibold : .medium
        switch kind {
        case .heading(let level, let content):
            return inline(
                content,
                size: style.headingSize(level),
                weight: .semibold,
                color: DS.text,
                emphasisWeight: .semibold)

        case .paragraph(let content):
            return inline(
                content,
                size: size,
                color: DS.text,
                emphasisWeight: emphasis)

        case .bullet(let items):
            let pieces = items.map { item -> AttributedString in
                let prefix = item.indent > 0 ? String(repeating: "    ", count: item.indent) : ""
                let bullet = item.indent.isMultiple(of: 2) ? "•  " : "◦  "
                var marker = AttributedString(prefix + bullet)
                marker.font = DS.Font.prose(size)
                marker.foregroundColor = DS.text3
                marker += inline(
                    item.content, size: size, color: DS.text, emphasisWeight: emphasis)
                return marker
            }
            return joined(pieces, separator: newline(style: style))

        case .ordered(let items):
            let pieces = items.map { item -> AttributedString in
                var marker = AttributedString("\(item.number).  ")
                marker.font = DS.Font.proseNumber(size)
                marker.foregroundColor = DS.text3
                marker += inline(
                    item.content, size: size, color: DS.text, emphasisWeight: emphasis)
                return marker
            }
            return joined(pieces, separator: newline(style: style))

        case .code, .quote, .table, .rule:
            return AttributedString()
        }
    }

    // MARK: Inline styling

    static func inline(
        _ source: AttributedString,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: Color,
        emphasisWeight: NSFont.Weight = .medium
    ) -> AttributedString {
        var text = source
        text.font = DS.Font.prose(size, weight: weight)
        text.foregroundColor = color
        // Foundation 只标记行内代码的 presentation intent，SwiftUI 的 `Text`
        // 会据此换用等宽字体；换成单个 `Text` 后仍需显式补上等宽与底色。
        // 对话正文的加粗用 semibold（Splash 的 600），资料卡仍收敛到 medium，
        // 避免中文正文在系统默认 bold 下笔画过重、发糊。
        let styledRuns = text.runs.compactMap {
            run -> (Range<AttributedString.Index>, InlinePresentationIntent)? in
            guard let intent = run.inlinePresentationIntent, !intent.isEmpty else { return nil }
            return (run.range, intent)
        }
        for (range, intent) in styledRuns {
            if intent.contains(.code) {
                text[range].font = DS.Font.mono(max(11.5, size - 1.5))
                text[range].foregroundColor = DS.text
                text[range].backgroundColor = inlineCodeBackground
            } else if intent.contains(.stronglyEmphasized) || intent.contains(.emphasized) {
                let resolvedWeight: NSFont.Weight =
                    (intent.contains(.stronglyEmphasized) && weight == .regular)
                    ? emphasisWeight : weight
                var font = DS.Font.prose(size, weight: resolvedWeight)
                if intent.contains(.emphasized) {
                    font = font.italic()
                }
                text[range].font = font
            }
        }
        let linkRanges = text.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard run.link != nil else { return nil }
            return run.range
        }
        for range in linkRanges {
            text[range].foregroundColor = DS.accent
        }
        return text
    }

    private static func joined(
        _ pieces: [AttributedString],
        separator: AttributedString
    ) -> AttributedString {
        var out = AttributedString()
        for (index, piece) in pieces.enumerated() {
            if index > 0 { out += separator }
            out += piece
        }
        return out
    }

    private static func newline(style: MarkdownStyle) -> AttributedString {
        var text = AttributedString("\n")
        text.font = DS.Font.prose(style.bodySize)
        return text
    }

    /// 段落与块之间的纵向间隔：第一行用正文行高，第二行只占很小的占位高度，
    /// 保留单 `Text` 的跨段拖选与复制，同时避免整行空距过大。
    private static func blockGap(_ spacerSize: CGFloat, style: MarkdownStyle) -> AttributedString {
        var first = AttributedString("\n")
        first.font = DS.Font.prose(style.bodySize)
        var second = AttributedString("\n")
        second.font = .system(size: spacerSize)
        return first + second
    }
}

// MARK: - Blocks

struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(Int, AttributedString)
        case paragraph(AttributedString)
        case code(String?, String)
        case quote([AttributedString])
        case bullet([(indent: Int, content: AttributedString)])
        case ordered([(number: Int, index: Int, content: AttributedString)])
        case table([[String]])
        case rule
    }

    let id = UUID()
    let kind: Kind

    /// 解析结果缓存：视图每秒都会因为指标/状态变化重新求值 body，未变化的
    /// 历史消息若每次重解析整段 Markdown，会把滚动与实时指标一起拖慢。缓存
    /// 同时保持 `id` 稳定，SwiftUI 也就不必整块重建历史消息。
    private static let parseCacheLock = NSLock()
    nonisolated(unsafe) private static var parseCache: [String: [MarkdownBlock]] = [:]
    nonisolated(unsafe) private static var parseCacheOrder: [String] = []
    nonisolated(unsafe) private static var streamingCache: (source: String, blocks: [MarkdownBlock])?
    private static let parseCacheLimit = 32
    nonisolated(unsafe) private static var inlineCache: [String: AttributedString] = [:]
    nonisolated(unsafe) private static var inlineCacheOrder: [String] = []
    private static let inlineCacheLimit = 512

    static func parse(_ source: String, caching: Bool = true) -> [MarkdownBlock] {
        if !caching {
            // 流式内容只保留最后一次结果：同一帧内重复求值不会重解析，也不会
            // 把稳定消息的缓存条目挤掉。
            parseCacheLock.lock()
            if let streamingCache, streamingCache.source == source {
                let blocks = streamingCache.blocks
                parseCacheLock.unlock()
                return blocks
            }
            parseCacheLock.unlock()

            let blocks = parseUncached(source)

            parseCacheLock.lock()
            streamingCache = (source, blocks)
            parseCacheLock.unlock()
            return blocks
        }

        parseCacheLock.lock()
        if let hit = parseCache[source] {
            parseCacheLock.unlock()
            return hit
        }
        parseCacheLock.unlock()

        let blocks = parseUncached(source)

        parseCacheLock.lock()
        if parseCache[source] == nil {
            parseCache[source] = blocks
            parseCacheOrder.append(source)
            if parseCacheOrder.count > parseCacheLimit {
                let oldest = parseCacheOrder.removeFirst()
                parseCache.removeValue(forKey: oldest)
            }
        }
        parseCacheLock.unlock()
        return blocks
    }

    private static func parseUncached(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        func inline(_ text: String) -> AttributedString {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return AttributedString(text) }
            // 纯文本快路径：不含任何行内 Markdown 语法字符时直接构造，避免每次
            // 流式重解析都对整段历史段落调用昂贵的 Foundation Markdown 解析器。
            if !trimmed.contains(where: { "*_`~\\[]<&".contains($0) }),
                !trimmed.contains("http")
            {
                return AttributedString(trimmed)
            }
            parseCacheLock.lock()
            if let hit = inlineCache[trimmed] {
                parseCacheLock.unlock()
                return hit
            }
            parseCacheLock.unlock()

            let parsed: AttributedString
            if let attributed = try? AttributedString(
                markdown: trimmed,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                parsed = attributed
            } else {
                parsed = AttributedString(text)
            }

            parseCacheLock.lock()
            if inlineCache[trimmed] == nil {
                inlineCache[trimmed] = parsed
                inlineCacheOrder.append(trimmed)
                if inlineCacheOrder.count > inlineCacheLimit {
                    let oldest = inlineCacheOrder.removeFirst()
                    inlineCache.removeValue(forKey: oldest)
                }
            }
            parseCacheLock.unlock()
            return parsed
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let opening = openingFence(in: line) {
                var code: [String] = []
                index += 1
                while index < lines.count,
                    !isClosingFence(lines[index], char: opening.char, minLength: opening.length)
                {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(
                    MarkdownBlock(
                        kind: .code(
                            opening.language,
                            code.joined(separator: "\n"))))
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(MarkdownBlock(kind: .rule))
                index += 1
                continue
            }

            if let match = trimmed.firstMatch(ofHeading: true) {
                blocks.append(MarkdownBlock(kind: .heading(match.level, inline(match.text))))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count,
                    lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">")
                {
                    let content = lines[index].trimmingCharacters(in: .whitespaces)
                        .dropFirst()
                        .trimmingCharacters(in: .whitespaces)
                    quoted.append(content)
                    index += 1
                }
                blocks.append(MarkdownBlock(kind: .quote(quoted.map(inline))))
                continue
            }

            if bulletItem(in: line) != nil {
                var items: [(indent: Int, content: AttributedString)] = []
                while index < lines.count, let item = bulletItem(in: lines[index]) {
                    items.append((indent: item.indent, content: inline(item.text)))
                    index += 1
                }
                blocks.append(MarkdownBlock(kind: .bullet(items)))
                continue
            }

            if let first = orderedItem(trimmed) {
                var items: [(number: Int, index: Int, content: AttributedString)] = []
                var expected = first.number
                var order = 0
                var cursor = index
                while cursor < lines.count {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    guard let item = orderedItem(candidate), item.number == expected else { break }
                    items.append((item.number, order, inline(item.text)))
                    expected += 1
                    order += 1
                    cursor += 1
                }
                index = cursor
                blocks.append(MarkdownBlock(kind: .ordered(items)))
                continue
            }

            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                var rows: [[String]] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix("|"), candidate.hasSuffix("|") else { break }
                    let cells =
                        candidate
                        .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                        .components(separatedBy: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    // 分隔行（|---|---|）不是数据。
                    if cells.allSatisfy({ $0.allSatisfy { char in char == "-" || char == ":" } }) {
                        index += 1
                        continue
                    }
                    rows.append(cells)
                    index += 1
                }
                if !rows.isEmpty { blocks.append(MarkdownBlock(kind: .table(rows))) }
                continue
            }

            // 段落：一路吃到空行或另一个块级语法。
            var paragraph: [String] = [line]
            index += 1
            while index < lines.count {
                let candidate = lines[index]
                let trimmedCandidate = candidate.trimmingCharacters(in: .whitespaces)
                if trimmedCandidate.isEmpty
                    || openingFence(in: candidate) != nil
                    || trimmedCandidate.hasPrefix(">")
                    || bulletItem(in: candidate) != nil
                    || trimmedCandidate.hasPrefix("|")
                    || trimmedCandidate.firstMatch(ofHeading: true) != nil
                    || orderedItem(trimmedCandidate) != nil
                {
                    break
                }
                paragraph.append(candidate)
                index += 1
            }
            blocks.append(MarkdownBlock(kind: .paragraph(inline(paragraph.joined(separator: "\n")))))
        }
        return blocks
    }

    private static func openingFence(in line: String) -> (char: Character, length: Int, language: String?)? {
        var cursor = line.startIndex
        var spaces = 0
        while cursor < line.endIndex, line[cursor] == " ", spaces < 3 {
            spaces += 1
            cursor = line.index(after: cursor)
        }
        guard cursor < line.endIndex else { return nil }
        let char = line[cursor]
        guard char == "`" || char == "~" else { return nil }
        var count = 0
        while cursor < line.endIndex, line[cursor] == char {
            count += 1
            cursor = line.index(after: cursor)
        }
        guard count >= 3 else { return nil }
        let remainder = line[cursor...]
        if char == "`", remainder.contains("`") { return nil }
        let language = String(remainder).trimmingCharacters(in: .whitespaces)
        return (char, count, language.isEmpty ? nil : language)
    }

    private static func isClosingFence(_ line: String, char: Character, minLength: Int) -> Bool {
        var cursor = line.startIndex
        var spaces = 0
        while cursor < line.endIndex, line[cursor] == " ", spaces < 3 {
            spaces += 1
            cursor = line.index(after: cursor)
        }
        var count = 0
        while cursor < line.endIndex, line[cursor] == char {
            count += 1
            cursor = line.index(after: cursor)
        }
        guard count >= minLength else { return false }
        return line[cursor...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func bulletItem(in line: String) -> (indent: Int, text: String)? {
        var cursor = line.startIndex
        var spaces = 0
        while cursor < line.endIndex {
            let char = line[cursor]
            if char == " " {
                spaces += 1
                cursor = line.index(after: cursor)
            } else if char == "\t" {
                spaces += 2
                cursor = line.index(after: cursor)
            } else {
                break
            }
        }
        let rest = line[cursor...]
        guard rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") else {
            return nil
        }
        return (min(3, spaces / 2), String(rest.dropFirst(2)))
    }

    private static func orderedItem(_ text: String) -> (number: Int, text: String)? {
        guard let dot = text.firstIndex(of: ".") else { return nil }
        let prefix = text[text.startIndex..<dot]
        guard !prefix.isEmpty, prefix.count <= 3, let number = Int(prefix) else { return nil }
        let rest = text[text.index(after: dot)...]
        guard rest.first == " " else { return nil }
        return (number, rest.trimmingCharacters(in: .whitespaces))
    }
}

extension String {
    fileprivate struct HeadingMatch {
        let level: Int
        let text: String
    }

    fileprivate func firstMatch(ofHeading: Bool) -> HeadingMatch? {
        guard ofHeading else { return nil }
        var level = 0
        for character in self {
            if character == "#" { level += 1 } else { break }
            if level > 6 { return nil }
        }
        guard level > 0 else { return nil }
        let rest = dropFirst(level)
        guard rest.first == " " else { return nil }
        return HeadingMatch(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }
}
