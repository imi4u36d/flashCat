#!/usr/bin/env bash
# Make a runtime pack relocatable.
#
# PyPI wheels and native extensions sometimes bake the *build machine's* absolute
# path into LC_RPATH. A pack carrying such a path only runs where it was built,
# which breaks the whole point of installing into
# ~/Library/Application Support/flashCat/engines. This rewrites every rpath that
# points inside the pack into an `@loader_path/...` equivalent and re-signs the
# binary ad-hoc (install_name_tool invalidates the signature; Apple Silicon
# refuses to load a binary with a stale signature).
#
#   scripts/engines/fix-pack-rpaths.sh vendor/engines/mtplx/2.12.2
#
# Idempotent: already-relative rpaths are ignored. Absolute paths *outside* the
# pack are reported but left alone — they belong to the build environment, not
# to us, and rewriting them could break a real system dependency lookup.
set -euo pipefail

# The argument checks run *before* the `cd` in the command substitution: when the
# path does not exist, `$(cd "$1" && pwd)` fails inside the assignment and
# `set -e` kills the script with a bare exit 1 — the usage below never prints.
# (No argument is harmless by accident: macOS bash 3.2 lets `cd ""` succeed and
# stay put, which is exactly the kind of accident not worth depending on.)
usage() {
  echo "usage: $0 <pack-root>   (must contain manifest.json)" >&2
}

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
  usage
  exit 2
fi
if [ ! -d "$1" ]; then
  echo "error: not a directory: $1" >&2
  usage
  exit 2
fi
PACK="$(cd -- "$1" && pwd)"
# The optional second argument only changes the path printed by "==> done:".
# build-*-pack.sh rewrites rpaths inside a staging directory and then renames
# it, so the path worth reporting is the final one.
DISPLAY="${2:-$PACK}"
if [ ! -f "$PACK/manifest.json" ]; then
  echo "error: no manifest.json in $PACK" >&2
  usage
  exit 2
fi

python3 - "$PACK" <<'PY'
import os, subprocess, sys

pack = sys.argv[1]
fixable, foreign = [], []

# Only Mach-O files can carry LC_RPATH, and a file name does not tell you which
# ones are Mach-O: `python/bin/python3.13` has an extension, a wheel's data
# directory may hold `1.2.3` that looks extensionless. Read the magic instead.
MACHO_MAGICS = {
    b"\xcf\xfa\xed\xfe",  # 64-bit, little endian (arm64, x86_64)
    b"\xce\xfa\xed\xfe",  # 32-bit, little endian
    b"\xfe\xed\xfa\xcf",  # 64-bit, big endian
    b"\xfe\xed\xfa\xce",  # 32-bit, big endian
    b"\xca\xfe\xba\xbe",  # universal (fat) binary
    b"\xbf\xba\xfe\xca",  # universal (fat) 64-bit
}


def is_macho(path):
    try:
        with open(path, "rb") as handle:
            return handle.read(4) in MACHO_MAGICS
    except OSError:
        return False


for root, _dirs, files in os.walk(pack):
    for name in files:
        path = os.path.join(root, name)
        if not is_macho(path):
            continue
        try:
            listing = subprocess.run(["/usr/bin/otool", "-l", path],
                                     capture_output=True, text=True).stdout
        except Exception:
            continue
        if "LC_RPATH" not in listing:
            continue
        lines = listing.splitlines()
        for index, line in enumerate(lines):
            if line.strip().startswith("cmd LC_RPATH"):
                for follow in lines[index + 1:index + 3]:
                    follow = follow.strip()
                    if not follow.startswith("path "):
                        continue
                    value = follow[5:].split(" (offset")[0].strip()
                    if value.startswith("@"):
                        break
                    if not value.startswith("/"):
                        break
                    target = os.path.realpath(value)
                    if target.startswith(os.path.realpath(pack) + os.sep) and os.path.isdir(target):
                        fixable.append((path, value, target))
                    else:
                        foreign.append((path, value))
                    break

if foreign:
    print("==> rpaths outside the pack (left as-is):")
    for path, value in foreign:
        print("    %s :: %s" % (os.path.relpath(path, pack), value))

if not fixable:
    print("==> no absolute rpaths inside the pack; nothing to do")
    sys.exit(0)

print("==> rewriting %d rpath(s)" % len(fixable))
for path, value, target in fixable:
    rel = os.path.relpath(target, os.path.dirname(path))
    replacement = "@loader_path/" + rel
    subprocess.run(["/usr/bin/install_name_tool", "-rpath", value, replacement, path],
                   check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", path],
                   check=True, capture_output=True)
    print("    %s\n      %s\n      -> %s" % (os.path.relpath(path, pack), value, replacement))
PY

echo "==> done: $DISPLAY"
