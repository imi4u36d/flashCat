// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCatCore

final class CoreUtilitiesTests: XCTestCase {
    func testServerStateMapsEngineRunStates() {
        XCTAssertEqual(ServerState(EngineRunState.stopped), .stopped)
        XCTAssertEqual(ServerState(EngineRunState.starting), .starting)
        XCTAssertEqual(ServerState(EngineRunState.loading), .starting)
        XCTAssertEqual(ServerState(EngineRunState.ready), .ready)
        XCTAssertEqual(ServerState(EngineRunState.stopping), .stopping)
        XCTAssertEqual(ServerState(EngineRunState.failed), .failed)
    }

    func testNoticeKindClassifiesBothLanguages() {
        XCTAssertEqual(IslandNotice.Kind(message: "下载失败"), .error)
        XCTAssertEqual(IslandNotice.Kind(message: "please wait"), .warning)
        XCTAssertEqual(IslandNotice.Kind(message: "已复制"), .success)
        XCTAssertEqual(IslandNotice.Kind(message: "已刷新模型列表"), .success)
        XCTAssertEqual(IslandNotice.Kind(message: "随便一句"), .info)
    }

    func testModelInfoShortNameAndQuantization() {
        let info = ModelInfo(
            id: "mlx-community/Qwen3-8B-4bit", path: "/tmp/model", bytes: 4_000_000_000,
            origin: .local, targetName: "Qwen3-8B-4bit")
        XCTAssertEqual(info.shortName, "Qwen3-8B-4bit")
        XCTAssertEqual(ModelQuantization.label(bits: 4), "4-bit")
        XCTAssertEqual(ModelQuantization.detect(in: "Qwen3-8B-Q4_K_M.gguf"), "Q4_K_M")
        XCTAssertNil(ModelQuantization.detect(in: "Qwen3-8B"))
    }

    func testCatalogMachineDeduplicatesLocalAndInstalled() {
        let local = ModelInfo(
            id: "owner/repo", path: "/tmp/a", bytes: 1, origin: .local, targetName: "a")
        let installed = ModelInfo(
            id: "owner/repo", path: "/tmp/b", bytes: 2, origin: .splash, targetName: "b")
        var catalog = ModelCatalog()
        catalog.local = [local]
        catalog.installed = [installed]

        XCTAssertEqual(catalog.machine.count, 1)
        XCTAssertEqual(catalog.machineModel("owner/repo")?.bytes, 1)
    }

    func testHubSearchRoutesByFormat() {
        XCTAssertEqual(HubSearchState.engines(for: .gguf), [.splash])
        XCTAssertEqual(HubSearchState.engines(for: .mtplx), [.mtplx])
        XCTAssertEqual(HubSearchState.engines(for: .mlx), [.omlx, .mlxServe])
        XCTAssertEqual(HubSearchState.engines(for: .unmarked), [.omlx, .mlxServe])
    }
}
