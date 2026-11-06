# 贡献指南

flashCat 把「装引擎、下模型、聊天、对外提供本地接口」收进一个窗口。它的价值不在功能数量，而在**把五个推理引擎的差异收敛成一层**——所以这里最重要的规矩都跟"别把差异漏回业务层"有关。

## 环境

| 需要 | 版本 |
| --- | --- |
| macOS | 26.0+（应用下限是 Liquid Glass 所需的 macOS 26；splash 引擎自身下限 26.4） |
| Xcode / Swift | 6.x 工具链 |
| SwiftLint / swift-format | 可选，`brew install swiftlint swift-format` |

## 本地验证（提交前请全过）

```bash
cd native && swift build          # 0 warning，CI 以 -warnings-as-errors 跑
cd native && swift test           # 应用层 + Kit 用例，约 1 秒
make app                          # 组装 /Applications 里的 .app（或 INSTALL=0 只出 dist）
```

界面全部在 `Sources/FlashCat/UI/`，直接跑 `swift run flashCat` 就能看；没有打包步骤，
改了 Swift 文件重新编译即可。

严格并发是一道**棘轮**，不是"零告警"：仓库当前带 33 条，`native/.strict-concurrency-baseline` 记着这个数，CI 只在数字变大时失败。修掉一条就把基线调小一条，这样它才会一路降到零而不会在第一天就红。

## 架构规矩（评审会直接打回的那种）

1. **`FlashCatKit` 不许引 UI。** 只允许 `import Foundation / Network / CryptoKit`。这一层必须能在无窗口的测试进程里跑——187 个测试全打在这里。
2. **依赖单向。** `FlashCat` → `FlashCatKit`。Kit 里出现任何应用侧符号都是破坏。
3. **引擎差异只许存在于 descriptor 与 adapter。** 不要在 `EngineManager`、安装中心、页面里写 `if engine == .splash`。真需要按引擎分支，先问"这能不能变成 manifest 字段"。
4. **清单契约是唯一接口。** 除了 `manifest.json` 声明的字段，应用不解释 pack 里的任何文件。
5. **未知枚举值降级，不失败。** 新 pack 带来的未知 capability / modelArgument 必须让旧版应用仍然装得上、起得来。
6. **只有用户自己的 pack 可删。** bundle 内的删了会破坏签名，checkout 里的是构建产物——两者只读。

新增引擎的完整步骤见 `native/Sources/FlashCatKit/SPEC.md` 的「添加一个新引擎」。

## 代码风格

- 4 空格缩进；行宽上限 140，超出即断行。格式化用 `swift-format`（`native/.swift-format`）。
- **注释：`native/` 下的设计说明写中文，面向外部贡献者的接口文档写英文。** 同文件内不要混。注释解释"为什么"，不解释"做了什么"——`// 让大数字、曲线、菜单栏读的都是同一个平滑速率` 是好注释，`// 设置 liveDecodeRate` 不是。
- 禁止 `try!` / `as!` / `fatalError` / 强制解包。当前全仓为 0，请保持。
- 错误不要用 `try?` 静默吞掉。要么处理，要么写进 `LogStore`——用户排查问题的唯一入口是日志页。
- 新增 `@MainActor` 之外的共享可变状态前，先读一遍现有 33 条严格并发告警的处理方式（基线在 `native/.strict-concurrency-baseline`）。

## 测试

- 纯逻辑进 `FlashCatKit` 并配单元测试。**判据：能在没有窗口、没有引擎进程的情况下断言的行为，就不该写在 `AppState` 里。**
- 修 bug 请带一条能复现它的用例。解析类问题尤其如此——`StatusParserTests` 里每个用例都对应过一次线上错误。
- 涉及真实归档的安装流程用 `PackInstallIntegrationTests` 的跳过机制，不要在 CI 里拉 GB 级文件。
- **界面改动先读 `native/Sources/FlashCat/UI-SPEC.md`。** 六个页面只读 `AppState`、只调它的方法；视图里不直接发网络请求、不读写文件、不绕过 `AppState` 改 `EngineStore`。新增页面沿用 `Design.swift` 的 `Native` token 与组件，不引入第二套色板或圆角。
- **不许把网页层加回来。** 没有 `WKWebView`、没有内嵌 HTML/JS、没有跨语言快照桥。需要富文本就用 `MarkdownView`，需要图表就用 Swift Charts。

## 提交

Conventional Commits，scope 用模块名：

```
feat(engines): 接入 MLX-Serve 与 Strata 多引擎架构
fix(kit): 根目录的拆分 GGUF 不再当成一档量化
docs(spec): 记录 DFlash2 随主模型下载与启动前补齐
```

类型：`feat` / `fix` / `refactor` / `perf` / `test` / `docs` / `chore` / `build`。

一个提交只做一件事。格式化、重命名这类大 diff 单独提交，方便 `git blame --ignore-rev` 跳过。

## 版本

`VERSION` 文件是唯一来源。不要在任何脚本里硬编码版本号——`scripts/version.sh` 会读它。发版时 `VERSION` 与 tag 必须一致，CI 会校验。

## 许可

提交即表示同意以 [MIT](../LICENSE) 授权。
