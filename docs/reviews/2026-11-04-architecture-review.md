---
title: flashCat 整改待办
date: 2026-11-04
updated: 2026-11-11
scope: native/（Swift 38,000 行 / 135 个文件：App、FlashCatKit、FlashCatCLICore 与 flashcat-cli）
method: 全量静态扫描 + 关键路径人工通读 + 干净构建/测试实测
status: 阶段 0/1/2 已完成；WebUI 已随原生重写删除；11-11 终审修掉并发/引擎/面板/安装器缺陷，严格并发清零；只剩 P0-2 与 P2 规范项
---

# flashCat 整改待办

> 原文档为 2026-11-04 架构与代码质量审查（P0×3、P1×8、P2×14）。阶段 0/1/2 已完成；
> 2026-11-08 的收尾轮清理了命令行与控制接口的已知缺陷。本文只保留**尚未完成**的
> 工作与仍然有效的判断。

## 整改台账（已完成）

| 日期 | 内容 | 结果 |
| --- | --- | --- |
| 11-04 | 阶段 0 护栏：CI、lint/format 配置、版本号收敛（`scripts/version.sh`）、治理文件、编译警告清零 | `swift build` 0 warning |
| 11-04 | 阶段 1：P1-1…8（退出异步收尾、进程身份校验、进程树快照、就绪超时、快照清洗、日志 sink、流式按 id 寻址、导航策略 + CSP） | 真机退出 0.20 s、零残留 |
| 11-05 | 阶段 2：WebUI 分层与渲染治理 | 已随 1.5.x 原生重写作废，WebUI 目录整体删除 |
| 11-11 | 终审：流式请求状态按请求隔离、引擎兜底/预留/看门狗/超时归位、面板单位统一、采样滑杆跟手、dmg 由 diskutil 生成且缺件报错、严格并发 11→0、模型 id 路径穿越与 pack 入口越界封堵 | `swift test` 372 个用例全过；严格并发 0；`make dmg` 产出 5.3M 镜像；详见 `2026-11-11-final-review.md` |
| 11-08 | 命令行/控制接口精修：`engines uninstall` 不再把指定版本回退成最新版、`chat -` 与确认提示改看 stdin、重复 `--for` 累加、表格按显示宽度对齐、`control.json` 从创建起 0600、`--control-url` 限制回环或 HTTPS、日志级别过滤统一、控制服务启停竞态 | `swift build -Xswiftc -warnings-as-errors` 通过；`swift test` 294 个用例全过；严格并发 25→11 |

当前质量门禁：`swift build -Xswiftc -warnings-as-errors` 零告警；`swift test` 全过；
严格并发棘轮基线 **0**（`.strict-concurrency-baseline`；CI 口径：干净构建、去重后的
唯一 `文件:行:列`——增量编译只报被改文件的告警，读数不可信）。11-11 之前的 11 条
历史告警已按"按请求隔离 / 加锁缓冲区 / 本地滑杆状态"三条线修完，门禁从"别变多"
改成"一条都不许有"。

---

## 一、仍然有效的判断（不随整改过期）

1. **Kit 层的抽象是对的，而且被测试守住了。** 不要为了"更优雅"去重写它——`开放值 + descriptor + manifest` 三件套是这类多引擎产品的正确解法，改成封闭枚举或插件市场都会退步。
2. **应用层正在重演 Kit 层当初想消灭的问题：特例。** Kit 用 descriptor 消灭了 `if engine == .splash`，但 `AppState` 里又以"这个引擎要补 draft""那个引擎要热切换""某个引擎端口要 +75 秒宽限"的形式长回来了。差异没有消失，只是换了楼层。
3. **整改期间验证过的教训**：任何"编译告警数"结论必须来自干净构建并写明统计口径，否则量的是增量编译器的工作量，不是代码。

## 二、不要动的东西

1. **`EngineCore.swift` 的开放值设计**（`EngineID` / `EngineCapability` 用 `RawRepresentable` 而非 `enum`）。新 pack 带来未知 capability 时，旧应用不该装不上——向前兼容优先于类型完备。
2. **`EngineTemplate.unresolvedPlaceholders`**（`EngineCore.swift:270`）。残留占位符**显式报告**而不是静默传字面量——"把错误提前到边界"的写法应扩散到别处。
3. **`EnginePackOwnership` 的路径分量比较**（`~/…/engines-copy/x` 不算 `~/…/engines` 的子目录）。没被 `hasPrefix` 糊弄过去。
4. **`ControlJSON` 每次新建 coder**（`Control/ControlProtocol.swift`）。`JSONEncoder` 是可变引用类型，共享实例正是并发检查拒绝放行的那类状态；按调用创建换来的是两端的日期策略天然一致。
5. **CLI 输出契约**：结果走 stdout、进度走 stderr、固定退出码、`--json` 时 stdout 不含杂讯。它是脚本契约，不是展示细节。

---

## 三、待办路线图

### P0-2 · 拆分 `AppState`（唯一剩下的阻断项）

3,584 行、61 个 `@Published`、123 个方法（11-11 实测；数字只会往上走，这是它必须被拆的理由）、约 95 个存储属性、13 处直接读写 `UserDefaults`：导航、引擎生命周期、模型切换状态机、下载队列、Hub、对话流式、硬件推荐混在一层。

- `syncController()` 在每秒一次的快照路径里做采样决策、EMA 平滑、接受率落点——业务规则写进了"读状态"的函数。
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

### 阶段 3 · 结构（持续）

- [ ] 引擎差异回归 Kit：`if engine == …` / `descriptor.adapter == …` 分支统计，逐个搬回 adapter。
- [x] 严格并发 11 条已清零（11-11）：流式回调改 `@Sendable`、`TailReader` 的缓冲区收进加锁的 `LineSplitter`、`ChatClient` 按请求隔离、滑杆用本地 `@State`。
- [ ] 在线/离线两套文档收敛：`StatusCommand.offlineReport`、`EnginesCommand.offlineEngines` 与 `ControlServer+Documents` 的配置表各写一份，已经出现行为漂移（例如离线的 `thinkingMode` 不接受 `none`）。把离线文档做成 Kit 里的纯函数，命令只负责取数。

### P2 规范类（开源前）

- [ ] 错误分类改枚举（`ChatError` 只有 `message: String`，`AppState` 靠字符串匹配 "cancel"/"取消"）。
- [ ] `EngineController` 10 个布尔/可选拼状态机收敛成单一 `enum Phase`。
- [ ] `LocalState.engineConfiguration` 解析失败时报告，而不是 `try?` 后当成空配置；否则 `status` 会把损坏的 `engines.json` 说成"没有引擎"。
- [ ] 全仓 `swift-format` 一次（一次性大 diff，单独提交，便于 `git blame --ignore-rev`）。
- [ ] 每文件加 `// SPDX-License-Identifier: MIT`，注释语言规则写进 CONTRIBUTING。

---

## 四、待人工验证（真机）

1. **启动引擎后**再退出 → 秒级退出且无残留（宽限期轮询分支未被真机走到，逻辑有 `ProcessTreeTests` 覆盖）。
2. 生成中切到另一条会话 → 回复不应出现在新会话里（流式已按 id 寻址，真机路径要人看一遍）。
3. 模型广场点 README 外链 → 系统浏览器打开，控制台不跳转。

---

*环境：macOS，Swift 6 工具链。行号会随整改移动，仅供定位参考。*
