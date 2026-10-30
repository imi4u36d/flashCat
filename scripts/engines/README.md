# Engine runtime packs

自包含的本地推理引擎运行时。每个 pack 是 `vendor/engines/<engine-id>/<version>/`，
含 `manifest.json`、`python/bin/python3`（python-build-standalone）和引擎自己的
site-packages；App 读 `manifest.json` 决定怎么启动。字段含义见
[manifest-template.md](manifest-template.md)，实测记录见 `vendor/engines/BUILD-REPORT.md`。

## 构建（不下载模型权重）

```bash
scripts/engines/build-mtplx-pack.sh     # -> vendor/engines/mtplx/2.12.2  (~434 MB)
scripts/engines/build-omlx-pack.sh      # -> vendor/engines/omlx/0.7.2   (~1.7 GB)
# 选项：--version VER | --out DIR | --force（覆盖已有 pack）
```

- 两个脚本都用 `uv` 取 python-build-standalone：mtplx 要 **3.13 / cp313**，
  omlx 要 **3.11 / cp311**（由包内二进制轮子的 ABI 决定）。`uv` 不要求本机预装：
  首次运行自动下载独立二进制缓存到 `.tools/uv`（已 gitignore），整条链路只依赖
  macOS 自带工具（curl/tar/shasum）和网络，**不依赖 Homebrew**。
- MTPLX 来自 PyPI（`mtplx==2.12.2`，mlx/mlx-metal/mlx-lm/nanobind 钉死版本 ——
  mlx 版本决定原生扩展缓存指纹）。构建期就编译 `_paged_ops` 放进 `cache/` 并在
  manifest 的 `warmup` 里声明，目标机无需编译器。
- oMLX **不在 PyPI**，但上游 GitHub Releases 每个版本都发 cp311 wheel
  （`omlx-<ver>-cp311-cp311-macosx_15_0_universal2.whl`）。脚本直接下载该 wheel、
  对照 GitHub release API 的 assets digest 校验 sha256（也可 `--sha256` 手动指定），
  再装进 pack 自带的 CPython 3.11。不再从 Homebrew keg 复制 site-packages，
  也不需要 `brew upgrade`。App 内更新同理：构建脚本自己拉取上游产物。
- wheel 的平台 tag 是 `macosx_15_0`，pack 的 `minMacOS` 相应为 **15.0**。
- pack **不可移动**：`_paged_ops` 的 rpath 是绝对路径，安装位置必须含版本号。

## 校验（用产物里的 python 起服务，验完杀进程释放端口）

```bash
P=vendor/engines/mtplx/2.12.2; (cd $P && $P/python/bin/python3 -m mtplx.cli serve \
  --model ~/.mtplx/models/Youssofal--Qwen3.5-4B-MTPLX-Optimized-Speed \
  --host 127.0.0.1 --port 8399 --no-auth --model-search-dir ~/.mtplx/models &)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8399/health   # 200
lsof -nP -iTCP:8399 -sTCP:LISTEN -t | xargs kill   # mtplx 的 argv 是 python3.13，pkill -f 杀不到

P=vendor/engines/omlx/0.7.2; (cd $P && $P/python/bin/python3 -m omlx.cli serve \
  --host 127.0.0.1 --port 8398 --model-dir ~/.omlx/models &)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8398/health   # 200
lsof -nP -iTCP:8398 -sTCP:LISTEN -t | xargs kill
```

## 更新

改 `DEFAULT_VERSION`（或传 `--version`）→ `--force` 重建 → 跑上面校验 → 释放端口。
`vendor/engines/` 是 GB 级构建产物，不要提交进 git（需要入库先确认）。
