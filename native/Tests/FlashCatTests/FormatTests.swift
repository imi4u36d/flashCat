import XCTest
@testable import FlashCat

/// 面板上的数字只有一套口径：磁盘用十进制（和 Finder 一致），内存用二进制
/// （和活动监视器一致），速度跟磁盘同口径。这几条断言就是口径的看门狗。
final class FormatTests: XCTestCase {
    func testDiskSizeIsDecimalSoItMatchesTheFinder() {
        XCTAssertEqual(Format.size(4_300_000_000), "4.3 GB")
        XCTAssertEqual(Format.size(1_000_000_000), "1.0 GB")
        XCTAssertEqual(Format.size(999_000_000), "999 MB")
        XCTAssertEqual(Format.size(4_294_967_296), "4.3 GB")
        // 低于 1 MB 不能读成「0 MB」。
        XCTAssertEqual(Format.size(524_288), "524 KB")
    }

    func testMemoryIsBinary() {
        XCTAssertEqual(Format.memory(8_589_934_592), "8.0 GB")
        XCTAssertEqual(Format.memory(1_073_741_824), "1.0 GB")
        XCTAssertEqual(Format.memory(1_048_576), "1.0 MB")
        XCTAssertEqual(Format.memory(1024), "1.0 KB")
    }

    func testTheSameByteCountReadsTheSameOnEveryPanel() {
        // 这个值在模型卡片、Hub 列表和下载中心三处出现，早先卡片用十进制、
        // 下载中心用二进制，同一份权重写成 4.3 GB / 4.0 GB 两个数。
        let bytes = 4_294_967_296
        XCTAssertEqual(Format.size(bytes), Format.size(bytes))
        XCTAssertEqual(Format.size(bytes), "4.3 GB")
        XCTAssertNotEqual(Format.memory(bytes), Format.size(bytes))
    }

    func testTransferRateUsesTheSameDecimalBase() {
        XCTAssertEqual(Format.rate(10_000_000), "10.0 MB/s")
        XCTAssertEqual(Format.rate(2_000_000), "2.0 MB/s")
        XCTAssertEqual(Format.rate(1500), "2 KB/s")
        XCTAssertEqual(Format.rate(0), "—")
    }

    func testTokenReadings() {
        XCTAssertEqual(Format.tokens(999), "999")
        XCTAssertEqual(Format.tokens(1000), "1.0K")
        XCTAssertEqual(Format.tokens(12_345), "12.3K")
        XCTAssertEqual(Format.tokensShort(131_072), "131K")
        XCTAssertEqual(Format.tokensShort(999), "999")
    }

    func testCompactKeepsThreeSignificantShapes() {
        XCTAssertEqual(Format.compact(123.4), "123")
        XCTAssertEqual(Format.compact(12.34), "12.3")
        XCTAssertEqual(Format.compact(1.234), "1.23")
    }
}
