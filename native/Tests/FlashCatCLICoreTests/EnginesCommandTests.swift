import XCTest
@testable import FlashCatCLICore

final class EnginesCommandTests: XCTestCase {
    func testSelectedVersionDefaultsToNewest() throws {
        XCTAssertEqual(try EnginesCommand.selectedVersion(["0.7.3", "0.7.2"], requested: nil),
                       "0.7.3")
    }

    func testSelectedVersionHonoursAnExactMatch() throws {
        XCTAssertEqual(try EnginesCommand.selectedVersion(["0.7.3", "0.7.2"], requested: "0.7.2"),
                       "0.7.2")
    }

    func testSelectedVersionNeverRetargetsAMissingVersion() {
        XCTAssertThrowsError(try EnginesCommand.selectedVersion(["0.7.3"], requested: "0.7.2")) { error in
            guard let cli = error as? CLIError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(cli.exit, .notFound)
            XCTAssertTrue(cli.message.contains("0.7.2"))
            XCTAssertTrue(cli.hint?.contains("0.7.3") == true)
        }
    }

    func testSelectedVersionFailsWhenNothingIsInstalled() {
        XCTAssertThrowsError(try EnginesCommand.selectedVersion([], requested: nil))
    }
}
