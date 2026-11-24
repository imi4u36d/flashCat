// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation
import SwiftUI

/// Markdown 的两套排版尺度：资料卡沿用原来的紧凑版，对话正文对齐 Splash 的
/// 15pt / 24pt 阅读节奏（标题、段落间距、代码块与表格也一起换）。
struct MarkdownStyle: Equatable {
    var bodySize: CGFloat
    var lineSpacing: CGFloat
    /// 段落之间的额外空隙（合并进单个 `Text` 时用空行模拟）。
    var paragraphSpacing: CGFloat
    var headingSpacing: CGFloat
    var headingSizes: [CGFloat]
    /// 对话正文：代码块与表格是「描边 + 分隔线」而不是一整块卡片。
    var chat: Bool

    static let standard = MarkdownStyle(
        bodySize: 13.5,
        lineSpacing: 5.5,
        paragraphSpacing: 6,
        headingSpacing: 10,
        headingSizes: [18, 16, 14.5, 13.5, 13.5, 13.5],
        chat: false)

    /// Splash：正文 15pt / 行高 24pt，标题 20 / 17 / 15，块间距 14。
    static let chat = MarkdownStyle(
        bodySize: 15,
        lineSpacing: 5,
        paragraphSpacing: 9,
        headingSpacing: 12,
        headingSizes: [20, 17, 15, 15, 15, 15],
        chat: true)

