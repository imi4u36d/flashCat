// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest

@testable import FlashCatKit

final class ControlEngineDocumentsTests: XCTestCase {

    // MARK: port

    func testPortPrefersBoundPortOverConfigured() {
        let input = ControlEngineDocumentInput(id: .omlx, configuredPort: 8123, boundPort: 9001)
        XCTAssertEqual(ControlEngineDocuments.port(input), 9001)
    }

    func testPortUsesConfiguredWhenNothingBound() {
        let input = ControlEngineDocumentInput(id: .omlx, configuredPort: 8123)
        XCTAssertEqual(ControlEngineDocuments.port(input), 8123)
    }

    func testPortFallsBackToEngineDefaultWhenUnset() {
        XCTAssertEqual(ControlEngineDocuments.port(ControlEngineDocumentInput(id: .omlx)), 8100)
        XCTAssertEqual(ControlEngineDocuments.port(ControlEngineDocumentInput(id: .splash)), 8000)
    }

    func testPortTreatsZeroAsUnset() {
        // 老版本把「没配置」写成 0；任何调用点都必须读到该引擎自己的默认端口。
        let input = ControlEngineDocumentInput(id: .omlx, configuredPort: 0)
        XCTAssertEqual(ControlEngineDocuments.port(input), 8100)
    }

    // MARK: model

    func testActiveEngineUsesSelectedModel() {
        let input = ControlEngineDocumentInput(
            id: .omlx, isActive: true,
            selectedModel: "qwen3-8b", lastModel: "llama3-7b")
        XCTAssertEqual(ControlEngineDocuments.model(input), "qwen3-8b")
    }

    func testActiveEngineFallsBackToLastModelWhenNothingSelected() {
        let input = ControlEngineDocumentInput(
            id: .omlx, isActive: true,
            selectedModel: "", lastModel: "llama3-7b")
        XCTAssertEqual(ControlEngineDocuments.model(input), "llama3-7b")
    }

    func testInactiveEngineIgnoresSelectedModel() {
        // 非 active 引擎显示自己上次用的模型，而不是当前选中模型。
        let input = ControlEngineDocumentInput(
            id: .omlx, isActive: false,
            selectedModel: "qwen3-8b", lastModel: "llama3-7b")
        XCTAssertEqual(ControlEngineDocuments.model(input), "llama3-7b")
    }

    func testModelIsEmptyWhenNothingKnown() {
        XCTAssertEqual(ControlEngineDocuments.model(ControlEngineDocumentInput(id: .omlx)), "")
    }

    // MARK: phase

    func testLoadingPhaseIsRunningAndOnDiskState() {
        let input = ControlEngineDocumentInput(id: .omlx, phase: .loading)
        let engine = ControlEngineDocuments.engine(input)
        XCTAssertEqual(engine.state, "loading")
        XCTAssertTrue(engine.isRunning)
    }

    func testEachPhaseMapsToItsRawValue() {
        for phase in ControlEnginePhase.allCases {
            let engine = ControlEngineDocuments.engine(ControlEngineDocumentInput(id: .splash, phase: phase))
            XCTAssertEqual(engine.state, phase.rawValue)
            XCTAssertEqual(engine.isRunning, ["starting", "loading", "ready", "stopping"].contains(phase.rawValue))
        }
    }

    // MARK: primary

    func testPrimaryPrefersActiveEngine() {
        let engines = ControlEngineDocuments.engines([
            ControlEngineDocumentInput(id: .splash),
            ControlEngineDocumentInput(id: .omlx, isActive: true),
        ])
        XCTAssertEqual(ControlEngineDocuments.primary(engines)?.id, EngineID.omlx.rawValue)
    }

    func testPrimaryFallsBackToFirstEngine() {
        let engines = ControlEngineDocuments.engines([
            ControlEngineDocumentInput(id: .splash),
            ControlEngineDocumentInput(id: .omlx),
        ])
        XCTAssertEqual(ControlEngineDocuments.primary(engines)?.id, EngineID.splash.rawValue)
    }

    func testPrimaryIsNilWithoutEngines() {
        XCTAssertNil(ControlEngineDocuments.primary([]))
    }

    // MARK: document fields

    func testEngineDocumentCarriesInstallationAndDescriptorFacts() {
        let input = ControlEngineDocumentInput(
            id: .omlx, installedVersion: "1.2.3",
            installedVersions: ["1.2.3", "1.1.0"], isActive: true,
            phase: .ready, configuredPort: 8123, boundPort: 8123,
            selectedModel: "qwen3-8b", stage: "加载权重",
            uptimeSeconds: 42, pid: 1234)
        let engine = ControlEngineDocuments.engine(input)
        XCTAssertEqual(engine.id, "omlx")
        XCTAssertEqual(engine.name, EngineID.omlx.displayName)
        XCTAssertEqual(engine.version, "1.2.3")
        XCTAssertEqual(engine.installedVersions, ["1.2.3", "1.1.0"])
        XCTAssertTrue(engine.isInstalled)
        XCTAssertEqual(engine.port, 8123)
        XCTAssertEqual(engine.model, "qwen3-8b")
        XCTAssertEqual(engine.stage, "加载权重")
        XCTAssertEqual(engine.uptimeSeconds, 42)
        XCTAssertEqual(engine.pid, 1234)
        XCTAssertEqual(engine.capabilities, EngineID.omlx.descriptor.capabilities.map(\.rawValue).sorted())
        XCTAssertFalse(engine.capabilities.isEmpty)
    }

    func testUninstalledEngineUsesPlaceholderVersion() {
        let engine = ControlEngineDocuments.engine(ControlEngineDocumentInput(id: .mlxServe))
        XCTAssertEqual(engine.version, "—")
        XCTAssertFalse(engine.isInstalled)
        XCTAssertEqual(engine.installedVersions, [])
    }

    func testEnginesPreserveInputOrder() {
        let inputs = EngineCatalog.allIDs.map { ControlEngineDocumentInput(id: $0) }
        let engines = ControlEngineDocuments.engines(inputs)
        XCTAssertEqual(engines.map(\.id), EngineCatalog.allIDs.map(\.rawValue))
    }
}
