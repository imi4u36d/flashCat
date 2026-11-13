---
title: flashCat 终审记录（1.5.5）
date: 2026-11-11
scope: native/ 全量、scripts/ 发布链、CI 门禁
method: 干净构建 + 全量测试 + 严格并发零点化 + 真机安装启动
---

# flashCat 终审记录（1.5.5）

上一份台账（`2026-11-04-architecture-review.md`）记的是"还欠什么"。这一份记的是
"这一轮动了什么、凭什么说动对了"。

一句话结论：1.5.4 能跑，但有三类**看起来正常、实际会丢东西**的问题——快速重发
会丢一条流、停止引擎可能只停掉 python 主干、同一份数据在不同面板上用两套单位。
这一轮把这几个修掉，并把严格并发门禁收到 0。

---

## 一、修了什么（按读者会遇到的症状排）

### 1. 生成中再发一条，前一条流会永久挂住

- **症状**：对话里连续发两条（或点停止后立刻重发），前一条的 `send` 永远不返回，
  UI 停在"生成中"，只能再发一条把它顶开；偶发表现为新回复被旧流的尾部污染。
- **根因**：`Chat.swift` 的 `ChatClient` 只存一份 `task` / `completion` / 缓冲区。
  第二次 `send` 先 `cancel()` 再覆盖 `completion`，而第一条流的 `didComplete` 随后
  到达，把这个**新的** continuation 提前 resume——第二条请求拿到空文本返回，第一条
  请求的 continuation 再也没人 resume。
- **修法**：状态按请求隔离。`private final class Request` 持有自己的缓冲区、usage、
  取消标志和四个 `@Sendable` 回调；`requests: [ObjectIdentifier: Request]` 以 task
  身份索引；`install()` 先注册新 task 再取消旧的，`retire()` 保证每个 continuation
  只 resume 一次。顺带把 SSE 行尾从 `.whitespaces` 改成 `.whitespacesAndNewlines`，
  CRLF 流上的 `[DONE]` 现在能认出来。
- **证据**：`Tests/FlashCatTests/ChatClientTests.swift` 起了一个真的
  `GatewayHTTPServer`：一条"慢流"每 25 ms 吐一个分片，250 ms 后发第二条"快请求"，
  断言最终文本只有新回答、且分片集合不含旧流内容。**把 `Chat.swift` 换回 1.5.4 的
  实现，这个用例会永久挂起**（旧 continuation 无人 resume），换回新实现 0.6 秒通过。

### 2. 停止引擎可能只停掉 python 主干，权重留在显存里

- **症状**：点了停止、进程列表也空了，下一次启动却报端口被占 / 显存不足；显存要等
  launchd 回收才降下来。
- **根因**：`EngineController.swift` 的 SIGKILL 兜底闭包以 `self.process` 当门
  （`processPid(current) == pid`）。python 主干收到 SIGINT 先退出，`processExited`
  随即把 `self.process` 清空；20 秒后兜底闭包看到 `self.process == nil` 直接 return，
  而不是去杀快照里仍然活着的子进程（推理二进制、池 worker）。
- **修法**：兜底不再读 `self.process`，改为遍历启动时抓下的 `ProcessTree` 快照，
  只对「仍然存活 **且** 可执行文件在本引擎 pack 目录内」的 pid 发 SIGKILL —— 后者
  同时挡住 pid 复用误杀。

### 3. 「停止」落在准备阶段会被吞掉，并发启动还能起第二个进程

- **症状**：下载 draft / 等端口的几分钟里点停止，界面显示已停止，几十秒后引擎却
  自己起来了；或者启动按钮在准备阶段被连点两次，起了两个进程，先那个的退出事件被
  `finished === process` 静默丢掉。
- **根因**：`preparing` 的 `defer` 在准备阶段结束时就释放，而后面还有一次可能要等
  90 秒的 `claimPort`；这段时间 `stop()` 看到 `process == nil` 直接返回，`start()`
  却继续往下跑。第二个 `start()` 也因此能通过 `process != nil || preparing` 的守卫。
- **修法**：`preparing` 提升到函数作用域（覆盖到 `run()`），入口处记 `attempt =
  stopRequests`，在 `claimPort` 返回后复查：`attempt != stopRequests` 就停在
  `.stopped`，不拉进程。

### 4. 健康的引擎可能被判「启动超时」，超时后进程还占着端口

- **症状**：引擎早就 Ready，用了一阵后切模型，突然报"启动超时：180 秒内没有就绪"，
  而且再点启动没反应（`process != nil` 挡住了）。
