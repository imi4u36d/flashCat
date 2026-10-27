import Foundation

enum ModelOrigin: String {
    case local = "本地"
    case splash = "已安装"
    case recommended = "推荐"
}

struct ModelInfo: Identifiable {
    let id: String
    let path: String
    let bytes: Int
    let origin: ModelOrigin
    var targetName: String
    var family: String?
    var draftPath: String?
    var mmprojPath: String?
    /// A suggestion's size comes from the Hub page, not from a scan of the
    /// files, so the card marks it as approximate instead of claiming a
    /// measurement it never took.
    var approximateSize = false

    var shortName: String { id.split(separator: "/").last.map(String.init) ?? id }
    var sizeText: String { bytes > 0 && approximateSize ? "≈" + Format.size(bytes) : Format.size(bytes) }
    var exists: Bool { Paths.fileExists(path) }
}

struct ModelCatalog {
    var local: [ModelInfo] = []
    var installed: [ModelInfo] = []
    var recommended: [String] = []
    var draftRepositories: [String: String] = [:]

    var machine: [ModelInfo] {
        var seen = Set<String>()
        var result = [ModelInfo]()
        for model in local + installed where seen.insert(model.id).inserted {
            result.append(model)
        }
        return result.sorted { $0.id.lowercased() < $1.id.lowercased() }
    }

    var missingRecommendations: [String] {
        recommended.filter { id in !machine.contains { $0.id == id } }
    }

    func localModel(_ id: String) -> ModelInfo? {
        local.first { $0.id == id }
    }

    func machineModel(_ id: String) -> ModelInfo? {
        machine.first { $0.id == id }
    }

    func draftRepository(_ modelId: String, family: String?) -> String? {
        var candidates: [String] = Array(draftRepositories.keys)
        if let family = family, !family.isEmpty { candidates.insert(family, at: 0) }
        candidates.sort { Self.fold($1).count < Self.fold($0).count }
        let folded = Self.fold(modelId)
        for candidate in candidates {
            let needle = Self.fold(candidate)
            if !needle.isEmpty && folded.contains(needle) {
                let repo = draftRepositories[candidate]
                return repo == nil || repo!.isEmpty ? nil : repo
            }
        }
        return nil
    }

