# flashCat 多引擎接入：实现现状

本文记录多引擎门户第一轮落地之后，代码里**实际**的形态、验证过的边界，
以及还没做的部分。这一轮把「能切换引擎并真正跑起来」
连同自管安装器（runtime pack 下载 / SHA256 / 解包 / 激活）一起打通了。

## 第二轮变更：splash 不再是特例（当前形态）

这一轮把 splash 从「应用内置运行时」改成和 oMLX / MTPLX 完全同级的第三方 runtime pack：

- **应用不再携带任何推理运行时**。`scripts/build-native-app.sh` 不再解压 splash 归档，
  `Contents/Resources` 里只有可选的 `pack-index.json` 和指向 `vendor/engines` 的符号链接。
- **splash pack** 由 `scripts/engines/build-splash-pack.sh` 从
  `vendor/splash-<ver>-arm64-macos26.tar.gz` 生成到 `vendor/engines/splash/<ver>`，含
  `manifest.json`、`flashcat_serve.py`、自带 `python/bin/python3` 与 `install/launcher.py`；
  它和别的 pack 一样由 `make-pack-release.sh` / `make-pack-index.sh` 发布。
- **启动页（`OnboardingView`）**：一个引擎都没装时占据整个窗口，列出三个引擎与索引里的
  版本，安装完成即 `AppState.adoptEngine`，之后从「引擎」页的「启动页…」可再次进入。
- **每个引擎一个配置页（`EngineConfigView`）**：端口/模型目录/日志是公共部分，其余是各引
  擎真正认识的开关——splash 的 DFlash2（draft 目录、内存、上下文、仅语言、空闲保留）、
  MTPLX 的 `--mtp` / `--load-mtp` / `--mtp-quant-bits`、oMLX 的 MTP/DFlash2（互斥，通过
  `PUT /api/models/<id>/settings` 按模型生效）。配置落在
  `EngineConfiguration.tuning`（`EngineTuning`，在 `FlashCatKit` 里带单测）。
- **引擎层去特例**：`EngineController` 只有一个 `installation`，启动参数全部来自 manifest；
  manifest 新增 `modelArgument`（`name` / `path` / `id`）说明 `{model}` 怎么填，profile 按
  `local` → `default` 的候选顺序解析（splash 用 `hub` / `local` 两个 profile）。
  `EngineModelLinker` 与 `LocalEngineModels` 里的 splash 早退改成「源目录 == 目标目录」的
  通用判断；应用内 runtime 更新器（`RuntimeUpdater` / `LocalAPI`）已删除。

## 结论速览

| 引擎 | 运行时包 | 启动 | 状态面板 | 切模型 | 本机验证（走 App UI） |
| --- | --- | --- | --- | --- | --- |
| Splash | `vendor/engines/splash/1.4.0`（259 MB，由 `build-splash-pack.sh` 生成） | manifest 模板（`hub` / `local`） | `/status` | 重启 | 切回后 `/ready` 200，回归通过 |
| oMLX 0.7.2 | `vendor/engines/omlx/0.7.2`（434 MB） | manifest 模板 | `/api/status` | **热切换**（`POST /v1/models/{id}/load`） | 启动 → 27B 热加载 → 对话 65.9 tok/s / 首字 285 ms |
| MTPLX 2.12.2 | `vendor/engines/mtplx/2.12.2`（1.7 GB） | manifest 模板 | `/v1/mtplx/snapshot` | 重启（singleModel） | 启动 → 对话 90.0 tok/s / 首字 77 ms / 预填充 228 tok/s |

切引擎实测：MTPLX 运行中点「切换到 oMLX」→ MTPLX 进程退出、8200 释放，oMLX 在 8100
起来并自动热加载 `Jundot--Qwen3.8-27B-oQ4e-mtp`（`/api/status` 的 `models_loaded: 1`）；
再点「切换到 Splash」→ 8100 释放、8000 `/ready` 200。

