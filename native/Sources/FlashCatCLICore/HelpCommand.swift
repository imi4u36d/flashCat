import Foundation

public enum HelpCommand {
    public static func run(_ context: CLIContext) {
        let topic = context.invocation.explicitCommand
            ? (context.invocation.arguments.first ?? context.invocation.command)
            : "overview"
        switch topic {
        case "status", "engines", "models", "chat", "gateway", "logs",
             "config", "app", "doctor", "completion", "cli":
            printTopic(topic, context)
        default:
            printOverview(context)
        }
    }

    private static func printOverview(_ context: CLIContext) {
        let out = context.output
        out.line(out.bold("flashcat") + " — flashCat 的命令行接口")
        out.line()
        out.line("用法：flashcat <命令> [参数] [选项]")
        out.line()
        out.table(headers: ["命令", "说明"], rows: [
            ["status", "应用、引擎、网关和下载状态"],
            ["engines", "列出、启停、切换、安装与卸载引擎"],
            ["models", "列出、加载、下载与删除模型"],
            ["chat", "通过本地网关发起一轮对话"],
            ["gateway", "查看、启动或停止 OpenAI / Claude 网关"],
            ["logs", "看引擎、网关或控制接口日志（可跟踪）"],
            ["config", "读取或修改设置"],
            ["app", "打开、退出或重启 flashCat"],
            ["doctor", "检查安装、权限与运行时"],
            ["completion", "输出 zsh / bash / fish 补全脚本"],
            ["cli", "把 flashcat 安装到 PATH"],
            ["version", "打印版本"],
            ["help", "查看某个命令的完整用法"],
        ])
        out.line()
        out.line(out.bold("常用"))
        out.line("  flashcat status                    # 一眼看完当前状态")
        out.line("  flashcat engines start omlx        # 切到 oMLX 并等它就绪")
        out.line("  flashcat models list --all         # 本机权重 + 推荐档位")
        out.line("  flashcat chat \"用一句话解释 MoE\"   # 走网关对话")
        out.line("  flashcat chat - --json < prompt.txt")
        out.line()
        out.line(out.bold("全局选项"))
        out.table(headers: ["选项", "说明"], rows: [
            ["-j, --json", "输出 JSON；错误也走 JSON"],
            ["-q, --quiet", "只输出结果，不输出进度提示"],
            ["--no-color", "关闭 ANSI 颜色"],
            ["--timeout <秒>", "控制接口超时（默认 30，长任务 900）"],
            ["--control-port <端口>", "覆盖控制端口（默认读 control.json）"],
            ["--control-url <URL>", "覆盖控制接口地址（仅本机回环，或 https）"],
            ["--control-token <令牌>", "覆盖控制令牌（默认读 control.json）"],
            ["-v, --verbose", "输出调试细节"],
            ["-h, --help", "显示帮助"],
            ["-V, --version", "显示版本"],
        ])
        out.line()
        out.line(out.bold("退出码"))
        out.table(headers: ["码", "含义"], rows: [
            ["0", "成功"],
            ["1", "执行失败"],
            ["2", "用法或参数错误"],
            ["3", "flashCat 应用未运行 / 控制接口不可达"],
            ["4", "找不到引擎、模型或设置项"],
            ["5", "等待超时"],
            ["6", "状态冲突（切换中、下载中、未确认）"],
            ["7", "控制令牌错误"],
        ])
        out.line()
        out.line(out.dim("提示：flashcat app open 启动应用；flashcat cli install 把命令放进 PATH。"))
    }

