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

页面：概览、对话、模型、引擎、日志、设置，以及首次启动的硬件推荐 / 引擎安装页。

**`WebUI/` 自身就是唯一视觉源。** 早期那条 `preview/liquid-glass` 预览稿 + `sync-preview-ui.sh` 复制 + `patch-preview-ui.py` 补丁的链路已经移除：预览与应用曾经用两套不同的对话页 markup，样式互相覆盖，改一处看不到另一处。现在样式、组件和动效都直接在这个目录里维护，`index.html` 与 `app-shell.css` 只保留真实原生窗口内的 UI。

`WebUI/live.js` 是应用侧适配层：把 Swift 快照转换成组件需要的视图状态，把点击变成 `webkit.messageHandlers.bridge` 命令。`app.js` / `*-workspace.js` 负责版式与动效。

## 桥协议

这是本模块与外界的**唯一**接口，双向、序列化、无共享内存。

- **Swift → JS：全量状态快照。** 由 Combine 订阅加 1 秒心跳驱动，0.1 秒去抖合并。网页不做增量订阅，也不自己取数。
- **JS → Swift：`webkit.messageHandlers.bridge`。** 载荷是 JSON `{type, payload}`。命令覆盖导航、窗口拖动、引擎启停/切换/安装/删除、模型使用与下载、对话收发与线程切换、复制、日志清理、设置保存、外观切换、以及各处的确认/取消。

确认类交互（换模型、选库、装引擎）也走这条路径，但状态由 Swift 侧持有（例如 `confirmingModelSwitch`），网页只负责显示与回传选择——网页不做前置判断。

**模型广场（Hub）就一个搜索窗口。** 命令 `searchHub {query, sort, filter, page}`：`query` 为空就是热门列表，`sort` 取 `trending|downloads`，`filter` 取 `all|mlx|gguf`（HF 一页 30 条，`page` 从 0 起）。快照字段 `hub` 是 `{query, sort, filter, page, hasMore, loading, detailLoading, error, results: [...], detail, local, shared}`——排序、格式筛选、翻页和模型卡都由 Swift 侧取数，网页不请求 Hugging Face、不按引擎过滤、也不判断某个仓库能不能加载。打开广场且没有上次查询时，网页会先发一次空 query 拿热门列表，而不是摆一个空面板等人输入。

结果项是 `HubModel.json`：`id`、`downloads`、`likes`、`tags`、`mlx|gguf|mtplx`、`gated`、`pipeline`/`io`、`quantization`、`memoryMin`/`memoryMax`、`engine`/`engineID`（`none` 表示没有引擎认领这个格式）、`parameters`、`size`、`license`、`updated`。列表行据此画格式角标、归属引擎、量化、体积、内存与下载量。`local`/`shared` 是 Swift 判好的「已在本机」清单，网页只照着置灰下载按钮。

**模型卡。** 点一行发 `hubDetail {repo}`；快照里的 `detail` 回填后显示 README（`modelCard` 原文，网页只去 HTML/图片标记）、文件清单与标签，`hub-back` / `closeHubDetail` 收起。详情带上 `files` 与 `size`，列表行不重复请求。

快照同时下发 `engineCatalog`：每个引擎的 `id/name/summary/accent/adapter/defaultPort/switchMode/installed/capabilities`。网页的引擎页、启动页、侧栏 chip、模型筛选和端口设置都从这里生成，不再维护 `splash|omlx|mtplx` 固定数组；运行时现在是五个（Splash / oMLX / MTPLX / MLX-Serve / Strata）。

**下载两条路。** 模型页卡片的「下载」走 `downloadModel {engine, id}`，装进该引擎自己的模型目录；广场的下载走 `downloadRepo {repo, engines}`，落到公共目录、只存一份，`engines` 先是格式归属的那个引擎，没有归属时退到当前浏览的引擎（之后可在模型页的「放到哪些引擎…」里改授权）。两边都不在网页缓存或重试，也没有「搜索历史」；搜索结果只活在 Swift 侧的内存会话里。

