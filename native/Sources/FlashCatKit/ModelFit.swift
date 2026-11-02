import Foundation

/// How well one model pack fits the machine flashCat runs on.
public enum DeviceFit: Int, Codable, Sendable {
    /// Memory floor is met and the weights fit on disk.
    case good
    /// Not enough facts (Hub page states neither size nor memory floor).
    case unknown
    /// The pack wants more unified memory than this Mac has.
    case tight
    /// The download is bigger than the free disk space.
    case diskShort

    /// Whether a pack carrying this verdict can actually run here.
    public var runs: Bool { self == .good || self == .unknown }
}

/// The few machine facts the fit rules need: whose Mac it is, how much unified
/// memory it has, and how much disk is left for weights.
public struct MachineProfile: Codable, Equatable, Sendable {
    public var chipName: String
    public var memoryGB: Int
    public var freeDiskBytes: Int64

    public init(chipName: String, memoryGB: Int, freeDiskBytes: Int64) {
        self.chipName = chipName
        self.memoryGB = memoryGB
        self.freeDiskBytes = freeDiskBytes
    }
}

/// One tier an engine could load.
public struct FitCandidate: Equatable, Sendable {
    public var id: String
    /// Approximate download size; 0 when nobody states one.
    public var bytes: Int
    /// Unified memory the pack is meant for, in GB; 0 when not stated.
    public var minimumMemory: Int
    /// How strong this tier is *within its own engine*: bigger is stronger.
    ///
    /// Memory floors cannot stand in for this. MTPLX's 35B and 27B both ask for
    /// 32 GB, so the floor cannot tell which one is the better model, and
    /// catalog order is display order, not strength.
    public var rank: Int

    public init(id: String, bytes: Int, minimumMemory: Int, rank: Int) {
        self.id = id
        self.bytes = bytes
        self.minimumMemory = minimumMemory
        self.rank = rank
    }
}

/// Which tier an engine should load on this machine.
public struct FitPick: Equatable, Sendable {
    /// Index into the candidate list this pick was made from.
    public var index: Int
    /// The chosen tier's own verdict — `.tight`/`.diskShort` when it is only
    /// offered because nothing on the machine can run any tier.
    public var verdict: DeviceFit

    public init(index: Int, verdict: DeviceFit) {
        self.index = index
        self.verdict = verdict
    }
}

/// The one place that decides "fits / does not fit" and "which tier".
///
/// The rule is "as strong as this machine can take": among the tiers that run
/// (.good/.unknown) pick the strongest, and only when none of them runs fall
/// back to the lightest tier — a recommendation row that says "this may not be
/// enough" is more useful than an empty row.
public enum ModelFit {
    public static func verdict(bytes: Int, minimumMemory: Int, machine: MachineProfile) -> DeviceFit {
        guard bytes > 0 || minimumMemory > 0 else { return .unknown }
        if bytes > 0, machine.freeDiskBytes > 0, Int64(bytes) > machine.freeDiskBytes { return .diskShort }
        if minimumMemory > 0, minimumMemory > machine.memoryGB { return .tight }
        return .good
    }

    /// A candidate whose `rank` is 0 has no place on the ladder — a catalog
    /// entry that lost its facts (bytes 0, floor 0) would otherwise read as
    /// `.unknown`, i.e. runnable, and as the lightest tier, i.e. recommended to
    /// every Mac. Dropping it makes missing facts show up as missing advice.
    public static func pick(_ candidates: [FitCandidate], machine: MachineProfile) -> FitPick? {
        // Keep the caller's offsets: `FitPick.index` indexes the array that was
        // passed in, so filtering must not renumber what the caller reads back.
        let ladder = candidates.enumerated().filter { $0.element.rank > 0 }
        guard !ladder.isEmpty else { return nil }

        func verdict(_ candidate: FitCandidate) -> DeviceFit {
            ModelFit.verdict(bytes: candidate.bytes,
                             minimumMemory: candidate.minimumMemory,
                             machine: machine)
        }

        let running = ladder.filter { verdict($0.element).runs }
        if let strongest = running.max(by: { $0.element.rank < $1.element.rank }) {
            return FitPick(index: strongest.offset, verdict: verdict(strongest.element))
        }
        // Nothing runs: the lightest tier, ties going to the lower rank so the
        // smaller model wins a shared memory floor.
        let lightest = ladder.min { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            if a.minimumMemory != b.minimumMemory { return a.minimumMemory < b.minimumMemory }
            return a.rank < b.rank
        }
        guard let lightest else { return nil }
        return FitPick(index: lightest.offset, verdict: verdict(lightest.element))
    }
}
