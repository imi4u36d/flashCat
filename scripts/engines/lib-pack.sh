#!/usr/bin/env bash
#
# Shared scaffolding for the pack builders in this directory. Sourced, never
# executed: the five build-*-pack.sh scripts each `source` it right after
# `set -euo pipefail`, so a pack build behaves the same way no matter which
# engine it targets.
#
# What lives here is only what was byte-for-byte identical in all five scripts:
# path discovery, die/step/elapsed, the common option loop, the target path and
# --force gate, staging + atomic swap, manifest JSON validation, artifact
# cleanup, rpath rewriting, the summary, and the "what do I run next" hint.
#
# What deliberately stays in the per-engine scripts:
#   * download + verification strategy — the five upstreams are genuinely
#     different (GitHub release tarball with a resolved digest, Control+Metal
#     assets from a release API, a PyPI cp313 CLI, a cp311 wheel, a hand-placed
#     tarball with a sidecar sha256). Unifying them would change when and how a
#     build refuses to run, which is not a refactor.
#   * the manifest heredocs — the field set IS the engine difference.
#   * engine self-checks (ast.parse of the wrapper, launchProfiles shape, the
#     precompiled .so fingerprint, entrypoint existence).
#
# Contract for callers: `set -euo pipefail`, then define ENGINE_ID, ENGINE_NAME,
# DEFAULT_VERSION, DEFAULT_OUT, DEFAULT_PORT, VERSION, OUT, FORCE and usage(),
# then call pack_parse_common_args "$@" and pack_begin.

# Directory of this library (= scripts/engines) and the repo root. Derived from
# BASH_SOURCE so callers no longer repeat the two `cd -- "$(dirname ...)"` lines;
# ROOT stays overridable so lib-pack-selftest.sh can point it at a scratch tree.
PACK_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(cd -- "$PACK_LIB_DIR/../.." && pwd)}"

DRY_RUN=0
PACK_STAGING=""
PACK_ARG_SHIFT=""
PACK_CLEANUP=()

# --------------------------------------------------------------------- output

pack_die() { printf 'error: %s\n' "$*" >&2; exit 1; }
pack_step() { printf '\n==> %s\n' "$*"; }
pack_elapsed() { printf '    (%.1fs)\n' "$(( $(date +%s) - $1 ))"; }

# The scripts already call die/step/elapsed in a few hundred places; keep the
# short names as thin aliases so this refactor's diff is the behaviour change
# (staging + swap) and not a mechanical rename that hides it.
die() { pack_die "$@"; }
step() { pack_step "$@"; }
elapsed() { pack_elapsed "$@"; }

# ------------------------------------------------------------ temp path cleanup

