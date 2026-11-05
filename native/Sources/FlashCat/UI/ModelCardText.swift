import Foundation

/// 把 Hugging Face 的 README 模型卡洗成能直接渲染的 Markdown。
///
/// README 里混着大量 HTML：`<div align="center">`、shields.io 徽章、`<img>`。
/// `MarkdownView` 只认 Markdown 语法，这些标签会原样显示成一堆尖括号，
/// 所以先在入口处把 HTML 折叠成链接/文字，再交给 Markdown 渲染。
enum ModelCardText {
    static func normalized(_ raw: String) -> String {
        var text = stripFrontMatter(raw)
        text = linkedBadges(text)
        text = standaloneImages(text)
        text = text.replacingOccurrences(of: "<br\\b[^>]*>", with: "\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<p\\b[^>]*>", with: "\n\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</p>", with: "\n\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<(a|div|center|blockquote)\\b[^>]*>", with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</(a|div|center|blockquote)>", with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = decodeEntities(text)
        text = joinBadgeLines(text)
        return tidyLines(text)
    }

    private static func stripFrontMatter(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else { return text }
        return lines[(end + 1)...].joined(separator: "\n")
    }

    /// `<a href="…"><img alt="…"></a>` 是 shields.io 徽章，折成普通链接，
    /// 别让一张图撑成三行尖括号。
    private static func linkedBadges(_ text: String) -> String {
        replace(text,
                pattern: "<a\\b[^>]*href\\s*=\\s*\"([^\"]*)\"[^>]*>\\s*<img\\b[^>]*alt\\s*=\\s*\"([^\"]*)\"[^>]*>\\s*</a>",
                template: "[$2]($1)")
    }

    private static func standaloneImages(_ text: String) -> String {
        replace(text, pattern: "<img\\b[^>]*alt\\s*=\\s*\"([^\"]*)\"[^>]*>", template: "$1")
    }

    private static func replace(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
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
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if lines.last?.isEmpty == false { lines.append("") }
            } else {
                lines.append(trimmed)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
                      let valueRange = Range(match.range(at: 2), in: text) else { continue }
                decoded += text[cursor..<full.lowerBound]
                let radix = text[radixRange].isEmpty ? 10 : 16
                if let value = Int(text[valueRange], radix: radix),
                   let scalar = Unicode.Scalar(value) {
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
