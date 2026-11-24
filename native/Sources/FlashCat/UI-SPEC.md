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

页面：概览、对话、模型库、引擎、日志、设置、画廊，以及首次启动的硬件推荐 / 引擎安装页。

## 目录

| 文件 | 职责 |
| --- | --- |
| `UI/Shell/ConsoleShell.swift` | 窗口根视图、标题栏、侧栏、页路由与全局确认弹窗 |
| `UI/Shell/StatusPill.swift` | 侧栏收起时的紧凑状态胶囊、窗口左下角的通知浮层与引擎详情弹层 |
| `App/State/IslandNotice.swift` | 通知的数据模型与信息 / 成功 / 警告 / 错误分类 |
| `UI/Components/ModelFamily.swift` | 模型家族识别与家族徽标 |
| `UI/Features/Models/ModelCardText.swift` | Hugging Face 模型卡的 Markdown 清洗 |
| `UI/Shell/CommandPalette.swift` | 命令面板：页面 / 动作 / 本地模型 / 最近对话（鼠标操作） |
| `UI/Features/Overview/OverviewPage.swift` | 页头、当前模型条、三项实时指标、吞吐曲线 / 上次运行卡、上下文、接口与三步清单 |
| `UI/Features/Chat/ChatPage.swift` | 会话转录、用户气泡 / 思考行 / 操作行（复制 / 编辑重发 / 分支）、新会话空态、输入卡与生成参数 |
| `Core/Chat/ChatThreadSections.swift` | 「最近对话」的搜索、置顶与按日期分组 |
| `UI/Features/Chat/ChatRecents.swift` | 与侧栏共用的会话行、新建对话按钮，以及对话页顶栏的历史弹层 |
| `UI/Components/MarkdownView.swift` | 对话正文的块级 Markdown 渲染（标题/列表/表格/代码/引用） |
| `UI/Components/CodeHighlighter.swift` | 代码块的语言高亮（关键字 / 字符串 / 注释 / 数字 / 类型）与按行切分 |
| `Core/Gateway/GatewaySnippets.swift` | 接口卡的 curl / Python 调用片段 |
| `Core/Gateway/GatewayClientSummary.swift` | 最近客户端按 `User-Agent` 聚合 |
| `UI/Features/Overview/GatewayTestButton.swift` | 接口测试请求与结果弹层 |
| `Core/Support/AppUpdateChecker.swift` | flashCat 自身的 releases.atom 更新检查 |
| `UI/Features/Models/ModelsPage.swift` | 本地库 / 推荐两种模式、家族聚合、排序与「能跑」过滤、下载/使用/删除 |
| `UI/Features/Models/ModelsPage.swift` 内的 `ModelRow` | 单个变体行的动作、来源与进度 |
| `UI/Features/Models/HubSheet.swift` | 模型广场：搜索、排序、格式筛选、翻页、模型卡、下载 |
| `UI/Features/Engines/DownloadCenterSheet.swift` | 下载任务：进度、暂停、继续、清理半成品 |
| `UI/Features/Engines/EnginesPage.swift` | 五台引擎的安装、启停、切换、上游版本与运行时删除 |
| `UI/Features/Engines/EngineConfigSheet.swift` | 单台引擎的调优开关 |
| `UI/Features/Logs/LogsPage.swift` | 日志：合并全部引擎、来源 / 级别 / 搜索同一行、暂停、复制、清空 |
| `Core/Logs/LogFeed.swift` | 多引擎日志尾巴合并、来源标签与按引擎指纹的增量裁剪 |
| `UI/Features/Settings/SettingsPage.swift` | 分区设置：通用 / 模型来源 / 接口 / 对话 / 关于 |
| `UI/Features/Lab/LabPage.swift` | 画廊：图片 / 视频网格、时长角标、多选导出、缩略图预取与详情入口 |
| `UI/Features/Lab/GalleryDetailSheet.swift` | 生成结果详情：大图、视频播放、参数与提示词复用 |
| `UI/Features/Chat/ChatColumn.swift` | 对话列宽换算：拖动上下限、落盘夹取与气泡 / 输入卡派生 |
| `UI/Components/VideoPlayback.swift` | 用 QuickTime 打开生成视频，失败退回默认应用 |
| `UI/Features/Launch/LaunchPage.swift` | 首次启动的硬件推荐与引擎安装 |
| `UI/DesignSystem/DesignSystem.swift` | 唯一设计源 `DS`：色阶、字号、圆角、动效、页头（`DSPageHeader`）与基础控件 |
| `UI/DesignSystem/Design.swift` / `UI/DesignSystem/Theme.swift` | 旧 token 的兼容别名与浅色 / 深色解析（`Native` / `AppAppearance`） |

