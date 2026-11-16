import FlashCatKit

// MARK: - 选项

/// 选项的种类。解析器据此决定吃不吃值、吃不吃数字、能不能累积。
public enum CLIOptionKind: Equatable, Sendable {
    /// 布尔开关：出现即为真，也接受 `--flag=false` 与后随的 true/false。
    case flag
    /// 单值选项。
    case value
    /// 数值选项：解析阶段就拒绝非数字，别把 `--timeout abc` 拖到发请求才炸。
    case number
    /// 逗号分隔、可重复出现并累积（`--for a,b --for c`）。
    case list
}

/// 一个选项的声明。解析器、`help`、补全脚本都从这一份投影。
public struct CLIOptionSpec: Equatable, Sendable {
    /// 规范名（不带 `--`）：`CLIInvocation.options` / `flags` 里用的键。
    public let name: String
    /// 短别名（`-j`）；没有则为 nil。
    public let short: Character?
    public let kind: CLIOptionKind
    /// 值占位符（`<秒>`），只用于渲染帮助。
    public let placeholder: String?
    public let summary: String

    public init(_ name: String,
                short: Character? = nil,
                kind: CLIOptionKind = .flag,
                placeholder: String? = nil,
                summary: String) {
        self.name = name
        self.short = short
        self.kind = kind
        self.placeholder = placeholder
        self.summary = summary
    }

    /// 帮助表格里的一列：`-j, --json` / `--timeout <秒>`。
    public var usageLabel: String {
        var label = short.map { "-\($0), --\(name)" } ?? "--\(name)"
        if let placeholder { label += " " + placeholder }
        return label
    }

    /// 压成一行时用的写法：`-j/--json` / `--no-color`。
    public var compactLabel: String {
        var label = short.map { "-\($0)/--\(name)" } ?? "--\(name)"
        if let placeholder { label += " " + placeholder }
        return label
    }

    /// 补全脚本用的长名（带 `--`）。
    public var dashedName: String { "--" + name }
}

/// 所有选项的唯一来源。
///
/// 为什么集中在这里：以前「哪些选项吃值、哪些是开关、哪些必须是数字」写在
/// `CLIArguments`，「每个命令有哪些选项」写在 `HelpCommand` 的手写文本里，
/// 补全脚本又是一份。加一个 `--foo` 要改三处，忘一处就成了「帮助里没有、
/// 但解析器认识」或者反过来的幽灵选项。现在只有这一份，其余位置都是投影。
public enum CLIOptions {
    // MARK: 全局

    public static let json = CLIOptionSpec("json", short: "j", summary: "输出 JSON；错误也走 JSON")
    public static let quiet = CLIOptionSpec("quiet", short: "q", summary: "只输出结果，不输出进度提示")
    public static let verbose = CLIOptionSpec("verbose", short: "v", summary: "输出调试细节")
    public static let help = CLIOptionSpec("help", short: "h", summary: "显示帮助")
    public static let version = CLIOptionSpec("version", short: "V", summary: "显示版本")
    public static let noColor = CLIOptionSpec("no-color", summary: "关闭 ANSI 颜色")
    public static let timeout = CLIOptionSpec("timeout", short: "t", kind: .number,
                                              placeholder: "<秒>",
                                              summary: "控制接口超时（默认 30，长任务 900）")
    public static let controlPort = CLIOptionSpec("control-port", kind: .number,
                                                  placeholder: "<端口>",
                                                  summary: "覆盖控制端口（默认读 control.json）")
    public static let controlURL = CLIOptionSpec("control-url", kind: .value,
                                                 placeholder: "<URL>",
                                                 summary: "覆盖控制接口地址（仅本机回环，或 https）")
    public static let controlToken = CLIOptionSpec("control-token", kind: .value,
                                                   placeholder: "<令牌>",
                                                   summary: "覆盖控制令牌（默认读 control.json）")

    // MARK: status

