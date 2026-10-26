#!/usr/bin/env python3
"""为 flashCat 生成 AppIcon.iconset。

用量：make-icon.py /path/to/AppIcon.iconset

画布 1024px：猫头轮廓 + 闪电，日落橙→桃红→紫罗兰的街机渐变，
配合顶部高光与放射光线，和游戏库风格的界面保持一致。
"""

import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

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
        [inset, inset + 92 * scale, big - inset, big - inset],
        radius=radius,
        fill=255,
    )

    left_ear = [
        (int(big * 0.190), int(big * 0.330)),
        (int(big * 0.278), int(big * 0.030)),
        (int(big * 0.500), int(big * 0.250)),
    ]
    right_ear = [
        (int(big * 0.810), int(big * 0.330)),
        (int(big * 0.722), int(big * 0.030)),
        (int(big * 0.500), int(big * 0.250)),
    ]
    draw.polygon(left_ear, fill=255)
    draw.polygon(right_ear, fill=255)

    return mask.resize((size, size), Image.LANCZOS)


def diagonal_gradient(size: int, stops: list) -> Image.Image:
    """左上→右下的多段渐变，先在 256px 上计算再放大，避免逐像素过慢。"""
    small = 256
    grid = Image.new("RGB", (small, small))
    pixels = grid.load()
    for y in range(small):
        for x in range(small):
            t = (x + y) / (2 * (small - 1))
            scaled = t * (len(stops) - 1)
            index = min(int(scaled), len(stops) - 2)
            local = scaled - index
            a, b = stops[index], stops[index + 1]
            pixels[x, y] = tuple(
                int(a[i] + (b[i] - a[i]) * local) for i in range(3)
            )
    return grid.resize((size, size), Image.BICUBIC)


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


def rays(size: int) -> Image.Image:
    """从右上角发散的细光线，模拟游戏主视觉。"""
    scale = 2
    big = size * scale
    layer = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    anchor = (big * 0.82, big * 0.18)
    reach = big * 1.6
    for index in range(56):
        angle = index / 56 * math.tau + 0.02
        width = (1 + (index % 5)) * scale
        alpha = 14 + (index * 7) % 26
        draw.line(
            [anchor,
             (anchor[0] + math.cos(angle) * reach,
              anchor[1] + math.sin(angle) * reach)],
            fill=(255, 255, 255, alpha),
            width=width,
        )
    layer = layer.filter(ImageFilter.GaussianBlur(1.2 * scale))
    return layer.resize((size, size), Image.LANCZOS)


def render(iconset: Path) -> None:
    head = cat_head_mask(SIZE)

    # 街机渐变底
    background = diagonal_gradient(
        SIZE,
        [(0xFF, 0xA2, 0x33), (0xFF, 0x5A, 0x5F), (0xFF, 0x37, 0x8F), (0x7C, 0x3A, 0xED)],
    )

    base = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    base.paste(background, (0, 0), head)

    # 放射光线，只落在猫头内部
    light = rays(SIZE)
    clipped = Image.new("L", (SIZE, SIZE), 0)
    clipped.paste(light.getchannel("A"), (0, 0))
    light.putalpha(ImageChops.multiply(clipped, head))
    base = Image.alpha_composite(base, light)

    # 顶部玻璃高光
    gloss = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(gloss).ellipse(
        [-SIZE * 0.35, -SIZE * 0.85, SIZE * 1.35, SIZE * 0.48],
        fill=70,
    )
    gloss = gloss.filter(ImageFilter.GaussianBlur(80))
    gloss = ImageChops.multiply(gloss, head)
    sheen = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 255))
    sheen.putalpha(gloss)
    base = Image.alpha_composite(base, sheen)

    # 内侧白描边
    edge = ImageChops.subtract(head, head.filter(ImageFilter.MinFilter(7)))
    stroke = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 255))
    stroke.putalpha(edge.point(lambda v: int(v * 0.55)))
    base = Image.alpha_composite(base, stroke)

    # 闪电：白色渐变 + 柔和投影
    bolt_mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(bolt_mask).polygon(bolt_polygon(SIZE), fill=255)
    bolt_gradient = diagonal_gradient(SIZE, [(255, 255, 255), (255, 236, 214)])

    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 120), (0, 0), bolt_mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(22))
    base = Image.alpha_composite(base, shadow)

    bolt = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bolt.paste(bolt_gradient, (0, 0), bolt_mask)
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