    private static func fold(_ value: String) -> String {
        value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

final class ModelCatalogService {
    func load(runtime: EngineRuntime?) -> ModelCatalog {
        var catalog = ModelCatalog()
        catalog.local = scanLocalModels(Paths.modelsDirectory)
        catalog.installed = scanSplash(Paths.splashModelsDirectory)
        catalog.recommended = runtime?.suggestedModels ?? []
        catalog.draftRepositories = runtime?.draftRepositories ?? [:]
        return catalog
    }

    func migrateLegacyDirectory() {
        let legacy = Paths.legacyModelsDirectory
        let target = Paths.modelsDirectory
        if !Paths.fileExists(legacy) || legacy == target { return }
        Paths.ensureDirectory(target)
        for owner in directories(legacy) {
            for repo in directories(owner) {
                let destination = target + "/" + basename(owner) + "/" + basename(repo)
                if Paths.fileExists(destination) { continue }
                Paths.ensureDirectory(destination)
                try? FileManager.default.moveItem(atPath: repo, toPath: destination)
            }
        }
    }

    struct ImportResult { let id: String; let destination: String }
    struct ImportError: Error { let message: String }

    /// Copy (or move) a model folder into an engine's model directory —
    /// `~/.flashcat/models` for Splash, `~/.flashcat/models/<engine>` for the
    /// rest — so importing works the same for every engine.
    func importDirectory(_ source: String, move: Bool, into root: String = Paths.modelsDirectory,
                         flatten: Bool = false, progress: (Double, String) -> Void) throws -> ImportResult {
        guard Paths.fileExists(source) else { throw ImportError(message: "选择的目录不存在") }
        let files = allFiles(source)
        let hasWeights = files.contains {
            let lower = $0.lowercased()
            if lower.hasSuffix(".gguf") { return lower.contains("mmproj") == false }
            return lower.hasSuffix(".safetensors")
        }
        if !hasWeights { throw ImportError(message: "目录里没有找到 .gguf 或 .safetensors 权重文件") }

        let owner = sanitize(basename((source as NSString).deletingLastPathComponent))
        let repo = sanitize(basename(source))
        // Splash reads `<owner>/<repo>`, the packaged engines read flat
        // `<owner>--<repo>` folders, so the destination shape follows the root.
        let id = flatten ? "\(owner)--\(repo)" : "\(owner)/\(repo)"
        let destination = root + "/" + id
        if Paths.fileExists(destination) { throw ImportError(message: "\(id) 已经存在") }

        Paths.ensureDirectory(destination)
        let total = files.reduce(0) { $0 + fileSize($1) }
        var completed = 0

        if move {
            if (try? FileManager.default.moveItem(atPath: source, toPath: destination)) != nil {
                progress(1, "已移动 \(id)")
                return ImportResult(id: id, destination: destination)
            }
        }

        for file in files {
            var relative = (file as NSString).substring(from: source.count)
            while relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
            let output = destination + "/" + relative
            Paths.ensureDirectory((output as NSString).deletingLastPathComponent)
            if move {
                try? FileManager.default.moveItem(atPath: file, toPath: output)
            } else {
                try? FileManager.default.copyItem(atPath: file, toPath: output)
            }
            completed += fileSize(output)
            progress(total == 0 ? 1 : Double(completed) / Double(total), "正在复制 " + basename(file))
        }

        if move { try? FileManager.default.removeItem(atPath: source) }
        return ImportResult(id: id, destination: destination)
    }

    func deleteLocal(_ model: ModelInfo) throws {
        if model.origin != .local {
            throw ImportError(message: "只能删除 flashCat 本地模型目录中的模型")
        }
        try? FileManager.default.removeItem(atPath: model.path)
        let parent = (model.path as NSString).deletingLastPathComponent
        if Paths.fileExists(parent), let items = try? FileManager.default.contentsOfDirectory(atPath: parent), items.isEmpty {
            try? FileManager.default.removeItem(atPath: parent)
        }
    }

    // MARK: scanning

    private func scanLocalModels(_ root: String) -> [ModelInfo] {
        var result: [ModelInfo] = []
        guard Paths.fileExists(root) else { return result }
        for owner in directories(root) {
            for repo in directories(owner) {
                if let parsed = parseRepository(repo) { result.append(parsed) }
            }
        }
        return result
    }

    private func scanSplash(_ root: String) -> [ModelInfo] {
        var result: [ModelInfo] = []
        var seen = Set<String>()
        guard Paths.fileExists(root) else { return result }

        let resolved = root + "/.resolved"
        for assembly in directories(resolved) {
            if let parsed = parseAssembly(assembly), seen.insert(parsed.id).inserted {
                result.append(parsed)
            }
        }
        for owner in directories(root) {
            for repo in directories(owner) {
                let fallback = basename(owner) + "/" + basename(repo)
                if let parsed = parseAssembly(repo, fallbackId: fallback), seen.insert(parsed.id).inserted {
                    result.append(parsed)
                }
            }
        }
        return result
    }

    private func parseRepository(_ repository: String) -> ModelInfo? {
        let entries = entriesOf(repository)
        let hasConfig = entries.contains { basename($0) == "config.json" }
        let ggufs = entries.filter {
            $0.lowercased().hasSuffix(".gguf") && !$0.lowercased().contains("mmproj")
        }.sorted { splitPart($0) < splitPart($1) }
        let mmproj = entries.first {
            $0.lowercased().hasSuffix(".gguf") && $0.lowercased().contains("mmproj")
        }
        if ggufs.isEmpty && !hasConfig { return nil }

        let target = ggufs.first
        var draft: String?
        for directory in directories(repository) {
            let name = basename(directory).lowercased()
            if (name == "draft" || name == "dflash2")
                && Paths.fileExists(directory + "/config.json") {
                draft = directory
                break
            }
        }

        var bytes = 0
        for file in allFiles(repository) { bytes += fileSize(file) }

        let parent = (repository as NSString).deletingLastPathComponent
        return ModelInfo(
            id: basename(parent) + "/" + basename(repository),
            path: repository,
            bytes: bytes,
            origin: .local,
            targetName: target ?? repository,
            draftPath: draft,
            mmprojPath: mmproj
        )
    }

    private func parseAssembly(_ assembly: String, fallbackId: String? = nil) -> ModelInfo? {
        var id: String?
        var family: String?
        var bytes = 0
        if let json = EngineRuntime.readJSON(assembly + "/model.json") as? [String: Any] {
            id = json["model"] as? String
            family = json["family"] as? String
            if let files = json["files"] as? [String: Any] {
                for value in files.values {
                    if let item = value as? [String: Any], let count = item["bytes"] as? Double {
                        bytes += Int(count)
                    }
                }
            }
        }
        id = id ?? fallbackId
        guard let modelId = id, modelId.contains("/") else { return nil }

        // An assembly is served from its target directory. The path has to be
        // absolute: flashcat_serve.py resolves a relative --target against the
        // runtime, not against the models directory, so "target" pointed at
        // <runtime>/target and every installed model failed to start.
        let targetDirectory = assembly + "/target"
        guard Paths.fileExists(targetDirectory) else { return nil }
        let draft = assembly + "/draft"

        return ModelInfo(
            id: modelId,
            path: assembly,
            bytes: bytes,
            origin: .splash,
            targetName: targetDirectory,
            family: family,
            draftPath: Paths.fileExists(draft) ? draft : nil
        )
    }

    private func splitPart(_ path: String) -> Int {
        if let match = TextPattern.firstMatch("-(\\d{5})-of-\\d{5}\\.gguf$", path),
           let part = Int(match[1]) {
            return part
        }
        return Int.max
    }

    private func directories(_ root: String) -> [String] {
        var result: [String] = []
        for item in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            if item.hasPrefix(".") { continue }
            var isDirectory: ObjCBool = false
            let path = root + "/" + item
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue {
                result.append(path)
            }
        }
        return result
    }

    private func entriesOf(_ root: String) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return items.map { root + "/" + $0 }
    }

    private func allFiles(_ root: String) -> [String] {
        var result: [String] = []
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                                                             includingPropertiesForKeys: nil) else {
            return result
        }
        for item in enumerator {
            guard let url = item as? URL else { continue }
            if Paths.fileExists(url.path) { result.append(url.path) }
        }
        return result
    }

    private func fileSize(_ path: String) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return 0 }
        return attributes[FileAttributeKey.size] as? Int ?? 0
    }

    private func basename(_ path: String) -> String { (path as NSString).lastPathComponent }

    private func sanitize(_ value: String) -> String {
        let cleaned = TextPattern.replace("[^A-Za-z0-9_.-]", value, with: "-")
        return cleaned.isEmpty ? "model" : cleaned
    }
}
