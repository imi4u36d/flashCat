import Foundation
import FlashCatKit

/// A model flashCat suggests while an engine holds nothing to serve.
///
/// Every engine is offered the same three Qwen tiers — 3.6 35B-A3B, 3.8 27B and
/// 3.8 Flash-Next — because those are the families all three runtimes ship
/// kernels, draft heads and tuning for. Only the repository differs: Splash and
/// oMLX read MLX folders, MTPLX serves its own MTP-ready packs, so each engine
/// gets the build it can actually load.
struct ModelRecommendation: Identifiable, Hashable {
    /// Hub repository, `owner/repo`, optionally `owner/repo:VARIANT` for a
    /// single GGUF quant inside a repository that also carries the others.
    let id: String
    /// Approximate download size in bytes; 0 when the Hub page states none.
    let bytes: Int
    /// Unified memory the pack is meant for, in GB; 0 when not stated.
    let minimumMemory: Int
    let summary: String
    let tags: [String]
    let draftRepository: String?

    var repo: String {
        id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id
    }

    var variant: String? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        return String(id[id.index(after: colon)...])
    }

    var shortName: String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    var owner: String {
        repo.split(separator: "/").first.map(String.init) ?? repo
    }

    var sizeText: String? {
        bytes > 0 ? "≈" + Format.size(bytes) : nil
    }

    var memoryText: String? {
        minimumMemory > 0 ? "\(minimumMemory) GB 内存起" : nil
    }
}

/// The three suggestions per engine, with the Hub facts (size, memory floor,
/// what the pack is good at) collected once so the model page can show them
/// without a network round trip.
enum ModelRecommendations {
    /// Splash serves MLX folders and prepares its own assembly, so it gets the
    /// community 4-bit builds plus the oQ build of Flash-Next — the only 4-bit
    /// one published for that family — and the DFlash2 draft it ships with.
    static let splash = [
        "mlx-community/Qwen3.6-35B-A3B-4bit",
        "mlx-community/Qwen3.8-27B-4bit",
        "Jundot/Qwen3.8-Flash-Next-oQ4e-mtp",
    ]

    /// oMLX adds MTP-aware oQ quants on top of plain MLX, so all three tiers use
    /// the oMLX author's own oQ builds.
    static let omlx = [
        "Jundot/Qwen3.6-35B-A3B-oQ6-mtp",
        "Jundot/Qwen3.8-27B-oQ4e-mtp",
        "Jundot/Qwen3.8-Flash-Next-oQ4e-mtp",
    ]

    /// MTPLX only serves its own packs: each carries a calibrated MTP head that
    /// the engine verifies draft tokens with.
    static let mtplx = [
        "Youssofal/Qwen3.6-35B-A3B-MTPLX-Optimized-Speed",
        "Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed",
        "Youssofal/Qwen3.8-Flash-Next-MTPLX-Optimized-Speed",
    ]

    static func suggested(_ engine: EngineID) -> [String] {
        switch engine {
        case .splash: return splash
        case .omlx: return omlx
        case .mtplx: return mtplx
        }
    }

    /// The suggestions an engine's model page offers, spelled out with the Hub
    /// facts the table knows.
    static func list(for engine: EngineID) -> [ModelRecommendation] {
        suggested(engine).map(recommendation(for:))
    }

    static func recommendation(for id: String) -> ModelRecommendation {
        let repo = id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id
        let detail = details[repo]
        return ModelRecommendation(id: id,
                                   bytes: detail?.bytes ?? 0,
                                   minimumMemory: detail?.minimumMemory ?? 0,
                                   summary: detail?.summary ?? "引擎推荐",
                                   tags: detail?.tags ?? [],
                                   draftRepository: detail?.draftRepository)
    }

    private struct Detail {
        var bytes: Int = 0
        var minimumMemory: Int = 0
        var summary: String
        var tags: [String] = []
        var draftRepository: String?
    }

    private static let details: [String: Detail] = [
        "mlx-community/Qwen3.6-35B-A3B-4bit": Detail(
            bytes: 19_500_000_000, minimumMemory: 32,
            summary: "35B MoE，只激活 3B，长上下文更省内存",
            tags: ["MLX", "MoE", "DFlash2"],
            draftRepository: "incoai/Qwen3.6-35B-A3B-DFlash2"),
        "mlx-community/Qwen3.8-27B-4bit": Detail(
            bytes: 15_600_000_000, minimumMemory: 24,
            summary: "27B 稠密 4 位，Splash 与 oMLX 的通用档",
            tags: ["MLX", "DFlash2"],
            draftRepository: "incoai/Qwen3.8-27B-DFlash2"),
        "Jundot/Qwen3.8-Flash-Next-oQ4e-mtp": Detail(
            bytes: 106_000_000_000, minimumMemory: 128,
            summary: "125B MoE 的 oQ 4 位版，Flash-Next 里最省内存的一档",
            tags: ["oQ4", "MoE", "视觉", "MTP"],
            draftRepository: "incoai/Qwen3.8-Flash-Next-DFlash2"),
        "Jundot/Qwen3.8-27B-oQ4e-mtp": Detail(
            bytes: 17_200_000_000, minimumMemory: 24,
            summary: "27B 稠密 oQ4 混合精度，保留 MTP 草稿头",
            tags: ["oQ4", "MTP"],
            draftRepository: "incoai/Qwen3.8-27B-DFlash2"),
        "Jundot/Qwen3.6-35B-A3B-oQ6-mtp": Detail(
            bytes: 30_100_000_000, minimumMemory: 48,
            summary: "MoE 的 oQ6 混合精度，保留 MTP 草稿头",
            tags: ["oQ6", "MoE", "MTP"]),
        "Youssofal/Qwen3.6-35B-A3B-MTPLX-Optimized-Speed": Detail(
            bytes: 0, minimumMemory: 32,
            summary: "35B MoE，MTP 头单独放在 mtp.safetensors",
            tags: ["MTP", "MoE"]),
        "Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed": Detail(
            bytes: 20_400_000_000, minimumMemory: 32,
            summary: "MTPLX 默认档：4 位动态量化 27B，MTP 加速",
            tags: ["MTP", "4-bit"]),
        "Youssofal/Qwen3.8-Flash-Next-MTPLX-Optimized-Speed": Detail(
            bytes: 115_000_000_000, minimumMemory: 128,
            summary: "125B Flash-Next，动态 4 位 + 8 位注意力",
            tags: ["MTP", "MoE", "视觉"]),
    ]
}
