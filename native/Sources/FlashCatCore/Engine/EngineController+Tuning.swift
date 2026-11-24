// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Darwin
import FlashCatKit
import Foundation

extension EngineController {
    // MARK: tuning

    /// oMLX has no CLI switch for MTP/DFlash — they are per-model server
    /// settings, so they are pushed through its admin API once the engine is up.
    /// MTPLX and splash bake the same switches into their launch arguments.
    func applyTuningIfNeeded() async {
        guard !tuningApplied else { return }
        tuningApplied = true
        let resident = await residentModels() ?? status?.loadedModels ?? []
        await pushTuning(for: resident)
    }

    /// Push the stored tuning again after the user edits it on the engine page.
    /// CLI engines only take new flags at launch, so this notes a restart instead
    /// of pretending an in-place change happened.
    package func reapplyTuning() async {
        guard isRunning else { return }
        guard descriptor.adapter == .omlx else {
            note("==> \(id.displayName) 的配置已保存，重启后生效")
            return
        }
        let resident = await residentModels() ?? status?.loadedModels ?? []
        guard !resident.isEmpty else { return }
        await pushTuning(for: resident)
        // A model keeps the settings it was loaded with, so the loaded one is
        // reloaded for the new depth/draft flags to take effect.
        if let current = resident.first(where: { $0 == model || $0 == desiredModel }) {
            _ = await unloadLoadedModels(keeping: "")
            _ = await loadModelHot(current)
        }
    }

    func pushTuning(for targets: [String]) async {
        guard descriptor.adapter == .omlx, !targets.isEmpty else { return }
        let tuning = EngineStore.shared.tuning(for: .omlx)
        var failures = 0
        for target in targets {
            // A model with an assigned draft gets `dflash_draft_model` merged
            // into its payload; everyone else takes the engine-level tuning.
            // The payload is push-ready: the resolved thinking budget rides in.
            let override = EngineStore.shared.draftAssignment(for: id, model: target)
            guard let settings = tuning.omlxSettings(id: id, draftOverride: override),
                !settings.isEmpty
            else { continue }
            let payload = settings.mapValues { $0.jsonObject }
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            let response = await HTTP.put(
                port: port,
                path: EngineRoutes.modelSettings(target),
                json: data,
                timeout: 20)
            let status = response?.status ?? 0
            logs.append(
                "==> \(target) 应用 MTP/DFlash 设置 -> HTTP \(status)",
                level: status < 300 ? .system : .warning)
            if status >= 300 { failures += 1 }
        }
        if failures > 0 {
            failureMessage = "MTP/DFlash 设置未被 \(id.displayName) 接受（\(failures) 个模型失败）"
        }
        onChange()
    }

    func writePidFile(_ pid: Int32) {
        Paths.ensureDirectory(Paths.supportDirectory)
        try? String(pid).write(toFile: EnginePaths.pidFile(id), atomically: true, encoding: .utf8)
    }

    func removePidFile() {
        try? FileManager.default.removeItem(atPath: EnginePaths.pidFile(id))
    }

    func readPidFile() -> Int32? {
        guard
            let text = try? String(contentsOfFile: EnginePaths.pidFile(id), encoding: .utf8)
                .trimmingCharacters(in: .whitespaces),
            let pid = Int32(text), pid > 0
        else { return nil }
        return pid
    }
}
