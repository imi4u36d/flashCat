import Foundation
import FlashCatKit

/// One engine's persisted preferences. Keyed by `EngineID.rawValue` inside
/// `engines.json` so a new engine can be added without a migration.
struct EngineConfiguration: Codable {
    var enabled: Bool = true
    var version: String?
    var port: Int?
    var lastModel: String?
    var autoStart: Bool = false
}

/// Reads and writes `engines.json`, and tells the UI where every engine's pack
/// lives. Deliberately tolerant: a corrupt file falls back to defaults instead
/// of blocking app launch.
@MainActor
final class EngineStore {
    static let shared = EngineStore()

    private(set) var configurations: [String: EngineConfiguration] = [:]
    private let fileURL: URL

    init(directory: String = Paths.supportDirectory, file: String = "engines.json") {
        fileURL = URL(fileURLWithPath: directory).appendingPathComponent(file)
        load()
    }

    /// Engine the app should open on: explicit env override (tests, scripts)
    /// then the last engine the reader used, then splash.
    var preferredEngine: EngineID {
        if let raw = ProcessInfo.processInfo.environment["FLASHCAT_ENGINE"],
           let id = EngineID(rawValue: raw) {
            return id
        }
        if let raw = configurations["active"]?.version, let id = EngineID(rawValue: raw) {
            return id
        }
        return .splash
    }

    func rememberActive(_ id: EngineID) {
        update(id) { _ in }
        var value = configurations["active"] ?? EngineConfiguration()
        value.version = id.rawValue
        configurations["active"] = value
        save()
    }

    func configuration(for id: EngineID) -> EngineConfiguration {
        configurations[id.rawValue] ?? EngineConfiguration(port: id.defaultPort)
    }

