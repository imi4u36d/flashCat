// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Darwin
import FlashCatKit
import Foundation

extension EngineController {
    // MARK: model switching

    /// Swap the loaded weights. Both engine kinds follow the same rule: the old
    /// model must be *confirmed* gone — process exited and port released, or the
    /// engine's own status no longer listing it — before the new weights
    /// allocate. Two 27B models do not fit in unified memory, and issuing the
    /// load while the previous weights were still resident is what left the app
    /// spinning on an engine that could not answer.
    package func switchModel(_ target: String, stage: @escaping (String) -> Void) async -> ModelSwitchOutcome {
        let wanted = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return .failed("模型标识为空") }
        guard await claimSwitchSlot() else { return .failed("已有切换在进行") }
        defer { switchInFlight = false }

        if descriptor.switchMode == .hot, isRunning {
            // Park the poller: nothing may nudge a load while we unload.
            desiredModel = nil
            stage("卸载旧模型")
            let cleared = await unloadLoadedModels(keeping: wanted)
            if Task.isCancelled {
                desiredModel = wanted
                onChange()
                return .failed("切换已取消")
            }
            if cleared {
                stage("加载新模型")
                desiredModel = wanted
                model = wanted
                let loaded = await loadModelHot(wanted)
                return loaded ? .ready : .failed(failureMessage ?? "加载 \(wanted) 失败")
            }
            // The engine would not let go of the weights. Restarting the process
            // is the only way to guarantee the memory is released before the new
            // model allocates, so fall back to the cold path instead of piling a
            // second 27B model on top of the first.
            logs.append("==> 就地卸载未能确认，改为重启服务释放显存", level: .system)
        }

        if isRunning {
            stage("停止旧模型")
            desiredModel = wanted
            model = wanted
            guard await stopAndWait() else {
                failureMessage = "旧模型（端口 \(port)）未能退出，已取消切换"
                logs.append("==> 切换已取消：端口 \(port) 仍被旧进程占用", level: .error)
                onChange()
                return .failed("旧模型未能退出")
            }
            if Task.isCancelled { return .failed("切换已取消") }
            stage("加载新模型")
            let local = catalog.machineModel(wanted)
            await start(localModel: local, requestedModel: wanted)
            let ready = await waitForReady(timeout: id.startupTimeout)
            return ready ? .ready : .failed(failureMessage ?? "\(id.displayName) 未能在预期时间内就绪")
        }

