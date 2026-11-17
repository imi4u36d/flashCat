# 2026-11-16 后端结构与逻辑优化评审

范围：`FlashCatKit`（引擎核心 / Gateway / Control）、应用侧服务层（`AppState` / `EngineController` / `EngineStore` / 客户端）、`ControlServer` 与 CLI 控制面、`scripts/` 发布脚本与 CI。
不包含：`Sources/FlashCat/UI/`、`Design.swift`、`Theme.swift` 等纯 SwiftUI 文件。

评审方式：4 个只读审计并行（Kit 核心、网关与控制面、应用服务层、CLI 与脚本），全部结论都带 `file:line` 证据；随后按互不重叠的写作用域并行落地（见第七节）。

---

## 一、基线数字（2026-11-16，HEAD `352b763`，VERSION 1.5.6）

| 指标 | 值 |
| --- | --- |
| `native/` Swift 总行数 | 52297 |
| `FlashCatKit` | 7414 |
| `Tests` | 8216 |
| `FlashCatCLICore` | 3960 |
| `AppState.swift` | **5014** |
| `AppState` 的 `@Published` | **63**（`grep -c '^    @Published'`；含注释的 `grep -c '@Published'` 是 68） |
| `AppState` 的 `func` 声明 | 163 |
| `AppState` 的 `try?` | 11 |
| `AppState` 的 `Task {` | 36 |
| UI 里 `$state.` 绑定 | **0**（视图全是 `@ObservedObject` 读 `state.x`） |
| 测试 | 253（FlashCatTests）+ 34（CLICoreTests），4 skipped，全绿，约 10s |
| 严格并发基线 | 0 条告警（`native/.strict-concurrency-baseline`） |

`EngineController`、`EngineManager`、`AppState` **零测试**。这是本轮所有"不敢改"的共同原因。

**本轮之后（最终，2026-11-17 第三轮收口）**：`AppState.swift` **795** 行 / `@Published` **0**（全部搬进 9 个 store，见第十一节）；`native/` 共 **201** 个 Swift 文件全部带 SPDX 头；测试 **661** 条（477 → 661）；`swift format lint --strict` 零输出；19 个提交（其中 2 个是纯机械的格式化与 SPDX）。

---

## 二、结构性问题（需要动结构，不是改 bug）

### S-1 同一份"文档"有多个生产者，且已经漂移（P0，本仓最严重）

控制协议里的文档本来是"唯一事实"的载体，实际上被独立实现了多份：

| 文档 | 生产者 | 已漂移 |
| --- | --- | --- |
| 引擎状态 | `ControlServer.engineDocuments`（在线）、`StatusCommand.offlineReport`（离线）、`EnginesCommand.offlineEngines`（离线） | **11 个字段** |
| 配置条目 | `ControlServer.configBindings`（在线）、`OfflineConfig.entries`（离线） | **8 类**，28 行里 12 行永久不同 |
| 网关状态 | `ControlServer.gatewayState`、`StatusCommand`、`GatewayCommand` | 3 份，`failure` 一份有一份无 |
| doctor 报告 | `ControlServer+Documents.doctorDocument`、`DoctorCommand` | 检查项集合不同 |
| 下载摘要 | `ControlServer+Documents.downloadDocuments`、`StatusCommand.localDownloads` | 离线把 `downloading` 改写成 `paused` |

用户可见后果（不是数据缺失，是**另一个答案**）：

- `flashcat status` 在应用运行时显示"运行中 / 实际绑定端口 / 启动阶段"，应用一停全部变成"已停止 / 配置端口"。
- `flashcat engines` 与 `flashcat status` 在同一离线时刻给出**不同的 model**（`EnginesCommand.swift:77` 少了 `selectedModel` 回退）。
- 脚本解析 `--json`：`engine` 会从对象变 null，`gateway.failure` 从字符串变 null，`downloads[].status` 从 `downloading` 变 `paused`。
- `flashcat config set thinkingMode none`：应用在跑时成功，应用关了 `exit 2`。
- `flashcat config list` 里 `engines.omlx.port` 未配置时离线报 **8000**，真实默认是 8100（`normalizedPort` 的 fallback 写死 8000）——最大偏差 400。

根因：这三份实现里，`—` 占位、capabilities 排序、端口回落顺序、"当前引擎"是否 fallback、枚举 token 白名单、数值格式化，全都各写一遍。**字段一多就漂，而且漂了没人发现，因为两份都没有测试。**

### S-2 `AppState` 是一个 5014 行的 God Object（P0，仓库自己已立项）

63 个 `@Published`、163 个方法，同时承担：引擎会话、模型库、下载中心、Hub 浏览、指标采样、偏好、剪贴板/媒体轮次。仓库 2026-11-11 评审的验收口径就是"`AppState.swift` < 400 行、`@Published` < 12，且 EngineSession/ChatSession/DownloadCenter 各有独立测试文件"。

拆分算术（63 → 目标 7）：指标 13、Hub 16、引擎会话 9、模型库 9、下载 5、会话/媒体 4、壳层保留 7。**中途任何一步都不能让 @Published 到 11**，只有全切完才达标。

好消息：UI 里 **0 个 `$state.` 绑定**，所以把 `@Published` 换成转发计算属性不会让视图编译失败——这是"零 SwiftUI 改动"拆分的前提。代价是必须补 `objectWillChange` 桥，否则界面不重绘（目前只有 2 处手动 `objectWillChange.send()`，没有任何子 store 桥）。

依赖边（决定顺序）：
- `DownloadCenter.finishDownload` 结束时要 `applyModel`（模型库）与 `publishShared`（Hub）→ 会成环，必须用 `enum DownloadEvent` 打断。
- `ModelLibraryStore.scanEngineModels` 读 `downloadTasks` 算 "unfinished" → 注入 `unfinishedRepos: () -> Set<String>`。
- `syncController` 里 `if switchingModel != nil { syncSwitchStage() }` 是指标 → 引擎会话的第二条边，必须留在 AppState 薄壳里。

### S-3 `EngineInstaller` 1044 行塞了 9 类职责（P1）

| 行范围 | 职责 | 变更驱动 |
| --- | --- | --- |
| 4-79 | 索引值对象 + 发布语义 | 索引 schema |
| 81-119 | `EngineInstallError` 10 个 case | 错误契约 |
| 178-228 | 部署布局 / 环境变量 | 磁盘布局 |
| 230-249 + 549-751 | tar 输出解析、链接校验、路径逃逸、`stripComponents`、`extract` | **归档格式** |
| 251-358 | 目录布局 | 磁盘布局 |
| 362-547 | install / uninstall / activate / validate 事务 | 安装事务 |
| 755-835 + 918-1044 | 下载 + `RemoteDownloadDelegate` + `PipeCollector` | 传输协议 |
| 840-915 | sha256 / 子进程 | 工具 |

其中 tar/链接校验那 ~240 行是纯函数，却因为和 actor 混在一起而只能整文件测。拆成 `EngineArchiveValidator.swift` 后可独立测试、可复用。

### S-4 `StatusParsers` 734 行里 500 行是 per-engine 分支（P2）

`+Splash` 129-233、`+OMLX` 239-334、`+MTPLX` 340-455、`+OpenAIModels` 462-573、`+Prometheus` 577-649、`+Strata` 653-733。上游任一格式变化都要在 734 行里定位。按引擎拆文件后，一个上游改一次只动一个文件。

同类问题：`EngineTuning` 有 **5 处并列的 per-engine switch**（`defaults` 120-131、`prefixCacheArguments` 关闭档 151-156 与开启档 158-180、`arguments` 197-217、`speculativeMode` 243-…）。CONTRIBUTING 要求"引擎差异只进 descriptor + adapter"，加一个引擎要改 5 处。

### S-5 5 个 `build-*-pack.sh` 有 359 行冗余副本（P1，维护成本 + 行为漂移）

规范化逐行比对：strata 212 行 / omlx 278 / mtplx 266 / splash 246 / mlx-serve 201，共 1203 行；**173 行出现在 ≥2 个脚本，47 行在 5 个脚本里逐字相同**。`omlx ↔ mtplx` 相似度 0.63（mtplx 基本是 omlx 的删减版，`ensure_uv` 30 行逐字相同），`mlx-serve ↔ strata` 0.46。

