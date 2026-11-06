---
id: flashcat-app
type: module-design
status: draft
title: FlashCat 应用壳 — 状态与进程编排
parent: flashcat-architecture
depends-on: [flashcat-kit, flashcat-manifest-contract]
---

# FlashCat 应用壳 — 状态与进程编排

## 职责

macOS 壳。它持有全部可变状态，驱动引擎进程，并把自己画成六个原生页面。界面与状态在同一进程、同一语言里，没有网页层。

- **状态中枢。** `AppState`（`@MainActor` 单例）——当前页面、服务状态与统计、模型选择与切换阶段、会话与线程、下载队列、设置、外观、侧栏。表现层的每一帧数据都从它出来。
- **进程编排。** `EngineController` / `EngineManager` / `EngineRuntime` —— 把 pack 清单和 engine descriptor 解析成启动计划、spawn 入口、健康轮询、pid 文件、日志采集、启停与切换。模型 load/unload/rescan 由 descriptor 的 `modelControl` 驱动，状态由多个 telemetry source 合并；Strata 这类特例只允许出现在专用 adapter。
- **装机。** `EngineInstallCenter` —— 读发布索引，串行执行安装（三次安装写同一棵目录树，不能并行）。
- **模型。** `ModelCatalog` / `ModelLibrary` / `ModelInstaller` / `ModelRecommendations` / `ModelDownloadTask` / `LocalEngineModels` / `DeviceProfile` —— 内置目录中的一条模型可以同时标记多个引擎；Splash、oMLX、MTPLX、MLX-Serve 和 Strata 都是平级 engine descriptor。归属靠 `ModelRecommendation.engines`，下载与模型布局按 descriptor 决定。Hub 搜索结果同样可以服务多个兼容引擎。splash 的 DFlash2 draft 随主模型一起下，缺了就在启动前补齐。库是「目录 ∪ 磁盘扫描」：盘上有、这一栏没有的权重照样成行并标「未收录」。
- **对话。** `Chat` / `ChatHistory` / `LocalAPI` —— `URLSession` 流式、usage 与 `finish_reason`、本地历史（上限 6 条）。
- **网关控制。** `GatewayController` 持有网关对象与路由，`GatewayMeter` 打点。
- **外壳与界面。** 窗口与场景、菜单栏面板、状态栏图标、登录项、日志缓冲、外观主题、设计 token，以及六个原生页面（`UI/`，见 [flashcat-ui](UI-SPEC.md)）。

## 边界

- **允许依赖 `FlashCatKit`；Kit 不许反向依赖本模块。**
- **只通过 [manifest 契约](../../../scripts/engines/manifest-template.md) 驱动 pack。** pack 里的 `manifest.json` 之外的文件，应用不解释。
- **表现层就是 SwiftUI 视图。** 六个页面属于 [flashcat-ui](UI-SPEC.md)，只读 `AppState`、只调它的方法；视图不取数、不写盘。
- **只走回环。** 不监听、不连接非本机地址。
- **磁盘布局固定**（清理、备份、支持都依赖它）：

| 内容 | 位置 |
| --- | --- |
| 支持目录 | `~/Library/Application Support/flashCat`（`FLASHCAT_SUPPORT_DIR` 可覆盖，测试与试跑用） |
| pack | `<support>/engines/<id>/<version>`；索引来源 `FLASHCAT_ENGINE_PACKS_DIR` 或 `<support>/packs` |
| 模型 | 所有引擎统一为 `<support>/models/<id>` |
| 日志 | `~/Library/Logs/flashCat/<id>.log`（`FLASHCAT_LOGS_DIR` 可覆盖） |
| pid | `<support>/<id>.pid` |
| 会话与历史 | `<support>/conversation.json`、`<support>/chat-history.json` |

## 本层持有的不变量