## 窗口 chrome

- **标题栏。** 侧栏顶部 48pt 留给红绿灯与折叠按钮；右侧工作区各页顶部与红绿灯保持对齐。
- **侧栏。** ZCode 风格实体侧边栏（浅色 `#F0F0F0` / 深色 `#1C1C1C`），右侧以 1pt 发丝线与主工作区分隔，可整体隐藏让主视口铺满窗口；
  收起按钮与「显示 → 隐藏边栏」（`⌃⌘S`）菜单同一条路径；
  工作区七页（设置也在控制台分组里）+ 最近对话，列表直接铺到侧栏底部。侧栏收起后，
  窗口左下角出现一枚紧凑状态胶囊（引擎 / 模型 / tok/s / 网关 / 未读通知）。
- **状态胶囊。** 只在侧栏收起时出现，承载引擎与真实阶段、当前模型、解码读数与网关。
  点开一张 322pt 实色弹层：引擎详情、启停、复制接口、查看日志，以及最近通知与清空。
  命令面板同时搜索本地模型、最近 20 段对话与五个设置分区，选中模型直接切换、选中对话
  直接打开、选中分区直接落到对应设置页。`UIStateStore.toast` 的通知统一由窗口左下角的
  浮层承担，侧栏展开与收起都一样——不再有侧栏内的第二个出口。
- **页头语法。** 七个页面共用 `DSPageHeader`：页名 22pt + 一行现场（引擎 / 端口 /
  阶段，或计数）+ 右侧页面级动作；筛选条放在第二行。概览的模型名不再是页标题，
  而是页内的「当前模型条」。
- **页面切换。** 220ms 淡入 + 4pt 上移；侧栏选中态用 `matchedGeometryEffect` 在工作区导航行间滑动。
- **动效。** `DS.Motion.snappy` 180ms 用于 hover/press，`DS.Motion.smooth` 280ms 用于页面与卡片状态，
  `DS.Motion.bouncy` 轻弹簧用于命令面板；`accessibilityReduceMotion` 下关闭位移动画。

## 控件

- 控件统一走 ZCode 工作台美学（停止使用 Liquid Glass、模糊折射与大胶囊圆角）：
  侧栏、按钮、分段控件、搜索框、命令面板、输入卡与浮层使用实色分层表面 + 1px 发丝边框，
  遵循同心圆角层级（6 / 8 / 10 / 12pt）；分段控件用圆角矩形滑块（`NativeSegmented`），
  菜单用实体浮层 popover（`DSPopoverSurface` / `ModelPickerPopover`）。
- 可点击 / 可悬停的卡片表面使用 `dsSurface(..., hoverable: true)`，悬停时轻微提亮并加深边框。
- **模型卡内的动作按钮**采用 ZCode 紧凑次级描边按钮（`Radius.sm` = 6pt）；正在使用的模型卡以
  「使用中」徽标和强调色边框标记，不再整块叠色。
- **行尾删除按钮只在悬停时显形。** 常驻垃圾桶会让每一行历史都顶一个危险色标记，和行尾
  的时间读数抢注意力。侧栏「最近对话」与对话页的「…」弹层用同一个 `RowDeleteButton`：
  行宽不变，悬停时读数淡出、垃圾桶淡入；挂在行上是中性灰，真指着按钮才转危险红。
  垃圾桶与行按钮平级（`ZStack`），塞进行按钮的 label 里点击会被外层按钮吞掉。
- **下拉菜单触发器**通过 `DSMenu` 包装 `.menuStyle(.button)` + `.buttonStyle(.plain)`，
  保留图标与文字原色，外层由 `DS.rect` 填充与 1px 描边承载。

## 页面

- **概览。** 页头（页名 + 引擎现场 + 启停 / 切换模型）→ 当前模型条（家族图标、名称、
  量化 / 体积、上下文占用）→ 三格读数（平均解码 / 首字延迟 / 预填充）→ 60 秒曲线与
  右侧网关、引擎事实表 → 最近请求。停引擎时曲线位置换成「上次运行」卡：模型、
  解码、输出 tokens、时间与启动按钮；缓存命中率在引擎事实表里。
  宽版「平均解码」占更大宽度与 34pt 字号，首字 / 预填充做次级；窄版三格改成三行读数。
  接口每行保留一键复制地址，旁边的下拉给出 curl / Python 片段（模型 ID 取当前
  模型），标题旁的闪电按钮发一条真实测试请求；「最近客户端」按会话表里的
  `User-Agent` 聚合，内置对话登记为 `flashCat`。首次使用（缺引擎或缺本地权重）时
  页头下出现三步清单：装引擎 → 下模型 → 启动，可关闭。
  曲线、上下文进度与「引擎实测」角标统一取激活引擎的识别色，换引擎时数据色跟着换。
