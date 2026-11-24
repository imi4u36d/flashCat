// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation

/// flashCat 自身的更新检查：读 GitHub 的 releases.atom，不占 REST API 配额。
/// 引擎更新走 `EngineUpstream` 的同一套思路；这里只保留「最新正式版」一件事。
package enum AppUpdateChecker {
    package static let feedURL = ConstantURL.make("https://github.com/imi4u36d/flashCat/releases.atom")

    package struct Release: Equatable {
        package let version: String
        package let title: String
        package let url: URL
        package let publishedAt: Date?

        package init(version: String, title: String, url: URL, publishedAt: Date?) {
            self.version = version
            self.title = title
            self.url = url
            self.publishedAt = publishedAt
        }
    }

    /// 返回比 `current` 新的最新正式版；没有更新时返回 nil。
    package static func check(current: String) async throws -> Release? {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 20
        request.setValue("flashCat-update-check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let xml = String(data: data, encoding: .utf8)
        else {
            throw URLError(.badServerResponse)
        }
        let releases = parse(xml)
        return
            releases
            .filter { isNewer($0.version, than: current) }
            .max { lhs, rhs in isNewer(rhs.version, than: lhs.version) }
    }

    /// Atom 里每条的标题是 release 名，链接末段是 tag（如 `v1.6.1`）。
    package static func parse(_ xml: String) -> [Release] {
        let entryPattern = #"<entry>([\s\S]*?)</entry>"#
        guard let entryRegex = try? NSRegularExpression(pattern: entryPattern) else {
            return []
        }
        let ns = xml as NSString
        var releases: [Release] = []
        for match in entryRegex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let block = ns.substring(with: match.range(at: 1))
            guard
                let link = firstGroup(#"<link[^>]*href="([^"]+)""#, in: block),
                let url = URL(string: link),
                let tag = url.pathComponents.last
            else { continue }
            let version = normalized(tag)
            guard !version.isEmpty, !isPrerelease(version) else { continue }
            let title = firstGroup(#"<title[^>]*>([\s\S]*?)</title>"#, in: block) ?? version
            let dateText = firstGroup(#"<updated>([\s\S]*?)</updated>"#, in: block)
            releases.append(
                Release(
                    version: version,
                    title: decodeEntities(title),
                    url: url,
                    publishedAt: dateText.flatMap { ISO8601DateFormatter().date(from: $0) }))
        }
        return releases
    }

    package static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numbers(in: candidate)
        let b = numbers(in: current)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: helpers

    package static func normalized(_ tag: String) -> String {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        return value
    }

    private static func isPrerelease(_ version: String) -> Bool {
        let lower = version.lowercased()
        return lower.contains("rc") || lower.contains("beta") || lower.contains("alpha")
            || lower.contains("dev") || lower.contains("preview")
    }

    private static func numbers(in version: String) -> [Int] {
        normalized(version)
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, range: range),
            let found = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[found])
    }

    private static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
