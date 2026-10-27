import XCTest
@testable import FlashCatKit

/// "删除" only makes sense for packs flashCat installed itself. Packs that come
/// with the app (or with a checkout) are listed, but not deletable — deleting
/// them either breaks the code signature or the next build.
final class EnginePackOwnershipTests: XCTestCase {
    private let userRoot = "/Users/me/Library/Application Support/flashCat/engines"

    private func removable(_ path: String, roots: [String]? = nil) -> Bool {
        EnginePackOwnership.isRemovable(directory: path, userRoots: roots ?? [userRoot])
    }

    func testVersionInsideUserRootIsRemovable() {
        XCTAssertTrue(removable(userRoot + "/splash/1.4.1"))
    }

    func testRootItselfCounts() {
        XCTAssertTrue(removable(userRoot))
    }

    func testTrailingSlashStillMatches() {
        XCTAssertTrue(removable(userRoot + "/splash/1.4.1/"))
        XCTAssertTrue(removable(userRoot + "/", roots: [userRoot + "/"]))
    }

    func testBundledPackIsNotRemovable() {
        XCTAssertFalse(removable("/Applications/flashCat.app/Contents/Resources/engines/splash/1.4.0"))
    }

    func testCheckoutPackIsNotRemovable() {
        XCTAssertFalse(removable("/Users/me/zhuo/flashCat/vendor/engines/omlx/0.7.2"))
    }

    func testSiblingDirectoryWithSamePrefixIsNotRemovable() {
        // `engines-copy` must not be treated as living under `engines`.
        XCTAssertFalse(removable("/Users/me/Desktop/engines-copy/splash/1.4.0"))
    }

    func testNoUserRootsMeansNothingIsRemovable() {
        XCTAssertFalse(removable(userRoot + "/splash/1.4.1", roots: []))
        XCTAssertFalse(removable("relative/path", roots: [""]))
    }

    func testRemovableVersionsKeepsOnlyUserOwnedEntries() {
        let sets = EnginePackOwnership.removableVersions(
            directories: [
                ("1.4.1", userRoot + "/splash/1.4.1"),
                ("1.4.0", "/Applications/flashCat.app/Contents/Resources/engines/splash/1.4.0"),
            ],
            userRoots: [userRoot])
        XCTAssertEqual(sets, ["1.4.1"])
    }
}