- **同一时刻只做一件事。** 一次只跑一个安装（同目录树），一个引擎一次只跑一个切换。
- **换引擎是「先卸载，再启动」。** `EngineManager.activate` 对每台还在跑的引擎 `stopAndWait`：进程退出、端口释放之后才切 `activeID`，调用方随后才允许启动新引擎。`stop()` 只是发信号，旧进程的 Metal 缓冲区还要一会儿才放开；在那之前启动新引擎会让两份权重同时占同一块统一内存。连续换引擎由 `handoffInFlight` 串行，后一次不会去停前一次正要启动的那台。
- **模型跟着引擎走。** 选中的模型属于另一台引擎时，`hopEngine` 走同一条卸载链：先确认旧引擎退出，再切库、选中模型、启动新引擎并等它真的加载完（`waitForSwitchReady`），阶段文案是「停止旧引擎 → 加载新模型」。
- **切换有代号。** 每次切换领一个 `switchGeneration`，只有当代的收尾允许改「切换中」状态。被接管或被取消的旧任务回来时代数已经不同，它静默退出：既不会抹掉新切换的状态，也没人能把界面永久留在「切换中」。
- **切换中的再次选择要排队，不能丢弃。** 切换进行中又选了同一引擎的模型时，排到这次切换之后且只保留最后一次——早期直接丢弃，读者看到的是「点了没反应」；队列只属于当前引擎，换引擎时清空，不能拿 A 的 id 去 B 的目录里找权重。
- **换模型先确认。** 换权重意味着卸下常驻模型、引擎短暂不可用，这值得一次点击，而不是静默停摆。
- **API 请求按 `model` 落到真实权重。** 网关先解析模型归属引擎；同一引擎换模型走热切换/重启，跨引擎走先卸载再启动，引擎未运行则直接拉起。准备完成后才向上游转发，不能把未知模型名原样交给「忽略 model 字段」的引擎。
- **对话线程 id 跟着 `conversation.json` 走。** 线程 id 落在 `UserDefaults` 的 `chat.threadID`，历史保存是原地覆盖而非每轮 insert——早期每轮生成都新建一条线程，同一段对话在侧栏堆成好几份，概览读到的上下文还可能来自旧副本。
- **下载任务的「下载中」在重启后降级为「暂停」。** Hub 的部分文件留在目标目录的 `.cache` 里，暂停或中断的传输能跨进程存活，续传靠这份部分文件，任务行只记录停在哪一步。
- **续传从已有的字节接着算，不从 0 重来。** 暂停时任务行记下已下载字节，继续时 `startDownload` 把它作为进度起点（`downloadResumeBytes`），目录监听只在其上累加新增字节；卡片和下载中心因此始终显示「已下载 / 总量」，百分比在暂停/继续之间连续，速度也不会因为起点归零而先蹦一个假峰值。
- **DFlash2 对用户是隐形的。** splash 的每个模型家族都带一个 draft，它只影响速度、不是一个需要用户挑的模型。下载主模型时一起下；装配里缺 draft（老版本下的，或家族表里认出来的）时，`EngineController.start` 在 `launchPlan` 之前先补齐——`startService`、`restart`、冷切换都经过这一个开闸处。补下走的是下载中心那条链，所以可以暂停、可以取消：用户取消就按无加速启动，补下失败才阻断启动，因为「没有加速」能跑、起不来不能跑。
- **引擎自报的解码速度口径不一致时，用本地口径。** splash 报实时值，oMLX 报开机以来的累计均值（只在请求结束时跳一格）。生成期间概览卡与曲线统一用流式窗口的本地测速，空闲时回落到引擎读数。

## 已知限制

- **这一层没有测试。** `FlashCatKitTests` 全部针对 Kit；`AppState` 的状态机、`EngineController` 的启停与切换、六个页面的交互都没有自动化覆盖。
- **`AppState` 是单一大类**（约 77 KB），界面状态集中在一个 `@MainActor` 对象上。边界靠约定维持，不靠类型系统。
