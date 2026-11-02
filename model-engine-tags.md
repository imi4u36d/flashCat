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

现状里「一款模型属于哪个引擎」是被三份硬编码列表**隐式**表达出来的：写进 `splash` 那一份就归 Splash，写进 `omlx` 那一份就归 oMLX。这带来三个具体后果：一款权重同时能跑两个引擎时只能二选一（`Jundot/*-oQ4e-mtp` 被钉死在 oMLX）；`ModelLibrary` 只渲染列表里出现过的行，磁盘上没有对应的已装权重在界面上完全不存在；用户想用的模型只要不在那 9 款里就没有任何入口。

这次把归属变成**显式标签**，并让标签同样适用于用户自己从 Hub 搜到的仓库。

## 决定

**归属是一组事实，不是一张表的成员。** `ModelRecommendation` 携带 `engines: Set<EngineID>`；目录只有一份，`list(for:)` 按标签过滤。判据是产品性的而不是技术性的：**通用模型只给 oMLX**（oMLX 是通用引擎），Splash / MTPLX 只吃各自的专用包——即使 Splash 技术上也能起 MLX 权重。

**存量权重照常可见。** `ModelLibrary` 从「只列目录里的行」改为「目录 ∪ 磁盘扫描」去重合并：目录里的按标签出现在对应引擎，盘上有但目录里没有的，作为「未收录」出现在它实际所在的引擎目录下。已装就是已装，标签只管推荐与下载归属。

**搜索在 Swift 侧。** Hugging Face 的两个请求（搜索 `/api/models?search=`、单仓库 `/api/models/{repo}?blobs=true`——列表接口的 `siblings[].size` 恒为 null，真实字节只能从单仓库接口拿）属于 FlashCatKit 的新模块，结果随快照下发——[flashcat-webui](native/Sources/FlashCat/WebUI-SPEC.md) 的边界是「网页不取数、不写盘」，这条不破例。

**格式靠仓库自报的元数据判定，不靠猜名字。** 判定是自上而下先命中先得的具体四步：① `library_name=mtplx`；② GGUF 证据（`library_name=gguf`、`gguf` 标记、根级 `*.gguf`、完整的 `VARIANT/` 分片目录）；③ MTPLX 运行时证据（`mtp.safetensors`、`mtplx_runtime.json`）；④ `library_name=mlx` 或 `mlx` 标记。没有「`library_name` 一律优先」这回事——`library_name=mlx` 同时带根级 `.gguf` 的仓库归 Splash（②先于④）。MTPLX 包同时带 `mlx` 标记，所以①必须排在④前面。有 safetensors + `config.json` 但四步都不命中的仓库归 oMLX 并标「未验证」；其余格式不出现在结果里。

**GGUF 的量化工件名直接问引擎的规则，不自己发明。** Splash 的 `install/upstream.py:select_gguf` 是唯一权威，它有两条规则：`:VARIANT` 一是「所有根级 GGUF 候选共享词前缀之后的剩余词用 `-` 连接」，二是兜底「唯一以 `-VARIANT` 结尾的文件」；`VARIANT/` 目录里的分片则以目录名作 variant，且要求 `-\d{5}-of-\d{5}` 五位数分片齐全。应用侧镜像这三条，选出的 token 必定被引擎接受——这是唯一让「任意 GGUF 仓库」可信的办法。

**体积与内存下限要标出估算。** 体积取单仓库接口的真实字节（列表接口的 `siblings[].size` 恒为 null）。内存下限按仓库是否在目录里分两源：**仓库 id 命中目录行时直接复用它的 `minimumMemory`**（那是有实测依据的值，含 KV cache，`Qwen3.6-35B-A3B-4bit` 是 32 GiB，而纯权重的 `ceil(bytes×1.2)` 只有 ≈23 GiB）；只有目录外的仓库才用 `ceil(bytes * 1.2)`，此时界面上带 ≈。两者都直接和 `DeviceProfile.memoryGB` 比，所以同一款模型无论在搜索里还是目录里都得给同一个数，否则会出现「搜索里能跑、目录里内存不够」。

**搜索结果只活在当前会话。** 切引擎、刷新状态、重启即散；下载完的变成「本机」留下。不落盘，也就没有缓存失效这一整类问题。

## 未确认的假设

- **oMLX 能加载「有 config.json + safetensors、但没有 mlx 标记」的仓库**——按产品规则这类归 oMLX 并标「未验证」，实际能否起得来没有验证过。
- **MTPLX 引擎能吃 Youssofal 以外打出的 `library_name=mtplx` 包**——判定只认元数据，没有验证过别的作者的包。
- **拆分 GGUF（`VARIANT/` 目录）只服务 Splash**——oMLX 侧不涉及，若将来要支持需另立判据。

## 明确不做

- gated / 私有仓库、`HF_TOKEN`：搜索与下载只碰公开仓库。
- 搜索结果落盘、最近搜索记忆。
- GGUF 的 `mmproj` 单独挑：与主权重同仓库的多模态投影不单独列出。
- 磁盘上多余权重的清理：这次只让它们可见，不动文件。
