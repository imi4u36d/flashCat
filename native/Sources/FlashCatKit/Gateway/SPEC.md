---
id: flashcat-gateway
type: submodule-design
status: draft
title: API 网关 — 双方言本地接口
parent: flashcat-kit
depends-on: [flashcat-kit]
---

# API 网关 — 双方言本地接口

## 职责

在一个固定地址上同时说两种客户端方言，把它们翻译给当前运行中的引擎。客户端只需钉一次 Base URL，换引擎、换端口都不用改配置。

## 对外接口

默认 `http://127.0.0.1:9000`，端口可改。

| 路由 | 方言 | 行为 |
| --- | --- | --- |
| `GET /`、`GET /health` | — | 服务健康文档，列出可用端点 |
| `GET /v1/models` | 双方言共用 | 跨引擎统一模型列表，活动引擎优先且去重，每项标出所属引擎与权重是否常驻；按请求头决定回答形状 |
| `GET /v1/models/<id>` | 双方言共用 | 单个模型条目 |
| `POST /v1/chat/completions` | OpenAI | 按请求的 `model` 解析归属引擎，确保该模型已加载后转发，支持流式 |
| `POST /v1/messages` | Anthropic | 完整翻译后按 `model` 解析并加载对应模型，再转发，支持流式 |
| `POST /v1/messages/count_tokens` | Anthropic | 本地估算 |

未命中的 POST 返回 404，非 POST 且未命中返回 405，错误体按该请求的方言给出。

**方言判定**只看请求头：带 `x-api-key` 或 `anthropic-version` 即为 Anthropic。

**Anthropic 方向的翻译是完整的**，不是只转文本：system 提示、图片、工具调用、stop 序列、思考块，以及 `end_turn` / `max_tokens` / `tool_use` 等停止原因。

**错误分类**用 Anthropic 的税则（`invalid_request_error` / `not_found_error` / `overloaded_error`）；OpenAI 透传路径用 `upstream` 并原样转发引擎的响应体，让客户端看到的是引擎自己的话。

## 边界

- **只监听回环。** 对外暴露不是本模块的事(见 [flashcat-product](../../../../goal-and-requirements.md) 的非目标)。
- **不做鉴权。** 本地服务不校验 API Key。
- **不实现推理。** 所有对话请求在模型就绪后转发给对应引擎的 OpenAI 兼容面；上游不可用时回答 503，而不是自己降级。
- **不直接持有进程生命周期。** 启停和模型切换归应用壳；网关通过 `AppState` 请求「让这个模型就绪」，再读取最终端口转发。引擎未启动时，这一步会把引擎拉起。

## 内部划分

三个文件承担三种职责，不许混淆：

- `AnthropicCodec` — 纯编解码与错误封装，不碰网络。
- `GatewayUpstream` — 唯一出网的地方；`/v1/models` 与非流式用缓冲响应，SSE 用字节流，让 chunk 在引擎产生的那一刻就到客户端。冷启动首 token 可能很慢，默认超时给得宽。
- `GatewayHTTPServer` — 只做 HTTP 解析与响应写出（JSON 一次写完，SSE 交给路由往会话里推事件）。

## 决策

**请求里的 `model` 是路由事实，不是装饰字段。** 客户端可能同时看到多个引擎的模型；网关先按 `GET /v1/models` 的优先顺序（活动引擎优先）解析模型归属，再切引擎/换权重并等待真正就绪。不能把请求原样丢给当前引擎：部分引擎会忽略未知模型名，直接用已常驻的权重回答，客户端于是拿到了错误模型的成功响应。

**API 请求会拉起模型，但不能绕过应用状态机。** 引擎未运行时由应用壳启动，热引擎换权重时走 unload-confirm-load，重启引擎先停旧进程。并发 API 请求在网关侧串行准备，避免两次 load 抢同一个单飞位。

**会话级读数在网关侧统计，不在引擎侧。** 引擎层没有 per-session 指标：splash 只报累计的 `decode_output_tokens / decode_wall_ms`，oMLX 只给聚合吞吐和一个在跑计数，MTPLX 更极端——串行到连「有几路在排队」都不报（排队被算进了在跑）。唯一知道每个请求何时进来、首个 token 何时到达、一共吐了多少字的地方就是网关本身，所以概览页的「会话」网格取数于此。

因此 `GatewayMeter` 的线程模型也是被这个职责决定的：转发跑在非主 actor 上，打点密度是每 250 ms 一格，所以它是用 `NSLock` 保护的普通类，而不是 `@MainActor` 的 `ObservableObject`；读侧只做一次快照，不做增量订阅。

**预填充的分子只算真正前向过的 token。** 会话第二轮的 `prompt_tokens` 几乎全是命中前缀缓存的上下文，引擎并没有重新计算它们；用整段 token 除以首字耗时，读数会随上下文长度线性虚高（108K 上下文实测能到几十万 tok/s）。网关从 usage 的 `prompt_tokens_details.cached_tokens`（Anthropic 方言为 `input_tokens_details.cached_tokens`）扣掉命中量，全命中时不报预填充，交给引擎自己的实时计数。工具调用的 `function.arguments` 同样计入生成量——agent 会话的大头在那里，不数就会永远显示 0 tok/s。
