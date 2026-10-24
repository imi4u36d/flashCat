# flashCat

基于 [incoai/splash](https://github.com/incoai/splash) 的本地 AI 推理桌面应用。

客户端已从 SwiftUI/AppKit 迁移为 **Flutter + Material 3**，是一个带 Dock 图标、
标准窗口和系统菜单的独立应用，不是菜单栏工具。macOS 版本把 splash 的 Metal
引擎、Python 服务和独立 Python 运行时一起打进 `.app`，双击即可使用。

## 当前状态

- Flutter 客户端：macOS / Windows / Linux 工程骨架已生成
- macOS 打包：Flutter release + splash 运行时 + 自定义图标 + ad-hoc 签名
- 全局 UI：Material 3、响应式侧栏、系统浅色/深色主题、键盘快捷键
- 功能页面：概览、对话、模型、日志、设置
- 推理后端：Apple Silicon macOS 使用内置 splash；其他平台保留同一套 Flutter
  界面，需接入对应平台运行时

## 界面

| 页面 | 内容 |
| --- | --- |
| 概览 | 服务启停、模型状态、解码速度、草稿接受率、内存、上下文、吞吐曲线、运行指标 |
| 对话 | 流式输出、Markdown、停止/重试/复制、参数面板、本地对话持久化 |
| 模型 | 本机模型、Splash 已安装和推荐模型、自定义模型 ID、目录导入与删除 |
| 日志 | 搜索、级别过滤、自动滚动、复制、清空、打开日志文件 |
| 设置 | 端口、资源和上下文上限、思考模式、模型、运行时更新、附加参数 |

窗口快捷键：`⌘1` 到 `⌘5` 切换页面，`⌘O` 打开对话，`⌘,` 打开设置。
对话输入框使用 `⌘↩` 发送，`⇧↩` 换行。

## 系统要求

- Apple Silicon（M3 或更新）
- macOS 26.4 或更新（splash 引擎在启动时拒绝更旧的系统）
- Xcode 27 或可用的 Flutter macOS 工具链
- Flutter stable 3.47.7

4-bit 27B 模型建议 36 GB 以上统一内存，48 GB 更稳。

## 构建与安装 macOS

```bash
make app
```

产物：

```text
/Applications/flashCat.app             ← 已自动安装，Dock 里直接可用
dist/flashCat-<version>.pkg            ← 双击自动安装到 /Applications
dist/flashCat-<version>.dmg            ← 拖到 Applications 的分发镜像
dist/.build/flashCat.app              ← 临时构建副本（不要双击运行）
```

构建脚本会：

1. 执行 `flutter build macos --release`
2. 解包 `vendor/splash-<SPLASH_VERSION>-arm64-macos26.tar.gz`（当前 1.4.0），
   并校验其 `.sha256` 与 `release.json` 里的版本号
3. 把运行时写入 `flashCat.app/Contents/Resources/runtime`
4. 写入 `flashcat_serve.py`
5. 生成并替换 macOS `AppIcon.icns`
6. 校验版本、信息和签名
7. 生成 `.pkg` / `.dmg`
8. 退出正在运行的旧 flashCat，把新 bundle 安装到 `/Applications`
   （旧版本备份为 `/Applications/.flashCat-previous-<时间戳>.app`）

只构建不安装：

```bash
INSTALL=0 make app
```

可覆盖版本和输出目录：

```bash
VERSION=1.0.1 BUILD_NUMBER=2 make app
OUT_DIR=/tmp/flashcat-dist make app
```

常用命令：

```bash
make analyze    # flutter analyze
make test       # flutter test
make install    # 把已构建的 bundle 安装到 /Applications
make verify     # 安装、启动并确认进程存活
make run        # 打开 /Applications/flashCat.app
make pkg        # 只生成 .pkg / .dmg
make uninstall  # 删除 /Applications/flashCat.app 及其残留服务
make windows    # Windows release 工程构建
make linux      # Linux release 工程构建
```

安装后系统里只有一份应用：`/Applications/flashCat.app`。构建出来的
`dist/flashCat.app` 会被移到 `dist/.build/`，只是中间产物。两份副本同时
运行会互相抢占 8000 端口，这是之前"端口一直被占用"的直接原因。

现在端口冲突不再报错，启动时按三种情况处理：

- 端口上的服务已经是**同一个模型** → 直接接入，不重复启动；
- 端口上的进程是**本应用上次遗留的**（pid 记录在
  `~/Library/Application Support/flashCat/server.pid`） → 结束它，等端口真正释放，再启动；
- 端口被**其它程序**占用 → 自动试 8001…8010，成功的端口写回设置。

推理进程还带一个看门狗：应用窗口关闭（或应用被杀掉）时，它会在几秒内
结束推理进程，不再留下占着端口的孤儿进程。

## 开发

开发时可以让 Flutter 使用未放入 App bundle 的运行时：

```bash
export FLASHCAT_RUNTIME="$PWD/dist/.build/flashCat.app/Contents/Resources/runtime"
flutter run -d macos
```

运行时查找顺序：

1. `FLASHCAT_RUNTIME`
2. `~/Library/Application Support/flashCat/runtimes/<active-version>`
3. `flashCat.app/Contents/Resources/runtime`
4. 项目下的 `.runtime`

引擎归档直接取 splash 官方发布（自动带上 `.sha256` 并校验）：

```bash
make fetch-runtime                 # 当前 SPLASH_VERSION（默认 1.4.0）
make fetch-runtime SPLASH_VERSION=1.4.0
```

也可以从 splash 源码自己打包：

```bash
make runtime SPLASH_SRC=/path/to/splash SPLASH_VERSION=1.4.0
```

`VERSION` 是 flashCat 的 App 版本（`CFBundleShortVersionString`、`.pkg`/`.dmg` 命名），
`SPLASH_VERSION` 是内置 splash 引擎的版本，两者独立。`make runtime-check` 会打印
归档里 `release.json` 的版本，构建脚本也会拒绝名字与 `release.json` 不一致的归档。

## 数据与日志

| 路径 | 内容 |
| --- | --- |
| `~/.flashcat/models` | flashCat 本地权重目录 |
| `~/Library/Application Support/Splash` | 与 splash 共用的已安装模型目录 |
| `~/Library/Application Support/flashCat/runtimes` | 应用内更新的运行时 |
| `~/Library/Application Support/flashCat/conversation.json` | 对话界面记录 |
| `~/Library/Logs/flashCat/server.log` | 推理服务日志 |
| `~/.cache/huggingface/hub` | 默认模型下载缓存 |

## 项目结构

```text
lib/
  core/       设置、服务进程、运行时、模型目录、API 与对话客户端
  features/   概览、对话、模型、日志、设置和响应式应用壳
  widgets/    Material 公共组件与 macOS 原生菜单
macos/        Flutter macOS Runner
windows/      Flutter Windows Runner
linux/        Flutter Linux Runner
runtime/      flashCat 本地模型服务入口
vendor/       splash macOS 运行时归档
```

## API

服务启动后提供 OpenAI 兼容接口：

```bash
curl http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"mlx-community/Qwen3.8-27B-4bit",
       "messages":[{"role":"user","content":"你好"}]}'
```

状态与就绪检查：

```bash
curl http://127.0.0.1:8000/ready
curl http://127.0.0.1:8000/status
```
