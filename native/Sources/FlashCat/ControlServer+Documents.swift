import AppKit
import Foundation
import FlashCatKit

// MARK: - Models, downloads, logs, config and diagnostics

extension ControlServer {
    // MARK: Models

    func modelDocuments(engine: String?, includeAll: Bool) -> [ControlModelSummary] {
        let state = AppState.shared
        let requested = engine.flatMap { EngineID(rawValue: $0) }
        let ids: [EngineID] = requested.map { [$0] } ?? EngineCatalog.allIDs
        var rows: [ControlModelSummary] = []
        for id in ids {
            let entries = state.libraryEntries(for: id)
            let controller = state.engines?.controller(id)
            let loaded = Set((controller?.status?.loadedModels ?? [])
                .map(ModelLibraryEntry.normalized))
            for entry in entries {
                if !includeAll && !entry.installed { continue }
                let path = entry.model.path
                let shared = !path.isEmpty && path.hasPrefix(FlashCatPaths.sharedModelsDirectory)
                rows.append(ControlModelSummary(
                    id: entry.model.id,
                    engine: id.rawValue,
                    path: path.isEmpty ? nil : path,
                    bytes: entry.model.bytes > 0 ? entry.model.bytes : nil,
                    installed: entry.installed,
                    loaded: loaded.contains(ModelLibraryEntry.normalized(entry.model.id)),
                    hidden: false,
                    helper: entry.isDraft,
                    recommended: entry.source == .recommended && !entry.installed,
                    source: shared ? "shared" : (entry.recommendation == nil ? "local" : "catalog")))
            }
        }
        return rows
    }

