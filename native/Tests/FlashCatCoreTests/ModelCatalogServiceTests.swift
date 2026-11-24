// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCatCore

final class ModelCatalogServiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLoadScansLocalRepositoriesAndSkipsIncomplete() throws {
        let repo = root.appendingPathComponent("owner/repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: repo.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: repo.appendingPathComponent("tokenizer.json"))

        let partial = root.appendingPathComponent("owner/partial", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: partial.appendingPathComponent("config.json"))
        try Data().write(to: URL(fileURLWithPath: partial.path + ".flashcat-incomplete"))

        let service = ModelCatalogService(
            splashModelsDirectory: root.path, sharedScanner: { [] })
        let catalog = service.load()

        XCTAssertEqual(catalog.local.map(\.id), ["owner/repo"])
        XCTAssertEqual(catalog.machineModel("owner/repo")?.origin, .local)
    }

    func testLoadScansResolvedAssemblies() throws {
        let assembly = root.appendingPathComponent(".resolved/asm", isDirectory: true)
        let target = assembly.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(#"{"model":"owner/assembed","files":{"w.safetensors":{"bytes":10}}}"#.utf8)
            .write(to: assembly.appendingPathComponent("model.json"))

        let service = ModelCatalogService(
            splashModelsDirectory: root.path, sharedScanner: { [] })
        let catalog = service.load()

        XCTAssertEqual(catalog.installed.map(\.id), ["owner/assembed"])
        XCTAssertEqual(catalog.installed.first?.bytes, 10)
        XCTAssertEqual(catalog.installed.first?.origin, .splash)
    }

    func testDeleteLocalRemovesFolderAndRefusesRecommendations() throws {
        let repo = root.appendingPathComponent("owner/repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let model = ModelInfo(
            id: "owner/repo", path: repo.path, bytes: 0, origin: .local, targetName: "")

        let service = ModelCatalogService(
            splashModelsDirectory: root.path, sharedScanner: { [] })
        try service.deleteLocal(model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.path))

        let recommended = ModelInfo(
            id: "owner/rec", path: "/tmp/rec", bytes: 0, origin: .recommended, targetName: "")
        XCTAssertThrowsError(try service.deleteLocal(recommended))
    }
}
