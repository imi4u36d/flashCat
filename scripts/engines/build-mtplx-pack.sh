#!/usr/bin/env bash
#
# Build a self-contained MTPLX runtime pack:
#   <out>/mtplx/<version>/{manifest.json,bin/,python/,cache/}
#
# The pack bundles a python-build-standalone CPython 3.13 (ABI cp313 is required
# by the precompiled `_paged_ops` extension) plus the mtplx wheel and its pinned
# dependencies. The native `_paged_ops` extension is compiled at build time and
# shipped inside the pack's `cache/` directory, so the target machine needs no
# compiler at all.
#
# Usage:
#   scripts/engines/build-mtplx-pack.sh [--version 2.12.2] [--out DIR] [--force]
#
# Notes:
#   * No model weights are downloaded by this script.
#   * The pack is NOT relocatable: the compiled `_paged_ops` .so carries an
#     absolute rpath into `<pack>/python/lib/python3.13/site-packages/mlx/lib`,
#     so the pack must be installed at the path it is built at (version included).
#   * mlx must stay pinned to 0.32.2: the precompiled cache filename is
#     `_paged_ops-<sha256(libmlx.dylib)[:16]>.cpython-313-darwin.so`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

ENGINE_ID="mtplx"
ENGINE_NAME="MTPLX"
DEFAULT_VERSION="2.12.2"
DEFAULT_OUT="$REPO_ROOT/vendor/engines"
DEFAULT_PORT=8200
# ABI-critical: `_paged_ops` is built as .cpython-313-darwin.so
PYTHON_SERIES="3.13"
# Pinned on purpose — mlx version determines the native cache fingerprint.
PINNED_PACKAGES=(
  "mlx==0.32.2"
  "mlx-metal==0.32.2"
  "mlx-lm==0.31.3"
  "nanobind==3.1.0"
)

VERSION="$DEFAULT_VERSION"
OUT="$DEFAULT_OUT"
FORCE=0