- **根因**：`startStartupDeadline` 的看门狗只在 `processExited` / `shutdown` 里取消，
  正常就绪时没取消。热切换会把 `state` 再改回 `.starting`，此时看门狗到期，条件
  `process === task && state == .starting` 正好成立，于是把一个健康的引擎标成失败。
- **修法**：新增 `markReady()`，三处 `.ready` 迁移（日志 "Ready ·"、轮询晋升、热切换
  结果）统一走它，进入 ready 即取消看门狗；超时分支在 `fail()` 后补一次 `stop()`，
  别让一个已经放弃的进程继续占端口和显存。

### 5. 面板口径：同一份权重有两个 GB

- **症状**：模型卡片写「≈4.3 GB」，下载中心对同一份权重写「共 4.0 GB」；Hub 列表
  与下载进度条同屏时两个数对不上。
- **根因**：`Format.size` 用十进制（1 GB = 10⁹ B），`Format.bytes` 用二进制
  （1 GiB），而两者被混用在磁盘容量上：`HubSheet.swift:359`、`DownloadCenterSheet.swift:153-154`
  走二进制，同一屏的 `HubSheet.swift:239/308/503` 走十进制。内存（`MenuBarPanel.swift:556`）
  才是真正该用二进制的地方。
- **修法**：`Format.size` = 磁盘唯一口径（十进制，和 Finder / 系统设置一致，低于
  1 MB 退回 KB 而不是显示「0 MB」）；`Format.bytes` 更名 `Format.memory`（二进制，
  只给内存用）；`Format.rate` 改成同口径十进制（100 MB 的包 10 MB/s 就是 10 秒）。
  `Tests/FlashCatTests/FormatTests.swift` 把这几条口径钉住。
- **同批**：`Format.tokensShort` 收编了 `OverviewPage.swift` 与 `ChatPage.swift` 各写
  一份的 `shortTokens`（两处都是 `/ 131K`，和 `Format.tokens` 的 `12.3K` 是两种读法，
  现在有名字也有断言）。

### 6. 采样滑杆的数字不跟手

- **症状**：拖「温度」滑杆时右侧数字停在旧值，切换页面回来才更新。
- **根因**：`AppSettings.setTemperature` 直接写 `UserDefaults`，不触发 SwiftUI 重绘；
  `ChatPage.swift` 的老 `slider(...)` 把 `value` 当常量传进 `Text`，读数是拿渲染时的
  旧值格式化的。
- **修法**：抽出 `SamplingSlider`，用本地 `@State` 驱动滑杆与读数（`onChange` 再落
  盘），数字带 `.contentTransition(.numericText())`。顺带消掉了 `Binding(get:set:)`
  在严格并发下的那条告警。

### 7. `.dmg` 静默消失

- **症状**：`make app` 全绿，`dist/` 里只有 `.pkg`，没有拖拽安装用的 `.dmg`，只有
  一行 `warning: .dmg 生成失败，已跳过`。
- **根因**：两件事叠在一起。(a) `hdiutil create` 要新建一块临时 APFS 卷，受限沙箱下
  `newfs_apfs` 直接 `Operation not permitted`，hdiutil 把真因吞成一句「目录非空」；
  (b) 脚本把 dmg 当"副产物"，失败只警告，发布链因此永远发现不了缺件。
- **修法**：`scripts/make-installer.sh` 先试 `diskutil image create`（macOS 27 起
  `hdiutil create` 已弃用，官方替代就是它），失败再退回 hdiutil 并先摘掉残留挂载；
  失败时把真实原因（`operation not permitted` 等）捞出来打给人看；`make dmg` 传
  `FLASHCAT_REQUIRE_DMG=1`，显式要镜像时缺件就退出非零。`make app` 仍保持"装不上
  不能拦构建"，但不再对镜像说假话。
- **验证**：`VERSION=1.5.4 FLASHCAT_REQUIRE_DMG=1 ./scripts/make-installer.sh` →
  `dist/flashCat-1.5.4.dmg (5.3M)`。

### 8. 严格并发 11 → 0

| 位置 | 原来 | 现在 |
| --- | --- | --- |
| `AppState.swift:2418` 流式回调 | 3 条 non-Sendable 闭包 | 回调改为 `@Sendable` |
| `AppState.swift:3084` 下载退出 | 弱引用被当成可变捕获 | `Task { @MainActor }` 只带可发送值 |
| `AppState.swift:3567-3578` `TailReader` | 可变 `buffer` 被 `@Sendable` 闭包捕获 ×7 | 缓冲区收进加锁的 `LineSplitter`，回调在锁外 |
| `Chat.swift:67` | `task` 可变 | 每请求 `Request` |
| `ChatPage.swift:716` | `Binding(get:set:)` 传非 Sendable set | `SamplingSlider` 用 `$current` |

