// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import Foundation

/// 对话里代码块的轻量高亮。
///
/// 不引入语法分析器：按语言挑一组注释 / 字符串 / 关键字 / 数字 / 类型规则，
/// 在整段代码上跑一遍正则，再把带属性的文本按行切开交给行号栏对齐。
/// 规则是「后写的覆盖先写的」——先关键字与数字，再字符串，最后注释，
/// 所以字符串里的 `return` 不会被当成关键字、注释里的引号也不会开启字符串。
enum CodeHighlighter {
    enum Language {
        case swift, python, javascript, json, shell, sql, html, yaml, other
    }

    static func language(_ raw: String?) -> Language {
        let value = (raw ?? "").lowercased()
        switch value {
        case "swift": return .swift
        case "py", "python", "python3": return .python
        case "js", "javascript", "jsx", "ts", "typescript", "tsx":
            return .javascript
        case "json", "jsonc": return .json
        case "sh", "bash", "shell", "zsh", "console": return .shell
        case "sql", "sqlite": return .sql
        case "html", "xml", "svg": return .html
        case "yml", "yaml": return .yaml
        default: return .other
        }
    }

    /// 把整段代码高亮后按 `\n` 切行，返回每一行的带属性文本。
    static func lines(_ code: String, language rawLanguage: String?) -> [AttributedString] {
        let source = highlighted(code, language: rawLanguage)
        var result: [AttributedString] = []
        var offset = 0
        let ns = code as NSString
        for line in code.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let clamped = min(length, max(0, ns.length - offset))
            let sub = source.attributedSubstring(
                from: NSRange(location: min(offset, ns.length), length: clamped))
            result.append(AttributedString(sub))
            offset += length + 1
        }
        return result.isEmpty ? [AttributedString("")] : result
    }

    /// 整段代码的着色结果（测试直接看属性，渲染层再按行切开）。
    static func highlighted(_ code: String, language rawLanguage: String?) -> NSAttributedString {
        let language = language(rawLanguage)
        let source = NSMutableAttributedString(
            string: code,
            attributes: [.foregroundColor: NSColor(DS.text)])
        let full = NSRange(location: 0, length: source.length)

        applyKeywords(source, language: language, range: full)
        applyNumbers(source, range: full)
        applyStrings(source, range: full)
        applyComments(source, language: language, range: full)
        applyLanguageSpecific(source, language: language, range: full)
        return source
    }

    // MARK: Palette

    private enum Palette {
        static let keyword = NSColor.adaptive(dark: 0xC084FC, light: 0x7C3AED)
        static let string = NSColor.adaptive(dark: 0x6EE7B7, light: 0x1E8A3E)
        static let comment = NSColor.adaptive(dark: 0x8C8C8C, light: 0x6B7280)
        static let number = NSColor.adaptive(dark: 0xFBBF24, light: 0xB45309)
        static let type = NSColor.adaptive(dark: 0x7DD3FC, light: 0x0369A1)
        static let key = NSColor.adaptive(dark: 0x93C5FD, light: 0x1D4ED8)
    }

    // MARK: Rules

    private static func applyKeywords(
        _ text: NSMutableAttributedString, language: Language, range: NSRange
    ) {
        let words: [String]
        switch language {
        case .swift:
            words = [
                "func", "let", "var", "if", "else", "guard", "return", "for", "in",
                "while", "switch", "case", "default", "struct", "class", "enum",
                "protocol", "extension", "import", "init", "deinit", "self", "Self",
                "nil", "true", "false", "try", "catch", "throw", "throws", "async",
                "await", "actor", "some", "any", "private", "public", "internal",
                "fileprivate", "static", "mutating", "override", "final", "lazy",
                "weak", "unowned", "defer", "where", "as", "is", "repeat", "break",
                "continue", "fallthrough", "associatedtype", "typealias", "subscript",
            ]
        case .python:
            words = [
                "def", "class", "import", "from", "as", "if", "elif", "else", "for",
                "in", "while", "return", "yield", "try", "except", "finally", "with",
                "lambda", "pass", "break", "continue", "None", "True", "False", "and",
                "or", "not", "is", "async", "await", "self", "raise", "global",
                "nonlocal", "del", "assert", "match", "case",
            ]
        case .javascript:
            words = [
                "function", "const", "let", "var", "if", "else", "for", "while",
                "return", "class", "extends", "import", "export", "from", "default",
                "async", "await", "try", "catch", "finally", "throw", "new", "this",
                "typeof", "instanceof", "interface", "type", "enum", "implements",
                "public", "private", "protected", "static", "readonly", "null",
                "undefined", "true", "false", "switch", "case", "break", "continue",
            ]
        case .shell:
            words = [
                "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while",
                "case", "esac", "function", "return", "export", "local", "echo", "cd",
                "set", "unset", "readonly", "source", "alias", "shift", "exit",
            ]
        case .sql:
            words = [
                "SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER",
                "ON", "GROUP", "BY", "ORDER", "LIMIT", "OFFSET", "INSERT", "INTO",
                "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "ALTER",
                "DROP", "AND", "OR", "NOT", "NULL", "AS", "DISTINCT", "HAVING",
                "UNION", "ALL", "WITH", "CASE", "WHEN", "THEN", "ELSE", "END",
            ]
        case .json, .html, .yaml, .other:
            words = []
        }
        guard !words.isEmpty else { return }
        let pattern =
            "\\b("
            + words.map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|") + ")\\b"
        let options: NSRegularExpression.Options =
            language == .sql ? [.caseInsensitive] : []
        apply(pattern, to: text, range: range, color: Palette.keyword, options: options)
    }

    private static func applyNumbers(_ text: NSMutableAttributedString, range: NSRange) {
        apply(
            #"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#,
            to: text, range: range, color: Palette.number)
    }

    private static func applyStrings(_ text: NSMutableAttributedString, range: NSRange) {
        // 单双引号与反引号；允许转义。整段代码上跑，跨行字符串也能一次覆盖。
        apply(
            #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`"#,
            to: text, range: range, color: Palette.string,
            options: [.dotMatchesLineSeparators])
    }

    private static func applyComments(
        _ text: NSMutableAttributedString, language: Language, range: NSRange
    ) {
        switch language {
        case .python, .shell, .yaml:
            apply(
                #"#.*$"#, to: text, range: range, color: Palette.comment,
                options: [.anchorsMatchLines])
        case .sql:
            apply(
                #"--.*$"#, to: text, range: range, color: Palette.comment,
                options: [.anchorsMatchLines])
        case .html:
            apply(#"<!--[\s\S]*?-->"#, to: text, range: range, color: Palette.comment)
        case .swift, .javascript:
            apply(
                #"//.*$"#, to: text, range: range, color: Palette.comment,
                options: [.anchorsMatchLines])
            apply(#"/\*[\s\S]*?\*/"#, to: text, range: range, color: Palette.comment)
        case .json, .other:
            break
        }
    }

    private static func applyLanguageSpecific(
        _ text: NSMutableAttributedString, language: Language, range: NSRange
    ) {
        switch language {
        case .json:
            // 键名（引号后紧跟冒号）与字符串值区分开。
            apply(
                #""(?:[^"\\]|\\.)*"(?=\s*:)"#, to: text, range: range,
                color: Palette.key, options: [.dotMatchesLineSeparators])
        case .yaml:
            apply(
                #"^\s*[\w.-]+(?=\s*:)"#, to: text, range: range,
                color: Palette.key, options: [.anchorsMatchLines])
        case .html:
            apply(#"</?[\w:-]+"#, to: text, range: range, color: Palette.key)
            apply(#"/?>"#, to: text, range: range, color: Palette.key)
        case .swift, .javascript, .python, .shell, .sql, .other:
            // 首字母大写当作类型；关键字与字符串的颜色已经先写，不会被覆盖。
            apply(
                #"\b[A-Z][A-Za-z0-9_]*\b"#, to: text, range: range,
                color: Palette.type)
        }
    }

    private static func apply(
        _ pattern: String,
        to text: NSMutableAttributedString,
        range: NSRange,
        color: NSColor,
        options: NSRegularExpression.Options = []
    ) {
        guard !pattern.isEmpty,
            let expression = try? NSRegularExpression(pattern: pattern, options: options)
        else { return }
        for match in expression.matches(in: text.string, range: range) {
            text.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
