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
DMG="$OUT_DIR/flashCat-$VERSION.dmg"
DMG_LOG_FILE="${TMPDIR:-/tmp}/flashcat-dmg.log"
: > "$DMG_LOG_FILE"
# 造镜像要新建一块临时 APFS 卷，依赖「能写原始磁盘」这个权限：受限沙箱里
# newfs_apfs 直接 EPERM，hdiutil 只会丢一句「目录非空」，看不出真因。这里把
# 真正的原因捞出来打给人看，并把「dmg 必须存在」交给 FLASHCAT_REQUIRE_DMG
# 决定：发布机器上设成 1，产物缺了就退出非零。
dmg_cause() {
    grep -iE "operation not permitted|not permitted|no space left|denied|OSStatus error|create failed" "$DMG_LOG_FILE" | tail -1
}
create_dmg() {
    # 卷根必须是「flashCat.app + Applications 链接」，拖进去就能装。
    # 直接把 .app 路径交给 `diskutil image create from` 会把 bundle 的
    # Contents 摊到卷根（1.5.5 发的 dmg 就这样，打开只看到一个 Contents
    # 文件夹），所以先搭一个只含 app 和链接的暂存目录，两种命令都指向它。
    local root="$OUT_DIR/.dmg-root"
    rm -rf "$root"
    mkdir -p "$root"
    cp -R "$APP" "$root/flashCat.app"
    ln -sfn /Applications "$root/Applications"
    local ok=1
    # macOS 27 起 `hdiutil create` 已标记弃用，官方替代是 diskutil；旧系统没有
    # 这个子命令，所以先试 diskutil，再退回 hdiutil。
    if command -v diskutil >/dev/null 2>&1 \
        && diskutil image create from "$root" --volumeName "flashCat" --format UDZO "$DMG" >>"$DMG_LOG_FILE" 2>&1; then
        ok=0
    elif command -v hdiutil >/dev/null 2>&1; then
        # 上一次没卸载干净的卷会让 hdiutil 直接失败，先摘掉。
        hdiutil detach "/Volumes/flashCat" -force >/dev/null 2>&1 || true
        if hdiutil create -volname "flashCat" -srcfolder "$root" -ov \
                -format UDZO "$DMG" >>"$DMG_LOG_FILE" 2>&1; then
            ok=0
        # 卷名被别的镜像占着时，换一次性卷名再试一次。
        elif hdiutil create -volname "flashCat-$$" -srcfolder "$root" -ov \
                -format UDZO "$DMG" >>"$DMG_LOG_FILE" 2>&1; then
            ok=0
        fi
    else
        echo "hdiutil not available" >>"$DMG_LOG_FILE"
    fi
    rm -rf "$root"
    return $ok
}
if create_dmg; then
    echo "     $DMG ($(du -sh "$DMG" | cut -f1))"
    rm -f "$DMG_LOG_FILE"
else
    # grep 没匹配到原因时返回 1；`set -e` 下直接赋值会让脚本静默退出，
    # 连下面「只警告」的分支都走不到。这里显式兜底。
    cause="$(dmg_cause || true)"
    rm -f "$DMG" "$DMG_LOG_FILE" 2>/dev/null || true
    if [ "${FLASHCAT_REQUIRE_DMG:-0}" = "1" ]; then
        echo "error: .dmg 未生成${cause:+（${cause}）}。发布要求 .pkg 与 .dmg 同时在 dist/。" >&2
        exit 1
    fi
    echo "warning: .dmg 未生成${cause:+（${cause}）}，.pkg 不受影响。" >&2
    echo "         受限沙箱里造镜像要写原始磁盘；发布时设 FLASHCAT_REQUIRE_DMG=1 并在有权限的会话重跑。" >&2
fi