    func update(_ id: EngineID, _ change: (inout EngineConfiguration) -> Void) {
        var value = configuration(for: id)
        change(&value)
        configurations[id.rawValue] = value
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: EngineConfiguration].self, from: data) else {
            return
        }
        configurations = decoded
    }

    private func save() {
        Paths.ensureDirectory(Paths.supportDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(configurations) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Where each engine lives on disk, and which packs are actually installed.
enum EnginePaths {
    static var supportDirectory: String { Paths.supportDirectory }
    static var enginesDirectory: String { supportDirectory + "/engines" }
    static var packsDirectory: String {
        ProcessInfo.processInfo.environment["FLASHCAT_ENGINE_PACKS_DIR"]
            ?? (supportDirectory + "/packs")
    }
    static var modelsRoot: String { supportDirectory + "/models" }
    static var logsDirectory: String {
        ProcessInfo.processInfo.environment["FLASHCAT_LOGS_DIR"]
            ?? (Paths.home + "/Library/Logs/flashCat")
    }

    static func installationDirectory(_ id: EngineID, version: String) -> String {
        enginesDirectory + "/" + id.rawValue + "/" + version
    }

    static func modelsDirectory(_ id: EngineID) -> String {
        modelsRoot + "/" + id.rawValue
    }

    static func logFile(_ id: EngineID) -> String {
        logsDirectory + "/" + id.rawValue + ".log"
    }

    static func pidFile(_ id: EngineID) -> String {
        supportDirectory + "/" + id.rawValue + ".pid"
    }
}

/// Finds installed runtime packs. Search order mirrors what a developer has at
/// hand: env override, user installs, the app bundle, then the repo's
/// `vendor/engines` so `swift run` works without an install step.
enum EngineInstallations {
    static func searchRoots() -> [String] {
        var roots: [String] = []
        if let override = ProcessInfo.processInfo.environment["FLASHCAT_ENGINE_PACKS_DIR"] {
            roots.append(override)
        }
        roots.append(EnginePaths.enginesDirectory)
        if let resources = Bundle.main.resourceURL?.path {
            roots.append(resources + "/engines")
        }
        for candidate in developmentRoots() { roots.append(candidate + "/vendor/engines") }
        return roots
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
    static func installed(_ id: EngineID) -> [EngineInstallation] {
        var found: [String: EngineInstallation] = [:]
        for root in searchRoots() {
            let engineRoot = root + "/" + id.rawValue
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: engineRoot)) ?? []
            for version in versions {
                guard found[version] == nil else { continue }
                let directory = engineRoot + "/" + version
                guard let installation = try? EngineInstallation.load(root: URL(fileURLWithPath: directory)),
                      installation.id == id else { continue }
                found[version] = installation
            }
        }
        return found.values.sorted { EngineVersionOrder.isNewer($0.manifest.version, than: $1.manifest.version) }
    }

    static func newest(_ id: EngineID, version: String?) -> EngineInstallation? {
        let all = installed(id)
        guard let version else { return all.first }
        return all.first { $0.manifest.version == version }
    }
}

/// Keeps `~/Library/Application Support/flashCat/models/<engine>` populated with
/// symlinks into the model directories the user already has. Nothing is copied
/// and nothing is downloaded: the engine only ever sees flashCat's own folder.
enum EngineModelLinker {
    /// Directories that hold the user's pre-existing weights. Read only.
    static func sourceDirectories(for id: EngineID) -> [String] {
        let home = Paths.home
        switch id {
        case .omlx:
            return [home + "/.omlx/models", home + "/.omlx/gguf"]
        case .mtplx:
            return [home + "/.mtplx/models"]
        case .splash:
            return [Paths.modelsDirectory]
        }
    }

    struct LinkedModel {
        let id: String
        let link: String
        let target: String
        let bytes: Int
    }

    /// Scans the source directories for weight folders and links the missing
    /// ones. Existing links are left untouched so the user can prune by hand.
    @discardableResult
    static func synchronize(_ id: EngineID) -> [LinkedModel] {
        guard id != .splash else { return [] }
        let destination = EnginePaths.modelsDirectory(id)
        Paths.ensureDirectory(destination)
        var result: [LinkedModel] = []
        let manager = FileManager.default

        for source in sourceDirectories(for: id) {
            let entries = (try? manager.contentsOfDirectory(atPath: source)) ?? []
            for entry in entries.sorted() where !entry.hasPrefix(".") {
                let first = source + "/" + entry
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: first, isDirectory: &isDirectory) else { continue }
                if !isDirectory.boolValue { continue }

                var candidates: [String] = []
                // oMLX nests weights one level deeper (`models/<owner>/<model>`);
                // MTPLX keeps `<owner>--<model>` flat; `~/.omlx/gguf/<name>` is a
                // single folder whose weights are symlinks.
                if isWeightsDirectory(first, engine: id) {
                    candidates = [first]
                } else {
                    let nested = (try? manager.contentsOfDirectory(atPath: first)) ?? []
                    candidates = nested.sorted()
                        .filter { !$0.hasPrefix(".") }
                        .map { first + "/" + $0 }
                        .filter { isWeightsDirectory($0, engine: id) }
                }

                for candidate in candidates {
                    let relative = candidate.replacingOccurrences(of: source + "/", with: "")
                    let name = relative.replacingOccurrences(of: "/", with: "--")
                    let link = destination + "/" + name
                    if manager.fileExists(atPath: link) || isDanglingLink(link) { continue }
                    try? manager.createSymbolicLink(atPath: link, withDestinationPath: candidate)
                    result.append(LinkedModel(id: name, link: link, target: candidate, bytes: size(of: candidate)))
                }
            }
        }
        return result
    }

    /// A folder counts as a model when it has weights config *and* a tokenizer.
    /// Draft/assistant heads (oMLX's `DFlash2` folders, for instance) ship only
    /// `config.json` + weights and cannot be served on their own, so offering
    /// them in the picker would just produce a load failure.
    static func isWeightsDirectory(_ path: String, engine: EngineID) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path + "/config.json") else { return false }
        let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json", "chat_template.jinja",
                              "merges.txt", "vocab.json", "tokenizer.model"]
        return tokenizerFiles.contains { manager.fileExists(atPath: path + "/" + $0) }
    }

    private static func isDanglingLink(_ path: String) -> Bool {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeSymbolicLink else { return false }
        return !manager.fileExists(atPath: path)
    }

    static func size(of path: String) -> Int {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(atPath: path) else { return 0 }
        var total = 0
        for case let entry as String in enumerator {
            let full = path + "/" + entry
            guard let attributes = try? manager.attributesOfItem(atPath: full) else { continue }
            total += (attributes[.size] as? Int) ?? 0
        }
        return total
    }
}