MTPLX 的 `_paged_ops` Gate 通过：build 阶段就把 `_paged_ops-<sha256(libmlx)[:16]>.cpython-313-darwin.so`
编进 `vendor/engines/mtplx/<ver>/cache/`，目标机不需要编译器（只需 Command Line Tools，
连完整 Xcode 都不需要）。mlx 必须钉死 0.32.2 —— 指纹来自 `libmlx.dylib`，换版本缓存失效。

## 模型从哪来（关键约束）

早期约束是「只认 `~/.omlx`、`~/.mtplx` 里已有的权重，应用不下载」。本轮起改为：
**模型库按引擎自治，可以下载**，但每个引擎只往自己的目录里写，下载器统一走
各引擎 pack 自带的 `python/bin/python3` + `huggingface_hub`。

1. `~/Library/Application Support/flashCat/models/` 是 flashCat 自己的模型根目录，
   splash 直接用它（`owner/repo`），pack 引擎各有一个子目录
   （`models/omlx/`、`models/mtplx/`，`owner--repo` 扁平命名）；
2. `EngineModelLinker.synchronize(_:)`（`native/Sources/FlashCat/EngineStore.swift`）
   在 pack 引擎的目录里建**符号链接**，指向用户已有的权重：oMLX → `~/.omlx/models/*/*` +
   `~/.omlx/gguf/*`，MTPLX → `~/.mtplx/models/*`，名字 = 相对路径把 `/` 换成 `--`；
3. 引擎的 `--model-dir` / `--model-search-dir` 指向 flashCat 目录；
4. 下载（`ModelInstaller.swift`）：splash 走 pack 自带的 `install/models.py prepare`
   （`--models` / `--model` / `--draft-model`，会自己打印百分比）；oMLX / MTPLX 走
   `Paths.supportDirectory/scripts/hf_snapshot.py`，用 pack 自带 python 的
   `huggingface_hub.snapshot_download(local_dir:)`，先 `HfApi().model_info` 求和打印
   `TOTAL <bytes>`，AppState 再按目录体积算进度。

`EngineModelLinker.isWeightsDirectory(_:engine:)` 要求 `config.json` **且**有 tokenizer
文件（`tokenizer.json`/`chat_template.jinja`/`merges.txt`/…），或者目录里有自己的
`.gguf`（GGUF 自带词表，本轮新增）。前一条规则是必要的：oMLX 的
`incoai/Qwen3.8-27B-DFlash2` 只有 `config.json` + `model.safetensors`，是草稿头，单独加载
会 409；MTPLX 的模型也只有 1/4 带 `mtplx_runtime.json`，不能拿它当判据。

### 公共目录（自己下载的模型）

固定三档之外还允许用户填任意 Hugging Face 仓库 id（模型页右上角「＋ 下载模型」）。
权重只存一份在 `~/Library/Application Support/flashCat/shared-models/<owner>--<repo>`
（`EnginePaths.sharedModelsDirectory`），哪些引擎能看见它由
`~/Library/Application Support/flashCat/model-shares.json` 这张授权表决定
（`repo → [splash, omlx, mtplx]`），实现在 `native/Sources/FlashCat/ModelSharing.swift`：

- **不复制、不 clonefile**：`ModelSharing.synchronize()` 给授权过的 pack 引擎在它自己的
  模型目录里建一条软链接指向公共目录；Splash 不需要链接，`--target` 直接指向共享目录
  里的绝对路径（`runtime/flashcat_serve.py` 的 `--target` 接受「目录」），草稿与 mmproj
  由它自己的 assembly 挂上；
- 目录必须在 `EnginePaths.modelsRoot` **之外**：根下任意两层目录都会被
  `ModelCatalog.scanLocalModels` 当成 `owner/repo`，放根里会多出 owner = `shared-models`
  的脏数据；
- 授权变更 = 写表 + `synchronize()`，删模型 = 先 `ModelSharing.forget` 收回授权（各引擎
  的链接随之消失）再删文件；
- 扫描侧把公共目录当**一等来源**（`ModelCatalogService.load` 里拼进 `catalog.local`，
  `AppState.engineModels(for:)` 按授权过滤），而不是靠软链接被发现 ——
  `LocalEngineModels.isRealDirectory` 明确跳过符号链接；
