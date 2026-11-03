---
id: flashcat-engine-packs
type: module-design
status: draft
title: 引擎运行时 pack 构建与发布
parent: flashcat-architecture
depends-on: [flashcat-manifest-contract]
---

# 引擎运行时 pack 构建与发布

## 职责

把形态各异的上游产物打成同一种自包含运行时 pack，并把它们汇总成应用消费的发布索引。应用本身只发脚本，不发引擎二进制。

pack 的统一形状是 `vendor/engines/<engine-id>/<version>/`。入口可以是自带的 CPython，也可以是原生二进制；应用只读入口路径、`manifest.json` 与 adapter 声明，不解释其余文件——那份契约见 [manifest 契约](manifest-template.md)。

## 多上游，多打法

差异是本质的，脚本没有强行统一：

| 引擎 | 来源 | 需要 | 关键点 |
| --- | --- | --- | --- |
| splash | 官方发行 tarball | CPython 随包自带 | 发行包已经带好 `python/`、`install/`、`server/`、`engine/`，解包即成 pack |
| mtplx | PyPI `mtplx==<v>` | CPython **3.13 / cp313** | 原生扩展 `_paged_ops` 在构建期编译进 `cache/`，并由清单的 `warmup` 声明，目标机无需编译器 |
| omlx | 上游 GitHub release 的 **cp311 wheel** | CPython **3.11 / cp311** | 不在 PyPI；wheel 平台 tag 是 `macosx_15_0`，故清单 `minMacOS` 为 15.0 |
| mlx-serve | 官方 `mlx-serve-bin-macos-arm64.tar.gz` | 无 Python | 只接签名 CLI server，不接 DMG；入口是原生二进制 |
| strata | 官方 Control + Metal engine component | Control 自带 **CPython 3.12** | Control 必须复制到可写 support 目录；模型和 engine 由 Strata 受管 |

- **`uv` 取 CPython。** 两个脚本都用 `uv` 拿 python-build-standalone，且 **不要求本机预装**：首次运行自动把独立二进制缓存到 `.tools/uv`（已 gitignore），整条链路只依赖 macOS 自带的 `curl` / `tar` / `shasum` 和网络，**不依赖 Homebrew**。
- **mlx 版本钉死决定缓存指纹。** mtplx 的 `mlx` / `mlx-metal` / `mlx-lm` / `nanobind` 必须钉住版本——mlx 版本会改变原生扩展的缓存指纹，浮动的依赖会让「构建期编译好、运行期免编译」这一招失效。
- **omlx 的 sha256 来自上游。** 脚本直接下载 release 资产，并对照 GitHub release API 给出的 assets digest 校验；也允许 `--sha256` 手工指定。不再从 Homebrew keg 复制 site-packages，也不需要 `brew upgrade`。
- **splash 需要一个自己的启动脚本。** `runtime/flashcat_serve.py` 随 splash pack 一起装：splash 的 `serve` 只接受 Hub 仓库 ID（它解析仓库，从不服务路径），而 flashCat 的模型在自己目录里，所以脚本用安装器文档化的 `install.local.prepare_local_model` 接口准备文件（全程不联网，不解析 ID、不下载），再 exec 运行时自己的 server。它同时拉一个 watchdog：exec 保住了主进程的 pid，应用退出或崩溃后靠它结束子进程，否则端口会一直被占着直到下次启动来回收。

## 发布链

`build-*-pack.sh` → `make-pack-release.sh`（出 `tar.gz` + `.release.json`）→ `make-pack-index.sh`（汇总成 `pack-index.json`）→ 应用首次启动时读取。

- **索引里的 `url` 相对索引自身解析。** `make-pack-index.sh` 不带 `--base-url` 时写的是相对文件名（`mtplx-2.12.2-arm64-macos26.0.tar.gz`），只有显式传了 `--base-url` 才换成发布域前缀。**任何情况下都不写本机绝对路径**：那样索引只在这台机器上能用，别人首次启动永远装不上引擎，而索引恰恰是要被分发出去的那一份。汇总脚本对上游 `.release.json` 里已有的绝对地址一律取 basename，所以一份脏的 release 文件也不会把路径带进发出的索引。
- **索引必须与归档同一个可达目录。** 相对地址意味着 `FLASHCAT_PACK_INDEX_URL` 指到哪一层，归档就得在那层的旁边；`--base-url` 是唯一例外（归档上 CDN、索引留在别处）。应用 bundle 里那份 `pack-index.json` 因此只是发布目录的同构副本，靠它装引擎的前提是归档就在旁边。本机自测就把索引直接写进归档目录、再用环境变量指过去：`make-pack-index.sh --packs dist/packs --out dist/packs/pack-index.json`，`FLASHCAT_PACK_INDEX_URL=file://$PWD/dist/packs/pack-index.json`。
- **pack 不可移动。** 原生扩展会把绝对 rpath 烧进去，安装路径必须含版本号且装完不许挪。`fix-pack-rpaths.sh` 负责把指向 pack 内部的 rpath 改写成 `@loader_path/...` 等价形式并重新签名。
- **清单版本、目录名、引擎自己的 `--version` 三者必须一致**，构建脚本会挡。
- 校验方式是用产物里的 python 起服务、打一次 `/health`，然后用 `lsof` 按端口杀进程释放（mtplx 的 argv 是 `python3.13`，`pkill -f` 杀不到）。

## 边界

- **只通过 [manifest 契约](manifest-template.md) 与应用对话。** 契约改字段才改 `schemaVersion`；加字段是向后兼容的。
- **不下载模型权重。** pack 只含运行时，模型归应用侧的模型页。
- **`vendor/engines/` 不入库。** 它是 GB 级构建产物。
- **应用里的构建入口必须调用同一批脚本。** `EnginePackBuilder` 生成的就是这些脚本的命令行——两侧各有一套命令是不可接受的重复。

## 已知限制

- 构建脚本本身不做完整自动化测试；清单解码与版本比对在 `FlashCatKitTests` 里有覆盖。真实发布前仍需运行对应脚本，并用 `PackInstallIntegrationTests` 指向产物做安装/入口验证。
