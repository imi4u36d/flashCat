import SwiftUI
import Foundation

/// 对话正文的 Markdown 渲染：标题、段落、围栏代码、引用、列表、表格与分隔线。
///
/// 解析是刻意保守的：只认行首语法，inline 用 Foundation 的 Markdown 解析器，
/// 不认识的结构按段落原样显示。流式期间每次增量重解析，长回答的代价与文本长度
/// 成正比，但一次只有一条消息在长。
struct MarkdownView: View {
    let text: String

    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level, let content):
            Text(content)
                .font(.system(size: headingSize(level), weight: .bold))
                .foregroundStyle(Native.label)
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let content):
            Text(content)
                .font(.system(size: 13))
                .foregroundStyle(Native.label)
                .lineSpacing(3)
                .textSelection(.enabled)

        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(language?.isEmpty == false ? language! : "code")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Native.tertiary)
                    Spacer(minLength: 4)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9.5))
                    }
                    .buttonStyle(.plainHit)
                    .foregroundStyle(Native.tertiary)
                    .help("复制代码")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Hairline()
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Native.label)
                        .textSelection(.enabled)
                        .padding(10)
                }
            }
            .background { GlassSurface(radius: Native.radiusTile) }

        case .quote(let lines):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Native.accent.opacity(0.5))
                    .frame(width: 2.5)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Native.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 2)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(Native.accent.opacity(0.7))
                            .frame(width: 4, height: 4)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                        Text(item)
                            .font(.system(size: 13))
                            .foregroundStyle(Native.label)
                            .textSelection(.enabled)
                    }
                }
            }

        case .ordered(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(verbatim: "\(item.number).")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Native.tertiary)
                            .frame(width: 20, alignment: .trailing)
                        Text(item.content)
                            .font(.system(size: 13))
                            .foregroundStyle(Native.label)
                            .textSelection(.enabled)
                    }
                }
            }

        case .table(let rows):
            MarkdownTable(rows: rows)

        case .rule:
            Hairline().padding(.vertical, 4)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 20
        case 2: return 17
        case 3: return 15
        default: return 13.5
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

    static func parse(_ source: String) -> [MarkdownBlock] {
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

// MARK: - Table

private struct MarkdownTable: View {
    let rows: [[String]]

    var body: some View {
        let width = rows.map(\.count).max() ?? 0
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<width, id: \.self) { column in
                        Text(column < row.count ? row[column] : "")
                            .font(.system(size: 11, weight: index == 0 ? .semibold : .regular))
                            .foregroundStyle(index == 0 ? Native.label : Native.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                    }
                }
                .background(index == 0 ? Native.overlay(0.05) : Color.clear)
                if index != rows.count - 1 { Hairline() }
            }
        }
        .background { GlassSurface(radius: Native.radiusTile) }
        .clipShape(RoundedRectangle(cornerRadius: Native.radiusTile, style: .continuous))
    }
}
