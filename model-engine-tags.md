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

**落地后要折回上游文档的改动（别漏）。** 这份任务书是临时的：`goal-and-requirements.md:29` 现在写着「内置固定三档 Qwen」，那是标签制之前的事实；落地后要让 Splash 页只剩 GGUF 一档、其余归 oMLX，这句必须改，[flashcat-product](goal-and-requirements.md) 与 [README](README.md) 里「每引擎一份列表」的说法同理。`native/Sources/FlashCat/SPEC.md:19` 现在写的是「当前归属仍是列表成员（`suggested`/`isPinned`/`allows`），`ModelRecommendation` 还没有 `engines` 字段」，落地后要改成 `engines`。这三处连同本文件一起，在计划最后一步收口（见任务清单的「删掉任务书与三处指针」）。

**归属是一组事实，不是一张表的成员。** `ModelRecommendation` 携带 `engines: Set<EngineID>`；目录只有一份，`list(for:)` 按标签过滤。判据是产品性的而不是技术性的：**通用 MLX 权重给 oMLX 与 MLX-Serve**、Splash / MTPLX / Strata 按各自的专用包与产品分工收录——即使 Splash 技术上也能起 MLX 权重；一款模型能跑多个引擎时写多个标签，标签不是互斥的。

现有 10 款按格式严格归类，没有例外。注意这张表的依据是**产品取舍**而不是引擎能力：oMLX 技术上也能起 GGUF——`native/Tests/FlashCatKitTests/Fixtures/omlx/models-status.json` 里它同时托管 `Qwen3.8-Flash-Next-GSQ-RCO-Q2_0`（`model_format: gguf`、`engine_type: vlm`、`is_helper: false`）与一份 `DFlash2-Q8_0`，`EngineStore.swift:445` 的注释也写着「all three packs serve those directly」。我们仍然不让 GGUF 进 oMLX 的推荐与搜索，理由是产品分工：GGUF/GGUF 草稿这条线归 Splash，oMLX 作为通用引擎只吃 MLX 权重。别把这张表当能力矩阵实现，也别因为「oMLX 其实能跑」就顺手放宽。

| 仓库 | `engines` | 依据 |
| --- | --- | --- |
| `Jundot/Qwen3.6-35B-A3B-oQ4e-mtp` | `{omlx, mlx-serve}` | oQ4e 量化，带 MTP 头 |
| `Jundot/Qwen3.8-27B-oQ4e-mtp` | `{omlx, mlx-serve}` | 同上 |
| `Jundot/Qwen3.8-Flash-Next-oQ4e-mtp` | `{omlx, mlx-serve}` | 同上 |
| `ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF:IQ3_S` | `{splash}` | 24 GB 起的 27B GGUF，IQ3_S 约 3.5 bpw |
| `ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0` | `{splash, strata}` | Splash 的 GGUF 通道；同一份文件可由 Strata 受管准备 |
| `Youssofal/Qwen3.6-35B-A3B-MTPLX-Optimized-Speed` | `{mtplx}` | `library_name=mtplx` 专用包 |
| `Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed` | `{mtplx}` | 同上 |
| `Youssofal/Qwen3.8-Flash-Next-MTPLX-Optimized-Speed` | `{mtplx}` | 同上 |
| `Youssofal/MiMo-V2.6-Qwen-9B-MTPLX-Optimized-Speed` | `{mtplx}` | 同上；目录收录，不参与硬件三档 |
| `Youssofal/Qwen3.5-4B-MTPLX-Optimized-Speed` | `{mtplx}` | 同上 |

结论是 **Splash 页主推 27B IQ3_S 与 Flash-Next Q2_0 两档 GGUF，oMLX 与 MLX-Serve 页主推三档 Jundot 的 oQ4e 包，MTPLX 页主推三档 Qwen 并额外收录 MiMo 9B、Qwen3.5 4B 两款 Youssofal 包，Strata 复用 Flash-Next Q2_0**——这是产品规则要的结果，不是遗漏。模型页会把已下载权重放在「本机模型」，把当前 Mac 内存能承载且尚未下载的档位放在「FlashCat 推荐」。额外收录项用 `rank: 0` 在低内存机器上没有正式档可跑时兜底，不参与高内存机器的推荐。**草稿仓库不成行**：`incoai/*-DFlash2` 只作为主行的 `draftRepository` 挂在主行上，界面上既不单独出现、也不带标签，所以没有「草稿该归谁」这个问题。

**存量权重照常可见，页过滤只管推荐与搜索。** `ModelLibrary` 从「只列目录里的行」改为「目录 ∪ 磁盘扫描」去重合并：目录里的按标签出现在对应引擎，盘上有但目录里没有的，作为「未收录」出现在**它实际所在的那个目录对应的引擎页**。已装就是已装，标签只管推荐与下载归属。

这条与上两段的页过滤不冲突：页过滤管的是「推荐哪几款」和「搜出哪几个仓库」，不管「盘上已经有什么」。具体的难题是升级时 Splash 目录里已有 `mlx-community/Qwen3.6-35B-A3B-4bit` 这类被改判为 oMLX 的权重——它们不会被隐藏（隐藏了用户就再也没有入口删改它们），而是在 Splash 页作为「未收录」行留着，标签显式写 `oMLX`，行上只说清楚「这一款归 oMLX」，不做任何自动迁移：现有机制都帮不上忙——`applyModelFromAnyEngine` 一旦发现目标引擎的清单里没这个 id 就会 toast「oMLX 没有模型」然后返回（`native/Sources/FlashCat/AppState.swift:798`），而 `EngineModelStore.adoptExistingWeights` 只会扫引擎自己目录里的链接、并把链接目标**移**进去（`EngineStore.swift:265`），把 Splash 那份挪走就刚好让这行失去依托。所以这一版的行为是：行在、标签在、可以删；要用 oMLX 跑就按 oMLX 页正常的下载流程来。oMLX 页那份对应目录行仍是「下载」状态，不把已经存在的文件当成已装。

