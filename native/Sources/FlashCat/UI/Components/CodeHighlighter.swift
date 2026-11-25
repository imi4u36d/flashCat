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
    enum Language: Hashable {
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

    struct Document {
        let attributed: AttributedString
        let lineCount: Int
    }

    /// 把整段代码高亮并保留整块 `AttributedString`，供 `HighlightedCode` 一次渲染成单个 `Text`。
    static func document(
        _ code: String,
        language rawLanguage: String?,
        caching: Bool = true
    ) -> Document {
        let language = language(rawLanguage)
        let key = LineCacheKey(code: code, language: language)
        if !caching {
            lineCacheLock.lock()
            if let hit = streamingDocumentCache, hit.key == key {
                lineCacheLock.unlock()
                return hit.doc
            }
            lineCacheLock.unlock()

            let value = makeDocument(code, language: language)

            lineCacheLock.lock()
            streamingDocumentCache = (key, value)
            lineCacheLock.unlock()
            return value
        }

        if let cached = cachedDocument(for: key) { return cached }
        let value = makeDocument(code, language: language)
        storeDocument(value, for: key)
        return value
    }

    /// 预生成行号栏文本（`"1\n2\n..."`），避免为每一行单独创建 SwiftUI `Text` 视图。
    static func gutterText(lineCount: Int) -> String {
        let clamped = max(1, lineCount)
        if clamped <= 2000 {
            lineCacheLock.lock()
            if let cached = gutterCache[clamped] {
                lineCacheLock.unlock()
                return cached
            }
            lineCacheLock.unlock()
        }
        let text = (1...clamped).map(String.init).joined(separator: "\n")
        if clamped <= 2000 {
            lineCacheLock.lock()
            gutterCache[clamped] = text
            lineCacheLock.unlock()
        }
        return text
    }

    /// 把整段代码高亮后按 `\n` 切行，返回每一行的带属性文本。
    ///
    /// 结果按「代码 + 语言」缓存：`HighlightedCode` 的每一行都要取自己那份文本，
    /// 页面切换、悬停与流式追加都会让 body 反复求值。没有缓存时一个 180 行的
    /// 代码块一次布局要重跑上百遍全量正则，长对话切页会卡住好几秒。缓存命中
    /// 后重复求值只做一次字典查找，流式期间不断增长的新内容走 LRU 淘汰。
    static func lines(_ code: String, language rawLanguage: String?) -> [AttributedString] {
        let language = language(rawLanguage)
        let key = LineCacheKey(code: code, language: language)
        if let cached = cachedLines(for: key) { return cached }

        let value = makeLines(code, language: language)
        storeLines(value, for: key)
        return value
    }

    // MARK: Cache

    private struct LineCacheKey: Hashable {
        let code: String
        let language: Language
    }

    private static let lineCacheLock = NSLock()
    nonisolated(unsafe) private static var lineCache: [LineCacheKey: [AttributedString]] = [:]
    nonisolated(unsafe) private static var lineCacheOrder: [LineCacheKey] = []
    nonisolated(unsafe) private static var documentCache: [LineCacheKey: Document] = [:]
    nonisolated(unsafe) private static var documentCacheOrder: [LineCacheKey] = []
    nonisolated(unsafe) private static var streamingDocumentCache: (key: LineCacheKey, doc: Document)?
    nonisolated(unsafe) private static var gutterCache: [Int: String] = [:]
    /// 只留最近几段代码。长对话可能包含上百个历史代码块，提高上限避免切页或滚动时重复高亮。
    private static let lineCacheLimit = 128

    private static func cachedDocument(for key: LineCacheKey) -> Document? {
        lineCacheLock.lock()
        defer { lineCacheLock.unlock() }
        guard let hit = documentCache[key] else { return nil }
        if let index = documentCacheOrder.firstIndex(of: key) {
            documentCacheOrder.remove(at: index)
            documentCacheOrder.append(key)
        }
        return hit
    }

    private static func storeDocument(_ doc: Document, for key: LineCacheKey) {
        lineCacheLock.lock()
        defer { lineCacheLock.unlock() }
        guard documentCache[key] == nil else { return }
        documentCache[key] = doc
        documentCacheOrder.append(key)
        if documentCacheOrder.count > lineCacheLimit {
            let oldest = documentCacheOrder.removeFirst()
            documentCache.removeValue(forKey: oldest)
        }
    }

    private static func cachedLines(for key: LineCacheKey) -> [AttributedString]? {
        lineCacheLock.lock()
        defer { lineCacheLock.unlock() }
        guard let hit = lineCache[key] else { return nil }
        if let index = lineCacheOrder.firstIndex(of: key) {
            lineCacheOrder.remove(at: index)
            lineCacheOrder.append(key)
        }
        return hit
    }

    private static func storeLines(_ lines: [AttributedString], for key: LineCacheKey) {
        lineCacheLock.lock()
        defer { lineCacheLock.unlock() }
        guard lineCache[key] == nil else { return }
        lineCache[key] = lines
        lineCacheOrder.append(key)
        if lineCacheOrder.count > lineCacheLimit {
            let oldest = lineCacheOrder.removeFirst()
            lineCache.removeValue(forKey: oldest)
        }
    }

    private static func makeDocument(_ code: String, language: Language) -> Document {
        let lineCount = max(1, code.utf8.reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) })
        if code.isEmpty {
            return Document(attributed: AttributedString(" "), lineCount: 1)
        }
        var attributed = AttributedString(highlighted(code, language: language))
        // 结尾是换行符时补零宽空格，让 SwiftUI `Text` 把最后的空行也算进布局高度，与行号栏对齐。
        if code.hasSuffix("\n") {
            attributed.append(AttributedString("\u{200B}"))
        }
        return Document(attributed: attributed, lineCount: lineCount)
    }

    private static func makeLines(_ code: String, language: Language) -> [AttributedString] {
        let source = highlighted(code, language: language)
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
        highlighted(code, language: language(rawLanguage))
    }

    private static func highlighted(_ code: String, language: Language) -> NSAttributedString {
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
        guard !pattern.isEmpty, let expression = expression(for: pattern, options: options)
        else { return }
        for match in expression.matches(in: text.string, range: range) {
            text.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    // MARK: Regex cache

    private struct ExpressionKey: Hashable {
        let pattern: String
        let options: UInt
    }

    private static let expressionLock = NSLock()
    nonisolated(unsafe) private static var expressions: [ExpressionKey: NSRegularExpression] = [:]

    /// 规则是固定的十几条，编译一次就够。以前每次高亮都重新编译六七个正则，
    /// 流式吐字和切页时这部分开销会反复出现。
    private static func expression(
        for pattern: String,
        options: NSRegularExpression.Options
    ) -> NSRegularExpression? {
        let key = ExpressionKey(pattern: pattern, options: options.rawValue)
        expressionLock.lock()
        defer { expressionLock.unlock() }
        if let cached = expressions[key] { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options)
        else { return nil }
        expressions[key] = compiled
        return compiled
    }
}
