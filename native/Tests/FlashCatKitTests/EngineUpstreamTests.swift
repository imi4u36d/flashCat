// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest

@testable import FlashCatKit

final class EngineUpstreamTests: XCTestCase {
    private func release(
        _ version: String,
        prerelease: Bool = false,
        assets: [(String, String)] = []
    ) -> EngineUpstreamRelease {
        EngineUpstreamRelease(
            version: version,
            tag: prerelease ? "v\(version)" : "v\(version)",
            title: "v\(version)",
            publishedAt: nil,
            isPrerelease: prerelease,
            pageURL: URL(string: "https://github.com/jundot/omlx/releases/tag/v\(version)")!,
            assets: assets.compactMap { name, link in
                URL(string: link).map { EngineUpstreamRelease.Asset(name: name, url: $0, bytes: 1) }
            })
    }

    func testRepositoriesAndPages() {
        XCTAssertEqual(EngineUpstream.repository(for: .omlx), "jundot/omlx")
        XCTAssertEqual(EngineUpstream.repository(for: .mtplx), "youssofal/mtplx")
        XCTAssertEqual(EngineUpstream.repository(for: .splash), "incoai/splash")
        XCTAssertEqual(EngineUpstream.repository(for: .mlxServe), "ddalcu/mlx-serve")
        XCTAssertEqual(EngineUpstream.repository(for: .strata), "Niko1221/Strata")
        XCTAssertEqual(
            EngineUpstream.releasesPage(for: .splash).absoluteString,
            "https://github.com/incoai/splash/releases")
    }

    func testNormalizedVersionStripsTheVPrefix() {
        XCTAssertEqual(EngineUpstream.normalizedVersion("v1.4.1"), "1.4.1")
        XCTAssertEqual(EngineUpstream.normalizedVersion(" V2.12.2 "), "2.12.2")
        XCTAssertEqual(EngineUpstream.normalizedVersion("0.7.3.dev2"), "0.7.3.dev2")
    }

    func testLandingReleasePrefersTheNewestIncludingPrereleases() {
        let releases = [release("0.7.2"), release("0.7.3.dev1", prerelease: true), release("0.7.1")]
        XCTAssertEqual(EngineUpstream.landingRelease(releases)?.version, "0.7.3.dev1")
        XCTAssertNil(EngineUpstream.landingRelease([]))
    }

    func testAssetLookupByNameAndPrefix() {
        let subject = release(
            "1.4.1",
            assets: [
                ("splash-1.4.1-arm64-macos26.tar.gz", "https://example.com/splash-1.4.1-arm64-macos26.tar.gz"),
                (
                    "splash-1.4.1-arm64-macos26.tar.gz.sha256",
                    "https://example.com/splash-1.4.1-arm64-macos26.tar.gz.sha256"
                ),
            ])
        XCTAssertEqual(
            subject.asset(named: "splash-1.4.1-arm64-macos26.tar.gz")?.url.lastPathComponent,
            "splash-1.4.1-arm64-macos26.tar.gz")
        XCTAssertEqual(
            subject.asset(prefix: "splash-1.4.1-")?.url.lastPathComponent,
            "splash-1.4.1-arm64-macos26.tar.gz")
        XCTAssertNil(subject.asset(prefix: "splash-1.4.9-"))
    }

    func testComparisonReportsAnUpdateWhenUpstreamIsNewer() {
        let status = EngineUpstreamComparison.status(installed: ["1.4.0"], release: release("1.4.1"))
        guard case .update(let installed, let landing) = status else {
            return XCTFail("expected .update, got \(status)")
        }
        XCTAssertEqual(installed, "1.4.0")
        XCTAssertEqual(landing.version, "1.4.1")
    }

    func testComparisonUsesTheNewestInstalledVersion() {
        let status = EngineUpstreamComparison.status(installed: ["2.12.1", "2.12.2"], release: release("2.12.2"))
        XCTAssertEqual(status, .current(version: "2.12.2"))
    }

    func testComparisonStaysCurrentWhenLocalIsAhead() {
        // A locally built dev pack must not be reported as "update available".
        let status = EngineUpstreamComparison.status(installed: ["0.7.3.dev2"], release: release("0.7.2"))
        XCTAssertEqual(status, .current(version: "0.7.3.dev2"))
    }

    func testComparisonWithoutAnythingInstalledOffersTheRelease() {
        let status = EngineUpstreamComparison.status(installed: [], release: release("1.4.1"))
        XCTAssertEqual(status.newerRelease?.version, "1.4.1")
        XCTAssertNil(status.installedVersion)
    }

    // MARK: Atom fallback

