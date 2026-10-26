#!/bin/bash
# Build the native macOS client (SwiftUI + AppKit) and assemble a self-contained
# flashCat.app that carries the splash inference runtime inside it.
#
#   INSTALL=0 ./scripts/build-native-app.sh      keep the bundle in dist/ only
#   VERSION=1.1.0 ./scripts/build-native-app.sh  override the bundle version
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
INSTALL="${INSTALL:-1}"
SPLASH_VERSION="${SPLASH_VERSION:-1.4.0}"
IDENTIFIER="${IDENTIFIER:-com.zhuo.flashCat}"
# macOS 26.4 is the floor splash's native engine enforces.
MIN_MACOS="${MIN_MACOS:-26.4}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
APP="$OUT_DIR/flashCat.app"
RUNTIME_TARBALL="${RUNTIME_TARBALL:-$ROOT/vendor/splash-$SPLASH_VERSION-arm64-macos26.tar.gz}"
NATIVE_DIR="$ROOT/native"

command -v swift >/dev/null 2>&1 || {
    echo "error: swift toolchain not found" >&2
    exit 1
}

[ -f "$RUNTIME_TARBALL" ] || {
    echo "error: missing runtime archive: $RUNTIME_TARBALL" >&2
    echo "       run ./scripts/fetch-runtime.sh $SPLASH_VERSION" >&2
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
    exit 1
fi
echo "==> splash runtime: $EMBEDDED_VERSION"

echo "==> Swift release build"
( cd "$NATIVE_DIR" && swift build -c release --disable-sandbox )
BINARY="$NATIVE_DIR/.build/release/flashCat"
[ -x "$BINARY" ] || {
    echo "error: swift build did not produce $BINARY" >&2
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/flashCat"
chmod +x "$APP/Contents/MacOS/flashCat"

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
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import PIL, numpy' >/dev/null 2>&1; then
        PYTHON="$candidate"
        break
    fi
done
if [ -n "$PYTHON" ] && "$PYTHON" "$ROOT/scripts/make-icon.py" "$ICONSET" >/dev/null 2>&1 \
    && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
    echo "     AppIcon.icns"
else
    echo "warning: icon generation failed; the app will use the default icon" >&2
fi

echo "==> Write Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>flashCat</string>
    <key>CFBundleExecutable</key>
    <string>flashCat</string>
    <key>CFBundleIdentifier</key>
    <string>$IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>flashCat</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key>
    <string>本地推理控制台</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST
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