漂移证据：至少 4 种 JSON 校验写法；只有 2 个脚本调 `fix-pack-rpaths.sh`（`SPEC.md:41` 却写成通用要求）；只有 2 个脚本清 `__pycache__`/`.DS_Store`；5 个 `DEFAULT_VERSION` 全部比 `pack-index.json` 落后一版；`MIN_MACOS` 口径 5 处打架（splash 26.0 vs `build-native-app.sh` 注释的 26.4 vs mlx-serve 26.4 vs strata 15.0 vs mtplx manifest 14.0）；`mtplx` **完全不校验下载**。

### S-6 CLI 的"命令表 / 选项表 / 退出码表"各三份（P2，漂移源头）

- 命令与选项：`CLIArguments.swift:105-114`（groups）、`HelpCommand.swift:23-37`+`:47-58`、`DoctorCommand.swift:156-169`（补全）三张表已经不一致。
- 具体 bug：`CLIArguments.swift:113` 的 logs 组没有 `app`，而 `LogsCommand.swift:97-102` 有 `case "app"`（**不可达**）→ `flashcat logs app` 静默退化成引擎日志；`HelpCommand.swift:123-132` 又把它写进文档。补全表完全没有 logs 组，但 fish 里有——三种 shell 三种事实。
- 退出码：`CLIOutput.swift:6-15`（定义）、`ControlClient.swift:197-208`（HTTP→码）、`HelpCommand.swift:61-70`（文档表格）、`SPEC.md` 四处，已出现"同因不同码"（`GatewayCommand.swift:53` 用 `.failure` 而 `ChatCommand.swift:113` 同类事件用 `.timeout`）。

### S-7 `GatewayMeter`（668 行）放错 target（P2）

它只依赖 Kit 的 `DecodeWindowMeter` / `TokenEstimator` / `JSONValue`，是纯逻辑，却放在 `FlashCat`（macOS 壳），导致 30 个测试落在 `FlashCatTests`。按 CONTRIBUTING 的分层判据它属于 Kit。**它不是** Kit 现有 meter 的重复——Kit 提供采样器，`GatewayMeter` 是网关会话记账层，方向正确。

---

## 三、正确性缺陷（会崩 / 会挂 / 会丢数据 / 会误导）

| ID | 级别 | 位置 | 现象 | 修法 |
| --- | --- | --- | --- | --- |
| C-1 | **P0** | `FlashCatKit/Gateway/GatewayHTTPServer.swift:149-173` | `withCheckedContinuation` 在 `stateUpdateHandler` 里对 `.ready` / `.failed` 各 resume 一次，**无一次性标志**：`.ready` 后再 `.failed` → 二次 resume 崩溃；`.cancelled` 不 resume → 端口被占时 `start/stop/start` 永久挂起（控制面 21 个候选端口循环会踩到） | 加锁 + `resumed` 标志，所有终态恰好 resume 一次；`start` 加超时兜底 |
| C-2 | **P0** | `FlashCatKit/EngineStatus.swift:308-321` | `JSONValue.number` 只有 Double 分支查 `isFinite`；`int = number |> Int` → `{"ttft_ms":"nan"}`、`{"max_tokens":"1e999"}`、`1e20` 会让 `Int(...)` 运行期 trap（等同仓库禁止的 `fatalError`）。输入是引擎 JSON / `--props` 文本，属外部不可信数据 | 所有分支过滤 `isFinite`；`int` 先判范围 |
| C-3 | **P0** | `FlashCatKit/EngineInstaller.swift:370-371、411、477` | `release.version` 未校验字符集就拼进文件路径（`.partial` 名、staging 名、`activate` 的 `root/version`），`EnginePackIndex` 解码（`:56-79`）也不校验。远程索引被劫持给 `"version":"../../../../tmp/x"` → 在归档校验**之前**就写出 packs 目录，且 sha256 取自同一索引，自洽通过 | `FlashCatPaths.isSafeVersion` 白名单 + install 入口与索引解码各校验一次 |
| C-4 | **P0** | `FlashCatKit/EnginePackBuilder.swift:170-173` | `try process.run()` 之后才设 `terminationHandler`：子进程若在此之前退出，continuation 永不 resume → **整个 pack 构建挂死**（无超时、不响应取消） | 先声明 continuation、先赋 handler，再 `run()` |
| C-5 | **P0** | 5 个 `build-*-pack.sh` | 解包/校验**之前**就 `rm -rf "$PACK_DIR"`：解包失败即失去已安装的可用包 | staging 目录 + 校验通过后 `mv` 原子替换 |
| C-6 | **P0** | `scripts/fetch-runtime.sh:24、36` | ① 从不 `mkdir -p vendor`，直接往不存在的目录 `curl -o`；② `tar -xzf "$TARBALL" -O "$ARCHIVE/release.json"` 把带 `.tar.gz` 的文件名当归档内路径（归档只有一个顶层目录），tar 报错被 `2>/dev/null` 吞掉，`set -e` 在赋值处中止，`:38-41` 的版本比较**永远不可达** | 补 `mkdir -p`；`mktemp -d` + `--strip-components=1` 解出 `release.json`；去掉 `2>/dev/null` |
| C-7 | **P1** | `CLIContext` / `StatusCommand` / `DoctorCommand` / `GatewayCommand` / `LogsCommand` / `ChatCommand` / `ModelsCommand` 共 7 处 | `if let location = try? context.control, let x = try? await ...` 把 401（令牌过期）/504/超时全部折叠成"应用没运行"，然后**打印本地旧值并 `exit 0`**。`flashcat doctor` 会拿离线检查冒充诊断结论，这是审计里最会误导人的一类问题 | 抽出 `ControlFallback.shouldFallBack(_:)`（只允许 `.notRunning` 降级），其余 rethrow |
| C-8 | **P1** | `AppState.swift:3891-3894` | 取消判定是 `message.localizedCaseInsensitiveContains("cancel") / ("取消")` 文案匹配；三个错误类型（`ChatError`、`ImageClientError`、`VideoClientError`）都没有 case | 三型各加 `enum Kind` + `isCancellation`，判据改成 `error.isCancellation` |
| C-9 | **P1** | `EngineController.swift:478-484` | `markReady` 只 `guard state != .ready`，**不检查 `process` / `terminating`**：Ready 日志行经 reader Thread → main queue，晚于 `processExited` 回调到达时会变成"`state == .ready` 但进程已死"；`AppState.canChat` 两个条件同时为真 → `send()` 打到死端口 | `guard process != nil, !terminating` |
| C-10 | **P1** | `EngineController.swift:957-969` | 每行日志 `line.lowercased()`，20k 行日志 = 20k 次整串分配；且就绪/错误判定是 `contains("Ready ·")` 之类的裸字符串 | 抽 `EngineLogSignal.detect(_:)`，用 UTF-8 前缀比较 |
| C-11 | **P1** | `ChatHistory.swift:234-246` | `try? JSONEncoder().encode` + `try? data.write` → **静默丢聊天历史**，违反 CONTRIBUTING "错误不许 `try?` 静默吞" | 至少写 `LogStore`，最好在 UI 提示 |
| C-12 | **P1** | `ModelDownloadTask.swift:46-68`、`EngineStore.swift:39-40`、`ImageGallery.swift:write` | 同样的 `try?` 静默吞：下载中心整表静默消失、tuning 静默丢、图库写失败无感 | 同上 |
| C-13 | **P1** | `FlashCatCLICore/CLIContext.swift:144-168` | `engineConfiguration` 解析失败 `try? ... else { return EngineConfiguration() }`，把"读不动"当"空配置"（2026-11-04 评审已点名）。补偿函数 `engineConfigurationIsUnreadable()` 已存在却只能再看一遍文件 | 解析结果缓存为 `Result`，错误里带真实 `DecodingError` 文案 |
| C-14 | **P1** | `EngineInstaller.swift:265-283` | 远程索引**解码失败直接抛错**（`:268`），bundled 索引回落永远走不到 → 一个损坏的远程索引就让应用失去自带索引；而 `fetch` 失败（`:267`）静默 `continue`，最终统一 `indexUnavailable` 无原因 | decode 失败改 `continue`，末尾抛带原因的错 |
| C-15 | P2 | `EngineInstaller.swift:975` | `try? handle?.write` 吞 ENOSPC/EIO，仍累加 `received` → 磁盘满时"下载成功"，最终报 `checksumMismatch`（误导），真实原因不可见 | 捕获写错误 → `finish(error:)` |
| C-16 | P2 | `EngineInstaller.swift:795-798`、`362-448` | `AsyncThrowingStream` 无 `onTermination`，消费任务取消时 `URLSession` 不 cancel → 后台继续写 `.partial` + 循环引用；`install` 全程无 `Task.isCancelled` | `onTermination` 取消 + 关键点 `checkCancellation` |
| C-17 | P2 | `EngineInstaller.swift:362-448` | actor 在 `await download` 处可重入：同 id+version 两次 `install` 会同时写同一 `.partial`，各自 `activate` | actor 内 `inFlight: Set` 守卫 |
| C-18 | P2 | `GatewayHTTPServer.swift:278` | 完全不认 `Transfer-Encoding: chunked`：body 被当 0 字节 → 上层报"请求体需要 model 字段"（误导）；网关还会先 `prepareModelForGateway(nil)`（可能拉起模型）再 400 | 明确 400 unsupported，或真正解析 |
| C-19 | P2 | `GatewayHTTPServer.swift:254-300` | head 无大小上限（本机任意进程可发无限长 header）；畸形请求（空 method / 请求行不足两段）当 404 而不是 400；不认 `Expect: 100-continue` | 64KB 上限 + 400 + 100-continue |
| C-20 | P2 | `GatewayController.swift:339、347、354` | 三处 `where !session.write(frame) { return }` 早退**不调 `GatewayMeter.finish`** → 会话永不收尾：`isLive` 永远 true、曲线不冻结、`sessionLimit` 满后挤掉在跑会话 | `defer { finish(meterID) }`（`finish` 已幂等） |
| C-21 | P2 | `GatewayUpstream.swift:25-75` | 三个入口 `catch { return nil }`，无法区分"引擎没起 / 超时 / 连接被拒"，上层统一 503 且无日志 | 可区分错误 + 记日志 |
| C-22 | P2 | `GatewayHTTPServer.swift:343-371` | SSE 结束用 `try? await Task.sleep(80ms)` 再 `cancel()`，尾帧可能在队列里被丢 | 等最后一次 `send` 的 completion |
| C-23 | P2 | `ControlServer+Documents.swift:514-517` + `AppState.swift:1658-1666` | `engines.<id>.port` 写入：引擎未安装时 `switchEnginePort` 首行 `guard let controller else { return }` 静默 no-op，`setConfig` 仍返回 200 旧值 | 返回 `Bool`，false → 409 |
| C-24 | P2 | `EngineController.swift:1416-1455` | `preferredPort` 不校验范围：`engines.json` 里 `port = 0` / 负数原样作为 `--port` 传下去（0 让引擎自选端口 → 读写状态撕裂） | 校验 `descriptor.portRange` |
| C-25 | P2 | `ControlServer.swift:109-117` | `stop()` 用 `try? removeItem(control.json)`，残留旧 token 文件 → 下个 CLI 连旧端口得 401 并提示"重启 flashCat" | 失败写日志 |
| C-26 | P2 | `EnginePackBuilder.swift:222-233` | `_LineBuffer.consume` 在 UTF-8 多字节被 read 边界切断时整块丢弃 → 中文输出丢行 | 累积 `Data` 按边界补完 |
| C-27 | P3 | `EngineInstaller.swift:720-731` | `stripComponents` 对"单条目平铺归档"返回 1 → 解出空目录 → 报"无法解码 manifest" | 单层文件条目返回 0 |
| C-28 | P3 | `EngineStatus.swift:326-333` | `bool` 对未知字符串返回 `false` 而非 `nil`，"未知"被当"明确关闭" | 返回 nil |
| C-29 | P3 | `EnginePackBuilder.swift:72、78` | `id.rawValue` 未加引号拼进 `bash -lc` | 白名单或单引号 |
| C-30 | P3 | `ChatCommand.swift:58-77` | `FileHandle.standardInput.readDataToEndOfFile()` 无超时无上限、且绕过注入 → 接不关闭的管道**永久挂住**，该路径也永远无法单测 | 注入 stdin + 上限 |
| C-31 | P3 | 全仓 | 无 `signal(SIGPIPE, SIG_IGN)`，`CLIOutput` 写失败无处理 → `flashcat chat ... \| head -1` 以 141 结束或抛异常污染 stderr | 忽略 SIGPIPE + 静默退出 |
| C-32 | P3 | `CLIHTTP.swift:7-14` | 每次请求新建 `URLSession(.ephemeral)` 且从不 invalidate → `status --watch` / `logs --follow` 每秒新建 session | 共享 session |
| C-33 | P3 | `LogsCommand.swift:178-183` | `FileManager.contents(atPath:)` 全量读日志，`-n 200` 也要把 GB 级文件读进内存 | 只读文件尾 |
| C-34 | P3 | `fix-pack-rpaths.sh:19` | `PACK="$(cd "${1:-}" && pwd)"` 无参时 `cd ""` 在 `set -e` 下以 1 退出 → `:20-23` 的 usage（exit 2）**永远不可达** | 先判参数个数 |
| C-35 | P3 | `GatewayController.swift:85-88` | `/v1/models/<id>` 只 `dropFirst` 不 `removingPercentEncoding` → 含 `%2F` 的 id 查不到 | 解码后再查 |

