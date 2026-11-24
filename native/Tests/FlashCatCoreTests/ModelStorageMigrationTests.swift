// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCatCore

/// 迁移会移动真实文件，所以整个夹具把 `HOME` 与 `FLASHCAT_SUPPORT_DIR` 都指到
/// 临时目录；生产路径一个字节都不会被碰。
final class ModelStorageMigrationTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var support: URL!
    private var previousEnvironment: [(key: String, value: String?)] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-migration-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        previousEnvironment = ["HOME", "FLASHCAT_SUPPORT_DIR", "FLASHCAT_LOGS_DIR"].map {
            ($0, ProcessInfo.processInfo.environment[$0])
        }
        setenv("HOME", home.path, 1)
        setenv("FLASHCAT_SUPPORT_DIR", support.path, 1)
        setenv("FLASHCAT_LOGS_DIR", root.appendingPathComponent("logs").path, 1)
    }

    override func tearDownWithError() throws {
        for entry in previousEnvironment {
            if let value = entry.value {
                setenv(entry.key, value, 1)
            } else {
                unsetenv(entry.key)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testMovesLegacyEngineModelsIntoSupport() throws {
        let source = home.appendingPathComponent(".omlx/models/owner/repo", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: source.appendingPathComponent("tokenizer.json"))

        let report = ModelStorageMigration.migrate()

        XCTAssertGreaterThanOrEqual(report.moved, 1)
        let target = EnginePaths.modelsDirectory(.omlx) + "/owner--repo"
        XCTAssertTrue(FileManager.default.fileExists(atPath: target))
    }

    func testRoutesLegacyFlashCatRootIntoNestedSplashLayout() throws {
        let source = home.appendingPathComponent(".flashcat/models/owner/repo", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("model.safetensors"))

        let report = ModelStorageMigration.migrate()

        XCTAssertGreaterThanOrEqual(report.moved, 1)
        let target = EnginePaths.modelsDirectory(.splash) + "/owner/repo"
        XCTAssertTrue(FileManager.default.fileExists(atPath: target))
    }

    func testMovesUnknownTopLevelEntriesBackUnderSplash() throws {
        let stray = EnginePaths.modelsRoot + "/stray"
        try FileManager.default.createDirectory(atPath: stray, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: stray + "/weights.bin"))

        let report = ModelStorageMigration.migrate()

        XCTAssertGreaterThanOrEqual(report.moved, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: EnginePaths.modelsDirectory(.splash) + "/stray/weights.bin"))
    }

    func testArchivesLegacyAssemblyIndexes() throws {
        let source = home.appendingPathComponent(".omlx/splash", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("model.json"))

        let report = ModelStorageMigration.migrate()

        XCTAssertGreaterThanOrEqual(report.archived, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let backups = support.appendingPathComponent("migration-backups")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backups.path))
    }

    func testMovesLegacyPrefixCache() throws {
        let source = home.appendingPathComponent(".mtplx/session-bank/data.bin")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: source)

        _ = ModelStorageMigration.migrate()

        let target = FlashCatPaths.prefixCacheDirectory(.mtplx)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target))
    }
}
