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

现状里「一款模型属于哪个引擎」是被三份硬编码列表**隐式**表达出来的：写进 `splash` 那一份就归 Splash，写进 `omlx` 那一份就归 oMLX。这带来三个具体后果：一款权重同时能跑两个引擎时只能二选一（`Jundot/*-oQ4e-mtp` 被钉死在 oMLX）；`ModelLibrary` 只渲染列表里出现过的行，磁盘上没有对应的已装权重在界面上完全不存在；用户想用的模型只要不在那 27 行里就没有任何入口。

这次把归属变成**显式标签**，并让标签同样适用于用户自己从 Hub 搜到的仓库。

## 决定

**归属是一组事实，不是一张表的成员。** `ModelRecommendation` 携带 `engines: Set<EngineID>`；目录只有一份，`list(for:)` 按标签过滤。判据是产品性的而不是技术性的：**通用模型只给 oMLX**（oMLX 是通用引擎），Splash / MTPLX 只吃各自的专用包——即使 Splash 技术上也能起 MLX 权重。

**存量权重照常可见。** `ModelLibrary` 从「只列目录里的行」改为「目录 ∪ 磁盘扫描」去重合并：目录里的按标签出现在对应引擎，盘上有但目录里没有的，作为「未收录」出现在它实际所在的引擎目录下。已装就是已装，标签只管推荐与下载归属。

**搜索在 Swift 侧。** Hugging Face 的两个请求（`/api/models?search=`、`/api/models/{repo}/tree/main?recursive=true`）属于 FlashCatKit 的新模块，结果随快照下发——[flashcat-webui](../native/Sources/FlashCat/WebUI-SPEC.md) 的边界是「网页不取数、不写盘」，这条不破例。

**格式靠仓库自报的元数据判定，不靠猜名字。** `library_name` 实测取值为 `mlx` / `mtplx` / `gguf`（`Jundot/*-oQ4e-mtp` 这类带 MTP 头的 MLX 包也是 `mlx`）；`mtp.safetensors`、`mtplx_runtime.json` 作为 MTPLX 的二次证据，根级 `*.gguf` 作为 GGUF 的二次证据。有 safetensors + `config.json` 但没有任何标记的仓库按产品规则归 oMLX 并标「未验证」；其余格式不出现在结果里。

**GGUF 的量化工件名直接问引擎的规则，不自己发明。** Splash 的 `install/upstream.py:select_gguf` 是唯一权威：`:VARIANT` 等于「所有根级 GGUF 候选共享词前缀之后的剩余词用 `-` 连接」，`VARIANT/` 目录里的分片则以目录名作 variant。应用侧镜像同一算法，选出的 token 必定被引擎接受——这是唯一让「任意 GGUF 仓库」可信的办法。

**体积与内存下限要标出估算。** 体积取 tree 接口的真实字节（列表接口的 `size` 恒为 null），内存下限 = `ceil(bytes * 1.2)`，界面上一律带 ≈。

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
