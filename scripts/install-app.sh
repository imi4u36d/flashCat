#!/bin/bash
# Install a flashCat.app bundle into /Applications and make it the only copy.
#
#   scripts/install-app.sh [APP_PATH]
#
# Environment:
#   PREFIX=/Applications     install destination
#   VERSION=1.0.0            recorded in the backup name (defaults to VERSION file)
#   LAUNCH=1                 open the installed app after installing
#   STOP_SERVER=1            also stop leftover inference servers (port 8000)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-/Applications}"
TARGET="$PREFIX/flashCat.app"
VERSION="${VERSION:-$("$ROOT/scripts/version.sh")}"

EXE_NAME="flashCat"

# dist/flashCat.app is the staging bundle; after an install it is parked in
# dist/.build/ so nobody double-clicks a second copy of the app.
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

if [ ! -d "$APP/Contents/MacOS" ]; then
    echo "error: $APP is not an app bundle; run make app first" >&2
    exit 1
fi

if [ ! -w "$PREFIX" ]; then
    echo "error: $PREFIX is not writable; install with sudo or change PREFIX" >&2
    exit 1
fi

# 1. Stop the running copies so the new install launches cleanly.
echo "==> Stop running flashCat instances"
pids="$(pgrep -f "$APP/Contents/MacOS/$EXE_NAME" || true)"
pids="$pids $(pgrep -f "$TARGET/Contents/MacOS/$EXE_NAME" || true)"
if [ -n "${pids// /}" ]; then
    kill $pids 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        alive=""
        for pid in $pids; do
            kill -0 "$pid" 2>/dev/null && alive="$alive $pid"
        done
        [ -n "${alive// /}" ] || break
        sleep 1
    done
    kill -9 $pids 2>/dev/null || true
    echo "     stopped: ${pids// /}"
else
    echo "     none running"
fi

# 2. Optional: clear orphan inference servers left by an earlier run.
if [ "${STOP_SERVER:-0}" = "1" ]; then
    servers="$(pgrep -f "server.server" || true)"
    if [ -n "${servers// /}" ]; then
        echo "==> Stop inference servers: ${servers// /}"
        kill $servers 2>/dev/null || true
    fi
fi

# 3. Park the previous install as a backup so a failed copy can be rolled back.
#    Pruning older backups is deferred to the end: it is bookkeeping, and a
#    failure there (permissions, a locked bundle, an interrupted process) used
#    to abort the script *after* the old app was moved aside but *before* the
#    new one landed — leaving the prefix with no flashCat.app at all.
BACKUP=""
if [ -e "$TARGET" ]; then
    BACKUP="$PREFIX/.flashCat-previous-$(date +%Y%m%d-%H%M%S).app"
    mv "$TARGET" "$BACKUP"
    echo "==> Previous install moved to $BACKUP"
fi

INSTALL_OK=0
restore_on_exit() {
    status=$?
    if [ "$INSTALL_OK" = "1" ] || [ -z "$BACKUP" ] || [ ! -e "$BACKUP" ]; then
        return $status
    fi
    rm -rf "$TARGET" 2>/dev/null || true
    if mv "$BACKUP" "$TARGET"; then
        echo "error: install failed; the previous bundle was put back" >&2
    else
        echo "error: install failed and the previous bundle is at $BACKUP" >&2
    fi
    return $status
}
trap restore_on_exit EXIT

# 4. Install.
echo "==> Install $APP -> $TARGET"
cp -R "$APP" "$TARGET"

# 5. Ad-hoc signatures and a fresh copy out of a build directory carry no
#    quarantine, but clear it anyway so Gatekeeper does not block the launch.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

if codesign --verify --deep --strict "$TARGET" >/dev/null 2>&1; then
    echo "     signature verified"
else
    codesign --force --deep --sign - "$TARGET" >/dev/null 2>&1 \
        && echo "     re-signed (ad-hoc)" \
        || echo "warning: could not verify or re-sign the bundle" >&2
fi

# 6. Report what landed.
INSTALLED_VERSION="$(plutil -extract CFBundleShortVersionString raw "$TARGET/Contents/Info.plist" 2>/dev/null || echo unknown)"
SIZE="$(du -sh "$TARGET" | cut -f1)"
echo "==> Installed flashCat $INSTALLED_VERSION to $TARGET ($SIZE)"
INSTALL_OK=1

# 6b. Bookkeeping only, now that the new bundle is in place: drop older
#     backups. Never fatal — a leftover backup costs disk, a missing app costs
#     the install.
if [ -n "$BACKUP" ]; then
    for old in "$PREFIX"/.flashCat-previous-*.app; do
        [ -e "$old" ] || continue
        [ "$old" = "$BACKUP" ] && continue
        rm -rf "$old" 2>/dev/null || echo "note: could not remove old backup $old"
    done
fi

if [ "${LAUNCH:-0}" = "1" ]; then
    open "$TARGET"
    sleep 4
    if pgrep -f "$TARGET/Contents/MacOS/$EXE_NAME" >/dev/null; then
        echo "     launched"
    else
        echo "warning: the installed app did not stay running" >&2
        exit 1
    fi
fi

# 7. Warn about inference servers left behind by an earlier run, which is the
#    usual reason the app later reports the port as occupied.
PORT="${PORT:-8000}"
holder="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
if [ -n "${holder// /}" ]; then
    echo "note: port $PORT is still held by an older inference server (PID ${holder// /})"
    echo "      kill $holder, or choose another port in flashCat Settings."
fi
