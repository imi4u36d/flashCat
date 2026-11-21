// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

// MARK: - Upstream releases

/// One GitHub release of an engine upstream. The app only needs enough of the
/// payload to say "here is a newer version" and to hand the build script a
/// download URL, so the fields stay deliberately small.
public struct EngineUpstreamRelease: Sendable, Equatable {
    public struct Asset: Sendable, Equatable {
        public let name: String
        public let url: URL
        public let bytes: Int?

        public init(name: String, url: URL, bytes: Int? = nil) {
            self.name = name
            self.url = url
            self.bytes = bytes
        }
    }

    /// Tag without the leading `v` (`v1.4.1` → `1.4.1`), so it compares with the
    /// versions in the pack manifest.
    public let version: String
    public let tag: String
    public let title: String?
    public let publishedAt: Date?
    public let isPrerelease: Bool
    public let pageURL: URL
    public let assets: [Asset]

    public init(
        version: String,
        tag: String,
        title: String? = nil,
        publishedAt: Date? = nil,
        isPrerelease: Bool = false,
        pageURL: URL,
        assets: [Asset] = []
    ) {
        self.version = version
        self.tag = tag
        self.title = title
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
        self.pageURL = pageURL
        self.assets = assets
    }

    public func asset(named name: String) -> Asset? {
        assets.first { $0.name == name }
    }

    /// Suite-suffixed archive names carry the platform, so the lookup cannot be
    /// an exact match: `splash-1.4.1-arm64-macos26.tar.gz`.
    public func asset(prefix: String) -> Asset? {
        assets.first { $0.name.hasPrefix(prefix) }
    }

    /// Same release with a freshly discovered asset list. Used when the version
    /// came from the Atom feed, which carries no asset metadata.
    public func replacingAssets(_ assets: [Asset]) -> EngineUpstreamRelease {
        EngineUpstreamRelease(
            version: version,
            tag: tag,
            title: title,
            publishedAt: publishedAt,
            isPrerelease: isPrerelease,
            pageURL: pageURL,
            assets: assets)
    }
}

/// Where each engine comes from. Recorded here instead of derived from the pack
/// so the check keeps working when a pack is missing or half-installed.
public enum EngineUpstream {
    public static func repository(for id: EngineID) -> String {
        id.descriptor.upstreamRepository ?? id.rawValue
    }

    public static func releasesPage(for id: EngineID) -> URL {
        ConstantURL.make("https://github.com/\(repository(for: id))/releases")
    }

    /// Release tags are `v1.4.1` for two of the three engines and `1.4.1` for the
    /// third, so the prefix is stripped rather than assumed.
    public static func normalizedVersion(_ tag: String) -> String {
        var version = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        // 版本号会拼进 shell 命令、文件名和下载 URL：只留安全字符。GitHub 的
        // tag 是远端可控输入，`1.2'; rm -rf ~` 这种必须在拼命令之前就拆掉。
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-")
        version = String(String.UnicodeScalarView(version.unicodeScalars.filter(allowed.contains)))
        return version
    }

    public static func landingRelease(_ releases: [EngineUpstreamRelease]) -> EngineUpstreamRelease? {
        // Newest by the same numeric-aware order the install UI uses, so a
        // `0.7.3.dev2` sorts above `0.7.2` and `1.4.10` above `1.4.9`.
        releases.max { EngineVersionOrder.isNewer($1.version, than: $0.version) }
    }
}

public enum EngineUpstreamError: Error, LocalizedError, Equatable {
    case http(Int)
    case decoding
    case empty

    public var errorDescription: String? {
        switch self {
        case .http(let status): return "GitHub 返回 HTTP \(status)（未登录的接口限额是每小时 60 次）"
        case .decoding: return "无法解析 GitHub 的发布信息"
        case .empty: return "上游仓库没有发布记录"
        }
    }
}