- **模型库。** 默认是「本地库」模式，只列已经落盘的权重；未下载的推荐收进单独的
  「推荐」模式。两种模式都先按引擎筛选、再按家族聚合（Qwen / MiMo / …），家族内是
  紧凑的变体行：名称、能力图标、引擎 · 量化 · 体积 · 内存下限、来源（推荐 / 个人下载）
  与动作。行高 46pt，选中行用引擎色左侧标与淡底；标题只取仓库名。
  工具条还有排序（推荐顺序 / 体积 / 内存下限 / 名称）与「能跑」过滤；本地库里若有
  下载任务，列表顶部出现「正在下载 N 项」入口。窄窗口下引擎筛选折成下拉菜单。
  超宽窗口不拉大行高，内容列由 `dsPageColumn()` 收在 1180pt。
- **引擎。** 页头「引擎」+ 已安装 / 运行中计数与检查更新；卡片只留更新与主操作，
  配置与删除收进悬停时显形的「…」菜单。
- **日志。** 页头（来源 + LIVE / PAUSED + 复制 / 打开 / 暂停 / 清空），第二行是
  来源、级别与搜索；搜索命中在行内高亮，详情同样高亮；控制台头只留 LIVE 与行数。
- **设置。** 宽版左侧分区（通用 / 模型来源 / 接口 / 对话 / 关于），窄版折成分区下拉；
  右侧只显示当前分区。接口分区写明两个本机接口始终启用；关于页可检查 flashCat 自身更新。
- **画廊。** 页头（图片 / 视频计数 + 选择、刷新、打开文件夹）+ 分段与搜索；视频封面标时长，
  选择模式可全选、批量导出到指定目录，或确认后批量删除（索引与落盘文件一起删）。

## 对话

对话页版式对齐 Splash 的 `ChatScreen` / `Composer` / `transcript`：

- **单列转录。** 内容列默认 744pt（Splash 的 680pt 正文 + 左右各 32pt），正文、输入卡和
  「回到最新」都在这条列上。列右边缘仍可拖动（下限 744，上限「页面宽度 − 40」），
  双击回到默认；拖动只改内存值，松手才写 `UserDefaults("chat.columnWidth")`，读取时
  按窗口夹一次但不回写。气泡最宽 = 列宽 − 64 − 88（默认 592）。转录底部留 44pt，
  最后一行不会贴到输入卡的阴影上。
- **用户消息。** 右对齐、强调色 12% 淡底气泡（深色 17%），圆角 18pt，无描边；正文
  15pt / 行距 3，图片 120pt 见方、圆角 12、内侧一圈发丝线。行悬停浮出复制 / 编辑重发 /
  从这里分支；编辑会先确认「这之后的 N 条回答会被删除」。
- **助手消息。** 不套气泡，直接铺在画布上。上方是思考折叠行（chevron + 「思考中」/
  「读取提示词」+ 秒数，点号与秒数始终和动词同一行；结束后是 token 数与思考时长）；
  正文按 Splash 的 15pt / 24pt
  节奏渲染，标题 20 / 17 / 15，列表标记右对齐成一列，表格只留行间发丝线，代码块用
  描边 + 语言栏 + 复制图标；代码按语言着色并带固定行号栏。正文下方是操作行：复制、最后一轮的「重新生成」，
  后面跟模型名 / tok/s / tokens / 首字 / 「已停止」。最后一轮常显（流式期间也显示），
  更早的消息悬停才浮出，免得整页挂满操作行。
- **流式输出。** `StreamingMarkdownView` 与思考正文都按 Splash `page.paced` 的节奏吐字：
  每帧放出剩余积压的 `1 − e^(−dt/100ms)`，至少一个字符；首次出现整段显示，流结束
  立即补齐。思考流式期间只显示最新约 5 行（顶部渐隐），正文开始或用户点开后展开
  全文。转录区在底部时跟随内容长高，往上翻后不再抢滚动；滚离底部浮出 30pt 的
  「回到最新」圆钮。
- **新会话。** 只留 44pt 品牌标记与一行状态（模型未运行 / 正在启动 / 引擎 · 模型），
  不再摆快捷提示卡和最近对话胶囊。输入卡与标记作为一组放在剩余空间约 1/3 处；
  第一条消息发出后输入卡平滑移到页脚（24pt），转录在它上方淡入。两种状态共用同一个
  输入卡视图，文本视图、输入法和光标不会重建。
