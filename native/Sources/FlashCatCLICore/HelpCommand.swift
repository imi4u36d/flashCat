import Foundation

/// `flashcat help` / `--help` 的输出。
///
/// 这里只负责排版：命令清单、用法、选项、退出码全部来自 `CLICommandTable`。
/// 以前这些文案是手写的第二份清单，加一个命令要记得在这里补一行，漏了就成了
/// 「命令能跑，但 help 里查不到」；现在没有第二份可以漏。
public enum HelpCommand {
    /// 概览页里的示例。属于「怎么用」的教学内容，不是命令元数据，所以留在渲染层；
    /// 命令与选项本身仍然只从表里取。
    private static let examples = [
        "flashcat status                    # 一眼看完当前状态",
        "flashcat engines start omlx        # 切到 oMLX 并等它就绪",
        "flashcat models list --all         # 本机权重 + 推荐档位",
        "flashcat chat \"用一句话解释 MoE\"   # 走网关对话",
        "flashcat chat - --json < prompt.txt",
    ]

    public static func run(_ context: CLIContext) {
        // `flashcat help` 不带主题 = 概览；`flashcat help status` = status 的页。
        // 这条规则和 `flashcat status --help` 共用：后者没有参数，主题就是命令本身，
        // 所以带 `--help` 时总能拿到「你正在用的那个命令」的说明。
        let topic: String?
        if context.invocation.command == "help" {
            topic = context.invocation.arguments.first
        } else if context.invocation.explicitCommand {
            topic = context.invocation.arguments.first ?? context.invocation.command
        } else {
            topic = nil
        }
        // 别名也认：`flashcat help ps` 与 `flashcat help status` 打同一页。
        let resolved = topic.map { CLICommandTable.commandAliases[$0] ?? $0 }
        if let resolved, let command = CLICommandTable.command(named: resolved) {
            printTopic(command, out: context.output)
        } else {
            // 未知主题不报错：`flashcat help foo` 打概览并退出 0，和 `flashcat help`
            // 一致。帮助本身不该变成一个错误，否则脚本里 `flashcat help x || …`
            // 会莫名其妙走进失败分支。
            printOverview(context.output)
        }
    }

    private static func printOverview(_ out: CLIOutput) {
        out.line(out.bold("flashcat") + " — flashCat 的命令行接口")
        out.line()
        out.line("用法：flashcat <命令> [参数] [选项]")
        out.line()
        out.table(headers: ["命令", "说明"],
                  rows: CLICommandTable.commands.map { [$0.name, $0.summary] })
        out.line()
        out.line(out.bold("常用"))
        for example in examples {
            out.line("  " + example)
        }
        out.line()
        out.line(out.bold("全局选项"))
        out.table(headers: ["选项", "说明"],
                  rows: CLICommandTable.globalOptions.map { [$0.usageLabel, $0.summary] })
        out.line()
        out.line(out.bold("退出码"))
        out.table(headers: ["退出码", "含义", "控制接口"],
                  rows: CLICommandTable.exitCodes.map { spec in
                      [String(spec.code.rawValue), spec.summary, controlShift(spec)]
                  })
        out.line()
        out.line("提示：flashcat app open 启动应用；flashcat cli install 把命令放进 PATH。")
    }

    /// 控制接口一侧怎么表达这个退出码。空列表示没有专门映射
    /// （`.notRunning` 是本机连不上，`.failure` 是兜底）。
    private static func controlShift(_ spec: CLIExitCodeSpec) -> String {
        var parts: [String] = []
        if !spec.httpStatuses.isEmpty {
            parts.append("HTTP " + spec.httpStatuses.map { String($0) }.joined(separator: "/"))
        }
        if !spec.controlErrorCodes.isEmpty {
            parts.append("error.code=" + spec.controlErrorCodes.joined(separator: "/"))
        }
        return parts.joined(separator: "、")
    }

    private static func printTopic(_ command: CLICommandSpec, out: CLIOutput) {
        out.line(out.bold("flashcat \(command.name)"))
        out.line()
        out.line(out.bold("用法"))
        out.line("  " + command.usage)
        out.line()
        out.line(command.summary)
        if !command.details.isEmpty {
            out.line()
            out.line(out.bold("说明"))
            for row in command.details {
                out.line(row.isEmpty ? "" : "  " + row)
            }
        }
        if !command.options.isEmpty {
            out.line()
            out.line(out.bold("选项"))
            out.table(headers: ["选项", "说明"],
                      rows: command.options.map { [$0.usageLabel, $0.summary] })
        }
        out.line()
        out.line(out.bold("全局选项"))
        out.line("  " + CLICommandTable.globalOptions.map(\.compactLabel).joined(separator: "  "))
        out.line()
        out.line(out.bold("退出码"))
        out.table(headers: ["退出码", "含义"],
                  rows: command.exitCodes.map { spec in
                      [String(spec.rawValue), CLICommandTable.summary(for: spec) ?? ""]
                  })
    }
}

public enum VersionCommand {
    public static func run(_ context: CLIContext) async {
        let version = CLIInfo.version(environment: context.environment)
        let build = CLIInfo.build(environment: context.environment)
        if context.output.json {
            struct Body: Encodable {
                let name: String
                let version: String
                let build: String?
                let app: String?
                let control: String?
                let gateway: String?
            }
            context.output.json(Body(name: "flashcat",
                                     version: version,
                                     build: build,
                                     app: AppLocator.resolve(environment: context.environment)?.path,
                                     control: controlURL(context),
                                     gateway: "http://127.0.0.1:\(context.local.gatewayPort)"))
        } else {
            let suffix = build.map { " (\($0))" } ?? ""
            context.output.line("flashcat \(version)\(suffix)")
        }
    }

    /// `control` 只是诊断字段：没有控制接口就留 null。这里不能写 `try?` 的原因是
    /// 它会连「令牌过期」也一起变成 null，让 `version --json` 看起来像应用没运行。
    private static func controlURL(_ context: CLIContext) -> String? {
        do {
            return try context.control.baseURL.absoluteString
        } catch {
            return nil
        }
    }
}
