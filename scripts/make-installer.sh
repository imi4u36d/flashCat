#!/bin/bash
# Produce the distributable installers for a built flashCat.app.
#
#   scripts/make-installer.sh [APP_PATH]
#
# dist/flashCat-<version>.pkg  double-click installs straight into /Applications
# dist/flashCat-<version>.dmg  the drag-to-Applications image for distribution
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
IDENTIFIER="${IDENTIFIER:-com.zhuo.flashCat}"

APP="${1:-}"
if [ -z "$APP" ]; then
    for candidate in "$ROOT/dist/flashCat.app" "$ROOT/dist/.build/flashCat.app"; do
        if [ -d "$candidate/Contents/MacOS" ]; then
            APP="$candidate"
            break
        fi
    done
fi
APP="${APP:-$ROOT/dist/flashCat.app}"

[ -d "$APP/Contents/MacOS" ] || {
    echo "error: $APP is not an app bundle; run make app first" >&2
    exit 1
}
mkdir -p "$OUT_DIR"

echo "==> Installer package"
if command -v pkgbuild >/dev/null 2>&1; then
    PKG="$OUT_DIR/flashCat-$VERSION.pkg"
    PAYLOAD="$OUT_DIR/.pkg-payload"
    rm -rf "$PAYLOAD"
    mkdir -p "$PAYLOAD"
    cp -R "$APP" "$PAYLOAD/flashCat.app"
    # The pkg is the one install path that can put `flashcat` on PATH without
    # asking the user to run anything. The postinstall is best effort: a
    # read-only /usr/local/bin must not fail the application install.
    SCRIPTS="$OUT_DIR/.pkg-scripts"
    rm -rf "$SCRIPTS"
    mkdir -p "$SCRIPTS"
    cat > "$SCRIPTS/postinstall" <<'POSTINSTALL'
#!/bin/bash
set -e
TARGET="/Applications/flashCat.app/Contents/Helpers/flashcat"
if [ -x "$TARGET" ] && [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    ln -sfn "$TARGET" /usr/local/bin/flashcat 2>/dev/null || true
fi
exit 0
POSTINSTALL
    chmod +x "$SCRIPTS/postinstall"
    pkgbuild \
        --identifier "$IDENTIFIER" \
        --version "$VERSION" \
        --install-location /Applications \
        --root "$PAYLOAD" \
        --scripts "$SCRIPTS" \
        "$PKG"
    rm -rf "$PAYLOAD" "$SCRIPTS"
    echo "     $PKG ($(du -sh "$PKG" | cut -f1), double-click installs into /Applications)"
else
    echo "warning: pkgbuild not available; skipped the .pkg installer" >&2
fi

echo "==> Disk image"
if command -v hdiutil >/dev/null 2>&1; then
    DMG="$OUT_DIR/flashCat-$VERSION.dmg"
    hdiutil create -volname "flashCat" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
    echo "     $DMG ($(du -sh "$DMG" | cut -f1))"
else
    echo "warning: hdiutil not available; skipped the .dmg" >&2
fi
