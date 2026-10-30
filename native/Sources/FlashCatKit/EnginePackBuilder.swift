import Foundation

// MARK: - Plan

/// One shell step of an in-app "build the pack, then install it" run. The step
/// runs as `bash -lc <command>` with the repository as the working directory,
/// which is what the scripts under `scripts/engines/` expect.
public struct EnginePackBuildStep: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let command: String

    public init(id: String, title: String, command: String) {
        self.id = id
        self.title = title
        self.command = command
    }
}

/// Turns "upstream has 1.4.1, we have 1.4.0" into the commands that actually
/// produce a runtime pack on this machine.
///
/// The three engines have different sources, so the plans differ:
/// - splash ships a release tarball → download it (with its `.sha256`), then unpack;
/// - MTPLX comes from PyPI → the build script runs `uv pip install mtplx==<v>`;
/// - oMLX is not on PyPI, but its upstream GitHub release ships a prebuilt cp311
///   wheel → the build script downloads that wheel, verifies its sha256 against
///   the release notes, and installs it into the pack's own CPython 3.11.
///
/// None of the plans rely on machine-local toolchains: every script bootstraps
/// its own uv into `.tools/` and uses only /usr/bin tools otherwise.
public enum EnginePackBuildPlanner {
    /// Directory of the release archives, relative to the repository root.
    public static let packsDirectory = "dist/packs"

    public static func steps(for id: EngineID,
                             version: String,
                             release: EngineUpstreamRelease?) -> [EnginePackBuildStep] {
        var steps: [EnginePackBuildStep] = []
        let root = "$PWD"

        switch id {
        case .omlx:
            // The build script fetches the upstream wheel itself; no local
            // Homebrew keg (and no `brew upgrade`) is involved.
            break
        case .splash:
            if let asset = release?.asset(prefix: "splash-\(version)-"),
               let checksum = release?.asset(named: asset.name + ".sha256") {
                let target = "vendor/\(asset.name)"
                steps.append(EnginePackBuildStep(
                    id: "download",
                    title: "下载并校验 Splash \(version) 发行包",
                    command: """
                    set -euo pipefail
                    curl -fL --retry 2 -o '\(target)' '\(asset.url.absoluteString)'
                    curl -fL --retry 2 -o '/tmp/\(asset.name).sha256' '\(checksum.url.absoluteString)'
                    expected=$(awk '{print $1}' '/tmp/\(asset.name).sha256')
                    actual=$(shasum -a 256 '\(target)' | awk '{print $1}')
                    [ "$expected" = "$actual" ] || { echo "SHA256 不匹配：期望 $expected，实际 $actual"; exit 1; }
                    echo "SHA256 校验通过：$actual"
                    """))
            }
        case .mtplx:
            break
        }

        steps.append(EnginePackBuildStep(
            id: "build",
            title: "构建 \(id.displayName) \(version) 运行时包",
            command: "scripts/engines/build-\(id.rawValue)-pack.sh --version '\(version)' --force"))
        steps.append(EnginePackBuildStep(
            id: "release",
            title: "打包并写索引",
            command: """
            set -euo pipefail
            scripts/engines/make-pack-release.sh --engine \(id.rawValue) --version '\(version)' \
              --out \(packsDirectory) --base-url "file://\(root)/\(packsDirectory)"
            scripts/engines/make-pack-index.sh --packs \(packsDirectory) --out pack-index.json \
              --base-url "file://\(root)/\(packsDirectory)"
            """))
        return steps
    }

    /// Where the freshly built pack release JSON lands, so the installer can run
    /// without waiting for the index to be re-read from disk.
    public static func releaseFile(for id: EngineID, version: String) -> String {
        "\(packsDirectory)/\(id.rawValue)-\(version).release.json"
    }
}

// MARK: - Runner

public enum EnginePackBuildError: Error, LocalizedError, Equatable {
    case repositoryNotFound
    case stepFailed(title: String, status: Int32)
    case releaseFileMissing(String)

    public var errorDescription: String? {
        switch self {
        case .repositoryNotFound:
            return "找不到 flashCat 源码目录（需要 scripts/engines/）。设置 FLASHCAT_REPO_ROOT 指向仓库根目录。"
        case .stepFailed(let title, let status):
            return "「\(title)」失败（退出码 \(status)）"
        case .releaseFileMissing(let path):
            return "构建结束但没有生成 \(path)"
        }
    }
}

public enum EnginePackBuildRunner {
    /// Finds the repository that carries the build scripts: an explicit
    /// environment override, then the usual checkout locations.
    public static func locateRepository() -> String? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = environment["FLASHCAT_REPO_ROOT"], !override.isEmpty {
            candidates.append(override)
        }
        let home = NSHomeDirectory()
        candidates.append("\(home)/zhuo/flashCat")
        candidates.append("\(home)/flashCat")
        candidates.append(FileManager.default.currentDirectoryPath)
        // A few levels up from the bundle, for `swift run` style launches.
        var url = Bundle.main.bundleURL
        for _ in 0..<4 {
            candidates.append(url.deletingLastPathComponent().path)
            url = url.deletingLastPathComponent()
        }
        for candidate in candidates {
            let script = candidate + "/scripts/engines/build-omlx-pack.sh"
            if FileManager.default.isExecutableFile(atPath: script) { return candidate }
            let plain = candidate + "/scripts/engines/build-omlx-pack.sh"
            if FileManager.default.fileExists(atPath: plain) { return candidate }
        }
        return nil
    }

    public static func run(_ step: EnginePackBuildStep,
                           in repository: String,
                           onLine: @escaping @Sendable (String) -> Void) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", step.command]
        process.currentDirectoryURL = URL(fileURLWithPath: repository)
        var environment = ProcessInfo.processInfo.environment
        // The build scripts bootstrap their own uv into <repo>/.tools/ and use
        // only /usr/bin tools besides, so no Homebrew or other machine-local
        // toolchain is added to the search path.
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = path
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading
        let buffer = _LineBuffer(onLine: onLine)
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                readable.readabilityHandler = nil
                return
            }
            buffer.consume(data)
        }

        try process.run()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        handle.readabilityHandler = nil
        if let rest = try? handle.readToEnd(), !rest.isEmpty {
            buffer.consume(rest)
        }
        buffer.flush()

        if process.terminationStatus != 0 {
            throw EnginePackBuildError.stepFailed(title: step.title, status: process.terminationStatus)
        }
    }

    /// Runs the whole plan in order, forwarding every output line.
    public static func run(steps: [EnginePackBuildStep],
                           in repository: String,
                           onStep: @escaping @Sendable (EnginePackBuildStep) -> Void = { _ in },
                           onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        for step in steps {
            onStep(step)
            onLine("$ \(step.command)")
            try await run(step, in: repository, onLine: onLine)
        }
    }

    public static func loadRelease(at path: String) throws -> EnginePackRelease {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw EnginePackBuildError.releaseFileMissing(path)
        }
        return try JSONDecoder().decode(EnginePackRelease.self, from: data)
    }
}

/// Splits a byte stream into lines. Build scripts emit progress as lines, so the
/// handler can forward them as they arrive instead of after the run.
private final class _LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func consume(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        pending += text
        var lines: [String] = []
        while let index = pending.firstIndex(of: "\n") {
            lines.append(String(pending[..<index]))
            pending = String(pending[pending.index(after: index)...])
        }
        lock.unlock()
        for line in lines where !line.isEmpty { onLine(line) }
    }

    func flush() {
        lock.lock()
        let rest = pending
        pending = ""
        lock.unlock()
        if !rest.isEmpty { onLine(rest) }
    }
}
