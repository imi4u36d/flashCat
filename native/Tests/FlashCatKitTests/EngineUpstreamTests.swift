import XCTest
@testable import FlashCatKit

final class EngineUpstreamTests: XCTestCase {
    private func release(_ version: String,
                         prerelease: Bool = false,
                         assets: [(String, String)] = []) -> EngineUpstreamRelease {
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
        XCTAssertEqual(EngineUpstream.releasesPage(for: .splash).absoluteString,
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
        let subject = release("1.4.1", assets: [
            ("splash-1.4.1-arm64-macos26.tar.gz", "https://example.com/splash-1.4.1-arm64-macos26.tar.gz"),
            ("splash-1.4.1-arm64-macos26.tar.gz.sha256", "https://example.com/splash-1.4.1-arm64-macos26.tar.gz.sha256"),
        ])
        XCTAssertEqual(subject.asset(named: "splash-1.4.1-arm64-macos26.tar.gz")?.url.lastPathComponent,
                       "splash-1.4.1-arm64-macos26.tar.gz")
        XCTAssertEqual(subject.asset(prefix: "splash-1.4.1-")?.url.lastPathComponent,
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
}