**下载进度只有一份。** `downloads.active`（正在跑的子进程）加 `downloads.tasks`（排队 / 暂停 / 失败的行）是卡片和下载中心共用的唯一来源；卡片按 `engine + 规范化的 repo id` 匹配，所以扁平目录的 `owner--repo` 也能对上 `owner/repo` 的任务。只要这个模型还有一行任务，卡片就只显示进度（下载 / 已暂停 / 下载失败），不显示「使用」：下载中的进度按钮打开下载中心；已暂停的按钮直接 `resumeDownload` 续传，不绕一步下载中心。暂停的行在续传时从已有字节接着走，百分比始终是「已下载 / 总量」，不会回到 0%。Swift 侧同时用任务行与目的地旁的 `.flashcat-incomplete` 标记把半成品目录挡在模型库之外——`config.json` 和 tokenizer 先落盘不等于下载完成；只有下载成功才删标记，在下载中心移除暂停 / 失败任务时连同半成品目录一起清理。卡片不再挂「已下载 / 下载中」的状态胶囊：装好的卡片只在右上角留一枚「更多」菜单（在 Finder 中显示、复制 ID、删除），动作区只放「使用」；下载中的卡片右上角留空，进度由动作区的百分比按钮和卡片底部的进度条表达。

**模型列表的两份。** `library.entries` 是当前浏览引擎那一栏；`modelsAll` 是所有引擎的平铺条目，模型页的「全部 / 各引擎」筛选与卡片池都读它。每项除 `installed`、`source`、`originText` 外，目录项还带 `summary`、`minMemory`、`fit`（`good|unknown|tight|diskShort`）和 `rank`。模型页按「当前浏览引擎优先、已装优先」排序，不再自己判断档位是否适合这台机器（`fit` 由 Swift 算）。

其余应用侧字段：`threadID` 让侧栏高亮当前对话，`appVersion` 给设置页版本行，`enginesInstall[id].logsDir` 给配置面板的日志目录。每条回答还带 `reasoning`（思考流）、`thinkingSeconds`（正文首字前的时间，落盘后旧回答仍能显示「思考了 8.4 秒」）、`createdAt`（思考计时起点）、`model`（写入时的模型，决定头像家族图标）与 `rate`/`ttft`/`tokens`。

**对话正文是 Markdown，不是纯文本。** 模型输出按块渲染：标题、段落、围栏代码、引用、有序/无序/任务列表、表格、分隔线，以及行内的粗体、斜体、删除线、代码、链接、图片占位。渲染器在 `WebUI/chat-markdown.js`：先整体转义，再只插入自己构造的标签；链接只放行 `http(s)`／`mailto`／站内锚点，`javascript:`、`data:` 一律降级为可见文字；远程图片不发起请求，只显示 alt 文字的小标签。流式期间 `FCChatMarkdown.sync()` 复用未变化的块，只重画仍在生长的那一块——一条已经八千字的回答，每帧成本仍然只是最后一段；纯文字增量更进一步直接追加到该段的文本节点，连分块都省掉。

## 边界

- **网页不取数、不写盘。** 没有直接网络请求，没有持久化：偏好、历史、下载任务都在 Swift 侧落盘，网页刷新后从快照重建。
- **不假设 Swift 内部类型。** 只依赖桥协议的字段，不依赖 Swift 的类型名或文件结构。
- **视觉方向是 Liquid Glass。** 页面底色是雾蓝（日）/ 深石墨（夜），窗口内是半透明玻璃面、细描边和柔和大圆角；品牌色是日落粉橙，状态色只出现在状态点、进度和读数上。日落渐变只允许出现在应用图标、侧栏 Logo、AI 消息头像与对话空状态。
- **两副皮肤共享同一套语义 token。** 取值随外观解析，页面代码永远不分支判断当前是哪套皮肤；换肤是改一次解析结果，不是改两份样式。
- **窗口 chrome 归原生。** 红绿灯、菜单栏、窗口阴影都由 macOS 画；网页只画标题栏那一行内容（折叠手柄、引擎状态、外观、下载中心）。

## 决策

