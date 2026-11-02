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
| `POST /v1/chat/completions` | OpenAI | 转发给引擎，支持流式 |
| `POST /v1/messages` | Anthropic | 完整翻译后转发，支持流式 |
| `POST /v1/messages/count_tokens` | Anthropic | 本地估算 |

未命中的 POST 返回 404，非 POST 且未命中返回 405，错误体按该请求的方言给出。

**方言判定**只看请求头：带 `x-api-key` 或 `anthropic-version` 即为 Anthropic。

**Anthropic 方向的翻译是完整的**，不是只转文本：system 提示、图片、工具调用、stop 序列、思考块，以及 `end_turn` / `max_tokens` / `tool_use` 等停止原因。

**错误分类**用 Anthropic 的税则（`invalid_request_error` / `not_found_error` / `overloaded_error`）；OpenAI 透传路径用 `upstream` 并原样转发引擎的响应体，让客户端看到的是引擎自己的话。

## 边界

- **只监听回环。** 对外暴露不是本模块的事（见 [flashcat-product](../../../goal-and-requirements.md) 的非目标）。
- **不做鉴权。** 本地服务不校验 API Key。
- **不实现推理。** 所有对话请求都转发给当前引擎的 OpenAI 兼容面；上游不可用时回答 503，而不是自己降级。
- **不持有引擎生命周期。** 启停归应用壳；网关只观察「当前是哪个引擎、它在什么端口」。

## 内部划分

三个文件承担三种职责，不许混淆：

- `AnthropicCodec` — 纯编解码与错误封装，不碰网络。
- `GatewayUpstream` — 唯一出网的地方；`/v1/models` 与非流式用缓冲响应，SSE 用字节流，让 chunk 在引擎产生的那一刻就到客户端。冷启动首 token 可能很慢，默认超时给得宽。
- `GatewayHTTPServer` — 只做 HTTP 解析与响应写出（JSON 一次写完，SSE 交给路由往会话里推事件）。

## 决策

**会话级读数在网关侧统计，不在引擎侧。** 引擎层没有 per-session 指标：splash 只报累计的 `decode_output_tokens / decode_wall_ms`，oMLX 只给聚合吞吐和一个在跑计数，MTPLX 更极端——串行到连「有几路在排队」都不报（排队被算进了在跑）。唯一知道每个请求何时进来、首个 token 何时到达、一共吐了多少字的地方就是网关本身，所以概览页的「会话」网格取数于此。

因此 `GatewayMeter` 的线程模型也是被这个职责决定的：转发跑在非主 actor 上，打点密度是每 250 ms 一格，所以它是用 `NSLock` 保护的普通类，而不是 `@MainActor` 的 `ObservableObject`；读侧只做一次快照，不做增量订阅。
