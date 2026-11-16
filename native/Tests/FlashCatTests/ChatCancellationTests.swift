import XCTest
@testable import FlashCat

/// 「取消」只能来自类型，不能来自文案。
///
/// 这是验收口径第二条（`grep -rn '"cancel"\|"取消"' Sources/` 为空）的钉子：
/// 以前 `AppState.isCancellation` 用 `localizedCaseInsensitiveContains` 判取消，
/// 引擎自己的报错里出现「取消」「cancel」就会被当成用户停止，真实的失败被静默
/// 吞掉。下面的断言里，消息文案写满这些词也必须判成「不是取消」。
final class ChatCancellationTests: XCTestCase {
    func testChatErrorCancelledKindIsCancellation() {
        XCTAssertTrue(ChatError(kind: .cancelled, message: "已取消").isCancellation)
    }

    func testChatErrorOtherKindsAreNotCancellation() {
        XCTAssertFalse(ChatError(kind: .badStatus(500), message: "服务返回 HTTP 500").isCancellation)
        XCTAssertFalse(ChatError(kind: .invalidEndpoint(port: 0), message: "端口无效").isCancellation)
        XCTAssertFalse(ChatError(kind: .encoding, message: "编码失败").isCancellation)
        XCTAssertFalse(ChatError(kind: .transport, message: "连接被拒").isCancellation)
        XCTAssertFalse(ChatError(kind: .emptyBody, message: "服务没有返回内容").isCancellation)
    }

    /// 兼容构造只给文案：一律按传输失败收，绝不按文案猜成取消。
    func testMessageOnlyInitNeverProducesCancellation() {
        XCTAssertEqual(ChatError(message: "已取消").kind, .transport)
        XCTAssertFalse(ChatError(message: "已取消").isCancellation)
        XCTAssertFalse(ChatError(message: "request cancelled by peer").isCancellation)
        XCTAssertFalse(ChatError(message: "CANCEL").isCancellation)
    }

    func testChatErrorEquatableComparesKindAndMessage() {
        XCTAssertEqual(ChatError(kind: .badStatus(500), message: "500"),
                       ChatError(kind: .badStatus(500), message: "500"))
        XCTAssertNotEqual(ChatError(kind: .badStatus(500), message: "500"),
                          ChatError(kind: .badStatus(502), message: "500"))
        XCTAssertNotEqual(ChatError(kind: .badStatus(500), message: "500"),
                          ChatError(kind: .badStatus(500), message: "502"))
    }

    /// 图像与视频客户端同构：同一个判据、同一套「文案不算数」的规则。
    func testImageClientErrorUsesTheSameRule() {
        XCTAssertTrue(ImageClientError(kind: .cancelled, message: "已取消").isCancellation)
        XCTAssertFalse(ImageClientError(kind: .badStatus(500), message: "服务返回 HTTP 500").isCancellation)
        XCTAssertFalse(ImageClientError(kind: .engine, message: "已取消").isCancellation)
        XCTAssertEqual(ImageClientError(message: "已取消").kind, .transport)
        XCTAssertFalse(ImageClientError(message: "已取消").isCancellation)
    }

    func testVideoClientErrorUsesTheSameRule() {
        XCTAssertTrue(VideoClientError(kind: .cancelled, message: "已取消").isCancellation)
        XCTAssertFalse(VideoClientError(kind: .invalidParameter, message: "参数无效").isCancellation)
        XCTAssertFalse(VideoClientError(kind: .payloadTooLarge, message: "太大").isCancellation)
        XCTAssertFalse(VideoClientError(kind: .transport, message: "已取消").isCancellation)
        XCTAssertEqual(VideoClientError(message: "已取消").kind, .transport)
        XCTAssertFalse(VideoClientError(message: "已取消").isCancellation)
    }
}
