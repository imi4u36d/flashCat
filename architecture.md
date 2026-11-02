---
id: flashcat-architecture
type: architecture-design
status: draft
title: flashCat 架构
parent: flashcat-product
tags: [macos, swift, packaging]
---

# flashCat 架构

一个 SwiftPM 工作区 + 一组构建脚本。应用本体只有两层：可测试的无界面引擎核心（`FlashCatKit`）和包着它的 macOS 壳（`FlashCat`）。表现层是壳里的一张网页。

## 拓扑

```mermaid
graph TD
  App["FlashCat（可执行壳）<br/>SwiftUI/AppKit + 状态"]
  Web["WebUI（HTML/CSS/JS）<br/>六个页面"]
  Kit["FlashCatKit（库）<br/>引擎核心，无 UI"]
  GW["Gateway<br/>双方言本地 API"]
  Packs["scripts/engines<br/>pack 构建与发布"]
  Contract["manifest.json 契约<br/>schemaVersion 1"]
  Engine["引擎 pack（外部）<br/>Splash / oMLX / MTPLX"]

  App --> Kit
  Kit --> GW
  App -. bridge 协议 .-> Web
  App --> Contract
  Packs --> Contract
  Contract --> Engine
  App --> Engine
```

| 模块 | 职责 | spec |
| --- | --- | --- |
| `FlashCat` | macOS 壳：全部可变状态、进程启停、模型库、对话、菜单栏、网页宿主 | [flashcat-app](native/Sources/FlashCat/SPEC.md) |
| `WebUI` | 六个页面的表现层，以及与 Swift 之间的桥协议 | [flashcat-webui](native/Sources/FlashCat/WebUI-SPEC.md) |
| `FlashCatKit` | 引擎身份/端口/能力、清单解码、状态解析、路由、包安装、启动阶段判定 | [flashcat-kit](native/Sources/FlashCatKit/SPEC.md) |
| `FlashCatKit/Gateway` | 只监听本机的双方言 HTTP 网关 | [flashcat-gateway](native/Sources/FlashCatKit/Gateway/SPEC.md) |
| `scripts/engines` | 把上游产物打成自包含运行时 pack，并生成发布索引 | [flashcat-engine-packs](scripts/engines/SPEC.md) |
| `manifest.json` 契约 | pack 与应用之间唯一的接口 | [flashcat-manifest-contract](scripts/engines/manifest-template.md) |

依赖边只有三条是真的：应用依赖 Kit（14 个文件 `import FlashCatKit`）；Kit 依赖系统框架，从不反向引用应用符号；网页与 Swift 之间只有那条序列化桥，没有其他耦合。

## 不变量

代码已经在执行的规则，不是愿望。

1. **`FlashCatKit` 不许引 UI。** 它只 `import` `Foundation` / `Network` / `CryptoKit`。这决定它能在无窗口的测试进程里跑——`FlashCatKitTests` 有 13 个测试文件、145 个测试函数，全部针对这一层。
2. **依赖单向。** `FlashCat` → `FlashCatKit`。Kit 里出现任何应用侧符号都是破坏。
3. **端口段不重叠。** 每个引擎的默认端口是 `splash 8000` / `omlx 8100` / `mtplx 8200`，可用范围是 `defaultPort...defaultPort+19`；分配器在段内跳过被占端口，段外放弃。
4. **切换方式是能力，不是选项。** `omlx = hot`，`splash` / `mtplx = restart`。应用不许对 `restart` 引擎做热切换。
5. **未知枚举值降级而非失败。** 新版本 pack 带来的未知 `capability` 解成 `.chat`，未知 `modelArgument` 解成 `.name`——一个旧版应用不会因为清单多了个词就装不上。
6. **pack 不可移动。** 安装路径必须含版本号且装完不许挪（原生扩展带绝对 rpath）。`fix-pack-rpaths.sh` 在上游 wheel 把构建机路径烧进 `LC_RPATH` 时把它改写成 `@loader_path/...` 并重签名。
7. **只有用户自己的 pack 可删。** pack 有四个发现位置（环境变量覆盖、用户安装目录、应用 bundle、仓库 `vendor/engines`），但只有前两个属于用户；bundle 内的删了会破坏签名，checkout 里的是构建产物——两者都列出、只读。
8. **网关只监听回环。** 见 [flashcat-gateway](native/Sources/FlashCatKit/Gateway/SPEC.md)。
9. **清单契约是唯一接口。** 应用除了 `manifest.json` 里的字段之外不解释 pack 里的任何文件。

