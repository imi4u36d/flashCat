#!/usr/bin/env bash
#
# Self-test for lib-pack.sh. Runs the shared pack scaffolding against stub
# tools in a scratch directory, so it needs no network, no Xcode, no engine and
# no writable repo: it must stay cheap enough to run inside CI on every push.
#
# The point of these cases is the contract the five build-*-pack.sh scripts rely
# on, above all the one this refactor fixed: a failed build must never destroy
# the pack that is already installed.
#
#   scripts/engines/lib-pack-selftest.sh
#
# Every case runs in its own bash process (a generated fixture) so that `die`,
# the EXIT trap and `pack_begin`'s `exit 0` behave exactly like they do in a
# real build script instead of terminating the test runner.
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# pwd -P normalises $TMPDIR (which ends in a slash on macOS) and /var ->
# /private/var, so the paths printed by pack_print_summary can be compared
# literally below.
WORK="$(cd -- "$(mktemp -d "${TMPDIR:-/tmp}/lib-pack-selftest.XXXXXX")" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

# run_case <case> [env assignments...] — the fixture is a text file, so nothing
# has to be quoted through a subshell. Output is kept in $WORK/out.<case>.
run_case() {
  local case_name="$1"
  shift
  env -i PATH="${STUB_PATH:-$PATH}" HOME="$WORK/home" TMPDIR="$WORK/tmp" \
    SELF_DIR="$SELF_DIR" WORK="$WORK" CASE="$case_name" "$@" \
    /bin/bash "$WORK/fixture.sh" >"$WORK/out.$case_name" 2>&1
}

# Failing cases are expected to print an error, so their output is only shown for
# a case that should have succeeded: a wall of expected stderr on every run
# makes the log useless.
expect_failure() {
  local label="$1" case_name="$2"
  shift 2
  if run_case "$case_name" "$@"; then
    fail "$label (fixture was expected to fail)"
    return 0
  fi
  pass "$label"
}

expect_success() {
  local label="$1" case_name="$2"
  shift 2
  if run_case "$case_name" "$@"; then
    pass "$label"
  else
    fail "$label"
    printf '     fixture output (%s):\n' "$case_name" >&2
    sed 's/^/       /' "$WORK/out.$case_name" >&2
  fi
}

expect_grep() {
  local label="$1" pattern="$2" file="$3"
  if grep -q "$pattern" "$file"; then
    pass "$label"
  else
    fail "$label (no '$pattern' in output)"
  fi
}

no_residue() {
  local label="$1" dir="$2"
  if find "$dir" -maxdepth 2 -name '*.new.*' -o -maxdepth 2 -name '*.old.*' | grep -q .; then
    fail "$label (leftover staging/old directory)"
  else
    pass "$label"
  fi
}

mkdir -p "$WORK/tmp" "$WORK/home" "$WORK/failtar"
cat > "$WORK/failtar/tar" <<'STUB'
#!/bin/bash
echo "stub-tar: simulated unpack failure" >&2
exit 1
STUB
chmod +x "$WORK/failtar/tar"

# ---------------------------------------------------------------------------
# Fixture: sources the real library and runs one scenario.
# ---------------------------------------------------------------------------
cat > "$WORK/fixture.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail

ROOT="$WORK/root"
mkdir -p "$ROOT"
export ROOT
# shellcheck source=lib-pack.sh
source "$SELF_DIR/lib-pack.sh"

ENGINE_ID="probe"
ENGINE_NAME="Probe"
DEFAULT_VERSION="9.9.9"
DEFAULT_OUT="$WORK/out"
DEFAULT_PORT=9999
MIN_MACOS="15.0"
VERSION="$DEFAULT_VERSION"
OUT="$DEFAULT_OUT"
FORCE=0
usage() { :; }

python3_or_fail() {
  if [[ -x /usr/bin/python3 ]]; then printf '/usr/bin/python3\n'; else command -v python3; fi
}

fail() { printf 'assert failed: %s\n' "$*" >&2; exit 1; }

