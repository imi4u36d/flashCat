import Foundation
import Darwin
import FlashCatKit

public enum DoctorCommand {
    public static func run(_ context: CLIContext) async throws -> Int32 {
        let report: ControlDoctorReport
        if let location = try? context.control,
           let online: ControlDoctorReport = try? await location.client.get("/v1/doctor",
                                                                              timeout: context.timeout) {
            report = online
        } else {
            report = offline(context)
        }
        if context.output.json {
            context.output.json(report)
        } else {
            let rows = report.checks.map { check in
                [statusText(check.status, context.output), check.title, check.detail]
            }
            context.output.table(headers: ["STATUS", "CHECK", "DETAIL"], rows: rows)
        }
        return report.failed ? CLIExit.failure.rawValue : CLIExit.success.rawValue
    }

    private static func statusText(_ status: String, _ out: CLIOutput) -> String {
        switch status {
        case "ok": return out.green("ok")
        case "warn": return out.yellow("warn")
        default: return out.red("fail")
        }
    }

    private static func offline(_ context: CLIContext) -> ControlDoctorReport {
        let local = context.local
        let environment = context.environment
        var checks: [ControlDoctorCheck] = []

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        checks.append(ControlDoctorCheck(status: os.majorVersion >= 26 ? "ok" : "fail",
                                         id: "macos",
                                         title: "macOS",
                                         detail: "\(osVersion)（最低 26.0）"))

        if let app = AppLocator.resolve(environment: environment) {
            checks.append(ControlDoctorCheck(status: AppCommand.isRunning(app) ? "ok" : "warn",
                                             id: "app",
                                             title: "应用",
                                             detail: app.path))
        } else {
            checks.append(ControlDoctorCheck(status: "fail", id: "app",
                                             title: "应用", detail: "没有找到 flashCat.app"))
        }

        let runtime = ControlRuntime.load()
        let running = runtime?.processIsAlive == true && portOpen(Int(runtime?.port ?? 0))
        checks.append(ControlDoctorCheck(status: running ? "ok" : "warn",
                                         id: "control",
                                         title: "命令行接口",
                                         detail: runtime.map { "127.0.0.1:\($0.port)" } ?? "没有 control.json"))
        if !local.controlEnabled {
            checks.append(ControlDoctorCheck(status: "warn", id: "control-enabled",
                                             title: "命令行接口开关", detail: "已在设置中关闭"))
        }

        checks.append(ControlDoctorCheck(status: local.gatewayEnabled && portOpen(local.gatewayPort) ? "ok" : "warn",
                                         id: "gateway",
                                         title: "API 网关",
                                         detail: "http://127.0.0.1:\(local.gatewayPort)/v1"))

        let installed = local.installedIDs
        checks.append(ControlDoctorCheck(status: installed.isEmpty ? "warn" : "ok",
                                         id: "engines",
                                         title: "推理引擎",
                                         detail: installed.isEmpty
                                             ? "还没有安装引擎"
                                             : installed.map { "\($0.displayName) \(local.newest($0)?.version ?? "")" }
                                                 .joined(separator: "、")))

        let modelCount = EngineCatalog.allIDs.reduce(0) { total, id in
            total + local.localModels(engine: id).count
        }
        checks.append(ControlDoctorCheck(status: modelCount == 0 ? "warn" : "ok",
                                         id: "models",
                                         title: "模型",
                                         detail: modelCount == 0 ? "磁盘上没有模型" : "\(modelCount) 个模型目录"))

        let support = FlashCatPaths.supportDirectory
        let writable = FileManager.default.isWritableFile(atPath: support)
            || !FileManager.default.fileExists(atPath: support)
        checks.append(ControlDoctorCheck(status: writable ? "ok" : "warn",
                                         id: "paths",
                                         title: "数据目录",
                                         detail: "\(support)\(writable ? "" : "（不可写）")"))

        let free = freeDiskBytes()
        let gigabytes = Double(free) / 1_000_000_000
        checks.append(ControlDoctorCheck(status: gigabytes > 5 ? "ok" : "warn",
                                         id: "disk",
                                         title: "磁盘",
                                         detail: String(format: "可用 %.1f GB", gigabytes)))

        let pathLink = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            .first { FileManager.default.isExecutableFile(atPath: $0 + "/flashcat") }
        checks.append(ControlDoctorCheck(status: pathLink == nil ? "warn" : "ok",
                                         id: "cli",
                                         title: "flashcat 命令",
                                         detail: pathLink.map { $0 + "/flashcat" }
                                             ?? "不在 PATH；运行 flashcat cli install"))

        let index = AppLocator.resolve(environment: environment)
            .flatMap { AppLocator.resourceRoot($0) }
            .map { $0.appendingPathComponent("pack-index.json").path }
        let indexExists = index.map { FileManager.default.fileExists(atPath: $0) } ?? false
        checks.append(ControlDoctorCheck(status: indexExists ? "ok" : "warn",
                                         id: "index",
                                         title: "引擎包索引",
                                         detail: indexExists ? (index ?? "") : "应用 bundle 里没有 pack-index.json"))

        return ControlDoctorReport(checks: checks)
    }

