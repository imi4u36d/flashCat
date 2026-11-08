import Foundation
import Darwin
import FlashCatKit

/// Entry point for the `flashcat` command. Keeping the dispatcher in a library
/// target lets the tests exercise parsing, formatting and SSE decoding without
/// launching the app.
public enum CLI {
    public static func run(arguments: [String],
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           stdout: @escaping (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) },
                           stderr: @escaping (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) },
                           isTTY: Bool = CLI.isatty(FileHandle.standardOutput.fileDescriptor),
                           stdinIsTTY: Bool = CLI.isatty(FileHandle.standardInput.fileDescriptor),
                           executable: String = CommandLine.arguments.first ?? "flashcat") async -> Int32 {
        let rawJSON = arguments.contains("--json") || arguments.contains("-j")
        let invocation: CLIInvocation
        do {
            invocation = try CLIArguments.parse(arguments)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            let output = CLIOutput(json: rawJSON, stdout: stdout, stderr: stderr)
            if rawJSON {
                output.jsonError(CLIError(message, exit: .usage))
            } else {
                output.errorLine(output.red("flashcat: ") + message)
                output.errorLine("运行 flashcat help 查看用法")
            }
            return CLIExit.usage.rawValue
        }

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

        if invocation.flag("version") || invocation.command == "version" {
            await VersionCommand.run(context)
            return CLIExit.success.rawValue
        }
        if invocation.command == "help" || invocation.flag("help") {
            HelpCommand.run(context)
            return CLIExit.success.rawValue
        }

        do {
            switch invocation.command {
            case "status":
                return try await StatusCommand.run(context)
            case "engines":
                return try await EnginesCommand.run(context)
            case "models":
                return try await ModelsCommand.run(context)
            case "chat":
                return try await ChatCommand.run(context)
            case "gateway":
                return try await GatewayCommand.run(context)
            case "logs":
                return try await LogsCommand.run(context)
            case "config":
                return try await ConfigCommand.run(context)
            case "app":
                return try await AppCommand.run(context)
            case "doctor":
                return try await DoctorCommand.run(context)
            case "completion":
                return try CompletionCommand.run(context)
            case "cli":
                return try SelfInstallerCommand.run(context)
            default:
                if output.json {
                    output.jsonError(CLIError("未知命令：\(invocation.command)",
                                              exit: .usage,
                                              hint: "运行 flashcat help 查看用法"))
                } else {
                    output.errorLine(output.red("flashcat: ") + "未知命令：\(invocation.command)")
                    output.errorLine("运行 flashcat help 查看用法")
                }
                return CLIExit.usage.rawValue
            }
        } catch let error as CLIError {
            if output.json {
                output.jsonError(error)
            } else {
                output.errorLine(output.red("flashcat: ") + error.message)
                if let hint = error.hint { output.errorLine(output.dim(hint)) }
            }
            return error.exit.rawValue
        } catch {
            if output.json {
                output.jsonError(CLIError(error.localizedDescription))
            } else {
                output.errorLine(output.red("flashcat: ") + error.localizedDescription)
            }
            return CLIExit.failure.rawValue
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
