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

# vendor/ is gitignored and therefore absent in a fresh checkout; without this
# the first `curl -o` fails with "No such file or directory".
mkdir -p "$ROOT/vendor"

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

# The archive wraps everything in a single top-level directory, and bsdtar
# matches the member name *before* stripping components, so the pattern needs
# the leading `*/`. Extract into a scratch directory instead of piping `tar -O`:
# that way a missing or unreadable release.json is a real, visible error instead
# of an empty variable that quietly makes the comparison below fail.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/splash-release.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
tar -xzf "$ROOT/vendor/$ARCHIVE" -C "$TMP" --strip-components=1 '*/release.json'
EMBEDDED="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$TMP/release.json" | head -1)"
[ -n "$EMBEDDED" ] || {
    echo "error: release.json inside $ARCHIVE has no \"version\" field" >&2
    exit 1
}
echo "==> vendor/$ARCHIVE ($ACTUAL), release.json version: $EMBEDDED"
if [ "$EMBEDDED" != "$VERSION" ]; then
    echo "error: release.json reports $EMBEDDED, not $VERSION (refusing a mismatched archive)" >&2
    exit 1
fi