---

## 四、业务规则长在读状态路径上（P1，结构 + 性能双重）

| 位置 | 问题 | 该去的地方 |
| --- | --- | --- |
| `AppState.swift:1085-1132` | 每秒执行：`logs.snapshot(limit: 4000)`（有新行就复制最多 4000 元素）、6 次 `GatewayMeter` 加锁读、acceptance 采样**三条件决策**（`due` 0.9s / `changed` 1e-4 / `rateMoving` 0.15）、两个 `removeAll { $0.at < now - 600 }` 每秒 O(n) 扫描。**"什么时候落一个点"这种业务规则不该在每秒快照路径里**，而且不可测 | `AcceptanceSampler`（纯 struct，`mutating func offer(value:reportedRate:now:) -> Bool`）+ 定长环形缓冲 |
| `AppState.swift:573-599`、`:647-659` | `modelContextWindow` / `contextWindowCeiling` 是**计算属性**，却分别在 `:591`、`:638` 往 `UserDefaults` **写**。读路径带磁盘副作用，每帧可能触发 | `struct ContextWindowMemory`，只由 `applyModel` / `send` 显式 `remember` |
| `EngineController.swift:195-208` | `downloadProgress` 按 `logs.latestId` 缓存、扫 `logs.tail(40)` 正则抓百分数 —— 这是下载中心的活，寄居在引擎控制器里 | `DownloadCenter`（它已经解析 TOTAL/百分比） |
| `AppState.swift:158` + `:705-720` | `lifecycleTick` 是个"每 tick 变一次的整数"，唯一用途是制造 SwiftUI 依赖，导致 `engineStageText` 每次重绘重算字符串 | 每 tick 算一次成品字符串，值变了才发 |
| `AppState.swift:686-700` | `isModelBusy` / `canChat` / `isReady` / `engineStageText` 各自重解一遍"现在能不能用" | 单一 `phase` 的派生 |
| `AppState.swift:4704-4749` + `ModelInstaller.swift:457-471` | 下载监视每 500ms 对下载目录做 `FileManager.enumerator` + **逐文件 `attributesOfItem`**；300GB 多分片仓库 = 每 tick 数千次 stat × 目录数。而下载器本身已经在打印百分比 | 优先用解析出的进度，磁盘扫描降级为兜底并拉到 2s |

---

## 五、性能清单（P0-P2）

