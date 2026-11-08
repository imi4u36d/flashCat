---
id: flashcat-ui
type: submodule-design
status: draft
title: 原生界面 — 六个页面与控制台壳
parent: flashcat-app
---

# 原生界面 — 六个页面与控制台壳

## 职责

整个可见界面。六个页面、首次启动页、下载中心、模型广场、引擎配置与对话参数全部是
SwiftUI / AppKit 视图，直接读取 `AppState` 的 `@Published` 状态，用户动作直接调用
`AppState` 的方法。没有 `WKWebView`、没有 HTML/CSS/JS、没有序列化桥、没有打包产物。

页面：概览、对话、模型、引擎、日志、设置，以及首次启动的硬件推荐 / 引擎安装页。

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
| `UI/LaunchPage.swift` | 首次启动的硬件推荐与引擎安装 |
| `Design.swift` / `Theme.swift` | 设计 token、组件与外观（`Native` / `AppAppearance`） |

## 窗口 chrome

- **标题栏。** 一行 48pt：红绿灯留白、折叠边栏、居中的灵动岛（引擎名、真实阶段、实时 tok/s 与启停；
  通知到来时临时显示消息并计未读，点开原地展开通知历史或引擎详情）、命令面板入口、
  外观切换、下载中心（带任务徽标）。
- **侧栏。** 悬浮玻璃导航列，可整体隐藏让主视口铺满窗口；收起按钮在红绿灯右侧，
  与「显示 → 隐藏边栏」菜单同一条路径；
  工作区六页 + 最近对话 + 引擎卡（启停与切换）+ 反馈入口。
- **页面切换。** 220ms 淡入 + 8pt 上移；侧栏选中态用 `matchedGeometryEffect` 在行间滑动。
- **动效。** `Motion.quick` 140ms 用于 hover/press，`Motion.standard` 220ms 用于页面与卡片状态，
  `Motion.entrance` 轻弹簧用于消息与 toast；`accessibilityReduceMotion` 下关闭位移动画。

## 控件

- 控件统一走 macOS 26 Liquid Glass：侧栏、标题栏按钮、命令面板、输入卡与浮层使用
  `glassEffect`（`LiquidGlassSurface`），互斥按钮组用系统 `.tabs` 分段控件（`NativeSegmented`）；
  卡片也用同一层玻璃材质，但正文只靠排版分层，不在内容上再叠色。
  菜单用系统玻璃 popover（如 `ModelPickerPopover`）。

## 键盘策略

**应用不注册任何键盘快捷键。** 菜单项、工具栏按钮和命令面板都不带按键等价物；
对话输入框不把回车当发送，命令面板不接管方向键 / 回车 / esc，搜索框也不在回车
时提交——这些动作一律由点击完成。这样做的原因不是「不要键盘」，而是把键盘
效率集中到 `flashcat` 命令行：它支持补全、JSON、脚本与批量动作，且不会和用户
自己的快捷键管理器打架。

命令面板因此只负责「点击一行运行命令」；搜索框仍然可以输入文字（文本编辑不是
快捷键）。检查由 `FlashCatTests.LocalizationTests.testNoInAppKeyboardShortcutsRemain`
守着：`.keyboardShortcut`、`.onKeyPress`、`.onExitCommand`、`.onSubmit` 和
`NSEvent` 全局/本地监听都不允许再出现在 `Sources/FlashCat` 里。

macOS 自己提供的文本编辑与剪贴板快捷键、关闭窗口与退出等系统级菜单项不受影响，
它们属于 AppKit，不属于这个应用。

## 状态与数据流

- **单一状态源。** `AppState`（`@MainActor`，`ObservableObject`）持有全部可变状态：
  引擎、模型库、会话、下载、设置、外观、侧栏。视图只读，不缓存副本。
- **没有快照协议。** 页面直接订阅 `@Published`；引擎指标空闲时按 1 秒轮询，
  预填充时按 0.4 秒轮询（`prefill_tokens_live` 只在 chunk 完成时前进，1 秒采样
  经常整块跨过），但只是普通状态变化，不经过 JSON 序列化，也不存在「快照与实时流
  谁领先」的问题。空闲时**不**降频：隔秒轮询会把累计计数器的差分窗口从 1 秒拉成 2 秒。
- **概览速度统一走网关。** 解码速度的 hero 大数字、60 秒曲线与「最近请求」逐行都读
  `GatewayMeter` 的按请求低通聚合，所以大数字就是活跃行之和；应用内对话也注册在网关里。
  引擎的 `LAST` / `AVG` 不参与当前速度，只有网关没有在跑会话（客户端直连引擎端口）时
  才用引擎的 `.live` 计数兜底，且要求 `activeRequests > 0`。角标如实写「网关估算」/
  「网关 LAST」/「引擎实时」；请求结束后保留最近一条请求的终值并标「网关 LAST」，
  「最近请求」也不再清空，直到它被后续请求挤出列表。
- **生命体征仍由引擎上报，并自证粒度。** 预填充、首字延迟 p50、内存占用、上下文上限
  与 `SESSIONS`（`activeRequests`）读引擎 status，卡片说明标明「引擎」；预填充不是连续量，按 `EngineRateKind` 打
  `LIVE` / `LAST` / `AVG` 角标，说明随之改口（「正在处理提示词」/「上一个请求的实测值」/
  「开机以来均值」）。`LIVE` 的预填充值是最近约 1.2 秒（1~2 个 chunk）的窗口速度，
  不是整轮请求的累计平均；灵动岛只说当前速度，因此只在 `.live` 时采用引擎读数。
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

- **没有界面自动化测试。** 六个页面的渲染与弹窗开合靠手工回归；`FlashCatTests`
  只覆盖壳层的纯函数（日志切片、进程树、快照数值清洗），外加一条禁止快捷键
  回流的源码守卫。
- **Markdown 渲染是保守实现。** 支持标题、段落、围栏代码、引用、有序/无序列表、
  表格与行内语法；嵌套列表、脚注与 HTML 原样显示。
- **超长对话仍是一次性重排。** `LazyVStack` 只实例化可见行，但流式期间最后一条
  消息每帧重解析 Markdown；八千字回答的尾段成本仍是 O(n)。
