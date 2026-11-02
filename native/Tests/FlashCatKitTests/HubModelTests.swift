import XCTest
@testable import FlashCatKit

/// Hub repository classification and the GGUF variant naming Splash resolves.
/// The variant rule is copied from the engine's `install/upstream.py`, so these
/// tests pin the copy against the shapes real repositories publish.
final class HubModelTests: XCTestCase {
    // MARK: Kind

    func testMTPLXWinsOverItsOwnMLXTag() {
        // Youssofal's packs carry both `mtplx` and `mlx` tags; the runtime
        // snapshot is what makes them MTPLX-only.
        let model = HubModel(id: "Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed",
                             libraryName: "mtplx",
                             tags: ["mtplx", "safetensors", "mlx"],
                             paths: ["config.json", "model-00001-of-00004.safetensors", "mtp.safetensors"])
        XCTAssertEqual(model.kind, .mtplx)
    }

    func testMTPTFilesAloneIdentifyAnMTPLXPack() {
        let model = HubModel(id: "someone/whatever",
                             libraryName: "mlx",
                             tags: ["mlx"],
                             paths: ["config.json", "mtplx_runtime.json"])
        XCTAssertEqual(model.kind, .mtplx)
    }

    func testRootGGUFMakesARepositorySplashOnly() {
        let model = HubModel(id: "unsloth/Qwen3.5-4B-GGUF",
                             libraryName: "transformers",
                             tags: ["gguf", "unsloth"],
                             paths: ["config.json", "Qwen3.5-4B-Q4_K_M.gguf"])
        XCTAssertEqual(model.kind, .gguf)
    }

    func testSplitGGUFFoldersCountAsGGUFWithoutRootGGUFs() {
        // ISTA-DASLab publishes each quant in its own folder and nothing at the
        // root, so the folder names are the only evidence.
        let model = HubModel(id: "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF",
                             libraryName: "gguf",
                             paths: ["README.md",
                                     "Q2_0/Qwen3.8-Flash-Next-GSQ-RCO-Q2_0-00001-of-00002.gguf",
                                     "Q2_0/Qwen3.8-Flash-Next-GSQ-RCO-Q2_0-00002-of-00002.gguf"])
        XCTAssertEqual(model.kind, .gguf)
    }

    func testMLXLibraryName() {
        let model = HubModel(id: "mlx-community/Qwen3.8-27B-4bit",
                             libraryName: "mlx",
                             tags: ["mlx", "safetensors"],
                             paths: ["config.json", "model-00001-of-00003.safetensors"])
        XCTAssertEqual(model.kind, .mlx)
    }

    func testUnmarkedWeightsAreNotPromised() {
        let model = HubModel(id: "someone/Qwen3.8-27B-bf16",
                             libraryName: "transformers",
                             tags: ["safetensors"],
                             paths: ["config.json", "model.safetensors"])
        XCTAssertEqual(model.kind, .unmarked)
    }

    func testONNXIsNotOffered() {
        let model = HubModel(id: "someone/model-onnx",
                             libraryName: "onnx",
                             tags: ["onnx"],
                             paths: ["model.onnx", "config.json"])
        XCTAssertEqual(model.kind, .unknown)
    }

    // MARK: GGUF variants

    func testRootGGUFVariantsDropTheSharedPrefix() {
        let model = HubModel(id: "unsloth/Qwen3.5-4B-GGUF",
                             paths: ["Qwen3.5-4B-BF16.gguf",
                                     "Qwen3.5-4B-Q4_K_M.gguf",
                                     "Qwen3.5-4B-Q8_0.gguf",
                                     "README.md"],
                             sizes: ["Qwen3.5-4B-BF16.gguf": 8_424_393_632,
                                     "Qwen3.5-4B-Q4_K_M.gguf": 2_665_878_240,
                                     "Qwen3.5-4B-Q8_0.gguf": 4_541_740_288])
        let variants = model.ggufVariants
        XCTAssertEqual(variants.map(\.name), ["BF16", "Q4_K_M", "Q8_0"])
        XCTAssertEqual(variants[1].bytes, 2_665_878_240)
        XCTAssertEqual(variants[1].files, ["Qwen3.5-4B-Q4_K_M.gguf"])
    }

    func testVisionProjectorIsNotAVariant() {
        let model = HubModel(id: "someone/vision-GGUF",
                             paths: ["Model-Q4_K_M.gguf", "Model-Q8_0.gguf", "mmproj-Model-BF16.gguf"],
                             sizes: ["Model-Q4_K_M.gguf": 100, "Model-Q8_0.gguf": 200])
        XCTAssertEqual(model.ggufVariants.map(\.name), ["Q4_K_M", "Q8_0"])
    }

