#!/usr/bin/env bash
# Package a locally built runtime pack into a distributable archive plus the
# index entry the in-app installer consumes.
#
#   scripts/engines/make-pack-release.sh --engine omlx --version 0.7.2
#   scripts/engines/make-pack-release.sh --engine mtplx --version 2.12.2 --out dist/packs
#   scripts/engines/make-pack-release.sh --engine splash --version 1.4.0 --base-url https://host/packs
#
# Output (both optional to keep, the JSON is what you paste into pack-index.json):
#   dist/packs/<engine>-<version>-arm64-macos<min>.tar.gz
#   dist/packs/<engine>-<version>.sha256
#   dist/packs/<engine>-<version>.release.json   ← one EnginePackRelease object
#
# The archive has a single top-level directory (`<engine>-<version>/`), which is
# exactly the layout EngineInstaller detects and strips. Nothing here downloads
# anything: it only re-packs `vendor/engines/<engine>/<version>`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE=""
VERSION=""
OUT="$ROOT/dist/packs"
BASE_URL=""
MIN_MACOS="26.0"

while [ $# -gt 0 ]; do
  case "$1" in
    --engine)     ENGINE="$2"; shift 2 ;;
    --version)    VERSION="$2"; shift 2 ;;
    --out)        OUT="$2"; shift 2 ;;
    --base-url)   BASE_URL="$2"; shift 2 ;;
    --min-macos)  MIN_MACOS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$ENGINE" ] || [ -z "$VERSION" ]; then
  echo "usage: $0 --engine <omlx|mtplx|splash> --version <x.y.z> [--out DIR] [--base-url URL]" >&2
  exit 2
fi

SRC="$ROOT/vendor/engines/$ENGINE/$VERSION"
if [ ! -f "$SRC/manifest.json" ]; then
  echo "no pack at $SRC — build it first with scripts/engines/build-$ENGINE-pack.sh" >&2
  exit 1
fi

mkdir -p "$OUT"
NAME="$ENGINE-$VERSION"
ARCHIVE="$OUT/$NAME-arm64-macos$MIN_MACOS.tar.gz"

# Stage under the archive's own name so the tarball has one top-level folder.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -a "$SRC" "$STAGE/$NAME"

echo "==> packing $NAME"
/usr/bin/tar -czf "$ARCHIVE" -C "$STAGE" "$NAME"

SHA="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
BYTES="$(stat -f%z "$ARCHIVE")"
printf '%s  %s\n' "$SHA" "$(basename "$ARCHIVE")" > "$OUT/$NAME.sha256"

URL="${BASE_URL%/}/$(basename "$ARCHIVE")"
cat > "$OUT/$NAME.release.json" <<JSON
{
  "version": "$VERSION",
  "url": "$URL",
  "sha256": "$SHA",
  "bytes": $BYTES,
  "minMacOS": "$MIN_MACOS",
  "notes": ""
}
JSON

echo "==> $(basename "$ARCHIVE")"
echo "    sha256  $SHA"
echo "    bytes   $BYTES"
echo "    url     $URL"
echo
echo "Index entry (merge into pack-index.json → engines.\"$ENGINE\"):"
cat "$OUT/$NAME.release.json"
