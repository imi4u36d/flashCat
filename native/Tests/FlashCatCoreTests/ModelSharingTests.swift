// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCatCore

final class ModelSharingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-sharing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ModelSharing.directoryOverride = root.path
        ModelSharing.tableFileOverride = root.appendingPathComponent("shares.json").path
        ModelSharing.invalidateCaches()
    }

    override func tearDownWithError() throws {
        ModelSharing.directoryOverride = nil
        ModelSharing.tableFileOverride = nil
        ModelSharing.invalidateCaches()
        try? FileManager.default.removeItem(at: root)
    }

    func testTableAndVisibilityReadFromDisk() throws {
        let table = #"{"owner/repo":["splash","omlx"]}"#
        try Data(table.utf8).write(to: URL(fileURLWithPath: ModelSharing.tableFileOverride!))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("owner--repo", isDirectory: true),
            withIntermediateDirectories: true)
        ModelSharing.invalidateCaches()

        XCTAssertEqual(ModelSharing.engines(for: "owner/repo"), [.splash, .omlx])
        XCTAssertTrue(ModelSharing.visible("owner--repo", engine: .splash))
        XCTAssertFalse(ModelSharing.visible("owner--repo", engine: .mtplx))
        XCTAssertTrue(ModelSharing.isShared("owner--repo"))
        XCTAssertEqual(ModelSharing.downloadTargets(lead: .omlx).first, .omlx)
        XCTAssertEqual(ModelSharing.canonical("owner/repo:Q4_K_M"), "owner/repo")
        XCTAssertEqual(ModelSharing.repo(forFolder: "owner--repo"), "owner/repo")
    }

    func testScanIgnoresIncompleteAndNonWeightsDirectories() throws {
        func makeDir(_ name: String, config: Bool, weights: Bool) throws {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if config {
                try Data(#"{"num_hidden_layers":2}"#.utf8)
                    .write(to: directory.appendingPathComponent("config.json"))
            }
            if weights {
                try Data().write(to: directory.appendingPathComponent("model.safetensors"))
                try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
            }
        }
        try makeDir("owner--good", config: true, weights: true)
        try makeDir("owner--partial", config: true, weights: true)
        try FileManager.default.createFile(
            atPath: root.appendingPathComponent("owner--partial.flashcat-incomplete").path,
            contents: nil)
        try makeDir("owner--empty", config: false, weights: false)

        ModelSharing.invalidateCaches()
        let found = ModelSharing.scan()

        XCTAssertEqual(found.map(\.id), ["owner/good"])
    }

    func testPathUsesInjectedDirectory() {
        XCTAssertEqual(
            ModelSharing.path(for: "owner/repo"),
            root.path + "/owner--repo")
    }
}
