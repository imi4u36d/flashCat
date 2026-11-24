// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation

/// One Hugging Face repository as the model page can offer it: the engine that
/// may serve it, the size the download actually costs, and — for a GGUF
/// repository — the quants inside it.
///
/// This is a session object. It is not persisted anywhere: a search result is
/// only good while the query is on screen, so there is no cache to invalidate
/// and nothing to migrate when the shapes change.
package struct HubSearchResult: Identifiable {
    /// `owner/repo`, or `owner/repo:VARIANT` once a quant is chosen.
    package let id: String
    package let repo: String
    package let engine: EngineID
    package let engines: Set<EngineID>
    package let kind: HubModelKind
    /// Bytes the download costs, for the chosen quant or the biggest one.
    package let bytes: Int
    /// Unified memory floor in GB. Reused from the catalog when the repository
    /// and the chosen quant both match a pinned row; otherwise estimated.
    package let memoryGB: Int
    /// True when the floor is the `bytes × 1.2` guess rather than a measured
    /// value, so the page can print it with ≈.
    package let estimated: Bool
    package let downloads: Int
    /// Declared task modalities, when the Hub metadata identifies one.
    package let io: String?
    /// Every quant of a GGUF repository, each with its own size and memory
    /// floor — computed here so the page can switch quants without a round trip.
    package let options: [Quant]
    package let summary: String?
    package let tags: [String]

    /// One downloadable quant (or the single snapshot of a non-GGUF row).
    package struct Quant: Identifiable, Hashable {
        /// nil for the snapshot itself; the GGUF variant name otherwise.
        package let name: String?
        package let bytes: Int
        package let memoryGB: Int
        package let estimated: Bool

        package init(name: String?, bytes: Int, memoryGB: Int, estimated: Bool) {
            self.name = name
            self.bytes = bytes
            self.memoryGB = memoryGB
            self.estimated = estimated
        }

        package var id: String { name ?? "" }

        package var label: String { name ?? "默认" }

        package var sizeText: String? { bytes > 0 ? "≈" + Format.size(bytes) : nil }

        package var memoryText: String { estimated ? "≈\(memoryGB) GB" : "\(memoryGB) GB" }
    }

    package var variant: String? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        return String(id[id.index(after: colon)...])
    }

    package var shortName: String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    package var sizeText: String? {
        bytes > 0 ? "≈" + Format.size(bytes) : nil
    }

    package var memoryText: String {
        estimated ? "≈\(memoryGB) GB 内存起" : "\(memoryGB) GB 内存起"
    }

    package func targeting(_ engine: EngineID) -> HubSearchResult {
        HubSearchResult(
            id: id, repo: repo, engine: engine, engines: engines,
            kind: kind, bytes: bytes, memoryGB: memoryGB,
            estimated: estimated, downloads: downloads, io: io,
            options: options, summary: summary, tags: tags)
    }

    /// The same row with another quant of the same repository chosen.
    package func choosing(_ quant: String?) -> HubSearchResult {
        guard let option = options.first(where: { $0.name == quant }) ?? options.last else { return self }
        let id = option.name.map { repo + ":" + $0 } ?? repo
        return HubSearchResult(
            id: id, repo: repo, engine: engine, engines: engines,
            kind: kind,
            bytes: option.bytes, memoryGB: option.memoryGB,
            estimated: option.estimated, downloads: downloads,
            io: io,
            options: options, summary: summary, tags: tags)
    }

    /// The catalog's measured floor wins only when the repository *and* the
    /// quant both match: 64 GB is right for `Q2_0` and nonsense for `Q8_0`.
    package static func memoryFloor(id: String, bytes: Int) -> (value: Int, estimated: Bool) {
        if let row = ModelRecommendations.recommendation(for: id), row.minimumMemory > 0,
            variant(of: row.id) == variant(of: id)
        {
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
package struct HubSearchState {
    package var query: String = ""
    package var phase: Phase = .idle
    package var results: [HubSearchResult] = []
    package var error: String?

    package enum Phase: String {
        case idle, loading, failed
    }

    package init(
        query: String = "", phase: Phase = .idle, results: [HubSearchResult] = [], error: String? = nil
    ) {
        self.query = query
        self.phase = phase
        self.results = results
        self.error = error
    }

    package var isEmpty: Bool { query.isEmpty && results.isEmpty && phase == .idle }

    /// The engine a repository belongs to, by the format the Hub reports.
    /// GGUF is Splash's channel and MTPLX packs are MTPLX's, each by product
    /// rule rather than capability; everything else MLX-ish is the general
    /// engine's.
    package static func engines(for kind: HubModelKind) -> Set<EngineID> {
        switch kind {
        case .gguf: return [.splash]
        case .mtplx: return [.mtplx]
        case .mlx, .unmarked: return [.omlx, .mlxServe]
        case .unknown: return []
        }
    }

    /// A repository as one result row, with the catalog's summary and tags when
    /// the catalog knows it.
    package static func result(for model: FlashCatKit.HubModel) -> HubSearchResult? {
        let engines = engines(for: model.kind)
        guard let engine = EngineCatalog.allIDs.first(where: { engines.contains($0) }) else { return nil }
        let repo = model.id
        let variants = model.ggufVariants
        let options: [HubSearchResult.Quant]
        if variants.isEmpty {
            let bytes = model.weightBytes(ggufVariant: nil)
            let floor = HubSearchResult.memoryFloor(id: repo, bytes: bytes)
            options = [
                HubSearchResult.Quant(
                    name: nil, bytes: bytes,
                    memoryGB: floor.value, estimated: floor.estimated)
            ]
        } else {
            options = variants.map { variant in
                let id = variant.name.map { repo + ":" + $0 } ?? repo
                let floor = HubSearchResult.memoryFloor(id: id, bytes: variant.bytes)
                return HubSearchResult.Quant(
                    name: variant.name, bytes: variant.bytes,
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
        return HubSearchResult(
            id: start.name.map { repo + ":" + $0 } ?? repo,
            repo: repo, engine: engine, engines: engines, kind: model.kind,
            bytes: start.bytes, memoryGB: start.memoryGB,
            estimated: start.estimated, downloads: model.downloads,
            io: model.ioTypes?.label,
            options: sized, summary: row?.summary, tags: row?.tags ?? [])
    }
}
