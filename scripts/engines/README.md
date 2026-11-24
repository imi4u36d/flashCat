# Engine runtime packs

自包含的本地推理引擎运行时。每个 pack 是 `vendor/engines/<engine-id>/<version>/`，
含 `manifest.json` 和可执行入口。入口可以是自带 CPython（`python/bin/python3`），
也可以是原生二进制；App 读 `manifest.json` 和 adapter 描述决定怎么启动。字段含义见
[manifest-template.md](manifest-template.md)，实测记录见 `vendor/engines/BUILD-REPORT.md`。

## 构建（不下载模型权重）

```bash
scripts/engines/build-mtplx-pack.sh     # -> vendor/engines/mtplx/2.12.2  (~434 MB)
scripts/engines/build-omlx-pack.sh      # -> vendor/engines/omlx/0.7.2   (~1.7 GB)
scripts/engines/build-splash-pack.sh    # -> vendor/engines/splash/1.4.0
scripts/engines/build-mlx-serve-pack.sh # -> vendor/engines/mlx-serve/26.11.1 (~265 MB)
# 选项：--version VER | --out DIR | --force（覆盖已有 pack）
```

四个脚本共用 [lib-pack.sh](lib-pack.sh)：参数解析（`pack_parse_common_args`）、步骤日志与
计时（`pack_step` / `pack_elapsed`）、依赖检查（`pack_require_tools`）、解包（`pack_extract`）、
清单校验（`pack_validate_manifest`）、rpath 修正（`pack_fix_rpaths`）、收尾摘要
（`pack_print_summary` / `pack_next_release_cmd`）都在那里，引擎专属的部分只留常量、
usage 文案、下载校验策略、manifest heredoc 和各自的启动自检。改公共逻辑请改 lib，
不要复制回单个脚本。

**解包永远先 staging 再原子替换**（`pack_stage_then_swap`）：目标目录写在
`$PACK_DIR.new.$$`，全部校验通过才 `mv` 换上去；解包或校验失败只删 staging，**已装好的
旧 pack 逐字节保留**。所以 `--force` 的含义是「允许覆盖已存在的 pack」，不是「先删再装」。
构建中途 Ctrl-C 不会留下半个 pack。

```bash
scripts/engines/lib-pack-selftest.sh    # lib 自身的行为回归（29 个用例，全 stub，不下载任何东西）
```

`lib-pack-selftest.sh` 覆盖：无 `--force` 时拒绝覆盖、解包失败保留旧 pack 且不留
`.new.*` / `.old.*` 残留、`--dry-run` 零写入、参数缺值报错。改 `lib-pack.sh` 后先跑它。

`fix-pack-rpaths.sh <pack 目录>` 是后处理：把 pack 里 Mach-O 的 install name / rpath 指回
包内绝对路径（按 Mach-O magic 判定，不靠文件名后缀），重复运行幂等。自带 Python 的引擎
在取出 CPython 后需要它，否则换机就 `dyld: Library not loaded`。

`fetch-runtime.sh` 只负责把 python-build-standalone 取到 `vendor/` 并打印版本比较结果，
被 Python 引擎的构建脚本调用；它不建 pack。

- Python 引擎脚本用 `uv` 取 python-build-standalone：mtplx 要 **3.13 / cp313**，
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
- MLX-Serve 只使用上游签名 CLI tarball，不接 DMG；运行时是原生二进制，无 Python。

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

改 `DEFAULT_VERSION`（或传 `--version`）→ 重建（新版本默认写到新的 `<version>/` 目录，
旧目录不动，可回滚）→ 跑上面校验 → 释放端口。要覆盖同版本产物时加 `--force`，
失败不会毁掉已装的那份（见上文 staging + 原子替换）。
`vendor/engines/` 是 GB 级构建产物，不要提交进 git（需要入库先确认）。
