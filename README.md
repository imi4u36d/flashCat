<img src="native/Sources/FlashCat/Resources/app-icon.png" width="96" align="right" alt="flashCat" />

# flashCat

**Mac 上的本地大模型控制台。** 一个原生 SwiftUI 应用，管好三个本地推理引擎
（Splash / oMLX / MTPLX），把本地模型目录接成一个 OpenAI 兼容的本地服务，
并自带一个可以直接聊天的窗口。

不用敲命令行、不用记每个引擎的参数，装上就能用；想接自己的客户端时，
它就是一个 http://127.0.0.1:8000/v1 这样的接口。

---

## 目录

- [它能做什么](#它能做什么)
- [系统要求](#系统要求)
- [安装](#安装)
- [第一次启动：先选一个引擎](#第一次启动先选一个引擎)
- [六个页面怎么用](#六个页面怎么用)
- [用别的客户端连它](#用别的客户端连它)
- [模型从哪来](#模型从哪来)
- [设置项说明](#设置项说明)
- [常见问题](#常见问题)
- [卸载](#卸载)
- [从源码构建（可选）](#从源码构建可选)
- [许可](#许可)

---

## 它能做什么

- **三个引擎，一个界面。** Splash、oMLX、MTPLX 各有自己的运行时、端口和日志，
  在应用里统一切换、启动、停止，不用并行开三个终端。
- **模型直接复用你已有的权重。** 扫描 `~/.omlx/models`、`~/.omlx/gguf`,
  `~/.mtplx/models` 和 Splash 的模型目录，用软链接到应用自己的模型目录里，
  不复制、不搬家。也可以在应用里从 Hugging Face 下载。
- **标准 OpenAI + Claude 双格式网关。** 应用自带一个固定端口的本地 API 网关
  （默认 `http://127.0.0.1:9000/v1`），同时提供 OpenAI（`/v1/chat/completions`）
  和 Claude（`/v1/messages`）两种标准格式与统一模型列表（`/v1/models`），
  引擎切换、换端口都不用改客户端配置。
- **看得见的性能。** 概览页实时显示解码速度（tok/s）、首字延迟、预填充速度、
  草稿接受率、内存占用、热状态和端口占用。
- **日间 / 夜间皮肤。** 跟随系统、浅色、深色三档，点完立刻生效。
- **日志在应用里。** 引擎的 stderr 实时进日志页，支持按级别过滤、搜索、暂停、清空。

## 系统要求

| | |
| --- | --- |
| 芯片 | Apple Silicon（arm64） |
| 系统 | macOS **26.4** 或更高 |
| 磁盘 | 应用约 10 MB；每个引擎 80 MB ~ 600 MB；模型另算 |

## 安装

### 方式一：安装包

从 [Releases](https://github.com/imi4u36d/flashCat/releases) 下载：

- `flashCat-<版本>.dmg` —— 打开后把 flashCat 拖进「应用程序」
- `flashCat-<版本>.pkg` —— 双击一路安装

应用是 ad-hoc 签名、未做公证，第一次打开系统会拦一下：
在 Finder 里**右键点 flashCat → 打开**，之后就不会再问了。

> ⚠️ 应用不含推理引擎。本项目**不托管引擎运行时二进制**，
> 装完请按[引擎运行时包](#引擎运行时包)一节的说明自行构建（或把 `FLASHCAT_PACK_INDEX_URL`
> 指向你自己的索引），否则首次启动页会下载失败。

### 方式二：从源码构建

见文末[从源码构建](#从源码构建可选)，需要 Xcode 命令行工具（Swift 6）。

装好之后从「应用程序」或 Spotlight 里打开 flashCat 即可。

## 第一次启动：先选一个引擎

引擎不再打进应用包里，所以第一次打开会停在启动页，让你挑一个：

1. 选一个引擎，点下载。应用从发布索引拉运行时包，校验 sha256 后解压安装。
   （索引默认指向项目 Release，但本项目不发布引擎二进制，
   所以这一步需要你先把索引指到自己构建的包，见[引擎运行时包](#引擎运行时包)。）
2. 装完它就成为**默认引擎**，窗口自动切到控制台。
3. 之后随时可以在「引擎」页安装另外两个、切换默认引擎或删掉不用的。

三个引擎的差别（默认端口可以在设置里改）：

| 引擎 | 默认端口 | 适合 | 切模型 |
| --- | --- | --- | --- |
| **Splash** | 8000 | 单模型、最省事；带 DFlash2 草稿加速 | 重启引擎 |
| **oMLX** | 8100 | 多模型常驻，支持热加载 / 热卸载、模型热重扫 | 不停进程热切换 |
| **MTPLX** | 8200 | 走 MTP（multi-token prediction）路径，长上下文 | 重启引擎 |

三个引擎都支持对话、流式输出、视觉模型和推理（thinking）模型。

> 端口是固定段：Splash 8000、oMLX 8100、MTPLX 8200，各自往后占 20 个端口，
> 互相不会抢。`settings` 里可以在 1024–65535 之间改。

## 六个页面怎么用

**概览** —— 引擎起没起、现在加载的是哪个模型、实时解码速度曲线，以及
API 网关地址（OpenAI + Claude 双格式，一键复制）。旁边是运行详情：设备、进程、内存压力、热状态。

**对话** —— 应用内置的聊天窗口。顶部可以切模型、调参数（温度、top-p、最大输出）、
设置思考模式（自动 / 关闭 / 开启）和推理等级。每条回复下方有 tok/s 和首字延迟。
对话记录在本地，支持新建和翻看历史。

**模型** —— 每个引擎一份模型库，顶部 chip 条先选看哪个引擎（跟当前跑的是谁无关，没装
也能先看）。列扫到的本地权重与该引擎适配的推荐档位，点一下就是当前模型（oMLX 下是热
切换），或在原地从 Hugging Face 下载；某个引擎一个模型都没有时，页面顶部直接给出它
最适配的 Qwen 三档。引擎的模型目录可以在每张卡片的 ⋯ 里打开。

**引擎** —— 每个引擎一张卡片：状态、端口、启动参数、上游最新版本比对、
一键构建并安装上游新版本、打开安装目录、查看日志、卸载任意已装版本（含正在
使用的版本：先停引擎再删包，之后自动切到其他引擎或回到启动页；端口和参数
设置保留，重装即恢复）。

**日志** —— 当前引擎的实时输出，可按「全部 / 提示 / 警告 / 错误」过滤、
搜关键词、暂停滚动、清空。

**设置** —— 外观、端口、自启、思考模式、推理等级、默认模型、下载缓存目录等，
改完底部会出现保存条。

## 用别的客户端连它

应用自带一个 **API 网关**，推荐所有客户端都接它：地址固定、双格式，
请求自动转发到当前运行中的引擎。

| | |
| --- | --- |
| 地址 | `http://127.0.0.1:9000/v1`（端口可在设置里改） |
| OpenAI 格式 | `POST /v1/chat/completions`（支持流式） |
| Claude 格式 | `POST /v1/messages`（支持流式）、`POST /v1/messages/count_tokens` |
| 模型列表 | `GET /v1/models` —— 两种格式各自的标准形态，列出全部已装引擎的模型 |
| API Key | 本地服务不校验，填任意字符串即可 |

OpenAI 格式示例：

```bash
curl http://127.0.0.1:9000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "你的模型名",
    "messages": [{"role": "user", "content": "你好"}],
    "stream": true
  }'
```

Claude 格式示例（SDK 里 Base URL 填 `http://127.0.0.1:9000` 即可）：

```bash
curl http://127.0.0.1:9000/v1/messages \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "你的模型名",
    "max_tokens": 1024,
    "messages": [{"role": "user", "content": "你好"}]
  }'
```

- 模型名：填 `/v1/models` 返回的名字（概览页也能看到当前加载的是哪个）
- 网关把 Claude 格式完整翻译给引擎：system 提示、base64 图片、
  `tool_use` / `tool_result` 工具调用、stop 序列、思考模型的
  `thinking` 块、`end_turn` / `max_tokens` / `tool_use` 停止原因等都支持
- 引擎自己也是一个标准 OpenAI `/v1` 服务（端口 8000 / 8100 / 8200），
  想直连某个引擎时也可以直接用，但地址会随引擎切换变化

## 模型从哪来

应用不改动你原有的模型目录，只做软链：

| 引擎 | 读取的目录 |
| --- | --- |
| oMLX | `~/.omlx/models`、`~/.omlx/gguf` |
| MTPLX | `~/.mtplx/models` |
| Splash | `~/Library/Application Support/Splash/models` |

扫描到的模型会以软链的形式出现在
`~/Library/Application Support/flashCat/models/<引擎>/` 下，引擎只看这一个目录。
所以把模型放进上面任意一个目录，回「模型」页点重新扫描就能看到。

应用内下载的模型走 Hugging Face，缓存目录可以在设置里改
（默认沿用 `HF_HUB_CACHE`）。oMLX 支持 GGUF 和多模型常驻，Splash / MTPLX 一次跑一个模型。

## 设置项说明

| 设置 | 说明 |
| --- | --- |
| 外观 | 跟随系统 / 浅色 / 深色，选中立即生效 |
| 端口 | 引擎监听端口，1024–65535；占用时会提示 |
| API 网关 | 统一的 OpenAI + Claude 双格式接口；开关与端口（默认 9000）改动立即生效 |
| 随 flashCat 启动 | 打开应用时自动把引擎拉起来 |
| 登录时启动 | 把 flashCat 加进 macOS 登录项 |
| 思考模式 | 自动 / 关闭 / 开启，控制 reasoning 模型是否先输出思考过程 |
| 推理等级 | 思考模式为「开启」时生效，档位由引擎决定 |
| 默认模型 | 引擎启动时自动加载哪个模型，也可手填自定义模型 ID |
| 下载缓存目录 | Hugging Face 下载缓存位置 |
| 恢复默认设置 | 把上面各项恢复成出厂值 |

## 常见问题

**引擎起不来 / 一直转圈？**
去「日志」页看最后几行，大多是端口被占或模型太大放不进内存。端口在设置里改，
模型换成量化的更小一档。

**模型页是空的 / 看不到某个引擎的模型？**
模型页顶部可以切引擎，不启动、甚至没安装的引擎也能先浏览它适配什么。某个引擎一个
模型都没有时，页面顶部会出现三张推荐档位（Qwen3.6-35B-A3B / Qwen3.8-27B /
Qwen3.8-Flash-Next），下载后回到「本机」。自己放进目录的权重点「重新扫描」即可：
目录里的模型需要是引擎认识的格式（oMLX 支持 GGUF 和 safetensors 目录，MTPLX 用
`<owner>--<model>` 命名）。

**第一次下载引擎很慢？**
oMLX 的运行时包约 590 MB，Splash / MTPLX 在 80–130 MB 之间，取决于网速。

**换了模型后显存没释放？**
oMLX 可以在模型之间热切；Splash / MTPLX 换模型会重启进程，等状态变成「运行中」再发请求。

**想让别的机器访问？**
目前只监听 `127.0.0.1`。要对外暴露，请自己加一层反向代理，不要把端口直接开到公网。

**应用没签名 / 打不开？**
右键 → 打开；或者在「系统设置 → 隐私与安全性」里点「仍要打开」。

## 卸载

```bash
make uninstall
```

会停掉正在跑的引擎、删除 `/Applications/flashCat.app` 和登录项。
想连配置和模型软链一起清掉：

```bash
rm -rf ~/Library/Application\ Support/flashCat ~/Library/Logs/flashCat
```

模型本身在你自己的目录里（`~/.omlx`、`~/.mtplx` 等），不会被删。

## 从源码构建（可选）

需要 Xcode 命令行工具（Swift 6.4+）和 macOS 26.4+。

```bash
git clone https://github.com/imi4u36d/flashCat.git
cd flashCat
make app          # 构建并安装到 /Applications
INSTALL=0 make app   # 只构建到 dist/flashCat.app，不动 /Applications
make dmg          # 生成 dist/flashCat-<版本>.dmg / .pkg
make run          # 打开已安装的应用
make uninstall    # 卸载
```

版本号、构建号可以覆盖：`make app VERSION=1.2.0 BUILD_NUMBER=7`。

主要目录：

```
native/Sources/FlashCat/      应用本体（SwiftUI + AppKit）
native/Sources/FlashCatKit/   引擎运行时、安装器、状态解析、打包等核心逻辑
native/Tests/                 单元测试（swift test）
scripts/                      构建、图标、安装包、引擎包打包脚本
pack-index.json               内置的引擎发布索引
```

### 引擎运行时包

引擎以「运行时包」的形式分发，一个包就是某个引擎某个版本的完整可执行文件。
应用按索引里的 URL 下载并校验 sha256。索引来源的优先级：

1. 环境变量 `FLASHCAT_PACK_INDEX_URL` 指向的 JSON
2. 应用包内置的 `pack-index.json`

自己构建一个包并生成索引（仓库里不带上游二进制，先按需下载）：

```bash
scripts/fetch-runtime.sh 1.4.1                   # 把上游运行时包下载到 vendor/
make splash-pack                                  # 解成 flashCat 认的运行时包
scripts/engines/make-pack-index.sh --base-url https://你的域名/packs
```

也可以完全跳过下载：把构建好的运行时目录放进
`~/Library/Application Support/flashCat/engines/<引擎>/<版本>/`，应用启动时会直接识别。

## 许可

[MIT](LICENSE) © 2026 wangzhuo

三个推理引擎是各自上游项目的成果，本项目只做运行时的下载、安装与调度：
[Splash](https://github.com/incoai/splash)、
[oMLX](https://github.com/jundot/omlx)、
[MTPLX](https://github.com/youssofal/mtplx)。
模型版权归各自的发布者所有。
