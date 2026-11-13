# 安全策略

**简体中文** | [English](SECURITY.en.md)

## 报告漏洞

请不要开公开 issue。用 GitHub 的 [Private vulnerability reporting](https://github.com/imi4u36d/flashCat/security/advisories/new)，或邮件联系维护者（见仓库 commits）。

请在报告里说明：受影响的版本、复现步骤、影响面（能否读到本机文件 / 能否执行命令 / 能否让应用崩溃）。

48 小时内会收到首次回复。修复发布前请勿公开细节。

## 安全模型

理解下面这几条能省掉很多误报：

1. **网关不鉴权，且只监听回环。** `127.0.0.1:9000` 绑定在 `requiredLocalEndpoint`（`GatewayHTTPServer.swift:152`），填任意 API Key 都能用。**这不是漏洞，是设计。** 任何能连上本机回环的进程本来就能起自己的推理服务。要对外提供服务请自行加反向代理。
2. **引擎运行时是第三方二进制。** pack 从 `pack-index.json` 声明的地址下载，解包前做 sha256 校验（`EngineInstaller.swift:398`）。应用只按 `manifest.json` 启动它，不解释其余文件。
3. **没有网页层。** 界面是原生 SwiftUI——没有 `WKWebView`、没有内嵌 HTML/JS、没有脚本桥。远程内容（Hugging Face 模型卡）在 `ModelCardText.swift` 里剥掉全部 HTML 标签后才渲染成普通文本：不执行脚本，也不加载远程图片。
4. **控制接口带令牌。** 只监听回环，每次启动重新生成令牌（`ControlServer.swift:37`），`Authorization: Bearer` 与 `x-flashcat-token` 均可；`control.json` 权限 0600（`ControlServer.swift:36`）。

## 已知的攻击面（欢迎针对这几条报告）

- **控制接口是一条命令面。** 拿到令牌就能改设置、起停引擎、下载模型、读日志。令牌泄漏、权限配置错误、监听范围超出回环、绕过 401，都是有效漏洞。
- **模型卡等 Hugging Face 元数据是不可信输入。** 全部转义或剥离后才渲染；任何能执行远程标记、或在渲染时加载远程资源的路径都是有效漏洞。
- **下载的 pack 与模型是不可信数据。** sha256 只证明传输完整性，不证明打包者与模型作者的意图；引擎解析模型文件时的内存安全问题归上游，flashCat 的过滤、安装与启动逻辑归我们。
- **引擎日志是不可信输入。** 日志来自引擎 stdout，会进日志页并参与状态解析，绝不能被当作命令执行，或被拼进 shell。