- 注意 `EngineModelStore.adoptExistingWeights(_:)` 会把引擎目录下的软链接「解引用搬进来」，
  它现在跳过指向公共目录的链接，否则共享会变成某个引擎独占、磁盘翻倍；
- 不做格式 / 家族预检：能不能被某个引擎加载由引擎自己判断，卡片只标「引擎推荐」/
  「个人下载」的来源。

## 代码结构

`native/Sources/FlashCatKit/`（不依赖 AppKit，可测）
- `EngineCore.swift`：`EngineID`（端口 8000/8100/8200，各顺延 20）、`EngineCapability`、
  `EngineManifest`/`EngineLaunchProfile`/`EngineHealthSpec`/`EngineModelsSpec`、
  `EngineInstallation.load(root:)`、`EngineTemplate.expand(_:context:)`、
  `EngineVersionOrder`、`EnginePortAllocator`。
- `EngineStatus.swift`：`EngineStatus`/`EngineModel`/`EngineEndpoint`/`JSONValue`。
- `StatusParsers.swift`：三个引擎的状态文档 → 统一 `EngineStatus`。

`native/Sources/FlashCat/`
- `EngineController.swift`（取代已删除的 `ServerController.swift`）：每引擎一个，负责
  端口占用、进程拉起、健康探测、状态轮询、停止/重启、**热切模型**。
  非 splash 的命令行 100% 来自 pack 的 `manifest.json` 模板，加引擎不用改 supervisor。
- `EngineManager.swift`：持有全部 controller，`activate(_:)` 保证同一时刻只跑一个引擎
  （两个 MLX 引擎会抢同一块统一内存），并把选择记进 `engines.json`。
- `EngineStore.swift`：`engines.json` 读写、pack 搜索路径、符号链接、`EnginePaths`。
- `LocalEngineModels.swift`：离线扫 flashCat 模型目录，读 `max_position_embeddings`
  和 `model_type`，不启动引擎也能列模型。
- `EngineSwitcher.swift`：侧栏引擎 chip 条（切引擎）。
- `ModelsView.swift` + `ModelLibrary.swift`：模型页 = **按引擎自治的模型库**。顶部 chip
  条切「看哪个引擎的库」（`AppState.libraryEngine`，与正在运行的引擎解耦，未安装的引擎
  也能浏览）；已安装权重与推荐模型进同一个网格（`ModelLibrary.entries`，`owner--repo`
  与 `owner/repo` 归一后去重）；某个引擎一个模型都没有时，页面顶部换成
  `LibraryStartCard` 推荐卡（该引擎最适配的 Qwen 三档，一键下载）。
- `ModelRecommendations.swift`：每个引擎的推荐清单（splash → mlx-community 4-bit /
  Jundot Flash-Next oQ4e；oMLX → Jundot 全系 oQ+mtp；MTPLX → Youssofal 的
  `-MTPLX-Optimized-Speed` 包），带体积/内存下限/简介/DFlash2 草稿映射。
- `ModelInstaller.swift`：下载计划（可执行文件、参数、目标目录、监听目录、环境变量）。
- `EnginesView.swift`：引擎页（`EngineInstallCenter` + 安装/删除/端口编辑/打开目录/查看日志）。
- `AppState.swift`：`controller` 变成 `engines?.active`，21 个 `@Published` 与 7 个视图
  保持不动；`applyModel` 对非 splash 引擎走 `switchModel`（热/重启自动分流）。

## 安装器与引擎页

`native/Sources/FlashCatKit/EngineInstaller.swift` 是 `public actor EngineInstaller`：

- 阶段机 `EngineInstallPhase`：`idle → resolving → downloading → verifying → unpacking →
  validating → activating → installed`，失败进 `failed(message:)`，`.partial` / `.staging` /
  `.trash` 全部清理，旧版本不受影响；