    public static let watch = CLIOptionSpec("watch", summary: "每秒刷新（Ctrl-C 退出）")
    public static let interval = CLIOptionSpec("interval", kind: .number, placeholder: "<秒>",
                                               summary: "刷新间隔，默认 1")

    // MARK: engines

    public static let release = CLIOptionSpec("release", kind: .value, placeholder: "<版本>",
                                              summary: "指定要安装的 pack 版本，默认最新")
    public static let index = CLIOptionSpec("index", kind: .value, placeholder: "<路径|URL>",
                                            summary: "覆盖 pack 索引位置")
    public static let force = CLIOptionSpec("force", summary: "跳过保护性检查，强制执行")
    public static let yes = CLIOptionSpec("yes", short: "y", summary: "不可逆操作不再确认")
    public static let noReload = CLIOptionSpec("no-reload", summary: "装完不触发 engines reload")

    // MARK: models

    public static let engine = CLIOptionSpec("engine", short: "e", kind: .value, placeholder: "<id>",
                                             summary: "限定引擎")
    public static let all = CLIOptionSpec("all", short: "a", summary: "连推荐档位一起列出")
    public static let shared = CLIOptionSpec("shared", summary: "用共享权重目录")
    public static let wait = CLIOptionSpec("wait", short: "w", summary: "等到任务结束再返回")
    public static let forEngines = CLIOptionSpec("for", kind: .list, placeholder: "<a,b>",
                                                 summary: "同时为这些引擎准备（可重复）")

    // MARK: chat

    public static let model = CLIOptionSpec("model", short: "m", kind: .value, placeholder: "<模型>",
                                            summary: "指定模型（默认当前模型）")
    public static let system = CLIOptionSpec("system", kind: .value, placeholder: "<提示词>",
                                             summary: "系统提示")
    public static let temperature = CLIOptionSpec("temperature", kind: .number, placeholder: "<值>",
                                                  summary: "温度，默认读应用设置")
    public static let topP = CLIOptionSpec("top-p", kind: .number, placeholder: "<值>",
                                           summary: "top-p，默认读应用设置")
    public static let maxTokens = CLIOptionSpec("max-tokens", kind: .number, placeholder: "<数>",
                                                summary: "最大输出；0 表示模型上限")
    public static let stream = CLIOptionSpec("stream", summary: "流式输出（默认 tty 下开启）")
    public static let noStream = CLIOptionSpec("no-stream", summary: "关闭流式输出")
    public static let showReasoning = CLIOptionSpec("show-reasoning", summary: "把思考过程打到 stderr")
    public static let gatewayURL = CLIOptionSpec("gateway-url", kind: .value, placeholder: "<URL>",
                                                 summary: "覆盖网关地址（默认读设置）")

    // MARK: logs

    public static let gateway = CLIOptionSpec("gateway", summary: "网关日志")
    public static let control = CLIOptionSpec("control", summary: "控制接口日志")
    public static let app = CLIOptionSpec("app", summary: "应用日志")
    public static let lines = CLIOptionSpec("lines", short: "n", kind: .number, placeholder: "<数>",
                                            summary: "显示尾部行数，默认 200")
    public static let level = CLIOptionSpec("level", kind: .value, placeholder: "<级别>",
                                            summary: "过滤 info/system/warning/error/success")
    public static let follow = CLIOptionSpec("follow", short: "f", summary: "持续跟踪（Ctrl-C 退出）")

    // MARK: cli

    public static let systemWide = CLIOptionSpec("system-wide", summary: "改为装到 /usr/local/bin（需要写权限）")

    // MARK: 仅解析器认识的旧选项

    /// `--engines` 只在历史脚本里出现过，现在没有任何命令读它。
    ///
    /// 为什么还留着：删掉它会让 `flashcat models list --engines splash` 这类
    /// 老脚本从「参数被忽略」变成「未知选项 + 退出码 2」。它不进帮助、也不进
    /// 任何命令的选项表，只是解析器继续接受。
    public static let engines = CLIOptionSpec("engines", kind: .value, placeholder: "<id>",
                                              summary: "兼容保留：解析器接受，但没有命令读取")
}

