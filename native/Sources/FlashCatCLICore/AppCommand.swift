import AppKit
import Darwin
import Foundation
import FlashCatKit

public enum AppCommand {
    public static func run(_ context: CLIContext) async throws -> Int32 {
        switch context.invocation.subcommand ?? "status" {
        case "status":
            return try await StatusCommand.run(context)
        case "path":
            return path(context)
        case "open":
            return try await open(context)
        case "quit":
            return try await quit(context)
        case "restart":
            _ = try await quit(context)
            return try await open(context)
        default:
            throw CLIError("未知 app 子命令：\(context.invocation.subcommand ?? "")", exit: .usage,
                           hint: "可用：status / open / quit / restart / path")
        }
    }

    private static func path(_ context: CLIContext) -> Int32 {
        let app = AppLocator.resolve(environment: context.environment)
        if context.output.json {
            struct Body: Encodable {
                let path: String?
                let running: Bool
                let version: String
            }
            context.output.json(Body(path: app?.path,
                                     running: app.map(isRunning) ?? false,
                                     version: CLIInfo.version(environment: context.environment)))
        } else if let app {
            context.output.line(app.path)
        } else {
            context.output.errorLine("没有找到 flashCat.app")
            return CLIExit.notFound.rawValue
        }
        return CLIExit.success.rawValue
    }

