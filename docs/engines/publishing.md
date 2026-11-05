# 引擎运行时包的构建与分发

flashCat 自己管理推理引擎的运行时（Python + 引擎依赖），不依赖 Homebrew、不依赖
`/Applications/oMLX.app`、也不读写 `~/.omlx` / `~/.mtplx` 的配置。一个引擎运行时装
就叫一个 **runtime pack**：一个目录，里面有 `manifest.json` 和一个自带解释器。

三个引擎（splash / oMLX / MTPLX）地位完全相同：**没有任何引擎随应用打包**。App 首次
启动显示启动页，由用户选一个引擎从分发索引下载安装；splash 只是其中一个 pack。

本文覆盖四件事：怎么在本机把 pack 构建出来、怎么把它打成可分发的归档、分发索引长
什么样、以及 App 端如何解析。**注意：这里自始至终不下载模型权重。** 模型只来自本机
已有目录，通过符号链接进入 flashCat 的模型目录。

## 1. 本机构建（开发时用）

```bash
# oMLX：包不在 PyPI，从 Homebrew keg 只读复制 site-packages
scripts/engines/build-omlx-pack.sh --version 0.7.2        # → vendor/engines/omlx/0.7.2
# MTPLX：来自 PyPI，mlx 版本必须钉死（决定原生扩展缓存指纹）
scripts/engines/build-mtplx-pack.sh --version 2.12.2      # → vendor/engines/mtplx/2.12.2
# splash：把 vendor/splash-<v>-arm64-macos26.tar.gz 解成 pack（含 flashcat_serve.py + manifest.json）
scripts/engines/build-splash-pack.sh --version 1.4.0      # → vendor/engines/splash/1.4.0
```

产物目录结构（`<root>` = `vendor/engines/<id>/<version>`）：

```
manifest.json
python/bin/python3          # python-build-standalone，自带解释器
python/lib/python3.X/site-packages/...
cache/                      # MTPLX: 预编译的 _paged_ops（目标机无需编译器）
```

构建细节见 `scripts/engines/README.md`。两条硬约束：

- **pack 不可移动**：MTPLX 的 `_paged_ops.dylib` rpath 是绝对路径，pack 必须留在
  构建时的位置，路径里必须含版本号。
- **Python 版本由轮子 ABI 决定**：MTPLX 是 cp313，oMLX 是 cp311。

## 2. 开发期加载

`native/scripts` 之外，App 按以下顺序找 pack：

1. `FLASHCAT_ENGINE_PACKS_DIR`
2. `~/Library/Application Support/flashCat/engines/<id>/<version>`
3. `Bundle.main.resourceURL/engines/<id>/<version>`（`scripts/build-native-app.sh`
   在 .app 里放了一个指向 `vendor/engines` 的符号链接）
4. 从 bundle 路径和当前目录各向上 6 层找 `vendor/engines`

所以本地开发时直接 `swift build && .build/debug/flashCat` 就能看到全部三个引擎，启动
页也会把它们列为「已有本地包」。App 本体不再解压任何 runtime，`Contents/Resources`
里只有 `pack-index.json`（可选）与引擎包的符号链接。

## 3. 打成可分发的归档

```bash
scripts/engines/make-pack-release.sh --engine omlx --version 0.7.2 \
  --base-url https://downloads.example.com/flashcat/packs
```

产出（默认在 `dist/packs/`）：

```
omlx-0.7.2-arm64-macos26.0.tar.gz
omlx-0.7.2.sha256
omlx-0.7.2.release.json        # 一个 EnginePackRelease 对象
```

归档只有一个顶层目录（`omlx-0.7.2/`）。安装器会检测这一点并自动加
`--strip-components 1`；散装的归档不会被误剥离。splash 的脚本同样支持
`--engine splash --version 1.4.0`。

## 3.1 生成索引

```bash
scripts/engines/make-pack-index.sh   --packs dist/packs --base-url https://downloads.example.com/flashcat/packs
```

它把每个 `<engine>-<version>.release.json` 收进 `engines.<engine>`（版本号新的在前），
`--base-url` 会把 `url` 重写成该前缀下的归档名，产出仓库根目录的 `pack-index.json`；
`scripts/build-native-app.sh` 会把它拷进 `Contents/Resources/pack-index.json`。

## 4. 分发索引

`pack-index.json`（App 里通过 `FLASHCAT_PACK_INDEX_URL` 或打进 bundle 的
`Resources/pack-index.json` 读取）：

```json
{
  "schemaVersion": 1,
  "engines": {
    "omlx": [
      {
        "version": "0.7.2",
        "url": "https://downloads.example.com/flashcat/packs/omlx-0.7.2-arm64-macos26.0.tar.gz",
        "sha256": "cf2d3dded0f4ff2dc6fc79d651e9b93ecad202bdc56da53545c03003942f87b1",
        "bytes": 589640462,
        "minMacOS": "26.0",
        "notes": "oMLX 0.7.2 + mlx 0.32.4"
      }
    ],
    "mtplx": []
  }
}
```

- `engines` 的 key 就是 `EngineID.rawValue`，未知 key 会被忽略。
- 版本列表会按版本号排序（预发布后缀排在正式版之前），App 里只显示尚未安装的版本。
- 仓库根目录的 `pack-index.json` 由 `make-pack-index.sh` 生成，别手写。
- `bytes` 只用于显示大小；未知就省略。

## 5. 安装器做什么

`EngineInstaller`（`native/Sources/FlashCatKit/EngineInstaller.swift`）的状态机：

```
idle → resolving → downloading(.partial) → verifying(SHA256)
     → unpacking(.staging) → validating(manifest + entrypoint)
     → activating(xattr -dr com.apple.quarantine, move) → installed
```

- 失败时清理 `.downloads/*.partial` 与 `.staging/*`，**已安装的旧版本不动**。
- 解包前用 `/usr/bin/tar -tzf` 列目录，任何绝对路径或 `..` 分量直接拒绝。
- 永不拼 shell 字符串：`Process.arguments` 是 `[String]`。
- 卸载是「移到 `.trash/` 再删」，不是原地删。

## 6. 启动页与引擎页

- **启动页（`OnboardingView`）**：一个引擎都没装时自动出现，列出三个引擎与可下载版本，
  点「安装并开始使用」走上面的安装状态机，装完立刻 `AppState.adoptEngine`，控制器接管。
  索引不可用时会提示，并照常识别本机已有的 pack。
- **引擎页（`EnginesView`）**：`EngineID.allCases` 全量展示（含 splash），每张卡片有当前
  版本、端口、已安装/可安装版本、安装进度、卸载、打开目录、查看日志，以及「配置…」
  和「设为当前」。
- **引擎配置页（`EngineConfigView`）**：每个引擎一个详情页，端口/模型目录/日志是公共部
  分，下面是各引擎真正认识的开关——splash 的 DFlash2 draft 目录与内存/上下文、MTPLX 的
  `--mtp` / `--load-mtp` / `--mtp-quant-bits`、oMLX 的 MTP/DFlash2（互斥，按模型通过
  `PUT /api/models/<id>/settings` 生效）。配置存在 `EngineStore` 的 `EngineConfiguration.tuning`。

改端口只改偏好值：停着的引擎立刻用新端口，运行中的要重启才生效；端口被别的进程
占了会在 `defaultPort…+19` 范围内顺延，顺延结果写回 `engines.json`。
