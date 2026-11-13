import XCTest
@testable import FlashCat

final class LocalEngineModelsTests: XCTestCase {
    func testScanDetectsH3VideoWithoutModelIndex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-local-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let model = root.appendingPathComponent("MiniMax-H3-FL2VA-MLX-Serve-8bit")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try #"{"model_type":"minimax_h3","partition":"fl2va"}"#
            .write(to: model.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try #"{}"#.write(to: model.appendingPathComponent("tokenizer_config.json"),
                         atomically: true, encoding: .utf8)
        try Data().write(to: model.appendingPathComponent("video_vae.safetensors"))

        let models = LocalEngineModels.scan(engine: .mlxServe, directory: root.path)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.capabilities, ["video"])
        XCTAssertTrue(models.first?.supportsVideo == true)
    }

    func testScanStillDetectsImagePipeline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-local-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let model = root.appendingPathComponent("Qwen-Image-Test")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try #"{"_class_name":"QwenImage21Pipeline"}"#
            .write(to: model.appendingPathComponent("model_index.json"),
                   atomically: true, encoding: .utf8)
        try #"{}"#.write(to: model.appendingPathComponent("tokenizer_config.json"),
                         atomically: true, encoding: .utf8)

        let models = LocalEngineModels.scan(engine: .mlxServe, directory: root.path)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.capabilities, ["image"])
        XCTAssertTrue(models.first?.supportsImage == true)
    }


    func testScanDetectsVisionFromConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-local-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // 目录名故意不带 VL，确保认出来的是 config.json 里的视觉塔。
        let model = root.appendingPathComponent("PlainFolderName")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try #"{"model_type":"qwen3_5","architectures":["Qwen3_5ForConditionalGeneration"],"vision_config":{"depth":27}}"#
            .write(to: model.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try #"{}"#.write(to: model.appendingPathComponent("tokenizer_config.json"),
                         atomically: true, encoding: .utf8)

        let models = LocalEngineModels.scan(engine: .mlxServe, directory: root.path)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.capabilities, ["chat", "vision"])
        XCTAssertTrue(models.first?.supportsVision == true)
        XCTAssertTrue(models.first?.supportsChat == true)
    }

    func testScanDetectsVisionFromMMProj() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-local-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let model = root.appendingPathComponent("PlainFolderName")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data().write(to: model.appendingPathComponent("weights.gguf"))
        try Data().write(to: model.appendingPathComponent("mmproj-Qwen3.8-Flash-Next-BF16.gguf"))

        let models = LocalEngineModels.scan(engine: .mlxServe, directory: root.path)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.capabilities, ["chat", "vision"])
        XCTAssertTrue(models.first?.supportsVision == true)
    }


    func testScanDetectsVisionFromArchitecture() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-local-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // 有的转换包不写 vision_config，只剩架构名里的 VL。
        let model = root.appendingPathComponent("PlainFolderName")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try #"{"model_type":"qwen2","architectures":["Qwen2VLForConditionalGeneration"]}"#
            .write(to: model.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try #"{}"#.write(to: model.appendingPathComponent("tokenizer_config.json"),
                         atomically: true, encoding: .utf8)

        let models = LocalEngineModels.scan(engine: .mlxServe, directory: root.path)
        XCTAssertEqual(models.first?.capabilities, ["chat", "vision"])
        XCTAssertTrue(models.first?.supportsVision == true)
    }

    func testScanLeavesPlainChatModelWithoutCapabilities() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-local-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let model = root.appendingPathComponent("PlainFolderName")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try #"{"model_type":"qwen3_5","architectures":["Qwen3_5ForCausalLM"]}"#
            .write(to: model.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try #"{}"#.write(to: model.appendingPathComponent("tokenizer_config.json"),
                         atomically: true, encoding: .utf8)

        let models = LocalEngineModels.scan(engine: .mlxServe, directory: root.path)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.capabilities, [])
        XCTAssertFalse(models.first?.supportsVision == true)
        XCTAssertTrue(models.first?.supportsChat == true)
    }

    /// 真机目录核查：普通测试跳过，只有显式给出本机模型目录时才跑。
    func testRealMlxServeDirectoryWhenProvided() throws {
        guard let directory = ProcessInfo.processInfo.environment["FLASHCAT_REAL_MLX_MODELS"] else {
            throw XCTSkip("未设置 FLASHCAT_REAL_MLX_MODELS")
        }
        let models = LocalEngineModels.scan(engine: .mlxServe, directory: directory)
        let h3 = try XCTUnwrap(models.first { $0.id.contains("MiniMax-H3") })
        XCTAssertTrue(h3.supportsVideo, "H3 应该被识别为视频模型：\(h3.capabilities)")
        let image = try XCTUnwrap(models.first { $0.id.contains("Qwen-Image") })
        XCTAssertTrue(image.supportsImage, "Qwen-Image 应该被识别为图像模型：\(image.capabilities)")
    }
}
