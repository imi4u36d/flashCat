#!/bin/bash
# Single source of truth for the release version.
#
# VERSION at the repository root is the only place the human edits. Everything
# else — Makefile, build-native-app.sh, install-app.sh, CI — reads it from here,
# so `./scripts/build-native-app.sh` can no longer produce a bundle whose
# CFBundleShortVersionString disagrees with the git tag.
#
#   scripts/version.sh           1.4.2
#   scripts/version.sh --build   412      (monotonic commit count, for CFBundleVersion)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

read_version() {
    local file="$ROOT/VERSION"
    [ -f "$file" ] || { echo "error: $file is missing" >&2; exit 1; }
    local value
    value="$(tr -d '[:space:]' < "$file")"
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "error: VERSION must look like 1.2.3, got '$value'" >&2
        exit 1
    }
    printf '%s' "$value"
}

read_build_number() {
    local count
    count="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
    printf '%s' "$count"
}

case "${1:-}" in
    --build) read_build_number ;;
    --tag)   printf 'v%s' "$(read_version)" ;;
    "")      read_version ;;
    *)       echo "usage: scripts/version.sh [--build|--tag]" >&2; exit 2 ;;
esac
