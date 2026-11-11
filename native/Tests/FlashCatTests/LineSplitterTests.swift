import XCTest
@testable import FlashCat

final class LineSplitterTests: XCTestCase {
    func testSplitsOnNewlinesAndKeepsTheTail() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.consume(Data("alpha\nbeta".utf8)), ["alpha"])
        XCTAssertEqual(splitter.consume(Data("\ngamma\n".utf8)), ["beta", "gamma"])
        XCTAssertNil(splitter.flush())
    }

    func testCarriageReturnRedrawsSplitToo() {
        // Splash 的 tqdm 进度条只吐 \r，早先只按 \n 切，整段进度到最后才出现。
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.consume(Data(" 12%\r 48%\r100%".utf8)), [" 12%", " 48%"])
        XCTAssertEqual(splitter.flush(), "100%")
    }

    func testEmptyLinesFromRedrawsAreDropped() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.consume(Data("\r\r\n\n".utf8)), [])
        XCTAssertNil(splitter.flush())
    }

    func testInvalidUTF8TailIsDroppedInsteadOfCrashing() {
        var splitter = LineSplitter()
        _ = splitter.consume(Data([0xFF, 0x0A]))
        XCTAssertNil(splitter.flush())
    }
}