// MARK: - 命令

/// 一个命令的声明：帮助文本、选项、可能出现的退出码都在这里。
public struct CLICommandSpec: Equatable, Sendable {
    public let name: String
    /// 概览表里的一行说明。
    public let summary: String
    /// 「用法」行的正文。
    public let usage: String
    /// 「说明」段的口述行（子命令、示例、注意事项）；空串表示一个空行。
    public let details: [String]
    /// 子命令名。解析器据此把 `flashcat engines start` 拆成 command + subcommand。
    public let subcommands: [String]
    /// 该命令特有的选项；全局选项不重复列。
    public let options: [CLIOptionSpec]
    /// 该命令可能出现的退出码（含 0）。帮助里的「退出码」段由它生成。
    public let exitCodes: [CLIExit]

    public init(name: String,
                summary: String,
                usage: String,
                details: [String] = [],
                subcommands: [String] = [],
                options: [CLIOptionSpec] = [],
                exitCodes: [CLIExit]) {
        self.name = name
        self.summary = summary
        self.usage = usage
        self.details = details
        self.subcommands = subcommands
        self.options = options
        self.exitCodes = exitCodes
    }
}

/// 一个退出码的语义，以及它在控制接口里的两种表现形式。
public struct CLIExitCodeSpec: Equatable, Sendable {
    public let code: CLIExit
    public let summary: String
    /// 控制接口用这些 HTTP 状态表达它；空数组表示没有专门的状态。
    public let httpStatuses: [Int]
    /// 控制接口错误体里 `error.code` 的取值。命中时优先于 HTTP 状态——令牌过期
    /// 常常带 500 回来，只看状态码会把它误报成「执行失败」。
    public let controlErrorCodes: [String]
}

/// 一条控制接口路由归谁发起。
///
/// CLI 不发起的路由也要登记一行并写清原因：`ControlRoute` 加新 case 时，覆盖
/// 测试会失败并要求在这里表态「哪个命令用」或「CLI 为什么不用」。
public struct CLIRouteOwnership: Equatable, Sendable {
    public let route: ControlRoute
    /// 发起它的 CLI 命令；空数组表示 CLI 不发起。
    public let commands: [String]
    /// 样例请求。测试用它跑 `ControlRoute.parse`，确认这张表没有写错路径。
    public let method: String
    public let path: String
    public let summary: String
}

/// CLI 的「命令表 / 选项表 / 退出码表」：唯一来源。
///
/// 为什么要有这张表：命令清单、帮助文本、`--json` 之外的选项语义、以及控制接口
/// HTTP 状态到退出码的映射，过去分别写在 `HelpCommand` / `CLIArguments` /
/// `CLIOutput` / `ControlClient` 四处，同一件事要改四处，漏一处就出现「帮助说
/// 有、解析器不认识」或者「同一个失败有两种退出码」。
public enum CLICommandTable {
    // MARK: 全局选项

    /// 顺序就是帮助里的顺序：先常用输出开关，再控制接口覆盖，最后是 -v/-h/-V。
    public static let globalOptions: [CLIOptionSpec] = [
        CLIOptions.json, CLIOptions.quiet, CLIOptions.noColor, CLIOptions.timeout,
        CLIOptions.controlPort, CLIOptions.controlURL, CLIOptions.controlToken,
        CLIOptions.verbose, CLIOptions.help, CLIOptions.version,
    ]

    // MARK: 命令

    /// 走控制接口的命令都会遇到这些码：参数错(2)、应用没开(3)、接口超时(5)、
    /// 令牌错(7)，外加成功(0) 与其它失败(1)。
    private static let controlExitCodes: [CLIExit] = [
        .success, .failure, .usage, .notRunning, .timeout, .unauthorized,
    ]

    /// 只在本机干活的命令：不碰控制接口，所以不会给 3/5/7。
    private static let localExitCodes: [CLIExit] = [.success, .failure, .usage]

