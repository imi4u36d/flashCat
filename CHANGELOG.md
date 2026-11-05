# 更新日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。版本号的唯一来源是仓库根的 `VERSION` 文件。

## [Unreleased]

### 界面
- **版式改为逐页对齐 WebUI**：200 pt 玻璃侧栏（白底选中胶囊、最近对话日期）、浮层标题栏（居中引擎胶囊）、
  概览（hero + API 网关 + 四指标 + 总解码/最近请求）、模型（引擎分段 + 搜索 + 两列大卡）、
  引擎（运行时统计 + 整行卡片）、日志（过滤条 + 玻璃控制台）、设置（左右两列卡片）。
  新增 `Console` 设计 token（#EAEEF7 画布、#D1487A 品牌粉、20 pt 卡片圆角、冷色投影）。
- 补齐 WebUI 的窗口 chrome 与交互：48pt 标题栏（折叠边栏、当前引擎胶囊含实时 tok/s 与启停、
  ⌘K 命令面板、外观切换、下载中心徽标）、可拖动调宽的侧栏、页面切换淡入。
- ⌘K 命令面板：六页跳转、启停引擎、新对话、生成参数、下载中心、模型广场、切换外观、折叠边栏；
  ↑↓ 选择、↵ 执行、esc 关闭。
- 概览：品牌渐变 hero（模型切换菜单、实时速率与迷你曲线）、DFlash2 接受率曲线、
  网关按请求打点的会话网格（解码/预填充/首字/上下文）。
- 对话：回车发送、⇧回车换行、滚动离底时浮出「回到最新」、思考块流式自动展开/首字后自动折叠、
  生成中的光标与呼吸点、输入框聚焦光环。
- 模型/引擎卡片 hover 抬升、当前项强调色描边；「正在使用」状态替代禁用按钮；
  模型广场支持手填 owner/repo 的预检（体积、归属引擎、是否已在本机）。
- 设置页可直接切换默认模型（按引擎分组）。
- 动效统一到 `Motion`（140/220ms + 轻弹簧），并服从 reduce-motion；持久化的深色外观在启动时即时生效。

### 变更
- **界面回到纯原生。** 六个页面、启动页、下载中心、模型广场、引擎配置与对话参数全部改为 SwiftUI / AppKit 视图（`Sources/FlashCat/UI/`），直接读写 `AppState`：没有 `WKWebView`、没有快照桥、没有 token 级 IPC。删除了 `WebViewShell.swift`（1350 行）、整个 `WebUI/`（14 个 ES module + 8 份 CSS + `bundle.js`，约 2.8 万行）、esbuild 工具链（`package.json` / `package-lock.json` / `node_modules`）、`webui-render-check` 测试台与 CI 的 webui job。
- 视觉方向改为 macOS 原生「仪器化」语言：纯色画布 + 1px 描边分层、等宽读数、系统控件；设计 token 与组件全部来自 `Design.swift` / `Theme.swift`。
- 新增 `native/Sources/FlashCat/UI-SPEC.md`，替换 `WebUI-SPEC.md`；`architecture.md`、`SPEC.md`、`CONTRIBUTING.md`、`README.md` 同步改写。
- 安装脚本不再把上一版留在 `/Applications`：备份移到 `~/Library/Application Support/flashCat/backups`，并注销 staging/备份的 LaunchServices 记录，避免同 bundle id 的旧构建被 Spotlight / Dock 打开。

### 新增
- WebUI 打包管线：14 个经典脚本改为 ES module（`main.js` 显式入口），esbuild 打包为单文件 `bundle.js`（`make webui-build`，CI 校验产物新鲜度）；JS 请求 14 → 1
- `esc.js`：全局唯一的 HTML 转义实现（统一前 8 份副本语义不一，统一版补齐 `'` 转义）
- 工程护栏：CI（构建/测试/严格并发/版本一致性）、SwiftLint、swift-format、EditorConfig
- `CONTRIBUTING.md`、`SECURITY.md`、`CHANGELOG.md`
- `VERSION` 文件 + `scripts/version.sh`，收敛此前分散在 4 处的版本号
- `native/Tools/WebUIRenderCheck`：在真 `WKWebView` 里渲染六个页面并断言非空、无控制台报错，`make webui-check`；CI 独立 job
- 应用层首个测试目标 `Tests/FlashCatTests`

### 修复
- 旧进程的退出回调不再打断新进程（`processExited` 增加进程身份校验）
- 停止引擎时一次性快照进程树，SIGKILL 升级能真正回收忽略 SIGINT 的子进程
- 引擎启动增加就绪超时，不再永久停在「启动中」
- 退出应用改为异步收尾，并清理全部引擎（此前只清理当前引擎）
- 快照序列化失败不再静默，并对非有限浮点做清洗
- `note()` 不再关闭运行期日志写入句柄
- 流式回复改为按消息 id 写入，切换会话不再污染另一条会话
- WebView 补导航策略、CSP、`openURL` 协议白名单与桥的 `tearDown`
- `install-app.sh` 安装失败不再导致 `/Applications` 里没有应用（`EXIT` trap 回滚）

### 变更
- WebUI 模块化：消灭 49 处 `window.X =` 全局接线（仅保留 Swift 桥面 `__fc__*`/`__fcToast`、测试台错误收集与 rAF 补丁共 5 处，均注明消费者）；跨文件调用改为显式 import/export
- 删除无消费者的 10 个 window 发布与 `#commandTrigger` 死绑定、只写不读的 `flowHistory` 死状态
- `swift build` 不再报告未声明的资源文件
- 删除 WebUI 死代码 1,979 行：app.js 的 preview 渲染实现与 mock 遥测（1,638 行）、整个 page-components.js（340 行，`FCPages` 已无任何调用方）。剩余 74 个顶层声明全部可达；live.js 缺失时改为显式报错，不再回退到假数据界面
- `make webui-check` 的脚本加载断言改为与 index.html 声明的 `<script>` 标签完全一致（原为 ≥14 的魔法数）

## [1.4.2] - 2026-11-04

### 新增
- WebUI 模块化重构
### 修复
- 模型下载进度条不刷新

## [1.4.1]

### 修复
- 见 git 历史

## [1.4.0]

首个公开版本：多引擎（Splash / oMLX / MTPLX / MLX-Serve / Strata）、模型库、内置对话、OpenAI + Anthropic 双方言网关。
