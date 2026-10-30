import Foundation

/// Which speculative-decoding head an engine runs with. The overview derives
/// its draft-acceptance label from this, so the metric always names the head
/// that is actually producing the rate.
public enum SpeculativeMode: Equatable, Sendable {
    /// Splash's DFlash2 draft / oMLX's DFlash head.
    case dflash
    /// Native multi-token prediction.
    case mtp
    /// Speculative decoding is off: no acceptance rate exists to show.
    case off

    /// Short head name for UI labels; empty when nothing is active.
    public var headName: String {
        switch self {
        case .dflash: return "DFlash2"
        case .mtp: return "MTP"
        case .off: return ""
        }
    }
}

/// Per-engine knobs the reader can change from that engine's own config page.
/// Everything is optional: `nil` means "leave it to the engine", which keeps a
/// pack's own defaults intact and lets a new build add a knob without a
/// migration.
public struct EngineTuning: Codable, Equatable, Sendable {
    /// Native multi-token prediction. MTPLX gets `--mtp`/`--no-mtp`; oMLX takes
    /// it as a per-model server setting.
    public var mtp: Bool?
    /// Fixed MTP depth. `nil` keeps the engine's adaptive depth.
    public var mtpDepth: Int?
    /// MTPLX: preload the MTP head with the model (`--load-mtp`).
    public var loadMtp: Bool?
    /// MTPLX: quantize the MTP head to this many bits.
    public var mtpQuantBits: Int?
    /// Speculative decoding: Splash's DFlash2 draft, oMLX's DFlash head.
    public var dflash: Bool?
    /// A DFlash2 draft directory to use instead of the automatically picked one.
    public var draftModel: String?
    /// Splash `--max-memory` (for example `24G`).
    public var maxMemory: String?
    /// Splash `--max-context` (for example `256K`).
    public var maxContext: String?
    /// Splash `--language-only`: skip vision preparation.
    public var languageOnly: Bool?
    /// Splash `--idle-release off`: keep the weights resident between requests.
    public var idleReleaseOff: Bool?
    /// Splash `--ple-memory`: the RAM row cache of a Qwen3.8-Flash-Next PLE
    /// n-gram table, e.g. `2G`. Rows the cache cannot hold stream from the SSD;
    /// `off` loads the whole table (tens of GB). `nil` leaves it to the engine.
    public var pleMemory: String?
    /// Keep the PLE n-gram table on the SSD instead of loading it resident.
    /// Splash spells that `--ple-memory auto`/`off`; oMLX takes the per-model
    /// `qwen4_ple_ssd_offload` setting. MTPLX has no switch — it attaches its
    /// SSD sidecar whenever the checkpoint ships `ngram-table.safetensors`.
    public var pleSSDOffload: Bool?
    /// Free-form extra CLI arguments, split like a shell would.
    public var extraArguments: String?

    public init(mtp: Bool? = nil,
                mtpDepth: Int? = nil,
                loadMtp: Bool? = nil,
                mtpQuantBits: Int? = nil,
                dflash: Bool? = nil,
                draftModel: String? = nil,
                maxMemory: String? = nil,
                maxContext: String? = nil,
                languageOnly: Bool? = nil,
                idleReleaseOff: Bool? = nil,
                pleMemory: String? = nil,
                pleSSDOffload: Bool? = nil,
                extraArguments: String? = nil) {
        self.mtp = mtp
        self.mtpDepth = mtpDepth
        self.loadMtp = loadMtp
        self.mtpQuantBits = mtpQuantBits
        self.dflash = dflash
        self.draftModel = draftModel
        self.maxMemory = maxMemory
        self.maxContext = maxContext
        self.languageOnly = languageOnly
        self.idleReleaseOff = idleReleaseOff
        self.pleMemory = pleMemory
        self.pleSSDOffload = pleSSDOffload
        self.extraArguments = extraArguments
    }

    public var isDefault: Bool { self == EngineTuning() }

    /// The tuning a fresh install starts from. The Flash-Next PLE n-gram table is
    /// tens of gigabytes, so both engines that can stream it start that way; oMLX
    /// starts with MTP and Splash with DFlash2, i.e. speculative decoding on.
    public static func defaults(for id: EngineID) -> EngineTuning {
        switch id {
        case .splash:
            return EngineTuning(dflash: true, pleSSDOffload: true)
        case .omlx:
            return EngineTuning(mtp: true, dflash: false, pleSSDOffload: true)
        case .mtplx:
            return EngineTuning()
        }
    }

    /// CLI arguments appended after the pack's launch profile. Anything the
    /// engine only accepts over HTTP (oMLX's per-model MTP/DFlash settings) is
    /// deliberately absent here.
    public func arguments(for id: EngineID) -> [String] {
        var result: [String] = []
        switch id {
        case .splash:
            if let value = trimmed(maxMemory) { result += ["--max-memory", value] }
            if let value = trimmed(maxContext) { result += ["--max-context", value] }
            if languageOnly == true { result.append("--language-only") }
            if idleReleaseOff == true { result += ["--idle-release", "off"] }
            // An explicit cache size says more than the on/off switch, so it wins.
            if let value = trimmed(pleMemory) {
                result += ["--ple-memory", value]
            } else if let offload = pleSSDOffload {
                result += ["--ple-memory", offload ? "auto" : "off"]
            }
        case .mtplx:
            if let mtp { result.append(mtp ? "--mtp" : "--no-mtp") }
            if let loadMtp { result.append(loadMtp ? "--load-mtp" : "--no-load-mtp") }
            if let bits = mtpQuantBits, bits > 0 { result += ["--mtp-quant-bits", String(bits)] }
        case .omlx:
            break
        }
        result += EngineTuning.splitArguments(extraArguments)
        return result
    }