    public static let commands: [CLICommandSpec] = [
        CLICommandSpec(
            name: "status",
            summary: "应用、引擎、网关和下载状态",
            usage: "flashcat status [--json] [--watch]",
            details: ["应用没在运行时读磁盘上的 engines.json 与下载任务，退化成一份离线报告。"],
            options: [CLIOptions.watch, CLIOptions.interval],
            exitCodes: controlExitCodes),
        CLICommandSpec(
            name: "engines",
            summary: "列出、启停、切换、安装与卸载引擎",
            usage: "flashcat engines <list|start|stop|restart|use|install|uninstall|port|logs> …",
            details: [
                "list                    列出引擎与安装版本",
                "start <id>              切换并启动，等到就绪才返回",
                "stop <id>               停止",
                "restart <id>            重启",
                "use <id>                只切换活动引擎，不启动",
                "install <id>[@版本]     下载并安装运行时 pack（不需要应用在运行）",
                "uninstall <id>[@版本]   删除用户安装的 pack（先确认）",
                "port <id> [端口]        查看或修改端口（需要应用在运行）",
                "logs <id>               等价于 logs --engine <id>",
            ],
            subcommands: ["list", "start", "stop", "restart", "use",
                          "install", "uninstall", "port", "logs"],
            options: [CLIOptions.release, CLIOptions.index, CLIOptions.force,
                      CLIOptions.yes, CLIOptions.noReload],
            exitCodes: controlExitCodes + [.notFound, .conflict]),
        CLICommandSpec(
            name: "models",
            summary: "列出、加载、下载与删除模型",
            usage: "flashcat models <list|use|download|delete|path> …",
            details: [
                "list [--engine id] [--all]  本机权重；--all 连推荐档位一起列出",
                "use <模型> [--engine id]    加载并等到就绪（可能换引擎）",
                "download <repo|模型>        下载权重",
                "delete <模型>               删除权重（先确认）",
                "path <模型> [--engine id]   打印模型目录",
            ],
            subcommands: ["list", "use", "download", "delete", "path"],
            options: [CLIOptions.engine, CLIOptions.all, CLIOptions.shared,
                      CLIOptions.wait, CLIOptions.forEngines, CLIOptions.yes],
            exitCodes: controlExitCodes + [.notFound, .conflict]),
        CLICommandSpec(
            name: "chat",
            summary: "通过本地网关发起一轮对话",
            usage: "flashcat chat [提示词] [选项]",
            details: ["提示词写 - 或省略时从 stdin 读取。"],
            options: [CLIOptions.model, CLIOptions.engine, CLIOptions.system,
                      CLIOptions.temperature, CLIOptions.topP, CLIOptions.maxTokens,
                      CLIOptions.stream, CLIOptions.noStream,
                      CLIOptions.showReasoning, CLIOptions.gatewayURL],
            exitCodes: controlExitCodes + [.notFound, .conflict]),
        CLICommandSpec(
            name: "gateway",
            summary: "查看、启动或停止 OpenAI / Claude 网关",
            usage: "flashcat gateway <status|start|stop>",
            details: ["status  查看端口与运行状态",
                      "start   启用并启动",
                      "stop    停用并停止"],
            subcommands: ["status", "start", "stop"],
            exitCodes: controlExitCodes + [.conflict]),
        CLICommandSpec(
            name: "logs",
            summary: "看引擎、网关或控制接口日志（可跟踪）",
            usage: "flashcat logs [--engine id|--gateway|--control|--app] [选项]",
            options: [CLIOptions.engine, CLIOptions.gateway, CLIOptions.control,
                      CLIOptions.app, CLIOptions.lines, CLIOptions.level, CLIOptions.follow],
            exitCodes: controlExitCodes + [.notFound]),
        CLICommandSpec(
            name: "config",
            summary: "读取或修改设置",
            usage: "flashcat config <list|get|set|unset|path> …",
            details: [
                "list [--json]        列出全部设置项",
                "get <键>             读取一个设置项",
                "set <键> <值>        修改",
                "unset <键>           恢复空值 / 默认值",
                "path                 打印 engines.json 等配置路径",
                "",
                "示例：flashcat config set appearance dark",
                "      flashcat config set engines.omlx.port 8101",
            ],
            subcommands: ["list", "get", "set", "unset", "path"],
            exitCodes: controlExitCodes + [.notFound, .conflict]),
        CLICommandSpec(
            name: "app",
            summary: "打开、退出或重启 flashCat",
            usage: "flashcat app <status|open|quit|restart|path>",
            details: [
                "open [--timeout 秒]  启动并等待控制接口就绪",
                "quit                 通过控制接口优雅退出（会先收引擎）",
                "restart              退出后重启",
                "path                 打印应用 bundle 位置",
            ],
            subcommands: ["status", "open", "quit", "restart", "path"],
            options: [CLIOptions.force],
            exitCodes: controlExitCodes + [.conflict]),
        CLICommandSpec(
            name: "doctor",
            summary: "检查安装、权限与运行时",
            usage: "flashcat doctor [--json]",
            details: ["有 fail 项时退出码为 1。"],
            exitCodes: controlExitCodes),
        CLICommandSpec(
            name: "completion",
            summary: "输出 zsh / bash / fish 补全脚本",
            usage: "flashcat completion <zsh|bash|fish>",
            details: [
                "zsh:  flashcat completion zsh > ~/.zfunc/_flashcat",
                "bash: flashcat completion bash > /usr/local/etc/bash_completion.d/flashcat",
                "fish: flashcat completion fish > ~/.config/fish/completions/flashcat.fish",
            ],
            subcommands: ["zsh", "bash", "fish"],
            exitCodes: localExitCodes),
        CLICommandSpec(
            name: "cli",
            summary: "把 flashcat 安装到 PATH",
            usage: "flashcat cli <install|uninstall|path> [--system-wide]",
            details: [
                "install     链接到 ~/.local/bin/flashcat",
                "uninstall   删除自己创建的链接",
                "path        打印当前可执行文件路径",
            ],
            subcommands: ["install", "uninstall", "path"],
            options: [CLIOptions.systemWide],
            exitCodes: localExitCodes),
        CLICommandSpec(
            name: "version",
            summary: "打印版本",
            usage: "flashcat version [--json]",
            exitCodes: localExitCodes),
        CLICommandSpec(
            name: "help",
            summary: "查看某个命令的完整用法",
            usage: "flashcat help [命令]",
            exitCodes: localExitCodes),
    ]

