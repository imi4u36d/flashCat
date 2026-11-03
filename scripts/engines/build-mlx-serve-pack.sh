#!/usr/bin/env bash
#
# Build a self-contained MLX-Serve runtime pack from the upstream macOS CLI
# archive. The DMG is intentionally not used: flashCat drives the signed CLI
# server, not the upstream desktop application.
#
# Usage:
#   scripts/engines/build-mlx-serve-pack.sh [--version 26.11.1] [--out DIR]
#                                           [--tarball FILE] [--sha256 HEX] [--force]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

ENGINE_ID="mlx-serve"
ENGINE_NAME="MLX-Serve"
UPSTREAM_REPO="ddalcu/mlx-serve"
DEFAULT_VERSION="26.11.1"
DEFAULT_OUT="$ROOT/vendor/engines"
DEFAULT_PORT=8300
MIN_MACOS="26.4"
ASSET="mlx-serve-bin-macos-arm64.tar.gz"

VERSION="$DEFAULT_VERSION"
OUT="$DEFAULT_OUT"
TARBALL=""
EXPECTED_SHA=""
FORCE=0

usage() {
  cat <<'EOF'
Build a self-contained MLX-Serve runtime pack.

Usage: build-mlx-serve-pack.sh [options]

  --version VER   upstream version (default: 26.11.1)
  --out DIR       output root (default: vendor/engines)
  --tarball FILE  use an existing upstream archive
  --sha256 HEX    expected archive sha256 (resolved from GitHub by default)
  --force         replace an existing pack
  -h, --help      show this help
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    --tarball) TARBALL="${2:?--tarball needs a value}"; shift 2 ;;
    --sha256) EXPECTED_SHA="${2:?--sha256 needs a value}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "$VERSION" ]] || die "--version must not be empty"
[[ "$VERSION" != v* ]] || VERSION="${VERSION#v}"
TARBALL="${TARBALL:-$ROOT/vendor/mlx-serve-$VERSION-$ASSET}"
mkdir -p "$(dirname -- "$TARBALL")"

if [[ ! -f "$TARBALL" ]]; then
  step "Downloading $ASSET $VERSION"
  curl -fL --retry 2 --max-time 300 -o "$TARBALL" \
    "https://github.com/$UPSTREAM_REPO/releases/download/v$VERSION/$ASSET"
fi

if [[ -z "$EXPECTED_SHA" ]]; then
  step "Resolving upstream sha256"
  API_JSON="$(mktemp "${TMPDIR:-/tmp}/mlx-serve-release.XXXXXX.json")"
  trap 'rm -f "$API_JSON"' EXIT
  curl -fsSL --retry 2 -o "$API_JSON" \
    "https://api.github.com/repos/$UPSTREAM_REPO/releases/tags/v$VERSION"
  EXPECTED_SHA="$(/usr/bin/python3 - "$ASSET" "$API_JSON" <<'PY'
import json, sys
asset, path = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    release = json.load(handle)
for item in release.get("assets", []):
    if item.get("name") == asset:
        digest = item.get("digest") or ""
        if digest.startswith("sha256:"):
            print(digest.split(":", 1)[1])
            raise SystemExit(0)
raise SystemExit(1)
PY
)" || die "could not resolve sha256 for $ASSET; pass --sha256 HEX explicitly"
  rm -f "$API_JSON"
  trap - EXIT
fi

ACTUAL_SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || die "sha256 mismatch: expected $EXPECTED_SHA, got $ACTUAL_SHA"

mkdir -p "$OUT"
OUT="$(cd -- "$OUT" && pwd -P)"
PACK_DIR="$OUT/$ENGINE_ID/$VERSION"
if [[ -e "$PACK_DIR" ]]; then
  [[ $FORCE -eq 1 ]] || die "$PACK_DIR already exists (pass --force)"
  rm -rf "$PACK_DIR"
fi
mkdir -p "$PACK_DIR"

step "Extracting MLX-Serve"
tar -xzf "$TARBALL" --strip-components=1 -C "$PACK_DIR"
chmod -R u+w "$PACK_DIR"
for required in mlx-serve LICENSE NOTICE LICENSE-APACHE-2.0 lib/libmlx.dylib lib/libmlxc.dylib lib/mlx.metallib; do
  [[ -e "$PACK_DIR/$required" ]] || die "archive is incomplete: missing $required"
done

step "Verifying binary"
"$PACK_DIR/mlx-serve" --version >/tmp/flashcat-mlx-serve-version.txt
cat /tmp/flashcat-mlx-serve-version.txt
rm -f /tmp/flashcat-mlx-serve-version.txt
otool -L "$PACK_DIR/mlx-serve" | grep -q '@executable_path/lib/libllama.dylib' \
  || die "MLX-Serve binary is not relocatable with its bundled libraries"

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
  "entrypoint": "mlx-serve",
  "workingDirectory": ".",
  "modelsSubdirectory": "models",
  "launchProfiles": {
    "default": {
      "args": [
        "--serve",
        "--host", "127.0.0.1",
        "--port", "{port}",
        "--model-dir", "{models}",
        "--max-resident-models", "1",
        "--metrics",
        "--no-plugins",
        "--log-file", "off"
      ],
      "environment": {
        "HOME": "{support}/engine-homes/mlx-serve",
        "HF_HOME": "{support}/engine-homes/mlx-serve/.cache/huggingface"
      }
    }
  },
  "health": { "path": "/health", "readyStatus": 200 },
  "status": ["/v1/models"],
  "models": { "path": "/v1/models" },
  "defaultPort": $DEFAULT_PORT,
  "modelSwitch": "hot",
  "modelArgument": "name",
  "capabilities": [
    "chat", "streaming", "vision", "reasoning", "tool-use",
    "multi-model", "hot-load", "hot-unload", "model-rescan"
  ],
  "adapter": "mlx-serve",
  "startupTimeout": 600,
  "portRangeSize": 20,
  "modelLayout": "nested",
  "modelControl": {
    "load": {
      "method": "POST",
      "path": "/v1/load-model",
      "body": { "model": "{model}", "default": true }
    },
    "unload": {
      "method": "POST",
      "path": "/v1/unload-model",
      "body": { "model": "{model}" }
    },
    "rescan": { "method": "POST", "path": "/v1/models/rescan" }
  },
  "telemetry": [
    { "role": "inventory", "path": "/v1/models", "format": "openai.models" },
    { "role": "metrics", "path": "/metrics.json", "format": "prometheus.json" },
    { "role": "props", "path": "/props", "format": "llama.props" }
  ],
  "license": "MIT"
}
EOF

/usr/bin/python3 -m json.tool "$PACK_DIR/manifest.json" >/dev/null
mkdir -p "$PACK_DIR/models"

step "Pack summary"
printf '    path: %s\n' "$PACK_DIR"
printf '    size: %s\n' "$(du -sh "$PACK_DIR" | awk '{print $1}')"
printf '    sha256: %s\n' "$ACTUAL_SHA"

cat <<EOF

Next:
  scripts/engines/make-pack-release.sh --engine $ENGINE_ID --version $VERSION
EOF
