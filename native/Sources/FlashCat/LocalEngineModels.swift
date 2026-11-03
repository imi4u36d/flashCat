import Foundation
import FlashCatKit

/// Reads the flashCat model folder for a pack-based engine. The folder holds
/// the weights themselves — a linked folder is not a model here, because an
/// engine has to be able to serve it after the directory it came from is gone.
enum LocalEngineModels {
    static func scan(engine: EngineID, directory: String) -> [EngineModel] {
        let manager = FileManager.default
        let scanRoot: String
        if engine.descriptor.modelLayout == .external {
            let managed = directory + "/models"
            scanRoot = Paths.fileExists(managed) ? managed : directory
        } else {
            scanRoot = directory
        }
        let entries = (try? manager.contentsOfDirectory(atPath: scanRoot)) ?? []
        var models: [EngineModel] = []
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let path = scanRoot + "/" + entry
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            guard isRealDirectory(path) else { continue }
            if EngineModelStore.isWeightsDirectory(path, engine: engine) {
                models.append(model(id: canonicalID(entry, engine: engine), path: path, engine: engine))
                continue
            }
            guard engine.descriptor.modelLayout == .nested else { continue }
            // Hugging Face-native engines keep `owner/repo`.
            let children = (try? manager.contentsOfDirectory(atPath: path)) ?? []
            for child in children.sorted() where !child.hasPrefix(".") {
                let childPath = path + "/" + child
                var childDirectory: ObjCBool = false
                guard manager.fileExists(atPath: childPath, isDirectory: &childDirectory),
                      childDirectory.boolValue,
                      isRealDirectory(childPath),
                      EngineModelStore.isWeightsDirectory(childPath, engine: engine) else { continue }
                models.append(model(id: canonicalID(entry + "/" + child, engine: engine),
                                    path: childPath,
                                    engine: engine))
            }
        }
        return models
    }

    private static func canonicalID(_ raw: String, engine: EngineID) -> String {
        guard engine.adapter == .strata else { return raw }
        let lower = raw.lowercased()
        guard lower.contains("qwen3.8-flash-next") else { return raw }
        if lower.contains("iq3_xxs") { return "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:IQ3_XXS" }
        if lower.contains("iq3_s") { return "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:IQ3_S" }
        if lower.contains("iq2_xs") { return "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:IQ2_XS" }
        return "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0"
    }

    private static func model(id: String, path: String, engine: EngineID) -> EngineModel {
        let meta = EngineModelStore.meta(of: path)
        return EngineModel(id: id,
                           path: path,
                           bytes: meta.bytes,
                           maximumContextTokens: meta.maximumContextTokens,
                           loaded: false,
                           loading: false,
                           kind: meta.architecture,
                           hidden: false,
                           helper: false,
                           engine: engine)
    }

    /// A symlink is skipped, not followed: everything under the model folder is
    /// meant to be that engine's own copy of the weights.
    private static func isRealDirectory(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        return type == .typeDirectory
    }

}
