import Foundation

/// Locates the bundled (or managed) splash inference runtime.
///
/// Search order, same as the previous client:
///   FLASHCAT_RUNTIME → ~/Library/Application Support/flashCat/runtimes/<active>
///   → <app>/Contents/Resources/runtime → ./.runtime
struct EngineRuntime {
    let root: String

    var pythonPath: String { root + "/python/bin/python3" }
    var launcherPath: String { root + "/install/launcher.py" }
    var enginePath: String { root + "/engine/splash" }
    var serveScriptPath: String { root + "/flashcat_serve.py" }
    var releaseFile: String { root + "/release.json" }

    var exists: Bool {
        Paths.fileExists(releaseFile)
            && Paths.fileExists(pythonPath)
            && Paths.fileExists(launcherPath)
            && Paths.fileExists(enginePath)
    }

    var version: String {
        guard let data = Self.readJSON(releaseFile) as? [String: Any],
              let value = data["version"] as? String else { return "unknown" }
        return value
    }

    var suggestedModels: [String] {
        let path = root + "/install/completions/suggested-models.txt"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// family → draft repository, parsed straight out of the runtime's families.py
    var draftRepositories: [String: String] {
        let path = root + "/install/families.py"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return Self.knownDrafts
        }
        var result: [String: String] = [:]
        for match in TextPattern.allMatches(#"ModelFamily\(\s*"([^"]+)"\s*,\s*(?:"([^"]+)"|None)"#, text) {
            let family = match.count > 1 ? match[1] : ""
            let repo = match.count > 2 ? match[2] : ""
            if !family.isEmpty { result[family] = repo }
        }
        return result.isEmpty ? Self.knownDrafts : result
    }

    static let knownDrafts: [String: String] = [
        "Qwen3.8-27B": "incoai/Qwen3.8-27B-DFlash2",
        "Qwen3.6-35B-A3B": "incoai/Qwen3.6-35B-A3B-DFlash2",
        "Qwen3.8-Flash-Next": "incoai/Qwen3.8-Flash-Next-DFlash2",
    ]

    static var managedVersion: String? {
        guard let value = try? String(contentsOfFile: Paths.activeRuntimeFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespaces),
            !value.isEmpty,
            TextPattern.test("^[A-Za-z0-9._-]+$", value) else { return nil }
        return value
    }

    static var bundledResourcesDirectory: String? {
        // Inside a .app bundle: …/flashCat.app/Contents/Resources
        let bundle = Bundle.main
        if bundle.bundleURL.path.hasSuffix(".app"), let resources = bundle.resourceURL,
           FileManager.default.fileExists(atPath: resources.path) {
            return resources.path
        }
        // Development build: native/.runtime or the project's .runtime
        return nil
    }

    static func locate() -> EngineRuntime? {
        var candidates: [String] = []
        let override = ProcessInfo.processInfo.environment["FLASHCAT_RUNTIME"] ?? ""
        if !override.isEmpty { candidates.append(override) }

        if let active = managedVersion {
            candidates.append(Paths.runtimesDirectory + "/" + active)
        }
        if let resources = bundledResourcesDirectory {
            candidates.append(resources + "/runtime")
        }
        candidates.append(FileManager.default.currentDirectoryPath + "/.runtime")
        candidates.append(FileManager.default.currentDirectoryPath + "/../.runtime")

        for candidate in candidates {
            let runtime = EngineRuntime(root: candidate)
            if runtime.exists { return runtime }
        }
        return nil
    }

    static func selectRuntime(_ version: String?) {
        Paths.ensureDirectory(Paths.supportDirectory)
        if version == nil {
            try? FileManager.default.removeItem(atPath: Paths.activeRuntimeFile)
        } else if let value = version {
            try? value.write(toFile: Paths.activeRuntimeFile, atomically: true, encoding: .utf8)
        }
    }

    static func readJSON(_ path: String) -> Any? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
