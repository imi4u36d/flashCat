// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCat

final class ModelLibraryTests: XCTestCase {
    /// 同一个模型可以由多个引擎驱动，在「全部」页会各占一行。列表身份必须
    /// 带上引擎，否则 ForEach 收到重复 id，懒加载网格会出现空位甚至整页空白。
    func testAllScopeEntriesHaveUniqueIdentity() {
        let rows = EngineCatalog.allIDs.flatMap { engine in
            ModelLibrary.entries(
                installed: [],
                engine: engine,
                recommendations: ModelRecommendations.list(for: engine),
                draftRepository: { _ in nil })
        }

        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(Set(rows.map(\.identity)).count, rows.count)
        XCTAssertLessThan(
            Set(rows.map(\.id)).count, rows.count,
            "目录里有跨引擎共享的模型，裸 id 本就会重复")
    }

    func testIdentityIncludesEngine() {
        let entry = ModelLibraryEntry(
            model: ModelInfo(
                id: "owner/repo", path: "", bytes: 0, origin: .recommended,
                targetName: ""),
            engine: .omlx,
            recommendation: nil,
            draftRepository: nil,
            source: .recommended
        )
        XCTAssertEqual(entry.identity, "omlx/owner/repo")
    }

    /// HF 缓存目录把仓库压成 `owner--repo`；卡片标题只应该显示仓库名，
    /// 否则 340pt 宽的卡片会把作者前缀当成模型名的一部分。
    func testShortNameDropsHuggingFaceOwnerPrefix() {
        func name(_ id: String) -> String {
            ModelInfo(
                id: id, path: "", bytes: 0, origin: .recommended, targetName: ""
            ).shortName
        }
        XCTAssertEqual(
            name("Youssofal--Qwen3.8-27B-MTPLX-Optimized-Speed"),
            "Qwen3.8-27B-MTPLX-Optimized-Speed")
        XCTAssertEqual(name("owner/repo"), "repo")
        XCTAssertEqual(name("Qwen3.8-Flash-Next"), "Qwen3.8-Flash-Next")
        XCTAssertEqual(name("--leading"), "leading")
    }
}
