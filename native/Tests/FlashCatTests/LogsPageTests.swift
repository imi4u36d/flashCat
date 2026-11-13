import XCTest
@testable import FlashCat

/// 日志页的阅读顺序：存储层按时间追加，页面把最新的排在最上面。
final class LogsPageTests: XCTestCase {
    private func line(_ id: Int, _ text: String, _ level: LogLevel = .info) -> LogLine {
        LogLine(id: id, time: Date(timeIntervalSince1970: TimeInterval(id)), text: text, level: level)
    }

    /// 页面的第一行必须是最后到达的那条——否则实时日志要滚到底才看得见。
    func testDigestPutsTheNewestLineFirst() {
        let source = (1...4).map { line($0, "line \($0)") }

        let digest = LogsDigest.make(from: source, level: .all, query: "")

        XCTAssertEqual(digest.lines.map(\.text), ["line 4", "line 3", "line 2", "line 1"])
        XCTAssertEqual(digest.counts[.all], 4)
        XCTAssertEqual(digest.counts[.info], 4)
    }

    /// 过滤后的顺序同样是从新到旧，复制出去的内容才和屏幕上一致。
    func testFilteredDigestKeepsNewestFirstOrder() {
        let source = [
            line(1, "Error · 第一次失败", .error),
            line(2, "引擎已启动", .success),
            line(3, "Error · 第二次失败", .error),
        ]

        let digest = LogsDigest.make(from: source, level: .error, query: "失败")

        XCTAssertEqual(digest.lines.map(\.id), [3, 1])
        XCTAssertEqual(digest.counts[.all], 3)
        XCTAssertEqual(digest.counts[.error], 2)
        // 成功行在计数上归入「提示」，但被级别筛选挡在列表外。
        XCTAssertEqual(digest.counts[.info], 1)
    }

    func testSearchNarrowsTheListWithoutChangingOrder() {
        let source = [
            line(1, "==> 启动 splash"),
            line(2, "模型加载完成"),
            line(3, "==> 预热 splash"),
        ]

        let digest = LogsDigest.make(from: source, level: .all, query: "splash")

        XCTAssertEqual(digest.lines.map(\.id), [3, 1])
    }
}