case "$CASE" in
  dryrun)
    pack_parse_common_args --version v9.9.9 --out "$WORK/dryrun-out" --dry-run
    # pack_begin exits 0 for --dry-run; anything below this line must not run.
    pack_begin
    fail "pack_begin did not exit for --dry-run"
    ;;
  refused)
    pack_parse_common_args
    pack_begin
    fail "pack_begin accepted an existing pack without --force"
    ;;
  force_swap)
    FORCE=1
    pack_parse_common_args
    pack_begin
    pack_stage
    [[ "$PACK_STAGING" == "$PACK_DIR.new.$$" ]] || fail "staging path is not <pack>.new.$$ ($PACK_STAGING)"
    printf 'new\n' > "$PACK_STAGING/marker"
    pack_swap
    [[ "$(cat "$PACK_DIR/marker")" == "new" ]] || fail "swap did not publish the staged pack"
    [[ ! -e "$PACK_STAGING" ]] || fail "staging directory survived the swap"
    ;;
  tar_failure)
    FORCE=1
    pack_parse_common_args
    pack_begin
    pack_stage
    pack_extract "$WORK/missing.tar.gz" "$PACK_STAGING" strip
    fail "pack_extract accepted a missing archive"
    ;;
  bad_manifest)
    FORCE=1
    pack_parse_common_args
    pack_begin
    pack_stage
    printf '{ "id": "probe",\n' > "$PACK_STAGING/manifest.json"
    pack_validate_manifest "$(python3_or_fail)"
    fail "pack_validate_manifest accepted broken JSON"
    ;;
  good_manifest)
    FORCE=1
    pack_parse_common_args
    pack_begin
    pack_stage
    printf '{ "schemaVersion": 1, "id": "probe" }\n' > "$PACK_STAGING/manifest.json"
    pack_validate_manifest "$(python3_or_fail)"
    ;;
  extract_strip)
    pack_extract "$WORK/strip.tar.gz" "$WORK/dest-strip" strip
    [[ -f "$WORK/dest-strip/release.json" ]] || fail "strip extraction did not lift release.json"
    [[ ! -d "$WORK/dest-strip/pkg-1.0" ]] || fail "strip extraction kept the leading directory"
    ;;
  cleanup_registry)
    printf 'x\n' > "$WORK/registered-file"
    mkdir -p "$WORK/registered-dir"
    touch "$WORK/registered-dir/inside"
    pack_cleanup_add "$WORK/registered-file"
    pack_cleanup_add "$WORK/registered-dir"
    exit 3
    ;;
  missing_tool)
    pack_require_tools definitely-not-a-real-tool-xyz
    fail "pack_require_tools accepted a missing tool"
    ;;
  unknown_option)
    pack_parse_common_args --definitely-not-an-option
    fail "unknown option was accepted"
    ;;
  missing_value)
    pack_parse_common_args --version
    fail "--version without a value was accepted"
    ;;
  clean_artifacts)
    FORCE=1
    pack_parse_common_args
    pack_begin
    pack_stage
    mkdir -p "$PACK_STAGING/pkg/__pycache__"
    touch "$PACK_STAGING/pkg/__pycache__/mod.cpython-313.pyc" "$PACK_STAGING/.DS_Store"
    printf 'keep\n' > "$PACK_STAGING/pkg/keep.txt"
    pack_clean_artifacts
    [[ ! -d "$PACK_STAGING/pkg/__pycache__" ]] || fail "__pycache__ was not removed"
    [[ ! -e "$PACK_STAGING/.DS_Store" ]] || fail ".DS_Store was not removed"
    [[ -f "$PACK_STAGING/pkg/keep.txt" ]] || fail "pack_clean_artifacts removed a real file"
    ;;
  summary)
    FORCE=1
    pack_parse_common_args
    pack_begin
    pack_stage
    printf '{ "schemaVersion": 1 }\n' > "$PACK_STAGING/manifest.json"
    pack_swap
    pack_print_summary
    pack_next_release_cmd "$MIN_MACOS"
    ;;
  *)
    fail "unknown fixture case: $CASE"
    ;;
esac
FIXTURE

# Deterministic, tool-independent environment for every fixture run.
STUB_PATH="$PATH"

# ---------------------------------------------------------------------------
# 1. --dry-run must not create anything and must show the resolved target.
# ---------------------------------------------------------------------------
expect_success "--dry-run exits 0" dryrun
if [[ -e "$WORK/dryrun-out" ]]; then
  fail "--dry-run wrote $WORK/dryrun-out"
else
  pass "--dry-run creates no output directory"
fi
expect_grep "--dry-run prints the pack target" 'pack target : ' "$WORK/out.dryrun"