| 级别 | 位置 | 问题 |
| --- | --- | --- |
| P0 | `AppState.swift:1085-1132` | 每秒固定开销：4000 元素数组复制 + 6 次加锁 + 2 次 O(n) 扫描 |
| P0 | `AppState.swift:4704-4749` | 下载监视每 500ms 全盘递归 stat |
| P1 | `EngineInstaller.swift:406、409、414` | **同一归档完整解压三遍**（`tar -tzf` + `tar -tvzf` + `tar -xzf`），600MB pack 每次安装多解两遍 |
| P1 | `EngineInstaller.swift:591、616` | 链接解析 O(链接行 × 条目数 × 名字长)：数千条目 × 数百软链 → 数百万次 `hasSuffix` |
| P2 | `ControlServer.swift:294-323` | 每次 `/v1/status` 每引擎调 `EngineInstallations.newest` + `installed`（各扫 5 个搜索根）= **10 次目录扫描**；`status --watch` 每秒一次 |
| P2 | `GatewayController.swift:122-136` | 每个网关请求都走主 actor 的 `prepareModelForGateway`，网关吞吐上限 = 主 actor 串行 |
| P2 | `HuggingFace.swift:401` | `cache: [String: HubModel]` 无上限，每次搜索 enrich ≤50 个 repo（每个带全文件表）→ 搜索 100 次常驻几十 MB |
| P2 | `FlashCatPaths.swift:82-86`、`EngineCore.swift:301-310`、`SplashDraft.swift:55` | 三处正则**每次调用现场编译**（`EngineTemplate.matches` 还被逐参数调用） |
| P2 | `ChatHistory.swift:234-246` | 主线程把**所有线程的所有消息**映射成 26 字段 DTO，只有 encode+write 在后台队列 |
| P2 | `ImageGallery.swift` | `visible()` 每次重绘对每条记录 `fileExists`（500 张图 = 500 次 main 线程 stat） |
| P3 | `LogStore.swift:40-150` | 三个日志文件从不 rotate；`openFile()` 每次启动 `String(contentsOfFile:)` 全量读入再截尾 |
| P3 | `AppState.swift:1504-1527` | 一次下载完成触发 7-13 次目录遍历（`ModelSharing.scan` + 每引擎 `LocalEngineModels.scan` + `refreshLocalRepos` 再扫一遍） |

---

## 六、有意设计：不要动（会误报为"问题"）

- **`ControlJSON` 每次新建 coder**（`ControlProtocol.swift:98-113`）：`JSONEncoder` 是可变引用类型，按调用创建换来两端日期策略一致。不是性能问题。
- **`DecodeRateMeter` 与 `DecodeWindowMeter` 并存**：两个估计器分工在 SPEC 里写明，不合并。
- **`EngineCore` 的开放值设计**：`EngineID` / `EngineCapability` 用 `RawRepresentable` 而非 enum，未知引擎要能降级。
- **`EngineTemplate.unresolvedPlaceholders`**（`EngineCore.swift:270`）：显式报告残留占位符，是特性不是遗漏。
- **`EnginePackOwnership` 的路径分量比较**：不要换成 `standardizedFileURL` 前缀比较。
- **CLI 输出契约**：结果 stdout、进度 stderr、固定退出码、`--json` 时 stdout 无杂讯。`CLIFormat.bytes` 是二进制单位且属"文档化输出契约"，改单位要显式发版。
- **网关不鉴权**（默认 9000，仅回环）：SPEC 有意。但建议在 README 与 health 响应里显式写明"仅回环、无鉴权，勿在共享机器上开"。

---

## 七、已落地的改动（第一轮：四个 P0 面）

**第一轮统计**：47 个已跟踪文件改动（+2816 / −1672）、18 个新文件；测试方法 477 → **594**（+117）；`try?` 净减 37 处（新增 3、删除 40）；`AppState.swift` 5014 → **4495** 行、`@Published` 63 → **50**。第二轮在其上继续，见第八节。

**验证（本机实跑，全部通过）**

| 门禁 | 命令 | 结果 |
| --- | --- | --- |
| 全量构建 | `swift build --build-tests --disable-sandbox` | Build complete（仅 3 条既有测试告警，位于未改动的 `ImageToolTests.swift`，CI 不编译测试，不阻塞） |
| CI 硬门禁 1 | `swift build -Xswiftc -warnings-as-errors`（全新 scratch `.build-wae`） | Build complete，零 error |
| CI 硬门禁 2 | `swift build -Xswiftc -strict-concurrency=complete`（全新 scratch） | 警告计数 **0**（基线 0） |
| 测试 | `swift test --disable-sandbox` | Kit 307 / App 216 / CLI 71，**0 failure**（4 skipped 为既有环境跳过） |
| 脚本 | `bash -n` 15 个脚本 + `lib-pack-selftest.sh` + `runtime/*.py` 语法 | 15 OK / 29 passed / 2 files OK |

### T1 文档单一来源（P0）

新增 `native/Sources/FlashCatKit/Control/ControlEngineDocuments.swift`（102 行）、`ControlConfigGrammar.swift`（146 行）。

- `ControlEngineDocumentInput` + `ControlEngineDocuments.engine/engines/primary/port/model`：端口优先级「真实绑定 > 用户配置 > 引擎默认」、model 的 active→`lastModel` 回退、`—` 占位、capabilities 排序全部收成一份。`primary()` 把「active 优先，否则第一个」也收成一份。
- `ControlConfigGrammar`：28 个配置键的 kind / mutable / 范围 / token 白名单唯一。CLI 的 `normalizedPort`、App 侧的 `ConfigError` / `parseBool` / `parseInt` / `parseDouble` / `runState` 全部删除。
- 修掉的用户可见漂移：`flashcat engines` 离线缺 `lastModel` 回退；`config set thinkingMode none` 在线成功离线被拒；`engines.omlx.port` 未配置时离线显示 **8000** 而真实默认 8100（差 400）；根 `port` 配成 0 时在线显示 "0"。
- 端到端对照（本机）：`flashcat status --json` 在线与「指向死端口的离线」两次输出的 `engines[]` **字段集合完全一致**。残余字段值差异（`stage` 在线 `已停止` / 离线空串；`installedVersions` 在线只给 newest / 离线给全部已装版本）来自**在线侧跑的还是本机已安装的旧二进制**（`/Applications/flashCat.app`，pid 28690），要彻底验证在线侧需重新打包启动 App；两份规则的等价性由 `ControlEngineDocumentsTests`(16) + `ControlConfigGrammarTests`(15) + `OfflineConfigTests`(13) 钉住。
- CLI 侧还删掉了 8 处 `try?` 静默降级（`ConfigCommand.swift` 3 处、`EnginesCommand.swift` 4 处 + 1 处判据换 `ControlFallback`），只保留 `EnginesCommand.reloadApp` 一处刻意的 best-effort 并写明原因。

### T2 网关 HTTP 硬化（P0）

- `ResumeOnce` 门控续体 + 2 s 兜底：`.ready` / `.failed` / `.cancelled` / `.waiting` 各恰好唤醒一次 —— 修掉**二次 resume 崩溃**与**端口被占后 `start` 永久挂起**。
- `maximumHeadBytes = 64 KiB`；畸形请求（非 UTF-8 / 请求行不足两段 / 空 method）→ 400；`Transfer-Encoding: chunked` → 400（不再把 body 当 0 字节，从而不再先拉起模型再报"请求体需要 model"）；`Expect: 100-continue` → 回 100 行。
- SSE 收尾改为等最后一次 `contentProcessed`（`session.flush(timeout:)`），删掉 80 ms sleep 竞态。
- `GatewayUpstream` 三入口改 `Result` + `GatewayUpstreamError`（`notReachable` 503 / `timedOut` 504 / `transport` 502，中文 message 写进 `gateway.log`），不再全部折叠成 503。
- `GatewayController` 三处 `session.write` 早退改用 `defer finish`，会话不再泄漏（`finish` 幂等，迟到 `failed: true` 仍会结算）。
- 测试 +9，含 `testServerCanRestartOnSamePort`。

### T3 Kit 正确性（P0 / P1）

- `EngineStatus.JSONValue`：所有 `case` 过滤 `isFinite`，`int` 改 `Int(exactly:)` —— `{"ttft_ms":"nan"}`、`1e999`、`1e20` 不再运行期 trap。
- `FlashCatPaths.isSafeVersion`（白名单 + 长度 + 禁 `..`），索引解码与 `install` 入口各校验一次 —— 远程索引被劫持写不出 packs 目录。
- `EnginePackBuilder`：先声明 continuation、先赋 `terminationHandler`、再 `run()`；`_LineBuffer` 改按 `\n` 切 `Data`，UTF-8 多字节被 read 边界切断时不再整块丢行。
- `loadIndex`：远程解码失败改逐条记原因并回落 bundled（新增 `indexUnavailable(reason:)`、`versionInvalid`）—— 一个坏索引不再让应用失去自带索引。
- `stripComponents`：单层平铺的单文件归档返回 0。
- 测试 +457 行 / +9 例。

