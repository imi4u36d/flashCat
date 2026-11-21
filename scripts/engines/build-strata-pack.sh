#!/usr/bin/env bash
#
# Build a self-contained Strata runtime pack for Apple Silicon:
#   <out>/strata/<app-version>/
#     python/ ... bin/strata  (official control archive)
#     engine/ ...             (official Metal engine component)
#     flashcat_strata.py      (foreground lifecycle adapter)
#
# Usage:
#   scripts/engines/build-strata-pack.sh [--version 0.2.10] [--out DIR] [--force] [--dry-run]

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib-pack.sh"

ENGINE_ID="strata"
ENGINE_NAME="Strata"
UPSTREAM_REPO="Niko1221/Strata"
DEFAULT_VERSION="0.2.10"
DEFAULT_OUT="$ROOT/vendor/engines"
DEFAULT_PORT=8400
MIN_MACOS="15.0"
WRAPPER="$ROOT/runtime/flashcat_strata.py"

VERSION="$DEFAULT_VERSION"
OUT="$DEFAULT_OUT"
FORCE=0

usage() {
  cat <<'EOF'
Build a self-contained Strata runtime pack.

Usage: build-strata-pack.sh [options]

  --version VER   Strata app/Terminal version (default: 0.2.10)
  --out DIR       output root (default: vendor/engines)
  --force         replace an existing pack
  --dry-run       print the resolved target and exit without writing anything
  -h, --help      show this help
EOF
}

pack_parse_common_args "$@"

[[ "$VERSION" != v* ]] || VERSION="${VERSION#v}"
[[ -f "$WRAPPER" ]] || die "wrapper missing: $WRAPPER"

pack_require_tools curl tar shasum /usr/bin/python3
pack_begin "pass --force"

# Two assets, one release: the control archive carries the bundled interpreter
# and the CLI, the Metal archive carries the compiled engine. Which asset is
# which is only encoded in the asset names, so the release API is the authority.
# Pick the control and engine rows out of a `name\turl\tsha256` stream.
select_assets() {
  /usr/bin/python3 - <<'PY'
import sys
control = engine = None
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 3:
        continue
    name, url, sha = parts
    row = (name, url, sha)
    if name.startswith("strata-control-") and name.endswith("-macos-arm64.tar.gz"):
        control = row
    elif name.startswith("strata-engine-") and name.endswith("-macos-arm64-metal.tar.gz"):
        engine = row
if not control or not engine:
    raise SystemExit(1)
print("\t".join(control))
print("\t".join(engine))
PY
}

mkdir -p "$ROOT/vendor"
API_JSON="$(mktemp "${TMPDIR:-/tmp}/strata-release.XXXXXX.json")"
pack_cleanup_add "$API_JSON"
step "Resolving Strata $VERSION release assets"
ASSETS=""
if curl -fsSL --retry 2 -o "$API_JSON" \
    "https://api.github.com/repos/$UPSTREAM_REPO/releases/tags/v$VERSION"; then
  ASSETS="$(/usr/bin/python3 - "$API_JSON" <<'PY' | select_assets
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    release = json.load(handle)
for asset in release.get("assets", []):
    name = asset.get("name", "")
    digest = asset.get("digest") or ""
    print("\t".join([name, asset.get("browser_download_url", ""), digest.split(":", 1)[-1]]))
PY
)" || true
fi
rm -f "$API_JSON"
if [[ -z "$ASSETS" ]]; then
  # The API is capped at 60 unauthenticated requests/hour per IP; a shared
  # proxy exhausts that quickly. The asset page has the same names, links and
  # digests.
  step "Release API unavailable (rate limit?); reading the asset page"
  ASSETS="$(pack_release_assets "$UPSTREAM_REPO" "v$VERSION" | select_assets)" || true
fi
[[ -n "$ASSETS" ]] || die "could not resolve release assets"

CONTROL_NAME="$(printf '%s\n' "$ASSETS" | sed -n '1p' | cut -f1)"
CONTROL_URL="$(printf '%s\n' "$ASSETS" | sed -n '1p' | cut -f2)"
CONTROL_SHA="$(printf '%s\n' "$ASSETS" | sed -n '1p' | cut -f3)"
ENGINE_NAME_ASSET="$(printf '%s\n' "$ASSETS" | sed -n '2p' | cut -f1)"
ENGINE_URL="$(printf '%s\n' "$ASSETS" | sed -n '2p' | cut -f2)"
ENGINE_SHA="$(printf '%s\n' "$ASSETS" | sed -n '2p' | cut -f3)"

