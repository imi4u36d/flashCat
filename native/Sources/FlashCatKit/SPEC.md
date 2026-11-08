---
id: flashcat-kit
type: module-design
status: draft
title: FlashCatKit — 引擎核心
parent: flashcat-architecture
depends-on: [flashcat-manifest-contract]
---

# FlashCatKit — 引擎核心

## 职责

把所有受支持引擎的差异收敛成一套引擎无关的类型与判定，供应用壳和网关使用。它描述引擎「是什么」和「该怎么启动」，但从不真的启动任何东西。

- **引擎身份与 descriptor。** `EngineID`、`EngineCatalog` 和 `EngineDescriptor` 统一描述显示、默认端口、端口段、启动预算、切换模式、能力位、模型布局、控制端点和遥测源。
- **清单。** 解码 pack 的 `manifest.json`，并展开 `{root}` `{port}` `{models}` `{model}` `{modelID}` `{modelPath}` `{support}` `{home}` 八个模板变量。
- **状态归一。** 把 descriptor 声明的模型清单、状态、指标和 props 报文折成一个 `EngineStatus`。
- **路由与调参。** `EngineRoutes` 记住每个引擎的实际端点形状，`EngineTuning` 保存每引擎的可选旋钮（`nil` = 交给引擎，不做迁移）。
- **上游版本。** 读 GitHub release，与已装版本比对，得出「安装 / 更新 / 重装」。
- **Splash 的家族表。** 解析 pack 里的 `install/families.py`，得出「模型家族 → 它发布的 DFlash2 draft」；再按 `model.json` 记下的 family（优先）或折叠后的模型 id 反查一个模型该配哪个 draft。
- **装机。** 索引解析、校验和验证、安装/卸载、可删性判定，以及「上游有新版」到「实际产出 pack 的命令」的转化。
- **启动阶段。** 从引擎自己打印的日志行判定它现在在哪一步。
- **Hub 仓库。** `HubSearchClient` 检索 Hugging Face、逐仓库补齐真实字节；`HubModelLayout` 从仓库自报的元数据判出它服务哪个引擎（GGUF / MTPLX / MLX），并把 GGUF 仓库的量化枚举成 `select_gguf` 认得的名字。它只描述「这个仓库能不能跑」和「体积多大」，下载与归属判定归应用壳；网络出口仍只有 `URLSession`，没有新依赖。

## 边界

- **只允许 `Foundation` / `Network` / `CryptoKit`。** 不许 `AppKit`、`SwiftUI`、`WebKit`。这条约束换来的是：整层可以在没有窗口的测试进程里跑——`FlashCatKitTests` 的单元和 pack 契约测试都打在这里。
- **不拥有进程。** 不 spawn、不 kill、不轮询端口、不写 pid 文件。Kit 只输出「该怎么启动」，执行归应用壳。
- **不拥有 UI 状态，不读用户偏好。** 配置从外部传入，Kit 不碰 `UserDefaults`。
- **禁止反向依赖** 应用壳里的任何符号。
- **受支持引擎是显式集合，不是运行时引擎市场。** `EngineCatalog` 是唯一的引擎清单元数据；`EngineID`/`EngineCapability` 使用开放值只是为了减少扩散的类型分支，不表示用户可以运行时安装任意新引擎。
- 网关是本模块的子模块，见 [flashcat-gateway](Gateway/SPEC.md)；它同样受以上约束。

## 添加一个新引擎

1. 在 `EngineCatalog.builtIns` 增加一个 descriptor（稳定 id、显示、端口、切换模式、能力、模型布局、控制端点、遥测源）和对应的 `EngineID` 便利常量。
2. 产出 pack 的 `manifest.json`。标准 OpenAI 兼容引擎到此为止；它的 load/unload/rescan、模型清单和指标应全部由 manifest 描述。
3. 只有真实生命周期差异才新增 adapter，例如 Splash 的本地装配、Strata 的受管 Control/engine。adapter 也不能把 `if engine == ...` 扩散回 `EngineManager`、安装中心或页面。
4. 用 `PackInstallIntegrationTests` 指向真实归档，验证安装、入口和 manifest；为每种新的 `telemetry.format` 增加解析测试。
5. UI 不增加引擎数组；它只消费快照中的 `engineCatalog`。

