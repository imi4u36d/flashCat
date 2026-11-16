// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 不可变的遥测文档：`json` 是解析后的字典，创建后只读。并发拉取时需要在
/// 任务之间传递，语义上安全，因此显式声明 `@unchecked Sendable`。
public struct EngineTelemetryDocument: @unchecked Sendable {
    public let source: EngineTelemetrySource
    public let json: [String: Any]

    public init(source: EngineTelemetrySource, json: [String: Any]) {
        self.source = source
        self.json = json
    }
}

/// 把各引擎自报的遥测折成引擎中立的 `EngineStatus`。
///
/// 三家引擎几乎没有一致的地方：splash 把一切嵌在 `metrics`/`instance` 下，oMLX
/// 是一份扁平的 `/api/status`，MTPLX 的真相分散在 `/health`（pid、模型）、
/// `/v1/mtplx/snapshot`（实时数字）与 `/v1/models`（上下文长度）里。
///
/// 「谁长什么样」现在只写在 `EngineStatusDialects` 的方言表里；这里只负责按
/// descriptor 声明的角色顺序折叠、合并（`merge`）与排序（`rank`），不再认识
/// 任何引擎 id 或 adapter。
public enum EngineStatusParser {

    /// Parse every telemetry source a descriptor asks for and merge it into one
    /// engine-neutral snapshot. Adding a new reporting format no longer means
    /// adding another engine-id branch in the controller.
    public static func parse(
        documents: [EngineTelemetryDocument],
        fallbackState: EngineRunState = .ready
    ) -> EngineStatus {
        var result = EngineStatus(state: fallbackState)
        let ordered = documents.sorted {
            rank($0.source.role) < rank($1.source.role)
        }
        // health 文档只对自己的格式有意义（MTPLX 的身份在 `/health` 里），其余
        // 方言不用它；统一传进去，由方言决定读不读。
        let health = documents.first { $0.source.role == .health }?.json
        for document in ordered {
            // 每个文档按它自己声明的格式查方言：核心这里不认识任何引擎。
            let next = EngineStatusDialects.fold(
                document.source.format,
                json: document.json,
                health: health,
                fallbackState: fallbackState)
            merge(next, into: &result)
        }
        return result
    }

    private static func rank(_ role: EngineTelemetryRole) -> Int {
        switch role {
        case .health: return 0
        case .status: return 1
        case .metrics: return 2
        case .props: return 3
        case .inventory: return 4
        }
    }

    private static func merge(_ next: EngineStatus, into result: inout EngineStatus) {
        if next.state != .ready || result.state == .stopped { result.state = next.state }
        if let value = next.model, !value.isEmpty { result.model = value }
        if !next.loadedModels.isEmpty { result.loadedModels = next.loadedModels }
        // 速率与它的粒度必须**成对**合并。文档按 health → status → metrics →
        // props → inventory 的顺序折叠，后到的会覆盖数值；如果只让数值覆盖、
        // 粒度另外取最强，就会出现「数值是后来的累计均值、角标却写着 LIVE」。
        // 所以只有来源粒度不弱于当前时才整对替换：更好的来源（`.live`）不会被
        // 后面端点的均值洗掉，均值也不会冒充实时。
        if let value = next.decodeTokensPerSecond, value > 0,
            next.decodeRateKind.rank >= result.decodeRateKind.rank
        {
            result.decodeTokensPerSecond = value
            result.decodeRateKind = next.decodeRateKind
        }
        if let value = next.prefillTokensPerSecond, value > 0,
            next.prefillRateKind.rank >= result.prefillRateKind.rank
        {
            result.prefillTokensPerSecond = value
            result.prefillRateKind = next.prefillRateKind
        }
        if let value = next.lifetimeDecodeTokensPerSecond, value > 0 {
            result.lifetimeDecodeTokensPerSecond = value
        }
        if let value = next.draftAcceptance { result.draftAcceptance = value }
        if let value = next.ttftMilliseconds, value > 0,
            next.ttftKind.rank >= result.ttftKind.rank
        {
            result.ttftMilliseconds = value
            result.ttftKind = next.ttftKind
        }
        if next.activeRequests > 0 || result.activeRequests == 0 { result.activeRequests = next.activeRequests }
        if next.queuedRequests > 0 { result.queuedRequests = next.queuedRequests }
        if next.requestsCompleted > 0 { result.requestsCompleted = next.requestsCompleted }
        if next.requestsFailed > 0 { result.requestsFailed = next.requestsFailed }
        if let value = next.memoryBytes { result.memoryBytes = value }
        if let value = next.peakMemoryBytes { result.peakMemoryBytes = value }
        if let value = next.maximumContextTokens { result.maximumContextTokens = value }
        if let value = next.startedAt { result.startedAt = value }
        if let value = next.uptimeSeconds { result.uptimeSeconds = value }
        if let value = next.processIdentifier { result.processIdentifier = value }
        if let value = next.detail { result.detail = value }
        if let value = next.reasoningEfforts, !value.isEmpty { result.reasoningEfforts = value }
        result.extras.merge(next.extras) { _, new in new }
    }

