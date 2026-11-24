// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCatCore

final class ModelPathTests: XCTestCase {
    func testFolderAndDestinationNaming() {
        XCTAssertEqual(ModelInstaller.folderName(for: "owner/repo"), "owner--repo")
        XCTAssertEqual(ModelInstaller.folderName(for: "owner/repo:Q4_K_M"), "owner--repo-Q4_K_M")
        XCTAssertTrue(
            ModelInstaller.destination(engine: .splash, repo: "owner/repo")
                .contains("owner/repo"))
        XCTAssertTrue(
            ModelInstaller.sharedDestination(repo: "owner/repo")
                .hasSuffix("/owner--repo"))
        XCTAssertEqual(
            ModelInstaller.incompleteMarker(for: "/tmp/model"),
            "/tmp/model.flashcat-incomplete")
    }

    func testRepositoryIdNormalization() {
        XCTAssertEqual(ModelCatalogService.repositoryId(from: "owner/repo"), "owner/repo")
        XCTAssertEqual(ModelCatalogService.repositoryId(from: " owner/repo "), "owner/repo")
        XCTAssertEqual(
            ModelCatalogService.repositoryId(from: "/weights/mlx/owner/repo"),
            "owner/repo")
        XCTAssertNil(ModelCatalogService.repositoryId(from: nil))
        XCTAssertNil(ModelCatalogService.repositoryId(from: "   "))
        XCTAssertNil(ModelCatalogService.repositoryId(from: "no-slash"))
        XCTAssertNil(ModelCatalogService.repositoryId(from: "/repo-only"))
    }

    func testSizeWalksNestedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-size-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 20).write(to: nested.appendingPathComponent("b.bin"))

        XCTAssertEqual(ModelInstaller.size(of: root.path), 30)
    }

    func testDownloadEnvironmentForMirror() {
        let environment = ModelInstaller.environment(
            pythonRoot: "/tmp/runtime", cache: "  /tmp/cache  ", source: .hfMirror)

        XCTAssertEqual(environment["HF_HUB_CACHE"], "/tmp/cache")
        XCTAssertEqual(environment["HF_HUB_DISABLE_XET"], "1")
        XCTAssertEqual(environment["PYTHONNOUSERSITE"], "1")
        XCTAssertEqual(environment["HF_ENDPOINT"], HFEndpoint.mirror)
        XCTAssertTrue(environment["PATH"]?.hasPrefix("/tmp/runtime/bin:") == true)
    }

    func testDraftLookupUsesCatalogFamilyTable() {
        var catalog = ModelCatalog()
        catalog.draftRepositories = ["qwen": "owner/draft"]
        XCTAssertEqual(
            catalog.draftRepository("owner/qwen-8b", family: "qwen"),
            "owner/draft")
    }
}