# Each script used to install its own `trap '...' EXIT`. EXIT traps overwrite
# each other, so two of the scripts had to `trap - EXIT` by hand after their
# temporary file was gone. One registry, one trap: whoever creates a path
# registers it and it is removed on every exit path (die, set -e, success).
pack_cleanup_add() { PACK_CLEANUP[${#PACK_CLEANUP[@]}]="$1"; }

pack_cleanup() {
  local path
  for path in ${PACK_CLEANUP[@]+"${PACK_CLEANUP[@]}"}; do
    [[ -n "$path" ]] || continue
    rm -rf -- "$path" || true
  done
}

trap 'pack_cleanup' EXIT

# ---------------------------------------------------------- tools and options

# Fail before the download, not in the middle of it, when a tool is missing.
# An absolute path is checked for the executable bit; a bare name is resolved
# through PATH.
pack_require_tools() {
  local tool
  for tool in "$@"; do
    case "$tool" in
      */*) [[ -x "$tool" ]] || pack_die "required tool is missing: $tool" ;;
      *) command -v "$tool" >/dev/null 2>&1 || pack_die "required tool is missing: $tool" ;;
    esac
  done
}

# Default engine-specific option parser: match nothing. Scripts override it and,
# when they consume an option, set PACK_ARG_SHIFT to the number of arguments
# eaten (1 for a flag, 2 for an option with a value) and return 0.
pack_parse_engine_arg() { return 1; }

# The option loop shared by all five scripts. Handles the flags every builder
# understands and delegates everything else to the engine hook above.
#
# Option values are checked with pack_die instead of the shorter ${2:?word}
# form on purpose: on macOS /bin/bash 3.2 a ${x:?} error exits the shell *after*
# running the EXIT trap, and that trap resets $? to 0, so `build-x-pack.sh
# --version` with no value would report success to CI. A real die keeps status 1.
pack_parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [[ $# -ge 2 && -n "$2" ]] || pack_die "--version needs a value"
        VERSION="$2"
        shift 2
        ;;
      --out)
        [[ $# -ge 2 && -n "$2" ]] || pack_die "--out needs a value"
        OUT="$2"
        shift 2
        ;;
      --force) FORCE=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *)
        PACK_ARG_SHIFT=""
        pack_parse_engine_arg "$@" || pack_die "unknown argument: $1 (try --help)"
        if [[ -z "$PACK_ARG_SHIFT" || "$PACK_ARG_SHIFT" -lt 1 ]]; then
          pack_die "internal error: pack_parse_engine_arg accepted $1 without setting PACK_ARG_SHIFT"
        fi
        shift "$PACK_ARG_SHIFT"
        ;;
    esac
  done
}

# --------------------------------------------------------------- target paths

# Resolve OUT/PACK_DIR and enforce the --force gate. This is the one step that
# moved earlier: it used to run after the download, so "--force is missing"
# cost a full upstream download first. $1 is the hint appended to the error
# message, because the five scripts worded that hint differently.
# --dry-run ends here: everything after this function produces side effects.
pack_begin() {
  local exists_hint="${1:-pass --force}"

  if [[ $DRY_RUN -eq 1 ]]; then
    case "$OUT" in
      /*) ;;
      *) OUT="$PWD/$OUT" ;;
    esac
    PACK_DIR="${OUT%/}/$ENGINE_ID/$VERSION"
    printf '==> dry run: nothing is downloaded, unpacked or written\n'
    printf '    engine      : %s %s\n' "$ENGINE_ID" "$VERSION"
    printf '    pack target : %s\n' "$PACK_DIR"
    if [[ -e "$PACK_DIR" ]]; then
      if [[ $FORCE -eq 1 ]]; then
        printf '    existing    : would be replaced (--force)\n'
      else
        printf '    existing    : yes, a real build would stop here and ask for --force\n'
      fi
    fi
    exit 0
  fi

  mkdir -p "$OUT"
  OUT="$(cd -- "$OUT" && pwd -P)"
  PACK_DIR="$OUT/$ENGINE_ID/$VERSION"
  if [[ -e "$PACK_DIR" ]]; then
    [[ $FORCE -eq 1 ]] || pack_die "$PACK_DIR already exists ($exists_hint)"
  fi
}

# ------------------------------------------------------ staging and the swap

# Build into $PACK_DIR.new.$$ instead of $PACK_DIR. The scripts used to
# `rm -rf "$PACK_DIR"` before unpacking, so a missing asset, a bad digest or a
# failed self-check left the user with no pack and no way back: the previously
# working install was already gone. Nothing here touches the live pack.
pack_stage() {
  PACK_STAGING="$PACK_DIR.new.$$"
  rm -rf -- "$PACK_STAGING"
  mkdir -p -- "$PACK_STAGING"
  pack_cleanup_add "$PACK_STAGING"
}

# Publish the staged tree once every check has passed. A plain `mv dir existing`
# would move the new tree *inside* the old one, so the old pack steps aside
# first; if the second mv fails, it is moved back. The staging directory is
# never left behind: pack_cleanup_add already covers the failure paths.
pack_swap() {
  local old
  if [[ ! -d "$PACK_STAGING" ]]; then
    pack_die "staging directory is missing: $PACK_STAGING"
  fi
  if [[ -e "$PACK_DIR" ]]; then
    old="$PACK_DIR.old.$$"
    rm -rf -- "$old"
    if ! mv -- "$PACK_DIR" "$old" || ! mv -- "$PACK_STAGING" "$PACK_DIR"; then
      mv -- "$old" "$PACK_DIR" 2>/dev/null || true
      pack_die "could not move the new pack into place: $PACK_DIR"
    fi
    rm -rf -- "$old"
  else
    mkdir -p -- "$(dirname -- "$PACK_DIR")"
    mv -- "$PACK_STAGING" "$PACK_DIR"
  fi
}

# pack_extract <archive> <dest> [strip] — unpack and drop the read-only bits the
# upstream archives ship with (otherwise the cleanup below cannot remove them).
# `strip` is for upstreams whose archive has a single leading directory.
pack_extract() {
  local archive="$1" dest="$2" mode="${3:-}"
  if [[ ! -f "$archive" ]]; then
    pack_die "archive not found: $archive"
  fi
  mkdir -p -- "$dest"
  case "$mode" in
    strip) tar -xzf "$archive" --strip-components=1 -C "$dest" ;;
    "") tar -xzf "$archive" -C "$dest" ;;
    *) pack_die "unknown pack_extract mode: $mode" ;;
  esac
  chmod -R u+w "$dest"
}

# --------------------------------------------------------------- verification

# The manifest has to be parseable JSON for the installer; that check is the
# same for all five engines, so it lives here. Field-level assertions are engine
# specific and stay in the scripts.
# pack_validate_manifest <python> [manifest path]
pack_validate_manifest() {
  local python="$1" manifest="${2:-$PACK_STAGING/manifest.json}"
  if [[ ! -f "$manifest" ]]; then
    pack_die "manifest is missing: $manifest"
  fi
  "$python" -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$manifest" >/dev/null \
    || pack_die "manifest.json is not valid JSON: $manifest"
}

# Bytecode and macOS metadata are not part of a pack: unpacking and importing
# during the self-checks creates them, and they only add noise to the release.
pack_clean_artifacts() {
  local dir="${1:-$PACK_STAGING}"
  find "$dir" -type d -name '__pycache__' -prune -exec rm -rf {} +
  find "$dir" -name '.DS_Store' -delete
}

# Native extensions bake the builder's absolute rpath into the binary, which
# breaks once the pack is copied into Application Support. fix-pack-rpaths.sh
# rewrites them to @loader_path and re-signs; it is idempotent.
pack_fix_rpaths() {
  local dir="${1:-$PACK_STAGING}"
  step "Make the pack relocatable"
  # The second argument is display-only: the rewrite happens in the staging
  # directory, but the path worth reporting is the one the user will keep.
  "$PACK_LIB_DIR/fix-pack-rpaths.sh" "$dir" "$PACK_DIR"
}

# ------------------------------------------------------------- report back

# Common summary lines. Takes the final path, so call it after pack_swap; each
# script appends its own engine-specific lines and its Next: hint.
pack_print_summary() {
  local pack_size file_count
  pack_size="$(du -sh "$PACK_DIR" | awk '{print $1}')"
  file_count="$(find "$PACK_DIR" -type f | wc -l | tr -d ' ')"
  step "Pack summary"
  printf '    path      : %s\n' "$PACK_DIR"
  printf '    size      : %s (%s files)\n' "$pack_size" "$file_count"
}

# make-pack-release.sh is always the next step; only the packs with a minimum
# macOS floor have to pass --min-macos.
pack_next_release_cmd() {
  local min_macos="${1:-}"
  printf '\nNext:\n  scripts/engines/make-pack-release.sh --engine %s --version %s' \
    "$ENGINE_ID" "$VERSION"
  if [[ -n "$min_macos" ]]; then
    printf ' --min-macos %s' "$min_macos"
  fi
  printf '\n'
}

# ------------------------------------------------------- uv (Python engines)

# mtplx and omlx both need a python-build-standalone interpreter and neither
# wants to depend on Homebrew: the first run drops a standalone uv into .tools/,
# which is gitignored. Only the resolved binary path goes to stdout, because the
# callers capture it with UV="$(pack_ensure_uv)" -- progress output on stdout
# used to be swallowed into that variable and broke the very first bootstrap.
pack_ensure_uv() {
  local uv_bin="$ROOT/.tools/uv"
  local url="https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz"
  local tmp

  if [[ -x "$uv_bin" ]]; then
    printf '%s\n' "$uv_bin"
    return 0
  fi

  step "Downloading standalone uv (one-time bootstrap into .tools/)" >&2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/uv-bootstrap.XXXXXX")"
  pack_cleanup_add "$tmp"
  curl -fL --retry 2 --max-time 300 -o "$tmp/uv.tar.gz" "$url"
  tar -xzf "$tmp/uv.tar.gz" -C "$tmp"
  mkdir -p "$ROOT/.tools"
  mv "$tmp/uv-aarch64-apple-darwin/uv" "$uv_bin"
  rm -rf -- "$tmp"
  # A half-finished bootstrap must not hand the caller a path that does not exist.
  [[ -f "$uv_bin" ]] || pack_die "uv bootstrap failed: $uv_bin was not installed"
  chmod +x "$uv_bin"
  printf '    uv -> %s\n' "$uv_bin" >&2
  printf '%s\n' "$uv_bin"
}
