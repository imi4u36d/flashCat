#!/usr/bin/env bash
# Collect the `.release.json` files produced by make-pack-release.sh into the
# pack index the app reads (FLASHCAT_PACK_INDEX_URL, or the copy bundled in
# flashCat.app/Contents/Resources/pack-index.json).
#
#   scripts/engines/make-pack-index.sh
#   scripts/engines/make-pack-index.sh --packs dist/packs --base-url https://host/packs
#   scripts/engines/make-pack-index.sh --out pack-index.json --base-url https://host/packs
#
# The engine id comes from the file name (`<engine>-<version>.release.json`), so
# a release file is self-describing; `--base-url` rewrites every `url` to point
# at that prefix, which is what you want after uploading the archives.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKS="$ROOT/dist/packs"
OUT="$ROOT/pack-index.json"
BASE_URL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --packs)    PACKS="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ ! -d "$PACKS" ]; then
  echo "error: no pack directory at $PACKS" >&2
  echo "       build one first: scripts/engines/make-pack-release.sh --engine <id> --version <x.y.z>" >&2
  exit 1
fi

shopt -s nullglob
RELEASES=("$PACKS"/*.release.json)
shopt -u nullglob
if [ ${#RELEASES[@]} -eq 0 ]; then
  echo "error: no *.release.json under $PACKS" >&2
  exit 1
fi

PACKS="$PACKS" OUT="$OUT" BASE_URL="$BASE_URL" python3 - "${RELEASES[@]}" <<'PY'
import json, os, re, sys

packs_dir = os.environ["PACKS"]
base_url = os.environ.get("BASE_URL", "").rstrip("/")
engines = {}

def version_key(version):
    # Numeric-aware, with pre-releases ordered before their final release so the
    # app's "latest" and this index agree.
    parts = re.split(r"[.\-+]", version)
    key = []
    for part in parts:
        key.append((0, int(part)) if part.isdigit() else (1, part))
    return key

for path in sys.argv[1:]:
    name = os.path.basename(path)
    match = re.match(r"(.+)-(\d+.*)\.release\.json$", name)
    if not match:
        print(f"skip {name}: expected <engine>-<version>.release.json", file=sys.stderr)
        continue
    engine, version = match.group(1), match.group(2)
    with open(path, "r", encoding="utf-8") as handle:
        entry = json.load(handle)
    entry.setdefault("version", version)
    if base_url:
        entry["url"] = f"{base_url}/{os.path.basename(entry.get('url', ''))}"
    engines.setdefault(engine, []).append(entry)

for engine, entries in engines.items():
    entries.sort(key=lambda item: version_key(item["version"]), reverse=True)

index = {"schemaVersion": 1, "engines": engines}
out = os.environ["OUT"]
os.makedirs(os.path.dirname(os.path.abspath(out)) or ".", exist_ok=True)
with open(out, "w", encoding="utf-8") as handle:
    json.dump(index, handle, ensure_ascii=False, indent=2)
    handle.write("\n")

for engine in sorted(engines):
    versions = ", ".join(item["version"] for item in engines[engine])
    print(f"    {engine}: {versions}")
print(f"==> {out}")
PY
