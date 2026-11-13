---
id: flashcat-ui
type: submodule-design
status: draft
title: 原生界面 — 七个页面与控制台壳
parent: flashcat-app
---

# 原生界面 — 七个页面与控制台壳

## 职责

整个可见界面。七个页面、首次启动页、下载中心、模型广场、引擎配置与对话参数全部是
SwiftUI / AppKit 视图，直接读取 `AppState` 的 `@Published` 状态，用户动作直接调用
`AppState` 的方法。没有 `WKWebView`、没有 HTML/CSS/JS、没有序列化桥、没有打包产物。

页面：概览、对话、模型、引擎、日志、设置、实验室，以及首次启动的硬件推荐 / 引擎安装页。

## 目录

| 文件 | 职责 |
| --- | --- |
| `UI/ConsoleShell.swift` | 窗口根视图、标题栏、侧栏、页路由、全局确认弹窗与灵动岛层 |
| `UI/DynamicIsland.swift` | 标题栏灵动岛：引擎状态、通知历史与引擎详情 |
| `IslandNotice.swift` | 灵动岛通知的数据模型与信息 / 成功 / 警告 / 错误分类 |
| `UI/FeedbackSheet.swift` | 反馈弹窗：QQ 群号、复制与拉起 QQ |
| `UI/LiquidGlass.swift` | macOS 26 Liquid Glass 材质与玻璃按钮样式 |
| `UI/ModelFamily.swift` | 模型家族识别与家族徽标 |
| `UI/ModelCardText.swift` | Hugging Face 模型卡的 Markdown 清洗 |
| `UI/CommandPalette.swift` | 命令面板：页面跳转与常用动作（鼠标操作） |
| `UI/OverviewPage.swift` | 引擎状态、当前模型、六项实时指标、吞吐曲线、上下文与接口 |
| `UI/ChatPage.swift` | 会话、流式消息、思考块、Markdown 正文、输入框与生成参数 |
| `UI/MarkdownView.swift` | 对话正文的块级 Markdown 渲染（标题/列表/表格/代码/引用） |
| `UI/ModelsPage.swift` | 引擎栏、筛选、模型卡、下载/使用/删除、草稿与共享授权 |
| `UI/ModelsPage.swift` 内的 `ModelCard` | 单张模型卡的动作与进度 |
| `UI/HubSheet.swift` | 模型广场：搜索、排序、格式筛选、翻页、模型卡、下载 |
| `UI/DownloadCenterSheet.swift` | 下载任务：进度、暂停、继续、清理半成品 |
| `UI/EnginesPage.swift` | 五台引擎的安装、启停、切换、上游版本与运行时删除 |
| `UI/EngineConfigSheet.swift` | 单台引擎的端口与调优开关 |
| `UI/LogsPage.swift` | 实时日志、级别过滤、搜索、暂停、复制、清空 |
| `UI/SettingsPage.swift` | 外观、服务、网关、命令行接口、生成默认值、存储与关于 |
| `UI/LabPage.swift` | 实验室：图片 / 视频分页网格、翻页、缩略图预取与详情入口 |
| `UI/GalleryDetailSheet.swift` | 生成结果详情：大图、视频播放、参数与提示词复用 |
| `UI/ChatColumn.swift` | 对话列宽换算：拖动上下限、落盘夹取与气泡 / 输入卡派生 |
| `UI/VideoPlayback.swift` | 用 QuickTime 打开生成视频，失败退回默认应用 |
| `UI/LaunchPage.swift` | 首次启动的硬件推荐与引擎安装 |
| `Design.swift` / `Theme.swift` | 设计 token、组件与外观（`Native` / `AppAppearance`） |

## 窗口 chrome

