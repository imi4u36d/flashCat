// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest

@testable import FlashCat

final class AppUpdateCheckerTests: XCTestCase {
    private let sample = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <title>flashCat 1.6.1</title>
            <updated>2026-11-20T10:00:00Z</updated>
            <link rel="alternate" href="https://github.com/imi4u36d/flashCat/releases/tag/v1.6.1"/>
          </entry>
          <entry>
            <title>flashCat 1.6.2-rc1</title>
            <updated>2026-11-21T10:00:00Z</updated>
            <link rel="alternate" href="https://github.com/imi4u36d/flashCat/releases/tag/v1.6.2-rc1"/>
          </entry>
          <entry>
            <title>flashCat 1.5.9</title>
            <updated>2026-11-01T10:00:00Z</updated>
            <link rel="alternate" href="https://github.com/imi4u36d/flashCat/releases/tag/v1.5.9"/>
          </entry>
        </feed>
        """

    func testParseKeepsStableReleases() {
        let releases = AppUpdateChecker.parse(sample)
        XCTAssertEqual(releases.map(\.version), ["1.6.1", "1.5.9"])
        XCTAssertEqual(releases.first?.title, "flashCat 1.6.1")
    }

    func testVersionComparison() {
        XCTAssertTrue(AppUpdateChecker.isNewer("1.6.1", than: "1.6.0"))
        XCTAssertTrue(AppUpdateChecker.isNewer("1.10.0", than: "1.6.9"))
        XCTAssertFalse(AppUpdateChecker.isNewer("1.6.0", than: "1.6.0"))
        XCTAssertFalse(AppUpdateChecker.isNewer("1.5.9", than: "1.6.0"))
    }

    func testNormalizedTag() {
        XCTAssertEqual(AppUpdateChecker.normalized("v1.6.1"), "1.6.1")
        XCTAssertEqual(AppUpdateChecker.normalized("1.6.1"), "1.6.1")
    }
}