    /// Draft directory for Splash's local serve path: an explicit choice wins,
    /// the model's own draft is the fallback, and `dflash == false` means no
    /// draft at all.
    public func draftDirectory(automatic: String?) -> String? {
        guard dflash != false else { return nil }
        if let custom = trimmed(draftModel) { return custom }
        return automatic
    }

    public var draftsDisabled: Bool { dflash == false }

    /// The speculative head this tuning actually starts the engine with. An
    /// unset knob falls back to the pack default — and MTPLX's own default is
    /// MTP on — so a freshly installed engine already reports the right head.
    /// Conflicting oMLX switches resolve to DFlash, matching `sanitized()` and
    /// `omlxSettings`.
    public func speculativeMode(for id: EngineID) -> SpeculativeMode {
        let fallback = EngineTuning.defaults(for: id)
        let dflashOn = dflash ?? fallback.dflash ?? false
        let mtpOn: Bool
        switch id {
        case .splash, .omlx:
            mtpOn = mtp ?? fallback.mtp ?? false
        case .mtplx:
            // The pack's own switch defaults to on; `nil` leaves it that way.
            mtpOn = mtp ?? true
        }
        switch id {
        case .splash:
            // Splash only runs the DFlash2 draft; its mtp knob is ignored.
            return dflashOn ? .dflash : .off
        case .omlx:
            if dflashOn { return .dflash }
            return mtpOn ? .mtp : .off
        case .mtplx:
            return mtpOn ? .mtp : .off
        }
    }

    /// oMLX applies MTP/DFlash per model through
    /// `PUT /admin/api/models/{id}/settings`. The engine refuses a payload where
    /// both heads are on, so enabling one always switches the other off.
    public var omlxSettings: [String: EngineSettingValue]? {
        var payload: [String: EngineSettingValue] = [:]
        if dflash == true {
            payload["dflash_enabled"] = .bool(true)
            payload["mtp_enabled"] = .bool(false)
        } else if mtp == true {
            payload["mtp_enabled"] = .bool(true)
            payload["dflash_enabled"] = .bool(false)
            // `null` is oMLX's adaptive depth; anything else pins the depth.
            payload["mtp_fixed_depth"] = mtpDepth.map { .int($0) } ?? .null
        } else {
            if let dflash { payload["dflash_enabled"] = .bool(dflash) }
            if let mtp { payload["mtp_enabled"] = .bool(mtp) }
        }
        // Qwen4-Exp (Flash-Next) keeps its 51B-row PLE n-gram table on SSD and
        // gathers rows through mmap; oMLX forces this on by itself when the
        // resident load would leave no room to serve prompts.
        if let offload = pleSSDOffload { payload["qwen4_ple_ssd_offload"] = .bool(offload) }
        return payload.isEmpty ? nil : payload
    }

    /// The settings for one model, plus a DFlash2 draft the model page assigned
    /// to it. An assignment means this model runs DFlash2 with that checkpoint
    /// (oMLX's `dflash_draft_model`), which necessarily turns MTP off for it —
    /// the same exclusivity the engine itself enforces. A `nil`/empty override
    /// falls back to the engine-level tuning untouched.
    public func omlxSettings(draftOverride: String?) -> [String: EngineSettingValue]? {
        let draft = draftOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !draft.isEmpty else { return omlxSettings }
        var payload = omlxSettings ?? [:]
        payload["dflash_enabled"] = .bool(true)
        payload["mtp_enabled"] = .bool(false)
        // The retired head's knob has no business in a DFlash payload.
        payload.removeValue(forKey: "mtp_fixed_depth")
        payload["dflash_draft_model"] = .string(draft)
        return payload
    }

    /// oMLX's own constraint, mirrored here so the config page can keep the two
    /// switches mutually exclusive before the request ever leaves the app.
    public var omlxHeadsConflict: Bool { mtp == true && dflash == true }

    public func sanitized() -> EngineTuning {
        var value = self
        value.mtpDepth = value.mtpDepth.map { min(max($0, 1), 16) }
        value.mtpQuantBits = value.mtpQuantBits.map { min(max($0, 2), 16) }
        value.draftModel = trimmed(value.draftModel)
        value.maxMemory = trimmed(value.maxMemory)
        value.maxContext = trimmed(value.maxContext)
        value.pleMemory = trimmed(value.pleMemory)
        value.extraArguments = trimmed(value.extraArguments)
        // DFlash2 wins a conflicting pair, exactly like `omlxSettings` does.
        if value.mtp == true && value.dflash == true {
            value.mtp = false
        }
        return value
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Split a free-form argument string the way the settings page always has:
    /// whitespace separates, single or double quotes group.
    public static func splitArguments(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let closing = quote {
                if character == closing { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// JSON value for an engine-side setting. Keeping it typed (instead of `Any`)
/// lets the payload builder stay testable and `Sendable`.
public enum EngineSettingValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    /// A path or repository id, e.g. oMLX's `dflash_draft_model`.
    case string(String)
    case null

    public var jsonObject: Any {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value
        case .string(let value): return value
        case .null: return NSNull()
        }
    }
}
