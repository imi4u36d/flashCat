import XCTest
import FlashCatKit
@testable import FlashCat

/// 分辨率预设与固定步数的判定。引擎把这两件事都藏在二进制里：预设表按
/// `meta.architecture` 选，固定步数要看本地 `model_index.json` 的
/// `sample_sigmas`，这里把两条规则钉住。
final class ImageModelProfileTests: XCTestCase {
    private func model(_ id: String,
                       architecture: String? = nil,
                       path: String? = nil) -> EngineModel {
        EngineModel(id: id,
                    path: path,
                    architecture: architecture,
                    capabilities: ["image"],
                    engine: .mlxServe)
    }

    func testFamiliesComeFromArchitectureFirst() {
        XCTAssertEqual(ImageModelProfile.family(
            for: model("ddalcu/Qwen-Image-2.1-Turbo-MLX-Serve-8bit",
                       architecture: "qwen_image21")), .qwen)
        XCTAssertEqual(ImageModelProfile.family(
            for: model("black-forest-labs/FLUX.2-klein", architecture: "flux2")), .flux)
        XCTAssertEqual(ImageModelProfile.family(
            for: model("krea/Krea-Image", architecture: "krea")), .krea)
        XCTAssertEqual(ImageModelProfile.family(
            for: model("whatever/mage-flow", architecture: "mage_flow")), .mage)
        XCTAssertEqual(ImageModelProfile.family(
            for: model("whatever/moss-image", architecture: "moss_image")), .moss)
    }

    func testFamilyFallsBackToModelID() {
        XCTAssertEqual(ImageModelProfile.family(
            for: model("owner/Qwen-Image-2.1-MLX-Serve-8bit")), .qwen)
        XCTAssertEqual(ImageModelProfile.family(
            for: model("owner/flux2-klein-9b-base-q4")), .flux)
        XCTAssertEqual(ImageModelProfile.family(
            for: model("owner/some-chat-model", architecture: "llama")), .generic)
    }

    func testPresetTablesMatchEngineFamilies() {
        XCTAssertEqual(ImageModelProfile.fluxPresets.count, 9)
        XCTAssertEqual(ImageModelProfile.kreaPresets.count, 7)
        XCTAssertEqual(ImageModelProfile.magePresets.count, 11)
        XCTAssertEqual(ImageModelProfile.qwenPresets.count, 7)
        XCTAssertEqual(ImageModelProfile.mossPresets.count, 10)
        XCTAssertEqual(ImageModelProfile(model: model("x", architecture: "flux2")).presets,
                       ImageModelProfile.fluxPresets)
        XCTAssertEqual(ImageModelProfile(model: model("x", architecture: "qwen_image")).presets,
                       ImageModelProfile.qwenPresets)
    }

    func testMageIsFixedAtFourStepsAndRejectsCustomCanvas() {
        let profile = ImageModelProfile(model: model("x/mage-flow", architecture: "mage_flow"))
        XCTAssertEqual(profile.fixedSteps, 4)
        XCTAssertFalse(profile.allowsCustomCanvas)
    }

    func testSampleSigmasFixDistilledStepCount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sigmas = [1.0, 0.978453, 0.95418, 0.926626, 0.89508, 0.845148, 0.704534, 0.414568]
        let data = try JSONSerialization.data(withJSONObject: ["sample_sigmas": sigmas])
        try data.write(to: directory.appendingPathComponent("model_index.json"))

        let profile = ImageModelProfile(model: model("owner/turbo",
                                                     architecture: "qwen_image21",
                                                     path: directory.path))
        XCTAssertEqual(profile.fixedSteps, 8)
        XCTAssertTrue(profile.allowsCustomCanvas)
    }

    func testLocalScanKeepsArchitectureAndPathForTurboModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-scan-\(UUID().uuidString)", isDirectory: true)
        let modelDirectory = root
            .appendingPathComponent("owner", isDirectory: true)
            .appendingPathComponent("Qwen-Image-2.1-Turbo-MLX-Serve-8bit", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let config = ["model_type": "qwen_image21"]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: modelDirectory.appendingPathComponent("config.json"))
        let sigmas = [1.0, 0.978453, 0.95418, 0.926626, 0.89508, 0.845148, 0.704534, 0.414568]
        let index = ["_class_name": "QwenImage21Pipeline", "sample_sigmas": sigmas] as [String: Any]
        try JSONSerialization.data(withJSONObject: index)
            .write(to: modelDirectory.appendingPathComponent("model_index.json"))

        let scanned = LocalEngineModels.scan(engine: .mlxServe, directory: root.path)
        let model = try XCTUnwrap(scanned.first)
        XCTAssertEqual(model.id, "owner/Qwen-Image-2.1-Turbo-MLX-Serve-8bit")
        XCTAssertEqual(model.architecture, "qwen_image21")
        XCTAssertEqual(model.capabilities, ["image"])

        let profile = ImageModelProfile(model: model)
        XCTAssertEqual(profile.family, .qwen)
        XCTAssertEqual(profile.fixedSteps, 8)
        XCTAssertEqual(profile.presets.count, 7)
    }

    func testCustomCanvasBounds() {
        let profile = ImageModelProfile(model: model("x", architecture: "qwen_image"))
        XCTAssertTrue(profile.isValidCanvas(width: 256, height: 2048))
        XCTAssertFalse(profile.isValidCanvas(width: 255, height: 1024))
        XCTAssertFalse(profile.isValidCanvas(width: 1024, height: 2050))
        XCTAssertEqual(profile.clampedCanvas(width: 100, height: 3000).width, 256)
        XCTAssertEqual(profile.clampedCanvas(width: 100, height: 3000).height, 2048)

        let flux = ImageModelProfile(model: model("x", architecture: "flux2"))
        XCTAssertEqual(flux.maximumSide, 1536)
        XCTAssertEqual(flux.alignment, 32)
    }
}