### T4 CLI 契约（P1）

- 新增 `ControlFallback.shouldFallBack`（**只允许 `.notRunning` 降级**），7 个文件 13 处 `try?` 折叠改 `do/catch`：401 / 504 / 超时 / 令牌过期不再被当成"应用没运行"然后 `exit 0` 打印旧值。
- `CLI.swift`：删 `rawJSON`（与 `invocation.flag("json")` 的双判定收成一处）、入口 `signal(SIGPIPE, SIG_IGN)`、参数错误改用已构造的 `context.output` 报告（`--json/--quiet/--no-color` 生效）。
- `CLIHTTP.shared` 共享 `URLSession`（`status --watch` 不再每秒新建 session）。
- `LogsCommand` 尾部 64 KiB 分块倒读，`-n 200` 不再把 GB 级日志读进内存。
- `CLIArguments` 布尔归一（`--json=false`、`--json true`、`-jq` 都落 flags，`--json status` 不吞子命令）+ 容错解析；`ControlClient.decode/exitCode` 放开 internal，补表驱动测试（400→2 / 401→7 / 404→4 / 504→5 / 409→6 / 500→1 / 200→0）。
- CLI 测试 34 → **71**。

### T5 脚本与 CI（P0 / P1）

- 新增 `scripts/engines/lib-pack.sh`（303 行）与 `lib-pack-selftest.sh`（334 行 / 29 用例）。
- 5 个 `build-*-pack.sh` 1203 → 1105 行，全部 `source lib-pack.sh`，改为「解到 `$PACK_DIR.new.$$` → 全部校验 → 原子 swap」：**先删后装变成失败保留已装包**，实测旧包逐字节保留、零 `.new.*` / `.old.*` 残留。
- `fetch-runtime.sh`：补 `mkdir -p vendor`、改 `mktemp -d` + `tar ... '*/release.json'`、去掉 `2>/dev/null` —— 版本比较不再是不可达代码。
- `fix-pack-rpaths.sh`：先校验参数（usage 分支可达）、改 Mach-O magic 探测（实测多修 1 个无后缀 `python3.13`）、二次运行幂等。
- CI 新增 fail-fast step：`bash -n` 全脚本 + `py_compile runtime/*.py` + `lib-pack-selftest.sh`。
- 顺带修掉首跑 uv bootstrap 污染 `$UV` 的真 bug（HEAD 首跑 rc=1）。

### T6 AppState 抽 `MetricsStore`（P1，God Object 第一刀）

- 新增 `native/Sources/FlashCat/MetricsStore.swift`（713 行）：5 个指标类型 + 13 个 `@Published` + 约 470 行指标管线；`syncController` 收成一个 `metrics.tick(now:stats:isRunning:activeEngine:)`。
- `AppState.swift` 5014 → **4495** 行、`@Published` 63 → **50**；12 个一行转发 + 7 个 `nonisolated static` 转发让 `CacheHitTests` / `DecodeRateTotalTests` 原样通过。
- `objectWillChange` 桥：`metricsBridge = metrics.objectWillChange.sink { self?.objectWillChange.send() }` —— 这是「UI 零改动」成立的前提（本仓 UI 里没有任何 `$state.` 绑定）。
- 新增 `MetricsStoreTests` 18 例；App 侧 `FlashCatTests` 全量 216 条通过。

### T7 取消语义与引擎信号（P1 + 我接力的收尾）

- `ChatError` / `ImageClientError` / `VideoClientError` 各加 `enum Kind` 与 `isCancellation`（`Error, Equatable, Sendable`），构造点 6 + 9 + 17 处全部改用具名 kind；`init(message:)` 一律 `.transport`，**不再按文案猜取消**。
- `EngineLogSignal` 用 `line.utf8` 字节视图判定 `Ready ·` / `Error ·` / 行首 `error:`，普通行零分配；**从 `FlashCat` 移到 `FlashCatKit` 并公开**，于是应用（`EngineController`、`LogStore`）与 CLI（`LogsCommand` 着色）现在共用同一份 marker 定义。
- `EngineController.markReady` 加 `guard process != nil, !terminating`（迟到信号打 warning 后丢弃），修掉「`state == .ready` 但进程已死」。
- 我接力的收尾：`AppState` 四处调用点改 `error.isCancellation`、删掉 `isCancellation(_:)` 里的 `localizedCaseInsensitiveContains`；`LogStore.classify` / `LogsCommand.classify` 改为先问 `EngineLogSignal`（那两处 `lowercased()` + `contains("Ready ·")` 是第三、第四份重复）；`MetricsStore.speedOrigin` 的 `gatewayAge!` 改成 `map ?? true`。
- 新增 `EngineLogSignalTests`(7) + `ChatCancellationTests`(6)；判定边界钉住「认什么」也钉住「不认什么」。

---

## 八、已落地的改动（第二轮：把剩下的 P0/P1 清完）

第一轮结束时仍挂在 P0/P1 上的四件事（AppState 剩下的五刀、EngineController 的十个布尔、Kit 的三处结构性分支、GatewayMeter 放错 target + CLI 三张表），这一轮全部落地；另外补上了两处遗留 `try?`、全仓格式化、SPDX 与 CI 门禁。

**第二轮统计**：语义改动 93 个路径（+11163 / −4370，含 32 个新文件）；此后两个纯机械提交：格式化 188 个文件（+8847 / −6117，仅空白与换行）、SPDX 头 201 个文件（+603）；合计 212 个路径。测试方法 594 → **636**。

### T8 AppState 续拆六个 store（P0）

| 刀 | store | `@Published` | AppState 行数 |
| --- | --- | --- | --- |
| 起点（第一轮后） | `MetricsStore` | 50 | 4495 |
| ① 下载队列 | `DownloadCenter`（605 行） | 45 | 4120 |
| ② Hub 搜索 | `HubStore`（208 行） | 30 | ~4050 |
| ③ 模型库 | `ModelLibraryStore`（45 行） | 21 | ~4030 |
| ④ 引擎会话 | `EngineSessionStore`（41 行） | 12 | 4020 |
| ⑤ 对话会话 | `ChatSessionStore`（28 行） | **8** | 4020 |

- 最终 `grep -c '^    @Published' native/Sources/FlashCat/AppState.swift` = **8**（section / showsLaunchPage / logs / notice / islandNotice / islandNotices / islandUnread / showsSidebar），`wc -l` = 4208（SPDX 与格式化各加数行）。
- 六个 store 都是 `@MainActor final class …: ObservableObject`，AppState 里 `let xxx = XxxStore()` + 同名转发 + `xxx.objectWillChange.sink { self?.objectWillChange.send() }`；UI 一行未改（视图原本就只读 `state.x`，没有一个 `$state.` 绑定）。
- 依赖环用两种方式打断：下载完成要 `applyModel` / `publishShared` → `enum DownloadEvent` + 回调回 AppState；store 要写日志/提示 → 注入 `Hooks`，替掉原来的 `downloadTasks.didSet` 副作用。
- 顺带修掉两处读路径污染：`modelContextWindow` 的 getter 里不再写 `UserDefaults`（改成显式 `rememberContextWindows()` 写点，引擎窗口用独立 key `contextWindowEngine.`，不再覆盖模型自身的窗口记录）；下载监视 500 ms → 1 s，且只 stat 仍存在的目录，删除失败改记 `LogStore`。
- **仍未切**：`// MARK: chat` 段（约 1560 行）留在 AppState —— 流式生成循环、工具调用、取消/重试与 `switchingModel != nil { syncSwitchStage() }` 这条边交织，且成员大量 `private`。这是 AppState 回不到 400 行以下的唯一原因，也是下一轮唯一的一刀。

### T9 EngineController 收敛成单一 Phase（P0）

