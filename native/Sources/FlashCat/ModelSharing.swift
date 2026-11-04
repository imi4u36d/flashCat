import Foundation
import FlashCatKit

/// 公共模型目录：权重只下载一份，哪些引擎能看见它由一张授权表决定。
///
/// 为什么不是「复制到每个引擎目录」：27B 的 4bit 就是 16 GB，每个引擎各存
/// 一份会让磁盘成倍膨胀，缓存目录再存一份更糟。共享目录让同一份文件同时被多个引擎
/// 服务——授权过的 pack 引擎（oMLX / MTPLX）在各自模型目录里得到一条符号链
/// 接，启动时按自己的路径加载；Splash 不需要链接，`--target` 直接指向共享
/// 目录里的绝对路径，它再用 assembly 里的软链挂上去。
///
/// 目录刻意放在 `EnginePaths.modelsRoot` 之外：根下任意两层目录都会被
/// `ModelCatalog.scanLocalModels` 当成 `owner/repo`，共享目录放进根里就会多出
/// 一行 owner = shared-models 的脏数据。
enum ModelSharing {
    static var directory: String { EnginePaths.sharedModelsDirectory }
    /// repo（`owner/repo`）→ 能看见它的引擎。splash 也在这张表里，它只是不
    /// 需要软链，但同样要记住「这个模型授权给 Splash 了」。
    static var tableFile: String { Paths.supportDirectory + "/model-shares.json" }

    // MARK: 授权表

