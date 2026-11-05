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
| `UI/ConsoleShell.swift` | 窗口根视图、标题栏、侧栏、页路由、全局确认弹窗与 toast |
| `UI/CommandPalette.swift` | ⌘K 命令面板：页面跳转与常用动作 |
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
| `UI/SettingsPage.swift` | 外观、服务、网关、生成默认值、存储与关于 |
| `UI/LaunchPage.swift` | 首次启动的硬件推荐与引擎安装 |
| `Design.swift` / `Theme.swift` | 设计 token、组件与外观（`Native` / `AppAppearance`） |

## 窗口 chrome

- **标题栏。** 一行 48pt：红绿灯留白、折叠边栏、当前引擎胶囊（状态点、名称、状态、实时 tok/s，点击启停）、
  命令面板入口（⌘K）、外观切换（⌘⇧A）、下载中心（带任务徽标）。对应 1.3 起 WebUI 的 titlebar。
- **侧栏。** 216pt 展开 / 76pt 图标档，右缘可拖动改宽（180–320，落盘到 `sidebarWidth`）；
  工作区六页 + 最近对话 + 引擎卡（启停与切换）。
- **页面切换。** 220ms 淡入 + 8pt 上移；侧栏选中态用 `matchedGeometryEffect` 在行间滑动。
- **动效。** `Motion.quick` 140ms 用于 hover/press，`Motion.standard` 220ms 用于页面与卡片状态，
  `Motion.entrance` 轻弹簧用于消息与 toast；`accessibilityReduceMotion` 下关闭位移动画。

## 控件

- 互斥按钮组（引擎切换、日志级别、外观、思考模式与等级）统一使用 macOS 26 原生
  `Picker(.segmented)`（`NativeSegmented`），由系统绘制 Liquid Glass 选中态；
  其余主/次按钮仍用 `ConsolePillStyle` 以贴合 WebUI 的胶囊形。

## 快捷键

| 键 | 动作 |
| --- | --- |
| ⌘K | 命令面板 |
| ⌘1…⌘6 | 六个页面 |
| ⌘\\ | 折叠 / 展开侧栏 |
| ⌘⇧A | 切换浅色 / 深色 |
| ⌘N | 新对话 |
| ⌘↩ | 发送（对话输入框内回车也发送，⇧↩ 换行） |
| esc | 关闭命令面板 / 浮层 |

## 状态与数据流

- **单一状态源。** `AppState`（`@MainActor`，`ObservableObject`）持有全部可变状态：
  引擎、模型库、会话、下载、设置、外观、侧栏。视图只读，不缓存副本。
- **没有快照协议。** 页面直接订阅 `@Published`；引擎指标仍按 1 秒轮询更新，
  但只是普通状态变化，不经过 JSON 序列化，也不存在「快照与实时流谁领先」的问题。
- **动作即方法调用。** 导航 `state.section = .models`，启停 `state.toggleService()`，
  换模型 `state.applyModelFromAnyEngine(id, engine:)`，下载 `state.downloadModel` /
  `state.downloadShared`。确认类交互由 `AppState` 持有（`confirmingModelSwitch`、
  `pendingLibraryUse`、`pendingEngineInstall`），壳层只负责画对应弹窗。
- **流式输出就是消息增量。** `Chat.send` 在回调里直接改最后一条消息的 `content`
  与 `reasoning`；SwiftUI 按需重绘该行。没有 token 级 IPC，也没有第二个文本通道。
- **引擎差异只来自 descriptor。** 名称、强调色、端口、切换方式、能力位都读
  `id.descriptor`；页面不按引擎 id 分支。新增引擎不需要改界面。

## 视觉语言

- 画布是纯色（日间白 / 夜间暖石墨），卡片是 `GlassSurface`：面板色 + 1px 毛发描边。
  没有玻璃渐变、没有网页式投影；投影只留给窗口级浮层。
- 品牌色是日落橙红，只出现在主按钮、选中态、大读数与状态点；状态色是页面里
  饱和度最高的颜色。
- 两副皮肤共享同一套语义 token（`Native` + `Theme.swift` 的 `NSColor.adaptive`），
  视图不判断当前是哪套皮肤；换肤由 `ThemeController` 改窗口外观，颜色自动重解。
- 数字用等宽 tabular 字体；正文 13pt，标题 28pt，卡片标题 15pt。
- 窗口 chrome 归 macOS：红绿灯、阴影、菜单栏都是系统画的；侧栏顶部留 42pt
  给红绿灯，内容区从窗口顶端开始排版。

## 交互约定

- **一次只做一件事。** 换引擎、换模型、安装引擎、下载模型都有单一进行中的状态，
  按钮在冲突期间禁用而不是排队；失败原因走底部 toast 或状态条。
- **不可逆动作先确认。** 删除模型、删除运行时、切换模型（会卸载权重）都先弹确认。
- **等待必须可解释。** 启停、换模型、安装、下载都显示阶段文案与进度，
  不靠一个转圈。
- **键盘可达。** ⌘1…⌘6 切页、⌘\ 折叠侧栏、⌘N 新对话、⌘↩ 发送；
  删除/确认弹窗的默认按钮有 `keyboardShortcut`。

## 边界

- **视图不取数、不写盘。** 网络请求、进程、文件与持久化都在 `AppState` /
  `FlashCatKit`；视图只调用方法。
- **视图不假设 Swift 内部实现。** 页面之间不共享视图状态；跨页面的东西
  （当前引擎、当前模型、下载任务）都从 `AppState` 读。
- **不绕过 `AppState` 直接改 `EngineStore` / `ChatHistory`。** 例外只有配置面板
  保存调优参数这类 `AppState` 没有包一层的动作。

## 已知限制

- **没有界面自动化测试。** 六个页面的渲染、弹窗开合与键盘快捷键靠手工回归；
  `FlashCatTests` 只覆盖壳层的纯函数（日志切片、进程树、快照数值清洗）。
- **Markdown 渲染是保守实现。** 支持标题、段落、围栏代码、引用、有序/无序列表、
  表格与行内语法；嵌套列表、脚注与 HTML 原样显示。
- **超长对话仍是一次性重排。** `LazyVStack` 只实例化可见行，但流式期间最后一条
  消息每帧重解析 Markdown；八千字回答的尾段成本仍是 O(n)。
