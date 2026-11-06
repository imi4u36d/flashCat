import XCTest
import FlashCatKit
@testable import FlashCat

final class ModelLibraryTests: XCTestCase {
    /// 同一个模型可以由多个引擎驱动，在「全部」页会各占一行。列表身份必须
    /// 带上引擎，否则 ForEach 收到重复 id，懒加载网格会出现空位甚至整页空白。
    func testAllScopeEntriesHaveUniqueIdentity() {
        let rows = EngineCatalog.allIDs.flatMap { engine in
            ModelLibrary.entries(installed: [],
                                 engine: engine,
                                 recommendations: ModelRecommendations.list(for: engine),
                                 draftRepository: { _ in nil })
        }

        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(Set(rows.map(\.identity)).count, rows.count)
        XCTAssertLessThan(Set(rows.map(\.id)).count, rows.count,
                          "目录里有跨引擎共享的模型，裸 id 本就会重复")
    }

    func testIdentityIncludesEngine() {
        let entry = ModelLibraryEntry(
            model: ModelInfo(id: "owner/repo", path: "", bytes: 0, origin: .recommended,
                             targetName: ""),
            engine: .omlx,
            recommendation: nil,
            draftRepository: nil,
            source: .recommended
        )
        XCTAssertEqual(entry.identity, "omlx/owner/repo")
    }
}
