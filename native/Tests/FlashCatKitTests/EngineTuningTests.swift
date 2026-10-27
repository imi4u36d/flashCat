import XCTest
@testable import FlashCatKit

final class EngineTuningTests: XCTestCase {

    func testDefaultTuningAddsNoArguments() {
        for id in EngineID.allCases {
            XCTAssertEqual(EngineTuning().arguments(for: id), [])
        }
    }

    func testSplashArgumentsCarryTheSplashOnlySwitches() {
        var tuning = EngineTuning()
        tuning.maxMemory = " 24G "
        tuning.maxContext = "256K"
        tuning.languageOnly = true
        tuning.extraArguments = "--decode-share 0.5"

        XCTAssertEqual(tuning.arguments(for: .splash),
                       ["--max-memory", "24G", "--max-context", "256K",
                        "--language-only", "--decode-share", "0.5"])
        // MTPLX/oMLX do not understand splash's memory flags.
        XCTAssertEqual(tuning.arguments(for: .mtplx), ["--decode-share", "0.5"])
        XCTAssertEqual(tuning.arguments(for: .omlx), ["--decode-share", "0.5"])
    }

    func testMtplxSwitchesMapToItsCli() {
        var tuning = EngineTuning()
        tuning.mtp = false
        tuning.loadMtp = true
        tuning.mtpQuantBits = 4
        XCTAssertEqual(tuning.arguments(for: .mtplx),
                       ["--no-mtp", "--load-mtp", "--mtp-quant-bits", "4"])

        tuning.mtp = true
        tuning.loadMtp = false
        XCTAssertEqual(tuning.arguments(for: .mtplx),
                       ["--mtp", "--no-load-mtp", "--mtp-quant-bits", "4"])
    }

    func testOMLXPayloadNeverEnablesBothHeads() {
        var tuning = EngineTuning()
        tuning.mtp = true
        tuning.depth(3)
        XCTAssertEqual(tuning.omlxSettings,
                       ["mtp_enabled": .bool(true),
                        "dflash_enabled": .bool(false),
                        "mtp_fixed_depth": .int(3)])

        tuning.dflash = true
        XCTAssertEqual(tuning.omlxSettings,
                       ["dflash_enabled": .bool(true), "mtp_enabled": .bool(false)])
        XCTAssertTrue(tuning.omlxHeadsConflict)

        // Sanitizing resolves the conflict in DFlash's favour, matching the UI.
        let cleaned = tuning.sanitized()
        XCTAssertEqual(cleaned.dflash, true)
        XCTAssertEqual(cleaned.mtp, false)  // the conflicting flag is dropped
        XCTAssertEqual(cleaned.omlxSettings,
                       ["dflash_enabled": .bool(true), "mtp_enabled": .bool(false)])
    }

    func testOMLXAdaptiveDepthSendsNull() {
        var tuning = EngineTuning()
        tuning.mtp = true
        XCTAssertEqual(tuning.omlxSettings?["mtp_fixed_depth"], .null)
    }

    func testOMLXWithNothingTogglesSendsNoPayload() {
        XCTAssertNil(EngineTuning().omlxSettings)
        var tuning = EngineTuning()
        tuning.draftModel = "/tmp/draft"
        XCTAssertNil(tuning.omlxSettings, "a draft path alone says nothing about MTP/DFlash")
    }

    // MARK: PLE n-gram table offload

    func testSplashTakesTheNgramCacheSizeVerbatim() {
        var tuning = EngineTuning()
        tuning.pleMemory = " 2G "
        XCTAssertEqual(tuning.arguments(for: .splash), ["--ple-memory", "2G"])
        // Only splash reads it as a flag.
        XCTAssertEqual(tuning.arguments(for: .mtplx), [])
        XCTAssertEqual(tuning.arguments(for: .omlx), [])
    }

    func testSplashMapsTheOffloadSwitchOntoPleMemory() {
        var tuning = EngineTuning()
        tuning.pleSSDOffload = true
        XCTAssertEqual(tuning.arguments(for: .splash), ["--ple-memory", "auto"])

        tuning.pleSSDOffload = false
        XCTAssertEqual(tuning.arguments(for: .splash), ["--ple-memory", "off"])

        // An explicit size beats the switch, so the CLI never carries both.
        tuning.pleMemory = "4G"
        XCTAssertEqual(tuning.arguments(for: .splash), ["--ple-memory", "4G"])
    }