    func testAtomFeedParsesTagsDatesAndPrereleaseMarkers() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <title>Release notes from omlx</title>
              <entry>
                <id>tag:github.com,2008:Repository/1157171418/v0.8.1</id>
                <updated>2026-11-21T01:17:02Z</updated>
                <link rel="alternate" type="text/html"
                      href="https://github.com/jundot/omlx/releases/tag/v0.8.1"/>
                <title>0.8.1</title>
              </entry>
              <entry>
                <id>tag:github.com,2008:Repository/1157171418/v0.8.0rc1</id>
                <updated>2026-11-12T16:06:56Z</updated>
                <link rel="alternate" type="text/html"
                      href="https://github.com/jundot/omlx/releases/tag/v0.8.0rc1"/>
                <title>0.8.0rc1</title>
              </entry>
            </feed>
            """
        let releases = EngineUpstreamChecker.parseAtomFeed(xml, repository: "jundot/omlx")
        XCTAssertEqual(releases.map(\.version), ["0.8.1", "0.8.0rc1"])
        XCTAssertEqual(releases.map(\.tag), ["v0.8.1", "v0.8.0rc1"])
        XCTAssertEqual(releases.map(\.isPrerelease), [false, true])
        XCTAssertEqual(
            releases.first?.pageURL.absoluteString,
            "https://github.com/jundot/omlx/releases/tag/v0.8.1")
        XCTAssertNotNil(releases.first?.publishedAt)
        // Stable wins even though the feed also contains an rc.
        let latest = releases.filter { !$0.isPrerelease }.max {
            EngineVersionOrder.isNewer($1.version, than: $0.version)
        }
        XCTAssertEqual(latest?.version, "0.8.1")
    }

    func testAtomFeedWithoutDashKeepsTheRealTag() {
        // Splash tags without a `v` prefix; the tag is needed verbatim for the
        // expanded-assets URL.
        let xml = """
            <feed><entry>
              <id>tag:github.com,2008:Repository/123/1.7.0</id>
              <link rel="alternate" href="https://github.com/incoai/splash/releases/tag/1.7.0"/>
              <title>Splash 1.7.0</title>
            </entry></feed>
            """
        let releases = EngineUpstreamChecker.parseAtomFeed(xml, repository: "incoai/splash")
        XCTAssertEqual(releases.first?.tag, "1.7.0")
        XCTAssertEqual(releases.first?.version, "1.7.0")
        XCTAssertEqual(releases.first?.title, "Splash 1.7.0")
    }

    func testAssetPageListsDownloadLinksWithoutTheAPI() {
        let html = """
            <ul>
              <li><a href="/incoai/splash/releases/download/1.7.0/splash-1.7.0-arm64-macos26.tar.gz">tarball</a>
                  <span>sha256:abc</span></li>
              <li><a href="/incoai/splash/releases/download/1.7.0/splash-1.7.0-arm64-macos26.tar.gz.sha256">checksum</a></li>
              <li><a href="/incoai/splash/releases/download/1.7.0/SHA256SUMS">sums</a></li>
            </ul>
            """
        let assets = EngineUpstreamChecker.parseAssetPage(html)
        XCTAssertEqual(
            assets.map(\.name),
            [
                "splash-1.7.0-arm64-macos26.tar.gz",
                "splash-1.7.0-arm64-macos26.tar.gz.sha256",
                "SHA256SUMS",
            ])
        XCTAssertEqual(
            assets.first?.url.absoluteString,
            "https://github.com/incoai/splash/releases/download/1.7.0/splash-1.7.0-arm64-macos26.tar.gz")
    }

    func testPrereleaseDetectionCoversInlineMarkers() {
        XCTAssertTrue(EngineUpstreamChecker.isPrereleaseVersion("0.8.0rc1"))
        XCTAssertTrue(EngineUpstreamChecker.isPrereleaseVersion("0.7.4.dev1"))
        XCTAssertTrue(EngineUpstreamChecker.isPrereleaseVersion("1.4.0-beta.2"))
        XCTAssertFalse(EngineUpstreamChecker.isPrereleaseVersion("0.8.0"))
        XCTAssertFalse(EngineUpstreamChecker.isPrereleaseVersion("2.12.3"))
    }

    func testComparisonOffersStableOverAnInstalledRC() {
        // oMLX 0.8.0rc1 → 0.8.0: the stable release must win.
        let status = EngineUpstreamComparison.status(
            installed: ["0.8.0rc1"],
            release: release("0.8.0"))
        guard case .update(let installed, let landing) = status else {
            return XCTFail("expected .update, got \(status)")
        }
        XCTAssertEqual(installed, "0.8.0rc1")
        XCTAssertEqual(landing.version, "0.8.0")
    }
}