- **标题栏。** 一行 48pt：红绿灯留白、折叠边栏、居中的灵动岛（引擎名、真实阶段、实时 tok/s 与启停；
  通知到来时临时显示消息并计未读，点开原地展开通知历史或引擎详情。模型加载、切换与复制、
  改设置这类一过性回执只在胶囊上闪一下，不写历史也不计未读；灵动岛、概览、菜单栏和命令
  面板一律只报引擎真实处于的阶段，不复述「切换中 / 加载新模型」）、
  外观切换、下载中心（带任务徽标）、反馈入口（最右，和下载中心之间隔一道 1pt 竖线）。
  标题栏不放命令面板入口，它只从「页面 → 命令面板」打开。
- **侧栏。** 悬浮玻璃导航列，可整体隐藏让主视口铺满窗口；收起按钮在红绿灯右侧，
  与「显示 → 隐藏边栏」菜单同一条路径；
  工作区七页 + 最近对话 + 引擎卡（启停与切换）。
- **页面切换。** 220ms 淡入 + 8pt 上移；侧栏选中态用 `matchedGeometryEffect` 在行间滑动。
- **动效。** `Motion.quick` 140ms 用于 hover/press，`Motion.standard` 220ms 用于页面与卡片状态，
  `Motion.entrance` 轻弹簧用于消息与 toast；`accessibilityReduceMotion` 下关闭位移动画。

## 控件

- 控件统一走 macOS 26 Liquid Glass：侧栏、标题栏按钮、命令面板、输入卡与浮层使用
  `glassEffect`（`LiquidGlassSurface`），互斥按钮组用系统 `.tabs` 分段控件（`NativeSegmented`）；
  卡片也用同一层玻璃材质，但正文只靠排版分层，不在内容上再叠色。
  菜单用系统玻璃 popover（如 `ModelPickerPopover`）。
- 可点击 / 可悬停的玻璃表面必须带 `interactive: true`（`LiquidGlassSurface` 与
  `consoleCardSurface` 同一语义）；只把 hover 填充色换成强调色不算交互反馈。
- **模型卡内的动作按钮不铺底面。** 卡片本身已经是一层玻璃，按钮再叠一个玻璃胶囊会在
  卡面上多出一块更亮的椭圆；卡内的「使用 / 下载 / 暂停」只留文字与图标，靠悬停提亮、
  按下收缩给反馈（`CardActionStyle`）。正在使用的模型卡也不整块染色，「使用中」胶囊是
  唯一的选中信号；卡面只在下载中铺一层暖色。右上角「…」例外——它是 Liquid Glass 的
  圆形交互面，保留玻璃圆底。
- **无边框 `Menu` 的标签会被压平。** `.menuStyle(.borderlessButton)` 把 label 当模板处理，
  label 里的 `frame`、`background`、`foregroundStyle` 都会失效（图标还会被全局
  `.tint(Console.accent)` 染成粉色）。尺寸、玻璃圆底和颜色都要挂在 `Menu` 外层：
  `.frame(width:height:)` + `.background { LiquidGlassSurface(...) }` + `.tint(...)`。

## 对话

- **消息气泡。** 用户消息右对齐、回答左对齐，各自一层不透明气泡：用户是冷灰蓝，回答
  接近卡片的白 / 深灰，描边 0.8pt。这组颜色是固定的中性色，**不从 `accent` 派生**——
  换品牌色时对话区不跟着变；思考状态、光标等状态提示仍用强调色。
- **气泡按内容收拢。** 两侧气泡最多宽 660pt（默认列宽下），短消息不会撑成整行；模型名
  留在气泡外上方，它是说话人标注。思考折叠行、图片 / 视频、正文、统计与复制按钮都在气泡内。
- **对话列可以拖宽。** 对话列右边缘有一条 3pt 竖线（悬停变 5pt、染强调色，光标换成左右
  箭头），拖动整列对称撑开：下限是默认 820pt，上限是「页面宽度 − 40」（输入卡在页面级
  已经让出 40pt），双击回到默认。气泡最宽 = 列宽 − 160（默认 660），输入卡 = 列宽 − 40
  （默认 780）——三条宽度都从一个列宽派生，换算集中在 `UI/ChatColumn.swift`。拖动过程中
  只改内存里的实时宽度，松手才写 `UserDefaults("chat.columnWidth")`；读取时按窗口夹一次
  但不回写，所以窗口缩小时列跟着收窄、放大回来还能回到用户拖出来的宽度。
