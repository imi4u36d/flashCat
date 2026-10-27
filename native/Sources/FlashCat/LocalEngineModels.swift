import Foundation
import FlashCatKit

/// Reads the flashCat model folder for a pack-based engine. The entries are
/// symlinks into weights the user already has, so sizes are resolved without
/// copying anything.
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
            // A broken link is a model the user deleted upstream, and a draft
            // head has weights but no tokenizer — neither can be served alone.
            guard EngineModelLinker.isWeightsDirectory(path, engine: engine) else { continue }
            models.append(EngineModel(id: entry,
                                      path: path,
                                      bytes: EngineModelLinker.size(of: path),
                                      maximumContextTokens: contextWindow(path + "/config.json"),
                                      loaded: false,
                                      loading: false,
                                      kind: architecture(path + "/config.json"),
                                      hidden: false,
                                      helper: false,
                                      engine: engine))
        }
        return models
    }

    /// Every local `config.json` keeps the window under `text_config`, except the
    /// draft models that also carry a top-level copy.
    private static func contextWindow(_ path: String) -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let top = json["max_position_embeddings"] as? Int { return top }
        if let text = json["text_config"] as? [String: Any],
           let nested = text["max_position_embeddings"] as? Int { return nested }
        return nil
    }

    private static func architecture(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return json["model_type"] as? String
    }
}
