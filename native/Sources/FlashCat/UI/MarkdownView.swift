// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

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
    /// 对话气泡按文字自身宽度收拢；资料卡等页面仍铺满可用宽度。
    var fillsWidth: Bool = true
    /// 流式吐字时末尾 1~2 个字符的渐显透明度，nil 表示完全不透明。
    var tailFadeAlpha: Double? = nil

    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(text, caching: caching) }
    private var segments: [MarkdownSegment] { MarkdownSegment.group(blocks) }

    var body: some View {
        // 连续的文字块（标题、段落、列表）仍然合并成一个 `Text`，保持跨段落
        // 拖选与复制；代码块、引用、表格、分隔线则各自独立成块，避免字符级底色
        // 在每行后面画出参差不齐的高亮条。
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case .text(let group):
                    let isLast = index == segments.count - 1
                    Text(MarkdownComposer.compose(group, tailFadeAlpha: isLast ? tailFadeAlpha : nil))
                        .textSelection(.enabled)
                        .lineSpacing(4.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)

                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)

                case .quote(let lines):
                    QuoteBlockView(lines: lines)

                case .table(let rows):
                    MarkdownTableView(rows: rows)

                case .rule:
                    Rectangle()
                        .fill(DS.line2)
                        .frame(height: 1)
                        .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    }
}

/// 流式吐字动画包装：按 60fps 节拍平滑推进可见字符数，并在末尾 1~2 个字符
/// 附带柔和的渐显过渡，避免网络分片整块跳出带来的生硬感。
struct StreamingMarkdownView: View {
    let text: String
    let streaming: Bool
    var fillsWidth: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealedProgress: Double
    @State private var targetLength: Int
    @State private var activeStreaming: Bool
    @State private var pumpTask: Task<Void, Never>?

    init(text: String, streaming: Bool, fillsWidth: Bool = false) {
        self.text = text
        self.streaming = streaming
        self.fillsWidth = fillsWidth
        let initial = text.count > 40 ? Double(text.count) : Double(min(1, text.count))
        _revealedProgress = State(initialValue: initial)
        _targetLength = State(initialValue: text.count)
        _activeStreaming = State(initialValue: streaming)
    }

    private var targetCount: Int { text.count }

    var body: some View {
        if !streaming || reduceMotion {
            MarkdownView(text: text, caching: !streaming, fillsWidth: fillsWidth)
                .onDisappear { stopPump() }
        } else {
            let count = min(targetCount, max(targetCount > 0 ? 1 : 0, Int(ceil(revealedProgress))))
            let slice = count >= targetCount ? text : String(text.prefix(count))
            MarkdownView(text: slice,
                         caching: false,
                         fillsWidth: fillsWidth,
                         tailFadeAlpha: leadingTailAlpha())
                .onAppear {
                    targetLength = text.count
                    activeStreaming = streaming
                    if text.count > 40, revealedProgress < Double(text.count) {
                        revealedProgress = Double(text.count)
                    }
                    ensurePumpRunning()
                }
                .onDisappear { stopPump() }
                .onChange(of: text.count) { _, newCount in
                    targetLength = newCount
                    if Double(newCount) < revealedProgress {
                        revealedProgress = Double(newCount)
                    }
                    ensurePumpRunning()
                }
                .onChange(of: streaming) { _, active in
                    activeStreaming = active
                    if !active {
                        stopPump()
                        revealedProgress = Double(text.count)
                    }
                }
        }
    }

    private func ensurePumpRunning() {
        guard activeStreaming, !reduceMotion, revealedProgress < Double(targetLength) else { return }
        guard pumpTask == nil else { return }
        pumpTask = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled, activeStreaming, revealedProgress < Double(targetLength) {
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { break }
                let now = Date()
                let dt = min(0.05, max(1.0 / 120.0, now.timeIntervalSince(last)))
                last = now
                let target = Double(targetLength)
                let backlog = target - revealedProgress
                guard backlog > 0 else { break }
                let speed = max(26.0, backlog * 14.0)
                revealedProgress = min(target, revealedProgress + speed * dt)
            }
            pumpTask = nil
        }
    }

    private func stopPump() {
        pumpTask?.cancel()
        pumpTask = nil
    }

    private func leadingTailAlpha() -> Double? {
        guard revealedProgress < Double(targetCount) else { return nil }
        let frac = revealedProgress - floor(revealedProgress)
        return 0.35 + 0.65 * (frac == 0 ? 1.0 : frac)
    }
}

// MARK: - Segments & Block Views

private enum MarkdownSegment {
    case text([MarkdownBlock])
    case code(String?, String)
    case quote([AttributedString])
    case table([[String]])
    case rule

    static func group(_ blocks: [MarkdownBlock]) -> [MarkdownSegment] {
        var result: [MarkdownSegment] = []
        var textBuffer: [MarkdownBlock] = []

        func flushText() {
            guard !textBuffer.isEmpty else { return }
            result.append(.text(textBuffer))
            textBuffer.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            switch block.kind {
            case .heading, .paragraph, .bullet, .ordered:
                textBuffer.append(block)
            case .code(let language, let code):
                flushText()
                result.append(.code(language, code))
            case .quote(let lines):
                flushText()
                result.append(.quote(lines))
            case .table(let rows):
                flushText()
                result.append(.table(rows))
            case .rule:
                flushText()
                result.append(.rule)
            }
        }
        flushText()
        return result
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    private var displayLanguage: String {
        guard let language, !language.isEmpty else { return "code" }
        return language.lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(displayLanguage)
                    .font(DS.Font.mono(11, weight: .medium))
                    .foregroundStyle(DS.text3)

                Spacer(minLength: 0)

                Button(action: copyCode) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: copied ? .semibold : .regular))
                            .contentTransition(.symbolEffect(.replace))
                        Text(copied ? "已复制" : "复制")
                            .font(DS.Font.xs)
                    }
                    .foregroundStyle(copied ? DS.accent : DS.text3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plainHit)
                .animation(DS.Motion.snappy, value: copied)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(DS.surface)

            Rectangle()
                .fill(DS.line)
                .frame(height: 1)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code.isEmpty ? " " : code)
                    .font(DS.Font.mono(12.5))
                    .foregroundStyle(DS.text)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.rect(DS.Radius.md).fill(DS.bg))
        .overlay(DS.rect(DS.Radius.md).strokeBorder(DS.line2, lineWidth: 1))
        .clipShape(DS.rect(DS.Radius.md))
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        resetTask?.cancel()
        withAnimation(DS.Motion.snappy) { copied = true }
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(DS.Motion.snappy) { copied = false }
        }
    }
}