- **「画」开关与系列图。** 文本模型的输入卡上有一枚画笔开关（默认开），只在引擎声明
  `tool-use` 且引擎里存在图像模型时出现；关掉后模型只写字。开启时模型一次调用给出多段
  提示词，一组图共用一个 seed，画一张追一张进同一条回答气泡——多张横排成缩略图、左上角
  标序号，单张仍按原来的大图显示。「正在画第 2/3 张 · 去噪 8/20」这类阶段写在占位气泡里，
  和图像 / 视频链路的进度占同一个位置；停止按钮一并掐断换模型与画图的整条链路。

## 实验室

- **第七页。** 侧栏「设置」之后是「实验室」（`flask`），顶部玻璃分段在「图片 / 视频」
  之间切换。两个库都只认 assistant 消息里落盘的结果，用户拖进输入卡的底图与首帧图
  不会混进来。
- **一屏一页。** 网格不滚动：按可视尺寸算出每页列数 × 行数（`LabGridLayout`），翻页器
  固定在左上角（`1 / 12` 与左右箭头），翻页整页替换。翻页只换数据，缩略图照旧异步解码；
  翻到下一页之前先把下一页的缩略图在后台解好，连续翻页看到的都是现成的图。
- **封面与详情。** 封面按目标像素解码后进 `ImageThumbnailCache`，主线程不碰原图。
  点开进 `GalleryDetailSheet`：图片看大图，视频用 `VideoPlayer` 原位播放；旁边列出模型、
  尺寸、步数、seed 与提示词，提示词可复制，也可以带着 seed 回填到输入卡再画一次。
- **两条生成链路。** 图像走 `ImageClient`（SSE 进度 + 最终图），视频走 `VideoClient`
  （SSE 进度 + 帧数据，mp4 在后台线程编码；发出前先按 RGB 体积预检载荷）。两者与
  对话里的画图共用同一套阶段文案和占位位置。

## 键盘策略

**应用不注册任何键盘快捷键。** 菜单项、工具栏按钮和命令面板都不带按键等价物；
命令面板不接管方向键 / 回车 / esc，搜索框也不在回车时提交——这些动作一律由点击
完成。这样做的原因不是「不要键盘」，而是把键盘效率集中到 `flashcat` 命令行：它
支持补全、JSON、脚本与批量动作，且不会和用户自己的快捷键管理器打架。

**唯一的按键例外是对话输入框里的回车**：回车发送、⌘回车换行。它属于文本编辑
动作，只在输入框拿到焦点时发生，没有全局影响；输入法组字期间的回车一律交回
AppKit（那是候选确认，不是发送）。实现在 `UI/ChatComposerField.swift` 的
`NSTextView.keyDown`，之所以不用 SwiftUI 的 `TextField(axis: .vertical)`，是因为
后者只会回车换行、没有换行组合键可留。Tab / ⇧Tab 仍然只在控件之间移动焦点，
输入框不插入制表符，键盘不会被困在输入框里。

命令面板因此只负责「点击一行运行命令」；搜索框仍然可以输入文字（文本编辑不是
快捷键）。检查由 `FlashCatTests.LocalizationTests.testNoInAppKeyboardShortcutsRemain`
守着：`.keyboardShortcut`、`.onKeyPress`、`.onExitCommand`、`.onSubmit` 和
`NSEvent` 全局/本地监听都不允许再出现在 `Sources/FlashCat` 里；
`testReturnKeyIsOnlyHandledByComposer` 再钉一遍例外范围——`keyDown` 覆盖只许出现在
那个输入框文件里。

