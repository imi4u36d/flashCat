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

    public init(version: String,
                tag: String,
                title: String? = nil,
                publishedAt: Date? = nil,
                isPrerelease: Bool = false,
                pageURL: URL,
                assets: [Asset] = []) {
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
}

/// Where each engine comes from. Recorded here instead of derived from the pack
/// so the check keeps working when a pack is missing or half-installed.
public enum EngineUpstream {
    public static func repository(for id: EngineID) -> String {
        switch id {
        case .omlx: return "jundot/omlx"
        case .mtplx: return "youssofal/mtplx"
        case .splash: return "incoai/splash"
        }
    }

    public static func releasesPage(for id: EngineID) -> URL {
        URL(string: "https://github.com/\(repository(for: id))/releases")!
    }

    /// Release tags are `v1.4.1` for two of the three engines and `1.4.1` for the
    /// third, so the prefix is stripped rather than assumed.
    public static func normalizedVersion(_ tag: String) -> String {
        var version = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
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

    public init(session: URLSession = .shared,
                apiBase: URL = URL(string: "https://api.github.com")!) {
        self.session = session
        self.apiBase = apiBase
    }

    /// Newest release, pre-releases included (the user asked for dev/rc tags to
    /// be visible), falling back to `/tags` for repositories that tag without
    /// cutting releases.
    public func latest(for id: EngineID) async throws -> EngineUpstreamRelease {
        do {
            let releases = try await self.releases(for: id)
            if let landing = EngineUpstream.landingRelease(releases) { return landing }
            throw EngineUpstreamError.empty
        } catch EngineUpstreamError.empty {
            return try await tagFallback(for: id)
        }
    }

    private func releases(for id: EngineID) async throws -> [EngineUpstreamRelease] {
        let url = apiBase.appendingPathComponent("repos/\(EngineUpstream.repository(for: id))/releases")
        let data = try await get(url)
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw EngineUpstreamError.decoding
        }
        return raw.compactMap { entry in
            guard (entry["draft"] as? Bool) != true,
                  let tag = entry["tag_name"] as? String else { return nil }
            let html = (entry["html_url"] as? String) ?? EngineUpstream.releasesPage(for: id).absoluteString
            guard let page = URL(string: html) else { return nil }
            let assets = (entry["assets"] as? [[String: Any]]) ?? []
            return EngineUpstreamRelease(
                version: EngineUpstream.normalizedVersion(tag),
                tag: tag,
                title: (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                publishedAt: (entry["published_at"] as? String).flatMap(Self.dateFormatter.date(from:)),
                isPrerelease: (entry["prerelease"] as? Bool) ?? false,
                pageURL: page,
                assets: assets.compactMap { asset in
                    guard let name = asset["name"] as? String,
                          let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else {
                        return nil
                    }
                    return EngineUpstreamRelease.Asset(name: name,
                                                       url: link,
                                                       bytes: asset["size"] as? Int)
                })
        }
    }

    private func tagFallback(for id: EngineID) async throws -> EngineUpstreamRelease {
        let url = apiBase.appendingPathComponent("repos/\(EngineUpstream.repository(for: id))/tags")
        let data = try await get(url)
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let tag = raw.compactMap({ $0["name"] as? String }).first else {
            throw EngineUpstreamError.empty
        }
        return EngineUpstreamRelease(version: EngineUpstream.normalizedVersion(tag),
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

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
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
    public static func status(installed: [String],
                              release: EngineUpstreamRelease) -> EngineUpstreamStatus {
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
