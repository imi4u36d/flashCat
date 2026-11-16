// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation
import Darwin
import FlashCatKit

public enum StatusCommand {
    public static func run(_ context: CLIContext) async throws -> Int32 {
        let watch = context.invocation.flag("watch")
        let interval = max(0.2, Double(context.invocation.option("interval") ?? "1") ?? 1)
        var finalExit = CLIExit.success.rawValue
        var warned = false
        repeat {
            let snapshot = await snapshot(context)
            // 警告只在第一轮打到 stderr：`--watch` 每轮重画整屏，同一行反复刷会把
            // 真正的状态挤掉；`--json` 时它已经在 payload 的 `warnings` 里，不必再打。
            if !warned, !context.output.json {
                for warning in snapshot.report.warnings {
                    context.output.warning(warning)
                }
            }
            warned = true
            if context.output.json {
                context.output.json(snapshot.report)
            } else {
                printHuman(snapshot, context)
            }
            finalExit = snapshot.report.running
                ? CLIExit.success.rawValue
                : snapshot.exit.rawValue
            if !watch { break }
            if context.isTTY && !context.output.json {
                context.output.write("\u{001B}[2J\u{001B}[H")
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } while true
        return finalExit
    }

    public struct Report: Encodable {
        public var running: Bool
        /// The process may be up while the command channel is disabled; the
        /// two are separate facts and the human view says which is which.
        public var appRunning: Bool
        public var app: ControlAppInfo?
        public var engine: ControlEngineState?
        public var engines: [ControlEngineState]
        public var gateway: ControlGatewayState
        public var downloads: [ControlDownloadSummary]
        public var offline: Bool
        public var error: String?
        /// 说清哪些本地材料没读成（目前只有损坏的 engines.json）。它不影响
        /// `running` / 退出码：既有契约不能因为一行警告而变。
        public var warnings: [String]
    }

    private struct Snapshot {
        var report: Report
        var offlineReason: String?
        var exit: CLIExit = .notRunning
    }

    private static func snapshot(_ context: CLIContext) async -> Snapshot {
        do {
            let location = try context.control
            let status: ControlStatus = try await location.client.get("/v1/status",
                                                                      timeout: context.timeout)
            return Snapshot(report: Report(running: true,
                                           appRunning: true,
                                           app: status.app,
                                           engine: status.engine,
                                           engines: status.engines,
                                           gateway: status.gateway,
                                           downloads: status.downloads,
                                           offline: false,
                                           error: nil,
                                           // 在线时这份文档来自应用自己的状态，
                                           // CLI 侧那份 engines.json 坏没坏都不影响结论。
                                           warnings: []),
                            offlineReason: nil,
                            exit: .success)
        } catch let error as CLIError {
            return Snapshot(report: offlineReport(context, reason: error.message),
                            offlineReason: error.message,
                            exit: error.exit)
        } catch {
            return Snapshot(report: offlineReport(context, reason: error.localizedDescription),
                            offlineReason: error.localizedDescription)
        }
    }

    private static func offlineReport(_ context: CLIContext, reason: String) -> Report {
        let local = context.local
        // 离线报告完全由磁盘拼出来，所以 engines.json 读不动的理由必须一起带上：
        // 否则「没有任何引擎」看起来就像事实，而不是一份读坏的文件的后果。
        let readout = local.engineConfigurationReadout()
        let engines = ControlEngineDocuments.engines(local.engineDocumentInputs())
        let gateway = ControlGatewayState(enabled: local.gatewayEnabled,
                                          running: local.gatewayEnabled && portOpen(local.gatewayPort),
                                          port: local.gatewayPort,
                                          baseURL: "http://127.0.0.1:\(local.gatewayPort)",
                                          failure: nil)
        let appRunning = local.app.map(AppCommand.isRunning) ?? false
        return Report(running: false,
                      appRunning: appRunning,
                      app: nil,
                      engine: ControlEngineDocuments.primary(engines),
                      engines: engines,
                      gateway: gateway,
                      downloads: localDownloads(),
                      offline: true,
                      error: reason,
                      warnings: readout.warning.map { [$0] } ?? [])
    }

    private static func localDownloads() -> [ControlDownloadSummary] {
        struct TaskFile: Decodable {
            var engine: String
            var model: String
            var status: String
            var downloadedBytes: Int?
            var totalBytes: Int?
            var shared: [String]?
        }
        guard let data = FileManager.default.contents(atPath: FlashCatPaths.downloadTasksFile),
              let tasks = try? JSONDecoder().decode([TaskFile].self, from: data) else {
            return []
        }
        return tasks.map { task in
            let downloaded = task.downloadedBytes ?? 0
            let total = task.totalBytes ?? 0
            return ControlDownloadSummary(engine: task.engine,
                                          model: task.model,
                                          status: task.status == "downloading" ? "paused" : task.status,
                                          downloadedBytes: downloaded,
                                          totalBytes: total,
                                          fraction: total > 0 ? min(Double(downloaded) / Double(total), 1) : nil,
                                          shared: task.shared)
        }
    }

    private static func printHuman(_ snapshot: Snapshot, _ context: CLIContext) {
        let out = context.output
        let report = snapshot.report
        if report.running, let app = report.app {
            out.line(out.bold("flashCat \(app.version)") + "  " + out.green("运行中")
                     + out.dim(" · pid \(app.pid) · 控制接口 \(app.controlPort)"))
        } else if report.appRunning {
            out.line(out.bold("flashCat") + "  " + out.yellow("运行中 · 控制接口不可用"))
            if let reason = snapshot.offlineReason {
                out.line(out.dim("  " + reason))
            }
        } else {
            out.line(out.bold("flashCat") + "  " + out.yellow("未运行"))
            if let reason = snapshot.offlineReason {
                out.line(out.dim("  " + reason))
            }
        }
        out.line()

        if let engine = report.engine, engine.isInstalled {
            let state = CLIFormat.engineState(engine.state)
            let tone = engine.state == "ready" ? out.green(state) : out.yellow(state)
            out.line("引擎   " + out.bold(engine.name) + " " + engine.version + " · " + tone
                     + (engine.model.isEmpty ? "" : " · " + engine.model)
                     + " · :\(engine.port)"
                     + (engine.uptimeSeconds.map { " · 已运行 \(CLIFormat.duration($0))" } ?? ""))
        } else {
            out.line("引擎   没有安装")
        }
        let gateway = report.gateway
        let gatewayState = gateway.running ? out.green("运行中") : (gateway.enabled ? out.yellow("未运行") : out.dim("已关闭"))
        out.line("网关   " + gateway.baseURL + "/v1 · " + gatewayState
                 + (gateway.failure.map { " · " + $0 } ?? ""))
        let installed = report.engines.filter(\.isInstalled)
        if !installed.isEmpty {
            out.line("已装   " + installed.map { "\($0.name) \($0.version)" }.joined(separator: "、"))
        }
        if let engine = report.engine {
            let others = report.engines.filter { $0.isInstalled && $0.id != engine.id }
            if !others.isEmpty {
                out.line("其他   " + others.map { "\($0.name) \($0.version)" }.joined(separator: "、"))
            }
        }
        if !report.downloads.isEmpty {
            for task in report.downloads {
                out.line("下载   \(task.model) · \(task.status) · \(CLIFormat.percent(task.fraction))")
            }
        }
        if !report.running {
            out.line()
            out.line(out.dim("提示：flashcat app open 启动应用；离线状态只能看到磁盘上已有的引擎与模型。"))
        }
    }

}

/// POSIX connect probe used for the offline status view. A local connect
/// resolves instantly: refused means free, accepted means something listens.
public func portOpen(_ port: Int) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    if descriptor < 0 { return false }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    inet_aton("127.0.0.1", &address.sin_addr)
    let connected = withUnsafePointer(to: address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            connect(descriptor, socketAddress, UInt32(MemoryLayout<sockaddr_in>.size))
        }
    }
    return connected == 0
}
