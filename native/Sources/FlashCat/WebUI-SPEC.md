---
id: flashcat-webui
type: submodule-design
status: draft
title: WebUI — 六个页面与 Swift 桥
parent: flashcat-app
---

# WebUI — 六个页面与 Swift 桥

## 职责

整个可见界面。六个页面加启动页全部是 HTML / CSS / JS，由 `WKWebView` 承载（`Package.swift` 以 `.copy("WebUI")` 把整个目录打进 bundle）。这份规格因此放在 `WebUI/` 之外：目录里的东西原样进应用包，规格该留在源码树里，否则每构建一次就多出一份同 id 的内部文档。这一层只渲染 Swift 推来的状态，并把读者操作变成命令发回去。

页面：概览、对话、模型、引擎、日志、设置，以及首次启动的引擎安装页。

## 桥协议

这是本模块与外界的**唯一**接口，双向、序列化、无共享内存。

- **Swift → JS：全量状态快照。** 由 Combine 订阅加 1 秒心跳驱动，0.1 秒去抖合并。网页不做增量订阅，也不自己取数。
- **JS → Swift：`webkit.messageHandlers.bridge`。** 载荷是 JSON `{type, payload}`。命令覆盖导航、窗口拖动、引擎启停/切换、模型使用与下载、对话收发与线程切换、复制、日志清理、设置保存、外观切换、引擎安装与升级、以及各处的确认/取消。

确认类交互（换模型、选库、装引擎）也走这条路径，但状态由 Swift 侧持有（例如 `confirmingModelSwitch`），网页只负责显示与回传选择——网页不做前置判断。

**Hub 搜索的两格。** 命令 `searchHub {query}`，空 `query` 即清空；快照字段 `hubSearch` 在没有搜索时是 `null`，否则 `{query, state: idle|loading|failed, error, results: [...]}`，`results` 只含**当前栏**（模型的 `libraryEngine`）的命中——归属由 Swift 侧的格式判定给出，网页不自己过滤。换栏时 Swift 侧清空搜索。

结果项：`id`（`owner/repo`，或带量化的 `owner/repo:VARIANT`）、`repo`、`display`（仓库短名）、`engine`（单值 `splash|omlx|mtplx`）、`kind`（`gguf|mtplx|mlx|unmarked`）、`bytes`、`memory`（GB 整数）、`estimated`（`true` 表示 `bytes × 1.2` 的估算，界面一律加 ≈）、`downloads`、`originText`（固定 `Hugging Face`）、`options`（`[{name, label, bytes, memory, estimated}]`，GGUF 多量化各一档，其余格式是一条 `name` 为空的记录），可选 `summary`、`tags`。

下载复用现有那一格：`downloadModel {engine, id}`，`id` 直接带 `:VARIANT`。结果只活在 Swift 侧的内存会话里，网页不缓存、不重试、不自己请求 Hugging Face，也没有「搜索历史」可言。

## 边界

- **网页不取数、不写盘。** 没有直接网络请求，没有持久化：偏好、历史、下载任务都在 Swift 侧落盘，网页刷新后从快照重建。
- **不假设 Swift 内部类型。** 只依赖桥协议的字段，不依赖 Swift 的类型名或文件结构。
- **视觉方向是「精密仪器」。** 页面底色是纯白（日）/ 暖石墨（夜），日间不带暖调：卡片靠 1px 毛发描边分层，不靠米色底与白面板的色差。数字是等宽大读数，状态色是页面里饱和度最高的颜色。品牌日出渐变只允许出现在三处（应用图标与侧栏 Logo、AI 消息头像、对话空状态），不许扩散到画布和卡片。
- **两副皮肤共享同一套语义 token。** 取值随外观解析，页面代码永远不分支判断当前是哪套皮肤；换肤是改一次解析结果，不是改两份样式。

## 决策

**表现层用网页而不是原生视图。** 有一个给定的视觉稿要求六个页面 1:1 还原，原生视图做不到那种还原度。代价是多一层跨语言桥与一份状态序列化成本；收益是视觉稿能被精确实现，且状态管线仍然留在 Swift 里（网页只当渲染器，不是应用逻辑的家）。

**快照全量推送，不做增量协议。** 状态规模小、页面少，全量快照加去抖合并足以保持流畅，换来的是网页侧无状态——不必维护 apply/diff 逻辑，也就没有"两边状态不同步"这一类 bug。

## 已知限制

- **没有任何自动化测试。** 桥的两端都没有覆盖：命令分发、快照字段、以及页面行为只能靠手工回归。
