#!/usr/bin/env python3
"""为 flashCat 生成 AppIcon.iconset。

用量：make-icon.py /path/to/AppIcon.iconset
画布 1024px：猫头剪影 + 橙色闪电，深色玻璃质感。
"""

import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
INSET = 40  # 留白，符合 macOS 图标视觉重量


def cat_head_mask(size: int) -> Image.Image:
    """圆角方底 + 顶部两只猫耳。"""
    scale = 4  # 超采样，边缘更干净
    big = size * scale
    mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(mask)

    inset = INSET * scale
    radius = int(big * 0.21)
    draw.rounded_rectangle(
        [inset, inset + 40 * scale, big - inset, big - inset],
        radius=radius,
        fill=255,
    )

    ear_y = inset + 40 * scale
    left_ear = [
        (int(big * 0.208), int(big * 0.335)),
        (int(big * 0.300), int(big * 0.075)),
        (int(big * 0.475), int(big * 0.245)),
    ]
    right_ear = [
        (int(big * 0.792), int(big * 0.335)),
        (int(big * 0.700), int(big * 0.075)),
        (int(big * 0.525), int(big * 0.245)),
    ]
    draw.polygon(left_ear, fill=255)
    draw.polygon(right_ear, fill=255)

    return mask.resize((size, size), Image.LANCZOS)


def vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    column = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(1, size - 1)
        column.putpixel(
            (0, y),
            tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)),
        )
    return column.resize((size, size))


def bolt_polygon(size: int) -> list:
    points = [
        (0.566, 0.118),
        (0.276, 0.560),
        (0.462, 0.560),
        (0.383, 0.902),
        (0.716, 0.404),
        (0.522, 0.404),
    ]
    return [(x * size, y * size) for x, y in points]


def render(iconset: Path) -> None:
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # 背景渐变
    background = vertical_gradient(SIZE, (0x16, 0x19, 0x22), (0x2C, 0x33, 0x44))
    head = cat_head_mask(SIZE)

    # 顶部高光，玻璃质感
    gloss = Image.new("L", (SIZE, SIZE), 0)
    gloss_draw = ImageDraw.Draw(gloss)
    gloss_draw.ellipse(
        [-SIZE * 0.35, -SIZE * 0.75, SIZE * 1.35, SIZE * 0.55],
        fill=48,
    )
    gloss = gloss.filter(ImageFilter.GaussianBlur(90))
    gloss = Image.composite(gloss, Image.new("L", (SIZE, SIZE), 0), head)

    base = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    base.paste(background, (0, 0), head)
    white = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 255))
    base.paste(white, (0, 0), gloss)

    # 细描边
    stroke = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    stroke_draw = ImageDraw.Draw(stroke)
    stroke_draw.bitmap((0, 0), head, fill=(255, 255, 255, 26))
    stroke = stroke.filter(ImageFilter.GaussianBlur(1))
    base = Image.alpha_composite(base, stroke)

    # 闪电：竖向渐变 + 外发光
    bolt_mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(bolt_mask).polygon(bolt_polygon(SIZE), fill=255)
    bolt_gradient = vertical_gradient(SIZE, (0xFF, 0xC2, 0x4A), (0xFF, 0x74, 0x12))
    bolt = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bolt.paste(bolt_gradient, (0, 0), bolt_mask)

    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    glow.paste((0xFF, 0x9A, 0x2E, 150), (0, 0), bolt_mask.filter(ImageFilter.GaussianBlur(38)))
    base = Image.alpha_composite(base, glow)
    base = Image.alpha_composite(base, bolt)

    base.save(iconset / "icon_512x512@2x.png")

    sizes = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
    }
    for name, edge in sizes.items():
        base.resize((edge, edge), Image.LANCZOS).save(iconset / name)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    iconset = Path(sys.argv[1])
    iconset.mkdir(parents=True, exist_ok=True)
    render(iconset)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
