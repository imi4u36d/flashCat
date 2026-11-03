import Foundation
import FlashCatKit

/// 这份权重是哪来的：引擎精选目录里的档位，还是用户自己从 Hub 下的。
/// 只影响卡片上的徽标与文案，不影响能不能下载、能不能用——开放下载之后，
/// 支持与否由用户自己判断。
enum ModelSource: String {
    case recommended
    case personal
}

/// One row of the model page: weights this engine has, or a suggestion it does
/// not have yet. Both live in the same grid, so browsing an engine never
/// depends on that engine being installed, running, or holding a model.
struct ModelLibraryEntry: Identifiable {
    let model: ModelInfo
    let engine: EngineID
    let recommendation: ModelRecommendation?
    let draftRepository: String?
    let source: ModelSource

    var id: String { model.id }
    var installed: Bool { model.origin != .recommended }
    var downloadable: Bool { !installed }

    /// A row that is not one of *this* engine's catalog rows — weights moved
    /// here by an upgrade, or a folder nobody tagged. It still carries its
    /// catalog tags (so the card can say 「oMLX 专用」), it just is not part of
    /// this column's recommendation list.
    var uncatalogued: Bool {
        guard let recommendation else { return true }
        return !recommendation.engines.contains(engine)
    }

    /// Auxiliary DFlash2 draft weights. They only make sense attached to a main
    /// model (the launcher hands them over as `dflash_draft_model`), so the page
    /// never offers a launch/download action for them.
    static func isDraftModel(_ id: String) -> Bool {
        normalized(id).contains("dflash")
    }
    var isDraft: Bool { Self.isDraftModel(model.id) }

    /// Engines name the same weights differently — Splash keeps `owner/repo`
    /// while the packs serve the flat `owner--repo` link name — so matching a
    /// suggestion against what is installed needs one normal form.
    static func normalized(_ id: String) -> String {
        let repo = id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id
        return repo.replacingOccurrences(of: "--", with: "/").lowercased()
    }
}

/// A model picked from another engine's library: using it means switching, so the
/// page asks first instead of silently stopping what runs now.
struct LibraryUseRequest: Identifiable {
    let engine: EngineID
    let model: String
    /// The engine does not hold the weights yet, so the switch also downloads.
    let needsDownload: Bool

    var id: String { engine.rawValue + "/" + model }
}

enum ModelLibrary {
    /// The catalog rows for an engine, plus whatever that engine already has on
    /// disk.
    ///
    /// A row whose folder exists is the same row with real bytes on it. A
    /// folder that is not in the catalog is still shown, marked 未收录: the
    /// engine can serve it right now, and hiding it would make an installed
    /// model invisible with no way to reach it. The page's engine filter only
    /// constrains recommendations and search results — never the weights that
    /// are already here.
    static func entries(installed: [ModelInfo],
                        engine: EngineID,
                        recommendations: [ModelRecommendation],
                        draftRepository: (String) -> String?) -> [ModelLibraryEntry] {
        var onDisk: [String: ModelInfo] = [:]
        for model in installed where onDisk[ModelLibraryEntry.normalized(model.id)] == nil {
            onDisk[ModelLibraryEntry.normalized(model.id)] = model
        }

        var claimed: Set<String> = []
        var rows: [ModelLibraryEntry] = recommendations.map { recommendation in
            let key = ModelLibraryEntry.normalized(recommendation.id)
            let found = onDisk[key]
            claimed.insert(key)
            let scannedBytes = found?.bytes ?? 0
            let model = ModelInfo(id: found?.id ?? recommendation.id,
                                  path: found?.path ?? "",
                                  bytes: scannedBytes > 0 ? scannedBytes : recommendation.bytes,
                                  origin: found?.origin ?? .recommended,
                                  targetName: found?.targetName ?? "",
                                  family: found?.family,
                                  draftPath: found?.draftPath,
                                  mmprojPath: found?.mmprojPath,
                                  approximateSize: found == nil && recommendation.bytes > 0)
            return ModelLibraryEntry(model: model,
                                     engine: engine,
                                     recommendation: recommendation,
                                     draftRepository: recommendation.draftRepository
                                         ?? (found == nil ? nil : draftRepository(model.id)),
                                     source: .recommended)
        }

        // Weights on disk that the catalog does not tag for this engine. Sorted
        // so the grid does not reshuffle between scans.
        let extras = installed
            .filter { !claimed.contains(ModelLibraryEntry.normalized($0.id)) }
            // 草稿头不成行：它没有独立可用的权重，卡片上唯一能做的「删除」
            // 会把另一个已装模型正配对的草稿删掉。
            .filter { !ModelLibraryEntry.isDraftModel($0.id) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            .map { model in
                // 迁移留下的旧权重可能仍是目录行、只是标签不在这一栏：它的
                // engines/repo/tags 照旧带上，卡片才标得出「oMLX 专用」。用户
                // 自己从 Hub 下的权重没有目录行，`source` 让卡片说得更准。
                let row = ModelRecommendations.recommendation(for: model.id)
                return ModelLibraryEntry(model: model,
                                         engine: engine,
                                         recommendation: row,
                                         draftRepository: draftRepository(model.id),
                                         source: row == nil ? .personal : .recommended)
            }
        rows.append(contentsOf: extras)
        return rows
    }
}
