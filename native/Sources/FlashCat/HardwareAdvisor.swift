import Foundation
import FlashCatKit

/// What this Mac should run, engine by engine, decided once from the machine's
/// own numbers.
///
/// The recommendation is stored rather than recomputed so the answer cannot
/// drift between launches (or halfway through a first-run install), and it is
/// kept per engine because the three catalogs pin different repositories for
/// the same three tiers — "the strongest 27B this Mac can run" is a different
/// download on Splash, oMLX and MTPLX.
struct HardwareRecommendation: Codable, Equatable {
    struct Pick: Codable, Equatable {
        /// `EngineID.rawValue` rather than the case itself, so a stored
        /// recommendation stays decodable even if the enum gains cases.
        let engine: String
        /// Catalog id of the picked tier, `owner/repo[:VARIANT]`.
        let model: String
        /// How the chosen tier sits against this machine. A tier is still
        /// recommended when it does not fit — the lightest one — and the
        /// verdict is what tells the UI to say so.
        let verdict: DeviceFit
        /// Ready-to-show explanation, e.g. "64 GB 内存下最强".
        let reason: String

        var engineID: EngineID? { EngineID(rawValue: engine) }

        /// Short tier label for one-line summaries, e.g. "Qwen3.6-35B-A3B-4bit".
        /// Derived from the catalog instead of stored, so a recheck summary and
        /// the model page's own card can never name the same tier differently.
        var shortName: String { ModelRecommendations.recommendation(for: model).shortName }
    }

    let chipName: String
    let memoryGB: Int
    let freeDiskBytes: Int64
    let computedAt: Date
    let picks: [Pick]

    func pick(for engine: EngineID) -> Pick? {
        picks.first { $0.engine == engine.rawValue }
    }

    /// One line for the settings card: the machine the answer was worked out on.
    var machineSummary: String {
        var parts = [chipName, "\(memoryGB) GB 统一内存"]
        if freeDiskBytes > 0 { parts.append("可用 " + Format.size(Int(freeDiskBytes))) }
        return parts.joined(separator: " · ")
    }
}

/// Works out, per engine, which catalog tier this machine should run.
///
/// "Best it can run" rather than "biggest that fits in the disk": an engine's
/// three tiers differ in quality, and a machine with room to spare should get
/// the strongest one, not the smallest. The pick itself is `ModelFit.pick`, so
/// the model page and the launch page can never disagree about what fits.
enum HardwareAdvisor {
    static func recommend(machine: MachineProfile) -> HardwareRecommendation {
        var picks: [HardwareRecommendation.Pick] = []
        for engine in EngineID.allCases {
            let catalog = ModelRecommendations.list(for: engine)
            let candidates = catalog.map {
                FitCandidate(id: $0.id, bytes: $0.bytes,
                             minimumMemory: $0.minimumMemory, rank: $0.rank)
            }
            guard let fit = ModelFit.pick(candidates, machine: machine) else { continue }
            picks.append(HardwareRecommendation.Pick(
                engine: engine.rawValue,
                model: catalog[fit.index].id,
                verdict: fit.verdict,
                reason: reason(verdict: fit.verdict, memoryGB: machine.memoryGB)))
        }
        return HardwareRecommendation(chipName: machine.chipName,
                                      memoryGB: machine.memoryGB,
                                      freeDiskBytes: machine.freeDiskBytes,
                                      computedAt: Date(),
                                      picks: picks)
    }

    /// The only place the recommendation wording lives, so the launch page, the
    /// confirmation sheet and the model page's tag all say the same thing.
    static func reason(verdict: DeviceFit, memoryGB: Int) -> String {
        switch verdict {
        case .good, .unknown: return "\(memoryGB) GB 内存下最强"
        case .tight: return "内存可能不够"
        case .diskShort: return "磁盘可能不够"
        }
    }
}