    func headingSize(_ level: Int) -> CGFloat {
        let index = min(max(level - 1, 0), headingSizes.count - 1)
        return headingSizes[index]
    }
}

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
    var style: MarkdownStyle = .standard

    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(text, caching: caching) }
    private var segments: [MarkdownSegment] { MarkdownSegment.group(blocks) }

    var body: some View {
        // 连续的文字块（标题、段落）仍然合并成一个 `Text`，保持跨段落拖选与
        // 复制；列表单独成块，标记右对齐成一列；代码块、引用、表格、分隔线各自
        // 独立，避免字符级底色在每行后面画出参差不齐的高亮条。
        VStack(alignment: .leading, spacing: style.chat ? 14 : 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case .text(let group):
                    let isLast = index == segments.count - 1
                    Text(
                        MarkdownComposer.compose(
                            group,
                            style: style,
                            tailFadeAlpha: isLast ? tailFadeAlpha : nil)
                    )
                    .textSelection(.enabled)
                    .lineSpacing(style.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)

                case .list(let items):
                    MarkdownListView(items: items, style: style)

                case .code(let language, let code):
                    CodeBlockView(language: language, code: code, style: style)

                case .quote(let lines):
                    QuoteBlockView(lines: lines, style: style)

                case .table(let rows):
                    MarkdownTableView(rows: rows, style: style)

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

/// 流式 Markdown：按 Splash `page.paced` 的节奏把新到的字符逐帧放出来——
/// 每一帧放出剩余积压约 `1 - e^(-dt/100ms)` 的比例，至少一个字符。首次出现
/// 时整段直接显示，流结束时立刻补齐；Markdown 每帧按可见切片重新解析，
/// 代码块、列表的样式在吐字过程中逐步成形。
struct StreamingMarkdownView: View {
    let text: String
    let streaming: Bool
    var fillsWidth: Bool = false
    var style: MarkdownStyle = .standard

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Int
    /// 当前要追的正文。放在 `@State` 里而不是直接读 `text`：吐字任务会跨
    /// 多次视图重建存活，读捕获时的 `text` 会停在旧长度，模型停顿时最后
    /// 几个字就永远出不来。
    @State private var target: String
    @State private var pumpTask: Task<Void, Never>?
    @State private var lastTick = Date()

    init(text: String, streaming: Bool, fillsWidth: Bool = false, style: MarkdownStyle = .standard) {
        self.text = text
        self.streaming = streaming
        self.fillsWidth = fillsWidth
        self.style = style
        // 页面打开时已经存在的正文整段显示（Splash 的 `shown[key] ??= text`），
        // 只有之后到达的增量才走逐字节奏。
        _shown = State(initialValue: text.count)
        _target = State(initialValue: text)
    }

    private var visibleText: String {
        guard streaming, !reduceMotion, shown < target.count else { return target }
        return String(target.prefix(shown))
    }

    var body: some View {
        MarkdownView(
            text: visibleText,
            caching: !streaming,
            fillsWidth: fillsWidth,
            tailFadeAlpha: nil,
            style: style
        )
        .onAppear { sync() }
        .onChange(of: text) { _, _ in sync() }
        .onChange(of: streaming) { _, _ in sync() }
        .onChange(of: reduceMotion) { _, _ in sync() }
        .onDisappear { stopPump() }
    }

    private func sync() {
        target = text
        if !streaming || reduceMotion {
            shown = target.count
            stopPump()
            return
        }
        if shown > target.count { shown = target.count }
        guard shown < target.count else {
            stopPump()
            return
        }
        ensurePump()
    }

    private func ensurePump() {
        guard pumpTask == nil else { return }
        lastTick = Date()
        pumpTask = Task { @MainActor in
            while !Task.isCancelled, streaming, shown < target.count {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { break }
                let now = Date()
                let dt = min(0.05, max(1.0 / 120.0, now.timeIntervalSince(lastTick)))
                lastTick = now
                let behind = target.count - shown
                guard behind > 0 else { break }
                let share = 1 - exp(-dt / 0.1)
                let step = max(1, Int(ceil(Double(behind) * share)))
                shown = min(target.count, shown + step)
            }
            pumpTask = nil
        }
    }

    private func stopPump() {
        pumpTask?.cancel()
        pumpTask = nil
    }
}

/// 纯文本的同一套吐字节奏，用在思考正文上。与 Markdown 版不同，这里保存
/// 「当前显示的字符串」而不是长度：思考行在流式期间会滚动显示最新一段，
/// 文本可能从头部被截掉，这时整段重新显示比按长度切更稳。
struct PacedText: View {
    let text: String
    let streaming: Bool
    /// 只画最后一段（思考行流式期间），吐字节奏仍按整段推进。
    var tail: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: String
    /// 与 `StreamingMarkdownView` 同理：吐字任务读这份 `@State`，而不是捕获
    /// 时的 `text`，否则模型停顿时最后的字符会停在旧目标上。
    @State private var target: String
    @State private var pumpTask: Task<Void, Never>?
    @State private var lastTick = Date()

    init(text: String, streaming: Bool, tail: Bool = false) {
        self.text = text
        self.streaming = streaming
        self.tail = tail
        _shown = State(initialValue: text)
        _target = State(initialValue: text)
    }

    var body: some View {
        Text(tail ? Self.latest(shown) : shown)
            .onAppear { sync() }
            .onChange(of: text) { _, _ in sync() }
            .onChange(of: streaming) { _, _ in sync() }
            .onChange(of: reduceMotion) { _, _ in sync() }
            .onDisappear { stopPump() }
    }

    /// 长思考只排版最后 2000 个字符，从换行处切。
    private static func latest(_ text: String) -> String {
        guard text.count > 2000 else { return text }
        let start = text.index(text.endIndex, offsetBy: -2000)
        if let newline = text[start...].firstIndex(of: "\n") {
            return String(text[text.index(after: newline)...])
        }
        return String(text[start...])
    }

    private func sync() {
        target = text
        guard streaming, !reduceMotion else {
            shown = target
            stopPump()
            return
        }
        if !target.hasPrefix(shown) {
            // 全新的一段（而不是接在已显示内容后面）：直接整段显示。
            shown = target
            stopPump()
            return
        }
        guard shown.count < target.count else {
            stopPump()
            return
        }
        ensurePump()
    }

    private func ensurePump() {
        guard pumpTask == nil else { return }
        lastTick = Date()
        pumpTask = Task { @MainActor in
            while !Task.isCancelled, streaming, shown.count < target.count {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { break }
                let now = Date()
                let dt = min(0.05, max(1.0 / 120.0, now.timeIntervalSince(lastTick)))
                lastTick = now
                let behind = target.count - shown.count
                guard behind > 0 else { break }
                let share = 1 - exp(-dt / 0.1)
                let step = max(1, Int(ceil(Double(behind) * share)))
                shown = String(target.prefix(min(target.count, shown.count + step)))
            }
            pumpTask = nil
        }
    }

    private func stopPump() {
        pumpTask?.cancel()
        pumpTask = nil
    }
}

// MARK: - Segments & Block Views

private struct MarkdownListItem: Identifiable {
    let id = UUID()
    let marker: String
    let content: AttributedString
    let indent: Int
    let ordered: Bool
}

private enum MarkdownSegment {
    case text([MarkdownBlock])
    case list([MarkdownListItem])
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
            case .heading, .paragraph:
                textBuffer.append(block)
            case .bullet(let items):
                flushText()
                result.append(
                    .list(
                        items.map { item in
                            MarkdownListItem(
                                marker: item.indent.isMultiple(of: 2) ? "•" : "◦",
                                content: item.content,
                                indent: item.indent,
                                ordered: false)
                        }))
            case .ordered(let items):
                flushText()
                result.append(
                    .list(
                        items.map { item in
                            MarkdownListItem(
                                marker: "\(item.number).",
                                content: item.content,
                                indent: 0,
                                ordered: true)
                        }))
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

/// 列表：标记在一列里右对齐，内容在第二列左对齐；缩进项整体右移。
private struct MarkdownListView: View {
    let items: [MarkdownListItem]
    var style: MarkdownStyle = .standard

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(items) { item in
                GridRow(alignment: .firstTextBaseline) {
                    Text(item.marker)
                        .font(
                            item.ordered
                                ? DS.Font.proseNumber(style.bodySize)
                                : DS.Font.prose(style.bodySize)
                        )
                        .foregroundStyle(DS.text3)
                        .gridColumnAlignment(.trailing)
                        .padding(.leading, CGFloat(item.indent) * 16)

                    Text(item.content)
                        .lineSpacing(style.lineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        }
        .padding(.leading, 4)
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String
    var style: MarkdownStyle = .standard

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var hoveringCopy = false
    @State private var resetTask: Task<Void, Never>?

    private var displayLanguage: String {
        guard let language, !language.isEmpty else { return "code" }
        return language.lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(displayLanguage)
                    .font(DS.Font.mono(style.chat ? 11 : 11, weight: .medium))
                    .foregroundStyle(DS.text3)

                Spacer(minLength: 0)

                Button(action: copyCode) {
                    Group {
                        if style.chat {
                            // Splash 的代码块头只有一枚复制图标。
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: copied ? .semibold : .regular))
                                .frame(width: 22, height: 22)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 10, weight: copied ? .semibold : .regular))
                                Text(L10n.t(copied ? "已复制" : "复制"))
                                    .font(DS.Font.xs)
                            }
                        }
                    }
                    .foregroundStyle(copied ? DS.accent : (hoveringCopy ? DS.text : DS.text3))
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.horizontal, style.chat ? 3 : 6)
                    .padding(.vertical, 3)
                    .background(DS.rect(DS.Radius.sm).fill(hoveringCopy ? DS.hover : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plainHit)
                .onHover { hoveringCopy = $0 }
                .help(L10n.t(copied ? "已复制" : "复制代码"))
                .accessibilityLabel(L10n.t(copied ? "已复制" : "复制代码"))
                .animation(reduceMotion ? nil : DS.Motion.snappy, value: copied)
                .animation(reduceMotion ? nil : DS.Motion.snappy, value: hoveringCopy)
            }
            .padding(.leading, style.chat ? 14 : 12)
            .padding(.trailing, style.chat ? 8 : 12)
            .frame(height: style.chat ? 32 : 30)
            .background(style.chat ? Color.clear : DS.surface)

            Rectangle()
                .fill(DS.line)
                .frame(height: 1)

            HighlightedCode(code: code, language: language, style: style)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.rect(style.chat ? 10 : DS.Radius.md).fill(style.chat ? Color.clear : DS.bg))
        .overlay(
            DS.rect(style.chat ? 10 : DS.Radius.md)
                .strokeBorder(style.chat ? DS.line : DS.line2, lineWidth: 1)
        )
        .clipShape(DS.rect(style.chat ? 10 : DS.Radius.md))
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        resetTask?.cancel()
        withAnimation(reduceMotion ? nil : DS.Motion.snappy) { copied = true }
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : DS.Motion.snappy) { copied = false }
        }
    }
}

