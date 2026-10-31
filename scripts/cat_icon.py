#!/usr/bin/env python3
"""flashCat 应用图标 v2：具像化猫头。

与 `icon_render.py` 的「带耳朵的方块」不同，这一版直接画一只猫头：

  · 猫头剪影（双耳、圆颊、圆下巴），沿用品牌日落渐变作毛色
  · 耳廓（深色内耳）、眼睛（带高光）、鼻、ω 嘴、胡须
  · 品牌闪电保留为额头的白色纹路（flash 的记忆点）
  · 菜单栏图标就是这只头的单色剪影，两者轮廓同源

用法：
    scripts/cat_icon.py dist/icon-preview/cat-head.png
    scripts/cat_icon.py dist/AppIcon-v2.iconset --icns dist/AppIcon-v2.icns

形状都在 1024 网格上定义，经 3x 超采样栅格化后合成，16px 依然干净。
"""

from __future__ import annotations

import math
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

import icon_render as ir

SIZE = 1024
SS = 3


# ---------------------------------------------------------------------------
# 猫头几何


def head_outline():
    """猫头外轮廓：双耳 + 圆额 + 宽颊 + 圆下巴。y 向下。"""
    p = []
    # 左耳外沿上坡
    p += ir._cubic((100, 430), (105, 300), (130, 120), (185, 100))
    # 左耳圆耳尖
    p += ir._cubic((185, 100), (200, 84), (236, 88), (252, 112))
    # 左耳内沿下坡到额头
    p += ir._cubic((252, 112), (300, 150), (352, 206), (396, 246))
    # 双耳之间的额头（微微上拱）
    p += ir._cubic((396, 246), (446, 206), (578, 206), (628, 246))
    # 右耳内沿上坡
    p += ir._cubic((628, 246), (672, 206), (724, 150), (772, 112))
    # 右耳圆耳尖
    p += ir._cubic((772, 112), (788, 88), (824, 84), (839, 100))
    # 右耳外沿下坡
    p += ir._cubic((839, 100), (894, 120), (919, 300), (924, 430))
    # 右颊
    p += ir._cubic((924, 430), (931, 492), (938, 552), (938, 622))
    # 右下到下巴
    p += ir._cubic((938, 622), (938, 822), (748, 956), (512, 956))
    # 左下
    p += ir._cubic((512, 956), (276, 956), (86, 822), (86, 622))
    # 左颊回到起点
    p += ir._cubic((86, 622), (86, 552), (93, 492), (100, 430))
    return p


def inner_ear_left():
    return ir.rounded_polygon([(168, 368), (238, 168), (376, 258)], 22.0)


def inner_ear_right():
    return ir.rounded_polygon([(1024 - 168, 368), (1024 - 238, 168), (1024 - 376, 258)], 22.0)


def forehead_bolt():
    """品牌闪电缩放到额头，作为毛色纹路。"""
    src = ir.bolt_outline()
    out = []
    for x, y in src:
        out.append((512 + (x - 512) * 0.60, 300 + (y - 300) * 0.31))
    return ir.rounded_polygon(out, 10)


def ellipse_points(cx, cy, rx, ry, angle_deg=0.0, steps=120):
    ang = math.radians(angle_deg)
    ca, sa = math.cos(ang), math.sin(ang)
    pts = []
    for i in range(steps):
        t = math.tau * i / steps
        x, y = rx * math.cos(t), ry * math.sin(t)
        pts.append((cx + x * ca - y * sa, cy + x * sa + y * ca))
    return pts


# ---------------------------------------------------------------------------
# 通用小工具


def mask_from_polys(polys, size=SIZE, ss=SS):
    big = Image.new("L", (size * ss, size * ss), 0)
    draw = ImageDraw.Draw(big)
    for pts in polys:
        draw.polygon([(x * ss, y * ss) for x, y in pts], fill=255)
    return big.resize((size, size), Image.LANCZOS)


