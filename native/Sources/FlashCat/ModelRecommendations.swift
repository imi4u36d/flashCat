import Foundation
import FlashCatKit

/// A model flashCat knows about, tagged with the engines that may serve it.
///
/// The catalog is one list, and each row carries `engines` instead of living in
/// a per-engine array: ownership is a property of the model, so a row that runs
/// on two runtimes says so, and the page filter is a `contains` on that set.
///
/// The tags are a product split, not a capability one. oMLX and MLX-Serve are
/// the general MLX engines; Splash, MTPLX and Strata have narrower product-fit
/// policies. A repository may be tagged for more than one engine, but search
/// and recommendation only show it where the product chooses to expose it.
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
    /// How strong this row is within its engine (bigger is stronger); the
    /// hardware recommendation picks "the best this machine can run" from it
    /// instead of guessing strength from the memory floor. Zero keeps a row in
    /// the engine catalog without putting it on the hardware ranked ladder.
    let rank: Int
    /// The engines that may serve this row. A row outside an engine's set is
    /// never offered there — neither as a recommendation nor through search.
    let engines: Set<EngineID>

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

    /// The tag names shown on the card, engine tags first so a card in the
    /// Splash column reads "Splash" before "GGUF".
    var engineLabels: [String] {
        EngineCatalog.allIDs.filter { engines.contains($0) }.map(\.displayName)
    }
}

/// The catalog, with the Hub facts (size, memory floor, what the pack is good
/// at) collected once so the model page can show them without a network round
/// trip.
enum ModelRecommendations {
    /// One row per repository. Drafts are not rows: they are helpers a row
    /// pairs with, and the page never offers them on their own.
    static let catalog: [ModelRecommendation] = [
        ModelRecommendation(
            id: "Jundot/Qwen3.6-35B-A3B-oQ4e-mtp",
            bytes: 22_157_307_177, minimumMemory: 32,
            summary: "MoE 的 oQ4e 量化，保留 MTP 草稿头",
            tags: ["oQ4e", "MoE", "MTP"],
            draftRepository: nil,
            rank: 2,
            engines: [.omlx, .mlxServe]),
        ModelRecommendation(
            id: "Jundot/Qwen3.8-27B-oQ4e-mtp",
            bytes: 17_540_672_204, minimumMemory: 24,
            summary: "27B 稠密 oQ4e 量化，保留 MTP 草稿头",
            tags: ["oQ4e", "MTP"],
            draftRepository: nil,
            rank: 1,
            engines: [.omlx, .mlxServe]),
        ModelRecommendation(
            id: "Jundot/Qwen3.8-Flash-Next-oQ4e-mtp",
            bytes: 107_693_774_391, minimumMemory: 128,
            summary: "125B MoE 的 oQ4e 版，Flash-Next 里最省内存的一档",
            tags: ["oQ4e", "MoE", "视觉", "MTP"],
            draftRepository: nil,
            rank: 3,
            engines: [.omlx, .mlxServe]),
        ModelRecommendation(
            id: "ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF:IQ3_S",
            bytes: 11_771_546_784, minimumMemory: 24,
            summary: "27B 稠密模型的 GSQ-RCO 动态量化，IQ3_S 按 HF 评测接近无损",
            tags: ["GGUF", "IQ3_S", "3.5 bpw", "视觉"],
            draftRepository: "incoai/Qwen3.8-27B-DFlash2",
            rank: 1,
            engines: [.splash]),
        ModelRecommendation(
            id: "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0",
            bytes: 66_423_878_624, minimumMemory: 64,
            summary: "125B MoE，Flash-Next 的 GGUF 包，Splash 与 Strata 可共享",
            tags: ["GGUF", "Q2_0", "2.4 bpw", "MoE", "视觉"],
            draftRepository: "incoai/Qwen3.8-Flash-Next-DFlash2",
            rank: 3,
            engines: [.splash, .strata]),
        ModelRecommendation(
            id: "Youssofal/Qwen3.6-35B-A3B-MTPLX-Optimized-Speed",
            bytes: 21_014_908_552, minimumMemory: 32,
            summary: "35B MoE，MTP 头单独放在 mtp.safetensors",
            tags: ["MTP", "MoE"],
            draftRepository: nil,
            rank: 2,
            engines: [.mtplx]),
        ModelRecommendation(
            id: "Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed",
            bytes: 20_703_486_926, minimumMemory: 32,
            summary: "MTPLX 默认档：4 位动态量化 27B，MTP 加速",
            tags: ["MTP", "4-bit"],
            draftRepository: nil,
            rank: 1,
            engines: [.mtplx]),
        ModelRecommendation(
            id: "Youssofal/Qwen3.8-Flash-Next-MTPLX-Optimized-Speed",
            bytes: 115_061_256_248, minimumMemory: 128,
            summary: "125B Flash-Next，动态 4 位 + 8 位注意力",
            tags: ["MTP", "MoE", "视觉"],
            draftRepository: nil,
            rank: 3,
            engines: [.mtplx]),
        ModelRecommendation(
            id: "Youssofal/MiMo-V2.6-Qwen-9B-MTPLX-Optimized-Speed",
            bytes: 8_695_113_783, minimumMemory: 16,
            summary: "MiMo-V2.6 Qwen 9B，MTPLX 官方优化包",
            tags: ["6-bit", "MTP"],
            draftRepository: nil,
            // 目录收录不等于硬件排名：rank 0 会在低内存机器上兜底，但不参与正式档评选。
            rank: 0,
            engines: [.mtplx]),
        ModelRecommendation(
            id: "Youssofal/Qwen3.5-4B-MTPLX-Optimized-Speed",
            bytes: 2_567_456_768, minimumMemory: 8,
            summary: "Qwen3.5 4B，MTPLX 轻量优化包",
            tags: ["4-bit", "MTP"],
            draftRepository: nil,
            rank: 0,
            engines: [.mtplx]),
    ]

    /// The catalog rows tagged for this engine, in catalog order — the page's
    /// recommendation list, and the filter search results have to respect.
    static func list(for engine: EngineID) -> [ModelRecommendation] {
        catalog.filter { $0.engines.contains(engine) }
    }

    /// The catalog row this id normalizes to, or nil for weights nobody tagged.
    /// A draft head is *not* a row: read the owning row's `draftRepository`.
    static func recommendation(for id: String) -> ModelRecommendation? {
        let repo = ModelLibraryEntry.normalized(id)
        return catalog.first { ModelLibraryEntry.normalized($0.id) == repo }
    }
}
