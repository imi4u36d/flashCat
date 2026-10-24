# flashCat 团队契约

> **历史文档**：本契约描述迁移前的 Swift/AppKit 实现。客户端已全部迁移为
> Flutter（Material 3），旧 Swift 源码（原 `legacy/swift-macos`）已删除，
> 下列 `app/` 路径不再存在。当前目录与所有权以 README.md 为准。

flashCat = 基于 incoai/splash 的本地推理引擎 macOS App。
最低系统 **macOS 26.0**。UI 文案用中文。

## 目录与文件所有权

| 路径 | 所有者 | 说明 |
| --- | --- | --- |
| `app/Package.swift` | lead | SwiftPM 清单，平台 macOS 26 |
| `app/Sources/FlashCat/main.swift` | lead | 入口；`--verify` 走无头自检 |
| `app/Sources/FlashCat/Verify.swift` | lead | 无头端到端自检 |
| `app/Sources/FlashCat/ServerController.swift` | lead | 推理进程管理（唯一 owner） |
| `app/Sources/FlashCat/Settings.swift` | lead | UserDefaults 设置 |
| `app/Sources/FlashCat/EngineRuntime.swift` | lead | 内置运行时定位 |
| `app/Sources/FlashCat/LocalAPI.swift` | lead | `/ready` `/status` 轮询与 HTTP |
| `app/Sources/FlashCat/AppDelegate.swift` | ui-shell | App 生命周期、状态栏菜单 |
| `app/Sources/FlashCat/MenuBarController.swift` | ui-shell | 状态栏图标与菜单构建/刷新 |
| `app/Sources/FlashCat/LogWindowController.swift` | ui-shell | 日志窗口（Liquid Glass） |
| `app/Sources/FlashCat/SettingsWindowController.swift` | ui-shell | 设置窗口（Liquid Glass） |
| `app/Sources/FlashCat/GlassSupport.swift` | ui-shell | Liquid Glass 辅助视图封装 |
| `scripts/*` `app/Resources/*` `Makefile` `README.md` `.gitignore` | packaging | 构建、打包、文档 |
| `vendor/splash-<SPLASH_VERSION>-arm64-macos26.tar.gz`（当前 1.4.0） | lead | 预构建运行时归档（勿改） |

**只写自己名下的文件。** 需要改别人的文件时，发消息给 lead。

## 后端接口（ServerController，ui-shell 只读使用）

```swift
final class ServerController {
    enum State: Equatable { case stopped, starting, ready, stopping, failed(String) }

    init(runtime: EngineRuntime)

    private(set) var state: State
    private(set) var stats: ServerStats?     // tok/s、并发数、热状态、显存
    private(set) var port: Int
    private(set) var model: String
    private(set) var logLines: [String]

    var onStateChange: (() -> Void)?         // 主线程回调
    var onStats: (() -> Void)?
    var onLogLine: ((String) -> Void)?

    var isRunning: Bool
    var isReady: Bool
    var statusText: String                   // "就绪 · 74 tok/s · 1 个请求"
    var logText: String
    var logFileURL: URL
    func clearLogs()

    func start(model: String, port: Int, extraArguments: [String]? = nil)
    func restart(model: String, port: Int, extraArguments: [String]? = nil)
    func stop()
    func stopAndWait(timeout: TimeInterval = 15)
}

struct ServerStats { var decodeTokensPerSecond: Double?; var activeRequests: Int; var thermal: String?; var memoryBytes: Int64?; var contextTokens: Int?; var model: String? }

struct EngineRuntime {
    let root: URL
    static func locate() throws -> EngineRuntime
    var python: URL        // runtime/python/bin/python3
    var launcher: URL      // runtime/install/launcher.py
    var version: String
    var suggestedModels: [String]   // 推荐模型（4 个）
}

final class Settings {                     // Settings.shared
    static let shared = Settings
    var port: Int                     // 默认 8000
    var model: String                 // 空 = 用 suggestedModels.first
    var maxMemory: String             // 例 "28G"
    var maxContext: String            // 例 "100K"
    var idleReleaseOff: Bool          // --idle-release off
    var languageOnly: Bool            // --language-only
    var extraArgs: String
    var autoStart: Bool               // 启动 App 时自动起服务
    var launchAtLogin: Bool           // 开机自启
    var hfCache: String               // HF_HUB_CACHE 覆盖，空=默认
    var recentModels: [String]
    func remember(model: String)
    func serveArguments() -> [String]
}
```

