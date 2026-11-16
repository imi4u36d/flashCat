import Foundation
import XCTest
import FlashCatKit
@testable import FlashCatCLICore

/// HTTP 状态码 → 退出码是 SPEC 里最硬的契约（脚本靠它判断故障类型），但一直只藏在
/// `request` 的非 2xx 分支里没有覆盖。表驱动测一遍，改映射时先红再绿。
final class ControlClientExitCodeTests: XCTestCase {
    private struct Payload: Decodable {
        let ok: Bool
    }

    private func makeClient() -> ControlClient {
        // 只用来调纯函数和 decode，不会真的发请求，端口随便给。
        ControlClient(baseURL: URL(string: "http://127.0.0.1:43210")!, token: "token")
    }

    func testStatusCodesMapToDocumentedExitCodes() {
        let table: [(Int, CLIExit)] = [
            (200, .success),
            (400, .usage),
            (401, .unauthorized),
            (403, .unauthorized),
            (404, .notFound),
            (408, .timeout),
            (409, .conflict),
            (500, .failure),
            (504, .timeout),
        ]
        for (status, expected) in table {
            XCTAssertEqual(ControlClient.exitCode(status: status, code: nil), expected,
                           "HTTP \(status) 应映射到 \(expected)")
        }
    }

    func testServerErrorCodeWinsOverStatus() {
        // 服务端可能用 400 包一个 unauthorized：令牌过期必须在状态码之前判定，
        // 否则用户会看到「用法错误」而不是「令牌过期，重启应用」。
        XCTAssertEqual(ControlClient.exitCode(status: 400, code: ControlErrorCode.unauthorized),
                       .unauthorized)
        XCTAssertEqual(ControlClient.exitCode(status: 504, code: ControlErrorCode.timeout), .timeout)
    }

    func testEmptyBodyIsAFailureNotAnOfflineView() {
        // 空响应说明接口在、但没答上话：至少是 failure，绝不能转成 notRunning 触发降级。
        XCTAssertThrowsError(try decodeEmpty()) { error in
            guard let cliError = error as? CLIError else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(cliError.exit, .failure)
        }
    }

    func testMalformedBodyIsAFailure() {
        XCTAssertThrowsError(try decode(Data("not json".utf8))) { error in
            guard let cliError = error as? CLIError else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(cliError.exit, .failure)
            XCTAssertTrue(cliError.message.contains("无法解析"))
        }
    }

    private func decodeEmpty() throws -> Payload {
        let payload: Payload = try makeClient().decode(Data())
        return payload
    }

    private func decode(_ data: Data) throws -> Payload {
        let payload: Payload = try makeClient().decode(data)
        return payload
    }
}