- **输入卡。** 22pt 圆角浮层、1px 发丝边、14/4 阴影；内边距 16/10，控件行间距 8。
  上方是提示行、图片 / 视频附件，下面是 15pt 单行起、最多 220pt 的输入框。底排从左到右：
  生成参数 / 媒体按钮、「画」开关、图像工具模型、模型槽（状态点 + 模型名 + 下拉）、
  上下文环（14pt，悬停给出精确数字）、28pt 圆形发送键。思考模式与等级收进「生成参数」
  弹层，底排不再和每轮都要点的发送键抢位置。生成中发送键原地变成停止键；输入框仍可
  继续写下一句。未聚焦且草稿为空时输入区只留 22pt 一行高度，光标进来、有草稿或附件时
  长到 40pt 并为多行留出空间；占位提示只在未聚焦且草稿为空时显示，光标进来就收起，
  避免和插入点叠在一起。上下文到 80% / 95% 时，输入卡上方出现提示与「新建对话」；
  ⌘V 粘贴截图走和拖拽相同的附件路径。
- **每个会话独立草稿。** 文本与图片 / 视频附件按 `currentThreadID` 存在
  `ChatDraftStore.drafts` 里（单独的 store，不桥回 AppState，避免逐字重绘整个壳层）；
  切会话、切页只换键，不会把上一段对话的附件带进下一段。
- **会话列表。** 「最近对话」带搜索（标题与消息正文），按置顶 / 今天 / 昨天 / 最近 7 天 /
  最近 30 天 / 更早分组；置顶的按置顶时间倒序。每行悬停浮出「…」菜单，右键同一组动作：
  置顶 / 取消置顶、重命名…、删除…。顶栏只显示当前会话标题 + 下拉箭头，菜单同样三项；
  删除与改名由壳层统一弹确认 / 输入框。历史上限 200 条，改名与置顶在每轮保存后保留。
- **对话页的会话入口。** 顶栏在标题左侧常驻 `clock.arrow.circlepath`，点开一张
  300pt 宽的实色浮层：标题行是「最近对话」+「新对话」，下面是同一套搜索与分组列表，
  点会话、新建、改名或删除后浮层自动收起；顶栏右侧常驻「新对话」按钮。边栏收起时
  也能在对话页里换会话、开新对话。

## 画廊

- **第七页。** 侧栏「对话」之后是「画廊」（`flask`；英文界面叫 Gallery），页头下面是实色
  分段在「图片 / 视频」之间切换。两个库都只认 assistant 消息里落盘的结果，
  用户拖进输入卡的底图与首帧图不会混进来。
- **连续滚动。** 网格按可用宽度排布（`DSAnimatedGrid`），全部作品由滚动承载；
  封面按目标像素异步解码后进 `ImageThumbnailCache`，主线程不碰原图。
- **详情。** 点开进 `GalleryDetailSheet`：图片看大图，视频用 `VideoPlayer` 原位播放；
  旁边列出模型、尺寸、步数、seed 与提示词，提示词可复制，也可以带着 seed 回填到输入卡再画一次。
- **两条生成链路。** 图像走 `ImageClient`（SSE 进度 + 最终图），视频走 `VideoClient`
  （SSE 进度 + 帧数据，mp4 在后台线程编码；发出前先按 RGB 体积预检载荷）。两者与
  对话里的画图共用同一套阶段文案和占位位置。

## 键盘策略

应用采用**声明式 SwiftUI 快捷键 + 命令行互补**的策略，保留安全、无侵入的系统菜单与焦点内键盘操作：
- **允许的声明式快捷键**：系统菜单栏命令（`⌘K` 命令面板、`⌘1`–`⌘6` 切换对话/画廊/概览/模型库/引擎/日志、`⌘,` 设置、`⌘N` 新建对话、`⌃⌘S` 折叠边栏）、命令面板的方向键/回车/Esc、以及搜索框和弹窗的 Esc/回车提交。
- **仍然禁止的做法**：不允许在 `Sources/FlashCat` 注册全局或局部 `NSEvent` 键盘监听（`addGlobalMonitorForEvents` / `addLocalMonitorForEvents`），避免干扰系统输入法或全局快捷键管理器；`override func keyDown(with:)` 依然只允许出现在 `UI/Features/Chat/ChatComposerField.swift`（负责回车发送、⇧回车换行、Escape 停止生成，并在 `hasMarkedText()` 组字期间交回 AppKit）。
- 这两项边界由 `LocalizationTests.testNoInAppKeyboardShortcutsRemain` 与 `testReturnKeyIsOnlyHandledByComposer` 持续守卫；批量自动化与脚本效率继续由 `flashcat` 命令行承担。

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
  60 秒曲线、「最近请求」逐行、菜单栏从同一组
  函数取数，数值与角标同源；以前 hero 走网关、预填充格走引擎、菜单栏引擎优先，
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
  `LIVE` 的预填充值是最近约 1.2 秒（1~2 个 chunk）的窗口速度，不是整轮请求的累计平均。