    // MARK: 退出码

    /// 退出码表。`status` / `config` 的 `--json` 里 `warnings` 只是信息，
    /// 不会改这里的任何一个码——脚本靠这些码判断状态，不能因为一行提示就漂移。
    public static let exitCodes: [CLIExitCodeSpec] = [
        CLIExitCodeSpec(code: .success, summary: "成功", httpStatuses: [], controlErrorCodes: []),
        CLIExitCodeSpec(code: .failure, summary: "执行失败（没有专门映射的错误都落到这里）",
                        httpStatuses: [], controlErrorCodes: []),
        CLIExitCodeSpec(code: .usage, summary: "用法或参数错误",
                        httpStatuses: [400], controlErrorCodes: []),
        CLIExitCodeSpec(code: .notRunning, summary: "flashCat 应用未运行 / 控制接口不可达",
                        httpStatuses: [], controlErrorCodes: []),
        CLIExitCodeSpec(code: .notFound, summary: "找不到引擎、模型或设置项",
                        httpStatuses: [404], controlErrorCodes: []),
        CLIExitCodeSpec(code: .timeout, summary: "等待超时",
                        httpStatuses: [408, 504],
                        controlErrorCodes: [ControlErrorCode.timeout]),
        CLIExitCodeSpec(code: .conflict, summary: "状态冲突（切换中、下载中、未确认）",
                        httpStatuses: [409], controlErrorCodes: []),
        CLIExitCodeSpec(code: .unauthorized, summary: "控制令牌错误",
                        httpStatuses: [401, 403],
                        controlErrorCodes: [ControlErrorCode.unauthorized]),
    ]

