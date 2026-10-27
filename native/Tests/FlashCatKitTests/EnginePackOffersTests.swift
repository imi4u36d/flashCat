import XCTest
@testable import FlashCatKit

/// The engine page has to keep offering a runtime pack after it is installed,
/// otherwise a broken pack can only be replaced by deleting it by hand first.
final class EnginePackOffersTests: XCTestCase {
    private func release(_ version: String) -> EnginePackRelease {
        EnginePackRelease(version: version,
                          url: "file:///tmp/engine-\(version).tar.gz",
                          sha256: "deadbeef",
                          bytes: 1,
                          minMacOS: "26.0",
                          notes: nil)
    }

    func testNothingInstalledOffersInstallForEveryRelease() {
        let offers = EnginePackOffers.offers(installed: [],
                                             releases: [release("0.8.0"), release("0.7.2")])
        XCTAssertEqual(offers.map(\.release.version), ["0.8.0", "0.7.2"])
        XCTAssertEqual(offers.map(\.action), [.install, .install])
        XCTAssertEqual(offers.map(\.action.label), ["安装", "安装"])
    }

    func testSameVersionIsOfferedAsReinstall() {
        let offers = EnginePackOffers.offers(installed: ["0.7.2"], releases: [release("0.7.2")])
        XCTAssertEqual(offers.count, 1)
        XCTAssertEqual(offers.first?.action, .reinstall)
        XCTAssertEqual(offers.first?.action.label, "重装")
    }

    func testNewerReleaseIsOfferedAsUpdateAndOlderIsDropped() {
        let offers = EnginePackOffers.offers(installed: ["0.7.2"],
                                            releases: [release("0.7.10"),
                                                       release("0.7.2"),
                                                       release("0.7.1")])
        XCTAssertEqual(offers.map(\.release.version), ["0.7.10", "0.7.2"])
        XCTAssertEqual(offers.map(\.action), [.update, .reinstall])
        XCTAssertEqual(offers.first?.action.label, "更新")
    }

    func testNewestInstalledDecidesEvenWhenOlderVersionsArePresent() {
        let offers = EnginePackOffers.offers(installed: ["0.7.1", "0.7.2"],
                                            releases: [release("0.7.2"), release("0.7.1")])
        XCTAssertEqual(offers.map(\.release.version), ["0.7.2"])
        XCTAssertEqual(offers.first?.action, .reinstall)
    }

    func testEmptyIndexOffersNothing() {
        XCTAssertTrue(EnginePackOffers.offers(installed: ["0.7.2"], releases: []).isEmpty)
        XCTAssertTrue(EnginePackOffers.offers(installed: [], releases: []).isEmpty)
    }

    func testMTPLXAndSplashDefaultsFromTheRepositoryIndex() throws {
        // Guards the shipped index shape: every engine the app knows has at least
        // one release, and each release carries the fields the installer needs.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FlashCatKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // native
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("pack-index.json")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("pack-index.json not present next to the checkout")
        }
        let index = try JSONDecoder().decode(EnginePackIndex.self, from: data)
        for id in EngineID.allCases {
            let releases = index.releases(for: id)
            XCTAssertFalse(releases.isEmpty, "\(id.rawValue) 没有发布条目")
            for release in releases {
                XCTAssertTrue(release.url.hasSuffix(".tar.gz"), "\(id.rawValue) 归档后缀异常")
                XCTAssertEqual(release.sha256.count, 64, "\(id.rawValue) sha256 长度异常")
            }
        }
    }
}
