---
title: flashCat 整改待办
date: 2026-11-04
updated: 2026-11-05
scope: native/（Swift 21,323 行 / 52 文件）+ WebUI（拆分后 store/render/actions/live 四模块）
method: 全量静态扫描 + 关键路径人工通读 + 编译/测试实测 + 真机验证
status: 阶段 0/1/2 已完成，仅保留未完成项；完成记录压缩为台账
---

# flashCat 整改待办

> 原文档为 2026-11-04 架构与代码质量审查（P0×3、P1×8、P2×14）。阶段 0/1/2 已完成，
> 完成记录压缩为下文「整改台账」，原详细记录已删；本文只保留**尚未完成**的工作与仍然有效的判断。

## 整改台账（已完成）

| 日期 | 内容 | 结果 |
| --- | --- | --- |
| 11-04 | 阶段 0 护栏：CI、lint/format 配置、版本号收敛（`scripts/version.sh`）、治理文件、编译警告清零 | `swift build` 0 warning |
| 11-04 | 阶段 1：P1-1…8 全部修复（退出异步收尾、进程身份校验、进程树快照、就绪超时、快照清洗、日志 sink、流式按 id 寻址、导航策略 + CSP） | 真机退出 0.20 s、零残留；`swift test` 199 通过 |
| 11-04 | 阶段 1.5：WebUI 渲染测试台 `native/Tools/WebUIRenderCheck` | 后续每步整改的证明基座 |
| 11-04 | 阶段 2 第一步：删 app.js preview 实现与 page-components 死分支 | -1,979 行 |
| 11-05 | 阶段 2 第二步：esc 统一（9→1）、main.js + ES module（`window.X =` 49→5）、esbuild 打包（14 请求→1） | bundle 400 KB 经典脚本（file:// 拒绝外链 module，已实证） |
| 11-05 | 阶段 2 第三步：live.js 三层拆分（store 953 / render 1,970 / actions 1,107 / live 186） | 可变状态收进 `S` 容器，分层单向 |
| 11-05 | 阶段 2 第四步：三个 `aria-modal` 对话框键盘治理（焦点陷阱/Escape/焦点还原） | `webui-render-check` 32 通过 |

当前质量门禁：`webui-render-check` **32 passed / 0 failed / 2 skipped**；严格并发棘轮基线 **33**（`.strict-concurrency-baseline`；CI 口径：去重后唯一 `文件:行:列`，必须来自干净构建——增量编译只报被改文件的告警，读数不可信）。

---

## 一、仍然有效的判断（不随整改过期）

1. **Kit 层的抽象是对的，而且被测试守住了。** 不要为了"更优雅"去重写它——`开放值 + descriptor + manifest` 三件套是这类多引擎产品的正确解法，改成封闭枚举或插件市场都会退步。
2. **应用层正在重演 Kit 层当初想消灭的问题：特例。** Kit 用 descriptor 消灭了 `if engine == .splash`，但 `AppState` 里又以"这个引擎要补 draft""那个引擎要热切换""某个引擎端口要 +75 秒宽限"的形式长回来了。差异没有消失，只是换了楼层。
3. **整改期间验证过的教训**：任何"编译告警数"结论必须来自干净构建并写明统计口径，否则量的是增量编译器的工作量，不是代码。

## 二、不要动的东西

1. **`EngineCore.swift` 的开放值设计**（`EngineID` / `EngineCapability` 用 `RawRepresentable` 而非 `enum`）。新 pack 带来未知 capability 时，旧应用不该装不上——向前兼容优先于类型完备。
2. **`EngineTemplate.unresolvedPlaceholders`**（`EngineCore.swift:270`）。残留占位符**显式报告**而不是静默传字面量——"把错误提前到边界"的写法应扩散到别处。
3. **`EnginePackOwnership` 的路径分量比较**（`~/…/engines-copy/x` 不算 `~/…/engines` 的子目录）。没被 `hasPrefix` 糊弄过去。
4. **`WebSnapshot.jsStringLiteral` + `JSON.parse` 的桥传输**（`WebViewShell.swift:637/665`）。桥不存在注入，比大多数 WKWebView 项目干净。
5. **WebUI 的 `store → app.js` 单向依赖**：`adapt` 的本质是把 Swift 快照写进 app.js 的共享 `state`，是三层拆分时确认过的既有架构事实，靠「所有模块求值期外部引用 = 0」保证 TDZ 安全。后续收敛状态时要连这条边一起设计，不要单方面切断。

