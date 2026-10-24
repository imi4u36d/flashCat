#!/bin/bash
# Download the official splash runtime archive (and its checksum) into vendor/.
#
#   ./scripts/fetch-runtime.sh            latest release
#   ./scripts/fetch-runtime.sh 1.4.0      a specific release
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-${SPLASH_VERSION:-}}"

if [ -z "$VERSION" ]; then
    VERSION="$(curl -fsSL https://api.github.com/repos/incoai/splash/releases/latest \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
fi
[ -n "$VERSION" ] || {
    echo "error: could not determine the latest splash release" >&2
    exit 1
}

ARCHIVE="splash-$VERSION-arm64-macos26.tar.gz"
URL="https://github.com/incoai/splash/releases/download/$VERSION/$ARCHIVE"

echo "==> Downloading $URL"
curl -fsSL -o "$ROOT/vendor/$ARCHIVE" "$URL"
curl -fsSL -o "$ROOT/vendor/$ARCHIVE.sha256" "$URL.sha256"

EXPECTED="$(cut -d' ' -f1 < "$ROOT/vendor/$ARCHIVE.sha256")"
ACTUAL="$(shasum -a 256 "$ROOT/vendor/$ARCHIVE" | cut -d' ' -f1)"
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "error: checksum mismatch for $ARCHIVE" >&2
    echo "       expected $EXPECTED" >&2
    echo "       actual   $ACTUAL" >&2
    exit 1
fi

EMBEDDED="$(tar -xzf "$ROOT/vendor/$ARCHIVE" -O "$ARCHIVE/release.json" 2>/dev/null \
    | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -1)"
echo "==> vendor/$ARCHIVE ($ACTUAL), release.json version: $EMBEDDED"
if [ "$EMBEDDED" != "$VERSION" ]; then
    echo "warning: release.json reports $EMBEDDED, not $VERSION" >&2
    exit 1
fi
