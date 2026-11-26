// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation

/// A model an engine itself recommends, tagged with the engine that ships the
/// list.
///
/// The rows are not flashCat's opinion: Splash's pack carries
/// `install/suggested-models.tsv`, and MTPLX's pack carries the same catalog
/// its macOS app shows. Both are read from the installed pack, so a new engine
/// release updates the model page without a flashCat release. oMLX and
/// MLX-Serve publish no such list, so they have no recommendation rows at all.
///
/// Ownership is still a property of the row (`engines`) instead of living in a
/// per-engine array: the model page filters with a `contains` on that set.
package struct ModelRecommendation: Identifiable, Hashable {
    /// Hub repository, `owner/repo`, optionally `owner/repo:VARIANT` for a
    /// single GGUF quant inside a repository that also carries the others.
    package let id: String
    /// Approximate download size in bytes; 0 when the engine's list states none.
    package let bytes: Int
    /// Unified memory the pack is meant for, in GB; 0 when not stated.
    package let minimumMemory: Int
    package let summary: String
    package let tags: [String]
    package let draftRepository: String?
    /// How strongly the engine prefers this row (bigger is stronger); the
    /// hardware recommendation picks "the best this machine can run" from it
    /// instead of guessing strength from the memory floor. Zero keeps a row in
    /// the engine catalog without putting it on the hardware ranked ladder.
    package let rank: Int
    /// The engines that ship this row. A row outside an engine's set is never
    /// offered there.
    package let engines: Set<EngineID>

    package var repo: String {
        id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id
    }

    package var variant: String? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        return String(id[id.index(after: colon)...])
    }

    package var shortName: String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    package var owner: String {
        repo.split(separator: "/").first.map(String.init) ?? repo
    }

    package var sizeText: String? {
        bytes > 0 ? "≈" + Format.size(bytes) : nil
    }

    package var memoryText: String? {
        minimumMemory > 0 ? "\(minimumMemory) GB 内存起" : nil
    }

    /// The tag names shown on the card, engine tags first so a card in the
    /// Splash column reads "Splash" before "GGUF".
    package var engineLabels: [String] {
        EngineCatalog.allIDs.filter { engines.contains($0) }.map(\.displayName)
    }
}

/// The engine-owned recommendation lists, read from the packs on disk.
///
/// There is deliberately no fallback catalog in the app: a hand-written list is
/// exactly what drifts from the engine it claims to describe. An engine that
/// is not installed has no list, and neither oMLX nor MLX-Serve has one to
/// read.
package enum ModelRecommendations {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [EngineID: [ModelRecommendation]] = [:]

    /// The rows this engine itself recommends on this Mac, in its own order.
    ///
    /// Splash's file lists every variant and its app shows one per family — the
    /// strongest that fits — so `NativeModelCatalog.splash` applies that rule.
    /// MTPLX's catalog returns the list its app would show for this chip tier
    /// and memory, so the ordering and the memory verdicts are its own.
    package static func list(for engine: EngineID) -> [ModelRecommendation] {
        lock.lock()
        if let hit = cache[engine] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let installation = EngineInstallations.newest(engine, version: nil) else {
            store([], for: engine)
            return []
        }
        let rows: [ModelRecommendation]
        switch engine {
        case .splash:
            rows = NativeModelCatalog.splash(
                root: installation.root.path,
                memoryGB: DeviceProfile.current().memoryGB)
        case .mtplx:
            rows = NativeModelCatalog.mtplx(
                root: installation.root.path,
                entrypoint: installation.entrypoint.path,
                machine: DeviceProfile.current().machine)
        case .omlx, .mlxServe:
            rows = []
        default:
            // `EngineID` 不是闭合枚举：未来新增的引擎如果没有随包目录，
            // 就按「没有推荐列表」处理，而不是让测试构建在这里失败。
            rows = []
        }
        store(rows, for: engine)
        return rows
    }

    /// Drop every cached list. Called when an engine pack appears, disappears
    /// or is updated: the catalogs live inside the pack, so the old rows are
    /// no longer the engine's answer.
    package static func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private static func store(
        _ rows: [ModelRecommendation], for engine: EngineID
    ) {
        lock.lock()
        cache[engine] = rows
        lock.unlock()
    }
}

