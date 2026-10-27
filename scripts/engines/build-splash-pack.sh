#!/usr/bin/env bash
#
# Build a self-contained Splash runtime pack from the shipped release tarball:
#   <out>/splash/<version>/{manifest.json,flashcat_serve.py,python/,install/,server/,engine/}
#
# 与 oMLX/MTPLX 不同，Splash 不需要在这里拼装 Python 环境：官方发行包
# `vendor/splash-<version>-arm64-macos26.tar.gz` 里已经带好了自包含的
# CPython（python/bin/python3）、安装器（install/）、服务端（server/）和
# Metal 引擎（engine/）。这个脚本只做三件事：校验、解包、补上 flashCat 自己的
# serve 包装脚本与 manifest.json，把它变成一个可安装的运行时包。
#
# 因此本脚本不会下载任何东西（模型权重、Python、依赖都不下载），也不会
# 修改 vendor/ 下的原始 tarball。
#
# Usage:
#   scripts/engines/build-splash-pack.sh [--version 1.4.0] [--out DIR] [--tarball FILE] [--force]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

ENGINE_ID="splash"
ENGINE_NAME="Splash"
DEFAULT_VERSION="1.4.0"
DEFAULT_OUT="$ROOT/vendor/engines"
DEFAULT_PORT=8000
DEFAULT_MIN_MACOS="26.0"
TARBALL_PLATFORM="arm64-macos26"
# flashCat 侧的 serve 包装脚本（准备本地模型文件后再 exec 运行时自己的服务器）。
SERVE_WRAPPER="$ROOT/runtime/flashcat_serve.py"

VERSION="$DEFAULT_VERSION"
OUT="$DEFAULT_OUT"
TARBALL=""
MIN_MACOS="$DEFAULT_MIN_MACOS"
FORCE=0

usage() {
  cat <<'EOF'
Build a self-contained Splash runtime pack from the shipped release tarball.

Usage: build-splash-pack.sh [options]

  --version VER   splash version to unpack (default: 1.4.0)
  --out DIR       output root; pack lands in DIR/splash/VER (default: vendor/engines)
  --tarball FILE  release tarball (default: vendor/splash-VER-arm64-macos26.tar.gz)
  --min-macos VER minimum macOS the pack declares (default: 26.0)
  --force         replace an existing pack directory
  -h, --help      show this help
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
elapsed() { printf '    (%.1fs)\n' "$(( $(date +%s) - $1 ))"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   VERSION="${2:?--version needs a value}"; shift 2 ;;
    --out)       OUT="${2:?--out needs a value}"; shift 2 ;;
    --tarball)   TARBALL="${2:?--tarball needs a value}"; shift 2 ;;
    --min-macos) MIN_MACOS="${2:?--min-macos needs a value}"; shift 2 ;;
    --force)     FORCE=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "$VERSION" ]] || die "--version must not be empty"
[[ -n "$MIN_MACOS" ]] || die "--min-macos must not be empty"
[[ -n "$TARBALL" ]] || TARBALL="$ROOT/vendor/splash-$VERSION-$TARBALL_PLATFORM.tar.gz"

# ------------------------------------------------------------------ 前置检查
step "Checking inputs"
[[ -f "$TARBALL" ]] || die "release tarball not found: $TARBALL
       download it into vendor/ or pass --tarball FILE"
[[ -f "$SERVE_WRAPPER" ]] || die "serve wrapper missing: $SERVE_WRAPPER"
printf '    tarball : %s (%s)\n' "$TARBALL" "$(du -sh "$TARBALL" | awk '{print $1}')"
printf '    wrapper : %s\n' "$SERVE_WRAPPER"

mkdir -p "$OUT"
OUT="$(cd -- "$OUT" && pwd -P)"
PACK_DIR="$OUT/$ENGINE_ID/$VERSION"

