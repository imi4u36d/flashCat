import Foundation
import FlashCatKit

/// Consolidates model data that older flashCat builds or standalone engines
/// kept outside `Application Support/flashCat`.
///
/// Weights are moved, not copied. Legacy assembly caches are small indexes of
/// symlinks and are archived because their absolute paths are tied to the old
/// root; Splash regenerates the active assembly from the moved weights.
enum ModelStorageMigration {
    struct Report {
        var moved = 0
        var archived = 0
        var failures: [String] = []

        var isEmpty: Bool { moved == 0 && archived == 0 && failures.isEmpty }
    }


    @discardableResult
    static func migrate() -> Report {
        var report = Report()
        Paths.ensureDirectory(EnginePaths.modelsRoot)

        var movedPaths: [String: String] = [:]
        repairMisroutedRootEntries(&report, movedPaths: &movedPaths)
        migrateLegacyFlashCatRoot(&report, movedPaths: &movedPaths)
        archiveLegacyUpstreamSplash(&report)
        migrateEngineRoot(.omlx, source: Paths.home + "/.omlx/models",
                          movedPaths: &movedPaths, report: &report)
        migrateEngineRoot(.mtplx, source: Paths.home + "/.mtplx/models",
                          movedPaths: &movedPaths, report: &report)
        migrateEngineRoot(.mlxServe, source: Paths.home + "/.mlx-serve/models",
                          movedPaths: &movedPaths, report: &report)
        archive(Paths.home + "/.omlx/splash", label: "omlx-splash-hub", report: &report)
        rewriteLinks(under: EnginePaths.modelsRoot, movedPaths: movedPaths, report: &report)
        migrateLegacyPrefixCache(&report)
        retargetPrefixCache(movedPaths: movedPaths, report: &report)

        if Paths.fileExists(Paths.legacySplashModelsDirectory),
           isEmptyDirectory(Paths.legacySplashModelsDirectory) {
            try? FileManager.default.removeItem(atPath: Paths.legacySplashModelsDirectory)
        }
        return report
    }

    /// A short-lived migration build treated every non-empty top-level name as
    /// a dynamic engine id. Move those entries back under Splash; real engine
    /// folders are the only names allowed beside `splash`.
    private static func repairMisroutedRootEntries(_ report: inout Report,
                                                   movedPaths: inout [String: String]) {
        let splash = EnginePaths.modelsDirectory(.splash)
        let engines = Set(EngineCatalog.allIDs.map(\.rawValue))
        for name in entries(EnginePaths.modelsRoot) where !engines.contains(name) && name != "splash" {
            let from = EnginePaths.modelsRoot + "/" + name
            let to = splash + "/" + name
            moveOrMerge(from: from, to: to, report: &report)
            movedPaths[from] = to
        }
    }

    /// `~/.flashcat/models` used to hold Splash repos and metadata alongside
    /// empty legacy `omlx/` and `mtplx/` folders. Route each entry by name.
    private static func migrateLegacyFlashCatRoot(_ report: inout Report,
                                                  movedPaths: inout [String: String]) {
        let source = Paths.legacySplashModelsDirectory
        guard Paths.fileExists(source) else { return }
        let splash = EnginePaths.modelsDirectory(.splash)
        Paths.ensureDirectory(splash)

        for name in entries(source) where name != ".DS_Store" {
            let from = source + "/" + name
            if name == ".resolved" || name == ".selections" {
                archive(from, label: "splash-\(name.dropFirst())", report: &report)
                continue
            }
            if let engine = EngineID(rawValue: name), EngineCatalog.allIDs.contains(engine) {
                migrateEngineRoot(engine, source: from,
                                  movedPaths: &movedPaths, report: &report)
                continue
            }
            let to = splash + "/" + name
            moveOrMerge(from: from, to: to, report: &report)
            movedPaths[from] = to
        }
        if isEmptyDirectory(source) {
            try? FileManager.default.removeItem(atPath: source)
        }
    }

    /// The upstream Splash app kept only assembly/symlink indexes here. The
    /// weights they referenced lived in `.omlx`, which is migrated separately.
    private static func archiveLegacyUpstreamSplash(_ report: inout Report) {
        archive(Paths.legacyUpstreamSplashModelsDirectory,
                label: "upstream-splash-models", report: &report)
    }

    /// Standalone oMLX/MTPLX used `models/<owner>/<repo>` while flashCat's
    /// pack engines use flat `models/<engine>/<owner>--<repo>` directories.
    /// MLX-Serve is Hugging Face-native and stays nested.
    private static func migrateEngineRoot(_ engine: EngineID,
                                          source: String,
                                          movedPaths: inout [String: String],
                                          report: inout Report) {
        guard Paths.fileExists(source) else { return }
        let target = EnginePaths.modelsDirectory(engine)
        Paths.ensureDirectory(target)

        if engine.descriptor.modelLayout == .nested {
            for name in entries(source) where name != ".DS_Store" {
                let from = source + "/" + name
                let to = target + "/" + name
                moveOrMerge(from: from, to: to, report: &report)
                movedPaths[from] = to
            }
            if isEmptyDirectory(source) {
                try? FileManager.default.removeItem(atPath: source)
            }
            return
        }

        for name in entries(source) where name != ".DS_Store" {
            let from = source + "/" + name
            if name.hasPrefix(".") || EngineModelStore.isWeightsDirectory(from, engine: engine) {
                let to = target + "/" + name
                moveOrMerge(from: from, to: to, report: &report)
                movedPaths[from] = to
                continue
            }
            guard isDirectory(from) else { continue }
            for repo in entries(from) where repo != ".DS_Store" {
                let nested = from + "/" + repo
                let to = target + "/" + ModelInstaller.folderName(for: name + "/" + repo)
                moveOrMerge(from: nested, to: to, report: &report)
                movedPaths[nested] = to
            }
            if isEmptyDirectory(from) {
                try? FileManager.default.removeItem(atPath: from)
            }
        }
        if isEmptyDirectory(source) {
            try? FileManager.default.removeItem(atPath: source)
        }
    }