---

## 三、待办路线图

### P0-2 · 拆分 `AppState`（唯一剩下的阻断项）

2,511 行、49 个 `@Published`、101 个方法、77 个存储属性：导航、引擎生命周期、模型切换状态机、下载（17 个字段）、Hub、对话流式、硬件推荐、UserDefaults（13 处直接读写）混在一层。

- `syncController()`（`:468`）在每秒一次的快照路径里做采样决策、EMA 平滑、接受率落点——业务规则写进了"读状态"的函数。
- `send()` 里 4 个回调各自 `Task { @MainActor in … }`，依赖下标式防御（P1-7 已修症状，根因在这里）。

**修法**（渐进，先测后搬，按"变更原因"切而不是按"页面"切）：

```
AppState（薄，只做组合与转发）
├─ EngineSession        // 启动/停止/切换/阶段，显式状态机
├─ ModelLibraryStore    // catalog / 扫描 / 归属 / 推荐
├─ DownloadCenter       // 下载队列、进度、断点（17 字段收进一个 struct）
├─ HubBrowser           // 搜索、分页、详情、预检
├─ ChatSession          // 消息、流式、测速、持久化
└─ PreferencesStore     // 唯一碰 UserDefaults 的地方
```

每切出一个先补 3-5 个测试（纯逻辑部分），再搬代码。

**验收**：`AppState.swift` < 400 行；`grep -c "@Published"` < 12；每个子模块有独立测试文件。

### 阶段 2 尾巴 · WebUI

- [ ] minify + 体积目标 ~200 KB（打包管线增量选项，`esbuild --minify` 即可打开）
- [ ] `innerHTML` 61 处（改 DOM API 或统一 sanitizer）
- [ ] CSS：`@layer` 分层 + 单一 `tokens.css`（现状 353 处字面色值、24 处 `!important`、58 个 `@keyframes`）
- [ ] 字号：252/400 条落在 6.5–10.5px，Retina 桌面应用最低 11px

### 阶段 3 · 结构（持续）

- [ ] WebUI 渲染抽 selector + 增量 diff（当前每次快照全量重建）
- [ ] 引擎差异回归 Kit：`if engine == …` / `descriptor.adapter == …` 分支统计，逐个搬回 adapter
- [ ] 严格并发 33 条告警逐条清零（集中：`AppState` 12、`GatewayController` 11、`GatewayHTTPServer` 5、`HubClient` 4——问题在网关的 `Sendable` 边界，不是到处漏）

### P2 规范类（开源前）

- [ ] 错误分类改枚举（`ChatError` 只有 `message: String`，`AppState.swift:1620` 靠字符串匹配 "cancel"/"取消"）
- [ ] 写盘后立刻读回改返回值直更（`AppState.swift:1610-1611`）
- [ ] `LogStore.tail` 锁内 `suffix()`，别全量复制 20k 行（每秒被调）
- [ ] 复用静态 `DateFormatter`（`Support.swift:124` 每行日志 new 一个）
- [ ] `EngineController` 10 个布尔/可选拼状态机收敛成单一 `enum Phase`；删 `attachedPid` 死字段
- [ ] 删死代码：`EngineManager.dispose()`（无调用）、`Design.swift:1066 healthTone`（无读取点）
- [ ] 全仓格式化一次（一次性大 diff，单独提交，便于 `git blame --ignore-rev`；因未提交 Git 而暂缓）
- [ ] 注释定语言并写进 CONTRIBUTING；每文件加 `// SPDX-License-Identifier: MIT`

---

## 四、待人工验证（真机）

1. **启动引擎后**再退出 → 秒级退出且无残留（宽限期轮询分支未被真机走到，逻辑有 `ProcessTreeTests` 覆盖）。
2. 生成中切到另一条会话 → 回复不应出现在新会话里（流式已按 id 寻址，真机路径要人看一遍）。
3. 模型广场点 README 外链 → 系统浏览器打开，控制台不跳转。

---

*行号基于 2026-11-04 工作区（提交 `98f0f46` + 未提交改动），整改会移动代码，仅供定位参考。环境：macOS，Swift 6 工具链。*