# --------------------------------------------------------- 1. sha256 校验
# 必须在 --force 删除旧包之前：校验失败说明 tarball 本身坏了，此时绝不能
# 先把一份好的旧包摸掉。
step "Verifying tarball checksum"
T=$(date +%s)
# 侧挂文件可能就放在 tarball 旁边，也可能在 vendor/ 下按发行名命名。
SIDECAR=""
for candidate in "$TARBALL.sha256" "$ROOT/vendor/splash-$VERSION-$TARBALL_PLATFORM.tar.gz.sha256"; do
  if [[ -f "$candidate" ]]; then SIDECAR="$candidate"; break; fi
done

if [[ -n "$SIDECAR" ]]; then
  # 有的侧挂文件只写了裸哈希（没有文件名），shasum -c 读不了这种格式，
  # 所以先归一化成 "<hash>  <basename>" 再交给 shasum 校验。
  EXPECTED="$(awk 'NF { print $1; exit }' "$SIDECAR")"
  [[ "$EXPECTED" =~ ^[0-9a-fA-F]{64}$ ]] || die "malformed checksum file: $SIDECAR (expected a sha256 hex digest)"
  CHECK_FILE="$(mktemp "${TMPDIR:-/tmp}/splash-sha.XXXXXX")"
  trap 'rm -f "$CHECK_FILE"' EXIT
  printf '%s  %s\n' "$EXPECTED" "$(basename "$TARBALL")" > "$CHECK_FILE"
  if ! ( cd -- "$(dirname -- "$TARBALL")" && shasum -a 256 -c "$CHECK_FILE" ); then
    rm -f "$CHECK_FILE"
    trap - EXIT
    die "sha256 mismatch for $TARBALL (see $SIDECAR) — refusing to unpack a corrupted tarball"
  fi
  rm -f "$CHECK_FILE"
  trap - EXIT
  printf '    ok: %s\n' "$EXPECTED"
else
  printf '    warning: no .sha256 sidecar next to %s, skipping checksum verification\n' "$(basename "$TARBALL")"
fi
elapsed "$T"

if [[ -e "$PACK_DIR" ]]; then
  [[ $FORCE -eq 1 ]] || die "$PACK_DIR already exists (pass --force to replace it)"
  step "Removing existing pack $PACK_DIR"
  rm -rf "$PACK_DIR"
fi

BUILD_START=$(date +%s)
printf 'Pack target: %s\n' "$PACK_DIR"

# ------------------------------------------------------------- 2. 解包
step "Extracting release tarball"
T=$(date +%s)
mkdir -p "$PACK_DIR"
tar -xzf "$TARBALL" --strip-components=1 -C "$PACK_DIR"
chmod -R u+w "$PACK_DIR"
printf '    %s extracted\n' "$(du -sh "$PACK_DIR" | awk '{print $1}')"
elapsed "$T"

step "Copying flashCat serve wrapper into the pack root"
cp -a "$SERVE_WRAPPER" "$PACK_DIR/flashcat_serve.py"
printf '    %s\n' "$PACK_DIR/flashcat_serve.py"

# ---------------------------------------------------------- 4. manifest.json
step "Writing manifest.json"
cat > "$PACK_DIR/manifest.json" <<EOF
{
  "schemaVersion": 1,
  "id": "$ENGINE_ID",
  "name": "$ENGINE_NAME",
  "version": "$VERSION",
  "kind": "download",
  "arch": "arm64",
  "minMacOS": "$MIN_MACOS",
  "entrypoint": "python/bin/python3",
  "workingDirectory": "{root}",
  "modelsSubdirectory": "models",
  "launchProfiles": {
    "hub": {
      "args": ["-u", "install/launcher.py", "serve", "--model", "{model}", "--port", "{port}"],
      "environment": {
        "PYTHONNOUSERSITE": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONUNBUFFERED": "1"
      }
    },
    "local": {
      "args": ["-u", "flashcat_serve.py", "--runtime", "{root}", "--models-dir", "{models}", "--model", "{model}", "--port", "{port}"],
      "environment": {
        "PYTHONNOUSERSITE": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONUNBUFFERED": "1"
      }
    }
  },
  "health": { "path": "/ready", "readyStatus": 200 },
  "status": ["/status"],
  "models": { "path": "/v1/models" },
  "defaultPort": $DEFAULT_PORT,
  "modelSwitch": "restart",
  "modelArgument": "id",
  "capabilities": ["chat", "streaming", "vision", "reasoning", "singleModel", "draft"],
  "license": "Proprietary"
}
EOF
"$PACK_DIR/python/bin/python3" -B - "$PACK_DIR/manifest.json" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
assert data["schemaVersion"] == 1 and data["id"] == "splash"
for profile in ("hub", "local"):
    assert profile in data["launchProfiles"], f"missing launch profile: {profile}"
    assert data["launchProfiles"][profile]["environment"], f"missing environment: {profile}"