- `enum Phase`：`idle / installing / starting(since:) / loading / ready / stopping(since:) / stopped / failed(reason:) / terminating`，自带 `serverState` 与 `busySince`。
- 26 条生命周期写语句 → **1 条** `phase = next`（只在 `transition(to:)` 内），11 个具名调用点；越界迁移记 `"==> 忽略非法的状态迁移…"` warning 并拒绝（返回 false）。
- `state` / `isReady` / `isStopping` / `isLaunching` / `busySince` 全部改成从 `phase` 派生的计算属性，**AppState / ControlServer / UI / EngineManager 零改动**。`isRunning` 仍看进程句柄（`.failed` 可能还留着活进程，用户要能点停止）。
- 新增 `EngineControllerPhaseTests` 10 例（假引擎 + 闸门文件控就绪，不拉真引擎）；实测拦住的例子：`.ready` 要求 `process != nil` 且只能来自 starting/loading，所以忽略 SIGINT 的引擎在「停止中」再喊 `Ready ·` 会被拒并留日志。
- 顺带：`markReady` 加 `guard process != nil, !terminating`（SIGKILL 后迟到的就绪信号不再把死控制器标成 ready，改为 warning 丢弃）；`prepareForTermination()` 在真有进程时迁 `.terminating`。

### T10 Kit 结构拆分（P1）

- 新增 `EngineArchiveValidator.swift`（221 行）：tar 条目模型（`ArchiveLink`/`ArchiveInspection`）+ 链接校验 + `stripComponents` + `staysInsideRoot`。`EngineInstaller.swift` **1101 → 928 行**，只剩 tar 调用、Process runner、xattr、下载/索引/激活/卸载；`install()` 改成先 `inspect` 一次拿到 strip 与 links，不再对同一归档解压两遍。
- `StatusParsers.swift` **734 → 294 行**：per-engine 的 500 行 if/switch 变成 `EngineStatusDialects.swift`（905 行）里的声明式方言表 —— 每个 `EngineTelemetryFormat` 一行（拉哪些文档、按什么格式解析、怎么收尾），核心只查表；未知格式返回「只有状态」的空快照。文件里再无 `switch/if …adapter`、`engine ==`。
- `EngineTuning.swift` 413 → 484 行：五处并列 switch 与写死的 `["splash","omlx"]` 收进 `EngineTuningProfile` 表 + `resolved(for:)`。
- 新增 `EngineDescriptorConformanceTests`（7 条）：descriptor 的 adapter 在方言表与调优表里都要有行、默认端口落在自己的段内、仓库索引 `defaultVersion` 非空，外加一条假 adapter（`teleportation`）的负向断言 —— 以后新增引擎忘了登记会直接红。
- 既有测试一行未改即全绿（`EngineInstallerTests` / `StatusParserTests` / `EngineTuningTests`）。

### T11 计量数学下沉 Kit + CLI 表单单一来源（P1）

- `native/Sources/FlashCatKit/Meter/GatewayMetrics.swift`（148 行，值类型）+ `Meter/GatewaySessionMeter.swift`（589 行，`@unchecked Sendable` 记账类）。App 侧 `GatewayMeter.swift` **668 → 15 行**，只剩 `typealias GatewayMeter = GatewaySessionMeter`，UI / AppState / MetricsStore / GatewayController 一行未改；四个 `public typealias` 保留原来的嵌套类型名。
- 新增 `native/Sources/FlashCatCLICore/CLICommandTable.swift`（548 行）：命令清单 + summary + 选项 + 退出码 + 24 条 `ControlRoute` 归属。`HelpCommand` 223 → 148 行（概览/主题页/退出码三张列表都由表生成）、`CLIArguments` 的 7 张硬编码选项表归零、`ControlClient.exitCode` 与补全词表也来自表；`CLICommandTableTests`(14) 用 `ControlRoute.parse` 反查做穷举覆盖。
- `CLIContext.engineConfiguration` 不再 `try?` 当空配置：新增 `EngineConfigurationReadout{configuration, warning}`，区分「文件不存在（无警告）/ 读不出来 / JSON 解析失败 / 顶层不是对象」，警告带路径与原因；`status --json`、`config list|get|unset --json` 带 `warnings` 字段，人类可读走 stderr，退出码不变。
- 测试：`FlashCatCLICoreTests` 71 → **96**；`GatewayMeterTests` 33 全绿（未改一行）。

### T12 Gateway 模块注释中文化（P2）

`Gateway/` 是唯一整块英文注释的区域（243 行）。四个文件译了 81 块注释、MARK 锚点保留英文并加中文括注；顺带纠正 8 处与新行为不符的描述，例如：body 超限实际回 413 而不是笼统的「拒绝」；`anthropicType(for:)` 并不处理状态码（由调用方沿用上游 status）；token 估算与聊天页取整方式不同（小数权重 vs 整数截断、图片 1000 vs 1024），结果不会相等。已用「改前快照 + 剔除注释行逐行比对」证明代码零改动。

### 我在集成阶段自己做的收尾

- `ChatHistory.swift` 三处 `try?` 静默吞（线程列表、对话记录、清空）改为注入 `onWriteFailure` 回调 + `do/catch`，由 AppState 接到引擎日志（无引擎时退网关日志）—— 历史与对话记录是用户找回上一轮回答的唯一途径。
- `EngineLogSignal` 从 App 移进 `FlashCatKit` 并公开（marker 与位置是引擎侧知识），`LogStore.classify` 与 CLI 的 `classify` 都改调它，全仓 marker 定义从 4 份收成 1 份。
- `AppState` 取消判据接线：四处 `isCancellation(error)` → `error.isCancellation`，删除按文案猜的 helper；图像轮次改 `error.isCancellation || Task.isCancelled`。
- 四处 lint 遗留：三处常量 URL 的 force unwrap 收进 `ConstantURL.make`（Swift 没有不会失败的字符串转 URL 构造器）、`[ModelInfo]()` 改字面量、`proc_pidpath` 的 silgen 绑定在 Swift 侧改小驼峰、`R`/`W` 单字母参数改名。
- 全仓 `swift format --in-place`（7348 → 0）、201 个文件加 SPDX 头、CI 的 format job 从 advisory 升为硬门禁（`swift format lint --strict`）、`scripts/engines/README.md` 补 lib-pack 与 staging 语义。

### 本轮最终门禁（本机实跑）

| 门禁 | 命令 | 结果 |
| --- | --- | --- |
| 全量构建 | `swift build --build-tests --disable-sandbox` | Build complete |
| CI 硬门禁 1 | `swift build -Xswiftc -warnings-as-errors`（全新 scratch，240 个编译任务） | Build complete，零 error |
| CI 硬门禁 2 | `swift build -Xswiftc -strict-concurrency=complete`（全新 scratch） | 警告计数 **0**（基线 0） |
| 测试 | `swift test --disable-sandbox` | Kit **314** / App **226** / CLI **96** = **636**，0 failure（4 skipped 为既有环境跳过） |
| 格式 | `swift format lint --strict --recursive Sources Tests` | **零输出，退出码 0** |
| 脚本 | `bash -n` 15 个脚本 + `lib-pack-selftest.sh` + `runtime/*.py` 语法 | 15 OK / 29 passed / 2 files OK |

## 九、修正后的验收口径（下一轮可直接用）

2026-11-11 评审的第四节里有两条口径**当前不可能通过**，建议改成下面这样：

1. ~~`grep -c "@Published" AppState.swift` < 12~~ → `grep -c '^    @Published' native/Sources/FlashCat/AppState.swift` < 12（原口径把 5 行注释也算进去了，68 vs 真实 63）。
2. ~~`grep -rn '"cancel"\|"取消"' Sources/` 为空~~ → UI 按钮标题（`UI/ConsoleShell.swift:87/94/100/106` 等 7 处）与协议解析（`ControlProtocol.swift:522 case "cancel": return .downloadCancel`）永远会命中。改成四条限定检查：
   ```bash
   grep -rn 'localizedCaseInsensitiveContains' native/Sources/FlashCat --include=*.swift   # 空
   grep -rn '"已取消"' native/Sources/FlashCat --include=*.swift | grep -v '/UI/'          # 空
   grep -rn 'ChatError(message:' native/Sources/FlashCat --include=*.swift | wc -l         # 0
   grep -rn 'ImageClientError(message:\|VideoClientError(message:' native/Sources/FlashCat # 仅 init 内部
   ```