`.strict-concurrency-baseline` 从 11 收到 **0**：门禁从"别变多"变成"一条都不许有"。

### 9. 模型 id 可以穿越到模型目录之外，并且能删掉它（P0）

- **症状**：`flashcat models download '../../../../../Documents' --engine mlx-serve`
  这类输入不只是"下载不了"——它会把目标目录拼成 `~/Documents`，在下载开始时给这个
  路径盖一个 `.flashcat-incomplete` 标记，随后在下载中心点"移除"，就会
  `removeItem(~/Documents)`。
- **根因**：`ModelInstaller` 把仓库 id 直接当路径分量（`modelsRoot + "/" + repo`），
  `FlashCatPaths.modelPath` 的嵌套布局同理；而"丢弃未完成下载"只凭标记文件存在就
  递归删除，从不检查路径在不在模型目录里。
- **修法**：仓库 id 只接受 `owner/repo` 形状（`FlashCatPaths.isSafeRepository`，
  `ModelInstaller` 在拼路径前拦一次，`modelPath` 再兜一次——不认的名字退化成扁平
  目录名）；新增 `FlashCatPaths.contains(_:in:)`，按标准化后的路径分量比较，标记
  只在"目标本来不存在且落在模型目录内"时创建，删除前再校验一次。
- **测试**：`Tests/FlashCatKitTests/RepositorySafetyTests.swift` 覆盖 `../../..`、
  绝对路径、`owner/../..`、空段、`/models2` 前缀陷阱。

### 10. 重下一次已装好的模型，失败后再点"移除"会删掉好权重

- **症状**：模型已经装好、能跑；手滑点了一次下载，中断；在下载中心"移除"那一行，
  模型从列表里消失，磁盘上的权重也没了。
- **根因**：`startDownload` 无条件写 incomplete 标记，即使目标目录已经完整存在；
  丢弃逻辑只看标记。
- **修法**：标记只在目标不存在时创建（见上一条），另外 `downloadModel` 补上了
  `downloadShared` 早有的 `repoIsLocal` 守卫——已经在本机的模型不再下一个副本。

### 11. 引擎包：入口可以指到包外，归档里的软链会被 chmod

- **症状**：一个构造过的 pack 可以带 `entrypoint: "../.."` 或 `pack/link -> ~/.ssh/id_rsa`
  的软链条目。安装时会 `chmod 755` 目标文件，启动时执行它。
- **根因**：validate 只检查清单 id、入口文件存在；归档校验只看名字里的绝对路径与
  `..`，从没看过条目类型（软链/硬链），也从没比较过 `manifest.version` 与
  release 目录名。
- **修法**：入口必须是相对路径、不含 `..`，解析软链后仍须落在 pack 内；归档用
  `tar -tvzf` 再列一遍，首列是 `l`/`h` 的条目直接拒绝；`manifest.version` 与
  release version 不一致即失败（目录名与清单各说各话时，卸载会删错目录）。
  远程 pack 索引只接受 https（回环地址除外），否则中间人换掉索引就等于换掉权重。
- **追记（1.5.6）**：「首列是 `l`/`h` 的条目直接拒绝」后来被证明过宽——Python 发行包
  （splash、mtplx、omlx、strata 都是）自带同目录相对软链，一律拒绝等于这些引擎全装不上，
  Splash 1.6.1 就卡在 `python/share/man/man1/python3.1 -> python3.13.1`。现在改为按**目标**
  判定：相对路径、按 `--strip-components` 解析后仍在 pack 根内即放行；绝对路径、`~`、
  爬出根的 `..` 仍整包拒绝（错误文案「归档中包含指向包外的链接」）。见
  `native/Sources/FlashCatKit/SPEC.md` 的「链接可以留，但不能出包」。

### 12. GitHub tag 可以变成 shell 命令

- **症状**：pack 构建脚本把 `version` 拼进 `bash -lc` 的单引号参数；一个
  `1.2'; rm -rf ~; echo '` 形状的 tag 会在构建机上执行。
- **根因**：`EngineUpstream.normalizedVersion` 只剥了前缀 `v`。
- **修法**：版本号只保留 `[0-9A-Za-z._+-]`，其余字符在拼命令之前就丢掉。

