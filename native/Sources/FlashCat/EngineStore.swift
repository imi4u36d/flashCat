import Foundation
import FlashCatKit

/// One engine's persisted preferences. Keyed by `EngineID.rawValue` inside
/// `engines.json` so a new engine can be added without a migration.
struct EngineConfiguration: Codable, Equatable {
    var enabled: Bool = true
    var version: String?
    var port: Int?
    var lastModel: String?
    var autoStart: Bool = false
    /// Per-engine knobs edited on that engine's config page. Optional so a file
    /// written before the config page existed still decodes.
    var tuning: EngineTuning?
    /// Which auxiliary DFlash2 draft each main model runs with, keyed by model
    /// id. Engine scoping comes free: the map lives inside this engine's own
    /// configuration. Absent key = follow the engine-level tuning.
    var draftAssignments: [String: String]?
}

/// Reads and writes `engines.json`, and tells the UI where every engine's pack
/// lives. Deliberately tolerant: a corrupt file falls back to defaults instead
/// of blocking app launch.
@MainActor
final class EngineStore {
    static let shared = EngineStore()

    /// Posted after `setTuning`. The store is deliberately not observable, so
    /// views that only read tuning indirectly (the overview's draft-acceptance
    /// label) listen for this instead.
    static let tuningDidChangeNotification =
        Notification.Name("FlashCatEngineTuningDidChange")

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

    func tuning(for id: EngineID) -> EngineTuning {
        configuration(for: id).tuning ?? EngineTuning.defaults(for: id)
    }

    func setTuning(_ value: EngineTuning, for id: EngineID) {
        update(id) { $0.tuning = value == EngineTuning.defaults(for: id) ? nil : value }
        NotificationCenter.default.post(name: Self.tuningDidChangeNotification, object: nil)
    }

    /// The DFlash2 draft assigned to one model, or nil when it follows the
    /// engine-level tuning.
    func draftAssignment(for id: EngineID, model: String) -> String? {
        configuration(for: id).draftAssignments?[model]
    }

