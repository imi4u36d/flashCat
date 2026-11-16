#!/usr/bin/env bash
#
# Build a self-contained oMLX runtime pack:
#   <out>/omlx/<version>/{manifest.json,bin/,python/,models/}
#
# oMLX is NOT published on PyPI, but every upstream release on GitHub ships a
# prebuilt cp311 wheel (omlx-<ver>-cp311-cp311-macosx_15_0_universal2.whl).
# This script downloads that wheel straight from the GitHub release, verifies
# its sha256 against the release notes, and installs it (with its PyPI
# dependencies) into a python-build-standalone CPython 3.11 bundled in the pack.
# Nothing here depends on Homebrew, a preinstalled uv, or any other local
# toolchain — only /usr/bin tools (curl, tar, shasum) plus one bootstrap
# download of the standalone uv binary.
#
# Usage:
#   scripts/engines/build-omlx-pack.sh [--version 0.7.2] [--out DIR] [--force]
#                                      [--sha256 HEX] [--dry-run]
#
# No model weights are downloaded by this script.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib-pack.sh"

ENGINE_ID="omlx"
ENGINE_NAME="oMLX"
DEFAULT_VERSION="0.7.2"
DEFAULT_OUT="$ROOT/vendor/engines"
DEFAULT_PORT=8100
UPSTREAM_REPO="jundot/omlx"
# ABI-critical: the upstream wheel is built for cp311 only.
PYTHON_SERIES="3.11"
# macOS target of the upstream wheel (macosx_15_0_universal2).
MIN_MACOS="15.0"

VERSION="$DEFAULT_VERSION"
OUT="$DEFAULT_OUT"
FORCE=0
WHEEL_SHA=""

usage() {
  cat <<'EOF'
Build a self-contained oMLX runtime pack.

Usage: build-omlx-pack.sh [options]

  --version VER   omlx version to bundle (default: 0.7.2)
  --out DIR       output root; pack lands in DIR/omlx/VER (default: vendor/engines)
  --force         replace an existing pack directory
  --sha256 HEX    expected sha256 of the upstream wheel; resolved from the
                  GitHub release API automatically when omitted
  --dry-run       print the resolved target and exit without writing anything
  -h, --help      show this help
EOF
}

pack_parse_engine_arg() {
  case "$1" in
    --sha256)
      [[ $# -ge 2 && -n "$2" ]] || die "--sha256 needs a value"
      WHEEL_SHA="$2"; PACK_ARG_SHIFT=2
      ;;
    *) return 1 ;;
  esac
  return 0
}

pack_parse_common_args "$@"

pack_require_tools curl tar shasum /usr/bin/python3
pack_begin "use --force to replace"

# ------------------------------------------------- resolve the wheel + checksum
WHEEL_NAME="omlx-${VERSION}-cp311-cp311-macosx_15_0_universal2.whl"
WHEEL_URL="https://github.com/${UPSTREAM_REPO}/releases/download/v${VERSION}/${WHEEL_NAME}"

# GitHub's release API reports a server-computed digest per asset
# ("digest": "sha256:<hex>"); look up the one for our wheel.
expected_sha_from_notes() {
  local api_json
  api_json="$(mktemp "${TMPDIR:-/tmp}/omlx-release.XXXXXX.json")"
  pack_cleanup_add "$api_json"
  if ! curl -fsSL --retry 2 -o "$api_json" \
      "https://api.github.com/repos/${UPSTREAM_REPO}/releases/tags/v${VERSION}"; then
    rm -f "$api_json"
    return 1
  fi
  /usr/bin/python3 - "$WHEEL_NAME" "$api_json" <<'PYEOF'
import json, sys
wheel, path = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    raise SystemExit(1)
for asset in data.get("assets", []):
    if asset.get("name") == wheel:
        digest = asset.get("digest") or ""
        if digest.startswith("sha256:"):
            print(digest.split(":", 1)[1])
            raise SystemExit(0)
raise SystemExit(1)
PYEOF
  local rc=$?
  rm -f "$api_json"
  return "$rc"
}

