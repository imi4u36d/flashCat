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
                           architecture: meta.architecture,
                           capabilities: capabilities(at: path),
                           hidden: false,
                           helper: false,
                           engine: engine)
    }

    /// 离线判能力：目录扫描看不到 `/v1/models` 的 `capabilities`，但扩散类
    /// 权重自带 `model_index.json`，`_class_name` 就是流水线名（本地 Qwen 是
    /// `QwenImage21Pipeline`）。引擎没在跑时也要能认出图像模型，否则选中后
    /// 输入框不会切到出图模式。
    ///
    /// 视觉对话模型则靠 `vision_config`、根目录的 `mmproj*.gguf`（Splash 的
    /// 视觉投影）或 `*-VL` 架构名认；认出来要同时补 `chat`，因为 `supportsChat`
    /// 与隐藏规则都按能力位判断。
    static func capabilities(at path: String) -> [String] {
        let manager = FileManager.default
        // targetName 可能是 GGUF 文件本身；能力文件都在它所在的目录里。
        var isDirectory: ObjCBool = false
        let directory = manager.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            ? (path as NSString).deletingLastPathComponent : path
        let indexURL = URL(fileURLWithPath: directory + "/model_index.json")
        let index = (try? Data(contentsOf: indexURL))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }

        // 视频模型不一定有 model_index.json：H3 这类转换包只有 config.json、
        // transformer 和 video_vae。先看视频专属组件，避免被后面的
        // transformer + vae 规则误判成图像模型。
        let videoComponents = ["video_vae.safetensors", "video_vae.safetensors.index.json"]
        if videoComponents.contains(where: { manager.fileExists(atPath: directory + "/" + $0) }) {
            return ["video"]
        }
        if let index, let name = index["_class_name"] as? String,
           name.lowercased().contains("video") {
            return ["video"]
        }
        if let type = modelType(at: directory), isVideoModelType(type) {
            return ["video"]
        }
        // 有些仓库连 config.json 的 model_type 也不写，只能从目录名认。
        if isVideoModelType(URL(fileURLWithPath: directory).lastPathComponent) {
            return ["video"]
        }

        if let json = index {
            if let name = json["_class_name"] as? String {
                let lowered = name.lowercased()
                if lowered.contains("image") { return ["image"] }
            }
            // 有些转换包只留组件目录：transformer + vae 同时存在即扩散模型。
            if json["transformer"] != nil, json["vae"] != nil { return ["image"] }
        }
        if hasVision(at: directory) { return ["chat", "vision"] }
        return []
    }

    /// 视觉理解模型：config 里带视觉塔、目录里带 mmproj 投影，或架构名里
    /// 明确写着 VL/VLM。图像/视频生成模型已在上面提前返回，不会走到这里。
    private static func hasVision(at directory: String) -> Bool {
        let manager = FileManager.default
        if let data = try? Data(contentsOf: URL(fileURLWithPath: directory + "/config.json")),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if json["vision_config"] as? [String: Any] != nil { return true }
            let names = [json["model_type"] as? String,
                         json["architecture"] as? String]
                .compactMap { $0 }
                + ((json["architectures"] as? [String]) ?? [])
            if names.contains(where: isVisionModelType) { return true }
        }
        if let entries = try? manager.contentsOfDirectory(atPath: directory),
           entries.contains(where: {
               let lowered = $0.lowercased()
               return lowered.contains("mmproj") && lowered.hasSuffix(".gguf")
           }) {
            return true
        }
        return isVisionModelType(URL(fileURLWithPath: directory).lastPathComponent)
    }

    private static func isVisionModelType(_ raw: String) -> Bool {
        let value = raw.lowercased()
        if value.contains("vision") || value.contains("llava") || value.contains("internvl")
            || value.contains("paligemma") || value.contains("idefics") || value.contains("minicpmv")
            || value.contains("vlfor") || value.contains("vlmodel") {
            return true
        }
        let tokens = value.split { !$0.isLetter && !$0.isNumber }
        return tokens.contains("vl") || tokens.contains("vlm")
    }

    private static func modelType(at path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path + "/config.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let type = (json["model_type"] as? String) ?? (json["architecture"] as? String)
        let partition = json["partition"] as? String
        return [type, partition].compactMap { $0 }.joined(separator: " ")
    }

    /// 本地转换包的目录名/架构名。只列已知的视频家族，避免把普通对话模型
    /// 里的 "video" 字样（例如视觉理解模型）误判成视频生成。
    private static func isVideoModelType(_ raw: String) -> Bool {
        let value = raw.lowercased()
        let families = ["minimax_h3", "minimax-h3", "ltx-video", "ltx_video",
                        "wan2", "wan-2", "hunyuanvideo", "hunyuan-video",
                        "cogvideo", "mochi", "fl2va", "t2v", "i2v"]
        return families.contains { value.contains($0) }
    }

    /// A symlink is skipped, not followed: everything under the model folder is
    /// meant to be that engine's own copy of the weights.
    private static func isRealDirectory(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        return type == .typeDirectory
    }

}