macOS 自己提供的文本编辑与剪贴板快捷键、关闭窗口与退出等系统级菜单项不受影响，
它们属于 AppKit，不属于这个应用。

## 状态与数据流

- **单一状态源。** `AppState`（`@MainActor`，`ObservableObject`）持有全部可变状态：
  引擎、模型库、会话、下载、设置、外观、侧栏。视图只读，不缓存副本。
- **没有快照协议。** 页面直接订阅 `@Published`；引擎指标统一按 1 秒轮询，预填充
  不再提速到 0.4 秒——概览里的解码曲线、预填充格、hero 平均都只每秒变一次。
  只是普通状态变化，不经过 JSON 序列化，也不存在「快照与实时流谁领先」的问题。
  空闲时**不**降频：隔秒轮询会把累计计数器的差分窗口从 1 秒拉成 2 秒。
- **每个指标格只有一个 owner（1.5.4 起）。** 取数口径全部收在 `AppState` 的
  owner 表（`decodeReading` / `averageDecodeReading` / `menuBarDecodeReading` /
  `prefillReading` / `ttftReading` + `MetricOrigin` / `TTFTReading`），hero、
  60 秒曲线、「最近请求」逐行、灵动岛、菜单栏从同一组
  函数取数，数值与角标同源；以前 hero 走网关、预填充格走引擎、灵动岛引擎优先，
  同一页两处数字天然对不上。分工是：
  - **曲线 / 当前速度**（`decodeReading`）owner = 网关按请求打点，只认 LIVE；
    应用内对话也注册在网关里。引擎的 `LAST` / `AVG` 不参与当前速度，只有网关
    没有在跑会话（客户端直连引擎端口）时才用引擎的 `.live` 计数兜底，且要求
    `activeRequests > 0`；网关读数超过两拍未刷新同样降级到引擎兜底。
    收尾后**不**再挂上一请求的终值：曲线冻结在最后一个采样点，角标说「已冻结」。
  - **hero 大数字**（`averageDecodeReading`）owner = 网关按会话累计的
    「模型启动以来平均」：分子是生成 token，分母是首 token 到末 token 的解码
    时长，不含 TTFT / 排队 / 空闲。换引擎、换模型或引擎重启时累计量清零。
    角标写 `AVG`；没有网关样本时才退回引擎自己的 `.lifetimeMean`。
  - **采样节拍固定 1 秒**：曲线的点、当前速度、预填充格、hero 平均都在同一拍
    发布，不因 SSE 分片或预填充 chunk 而「立即变化」。
- **生命体征仍由引擎上报，并自证粒度。** 上下文上限 与 `SESSIONS`
  （`activeRequests`）读引擎 status，卡片说明标明「引擎」。预填充
  按请求实测，优先级写死在 owner 表里：**引擎 `timings`** →
  **网关 TTFT 口径** → 引擎的 `LAST` / `AVG`。`timings` 是 llama.cpp 口径的
  一块（`prompt_n` / `cached_n` / `prompt_ms`），mlx-serve 在**流式末片与
  非流式正文里都带**，所以分子分母都是引擎量的，不依赖传输方式；网关口径只在
  流式响应上成立（非流式回来时预填充早就结束，唯一的「首字时刻」是整段回答的
  收尾）。两种口径都只算**真正前向**的量：`promptTokens − cached_tokens`，
  前向不足 128 token 的样本一律不报——命中缓存后剩几十个 token 时耗时由缓存
  恢复的固定开销主导，报出来的三位数既不是算力也不是缓存速度。概览按
  `LIVE` / `LAST` / `AVG` 显示：`LIVE` = 此刻真的在预填充（只有引擎量得到）；
  `LAST` = 最近一次完成的预填充（「网关 · 最近一次预填充实测」），客户端绕过
  网关直连引擎端口时才回落成引擎的上一请求值；`AVG` = 引擎真的累计过的开机
  以来均值（mlx-serve 的 `prefill_tokens_total / prefill_time_seconds.sum`）。
  三档都没有时才画「—」。
  `LIVE` 的预填充值是最近约 1.2 秒（1~2 个 chunk）的窗口速度，不是整轮请求的累计平均；
  灵动岛只说当前速度，因此只在引擎 `.live` 时采用引擎读数。