    public static func parse(
        engine: EngineID,
        status: [String: Any]?,
        health: [String: Any]?,
        fallbackState: EngineRunState = .ready
    ) -> EngineStatus {
        // 「只有一份状态文档」的引擎走这张 adapter → 格式的表。strata 与
        // mlx-serve 的状态分散在多份文档里，这份老接口对它们只能给空状态，
        // 上层应当改用 `parse(documents:)`。
        guard let format = EngineStatusDialects.primaryStatusFormat[engine.adapter] else {
            return EngineStatus(state: fallbackState)
        }
        return EngineStatusDialects.fold(
            format,
            json: status ?? [:],
            health: health,
            fallbackState: fallbackState)
    }

    /// Read `/v1/models/status` into model rows. `models` is a flat array; the
    /// scalar siblings (`loaded_count`, `current_model_memory`) describe the pool.
    public static func omlxModels(_ json: [String: Any]) -> (models: [EngineModel], loadedCount: Int, memoryUsed: Int?)
    {
        let entries = (json["models"] as? [[String: Any]]) ?? []
        var models: [EngineModel] = []
        for entry in entries {
            guard let id = JSONValue.string(entry["id"]), !id.isEmpty else { continue }
            models.append(
                EngineModel(
                    id: id,
                    path: JSONValue.string(entry["model_path"]),
                    bytes: JSONValue.int(entry["actual_size"]) ?? JSONValue.int(entry["estimated_size"]),
                    maximumContextTokens: JSONValue.int(entry["max_context_window"])
                        ?? JSONValue.int(entry["model_context_length"]),
                    loaded: JSONValue.bool(entry["loaded"]) ?? false,
                    loading: JSONValue.bool(entry["is_loading"]) ?? false,
                    kind: JSONValue.string(entry["engine_type"]) ?? JSONValue.string(entry["model_type"]),
                    capabilities: capabilities(of: entry),
                    hidden: JSONValue.bool(entry["is_hidden"]) ?? false,
                    helper: JSONValue.bool(entry["is_helper"]) ?? false,
                    engine: .omlx))
        }
        models.sort { $0.id.lowercased() < $1.id.lowercased() }
        return (
            models,
            JSONValue.int(json["loaded_count"]) ?? models.filter { $0.loaded }.count,
            JSONValue.int(json["current_model_memory"])
        )
    }

    /// 从 `/v1/models`（或 `/v1/models/status`）的一条记录里读能力位。
    /// 各引擎写法不一致：mlx-serve/strata 报 `capabilities`，Splash 报
    /// `vision` + `input_modalities`，MTPLX 报 `supports_vision` +
    /// `modalities.input`。视觉模型统一补 `chat`，否则按能力位筛对话模型的
    /// 界面会把它当成非对话权重藏起来。
    static func capabilities(of entry: [String: Any]) -> [String] {
        var capabilities = entry["capabilities"] as? [String] ?? []
        let lower = Set(capabilities.map { $0.lowercased() })
        if lower.contains("image") || lower.contains("video") { return capabilities }

        var seesImages = lower.contains("vision")
        if JSONValue.digBool(
            entry, "vision", "supports_vision", "has_vision",
            "vision.enabled") == true
        {
            seesImages = true
        }
        let modalities =
            (entry["input_modalities"] as? [String])
            ?? (JSONValue.dig(entry, "modalities.input") as? [String])
            ?? (JSONValue.dig(entry, "meta.input_modalities") as? [String])
        if let modalities, modalities.contains(where: { $0.lowercased() == "image" }) {
            seesImages = true
        }
        let kinds = [
            entry["model_type"], entry["engine_type"], entry["architecture"],
            JSONValue.dig(entry, "meta.model_type"),
            JSONValue.dig(entry, "meta.architecture"),
        ]
        .compactMap { JSONValue.string($0)?.lowercased() }
        if kinds.contains(where: isVisionKind) { seesImages = true }

        guard seesImages else { return capabilities }
        if !capabilities.contains(where: { $0.lowercased() == "chat" }) {
            capabilities.append("chat")
        }
        if !capabilities.contains(where: { $0.lowercased() == "vision" }) {
            capabilities.append("vision")
        }
        return capabilities
    }

    /// `qwen2_5_vl` / `qwen3-vl` / `llava` 这类命名算视觉模型。
    private static func isVisionKind(_ text: String) -> Bool {
        if text.contains("vision") || text.contains("llava") || text.contains("internvl")
            || text.contains("paligemma") || text.contains("idefics") || text.contains("minicpmv")
            || text.contains("vlfor") || text.contains("vlmodel")
        {
            return true
        }
        let tokens = text.split { !$0.isLetter && !$0.isNumber }
        return tokens.contains("vl") || tokens.contains("vlm")
    }

