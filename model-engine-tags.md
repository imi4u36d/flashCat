---
id: task-model-engine-tags
type: task-spec
status: draft
title: 模型引擎标签与 Hugging Face 搜索
parent: flashcat-app
depends-on: [flashcat-app, flashcat-webui, flashcat-kit]
tags: [models, huggingface, tags]
---

## Purpose

现状里「一款模型属于哪个引擎」是被三份硬编码列表**隐式**表达出来的：写进 `splash` 那一份就归 Splash，写进 `omlx` 那一份就归 oMLX。这带来三个具体后果：归属藏在代码里，判一个模型属于谁要翻三处列表加一张 `details` 表（`ISTA-DASLab` 的 GGUF 带 `incoai` 草稿、`Jundot` 的 MTP 头两个事实都写在行外）；`ModelLibrary` 只渲染列表里出现过的行，磁盘上没有对应的已装权重在界面上完全不存在；用户想用的模型只要不在那 9 款里就没有任何入口。

这次把归属变成**显式标签**，并让标签同样适用于用户自己从 Hub 搜到的仓库。

## 决定

**归属是一组事实，不是一张表的成员。** `ModelRecommendation` 携带 `engines: Set<EngineID>`；目录只有一份，`list(for:)` 按标签过滤。判据是产品性的而不是技术性的：**通用 MLX 权重只给 oMLX**（oMLX 是通用引擎）、Splash / MTPLX 只吃各自的专用包——即使 Splash 技术上也能起 MLX 权重；一款模型能跑多个引擎时写多个标签，标签不是互斥的。

现有 9 款按格式严格归类，没有例外：

| 仓库 | `engines` | 依据 |
| --- | --- | --- |
| `mlx-community/Qwen3.6-35B-A3B-4bit` | `{omlx}` | MLX 权重，通用 |
| `mlx-community/Qwen3.8-27B-4bit` | `{omlx}` | 同上 |
| `Jundot/Qwen3.6-35B-A3B-oQ4e-mtp` | `{omlx}` | 带 MTP 头的 MLX 权重，仍是 MLX |
| `mlx-works/Qwen3.8-27B-oQ4e-mtp` | `{omlx}` | 同上 |
| `Jundot/Qwen3.8-Flash-Next-oQ4e-mtp` | `{omlx}` | 同上 |
| `ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0` | `{splash}` | GGUF，只有 Splash 能跑 |
| `Youssofal/Qwen3.6-35B-A3B-MTPLX-Optimized-Speed` | `{mtplx}` | `library_name=mtplx` 专用包 |
| `Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed` | `{mtplx}` | 同上 |
| `Youssofal/Qwen3.8-Flash-Next-MTPLX-Optimized-Speed` | `{mtplx}` | 同上 |

结论是 **Splash 页只会剩 Flash-Next 的 GGUF 一档，MTPLX 页只剩三款 Youssofal 包，其余全部在 oMLX**——这是产品规则要的结果，不是遗漏。**草稿仓库不成行**：`incoai/*-DFlash2` 只作为主行的 `draftRepository` 挂在主行上，下载主行时一并拉取（oMLX 也已通过 `dflash_draft_model` 吃草稿），界面上既不单独出现、也不带标签，所以没有「草稿该归谁」这个问题。

**存量权重照常可见。** `ModelLibrary` 从「只列目录里的行」改为「目录 ∪ 磁盘扫描」去重合并：目录里的按标签出现在对应引擎，盘上有但目录里没有的，作为「未收录」出现在它实际所在的引擎目录下。已装就是已装，标签只管推荐与下载归属。

**搜索在 Swift 侧。** Hugging Face 的两个请求（搜索 `/api/models?search=`、单仓库 `/api/models/{repo}?blobs=true`——列表接口的 `siblings[].size` 恒为 null，真实字节只能从单仓库接口拿）属于 FlashCatKit 的新模块，结果随快照下发——[flashcat-webui](native/Sources/FlashCat/WebUI-SPEC.md) 的边界是「网页不取数、不写盘」，这条不破例。

