// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest

@testable import FlashCat
@testable import FlashCatKit

final class HubSourceTests: XCTestCase {
    // MARK: Mirror endpoint

    func testEmptyEndpointMeansOfficial() {
        XCTAssertEqual(HFEndpoint.normalized(""), "")
        XCTAssertEqual(HFEndpoint.normalized("   "), "")
    }

    func testHostOnlyGetsHTTPS() {
        XCTAssertEqual(HFEndpoint.normalized("hf-mirror.com"), "https://hf-mirror.com")
        XCTAssertEqual(HFEndpoint.normalized(" hf-mirror.com/ "), "https://hf-mirror.com")
    }

    func testExplicitSchemeSurvives() {
        XCTAssertEqual(HFEndpoint.normalized("http://127.0.0.1:8080/"), "http://127.0.0.1:8080")
        XCTAssertEqual(
            HFEndpoint.normalized("https://huggingface.co///"),
            "https://huggingface.co")
    }

    func testInvalidEndpointIsRejected() {
        XCTAssertNil(HFEndpoint.normalized("ftp://hf-mirror.com"))
        XCTAssertNil(HFEndpoint.normalized("https://"))
        XCTAssertNil(HFEndpoint.normalized("not a host"))
    }

    func testDefaultSourceIsHuggingFace() {
        UserDefaults.standard.removeObject(forKey: "hubSource")
        XCTAssertEqual(HubSource.stored, .huggingFace)
    }

    // MARK: HF-Mirror source

    func testHFMirrorIsAHuggingFaceCompatibleSource() {
        XCTAssertEqual(HubSource(rawValue: "hf-mirror"), .hfMirror)
        XCTAssertEqual(HubSource.hfMirror.displayName, "HF-Mirror")
        XCTAssertEqual(HubSource.hfMirror.endpoint, "https://hf-mirror.com")
        XCTAssertTrue(HubSource.hfMirror.isHuggingFaceCompatible)
    }

    /// 自定义镜像地址只改官方那一档；显式选 HF-Mirror 时固定走镜像站。
    func testExplicitMirrorIsNotOverriddenByCustomEndpoint() {
        UserDefaults.standard.set("https://mirror.example.com", forKey: "hfEndpoint")
        defer { UserDefaults.standard.removeObject(forKey: "hfEndpoint") }

        XCTAssertEqual(HubSource.huggingFace.endpoint, "https://mirror.example.com")
        XCTAssertEqual(HubSource.hfMirror.endpoint, "https://hf-mirror.com")
    }

    func testDownloaderEnvironmentFollowsSource() {
        let mirror = ModelInstaller.environment(
            pythonRoot: "/tmp/flashcat-test", cache: "", source: .hfMirror)
        XCTAssertEqual(mirror["HF_ENDPOINT"], "https://hf-mirror.com")

        let official = ModelInstaller.environment(
            pythonRoot: "/tmp/flashcat-test", cache: "", source: .huggingFace)
        XCTAssertEqual(official["HF_ENDPOINT"], "https://huggingface.co")

        // ModelScope 走自己的协议，不能把 HF 端点带过去。
        let scope = ModelInstaller.environment(
            pythonRoot: "/tmp/flashcat-test", cache: "", source: .modelScope)
        XCTAssertNil(scope["HF_ENDPOINT"])
    }

    /// 引擎目录里的下载没有来源参数：选了 HF-Mirror 就跟着走，选了
    /// ModelScope 则退回 Hugging Face 端点那条通道。
    func testEngineDownloadsFollowStoredSource() {
        defer { UserDefaults.standard.removeObject(forKey: "hubSource") }

        UserDefaults.standard.set(HubSource.hfMirror.rawValue, forKey: "hubSource")
        XCTAssertEqual(HubSource.downloadSource, .hfMirror)

        UserDefaults.standard.set(HubSource.modelScope.rawValue, forKey: "hubSource")
        XCTAssertEqual(HubSource.downloadSource, .huggingFace)
    }

    // MARK: Quant download selection

    func testSingleRootQuantKeepsProjector() {
        let model = HubModel(
            id: "unsloth/Qwen3.5-4B-GGUF",
            tags: ["gguf"],
            files: [
                HubFile(name: "Qwen3.5-4B-Q4_K_M.gguf", size: 2_500),
                HubFile(name: "mmproj-Qwen3.5-4B-f16.gguf", size: 600),
                HubFile(name: "README.md", size: 10),
            ])
        let variants = model.ggufVariants
        XCTAssertEqual(variants.count, 1)
        let includes = model.downloadIncludes(for: variants[0])
        XCTAssertEqual(
            includes,
            ["Qwen3.5-4B-Q4_K_M.gguf", "mmproj-Qwen3.5-4B-f16.gguf"])
    }

    func testChoosingOneRootQuantLeavesTheOtherBehind() {
        let model = HubModel(
            id: "unsloth/Qwen3.5-4B-GGUF",
            tags: ["gguf"],
            files: [
                HubFile(name: "Model-Q4_K_M.gguf", size: 2_500),
                HubFile(name: "Model-Q8_0.gguf", size: 4_200),
                HubFile(name: "mmproj-Model-f16.gguf", size: 600),
            ])
        let variants = model.ggufVariants
        XCTAssertEqual(variants.count, 2)
        let small = try! XCTUnwrap(variants.min { $0.bytes < $1.bytes })
        XCTAssertEqual(small.name, "Q4_K_M")
        XCTAssertEqual(
            model.downloadIncludes(for: small),
            ["Model-Q4_K_M.gguf", "mmproj-Model-f16.gguf"])
    }

    func testSplitQuantOnlyBringsItsOwnFolder() {
        let model = HubModel(
            id: "ISTA-DASLab/Qwen3.8-Flash-Next-GGUF",
            tags: ["gguf"],
            files: [
                HubFile(name: "Q2_0/Model-Q2_0-00001-of-00002.gguf", size: 1_000),
                HubFile(name: "Q2_0/Model-Q2_0-00002-of-00002.gguf", size: 1_000),
                HubFile(name: "Q2_0/mmproj-Q2_0-f16.gguf", size: 300),
                HubFile(name: "Q4_0/Model-Q4_0-00001-of-00002.gguf", size: 2_000),
                HubFile(name: "Q4_0/Model-Q4_0-00002-of-00002.gguf", size: 2_000),
                HubFile(name: "Q4_0/mmproj-Q4_0-f16.gguf", size: 300),
            ])
        let variants = model.ggufVariants
        let q2 = try! XCTUnwrap(variants.first { $0.name == "Q2_0" })
        XCTAssertEqual(
            model.downloadIncludes(for: q2),
            [
                "Q2_0/Model-Q2_0-00001-of-00002.gguf",
                "Q2_0/Model-Q2_0-00002-of-00002.gguf",
                "Q2_0/mmproj-Q2_0-f16.gguf",
            ])
    }

    func testNilVariantDownloadsWholeRepository() {
        let model = HubModel(
            id: "mlx-community/Qwen3.8-27B-4bit",
            tags: ["mlx"],
            files: [HubFile(name: "config.json", size: 10)])
        XCTAssertEqual(model.downloadIncludes(for: nil), [])
    }
}
