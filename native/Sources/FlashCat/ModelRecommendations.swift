import Foundation
import FlashCatKit

/// A model flashCat knows about, tagged with the engines that may serve it.
///
/// The catalog is one list, and each row carries `engines` instead of living in
/// a per-engine array: ownership is a property of the model, so a row that runs
/// on two runtimes says so, and the page filter is a `contains` on that set.
///
/// The tags are a product split, not a capability one. oMLX is the general
/// engine; Splash and MTPLX are special-purpose. Plain MLX weights therefore go
/// to oMLX only even though Splash can serve them too, and GGUF goes to Splash
/// only even though oMLX can serve it — its own fixtures list two GGUF models.
/// MTPLX only serves `Youssofal/*` packs, whose calibrated MTP head it verifies
/// draft tokens with.
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
    /// instead of guessing strength from the memory floor.
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
        EngineID.allCases.filter { engines.contains($0) }.map(\.displayName)
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
            id: "mlx-community/Qwen3.6-35B-A3B-4bit",
            bytes: 20_400_000_000, minimumMemory: 32,
            summary: "35B MoE，只激活 3B，长上下文更省内存",
            tags: ["MLX", "MoE", "DFlash2"],
            draftRepository: "incoai/Qwen3.6-35B-A3B-DFlash2",
            rank: 2,
            engines: [.omlx]),
        ModelRecommendation(
            id: "mlx-community/Qwen3.8-27B-4bit",
            bytes: 15_600_000_000, minimumMemory: 24,
            summary: "27B 稠密 4 位，通用档",
            tags: ["MLX", "DFlash2"],
            draftRepository: "incoai/Qwen3.8-27B-DFlash2",
            rank: 1,
            engines: [.omlx]),
        ModelRecommendation(
            id: "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0",
            bytes: 0, minimumMemory: 64,
            summary: "125B MoE，Flash-Next 在 Splash 上只跑 GGUF",
            tags: ["GGUF", "MoE", "视觉"],
            draftRepository: "incoai/Qwen3.8-Flash-Next-DFlash2",
            rank: 3,
            engines: [.splash]),
        ModelRecommendation(
            id: "Jundot/Qwen3.6-35B-A3B-oQ4e-mtp",
            bytes: 22_100_000_000, minimumMemory: 32,
            summary: "MoE 的 oQ4 混合精度，保留 MTP 草稿头",
            tags: ["oQ4", "MoE", "MTP"],
            draftRepository: nil,
            rank: 2,
            engines: [.omlx]),
        ModelRecommendation(
            id: "mlx-works/Qwen3.8-27B-oQ4e-mtp",
            bytes: 17_200_000_000, minimumMemory: 24,
            summary: "27B 稠密 oQ4（imatrix 校准），oMLX 自家量化",
            tags: ["oQ4", "MTP"],
            draftRepository: nil,
            rank: 1,
            engines: [.omlx]),
        ModelRecommendation(
            id: "Jundot/Qwen3.8-Flash-Next-oQ4e-mtp",
            bytes: 108_000_000_000, minimumMemory: 128,
            summary: "125B MoE 的 oQ4 版，Flash-Next 里最省内存的一档",
            tags: ["oQ4", "MoE", "视觉", "MTP"],
            draftRepository: nil,
            rank: 3,
            engines: [.omlx]),
        ModelRecommendation(
            id: "Youssofal/Qwen3.6-35B-A3B-MTPLX-Optimized-Speed",
            bytes: 0, minimumMemory: 32,
            summary: "35B MoE，MTP 头单独放在 mtp.safetensors",
            tags: ["MTP", "MoE"],
            draftRepository: nil,
            rank: 2,
            engines: [.mtplx]),
        ModelRecommendation(
            id: "Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed",
            bytes: 20_400_000_000, minimumMemory: 32,
            summary: "MTPLX 默认档：4 位动态量化 27B，MTP 加速",
            tags: ["MTP", "4-bit"],
            draftRepository: nil,
            rank: 1,
            engines: [.mtplx]),
        ModelRecommendation(
            id: "Youssofal/Qwen3.8-Flash-Next-MTPLX-Optimized-Speed",
            bytes: 115_000_000_000, minimumMemory: 128,
            summary: "125B Flash-Next，动态 4 位 + 8 位注意力",
            tags: ["MTP", "MoE", "视觉"],
            draftRepository: nil,
            rank: 3,
            engines: [.mtplx]),
    ]

    /// The repository ids an engine's page suggests, in catalog order.
    static func suggested(_ engine: EngineID) -> [String] {
        list(for: engine).map(\.id)
    }

    /// The catalog rows tagged for this engine.
    static func list(for engine: EngineID) -> [ModelRecommendation] {
        catalog.filter { $0.engines.contains(engine) }
    }

    /// The catalog row this id normalizes to, or nil for weights nobody tagged.
    /// A draft head is *not* a row: resolve those through `draft(for:)` / the
    /// owning row's `draftRepository`.
    static func recommendation(for id: String) -> ModelRecommendation? {
        let repo = ModelLibraryEntry.normalized(id)
        return catalog.first { ModelLibraryEntry.normalized($0.id) == repo }
    }

    /// Whether this id is a catalog row for that engine — the rows the model
    /// page and the model switcher treat as known.
    static func isPinned(_ id: String, engine: EngineID) -> Bool {
        guard let row = recommendation(for: id) else { return false }
        return row.engines.contains(engine)
    }

    /// Whether the catalog tags this id anywhere at all.
    static func isCataloged(_ id: String) -> Bool {
        recommendation(for: id) != nil
    }

    /// A row's DFlash2 draft is a helper, not a model, but the draft menu still
    /// has to be able to name it.
    static func isPinnedDraft(_ id: String) -> Bool {
        let key = ModelLibraryEntry.normalized(id)
        return catalog.contains { row in
            guard let draft = row.draftRepository else { return false }
            return ModelLibraryEntry.normalized(draft) == key
        }
    }

    /// Everything the UI is allowed to name: the pinned rows and the drafts
    /// they pair with.
    static func allows(_ id: String, engine: EngineID) -> Bool {
        isPinned(id, engine: engine) || isPinnedDraft(id)
    }

    /// The draft an id pairs with, if the catalog says so.
    static func draft(for id: String) -> String? {
        recommendation(for: id)?.draftRepository
    }
}
