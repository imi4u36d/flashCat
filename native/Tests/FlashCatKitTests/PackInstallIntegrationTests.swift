import XCTest
@testable import FlashCatKit

/// End-to-end install of a **real** runtime pack archive. Skipped unless the
/// environment points at one, so ordinary test runs stay fast and offline:
///
///     scripts/engines/make-pack-release.sh --engine omlx --version 0.7.2
///     FLASHCAT_TEST_PACK=$PWD/dist/packs/omlx-0.7.2-arm64-macos26.0.tar.gz \
///     FLASHCAT_TEST_PACK_SHA=$(shasum -a 256 "$FLASHCAT_TEST_PACK" | cut -d' ' -f1) \
///     swift test --filter PackInstallIntegrationTests
final class PackInstallIntegrationTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let archive = environment["FLASHCAT_TEST_PACK"], !archive.isEmpty else {
            throw XCTSkip("FLASHCAT_TEST_PACK not set")
        }
        guard FileManager.default.fileExists(atPath: archive) else {
            throw XCTSkip("FLASHCAT_TEST_PACK does not exist: \(archive)")
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-pack-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !root.isEmpty {
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    func testInstallsRealPackArchive() async throws {
        let environment = ProcessInfo.processInfo.environment
        let archive = environment["FLASHCAT_TEST_PACK"]!
        let expectedSHA = environment["FLASHCAT_TEST_PACK_SHA"] ?? sha256(of: archive)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: archive)[.size] as? Int) ?? nil

        let installer = EngineInstaller(environment: EngineInstallEnvironment(packsDirectory: root))
        let release = EnginePackRelease(version: "0.7.2",
                                        url: URL(fileURLWithPath: archive).absoluteString,
                                        sha256: expectedSHA,
                                        bytes: bytes)

        let phases = Counter()
        let installation = try await installer.install(release, for: .omlx) { phase in
            phases.record(phase)
        }

        XCTAssertEqual(installation.manifest.id, .omlx)
        XCTAssertEqual(installation.manifest.version, "0.7.2")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installation.entrypoint.path),
                      "entrypoint must be executable: \(installation.entrypoint.path)")
        let versions = await installer.installedVersions(.omlx)
        XCTAssertEqual(versions, ["0.7.2"])
        let installedRoot = await installer.installedRoot(.omlx, version: "0.7.2")
        XCTAssertEqual(installedRoot, root + "/omlx/0.7.2")

        // Staging and partial files must not survive a successful install.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        XCTAssertFalse(leftovers.contains(".staging"), "staging left behind: \(leftovers)")
        XCTAssertFalse(leftovers.contains(".downloads"), "downloads left behind: \(leftovers)")

        // The pack is large; make sure the interpreter actually runs.
        let python = installation.root.appendingPathComponent("python/bin/python3").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import sys; print(sys.version_info[0])"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(output, "3", "unexpected interpreter: \(output ?? "nil")")

        let seen = phases.snapshot()
        XCTAssertTrue(seen.contains { if case .verifying = $0 { return true } else { return false } })
        XCTAssertTrue(seen.contains { if case .unpacking = $0 { return true } else { return false } })
        XCTAssertTrue(seen.contains { if case .installed = $0 { return true } else { return false } })
        print("phases: \(seen.map(\.label).joined(separator: " → "))")
    }

    func testRejectsCorruptArchiveWithoutDamagingExistingInstall() async throws {
        let archive = ProcessInfo.processInfo.environment["FLASHCAT_TEST_PACK"]!
        let installer = EngineInstaller(environment: EngineInstallEnvironment(packsDirectory: root))

        var good = EnginePackRelease(version: "0.7.2",
                                     url: URL(fileURLWithPath: archive).absoluteString,
                                     sha256: ProcessInfo.processInfo.environment["FLASHCAT_TEST_PACK_SHA"]
                                        ?? sha256(of: archive))
        _ = try await installer.install(good, for: .omlx) { _ in }

        good.version = "0.7.3"
        good.sha256 = String(repeating: "0", count: 64)
        do {
            _ = try await installer.install(good, for: .omlx) { _ in }
            XCTFail("corrupt archive should not install")
        } catch {
            XCTAssertTrue(error is EngineInstallError)
        }
        let versions = await installer.installedVersions(.omlx)
        XCTAssertEqual(versions, ["0.7.2"])
    }

    private func sha256(of path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: " ").first.map(String.init) ?? ""
    }
}

/// Small thread-safe collector: the installer calls back from its own actor.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [EngineInstallPhase] = []

    func record(_ phase: EngineInstallPhase) {
        lock.lock()
        defer { lock.unlock() }
        // Download progress fires constantly; keep one sample per stage.
        if case .downloading = phase, phases.contains(where: { if case .downloading = $0 { return true } else { return false } }) {
            return
        }
        phases.append(phase)
    }

    func snapshot() -> [EngineInstallPhase] {
        lock.lock()
        defer { lock.unlock() }
        return phases
    }
}