CONTROL_TGZ="$ROOT/vendor/$CONTROL_NAME"
ENGINE_TGZ="$ROOT/vendor/$ENGINE_NAME_ASSET"
download() {
  local url="$1" target="$2" expected="$3"
  if [[ ! -f "$target" ]]; then
    curl -fL --retry 2 --max-time 600 -o "$target" "$url"
  fi
  local actual
  actual="$(shasum -a 256 "$target" | awk '{print $1}')"
  [[ -z "$expected" || "$actual" == "$expected" ]] \
    || die "sha256 mismatch for $(basename "$target"): expected $expected, got $actual"
  printf '    %s  %s\n' "$actual" "$(basename "$target")"
}
step "Downloading release components"
download "$CONTROL_URL" "$CONTROL_TGZ" "$CONTROL_SHA"
download "$ENGINE_URL" "$ENGINE_TGZ" "$ENGINE_SHA"

pack_stage

step "Extracting Strata control and Metal engine"
pack_extract "$CONTROL_TGZ" "$PACK_STAGING"
pack_extract "$ENGINE_TGZ" "$PACK_STAGING/engine"
cp -a "$WRAPPER" "$PACK_STAGING/flashcat_strata.py"

for required in python/bin/python3 bin/strata setup.py flashcat_strata.py \
                engine/strata engine/strata-vision engine/engine-component.json; do
  [[ -e "$PACK_STAGING/$required" ]] || die "pack incomplete: missing $required"
done

step "Verifying bundled Python and Strata CLI"
PY="$PACK_STAGING/python/bin/python3"
"$PY" -B -VV
PYTHONPATH="$PACK_STAGING" STRATA_INSTALL_DIR="$PACK_STAGING/.runtime-check" \
  "$PACK_STAGING/bin/strata" --version
rm -rf "$PACK_STAGING/.runtime-check"
"$PY" -B - "$PACK_STAGING/flashcat_strata.py" <<'PY'
import ast, sys
ast.parse(open(sys.argv[1], "rb").read(), filename=sys.argv[1])
print("    flashcat_strata.py parses")
PY

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
  "entrypoint": "python/bin/python3",
  "workingDirectory": ".",
  "modelsSubdirectory": "models",
  "launchProfiles": {
    "default": {
      "args": [
        "-u", "flashcat_strata.py",
        "--strata-root", "{root}",
        "--model-path", "{modelPath}",
        "--model-id", "{modelID}",
        "--models", "{models}",
        "--support", "{support}",
        "--port", "{port}"
      ],
      "environment": {
        "PYTHONNOUSERSITE": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONUNBUFFERED": "1"
      }
    }
  },
  "health": { "path": "/health", "readyStatus": 200 },
  "status": ["/v1/status"],
  "models": { "path": "/v1/models" },
  "defaultPort": $DEFAULT_PORT,
  "modelSwitch": "restart",
  "modelArgument": "path",
  "capabilities": [
    "chat", "streaming", "vision", "reasoning", "single-model", "mtp", "tool-use"
  ],
  "adapter": "strata",
  "startupTimeout": 1800,
  "portRangeSize": 20,
  "modelLayout": "external",
  "telemetry": [
    { "role": "health", "path": "/health", "format": "strata.health" },
    { "role": "status", "path": "/v1/status", "format": "strata.status" },
    { "role": "metrics", "path": "/metrics", "format": "strata.metrics" },
    { "role": "props", "path": "/props", "format": "llama.props" },
    { "role": "inventory", "path": "/v1/models", "format": "openai.models" }
  ],
  "license": "MIT"
}
EOF
pack_validate_manifest /usr/bin/python3

pack_clean_artifacts

pack_swap

pack_print_summary
printf '    control   : %s\n' "$CONTROL_NAME"
printf '    engine    : %s\n' "$ENGINE_NAME_ASSET"

pack_next_release_cmd "$MIN_MACOS"