    private static func moveOrMerge(from: String, to: String, report: inout Report) {
        guard Paths.fileExists(from) || isLink(from) else { return }
        do {
            if !Paths.fileExists(to) && !isLink(to) {
                Paths.ensureDirectory((to as NSString).deletingLastPathComponent)
                try FileManager.default.moveItem(atPath: from, toPath: to)
                report.moved += 1
                return
            }
            if isDirectory(from), isDirectory(to) {
                for child in entries(from) where child != ".DS_Store" {
                    moveOrMerge(from: from + "/" + child, to: to + "/" + child, report: &report)
                }
                if isEmptyDirectory(from) {
                    try? FileManager.default.removeItem(atPath: from)
                }
                return
            }
            // Conflicting weights are never deleted. Keep the old copy in the
            // app-owned backup tree so the canonical path stays unambiguous.
            archive(from, label: "collision-" + (from as NSString).lastPathComponent,
                    report: &report)
        } catch {
            report.failures.append("\((from as NSString).lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func archive(_ path: String, label: String, report: inout Report) {
        guard Paths.fileExists(path) || isLink(path) else { return }
        if isDirectory(path), isEmptyDirectory(path) {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        let root = Paths.supportDirectory + "/migration-backups"
        Paths.ensureDirectory(root)
        var destination = root + "/" + label
        if Paths.fileExists(destination) || isLink(destination) {
            destination += "-" + String(Int(Date().timeIntervalSince1970))
        }
        do {
            try FileManager.default.moveItem(atPath: path, toPath: destination)
            report.archived += 1
        } catch {
            report.failures.append("\(label): \(error.localizedDescription)")
        }
    }

    private static func rewriteLinks(under root: String,
                                     movedPaths: [String: String],
                                     report: inout Report) {
        guard !movedPaths.isEmpty, let enumerator = FileManager.default.enumerator(atPath: root) else { return }
        let mappings = movedPaths.keys.sorted { $0.count > $1.count }
        for case let relative as String in enumerator {
            let path = root + "/" + relative
            guard isLink(path),
                  let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { continue }
            let absolute = raw.hasPrefix("/")
                ? raw
                : (path as NSString).deletingLastPathComponent + "/" + raw
            guard let old = mappings.first(where: {
                absolute == $0 || absolute.hasPrefix($0 + "/")
            }), let replacement = movedPaths[old] else { continue }
            let next = replacement + String(absolute.dropFirst(old.count))
            do {
                try FileManager.default.removeItem(atPath: path)
                try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: next)
            } catch {
                report.failures.append("link \((path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Bring an engine's disk tier under the shared prefix-cache root.
    ///
    /// MTPLX used to keep its SessionBank at `~/.mtplx/session-bank`. The app
    /// now passes `--ssd-session-cache-dir` under `prefix-cache/`, so the old
    /// bank would simply be abandoned — tens of gigabytes of warm snapshots
    /// nothing points at. Moving it keeps them; the manifest keys entries by
    /// absolute model path, which this same migration keeps stable below.
    private static func migrateLegacyPrefixCache(_ report: inout Report) {
        let source = Paths.home + "/.mtplx/session-bank"
        let target = FlashCatPaths.prefixCacheDirectory(.mtplx)
        guard Paths.fileExists(source), !Paths.fileExists(target) else { return }
        FlashCatPaths.ensureDirectory(FlashCatPaths.prefixCacheRoot)
        do {
            try FileManager.default.moveItem(atPath: source, toPath: target)
            report.archived += 1
        } catch {
            report.failures.append("mtplx-session-bank: \(error.localizedDescription)")
        }
    }

    /// Keep a moved model's disk-tier snapshots usable.
    ///
    /// A KV snapshot is only meaningful for one model, and engines find it
    /// again by the model's absolute path. Weights moving into
    /// `Application Support/flashCat` therefore used to strand the whole cache
    /// of that model: the rows still pointed at the old path, nothing could
    /// ever match them, and they kept their bytes forever. Rewriting the key
    /// costs one UPDATE and keeps every snapshot warm across the move.
    private static func retargetPrefixCache(movedPaths: [String: String],
                                            report: inout Report) {
        guard !movedPaths.isEmpty else { return }
        let manifest = FlashCatPaths.prefixCacheDirectory(.mtplx) + "/manifest.sqlite"
        guard Paths.fileExists(manifest) else { return }
        for (old, new) in movedPaths where old != new {
            let sql = "UPDATE entries SET model_path = \(quote(new)) WHERE model_path = \(quote(old));"
            guard runSQLite(manifest, sql) else {
                report.failures.append("prefix-cache: 无法改写 \(old)")
                continue
            }
        }
    }

    /// `'` is the only character SQLite needs doubled inside a literal.
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func runSQLite(_ database: String, _ sql: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database, sql]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func entries(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    private static func isDirectory(_ path: String) -> Bool {
        var value: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &value) && value.boolValue
    }

    private static func isLink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type]) as? FileAttributeType == .typeSymbolicLink
    }

    private static func isEmptyDirectory(_ path: String) -> Bool {
        guard isDirectory(path) else { return false }
        return entries(path).allSatisfy { $0 == ".DS_Store" }
    }
}