3. AppState < 400 行要附**推进算术**（63 → 50 → 45 → 29 → 20 → 11 → 7），否则中途任何一步都达不到 `< 12`。
4. "EngineSession/ChatSession/DownloadCenter 各有独立测试文件"要附**不可回归名单**：`CacheHitTests`、`DecodeRateTotalTests`、`GatewayMeterTests`、`BackgroundMathTests`、`ChatStopTests`、`ChatClientTests`、`ModelLibraryTests`、`EnginePreferenceTests`、`ImageStoreEncodingTests`。
5. 新增一条：`bash -n scripts/*.sh scripts/engines/*.sh` 与 `python3 -m py_compile runtime/*.py` 进 CI（当前完全没有 shell / python 静态门禁）。

### 本轮对第四节清单的进度

| 2026-11-11 的验收项 | 本轮状态 |
| --- | --- |
| `AppState.swift` < 400 行、`@Published` < 12 | **已推平到装配根**（第三轮 T13~T16）：`grep -c '^    @Published'` = **0**（63 → 8 → 0），行数 5014 → 4255 → **795**。剩下的 795 行里约 330 行是点名保留的稳定转发面（`指标转发` / `纯函数转发` / 各段一行转发），自有内容约 470 行；再往 400 压要让 View 改订阅方式，属产品决策而非重构 |
| `EngineSession` / `ChatSession` / `DownloadCenter` 各有独立测试文件 | **部分达成**：三者都已是独立 store（`EngineSessionStore.swift` 41 行、`ChatSessionStore.swift` 28 行、`DownloadCenter.swift` 605 行），行为由既有 226 条 App 测试兜住（含 `ChatStopTests`、`ChatCancellationTests`、`EnginePreferenceTests`、`ModelLibraryTests`），但 store 级独立测试文件还没建 |
| 取消不靠字符串 | **达标**：`grep -rn 'contains("cancel"\|contains("取消")' native/Sources/` = **0**；判据只剩 `error.isCancellation`（`ChatError` / `ImageClientError` / `VideoClientError` 三型都有 `enum Kind`）。残余的 `"已取消"` 全是构造点上已显式给出 `kind: .cancelled` 的用户可见文案；`UI/LogsPage.swift:331` 的 `localizedCaseInsensitiveContains` 是日志搜索，与取消无关 |
| `EngineController` 只有一个 `phase` 属性 | **达标**：`private(set) var phase: Phase`，26 条生命周期写语句收敛成 1 条，`state` / `isReady` / `isStopping` / `isLaunching` / `busySince` 全部派生，调用方零改动，新增 10 条测试 |
| 离线文档与在线文档同源 | **达标**：引擎文档与配置文档都只经 `ControlEngineDocuments` / `ControlConfigGrammar`，CLI 与 App 都只取数 |
| `swift-format lint --recursive Sources Tests` 零输出 | **达标**：7348 → **0**，`--strict` 退出码 0，并已升为 CI 硬门禁 |

### 这一轮新发现的下一轮口径

1. `native/Sources/FlashCat/AppState.swift` 的 chat 段拆成 `ChatSession`（流式循环 + 工具调用）与 `ChatTurn`（单轮状态），目标 < 1200 行；拆之前先给现有 chat 相关测试补 store 级断言，否则是在没有护栏的情况下搬代码。
2. SwiftLint 升硬门禁：先生成 `.swiftlint.baseline.json`（CI 里已经有读它的分支），再收一轮告警。现在这条门禁是 advisory，等于没有。
3. `GatewaySessionMeter.ingestResponse` 里最后一处 `try?`：解不出 JSON 会走 `finish(failed:)` 的显式失败分支，但值得改成 `Result` 让调用方看见原因（目前原因丢了）。
4. `EngineStatusDialects.swift`（905 行）是新的"数据文件"，每加一个引擎都要动它：现有 conformance 测试只检查 adapter 有行，还应在 manifest 声明 `telemetry` 的那一刻校验方言表里存在对应格式，让配置错误在启动时报出来，而不是解析出空快照。

---

## 十、提交清单（第一轮 + 第二轮）

前 14 个提交按模块切开，每个都能单独回滚（第三轮 4 个提交见第十一节末尾）：

| # | 提交 | 内容 |
| --- | --- | --- |
| 1 | `f0ea290` refactor(control) | 引擎文档与配置文档收敛到 Kit 单一来源（第一轮 T1 + 漂移修复） |
| 2 | `86d8e03` fix(gateway) | 服务端二次 resume / 取消后挂起、请求边界、上游错误分类、meter 泄漏 |
| 3 | `38943f3` fix(kit) | JSONValue 数值崩溃、版本号路径穿越、pack 构建挂死、单文件归档、坏索引回落 |
| 4 | `f33eb36` refactor(kit) | `StatusParsers` / `EngineTuning` 的 per-engine 分支改为方言表与调优表 |
| 5 | `41d31c8` refactor(meter) | 网关计量数学下沉 `FlashCatKit/Meter`，App 侧只剩 typealias |
| 6 | `596a2c6` refactor(appstate) | AppState 拆出六个 store，`@Published` 63 → 8 |
| 7 | `9a10343` refactor(engine) | `EngineController` 生命周期收敛成 `Phase`，就绪信号守卫，`EngineLogSignal` 进 Kit |
| 8 | `9fc01db` refactor(chat) | 取消语义改类型判据，`ChatHistory` 写盘失败不再静默 |
| 9 | `d5fdc46` refactor(cli) | 命令表 / 选项表 / 退出码表单一来源 + CLI 契约修复 |
| 10 | `27d824e` build(scripts) | 五个打包脚本共用 `lib-pack.sh`，staging + 原子替换，CI 脚本门禁 |
| 11 | `8c9f75b` style(tests) | 解码窗口测试助手参数名改小驼峰 |
| 12 | `4435b41` chore(license) | 201 个 Swift 文件加 SPDX 头 |
| 13 | `9aeb9f6` style | 全仓按 `.swift-format` 格式化（7348 → 0） |
| 14 | `24bee4b` ci | swift-format 从 advisory 升为硬门禁 |

规模（相对 `352b763`）：**212 个路径**、`+19529 / −9401`、**32 个新文件**；其中语义改动 93 个路径（`+11163 / −4370`），格式化 188 个文件，SPDX 201 个文件。测试方法 **477 → 636**。

---

## 十一、第三轮：把 AppState 拆成装配根（2026-11-17，T13~T16）

### 11.1 起点与判断错误

第一轮把 `AppState` 从 **63** 个 `@Published` 拆到 **8** 个（六个 store + `MetricsStore`），看上去"数据已经分家"，但合并另一条工作线（日志页改版）后实测仍是 **4255 行 / 162 个 func**。原因是那一轮切的是**数据归属**，没有切**方法归属**——行数的主体是方法：`// MARK: chat` 343 + `对话里主动画图` 175 + `工具调用` 1151 = **1669 行（39%）**，另有 `lifecycle` 285、`service` 251、`models` 249、`derived` 258。

第三轮按"方法归属"切四刀，每刀一个提交、每刀独立验证，切完 `AppState` 只剩装配。四刀都由子代理执行，我逐刀复验后提交。

### 11.2 四刀的结果

| 刀 | 新文件 | 行数 | 搬走什么 | AppState 行数 | 提交 |
| --- | --- | --- | --- | --- | --- |
| ① 对话编排 | `ChatRunner.swift` | 1904 | `// MARK: chat`、`对话里主动画图`、工具调用循环（含 `send` 七个重载、`cancelGeneration`、`regenerate`、`runImageTool`、`sendImage`/`sendVideo`） | 4255 → 2600 | `cc65e14` |
| ② 引擎编排 | `EngineCoordinator.swift` | 835 | `lifecycle`（`syncController`/`bootstrap`/`adoptEngine`/`reloadModels`）、`engines`（安装/切换/端口/模型扫描）、`API gateway model preparation`、`model switch progress` | 2600 → 1897 | `42bad12` |
| ③ 模型编排 | `ModelOps.swift` | 685 | `hardware`（硬件推荐）、`model library`（清单缓存）、`draft assignments`（草稿语义 `useModel`）、`models`（下载/删除/共享）、`download center` 事件处理 | 1897 → 1496 | `dec3772` |
| ④ 收口 | `ServiceCoordinator.swift` 426 / `UIStateStore.swift` 130 / `ContextWindowTracker.swift` 120 / `LogFeedService.swift` 104 / `AppState+Wiring.swift` 112 / `ProcessOutput.swift` 67 / `AppState+Gateway.swift` 44 / `Page.swift` 33 | 1136 | `service`（装模型/切模型/起停服务与派生）、`toasts`/`sidebar`/`notice`/`island*`/`section`、`logs`/`logsRevision`、上下文窗口推导、网关地址、`TailReader`/`LineSplitter`、`enum Page` | 1496 → **795** | `bd22c5f` |

