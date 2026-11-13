import XCTest
@testable import FlashCat

/// First tests for the app shell.
///
/// They deliberately avoid `AppState`: that class owns `UserDefaults`, the
/// engine manager and the download pipeline, so a test of it would be a test of
/// the machine it runs on. The boundary that made these fixes verifiable is the
/// one worth testing — pure helpers that the 1 Hz snapshot path can be wrong in.
final class LogStoreTests: XCTestCase {
    private var path = ""

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "flashcat-logstore-\(UUID().uuidString).log"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    func testTailReturnsNewestFirst() {
        let store = LogStore(path: path)
        for index in 1...5 { store.append("line \(index)") }

        // The stage line reads `tail(60)` once a second and expects newest first.
        XCTAssertEqual(store.tail(3).map(\.text), ["line 5", "line 4", "line 3"])
    }

    func testTailIsBoundedByTheRequestedCount() {
        let store = LogStore(path: path)
        for index in 1...200 { store.append("line \(index)") }

        XCTAssertEqual(store.tail(10).count, 10)
    }

    func testTailOnAnEmptyStoreIsEmpty() {
        XCTAssertTrue(LogStore(path: path).tail(20).isEmpty)
    }

    /// 上限之后的裁剪是分批的；无论裁掉多少，最新一行必须还在，且内存尾部
    /// 不能无限增长。
    func testBatchTrimKeepsTheNewestLines() {
        let store = LogStore(path: path)
        for index in 1...25_000 { store.append("line \(index)") }

        let tail = store.tail(30_000)
        XCTAssertLessThanOrEqual(tail.count, 20_000)
        XCTAssertGreaterThan(tail.count, 19_000)
        XCTAssertEqual(tail.first?.text, "line 25000")
        XCTAssertFalse(tail.contains { $0.text == "line 1" })
    }

    /// `note()` used to call `openFile()`/`close()` around a single line. Since
    /// `openFile()` reloads history from disk and `close()` drops the write
    /// handle, a note written while the engine ran stopped every later line from
    /// reaching the log file. Appending must not touch the sink lifecycle.
    func testAppendingDoesNotRequireAnOpenSink() {
        let store = LogStore(path: path)
        store.append("==> 启动", level: .system)
        store.append("plain engine output")

        XCTAssertEqual(store.tail(2).map(\.text), ["plain engine output", "==> 启动"])
        XCTAssertEqual(store.tail(2).map(\.level), [.info, .system])
    }

    /// 页面上的「最新在上」只在视图层翻序。存储层必须保持追加顺序：
    /// `AppState` 用 `logs.last?.id` 判断有没有新行，反过来的话日志页
    /// 会停在旧内容上不再刷新。
    func testSnapshotKeepsAppendOrder() {
        let store = LogStore(path: path)
        for index in 1...3 { store.append("line \(index)") }

        XCTAssertEqual(store.snapshot().map(\.text), ["line 1", "line 2", "line 3"])
    }
}