**表现层用网页，视觉源是预览而不是另写一套。** 预览已经承载了版式、动效和组件拆分，应用再抄一份必然漂移。所以复制预览文件、用 `live.js` 注入真实数据，并把三处数据形状差异（五个运行时、全引擎模型池、快照启动）收敛到一个可重放的补丁脚本里。代价是预览的 mock 外壳需要保持可替换；收益是预览更新可以一条命令同步，且 1:1 不再靠手工比对截图。

**快照全量推送，不做增量协议。** 状态规模小、页面少，全量快照加去抖合并足以保持流畅，换来的是网页侧无状态——不必维护 apply/diff 逻辑，也就没有「两边状态不同步」这一类 bug。

**应用功能在预览骨架上补齐，而不是另起一套页面。** 启动页、Hub、最近对话、下载中心、模型更多菜单、引擎配置面板都复用预览的 `.widget` / `.glass-sheet` / `.fc-*` 组件与 token，避免出现「预览里有、应用里没有」的第二套视觉。

## 实现注记

- **WKWebView 的浮层命中与 Chrome 不同。** 预览的 `.overlay-layer` 是 `pointer-events:none`，子面板各自 `auto`；在 Chrome 里没问题，在 WKWebView 里子面板会「看得见、点不到」。应用在 `is-open` 时把整层恢复为 `auto`，并让透明区域点击关闭当前面板；模型广场更进一步挂到 `body` 的 `position:fixed` 层（`z-index:500/501`）。
- **不要把新的浮动面板只做成「父层 none + 子层 auto」。** 要么挂在 `body`，要么确认父层在打开时是 `auto`，否则会重演「关闭按钮点不动」。
- **关闭的面板必须让出命中测试。** 模型广场关闭后仍留在 DOM 里做退场动画，但 `opacity: 0` 不会停止点击：`.fc-hub:not(.is-open) { pointer-events: none; }` 是必需的，否则它会继续盖住模型页右上角，把「模型广场」入口的点击吃掉。
- **预览里的假系统栏元素不存在。** `startClock` 在 `#systemClock` 缺失时直接返回；一旦在初始化里抛错，`bindGlobalEvents` 及其后的自定义监听都不会注册。
- **概览页不跑预览的 mock telemetry。** `live.js` 覆盖 `initFlowHistory` / `startLiveTelemetry` / `drawFlowField` / `updateFlowProbe`：曲线只画 `snapshot.throughput` 里带时间戳的真实采样（时间做 x 轴、峰值做 y 轴，超过 3 秒的断档断开），节奏条取最近 20 秒、TTFT 点在 0–2000 ms 轨道上、预填充按真实 tok/s 点亮档位、内存格按上报占用填充。停止引擎时这些视觉全部回到空态，不再用定时器续一条假曲线。
- **模型家族图标是 `model-brand.js` 的职责。** 它按仓库名/显示名匹配 Qwen、Xiaomi MiMo、DeepSeek、Llama、Gemma、Kimi、GLM、MiniMax、Mistral、Yi、Baichuan、StepFun、Cohere、Grok；匹配顺序有意义（`MiMo-V2.6-Qwen-9B` 先认 MiMo，蒸馏 Qwen 先认 DeepSeek）。字形是 `currentColor` 内联 SVG，`--fc-series` 决定底色；认不出的包用首字母字母块，不再回落到统一的 CPU 芯片。图标来自 Lobe Icons（MIT，见 `LOBE-ICONS-LICENSE.txt`）与 Simple Icons（CC0）。AI 消息头像也走这条路径：快照里的每条回答带写入时的 `model`，头像据此取家族图标，切换模型后旧回答不会换头像。
- **模型切换不重绘对话页和概览页。** `selectedModel`、引擎运行状态、切换阶段和上下文占用都不进这两页的指纹；对话页的模型 chip、引擎状态 pill、`已用 / 总量` 由 `syncChatChrome()` 原地更新，概览页的引擎 widget（状态 pill、模型标题、切换阶段、按钮、live 面板空态）由 `syncOverviewChrome()` 原地更新。快照变化只在消息体真的变了时替换 `#messagesInner`，标题栏、侧栏和输入框保持不动。消息入场动画只给当前线程里第一次出现的消息（`is-new`，动画结束即移除），所以切换模型或流式增量不会让整段对话重新淡入。
- **下载进度不进指纹，卡片和下载中心只补数字。** `downloads` 里的 `fraction` / `downloadedBytes` / `speed` 每 500ms 变一次；把它们算进模型页指纹，整页就会跟着半秒重建一次，鼠标停在卡片上时悬停的描边/投影过渡被反复从基础态重放，看起来就是卡片在闪。指纹只留任务形状（`downloadShape()`：谁在下、什么状态、共享给谁），数字由 `FCModelWorkspace.patchProgress()` 与 `patchDownloadRows()` 改写文字和进度条宽度，卡片、行、按钮和转圈的 loader 都留在原节点上。暂停/下载完成这类结构变化仍然整页渲染。库快照同理：`library.entries[].bytes` 是扫描到的磁盘大小，下载中每写一块就变，指纹改用 `libraryShape()`（只留 id、引擎、安装态、标签等结构/文案字段）。SIZE 不拿下载任务总量改写——一次下载会顺带抓草稿头、mmproj 和分片，任务总量不等于这张卡的权重体积；半截扫描值也不进指纹，卡上保留渲染时的大小，任务行消失（下载结束）时再刷新。
- **引擎安装进度同理，只补进度条。** `enginesInstall` 里的 `progress` / `step` 每 100~500ms 变一次，进指纹会让引擎页和首次安装页每次推送都整页重建：引擎卡片的进度条宽度没有过渡可播（一格一格跳），运行中卡片那排 `fc-engine-signal` 呼吸条也会从头开始。指纹改取 `engineInstallShape()`（版本、阶段、上游版本、端口、latestRelease、tuning），百分比由 `patchEngineProgress()` 按 `[data-engine-view]` / `[data-launch-engine]` 原地改写；`phase` 变化（开始、失败、装好）才换结构。
- **指针下的卡片不会因为重建而闪边框。** 即使某次结构变化真的换掉了网格节点，`live.js` 的 `restoreModelHover()` 也会在 `afterRender()` 里、首帧绘制前把 `is-hovered` 补到新卡片上；`app-shell.css` 里这份声明与 `:hover` 完全一致（同特异度、后加载），新节点直接从悬停色开始画，没有「玻璃白 → 引擎色」的过渡可重播。指针离开、移动别处、离开模型页都会清掉这份记忆，不会留下一张假悬停的卡片。
- **日志只追加，不重绘控制台。** `.log-line` 带 0.36s 入场动画，替换 `#consoleBody` 等于让屏幕上已有的每一行重播一次——引擎一开口整屏就在闪。`live.js` 记下上次画出的行 id（`markLogsRendered()`），新快照是它的尾部超集时只 `insertAdjacentHTML` 新增行并更新计数徽标（`patchLogs()`）；清空、截断、换筛选/搜索才整页重来。用户在往上翻历史时不强行拉回底部。
- **流式输出是 token 级增量，不是打字机回放。** `AppState` 在 SSE 的 `onDelta` / `onReasoning` 回调里同时发一条 `ChatStreamEvent`（`begin` / `delta` / `end`，`seq` 全应用单调），`WebBridge` 以 16ms 为窗口把事件合并成一次 `window.__fc__.stream(JSON.parse(...))`；`WebUI/chat-stream.js` 把增量直接追加到对应通道，由**全页面共享的一个** `requestAnimationFrame` 合帧上屏。100ms 去抖的整段快照仍是权威状态：`push()` 会把快照与屏幕上可能已经领先的文本做前缀合并（快照领先就补齐，实时流领先就保留，分歧就以快照为准），快照携带的 `streamSeq` 作为水位线让重复或乱序的 delta 被丢弃。因此本地引擎 100+ tok/s 时回答跟着引擎走，生成一停就停，不存在积压或收尾补播。`prefers-reduced-motion` 下只是关掉动效，文本依旧实时到达。
- **思考块是独立通道，只在真的有推理内容时出现。** `reasoning` delta 走自己的 Markdown 容器实时滚动；标题在思考阶段是流光文字 + 呼吸光点，秒数由共享 100ms ticker 维护（不依赖是否有新 token）。非思考模型不画空的思考带，首个 token 之前只留输入框上方那行紧凑的三点等待态，回答卡片的空壳由 CSS 隐藏，拿到首字后才淡入。正文首字一到，计时收敛为「思考了 8.4 秒」（优先用 Swift 落盘的 `thinkingSeconds`），稍作停留后折成一行；读者手动的展开/收起由 `MANUAL` 表按 `data-think-id` 记住，不被自动折叠覆盖。折叠时标题下方保留最新一行思考（去 Markdown 标记、单行省略、右侧渐隐），展开后让位给全文。展开/收起只对 `.fc-reason-body` 的 `height` 做过渡，配合 `contain: layout paint` 把重排限制在块内。
- **流式对话只补最后一条回答，滚动由渲染器统一治理。** 生成中不再重建 `#messagesInner`：`patchStreamingMessage()` 把快照交给 `chat-stream.js`，节点、光标、思考块的展开态和已渲染的 Markdown 块都留在原地。帧结束时只有在读者贴近底部时才跟随；往上翻会 pin 住视图并浮出「回到最新」，不会被下一批 token 拽回去。生成结束时 `end` 事件先收尾、光标淡出，最终快照的 `onSettled` 再换上带 tok/s 与首字时间的静态标记，所以结尾不会突然跳高。
- **长回答的逐帧成本是 O(1)。** `FCChatMarkdown.sync()` 对「仅追加普通文字」的流直接把新增字符 `appendData` 到尾段落的文本节点；只有出现换行、围栏、强调、表格等结构字符才重新分块并重画尾块。光标作为尾段落最后一个元素被跳过，不会让快路径失效。
- **高速流用「渐现」而不是限速来调和观感。** 每个块/行带稳定的 `data-md-line` 键（段落按行拆 `.md-line`、列表项、表格行、标题、围栏各占一行）；`sync()` 只给新键加 `is-revealing`，按 38ms/行错峰、最多 10 行。一帧塞进来的长行再切成最多 4 片、42ms/片，总延迟封顶 260ms。文字**当下就已经在 DOM 里并占据最终位置**，动画只改 opacity 与几像素位移，因此既没有积压，也不会在生成停止后继续播动画；短 delta（<6 字）直接落地不建 span。`animationend` 负责即时清理包装 span，900ms 兜底定时器与结束时的 `settleReveals()` 保证即使动画被吞掉文字也不会停在透明态。静态历史消息不带 `is-revealing`，打开旧会话不会整屏淡入；`prefers-reduced-motion` 下完全跳过。
- **file:// 的 WebKit 缓存会跨版本存活。** WebUI 在包内的 URL 固定，旧磁盘缓存会让升级后仍跑上一版 CSS/JS。`WebBridge.init` 在加载 `index.html` 前清掉 disk/memory cache，完成后再 `loadFileURL`；只清缓存类型，不碰 cookie 与 localStorage（侧栏宽度、外观偏好继续保留）。

## 已知限制

- **没有端到端自动化测试。** 桥的两端都没有覆盖：命令分发、快照字段、以及页面行为只能靠手工回归。唯一的自动化检查是 Markdown 渲染器的契约测试：`node scripts/check-chat-markdown.mjs`（转义、URL 白名单、图片不取、围栏/表格/列表、流式半成品不抛错）。
- **预览同步是脚本 + 断言，不是自动合并。** 预览改了 `app.js` / `model-workspace.js` 的结构时，`patch-preview-ui.py` 会因锚点失配直接失败，需要人工更新补丁。
- **超长回答与极端宽的表格仍需真机实测。** 纯文字追加已走 O(1) 快路径，但频繁出现 Markdown 结构字符的回答仍会每帧分块一次尾块；Swift 侧的全量快照也依旧序列化整段对话（delta 专线只是把可见文本从 100ms 去抖里摘出来）。
