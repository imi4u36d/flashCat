import XCTest
@testable import FlashCatKit

/// Plans for "build the pack here, then install it". The three engines have
/// different sources, so the commands differ per engine.
final class EnginePackBuildPlannerTests: XCTestCase {
    func testMTPLXPlanBuildsFromPyPI() {
        let steps = EnginePackBuildPlanner.steps(for: .mtplx, version: "2.13.0", release: nil)
        XCTAssertEqual(steps.map(\.id), ["build", "release"])
        XCTAssertTrue(steps[0].command.contains("build-mtplx-pack.sh --version '2.13.0'"))
        XCTAssertTrue(steps[0].command.contains("--force"))
        XCTAssertTrue(steps[1].command.contains("make-pack-release.sh --engine mtplx --version '2.13.0'"))
        XCTAssertTrue(steps[1].command.contains("make-pack-index.sh"))
    }

    func testOMLXPlanNeedsNoLocalToolchain() {
        // oMLX comes from the upstream GitHub release wheel; the build script
        // downloads and verifies it itself, so the plan must not shell out to
        // Homebrew (or any other machine-local tool) before building.
        let steps = EnginePackBuildPlanner.steps(for: .omlx, version: "0.7.3rc1", release: nil)
        XCTAssertEqual(steps.map(\.id), ["build", "release"])
        XCTAssertTrue(steps[0].command.contains("build-omlx-pack.sh --version '0.7.3rc1'"))
        XCTAssertFalse(steps.contains { $0.command.contains("brew") },
                       "oMLX updates must not depend on Homebrew")
        XCTAssertFalse(steps.contains { $0.command.contains("curl") },
                       "the wheel download lives in the build script, not the plan")
    }

    func testMLXServePlanUsesItsPackScriptAndMinimumMacOS() {
        let steps = EnginePackBuildPlanner.steps(for: .mlxServe, version: "26.11.1", release: nil)
        XCTAssertEqual(steps.map(\.id), ["build", "release"])
        XCTAssertTrue(steps[0].command.contains("build-mlx-serve-pack.sh --version '26.11.1'"))
        XCTAssertTrue(steps[1].command.contains("--min-macos '26.4'"))
    }

    func testStrataPlanUsesItsPackScriptAndMinimumMacOS() {
        let steps = EnginePackBuildPlanner.steps(for: .strata, version: "0.2.10", release: nil)
        XCTAssertEqual(steps.map(\.id), ["build", "release"])
        XCTAssertTrue(steps[0].command.contains("build-strata-pack.sh --version '0.2.10'"))
        XCTAssertTrue(steps[1].command.contains("--min-macos '15.0'"))
    }

    func testSplashPlanDownloadsTheAssetAndVerifiesItsChecksum() {
        let landing = EngineUpstreamRelease(
            version: "1.4.1",
            tag: "v1.4.1",
            title: nil,
            publishedAt: nil,
            isPrerelease: false,
            pageURL: URL(string: "https://github.com/incoai/splash/releases/tag/v1.4.1")!,
            assets: [
                .init(name: "splash-1.4.1-arm64-macos26.tar.gz",
                      url: URL(string: "https://example.com/splash-1.4.1-arm64-macos26.tar.gz")!),
                .init(name: "splash-1.4.1-arm64-macos26.tar.gz.sha256",
                      url: URL(string: "https://example.com/splash-1.4.1-arm64-macos26.tar.gz.sha256")!),
            ])
        let steps = EnginePackBuildPlanner.steps(for: .splash, version: "1.4.1", release: landing)
        XCTAssertEqual(steps.map(\.id), ["download", "build", "release"])
        XCTAssertTrue(steps[0].command.contains("vendor/splash-1.4.1-arm64-macos26.tar.gz"))
        XCTAssertTrue(steps[0].command.contains("shasum -a 256"))
        XCTAssertTrue(steps[1].command.contains("build-splash-pack.sh --version '1.4.1'"))
    }

    func testSplashPlanSkipsTheDownloadWhenTheReleaseHasNoAssets() {
        // A tag-only release (no uploaded tarball) must still produce a plan: the
        // build script then fails with its own "tarball not found" message.
        let steps = EnginePackBuildPlanner.steps(for: .splash, version: "1.4.1", release: nil)
        XCTAssertEqual(steps.map(\.id), ["build", "release"])
    }

    func testReleaseStepWritesPortableURLs() {
        // The release + index step used to pass `--base-url file://$PWD/…`, which
        // shipped machine-local addresses inside pack-index.json. The scripts
        // write the archive's bare file name instead, so no prefix belongs here.
        let steps = EnginePackBuildPlanner.steps(for: .omlx, version: "0.7.2", release: nil)
        let release = steps.first { $0.id == "release" }
        XCTAssertFalse(release?.command.contains("--base-url") ?? true)
    }

    func testLoadReleaseResolvesTheArchiveBesideTheReleaseFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("omlx-0.7.2.release.json")
        let json = #"{"version":"0.7.2","url":"omlx-0.7.2-arm64-macos26.0.tar.gz","sha256":"a","bytes":1}"#
        try Data(json.utf8).write(to: path)

        let release = try EnginePackBuildRunner.loadRelease(at: path.path)

        XCTAssertEqual(release.url,
                       dir.appendingPathComponent("omlx-0.7.2-arm64-macos26.0.tar.gz").absoluteString)
    }

    func testReleaseFilePath() {
        XCTAssertEqual(EnginePackBuildPlanner.releaseFile(for: .omlx, version: "0.7.3.dev2"),
                       "dist/packs/omlx-0.7.3.dev2.release.json")
    }
}