    // MARK: 别名与解析器用的表

    /// 命令别名：历史命令与缩写。解析器在拆子命令之前先查这张表。
    public static let commandAliases: [String: String] = [
        "engine": "engines",
        "model": "models",
        "ask": "chat",
        "ps": "status",
        "info": "status",
        "help": "help",
        "version": "version",
    ]

    /// 解析器接受、但不出现在帮助与任何命令选项表里的旧选项。
    public static let unlistedOptions: [CLIOptionSpec] = [CLIOptions.engines]

    // MARK: 路由归属

    public static let routeOwnership: [CLIRouteOwnership] = [
        CLIRouteOwnership(route: .health, commands: ["app"], method: "GET", path: "/v1/health",
                          summary: "应用是否在跑"),
        CLIRouteOwnership(route: .status, commands: ["status", "chat", "gateway", "app"],
                          method: "GET", path: "/v1/status", summary: "整体状态快照"),
        CLIRouteOwnership(route: .doctor, commands: ["doctor"], method: "GET", path: "/v1/doctor",
                          summary: "安装与运行时体检"),
        CLIRouteOwnership(route: .config, commands: ["config", "engines"], method: "GET",
                          path: "/v1/config", summary: "读取设置文档"),
        CLIRouteOwnership(route: .configSet, commands: ["config", "engines"], method: "POST",
                          path: "/v1/config", summary: "写入设置项"),
        CLIRouteOwnership(route: .downloads, commands: ["models"], method: "GET",
                          path: "/v1/downloads", summary: "列出下载任务"),
        CLIRouteOwnership(route: .downloadPause, commands: [], method: "POST",
                          path: "/v1/downloads/pause",
                          summary: "CLI 不发起：暂停是 GUI 里的人机交互动作，没有对应命令。"),
        CLIRouteOwnership(route: .downloadResume, commands: [], method: "POST",
                          path: "/v1/downloads/resume",
                          summary: "CLI 不发起：恢复下载同样只从 GUI 触发。"),
        CLIRouteOwnership(route: .downloadCancel, commands: [], method: "POST",
                          path: "/v1/downloads/cancel",
                          summary: "CLI 不发起：取消下载只从 GUI 触发。"),
        CLIRouteOwnership(route: .logs, commands: ["logs"], method: "GET", path: "/v1/logs",
                          summary: "读取日志尾部"),
        CLIRouteOwnership(route: .models, commands: ["models", "chat"], method: "GET",
                          path: "/v1/models", summary: "列出模型"),
        CLIRouteOwnership(route: .modelUse, commands: ["models"], method: "POST",
                          path: "/v1/models/use", summary: "加载模型"),
        CLIRouteOwnership(route: .modelDownload, commands: ["models"], method: "POST",
                          path: "/v1/models/download", summary: "下载模型"),
        CLIRouteOwnership(route: .modelDelete, commands: ["models"], method: "POST",
                          path: "/v1/models/delete", summary: "删除模型"),
        CLIRouteOwnership(route: .gatewayStart, commands: ["gateway", "chat"], method: "POST",
                          path: "/v1/gateway/start", summary: "启用并启动网关"),
        CLIRouteOwnership(route: .gatewayStop, commands: ["gateway"], method: "POST",
                          path: "/v1/gateway/stop", summary: "停用并停止网关"),
        CLIRouteOwnership(route: .appQuit, commands: ["app"], method: "POST", path: "/v1/app/quit",
                          summary: "让应用优雅退出"),
        CLIRouteOwnership(route: .appOpen, commands: [], method: "POST", path: "/v1/app/open",
                          summary: "CLI 不发起：`app open` 直接 startApplication 拉起应用，不等控制接口。"),
        CLIRouteOwnership(route: .engines, commands: ["engines"], method: "GET", path: "/v1/engines",
                          summary: "列出引擎"),
        CLIRouteOwnership(route: .enginesReload, commands: ["engines"], method: "POST",
                          path: "/v1/engines/reload", summary: "重新扫描引擎 pack"),
        CLIRouteOwnership(route: .engineStart("omlx"), commands: ["engines"], method: "POST",
                          path: "/v1/engines/omlx/start", summary: "切换并启动某个引擎"),
        CLIRouteOwnership(route: .engineStop("omlx"), commands: ["engines"], method: "POST",
                          path: "/v1/engines/omlx/stop", summary: "停止某个引擎"),
        CLIRouteOwnership(route: .engineRestart("omlx"), commands: ["engines"], method: "POST",
                          path: "/v1/engines/omlx/restart", summary: "重启某个引擎"),
        CLIRouteOwnership(route: .engineUse("omlx"), commands: ["engines"], method: "POST",
                          path: "/v1/engines/omlx/use", summary: "只切换活动引擎"),
    ]