### 13. 引擎激活先删旧版再装新版

- **症状**：升级时如果移动新版本失败（磁盘满、权限、崩溃），旧版本已经被挪进回收站
  并删掉，引擎变成"没装"。
- **根因**：`activate` 的 `moveItem` → `removeItem` → `moveItem` 之间没有回滚。
- **修法**：旧版移到 `.trash` 后先装新版，失败则把旧版搬回原位并重新抛出错误；
  回收站清理失败只记日志。

### 14. 命令行离线读 `engines.json`：坏文件静默变成"没有引擎"

- **症状**：手改坏的 `engines.json`（少一个 `enabled` 键）会让整个字典解析失败，
  应用随后 `save()` 把它写成 `{}`；`flashcat status` 则报"没有引擎"、默认端口。
- **修法**：`EngineConfiguration` 自定义解码，缺键用默认值（`enabled` 默认开、
  `autoStart` 默认关）；`EngineStore.load` 逐条解码，解不动的条目原样保留并在
  `save()` 时写回；CLI 在配置读不出来时往 stderr 打一行警告，而不是假装一切正常。

### 15. 窗口恢复到了屏幕之外（P1）

- **症状**：换过显示器之后启动，Dock 图标亮着、菜单栏也在，但屏幕上没有窗口。
- **根因**：`NSScreen` 的 autosave frame 原样恢复。`configure` 只兜底了尺寸，没管坐标，
  实测恢复出来的是 `(-1485, 199, 1299×760)`——整块在副屏曾经的坐标上。
- **修法**：`App.swift` 新增 `clampToVisibleScreen`：只承认"与某块屏幕的可视区域重叠
  至少 160×120"的 frame，否则按最小尺寸在主屏居中。窗口每次成为 key window 都会走
  一遍，代价可忽略，恢复后实测 `(224, 80, 1280×820)`。

### 16. 首屏模型名被截成 `Qwen3.8-Flash-...t-GSQ-RCO-GGUF`

- **症状**：概览首屏最醒目的信息是模型名，长 id 用中间截断后只剩首尾碎片。
- **修法**：改成尾截断 + 最多两行（`lineLimit(2)`、`fixedSize(vertical:)`），
  完整 id 现在读得出来。

### 17. 没有读数时单位还在

- **症状**：首字延迟显示 `— ms`、缓存命中率显示 `— %`，看起来像"零延迟""零命中"，
  实际只是"还没测到"。
- **修法**：`metricCard` 在值为 `—` 时不渲染单位；空状态（曲线、最近请求）补上图标与
  一句操作提示，不再是一行字悬在大片空白里。

### 18. 同一张模型卡上，SIZE 比「内存起」还大

- **症状**：68.5 GB 的权重配着「64 GB 内存起」。两个数并排放在一张卡上，前者是实测、
  后者是目录里的估算，读者只会认为这软件不会算数。
- **修法**：`ModelsPage.memoryText` 取 `max(目录估算, ceil(实测权重))`——内存下限
  不可能低于权重本身；实测后该卡显示「69 GB 内存起」。

### 19. 模型卡把同一个 id 印了两遍

- **症状**：标题是 `Qwen3.8-27B-GSQ-RCO-GGUF:IQ3_S`，下一行小字还是同一串
  `ISTA-DASLab/...:IQ3_S`。两行占位、零信息增量。
- **修法**：副标题优先用目录里的一句话说明（「27B 稠密模型的 GSQ-RCO 动态量化…」），
  完整 id 收进悬停提示；只有 id 与标题不同（多级仓库名）时才用等宽字体印 id。

### 20. 五张引擎卡各拖一条「已安装」空页脚

- **症状**：页头已经写着「5 / 5 已安装」，每张卡底部还隔一条分割线再写一遍「已安装」，
  读起来像占位空行。
- **修法**：页脚只在有话说时出现——安装进度、可更新、尚未安装；纯已安装状态不再
  渲染分割线与文字。**第一版只做到这里，随即被截图打回**：一行两张卡，右侧出现
  「可更新至 X」时那张卡变高，左侧底下就空出一个 40pt 的洞，比要省掉的那行字更显眼。
  终版把页脚占位固定成 40pt：有内容时填满，没内容时是纯空白、不画分割线，同一行
  的卡因此永远等高，更新提示出现时也不会把下面的卡挤动。

### 21. 设置页与日志页的用词不统一

- **症状**：设置里是「APP 透明度」「背景模糊 0pt」，日志空状态说「启动服务后」，
  同一个产品里三种叫法（APP / 服务 / 引擎）。
