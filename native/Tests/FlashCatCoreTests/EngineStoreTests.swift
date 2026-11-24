// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCatCore

@MainActor
final class EngineStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-engine-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPortAndTuningSurviveReload() {
        let path = directory.path
        let store = EngineStore(directory: path)
        store.update(.omlx) { configuration in
            configuration.port = 8123
            configuration.enabled = false
        }
        store.setDefaultEngine(.mtplx)

        let reloaded = EngineStore(directory: path)
        let configuration = reloaded.configuration(for: .omlx)
        XCTAssertEqual(configuration.port, 8123)
        XCTAssertFalse(configuration.enabled)
        XCTAssertEqual(reloaded.defaultEngineID, .mtplx)
    }

    func testUndecodableEntriesArePreserved() throws {
        let path = directory.path
        let file = directory.appendingPathComponent("engines.json")
        try Data(#"{"mtplx":{"port":"not-a-number"},"omlx":{"port":8101}}"#.utf8)
            .write(to: file)

        let store = EngineStore(directory: path)
        XCTAssertEqual(store.configuration(for: .omlx).port, 8101)

        store.update(.splash) { $0.port = 8001 }
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"not-a-number\""), "读不懂的条目应原样写回")
        XCTAssertTrue(raw.contains("8001"))
    }

    func testConfigurationFieldsRoundTrip() {
        let store = EngineStore(directory: directory.path)
        store.update(.mlxServe) { configuration in
            configuration.version = "1.2.3"
            configuration.lastModel = "owner/repo"
            configuration.autoStart = true
            configuration.draftAssignments = ["owner/repo": "owner/draft"]
        }

        let reloaded = EngineStore(directory: directory.path).configuration(for: .mlxServe)
        XCTAssertEqual(reloaded.version, "1.2.3")
        XCTAssertEqual(reloaded.lastModel, "owner/repo")
        XCTAssertTrue(reloaded.autoStart)
        XCTAssertEqual(reloaded.draftAssignments?["owner/repo"], "owner/draft")
    }

    func testDefaultActiveAndDraftAssignments() {
        let store = EngineStore(directory: directory.path)
        store.rememberActive(.mlxServe)
        XCTAssertEqual(store.defaultEngineID, .mlxServe)

        store.setDraftAssignment("owner/draft", engine: .splash, model: "owner/main")
        XCTAssertEqual(
            store.draftAssignment(for: .splash, model: "owner/main"), "owner/draft")
        store.setDraftAssignment(nil, engine: .splash, model: "owner/main")
        XCTAssertNil(store.draftAssignment(for: .splash, model: "owner/main"))

        let reloaded = EngineStore(directory: directory.path)
        XCTAssertEqual(reloaded.defaultEngineID, .mlxServe)
    }

    func testTuningRoundTrip() {
        let path = directory.path
        let store = EngineStore(directory: path)
        var tuning = store.tuning(for: .splash)
        tuning.mtp = false
        store.setTuning(tuning, for: .splash)

        XCTAssertEqual(EngineStore(directory: path).tuning(for: .splash).mtp, false)
    }
}
