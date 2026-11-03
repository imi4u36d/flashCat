#!/usr/bin/env bash
#
# Build a self-contained Strata runtime pack for Apple Silicon:
#   <out>/strata/<app-version>/
#     python/ ... bin/strata  (official control archive)
#     engine/ ...             (official Metal engine component)
#     flashcat_strata.py      (foreground lifecycle adapter)
#
# Usage:
#   scripts/engines/build-strata-pack.sh [--version 0.2.10] [--out DIR] [--force]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

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
  -h, --help      show this help
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done
[[ "$VERSION" != v* ]] || VERSION="${VERSION#v}"
[[ -f "$WRAPPER" ]] || die "wrapper missing: $WRAPPER"

mkdir -p "$ROOT/vendor"
API_JSON="$(mktemp "${TMPDIR:-/tmp}/strata-release.XXXXXX.json")"
trap 'rm -f "$API_JSON"' EXIT
step "Resolving Strata $VERSION release assets"
curl -fsSL --retry 2 -o "$API_JSON" \
  "https://api.github.com/repos/$UPSTREAM_REPO/releases/tags/v$VERSION"
ASSETS="$(/usr/bin/python3 - "$API_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    release = json.load(handle)
control = engine = None
for asset in release.get("assets", []):
    name = asset.get("name", "")
    digest = asset.get("digest") or ""
    row = (name, asset.get("browser_download_url", ""), digest.split(":", 1)[-1])
    if name.startswith("strata-control-") and name.endswith("-macos-arm64.tar.gz"):
        control = row
    elif name.startswith("strata-engine-") and name.endswith("-macos-arm64-metal.tar.gz"):
        engine = row
if not control or not engine:
    raise SystemExit("missing control or Metal engine asset")
print("\t".join(control))
print("\t".join(engine))
PY
)" || die "could not resolve release assets"
rm -f "$API_JSON"
trap - EXIT

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

mkdir -p "$OUT"
OUT="$(cd -- "$OUT" && pwd -P)"
PACK_DIR="$OUT/$ENGINE_ID/$VERSION"
if [[ -e "$PACK_DIR" ]]; then
  [[ $FORCE -eq 1 ]] || die "$PACK_DIR already exists (pass --force)"
  rm -rf "$PACK_DIR"
fi
mkdir -p "$PACK_DIR"

step "Extracting Strata control and Metal engine"
tar -xzf "$CONTROL_TGZ" -C "$PACK_DIR"
mkdir -p "$PACK_DIR/engine"
tar -xzf "$ENGINE_TGZ" -C "$PACK_DIR/engine"
chmod -R u+w "$PACK_DIR"
cp -a "$WRAPPER" "$PACK_DIR/flashcat_strata.py"

for required in python/bin/python3 bin/strata setup.py flashcat_strata.py \
                engine/strata engine/strata-vision engine/engine-component.json; do
  [[ -e "$PACK_DIR/$required" ]] || die "pack incomplete: missing $required"
done

step "Verifying bundled Python and Strata CLI"
PY="$PACK_DIR/python/bin/python3"
"$PY" -B -VV
PYTHONPATH="$PACK_DIR" STRATA_INSTALL_DIR="$PACK_DIR/.runtime-check" \
  "$PACK_DIR/bin/strata" --version
rm -rf "$PACK_DIR/.runtime-check"
"$PY" -B - "$PACK_DIR/flashcat_strata.py" <<'PY'
import ast, sys
ast.parse(open(sys.argv[1], "rb").read(), filename=sys.argv[1])
print("    flashcat_strata.py parses")
PY

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
/usr/bin/python3 -m json.tool "$PACK_DIR/manifest.json" >/dev/null

find "$PACK_DIR" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$PACK_DIR" -name '.DS_Store' -delete

step "Pack summary"
printf '    path: %s\n' "$PACK_DIR"
printf '    size: %s\n' "$(du -sh "$PACK_DIR" | awk '{print $1}')"
printf '    control: %s\n' "$CONTROL_NAME"
printf '    engine: %s\n' "$ENGINE_NAME_ASSET"

cat <<EOF

Next:
  scripts/engines/make-pack-release.sh --engine $ENGINE_ID --version $VERSION --min-macos $MIN_MACOS
EOF