    private static func freeDiskBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        var stat = statfs()
        if statfs(NSHomeDirectory(), &stat) == 0 {
            return Int64(stat.f_bavail) * Int64(stat.f_bsize)
        }
        return 0
    }
}

public enum CompletionCommand {
    public static func run(_ context: CLIContext) throws -> Int32 {
        let shellPath = context.environment["SHELL"]
        let shell = context.invocation.subcommand
            ?? (shellPath.map { ($0 as NSString).lastPathComponent } ?? "zsh")
        let script: String
        switch shell {
        case "zsh": script = zsh
        case "bash": script = bash
        case "fish": script = fish
        default:
            throw CLIError("不支持的 shell：\(shell)", exit: .usage,
                           hint: "可用：zsh / bash / fish")
        }
        context.output.write(script.hasSuffix("\n") ? script : script + "\n")
        return CLIExit.success.rawValue
    }

    private static let commands = [
        "status", "engines", "models", "chat", "gateway", "logs",
        "config", "app", "doctor", "completion", "cli", "version", "help",
    ]

    private static let groups: [(String, [String])] = [
        ("engines", ["list", "start", "stop", "restart", "use", "install", "uninstall", "port", "logs"]),
        ("models", ["list", "use", "download", "delete", "path"]),
        ("gateway", ["status", "start", "stop"]),
        ("config", ["list", "get", "set", "unset", "path"]),
        ("app", ["status", "open", "quit", "restart", "path"]),
        ("cli", ["install", "uninstall", "path"]),
        ("completion", ["zsh", "bash", "fish"]),
    ]

    private static let engines = EngineCatalog.allIDs.map(\.rawValue)

    private static var zsh: String {
        var lines = [
            "#compdef flashcat",
            "# 由 `flashcat completion zsh` 生成。",
            "_flashcat() {",
            "  local -a commands",
            "  commands=(" + commands.map { "'\($0):flashCat 命令行'" }.joined(separator: " ") + ")",
            "  if (( CURRENT == 2 )); then",
            "    _describe 'command' commands",
            "    return",
            "  fi",
            "  case $words[2] in",
        ]
        for (group, subcommands) in groups {
            lines.append("    \(group))")
            lines.append("      compadd -- " + subcommands.joined(separator: " "))
            if group == "engines" || group == "models" || group == "logs" {
                lines.append("      compadd -- " + engines.joined(separator: " "))
            }
            lines.append("      ;;")
        }
        lines += [
            "    chat) compadd -- --model --engine --system --temperature --top-p --max-tokens --json --no-stream ;;",
            "  esac",
            "}",
            "_flashcat \"$@\"",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static var bash: String {
        var words = commands
        for (_, subcommands) in groups { words.append(contentsOf: subcommands) }
        words.append(contentsOf: engines)
        words.append(contentsOf: ["--json", "--quiet", "--help", "--version", "--no-color", "--timeout"])
        return """
        # 由 `flashcat completion bash` 生成。
        _flashcat() {
            local cur
            cur="${COMP_WORDS[COMP_CWORD]}"
            COMPREPLY=( $(compgen -W "\(words.joined(separator: " "))" -- "$cur") )
        }
        complete -F _flashcat flashcat
        """
    }

    private static var fish: String {
        var lines = ["# 由 `flashcat completion fish` 生成。"]
        for command in commands {
            lines.append("complete -c flashcat -f -n __fish_use_subcommand -a \(command)")
        }
        for (group, subcommands) in groups {
            for subcommand in subcommands {
                lines.append("complete -c flashcat -f -n '__fish_seen_subcommand_from \(group)' -a \(subcommand)")
            }
        }
        for engine in engines {
            lines.append("complete -c flashcat -f -n '__fish_seen_subcommand_from engines models logs' -a \(engine)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