    /// `/v1/models` is OpenAI-shaped on every engine; packs add context fields
    /// and may list both loaded and unloaded models.
    public static func openAIModels(_ json: [String: Any], engine: EngineID) -> [EngineModel] {
        let entries = (json["data"] as? [[String: Any]]) ?? []
        var models: [EngineModel] = []
        for entry in entries {
            guard let id = JSONValue.string(entry["id"]), !id.isEmpty else { continue }
            let state = JSONValue.digString(entry, "status.value", "state")
            let loaded =
                JSONValue.bool(entry["loaded"])
                ?? (state.map { $0.lowercased() == "loaded" || $0.lowercased() == "ready" })
                ?? (state?.lowercased() == "unloaded" ? false : true)
            let loading = state?.lowercased() == "loading"
            let parsedCapabilities = capabilities(of: entry)
            models.append(
                EngineModel(
                    id: id,
                    path: nil,
                    bytes: JSONValue.int(entry["bytes_on_disk"]),
                    maximumContextTokens: JSONValue.int(entry["max_context_length"])
                        ?? JSONValue.int(entry["context_length"])
                        ?? JSONValue.digInt(entry, "meta.n_ctx", "meta.context_length"),
                    loaded: loaded,
                    loading: loading,
                    kind: parsedCapabilities.first ?? JSONValue.string(entry["capability"])
                        ?? JSONValue.digString(entry, "meta.engine", "meta.architecture"),
                    architecture: JSONValue.digString(entry, "meta.architecture"),
                    capabilities: parsedCapabilities,
                    // 图像与视频模型都是对话页的合法选择，不再按「不含 chat 就隐藏」
                    // 处理；嵌入这类辅助权重继续藏起来。
                    hidden: parsedCapabilities.isEmpty
                        ? false
                        : {
                            let lower = Set(parsedCapabilities.map { $0.lowercased() })
                            return !lower.contains("chat") && !lower.contains("image") && !lower.contains("video")
                        }(),
                    helper: false,
                    engine: engine))
        }
        return models
    }

    // MARK: 兼容入口
    //
    // 这几个函数是给「只有一份状态文档」的调用方与测试用的。解析全在
    // `EngineStatusDialects` 的方言表里，这里只把格式名钉死，签名保持原样。

    public static func splash(
        status json: [String: Any],
        fallbackState: EngineRunState = .ready
    ) -> EngineStatus {
        EngineStatusDialects.fold(.splashStatus, json: json, fallbackState: fallbackState)
    }

    public static func omlx(
        status json: [String: Any],
        health: [String: Any]? = nil,
        fallbackState: EngineRunState = .ready
    ) -> EngineStatus {
        EngineStatusDialects.fold(
            .omlxStatus,
            json: json,
            health: health,
            fallbackState: fallbackState)
    }

    public static func mtplx(
        snapshot json: [String: Any],
        health: [String: Any]? = nil,
        fallbackState: EngineRunState = .ready
    ) -> EngineStatus {
        EngineStatusDialects.fold(
            .mtplxSnapshot,
            json: json,
            health: health,
            fallbackState: fallbackState)
    }

    public static func prometheusJSON(
        _ json: [String: Any],
        fallbackState: EngineRunState = .ready
    ) -> EngineStatus {
        EngineStatusDialects.fold(.prometheusJSON, json: json, fallbackState: fallbackState)
    }

    public static func llamaProps(
        _ json: [String: Any],
        fallbackState: EngineRunState = .ready
    ) -> EngineStatus {
        EngineStatusDialects.fold(.llamaProps, json: json, fallbackState: fallbackState)
    }

    public static func strataHealth(
        _ json: [String: Any],
        fallbackState: EngineRunState = .ready
    ) -> EngineStatus {
        EngineStatusDialects.fold(.strataHealth, json: json, fallbackState: fallbackState)
    }

    public static func strataStatus(
        _ json: [String: Any],
        fallbackState: EngineRunState = .ready
    ) -> EngineStatus {
        EngineStatusDialects.fold(.strataStatus, json: json, fallbackState: fallbackState)
    }

    public static func strataMetrics(
        _ json: [String: Any],
        fallbackState: EngineRunState = .ready
    ) -> EngineStatus {
        EngineStatusDialects.fold(.strataMetrics, json: json, fallbackState: fallbackState)
    }

    private static func omlxModelStatus(
        _ json: [String: Any],
        fallbackState: EngineRunState
    ) -> EngineStatus {
        EngineStatusDialects.fold(.omlxModels, json: json, fallbackState: fallbackState)
    }

    private static func openAIModelStatus(
        _ json: [String: Any],
        fallbackState: EngineRunState
    ) -> EngineStatus {
        EngineStatusDialects.fold(.openAIModels, json: json, fallbackState: fallbackState)
    }

}
