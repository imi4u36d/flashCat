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
#                                      [--sha256 HEX]
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
    --sha256)  WHEEL_SHA="${2:?--sha256 needs a value}"; shift 2 ;;
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

# ------------------------------------------------- resolve the wheel + checksum
WHEEL_NAME="omlx-${VERSION}-cp311-cp311-macosx_15_0_universal2.whl"
WHEEL_URL="https://github.com/${UPSTREAM_REPO}/releases/download/v${VERSION}/${WHEEL_NAME}"

# GitHub's release API reports a server-computed digest per asset
# ("digest": "sha256:<hex>"); look up the one for our wheel.
expected_sha_from_notes() {
  local api_json
  api_json="$(mktemp "${TMPDIR:-/tmp}/omlx-release.XXXXXX.json")"
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
WORK="$(mktemp -d "${TMP_BASE}/omlx-pack.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

BUILD_START=$(date +%s)
printf 'Pack target: %s\n' "$PACK_DIR"

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
PY="$PACK_DIR/python/bin/python3"
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
"$PY" - "$PACK_DIR/manifest.json" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
assert data["id"] == "omlx" and data["schemaVersion"] == 1
print("    manifest.json parsed OK")
PYEOF

step "Make the pack relocatable"
# Any wheel that bakes the build machine's absolute LC_RPATH in would break an
# installed copy; rewrite in-pack rpaths to @loader_path.
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
