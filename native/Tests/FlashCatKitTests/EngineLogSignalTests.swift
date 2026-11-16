import XCTest
@testable import FlashCatKit

/// 引擎日志信号的判定：这条用例同时钉住「认什么」和「不认什么」。
///
/// 不认的那一半是重点——以前靠 `lowercased()` 整串比较，判定边界没人写下来；
/// 现在它决定 `state` 会不会迁移、失败提示会不会出现，边界必须固定住。
final class EngineLogSignalTests: XCTestCase {
    func testReadyMarkerIsFoundAnywhereInTheLine() {
        XCTAssertEqual(EngineLogSignal.detect("INFO: Ready · serving"), .ready)
        XCTAssertEqual(EngineLogSignal.detect("Ready ·"), .ready)
        // 引擎的 Ready 行前面常带时间戳，标记不在行首。
        XCTAssertEqual(EngineLogSignal.detect("2026-11-16 09:39:00 Ready · serving :8080"), .ready)
    }

    func testErrorMarkerKeepsOnlyTheMessage() {
        XCTAssertEqual(EngineLogSignal.detect("Error · OOM"), .error("OOM"))
        XCTAssertEqual(EngineLogSignal.detect("Error ·   memory guard tripped  "), .error("memory guard tripped"))
    }

    func testBareMarkerFallsBackToTheWholeLine() {
        // 正文为空时提示不能是空串：读的人只剩退出码可看。
        XCTAssertEqual(EngineLogSignal.detect("Error ·"), .error("Error ·"))
        XCTAssertEqual(EngineLogSignal.detect("error:"), .error("error:"))
    }

    func testErrorPrefixIsCaseInsensitiveAndLineScoped() {
        XCTAssertEqual(EngineLogSignal.detect("error: port in use"), .error("port in use"))
        XCTAssertEqual(EngineLogSignal.detect("ERROR: port in use"), .error("port in use"))
        XCTAssertEqual(EngineLogSignal.detect("Error: model missing"), .error("model missing"))
        XCTAssertEqual(EngineLogSignal.detect("error:port in use"), .error("port in use"))
        // 只认行首：正文里出现 "error:" 不是准备失败。
        XCTAssertEqual(EngineLogSignal.detect("warn: retrying after error: timeout"), .none)
    }

    func testPlainLinesAreNotSignals() {
        XCTAssertEqual(EngineLogSignal.detect(""), .none)
        XCTAssertEqual(EngineLogSignal.detect("引擎已启动，正在加载权重"), .none)
        XCTAssertEqual(EngineLogSignal.detect("info: 已就绪"), .none)
        // 大小写不放宽：正文里提一句 ready 不该触发状态迁移。
        XCTAssertEqual(EngineLogSignal.detect("still not ready · waiting"), .none)
        XCTAssertEqual(EngineLogSignal.detect("error · lowercase marker"), .none)
    }

    func testCrlfLineTailDoesNotLeakIntoTheMessage() {
        // 日志按 \n 切行，CRLF 流会在行尾留一个 \r。
        XCTAssertEqual(EngineLogSignal.detect("Error · OOM\r"), .error("OOM"))
        XCTAssertEqual(EngineLogSignal.detect("error: port in use\r"), .error("port in use"))
        XCTAssertEqual(EngineLogSignal.detect("Ready · serving\r"), .ready)
    }

    /// 一整行模型输出可能有几 KB：判定必须不崩，也不能因为长就漏掉标记。
    func testLongLineStillDecidesCorrectly() {
        let padding = String(repeating: "模型权重加载中…", count: 512)
        XCTAssertGreaterThan(padding.utf8.count, 4096)
        XCTAssertEqual(EngineLogSignal.detect(padding), .none)
        XCTAssertEqual(EngineLogSignal.detect(padding + " Ready · serving"), .ready)
        XCTAssertEqual(EngineLogSignal.detect("Error · " + padding), .error(padding))
    }
}
