import CryptoKit
import XCTest
@testable import FlashCatKit

final class EngineInstallerTests: XCTestCase {

    private var workDirectory: URL!
    private var packsDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        packsDirectory = workDirectory.appendingPathComponent("packs", isDirectory: true)
        try FileManager.default.createDirectory(at: packsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        packsDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Install

    func testInstallsFromLocalArchive() async throws {
        let archive = try makeArchive(version: "0.7.2", topLevelDirectory: "omlx-0.7.2")
        let checksum = try sha256Hex(of: archive)
        let release = EnginePackRelease(version: "0.7.2",
                                        url: archive.absoluteString,
                                        sha256: checksum,
                                        bytes: nil,
                                        minMacOS: "14.0",
                                        notes: "本地归档")

        let installer = EngineInstaller(environment: makeEnvironment())
        let phases = PhaseBox()
        let installation = try await installer.install(release, for: .omlx) { phases.append($0) }

        XCTAssertEqual(installation.manifest.version, "0.7.2")
        XCTAssertEqual(installation.id, .omlx)
        XCTAssertEqual(installation.root.path, packsDirectory.appendingPathComponent("omlx/0.7.2").path)
        let versions = await installer.installedVersions(.omlx)
        XCTAssertEqual(versions, ["0.7.2"])
        let installedPath = await installer.installedRoot(.omlx, version: "0.7.2")
        XCTAssertEqual(installedPath, packsDirectory.appendingPathComponent("omlx/0.7.2").path)

        // The pack really landed: manifest decodes and the entrypoint is executable.
        let reloaded = EngineInstallation.load(root: installation.root)
        XCTAssertEqual(reloaded?.manifest.version, "0.7.2")
        let entrypoint = installation.root.appendingPathComponent("python/bin/python3")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: entrypoint.path))

        // No staging or partial leftovers anywhere under the packs root.
        XCTAssertTrue(residue(in: downloadsDirectory).isEmpty, "\(residue(in: downloadsDirectory))")
        XCTAssertTrue(residue(in: stagingDirectory).isEmpty, "\(residue(in: stagingDirectory))")
        XCTAssertTrue(allFiles(under: packsDirectory).allSatisfy { !$0.hasSuffix(".partial") })

