import Foundation
import FlashCatKit

/// Reads the flashCat model folder for a pack-based engine. The folder holds
/// the weights themselves — a linked folder is not a model here, because an
/// engine has to be able to serve it after the directory it came from is gone.
enum LocalEngineModels {
    static func scan(engine: EngineID, directory: String) -> [EngineModel] {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(atPath: directory)) ?? []
        var models: [EngineModel] = []
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let path = directory + "/" + entry
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            guard isRealDirectory(path) else { continue }
            // A draft head has weights but no tokenizer — it cannot be served
            // on its own.
            guard EngineModelStore.isWeightsDirectory(path, engine: engine) else { continue }
            // 字节数/上下文/架构走缓存（见 EngineModelStore.meta）：目录里有哪些
            // 模型仍然实时读，这三个要递归 stat + 解 JSON 的字段不进推送热路径。
            let meta = EngineModelStore.meta(of: path)
            models.append(EngineModel(id: entry,
                                      path: path,
                                      bytes: meta.bytes,
                                      maximumContextTokens: meta.maximumContextTokens,
                                      loaded: false,
                                      loading: false,
                                      kind: meta.architecture,
                                      hidden: false,
                                      helper: false,
                                      engine: engine))
        }
        return models
    }

    /// A symlink is skipped, not followed: everything under the model folder is
    /// meant to be that engine's own copy of the weights.
    private static func isRealDirectory(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        return type == .typeDirectory
    }

}
