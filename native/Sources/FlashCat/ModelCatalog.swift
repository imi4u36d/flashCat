import Foundation
import FlashCatKit

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
    var draftRepositories: [String: String] = [:]

    var machine: [ModelInfo] {
        var seen = Set<String>()
        var result = [ModelInfo]()
        for model in local + installed where seen.insert(model.id).inserted {
            result.append(model)
        }
        return result.sorted { $0.id.lowercased() < $1.id.lowercased() }
    }

    func localModel(_ id: String) -> ModelInfo? {
        local.first { $0.id == id }
    }

    func machineModel(_ id: String) -> ModelInfo? {
        machine.first { $0.id == id }
    }

    func draftRepository(_ modelId: String, family: String?) -> String? {
        SplashDraft.repository(for: modelId, family: family, familyDrafts: draftRepositories)
    }
}

final class ModelCatalogService {
    func load() -> ModelCatalog {
        var catalog = ModelCatalog()
        let splashModels = EnginePaths.modelsDirectory(.splash)
        catalog.local = scanLocalModels(splashModels) + ModelSharing.scan()
        catalog.installed = scanSplash(splashModels)
        catalog.draftRepositories = splashPackRuntime?.draftRepositories ?? [:]
        return catalog
    }

    private var splashPackRuntime: EngineRuntime? {
        guard let root = EngineInstallations.newest(.splash, version: nil)?.root.path else { return nil }
        return EngineRuntime(root: root)
    }

    @discardableResult
    func migrateLegacyDirectories() -> ModelStorageMigration.Report {
        ModelStorageMigration.migrate()
    }

    /// Deleting is the only mutating action left on a model now that importing
    /// is gone, so the error is about the folder, not a copy.
    struct CatalogError: Error { let message: String }

    func deleteLocal(_ model: ModelInfo) throws {
        // Splash 的行是 `.resolved` 里的装配体（`origin == .splash`），和
        // `.local` 一样是 flashCat 自己下进模型目录的东西，同样可删；只有
        // 目录里的建议行没有实体，才拒绝。
        if model.origin == .recommended {
            throw CatalogError(message: "这款模型还没有下载，没有可删除的权重")
        }
        try? FileManager.default.removeItem(atPath: model.path)
        try? FileManager.default.removeItem(atPath: model.path + ".flashcat-incomplete")
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
            // 共享模型单独一份（`<support>/shared-models`），归属由授权表决定，
            // 不能在这里被当成某个 owner 的仓库扫进来。
            if basename(owner) == (EnginePaths.sharedModelsDirectory as NSString).lastPathComponent { continue }
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
        // A download still in flight (or canceled) leaves this marker; the
        // folder may already carry config.json, but it is not servable yet.
        if Paths.fileExists(repository + ".flashcat-incomplete") { return nil }
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
        guard let modelId = Self.repositoryId(from: id) else { return nil }

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

    /// 装配体里的 `model` 在 splash 1.4 是 `owner/repo`，1.5 改成了权重的绝对
    /// 路径（GGUF 文件或 MLX 目录）。菜单、引擎和授权表都按 `owner/repo` 寻址，
    /// 直接把路径当 id 会在切换器里多出一条以 `.gguf` 结尾的假模型，选中它也
    /// 永远找不到允许的权重，所以这里把路径收回成仓库 id。
    static func repositoryId(from raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        value = value.replacingOccurrences(of: "\\", with: "/")
        let lowered = value.lowercased()
        if lowered.hasSuffix(".gguf") || lowered.hasSuffix(".safetensors") {
            value = (value as NSString).deletingLastPathComponent
        }
        if value.hasPrefix("/") {
            let name = (value as NSString).lastPathComponent
            let owner = ((value as NSString).deletingLastPathComponent as NSString).lastPathComponent
            guard !name.isEmpty, !owner.isEmpty, !owner.hasPrefix(".") else { return nil }
            return owner + "/" + name
        }
        guard value.contains("/") else { return nil }
        return value
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
}