# ---------------------------------------------------------------------------
# 2. Existing pack + no --force: refuse and leave the old pack alone.
#    (Before this refactor the script downloaded the whole upstream asset first
#    and only then noticed.)
# ---------------------------------------------------------------------------
mkdir -p "$WORK/out/probe/9.9.9"
printf 'old\n' > "$WORK/out/probe/9.9.9/marker"
expect_failure "existing pack without --force is refused" refused
if [[ "$(cat "$WORK/out/probe/9.9.9/marker" 2>/dev/null)" == "old" ]]; then
  pass "refused build keeps the installed pack"
else
  fail "refused build damaged the installed pack"
fi
no_residue "refused build leaves no staging directory" "$WORK/out"

# ---------------------------------------------------------------------------
# 3. --force publishes the staged tree and removes the old one.
# ---------------------------------------------------------------------------
expect_success "--force replaces the pack" force_swap
if [[ "$(cat "$WORK/out/probe/9.9.9/marker" 2>/dev/null)" == "new" ]]; then
  pass "--force published the new pack"
else
  fail "--force did not publish the new pack"
fi
no_residue "--force leaves no staging/old directory" "$WORK/out"

# ---------------------------------------------------------------------------
# 4. Failed unpack: the old pack must survive untouched (the P1 regression).
# ---------------------------------------------------------------------------
mkdir -p "$WORK/out/probe/9.9.9"
printf 'old\n' > "$WORK/out/probe/9.9.9/marker"
expect_failure "unpack failure aborts the build" tar_failure
if [[ "$(cat "$WORK/out/probe/9.9.9/marker" 2>/dev/null)" == "old" ]]; then
  pass "failed unpack keeps the installed pack"
else
  fail "failed unpack destroyed the installed pack"
fi
no_residue "failed unpack leaves no staging directory" "$WORK/out"

# ---------------------------------------------------------------------------
# 5. Same for a manifest that does not parse.
# ---------------------------------------------------------------------------
expect_failure "broken manifest aborts the build" bad_manifest
if [[ "$(cat "$WORK/out/probe/9.9.9/marker" 2>/dev/null)" == "old" ]]; then
  pass "broken manifest keeps the installed pack"
else
  fail "broken manifest destroyed the installed pack"
fi
no_residue "broken manifest leaves no staging directory" "$WORK/out"

# ---------------------------------------------------------------------------
# 6. A valid manifest passes.
# ---------------------------------------------------------------------------
expect_success "valid manifest is accepted" good_manifest

# ---------------------------------------------------------------------------
# 7. pack_extract strip semantics.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/strip-src/pkg-1.0"
printf '{ "version": "9.9.9" }\n' > "$WORK/strip-src/pkg-1.0/release.json"
tar -czf "$WORK/strip.tar.gz" -C "$WORK/strip-src" pkg-1.0
expect_success "pack_extract strip drops the leading directory" extract_strip

# ---------------------------------------------------------------------------
# 8. Registered temp paths are removed on a failing exit.
# ---------------------------------------------------------------------------
expect_failure "fixture exits non-zero for the cleanup case" cleanup_registry
if [[ ! -e "$WORK/registered-file" && ! -e "$WORK/registered-dir" ]]; then
  pass "cleanup registry removes temp files on failure"
else
  fail "cleanup registry left temp paths behind"
fi

# ---------------------------------------------------------------------------
# 9..11. Argument and tool guards.
# ---------------------------------------------------------------------------
expect_failure "missing tool is rejected" missing_tool
expect_grep "missing tool error names the tool" 'required tool is missing: definitely-not-a-real-tool-xyz' "$WORK/out.missing_tool"
expect_failure "unknown option is rejected" unknown_option
expect_grep "unknown option error is actionable" 'unknown argument: --definitely-not-an-option' "$WORK/out.unknown_option"
expect_failure "option without a value is rejected" missing_value

# ---------------------------------------------------------------------------
# 12. Artifact cleanup keeps real files.
# ---------------------------------------------------------------------------
expect_success "pack_clean_artifacts removes bytecode and metadata" clean_artifacts

# ---------------------------------------------------------------------------
# 13. Summary shape: final path, size and the release hint.
# ---------------------------------------------------------------------------
expect_success "summary runs after the swap" summary
expect_grep "summary prints the final pack path" "path      : $WORK/out/probe/9.9.9" "$WORK/out.summary"
expect_grep "summary prints a size line" 'size      : ' "$WORK/out.summary"
expect_grep "summary hints make-pack-release.sh" 'make-pack-release.sh --engine probe --version 9.9.9 --min-macos 15.0' "$WORK/out.summary"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
