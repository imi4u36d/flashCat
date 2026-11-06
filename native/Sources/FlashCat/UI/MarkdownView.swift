import SwiftUI
import Foundation

/// 对话正文的 Markdown 渲染：标题、段落、围栏代码、引用、列表、表格与分隔线。
///
/// 解析是刻意保守的：只认行首语法，inline 用 Foundation 的 Markdown 解析器，
/// 不认识的结构按段落原样显示。流式期间每次增量重解析，长回答的代价与文本长度
/// 成正比，但一次只有一条消息在长。
struct MarkdownView: View {
    let text: String
    /// 流式消息每次分片都会变成长字符串；把它塞进 LRU 会把已完成消息挤出
    /// 缓存，下一帧又要全部重解析。流式内容走独立的单槽缓存。
    var caching: Bool = true

    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(text, caching: caching) }

    var body: some View {
        // 整条回答合并成一个 `Text`：SwiftUI 的文本选择无法跨越多个 `Text`，
        // 逐块渲染时只能选中当前一块，无法从一行拖选到另一行。合并后既支持
        // 连续选择与复制，点击时也不会因为某一行的文本视图重新布局而抖动。
        Text(MarkdownComposer.compose(blocks))
            .textSelection(.enabled)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Composer

/// 把解析出的块合成一个 `AttributedString`，以单个 `Text` 渲染。
/// 行内样式（粗体、斜体、行内代码、链接）由 Foundation 的 Markdown
/// 解析器产出，这里只负责补上块级字体、颜色与块之间的间距。
private enum MarkdownComposer {
    private static let bodySize: CGFloat = 13
    private static let monoSize: CGFloat = 11.5

    private static var codeBackground: Color { Native.recess }

    static func compose(_ blocks: [MarkdownBlock]) -> AttributedString {
        var result = AttributedString()
        for block in blocks {
            if !result.characters.isEmpty {
                result += newline(count: 2)
            }
            result += content(for: block.kind)
        }
        return result
    }

    private static func content(for kind: MarkdownBlock.Kind) -> AttributedString {
        switch kind {
        case .heading(let level, let content):
            return inline(content,
                          font: .system(size: headingSize(level), weight: .bold),
                          color: Native.label)

        case .paragraph(let content):
            return inline(content, font: .system(size: bodySize), color: Native.label)

        case .code(let language, let code):
            var out = AttributedString()
            if let language, !language.isEmpty {
                out += styled(AttributedString(language),
                              font: .system(size: 9.5, weight: .semibold, design: .monospaced),
                              color: Native.tertiary)
                out += newline()
            }
            var codeText = AttributedString(code)
            codeText.font = .system(size: monoSize, design: .monospaced)
            codeText.foregroundColor = Native.label
            codeText.backgroundColor = codeBackground
            out += codeText
            return out

        case .quote(let lines):
            let pieces = lines.map { line -> AttributedString in
                var bar = AttributedString("▎ ")
                bar.font = .system(size: 12.5)
                bar.foregroundColor = Native.accent.opacity(0.55)
                bar += inline(line, font: .system(size: 12.5), color: Native.secondary)
                return bar
            }
            return joined(pieces, separator: newline())

        case .bullet(let items):
            let pieces = items.map { item -> AttributedString in
                var marker = AttributedString("•  ")
                marker.font = .system(size: bodySize)
                marker.foregroundColor = Native.accent
                marker += inline(item, font: .system(size: bodySize), color: Native.label)
                return marker
            }
            return joined(pieces, separator: newline())

        case .ordered(let items):
            let pieces = items.map { item -> AttributedString in
                var marker = AttributedString("\(item.number).  ")
                marker.font = .system(size: 11, weight: .semibold, design: .monospaced)
                marker.foregroundColor = Native.tertiary
                marker += inline(item.content, font: .system(size: bodySize), color: Native.label)
                return marker
            }
            return joined(pieces, separator: newline())

        case .table(let rows):
            return table(rows)

        case .rule:
            var rule = AttributedString(String(repeating: "─", count: 40))
            rule.font = .system(size: 10)
            rule.foregroundColor = Native.tertiary
            return rule
        }
    }

    // MARK: Inline styling

    private static func inline(_ source: AttributedString,
                               font: Font,
                               color: Color) -> AttributedString {
        var text = source
        text.font = font
        text.foregroundColor = color
        // Foundation 只标记行内代码的 presentation intent，SwiftUI 的 `Text`
        // 会据此换用等宽字体；换成单个 `Text` 后仍需显式补上等宽与底色。
        let codeRanges = text.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard run.inlinePresentationIntent?.contains(.code) == true else { return nil }
            return run.range
        }
        for range in codeRanges {
            text[range].font = .system(size: 12, design: .monospaced)
            text[range].backgroundColor = codeBackground
        }
        return text
    }

    private static func styled(_ text: AttributedString, font: Font, color: Color) -> AttributedString {
        var text = text
        text.font = font
        text.foregroundColor = color
        return text
    }

    private static func joined(_ pieces: [AttributedString],
                               separator: AttributedString) -> AttributedString {
        var out = AttributedString()
        for (index, piece) in pieces.enumerated() {
            if index > 0 { out += separator }
            out += piece
        }
        return out
    }

    private static func newline(count: Int = 1) -> AttributedString {
        var text = AttributedString(String(repeating: "\n", count: count))
        text.font = .system(size: bodySize)
        return text
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 20
        case 2: return 17
        case 3: return 15
        default: return 13.5
        }
    }

    // MARK: Tables

    private static func table(_ rows: [[String]]) -> AttributedString {
        guard !rows.isEmpty else { return AttributedString() }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return AttributedString() }

        var widths = Array(repeating: 0, count: columns)
        for row in rows {
            for (index, cell) in row.enumerated() where index < columns {
                widths[index] = max(widths[index], displayWidth(cell))
            }
        }

        var out = AttributedString()
        for (rowIndex, row) in rows.enumerated() {
            var line = ""
            for column in 0..<columns {
                let cell = column < row.count ? row[column] : ""
                line += cell
                if column < columns - 1 {
                    let padding = max(1, widths[column] - displayWidth(cell) + 2)
                    line += String(repeating: " ", count: padding)
                }
            }
            var piece = AttributedString(line)
            piece.font = rowIndex == 0
                ? .system(size: 11, weight: .semibold, design: .monospaced)
                : .system(size: 11, design: .monospaced)
            piece.foregroundColor = rowIndex == 0 ? Native.label : Native.secondary
            if rowIndex > 0 { out += newline() }
            out += piece
        }
        return out
    }

    /// 等宽字体里 CJK 字符占两格，用它估算表格列宽。
    private static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { width, character in
            width + (character.unicodeScalars.contains { $0.value >= 0x1100 } ? 2 : 1)
        }
    }
}

