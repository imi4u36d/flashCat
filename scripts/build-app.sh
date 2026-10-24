#!/bin/bash
# Build the Flutter client, assemble a self-contained flashCat.app, produce the
# installers, and install the app into /Applications.
#
#   INSTALL=0 make app     keep the bundle in dist/ only, do not install
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
INSTALL="${INSTALL:-1}"
SPLASH_VERSION="${SPLASH_VERSION:-1.4.0}"
# macOS 26.4 is the floor splash's native engine enforces (see splash Makefile).
MIN_MACOS="${MIN_MACOS:-26.4}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
RUNTIME_TARBALL="${RUNTIME_TARBALL:-$ROOT/vendor/splash-$SPLASH_VERSION-arm64-macos26.tar.gz}"
BUILT_APP="$ROOT/build/macos/Build/Products/Release/flashCat.app"
APP="$OUT_DIR/flashCat.app"

[ -f "$RUNTIME_TARBALL" ] || {
    echo "error: missing runtime archive: $RUNTIME_TARBALL" >&2
    echo "       put splash-$SPLASH_VERSION-arm64-macos26.tar.gz in vendor/" >&2
    echo "       or set SPLASH_VERSION / RUNTIME_TARBALL explicitly" >&2
    exit 1
}

if [ -f "$RUNTIME_TARBALL.sha256" ]; then
    EXPECTED="$(cut -d' ' -f1 < "$RUNTIME_TARBALL.sha256")"
    ACTUAL="$(shasum -a 256 "$RUNTIME_TARBALL" | cut -d' ' -f1)"
    [ "$EXPECTED" = "$ACTUAL" ] || {
        echo "error: runtime archive checksum mismatch" >&2
        echo "       expected $EXPECTED" >&2
        echo "       actual   $ACTUAL" >&2
        exit 1
    }
    echo "==> Runtime archive checksum verified ($ACTUAL)"
fi

EMBEDDED_VERSION="$(tar -xzf "$RUNTIME_TARBALL" -O "splash-$SPLASH_VERSION-arm64-macos26/release.json" 2>/dev/null \
    | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -1)"
if [ -z "$EMBEDDED_VERSION" ]; then
    echo "error: $RUNTIME_TARBALL has no release.json with a version" >&2
    exit 1
fi
if [ "$EMBEDDED_VERSION" != "$SPLASH_VERSION" ]; then
    echo "error: runtime archive reports splash $EMBEDDED_VERSION, expected $SPLASH_VERSION" >&2
    echo "       the archive was built with a RELEASE_VERSION that does not match its name" >&2
    exit 1
fi
echo "==> splash runtime: $EMBEDDED_VERSION"

echo "==> Flutter release build"
flutter build macos --release \
    --build-name "$VERSION" \
    --build-number "$BUILD_NUMBER"

[ -d "$BUILT_APP" ] || {
    echo "error: Flutter did not produce $BUILT_APP" >&2
    exit 1
}

echo "==> Assemble $APP"
mkdir -p "$OUT_DIR"
if [ -e "$APP" ]; then
    PREVIOUS="$OUT_DIR/.previous-flashCat-$(date +%s).app"
    mv "$APP" "$PREVIOUS"
    for old in "$OUT_DIR"/.previous-flashCat-*.app; do
        [ -e "$old" ] || continue
        [ "$old" = "$PREVIOUS" ] && continue
        rm -rf "$old"
    done
fi
mkdir -p "$APP"
rsync -a "$BUILT_APP/" "$APP/"

echo "==> Embed splash runtime"
mkdir -p "$APP/Contents/Resources/runtime"
tar -xzf "$RUNTIME_TARBALL" --strip-components=1 -C "$APP/Contents/Resources/runtime"
cp "$ROOT/runtime/flashcat_serve.py" "$APP/Contents/Resources/flashcat_serve.py"
chmod +x "$APP/Contents/Resources/flashcat_serve.py"

echo "==> Generate app icon"
ICONSET="$OUT_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
PYTHON=""
for candidate in "$APP/Contents/Resources/runtime/python/bin/python3" python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import PIL' >/dev/null 2>&1; then
        PYTHON="$candidate"
        break
    fi
done
if [ -n "$PYTHON" ] && "$PYTHON" "$ROOT/scripts/make-icon.py" "$ICONSET" >/dev/null 2>&1 \
    && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
    echo "     AppIcon.icns"
else
    echo "warning: icon generation failed; keeping Flutter's default app icon" >&2
fi

echo "==> Normalize application metadata"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$MIN_MACOS" "$APP/Contents/Info.plist"
plutil -replace CFBundleIconFile -string "AppIcon" "$APP/Contents/Info.plist"
plutil -remove LSUIElement "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Ad-hoc sign"
if codesign --force --deep --sign - "$APP" >/dev/null 2>&1; then
    if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
        echo "     signature verified"
    fi
else
    echo "warning: ad-hoc signing failed" >&2
fi

SIZE="$(du -sh "$APP" | cut -f1)"
echo "==> Built $APP ($SIZE)"

echo "==> Installers"
VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" "$ROOT/scripts/make-installer.sh" "$APP"

if [ "$INSTALL" = "1" ]; then
    echo "==> Install to /Applications"
    "$ROOT/scripts/install-app.sh" "$APP"
    STAGED="$OUT_DIR/.build/flashCat.app"
    mkdir -p "$OUT_DIR/.build"
    rm -rf "$STAGED"
    mv "$APP" "$STAGED"
    echo "    Staging bundle moved to $STAGED (dev copy only)."
    echo "    Use the installed app:  open /Applications/flashCat.app"
    echo "    Do not run both copies at once; that is what leaves port 8000 taken."
else
    echo "    INSTALL=0: not installed. Open it with: open \"$APP\""
fi
