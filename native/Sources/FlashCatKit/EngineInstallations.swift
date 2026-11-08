import Foundation

/// Finds installed runtime packs. Search order mirrors what a developer has at
/// hand: env override, user installs, the app bundle, then a repo's
/// `vendor/engines` so `swift run` works without an install step.
///
/// The locator is shared by the app and the CLI. Both must agree on which pack
/// a given engine id resolves to, otherwise `flashcat engines list` can report
/// a version the app's engine page never finds.
public enum EngineInstallations {
    /// Roots flashCat owns and may delete from. Everything else a pack can be
    /// found in (app bundle, a checkout's `vendor/engines`) is shipped with the
    /// app and is listed read-only.
    public static func userRoots() -> [String] {
        var roots: [String] = []
        if let override = ProcessInfo.processInfo.environment["FLASHCAT_ENGINE_PACKS_DIR"],
           !override.isEmpty {
            roots.append(override)
        }
        roots.append(FlashCatPaths.enginesDirectory)
        return roots
    }

    /// - Parameter extraRoots: additional read-only roots, e.g. the CLI adds
    ///   `Contents/Resources/engines` of the app bundle it was installed in.
    public static func searchRoots(extraRoots: [String] = []) -> [String] {
        var roots = userRoots()
        if let resources = Bundle.main.resourceURL?.path {
            roots.append(resources + "/engines")
        }
        roots.append(contentsOf: extraRoots)
        for candidate in developmentRoots() { roots.append(candidate + "/vendor/engines") }
        return roots
    }

    /// Versions of `id` the engine page may offer a delete button for.
    public static func removableVersions(_ id: EngineID) -> Set<String> {
        EnginePackOwnership.removableVersions(
            directories: installed(id).map { ($0.version, $0.root.path) },
            userRoots: userRoots())
    }

    private static func developmentRoots() -> [String] {
        var roots: [String] = []
        let manager = FileManager.default
        // Walk up from both the executable and the cwd: `swift run` puts the
        // binary under .build/<config>/ and the pack lives at the repo root.
        for start in [Bundle.main.bundlePath, manager.currentDirectoryPath] {
            var url = URL(fileURLWithPath: start)
            for _ in 0..<6 {
                roots.append(url.path)
                url.deleteLastPathComponent()
            }
        }
        return roots
    }

    /// All versions of every engine found under the search roots, newest first.
    public static func installed(_ id: EngineID, extraRoots: [String] = []) -> [EngineInstallation] {
        var found: [String: EngineInstallation] = [:]
        for root in searchRoots(extraRoots: extraRoots) {
            let engineRoot = root + "/" + id.rawValue
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: engineRoot)) ?? []
            for version in versions {
                guard found[version] == nil else { continue }
                let directory = engineRoot + "/" + version
                guard let installation = EngineInstallation.load(root: URL(fileURLWithPath: directory)),
                      installation.id == id else { continue }
                found[version] = installation
            }
        }
        return found.values.sorted { EngineVersionOrder.isNewer($0.manifest.version, than: $1.manifest.version) }
    }

    public static func newest(_ id: EngineID,
                              version: String?,
                              extraRoots: [String] = []) -> EngineInstallation? {
        let all = installed(id, extraRoots: extraRoots)
        guard let version else { return all.first }
        return all.first { $0.manifest.version == version }
    }
}
