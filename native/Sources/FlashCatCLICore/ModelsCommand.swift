import Foundation
import FlashCatKit

public enum ModelsCommand {
    public static func run(_ context: CLIContext) async throws -> Int32 {
        switch context.invocation.subcommand ?? "list" {
        case "list": return try await list(context)
        case "use": return try await use(context)
        case "download": return try await download(context)
        case "delete": return try await delete(context)
        case "path": return try await path(context)
        default:
            throw CLIError("未知 models 子命令：\(context.invocation.subcommand ?? "")", exit: .usage,
                           hint: "可用：list / use / download / delete / path")
        }
    }

    // MARK: List

    private static func list(_ context: CLIContext) async throws -> Int32 {
        let engine = try engineOption(context)
        let all = context.invocation.flag("all")
        var models: [ControlModelSummary] = []
        if let location = try? context.control {
            var query = [URLQueryItem(name: "all", value: all ? "true" : "false")]
            if let engine { query.append(URLQueryItem(name: "engine", value: engine.rawValue)) }
            models = try await location.client.get("/v1/models", query: query, timeout: context.timeout)
            if !all { models = models.filter { !$0.helper && !$0.hidden } }
        } else {
            models = offlineModels(context, engine: engine, all: all)
        }
        if context.output.json {
            context.output.json(models)
        } else {
            let rows = models.map { model in
                [model.engine,
                 model.id,
                 CLIFormat.bytes(model.bytes),
                 model.loaded ? "yes" : "",
                 model.installed ? "installed" : "recommended"]
            }
            context.output.table(headers: ["ENGINE", "MODEL", "SIZE", "LOADED", "STATE"],
                                 rows: rows,
                                 empty: "没有模型；先运行 flashcat models list --all 看推荐档位")
            if !context.local.installedIDs.isEmpty, (try? context.control) == nil {
                context.output.note("离线视图只列出磁盘目录；完整目录与共享授权需要应用在运行。")
            }
        }
        return CLIExit.success.rawValue
    }

    private static func offlineModels(_ context: CLIContext,
                                      engine: EngineID?,
                                      all: Bool) -> [ControlModelSummary] {
        let ids = engine.map { [$0] } ?? EngineCatalog.allIDs
        var rows: [ControlModelSummary] = []
        for id in ids {
            for model in context.local.localModels(engine: id) {
                if !all, model.id.lowercased().contains("dflash") { continue }
                rows.append(ControlModelSummary(id: model.id,
                                                engine: model.engine,
                                                path: model.path,
                                                bytes: model.bytes,
                                                installed: true,
                                                source: model.path.hasPrefix(FlashCatPaths.sharedModelsDirectory)
                                                    ? "shared" : "local"))
            }
            // The built-in recommendation catalog lives in the app target
            // (it is a product list, not core logic). Offline `--all` therefore
            // stops at what is on disk; the app-backed path lists suggestions.
        }
        return rows
    }

    // MARK: Use

    private static func use(_ context: CLIContext) async throws -> Int32 {
        guard let model = context.invocation.arguments.first, !model.isEmpty else {
            throw CLIError("需要模型 id", exit: .usage,
                           hint: "先用 flashcat models list 找一个模型")
        }
        let engine = try engineOption(context)
        let location = try context.control
        let body = ControlModelUse(model: model, engine: engine?.rawValue)
        let status: ControlStatus = try await location.client.post("/v1/models/use", body: body,
                                                                  timeout: context.longTimeout)
        if context.output.json {
            context.output.json(status)
        } else if let active = status.engine {
            context.output.success("\(active.name) \(active.version) · \(active.model)")
        } else {
            context.output.success("模型已就绪：\(model)")
        }
        return CLIExit.success.rawValue
    }

    // MARK: Download