/// 带语言高亮与行号的代码正文。行号栏固定不横滚，代码列单独横滚；
/// 两列共用同一个行高，逐行渲染，长代码横向拖动时序号不会跟着跑掉。
private struct HighlightedCode: View {
    let code: String
    let language: String?
    var style: MarkdownStyle

    private var lines: [AttributedString] {
        CodeHighlighter.lines(code, language: language)
    }
    private var fontSize: CGFloat { style.chat ? 13 : 12 }
    private var lineHeight: CGFloat { (fontSize * 1.55).rounded() }
    private var verticalPadding: CGFloat { style.chat ? 10 : 8 }
    private var showsGutter: Bool { lines.count > 1 }
    private var gutterWidth: CGFloat {
        CGFloat(max(2, String(lines.count).count)) * 7 + 8
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if showsGutter {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(verbatim: "\(index + 1)")
                            .font(DS.Font.mono(fontSize - 1.5))
                            .foregroundStyle(DS.text4)
                            .frame(
                                width: gutterWidth, height: lineHeight,
                                alignment: .trailing)
                    }
                }
                .padding(.vertical, verticalPadding)
                .background(DS.bg.opacity(0.55))
                .accessibilityHidden(true)

                Rectangle()
                    .fill(DS.line)
                    .frame(width: 1)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index])
                            .font(DS.Font.mono(fontSize))
                            .foregroundStyle(DS.text)
                            .frame(height: lineHeight, alignment: .leading)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.horizontal, style.chat ? 12 : 10)
                .padding(.vertical, verticalPadding)
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuoteBlockView: View {
    let lines: [AttributedString]
    var style: MarkdownStyle = .standard

    private var composed: AttributedString {
        var out = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 {
                var br = AttributedString("\n")
                br.font = DS.Font.prose(style.bodySize)
                out += br
            }
            out += MarkdownComposer.inline(
                line,
                size: style.bodySize,
                color: DS.text2,
                emphasisWeight: style.chat ? .semibold : .medium)
        }
        return out
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(DS.text3.opacity(0.45))
                .frame(width: 2)

            Text(composed)
                .lineSpacing(style.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 2)
        .padding(.vertical, 2)
    }
}