- **首字延迟格（`ttftReading`）优先引擎、网关兜底。** 引擎 status 有正样本时
  用它（splash 是 `ttft_ms.p50`，mlx-serve 是直方图均值，MTPLX 是上一请求值）；
  引擎没有这个字段（oMLX / strata）或首个请求之前还没样本（splash 报 0）时，
  退回网关逐请求量到的最近一次首字（`firstTokenAt − startedAt`，只对流式成立）。
  概览与菜单栏同读这一格：没有正样本时画「—」，0 不算「首字很快」；概览在
  网关来源时标 `LAST`，不冒充 p50。引擎停止时整格归零，不留下停掉前的读数。
- **缓存命中率格**（`CACHE`）owner = 网关按代累计：分子是 usage 里的
  `cached_tokens`，分母是同一批请求的 `prompt_tokens`，**按 token 加权**而不是
  各请求命中率的算术平均——一段 100K 的上下文命中 95%，比十次 1K 的冷请求更能
  代表缓存效率。只统计真的收到 usage 的请求（客户端没开
  `stream_options.include_usage` 时没有这个字段），窗口是会话表最近 ≤32 条；
  换引擎 / 换模型 / 重启时 `epoch` 翻代，读数从「—」重新等样本。网关一个带
  usage 的请求都没有时（客户端绕过网关直连引擎端口），退回引擎自己报的开机
  以来比值：mlx-serve 的 `prefix_cache_tokens_total / prompt_tokens_total`、
  MTPLX 的 `lifetime.cached_tokens_total / lifetime.prompt_tokens_total`、oMLX
  的 `total_cached_tokens / total_prompt_tokens`（它的 `cache_efficiency` 是
  百分数，统一走原始计数器，少一套单位）。两个口径都是累计平均，角标只有
  `AVG`；0% 是合法读数（有样本、一次都没命中），「没样本」才画「—」。
- **菜单栏读数条只留三格：解码 / 首字 / 预填充。** 面板没有概览的说明文案，
  所以角标直接标在格子里，取数仍走 owner 表：解码有实时读数时用
  `decodeReading`（`LIVE`），空闲时退回 `menuBarDecodeReading` 里的模型启动
  以来平均（`AVG`）——面板只有一格，不能像概览那样把实时曲线和大数字分两处
  摆，但也不把平均冒充成当前速度；首字走 `ttftReading`；预填充走
  `prefillReading`（`LIVE` / `LAST` / `AVG`）。内存占用不再占这一条：它是
  一次性快照，不是速度类读数，和「这台模型多快」不在一个问题上。
- **「最近请求」每行的速度同样是按请求的实测值。** 已结束的行读引擎 `timings`
  的 `predicted_n / predicted_ms`；没有 `timings` 的引擎退回网关按分片到达时刻
  估的窗口，且必须真的观测到解码跨度（首片到末片 ≥ 0.2 秒）。两样都没有就画
  「—」：非流式响应的正文一口气回来，网关手里只有一个到达点，拿窗口下限
  （0.35 秒）去除会把 14 155 token 的回答读成 40 443 tok/s——那正是「几万
  tok/s」的来历。单点会话同样不进 hero 的累计均值。
- **动作即方法调用。** 导航 `state.section = .models`，启停 `state.toggleService()`，
  换模型 `state.applyModelFromAnyEngine(id, engine:)`，下载 `state.downloadModel` /
  `state.downloadShared`。确认类交互由 `AppState` 持有（`confirmingModelSwitch`、
  `pendingLibraryUse`、`pendingEngineInstall`），壳层只负责画对应弹窗。
