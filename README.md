<img src="native/Sources/FlashCat/Resources/app-icon.png" width="96" align="right" alt="flashCat" />

# flashCat

**Mac 上的本地大模型控制台。** 在同一个窗口里装引擎、下模型、聊天，并把它变成
一个可以给自己任何 AI 客户端用的本地接口。

**优雅 · 流畅 · 高能**

[![flashCat 介绍视频（无旁白版）](https://github.com/imi4u36d/flashCat/releases/download/v1.5.1/flashCat-1.5.1-poster.png)](https://github.com/imi4u36d/flashCat/releases/download/v1.5.1/flashCat-1.5.1-intro.mp4)

<sub>▶ 50 秒介绍片 · 无旁白，建议开声音听垫乐 · 画面来自真实运行的 flashCat</sub>

不需要为每个引擎记一套参数；打开就能用，需要接别的工具时它就是一个
`http://127.0.0.1:9000/v1` 这样的地址。习惯终端的人也可以只装一次
`flashcat` 命令，把状态、启停、模型和对话都写进脚本。

---

## 亮点

**1. 灵动岛。** 窗口正中一颗常驻玻璃胶囊：引擎名、真实阶段（启动 / 加载权重 / 预热）、
实时 tok/s 与启停都在里面。通知在原位弹出，按信息 / 成功 / 警告 / 错误分级，3.2 秒后
回到引擎状态；点开就地展开通知历史或引擎详情，点外面收起。它替掉了状态栏、toast
和详情页三处信息。

**2. 多引擎聚合，模型无感切换。** Splash、oMLX、MTPLX、MLX-Serve、Strata 平级共存，
各有端口段、运行时、日志与模型目录。热切换引擎不停进程；重启类引擎也会显示阶段与
「已等待 m:ss」。对客户端更是无感——网关地址固定，换引擎、换端口都不用改 Base URL。

**3. 可定制的引擎设置。** 端口按引擎的段做校验；十三项旋钮按引擎翻译成它自己的启动参数
——MTP / DFlash2、`--max-memory`、`--max-context`、PLE 缓存与 SSD offload、思考预算、
额外参数。留空即交给引擎，默认值按引擎推荐给，新 pack 加旋钮也不用迁移配置。

**4. 模型下载。** 精选档位按本机内存配好，卡片直接标体积与内存下限；模型广场可以搜
Hugging Face、按下载量排序、筛 MLX / GGUF、翻页看模型卡（README 清洗后渲染、家族徽标）。
下载支持暂停与续传；权重落公共目录只存一份，下完勾给哪些引擎用。

**5. 直观的运行数据。** 解码速度、首字延迟、预填充、DFlash2 草稿接受率、缓存命中率、
当前上下文占用（如 `18K / 262K`）一屏读完；总解码是 60 秒实时曲线，最近请求逐条标出状态、
解码速度与上下文，请求结束后保留最后一条，不会整页归零。概览的读数统一按 1 秒一拍：
曲线画「此刻多快」，请求收尾即冻结；hero 大数字只显示「模型启动以来平均」。每个指标
只认一个数据源：速度类指标由网关按请求打点（墙钟窗口计量，成批到达也不闪），预填充优先
用引擎在响应里自报的逐请求耗时（`timings`，流式与非流式都带），没有才退回网关的 TTFT
口径；显存、接受率这些只有引擎量得到的走引擎。读数随来源自证粒度（LIVE / LAST / AVG），
量不出来的那一格画「—」，不拿到达间隔的下限编一个速度。

**6. 内置对话。** 流式输出、思考块、Markdown、温度 / top-p / 最大输出 / 思考等级；
回车发送、⌘回车换行；每条回复标 tok/s 与首字延迟；历史存本地，可随时新建与回看。
装完引擎第一件事就是验证它。

**7. 在对话里画图、出片。** 输入卡上有一个「画」开关：引擎声明了 `tool-use` 时，
对话模型会自己写分镜，一次给出多段提示词，客户端按同一组 seed 逐张调用图像模型，
画一张挂一张，再把成品交回对话模型接着写——支持视觉的模型还会先看图，再决定要不要补画。
图像 / 视频模型有自己的输入卡：尺寸、步数、种子、首尾帧；REF2VA 模型还能挂参考图与参考视频。
生成结果进「实验室」，提示词、模型与 seed 都在，重启不丢。

## 系统要求

| | |
| --- | --- |
| 芯片 | Apple Silicon（M 系列） |
| 系统 | macOS **26.0** 或更高 |
| 磁盘 | 应用约 15 MB（含 `flashcat` 命令行）；每个引擎约 50 MB ~ 600 MB；模型另算（每档 2 ~ 250 GB） |

界面跟随系统语言：**简体中文** 或 **English**。两种文案都随应用打包，切换系统语言后重开即可生效。

## 安装

从 [Releases](https://github.com/imi4u36d/flashCat/releases) 下载最新版本：

- `flashCat-<版本>.dmg` —— 打开后把 flashCat 拖进「应用程序」
- `flashCat-<版本>.pkg` —— 双击一路安装

应用没有做公证签名，第一次打开系统会拦一下：在 Finder 里**右键点 flashCat → 打开**，
之后就不会再问。第一次打开需要联网下载引擎运行时（80 MB ~ 600 MB，取决于选哪个引擎）。

## 第一次打开

1. 启动页会列出所有受支持引擎，选一个点下载，等它装好。
2. 装好后它就是默认引擎，窗口自动进入控制台。
3. 之后可以随时在「引擎」页安装其他引擎、切换默认引擎，或在「模型」页下载模型。

引擎都是平级 peer：

| 引擎 | 默认端口 | 适合 | 换模型 |
| --- | --- | --- | --- |
| **Splash** | 8000 | 单模型、最省事，带草稿加速 | 重启引擎 |
| **oMLX** | 8100 | 想同时常驻多个模型，换模型不停进程 | 热切换 |
| **MTPLX** | 8200 | 长上下文、多 token 预测 | 重启引擎 |
| **MLX-Serve** | 8300 | 通用 MLX / GGUF、多模型热加载、工具调用 | 热切换 |
| **Strata** | 8400 | SSD 专家流式、大 MoE、多硬件后端 | 重启引擎 |

所有引擎都支持对话与流式输出；视觉、思考、工具调用和多模型能力由引擎 descriptor
逐项声明，界面不会假设某个引擎必然具备。端口各占一段，互不冲突。

## 界面速览

**概览** —— 引擎状态、当前模型、实时速度曲线、内存与端口占用，以及当前会话
占用了多少上下文（例如 `18K / 262K`）。右侧是 API 网关地址
（OpenAI 与 Claude 各一行，都能一键复制）。

**对话** —— 内置聊天窗口。顶部可以切模型、调温度 / top-p / 最大输出、设置思考模式。
每条回复下方标着 tok/s 和首字延迟。对话记录存在本地，可以新建和翻看历史。

**模型** —— 每个引擎一份模型库，顶部先选引擎（没装的引擎也能先看它支持什么）。
装好的可以直接点「使用」，没装的点「下载」原地拉取，卡上标着体积、内存下限和量化格式
（`QUANT`：`Q4_K_M` / `oQ4e` / `8-bit` / `BF16`…）。
右上角「模型广场」打开搜索窗口：默认按热度列出 Hugging Face 上的仓库，也可以搜关键词、
按下载量排序，按「全部 / MLX / GGUF」筛权重格式，翻页继续往下看（HF 那边一页 30 条），点一行打开模型卡（README / 文件清单 / 标签），看完再决定要不要下。权重落到公共目录、
只存一份，下完再勾给哪些引擎用；卡片上的来源分为「引擎推荐」和「个人下载」两种。

**引擎** —— 每个引擎一张卡片：状态、端口、启动参数、上游版本比对，
可以一键更新、打开安装目录、查看日志、卸载某个版本。

**日志** —— 当前引擎的实时输出，可按「全部 / 提示 / 警告 / 错误」过滤、
搜关键词、暂停滚动、清空。

**设置** —— 外观、背景图与透明度、端口、开机自启、思考模式、推理等级、默认模型、
下载缓存目录、图像模型常驻等，行内即改即生效。

**实验室** —— 生成结果的作品库。顶部在「图片 / 视频」之间切换，一屏一页铺开缩略图，
左上翻页；点开看大图或播视频，提示词、模型与 seed 都在，可以复制回输入卡再画一次。
只收对话里生成的成品，用户拖进输入卡的底图与首帧图不会混进来。

页面跳转与常用动作都收在 **「页面 → 命令面板」**：七个页面、启停引擎、新对话、下载中心、
模型广场、切换外观、折叠边栏，输入关键词后点一行直达。应用内不注册键盘快捷键；
所有动作都可以用鼠标完成，键盘用户请使用下面介绍的 `flashcat` 命令行。

## 用自己的客户端连它

应用自带一个 **API 网关**，推荐所有客户端都接它：地址固定，OpenAI 和 Claude 两种格式
都能用。请求里的 `model` 会决定实际加载哪份权重：模型属于别的引擎就自动切引擎，
引擎没启动会自动拉起，加载完成后再转发。

| | |
| --- | --- |
| 地址 | `http://127.0.0.1:9000/v1`（端口可改） |
| OpenAI 格式 | `POST /v1/chat/completions`（支持流式） |
| Claude 格式 | `POST /v1/messages`、`POST /v1/messages/count_tokens`（支持流式） |
| 模型列表 | `GET /v1/models` |
| API Key | 本地服务不校验，填任意字符串即可 |

OpenAI 格式：

```bash
curl http://127.0.0.1:9000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "你的模型名",
    "messages": [{"role": "user", "content": "你好"}],
    "stream": true
  }'
```

Claude 格式（SDK 里 Base URL 填 `http://127.0.0.1:9000`）：

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

- 模型名填 `/v1/models` 里返回的名字；网关会按它确保对应模型已加载，概览页也能看到当前加载的是哪个
- Claude 格式会完整翻译给引擎：system 提示、图片、工具调用、stop 序列、
  思考块、以及 `end_turn` / `max_tokens` / `tool_use` 等停止原因都支持
- 也可以直连引擎自己（8000 / 8100 / 8200），但地址会随引擎切换变化，
  所以一般还是接网关

## 命令行 `flashcat`

应用自带一个完整的命令行客户端，和图形界面共用同一份引擎、模型、设置与日志。
`.pkg` 会在 `/usr/local/bin` 可写时把 `/usr/local/bin/flashcat` 指向应用内的
可执行文件；用 `.dmg` 安装或想手动放进 PATH 时：

```bash
/Applications/flashCat.app/Contents/Helpers/flashcat cli install
# 默认装到 ~/.local/bin/flashcat；加到 PATH：
export PATH="$HOME/.local/bin:$PATH"
```

`flashcat` 有两种工作方式：

- **应用在运行**：通过本机回环控制接口（默认 `127.0.0.1:9100`，每次启动随机令牌，
  只允许当前用户读取）执行启停、切模型、下载、改设置等动作。
- **应用没运行**：仍能查看磁盘上的引擎与模型、安装/卸载引擎、读写不需要副作用的
  配置、读日志；需要应用的动作会以退出码 `3` 明确失败，而不是假装成功。

```bash
flashcat                            # 状态：应用、引擎、网关、下载
flashcat engines list               # 五个引擎的安装版本与运行状态
flashcat engines install omlx       # 不需要图形界面，直接下载并安装运行时
flashcat engines start omlx         # 切换并等到权重真的加载完
flashcat models list --all          # 本机权重 + 推荐档位
flashcat models download mlx-community/Qwen3-8B-4bit --wait
flashcat models use <模型 id>       # 加载并等待就绪（必要时自动换引擎）
flashcat chat "用一句话解释 MoE"    # 走本地网关，流式输出
printf '总结这段日志\n' | flashcat chat - --model <模型 id> --json
flashcat logs --engine omlx -f      # 跟踪日志；--gateway / --control
flashcat config set appearance dark
flashcat gateway status             # OpenAI / Claude 网关
flashcat app open                   # 启动应用并等待控制接口就绪
flashcat doctor                     # 安装、权限、运行时、磁盘与 PATH 自检
```

离线安装引擎时，如果随应用分发的索引只带文件名、没有带归档，用
`--index <pack-index.json 或 URL>` 指向可下载的索引（或用
`FLASHCAT_PACK_INDEX_URL` 环境变量）；否则命令会以「索引里的归档不在本机」
明确失败，而不是启动一个注定失败的下载。

| 命令 | 用途 |
| --- | --- |
| `status` | 应用 / 引擎 / 网关 / 下载状态；`--watch` 持续刷新 |
| `engines` | `list`、`start`、`stop`、`restart`、`use`、`install`、`uninstall`、`port`、`logs` |
| `models` | `list`、`use`、`download`、`delete`、`path` |
| `chat` | 通过网关对话；支持 stdin、流式、思考过程与 JSON |
| `gateway` | `status`、`start`、`stop` |
| `logs` | 引擎 / 网关 / 控制接口日志，支持级别过滤与跟踪 |
| `config` | `list`、`get`、`set`、`unset`、`path` |
| `app` | `status`、`open`、`quit`、`restart`、`path` |
| `doctor` | 环境自检；有 `fail` 项时退出码为 1 |
| `completion` | 输出 zsh / bash / fish 补全脚本 |
| `cli` | 把 `flashcat` 链接到 PATH，或打印当前位置 |

**给脚本用。** 结果型命令都支持 `--json`（错误也是 JSON，写 stderr）；进度与提示
写 stderr，正文写 stdout，所以 `flashcat models list --json | jq` 不会混入日志。
退出码固定为：`0` 成功、`1` 失败、`2` 用法错误、`3` 应用未运行、`4` 找不到、
`5` 超时、`6` 状态冲突、`7` 控制令牌错误。`--timeout` 控制等待上限，`--quiet`
关掉提示，`--no-color` 或 `NO_COLOR` 关掉 ANSI 颜色。

控制接口的开关与端口在「设置 → 命令行接口」里；改端口后实际端口会写进
`control.json`，命令行自动跟随，不需要重新安装。接口只监听 `127.0.0.1`，
每次启动换一次随机令牌，`control.json` 以 `0600` 权限保存，因此同一台机器上的
其他用户不能驱动应用。

## 模型

模型都在应用里下载，来源是 Hugging Face。模型页把可直接加载的权重放在「本机模型」，
把当前 Mac 内存能承载、尚未下载的档位放在「FlashCat 推荐」：

| 档位 | 体积参考 | 说明 |
| --- | --- | --- |
| Qwen 3.6 35B-A3B | 约 16 ~ 20 GB | 每天用最稳的一档 |
| Qwen 3.8 27B | 约 16 ~ 21 GB | 新一代，质量和速度更均衡 |
| Qwen 3.8 Flash-Next | 约 99 GB | 最重的一档，需要 128 GB 内存 |

Splash 用 27B IQ3_S 与 Flash-Next Q2_0 的 GGUF；oMLX 使用 Jundot 的 `oQ4e` 量化；
MTPLX 另在低内存机器上把 MiMo 9B 与 Qwen3.5 4B 两个 Youssofal 优化包作为兜底。想跑别的模型，点模型页右上角
「＋ 下载模型」打开模型广场，搜或浏览 Hugging Face 仓库，点开看模型卡再下：权重落到公共目录、只存一份，下完再勾给
哪些引擎用（勾选只决定可见性，不复制文件）。能不能被某个引擎加载由引擎自己判断，
模型页会把已下载权重与尚未下载的「FlashCat 推荐」分开，本机权重再标出来源是「目录收录」还是「个人下载」。
走镜像或者下 gated 仓库时，可以在命令行里给两个偏好值（不填就是 huggingface.co、匿名访问）：

```bash
defaults write com.zhuo.flashCat hfEndpoint https://hf-mirror.com   # 镜像站
defaults write com.zhuo.flashCat hfToken hf_xxx                    # 有权限的 token
```

下载器（python）不读 macOS 的系统代理设置，所以启动下载时会把系统代理原样传给它；
挂着代理软件也不需要额外配置。

模型归属使用引擎标签：Splash 只出 GGUF，oMLX 主推 Jundot
`oQ4e` 包，MTPLX 主推 Qwen 并在低内存机器上兜底 MiMo 9B、Qwen3.5 4B。

磁盘上的位置（清理时用得上）：

| 内容 | 位置 |
| --- | --- |
| 应用配置、对话记录 | `~/Library/Application Support/flashCat` |
| 所有引擎的运行时 pack | `~/Library/Application Support/flashCat/engines/<引擎>/<版本>` |
| 所有引擎的模型 | `~/Library/Application Support/flashCat/models/<引擎>` |
| 公共目录（自己下载的模型） | `~/Library/Application Support/flashCat/shared-models` |
| 下载缓存 | 默认沿用 Hugging Face 的缓存目录，可在设置里改 |
| 控制接口 | `~/Library/Application Support/flashCat/control.json`（仅本机、权限 0600） |
| 日志 | `~/Library/Logs/flashCat` |

## 设置项

| 设置 | 说明 |
| --- | --- |
| 外观 | 跟随系统 / 浅色 / 深色，选中立即生效 |
| 端口 | 引擎监听端口，占用时会提示 |
| API 网关 | 双格式统一接口的开关与端口（默认 9000），改动立即生效 |
| 随 flashCat 启动 | 打开应用时自动把引擎拉起来 |
| 登录时启动 | 把 flashCat 加进 macOS 登录项 |
| 思考模式 | 自动 / 关闭 / 开启，控制思考模型是否先输出推理过程 |
| 推理等级 | 思考模式为「开启」时生效，档位由引擎决定 |
| 默认模型 | 引擎启动时自动加载哪个模型 |
| 下载缓存目录 | 模型下载缓存放哪里 |
| 命令行接口 | 本机 `flashcat` 命令连接的开关与端口（默认 9100） |
| 恢复默认设置 | 把上面各项恢复成出厂值 |

## 常见问题

**引擎起不来，或者一直转圈？**
去「日志」页看最后几行，多半是端口被占或模型太大放不进内存。换个端口，
或者选更小的一档模型。

**下载很慢？**
oMLX 的运行时约 590 MB，Splash / MTPLX 在 80 ~ 130 MB 之间；模型从十几 GB 到 99 GB，
主要看网速。

**换模型后内存没释放？**
oMLX 可以在模型之间热切；Splash / MTPLX 换模型会重启进程，
等状态变回「运行中」再发请求。

**想让别的机器访问？**
应用只监听本机 `127.0.0.1`。需要对外提供时请自己加一层反向代理，
不要把端口直接暴露到公网。

**应用打不开，提示损坏或来自未知开发者？**
右键 → 打开；或者到「系统设置 → 隐私与安全性」里点「仍要打开」。

**模型页看不到某个引擎的模型？**
顶部可以切换引擎，没安装的引擎也能先浏览它支持的精选档位。

**为什么应用里没有快捷键？**
这一版刻意不注册任何应用级快捷键：所有动作都有可点击的菜单项或按钮，需要键盘
效率时用 `flashcat` 命令行（支持补全、JSON 与脚本）。macOS 自己提供的文本编辑、
剪贴板、关闭窗口与退出等系统级按键不受影响。

**`flashcat` 提示应用未运行？**
先 `flashcat app open`。如果应用明明开着，检查「设置 → 命令行接口」是否被关闭，
或 `control.json` 是否被清理；`flashcat doctor` 会指出卡在哪一步。

**命令行端口被占用？**
控制接口在 9100 起、最多向后顺延 20 个端口，实际端口写在
`~/Library/Application Support/flashCat/control.json`，`flashcat` 会自动读取。

## 卸载

1. 退出 flashCat。
2. 把 `/Applications/flashCat.app` 拖进废纸篓。
3. 如果安装过命令行，删掉链接：`rm -f /usr/local/bin/flashcat ~/.local/bin/flashcat`
4. 想连配置和模型一起清掉，再删除：

```bash
rm -rf ~/Library/Application\ Support/flashCat ~/Library/Logs/flashCat
```

注意模型就存在这些目录里，删除等于把下载的权重一起删掉，执行前确认没有还想留着的模型。

## 许可

[MIT](LICENSE) © 2026 wangzhuo

各推理引擎是各自上游项目的成果，本项目负责运行时的下载、安装与调度：
[Splash](https://github.com/incoai/splash)、
[oMLX](https://github.com/jundot/omlx)、
[MTPLX](https://github.com/youssofal/mtplx)、
[MLX-Serve](https://github.com/ddalcu/mlx-serve)、
[Strata](https://github.com/Niko1221/Strata)。
模型版权归各自的发布者所有。
