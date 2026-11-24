// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCat
@testable import FlashCatCore

/// The recommendation rows come from the engines' own packs. These tests pin
/// the two readers to the formats those packs publish, so a parser change is
/// caught before the model page silently empties.
final class NativeModelCatalogTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "flashcat-catalog-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: root + "/install", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    // MARK: Splash

    func testSplashPicksTheStrongestVariantThatFitsPerFamily() throws {
        let table = """
            # MODEL\tNAME\tMEMORY\tSIZE\tABOUT
            org/Family-A-GGUF:Q4_K_M\tFamily A\t36\t24\tFast all-rounder
            mlx-community/Family-A-4bit\tFamily A\t36\t21\tFast all-rounder
            org/Family-A-GGUF:Q2_K\tFamily A\t24\t14\tFast all-rounder
            org/Family-B-GGUF:Q4_K_M\tFamily B\t64\t40\tLargest model
            org/Family-C-GGUF:Q8_0\tFamily C\t128\t90\tMost capable
            """
        try table.write(
            toFile: root + "/install/suggested-models.tsv",
            atomically: true, encoding: .utf8)

        let small = NativeModelCatalog.splash(root: root, memoryGB: 32)
        XCTAssertEqual(small.map(\.id), ["org/Family-A-GGUF:Q2_K"])
        XCTAssertEqual(small.first?.minimumMemory, 24)
        XCTAssertEqual(small.first?.engines, [.splash])
        XCTAssertEqual(small.first?.tags.first, "GGUF")

        let large = NativeModelCatalog.splash(root: root, memoryGB: 64)
        XCTAssertEqual(
            large.map(\.id),
            ["org/Family-A-GGUF:Q4_K_M", "org/Family-B-GGUF:Q4_K_M"])
        XCTAssertEqual(large.map(\.rank), [2, 1])
    }

    func testSplashWithoutTheTableHasNoRows() {
        XCTAssertTrue(NativeModelCatalog.splash(root: root, memoryGB: 64).isEmpty)
    }

    /// Reads the checkout's real Splash pack when present; skips otherwise.
    func testSplashPackCatalogLoads() throws {
        guard let installation = EngineInstallations.newest(.splash, version: nil) else {
            throw XCTSkip("没有 Splash pack，跳过原生目录读取")
        }
        let rows = NativeModelCatalog.splash(
            root: installation.root.path, memoryGB: 64)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.engines == [.splash] })
        XCTAssertTrue(rows.allSatisfy { $0.minimumMemory <= 64 })
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    // MARK: MTPLX

    func testChipTierMatchesThePacksGenerations() {
        XCTAssertEqual(NativeModelCatalog.chipTier(for: "Apple M4 Pro"), "m4")
        XCTAssertEqual(NativeModelCatalog.chipTier(for: "Apple M2 Ultra"), "m2")
        XCTAssertEqual(NativeModelCatalog.chipTier(for: "Apple M5 Max"), "m5")
        XCTAssertEqual(NativeModelCatalog.chipTier(for: "Intel Core i9"), "intel")
        XCTAssertEqual(NativeModelCatalog.chipTier(for: "Apple Silicon"), "unknown")
    }

    /// Uses the checkout's MTPLX pack when it is present; a machine without the
    /// vendored packs simply skips, because the reader needs a real pack.
    func testMTPLXCatalogComesFromThePackPolicy() throws {
        guard let installation = EngineInstallations.newest(.mtplx, version: nil) else {
            throw XCTSkip("没有 MTPLX pack，跳过原生目录读取")
        }
        let rows = NativeModelCatalog.mtplx(
            root: installation.root.path,
            entrypoint: installation.entrypoint.path,
            machine: MachineProfile(
                chipName: "Apple M4 Pro", memoryGB: 64, freeDiskBytes: 0))
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.engines == [.mtplx] })
        XCTAssertTrue(rows.allSatisfy { $0.minimumMemory > 0 })
        XCTAssertTrue(rows.allSatisfy { $0.bytes > 0 })
        XCTAssertGreaterThan(rows[0].rank, rows[rows.count - 1].rank)
    }

    // MARK: Engines without a list

    func testGeneralEnginesNeverRecommend() {
        ModelRecommendations.invalidate()
        XCTAssertTrue(ModelRecommendations.list(for: .omlx).isEmpty)
        XCTAssertTrue(ModelRecommendations.list(for: .mlxServe).isEmpty)
    }
}