usage() {
  cat <<'EOF'
Build a self-contained MTPLX runtime pack.

Usage: build-mtplx-pack.sh [options]

  --version VER   mtplx version to bundle (default: 2.12.2)
  --out DIR       output root; pack lands in DIR/mtplx/VER (default: vendor/engines)
  --force         replace an existing pack directory
  -h, --help      show this help
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
elapsed() { printf '    (%.1fs)\n' "$(( $(date +%s) - $1 ))"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --out)     OUT="${2:?--out needs a value}"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# ------------------------------------------------------------- bootstrap uv
# The pack build needs uv (python-build-standalone management + installs), but
# requiring it to be preinstalled would tie the build to the local machine's
# tooling. Instead, cache a standalone uv binary inside the repo and download
# it on first use.
ensure_uv() {
  local uv_bin="$REPO_ROOT/.tools/uv"
  if [[ -x "$uv_bin" ]]; then
    printf '%s\n' "$uv_bin"
    return 0
  fi
  step "Downloading standalone uv (one-time bootstrap into .tools/)"
  local url="https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz"
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/uv-bootstrap.XXXXXX")"
  curl -fL --retry 2 -o "$tmp/uv.tar.gz" "$url"
  mkdir -p "$REPO_ROOT/.tools"
  tar -xzf "$tmp/uv.tar.gz" -C "$tmp"
  mv "$tmp/uv-aarch64-apple-darwin/uv" "$uv_bin"
  rm -rf "$tmp"
  chmod +x "$uv_bin"
  printf '    uv -> %s\n' "$uv_bin"
  printf '%s\n' "$uv_bin"
}

UV="$(ensure_uv)"
mkdir -p "$OUT"
OUT="$(cd -- "$OUT" && pwd -P)"
PACK_DIR="$OUT/$ENGINE_ID/$VERSION"

if [[ -e "$PACK_DIR" ]]; then
  [[ $FORCE -eq 1 ]] || die "$PACK_DIR already exists (use --force to replace)"
  step "Removing existing pack $PACK_DIR"
  rm -rf "$PACK_DIR"
fi

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"   # a trailing slash would double up once Python normalises paths
WORK="$(mktemp -d "${TMP_BASE}/mtplx-pack.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

BUILD_START=$(date +%s)
printf 'Pack target: %s\n' "$PACK_DIR"

# ---------------------------------------------------------------- 1. CPython 3.13
step "Locating uv-managed CPython $PYTHON_SERIES"
T=$(date +%s)
if ! PY_REAL="$("$UV" python find --managed-python --resolve-links "$PYTHON_SERIES" 2>/dev/null)"; then
  printf '    not installed, fetching python-build-standalone %s\n' "$PYTHON_SERIES"
  "$UV" python install "$PYTHON_SERIES"
  PY_REAL="$("$UV" python find --managed-python --resolve-links "$PYTHON_SERIES")"
fi
[[ -n "$PY_REAL" && -x "$PY_REAL" ]] || die "could not resolve a managed CPython $PYTHON_SERIES"
PY_ROOT="$(cd -- "$(dirname -- "$PY_REAL")/.." && pwd -P)"
printf '    base: %s\n' "$PY_ROOT"
elapsed "$T"

step "Copying CPython into the pack"
T=$(date +%s)
mkdir -p "$PACK_DIR"
cp -a "$PY_ROOT" "$PACK_DIR/python"
chmod -R u+w "$PACK_DIR/python"
# The uv marker would block `uv pip install` into the pack interpreter.
rm -f "$PACK_DIR/python/lib/python${PYTHON_SERIES}/EXTERNALLY-MANAGED"
PY="$PACK_DIR/python/bin/python3"
[[ -x "$PY" ]] || die "pack interpreter missing: $PY"
printf '    %s\n' "$("$PY" -VV)"
elapsed "$T"

# --------------------------------------------------------------- 2. dependencies
step "Installing mtplx==$VERSION (pinned: ${PINNED_PACKAGES[*]})"
T=$(date +%s)
"$UV" pip install --python "$PY" --no-progress \
  "mtplx==$VERSION" "${PINNED_PACKAGES[@]}"
elapsed "$T"

step "Import / version self-check"
T=$(date +%s)
VERSION_LINE="$("$PY" -m mtplx.cli --version 2>&1 | tail -n 1)"
printf '    python -m mtplx.cli --version -> %s\n' "$VERSION_LINE"
[[ "$VERSION_LINE" == *"$VERSION"* ]] || die "version mismatch: expected $VERSION in '$VERSION_LINE'"
elapsed "$T"

# ------------------------------------------------- 3. precompile _paged_ops (cache)
step "Precompiling the _paged_ops native extension (build-time only)"
T=$(date +%s)
BUILD_HOME="$WORK/buildhome"
mkdir -p "$BUILD_HOME"
# HOME is redirected so we never touch the user's real ~/.cache/vllm-metal,
# and so the artefact we harvest is definitely produced by this build.
SO_BUILT="$(HOME="$BUILD_HOME" "$PY" - <<'PYEOF'
from vllm_metal.metal.build import build
print(build())
PYEOF
)"
SO_BUILT="$(printf '%s' "$SO_BUILT" | tail -n 1)"
[[ -f "$SO_BUILT" ]] || die "native extension build failed (no file at '$SO_BUILT')"
SO_NAME="$(basename "$SO_BUILT")"
mkdir -p "$PACK_DIR/cache"
cp -p "$SO_BUILT" "$PACK_DIR/cache/$SO_NAME"
printf '    %s (%s bytes)\n' "$SO_NAME" "$(wc -c < "$PACK_DIR/cache/$SO_NAME" | tr -d ' ')"
FINGERPRINT="$(printf '%s' "$SO_NAME" | sed -n 's/^_paged_ops-\([0-9a-f]\{16\}\)\..*$/\1/p')"
[[ -n "$FINGERPRINT" ]] || die "unexpected native extension name: $SO_NAME"
printf '    mlx libmlx.dylib fingerprint: %s\n' "$FINGERPRINT"
elapsed "$T"