**搜索在 Swift 侧。** Hugging Face 的两个请求（搜索 `/api/models?search=`、单仓库 `/api/models/{repo}?blobs=true`——列表接口的 `siblings[].size` 恒为 null，真实字节只能从单仓库接口拿）属于 FlashCatKit 的新模块，结果随快照下发——桥上一格命令 `searchHub {query}`、快照里一格 `hubSearch: {query, state, results}`（已记入 [flashcat-webui](native/Sources/FlashCat/WebUI-SPEC.md) 的桥协议）——[flashcat-webui](native/Sources/FlashCat/WebUI-SPEC.md) 的边界是「网页不取数、不写盘」，这条不破例。

**格式靠仓库自报的元数据判定，不靠猜名字。** 判定是自上而下先命中先得的具体四步：① `library_name=mtplx`；② GGUF 证据（`library_name=gguf`、`gguf` 标记、根级非 `mmproj` 的 `*.gguf`、完整的 `VARIANT/` 分片目录）；③ MTPLX 运行时证据（`mtp.safetensors`、`mtplx_runtime.json`）；④ `library_name=mlx` 或 `mlx` 标记。没有「`library_name` 一律优先」这回事——`library_name=mlx` 同时带根级 `.gguf` 的仓库归 Splash（②先于④）。MTPLX 包同时带 `mlx` 标记，所以①必须排在④前面。有 safetensors + `config.json` 但四步都不命中的仓库归 oMLX 并标「未验证」；其余格式不出现在结果里。

**GGUF 的量化工件名直接问引擎的规则，不自己发明。** Splash 的 `install/upstream.py:select_gguf` 是唯一权威，它认四种名字：① `:VARIANT` 等于「所有根级 GGUF 候选共享词前缀之后的剩余词用 `-` 连接」；② 兜底「唯一以 `-VARIANT` 结尾的文件」；③ `VARIANT/` 目录名，但要求 `-\d{5}-of-\d{5}` 五位数分片齐全；④ **只有一个根级 GGUF 且没有分片目录时根本不用 variant**——id 就是 `owner/repo`，给它拼个 token 反而会被引擎拒。应用侧逐条镜像这四种写法，选出的 token 必定被引擎接受——这是唯一让「任意 GGUF 仓库」可信的办法。

**体积与内存下限要标出估算。** 体积取单仓库接口的真实字节（列表接口的 `siblings[].size` 恒为 null）。内存下限分两源：**仓库 id 与所选量化都命中目录行时，直接复用它的 `minimumMemory`**（那是有实测依据的值，含 KV cache，`Qwen3.6-35B-A3B-4bit` 是 32 GiB，而纯权重的 `ceil(bytes×1.2)` 只有 ≈23 GiB）。量化必须也对得上——目录里 `ISTA-DASLab/…-GGUF` 钉的是 `Q2_0`（≈64 GiB），搜索里选了 `Q8_0` 就再拿 64 当底就荒唐了，这种情形走 `ceil(bytes * 1.2)`。目录外的仓库同理，一律按实际字节估，带 ≈。两者最后都直接和 `DeviceProfile.memoryGB` 比，所以同一款模型的同一量化无论在搜索里还是目录里都得给同一个数，否则会出现「搜索里能跑、目录里内存不够」。

**搜索结果只活在当前会话。** 切引擎、刷新状态、重启即散；下载完的变成「本机」留下。不落盘，也就没有缓存失效这一整类问题。

**搜索按页过滤，下载落到标签对应的引擎目录。** 搜索不是跨引擎的大杂烩：模型页当前在哪一栏，就只列该栏能消费的仓库——Splash 与 Strata 页出 `.gguf`、MTPLX 页出判为 `.mtplx` 的仓库、oMLX 与 MLX-Serve 页出 MLX（含「未验证」）。同一个 GGUF 可以同时出现在 Splash 和 Strata，同一个 MLX 行可以同时出现在 oMLX 和 MLX-Serve；其它列不出现。页过滤与格式判定共用同一个输入，不另外再写一套 `library_name` 条件。下载路由由当前选中的 engine descriptor 决定，标签、模型目录布局与下载策略保持同一个来源，不会出现「在 A 栏下了个只属于 B 的权重」这种自相矛盾的局面。

## 未确认的假设

- **oMLX 能加载「有 config.json + safetensors、但没有 mlx 标记」的仓库**——按产品规则这类归 oMLX 并标「未验证」，实际能否起得来没有验证过。
- **MTPLX 引擎能吃 Youssofal 以外打出的 `library_name=mtplx` 包**——判定只认元数据，没有验证过别的作者的包。
- **拆分 GGUF（`VARIANT/` 目录）只服务 Splash**——oMLX 侧不涉及，若将来要支持需另立判据。

## 明确不做

- **跨引擎搬权重。** 已装在 Splash 目录里的权重不会自动复制或链接进 oMLX（目录不同、`adoptExistingWeights` 会移走目标、复制又是 20 GB 量级），只靠标签告知归属。
- gated / 私有仓库、`HF_TOKEN`：搜索与下载只碰公开仓库。
- 搜索结果落盘、最近搜索记忆。
- GGUF 的 `mmproj` 单独挑：与主权重同仓库的多模态投影不单独列出。
- 磁盘上多余权重的清理：这次只让它们可见，不动文件。