- **修法**：统一为「界面透明度」「关闭（或 N pt）」「启动引擎后」；中英混排只保留
  品牌名与协议名。

### 22. 引擎卡上的五个亮红删除按钮抢视线

- **症状**：删除是不可逆操作，但一排五张卡上全是亮红图标，和引擎徽标、状态点争注意力。
- **修法**：图标收成次要色，危险语义交给确认弹窗；可点区域与提示文案不变。

---

## 二、验证记录

| 命令 | 结果 |
| --- | --- |
| `swift build --disable-sandbox -Xswiftc -warnings-as-errors` | 通过，零告警 |
| `swift test --disable-sandbox` | 374 个用例（Kit 244 / 壳层 96 / CLI 34）全过 |
| 干净构建 + `-strict-concurrency=complete` | 0 条唯一告警（基线 0） |
| `INSTALL=0 ./scripts/build-native-app.sh` | app 16M + pkg + dmg 全部产出 |
| `FLASHCAT_REQUIRE_DMG=1 ./scripts/make-installer.sh` | `flashCat-1.5.5.dmg (5.3M)` |
| 截图核对（概览首屏，1440×900 逻辑分辨率） | 窗口在屏内；模型名两行完整；四个指标格无残留单位；两块空状态有图标与提示 |
| `make verify`（安装后启动） | `APP LAUNCH OK`，Helper 报 `flashcat 1.5.5 (136)` |
| 网关实跑（127.0.0.1:9000，真模型） | `/health` 200、`/v1/models` 200、未知模型 404、`count_tokens` 4、`/v1/messages` 流式 22 个 `event:` 帧且 `message_stop` 收尾 |
| 六个页面逐页截图（深/浅两套外观） | 概览/对话/模型/引擎/日志/设置均无遮挡、无残留单位、无重复空行 |
| 1.5.6 重新打包安装 | `flashCat-1.5.6.{pkg,dmg}`（各 5.3M），`APP LAUNCH OK`，Helper `flashcat 1.5.6 (137)` |

---

## 三、没做，以及为什么

1. **P0-2 拆 `AppState`（3,584 行、61 个 `@Published`）**：这个活的价值在"让每个
   子模块可测"，一次做完需要先补测试再搬代码，属于跨多个提交的重构；本轮把它留在
   待办，并把现状数字更新进旧台账——不假装它不存在，也不在终审里做半截拆分。
2. **`ChatError` 枚举化 / `isCancellation` 字符串匹配**：改动会穿过 `AppState`、
   `ChatClient`、CLI 三处调用点，收益正确性大于观感，但没有新用例就动手容易把
   "取消"语义改歪；留给下一轮，验收口径是"删掉 `"cancel"/"取消"` 字面量"。
3. **`EngineController` 的 `enum Phase`**：本轮已把三处 `.ready` 收进 `markReady()`，
   状态机其余部分仍然是布尔组合。合并成枚举会同时改 20+ 处读写，风险大于收益，
   留待与 P0-2 的 `EngineSession` 一起做。
4. **在线/离线两套配置文档收敛**：`StatusCommand.offlineReport` 与
   `ControlServer+Documents` 仍各写一份，`thinkingMode` 的 `none` 漂移还在。
   收敛的正确做法是把它下沉成 Kit 纯函数，属于 API 设计活，不适合在终审里顺手改。
5. **全仓 `swift-format`**：一次性大 diff，必须单独提交才能保住 `git blame`；
   本轮只保证新代码符合格式。
6. **CLI 的容量单位仍是二进制**（`CLIFormat.bytes`）：终端输出是文档化的契约，
   改单位会让已有脚本的肉眼核对失效；如果要对齐 GUI，应当作为一次显式的
   "输出变更"发版，而不是混在修复里。

---

## 四、下一轮的验收口径（照这个做就不用再讨论）

- [ ] `AppState.swift` < 400 行、`grep -c "@Published"` < 12，且 `EngineSession` /
      `ChatSession` / `DownloadCenter` 各有独立测试文件。
- [ ] `grep -rn '"cancel"\|"取消"' Sources/` 为空（取消靠类型不靠字符串）。
- [ ] `EngineController` 只有一个 `phase` 属性，布尔组合清零。
- [ ] 离线文档与在线文档同源：同一个 Kit 函数产出，CLI 与 App 都只取数。
- [ ] `swift-format lint --recursive Sources Tests` 零输出。

---

*行号以本提交为准；上一份台账见 `2026-11-04-architecture-review.md`。*
