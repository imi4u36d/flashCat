#!/usr/bin/env bash
#
# Build a self-contained oMLX runtime pack:
#   <out>/omlx/<version>/{manifest.json,bin/,python/,models/}
#
# oMLX is NOT published on PyPI (https://pypi.org/pypi/omlx/json -> 404), so this
# script bundles the site-packages tree of an already-installed Homebrew omlx
# cell together with a python-build-standalone CPython 3.11 (ABI cp311 is
# required by the prebuilt binary wheels inside that tree). The Homebrew cellar
# is only read, never modified.
#
# Usage:
#   scripts/engines/build-omlx-pack.sh [--version 0.7.2] [--out DIR] [--force]
#
# No model weights are downloaded by this script.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

ENGINE_ID="omlx"
ENGINE_NAME="oMLX"
DEFAULT_VERSION="0.7.2"
DEFAULT_OUT="$REPO_ROOT/vendor/engines"
DEFAULT_PORT=8100
# ABI-critical: every prebuilt .so in the Homebrew tree is .cpython-311-darwin.so
PYTHON_SERIES="3.11"
# Read-only source of the omlx distribution (Homebrew keg, not PyPI).
SOURCE_KEG_DEFAULT="/opt/homebrew/Cellar/omlx"

VERSION="$DEFAULT_VERSION"
OUT="$DEFAULT_OUT"
FORCE=0

usage() {
  cat <<'EOF'
Build a self-contained oMLX runtime pack.

Usage: build-omlx-pack.sh [options]

  --version VER   omlx version to bundle (default: 0.7.2)
  --out DIR       output root; pack lands in DIR/omlx/VER (default: vendor/engines)
  --force         replace an existing pack directory
  -h, --help      show this help

Environment:
  OMLX_KEG        Homebrew keg root (default: /opt/homebrew/Cellar/omlx)
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

find_uv() {
  local candidates=(
    "${HOME:-/nonexistent}/.envpilot/tools/uv"
    /opt/homebrew/bin/uv
    /usr/local/bin/uv
  )
  local c
  for c in "${candidates[@]}"; do
    [[ -x "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  command -v uv 2>/dev/null && return 0
  die "uv not found (looked in ~/.envpilot/tools, /opt/homebrew/bin, PATH)"
}

KEG_ROOT="${OMLX_KEG:-$SOURCE_KEG_DEFAULT}"
KEG="$KEG_ROOT/$VERSION"
CELLAR_SITE="$KEG/libexec/lib/python${PYTHON_SERIES}/site-packages"

[[ -d "$CELLAR_SITE" ]] || die "no omlx $VERSION in $KEG_ROOT (expected $CELLAR_SITE).
       omlx is not on PyPI, so a local install is required: brew install omlx"

UV="$(find_uv)"
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
WORK="$(mktemp -d "${TMP_BASE}/omlx-pack.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

BUILD_START=$(date +%s)
printf 'Pack target: %s\n' "$PACK_DIR"
printf 'Source keg : %s (read-only)\n' "$KEG"

# ---------------------------------------------------------------- 1. CPython 3.11
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
PACK_SITE="$PACK_DIR/python/lib/python${PYTHON_SERIES}/site-packages"
rm -f "$PACK_DIR/python/lib/python${PYTHON_SERIES}/EXTERNALLY-MANAGED"
# Drop the standalone build's own site-packages (pip/setuptools) entirely: the
# cellar tree ships its own, and merging two copies of both is asking for trouble.
rm -rf "$PACK_SITE"
mkdir -p "$PACK_SITE"
PY="$PACK_DIR/python/bin/python3"
[[ -x "$PY" ]] || die "pack interpreter missing: $PY"
printf '    %s\n' "$("$PY" -VV)"
elapsed "$T"

# ------------------------------------------------- 2. copy the omlx site-packages
step "Copying omlx site-packages from the Homebrew keg (read-only source)"
T=$(date +%s)
cp -a "$CELLAR_SITE/." "$PACK_SITE/"
chmod -R u+w "$PACK_SITE"
printf '    %s\n' "$(du -sh "$PACK_SITE" | awk '{print $1}') copied"
# Stale absolute references would silently point at the cellar instead of the pack.
if find "$PACK_SITE" -maxdepth 1 -name '*.pth' -print -quit | grep -q .; then
  printf '    warning: .pth files found next to the pack:\n'
  find "$PACK_SITE" -maxdepth 1 -name '*.pth' | sed 's/^/      /'
fi
elapsed "$T"

# --------------------------------------------------------------- 3. self-check
step "Import / version self-check"
T=$(date +%s)
VERSION_LINE="$("$PY" -m omlx.cli --version 2>&1 | tail -n 1)"
printf '    python -m omlx.cli --version -> %s\n' "$VERSION_LINE"
[[ "$VERSION_LINE" == "$VERSION" ]] || die "version mismatch: expected '$VERSION', got '$VERSION_LINE'"
IMPORTED="$("$PY" - <<'PYEOF'
import omlx, mlx.core as mx, sys
print(f"omlx {omlx.__version__} / mlx {mx.__version__} / {sys.version.split()[0]}")
PYEOF
)"
printf '    import check -> %s\n' "$IMPORTED"
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
        "-m", "omlx.cli", "serve",
        "--host", "127.0.0.1",
        "--port", "{port}",
        "--model-dir", "{models}"
      ],
      "environment": {
        "PYTHONNOUSERSITE": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONUNBUFFERED": "1"
      }
    }
  },
  "health": { "path": "/health", "readyStatus": 200, "loadingStatus": 503 },
  "status": ["/api/status", "/v1/models/status"],
  "models": { "path": "/v1/models" },
  "defaultPort": $DEFAULT_PORT,
  "modelSwitch": "hot",
  "modelArgument": "name",
  "capabilities": ["chat", "streaming", "vision", "reasoning", "multiModel", "hotLoad", "hotUnload", "modelRescan"],
  "license": "Apache-2.0"
}
EOF
"$PY" - "$PACK_DIR/manifest.json" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
assert data["id"] == "omlx" and data["schemaVersion"] == 1
print("    manifest.json parsed OK")
PYEOF

step "Make the pack relocatable"
# Any wheel that bakes the build machine's absolute LC_RPATH in would break an
# installed copy; rewrite in-pack rpaths to @loader_path. No-op for this pack
# today (its rpaths already point outside the pack), but it keeps the two build
# scripts symmetric and future oMLX builds safe.
"$REPO_ROOT/scripts/engines/fix-pack-rpaths.sh" "$PACK_DIR"

# --------------------------------------------------------------------- 5. summary
step "Pack summary"
PACK_SIZE="$(du -sh "$PACK_DIR" | awk '{print $1}')"
FILE_COUNT="$(find "$PACK_DIR" -type f | wc -l | tr -d ' ')"
printf '    path      : %s\n' "$PACK_DIR"
printf '    size      : %s (%s files)\n' "$PACK_SIZE" "$FILE_COUNT"
printf '    python    : %s\n' "$("$PY" -VV)"
printf '    omlx      : %s\n' "$VERSION_LINE"
printf '    elapsed   : %ss total\n' "$(( $(date +%s) - BUILD_START ))"
printf '    sha256    :\n'
( cd "$PACK_DIR" && shasum -a 256 manifest.json | sed 's/^/      /' )
printf '\nDone: %s\n' "$PACK_DIR"
