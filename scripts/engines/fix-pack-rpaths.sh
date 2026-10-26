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

PACK="$(cd "${1:-}" && pwd)"
if [ -z "${1:-}" ] || [ ! -f "$PACK/manifest.json" ]; then
  echo "usage: $0 <pack-root>   (must contain manifest.json)" >&2
  exit 2
fi

python3 - "$PACK" <<'PY'
import os, subprocess, sys

pack = sys.argv[1]
fixable, foreign = [], []

for root, _dirs, files in os.walk(pack):
    for name in files:
        if not (name.endswith(".so") or name.endswith(".dylib") or "." not in name):
            continue
        path = os.path.join(root, name)
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

echo "==> done: $PACK"
