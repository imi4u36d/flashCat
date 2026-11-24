// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCatCore

/// 用临时 pack 目录验证下载计划：不碰真实引擎，也不发网络请求。
final class ModelInstallerPlanTests: XCTestCase {
    private var root: URL!
    private var packs: URL!
    private var support: URL!
    private var home: URL!
    private var previousEnvironment: [(key: String, value: String?)] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-plan-\(UUID().uuidString)", isDirectory: true)
        packs = root.appendingPathComponent("packs", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        for directory in [packs!, support!, home!] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        previousEnvironment = ["HOME", "FLASHCAT_SUPPORT_DIR", "FLASHCAT_ENGINE_PACKS_DIR"].map {
            ($0, ProcessInfo.processInfo.environment[$0])
        }
        setenv("HOME", home.path, 1)
        setenv("FLASHCAT_SUPPORT_DIR", support.path, 1)
        setenv("FLASHCAT_ENGINE_PACKS_DIR", packs.path, 1)
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

    func testSharedPlanUsesInstalledPythonPack() throws {
        try makePack(id: .omlx, entrypoint: "python/bin/python3")

        let plan = try ModelInstaller.sharedPlan(
            repo: "owner/repo", engines: [.omlx], cache: "/tmp/cache")

        XCTAssertTrue(plan.executable.hasSuffix("/python/bin/python3"))
        XCTAssertEqual(plan.engine, .omlx)
        XCTAssertEqual(plan.model, "owner/repo")
        XCTAssertTrue(plan.destination.contains("shared-models"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.executable))
    }

    func testSnapshotPlanUsesPackPython() throws {
        try makePack(id: .omlx, entrypoint: "python/bin/python3")

        let plan = try ModelInstaller.plan(
            engine: .omlx, model: "owner/repo", draftRepository: nil, cache: "/tmp/cache")

        XCTAssertEqual(plan.engine, .omlx)
        XCTAssertTrue(plan.executable.hasSuffix("/python/bin/python3"))
        XCTAssertTrue(plan.arguments.contains("owner/repo"))
    }

    func testSplashPlanUsesInstallScript() throws {
        try makePack(id: .splash, entrypoint: "python/bin/python3")
        let script = packs!.appendingPathComponent("splash/99.0.0/install/models.py")
        try FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: script)

        XCTAssertEqual(
            EngineInstallations.newest(.splash, version: nil)?.root.path,
            packs.path + "/splash/99.0.0")
        let plan = try ModelInstaller.plan(
            engine: .splash, model: "owner/repo", draftRepository: "owner/draft",
            cache: "/tmp/cache")

        XCTAssertTrue(plan.arguments.contains(script.path))
        XCTAssertTrue(plan.arguments.contains("--draft-model"))
        XCTAssertTrue(plan.arguments.contains("owner/draft"))
        XCTAssertNil(plan.incompleteMarker)
    }

    private func makePack(id: EngineID, entrypoint: String) throws {
        let root = packs!.appendingPathComponent("\(id.rawValue)/99.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = EngineManifest(
            id: id, name: id.rawValue, version: "99.0.0", kind: .bundled,
            entrypoint: entrypoint,
            launchProfiles: ["default": EngineLaunchProfile(args: ["--port", "{port}"])],
            health: EngineHealthSpec(path: "/health"),
            defaultPort: id.defaultPort,
            modelSwitch: .restart,
            capabilities: [.chat])
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: root.appendingPathComponent("manifest.json"))

        let executable = root.appendingPathComponent(entrypoint)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        // Splash 的下载计划要求运行时四件套齐全。
        try Data("{}".utf8).write(to: root.appendingPathComponent("release.json"))
        for relative in ["install/launcher.py", "engine/splash"] {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
    }
}
