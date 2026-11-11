import XCTest
@testable import FlashCatKit

/// 仓库 id 会被拼成模型目录名，路径比较决定「能不能删」。这两件事都没有第二次
/// 机会：一个 `..` 删掉的是用户的家目录，一次前缀比较错删的是隔壁目录。
final class RepositorySafetyTests: XCTestCase {
    func testOnlyOwnerSlashRepoIsAccepted() {
        XCTAssertTrue(FlashCatPaths.isSafeRepository("mlx-community/Qwen3.8-Flash-Next-4bit"))
        XCTAssertTrue(FlashCatPaths.isSafeRepository("owner/repo:q4_k_m"))
        XCTAssertTrue(FlashCatPaths.isSafeRepository("a.b/c_d-e"))

        XCTAssertFalse(FlashCatPaths.isSafeRepository("../../../../Documents"))
        XCTAssertFalse(FlashCatPaths.isSafeRepository("owner/../../../Documents"))
        XCTAssertFalse(FlashCatPaths.isSafeRepository("/Users/wangzhuo/Documents"))
        XCTAssertFalse(FlashCatPaths.isSafeRepository("owner//repo"))
        XCTAssertFalse(FlashCatPaths.isSafeRepository("owner"))
        XCTAssertFalse(FlashCatPaths.isSafeRepository(""))
        XCTAssertFalse(FlashCatPaths.isSafeRepository("owner/re po"))
        XCTAssertFalse(FlashCatPaths.isSafeRepository("owner/repo\0"))
    }

    func testNestedModelPathRefusesToEscapeTheModelsRoot() {
        let root = FlashCatPaths.modelsRoot
        let escaped = FlashCatPaths.modelPath(for: .mlxServe, model: "../../../Documents")
        XCTAssertTrue(FlashCatPaths.contains(escaped, in: root), "escaped path: \(escaped)")

        let safe = FlashCatPaths.modelPath(for: .mlxServe, model: "mlx-community/Qwen3.8-Flash-Next-4bit")
        XCTAssertEqual(safe, FlashCatPaths.modelsDirectory(.mlxServe) + "/mlx-community/Qwen3.8-Flash-Next-4bit")
    }

    func testContainmentComparesPathComponentsNotPrefixes() {
        XCTAssertTrue(FlashCatPaths.contains("/a/models/x", in: "/a/models"))
        XCTAssertTrue(FlashCatPaths.contains("/a/models", in: "/a/models"))
        XCTAssertTrue(FlashCatPaths.contains("/a/models/x/../y", in: "/a/models"))
        XCTAssertFalse(FlashCatPaths.contains("/a/models2/x", in: "/a/models"))
        XCTAssertFalse(FlashCatPaths.contains("/a/models/../secrets", in: "/a/models"))
    }

    func testVersionTagsCannotCarryShellMetacharacters() {
        XCTAssertEqual(EngineUpstream.normalizedVersion("v1.4.1"), "1.4.1")
        XCTAssertEqual(EngineUpstream.normalizedVersion("0.7.3.dev2"), "0.7.3.dev2")
        let hostile = EngineUpstream.normalizedVersion("1.2'; rm -rf ~; echo '")
        XCTAssertFalse(hostile.contains("'"))
        XCTAssertFalse(hostile.contains(";"))
        XCTAssertFalse(hostile.contains(" "))
    }
}
