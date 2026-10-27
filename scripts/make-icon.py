#!/usr/bin/env python3
"""Render the flashCat icon in one of its four light treatments.

The shipped artwork lives in `native/Sources/FlashCat/Resources/app-icon.png` and
`scripts/build-native-app.sh` derives `AppIcon.icns` from that file directly, so
this script is the fallback for a checkout without the master, and the tool for
re-rolling the icon in another style (`--style midnight`).

    scripts/make-icon.py dist/AppIcon.iconset
    scripts/make-icon.py dist/AppIcon.iconset --style midnight
    scripts/make-icon.py --png preview.png --style sunset

The default Sunset style keeps the brand's orange → pink → violet gradient,
with a sculpted squircle that grows two cat ears and a milled lightning bolt.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import icon_render  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("iconset", nargs="?", help="output .iconset directory")
    parser.add_argument("--style", default="sunset", choices=sorted(icon_render.STYLES))
    parser.add_argument("--png", help="also write a 1024 px PNG preview here")
    parser.add_argument("--size", type=int, default=1024, help="preview size (default 1024)")
    args = parser.parse_args()

    if not args.iconset and not args.png:
        parser.print_help()
        return 2

    image = icon_render.render(icon_render.STYLES[args.style])

    if args.iconset:
        icon_render.export_iconset(image, Path(args.iconset))

    if args.png:
        image.resize((args.size, args.size), icon_render.Image.LANCZOS).save(args.png)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