    // MARK: 投影给解析器

    /// 帮助与补全会展示的选项 = 全局 + 各命令。不含只给解析器的旧选项。
    public static let listedOptions: [CLIOptionSpec] = globalOptions + commands.flatMap(\.options)

    /// 所有登记过的选项（含只给解析器的旧选项）。
    public static let allOptions: [CLIOptionSpec] = listedOptions + unlistedOptions

    public static let valueOptionNames: Set<String> = Set(
        allOptions.filter { $0.kind != .flag }.map(\.name))
    public static let booleanOptionNames: Set<String> = Set(
        allOptions.filter { $0.kind == .flag }.map(\.name))
    public static let listOptionNames: Set<String> = Set(
        allOptions.filter { $0.kind == .list }.map(\.name))
    public static let numberOptionNames: Set<String> = Set(
        allOptions.filter { $0.kind == .number }.map(\.name))

    /// 短别名：`j` → `json`。
    public static let shortAliases: [Character: String] = {
        var table: [Character: String] = [:]
        for option in allOptions {
            if let short = option.short { table[short] = option.name }
        }
        return table
    }()

    /// 子命令表：`engines` → {list, start, …}。解析器用它拆命令，补全用它生成候选。
    public static let commandGroups: [String: Set<String>] = {
        var table: [String: Set<String>] = [:]
        for command in commands where !command.subcommands.isEmpty {
            table[command.name] = Set(command.subcommands)
        }
        return table
    }()

    /// 保持声明顺序的子命令表（补全脚本需要固定顺序，Set 每次遍历顺序不同）。
    public static let commandSubcommands: [(name: String, subcommands: [String])] =
        commands.compactMap { command in
            command.subcommands.isEmpty ? nil : (command.name, command.subcommands)
        }

    // MARK: 查询

    public static func command(named name: String) -> CLICommandSpec? {
        commands.first { $0.name == name }
    }

    public static func exitCodeSpec(for code: CLIExit) -> CLIExitCodeSpec? {
        exitCodes.first { $0.code == code }
    }

    public static func summary(for code: CLIExit) -> String? {
        exitCodeSpec(for: code)?.summary
    }

    /// 控制接口错误体里的 `error.code` → 退出码。命中优先于 HTTP 状态。
    public static func exitCode(forControlErrorCode code: String) -> CLIExit? {
        exitCodes.first { $0.controlErrorCodes.contains(code) }?.code
    }

    /// HTTP 状态 → 退出码。2xx 一律成功；没有专门映射的状态返回 nil，由调用方
    /// 兜底成 `.failure`（`ControlClient.exitCode` 就靠这个 nil）。
    public static func exitCode(forHTTPStatus status: Int) -> CLIExit? {
        if (200..<300).contains(status) { return .success }
        return exitCodes.first { $0.httpStatuses.contains(status) }?.code
    }

    public static func options(for command: CLICommandSpec) -> [CLIOptionSpec] {
        globalOptions + command.options
    }
}