    private static func printTopic(_ topic: String, _ context: CLIContext) {
        let out = context.output
        switch topic {
        case "status":
            usage(out, "flashcat status [--json] [--watch]",
                  "显示应用、当前引擎、网关、模型和下载状态。",
                  ["--watch          每秒刷新（Ctrl-C 退出）",
                   "--interval <秒>  刷新间隔，默认 1"])
        case "engines":
            usage(out, "flashcat engines <list|start|stop|restart|use|install|uninstall|port|logs> …",
                  "管理推理引擎。所有引擎平级，任意时刻只有一个在运行。",
                  ["list                    列出引擎与安装版本",
                   "start <id>              切换并启动，等到就绪才返回",
                   "stop <id>               停止",
                   "restart <id>            重启",
                   "use <id>                只切换活动引擎，不启动",
                   "install <id>[@版本]     下载并安装运行时 pack（不需要应用在运行）",
                   "uninstall <id>[@版本]   删除用户安装的 pack（先确认）",
                   "port <id> [端口]        查看或修改端口（需要应用在运行）",
                   "logs <id>               等价于 logs --engine <id>",
                   "",
                   "选项：--release <版本>  --index <路径|URL>  --force  --yes  --no-reload"])
        case "models":
            usage(out, "flashcat models <list|use|download|delete|path> …",
                  "查看与操作模型库。下载与加载需要 flashCat 应用在运行。",
                  ["list [--engine id] [--all]  本机权重；--all 连推荐档位一起列出",
                   "use <模型> [--engine id]    加载并等到就绪（可能换引擎）",
                   "download <repo|模型>        下载权重",
                   "delete <模型>               删除权重（先确认）",
                   "path <模型> [--engine id]   打印模型目录",
                   "",
                   "下载选项：--engine <id>  --shared  --for a,b  --wait  --yes"])
        case "chat":
            usage(out, "flashcat chat [提示词] [选项]",
                  "通过本地网关发起一轮对话。提示词写 - 或省略时从 stdin 读取。",
                  ["-m, --model <模型>        指定模型（默认当前模型）",
                   "-e, --engine <id>         在某个引擎的模型里挑",
                   "--system <提示词>         系统提示",
                   "--temperature <值>        温度，默认读应用设置",
                   "--top-p <值>              top-p",
                   "--max-tokens <数>         最大输出；0 表示模型上限",
                   "--stream / --no-stream    流式输出（默认 tty 下开启）",
                   "--show-reasoning          把思考过程打到 stderr",
                   "--json                    输出完整结果 JSON"])
        case "gateway":
            usage(out, "flashcat gateway <status|start|stop>",
                  "控制 OpenAI / Claude 双协议网关。",
                  ["status  查看端口与运行状态", "start   启用并启动", "stop    停用并停止"])
        case "logs":
            usage(out, "flashcat logs [--engine id|--gateway|--control|--app] [选项]",
                  "读取日志文件；可按级别过滤并跟踪新行。",
                  ["-e, --engine <id>   引擎日志（默认当前引擎）",
                   "--gateway           网关日志",
                   "--control           控制接口日志",
                   "-n, --lines <数>    显示尾部行数，默认 200",
                   "--level <级别>      过滤 info/system/warning/error/success",
                   "-f, --follow        持续跟踪（Ctrl-C 退出）",
                   "--json              NDJSON：每行一个日志对象"])
        case "config":
            usage(out, "flashcat config <list|get|set|unset|path> …",
                  "读取或修改应用设置。应用在运行时通过控制接口修改并立即生效；应用关闭时只允许修改无需副作用的纯配置。",
                  ["list [--json]        列出全部设置项",
                   "get <键>             读取一个设置项",
                   "set <键> <值>        修改",
                   "unset <键>           恢复空值 / 默认值",
                   "path                 打印 engines.json 等配置路径",
                   "",
                   "示例：flashcat config set appearance dark",
                   "      flashcat config set engines.omlx.port 8101"])
        case "app":
            usage(out, "flashcat app <status|open|quit|restart|path>",
                  "管理 flashCat 应用进程。",
                  ["open [--timeout 秒]  启动并等待控制接口就绪",
                   "quit                 通过控制接口优雅退出（会先收引擎）",
                   "restart              退出后重启",
                   "path                 打印应用 bundle 位置"])
        case "doctor":
            usage(out, "flashcat doctor [--json]",
                  "检查应用安装、控制接口、网关、引擎、模型、磁盘和 PATH。",
                  ["有 fail 项时退出码为 1。"])
        case "completion":
            usage(out, "flashcat completion <zsh|bash|fish>",
                  "输出补全脚本。",
                  ["zsh:  flashcat completion zsh > ~/.zfunc/_flashcat",
                   "bash: flashcat completion bash > /usr/local/etc/bash_completion.d/flashcat",
                   "fish: flashcat completion fish > ~/.config/fish/completions/flashcat.fish"])
        case "cli":
            usage(out, "flashcat cli <install|uninstall|path> [--system-wide]",
                  "把当前 flashcat 可执行文件链接到 PATH。",
                  ["install     链接到 ~/.local/bin/flashcat",
                   "--system-wide  改为 /usr/local/bin（需要写权限）",
                   "uninstall   删除自己创建的链接",
                   "path        打印当前可执行文件路径"])
        default:
            printOverview(context)
        }
    }

    private static func usage(_ out: CLIOutput, _ usage: String, _ summary: String, _ rows: [String]) {
        out.line(out.bold("用法"))
        out.line("  " + usage)
        out.line()
        out.line(summary)
        out.line()
        out.line(out.bold("说明"))
        for row in rows {
            out.line(row.isEmpty ? "" : "  " + row)
        }
        out.line()
        out.line(out.bold("全局选项"))
        out.line("  -j/--json  -q/--quiet  --no-color  --timeout  -h/--help")
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
                                     control: try? context.control.baseURL.absoluteString,
                                     gateway: "http://127.0.0.1:\(context.local.gatewayPort)"))
        } else {
            let suffix = build.map { " (\($0))" } ?? ""
            context.output.line("flashcat \(version)\(suffix)")
        }
    }
}
