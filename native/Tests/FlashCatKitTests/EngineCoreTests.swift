import XCTest
@testable import FlashCatKit

final class EngineCoreTests: XCTestCase {

    // MARK: engine identity

    func testDefaultPortsAndRangesDoNotCollide() {
        XCTAssertEqual(EngineID.splash.defaultPort, 8000)
        XCTAssertEqual(EngineID.omlx.defaultPort, 8100)
        XCTAssertEqual(EngineID.mtplx.defaultPort, 8200)
        for id in EngineID.allCases {
            XCTAssertEqual(id.portRange.count, 20)
            XCTAssertEqual(id.portRange.first, id.defaultPort)
        }
    }

    func testEachEngineKeepsOnlyTheSwitchesItSupports() {
        XCTAssertEqual(EngineID.omlx.switchMode, .hot)
        XCTAssertEqual(EngineID.mtplx.switchMode, .restart)
        XCTAssertEqual(EngineID.splash.switchMode, .restart)
        XCTAssertTrue(EngineID.omlx.capabilities.contains(.hotLoad))
        XCTAssertTrue(EngineID.mtplx.capabilities.contains(.mtp))
    }

    func testUnknownCapabilityDegradesInsteadOfThrowing() throws {
        let decoded = try JSONDecoder().decode(EngineCapability.self,
                                               from: Data("\"teleportation\"".utf8))
        XCTAssertEqual(decoded, .chat)
    }

    // MARK: version ordering

    func testVersionOrderPrefersLatest() {
        XCTAssertTrue(EngineVersionOrder.isNewer("0.7.2", than: "0.7.0"))
        XCTAssertTrue(EngineVersionOrder.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertFalse(EngineVersionOrder.isNewer("0.7.2", than: "0.7.2"))
        // A prerelease sorts before its release, so an RC never shadows it.
        XCTAssertFalse(EngineVersionOrder.isNewer("1.0.0-rc1", than: "1.0.0"))
    }

    // MARK: manifest

    func testManifestRoundTripsAndExpandsTemplates() throws {
        let manifest = EngineManifest(
            id: .mtplx,
            name: "MTPLX",
            version: "2.12.2",
            kind: .bundled,
            entrypoint: "python/bin/python3",
            launchProfiles: ["default": EngineLaunchProfile(
                args: ["-m", "mtplx.cli", "serve", "--model", "{model}",
                       "--port", "{port}", "--model-search-dir", "{models}"])],
            health: EngineHealthSpec(path: "/health"),
            status: ["/v1/mtplx/snapshot"],
            defaultPort: 8200,
            modelSwitch: .restart,
            capabilities: [.chat, .streaming])

        let data = try JSONEncoder().encode(manifest)
        let restored = try JSONDecoder().decode(EngineManifest.self, from: data)
        XCTAssertEqual(restored.id, .mtplx)
        XCTAssertEqual(restored.launchProfiles["default"]?.args.count, 9)

        let values = ["model": "/m/a", "port": "8200", "models": "/m"]
        let expanded = EngineTemplate.expand(restored.launchProfiles["default"]!.args, context: values)
        XCTAssertEqual(expanded[4], "/m/a")
        XCTAssertEqual(expanded[6], "8200")
        XCTAssertEqual(expanded[8], "/m")
        XCTAssertEqual(EngineTemplate.unresolvedPlaceholders(expanded), [])
    }

    func testUnresolvedPlaceholdersAreReportedNotSwallowed() {
        let expanded = EngineTemplate.expand(["--model", "{model}"], context: [:])
        XCTAssertEqual(EngineTemplate.unresolvedPlaceholders(expanded), ["{model}"])
    }

    // MARK: ports

    func testPortAllocatorSkipsBusyPortsInsideTheRange() {
        var busy: Set<Int> = [8100, 8101, 8102]
        let chosen = EnginePortAllocator.allocate(for: .omlx,
                                                  preferred: 8100,
                                                  taken: busy,
                                                  isOpen: { busy.contains($0) })
        XCTAssertEqual(chosen, 8103)
    }

    func testPortAllocatorGivesUpAfterTheRange() {
        let busy = Set(EngineID.omlx.portRange)
        let chosen = EnginePortAllocator.allocate(for: .omlx,
                                                  preferred: 8100,
                                                  taken: busy,
                                                  isOpen: { busy.contains($0) })
        XCTAssertNil(chosen)
    }

    func testPortAllocatorPrefersTheRequestedPortWhenFree() {
        let chosen = EnginePortAllocator.allocate(for: .splash,
                                                  preferred: 8123,
                                                  taken: [],
                                                  isOpen: { _ in false })
        XCTAssertEqual(chosen, 8123)
    }

    // MARK: real packs

    /// The repo's built packs are the only place a real manifest exists; skip
    /// when the suite runs somewhere without them.
    func testVendoredManifestsDecode() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FlashCatKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // native
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("vendor/engines")
        guard FileManager.default.fileExists(atPath: repo.path) else {
            throw XCTSkip("vendor/engines is not present")
        }

        let engines = (try? FileManager.default.contentsOfDirectory(atPath: repo.path)) ?? []
        XCTAssertFalse(engines.isEmpty)
        for engine in engines {
            let engineDir = repo.appendingPathComponent(engine)
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: engineDir.path)) ?? []
            for version in versions {
                let root = engineDir.appendingPathComponent(version)
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path) else {
                    continue
                }
                let installation = try XCTUnwrap(EngineInstallation.load(root: root),
                                                "manifest failed to decode: \(root.path)")
                XCTAssertEqual(installation.id.rawValue, engine)
                XCTAssertEqual(installation.version, version)
                // Every profile a pack ships must bind the port the app claims;
                // splash ships "hub" and "local" instead of one "default".
                XCTAssertFalse(installation.manifest.launchProfiles.isEmpty)
                for (name, profile) in installation.manifest.launchProfiles {
                    XCTAssertTrue(profile.args.contains("{port}"),
                                  "\(engine)/\(version) profile \(name) dropped the port placeholder")
                }
            }
        }
    }
}