## UI 规格（ui-shell）

**状态栏**：`NSStatusItem`（variableLength），SF Symbol `bolt.fill` 作模板图；就绪时在图标右侧显示 `74`（tok/s），启动中显示 `…`，失败显示 `!`。tooltip = `statusText`。

**菜单**（每次状态变化重建，或就地更新标题）：
```
flashCat · <statusText>            (disabled)
<当前模型，超长截断>                (disabled)
──────
启动服务 / 停止服务                (⌘⇧S)
打开聊天页                        (⌘O)   仅 ready 时可用 → http://127.0.0.1:<port>/
复制 API 地址                     (⌘⇧C)  → http://127.0.0.1:<port>/v1
模型 ▸
   ✓ mlx-community/Qwen3.6-35B-A3B-4bit
     mlx-community/Qwen3.8-27B-4bit
     unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M
     unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M
     ──────
     自定义模型…
     最近使用 ▸ (settings.recentModels)
日志…                            (⌘L)
设置…                            (⌘,)
──────
退出 flashCat                    (⌘Q)
```
切换模型时：`settings.model = id`，若在运行则 `controller.restart(model:port:)`。
自定义模型：NSAlert + 文本框，校验 `owner/repo` 或 `owner/repo:VARIANT`（正则 `^[\w.-]+/[\w.-]+(:\w[\w.-]*)?$`）。

**设置窗口**：Liquid Glass 面板，字段=端口、最大内存、最大上下文、额外参数、HF 缓存目录；开关=空闲时保留模型、仅文本、开机自启、启动 App 时自动起服务；按钮=保存/取消。保存后若端口或模型变化且服务在运行 → 重启服务。开机自启用 `SMAppService.mainApp.register()/unregister()`，失败弹 NSAlert 说明（ad-hoc 签名下可能失败）。

**日志窗口**：Liquid Glass 面板，等宽字体 NSTextView（只读、自动滚到底部），按钮=清空/打开日志文件/拷贝全部。窗口不要阻塞退出。

**Liquid Glass 用法**：
```swift
let glass = NSGlassEffectView()
glass.style = .regular            // macOS 26 起可用
glass.cornerRadius = 20
glass.tintColor = NSColor.controlAccentColor.withAlphaComponent(0.08)
glass.contentView = yourContentView
```
窗口配置：`NSPanel`，`styleMask = [.titled, .closable, .fullSizeContentView]`，
`titlebarAppearsTransparent = true`、`backgroundColor = .clear`、`isOpaque = false`、`isMovableByWindowBackground = true`。
`effectIsInteractive` 是 macOS 27 API，若使用必须 `if #available(macOS 27, *)` 包裹。

**App 生命周期**：`applicationDidFinishLaunching` 里 `EngineRuntime.locate()` 失败时弹一次说明性 NSAlert（不要崩）；`applicationShouldTerminate` 里 `controller.stopAndWait()` 后 `.terminateNow`；设置 `autoStart` 为真则启动时自动起服务。

## 构建与自检

```bash
cd /Users/example/zhuo/flashCat/app && swift build -c release   # 编译检查
cd /Users/example/zhuo/flashCat && make app                    # 组装 flashCat.app（packaging 负责）
./dist/flashCat.app/Contents/MacOS/flashCat --verify --port 8011 --max-memory 24G
```

不要执行 `codesign`（lead/packaging 脚本负责）、不要改 `vendor/`、不要动 `~/Library/Application Support/Splash`。
