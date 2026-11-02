import XCTest
@testable import FlashCatKit

final class ModelFitTests: XCTestCase {

    private func machine(_ memoryGB: Int, freeDisk: Int64 = 1_000_000_000_000) -> MachineProfile {
        MachineProfile(chipName: "Apple M4 Max", memoryGB: memoryGB, freeDiskBytes: freeDisk)
    }

    /// The three tiers every engine ships, with the ranks the catalog declares.
    private let tiers = [
        FitCandidate(id: "27B", bytes: 15_600_000_000, minimumMemory: 24, rank: 1),
        FitCandidate(id: "35B", bytes: 20_400_000_000, minimumMemory: 32, rank: 2),
        FitCandidate(id: "Flash-Next", bytes: 108_000_000_000, minimumMemory: 128, rank: 3),
    ]

    func testPicksTheStrongestTierTheMachineCanRun() {
        let pick = ModelFit.pick(tiers, machine: machine(128))
        XCTAssertEqual(pick, FitPick(index: 2, verdict: .good))
    }

    func testStopsAtTheTierJustAboveTheMemoryFloor() {
        // 64 GB: Flash-Next is out, 35B is the strongest that still runs.
        let pick = ModelFit.pick(tiers, machine: machine(64))
        XCTAssertEqual(pick, FitPick(index: 1, verdict: .good))
    }

    func testOnlyTheLightestTierRunsWhenOthersWantMoreMemory() {
        let candidates = [
            FitCandidate(id: "27B", bytes: 15_600_000_000, minimumMemory: 24, rank: 1),
            FitCandidate(id: "35B", bytes: 20_400_000_000, minimumMemory: 48, rank: 2),
        ]
        let pick = ModelFit.pick(candidates, machine: machine(32))
        XCTAssertEqual(pick, FitPick(index: 0, verdict: .good))
    }

    func testNothingRunsStillRecommendsTheLightestTier() {
        let pick = ModelFit.pick(tiers, machine: machine(16))
        XCTAssertEqual(pick, FitPick(index: 0, verdict: .tight))
    }

    func testDiskShortFallsBackToTheLightestTierWithItsVerdict() {
        let pick = ModelFit.pick(tiers, machine: machine(128, freeDisk: 10_000_000_000))
        XCTAssertEqual(pick, FitPick(index: 0, verdict: .diskShort))
    }

    func testPackWithNoSizeOrFloorStillRuns() {
        let candidates = [
            FitCandidate(id: "known", bytes: 20_400_000_000, minimumMemory: 32, rank: 1),
            FitCandidate(id: "unstated", bytes: 0, minimumMemory: 0, rank: 3),
        ]
        let pick = ModelFit.pick(candidates, machine: machine(64))
        XCTAssertEqual(pick, FitPick(index: 1, verdict: .unknown))
    }

    /// MTPLX's 35B and 27B both ask for 32 GB, so the floor cannot decide: rank
    /// picks the stronger one when it runs, and the lighter one when nothing does.
    func testEqualMemoryFloorsAreDecidedByRank() {
        let candidates = [
            FitCandidate(id: "27B", bytes: 20_400_000_000, minimumMemory: 32, rank: 1),
            FitCandidate(id: "35B", bytes: 0, minimumMemory: 32, rank: 2),
        ]
        XCTAssertEqual(ModelFit.pick(candidates, machine: machine(64)), FitPick(index: 1, verdict: .good))
        XCTAssertEqual(ModelFit.pick(candidates, machine: machine(16)), FitPick(index: 0, verdict: .tight))
    }

    func testEmptyCandidateListHasNoPick() {
        XCTAssertNil(ModelFit.pick([], machine: machine(64)))
    }

    func testVerdictThresholds() {
        XCTAssertEqual(ModelFit.verdict(bytes: 0, minimumMemory: 0, machine: machine(64)), .unknown)
        XCTAssertEqual(ModelFit.verdict(bytes: 0, minimumMemory: 64, machine: machine(64)), .good)
        XCTAssertEqual(ModelFit.verdict(bytes: 0, minimumMemory: 128, machine: machine(64)), .tight)
        // An unknown free disk (0) cannot make a pack "too big".
        XCTAssertEqual(ModelFit.verdict(bytes: 108_000_000_000, minimumMemory: 0,
                                        machine: machine(64, freeDisk: 0)), .good)
    }
}
