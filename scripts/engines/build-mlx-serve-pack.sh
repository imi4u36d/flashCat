#!/usr/bin/env bash
#
# Build a self-contained MLX-Serve runtime pack from the upstream macOS CLI
# archive. The DMG is intentionally not used: flashCat drives the signed CLI
# server, not the upstream desktop application.
#
# Usage:
#   scripts/engines/build-mlx-serve-pack.sh [--version 26.11.1] [--out DIR]
#                                           [--tarball FILE] [--sha256 HEX] [--force]
#                                           [--dry-run]

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib-pack.sh"

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
  --dry-run       print the resolved target and exit without writing anything
  -h, --help      show this help
EOF
}

pack_parse_engine_arg() {
  case "$1" in
    --tarball)
      [[ $# -ge 2 && -n "$2" ]] || die "--tarball needs a value"
      TARBALL="$2"; PACK_ARG_SHIFT=2
      ;;
    --sha256)
      [[ $# -ge 2 && -n "$2" ]] || die "--sha256 needs a value"
      EXPECTED_SHA="$2"; PACK_ARG_SHIFT=2
      ;;
    *) return 1 ;;
  esac
  return 0
}

pack_parse_common_args "$@"

[[ -n "$VERSION" ]] || die "--version must not be empty"
[[ "$VERSION" != v* ]] || VERSION="${VERSION#v}"
TARBALL="${TARBALL:-$ROOT/vendor/mlx-serve-$VERSION-$ASSET}"

pack_require_tools curl tar shasum otool /usr/bin/python3
pack_begin "pass --force"

mkdir -p "$(dirname -- "$TARBALL")"

if [[ ! -f "$TARBALL" ]]; then
  step "Downloading $ASSET $VERSION"
  curl -fL --retry 2 --max-time 300 -o "$TARBALL" \
    "https://github.com/$UPSTREAM_REPO/releases/download/v$VERSION/$ASSET"
fi

# The archive digest is published as a GitHub release asset digest, so ask the
# release API once instead of pinning it in the script. --sha256 is the escape
# hatch for offline builds and for upstreams that stop publishing digests.
if [[ -z "$EXPECTED_SHA" ]]; then
  step "Resolving upstream sha256"
  API_JSON="$(mktemp "${TMPDIR:-/tmp}/mlx-serve-release.XXXXXX.json")"
  pack_cleanup_add "$API_JSON"
  if curl -fsSL --retry 2 -o "$API_JSON" \
      "https://api.github.com/repos/$UPSTREAM_REPO/releases/tags/v$VERSION"; then
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
)" || true
  fi
  rm -f "$API_JSON"
  if [[ -z "$EXPECTED_SHA" ]]; then
    # The API is capped at 60 unauthenticated requests/hour per IP; a shared
    # proxy exhausts that quickly. The asset page reports the same digest.
    step "Release API unavailable (rate limit?); reading the asset page"
    EXPECTED_SHA="$(pack_release_assets "$UPSTREAM_REPO" "v$VERSION" \
      | awk -F '\t' -v asset="$ASSET" '$1 == asset && $3 != "" { print $3; exit }')"
  fi
  [[ -n "$EXPECTED_SHA" ]] || die "could not resolve sha256 for $ASSET; pass --sha256 HEX explicitly"
fi

ACTUAL_SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || die "sha256 mismatch: expected $EXPECTED_SHA, got $ACTUAL_SHA"

pack_stage

step "Extracting MLX-Serve"
pack_extract "$TARBALL" "$PACK_STAGING" strip
for required in mlx-serve LICENSE NOTICE LICENSE-APACHE-2.0 lib/libmlx.dylib lib/libmlxc.dylib lib/mlx.metallib; do
  [[ -e "$PACK_STAGING/$required" ]] || die "archive is incomplete: missing $required"
done

step "Verifying binary"
"$PACK_STAGING/mlx-serve" --version >/tmp/flashcat-mlx-serve-version.txt
cat /tmp/flashcat-mlx-serve-version.txt
rm -f /tmp/flashcat-mlx-serve-version.txt
otool -L "$PACK_STAGING/mlx-serve" | grep -q '@executable_path/lib/libllama.dylib' \
  || die "MLX-Serve binary is not relocatable with its bundled libraries"

step "Writing manifest.json"
cat > "$PACK_STAGING/manifest.json" <<EOF
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

pack_validate_manifest /usr/bin/python3
mkdir -p "$PACK_STAGING/models"

pack_swap

pack_print_summary
printf '    sha256    : %s\n' "$ACTUAL_SHA"

pack_next_release_cmd