- **流式输出就是消息增量。** `Chat.send` 在回调里直接改最后一条消息的 `content`
  与 `reasoning`；SwiftUI 按需重绘该行。没有 token 级 IPC，也没有第二个文本通道。
- **引擎差异只来自 descriptor。** 名称、强调色、端口、切换方式、能力位都读
  `id.descriptor`；页面不按引擎 id 分支。新增引擎不需要改界面。

## 视觉语言

- 画布是纯色（日间白 / 夜间暖石墨），卡片与 chrome 使用 macOS 26 Liquid Glass
  （`GlassSurface` / `GlassCard` → `glassEffect`）。窗口铺与画布一致的不透明底色，
  玻璃控件采样窗口内画布；不再自绘玻璃渐变与投影，也不再使用全透明窗口
  （切换壁纸后容易出现残影和错位）。
- 品牌色是日落橙红，只出现在主按钮、选中态、大读数与状态点；状态色是页面里
  饱和度最高的颜色。
- 危险色不交给玻璃 `tint`：tint 是层半透明色雾，红底叠红图标会被糊成一片
  （下载中心的删除按钮踩过）。危险态用中性玻璃 + 自绘的浅红底与 0.8 pt
  发丝边，图标保持满饱和，边缘由视图自己画，不经过玻璃模糊。
- 两副皮肤共享同一套语义 token（`Native` + `Theme.swift` 的 `NSColor.adaptive`），
  视图不判断当前是哪套皮肤；换肤由 `ThemeController` 改窗口外观，颜色自动重解。
  主动切换（标题栏按钮、命令面板、设置页）直接更换窗口外观，不做自定义过渡，
  沿用系统的即时切换。
- 数字用等宽 tabular 字体；正文 13pt，标题 28pt，卡片标题 15pt。
- 窗口 chrome 归 macOS：红绿灯、阴影、菜单栏都是系统画的；侧栏顶部留 42pt
  给红绿灯，内容区从窗口顶端开始排版。

## 交互约定

- **一次只做一件事。** 换引擎、换模型、安装引擎、下载模型都有单一进行中的状态，
  按钮在冲突期间禁用而不是排队；失败原因走底部 toast 或状态条。
- **不可逆动作先确认。** 删除模型、删除运行时、切换模型（会卸载权重）都先弹确认。
- **等待必须可解释。** 启停、换模型、安装、下载都显示阶段文案与进度，
  不靠一个转圈。
- **鼠标可达。** 页面跳转、启停引擎、新对话、下载中心、模型广场与外观切换都收在
  命令面板或标题栏按钮里；删除/确认弹窗的按钮都靠点击。键盘效率由 `flashcat`
  提供，界面本身不再注册快捷键。

## 边界

- **视图不取数、不写盘。** 网络请求、进程、文件与持久化都在 `AppState` /
  `FlashCatKit`；视图只调用方法。
- **视图不假设 Swift 内部实现。** 页面之间不共享视图状态；跨页面的东西
  （当前引擎、当前模型、下载任务）都从 `AppState` 读。
- **不绕过 `AppState` 直接改 `EngineStore` / `ChatHistory`。** 例外只有配置面板
  保存调优参数这类 `AppState` 没有包一层的动作。

## 已知限制

- **没有界面自动化测试。** 七个页面的渲染与弹窗开合靠手工回归；`FlashCatTests`
  只覆盖壳层的纯函数（日志切片、进程树、快照数值清洗），外加一条禁止快捷键
  回流的源码守卫。
- **Markdown 渲染是保守实现。** 支持标题、段落、围栏代码、引用、有序/无序列表、
  表格与行内语法；嵌套列表、脚注与 HTML 原样显示。
- **超长对话仍是一次性重排。** `LazyVStack` 只实例化可见行，但流式期间最后一条
  消息每帧重解析 Markdown；八千字回答的尾段成本仍是 O(n)。