## 决策

**表现层是网页，SwiftUI 只当壳。** 有一个给定的视觉稿（「精密仪器」）要求六个页面 1:1 还原，原生视图做不到那种还原度。因此状态管线留在 Swift（Combine 全量快照推给网页），表现层整体是 `WebUI/` 里的 HTML/CSS/JS，通过 `WKWebView` 承载。代价是多一层跨语言桥，收益是视觉稿能被精确实现。详见 [flashcat-webui](native/Sources/FlashCat/WebUI-SPEC.md)。

**引擎运行时永不随应用打包。** 三个原因共同决定：pack 是 GB 级（oMLX 一个就 590 MB，全塞进来应用会从 15 MB 变成数 GB，签名与分发一起变复杂）；引擎有自己的上游发布节奏，做成 pack 才能让引擎页比对上游、单独更新而不发新版应用；引擎是上游项目的成果，重分发二进制存在许可与合规顾虑，所以仓库只发构建脚本、让用户机器自己装。

**引擎差异收敛在一个适配层。** 三个引擎的状态报文几乎没有共识：splash 把指标嵌在 `metrics`/`instance` 下，oMLX 是扁平的一份 `/api/status`，MTPLX 把真话拆在 `/health`（pid、模型）、`/v1/mtplx/snapshot`（指标）、`/v1/models`（上下文长度）三处。把这些知识集中到 `StatusParsers`，概览、菜单栏、对话才能保持引擎无关。

**网关自己打点。** 引擎层没有 per-session 指标：splash 只报累计比值，oMLX 只给聚合吞吐，MTPLX 连排队数都并进在跑数。唯一知道「每个请求什么时候进来、首个 token 何时到、一共吐了多少字」的地方就是网关本身，所以会话级读数在网关侧统计。

## 发布形态

| 环节 | 脚本 | 契约 |
| --- | --- | --- |
| 编译并组装 `.app` | `scripts/build-native-app.sh` | `INSTALL=1` 装进 `/Applications`；`EMBED_PACKS` = `none`（默认，pack 由 pack-index 下载）/ `copy`（内嵌 `vendor/engines`）/ `link`（软链，仅供开发） |
| 安装到 `/Applications` | `scripts/install-app.sh` | 只保留一份副本，旧的改名备份 |
| 分发件 | `scripts/make-installer.sh` | `dist/flashCat-<版本>.pkg` 与 `.dmg` |
| 启动即登录 | `Sources/FlashCat/LoginItem.swift` | LaunchAgent `com.zhuo.flashCat` |

**最低系统版本是 macOS 26.4。** 这个门槛来自 splash 原生引擎的硬性要求，三处必须一致：`scripts/build-native-app.sh` 的 `MIN_MACOS` 写进 `Info.plist` 的 `LSMinimumSystemVersion`（默认 `26.4`），`README.md` 的系统一栏，以及 `native/Package.swift` 的 `platforms: [.macOS("26.4")]`。三点同心才站得住：前两者是用户看得见的门槛，Package.swift 是编译器与 SwiftPM 认的槛；它若停在 `14.0`，产物里写的是 26.4 而构建系统仍以为能跑在 14.0，两边说法不一。

## 已知限制

- **应用层没有测试。** 13 个测试文件全部针对 `FlashCatKit`；`FlashCat` target（状态机、引擎启停、桥的分发逻辑）和 `WebUI/` 的网页本身没有任何自动化测试。改动这一层只能靠手工回归。
