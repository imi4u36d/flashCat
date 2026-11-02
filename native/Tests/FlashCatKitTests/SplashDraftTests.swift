import XCTest
@testable import FlashCatKit

final class SplashDraftTests: XCTestCase {

    /// The three families the app recommends, as `install/families.py` has them.
    private let drafts = ["Qwen3.6-35B-A3B": "incoai/Qwen3.6-35B-A3B-DFlash2",
                          "Qwen3.8-27B": "incoai/Qwen3.8-27B-DFlash2",
                          "Qwen3.8-Flash-Next": "incoai/Qwen3.8-Flash-Next-DFlash2"]

    func testRecordedFamilyWins() {
        XCTAssertEqual(SplashDraft.repository(for: "some/assembly-4bit",
                                              family: "Qwen3.8-27B",
                                              familyDrafts: drafts,
                                              fallback: "incoai/Other"),
                       "incoai/Qwen3.8-27B-DFlash2")
    }

    func testFamilyThatReleasedNoDraftIsNotTalkedIntoOne() {
        // `None` in families.py: the family answered, so a fallback guess must
        // not turn into a draft the engine never released.
        XCTAssertNil(SplashDraft.repository(for: "mlx-community/Qwen3.8-27B-4bit",
                                            family: "Qwen3.8-27B",
                                            familyDrafts: ["Qwen3.8-27B": ""],
                                            fallback: "incoai/Qwen3.8-27B-DFlash2"))
    }

    func testIdFindsItsFamilyWithoutARecordedOne() {
        XCTAssertEqual(SplashDraft.repository(for: "mlx-community/Qwen3.8-27B-4bit",
                                              family: nil,
                                              familyDrafts: drafts),
                       "incoai/Qwen3.8-27B-DFlash2")
        XCTAssertEqual(SplashDraft.repository(for: "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0",
                                              family: nil,
                                              familyDrafts: drafts),
                       "incoai/Qwen3.8-Flash-Next-DFlash2")
    }

    func testLongestFamilyNameTakesTheMatch() {
        let nested = drafts.merging(["Qwen3.8": "incoai/Too-Generic"]) { current, _ in current }
        XCTAssertEqual(SplashDraft.repository(for: "mlx-community/Qwen3.8-27B-4bit",
                                              family: nil,
                                              familyDrafts: nested),
                       "incoai/Qwen3.8-27B-DFlash2")
    }

    func testUnknownModelOnlyTrustsWhatTheCatalogKnows() {
        XCTAssertEqual(SplashDraft.repository(for: "some-other/model",
                                              family: nil,
                                              familyDrafts: drafts,
                                              fallback: "owner/model-DFlash2"),
                       "owner/model-DFlash2")
        XCTAssertNil(SplashDraft.repository(for: "some-other/model",
                                            family: nil,
                                            familyDrafts: drafts))
        XCTAssertNil(SplashDraft.repository(for: "some-other/model",
                                            family: "unknown-family",
                                            familyDrafts: drafts,
                                            fallback: "  "))
    }

    func testPackWithoutFamiliesFallsBackToTheCatalog() {
        XCTAssertEqual(SplashDraft.repository(for: "mlx-community/Qwen3.8-27B-4bit",
                                              family: nil,
                                              familyDrafts: [:],
                                              fallback: "incoai/Qwen3.8-27B-DFlash2"),
                       "incoai/Qwen3.8-27B-DFlash2")
    }

    /// Shaped like the pack's own file, comments and the `vision=False` row
    /// included.
    private let familiesPy = """
    class ModelFamily:
        # The family's name, as the engine names it.
        name: str

    FAMILIES = (
        ModelFamily("Qwen3.8-27B", "incoai/Qwen3.8-27B-DFlash2", QWEN),
        ModelFamily("Qwen3.5-122B-A10B", "incoai/Ornith-1.5-122B-DFlash2", QWEN),
        ModelFamily("Flint", "incoai/Flint-DFlash2", FLINT, vision=False),
        ModelFamily("NoDraft", None, QWEN),
    )
    """

    func testFamiliesFileIsReadAsFamilyToDraft() {
        let parsed = SplashDraft.families(inFamiliesPy: familiesPy)
        XCTAssertEqual(parsed["Qwen3.8-27B"], "incoai/Qwen3.8-27B-DFlash2")
        XCTAssertEqual(parsed["Flint"], "incoai/Flint-DFlash2")
        // `None` keeps the family, with no draft: it must answer for itself.
        XCTAssertEqual(parsed["NoDraft"], "")
        XCTAssertNil(parsed["ModelFamily"])
        XCTAssertEqual(parsed.count, 4)
    }

    func testFamiliesFileWithoutRowsSaysNothing() {
        XCTAssertTrue(SplashDraft.families(inFamiliesPy: "FAMILIES = ()").isEmpty)
    }

    /// The pack installed on this Mac, when there is one: the three recommended
    /// models must resolve to the drafts their families release.
    func testInstalledPackResolvesTheRecommendedModels() throws {
        let root = NSHomeDirectory() + "/Library/Application Support/flashCat/runtimes"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root))?.sorted() ?? []
        guard let version = versions.last,
              let text = try? String(contentsOfFile: root + "/" + version + "/install/families.py",
                                     encoding: .utf8) else {
            throw XCTSkip("no splash pack installed")
        }
        let drafts = SplashDraft.families(inFamiliesPy: text)
        XCTAssertFalse(drafts.isEmpty)
        let expected = ["mlx-community/Qwen3.8-27B-4bit": "incoai/Qwen3.8-27B-DFlash2",
                        "mlx-community/Qwen3.6-35B-A3B-4bit": "incoai/Qwen3.6-35B-A3B-DFlash2",
                        "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0": "incoai/Qwen3.8-Flash-Next-DFlash2"]
        for (id, draft) in expected {
            XCTAssertEqual(SplashDraft.repository(for: id, family: nil, familyDrafts: drafts), draft, id)
        }
    }

    func testParsedPackFileResolvesTheRecommendedModels() {        let parsed = SplashDraft.families(inFamiliesPy: familiesPy)
        XCTAssertEqual(SplashDraft.repository(for: "mlx-community/Qwen3.8-27B-4bit",
                                              family: nil,
                                              familyDrafts: parsed),
                       "incoai/Qwen3.8-27B-DFlash2")
        XCTAssertNil(SplashDraft.repository(for: "NoDraft",
                                            family: nil,
                                            familyDrafts: parsed,
                                            fallback: "incoai/Whatever-DFlash2"))
    }
}
