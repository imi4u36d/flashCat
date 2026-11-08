import XCTest
@testable import FlashCatCLICore

final class CLIFormatTests: XCTestCase {
    func testByteAndRateFormatting() {
        XCTAssertEqual(CLIFormat.bytes(nil), "—")
        XCTAssertEqual(CLIFormat.bytes(2 * 1_073_741_824), "2.0 GB")
        XCTAssertEqual(CLIFormat.rate(2 * 1_048_576), "2.0 MB/s")
        XCTAssertEqual(CLIFormat.percent(0.25), "25%")
        XCTAssertEqual(CLIFormat.duration(65), "1m05s")
    }
}
