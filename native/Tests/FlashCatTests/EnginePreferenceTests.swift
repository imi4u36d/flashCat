import XCTest
import FlashCatKit
@testable import FlashCat

/// 「默认引擎」只是下次启动的偏好，绝不能顺手改写正在运行的那一台。
/// 引擎切换本身用 `EngineManager.activate` 落盘，这里只钉住存储层的边界。
@MainActor
final class EnginePreferenceTests: XCTestCase {
    func testDefaultEngineNeverRewritesTheActiveEngine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-engine-preference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = EngineStore(directory: directory.path)
        store.rememberActive(.splash)
        store.setDefaultEngine(.omlx)

        // 下次启动会落在 omlx…
        XCTAssertEqual(store.defaultEngineID, .omlx)
        XCTAssertEqual(store.preferredEngine, .omlx)
        // …但当前正在跑的仍是 splash，`active` 一个字节都没动。
        XCTAssertEqual(try storedVersion("active", in: directory), EngineID.splash.rawValue)
        XCTAssertEqual(try storedVersion("default", in: directory), EngineID.omlx.rawValue)
    }

    func testExplicitSwitchMovesTheDefaultWithIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-engine-preference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = EngineStore(directory: directory.path)
        store.rememberActive(.splash)
        store.setDefaultEngine(.omlx)
        store.rememberActive(.mlxServe)

        XCTAssertEqual(store.defaultEngineID, .mlxServe)
        XCTAssertEqual(try storedVersion("active", in: directory), EngineID.mlxServe.rawValue)
        XCTAssertEqual(try storedVersion("default", in: directory), EngineID.mlxServe.rawValue)
    }

    private func storedVersion(_ key: String, in directory: URL) throws -> String? {
        let url = directory.appendingPathComponent("engines.json")
        let data = try Data(contentsOf: url)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (document[key] as? [String: Any])?["version"] as? String
    }
}
