import Foundation
import FlashCatKit

/// One Hugging Face repository as the model page can offer it: the engine that
/// may serve it, the size the download actually costs, and — for a GGUF
/// repository — the quants inside it.
///
/// This is a session object. It is not persisted anywhere: a search result is
/// only good while the query is on screen, so there is no cache to invalidate
/// and nothing to migrate when the shapes change.
struct HubSearchResult: Identifiable {
    /// `owner/repo`, or `owner/repo:VARIANT` once a quant is chosen.
    let id: String
    let repo: String
    let engine: EngineID
    let kind: HubModelKind
    /// Bytes the download costs, for the chosen quant or the biggest one.
    let bytes: Int
    /// Unified memory floor in GB. Reused from the catalog when the repository
    /// and the chosen quant both match a pinned row; otherwise estimated.
    let memoryGB: Int
    /// True when the floor is the `bytes × 1.2` guess rather than a measured
    /// value, so the page can print it with ≈.
    let estimated: Bool
    let downloads: Int
    /// Every quant of a GGUF repository, each with its own size and memory
    /// floor — computed here so the page can switch quants without a round trip.
    let options: [Quant]
    let summary: String?
    let tags: [String]

    /// One downloadable quant (or the single snapshot of a non-GGUF row).
    struct Quant: Identifiable, Hashable {
        /// nil for the snapshot itself; the GGUF variant name otherwise.
        let name: String?
        let bytes: Int
        let memoryGB: Int
        let estimated: Bool

        var id: String { name ?? "" }

        var label: String { name ?? "默认" }

        var sizeText: String? { bytes > 0 ? "≈" + Format.size(bytes) : nil }

        var memoryText: String { estimated ? "≈\(memoryGB) GB" : "\(memoryGB) GB" }
    }

    var variant: String? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        return String(id[id.index(after: colon)...])
    }

    var shortName: String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    var sizeText: String? {
        bytes > 0 ? "≈" + Format.size(bytes) : nil
    }

    var memoryText: String {
        estimated ? "≈\(memoryGB) GB 内存起" : "\(memoryGB) GB 内存起"
    }

    /// The same row with another quant of the same repository chosen.
    func choosing(_ quant: String?) -> HubSearchResult {
        guard let option = options.first(where: { $0.name == quant }) ?? options.last else { return self }
        let id = option.name.map { repo + ":" + $0 } ?? repo
        return HubSearchResult(id: id, repo: repo, engine: engine, kind: kind,
                               bytes: option.bytes, memoryGB: option.memoryGB,
                               estimated: option.estimated, downloads: downloads,
                               options: options, summary: summary, tags: tags)
    }

    /// The catalog's measured floor wins only when the repository *and* the
    /// quant both match: 64 GB is right for `Q2_0` and nonsense for `Q8_0`.
    static func memoryFloor(id: String, bytes: Int) -> (value: Int, estimated: Bool) {
        if let row = ModelRecommendations.recommendation(for: id), row.minimumMemory > 0,
           variant(of: row.id) == variant(of: id) {
            return (row.minimumMemory, false)
        }
        return (HubModelLayout.estimatedMemoryGB(bytes: bytes), true)
    }

    private static func variant(of id: String) -> String? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        return String(id[id.index(after: colon)...])
    }
}

/// What the page knows about the current search. `results` is already filtered
/// to the engine column being shown, so the page never decides ownership.
struct HubSearchState {
    var query: String = ""
    var phase: Phase = .idle
    var results: [HubSearchResult] = []
    var error: String?

    enum Phase: String {
        case idle, loading, failed
    }

    var isEmpty: Bool { query.isEmpty && results.isEmpty && phase == .idle }

    /// The engine a repository belongs to, by the format the Hub reports.
    /// GGUF is Splash's channel and MTPLX packs are MTPLX's, each by product
    /// rule rather than capability; everything else MLX-ish is the general
    /// engine's.
    static func engine(for kind: HubModelKind) -> EngineID? {
        switch kind {
        case .gguf: return .splash
        case .mtplx: return .mtplx
        case .mlx, .unmarked: return .omlx
        case .unknown: return nil
        }
    }

    /// A repository as one result row, with the catalog's summary and tags when
    /// the catalog knows it.
    static func result(for model: HubModel) -> HubSearchResult? {
        guard let engine = engine(for: model.kind) else { return nil }
        let repo = model.id
        let variants = model.ggufVariants
        let options: [HubSearchResult.Quant]
        if variants.isEmpty {
            let bytes = model.weightBytes(ggufVariant: nil)
            let floor = HubSearchResult.memoryFloor(id: repo, bytes: bytes)
            options = [HubSearchResult.Quant(name: nil, bytes: bytes,
                                             memoryGB: floor.value, estimated: floor.estimated)]
        } else {
            options = variants.map { variant in
                let id = variant.name.map { repo + ":" + $0 } ?? repo
                let floor = HubSearchResult.memoryFloor(id: id, bytes: variant.bytes)
                return HubSearchResult.Quant(name: variant.name, bytes: variant.bytes,
                                             memoryGB: floor.value, estimated: floor.estimated)
            }
        }
        // A row without a single known size is worse than no row: it would show
        // no size and download whichever quant happens to be listed first. The
        // per-repository sizes are the only source, so an enrich that got rate
        // limited lands here.
        let sized = options.filter { $0.bytes > 0 }
        guard let start = sized.min(by: { $0.bytes < $1.bytes }) else { return nil }
        let row = ModelRecommendations.recommendation(for: repo)
        return HubSearchResult(id: start.name.map { repo + ":" + $0 } ?? repo,
                               repo: repo, engine: engine, kind: model.kind,
                               bytes: start.bytes, memoryGB: start.memoryGB,
                               estimated: start.estimated, downloads: model.downloads,
                               options: sized, summary: row?.summary, tags: row?.tags ?? [])
    }
}