    static func table() -> [String: Set<EngineID>] {
        guard let data = FileManager.default.contents(atPath: tableFile),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String]] else {
            return [:]
        }
        var result: [String: Set<EngineID>] = [:]
        for (repo, names) in raw {
            let engines = Set(names.compactMap(EngineID.init(rawValue:)))
            if !engines.isEmpty { result[repo] = engines }
        }
        return result
    }

    private static func write(_ table: [String: Set<EngineID>]) {
        var raw: [String: [String]] = [:]
        for (repo, engines) in table where !engines.isEmpty {
            raw[repo] = EngineCatalog.allIDs.filter { engines.contains($0) }.map(\.rawValue)
        }
        Paths.ensureDirectory(Paths.supportDirectory)
        guard let data = try? JSONSerialization.data(withJSONObject: raw,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: tableFile), options: .atomic)
    }

    static func engines(for repo: String) -> Set<EngineID> {
        table()[canonical(repo)] ?? []
    }

    /// 改了某个模型的可见引擎：写表，然后让磁盘跟上。
    static func setEngines(_ engines: Set<EngineID>, for repo: String) {
        var current = table()
        let key = canonical(repo)
        if engines.isEmpty {
            current.removeValue(forKey: key)
        } else {
            current[key] = engines
        }
        write(current)
        synchronize()
    }

    static func forget(_ repo: String) {
        setEngines([], for: repo)
    }

    // MARK: 路径

    /// 与各引擎的扁平命名一致：`owner--repo`。
    static func folder(for repo: String) -> String { ModelInstaller.folderName(for: repo) }
    static func path(for repo: String) -> String { directory + "/" + folder(for: repo) }
    static func repo(forFolder name: String) -> String {
        name.replacingOccurrences(of: "--", with: "/")
    }

    /// 卡片上的 id 可能是扁平的 `owner--repo`，也可能带 `:VARIANT` 后缀。
    static func canonical(_ id: String) -> String {
        let base = id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id
        return repo(forFolder: base)
    }

    /// 共享模型在某个引擎目录里的链接路径。
    static func linkPath(engine: EngineID, repo: String) -> String {
        let root = EnginePaths.modelsDirectory(engine)
        switch engine.descriptor.modelLayout {
        case .nested:
            return root + "/" + repo
        case .flat, .external:
            return root + "/" + folder(for: repo)
        }
    }

    /// 这份权重是不是共享目录里的（而不是某个引擎自己目录里的副本）。
    static func isShared(_ id: String) -> Bool {
        Paths.fileExists(path(for: canonical(id)))
    }

    /// 这个模型该不该出现在某个引擎的列表里。公共目录里的权重不是每个引擎
    /// 都看得见，没授权的就不列——列出来点了也用不了。
    static func visible(_ id: String, engine: EngineID) -> Bool {
        guard isShared(id) else { return true }
        return engines(for: id).contains(engine)
    }

    // MARK: 扫描

    /// 共享目录里已经成形的权重。判据与引擎目录一致（`isWeightsDirectory`），
    /// 半下载的目录不会成行——下载中心那一行还在，卡片继续显示进度。
    static func scan() -> [ModelInfo] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: directory)) ?? []
        var models: [ModelInfo] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let path = directory + "/" + name
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard !manager.fileExists(atPath: path + ".flashcat-incomplete") else { continue }
            guard EngineModelStore.isWeightsDirectory(path, engine: .omlx) else { continue }
            models.append(model(repo: repo(forFolder: name), path: path))
        }
        return models
    }

    static func model(repo: String, path: String) -> ModelInfo {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(atPath: path)) ?? []
        let lower = files.map { ($0, $0.lowercased()) }
        let gguf = lower.filter { $0.1.hasSuffix(".gguf") && !$0.1.contains("mmproj") }
            .map(\.0).sorted().first
        let mmproj = lower.first { $0.1.hasSuffix(".gguf") && $0.1.contains("mmproj") }?.0
        // 草稿头只在这两个目录名下出现过（oMLX 的 DFlash2 目录、Splash 的 draft），
        // 单独的草稿头没有 tokenizer，扫不出来，只能顺着主模型找。
        let draft = ["draft", "dflash2"].first { manager.fileExists(atPath: path + "/" + $0 + "/config.json") }
        return ModelInfo(id: repo,
                         path: path,
                         bytes: EngineModelStore.meta(of: path).bytes,
                         origin: .local,
                         targetName: gguf.map { path + "/" + $0 } ?? path,
                         family: nil,
                         draftPath: draft.map { path + "/" + $0 },
                         mmprojPath: mmproj.map { path + "/" + $0 })
    }

    // MARK: 链接

    /// 让磁盘与授权表保持一致：授权过的 pack 引擎有一条指向共享目录的软链，
    /// 没授权的删掉。Splash 不建链——它按 `--target` 的绝对路径加载。
    ///
    /// 只清理目标是共享目录的软链：引擎目录里用户自己放的权重或链接，一条都
    /// 不碰。
    static func synchronize() {
        let manager = FileManager.default
        let table = table()
        for id in EngineCatalog.allIDs where id.adapter != .splash {
            let root = EnginePaths.modelsDirectory(id)
            let allowed = Set(
                table.filter { $0.value.contains(id) }
                    .map { path(for: $0.key) }
            )
            for full in modelLinks(under: root, nested: id.descriptor.modelLayout == .nested) {
                guard let target = try? manager.destinationOfSymbolicLink(atPath: full) else { continue }
                let absolute = target.hasPrefix("/")
                    ? target
                    : (full as NSString).deletingLastPathComponent + "/" + target
                let normalized = URL(fileURLWithPath: absolute).standardizedFileURL.path
                if normalized.hasPrefix(directory + "/"), !allowed.contains(normalized) {
                    try? manager.removeItem(atPath: full)
                }
            }
            for (repo, engines) in table where engines.contains(id) {
                guard Paths.fileExists(path(for: repo)) else { continue }
                let link = linkPath(engine: id, repo: repo)
                if let target = try? manager.destinationOfSymbolicLink(atPath: link) {
                    if target == path(for: repo) { continue }
                    try? manager.removeItem(atPath: link)
                } else if Paths.fileExists(link) {
                    // 引擎目录里已经有同名实体权重，保持用户的副本不动。
                    continue
                }
                Paths.ensureDirectory(root)
                if id.descriptor.modelLayout == .nested {
                    Paths.ensureDirectory((link as NSString).deletingLastPathComponent)
                }
                try? manager.createSymbolicLink(atPath: link, withDestinationPath: path(for: repo))
            }
        }
    }

    private static func modelLinks(under root: String, nested: Bool) -> [String] {
        let manager = FileManager.default
        var result: [String] = []
        for name in (try? manager.contentsOfDirectory(atPath: root)) ?? [] where !name.hasPrefix(".") {
            let full = root + "/" + name
            let type = (try? manager.attributesOfItem(atPath: full)[.type]) as? FileAttributeType
            if type == .typeSymbolicLink {
                result.append(full)
                continue
            }
            guard nested, type == .typeDirectory else { continue }
            for child in (try? manager.contentsOfDirectory(atPath: full)) ?? [] where !child.hasPrefix(".") {
                let path = full + "/" + child
                let childType = (try? manager.attributesOfItem(atPath: path)[.type]) as? FileAttributeType
                if childType == .typeSymbolicLink { result.append(path) }
            }
        }
        return result
    }
}