/// Talks to the GitHub REST API. Unauthenticated, so callers cache the result
/// instead of polling: the API allows 60 requests per hour per address.
public actor EngineUpstreamChecker {
    private let session: URLSession
    private let apiBase: URL
    private let webBase: URL

    public init(
        session: URLSession = .shared,
        apiBase: URL = ConstantURL.make("https://api.github.com"),
        webBase: URL = ConstantURL.make("https://github.com")
    ) {
        self.session = session
        self.apiBase = apiBase
        self.webBase = webBase
    }

    /// Newest *stable* release only — pre-releases (rc/dev tags) are ignored so
    /// the engine page never nudges the reader toward an unfinished build. When
    /// a repository has published no stable release at all, the newest
    /// pre-release is used as a fallback so the engine is not left with nothing
    /// to offer. Falls back to `/tags` for repositories that tag without
    /// cutting releases.
    public func latest(for id: EngineID) async throws -> EngineUpstreamRelease {
        // github.com 的 Atom feed 不占 API 配额，优先用它。api.github.com 的
        // 未登录限额是每小时 60 次，而且按出口 IP 计算：走公共代理时这份额度
        // 属于整台代理上的所有人，经常很早就用光。旧实现把 403 静默映射成
        // `.unavailable`，引擎卡因此看起来永远「已是最新」。
        do {
            if let release = try await atomLatest(for: id) { return release }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            // Atom 也可能是被墙/超时；退回 REST API 再试一次。
        }
        do {
            let releases = try await self.releases(for: id)
            if let landing = Self.landing(in: releases) { return landing }
            throw EngineUpstreamError.empty
        } catch EngineUpstreamError.empty {
            return try await tagFallback(for: id)
        }
    }

    /// Fills in the asset list for a release discovered through the Atom feed.
    /// The public release page (`expanded_assets`) is HTML, not the rate-limited
    /// API, and lists the same download links the API reports. Hydration is
    /// lazy: checks only need the tag, installs need the downloads.
    public func hydrate(_ release: EngineUpstreamRelease, for id: EngineID) async -> EngineUpstreamRelease {
        guard release.assets.isEmpty else { return release }
        let repository = EngineUpstream.repository(for: id)
        let url = webBase.appendingPathComponent(
            "\(repository)/releases/expanded_assets/\(release.tag)")
        guard let html = try? await getText(url) else { return release }
        let assets = Self.parseAssetPage(html)
        return assets.isEmpty ? release : release.replacingAssets(assets)
    }

    private static func landing(in releases: [EngineUpstreamRelease]) -> EngineUpstreamRelease? {
        if let stable = EngineUpstream.landingRelease(releases.filter { !$0.isPrerelease }) {
            return stable
        }
        return EngineUpstream.landingRelease(releases)
    }

    /// Latest releases via `github.com/<repo>/releases.atom`. Atom exposes the
    /// newest ten releases with their tags, titles and dates — enough to answer
    /// "is there something newer" without touching the REST API.
    private func atomLatest(for id: EngineID) async throws -> EngineUpstreamRelease? {
        let repository = EngineUpstream.repository(for: id)
        let url = webBase.appendingPathComponent("\(repository)/releases.atom")
        let xml = try await getText(url)
        let releases = Self.parseAtomFeed(xml, repository: repository)
        return Self.landing(in: releases)
    }

    private func releases(for id: EngineID) async throws -> [EngineUpstreamRelease] {
        let url = apiBase.appendingPathComponent("repos/\(EngineUpstream.repository(for: id))/releases")
        let data = try await get(url)
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw EngineUpstreamError.decoding
        }
        return raw.compactMap { entry in
            guard (entry["draft"] as? Bool) != true,
                let tag = entry["tag_name"] as? String
            else { return nil }
            let version = EngineUpstream.normalizedVersion(tag)
            let html = (entry["html_url"] as? String) ?? EngineUpstream.releasesPage(for: id).absoluteString
            guard let page = URL(string: html) else { return nil }
            let assets = (entry["assets"] as? [[String: Any]]) ?? []
            return EngineUpstreamRelease(
                version: version,
                tag: tag,
                title: (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                publishedAt: (entry["published_at"] as? String).flatMap(Self.date(from:)),
                // GitHub 的 prerelease 标记并不可靠：oMLX 把 `0.8.0rc1`
                // 也按正式 release 发布。版本号本身才是判断依据。
                isPrerelease: ((entry["prerelease"] as? Bool) ?? false)
                    || Self.isPrereleaseVersion(version),
                pageURL: page,
                assets: assets.compactMap { asset in
                    guard let name = asset["name"] as? String,
                        let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
                    else {
                        return nil
                    }
                    return EngineUpstreamRelease.Asset(
                        name: name,
                        url: link,
                        bytes: asset["size"] as? Int)
                })
        }
    }

    private func tagFallback(for id: EngineID) async throws -> EngineUpstreamRelease {
        let url = apiBase.appendingPathComponent("repos/\(EngineUpstream.repository(for: id))/tags")
        let data = try await get(url)
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let tag = raw.compactMap({ $0["name"] as? String }).first
        else {
            throw EngineUpstreamError.empty
        }
        return EngineUpstreamRelease(
            version: EngineUpstream.normalizedVersion(tag),
            tag: tag,
            pageURL: EngineUpstream.releasesPage(for: id))
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("flashCat", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw EngineUpstreamError.http(http.statusCode)
        }
        return data
    }

    /// Plain `github.com` request (Atom feed / release asset page). These
    /// endpoints are HTML/XML rather than the REST API and carry no 60/h quota.
    private func getText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("flashCat", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw EngineUpstreamError.http(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw EngineUpstreamError.decoding
        }
        return text
    }

    // MARK: Feed parsing

    /// Parses a GitHub releases Atom feed. Each entry carries the tag in its
    /// `Repository/<id>/<tag>` id and an alternate link to the release page.
    /// Asset metadata is absent — `hydrate` fills it in when something is
    /// actually installed.
    static func parseAtomFeed(_ xml: String, repository: String) -> [EngineUpstreamRelease] {
        matches("<entry>(.*?)</entry>", in: xml).compactMap { groups in
            let entry = groups[1]
            let href = matches("<link[^>]*rel=\"alternate\"[^>]*href=\"([^\"]+)\"", in: entry)
                .first.map { $0[1].decodedHTMLEntities }
            let idTag = matches("<id>[^<]*Repository/\\d+/([^<]+)</id>", in: entry)
                .first.map { $0[1].decodedHTMLEntities }
            let rawTag = href.flatMap { URL(string: $0)?.lastPathComponent } ?? idTag
            guard let rawTag, !rawTag.isEmpty else { return nil }
            let tag = rawTag.removingPercentEncoding ?? rawTag
            let version = EngineUpstream.normalizedVersion(tag)
            guard !version.isEmpty else { return nil }
            let title = matches("<title>(.*?)</title>", in: entry)
                .first.map { $0[1].decodedHTMLEntities }
            let page = href.flatMap(URL.init(string:))
                ?? ConstantURL.make("https://github.com/\(repository)/releases")
            return EngineUpstreamRelease(
                version: version,
                tag: tag,
                title: title?.isEmpty == false ? title : nil,
                publishedAt: matches("<updated>([^<]+)</updated>", in: entry)
                    .first.flatMap { Self.date(from: $0[1]) },
                isPrerelease: isPrereleaseVersion(version),
                pageURL: page)
        }
    }

    /// Pulls the download links out of `releases/expanded_assets/<tag>`. The
    /// fragment lists the same files the REST API's `assets` array does, just
    /// without sizes.
    static func parseAssetPage(_ html: String) -> [EngineUpstreamRelease.Asset] {
        var seen = Set<String>()
        var assets: [EngineUpstreamRelease.Asset] = []
        for groups in matches("<a[^>]*href=\"([^\"]*/releases/download/[^\"]+)\"", in: html) {
            let href = groups[1].decodedHTMLEntities
            let absolute = href.hasPrefix("http") ? href : "https://github.com\(href)"
            guard let url = URL(string: absolute) else { continue }
            let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            assets.append(EngineUpstreamRelease.Asset(name: name, url: url))
        }
        return assets
    }

    /// oMLX publishes `0.8.0rc1` / `0.7.4.dev1` as ordinary GitHub releases,
    /// so the `prerelease` flag cannot be trusted. The version text is the
    /// authority: a semver `-suffix` or an inline alpha/beta/rc/dev marker.
    static func isPrereleaseVersion(_ version: String) -> Bool {
        let lower = version.lowercased()
        if lower.contains("-") { return true }
        for marker in ["alpha", "beta", "rc", "preview", "nightly", "canary", "dev"]
        where lower.contains(marker) {
            return true
        }
        return false
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard
            let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.dotMatchesLineSeparators, .caseInsensitive])
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let found = Range(match.range(at: index), in: text) else { return "" }
                return String(text[found])
            }
        }
    }

    /// A shared `ISO8601DateFormatter` would be non-Sendable global mutable
    /// state. Release lists decode a handful of dates, so a local instance is
    /// both safe and cheap.
    private static func date(from raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        // GitHub's REST payloads and Atom feeds usually omit the fraction.
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

private extension String {
    /// Minimal entity decoder for titles and hrefs; feeds escape `&`, `<` and
    /// quotes. `&amp;` is decoded last so `&amp;lt;` does not become `<`.
    var decodedHTMLEntities: String {
        var result = self
        for (entity, value) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Comparison

public enum EngineUpstreamStatus: Sendable, Equatable {
    /// Installed version is the newest upstream one.
    case current(version: String)
    /// Upstream has something newer than anything installed.
    case update(installed: String?, release: EngineUpstreamRelease)
    /// The check could not run (offline, rate limit, no release).
    case unavailable(String)

    public var newerRelease: EngineUpstreamRelease? {
        if case .update(_, let release) = self { return release }
        return nil
    }

    public var installedVersion: String? {
        if case .update(let installed, _) = self { return installed }
        return nil
    }
}

public enum EngineUpstreamComparison {
    public static func status(
        installed: [String],
        release: EngineUpstreamRelease
    ) -> EngineUpstreamStatus {
        let newest = installed.max { EngineVersionOrder.isNewer($1, than: $0) }
        guard let newest else {
            return .update(installed: nil, release: release)
        }
        if EngineVersionOrder.isNewer(release.version, than: newest) {
            return .update(installed: newest, release: release)
        }
        return .current(version: newest)
    }
}