    func testOMLXPushesTheNgramOffloadAsItsOwnSetting() {
        var tuning = EngineTuning()
        tuning.pleSSDOffload = true
        XCTAssertEqual(tuning.omlxSettings, ["qwen4_ple_ssd_offload": .bool(true)])

        tuning.pleSSDOffload = false
        XCTAssertEqual(tuning.omlxSettings, ["qwen4_ple_ssd_offload": .bool(false)])
    }

    func testNgramOffloadCoexistsWithTheHeads() {
        var tuning = EngineTuning()
        tuning.mtp = true
        tuning.pleSSDOffload = true
        XCTAssertEqual(tuning.omlxSettings,
                       ["mtp_enabled": .bool(true),
                        "dflash_enabled": .bool(false),
                        "mtp_fixed_depth": .null,
                        "qwen4_ple_ssd_offload": .bool(true)])
        XCTAssertFalse(tuning.omlxHeadsConflict)
    }

    func testDraftDirectoryHonoursTheDisableSwitch() {
        var tuning = EngineTuning()
        XCTAssertEqual(tuning.draftDirectory(automatic: "/models/draft"), "/models/draft")

        tuning.draftModel = "/custom/draft"
        XCTAssertEqual(tuning.draftDirectory(automatic: "/models/draft"), "/custom/draft")

        tuning.dflash = false
        XCTAssertNil(tuning.draftDirectory(automatic: "/models/draft"))
        XCTAssertTrue(tuning.draftsDisabled)
    }

    func testSplitArgumentsHandlesQuotes() {
        XCTAssertEqual(EngineTuning.splitArguments("a \"b c\" d"), ["a", "b c", "d"])
        XCTAssertEqual(EngineTuning.splitArguments("  "), [])
        XCTAssertEqual(EngineTuning.splitArguments(nil), [])
        XCTAssertEqual(EngineTuning.splitArguments("--x 'y z'"), ["--x", "y z"])
    }

    func testTuningSurvivesACodableRoundTrip() throws {
        var tuning = EngineTuning()
        tuning.mtp = true
        tuning.mtpDepth = 4
        tuning.dflash = false
        tuning.draftModel = "/draft"
        tuning.maxMemory = "16G"
        tuning.pleMemory = "2G"
        tuning.pleSSDOffload = true

        let data = try JSONEncoder().encode(tuning)
        let decoded = try JSONDecoder().decode(EngineTuning.self, from: data)
        XCTAssertEqual(decoded, tuning)
    }

    func testSanitizedClampsNumericKnobs() {
        var tuning = EngineTuning()
        tuning.mtpDepth = 99
        tuning.mtpQuantBits = 0
        let cleaned = tuning.sanitized()
        XCTAssertEqual(cleaned.mtpDepth, 16)
        XCTAssertEqual(cleaned.mtpQuantBits, 2)
    }
}

private extension EngineTuning {
    mutating func depth(_ value: Int) { mtpDepth = value }
}

final class EngineTuningDefaultsTests: XCTestCase {

    func testSplashStartsWithDFlash2AndTheNgramTableOnSSD() {
        let tuning = EngineTuning.defaults(for: .splash)
        XCTAssertEqual(tuning.dflash, true)
        XCTAssertEqual(tuning.pleSSDOffload, true)
        XCTAssertEqual(tuning.arguments(for: .splash), ["--ple-memory", "auto"])
        XCTAssertEqual(tuning.draftDirectory(automatic: "/models/draft"), "/models/draft")
    }

    func testOMLXStartsWithMTPAndTheNgramTableOnSSD() {
        let tuning = EngineTuning.defaults(for: .omlx)
        XCTAssertEqual(tuning.mtp, true)
        XCTAssertEqual(tuning.dflash, false)
        XCTAssertEqual(tuning.pleSSDOffload, true)
        XCTAssertEqual(tuning.omlxSettings,
                       ["mtp_enabled": .bool(true),
                        "dflash_enabled": .bool(false),
                        "mtp_fixed_depth": .null,
                        "qwen4_ple_ssd_offload": .bool(true)])
        XCTAssertFalse(tuning.omlxHeadsConflict)
    }

    func testMTPLXKeepsItsOwnDefault() {
        XCTAssertEqual(EngineTuning.defaults(for: .mtplx), EngineTuning())
        for id in EngineID.allCases {
            XCTAssertEqual(EngineTuning.defaults(for: id).sanitized(), EngineTuning.defaults(for: id),
                           "defaults survive sanitizing on \(id)")
        }
    }
}
