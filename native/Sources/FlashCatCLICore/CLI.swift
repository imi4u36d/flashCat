// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation
import Darwin
import FlashCatKit

/// Entry point for the `flashcat` command. Keeping the dispatcher in a library
/// target lets the tests exercise parsing, formatting and SSE decoding without
/// launching the app.
public enum CLI {
    public static func run(arguments: [String],
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           stdout: @escaping (String) -> Bool = {
                               CLIStandardIO.write($0, to: FileHandle.standardOutput.fileDescriptor)
                           },
                           stderr: @escaping (String) -> Bool = {
                               CLIStandardIO.write($0, to: FileHandle.standardError.fileDescriptor)
                           },
                           isTTY: Bool = CLI.isatty(FileHandle.standardOutput.fileDescriptor),
                           stdinIsTTY: Bool = CLI.isatty(FileHandle.standardInput.fileDescriptor),
                           executable: String = CommandLine.arguments.first ?? "flashcat") async -> Int32 {
        // `flashcat chat … | head -1` 会让下游提前关掉管道，默认处置是 SIGPIPE 直接杀掉进程
        // （退出码 141），用户分不清是崩溃还是正常分页结束。忽略它，再由 CLIOutput 把
        // EPIPE 当成一次可判定的写失败，命令安静收手。
        _ = signal(SIGPIPE, SIG_IGN)

        // 参数错误也要守同样的输出约定（--json 出 JSON、--no-color 不加转义），而这两个
        // 开关只有扫完参数才知道；所以先宽容解析拿到全局开关，再构造 output/context，
        // 最后才把第一个用法错误报出去。以前的 rawJSON 预扫描是同一件事的手工猜测版。
        let parsed = CLIArguments.parseTolerant(arguments)
        let invocation = parsed.invocation

        let color = isTTY
            && environment["NO_COLOR"] == nil
            && environment["TERM"] != "dumb"
            && !invocation.flag("no-color")
        let output = CLIOutput(json: invocation.flag("json"),
                               quiet: invocation.flag("quiet"),
                               color: color,
                               verbose: invocation.flag("verbose"),
                               stdout: stdout,
                               stderr: stderr)
        let context = CLIContext(invocation: invocation,
                                 environment: environment,
                                 output: output,
                                 local: LocalState(environment: environment),
                                 isTTY: isTTY,
                                 stdinIsTTY: stdinIsTTY,
                                 executable: executable)

        /// 下游关掉 stdout 属于正常分页（`| head`），不是命令失败：按 coreutils 的约定
        /// 返回 0，否则 `flashcat logs … | head -20` 会被 `set -e` 的脚本当成出错。
        func finish(_ code: Int32) -> Int32 {
            output.brokenPipe ? CLIExit.success.rawValue : code
        }

        func report(_ error: CLIError) -> Int32 {
            if output.json {
                output.jsonError(error)
            } else {
                output.errorLine(output.red("flashcat: ") + error.message)
                if let hint = error.hint { output.errorLine(output.dim(hint)) }
            }
            return finish(error.exit.rawValue)
        }

        if let usageError = parsed.error {
            return report(CLIError(usageError.errorDescription ?? "参数无效",
                                   exit: .usage,
                                   hint: "运行 flashcat help 查看用法"))
        }

        if invocation.flag("version") || invocation.command == "version" {
            await VersionCommand.run(context)
            return finish(CLIExit.success.rawValue)
        }
        if invocation.command == "help" || invocation.flag("help") {
            HelpCommand.run(context)
            return finish(CLIExit.success.rawValue)
        }

        do {
            let code: Int32
            switch invocation.command {
            case "status":
                code = try await StatusCommand.run(context)
            case "engines":
                code = try await EnginesCommand.run(context)
            case "models":
                code = try await ModelsCommand.run(context)
            case "chat":
                code = try await ChatCommand.run(context)
            case "gateway":
                code = try await GatewayCommand.run(context)
            case "logs":
                code = try await LogsCommand.run(context)
            case "config":
                code = try await ConfigCommand.run(context)
            case "app":
                code = try await AppCommand.run(context)
            case "doctor":
                code = try await DoctorCommand.run(context)
            case "completion":
                code = try CompletionCommand.run(context)
            case "cli":
                code = try SelfInstallerCommand.run(context)
            default:
                return report(CLIError("未知命令：\(invocation.command)",
                                       exit: .usage,
                                       hint: "运行 flashcat help 查看用法"))
            }
            return finish(code)
        } catch let error as CLIError {
            return report(error)
        } catch {
            return report(CLIError(error.localizedDescription))
        }
    }

    public static func isatty(_ descriptor: Int32) -> Bool {
        Darwin.isatty(descriptor) == 1
    }
}

public enum CLIInfo {
    public static func version(environment: [String: String]) -> String {
        if let value = environment["FLASHCAT_VERSION"], !value.isEmpty { return value }
        guard let app = AppLocator.resolve(environment: environment) else { return "dev" }
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let dictionary = NSDictionary(contentsOf: info),
              let value = dictionary["CFBundleShortVersionString"] as? String else {
            return "dev"
        }
        return value
    }

    public static func build(environment: [String: String]) -> String? {
        guard let app = AppLocator.resolve(environment: environment) else { return nil }
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let dictionary = NSDictionary(contentsOf: info),
              let value = dictionary["CFBundleVersion"] as? String else { return nil }
        return value
    }
}