最终形态：

```
AppState (795 行, 0 个 @Published)
 ├─ 9 个 store：EngineSessionStore / ChatStore / ChatSessionStore / ModelLibraryStore
 │              HubStore / MetricsStore / DownloadCenter / UIStateStore / LogFeedService
 ├─ 4 个编排：ChatRunner / EngineCoordinator / ModelOps / ServiceCoordinator
 └─ init 只做「建对象 → 接线 → 加 objectWillChange 桥」
```

`@Published` 的分布（`grep -c '^    @Published'`）：`AppState` **0**；`HubStore` 15、`MetricsStore` 12、`EngineInstallCenter` 10、`ModelLibraryStore` 9、`EngineSessionStore` 9、`UIStateStore` 7、`DownloadCenter` 5、`ChatStore` 5、`ChatSessionStore` 4、`GatewayController` 3、`BackgroundSettings` 3、`Theme` 2、`LogFeedService` 2、`StatusBarController` 1。

### 11.3 三条接线纪律（这次真正守住了）

1. **UI 零改动**：四刀全程 `git diff --stat -- native/Sources/FlashCat/UI native/Tests` 为空。视图仍然 `@ObservedObject var state` 读 `state.xxx`，`@Published` 搬走后靠 `objectWillChange` 桥（`makeBridge(_:)` 在 `AppState.swift` 里 8 行接完 8 个 store）。
2. **不认单例**：`ChatRunner`/`ModelOps`/`ServiceCoordinator` 都是 `@MainActor final class` + init 注入 + `Hooks` 闭包（`ChatRunner` 16 个、`ModelOps` 13 个），文件里不出现 `AppState.shared`。唯一例外是 `LogFeedService.swift:85` 的 `recordHistoryWriteFailure`——`ChatHistory` 的 `onWriteFailure` 闭包在 `history` 还是 `let` 时就要构造，只能走静态入口，属既有写法原样搬移。
3. **搬运保真**：`ChatRunner` 的 1669 行与原文件逐字节比对后只有 **16 处**差异（11 × `notice = …` → `hooks.setNotice(…)`、3 × `section = .chat` → `hooks.showChat()`、2 × `logs.append(…)+refreshLogs()` → `hooks.logWarning(…)`）；`ModelOps` 的 473 行有 **469 行逐字一致**，4 行差异全是有意改写。

### 11.4 验证（每刀都跑，最后一刀后复跑）

- `swift build --build-tests` → Build complete，`Sources/` 零警告（只剩既有 `Tests/FlashCatTests/ImageToolTests.swift` 的 3 条 `#UnnecessaryEffectMarker`）。
- `swift format lint --strict --recursive Sources Tests` → 零输出。
- `swift test` → **FlashCatTests 251 / FlashCatKitTests 314 / FlashCatCLICoreTests 96 = 661**，0 failure（合并 ModelScope 工作线后 App 侧多 11 条）。
- `swift build -Xswiftc -strict-concurrency=complete` → warning 计数 **0**（基线 0）。
- 四刀期间 `native/Sources/FlashCat/UI/`、`Tests/`、`MenuBarPanel.swift`、`Design.swift`、`Theme.swift`、`StatusBarController.swift` 全程零改动。

### 11.5 遗留的技术债（下一位接手的人必须知道）

1. **`EngineCoordinator` 用了 `weak var host: AppState?`**（`EngineCoordinator.swift:30`，约 100 处 `host?.`），是四刀里唯一反向引用的文件。理由：那批代码双向读写 AppState 的转发属性，用 `Hooks` 闭包会膨胀成几十个。**下一步**：抽 `@MainActor protocol EngineCoordinatorHost`（属性集合由协议声明），既去掉反向引用，又能脱离 AppState 单测。
2. **新增的四个编排对象没有独立单元测试**：`ChatRunner`/`ModelOps`/`ServiceCoordinator`/`EngineCoordinator` 的行为目前只由 240 条 App 集成测试兜住。搬完之后它们已经可以脱离 `AppState` 构造，值得按 `EngineControllerPhaseTests` 的样子补（`ChatRunner` 用假 `ChatClient` 跑一轮流式、`ModelOps` 用假 `EngineCoordinator` 跑一次 `useModel`）。
3. **`AppState` 仍持有 328 行转发面**（`指标转发` 50 + `纯函数转发` 70 + 各段一行转发约 210）。这是"View 与既有测试的稳定接口"，要再瘦必须改订阅方式（让视图直接订阅 store），属产品决策。
4. ~~`.pnpm-store` 被误提交进 git~~ **已修（`3c51937`）**：那次 revert 带进来的是 **4780 个文件**（`node_modules` 只占 2321，另有 pnpm 的 `projects/` 元数据），共 166 MB，`.gitignore` 也没有对应条目。已 `git rm -r --cached` + 忽略 `.pnpm-store/`、`node_modules/`：仓库跟踪文件从 **5054 → 288**，`native/` 247、`scripts/` 22。**历史里的 blob 还在**（`.git` 仍 108 MB），要清得 `git filter-repo --path .pnpm-store --invert-paths` 再让所有人重新克隆，属独立一轮。

### 11.6 第三轮的验收口径（替换第九节里过时的那条）

```bash
# 装配根：@Published 必须是 0
grep -c '^    @Published' native/Sources/FlashCat/AppState.swift     # 期望 0
# 行数预算：795 是当前值，任何人加回方法都应当显式说明
wc -l native/Sources/FlashCat/AppState.swift                          # 预算 ≤ 900
# 不允许新增反向引用（只有 EngineCoordinator 那条已知技术债）
grep -rn 'AppState\.shared' native/Sources/FlashCat --include=*.swift | grep -v LogFeedService
# 视图订阅方式未变（仍是 @ObservedObject 读 state.x）
grep -rn '\$state\.' native/Sources/FlashCat/UI | wc -l               # 期望 0
```

### 11.7 第三轮的 4 个提交

| # | 提交 | 内容 |
| --- | --- | --- |
| 15 | `cc65e14` refactor(appstate) | 对话编排与工具调用搬到 `ChatRunner`（4255 → 2600） |
| 16 | `42bad12` refactor(appstate) | 引擎编排搬到 `EngineCoordinator`（2600 → 1897） |
| 17 | `dec3772` refactor(appstate) | 模型编排搬到 `ModelOps`（1897 → 1496） |
| 18 | `bd22c5f` refactor(appstate) | 收口成装配根（1496 → 795） |

四刀合计：`+4812 / −3802`，新增 11 个文件，`AppState.swift` 净减 **3460 行**（4255 → 795）。

### 11.8 合并到 main 的记录

main 检出目录里一直有另一条工作线在跑（ModelScope 第二个模型源 + 背景主题改版）。这次按上次的约定先把现场提交成 `d1b360c wip: …`，再 `git merge --no-ff` 我的分支（`8fdfd59`）：**只有一个文件冲突**（`AppState.swift`），因为对面的改动落在被拆走的那些方法里。

处理原则是「保留拆分后的结构，把对面的语义改动逐条接到新家」，而不是把旧的四千行搬回来：`downloadShared` 的 `source`/`include` 参数与 plan 构造落到 `ModelOps`，完成文案改在 `ModelOps.publishShared`，hub 的 `source` 转发签名由 `HubStore` 新版自动合入。顺带修掉对面新代码里 `ModelScopeClient.search` 的 `URLComponents(string:)!`（`NeverForceUnwrap` 已是硬门禁）。

合并后跑：Build complete、`swift format lint --strict` 零输出、测试 251/314/96 全绿、`-strict-concurrency=complete` 计数 0。
