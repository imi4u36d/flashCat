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

    // MARK: per-model DFlash2 draft assignment

    func testDraftOverrideFallsBackToEngineTuningWhenAbsent() {
        var tuning = EngineTuning()
        tuning.mtp = true
        XCTAssertEqual(tuning.omlxSettings(id: .omlx, draftOverride: nil),
                       tuning.omlxSettings(id: .omlx, draftOverride: "  "),
                       "a blank override is no override")
        // 空覆盖回落到引擎级调优；未设预算时不限制，只下发 enabled=false。
        let payload = tuning.omlxSettings(draftOverride: nil)
        XCTAssertEqual(payload?["thinking_budget_enabled"], .bool(false))
        XCTAssertNil(payload?["thinking_budget_tokens"])
        XCTAssertEqual(payload?["mtp_fixed_depth"], .null)
    }

    func testDraftOverrideBindsTheCheckpointAndPicksDFlash() {
        var tuning = EngineTuning()
        tuning.mtp = true
        tuning.mtpDepth = 3
        let payload = tuning.omlxSettings(draftOverride: "incoai--Qwen3.8-Flash-Next-DFlash2-GGUF")
        // The assignment means this model runs DFlash2 with that draft, which
        // forces MTP off — the same exclusivity the engine enforces.
        XCTAssertEqual(payload?["dflash_enabled"], .bool(true))
        XCTAssertEqual(payload?["mtp_enabled"], .bool(false))
        XCTAssertEqual(payload?["dflash_draft_model"], .string("incoai--Qwen3.8-Flash-Next-DFlash2-GGUF"))
        XCTAssertNil(payload?["mtp_fixed_depth"], "the retired head's knobs leave the payload")
    }

    func testDraftOverrideWorksWhenTheEngineTuningSendsNothing() {
        // All-default tuning produces no payload of its own, but a model with
        // an assigned draft still needs its settings pushed before a hot load.
        let payload = EngineTuning().omlxSettings(draftOverride: "/tmp/draft")
        XCTAssertEqual(payload?["dflash_enabled"], .bool(true))
        XCTAssertEqual(payload?["dflash_draft_model"], .string("/tmp/draft"))
    }

    // MARK: 思考截断大小

    func testThinkingBudgetNilMeansUnlimited() {
        // 关闭 = 不限制：没填或清空时不下发任何预算，三个引擎一致。
        XCTAssertNil(EngineTuning().effectiveThinkingBudget(for: .splash))
        XCTAssertNil(EngineTuning().effectiveThinkingBudget(for: .omlx))
        XCTAssertNil(EngineTuning().effectiveThinkingBudget(for: .mtplx))
        // 打开 = 手动值生效；0/负数视同没填，同样不限制。
        var tuning = EngineTuning()
        tuning.thinkingBudget = 8192
        XCTAssertEqual(tuning.effectiveThinkingBudget(for: .splash), 8192)
        tuning.thinkingBudget = 0
        XCTAssertNil(tuning.effectiveThinkingBudget(for: .splash))
    }

    func testOMLXPushReadyPayloadCarriesTheThinkingBudget() {
        // 不限制（nil）也要显式下发 enabled=false，清掉之前推送过的按模型预算。
        XCTAssertEqual(EngineTuning().omlxSettings(id: .omlx, draftOverride: nil),
                       ["thinking_budget_enabled": .bool(false)])

        var tuning = EngineTuning()
        tuning.mtp = true
        tuning.thinkingBudget = 8192
        let payload = tuning.omlxSettings(id: .omlx, draftOverride: nil)
        XCTAssertEqual(payload?["thinking_budget_enabled"], .bool(true))
        XCTAssertEqual(payload?["thinking_budget_tokens"], .int(8192))
        XCTAssertEqual(payload?["mtp_enabled"], .bool(true))
    }

    func testSanitizedClampsTheThinkingBudget() {
        var tuning = EngineTuning()
        tuning.thinkingBudget = 999_999
        XCTAssertEqual(tuning.sanitized().thinkingBudget, 131_072)
        tuning.thinkingBudget = 10
        XCTAssertEqual(tuning.sanitized().thinkingBudget, 256)
        tuning.thinkingBudget = 0
        XCTAssertNil(tuning.sanitized().thinkingBudget)
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

    // MARK: speculative mode

    func testSpeculativeModeFollowsEachEngineTuning() {
        // Fresh tunings: splash runs DFlash2, oMLX MTP, MTPLX its own MTP.
        XCTAssertEqual(EngineTuning().speculativeMode(for: .splash), .dflash)
        XCTAssertEqual(EngineTuning().speculativeMode(for: .omlx), .mtp)
        XCTAssertEqual(EngineTuning().speculativeMode(for: .mtplx), .mtp)

        // Pack defaults reproduce the same answer through the fallback path.
        for id in EngineID.allCases {
            XCTAssertEqual(EngineTuning.defaults(for: id).speculativeMode(for: id),
                           EngineTuning().speculativeMode(for: id))
        }

        // Splash only has DFlash2; turning it off leaves nothing.
        var splash = EngineTuning()
        splash.dflash = false
        XCTAssertEqual(splash.speculativeMode(for: .splash), .off)

        // oMLX picks whichever head is on, DFlash winning a conflict.
        var omlx = EngineTuning()
        omlx.dflash = true
        XCTAssertEqual(omlx.speculativeMode(for: .omlx), .dflash)
        omlx.mtp = false
        XCTAssertEqual(omlx.speculativeMode(for: .omlx), .dflash)
        omlx.dflash = false
        XCTAssertEqual(omlx.speculativeMode(for: .omlx), .off)

        // MTPLX only has MTP, and `nil` keeps the pack's on default.
        var mtplx = EngineTuning()
        mtplx.mtp = false
        XCTAssertEqual(mtplx.speculativeMode(for: .mtplx), .off)
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
        tuning.thinkingBudget = 16384

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

    func testMTPLXPreloadsItsMTPHead() {
        let tuning = EngineTuning.defaults(for: .mtplx)
        XCTAssertEqual(tuning.loadMtp, true)
        // 思考截断默认不限制：出厂默认不带预算，需要时在配置里手动开。
        XCTAssertNil(tuning.thinkingBudget)
        // 思考截断走环境变量，不占 CLI 参数位。
        XCTAssertEqual(tuning.arguments(for: .mtplx), ["--load-mtp"])
        for id in EngineID.allCases {
            XCTAssertEqual(EngineTuning.defaults(for: id).sanitized(), EngineTuning.defaults(for: id),
                           "defaults survive sanitizing on \(id)")
        }
    }
}

final class EngineTuningMigrationTests: XCTestCase {

    /// The pre-switch document shape: a tuning object without `pleSSDOffload`
    /// used to decode as "leave it to the engine", whose default is *resident*.
    private let legacyDocument: [String: Any] = [
        "active": ["version": "omlx"],
        "omlx": ["port": 8100,
                 "tuning": ["dflash": false, "mtp": true]],
        "splash": ["tuning": ["dflash": true, "mtp": false]],
        "mtplx": ["tuning": ["loadMtp": true]],
    ]

    /// `EngineStore.load()` decodes the whole document; the tests decode the
    /// one tuning each migration pass touches.
    private func tuning(of engine: String, in document: [String: Any]) throws -> EngineTuning? {
        guard let configuration = document[engine] as? [String: Any],
              let tuning = configuration["tuning"] else { return nil }
        let data = try JSONSerialization.data(withJSONObject: tuning)
        return try JSONDecoder().decode(EngineTuning.self, from: data)
    }

    func testBackfillAddsTheFreshInstallDefaultToLegacyTunings() throws {
        let migrated = EngineTuning.backfillPLEOffload(in: legacyDocument)

        XCTAssertEqual(try tuning(of: "omlx", in: migrated)?.pleSSDOffload, true)
        XCTAssertEqual(try tuning(of: "splash", in: migrated)?.pleSSDOffload, true)
        // Everything else the old build stored stays exactly as it was.
        XCTAssertEqual(try tuning(of: "omlx", in: migrated)?.mtp, true)
        XCTAssertEqual(try tuning(of: "omlx", in: migrated)?.dflash, false)
        XCTAssertEqual(try tuning(of: "splash", in: migrated)?.dflash, true)
        // MTPLX has no PLE switch, so its tuning is untouched.
        XCTAssertEqual(try tuning(of: "mtplx", in: migrated)?.pleSSDOffload, nil)
        XCTAssertEqual(try tuning(of: "mtplx", in: migrated)?.loadMtp, true)
    }

    func testBackfillProducesAPayloadTheEngineAccepts() throws {
        let migrated = EngineTuning.backfillPLEOffload(in: legacyDocument)
        let settings = try XCTUnwrap(tuning(of: "omlx", in: migrated)?.omlxSettings)
        XCTAssertEqual(settings["qwen4_ple_ssd_offload"], .bool(true))
    }

    func testExplicitFalseAndMissingTuningsAreLeftAlone() throws {
        var document = legacyDocument
        document["omlx"] = ["port": 8100,
                            "tuning": ["dflash": false, "mtp": true, "pleSSDOffload": false]]
        document["splash"] = ["port": 8000]

        let migrated = EngineTuning.backfillPLEOffload(in: document)

        // An explicit `false` is a real choice; a missing tuning object falls
        // back to defaults in the store and needs no injection.
        XCTAssertEqual(try tuning(of: "omlx", in: migrated)?.pleSSDOffload, false)
        XCTAssertNil((migrated["splash"] as? [String: Any])?["tuning"])
    }

    func testBackfillIsIdempotent() throws {
        let once = EngineTuning.backfillPLEOffload(in: legacyDocument)
        let twice = EngineTuning.backfillPLEOffload(in: once)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: twice),
                       try JSONSerialization.data(withJSONObject: once))
    }
}