    private static func open(_ context: CLIContext) async throws -> Int32 {
        if let runtime = ControlRuntime.load(), runtime.processIsAlive,
           let base = URL(string: "http://127.0.0.1:\(runtime.port)"),
           let _: ControlAppInfo = try? await ControlClient(baseURL: base, token: runtime.token)
               .get("/v1/health", timeout: 3) {
            if !context.output.json, !context.output.quiet {
                context.output.success("flashCat 已经在运行")
            }
            return CLIExit.success.rawValue
        }
        guard let app = AppLocator.resolve(environment: context.environment) else {
            throw CLIError("找不到 flashCat.app", exit: .notFound,
                           hint: "先把 flashCat.app 放进 /Applications，或设置 FLASHCAT_APP")
        }
        // Do not start a second copy when the first one is still bringing its
        // control server up (or has it disabled). LaunchServices would usually
        // route `open` to the running app, but a direct isolated launch would
        // not.
        if isRunning(app) {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let runtime = ControlRuntime.load(), runtime.processIsAlive,
                   portOpen(Int(runtime.port)),
                   let base = URL(string: "http://127.0.0.1:\(runtime.port)"),
                   let _: ControlAppInfo = try? await ControlClient(baseURL: base, token: runtime.token)
                       .get("/v1/health", timeout: 2) {
                    if context.output.json {
                        context.output.json(ControlSimpleResult(message: "已经在运行"))
                    } else if !context.output.quiet {
                        context.output.success("flashCat 已经在运行")
                    }
                    return CLIExit.success.rawValue
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if !context.local.controlEnabled {
                if context.output.json {
                    context.output.json(ControlSimpleResult(message: "已经在运行（控制接口关闭）"))
                } else if !context.output.quiet {
                    context.output.success("flashCat 已经在运行（控制接口未开启）")
                }
                return CLIExit.success.rawValue
            }
            throw CLIError("flashCat 进程在运行，但控制接口没有就绪", exit: .timeout,
                           hint: "检查「设置 → 命令行接口」，或退出后重开")
        }
        if let status = launch(app, environment: context.environment) {
            guard status == 0 else {
                throw CLIError("无法打开 \(app.path)（启动退出码 \(status)）")
            }
        }
        let timeout = Double(context.invocation.option("timeout") ?? "") ?? 30
        let deadline = Date().addingTimeInterval(timeout)
        let started = Date()
        while Date() < deadline {
            if let runtime = ControlRuntime.load(), runtime.processIsAlive,
               portOpen(Int(runtime.port)),
               let base = URL(string: "http://127.0.0.1:\(runtime.port)"),
               let _: ControlAppInfo = try? await ControlClient(baseURL: base, token: runtime.token)
                   .get("/v1/health", timeout: 2) {
                if context.output.json {
                    context.output.json(ControlSimpleResult(message: "已启动"))
                } else if !context.output.quiet {
                    context.output.success("flashCat 已启动 · 控制接口 127.0.0.1:\(runtime.port)")
                }
                return CLIExit.success.rawValue
            }
            // The process can be up before the control server has bound its
            // port. Only report "control disabled" after a short grace period,
            // and only when the setting actually says it is off.
            if isRunning(app),
               Date().timeIntervalSince(started) > 5,
               !context.local.controlEnabled {
                if context.output.json {
                    context.output.json(ControlSimpleResult(message: "已启动（控制接口关闭）"))
                } else if !context.output.quiet {
                    context.output.success("flashCat 已启动（控制接口未开启）")
                }
                return CLIExit.success.rawValue
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        throw CLIError("flashCat 没有在 \(Int(timeout)) 秒内启动", exit: .timeout,
                       hint: "看 ~/Library/Logs/flashCat/ 或系统的控制台日志")
    }

    private static func quit(_ context: CLIContext) async throws -> Int32 {
        let app = AppLocator.resolve(environment: context.environment)
        let runtime = ControlRuntime.load()
        var requested = false
        let fallbackPid: Int32? = runningPid(app: app, runtime: runtime)

        if let runtime, runtime.processIsAlive, portOpen(Int(runtime.port)),
           let base = URL(string: "http://127.0.0.1:\(runtime.port)") {
            let client = ControlClient(baseURL: base, token: runtime.token)
            if (try? await client.postData("/v1/app/quit", body: Data("{}".utf8), timeout: 10)) != nil {
                requested = true
            }
        }
        if !requested {
            guard app.map(isRunning) ?? false else {
                if !context.output.json, !context.output.quiet {
                    context.output.success("flashCat 没有在运行")
                }
                return CLIExit.success.rawValue
            }
            // No control channel: `NSRunningApplication.terminate()` asks the
            // app to quit through LaunchServices and needs no Automation
            // permission (AppleScript does, and the prompt cannot appear in a
            // non-interactive shell).
            requested = requestTermination(app: app, runtime: runtime)
            if !requested {
                let status = runProcess("/usr/bin/osascript",
                                        ["-e", #"tell application id "com.zhuo.flashCat" to quit"#])
                requested = status == 0
            }
            guard requested else {
                throw CLIError("无法请求 flashCat 退出", exit: .failure,
                               hint: "从菜单栏或应用菜单退出；控制接口关闭时命令行没有别的通道")
            }
        }

        let deadline = Date().addingTimeInterval(max(5, context.timeout))
        let quitStarted = Date()
        var signalled = false
        while Date() < deadline {
            // A known pid is authoritative; the LaunchServices list can keep a
            // terminated app for several seconds and would keep us waiting for
            // an exit that already happened.
            let running: Bool
            if let pid = fallbackPid {
                running = kill(pid, 0) == 0
            } else {
                running = (app.map(isRunning) ?? false) || (runtime?.processIsAlive ?? false)
            }
            if running, !signalled, Date().timeIntervalSince(quitStarted) > 5,
               let pid = fallbackPid {
                // `NSRunningApplication.terminate()` uses an Apple event that
                // can be dropped when Automation permission was never granted.
                // A plain SIGTERM is the last resort; the engine watchdogs are
                // tied to this pid and reap the runtimes after it is gone.
                signalled = kill(pid, SIGTERM) == 0
            }
            if !running {
                try? FileManager.default.removeItem(atPath: FlashCatPaths.controlRuntimeFile)
                if context.output.json {
                    context.output.json(ControlSimpleResult(message: "已退出"))
                } else if !context.output.quiet {
                    context.output.success("flashCat 已退出")
                }
                return CLIExit.success.rawValue
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        throw CLIError("flashCat 没有在超时内退出", exit: .timeout,
                       hint: "引擎可能在等待卸载权重；再试一次或从菜单栏退出")
    }

    static func runningPid(app: URL?, runtime: ControlRuntime?) -> Int32? {
        if let runtime, runtime.processIsAlive { return runtime.pid }
        guard let app else { return nil }
        let target = app.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().path == target
        }?.processIdentifier
    }

    private static func requestTermination(app: URL?, runtime: ControlRuntime?) -> Bool {
        if let runtime, runtime.processIsAlive,
           let running = NSRunningApplication(processIdentifier: runtime.pid) {
            return running.terminate()
        }
        let candidates = NSWorkspace.shared.runningApplications.filter { running in
            guard !running.isTerminated,
                  let bundle = running.bundleURL?.resolvingSymlinksInPath() else { return false }
            return app.map { $0.resolvingSymlinksInPath().path == bundle.path } ?? false
        }
        return candidates.first?.terminate() ?? false
    }

    /// `open` is the normal path: LaunchServices gives the app a Dock icon and
    /// its own environment. When the caller is running an isolated instance
    /// (`FLASHCAT_SUPPORT_DIR`, `FLASHCAT_LOGS_DIR`, `FLASHCAT_CONTROL_PORT`),
    /// `open` would drop those variables and start a second instance against
    /// the real profile, so launch the executable directly with the current
    /// environment instead.
    private static func launch(_ app: URL, environment: [String: String]) -> Int32? {
        let overrides = ["FLASHCAT_SUPPORT_DIR", "FLASHCAT_LOGS_DIR",
                         "FLASHCAT_CONTROL_PORT", "FLASHCAT_ENGINE_PACKS_DIR"]
        guard overrides.contains(where: { environment[$0] != nil }) else {
            return runProcess("/usr/bin/open", [app.path])
        }
        let executable = app.appendingPathComponent("Contents/MacOS/flashCat")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return runProcess("/usr/bin/open", [app.path])
        }
        let process = Process()
        process.executableURL = executable
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            return 0
        } catch {
            return -1
        }
    }

    /// `pgrep -f` is the cheapest cross-process check and does not require the
    /// app to expose an API. The pattern is the bundle's own executable path so
    /// a second checkout cannot match.
    static func isRunning(_ app: URL) -> Bool {
        let pattern = app.appendingPathComponent("Contents/MacOS/flashCat").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // `-x` + `-f` matches the full command line exactly. Without it, the
        // shell that runs `pgrep -f <pattern>` matches itself.
        process.arguments = ["-x", "-f", pattern]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return true }
        } catch {
            // Fall through to the LaunchServices view.
        }
        // A development copy launched by relative path has a different argv[0],
        // so the exact pgrep above misses it while `runningApplications` still
        // knows the bundle. This list can lag a terminated process, which is
        // why it is only the fallback.
        let target = app.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.contains { running in
            !running.isTerminated && running.bundleURL?.resolvingSymlinksInPath().path == target
        }
    }

    @discardableResult
    static func runProcess(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

public enum SelfInstallerCommand {
    public static func run(_ context: CLIContext) throws -> Int32 {
        switch context.invocation.subcommand ?? "path" {
        case "path":
            let url = executableURL()
            if context.output.json {
                struct Body: Encodable {
                    let path: String
                    let installedLink: String?
                }
                context.output.json(Body(path: url.path, installedLink: installedLink()))
            } else {
                context.output.line(url.path)
            }
            return CLIExit.success.rawValue
        case "install":
            return try install(context)
        case "uninstall":
            return try uninstall(context)
        default:
            throw CLIError("未知 cli 子命令：\(context.invocation.subcommand ?? "")", exit: .usage,
                           hint: "可用：install / uninstall / path")
        }
    }

    private static func install(_ context: CLIContext) throws -> Int32 {
        let home = context.environment["HOME"] ?? NSHomeDirectory()
        let directory = context.invocation.flag("system-wide")
            ? "/usr/local/bin"
            : home + "/.local/bin"
        let target = directory + "/flashcat"
        let source = executableURL()
        let manager = FileManager.default
        do {
            try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            throw CLIError("无法创建 \(directory)：\(error.localizedDescription)", exit: .failure,
                           hint: "系统目录需要 sudo；不加 --system-wide 会装到 ~/.local/bin")
        }
        if let existing = try? manager.destinationOfSymbolicLink(atPath: target) {
            if URL(fileURLWithPath: existing).resolvingSymlinksInPath().path == source.path {
                if !context.output.json, !context.output.quiet {
                    context.output.success("已经安装：\(target) → \(source.path)")
                }
                return CLIExit.success.rawValue
            }
            guard context.invocation.flag("force") else {
                throw CLIError("\(target) 已指向 \(existing)", exit: .conflict,
                               hint: "加 --force 覆盖")
            }
            try? manager.removeItem(atPath: target)
        } else if manager.fileExists(atPath: target) {
            guard context.invocation.flag("force") else {
                throw CLIError("\(target) 已存在且不是符号链接", exit: .conflict,
                               hint: "加 --force 覆盖")
            }
            try? manager.removeItem(atPath: target)
        }
        do {
            try manager.createSymbolicLink(atPath: target, withDestinationPath: source.path)
        } catch {
            throw CLIError("无法创建链接：\(error.localizedDescription)", exit: .failure)
        }
        guard !context.output.json else {
            context.output.json(ControlSimpleResult(message: target))
            return CLIExit.success.rawValue
        }
        context.output.success("已安装：\(target) → \(source.path)")
        if !(context.environment["PATH"] ?? "").split(separator: ":").map(String.init).contains(directory) {
            context.output.note("把 \(directory) 加进 PATH：")
            context.output.note("  echo 'export PATH=\"\(directory):$PATH\"' >> ~/.zshrc")
        }
        return CLIExit.success.rawValue
    }

    private static func uninstall(_ context: CLIContext) throws -> Int32 {
        let home = context.environment["HOME"] ?? NSHomeDirectory()
        let candidates = [home + "/.local/bin/flashcat", "/usr/local/bin/flashcat"]
        let source = executableURL()
        var removed: [String] = []
        for target in candidates {
            guard FileManager.default.fileExists(atPath: target) else { continue }
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target) else {
                continue
            }
            let resolved = URL(fileURLWithPath: destination).resolvingSymlinksInPath().path
            if resolved == source.path || context.invocation.flag("force") {
                try? FileManager.default.removeItem(atPath: target)
                removed.append(target)
            }
        }
        if context.output.json {
            context.output.json(ControlSimpleResult(message: removed.isEmpty ? "没有链接" : removed.joined(separator: ", ")))
        } else if removed.isEmpty {
            context.output.note("没有找到指向当前 flashcat 的链接")
        } else {
            context.output.success("已删除：" + removed.joined(separator: ", "))
        }
        return CLIExit.success.rawValue
    }

    static func executableURL() -> URL {
        if let url = Bundle.main.executableURL {
            return url.resolvingSymlinksInPath()
        }
        let raw = CommandLine.arguments.first ?? "flashcat"
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath()
    }

    static func installedLink() -> String? {
        let home = NSHomeDirectory()
        let candidates = [home + "/.local/bin/flashcat", "/usr/local/bin/flashcat"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}
