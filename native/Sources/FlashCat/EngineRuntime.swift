import Foundation
import FlashCatKit

/// A view over the files inside one installed Splash pack. Splash has the same
/// lifecycle as every other pack: installation, versioning and entrypoint all
/// come from `EngineInstallations`.
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

    /// family → draft repository, parsed straight out of the runtime's families.py
    var draftRepositories: [String: String] {
        let path = root + "/install/families.py"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return Self.knownDrafts
        }
        let parsed = SplashDraft.families(inFamiliesPy: text)
        return parsed.isEmpty ? Self.knownDrafts : parsed
    }

    static let knownDrafts: [String: String] = [
        "Qwen3.8-27B": "incoai/Qwen3.8-27B-DFlash2",
        "Qwen3.6-35B-A3B": "incoai/Qwen3.6-35B-A3B-DFlash2",
        "Qwen3.8-Flash-Next": "incoai/Qwen3.8-Flash-Next-DFlash2",
    ]

    static func readJSON(_ path: String) -> Any? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
