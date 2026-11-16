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

    /// 回归：`terminationHandler` 曾是在 `process.run()` 之后才赋值的。子进程在
    /// 这两行之间退出时（`exit 0` 就是毫秒级），Process 不会补发通知，
    /// continuation 永不 resume，整个 pack 构建挂死（无超时、不响应取消）。
    /// 3 秒的 race 只是断言它「返回了」，不是在测性能。
    func testStepThatExitsImmediatelyDoesNotHang() async {
        let step = EnginePackBuildStep(id: "instant", title: "瞬时步骤", command: "exit 0")
        let done = FlagBox()
        let failure = ErrorBox()
        let task = Task {
            do {
                try await EnginePackBuildRunner.run(step,
                                                    in: FileManager.default.temporaryDirectory.path) { _ in }
            } catch {
                failure.set(error)
            }
            done.set()
        }

        let deadline = Date().addingTimeInterval(3)
        while !done.value && Date() < deadline {
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { break }
        }
        XCTAssertTrue(done.value, "子进程瞬间退出时 continuation 没有被 resume（构建会挂死）")
        XCTAssertNil(failure.value)
        task.cancel()
    }

    /// 回归：一次 read 可能正好把一个中文字符的 UTF-8 字节劈成两半。旧实现拿整块
    /// 去 `String(data:encoding:)`，解码失败就把整块（可能是好几行）静默丢掉，
    /// 中文构建输出会凭空少行。这里让 bash 分两次写出同一个字符的字节。
    func testMultiByteCharacterSplitAcrossReadsIsNotDropped() async throws {
        let step = EnginePackBuildStep(id: "utf8",
                                       title: "中文输出",
                                       command: #"printf '\xe4\xb8'; sleep 0.2; printf '\xad\n'"#)
        let lines = LineBox()
        try await EnginePackBuildRunner.run(step,
                                            in: FileManager.default.temporaryDirectory.path) {
            lines.append($0)
        }
        XCTAssertEqual(lines.value, ["中"])
    }
}

/// 跨队列的状态盒子：`onLine` 在 readabilityHandler 的队列上回调，测试在另一个
/// 执行上下文里读，直接捕获 var 会被严格并发检查拦下。
private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var value: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Error?

    func set(_ error: Error) {
        lock.lock()
        storage = error
        lock.unlock()
    }

    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