    func modelUse(_ body: ControlModelUse) async -> GatewayResponse {
        let state = AppState.shared
        let model = body.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            return Self.failure(400, ControlErrorCode.badRequest, "model 不能为空")
        }
        if let raw = body.engine, let engine = EngineID(rawValue: raw) {
            guard state.engines?.controller(engine) != nil else {
                return Self.failure(404, ControlErrorCode.notFound,
                                    "\(engine.displayName) 还没有安装")
            }
            if !state.engineModels(for: engine).contains(where: { $0.id == model }) {
                return Self.failure(404, ControlErrorCode.notFound,
                                    "\(engine.displayName) 没有模型 \(model)")
            }
            if state.activeEngine != engine {
                guard await state.switchEngine(engine, start: false) else {
                    return Self.failure(409, ControlErrorCode.conflict,
                                        "无法切换到 \(engine.displayName)")
                }
            }
        }
        if let error = await state.prepareModelForGateway(model) {
            return Self.preparationFailure(error)
        }
        return Self.json(statusDocument())
    }

    func modelDownload(_ body: ControlModelDownload) -> GatewayResponse {
        let state = AppState.shared
        let model = body.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            return Self.failure(400, ControlErrorCode.badRequest, "model 不能为空")
        }
        guard state.downloadingModel == nil else {
            let current = state.downloadingModel ?? "另一个模型"
            return Self.failure(409, ControlErrorCode.conflict,
                                "正在下载 \(current)，先等它结束或暂停它")
        }
        let engine = body.engine.flatMap { EngineID(rawValue: $0) }
            ?? Self.owningEngine(for: model, state: state)
        let mode = body.mode ?? (body.engines == nil ? "engine" : "shared")

        let started: Bool
        if mode == "shared" {
            var rawEngines = body.engines ?? []
            if rawEngines.isEmpty, let only = body.engine { rawEngines = [only] }
            let targets = rawEngines.compactMap { EngineID(rawValue: $0) }
            started = state.downloadShared(model, engines: targets.isEmpty ? [engine] : targets)
        } else {
            guard state.engines?.controller(engine) != nil else {
                return Self.failure(404, ControlErrorCode.notFound,
                                    "\(engine.displayName) 还没有安装")
            }
            started = state.downloadModel(model, engine: engine)
        }
        guard started else {
            return Self.failure(409, ControlErrorCode.conflict,
                                state.notice ?? "下载未能启动")
        }
        if let row = downloadDocuments().first(where: {
            $0.model == model || ModelLibraryEntry.normalized($0.model) == ModelLibraryEntry.normalized(model)
        }) {
            return Self.json(row, status: 202)
        }
        return Self.json(ControlSimpleResult(ok: true, message: "下载已开始"), status: 202)
    }

    /// Find which engine's library owns a model id. The active engine wins on a
    /// tie; an id that belongs to an engine that is not active would otherwise
    /// be downloaded into the wrong model folder (or fail there).
    private static func owningEngine(for model: String, state: AppState) -> EngineID {
        let normalized = ModelLibraryEntry.normalized(model)
        let ordered = [state.activeEngine] + EngineCatalog.allIDs.filter { $0 != state.activeEngine }
        for engine in ordered {
            if state.libraryEntries(for: engine).contains(where: {
                ModelLibraryEntry.normalized($0.model.id) == normalized
            }) {
                return engine
            }
        }
        return state.activeEngine
    }

    func modelDelete(_ body: ControlModelDelete) -> GatewayResponse {
        let state = AppState.shared
        let model = body.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            return Self.failure(400, ControlErrorCode.badRequest, "model 不能为空")
        }
        let before = state.notice
        if body.shared == true || ModelSharing.isShared(model) {
            state.removeShared(model)
        } else {
            let engine = body.engine.flatMap { EngineID(rawValue: $0) }
                ?? Self.owningEngine(for: model, state: state)
            guard state.engines?.controller(engine) != nil else {
                return Self.failure(404, ControlErrorCode.notFound,
                                    "\(engine.displayName) 还没有安装")
            }
            let exists = state.engineModels(for: engine).contains { $0.id == model }
                || state.libraryEntries(for: engine).contains { $0.model.id == model && $0.installed }
            guard exists else {
                return Self.failure(404, ControlErrorCode.notFound,
                                    "\(engine.displayName) 没有模型 \(model)")
            }
            state.removeModel(model, engine: engine)
        }
        if state.notice != before, let message = state.notice {
            return Self.failure(409, ControlErrorCode.failed, message)
        }
        return Self.json(ControlSimpleResult(ok: true, message: "已删除 \(model)"))
    }

    // MARK: Downloads

    func downloadDocuments() -> [ControlDownloadSummary] {
        let state = AppState.shared
        return state.downloadTasks.map { task in
            let active = state.downloadingModel == task.model && state.downloadingEngine == task.engine
            return ControlDownloadSummary(
                engine: task.engine.rawValue,
                model: task.model,
                status: task.status.rawValue,
                downloadedBytes: task.downloadedBytes,
                totalBytes: task.totalBytes,
                fraction: task.fraction,
                shared: task.shared?.map(\.rawValue),
                speed: active ? state.downloadSpeed : nil)
        }
    }

    func downloadAction(route: ControlRoute, body: ControlDownloadAction) -> GatewayResponse {
        let state = AppState.shared
        guard let task = state.downloadTasks.first(where: {
            $0.engine.rawValue == body.engine && $0.model == body.model
        }) else {
            return Self.failure(404, ControlErrorCode.notFound,
                                "下载队列里没有 \(body.engine)/\(body.model)")
        }
        switch route {
        case .downloadPause:
            guard state.downloadingModel == task.model, state.downloadingEngine == task.engine else {
                return Self.failure(409, ControlErrorCode.conflict, "这条下载当前没有在跑")
            }
            state.pauseDownload()
        case .downloadResume:
            guard task.status != .downloading else {
                return Self.failure(409, ControlErrorCode.conflict, "这条下载已经在跑")
            }
            state.resumeDownload(task)
        case .downloadCancel:
            state.cancelDownload(task)
        default:
            return Self.failure(400, ControlErrorCode.badRequest, "未知下载动作")
        }
        return Self.json(downloadDocuments())
    }

    // MARK: Logs

    func logsDocument(_ request: GatewayRequest) -> GatewayResponse {
        let state = AppState.shared
        guard let source = ControlLogSource.resolve(request.query["source"]) else {
            return Self.failure(400, ControlErrorCode.badRequest,
                                "source 只能是 engine / gateway / control / app")
        }
        let limit = min(max(Int(request.query["lines"] ?? "") ?? 200, 1), 5_000)
        let requested: EngineID
        if let raw = request.query["engine"] {
            guard let id = EngineID(rawValue: raw) else {
                return Self.failure(400, ControlErrorCode.badRequest, "无效的引擎 id：\(raw)")
            }
            requested = id
        } else {
            requested = state.activeEngine
        }

        let levels = Self.requestedLevels(request)

        // `app` is a plain file: no LogStore owns it, and borrowing the
        // engine's in-memory tail here would label engine lines as app lines.
        if source == .app {
            var lines = Self.readLogFile(path: FlashCatPaths.serverLogFile, limit: limit)
                .map { line in
                    ControlLogLine(date: Date(),
                                   level: LogStore.classify(line).rawValue,
                                   text: line)
                }
            if !levels.isEmpty {
                lines = lines.filter { levels.contains($0.level.lowercased()) }
            }
            return Self.json(ControlLogDocument(source: source.rawValue,
                                                path: FlashCatPaths.serverLogFile,
                                                lines: lines))
        }

        let store: LogStore
        let path: String
        switch source {
        case .engine:
            guard let controller = state.engines?.controller(requested) else {
                return Self.failure(404, ControlErrorCode.notFound,
                                    "\(requested.displayName) 还没有安装")
            }
            store = controller.logs
            path = FlashCatPaths.logFile(requested)
        case .gateway:
            store = state.gateway.logs
            path = FlashCatPaths.gatewayLogFile
        case .control:
            store = logs
            path = FlashCatPaths.controlLogFile
        case .app:
            // Handled above; this arm only keeps the switch exhaustive.
            store = logs
            path = FlashCatPaths.serverLogFile
        }

        var lines = store.snapshot(limit: limit).map { line in
            ControlLogLine(date: line.time,
                           level: line.level.rawValue,
                           text: line.text,
                           engine: source == .engine ? requested.rawValue : nil)
        }
        if !levels.isEmpty {
            lines = lines.filter { levels.contains($0.level.lowercased()) }
        }
        if lines.isEmpty {
            // The controller's in-memory tail is empty before a first launch;
            // the file still holds what an earlier session wrote.
            lines = Self.readLogFile(path: path, limit: limit).map { line in
                ControlLogLine(date: Date(),
                               level: LogStore.classify(line).rawValue,
                               text: line,
                               engine: source == .engine ? requested.rawValue : nil)
            }
            if !levels.isEmpty {
                lines = lines.filter { levels.contains($0.level.lowercased()) }
            }
        }
        return Self.json(ControlLogDocument(source: source.rawValue, path: path, lines: lines))
    }

    private static func readLogFile(path: String, limit: Int) -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard rows.count > limit else { return rows.map(String.init) }
        return rows.suffix(limit).map(String.init)
    }

    /// One classification for every log source. `LogStore.classify` is the
    /// canonical rule; a second copy here drifted (it never produced
    /// `success`, so `logs --app --level success` returned nothing).
    private static func requestedLevels(_ request: GatewayRequest) -> Set<String> {
        Set((request.query["level"] ?? "")
            .split(separator: ",")
            .map { token -> String in
                switch token.trimmingCharacters(in: .whitespaces).lowercased() {
                case "warn": return "warning"
                case "err": return "error"
                case "ready": return "success"
                case "app": return "system"
                default: return token.trimmingCharacters(in: .whitespaces).lowercased()
                }
            }
            .filter { !$0.isEmpty })
    }

    // MARK: Config

    struct ConfigBinding {
        let key: String
        let title: String
        let kind: String
        let mutable: Bool
        let read: () -> String
        let write: ((String) throws -> Void)?
    }

    enum ConfigError: Error, LocalizedError {
        case invalidKey(String)
        case readOnly(String)
        case invalidValue(String)

        var errorDescription: String? {
            switch self {
            case .invalidKey(let key): return "未知设置项：\(key)"
            case .readOnly(let key): return "\(key) 是只读项"
            case .invalidValue(let message): return message
            }
        }
    }

    func configEntries() -> [ControlConfigEntry] {
        configBindings().map { binding in
            ControlConfigEntry(kind: binding.kind,
                               key: binding.key,
                               title: binding.title,
                               value: binding.read(),
                               mutable: binding.mutable)
        }
    }

    func setConfig(_ body: ControlConfigSet) -> GatewayResponse {
        guard let binding = configBindings().first(where: { $0.key == body.key }) else {
            return Self.failure(404, ControlErrorCode.notFound, "未知设置项：\(body.key)")
        }
        guard binding.mutable, let write = binding.write else {
            return Self.failure(400, ControlErrorCode.badRequest, "\(body.key) 是只读项")
        }
        do {
            try write(body.value)
        } catch {
            return Self.failure(400, ControlErrorCode.badRequest,
                                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        let entry = configBindings().first { $0.key == body.key }
        return Self.json(ControlConfigEntry(kind: entry?.kind ?? binding.kind,
                                            key: body.key,
                                            title: binding.title,
                                            value: entry?.read() ?? body.value,
                                            mutable: true))
    }

    private func configBindings() -> [ConfigBinding] {
        let state = AppState.shared
        let settings = state.settings
        let defaults = UserDefaults.standard

        func bool(_ key: String, _ title: String, get: @escaping () -> Bool,
                  set: @escaping (Bool) -> Void) -> ConfigBinding {
            ConfigBinding(key: key, title: title, kind: "bool", mutable: true,
                          read: { get() ? "true" : "false" },
                          write: { try set(Self.parseBool($0, key: key)) })
        }
        func int(_ key: String, _ title: String, range: ClosedRange<Int>,
                 get: @escaping () -> Int, set: @escaping (Int) -> Void) -> ConfigBinding {
            ConfigBinding(key: key, title: title, kind: "int", mutable: true,
                          read: { String(get()) },
                          write: { try set(Self.parseInt($0, key: key, range: range)) })
        }
        func double(_ key: String, _ title: String, range: ClosedRange<Double>,
                    get: @escaping () -> Double, set: @escaping (Double) -> Void) -> ConfigBinding {
            ConfigBinding(key: key, title: title, kind: "double", mutable: true,
                          read: { String(format: "%.2f", get()) },
                          write: { try set(Self.parseDouble($0, key: key, range: range)) })
        }
        func text(_ key: String, _ title: String, get: @escaping () -> String,
                  set: @escaping (String) -> Void) -> ConfigBinding {
            ConfigBinding(key: key, title: title, kind: "string", mutable: true,
                          read: get, write: { set($0) })
        }

        var items: [ConfigBinding] = [
            ConfigBinding(key: "appearance", title: "外观", kind: "enum", mutable: true,
                          read: {
                              switch state.theme.mode {
                              case .system: return "system"
                              case .light: return "light"
                              case .dark: return "dark"
                              }
                          },
                          write: { value in
                              switch value.lowercased() {
                              case "system": state.theme.set(.system)
                              case "light": state.theme.set(.light)
                              case "dark": state.theme.set(.dark)
                              default: throw ConfigError.invalidValue("appearance 只能是 system / light / dark")
                              }
                          }),
            bool("autoStart", "随应用启动引擎", get: { settings.autoStart },
                 set: { settings.setAutoStart($0) }),
            bool("launchAtLogin", "登录时启动", get: { settings.launchAtLogin },
                 set: { value in
                     settings.setLaunchAtLogin(value)
                     LoginItem.set(enabled: value)
                 }),
            bool("gatewayEnabled", "API 网关", get: { settings.gatewayEnabled },
                 set: { value in
                     settings.setGatewayEnabled(value)
                     state.applyGatewaySettings()
                 }),
            int("gatewayPort", "API 网关端口", range: 1024...65535,
                get: { settings.gatewayPort },
                set: { value in
                    settings.setGatewayPort(value)
                    state.applyGatewaySettings()
                }),
            bool("controlAPIEnabled", "命令行接口", get: { settings.controlAPIEnabled },
                 set: { value in
                     settings.setControlAPIEnabled(value)
                     DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                         state.applyControlSettings()
                     }
                 }),
            int("controlPort", "命令行接口端口", range: 1024...65535,
                get: { settings.controlPort },
                set: { value in
                    settings.setControlPort(value)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                         state.applyControlSettings()
                    }
                }),
            int("port", "默认引擎端口", range: 1024...65535,
                get: { settings.port }, set: { settings.setPort($0) }),
            ConfigBinding(key: "model", title: "当前模型", kind: "string", mutable: false,
                          read: { state.selectedModel }, write: nil),
            ConfigBinding(key: "thinkingMode", title: "思考模式", kind: "enum", mutable: true,
                          read: {
                              switch settings.thinkingMode {
                              case .automatic: return "auto"
                              case .off: return "off"
                              case .on: return "on"
                              }
                          },
                          write: { value in
                              switch value.lowercased() {
                              case "auto", "automatic": settings.setThinkingMode(.automatic)
                              case "off", "none": settings.setThinkingMode(.off)
                              case "on": settings.setThinkingMode(.on)
                              default: throw ConfigError.invalidValue("thinkingMode 只能是 auto / off / on")
                              }
                          }),
            ConfigBinding(key: "reasoningEffort", title: "推理等级", kind: "enum", mutable: true,
                          read: { settings.reasoningEffort.token },
                          write: { value in
                              guard let effort = ReasoningEffort.allCases.first(where: {
                                  $0.token == value.lowercased()
                              }) else {
                                  throw ConfigError.invalidValue("reasoningEffort 只能是 low / medium / high / xhigh")
                              }
                              settings.setReasoningEffort(effort)
                          }),
            double("temperature", "温度", range: 0...2,
                   get: { settings.temperature }, set: { settings.setTemperature($0) }),
            double("topP", "Top P", range: 0...1,
                   get: { settings.topP }, set: { settings.setTopP($0) }),
            int("maxTokens", "最大输出", range: 0...1_000_000,
                get: { settings.maxTokens }, set: { settings.setMaxTokens($0) }),
            text("systemPrompt", "系统提示", get: { settings.systemPrompt },
                 set: { settings.setSystemPrompt($0) }),
            text("hfCache", "下载缓存目录", get: { settings.hfCache },
                 set: { settings.setHfCache($0) }),
            text("maxMemory", "最大内存参数", get: { settings.maxMemory },
                 set: { settings.setMaxMemory($0) }),
            text("maxContext", "最大上下文参数", get: { settings.maxContext },
                 set: { settings.setMaxContext($0) }),
            text("extraArgs", "额外启动参数", get: { settings.extraArgs },
                 set: { settings.setExtraArgs($0) }),
            bool("idleReleaseOff", "常驻权重", get: { settings.idleReleaseOff },
                 set: { settings.setIdleReleaseOff($0) }),
            bool("languageOnly", "纯文本", get: { settings.languageOnly },
                 set: { settings.setLanguageOnly($0) }),
            text("hfEndpoint", "Hugging Face 端点",
                 get: { defaults.string(forKey: "hfEndpoint") ?? "" },
                 set: { defaults.set($0, forKey: "hfEndpoint") }),
            text("hfToken", "Hugging Face Token",
                 get: { defaults.string(forKey: "hfToken") ?? "" },
                 set: { defaults.set($0, forKey: "hfToken") }),
        ]

        // Per-engine ports are settings too: `engines.omlx.port` reads the same
        // store the settings page edits.
        for id in EngineCatalog.allIDs {
            items.append(ConfigBinding(
                key: "engines.\(id.rawValue).port",
                title: L10n.format("%@ 端口", id.displayName),
                kind: "int",
                mutable: true,
                read: {
                    String(EngineStore.shared.configuration(for: id).port ?? id.defaultPort)
                },
                write: { value in
                    let port = try Self.parseInt(value, key: "engines.\(id.rawValue).port",
                                                 range: 1024...65535)
                    state.switchEnginePort(id, port: port)
                }))
        }
        return items
    }

    private static func parseBool(_ raw: String, key: String) throws -> Bool {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: throw ConfigError.invalidValue("\(key) 需要 true / false")
        }
    }

    private static func parseInt(_ raw: String, key: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(raw.trimmingCharacters(in: .whitespaces)), range.contains(value) else {
            throw ConfigError.invalidValue("\(key) 需要 \(range.lowerBound)…\(range.upperBound) 的整数")
        }
        return value
    }

    private static func parseDouble(_ raw: String, key: String, range: ClosedRange<Double>) throws -> Double {
        guard let value = Double(raw.trimmingCharacters(in: .whitespaces)), range.contains(value) else {
            throw ConfigError.invalidValue("\(key) 需要 \(range.lowerBound)…\(range.upperBound) 的数字")
        }
        return value
    }

    // MARK: Doctor

    func doctorReport() -> ControlDoctorReport {
        let state = AppState.shared
        var checks: [ControlDoctorCheck] = []

        checks.append(ControlDoctorCheck(status: "ok", id: "app",
                                         title: "应用",
                                         detail: "flashCat \(appVersion) · pid \(getpid())"))
        checks.append(ControlDoctorCheck(status: isRunning ? "ok" : "fail", id: "control",
                                         title: "命令行接口",
                                         detail: isRunning ? "127.0.0.1:\(port)" : "未启动"))
        let installed = EngineCatalog.allIDs.filter { state.engines?.controller($0) != nil }
        checks.append(ControlDoctorCheck(status: installed.isEmpty ? "warn" : "ok", id: "engines",
                                         title: "推理引擎",
                                         detail: installed.isEmpty
                                             ? "还没有安装引擎"
                                             : installed.map(\.displayName).joined(separator: "、")))
        if let controller = state.controller {
            checks.append(ControlDoctorCheck(status: controller.isReady ? "ok" : "warn",
                                             id: "engine",
                                             title: "当前引擎",
                                             detail: "\(state.activeEngine.displayName) · \(controller.state.rawValue)"))
        } else {
            checks.append(ControlDoctorCheck(status: "warn", id: "engine",
                                             title: "当前引擎", detail: "没有可用的引擎"))
        }
        checks.append(ControlDoctorCheck(status: state.gateway.isRunning ? "ok" : "warn",
                                         id: "gateway",
                                         title: "API 网关",
                                         detail: state.gateway.isRunning
                                             ? state.gateway.baseURL + "/v1"
                                             : (state.settings.gatewayEnabled ? "已启用但未运行" : "已关闭")))
        let models = state.engineModels().filter { !$0.helper && !$0.hidden }
        checks.append(ControlDoctorCheck(status: models.isEmpty ? "warn" : "ok", id: "models",
                                         title: "模型",
                                         detail: models.isEmpty
                                             ? "\(state.activeEngine.displayName) 没有可用模型"
                                             : "\(models.count) 个可用模型"))
        let device = DeviceProfile.current()
        let free = Double(device.freeDiskBytes) / 1_000_000_000
        checks.append(ControlDoctorCheck(status: free > 5 ? "ok" : "warn", id: "disk",
                                         title: "磁盘",
                                         detail: String(format: "可用 %.1f GB · %@", free, device.chipName)))
        let cli = ["/usr/local/bin/flashcat", FlashCatPaths.home + "/.local/bin/flashcat"]
            .first { FileManager.default.fileExists(atPath: $0) }
        checks.append(ControlDoctorCheck(status: cli == nil ? "warn" : "ok", id: "cli",
                                         title: "flashcat 命令",
                                         detail: cli ?? "未在 PATH 常见位置找到；运行 flashcat cli install"))
        return ControlDoctorReport(checks: checks)
    }

    // MARK: Helpers

    nonisolated static func preparationFailure(_ error: GatewayModelPreparationError) -> GatewayResponse {
        switch error {
        case .modelNotFound(let message):
            return failure(404, ControlErrorCode.notFound, message)
        case .badRequest(let message):
            return failure(400, ControlErrorCode.badRequest, message)
        case .unavailable(let message):
            return failure(503, ControlErrorCode.unavailable, message)
        case .failed(let message):
            return failure(503, ControlErrorCode.failed, message)
        }
    }

    nonisolated static func json<T: Encodable>(_ value: T, status: Int = 200) -> GatewayResponse {
        do {
            let data = try ControlJSON.encoder(pretty: false).encode(value)
            var response = GatewayResponse()
            response.status = status
            response.body = data
            return response
        } catch {
            return failure(500, ControlErrorCode.failed, "无法编码响应：\(error.localizedDescription)")
        }
    }

    nonisolated static func failure(_ status: Int, _ code: String, _ message: String) -> GatewayResponse {
        let data = (try? ControlJSON.encoder(pretty: false)
            .encode(ControlErrorDocument(code: code, message: message)))
            ?? Data(#"{"ok":false,"error":{"code":"failed","message":"control error"}}"#.utf8)
        var response = GatewayResponse()
        response.status = status
        response.body = data
        return response
    }

    nonisolated static func decode<T: Decodable>(_ request: GatewayRequest) -> T? {
        guard !request.body.isEmpty else { return nil }
        return try? ControlJSON.decoder().decode(T.self, from: request.body)
    }
}