- `EnginePackIndex` 来自 `FLASHCAT_PACK_INDEX_URL` 或 bundle 里的 `pack-index.json`，
  没有索引时引擎页只显示已装版本（离线优先）；
- 归档校验：SHA256 → `/usr/bin/tar -tzf` 逐条路径穿越检查 → 解包 → `manifest.json` 校验 →
  `xattr -dr com.apple.quarantine` → 原子激活。

引擎页（`⌘4`）对每个非 splash 引擎显示：状态点、当前引擎标记、端口（可直接改，运行中禁用）、
安装进度、已装版本（可删）、可安装版本（可装）、打开目录、查看日志。

## Pack 可重定位性（踩过的坑）

`cache/_paged_ops-*.so` 由 nanobind + mlx 编译产生，`LC_RPATH` 会写成**构建机的绝对路径**，
装到 `~/Library/Application Support/...` 后就加载不到 `libmlx.dylib`。
`scripts/engines/fix-pack-rpaths.sh` 把 pack 内的绝对 rpath 改写成 `@loader_path/...` 并
重签（`codesign --force --sign -`），两个 build 脚本都会调用它。实测把 pack `cp -a` 到
`/tmp` 下另起也能 `/health` 200。

## Pack 搜索顺序

`EngineInstallations.searchRoots()`：
`FLASHCAT_ENGINE_PACKS_DIR` → `<support>/engines` → `Bundle/main Resources/engines` →
从 bundle 路径与 cwd 各上溯 6 层找 `vendor/engines`。

`scripts/build-native-app.sh` 会把 `Contents/Resources/engines` 做成指向
`vendor/engines` 的符号链接（pack 是 GB 级构建产物，不复制、不入库）。

## 复现验证

```bash
# 单元测试（29 个：解析 8 + 引擎核心 10 + 安装器 9 + pack 安装集成 2 个默认跳过）
cd native && swift test

# 真实归档安装集成测试（会跑 21s 左右，装到临时目录）
FLASHCAT_TEST_PACK=dist/packs/omlx-0.7.2-arm64-macos14.tar.gz \
FLASHCAT_TEST_PACK_SHA=$(cut -d' ' -f1 dist/packs/omlx-0.7.2-arm64-macos14.tar.gz.sha256) \
  swift test --filter PackInstallIntegrationTests

# 手工验 oMLX pack（不经过 App）
cd vendor/engines/omlx/0.7.2
env -i PATH=/usr/bin:/bin HOME="$HOME" PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 \
  PYTHONUNBUFFERED=1 ./python/bin/python3 -m omlx.cli serve \
  --host 127.0.0.1 --port 8100 --model-dir /tmp/fcmodels/omlx
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8100/health        # 200
curl -sX POST http://127.0.0.1:8100/v1/models/Jundot--Qwen3.8-27B-oQ4e-mtp/load  # 200
lsof -nP -iTCP:8100 -sTCP:LISTEN -t | xargs kill

# 验引擎选择与链接（不污染真实 support 目录）
FLASHCAT_SUPPORT_DIR=/tmp/fcsupport FLASHCAT_ENGINE=omlx .build/debug/flashCat
```

`FLASHCAT_SUPPORT_DIR`、`FLASHCAT_ENGINE`、`FLASHCAT_ENGINE_PACKS_DIR`、
`FLASHCAT_LOGS_DIR` 都是为这个流程加的环境变量。

## 还没做（下一轮）

- oMLX 的 unload 与多模型常驻展示（`/v1/models/status` 的 `loaded_models` 已在解析，
  还没在 UI 上表达「常驻几个模型」）。
- pack 的升级/回滚 UI（安装器已有 `installedVersions` 与 `uninstall`，缺「切到旧版本」按钮）。
- 官方 pack 索引托管（现在只能靠 `FLASHCAT_PACK_INDEX_URL` 或手工放 `pack-index.json`）。
- MTPLX 的 `_paged_ops` 指纹校验：pack 里带了 `cache/`，但还没在启动前核对 mlx 版本。
- 引擎页的「安装」入口在离线环境只显示说明文案，没有「导入本地归档」按钮。
