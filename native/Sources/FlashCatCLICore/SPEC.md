# flashcat CLI — 设计说明

`flashcat` 是 flashCat 的命令行入口。它随应用 bundle 分发
（`Contents/Helpers/flashcat`），通过本机回环控制接口驱动应用；应用未运行时仍可
读取磁盘状态、安装/卸载引擎、读写无需副作用的设置与日志。

- 产物：`flashcat-cli`（SwiftPM 产品名；APFS 大小写不敏感，不能与 `flashCat`
  只差大小写）。打包时复制为 `Contents/Helpers/flashcat`。
- 逻辑：`Sources/FlashCatCLICore`（解析、输出、控制客户端、命令）
- 薄入口：`Sources/flashcat-cli/FlashCatCLI.swift`
- 测试：`Tests/FlashCatCLICoreTests`

## 分层

| 文件 | 职责 |
| --- | --- |
| `CLI.swift` | 入口、全局选项、错误到退出码 |
| `CLIArguments.swift` | 子命令 / 选项解析（无第三方依赖） |
| `CLIContext.swift` | 应用定位、离线状态、路径与超时 |
| `ControlClient.swift` | `control.json` 发现、HTTP 客户端、状态码映射 |
| `CLIHTTP.swift` | 无磁盘缓存的 `URLSession`（避免 CLI 写 `~/Library/Caches`） |
| `StatusCommand.swift` | 应用 / 引擎 / 网关 / 下载；在线与离线两套视图 |
| `EnginesCommand.swift` | 启停、切换、安装（Kit `EngineInstaller`）、卸载、端口 |
| `ModelsCommand.swift` | 列表、加载、下载（含 `--wait` 轮询）、删除、路径 |
| `ChatCommand.swift` | 网关 SSE 客户端与 `SSEAccumulator` |
| `LogsCommand.swift` | 日志尾部与 `--follow` |
| `ConfigCommand.swift` | 在线设置；离线只允许纯配置 |
| `AppCommand.swift` | 打开 / 退出 / 重启 / 定位应用，以及 `cli install` 的 PATH 链接 |
| `DoctorCommand.swift` | 环境自检与 zsh / bash / fish 补全 |

## 与应用的契约

- **控制接口。** `ControlLocation.discover` 先读
  `~/Library/Application Support/flashCat/control.json`（可用
  `FLASHCAT_SUPPORT_DIR` 覆盖），校验 pid 是否存活，再拼
  `http://127.0.0.1:<port>`。令牌只从文件或显式参数来，不做猜测。
- **两个服务器。** 网关（默认 9000）只负责推理；控制接口（默认 9100，可顺延）
  负责应用动作。`chat` 走网关，其余驱动类命令走控制接口。
- **不复制业务规则。** 引擎安装用 Kit 的 `EngineInstaller`；路径用
  `FlashCatPaths`；引擎发现用 `EngineInstallations`；控制文档用
  `ControlProtocol.swift`。
- **离线能力**：`status`、`engines list`、`engines install/uninstall`、`models
  list`（磁盘目录）、`logs`、`config list/get` 与部分纯配置 `set`、`doctor`、
  `completion`、`cli`。需要应用的动作在无控制接口时以退出码 3 失败并给出提示。

## 输出契约

- `--json`：stdout 只放 JSON；错误 JSON 写 stderr。
- 人类输出：结果写 stdout，进度与提示写 stderr。
- `--quiet` 关闭提示与成功文案；`--no-color` / `NO_COLOR` 关闭 ANSI。
- `chat -` 显式从 stdin 读提示词，即使 stdout 是终端也能用（Ctrl-D 结束）；
  只有既没有参数、stdin 又是终端时才报「需要提示词」。确认提示同理：stdin
  不是终端时必须加 `--yes`，不会假装有人会按回车。
- 退出码：`0` 成功、`1` 失败、`2` 用法、`3` 应用未运行、`4` 找不到、
  `5` 超时、`6` 冲突、`7` 令牌错误。控制接口的 HTTP 状态映射见
  `ControlClient.exitCode`。

## 安全

控制接口只绑定 `127.0.0.1`；每次启动生成随机令牌，`control.json` 从创建起就是
`0600`（不是写完再 chmod），令牌不会经过另一个本地用户可读的窗口。`--control-url`
只接受本机回环地址；指向其他主机时必须用 `https`，否则 CLI 直接拒绝，避免把
令牌明文发给网络。CLI 不读取用户密码。`app quit` 走控制接口，让 AppKit 执行
引擎的优雅退出；只有控制接口关闭时才回落到 AppleScript。
