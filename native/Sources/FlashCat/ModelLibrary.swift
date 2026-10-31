import Foundation
import FlashCatKit

/// One row of the model page: weights this engine has, or a suggestion it does
/// not have yet. Both live in the same grid, so browsing an engine never
/// depends on that engine being installed, running, or holding a model.
struct ModelLibraryEntry: Identifiable {
    let model: ModelInfo
    let engine: EngineID
    let recommendation: ModelRecommendation?
    let draftRepository: String?

    var id: String { model.id }
    var installed: Bool { model.origin != .recommended }
    var downloadable: Bool { !installed }

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
    /// The fixed catalog, in the order the engine's list names it.
    ///
    /// Only pinned rows appear. Weights scanned from the model folder are used
    /// purely as evidence that a pinned row is installed — a folder that is not
    /// in the catalog is not offered anywhere, because the page has no import
    /// action that could have put it there.
    static func entries(installed: [ModelInfo],
                        engine: EngineID,
                        recommendations: [ModelRecommendation],
                        draftRepository: (String) -> String?) -> [ModelLibraryEntry] {
        var onDisk: [String: ModelInfo] = [:]
        for model in installed where onDisk[ModelLibraryEntry.normalized(model.id)] == nil {
            onDisk[ModelLibraryEntry.normalized(model.id)] = model
        }

        return recommendations.map { recommendation in
            let key = ModelLibraryEntry.normalized(recommendation.id)
            let found = onDisk[key]
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
                                         ?? (found == nil ? nil : draftRepository(model.id)))
        }
    }
}