private struct MarkdownTableView: View {
    let rows: [[String]]
    var style: MarkdownStyle = .standard

    private var columnCount: Int {
        rows.map(\.count).max() ?? 0
    }

    var body: some View {
        if !rows.isEmpty, columnCount > 0 {
            if style.chat {
                chatTable
            } else {
                cardTable
            }
        }
    }

    /// 对话正文：没有卡片底与描边，只有行间一条发丝线（Splash 的表格）。
    private var chatTable: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 0) {
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
                            Text(
                                MarkdownComposer.inlineTableCell(
                                    cell,
                                    isHeader: rowIndex == 0,
                                    size: style.bodySize)
                            )
                            .lineSpacing(style.lineSpacing)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, rowIndex == 0 ? 0 : 8)
                            .frame(maxWidth: 320, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.bottom, 1)
        }
    }

    /// 资料卡：保留原来的实色表头与圆角卡片，读者在模型详情里已经熟悉。
    private var cardTable: some View {
        ScrollView(.horizontal, showsIndicators: true) {
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
                            Text(
                                MarkdownComposer.inlineTableCell(
                                    cell,
                                    isHeader: rowIndex == 0,
                                    size: style.bodySize)
                            )
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(maxWidth: 320, alignment: .leading)
                        }
                    }
                    .background(
                        rowIndex == 0
                            ? DS.raised
                            : (rowIndex.isMultiple(of: 2) ? DS.bg.opacity(0.45) : Color.clear)
                    )
                }
            }
        }
        .background(DS.rect(DS.Radius.md).fill(DS.surface))
        .overlay(DS.rect(DS.Radius.md).strokeBorder(DS.line2, lineWidth: 1))
        .clipShape(DS.rect(DS.Radius.md))
    }
}

// MARK: - Composer

/// 把解析出的块合成一个 `AttributedString`，以单个 `Text` 渲染。
/// 行内样式（粗体、斜体、行内代码、链接）由 Foundation 的 Markdown
/// 解析器产出，这里只负责补上块级字体、颜色与块之间的间距。
private enum MarkdownComposer {
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
