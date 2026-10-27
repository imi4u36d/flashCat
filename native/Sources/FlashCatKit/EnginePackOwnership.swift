import Foundation

/// Which runtime packs the app is allowed to delete.
///
/// Packs are discovered in four places, but only two of them belong to the user:
/// the installs directory and the `FLASHCAT_ENGINE_PACKS_DIR` override. A pack
/// that lives inside the app bundle ships with flashCat (removing it breaks the
/// code signature) and one under a checkout's `vendor/engines` is a build
/// artifact of that checkout. Both are still usable, so they are listed — they
/// just cannot be deleted from the engine page.
public enum EnginePackOwnership {
    /// True when `directory` sits under one of `userRoots`.
    ///
    /// Comparison is path-component based after standardizing, so
    /// `~/…/engines/x` matches `~/…/engines` but `~/…/engines-copy/x` does not.
    public static func isRemovable(directory: String, userRoots: [String]) -> Bool {
        let target = normalized(directory)
        return userRoots.contains { root in
            let prefix = normalized(root)
            guard !prefix.isEmpty else { return false }
            return target == prefix || target.hasPrefix(prefix + "/")
        }
    }

    /// Version folders inside `directory` that the app may delete, matching the
    /// engine page's list.
    public static func removableVersions(directories: [(version: String, path: String)],
                                         userRoots: [String]) -> Set<String> {
        Set(directories.filter { isRemovable(directory: $0.path, userRoots: userRoots) }
            .map(\.version))
    }

    private static func normalized(_ path: String) -> String {
        var value = (path as NSString).standardizingPath
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