## 不变量与代价

- **端口几何刻意避开上游默认值。** 当前为 splash 8000 / omlx 8100 / mtplx 8200 / mlx-serve 8300 / strata 8400，每段默认 20 个端口。默认端口、段大小和切换模式都来自 descriptor；段外不放宽是刻意的。
- **家族声明 `None` 就是没有 draft。** `families.py` 里 `ModelFamily("x", None, …)` 与「表里没这个家族」是两件事：前者以家族的回答为准，不许被应用里写死的已知表覆盖成「其实没发布过的 draft」；后者才回落到已知表，再没有就按无加速处理。
- **未知开放值不失败。** `EngineID` 与 `EngineCapability` 是开放值；新 pack 带来的未知 capability 会保留原文，未知 `modelArgument` 才回落到 `.name`。引擎仍然装得上、起得来。
- **解析器是唯一知道状态形状的地方。** 各家状态报文的字段知识只许存在于 `StatusParsers`；控制器只按 descriptor 拉取 source，再交给解析器按 `format` 合并。
- **仓库归属的顺序不许调。** 格式判定自上而下先命中先得：`library_name=mtplx` → GGUF 证据（`library_name=gguf`、`gguf` 标记、根级非 `mmproj` 的 `*.gguf`、完整 `VARIANT/`） → MTPLX 运行时（`mtp.safetensors`、`mtplx_runtime.json`） → `library_name=mlx` 或 `mlx` 标记。GGUF 证据必须排在 MTP 运行时之前：带根级 `.gguf`（`mmproj-*` 这种多模态投影不算）又带 MTP 头的仓库归 Splash（`.gguf` 是 Splash 专用通道，属产品取舍——oMLX 也能起 GGUF，`Fixtures/omlx/models-status.json` 里就有两份；这里排先是为了把仓库判给 Splash），若判成 MTPLX 就会送进一个只吃 safetensors 的引擎，直接加载失败。回归由 `HubModelTests` 的 `testGGUFWinsOverAnMTPTRuntimeItAlsoCarries` 守着。
- **GGUF 量化名以引擎的实现为准，不以猜名为准。** `HubModelLayout` 里的 variant 枚举逐条镜像 splash `install/upstream.py` 的 `select_gguf` 的四种情形：根级候选的共享词前缀之后是 token；`VARIANT/` 目录名是 token（且要五位数分片齐全）；共享前缀吃光名字时用「唯一以 `-VARIANT` 结尾」的尾部兜底；只有一个根级 GGUF、又没有分片目录时**不给 variant**（id 就是 `owner/repo`，拼出 token 反而被引擎拒）。两边任何一侧改了规则，另一个必须同步——否则界面报出的量化名引擎不收。
- **启动阶段只认真正命名阶段的行。** 早期版本用裸词 `kv` / `context` 匹配，而 splash 每次启动都打印的内存计划行里恰好含这两个词，于是每次启动都报出一个引擎并不存在的「准备上下文」阶段——真正的过程是预热（arena 组装、专家表流入、最大前缀与解码预热、内存审计），以及 macOS 还没还够内存时的等待。回归由 `EngineStartupStageTests` 的两条用例守着。
- **oMLX 的管理 API 挂在 `/admin` 下**（上游 `APIRouter(prefix="/admin")`）。按朴素的 `/api/...` 写法请求会 404，即使模型已经加载。
- **已装版本的目录里，只有用户根下的可删。** 判定按路径分量标准化后比较：`~/…/engines/x` 命中 `~/…/engines`，但 `~/…/engines-copy/x` 不命中。
- **索引条目相对索引自身解析。** 索引可能来自 https，也可能是随包的或本地的一份 `file://`；同一份索引要在别的机器上也能用，条目就只能写相对索引位置的路径。相对条目在 `loadIndex` 解码时按拿到这份索引的那个地址解析（重定向之后算数——`/latest/pack-index.json` 转到 `/v1.4.1/…` 时，归档就放在后者旁边）；已经是绝对地址的条目原样通过；`install` 在碰网络之前就拒掉仍不是绝对的地址，因为那种地址只会在 `URLSession` 里无声失败。应用内「打包引擎」跑完 `make-pack-release.sh` / `make-pack-index.sh` 直接读 `.release.json` 就装，那份文件同样写相对名，`loadRelease` 按该文件所在目录解析——否则刚构建完的包装不上，而同一份 `.release.json` 还会被写回索引。

