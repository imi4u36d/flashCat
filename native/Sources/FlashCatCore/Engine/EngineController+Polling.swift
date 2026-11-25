// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Darwin
import FlashCatKit
import Foundation

extension EngineController {
    // MARK: polling

    func startPolling() {
        schedulePolling(every: 1.0)
    }

    /// 统一的 1 Hz 轮询。预填充也从 0.4 秒改回 1 秒：概览的预填充格与
    /// 解码曲线共用同一个节拍，读数只每秒变一次，而不是按 chunk 立即跳。
    func schedulePolling(every interval: TimeInterval) {
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { await self.poll() }
        }
        pollTimer = timer
        // Default run-loop mode stops while a modal alert is up. The app opens
        // alerts from the engine page, so the poller used to freeze exactly when
        // the reader was staring at the stalled engine.
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Give the launch a budget. `descriptor.startupTimeout` already encodes
    /// how slow each engine is (oMLX 180 s, splash 660 s, mlx-serve 600 s), so
    /// reusing it keeps the promise the engine page makes about wait times.
    func startStartupDeadline(for task: Process) {
        startupWatchdog?.cancel()
        let budget = descriptor.startupTimeout
        startupWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Only the launch this deadline was armed for, and only if the
            // poller has not already promoted it to `.ready`.
            guard self.process === task, self.state == .starting else { return }
            self.logs.append("==> 启动超时：\(Int(budget)) 秒内未就绪", level: .error)
            self.fail("启动超时：\(Int(budget)) 秒内没有就绪。看日志页最后几行——多半是端口被占或模型放不进内存。")
            // 超时的进程留着只会占端口和显存，而且会把下一次启动挡在
            // `process != nil` 上——「启动」按钮看起来像坏了。
            self.stop()
        }
    }

    /// 用累计计数器的滑动窗口差分补上不直接上报实时预填充速率的引擎（目前是 mlx-serve）。
    /// 别的引擎不报这些键，`observe` 返回空读数，不会覆盖它们自己的口径。
    func applyLiveRates(to parsed: inout EngineStatus) {
        let reading = liveRates.observe(parsed, at: Date())
        if let prefill = reading.prefill.value, prefill > 0 {
            parsed.prefillTokensPerSecond = prefill
            parsed.prefillRateKind = reading.prefill.kind
        }
    }

    func poll() async {
        if pollInFlight || process == nil { return }
        pollInFlight = true
        defer { pollInFlight = false }

        let health = await probeHealth()
        guard health.ready else {
            // 503 while the weights load and the kernels warm: there is no
            // status document to read yet, but the console still has to tick —
            // the stage comes from the engine's log and the elapsed count from
            // the clock, and on a big MoE target both stay put for minutes.
            refreshStartupTick()
            return
        }

        await applyTuningIfNeeded()
        await ensureDesiredModelLoaded()
        let documents = await collectTelemetry(healthResponse: health.response)
        guard !documents.isEmpty else {
            if state == .starting,
                descriptor.switchMode != .hot
                    || desiredModel == nil
                    || status?.loadedModels.contains(desiredModel ?? "") == true
            {
                markReady()
            }
            return
        }
        var parsed = EngineStatusParser.parse(documents: documents, fallbackState: .ready)
        await adoptEngineReportedEfforts(into: &parsed)
        applyLiveRates(to: &parsed)
        status = parsed
        stats = ServerStats(engineStatus: parsed, previous: stats)
        // 先写入最新 `status` / `stats` 再宣告 `.ready`：`markReady()` 同步触发
        // `onChange()` → `syncLifetimeIdentity`，确保等待就绪的对话或网关请求在
        // `canChat` 变真之前就已经完成新代对齐，不会被随后到达的遥测误判为旧代。
        if state == .starting,
            descriptor.switchMode != .hot
                || desiredModel == nil
                || parsed.loadedModels.contains(desiredModel ?? "")
        {
            markReady()
        }
        if process == nil { logs.pollFollow() }
        onChange()
    }

    var healthPath: String {
        manifest.health.path
    }

    /// Keep the console alive while the engine is not answering yet. Nothing is
    /// polled from the engine here — a loading splash prints nothing for
    /// minutes — but republishing the snapshot each second is what makes the
    /// stage and the elapsed count move instead of freezing at one frame.
    func refreshStartupTick() {
        // 热切换时 state 已经是 .ready、权重却还在搬：健康探测可能先失败，
        // 这里仍要每秒重发一次快照，否则「已等待」会停住，看起来又像卡死。
        let stillLoading = state == .ready && startupStage != EngineStartupStage.ready.rawValue
        guard state == .starting || stillLoading else { return }
        if process == nil { logs.pollFollow() }
        onChange()
    }

    /// 同时把健康响应带回去：telemetry 里的 health 源通常跟这里是同一个
    /// 端点，复用它就不用每秒再 GET 一次。
    func probeHealth() async -> (ready: Bool, response: HTTPResponse?) {
        guard let response = await HTTP.get(port: port, path: healthPath, timeout: 1.5) else {
            return (false, nil)
        }
        let ready = manifest.health.readyStatus
        if response.status == ready { return (true, response) }
        if let loading = manifest.health.loadingStatus, response.status == loading { return (true, response) }
        return (false, response)
    }

    func fetchJSON(path: String) async -> [String: Any]? {
        guard let response = await HTTP.get(port: port, path: path, timeout: 1.8) else { return nil }
        guard (200..<300).contains(response.status) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) else { return nil }
        return object as? [String: Any]
    }

    /// Fetch every declared telemetry source. Descriptors decide what matters;
    /// the controller only knows how to GET JSON and merge the result.
    func collectTelemetry(healthResponse: HTTPResponse? = nil) async -> [EngineTelemetryDocument] {
        var sources = descriptor.telemetry
        if !sources.contains(where: { $0.role == .health }) {
            sources.append(
                EngineTelemetrySource(role: .health, path: healthPath, format: .llamaProps))
        }
        // 各端点互不依赖，并发拉取；返回时按 sources 原顺序还原，解析层
        // 的合并顺序保持稳定。以前串行等待，一个慢端点会拖住整轮轮询。
        // 健康探测已经拿到的 2xx 文档直接复用，不再为同一个端点发第二次请求。
        var prefetched: [String: [String: Any]] = [:]
        if let healthResponse, (200..<300).contains(healthResponse.status),
            let object = try? JSONSerialization.jsonObject(with: healthResponse.body),
            let json = object as? [String: Any]
        {
            prefetched[healthPath] = json
        }
        let port = self.port
        return await withTaskGroup(of: (Int, EngineTelemetryDocument?).self) { group in
            for (index, source) in sources.enumerated() {
                if let json = prefetched[source.path] {
                    let document = EngineTelemetryDocument(source: source, json: json)
                    group.addTask { (index, document) }
                    continue
                }
                group.addTask {
                    guard let response = await HTTP.get(port: port, path: source.path, timeout: 1.8),
                        (200..<300).contains(response.status),
                        let object = try? JSONSerialization.jsonObject(with: response.body),
                        let json = object as? [String: Any]
                    else {
                        return (index, nil)
                    }
                    return (index, EngineTelemetryDocument(source: source, json: json))
                }
            }
            var byIndex: [Int: EngineTelemetryDocument] = [:]
            for await (index, document) in group {
                if let document { byIndex[index] = document }
            }
            return sources.indices.compactMap { byIndex[$0] }
        }
    }

    /// oMLX 把每个模型支持的思考等级放在 `/v1/models/status` 的
    /// `reasoning_efforts` 里（`/api/status` 没有），所以这里补一次读取，
    /// 交给思考等级下拉框当数据源。其他引擎的等级已随状态文档解析
    /// （MTPLX），splash 不提供 → 保持 nil，上层用内置列表兜底。
    func adoptEngineReportedEfforts(into parsed: inout EngineStatus) async {
        guard descriptor.adapter == .omlx else { return }
        guard let wanted = parsed.model ?? desiredModel, !wanted.isEmpty else { return }
        if let cached = reasoningEffortsCache, cached.model == wanted,
            Date().timeIntervalSince(cached.at) < 30
        {
            if let efforts = cached.efforts { parsed.reasoningEfforts = efforts }
            return
        }
        guard let document = await fetchJSON(path: "/v1/models/status") else { return }
        let entries = (document["models"] as? [[String: Any]]) ?? []
        let efforts = entries.first(where: { ($0["id"] as? String) == wanted })?["reasoning_efforts"] as? [String]
        reasoningEffortsCache = (wanted, Date(), efforts)
        if let efforts, !efforts.isEmpty { parsed.reasoningEfforts = efforts }
    }
}