step "Verifying get_ops() loads the packed cache in a clean HOME"
T=$(date +%s)
VERIFY_HOME="$WORK/verifyhome"
mkdir -p "$VERIFY_HOME/.cache/vllm-metal"
cp -p "$PACK_DIR/cache/$SO_NAME" "$VERIFY_HOME/.cache/vllm-metal/$SO_NAME"
OPS_FILE="$(HOME="$VERIFY_HOME" "$PY" - <<'PYEOF' | tail -n 1
from vllm_metal.metal import get_ops
print(get_ops().__file__)
PYEOF
)"
printf '    get_ops() -> %s\n' "$OPS_FILE"
[[ "$OPS_FILE" == "$VERIFY_HOME"/* ]] || die "get_ops() did not use the packed cache (got '$OPS_FILE')"
[[ "$(basename "$OPS_FILE")" == "$SO_NAME" ]] || die "get_ops() loaded an unexpected artefact: $OPS_FILE"
elapsed "$T"

# ----------------------------------------------------------------- 4. manifest.json
step "Writing manifest.json"
mkdir -p "$PACK_DIR/bin" "$PACK_DIR/models"   # bin/ = PATH prefix dir the app may prepend
cat > "$PACK_DIR/manifest.json" <<EOF
{
  "schemaVersion": 1,
  "id": "$ENGINE_ID",
  "name": "$ENGINE_NAME",
  "version": "$VERSION",
  "kind": "bundled",
  "arch": "arm64",
  "minMacOS": "14.0",
  "entrypoint": "python/bin/python3",
  "workingDirectory": ".",
  "modelsSubdirectory": "models",
  "launchProfiles": {
    "default": {
      "args": [
        "-m", "mtplx.cli", "serve",
        "--model", "{model}",
        "--host", "127.0.0.1",
        "--port", "{port}",
        "--no-auth",
        "--model-search-dir", "{models}"
      ],
      "environment": {
        "PYTHONNOUSERSITE": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONUNBUFFERED": "1"
      }
    }
  },
  "health": { "path": "/health", "readyStatus": 200, "loadingStatus": 503 },
  "status": ["/v1/mtplx/snapshot"],
  "models": { "path": "/v1/models" },
  "defaultPort": $DEFAULT_PORT,
  "modelSwitch": "restart",
  "modelArgument": "path",
  "capabilities": ["chat", "streaming", "vision", "reasoning", "singleModel", "mtp"],
  "warmup": {
    "precompiled": ["cache/$SO_NAME"],
    "cacheDir": "{home}/.cache/vllm-metal"
  },
  "license": "Apache-2.0"
}
EOF
"$PY" - "$PACK_DIR/manifest.json" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
assert data["id"] == "mtplx" and data["schemaVersion"] == 1
assert data["warmup"]["precompiled"], "warmup.precompiled must not be empty"
print("    manifest.json parsed OK")
PYEOF

step "Make the pack relocatable"
# The precompiled _paged_ops inherits the build machine's absolute LC_RPATH,
# which would make an installed copy (Application Support) fail to load mlx.
"$REPO_ROOT/scripts/engines/fix-pack-rpaths.sh" "$PACK_DIR"

# --------------------------------------------------------------------- 5. summary
step "Pack summary"
PACK_SIZE="$(du -sh "$PACK_DIR" | awk '{print $1}')"
FILE_COUNT="$(find "$PACK_DIR" -type f | wc -l | tr -d ' ')"
printf '    path      : %s\n' "$PACK_DIR"
printf '    size      : %s (%s files)\n' "$PACK_SIZE" "$FILE_COUNT"
printf '    python    : %s\n' "$("$PY" -VV)"
printf '    mtplx     : %s\n' "$VERSION_LINE"
printf '    elapsed   : %ss total\n' "$(( $(date +%s) - BUILD_START ))"
printf '    sha256    :\n'
( cd "$PACK_DIR" && shasum -a 256 manifest.json "cache/$SO_NAME" | sed 's/^/      /' )
printf '\nDone: %s\n' "$PACK_DIR"