- **实时速率由累计计数差分得出，不猜。** mlx-serve 的 `/metrics.json` 只给 `generation_tokens_live`、`prefill_tokens_live`、`prefill_tokens_total` 与 `prefill_time_seconds` 这些原始量；`EngineLiveRates` 用采样差分得到真实的解码 / 预填充速度。解码取相邻两拍；预填充取最近约 1.2 秒（1~2 个 chunk）的滑动窗口——chunk 之间 gauge 不动时保持住上一格，下一块完成才刷新，既不随时间衰减，也不会把整轮请求开头那几秒一直算进分母。预填充期间轮询提到 0.4 秒，跟得上 chunk 节奏；超过 3 秒没有新 chunk 才退回本轮累计均值。预填充的分子只含真正前向的 token，前缀缓存恢复的部分不进——否则同一会话第二轮的读数会被放大两个数量级。解析器保持无状态，只把计数放进 `extras`；时间由轮询侧注入。
- **「是不是实时」不是布尔，是粒度。** 五家引擎全都自报速率，但它们回答的不是同一个问题，一个 `isLive` 分不出来。`EngineRateKind` 编码三档：`.live`（采样窗口内的计数差分，或引擎自报的瞬时场：splash 的 `current_*_batch.tokens_per_second`、strata 的 `live.prefill_tok_s_mean`、mtplx 的 `in_flight[].prefill_state`）、`.lastRequest`（上一个已完成请求的实测值：mtplx 的 `latest.*`、llama.cpp 风格的 `timings`）、`.lifetimeMean`（进程累计比值：splash 的 `metrics.*_tokens_per_second` 是 `prefillTokens_ * 1000 / prefillWallMilliseconds_` 两个只增不减的量相除，oMLX 的 `avg_*_tps` 同）。预填充天然不是连续量：请求一做完计数器就不动，"此刻多快"没有定义，所以界层按粒度打 `LIVE` / `LAST` / `AVG` 角标，并对空闲格给出对应文案，而不是把上一请求的终值或开机以来的均值说成当前速度。
- **速率与粒度必须成对合并。** `merge` 按 health → status → metrics → props → inventory 折叠，后到的文档会覆盖数值。如果只让数值覆盖、粒度在旁边独立地取最强，就会出现「数值是后来的累计均值、角标却写着 `LIVE`」。所以只有来源粒度 `rank` 不弱于当前时才整对替换（`.live` > `.lastRequest` > `.lifetimeMean` > `.none`）：更好的来源不会被后面端点的均值洗掉，均值也不会冒充实时。
- **MTPLX 的预填充按「越接近此刻越优先」排序。** `in_flight[].prefill_state`（每 chunk 刷新）→ `.live`；`latest.prefill_tok_s`（上一请求终值）→ `.lastRequest`；`prefill_rates.tokens / compute_time_s`（最近 ≤100 chunk 的滚动均值）→ `.lifetimeMean`。同处的 `peak_tok_s` 是单 chunk 最大值，**不能**当读数——那正是「恒定不变的大数字」的来源，只留作诊断。
- **预填充没有网关回落。** 1.5.2 起不再用「(整段提示词 − 缓存命中) / 首字耗时」估算：分母是 TTFT，混着排队与缓存恢复，分子要等末帧 `usage` 才知道命中量，请求进行中算不出可靠读数。引擎不上报该方向速率时显示「—」。
