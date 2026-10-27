import XCTest
@testable import FlashCatKit

final class ModelSelectionTests: XCTestCase {

    private let packModels = ["Jundot--Qwen3.8-27B-oQ4e-mtp",
                              "Jundot--Qwen3.8-Flash-Next-oQ4e-mtp"]
    /// What oMLX publishes for Splash: `omlx/<slug>-<sha1(model_id)[:8]>`.
    private let splashStaging = "omlx/Qwen3.8-27B-oQ4e-mtp-e5133ef4"

    func testRemembersTheEngineOwnModel() {
        XCTAssertEqual(EngineModelSelection.resolve(saved: packModels[1], available: packModels),
                       packModels[1])
    }

    func testSplashStagingIdIsNotHandedToAPackEngine() {
        // Picking the Splash package while oMLX is active used to be persisted
        // and then 404 on every request: the engine has no such model.
        XCTAssertEqual(EngineModelSelection.resolve(saved: splashStaging, available: packModels),
                       packModels[0])
        XCTAssertFalse(EngineModelSelection.isServable(splashStaging, available: packModels))
    }

    func testSplashKeepsItsPackageIds() {
        let splashModels = [splashStaging, "Jundot/Qwen3.8-27B-oQ4e-mtp"]
        XCTAssertEqual(EngineModelSelection.resolve(saved: splashStaging, available: splashModels),
                       splashStaging)
        XCTAssertTrue(EngineModelSelection.isServable(splashStaging, available: splashModels))
    }

    func testMissingOrBlankMemoryFallsBackToTheFirstModel() {
        XCTAssertEqual(EngineModelSelection.resolve(saved: nil, available: packModels), packModels[0])
        XCTAssertEqual(EngineModelSelection.resolve(saved: "", available: packModels), packModels[0])
        XCTAssertEqual(EngineModelSelection.resolve(saved: "   ", available: packModels), packModels[0])
        XCTAssertEqual(EngineModelSelection.resolve(saved: " \(packModels[0]) ", available: packModels),
                       packModels[0])
    }

    func testEmptyEngineSelectsNothingAndRejectsNothing() {
        XCTAssertNil(EngineModelSelection.resolve(saved: packModels[0], available: []))
        XCTAssertNil(EngineModelSelection.resolve(saved: nil, available: []))
        // No models yet (engine not synced): the typed id is kept, the launch
        // page decides.
        XCTAssertTrue(EngineModelSelection.isServable("anything", available: []))
    }
}

final class EngineRoutesTests: XCTestCase {

    func testSettingsRouteLivesUnderTheAdminPrefix() {
        // oMLX mounts its management API under /admin; the plain /api form 404s
        // even for a model the engine has loaded, so MTP/DFlash never applied.
        XCTAssertEqual(EngineRoutes.modelSettings("Jundot--Qwen3.8-27B-oQ4e-mtp"),
                       "/admin/api/models/Jundot--Qwen3.8-27B-oQ4e-mtp/settings")
        XCTAssertFalse(EngineRoutes.modelSettings("m").hasPrefix("/api/"))
    }

    func testLoadAndUnloadStayOnTheOpenAISurface() {
        XCTAssertEqual(EngineRoutes.load("Jundot--Qwen3.8-27B-oQ4e-mtp"),
                       "/v1/models/Jundot--Qwen3.8-27B-oQ4e-mtp/load")
        XCTAssertEqual(EngineRoutes.unload("Jundot--Qwen3.8-27B-oQ4e-mtp"),
                       "/v1/models/Jundot--Qwen3.8-27B-oQ4e-mtp/unload")
    }

    func testSlashInAHuggingFaceIdIsEscapedAsOneSegment() {
        XCTAssertEqual(EngineRoutes.modelSettings("ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF"),
                       "/admin/api/models/ISTA-DASLab%2FQwen3.8-Flash-Next-GSQ-RCO-GGUF/settings")
        // The Splash staging id an oMLX package carries survives unchanged too.
        XCTAssertEqual(EngineRoutes.modelSettings("omlx/Qwen3.8-27B-oQ4e-mtp-e5133ef4"),
                       "/admin/api/models/omlx%2FQwen3.8-27B-oQ4e-mtp-e5133ef4/settings")
    }
}