        let recorded = phases.phases
        XCTAssertEqual(recorded.first, .resolving)
        XCTAssertEqual(recorded.last, .installed(version: "0.7.2"))
        for expected in [EngineInstallPhase.verifying, .unpacking, .validating, .activating] {
            XCTAssertTrue(recorded.contains(expected), "缺少阶段 \(expected.label)")
        }
        XCTAssertTrue(recorded.contains {
            if case .downloading(let value, _, _) = $0 { return value == 1.0 }
            return false
        })
    }

    func testChecksumMismatchLeavesNothingBehind() async throws {
        let archive = try makeArchive(version: "0.7.2", topLevelDirectory: "omlx-0.7.2")
        let release = EnginePackRelease(version: "0.7.2",
                                        url: archive.absoluteString,
                                        sha256: String(repeating: "0", count: 64))

        let installer = EngineInstaller(environment: makeEnvironment())
        let phases = PhaseBox()
        await XCTAssertThrowsErrorAsync {
            _ = try await installer.install(release, for: .omlx) { phases.append($0) }
        } verify: { error in
            guard case EngineInstallError.checksumMismatch(let expected, let actual) = error else {
                return XCTFail("期望 checksumMismatch，实际 \(error)")
            }
            XCTAssertEqual(expected, String(repeating: "0", count: 64))
            XCTAssertEqual(actual.count, 64)
        }

        XCTAssertTrue(residue(in: downloadsDirectory).isEmpty, "\(residue(in: downloadsDirectory))")
        XCTAssertTrue(residue(in: stagingDirectory).isEmpty, "\(residue(in: stagingDirectory))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: packsDirectory.appendingPathComponent("omlx").path))
        let versionsAfterFailure = await installer.installedVersions(.omlx)
        XCTAssertEqual(versionsAfterFailure, [])
        if case .failed(let message)? = phases.phases.last {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("最后一个阶段应是 failed")
        }
    }

    func testRejectsUnsupportedArchive() async throws {
        let installer = EngineInstaller(environment: makeEnvironment())
        let release = EnginePackRelease(version: "0.7.2",
                                        url: "file:///tmp/omlx-0.7.2.zip",
                                        sha256: String(repeating: "a", count: 64))
        await XCTAssertThrowsErrorAsync {
            _ = try await installer.install(release, for: .omlx) { _ in }
        } verify: { error in
            guard case EngineInstallError.unsupportedArchive(let url) = error else {
                return XCTFail("期望 unsupportedArchive，实际 \(error)")
            }
            XCTAssertTrue(url.hasSuffix(".zip"))
        }

        let tgz = EnginePackRelease(version: "0.7.2",
                                    url: "file:///tmp/omlx-0.7.2.tgz",
                                    sha256: String(repeating: "a", count: 64))
        await XCTAssertThrowsErrorAsync {
            _ = try await installer.install(tgz, for: .omlx) { _ in }
        } verify: { error in
            // .tgz is accepted as a format; it only fails because the file is absent.
            XCTAssertEqual(error as? EngineInstallError,
                           .downloadFailed("找不到下载源文件：/tmp/omlx-0.7.2.tgz"))
        }
    }

    func testInstallsFromFlatArchiveWithoutStripping() async throws {
        // No single top-level folder: stripping a component here would throw
        // the manifest away, so the detector must choose 0 for this layout.
        let archive = try makeArchive(version: "0.7.4", topLevelDirectory: nil)
        let release = EnginePackRelease(version: "0.7.4",
                                        url: archive.absoluteString,
                                        sha256: try sha256Hex(of: archive))

        let installer = EngineInstaller(environment: makeEnvironment())
        let installation = try await installer.install(release, for: .omlx) { _ in }
        XCTAssertEqual(installation.manifest.version, "0.7.4")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: installation.root.appendingPathComponent("manifest.json").path))
    }

    // MARK: - Index

    func testLoadIndexFromLocalFile() async throws {
        let indexURL = workDirectory.appendingPathComponent("pack-index.json")
        let json = """
        {
          "schemaVersion": 1,
          "engines": {
            "omlx": [
              { "version": "0.7.2", "url": "https://example.invalid/omlx-0.7.2.tar.gz", "sha256": "aa" },
              { "version": "0.7.3", "url": "https://example.invalid/omlx-0.7.3.tar.gz", "sha256": "bb" }
            ],
            "teleportation": [
              { "version": "9.9.9", "url": "https://example.invalid/x.tar.gz", "sha256": "cc" }
            ]
          }
        }
        """
        try Data(json.utf8).write(to: indexURL, options: .atomic)

        var environment = makeEnvironment()
        environment.indexURL = URL(fileURLWithPath: indexURL.path)
        let installer = EngineInstaller(environment: environment)

        let index = try await installer.loadIndex()
        XCTAssertEqual(index.schemaVersion, 1)
        XCTAssertEqual(index.releases(for: .omlx).map(\.version), ["0.7.3", "0.7.2"])
        XCTAssertEqual(index.latest(for: .omlx)?.sha256, "bb")
        XCTAssertTrue(index.releases(for: .mtplx).isEmpty)
        // Keys that are not engine identifiers are dropped, not surfaced.
        XCTAssertNil(index.engines["teleportation"])
    }

    func testLoadIndexWithoutAnySourceThrows() async throws {
        var environment = makeEnvironment()
        environment.indexURL = nil
        environment.bundledIndexPath = nil
        let installer = EngineInstaller(environment: environment)
        await XCTAssertThrowsErrorAsync {
            _ = try await installer.loadIndex()
        } verify: { error in
            XCTAssertEqual(error as? EngineInstallError, .indexUnavailable)
        }
    }

    // MARK: - Uninstall

    func testUninstallRemovesVersion() async throws {
        let installer = EngineInstaller(environment: makeEnvironment())
        let release = try makeRelease(version: "0.7.2")
        _ = try await installer.install(release, for: .omlx) { _ in }

        let root = packsDirectory.appendingPathComponent("omlx/0.7.2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        try await installer.uninstall(.omlx, version: "0.7.2")
        let remaining = await installer.installedVersions(.omlx)
        XCTAssertEqual(remaining, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(residue(in: packsDirectory.appendingPathComponent(".trash")).isEmpty)

        // Removing something that is already gone must not throw.
        try await installer.uninstall(.omlx, version: "0.7.2")
    }

    func testInstallFailureKeepsExistingVersion() async throws {
        let installer = EngineInstaller(environment: makeEnvironment())
        let good = try makeRelease(version: "0.7.2")
        _ = try await installer.install(good, for: .omlx) { _ in }
        let afterInstall = await installer.installedVersions(.omlx)
        XCTAssertEqual(afterInstall, ["0.7.2"])

        let archive = try makeArchive(version: "0.7.3", topLevelDirectory: "omlx-0.7.3")
        let broken = EnginePackRelease(version: "0.7.3",
                                       url: archive.absoluteString,
                                       sha256: String(repeating: "f", count: 64))
        await XCTAssertThrowsErrorAsync {
            _ = try await installer.install(broken, for: .omlx) { _ in }
        } verify: { error in
            guard case EngineInstallError.checksumMismatch = error else {
                return XCTFail("期望 checksumMismatch，实际 \(error)")
            }
        }

        let survivors = await installer.installedVersions(.omlx)
        XCTAssertEqual(survivors, ["0.7.2"])
        let surviving = EngineInstallation.load(root: packsDirectory.appendingPathComponent("omlx/0.7.2"))
        XCTAssertEqual(surviving?.manifest.version, "0.7.2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: packsDirectory.appendingPathComponent("omlx/0.7.3").path))
        XCTAssertTrue(residue(in: downloadsDirectory).isEmpty)
        XCTAssertTrue(residue(in: stagingDirectory).isEmpty)
    }

    // MARK: - Phases

    func testPhaseLabelsAndFraction() {
        let downloading = EngineInstallPhase.downloading(progress: 0.42,
                                                         receivedBytes: 420,
                                                         totalBytes: 1000)
        XCTAssertTrue(downloading.label.contains("42"), downloading.label)
        XCTAssertEqual(downloading.fraction, 0.42)
        XCTAssertTrue(downloading.isBusy)

        XCTAssertNil(EngineInstallPhase.idle.fraction)
        XCTAssertNil(EngineInstallPhase.resolving.fraction)
        XCTAssertNil(EngineInstallPhase.verifying.fraction)
        XCTAssertNil(EngineInstallPhase.unpacking.fraction)
        XCTAssertNil(EngineInstallPhase.validating.fraction)
        XCTAssertNil(EngineInstallPhase.activating.fraction)
        XCTAssertNil(EngineInstallPhase.installed(version: "0.7.2").fraction)
        XCTAssertNil(EngineInstallPhase.failed(message: "坏了").fraction)

        XCTAssertEqual(EngineInstallPhase.idle.label, "待安装")
        XCTAssertEqual(EngineInstallPhase.resolving.label, "解析版本")
        XCTAssertEqual(EngineInstallPhase.verifying.label, "校验 SHA256")
        XCTAssertEqual(EngineInstallPhase.unpacking.label, "解包")
        XCTAssertEqual(EngineInstallPhase.validating.label, "校验包")
        XCTAssertEqual(EngineInstallPhase.activating.label, "激活")
        XCTAssertEqual(EngineInstallPhase.installed(version: "0.7.2").label, "已安装")
        XCTAssertEqual(EngineInstallPhase.failed(message: "网络中断").label, "失败：网络中断")

        XCTAssertFalse(EngineInstallPhase.idle.isBusy)
        XCTAssertFalse(EngineInstallPhase.installed(version: "0.7.2").isBusy)
        XCTAssertFalse(EngineInstallPhase.failed(message: "x").isBusy)
    }

    // MARK: - Fixtures

    private func makeEnvironment() -> EngineInstallEnvironment {
        EngineInstallEnvironment(packsDirectory: packsDirectory.path,
                                 indexURL: nil,
                                 bundledIndexPath: nil,
                                 tarPath: "/usr/bin/tar",
                                 xattrPath: "/usr/bin/xattr")
    }

    private func makeRelease(version: String) throws -> EnginePackRelease {
        let archive = try makeArchive(version: version, topLevelDirectory: "omlx-\(version)")
        return EnginePackRelease(version: version,
                                 url: archive.absoluteString,
                                 sha256: try sha256Hex(of: archive))
    }

    /// Builds a real `.tar.gz` on disk: either wrapped in one top-level folder
    /// (the layout the installer must strip) or flat.
    private func makeArchive(version: String,
                             topLevelDirectory: String?,
                             engineID: String = "omlx") throws -> URL {
        let fm = FileManager.default
        let buildRoot = workDirectory.appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
        let contentRoot = topLevelDirectory.map { buildRoot.appendingPathComponent($0, isDirectory: true) } ?? buildRoot
        let binDirectory = contentRoot.appendingPathComponent("python/bin", isDirectory: true)
        try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        let manifest = """
        {
          "schemaVersion": 1,
          "id": "\(engineID)",
          "name": "oMLX",
          "version": "\(version)",
          "kind": "bundled",
          "arch": "arm64",
          "minMacOS": "14.0",
          "entrypoint": "python/bin/python3",
          "workingDirectory": ".",
          "modelsSubdirectory": "models",
          "launchProfiles": {
            "default": { "args": ["-m", "omlx.cli", "serve", "--port", "{port}"] }
          },
          "health": { "path": "/health", "readyStatus": 200, "loadingStatus": 503 },
          "defaultPort": 8100,
          "modelSwitch": "hot",
          "capabilities": ["chat", "streaming"],
          "license": "Apache-2.0"
        }
        """
        try Data(manifest.utf8).write(to: contentRoot.appendingPathComponent("manifest.json"), options: .atomic)

        let entrypoint = binDirectory.appendingPathComponent("python3")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: entrypoint, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entrypoint.path)

        let archive = workDirectory.appendingPathComponent("\(engineID)-\(version)-\(UUID().uuidString).tar.gz")
        var arguments = ["-czf", archive.path, "-C", buildRoot.path]
        if let topLevelDirectory {
            arguments.append(topLevelDirectory)
        } else {
            arguments.append(contentsOf: ["manifest.json", "python"])
        }
        let result = try runProcess("/usr/bin/tar", arguments)
        XCTAssertEqual(result.status, 0, "tar 打包失败：\(result.stderrText)")
        return archive
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private var downloadsDirectory: URL {
        packsDirectory.appendingPathComponent(".downloads", isDirectory: true)
    }

    private var stagingDirectory: URL {
        packsDirectory.appendingPathComponent(".staging", isDirectory: true)
    }

    private func residue(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    private func allFiles(under directory: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                             includingPropertiesForKeys: nil) else {
            return []
        }
        var paths: [String] = []
        for case let url as URL in enumerator {
            paths.append(url.path)
        }
        return paths
    }

    private struct ProcessResult {
        var status: Int32
        var stdout: String
        var stderr: String
        var stderrText: String { stderr.isEmpty ? "无输出" : stderr }
    }

    private func runProcess(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self)
                                 .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Test plumbing

/// Progress arrives from inside the installer actor; the box keeps the
/// collection thread-safe without leaking a mutable capture.
private final class PhaseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EngineInstallPhase] = []

    func append(_ phase: EngineInstallPhase) {
        lock.lock()
        storage.append(phase)
        lock.unlock()
    }

    var phases: [EngineInstallPhase] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// `XCTAssertThrowsError` has no async variant.
private func XCTAssertThrowsErrorAsync(_ expression: () async throws -> Void,
                                       verify: (Error) -> Void = { _ in },
                                       file: StaticString = #filePath,
                                       line: UInt = #line) async {
    do {
        try await expression()
        XCTFail("期望抛出错误，但调用成功返回", file: file, line: line)
    } catch {
        verify(error)
    }
}
