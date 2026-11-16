// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

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
    /// 思考截断大小：思考请求没有自带预算时，思考超过这么多 token 就收束，
    /// 让出空间给正文。Splash 映射为 `--thinking-token-budget`，oMLX 是按模型
    /// 的 `thinking_budget_tokens` 设置，MTPLX 走启动环境变量
    /// `MTPLX_THINKING_BUDGET`（其 ThinkingGuard 默认关且只覆盖 agent 工具
    /// 循环，聊天范围由 `MTPLX_THINKING_GUARD_SCOPE=all` 一并放开）。
    /// `nil` 表示不限制，思考自然结束。
    public var thinkingBudget: Int?
    /// Free-form extra CLI arguments, split like a shell would.
    public var extraArguments: String?
    /// 落盘前缀缓存的 SSD 预算，单位 GB。
    ///
    /// 引擎的 hot cache 只在内存里，App 一重启就清零，上一次会话的整段历史
    /// 只能从零重算——这是「重启后预填充特别久」的根因。打开这一层后，见过的
    /// 前缀 KV 快照落在 SSD 上，下次直接恢复而不是重算。
    ///
    /// `nil` 跟随引擎自己的默认（MTPLX 默认开、其余默认关）；`0` 显式关闭。
    /// 各家单位拼写不同（Splash 只认 `16G`，其余认 `16GB`），所以这里存 GB
    /// 数，下发时按引擎再拼。
    public var prefixCacheDiskGB: Int?

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
                thinkingBudget: Int? = nil,
                extraArguments: String? = nil,
                prefixCacheDiskGB: Int? = nil) {
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
        self.thinkingBudget = thinkingBudget
        self.extraArguments = extraArguments
        self.prefixCacheDiskGB = prefixCacheDiskGB
    }

    public var isDefault: Bool { self == EngineTuning() }

    /// The tuning a fresh install starts from. The Flash-Next PLE n-gram table is
    /// tens of gigabytes, so both engines that can stream it start that way; oMLX
    /// starts with MTP and Splash with DFlash2, i.e. speculative decoding on.
    /// MTPLX preloads its MTP head (`--load-mtp`) so the first request does not
    /// pay the head-loading latency — the engine's own recommended setup.
    public static func defaults(for id: EngineID) -> EngineTuning {
        EngineTuningProfile.resolved(for: id).defaults
    }

    /// The disk tier's budget in GB, or `nil` when this engine has no such tier
    /// or the reader turned it off.
    public func effectivePrefixCacheDiskGB(for id: EngineID) -> Int? {
        let fallback = EngineTuning.defaults(for: id)
        guard let gb = prefixCacheDiskGB ?? fallback.prefixCacheDiskGB, gb > 0 else { return nil }
        return gb
    }

    /// Arguments that turn the engine's on-disk prefix cache on and point it at
    /// the shared root. Strata has no such tier, so it gets nothing.
    public func prefixCacheArguments(for id: EngineID) -> [String] {
        let profile = EngineTuningProfile.resolved(for: id)
        guard let gb = effectivePrefixCacheDiskGB(for: id) else {
            // Explicitly off. Splash keeps a temporary spill area by default and
            // only `--max-cache-disk 0` turns it off; oMLX is off while its
            // directory is unset; MTPLX defaults to on; mlx-serve to off.
            return profile.prefixCacheOff
        }
        return profile.prefixCacheOn(FlashCatPaths.prefixCacheDirectory(id), gb)
    }

    /// The thinking cap actually applied for `id`: only an explicit knob counts.
    /// `nil` — the field was never filled, or the switch was turned off — means
    /// 不限制，思考自然结束。所有适配引擎都有思考预算面（splash CLI、oMLX 按
    /// 模型设置、MTPLX ThinkingGuard 环境变量），不限制即不下发任何预算。
    public func effectiveThinkingBudget(for id: EngineID) -> Int? {
        guard let thinkingBudget, thinkingBudget > 0 else { return nil }
        return thinkingBudget
    }

    /// CLI arguments appended after the pack's launch profile. Anything the
    /// engine only accepts over HTTP (oMLX's per-model MTP/DFlash settings) is
    /// deliberately absent here.
    public func arguments(for id: EngineID) -> [String] {
        var result = EngineTuningProfile.resolved(for: id).knobs(self)
        result += prefixCacheArguments(for: id)
        result += EngineTuning.splitArguments(extraArguments)
        return result
    }

    /// Draft directory for Splash's local serve path: an explicit choice wins,
    /// the model's own draft is the fallback, and `dflash == false` means no
    /// draft at all.
    public func draftDirectory(automatic: String?) -> String? {
        guard dflash != false else { return nil }
        if let custom = trimmedText(draftModel) { return custom }
        return automatic
    }

    public var draftsDisabled: Bool { dflash == false }

    /// The speculative head this tuning actually starts the engine with. An
    /// unset knob falls back to the pack default — and MTPLX's own default is
    /// MTP on — so a freshly installed engine already reports the right head.
    /// Conflicting oMLX switches resolve to DFlash, matching `sanitized()` and
    /// `omlxSettings`.
    public func speculativeMode(for id: EngineID) -> SpeculativeMode {
        let profile = EngineTuningProfile.resolved(for: id)
        let dflashOn = dflash ?? profile.defaults.dflash ?? false
        // MTPLX's own switch defaults to on — `mtpWhenUnset` carries that, so the
        // resolution is one expression instead of a per-engine switch.
        let mtpOn = mtp ?? profile.mtpWhenUnset
        return profile.speculative(dflashOn, mtpOn)
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
    ///
    /// This is the push-ready form: the resolved thinking budget rides along
    /// here (request 参数 > 模型设置，这里落的是"请求没带预算时"的模型默认),
    /// so `pushTuning` can send the payload as it is. 不限制（nil）时显式下发
    /// `thinking_budget_enabled=false`，把之前推送过的按模型预算清掉。
    public func omlxSettings(id: EngineID = .omlx, draftOverride: String?) -> [String: EngineSettingValue]? {
        var payload = omlxSettings ?? [:]
        if let budget = effectiveThinkingBudget(for: id) {
            payload["thinking_budget_enabled"] = .bool(true)
            payload["thinking_budget_tokens"] = .int(budget)
        } else {
            payload["thinking_budget_enabled"] = .bool(false)
        }
        let draft = draftOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !draft.isEmpty else { return payload.isEmpty ? nil : payload }
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
        // 0 以下的输入当作"没填"；其余收进 256…131072 防手滑。
        if let raw = value.thinkingBudget {
            value.thinkingBudget = raw > 0 ? min(max(raw, 256), 131_072) : nil
        }
        value.draftModel = trimmedText(value.draftModel)
        value.maxMemory = trimmedText(value.maxMemory)
        value.maxContext = trimmedText(value.maxContext)
        value.pleMemory = trimmedText(value.pleMemory)
        value.extraArguments = trimmedText(value.extraArguments)
        // DFlash2 wins a conflicting pair, exactly like `omlxSettings` does.
        if value.mtp == true && value.dflash == true {
            value.mtp = false
        }
        return value
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

    /// Tunings saved before the PLE SSD-offload switch existed carry no
    /// `pleSSDOffload` key. Decoding reads that as "leave it to the engine" —
    /// but the engine's own default is *resident*, while the config page has
    /// always shown the switch as on (the fresh-install default). The result
    /// was the multi-gigabyte Flash-Next n-gram table loading into RAM behind a
    /// toggle that looked enabled. Backfill the fresh-install default (`true`)
    /// into any stored splash/oMLX tuning that predates the switch, straight in
    /// the decoded-JSON document before `EngineTuning` ever sees it. An explicit
    /// `false` is a real choice and stays untouched, and once the key is
    /// written the pass is a no-op — an absent key only ever comes from an old
    /// build, since `nil` cannot be encoded.
    public static func backfillPLEOffload(in document: [String: Any]) -> [String: Any] {
        var result = document
        // 「谁有 PLE 开关」是表里的一列（MTPLX 没有——它的 SSD sidecar 随
        // checkpoint 无条件挂载），所以这里按 descriptor 遍历，而不是写死 id。
        for id in EngineCatalog.allIDs where EngineTuningProfile.resolved(for: id).backfillsPLEOffload {
            guard var configuration = result[id.rawValue] as? [String: Any],
                  var tuning = configuration["tuning"] as? [String: Any],
                  tuning["pleSSDOffload"] == nil else { continue }
            tuning["pleSSDOffload"] = true
            configuration["tuning"] = tuning
            result[id.rawValue] = configuration
        }
        return result
    }
}

/// `nil`、空串和只有空白都算「没填」：参数面板清空输入框后下发的是空字符串，
/// 直接拼进命令行就是一对空引号，引擎会把它当作一个空参数而报用法错误。
private func trimmedText(_ value: String?) -> String? {
    guard let value else { return nil }
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
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

// MARK: - Per-adapter spelling

/// 一个适配器的参数拼写表。
///
/// 同一件事在五家引擎上叫法不同：落盘前缀缓存对 Splash 是
/// `--max-cache-disk 20G --persistent-cache --cache-dir <dir>`，对 oMLX 是
/// `--paged-ssd-cache-dir <dir> --paged-ssd-cache-max-size 20GB`。这些差异以前是
/// 四个公开函数里各一张并列的 `switch id.adapter`：加一个引擎要在四五处各补一个
/// `case`，漏一处就是静默少下发一个参数，而且没有任何测试抓得到「表项缺失」。
/// 收成一张表之后，新增引擎只是加一行数据，公开函数的形态对所有引擎都一样。
///
/// 表项只拼字符串，不读文件、不碰全局状态，所以可以安全地放进 `Sendable` 静态表。
struct EngineTuningProfile: Sendable {
    /// 新装默认值。
    let defaults: EngineTuning
    /// `mtp` 没填时的取值，也就是引擎自己的缺省态度。
    let mtpWhenUnset: Bool
    /// 两个开关合成的实际投机头。
    let speculative: @Sendable (_ dflash: Bool, _ mtp: Bool) -> SpeculativeMode
    /// 显式关掉落盘前缀缓存时要下发的参数。
    let prefixCacheOff: [String]
    /// 打开落盘前缀缓存时的参数：`directory` 是共享根下的目录，`gigabytes` 是预算。
    let prefixCacheOn: @Sendable (_ directory: String, _ gigabytes: Int) -> [String]
    /// 引擎专属 knob 的下发拼写。
    let knobs: @Sendable (EngineTuning) -> [String]
    /// 这个引擎的旧配置要不要补写 `pleSSDOffload` 缺省值。
    let backfillsPLEOffload: Bool

    init(defaults: EngineTuning = EngineTuning(),
         mtpWhenUnset: Bool = false,
         speculative: (@Sendable (Bool, Bool) -> SpeculativeMode)? = nil,
         prefixCacheOff: [String] = [],
         prefixCacheOn: (@Sendable (String, Int) -> [String])? = nil,
         knobs: (@Sendable (EngineTuning) -> [String])? = nil,
         backfillsPLEOffload: Bool = false) {
        self.defaults = defaults
        self.mtpWhenUnset = mtpWhenUnset
        // 没单独声明的引擎按「DFlash2 优先、其次 MTP」合成：两个都没开就等于没有
        // 投机解码，这是最保守的读法。
        self.speculative = speculative ?? { dflash, mtp in
            dflash ? .dflash : (mtp ? .mtp : .off)
        }
        self.prefixCacheOff = prefixCacheOff
        self.prefixCacheOn = prefixCacheOn ?? { _, _ in [] }
        self.knobs = knobs ?? { _ in [] }
        self.backfillsPLEOffload = backfillsPLEOffload
    }

    /// 表里没有的适配器用这张空表。不认识的引擎不该因为「我们没给它写参数」而
    /// 启动失败，代价只是所有 knob 都下不出去。
    static let generic = EngineTuningProfile()

    /// 键就是 descriptor 的 `adapter`：引擎差异只允许出现在 descriptor/adapter
    /// 这一层（CONTRIBUTING 的硬规矩），所以这张表是 per-engine 分支的唯一去处。
    static let byAdapter: [EngineAdapterID: EngineTuningProfile] = [
        .splash: EngineTuningProfile(
            // Flash-Next 的 PLE n-gram 表有几十 GB，两个能流式读它的引擎都从
            // SSD 流式起步；Splash 的投机解码固定是 DFlash2 draft。
            defaults: EngineTuning(dflash: true, pleSSDOffload: true, prefixCacheDiskGB: 20),
            // Splash 只跑 DFlash2 draft，它的 mtp knob 被忽略。
            mtpWhenUnset: false,
            speculative: { dflash, _ in dflash ? .dflash : .off },
            // Splash 默认留一个临时溢写区，只有 `--max-cache-disk 0` 才关掉。
            prefixCacheOff: ["--max-cache-disk", "0"],
            prefixCacheOn: { directory, gigabytes in
                // Splash 的解析器只认裸 `G`；`--persistent-cache` 是让 SSD 层跨
                // 重启保留的那一档，`--cache-dir` 把它挪出系统临时目录。
                ["--max-cache-disk", "\(gigabytes)G",
                 "--persistent-cache",
                 "--cache-dir", directory]
            },
            knobs: { tuning in
                var arguments: [String] = []
                if let value = trimmedText(tuning.maxMemory) { arguments += ["--max-memory", value] }
                if let value = trimmedText(tuning.maxContext) { arguments += ["--max-context", value] }
                if tuning.languageOnly == true { arguments.append("--language-only") }
                if tuning.idleReleaseOff == true { arguments += ["--idle-release", "off"] }
                // 显式缓存尺寸比开关更具体，所以它优先。
                if let value = trimmedText(tuning.pleMemory) {
                    arguments += ["--ple-memory", value]
                } else if let offload = tuning.pleSSDOffload {
                    arguments += ["--ple-memory", offload ? "auto" : "off"]
                }
                return arguments
            },
            backfillsPLEOffload: true),
        .omlx: EngineTuningProfile(
            defaults: EngineTuning(mtp: true, dflash: false, pleSSDOffload: true, prefixCacheDiskGB: 20),
            mtpWhenUnset: true,
            // oMLX 拒绝两个头同时打开的 payload，DFlash 优先与 `omlxSettings` 一致。
            speculative: { dflash, mtp in dflash ? .dflash : (mtp ? .mtp : .off) },
            prefixCacheOff: ["--no-cache"],
            prefixCacheOn: { directory, gigabytes in
                // oMLX 的 paged cache 在目录未设置时是完全关掉的。
                ["--paged-ssd-cache-dir", directory,
                 "--paged-ssd-cache-max-size", "\(gigabytes)GB"]
            },
            backfillsPLEOffload: true),
        .mtplx: EngineTuningProfile(
            // 预加载 MTP head（`--load-mtp`）让第一个请求不必再付加载延迟——
            // 这是引擎自己推荐的装法。
            defaults: EngineTuning(loadMtp: true, prefixCacheDiskGB: 20),
            mtpWhenUnset: true,
            speculative: { _, mtp in mtp ? .mtp : .off },
            prefixCacheOff: ["--ssd-session-cache", "off"],
            prefixCacheOn: { directory, gigabytes in
                ["--ssd-session-cache", "on",
                 "--ssd-session-cache-dir", directory,
                 "--ssd-session-cache-max-size", "\(gigabytes)GB"]
            },
            knobs: { tuning in
                var arguments: [String] = []
                if let mtp = tuning.mtp { arguments.append(mtp ? "--mtp" : "--no-mtp") }
                if let loadMtp = tuning.loadMtp {
                    arguments.append(loadMtp ? "--load-mtp" : "--no-load-mtp")
                }
                if let bits = tuning.mtpQuantBits, bits > 0 {
                    arguments += ["--mtp-quant-bits", String(bits)]
                }
                return arguments
            }),
        .mlxServe: EngineTuningProfile(
            defaults: EngineTuning(mtp: true, prefixCacheDiskGB: 20),
            mtpWhenUnset: true,
            prefixCacheOn: { _, gigabytes in
                // 位置固定是 `$HOME/.mlx-serve/kv-cache`，启动计划把 HOME 指到
                // 共享根上，所以这里只给预算，不给路径。
                ["--prefix-cache-disk", "\(gigabytes)GB"]
            }),
        .strata: EngineTuningProfile(
            // Strata 没有落盘前缀缓存这一层，所以三个缓存字段全空。
            defaults: EngineTuning(mtp: true),
            mtpWhenUnset: true),
    ]

    /// 走 descriptor 的 adapter 查表；未登记的适配器退回 `generic`。
    static func resolved(for id: EngineID) -> EngineTuningProfile {
        byAdapter[id.adapter] ?? generic
    }

    /// 这个适配器有没有表项。conformance 测试靠它抓「新增引擎忘了加表行」。
    static func registered(for adapter: EngineAdapterID) -> EngineTuningProfile? {
        byAdapter[adapter]
    }
}