    func testSingleRootGGUFNeedsNoVariant() {
        // Splash takes `owner/repo` alone when the repository holds one target.
        let model = HubModel(id: "someone/one-GGUF",
                             paths: ["Model-Q4_K_M.gguf"],
                             sizes: ["Model-Q4_K_M.gguf": 1234])
        XCTAssertEqual(model.ggufVariants, [GGUFVariant(name: nil, bytes: 1234, files: ["Model-Q4_K_M.gguf"])])
    }

    func testSplitGGUFVariantsAreNamedAfterTheirFolder() {
        let model = HubModel(id: "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF",
                             paths: ["Q2_0/Qwen3.8-Flash-Next-GSQ-RCO-Q2_0-00001-of-00002.gguf",
                                     "Q2_0/Qwen3.8-Flash-Next-GSQ-RCO-Q2_0-00002-of-00002.gguf",
                                     "IQ3_XS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XS-00001-of-00002.gguf",
                                     "IQ3_XS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XS-00002-of-00002.gguf"],
                             sizes: ["Q2_0/Qwen3.8-Flash-Next-GSQ-RCO-Q2_0-00001-of-00002.gguf": 30,
                                     "Q2_0/Qwen3.8-Flash-Next-GSQ-RCO-Q2_0-00002-of-00002.gguf": 12,
                                     "IQ3_XS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XS-00001-of-00002.gguf": 40,
                                     "IQ3_XS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XS-00002-of-00002.gguf": 4])
        let variants = model.ggufVariants
        XCTAssertEqual(variants.map(\.name), ["IQ3_XS", "Q2_0"])
        XCTAssertEqual(variants.map(\.bytes), [44, 42])
    }

    func testIncompleteSplitIsNotOffered() {
        let model = HubModel(id: "someone/broken-GGUF",
                             paths: ["Q4_K_M/Model-Q4_K_M-00001-of-00003.gguf"])
        XCTAssertTrue(model.ggufVariants.isEmpty)
    }

    func testWeightBytesFollowTheChosenVariant() {
        let model = HubModel(id: "someone/multi-GGUF",
                             paths: ["Model-Q4_K_M.gguf", "Model-Q8_0.gguf"],
                             sizes: ["Model-Q4_K_M.gguf": 100, "Model-Q8_0.gguf": 200])
        XCTAssertEqual(model.weightBytes(ggufVariant: "Q4_K_M"), 100)
        XCTAssertEqual(model.weightBytes(ggufVariant: nil), 200)
    }

    func testSafetensorsSnapshotsCountEveryShard() {
        let model = HubModel(id: "mlx-community/Qwen3.8-27B-4bit",
                             libraryName: "mlx",
                             paths: ["config.json", "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"],
                             sizes: ["model-00001-of-00002.safetensors": 700, "model-00002-of-00002.safetensors": 300])
        XCTAssertEqual(model.weightBytes(), 1000)
    }

    func testMemoryEstimateAddsAFifth() {
        XCTAssertEqual(HubModelLayout.estimatedMemoryGB(bytes: 0), 0)
        // 10 GiB of weights → 12 GiB floor.
        XCTAssertEqual(HubModelLayout.estimatedMemoryGB(bytes: 10 * 1_073_741_824), 12)
        // Anything non-empty still asks for a whole GiB.
        XCTAssertEqual(HubModelLayout.estimatedMemoryGB(bytes: 1), 1)
    }

    // MARK: Decoding

    func testSearchPayloadDecodesAndDropsUnreadableRepositories() throws {
        let payload = """
        [
          {"id": "unsloth/Qwen3.5-4B-GGUF", "downloads": 1323712, "gated": false,
           "library_name": "transformers", "tags": ["gguf"],
           "siblings": [{"rfilename": "Qwen3.5-4B-Q4_K_M.gguf", "size": 2665878240}]},
          {"id": "private/secret", "gated": "manual", "siblings": []},
          {"id": "onnx/model", "library_name": "onnx", "siblings": [{"rfilename": "model.onnx"}]}
        ]
        """
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: Any]])
        let models = raw.compactMap(HubSearchClient.model(from:))
        // Decoding keeps what it can read; `search` is what drops repositories
        // whose layout no engine serves.
        XCTAssertEqual(models.map(\.id), ["unsloth/Qwen3.5-4B-GGUF", "onnx/model"])
        let offered = models.filter { $0.kind != .unknown }
        XCTAssertEqual(offered.map(\.id), ["unsloth/Qwen3.5-4B-GGUF"])
        XCTAssertEqual(offered[0].downloads, 1_323_712)
        XCTAssertEqual(offered[0].sizes["Qwen3.5-4B-Q4_K_M.gguf"], 2_665_878_240)
        XCTAssertEqual(offered[0].kind, .gguf)
    }

    func testGatedBooleanTrueIsDropped() throws {
        let payload = """
        [{"id": "someone/gated", "gated": true, "siblings": []}]
        """
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: Any]])
        XCTAssertTrue(raw.compactMap(HubSearchClient.model(from:)).isEmpty)
    }
}