/// Readers for the two engines that ship a model list inside the pack.
package enum NativeModelCatalog {
    // MARK: Splash

    /// `install/suggested-models.tsv`, in the pack's own words:
    ///
    /// > The models Splash suggests, best first: the desktop app offers them and
    /// > shell completion completes them. MODEL<TAB>NAME<TAB>MEMORY<TAB>SIZE<TAB>ABOUT
    ///
    /// The app offers, per name, the variant with the most MEMORY that the Mac
    /// has. A family whose every variant asks for more memory than this Mac has
    /// is not offered at all — that is the engine's rule, not ours.
    package static func splash(root: String, memoryGB: Int) -> [ModelRecommendation] {
        let path = root + "/install/suggested-models.tsv"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            AppLog.debug(.app, "Splash 推荐列表读取失败：\(path)")
            return []
        }

        struct Row {
            let model: String
            let name: String
            let memory: Int
            let gigabytes: Int
            let about: String
        }

        var best: [String: Row] = [:]
        var familyOrder: [String] = []
        var seenFamilies = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line).trimmingCharacters(in: .newlines)
            guard !raw.isEmpty, !raw.hasPrefix("#") else { continue }
            let columns = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 5,
                let memory = Int(columns[2]), let gigabytes = Int(columns[3])
            else { continue }
            let row = Row(
                model: columns[0], name: columns[1], memory: memory,
                gigabytes: gigabytes, about: columns[4])
            if seenFamilies.insert(row.name).inserted { familyOrder.append(row.name) }
            // "the most MEMORY that the Mac has" — a tie keeps the first row.
            if memory <= memoryGB, memory > (best[row.name]?.memory ?? Int.min) {
                best[row.name] = row
            }
        }

        let selected = familyOrder.compactMap { best[$0] }
        return selected.enumerated().map { offset, row in
            ModelRecommendation(
                id: row.model,
                bytes: row.gigabytes * 1_000_000_000,
                minimumMemory: row.memory,
                summary: row.about,
                tags: splashTags(for: row.model),
                draftRepository: nil,
                // First row is the engine's first pick; ModelFit treats a
                // larger rank as stronger.
                rank: selected.count - offset,
                engines: [.splash])
        }
    }

    private static func splashTags(for id: String) -> [String] {
        var tags: [String] = []
        let repo = id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id
        tags.append(repo.lowercased().contains("gguf") ? "GGUF" : "MLX")
        if let quant = ModelQuantization.detect(in: id) { tags.append(quant) }
        return tags
    }

    // MARK: MTPLX

    /// Ask the pack's own Python for the list its macOS app would show.
    ///
    /// `model_catalog.py` is the sync pair of the app's `MTPLXModelOption`
    /// catalog and `ModelFeasibility` policy, so calling it is how flashCat
    /// stays aligned with a pack update instead of copying the numbers into
    /// Swift. The script also works out each model's RAM floor by asking the
    /// same policy at every standard memory size — the floor a user reads on
    /// the card is therefore the point at which MTPLX itself starts offering it.
    package static func mtplx(
        root: String, entrypoint: String, machine: MachineProfile
    ) -> [ModelRecommendation] {
        let tier = chipTier(for: machine.chipName)
        guard
            let output = runPython(
                executable: entrypoint,
                workingDirectory: root,
                arguments: ["-c", mtplxScript, String(machine.memoryGB), tier]),
            let data = output.data(using: .utf8),
            let payload = try? JSONDecoder().decode(MTPLXPayload.self, from: data)
        else {
            AppLog.warning(.app, "MTPLX 推荐列表读取失败：\(machine.chipName)")
            return []
        }

        let total = payload.models.count
        return payload.models.enumerated().map { offset, model in
            ModelRecommendation(
                id: model.hf,
                bytes: model.bytes,
                minimumMemory: model.floor,
                summary: model.detail,
                tags: mtplxTags(for: model),
                draftRepository: nil,
                rank: total - offset,
                engines: [.mtplx])
        }
    }

    private static func mtplxTags(for model: MTPLXPayload.Model) -> [String] {
        var tags: [String] = []
        if let quant = ModelQuantization.detect(in: model.detail) {
            tags.append(quant)
        } else if let quant = ModelQuantization.detect(in: model.name) {
            tags.append(quant)
        }
        tags.append(model.arOnly ? "AR" : "MTP")
        let text = (model.name + " " + model.detail).lowercased()
        if text.contains("vision") { tags.append("视觉") }
        return tags
    }

    /// `Apple M4 Pro` → `m4`; M1/M2 are the legacy tier, M3 and newer are
    /// modern. The pack's `chip_tier_for_generation` owns the meaning.
    package static func chipTier(for chipName: String) -> String {
        let lower = chipName.lowercased()
        if lower.contains("intel") { return "intel" }
        let pattern = #"\bm([1-9])\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: lower, range: NSRange(lower.startIndex..., in: lower)),
            let range = Range(match.range(at: 1), in: lower)
        else { return "unknown" }
        return "m" + lower[range]
    }

    // MARK: Python bridge

    private struct MTPLXPayload: Decodable {
        struct Model: Decodable {
            let hf: String
            let name: String
            let detail: String
            let bytes: Int
            let floor: Int
            let arOnly: Bool
        }

        let models: [Model]
    }

    /// Run the pack's Python and read its stdout. The script is local and
    /// deterministic, but a wedged interpreter must not hang the model page, so
    /// the wait is bounded and the child is terminated on timeout.
    private static func runPython(
        executable: String, workingDirectory: String, arguments: [String]
    ) -> String? {
        guard Paths.fileExists(executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment.removeValue(forKey: "PYTHONPATH")
        environment.removeValue(forKey: "PYTHONHOME")
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        if finished.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return nil
        }
        // The child has exited, so the pipe is closed and reading cannot block.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            AppLog.debug(.app, "MTPLX catalog 退出码 \(process.terminationStatus)：\(message)")
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs inside the pack. It prints only JSON; failures print nothing and
    /// exit non-zero so Swift keeps an empty list instead of half a catalog.
    private static let mtplxScript = """
        import json
        import sys
        from mtplx import model_catalog as catalog

        memory = float(sys.argv[1])
        tier = sys.argv[2]
        rams = [8, 16, 24, 32, 36, 48, 64, 96, 128, 192, 256, 384, 512]

        try:
            models = catalog.recommended_models(memory_gib=memory, chip_tier=tier)
        except Exception:
            models = [
                model for model in catalog.OFFICIAL_CATALOG
                if memory <= 0 or model.peak_memory_gib <= memory
            ]

        offered = {}
        for ram in rams:
            try:
                offered[ram] = {
                    model.id
                    for model in catalog.recommended_models(
                        memory_gib=ram, chip_tier=tier)
                }
            except Exception:
                offered[ram] = set()

        def floor_of(model):
            for ram in rams:
                if model.id in offered[ram]:
                    return ram
            return int(model.peak_memory_gib) + 1

        rows = []
        for model in models:
            rows.append({
                "hf": model.hf_model_id,
                "name": model.display_name,
                "detail": model.detail,
                "bytes": model.size_bytes,
                "floor": floor_of(model),
                "arOnly": bool(getattr(model, "ar_only", False)),
            })
        print(json.dumps({"models": rows}, ensure_ascii=False))
        """
}
