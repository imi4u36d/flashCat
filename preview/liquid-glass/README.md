# flashCat Liquid Glass Preview

macOS 26 Liquid Glass 方向的交互预览。概览页作为组件化设计的基准页：

- `EngineWidget`：当前模型、运行状态、启停与实时吞吐
- `GatewayWidget`：OpenAI / Claude 双协议地址
- `MetricWidget`：上下文、TTFT、预填充与内存
- `TokenFlowWidget`：最近 60 秒的总解码流
- `RequestWidget`：最近请求

## 本地运行

在仓库根目录执行：

```bash
python3 -m http.server 4173 --bind 127.0.0.1
```

打开：

```text
http://127.0.0.1:4173/preview/liquid-glass/index.html
```

## 快捷键

- `⌘ \`：折叠 / 展开侧栏
- `⌘ 1…6`：切换工作区
- `⌘ ⇧ A`：切换外观

侧栏右缘支持左右拖动调节宽度；双击分隔线恢复默认宽度。

页面无构建依赖，直接使用 HTML、CSS 和原生 JavaScript。
