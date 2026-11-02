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

把三个引擎的差异收敛成一套引擎无关的类型与判定，供应用壳和网关使用。它描述引擎「是什么」和「该怎么启动」，但从不真的启动任何东西。

- **引擎身份与几何。** `EngineID`（splash / omlx / mtplx）连同各自的默认端口、可用端口段、启动预算、切换模式、能力位。
- **清单。** 解码 pack 的 `manifest.json`，并展开 `{root}` `{port}` `{models}` `{model}` `{support}` `{home}` 六个模板变量。
- **状态归一。** 把三份互不相似的状态报文折成一个 `EngineStatus`。
- **路由与调参。** `EngineRoutes` 记住每个引擎的实际端点形状，`EngineTuning` 保存每引擎的可选旋钮（`nil` = 交给引擎，不做迁移）。
- **上游版本。** 读 GitHub release，与已装版本比对，得出「安装 / 更新 / 重装」。
- **装机。** 索引解析、校验和验证、安装/卸载、可删性判定，以及「上游有新版」到「实际产出 pack 的命令」的转化。
- **启动阶段。** 从引擎自己打印的日志行判定它现在在哪一步。

## 边界

- **只允许 `Foundation` / `Network` / `CryptoKit`。** 不许 `AppKit`、`SwiftUI`、`WebKit`。这条约束换来的是：整层可以在没有窗口的测试进程里跑——`FlashCatKitTests` 12 个文件、122 个测试全打在这里。
- **不拥有进程。** 不 spawn、不 kill、不轮询端口、不写 pid 文件。Kit 只输出「该怎么启动」，执行归应用壳。
- **不拥有 UI 状态，不读用户偏好。** 配置从外部传入，Kit 不碰 `UserDefaults`。
- **禁止反向依赖** 应用壳里的任何符号。
- 网关是本模块的子模块，见 [flashcat-gateway](Gateway/SPEC.md)；它同样受以上约束。

## 不变量与代价

- **端口几何刻意避开上游默认值。** splash 8000 / omlx 8100 / mtplx 8200，每段 20 个端口（`defaultPort...defaultPort+19`）。选 8100 / 8200 而不是上游自己用的 8099 / 8000，是为了让应用管理的实例和用户手工起的上游实例不打架；段外不放宽是刻意的——一个引擎的实例不该跑到另一个引擎的号段里。
- **未知枚举值降级，不失败。** 新版本 pack 可能带来当前应用不认识的 `capability` 或 `modelArgument`。解码时降级为 `.chat` / `.name`，那个值走不到相应 UI，但引擎仍然装得上、起得来。
- **解析器是唯一知道差异的地方。** 三份状态报文的形状知识只许存在于 `StatusParsers`；任何别处出现 `"metrics.decode_tokens_per_second"` 之类的路径都是把差异漏出去了。
- **启动阶段只认真正命名阶段的行。** 早期版本用裸词 `kv` / `context` 匹配，而 splash 每次启动都打印的内存计划行里恰好含这两个词，于是每次启动都报出一个引擎并不存在的「准备上下文」阶段——真正的过程是预热（arena 组装、专家表流入、最大前缀与解码预热、内存审计），以及 macOS 还没还够内存时的等待。回归由 `EngineStartupStageTests` 的两条用例守着。
- **oMLX 的管理 API 挂在 `/admin` 下**（上游 `APIRouter(prefix="/admin")`）。按朴素的 `/api/...` 写法请求会 404，即使模型已经加载。
- **已装版本的目录里，只有用户根下的可删。** 判定按路径分量标准化后比较：`~/…/engines/x` 命中 `~/…/engines`，但 `~/…/engines-copy/x` 不命中。
- **索引条目相对索引自身解析。** 索引可能来自 https，也可能是随包的或本地的一份 `file://`；同一份索引要在别的机器上也能用，条目就只能写相对索引位置的路径。相对条目在 `loadIndex` 解码时按拿到这份索引的那个地址解析（重定向之后算数——`/latest/pack-index.json` 转到 `/v1.4.1/…` 时，归档就放在后者旁边）；已经是绝对地址的条目原样通过；`install` 在碰网络之前就拒掉仍不是绝对的地址，因为那种地址只会在 `URLSession` 里无声失败。应用内「打包引擎」跑完 `make-pack-release.sh` / `make-pack-index.sh` 直接读 `.release.json` 就装，那份文件同样写相对名，`loadRelease` 按该文件所在目录解析——否则刚构建完的包装不上，而同一份 `.release.json` 还会被写回索引。