def stroke_mask(polylines, width, size=SIZE, ss=SS):
    big = Image.new("L", (size * ss, size * ss), 0)
    draw = ImageDraw.Draw(big)
    for pts in polylines:
        draw.line([(x * ss, y * ss) for x, y in pts], fill=255, width=int(width * ss), joint="curve")
    # 圆头端点
    for pts in polylines:
        for (x, y) in (pts[0], pts[-1]):
            r = width * ss / 2
            draw.ellipse([x * ss - r, y * ss - r, x * ss + r, y * ss + r], fill=255)
    return big.resize((size, size), Image.LANCZOS)


def disc_mask(centers_radius, size=SIZE, ss=SS):
    big = Image.new("L", (size * ss, size * ss), 0)
    draw = ImageDraw.Draw(big)
    for (cx, cy), r in centers_radius:
        draw.ellipse([(cx - r) * ss, (cy - r) * ss, (cx + r) * ss, (cy + r) * ss], fill=255)
    return big.resize((size, size), Image.LANCZOS)


# ---------------------------------------------------------------------------
# 渲染


def render(size=SIZE, ss=SS, flat=False):
    head_pts = head_outline()
    head_mask = mask_from_polys([head_pts], size, ss)
    ears_mask = mask_from_polys([inner_ear_left(), inner_ear_right()], size, ss)
    bolt_mask = mask_from_polys([forehead_bolt()], size, ss)

    # 眼睛（外圈微转，内角略下，看起来更像猫）
    eye_l = ellipse_points(335, 585, 76, 96, -9)
    eye_r = ellipse_points(1024 - 335, 585, 76, 96, 9)
    eyes_mask = mask_from_polys([eye_l, eye_r], size, ss)
    hi_big = disc_mask([((335 - 20, 585 - 32), 25), ((1024 - 335 + 20, 585 - 32), 25)], size, ss)
    hi_small = disc_mask([((335 + 22, 585 + 30), 12), ((1024 - 335 - 22, 585 + 30), 12)], size, ss)

    nose_mask = mask_from_polys([ir.rounded_polygon([(458, 660), (566, 660), (512, 718)], 16)], size, ss)

    # ω 嘴：从鼻底出发的两段下凸圆弧（控制点在弦下方才是“微笑的猫嘴”）
    mouth_l = ir._quad((512, 718), (474, 790), (438, 754))
    mouth_r = ir._quad((512, 718), (550, 790), (586, 754))
    mouth_mask = stroke_mask([mouth_l, mouth_r], 14, size, ss)

    whisker_lines = [
        ir._quad((292, 652), (196, 640), (102, 630)),
        ir._quad((288, 700), (192, 698), (94, 700)),
        ir._quad((292, 748), (198, 756), (106, 772)),
        ir._quad((1024 - 298, 640), (1024 - 200, 626), (1024 - 104, 616)),
        ir._quad((1024 - 296, 686), (1024 - 196, 682), (1024 - 98, 682)),
        ir._quad((1024 - 298, 732), (1024 - 200, 738), (1024 - 110, 752)),
    ]
    whiskers_mask = stroke_mask(whisker_lines, 11, size, ss)

    # 毛色：扁平版只保留一个轻微的单向日落渐变，去掉辉光/噪点/压暗
    if flat:
        stops = [
            (0.00, "#FF9E6B"),
            (0.50, "#F75C86"),
            (1.00, "#C247A8"),
        ]
        field = ir.linear_field(size, stops, 115)
    else:
        stops = [
            (0.00, "#FFB26B"),
            (0.28, "#FF7D5E"),
            (0.56, "#F24A7C"),
            (0.80, "#C03AA6"),
            (1.00, "#6E2A9E"),
        ]
        field = ir.linear_field(size, stops, 45)
        for color, strength, center, radius, power in [
            ("#FFF2D6", 0.30, (0.22, 0.12), 0.50, 1.9),
            ("#FF8FA8", 0.14, (0.85, 0.90), 0.50, 2.4),
        ]:
            field = ir.add_glow(field, color, ir.radial_alpha(size, center, radius, power) * strength)
        field = ir.grain(field, 2.2, seed=17)

        yy, xx = np.mgrid[0:size, 0:size].astype(float) / (size - 1)
        t = np.clip((xx + yy) / 2, 0, 1) ** 1.7
        field = field * (1 - t[..., None] * 0.18)

    head = ir.to_image(field).convert("RGBA")
    head.putalpha(head_mask)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # 投影 / 边缘光 / 体积阴影 / 玻璃高光（扁平版全部跳过）------------------
    shadow_color = "#2B0616"
    if not flat:
        contact = ir.drop_shadow(head_mask, 9 * size / 1024, (0, 7 * size // 1024), 0.28, size)
        canvas = Image.alpha_composite(canvas, ir.color_layer(size, shadow_color, ir.dither_alpha(contact, 0.9)))
        ambient = ir.drop_shadow(head_mask, 38 * size / 1024, (0, 20 * size // 1024), 0.20, size)
        canvas = Image.alpha_composite(canvas, ir.color_layer(size, shadow_color, ir.dither_alpha(ambient, 1.1)))

    canvas = Image.alpha_composite(canvas, head)

    if not flat:
        # 顶部边缘光
        rim = ir.inner_rim(head_mask, max(2, round(3 * size / 1024)))
        rim = ImageChops.multiply(rim, ir.vertical_mask(size, 255, 60))
        rim_rgb = np.empty((size, size, 3), dtype=float)
        y = np.linspace(0, 1, size)[:, None]
        for c in range(3):
            rim_rgb[..., c] = ir.rgb("#FFF6E8")[c] * (1 - y) + ir.rgb("#C08CFF")[c] * y
        rim_layer = Image.fromarray(rim_rgb.clip(0, 255).astype(np.uint8), "RGB").convert("RGBA")
        rim_layer.putalpha(rim.point(lambda v: int(v * 0.5)))
        canvas = Image.alpha_composite(canvas, rim_layer)

        # 底部体积阴影
        inner = ImageChops.subtract(
            head_mask,
            ir.drop_shadow(head_mask, 15 * size / 1024, (0, -13 * size // 1024), 1.0, size),
        )
        inner = ImageChops.multiply(inner, ir.vertical_mask(size, 0, 210))
        canvas = Image.alpha_composite(canvas, ir.color_layer(size, shadow_color, inner.point(lambda v: int(v * 0.40))))

        # 顶部玻璃高光
        sheen = ir.diagonal_mask(size, 150, 0, 90)
        sheen = ImageChops.multiply(sheen, head_mask).filter(ImageFilter.GaussianBlur(20 * size / 1024))
        canvas = Image.alpha_composite(canvas, ir.color_layer(size, "#FFFFFF", sheen.point(lambda v: int(v * 0.08))))

    # 耳廓 ----------------------------------------------------------------
    if flat:
        ears = ir.color_layer(size, "#D6448E", ears_mask)
    else:
        ear_field = ir.linear_field(size, [(0.0, "#E2558F"), (1.0, "#8E2470")], 90)
        ears = ir.to_image(ear_field).convert("RGBA")
        ears.putalpha(ears_mask)
    canvas = Image.alpha_composite(canvas, ears)

    # 额头闪电 --------------------------------------------------------------
    if flat:
        canvas = Image.alpha_composite(canvas, ir.color_layer(size, "#FFF6EC", bolt_mask))
    else:
        glow = bolt_mask.filter(ImageFilter.GaussianBlur(22 * size / 1024))
        canvas = Image.alpha_composite(canvas, ir.color_layer(size, "#FFD9E8", glow.point(lambda v: int(v * 0.35))))
        bolt_ambient = ir.drop_shadow(bolt_mask, 14 * size / 1024, (0, 9 * size // 1024), 0.30, size)
        canvas = Image.alpha_composite(canvas, ir.color_layer(size, shadow_color, bolt_ambient))
        canvas = Image.alpha_composite(
            canvas, ir.gradient_layer(size, [(0.0, "#FFFFFF"), (0.6, "#FFF3E2"), (1.0, "#FFE0C4")], bolt_mask, 62)
        )
        off = max(2, round(2.4 * size / 1024))
        hi = ImageChops.subtract(bolt_mask, ir.drop_shadow(bolt_mask, 1.2, (off, off), 1.0, size))
        hi = ImageChops.multiply(hi, ir.vertical_mask(size, 255, 90))
        canvas = Image.alpha_composite(canvas, ir.color_layer(size, "#FFFFFF", hi.point(lambda v: int(v * 0.5))))

    # 眼睛 ------------------------------------------------------------------
    canvas = Image.alpha_composite(canvas, ir.color_layer(size, "#2A1220", eyes_mask))
    if flat:
        # 扁平版：每只眼睛只留一枚干净的白色高光点
        flat_hi = disc_mask([((335 - 18, 585 - 30), 24), ((1024 - 335 + 18, 585 - 30), 24)], size, ss)
        canvas = Image.alpha_composite(canvas, ir.color_layer(size, "#FFFFFF", flat_hi))
    else:
        # 眼内上部微光，让眼睛不发死黑
        eye_glow = disc_mask([((335, 585 + 46), 60), ((1024 - 335, 585 + 46), 60)], size, ss)
        eye_glow = ImageChops.multiply(eye_glow, eyes_mask).filter(ImageFilter.GaussianBlur(14 * size / 1024))
        canvas = Image.alpha_composite(canvas, ir.color_layer(size, "#5C2A48", eye_glow.point(lambda v: int(v * 0.6))))
        canvas = Image.alpha_composite(canvas, ir.color_layer(size, "#FFFFFF", hi_big.point(lambda v: int(v * 0.95))))
        canvas = Image.alpha_composite(canvas, ir.color_layer(size, "#FFE9F2", hi_small.point(lambda v: int(v * 0.7))))

    # 鼻与嘴 -----------------------------------------------------------------
    canvas = Image.alpha_composite(canvas, ir.color_layer(size, "#521636", nose_mask))
    if not flat:
        nose_hi = disc_mask([((500, 672), 11)], size, ss)
        nose_hi = ImageChops.multiply(nose_hi, nose_mask)
        canvas = Image.alpha_composite(canvas, ir.color_layer(size, "#B85B8A", nose_hi.point(lambda v: int(v * 0.8))))
        nose_shadow = ir.drop_shadow(nose_mask, 5 * size / 1024, (0, 4 * size // 1024), 0.30, size)
        canvas = Image.alpha_composite(canvas, ir.color_layer(size, shadow_color, nose_shadow))
    canvas = Image.alpha_composite(canvas, ir.color_layer(size, "#521636", mouth_mask))

    # 胡须 --------------------------------------------------------------------
    whiskers = stroke_mask(whisker_lines, 11, size, ss)
    if not flat:
        whiskers = whiskers.filter(ImageFilter.GaussianBlur(1.2 * size / 1024))
    alpha = 0.85 if flat else 0.72
    canvas = Image.alpha_composite(canvas, ir.color_layer(size, "#FFF6EC" if flat else "#FFF1E4", whiskers.point(lambda v: int(v * alpha))))

    return canvas


# ---------------------------------------------------------------------------
# 导出


def size_strip(image: Image.Image, path: Path):
    """在浅灰底上排一排常用尺寸，检查小尺寸下的可读性。"""
    sizes = [256, 128, 64, 32, 16]
    pad, gap = 24, 20
    w = sum(sizes) + gap * (len(sizes) - 1) + pad * 2
    h = max(sizes) + pad * 2
    strip = Image.new("RGB", (w, h), "#F2F0EC")
    x = pad
    for s in sizes:
        strip.paste(image.resize((s, s), Image.LANCZOS), (x, pad), image.resize((s, s), Image.LANCZOS))
        x += s + gap
    strip.save(path)


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", help="输出 1024px PNG（.iconset 结尾则导出整套图标）")
    parser.add_argument("--icns", help="同时导出 .icns 到此路径")
    parser.add_argument("--strip", help="输出多尺寸检查条 PNG")
    parser.add_argument("--flat", action="store_true", help="扁平风格：无投影/高光/噪点")
    args = parser.parse_args()

    if not args.output:
        parser.print_help()
        return 2

    image = render(flat=args.flat)

    out = Path(args.output)
    if out.suffix == ".iconset":
        ir.export_iconset(image, out)
        if args.icns:
            subprocess.run(
                ["iconutil", "-c", "icns", str(out), "-o", str(args.icns)], check=True
            )
    else:
        out.parent.mkdir(parents=True, exist_ok=True)
        image.resize((1024, 1024), Image.LANCZOS).save(out)

    if args.strip:
        size_strip(image, Path(args.strip))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
