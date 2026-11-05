# 安全策略

## 报告漏洞

请不要开公开 issue。用 GitHub 的 [Private vulnerability reporting](https://github.com/imi4u36d/flashCat/security/advisories/new)，或邮件联系维护者（见仓库 commits）。

请在报告里说明：受影响的版本、复现步骤、影响面（能否读到本机文件 / 能否执行命令 / 能否让应用崩溃）。

48 小时内会收到首次回复。修复发布前请勿公开细节。

## 安全模型

理解下面这几条能省掉很多误报：

1. **网关不鉴权，且只监听回环。** `127.0.0.1:9000` 绑定在 `requiredLocalEndpoint`（`GatewayHTTPServer.swift:137`），填任意 API Key 都能用。**这不是漏洞，是设计。** 任何能连上本机回环的进程本来就能起自己的推理服务。要对外提供服务请自行加反向代理。
2. **引擎运行时是第三方二进制。** pack 从 `pack-index.json` 声明的地址下载，带 sha256 校验。应用只按 `manifest.json` 启动它，不解释其余文件。
3. **WebUI 是随包的本地静态资源**，通过 `file://` 加载，不加载远程脚本，也不需要网络请求。

## 已知的攻击面（欢迎针对这几条报告）

- **Swift↔JS 桥是一条无鉴权的原生命令面**（`WebViewShell.swift` 的 `handle(type:body:)`）。任何能在 WebUI 里执行脚本的注入点都等价于拿到这些命令：写设置、起停引擎、下载模型、`openURL`。
  - 现有防线：`decidePolicyFor` 只允许加载包内 `index.html`，其余导航一律取消并把 http(s) 交给系统浏览器；`openURL` 与 `createWebViewWith` 都只放行 http/https；`index.html` 带 CSP（`connect-src 'none'`，因此被注入的脚本没有外发通道）。**绕过其中任何一条都是有效漏洞。**
- **模型广场展示 Hugging Face 的 README 与仓库元数据。** 全部经 `esc()` 转义后渲染；若发现未转义路径即为有效漏洞。
- **引擎日志会进日志页并落盘。** 日志内容来自引擎 stdout，属于不可信输入。