- **首字延迟格（`ttftReading`）优先引擎、网关兜底。** 引擎 status 有正样本时
  用它（splash 是 `ttft_ms.p50`，mlx-serve 是直方图均值，MTPLX 是上一请求值）；
  引擎没有这个字段（oMLX）或首个请求之前还没样本（splash 报 0）时，
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

- 画布与表面对标 ZCode（Zai Light / Zai Dark）：日间浅灰画布 `#F8F8F8` + 侧栏 `#F0F0F0` + 卡片 `#FFFFFF`；
  夜间深灰画布 `#161616` + 侧栏 `#1C1C1C` + 卡片 `#222222`（浮层 `#282828`）。全部采用纯实色分层与 1px 发丝边框，
  不自绘装饰性环境光晕、不提供桌面透明透出或自定义背景图。
- 主动作按钮采用高对比单色墨块（日间 `#171717` / 夜间 `#EDEDED`）；聚焦、链接与关键强调色使用
  ZCode 蓝（日间 `#0B7FFF` / 夜间 `#3B82F6`），状态色只用于状态。
- 危险态采用浅红实色底 + 1px 描边 + 高对比红字，图标与文字保持清晰可读。
- 两副皮肤共享同一套语义 token（`DS` + `UI/DesignSystem/Theme.swift` 的 `NSColor.adaptive`），
  视图不判断当前是哪套皮肤；换肤由 `ThemeController` 改 **内容视图** 的外观
  （`window.contentView.appearance`），颜色自动重解，不做自定义过渡。
- 窗口本身的外观恒定是 Aqua，**不跟着皮肤走**：macOS 按窗口外观画窗口阴影，
  窗口一旦是 `darkAqua`，系统会在四周压出一圈约两倍重、近黑的投影（跟随系统
  切到深色时会看到 app 外一圈黑影）。皮肤因此落在内容视图上，窗口只负责
  红绿灯与阴影，始终是浅色外观。SwiftUI 的 `.preferredColorScheme` 不能再用
  ——它会把窗口外观改成 `darkAqua`，阴影问题会回来；换肤改由 `ThemeController`
  驱动。
- 因为窗口外观是 Aqua，内容视图解析出的深色语义色不能交给窗口用：
  `BackgroundSurface` 先按内容视图的外观把纯实色画布解成静态 sRGB 再涂给始终不透明的窗口，
  否则圆角外露出的底色会是浅色（白边闪烁）。
- 跟随系统时 `ThemeController.systemIsDark` 是 `@Published`，系统换肤通知
  （`AppleInterfaceThemeChangedNotification`）一到就重解并立即重绘，不需要
  切到别的 app 再切回来。sheet / alert 是自己的窗口，外观在
  `NSApplication.didUpdateNotification` 里补上皮肤。
- 数字用等宽 tabular 字体；正文 13pt，标题 28pt，卡片标题 15pt。
- 超宽窗口下七个控制台页面共用一个内容列：页头、筛选条与主体一起收在
  `DS.Layout.pageMaxWidth`（1180pt）内居中，不在大屏上横向拉满。
- 引擎识别色是页面上唯一的数据色：概览曲线、上下文进度、「引擎实测」角标与选中的
  模型卡都取激活引擎的颜色；引擎图标保留官方的原始配色，只加一圈同色描边。
- 窗口 chrome 归 macOS：红绿灯、阴影、菜单栏都是系统画的；侧栏顶部留 42pt
  给红绿灯，内容区从窗口顶端开始排版。

## 交互约定

- **一次只做一件事。** 换引擎、换模型、安装引擎、下载模型都有单一进行中的状态，
  按钮在冲突期间禁用而不是排队；失败原因走左下角浮出的通知。
- **不可逆动作先确认。** 删除模型、删除运行时、删除对话、切换模型（会卸载权重）都先弹确认。
  删除对话的确认由壳层统一弹出（`AppState.pendingThreadDelete`），侧栏与对话页两个入口
  只是把要删的那条挂上去，确认后才真正落盘。
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