// MARK: - Blocks

struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(Int, AttributedString)
        case paragraph(AttributedString)
        case code(String?, String)
        case quote([AttributedString])
        case bullet([AttributedString])
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
            if let parsed = try? AttributedString(
                markdown: trimmed,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                return parsed
            }
            return AttributedString(text)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(MarkdownBlock(kind: .code(language.isEmpty ? nil : language,
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
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let content = lines[index].trimmingCharacters(in: .whitespaces)
                        .dropFirst()
                        .trimmingCharacters(in: .whitespaces)
                    quoted.append(content)
                    index += 1
                }
                blocks.append(MarkdownBlock(kind: .quote(quoted.map(inline))))
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                var items: [AttributedString] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix("- ") || candidate.hasPrefix("* ") || candidate.hasPrefix("+ ") else { break }
                    items.append(inline(String(candidate.dropFirst(2))))
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
                    let cells = candidate
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
                    || trimmedCandidate.hasPrefix("```")
                    || trimmedCandidate.hasPrefix(">")
                    || trimmedCandidate.hasPrefix("- ")
                    || trimmedCandidate.hasPrefix("* ")
                    || trimmedCandidate.hasPrefix("+ ")
                    || trimmedCandidate.hasPrefix("|")
                    || trimmedCandidate.firstMatch(ofHeading: true) != nil
                    || orderedItem(trimmedCandidate) != nil {
                    break
                }
                paragraph.append(candidate)
                index += 1
            }
            blocks.append(MarkdownBlock(kind: .paragraph(inline(paragraph.joined(separator: "\n")))))
        }
        return blocks
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

private extension String {
    struct HeadingMatch {
        let level: Int
        let text: String
    }

    func firstMatch(ofHeading: Bool) -> HeadingMatch? {
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