**格式靠仓库自报的元数据判定，不靠猜名字。** 判定是自上而下先命中先得的具体四步：① `library_name=mtplx`；② GGUF 证据（`library_name=gguf`、`gguf` 标记、根级 `*.gguf`、完整的 `VARIANT/` 分片目录）；③ MTPLX 运行时证据（`mtp.safetensors`、`mtplx_runtime.json`）；④ `library_name=mlx` 或 `mlx` 标记。没有「`library_name` 一律优先」这回事——`library_name=mlx` 同时带根级 `.gguf` 的仓库归 Splash（②先于④）。MTPLX 包同时带 `mlx` 标记，所以①必须排在④前面。有 safetensors + `config.json` 但四步都不命中的仓库归 oMLX 并标「未验证」；其余格式不出现在结果里。

**GGUF 的量化工件名直接问引擎的规则，不自己发明。** Splash 的 `install/upstream.py:select_gguf` 是唯一权威，它认四种名字：① `:VARIANT` 等于「所有根级 GGUF 候选共享词前缀之后的剩余词用 `-` 连接」；② 兜底「唯一以 `-VARIANT` 结尾的文件」；③ `VARIANT/` 目录名，但要求 `-\d{5}-of-\d{5}` 五位数分片齐全；④ **只有一个根级 GGUF 且没有分片目录时根本不用 variant**——id 就是 `owner/repo`，给它拼个 token 反而会被引擎拒。应用侧逐条镜像这四种写法，选出的 token 必定被引擎接受——这是唯一让「任意 GGUF 仓库」可信的办法。

**体积与内存下限要标出估算。** 体积取单仓库接口的真实字节（列表接口的 `siblings[].size` 恒为 null）。内存下限按仓库是否在目录里分两源：**仓库 id 命中目录行时直接复用它的 `minimumMemory`**（那是有实测依据的值，含 KV cache，`Qwen3.6-35B-A3B-4bit` 是 32 GiB，而纯权重的 `ceil(bytes×1.2)` 只有 ≈23 GiB）；只有目录外的仓库才用 `ceil(bytes * 1.2)`，此时界面上带 ≈。两者都直接和 `DeviceProfile.memoryGB` 比，所以同一款模型无论在搜索里还是目录里都得给同一个数，否则会出现「搜索里能跑、目录里内存不够」。

**搜索结果只活在当前会话。** 切引擎、刷新状态、重启即散；下载完的变成「本机」留下。不落盘，也就没有缓存失效这一整类问题。

**搜索按页过滤，下载落到标签对应的引擎目录。** 搜索不是跨引擎的大杂烩：模型页当前在哪一栏，就只列能进那一栏的仓库——Splash 页只出 GGUF、MTPLX 页只出 `library_name=mtplx` 的包、oMLX 页只出其余 MLX（含「未验证」），这与「只有 oMLX 能用的模型不出现在另外两页」是同一条规则。因此下载路由不用猜：仓库的判定结果就是它该去的引擎，标签与下载目录永远指向同一个引擎，不会出现「在 Splash 页下了个 MLX 仓库、装进 Splash 目录后又被当成 Splash 的未收录行」这种自相矛盾的局面。

## 未确认的假设

- **oMLX 能加载「有 config.json + safetensors、但没有 mlx 标记」的仓库**——按产品规则这类归 oMLX 并标「未验证」，实际能否起得来没有验证过。
- **MTPLX 引擎能吃 Youssofal 以外打出的 `library_name=mtplx` 包**——判定只认元数据，没有验证过别的作者的包。
- **拆分 GGUF（`VARIANT/` 目录）只服务 Splash**——oMLX 侧不涉及，若将来要支持需另立判据。

## 明确不做

- gated / 私有仓库、`HF_TOKEN`：搜索与下载只碰公开仓库。
- 搜索结果落盘、最近搜索记忆。
- GGUF 的 `mmproj` 单独挑：与主权重同仓库的多模态投影不单独列出。
- 磁盘上多余权重的清理：这次只让它们可见，不动文件。