    private static func download(_ context: CLIContext) async throws -> Int32 {
        guard let model = context.invocation.arguments.first, !model.isEmpty else {
            throw CLIError("需要仓库 id 或模型 id", exit: .usage,
                           hint: "例如 flashcat models download mlx-community/Qwen3-8B-4bit")
        }
        let explicitEngine = try engineOption(context)
        let targets = context.invocation.listOption("for").compactMap { EngineID(rawValue: $0) }
        if let bad = context.invocation.listOption("for").first(where: { EngineID(rawValue: $0) == nil }) {
            throw CLIError("未知引擎：\(bad)", exit: .usage)
        }
        let shared = context.invocation.flag("shared") || !targets.isEmpty
        let location = try context.control
        let body = ControlModelDownload(model: model,
                                        engine: explicitEngine?.rawValue,
                                        mode: shared ? "shared" : "engine",
                                        engines: targets.isEmpty ? nil : targets.map(\.rawValue))
        let data = try await location.client.postData("/v1/models/download",
                                                      body: try ControlJSON.encoder(pretty: false).encode(body),
                                                      timeout: context.longTimeout)
        var accepted = decodeDownload(data)
        if accepted.model.isEmpty {
            // A simple `{ok,message}` answer (or a server that did not find the
            // row yet): ask the queue for the task we just started.
            let downloads: [ControlDownloadSummary] = (try? await location.client.get(
                "/v1/downloads", timeout: context.timeout)) ?? []
            // Only a row for *this* model counts. Falling back to the last
            // queued task makes `--wait` follow an unrelated download.
            if let match = downloads.first(where: { matches($0.model, model) }) {
                accepted = match
            }
        }
        if context.output.json, !context.invocation.flag("wait") {
            context.output.json(accepted)
        } else if !context.output.json {
            if accepted.model.isEmpty {
                context.output.note("下载已开始")
            } else {
                context.output.note("下载已开始：\(accepted.model)（\(accepted.engine)）")
            }
        }
        guard context.invocation.flag("wait") else { return CLIExit.success.rawValue }
        guard !accepted.model.isEmpty else {
            throw CLIError("下载已请求，但控制接口没有返回任务", exit: .failure,
                           hint: "运行 flashcat status 查看下载中心")
        }

        let result = try await waitForDownload(context, task: accepted, location: location)
        if context.output.json {
            context.output.json(result)
        } else {
            context.output.success("下载完成：\(result.id)")
        }
        return CLIExit.success.rawValue
    }