print("    manifest.json parsed OK")
PYEOF

# --------------------------------------------------------------- 5. 自检
step "Layout self-check"
for required in manifest.json flashcat_serve.py python/bin/python3 install/launcher.py \
                release.json server engine LICENSE; do
  [[ -e "$PACK_DIR/$required" ]] || die "pack is incomplete: missing $required"
done
# 自检用的 python 调用会往包里写 __pycache__，所以一律带 -B 并关掉字节码写入。
export PYTHONDONTWRITEBYTECODE=1
PACK_PY="$PACK_DIR/python/bin/python3"

[[ -x "$PACK_PY" ]] || die "pack interpreter is not executable: python/bin/python3"
printf '    %s\n' "$("$PACK_PY" -B -VV 2>&1 | head -n 1)"

# 只做语法检查，不启动服务器：确认 wrapper 能被这个解释器解析。
"$PACK_PY" -B - "$PACK_DIR/flashcat_serve.py" <<'PYEOF'
import ast, sys
path = sys.argv[1]
with open(path, "rb") as fh:
    source = fh.read()
ast.parse(source, filename=path)
print("    flashcat_serve.py compiles (ast.parse OK)")
PYEOF

# ------------------------------------------------------------- 6. 收尾清理
# 放在最后：解包后的原始内容和上面所有自检都可能留下字节码，交付前扫干净。
step "Removing __pycache__ and .DS_Store from the pack"
CACHE_COUNT="$(find "$PACK_DIR" -type d -name '__pycache__' | wc -l | tr -d ' ')"
DS_COUNT="$(find "$PACK_DIR" -name '.DS_Store' | wc -l | tr -d ' ')"
find "$PACK_DIR" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$PACK_DIR" -name '.DS_Store' -delete
printf '    removed %s __pycache__ dirs, %s .DS_Store files\n' "$CACHE_COUNT" "$DS_COUNT"

# ------------------------------------------------------------------ 7. 汇总
step "Pack summary"
PACK_SIZE="$(du -sh "$PACK_DIR" | awk '{print $1}')"
FILE_COUNT="$(find "$PACK_DIR" -type f | wc -l | tr -d ' ')"
printf '    path      : %s\n' "$PACK_DIR"
printf '    size      : %s (%s files)\n' "$PACK_SIZE" "$FILE_COUNT"
printf '    splash    : %s\n' "$VERSION"
printf '    minMacOS  : %s\n' "$MIN_MACOS"
printf '    elapsed   : %ss total\n' "$(( $(date +%s) - BUILD_START ))"

printf '\nDone: %s\n' "$PACK_DIR"
cat <<EOF

Next steps:
  1) 打包分发（生成 tarball + .sha256 + release.json 索引条目）:
       scripts/engines/make-pack-release.sh --engine splash --version $VERSION \\
         --base-url https://<your-host>/packs
  2) 本地安装测试: 把 $OUT/$ENGINE_ID/$VERSION 拷到应用的引擎目录，
     或直接用 make-pack-release.sh 产出的归档走 in-app installer。
EOF