if [[ -z "$WHEEL_SHA" ]]; then
  step "Resolving the wheel sha256 from the ${UPSTREAM_REPO} release API"
  WHEEL_SHA="$(expected_sha_from_notes || true)"
  [[ -n "$WHEEL_SHA" ]] || die "could not read a sha256 for $WHEEL_NAME from the GitHub release API
       (unreachable or rate-limited?). Pass --sha256 HEX explicitly."
  printf '    expected: %s\n' "$WHEEL_SHA"
fi

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"   # a trailing slash would double up once Python normalises paths
WORK="$(mktemp -d "${TMP_BASE}/omlx-pack.XXXXXX")"
pack_cleanup_add "$WORK"

# uv is bootstrapped after the target-path gate: a --dry-run or a refused
# --force must not write .tools/ or touch the network.
UV="$(pack_ensure_uv)"

BUILD_START=$(date +%s)
printf 'Pack target: %s\n' "$PACK_DIR"

pack_stage

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
cp -a "$PY_ROOT" "$PACK_STAGING/python"
chmod -R u+w "$PACK_STAGING/python"
# The uv marker would block `uv pip install` into the pack interpreter.
rm -f "$PACK_STAGING/python/lib/python${PYTHON_SERIES}/EXTERNALLY-MANAGED"
PY="$PACK_STAGING/python/bin/python3"
[[ -x "$PY" ]] || die "pack interpreter missing: $PY"
printf '    %s\n' "$("$PY" -VV)"
elapsed "$T"

# ------------------------------------- 2. download + install the upstream wheel
step "Downloading $WHEEL_NAME from the upstream GitHub release"
T=$(date +%s)
WHEEL_FILE="$WORK/$WHEEL_NAME"
curl -fL --retry 2 -o "$WHEEL_FILE" "$WHEEL_URL"
ACTUAL_SHA="$(shasum -a 256 "$WHEEL_FILE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$WHEEL_SHA" ]]; then
  die "wheel sha256 mismatch: expected $WHEEL_SHA, got $ACTUAL_SHA"
fi
printf '    sha256 OK: %s\n' "$ACTUAL_SHA"
elapsed "$T"

step "Installing the wheel and its PyPI dependencies into the pack"
T=$(date +%s)
"$UV" pip install --python "$PY" --no-progress "$WHEEL_FILE"
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

# --------------------------------------------------------------- 4. manifest.json
step "Writing manifest.json"
mkdir -p "$PACK_STAGING/bin" "$PACK_STAGING/models"   # bin/ = PATH prefix dir the app may prepend
cat > "$PACK_STAGING/manifest.json" <<EOF
{
  "schemaVersion": 1,
  "id": "$ENGINE_ID",
  "name": "$ENGINE_NAME",
  "version": "$VERSION",
  "kind": "bundled",
  "arch": "arm64",
  "minMacOS": "$MIN_MACOS",
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
"$PY" - "$PACK_STAGING/manifest.json" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
assert data["id"] == "omlx" and data["schemaVersion"] == 1
print("    manifest.json parsed OK")
PYEOF

# Any wheel that bakes the build machine's absolute LC_RPATH in would break an
# installed copy; rewrite in-pack rpaths to @loader_path.
pack_fix_rpaths

pack_swap
# The staging path is gone after the swap, so re-point the interpreter at the
# published pack before reporting on it.
PY="$PACK_DIR/python/bin/python3"

# --------------------------------------------------------------------- 5. summary
pack_print_summary
printf '    python    : %s\n' "$("$PY" -VV)"
printf '    omlx      : %s\n' "$VERSION_LINE"
printf '    elapsed   : %ss total\n' "$(( $(date +%s) - BUILD_START ))"
printf '    sha256    :\n'
( cd "$PACK_DIR" && shasum -a 256 manifest.json | sed 's/^/      /' )
printf '\nDone: %s\n' "$PACK_DIR"
