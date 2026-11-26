<img src="native/Sources/FlashCat/Resources/app-icon.png" width="88" align="right" alt="flashCat" />

# flashCat

**Mac 上的本地大模型控制台。** 在一个窗口里安装推理引擎、下载模型、对话，并把整台机器
变成一个任何 AI 客户端都能接入的本机接口。

**优雅 · 流畅 · 高能**

简体中文 | [English](README.en.md)

[![Release](https://img.shields.io/github/v/release/imi4u36d/flashCat?display_name=tag&style=flat-square)](https://github.com/imi4u36d/flashCat/releases/latest)
[![macOS 26+](https://img.shields.io/badge/macOS-26.0%2B-black?style=flat-square)](https://github.com/imi4u36d/flashCat/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

![flashCat 概览](https://flashxlab.com/assets/overview.webp)

## 功能

- **四引擎统一管理。** Splash、oMLX、MTPLX、MLX-Serve 平级共存，各有运行时、模型目录与
  日志。端口自动分配，被占用时顺延；oMLX 与 MLX-Serve 换模型不停进程。
- **一个本机接口。** 固定的 `http://127.0.0.1:9000/v1`，同时支持 OpenAI 与 Claude 两种
  格式。网关按请求里的模型名自动切换或拉起对应引擎，客户端不用改 Base URL。
- **模型库与广场。** 从 Hugging Face、HF-Mirror 或 ModelScope 搜索、查看模型卡并下载；
  GGUF 可按量化选择，下载支持暂停与续传。权重默认落在公共目录，所有引擎共享一份。
- **可用的对话。** 流式输出、思考块、Markdown、编辑重发、分支与重新生成；生成中回车
  排队发送。支持文本 / 源码 / PDF / RTF 附件与图片、视频输入，⌘V 可直接粘贴截图。
  会话存在本地，可搜索、置顶、重命名。
- **真实运行数据。** 解码速度、首字延迟、预填充、缓存命中率与上下文占用；60 秒实时曲线
  与逐条请求记录。指标由网关按请求打点，量不出来的读数明确标 `—`。
- **按自己习惯用。** 跟随系统 / 日间 / 夜间三档外观，六种主题色加系统取色器；原生标题栏
  与侧栏；菜单栏面板可在不切回主窗口时切模型、看遥测。
- **完整的命令行。** 内置 `flashcat`，与图形界面共用同一份引擎、模型、设置与日志，
  所有结果型命令支持 `--json`，便于脚本集成。

## 系统要求

| | |
| --- | --- |
| 芯片 | Apple Silicon（M 系列） |
| 系统 | macOS 26.0 或更高 |
| 磁盘 | 应用约 15 MB；每个引擎运行时约 50–600 MB；模型按档位 2–250 GB |

界面随系统语言显示简体中文或 English，两种文案都随应用打包。

## 安装

从 [Releases](https://github.com/imi4u36d/flashCat/releases/latest) 下载：

- `flashCat-2.0.0.dmg`：打开后把 flashCat 拖进「应用程序」。
- `flashCat-2.0.0.pkg`：双击按提示安装，可将 `flashcat` 链接到 `/usr/local/bin`。

应用使用 ad-hoc 签名，未经过 Apple 公证。首次打开若被 Gatekeeper 拦截，在 Finder 中
右键 flashCat →「打开」，或到「系统设置 → 隐私与安全性」点「仍要打开」。

## 快速开始

1. 启动后在引导页选择一个引擎下载并安装。
2. 在「模型库」下载一个模型，或在「模型广场」搜索任意 Hugging Face / ModelScope 仓库。
3. 回到「概览」启动引擎，进入「对话」验证；其他客户端接 `http://127.0.0.1:9000/v1`。

引擎运行时按需下载，不随应用打包。已装引擎可随时在「引擎」页更新、查看日志或卸载。

## 本机接口

应用启动后接口自动可用，无需手动开启。OpenAI 与 Claude 两种格式共用同一个端口，
API Key 不校验，填任意字符串即可。

| | |
| --- | --- |
| 地址 | `http://127.0.0.1:9000/v1`（端口可在设置中修改） |
| OpenAI | `POST /v1/chat/completions`（流式） |
| Claude | `POST /v1/messages`、`POST /v1/messages/count_tokens`（流式） |
| 模型列表 | `GET /v1/models` |

```bash
curl http://127.0.0.1:9000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "你的模型名",
    "messages": [{"role": "user", "content": "你好"}],
    "stream": true
  }'
```

Claude SDK 把 Base URL 填 `http://127.0.0.1:9000` 即可。模型名取自 `/v1/models`；
网关会确保对应权重已加载。接口只监听本机回环地址，不对外暴露。

## 命令行

`flashcat` 与图形界面共用状态，应用运行时通过本机控制接口驱动，应用未运行时仍可查看和
安装引擎、读写配置、读取日志。

```bash
flashcat                            # 应用、引擎、网关与下载状态
flashcat engines list               # 四个引擎的安装版本与运行状态
flashcat engines start omlx         # 切换引擎并等待权重加载完成
flashcat models list --all          # 本机权重与推荐档位
flashcat models download mlx-community/Qwen3-8B-4bit --wait
flashcat chat "用一句话解释 MoE"    # 走本地网关，流式输出
flashcat logs --engine omlx -f      # 跟踪引擎日志
flashcat doctor                     # 安装、权限、运行时与 PATH 自检
```

`.pkg` 安装时会把 `/usr/local/bin/flashcat` 指向应用内可执行文件；用 `.dmg` 或想手动
放到 PATH 时执行 `flashcat cli install`。完整命令见 `flashcat --help`。

退出码固定为 `0` 成功、`1` 失败、`2` 用法错误、`3` 应用未运行、`4` 找不到、`5` 超时、
`6` 状态冲突、`7` 控制令牌错误；错误信息也支持 `--json`。

## 模型与数据

| 内容 | 位置 |
| --- | --- |
| 应用配置、对话记录 | `~/Library/Application Support/flashCat` |
| 引擎运行时 | `~/Library/Application Support/flashCat/engines/<引擎>/<版本>` |
| 模型权重 | `~/Library/Application Support/flashCat/models/<引擎>` |
| 公共模型目录 | `~/Library/Application Support/flashCat/shared-models` |
| 控制接口凭据 | `~/Library/Application Support/flashCat/control.json`（权限 0600） |
| 日志 | `~/Library/Logs/flashCat` |

推荐档位来自已安装引擎自带的目录；Splash 与 MTPLX 提供推荐，oMLX 与 MLX-Serve 不提供。
自己从模型广场下载的权重标记为「个人下载」。删除应用不会删除模型与引擎，需要一并清理时
手动删除上述目录。

## 设置

通用（外观、开机自启、下载缓存、主题色）、模型来源（Hugging Face / HF-Mirror /
ModelScope、镜像地址与 token）、接口（网关与控制端口）、对话（默认参数、系统提示）、
关于（版本与更新检查）。两个本机接口始终启用；引擎端口不是设置项，由应用自动分配。

## 常见问题

**引擎起不来或一直转圈？** 查看「日志」页最后几行，通常是模型超出内存或文件不完整。
换更小的量化，或在「引擎」页重新安装运行时。

**模型库看不到某个引擎的模型？** 顶部可切换引擎；推荐档位依赖引擎包，未安装的引擎
没有目录可读。

**想让其他机器访问？** 应用只监听 `127.0.0.1`。需要对外提供时请自行加反向代理，
不要把端口直接暴露到公网。

**`flashcat` 提示应用未运行？** 先执行 `flashcat app open`；`flashcat doctor`
会指出卡在哪一步。

## 开发

```bash
make app      # 构建并安装到 /Applications
make test     # Swift 单元测试（778 条，5 条依赖本机环境自动跳过）
make verify   # 构建、安装、启动并验证进程与内置 CLI
```

源码在 `native/`，界面使用 SwiftUI / AppKit，无 WebView。开发环境、架构约束与提交流程
见 [CONTRIBUTING.md](CONTRIBUTING.md)，界面规范见 [UI-SPEC.md](native/Sources/FlashCat/UI-SPEC.md)。

## 许可

[MIT](LICENSE) © 2026 wangzhuo

推理引擎是各自上游项目的成果，本项目负责运行时的下载、安装与调度：
[Splash](https://github.com/incoai/splash)、
[oMLX](https://github.com/jundot/omlx)、
[MTPLX](https://github.com/youssofal/mtplx)、
[MLX-Serve](https://github.com/ddalcu/mlx-serve)。
模型版权归各自发布者所有。