private struct QuoteBlockView: View {
    let lines: [AttributedString]

    private var composed: AttributedString {
        var out = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 {
                var br = AttributedString("\n")
                br.font = .system(size: 13.5)
                out += br
            }
            out += MarkdownComposer.inline(line, font: .system(size: 13.5), color: DS.text2)
        }
        return out
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(DS.accent.opacity(0.65))
                .frame(width: 3)

            Text(composed)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.rect(DS.Radius.md).fill(DS.surface.opacity(0.75)))
        .overlay(DS.rect(DS.Radius.md).strokeBorder(DS.line, lineWidth: 1))
    }
}

private struct MarkdownTableView: View {
    let rows: [[String]]

    private var columnCount: Int {
        rows.map(\.count).max() ?? 0
    }

    var body: some View {
        if !rows.isEmpty, columnCount > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        if rowIndex > 0 {
                            Rectangle()
                                .fill(DS.line)
                                .frame(height: 1)
                                .gridCellUnsizedAxes([.horizontal])
                        }
                        GridRow {
                            ForEach(0..<columnCount, id: \.self) { col in
                                let cell = col < row.count ? row[col] : ""
                                Text(MarkdownComposer.inlineTableCell(cell, isHeader: rowIndex == 0))
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: 320, alignment: .leading)
                            }
                        }
                        .background(rowIndex == 0 ? DS.raised : Color.clear)
                    }
                }
            }
            .background(DS.rect(DS.Radius.md).fill(DS.surface))
            .overlay(DS.rect(DS.Radius.md).strokeBorder(DS.line2, lineWidth: 1))
            .clipShape(DS.rect(DS.Radius.md))
        }
    }
}

// MARK: - Composer

/// 把解析出的块合成一个 `AttributedString`，以单个 `Text` 渲染。
/// 行内样式（粗体、斜体、行内代码、链接）由 Foundation 的 Markdown
/// 解析器产出，这里只负责补上块级字体、颜色与块之间的间距。
private enum MarkdownComposer {
    private static let bodySize: CGFloat = 14
    private static let inlineCodeBackground = Color.adaptive(dark: 0x26262E, light: 0xEAEAEF)

    static func compose(_ blocks: [MarkdownBlock], tailFadeAlpha: Double? = nil) -> AttributedString {
        var result = AttributedString()
        for block in blocks {
            if !result.characters.isEmpty {
                result += newline(count: 2)
            }
            result += content(for: block.kind)
        }
        if let tailFadeAlpha, tailFadeAlpha < 0.99, !result.characters.isEmpty {
            let count = min(2, result.characters.count)
            let start = result.index(result.endIndex, offsetByCharacters: -count)
            let baseColor = result[start..<result.endIndex].foregroundColor ?? DS.text
            result[start..<result.endIndex].foregroundColor = baseColor.opacity(tailFadeAlpha)
        }
        return result
    }

    static func inlineTableCell(_ text: String, isHeader: Bool) -> AttributedString {
        let parsed: AttributedString
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            parsed = attributed
        } else {
            parsed = AttributedString(text)
        }
        return inline(parsed,
                      font: .system(size: 12.5, weight: isHeader ? .semibold : .regular),
                      color: isHeader ? DS.text : DS.text2)
    }

    private static func content(for kind: MarkdownBlock.Kind) -> AttributedString {
        switch kind {
        case .heading(let level, let content):
            return inline(content,
                          font: .system(size: headingSize(level), weight: .semibold),
                          color: DS.text)

        case .paragraph(let content):
            return inline(content, font: .system(size: bodySize), color: DS.text)

        case .bullet(let items):
            let pieces = items.map { item -> AttributedString in
                var marker = AttributedString("•  ")
                marker.font = .system(size: bodySize, weight: .semibold)
                marker.foregroundColor = DS.accent
                marker += inline(item, font: .system(size: bodySize), color: DS.text)
                return marker
            }
            return joined(pieces, separator: newline())

        case .ordered(let items):
            let pieces = items.map { item -> AttributedString in
                var marker = AttributedString("\(item.number).  ")
                marker.font = .system(size: 12.5, weight: .semibold, design: .monospaced)
                marker.foregroundColor = DS.text3
                marker += inline(item.content, font: .system(size: bodySize), color: DS.text)
                return marker
            }
            return joined(pieces, separator: newline())

        case .code, .quote, .table, .rule:
            return AttributedString()
        }
    }

    // MARK: Inline styling

    static func inline(_ source: AttributedString,
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
            text[range].font = .system(size: 12.5, design: .monospaced)
            text[range].foregroundColor = DS.text
            text[range].backgroundColor = inlineCodeBackground
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
        case 1: return 19
        case 2: return 16.5
        case 3: return 15
        default: return 14
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
               !trimmed.contains("http") {
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