        // Nothing running: just remember the choice, the next start uses it.
        desiredModel = wanted
        model = wanted
        return .ready
    }

    /// 只把 `target` 加载进来，不动已经常驻的模型。对话里画图时用：图像模型
    /// 进来的时候对话模型还要接着写这一轮，卸掉它就得多等一次几十秒的加载。
    ///
    /// 只有热加载引擎能同时挂两份权重；别的引擎没有这个能力，退回原来的独占
    /// 切换，保证行为是「换过去」而不是「加载失败」。
    package func loadModelKeepingResident(
        _ target: String,
        stage: @escaping (String) -> Void
    ) async -> ModelSwitchOutcome {
        let wanted = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return .failed("模型标识为空") }
        guard descriptor.switchMode == .hot, isRunning else {
            return await switchModel(wanted, stage: stage)
        }
        guard await claimSwitchSlot() else { return .failed("已有切换在进行") }
        defer { switchInFlight = false }
        if Task.isCancelled { return .failed("切换已取消") }
        stage("加载新模型")
        let loaded = await loadModelHot(wanted)
        return loaded ? .ready : .failed(failureMessage ?? "加载 \(wanted) 失败")
    }

    /// 等上一趟切换让出单飞位，再占住它。上一次切换可能刚被读者取消/被新选择
    /// 接管：主线程已经放弃了它，但它还没走完 defer（正在等 unload 或 load
    /// 收尾）。等它，而不是把这次新选择判成失败——那正是「再点一次没反应」
    /// 的另一半原因。
    func claimSwitchSlot() async -> Bool {
        if switchInFlight {
            let deadline = Date().addingTimeInterval(8)
            while switchInFlight, Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        guard !switchInFlight else { return false }
        switchInFlight = true
        return true
    }

    /// Models the engine itself reports as resident. `nil` means the status
    /// document could not be read at all.
    func residentModels() async -> [String]? {
        let documents = await collectTelemetry()
        guard !documents.isEmpty else { return nil }
        let parsed = EngineStatusParser.parse(documents: documents, fallbackState: .ready)
        return parsed.loadedModels
    }

    /// Ask the engine to drop every resident model except `target` and wait for
    /// its own status to agree. oMLX answers 202 while it drains in-flight
    /// streams, so the POST result alone is not a confirmation.
    func unloadLoadedModels(keeping target: String, timeout: Double = 180) async -> Bool {
        guard let resident = await residentModels() else {
            logs.append("==> 读取 \(id.displayName) 状态失败，无法确认已加载的模型", level: .error)
            return false
        }
        let victims = resident.filter { $0 != target }
        if victims.isEmpty { return true }

        var pending: [String] = []
        for victim in victims {
            let response = await modelControl(
                descriptor.modelControl?.unload,
                target: victim,
                fallbackPath: EngineRoutes.unload(victim),
                timeout: 60)
            let status = response?.status ?? 0
            logs.append("==> 卸载 \(victim) → HTTP \(status)", level: status < 300 ? .system : .error)
            // 400 (not loaded) / 404 (unknown id) mean this id holds no weights,
            // so there is nothing left to wait for. Everything else — 202 queued,
            // 409 still loading, or no answer at all — has to be polled.
            if status == 400 || status == 404 { continue }
            pending.append(victim)
        }
        if pending.isEmpty { return true }

        let startedAt = Date()
        var lastNote = Date()
        var clearSince: Date?
        while Date().timeIntervalSince(startedAt) < timeout {
            let remaining = (await residentModels() ?? pending).filter { pending.contains($0) && $0 != target }
            if remaining.isEmpty {
                // The engine drops the model from `loaded_models` a moment before
                // its own gc/clear_cache settle barrier releases the Metal
                // buffers (engine_pool._stop_and_unload_engine), so hold a short
                // grace instead of racing the new allocation against the old one.
                let clear = clearSince ?? Date()
                clearSince = clear
                if Date().timeIntervalSince(clear) >= 1.5 {
                    logs.append(
                        "==> 旧模型已卸载（\(Int(Date().timeIntervalSince(startedAt))) 秒），开始加载 \(target)",
                        level: .system)
                    return true
                }
            } else {
                clearSince = nil
            }
            if Date().timeIntervalSince(lastNote) > 10 {
                lastNote = Date()
                logs.append("==> 仍在卸载 \(remaining.joined(separator: "、")) …", level: .system)
            }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }

    /// Model ids are directory names, so no slash survives, but a custom id may
    /// still carry characters the URL path cannot.
    func loadModelHot(_ target: String) async -> Bool {
        guard loadInFlight != target else { return false }
        loadInFlight = target
        hotLoadSince = Date()
        defer {
            hotLoadSince = nil
            loadInFlight = nil
        }
        // ServerState has no loading case on purpose: the switch stage text
        // owns the "加载中" presentation for both engine kinds.
        // Weight loads are slow (tens of seconds for 27B); the poller keeps the
        // dashboard alive while this awaits.
        // Settings only reach a model at load time, so push them first.
        if descriptor.adapter == .omlx { await pushTuning(for: [target]) }
        let response = await modelControl(
            descriptor.modelControl?.load,
            target: target,
            fallbackPath: EngineRoutes.load(target),
            timeout: 600)
        let status = response?.status ?? 0
        logs.append(
            "==> \(id.displayName) 切换到 \(target) → HTTP \(status)",
            level: status < 300 ? .system : .error)
        if status >= 300 {
            failureMessage =
                status == 507
                ? "内存不足，无法加载 \(target)"
                : "加载 \(target) 失败（HTTP \(status)）"
        } else {
            failureMessage = nil
            lastHotLoad = (target, Date())
        }
        markReady()
        return status < 300
    }

    func modelControl(
        _ action: EngineModelAction?,
        target: String,
        fallbackPath: String,
        timeout: TimeInterval
    ) async -> HTTPResponse? {
        guard let action else {
            return await HTTP.post(port: port, path: fallbackPath, timeout: timeout)
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target
        let path = EngineTemplate.expand(action.path, context: ["model": encoded])
        let bodyContext = ["model": target]
        let json: Data?
        if let body = action.body {
            let object = body.mapValues { $0.jsonObject(context: bodyContext) }
            json = try? JSONSerialization.data(withJSONObject: object)
        } else {
            json = nil
        }
        return await HTTP.request(
            method: action.method,
            port: port,
            path: path,
            json: json,
            timeout: timeout)
    }

    /// oMLX starts with its own default model, so the requested one may still
    /// be cold once health turns green. Nudge it once per change — never while a
    /// switch owns the engine.
    func ensureDesiredModelLoaded() async {
        guard !switchInFlight else { return }
        guard descriptor.switchMode == .hot, let target = desiredModel, !target.isEmpty else { return }
        if let last = lastHotLoad, last.target == target,
            Date().timeIntervalSince(last.at) < 20
        {
            return
        }
        if let loaded = status?.loadedModels, loaded.contains(target) { return }
        if status?.model == target { return }
        _ = await loadModelHot(target)
    }
}