    private static func waitForDownload(_ context: CLIContext,
                                        task: ControlDownloadSummary,
                                        location: ControlLocation) async throws -> ControlModelSummary {
        let deadline: Date
        if let raw = context.invocation.option("timeout"), let value = Double(raw), value > 0 {
            deadline = Date().addingTimeInterval(value)
        } else {
            deadline = Date().addingTimeInterval(24 * 3600)
        }
        var lastLine = ""
        var missingSince: Date?
        while Date() < deadline {
            let downloads: [ControlDownloadSummary] = try await location.client.get("/v1/downloads",
                                                                                    timeout: context.timeout)
            if let current = downloads.first(where: { $0.engine == task.engine && $0.model == task.model })
                ?? downloads.first(where: { matches($0.model, task.model) }) {
                if current.status == "failed" {
                    throw CLIError("下载失败：\(current.model)", exit: .failure,
                                   hint: "运行 flashcat logs --engine \(current.engine) 查看下载器输出")
                }
                if current.status == "paused" {
                    throw CLIError("下载已暂停：\(current.model)", exit: .conflict,
                                   hint: "运行 flashcat models download \(current.model) --wait 可续传")
                }
                missingSince = nil
                if !context.output.json {
                    let line = "\(current.model)  \(CLIFormat.percent(current.fraction))"
                        + "  \(CLIFormat.bytes(current.downloadedBytes)) / \(CLIFormat.bytes(current.totalBytes))"
                        + (current.speed.map { "  " + CLIFormat.rate($0) } ?? "")
                    if line != lastLine {
                        lastLine = line
                        context.output.note(line)
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            // The row disappears on success — and also when another client
            // cancels it. Confirm the weights are actually visible, but give the
            // library a few seconds to finish rescanning before declaring that
            // the transfer ended without a model.
            if let installed = try await installedModel(context, location: location, model: task.model) {
                return installed
            }
            if missingSince == nil { missingSince = Date() }
            if let missingSince, Date().timeIntervalSince(missingSince) > 15 {
                throw CLIError("下载已结束，但模型没有出现在模型库里：\(task.model)", exit: .conflict,
                               hint: "运行 flashcat logs --engine \(task.engine) 查看下载器输出")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw CLIError("等待下载超时：\(task.model)", exit: .timeout,
                       hint: "下载仍在后台继续；用 flashcat status 或 flashcat models list 查看")
    }

    private static func installedModel(_ context: CLIContext,
                                       location: ControlLocation,
                                       model: String) async throws -> ControlModelSummary? {
        let models: [ControlModelSummary] = try await location.client.get("/v1/models",
                                                                           query: [URLQueryItem(name: "all", value: "false")],
                                                                           timeout: context.timeout)
        return models.first { $0.installed && matches($0.id, model) }
    }

    // MARK: Delete

    private static func delete(_ context: CLIContext) async throws -> Int32 {
        guard let model = context.invocation.arguments.first, !model.isEmpty else {
            throw CLIError("需要模型 id", exit: .usage)
        }
        let shared = context.invocation.flag("shared")
            || model.hasPrefix(FlashCatPaths.sharedModelsDirectory + "/")
        guard try context.confirm("删除模型 \(model) 及其权重文件？") else {
            context.output.note("已取消")
            return CLIExit.success.rawValue
        }
        let explicitEngine = context.invocation.option("engine")
        if let raw = explicitEngine, EngineID(rawValue: raw) == nil {
            throw CLIError("未知引擎：\(raw)", exit: .usage)
        }
        let location = try context.control
        let body = ControlModelDelete(model: model, engine: explicitEngine, shared: shared)
        let result: ControlSimpleResult = try await location.client.post("/v1/models/delete", body: body,
                                                                        timeout: context.longTimeout)
        if context.output.json {
            context.output.json(result)
        } else {
            context.output.success(result.message)
        }
        return CLIExit.success.rawValue
    }

    // MARK: Path

    private static func path(_ context: CLIContext) async throws -> Int32 {
        guard let model = context.invocation.arguments.first, !model.isEmpty else {
            throw CLIError("需要模型 id", exit: .usage)
        }
        let engine = try engineOption(context) ?? context.local.activeEngine
        var resolved: String?
        if let location = try? context.control {
            let models: [ControlModelSummary] = (try? await location.client.get("/v1/models",
                                                                                query: [URLQueryItem(name: "all", value: "true")],
                                                                                timeout: context.timeout)) ?? []
            resolved = models.first { matches($0.id, model) && ($0.path?.isEmpty == false) }?.path
        }
        let path = resolved ?? FlashCatPaths.modelPath(for: engine, model: model)
        if context.output.json {
            struct Body: Encodable {
                let model: String
                let engine: String
                let path: String
                let exists: Bool
            }
            context.output.json(Body(model: model, engine: engine.rawValue, path: path,
                                     exists: FileManager.default.fileExists(atPath: path)))
        } else {
            context.output.line(path)
        }
        return CLIExit.success.rawValue
    }

    // MARK: Helpers

    private static func engineOption(_ context: CLIContext) throws -> EngineID? {
        guard let raw = context.invocation.option("engine") else { return nil }
        guard let id = EngineID(rawValue: raw) else {
            throw CLIError("未知引擎：\(raw)", exit: .usage,
                           hint: "可用：" + EngineCatalog.allIDs.map(\.rawValue).joined(separator: ", "))
        }
        return id
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    static func normalized(_ value: String) -> String {
        let repo = value.split(separator: ":", maxSplits: 1).first.map(String.init) ?? value
        return repo.replacingOccurrences(of: "--", with: "/").lowercased()
    }

    private static func decodeDownload(_ data: Data) -> ControlDownloadSummary {
        if let summary = try? ControlJSON.decoder().decode(ControlDownloadSummary.self, from: data) {
            return summary
        }
        // A bare `{ok,message}` answer carries no task identity. Keep the model
        // empty so the caller can look the real task up instead of treating the
        // human-readable message as a model id.
        return ControlDownloadSummary(engine: "", model: "", status: "downloading",
                                      downloadedBytes: 0, totalBytes: 0)
    }

}