    /// Bind (or with `nil`, unbind) a draft to a main model. Posts the tuning
    /// notification so card views showing the pairing refresh.
    func setDraftAssignment(_ draft: String?, engine: EngineID, model: String) {
        update(engine) {
            var assignments = $0.draftAssignments ?? [:]
            let trimmed = draft?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                assignments.removeValue(forKey: model)
            } else {
                assignments[model] = trimmed
            }
            $0.draftAssignments = assignments.isEmpty ? nil : assignments
        }
        NotificationCenter.default.post(name: Self.tuningDidChangeNotification, object: nil)
    }

    func update(_ id: EngineID, _ change: (inout EngineConfiguration) -> Void) {
        var value = configuration(for: id)
        change(&value)
        configurations[id.rawValue] = value
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        // Old tuning documents predate newer knobs and must not read as "leave
        // it to the engine" when the page showed the switch as on.
        let migrated = EngineTuning.backfillPLEOffload(in: document)
        guard let encoded = try? JSONSerialization.data(withJSONObject: migrated),
              let decoded = try? JSONDecoder().decode([String: EngineConfiguration].self, from: encoded) else {
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
        // Splash's models are the ones flashCat already keeps and downloads into;
        // the pack points at the very same folder, so existing installs keep
        // working after the engine moved out of the app bundle.
        if id == .splash { return Paths.modelsDirectory }
        return modelsRoot + "/" + id.rawValue
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
    /// Roots flashCat owns and may delete from. Everything else a pack can be
    /// found in (app bundle, a checkout's `vendor/engines`) is shipped with the
    /// app and is listed read-only.
    static func userRoots() -> [String] {
        var roots: [String] = []
        if let override = ProcessInfo.processInfo.environment["FLASHCAT_ENGINE_PACKS_DIR"] {
            roots.append(override)
        }
        roots.append(EnginePaths.enginesDirectory)
        return roots
    }

    static func searchRoots() -> [String] {
        var roots = userRoots()
        if let resources = Bundle.main.resourceURL?.path {
            roots.append(resources + "/engines")
        }
        for candidate in developmentRoots() { roots.append(candidate + "/vendor/engines") }
        return roots
    }

    /// Versions of `id` the engine page may offer a delete button for.
    static func removableVersions(_ id: EngineID) -> Set<String> {
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

/// flashCat's own model folder is the only place its engines read weights from.
///
/// Nothing is linked in from outside any more: the folder holds the weights
/// themselves, so a model keeps working when `~/.omlx`, `~/.mtplx` or a Hub
/// cache is cleaned out. Weights that an earlier build symlinked out of those
/// directories are moved into the folder on launch, and any link that turns up
/// inside the folder afterwards is resolved into real files and removed.
enum EngineModelStore {
    struct AdoptedModel {
        let id: String
        let path: String
        let bytes: Int
    }

    /// What one adoption pass changed, so the caller can tell the user where
    /// their models went instead of silently relocating tens of gigabytes.
    struct AdoptionReport {
        var adopted: [AdoptedModel] = []
        var dropped: [String] = []
        var failures: [String] = []

        var bytes: Int { adopted.reduce(0) { $0 + $1.bytes } }
        var isEmpty: Bool { adopted.isEmpty && dropped.isEmpty && failures.isEmpty }
    }

    /// Move every linked model in `EnginePaths.modelsDirectory(id)` in place:
    /// the link is replaced by the weights it points at, and a link whose
    /// target is gone is dropped. Only the model folder is written to — the
    /// weights leave the directory they used to sit in, which is the point.
    @discardableResult
    static func adoptExistingWeights(_ id: EngineID) -> AdoptionReport {
        var report = AdoptionReport()
        let root = EnginePaths.modelsDirectory(id)
        Paths.ensureDirectory(root)
        let manager = FileManager.default

        var plans: [(link: String, target: String)] = []
        var dangling: [String] = []
        for link in links(under: root, depth: id == .splash ? 2 : 1) {
            if let target = realTarget(of: link) {
                plans.append((link, target))
            } else {
                dangling.append(link)
            }
        }
        guard !plans.isEmpty || !dangling.isEmpty else { return report }

        // Old absolute path -> the path the weights live at now. Links *inside*
        // a model folder are rewritten through this before they are inlined.
        var moved: [String: String] = [:]
        for plan in plans {
            let bytes = size(of: plan.target)
            do {
                try manager.removeItem(atPath: plan.link)
                try moveDereferencing(plan.target, to: plan.link)
                moved[plan.target] = plan.link
                report.adopted.append(AdoptedModel(id: (plan.link as NSString).lastPathComponent,
                                                   path: plan.link,
                                                   bytes: bytes))
            } catch {
                // Put the link back rather than leave the model unusable.
                try? manager.createSymbolicLink(atPath: plan.link, withDestinationPath: plan.target)
                report.failures.append((plan.link as NSString).lastPathComponent)
            }
        }

        for link in dangling {
            do {
                try manager.removeItem(atPath: link)
                report.dropped.append((link as NSString).lastPathComponent)
            } catch {
                report.failures.append((link as NSString).lastPathComponent)
            }
        }

        // A prepared GGUF assembly is a folder of links into the weights next to
        // it, so they dangle the moment those weights move. Turn them into real
        // files: the model folder has to stand on its own.
        if !moved.isEmpty { inlineLinks(under: root, moved: moved, report: &report) }
        return report
    }

    /// Links that stand where a model belongs: `models/<model>` for the pack
    /// engines, `models/<owner>/<repo>` for Splash. Anything deeper is a file
    /// inside a model and is left to the inlining pass.
    private static func links(under root: String, depth: Int) -> [String] {
        let manager = FileManager.default
        var result: [String] = []
        for entry in (try? manager.contentsOfDirectory(atPath: root)) ?? [] where !entry.hasPrefix(".") {
            let path = root + "/" + entry
            if isLink(path) {
                result.append(path)
            } else if depth > 1, isDirectory(path) {
                for nested in (try? manager.contentsOfDirectory(atPath: path)) ?? [] where !nested.hasPrefix(".") {
                    let child = path + "/" + nested
                    if isLink(child) { result.append(child) }
                }
            }
        }
        return result
    }

    /// `lstat` semantics: a link to a directory is not a directory here.
    static func isDirectory(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        return type == .typeDirectory
    }

    private static func isLink(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        return type == .typeSymbolicLink
    }

    /// Where a link really points, with empty links returning nil. `moved`
    /// rewrites paths whose weights this pass already relocated.
    private static func realTarget(of path: String, moved: [String: String] = [:]) -> String? {
        let manager = FileManager.default
        guard let destination = try? manager.destinationOfSymbolicLink(atPath: path) else { return nil }
        let absolute = destination.hasPrefix("/")
            ? destination
            : (path as NSString).deletingLastPathComponent + "/" + destination
        let resolved = URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path
        let relocated = moved.keys
            .filter { resolved == $0 || resolved.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
            .flatMap { old in moved[old].map { $0 + String(resolved.dropFirst(old.count)) } } ?? resolved
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: relocated, isDirectory: &isDirectory) else { return nil }
        return relocated
    }

    /// A rename when both paths are on one volume (always true here, and
    /// instant for a 100 GB folder); a real copy otherwise. A link is moved by
    /// moving what it points at, then dropping the link itself.
    static func moveDereferencing(_ source: String, to destination: String) throws {
        let manager = FileManager.default
        let linked = isLink(source)
        guard let real = linked ? realTarget(of: source) : source else { throw CocoaError(.fileNoSuchFile) }
        do {
            try manager.moveItem(atPath: real, toPath: destination)
        } catch {
            try copyDereferencing(real, to: destination)
            try manager.removeItem(atPath: real)
        }
        if linked { try? manager.removeItem(atPath: source) }
    }

    /// Copy the weights themselves: a link inside the source folder is followed
    /// and its target's bytes are written out, so the copy never depends on the
    /// directory it came from.
    static func copyDereferencing(_ source: String, to destination: String) throws {
        let manager = FileManager.default
        if isLink(source) {
            guard let target = realTarget(of: source) else { throw CocoaError(.fileNoSuchFile) }
            try copyDereferencing(target, to: destination)
            return
        }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: source, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if !isDirectory.boolValue {
            try manager.copyItem(atPath: source, toPath: destination)
            return
        }
        try manager.createDirectory(atPath: destination, withIntermediateDirectories: true)
        for entry in try manager.contentsOfDirectory(atPath: source) {
            try copyDereferencing(source + "/" + entry, to: destination + "/" + entry)
        }
    }

    /// Replace every link below `root` with the bytes it resolves to. A hard
    /// link keeps one copy of the same file on one disk; directories cannot be
    /// hard linked, so those are copied.
    private static func inlineLinks(under root: String, moved: [String: String],
                                    report: inout AdoptionReport) {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(atPath: root) else { return }
        var links: [String] = []
        for case let entry as String in enumerator {
            let path = root + "/" + entry
            if isLink(path) { links.append(path) }
        }
        for link in links {
            let name = (link as NSString).lastPathComponent
            guard let target = realTarget(of: link, moved: moved) else {
                // The weights this assembly pointed at are gone; the folder is
                // not servable and the dead link only hides that.
                try? manager.removeItem(atPath: link)
                report.dropped.append(name)
                continue
            }
            try? manager.removeItem(atPath: link)
            do {
                try manager.linkItem(atPath: target, toPath: link)
            } catch {
                do {
                    try copyDereferencing(target, to: link)
                } catch {
                    report.failures.append(name)
                }
            }
        }
    }

    /// A folder counts as a model when it carries a weights config *and* a
    /// tokenizer, or a GGUF file of its own. Draft/assistant heads (oMLX's
    /// `DFlash2` folders, for instance) ship only `config.json` + weights and
    /// cannot be served on their own, so offering them in the picker would just
    /// produce a load failure. GGUF folders need no tokenizer: the quantized
    /// file embeds its own vocab, and all three packs serve those directly.
    static func isWeightsDirectory(_ path: String, engine: EngineID) -> Bool {
        let manager = FileManager.default
        if hasGGUF(path) { return true }
        guard manager.fileExists(atPath: path + "/config.json") else { return false }
        let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json", "chat_template.jinja",
                              "merges.txt", "vocab.json", "tokenizer.model"]
        return tokenizerFiles.contains { manager.fileExists(atPath: path + "/" + $0) }
    }

    private static func hasGGUF(_ path: String) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return files.contains {
            let lower = $0.lowercased()
            return lower.hasSuffix(".gguf") && !lower.contains("mmproj")
        }
    }

    /// 扫描元数据缓存。模型目录的字节数、上下文窗口、架构都要读盘：递归 stat
    /// 每个文件 + 解析 config.json。快照每秒推一次，一次要扫多个引擎（实测
    /// omlx 15 ms / mtplx 11 ms，每次推送 40~83 ms），主线程被反复占住——
    /// 「实时指标不流畅」的主因就在这里。目录里有哪些模型仍然实时读，只有这几项
    /// 重活进缓存，20 秒过期，下载完成/删除模型时立即失效。
    struct ScanMeta {
        var bytes: Int
        var maximumContextTokens: Int?
        var architecture: String?
    }

    private static let metaLock = NSLock()
    nonisolated(unsafe) private static var metaCache: [String: (value: ScanMeta, at: Date)] = [:]
    private static let metaTTL: TimeInterval = 20

    static func meta(of path: String) -> ScanMeta {
        metaLock.lock()
        if let hit = metaCache[path], Date().timeIntervalSince(hit.at) < metaTTL {
            metaLock.unlock()
            return hit.value
        }
        metaLock.unlock()
        // 同一个 config.json 只读一次、只解析一次：原先 contextWindow 与
        // architecture 各读一遍各解析一遍，单个模型就是 2 次文件读 + 2 次 JSON。
        let config = configFacts(path + "/config.json")
        let value = ScanMeta(bytes: size(of: path),
                             maximumContextTokens: config.window,
                             architecture: config.architecture)
        metaLock.lock()
        metaCache[path] = (value, Date())
        metaLock.unlock()
        return value
    }

    /// 下载完成、删除模型之后调用，下次扫描重新读盘。
    static func invalidateMetaCache() {
        metaLock.lock()
        metaCache.removeAll()
        metaLock.unlock()
    }

    private static func configFacts(_ path: String) -> (window: Int?, architecture: String?) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (nil, nil)
        }
        // 每条本地 config.json 都把窗口放在 text_config 下，draft 模型另有一份顶层副本。
        let window = (json["max_position_embeddings"] as? Int)
            ?? ((json["text_config"] as? [String: Any])?["max_position_embeddings"] as? Int)
        return (window, json["model_type"] as? String)
    }

    static func size(of path: String) -> Int {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(atPath: path) else { return 0 }
        var total = 0
        for case let entry as String in enumerator {
            let full = path + "/" + entry
            // 一个文件只 stat 一次（原先类型/大小各调一遍）——
            // `attributesOfItem` 内部是 stat + listxattr + getxattr，不是免费的。
            guard let attributes = try? manager.attributesOfItem(atPath: full) else { continue }
            // `attributesOfItem` reports a symlink's own size (the target-path
            // string, ~100 bytes), not the weights it points at — linked GGUF
            // folders would otherwise show up as a few KB. Resolve one hop.
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink,
               let target = try? manager.destinationOfSymbolicLink(atPath: full) {
                let resolved = target.hasPrefix("/")
                    ? target
                    : (path as NSString).appendingPathComponent(target)
                if let targetSize = try? manager.attributesOfItem(atPath: resolved)[.size] as? Int {
                    total += targetSize
                    continue
                }
            }
            total += (attributes[.size] as? Int) ?? 0
        }
        return total
    }
}
