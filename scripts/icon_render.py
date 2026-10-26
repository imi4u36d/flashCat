#!/usr/bin/env python3
"""Vector-quality icon renderer for flashCat.

Shapes live on a 1024-unit grid, are rasterised as 3x masks and composited at
the target size, so the icon stays crisp from 1024 px down to 16 px.

The mark is a macOS squircle that grows two cat ears, charged by a milled
lightning bolt. Every style shares the silhouette and only changes its light.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
SS = 3  # mask supersampling


# ---------------------------------------------------------------------------
# geometry


def _cubic(p0, p1, p2, p3, n=90):
    pts = []
    for i in range(1, n + 1):
        t = i / n
        u = 1 - t
        x = u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0]
        y = u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1]
        pts.append((x, y))
    return pts


def _quad(p0, p1, p2, n=44):
    pts = []
    for i in range(1, n + 1):
        t = i / n
        u = 1 - t
        x = u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0]
        y = u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1]
        pts.append((x, y))
    return pts


def superellipse(x0, y0, x1, y1, n=4.7, steps=960):
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    a, b = (x1 - x0) / 2, (y1 - y0) / 2
    pts = []
    for i in range(steps):
        t = math.tau * i / steps
        ct, st = math.cos(t), math.sin(t)
        pts.append(
            (
                cx + a * math.copysign(abs(ct) ** (2 / n), ct),
                cy + b * math.copysign(abs(st) ** (2 / n), st),
            )
        )
    return pts


def rounded_polygon(points, radius, steps=10):
    n = len(points)
    out = []
    for i, p in enumerate(points):
        prev = points[(i - 1) % n]
        nxt = points[(i + 1) % n]
        v1 = (prev[0] - p[0], prev[1] - p[1])
        v2 = (nxt[0] - p[0], nxt[1] - p[1])
        l1 = math.hypot(*v1)
        l2 = math.hypot(*v2)
        r = min(radius, l1 / 2, l2 / 2)
        a = (p[0] + v1[0] / l1 * r, p[1] + v1[1] / l1 * r)
        b = (p[0] + v2[0] / l2 * r, p[1] + v2[1] / l2 * r)
        out.extend(_quad(a, p, b, steps))
    return out


def circle(cx, cy, r, steps=120):
    return [
        (cx + r * math.cos(math.tau * i / steps), cy + r * math.sin(math.tau * i / steps))
        for i in range(steps)
    ]


def cat_tile_parts(tip_y=110.0, top=214.0, bottom=924.0, fillet=0.0):
    """A squircle body plus two ears that break its top edge.

    Keeping the top edge calm between the ears makes it read as a forehead
    rather than a crown. Little tangent disks round the two concave notches
    where each ear meets the forehead.
    """
    body = superellipse(100, top, 924, bottom, 4.7)
    left_ear = rounded_polygon([(102.0, 434.0), (268.0, tip_y), (432.0, 342.0)], 30.0)
    right_ear = rounded_polygon(
        [(1024 - 102.0, 434.0), (1024 - 268.0, tip_y), (1024 - 432.0, 342.0)], 30.0
    )

    # A hairline fillet would need a boolean path; at icon sizes the clean
    # paper-cut notch reads better than a visible bulge.
    return [body, left_ear, right_ear]


def bolt_outline():
    points = [
        (578, 300),
        (392, 600),
        (494, 600),
        (452, 840),
        (632, 540),
        (530, 540),
    ]
    return rounded_polygon(points, 16)


def mask_from_parts(parts, size=SIZE, ss=SS):
    big = Image.new("L", (size * ss, size * ss), 0)
    draw = ImageDraw.Draw(big)
    for pts in parts:
        draw.polygon([(x * ss, y * ss) for x, y in pts], fill=255)
    return big.resize((size, size), Image.LANCZOS)


def mask_from_points(points, size=SIZE, ss=SS):
    big = Image.new("L", (size * ss, size * ss), 0)
    ImageDraw.Draw(big).polygon([(x * ss, y * ss) for x, y in points], fill=255)
    return big.resize((size, size), Image.LANCZOS)


# ---------------------------------------------------------------------------
# colour


def rgb(hex_value):
    hex_value = hex_value.lstrip("#")
    return tuple(int(hex_value[i : i + 2], 16) for i in (0, 2, 4))


def linear_field(size, stops, angle=45.0):
    positions = np.array([s[0] for s in stops], dtype=float)
    colors = np.array([rgb(s[1]) for s in stops], dtype=float)
    rad = math.radians(angle)
    dx, dy = math.cos(rad), math.sin(rad)
    yy, xx = np.mgrid[0:size, 0:size].astype(float) / (size - 1)
    t = np.clip((xx - 0.5) * dx + (yy - 0.5) * dy + 0.5, 0, 1)
    out = np.empty((size, size, 3), dtype=float)
    for c in range(3):
        out[..., c] = np.interp(t, positions, colors[:, c])
    return out


def radial_alpha(size, center, radius, power=2.0):
    yy, xx = np.mgrid[0:size, 0:size].astype(float)
    d = np.hypot(xx - center[0] * size, yy - center[1] * size) / (radius * size)
    return np.clip(1 - d, 0, 1) ** power


def screen(base, color, alpha):
    c = np.array(rgb(color), dtype=float)
    a = alpha[..., None]
    lit = 1 - (1 - base / 255.0) * (1 - c / 255.0)
    return np.clip(base * (1 - a) + lit * 255.0 * a, 0, 255)


def add_glow(base, color, alpha, mode="screen"):
    if mode == "screen":
        return screen(base, color, alpha)
    c = np.array(rgb(color), dtype=float)
    a = alpha[..., None]
    return base * (1 - a) + c * a


def grain(field, amount=3.0, seed=7):
    rng = np.random.default_rng(seed)
    noise = rng.normal(0, 1, field.shape[:2])
    noise = np.array(
        Image.fromarray(((noise * 0.5 + 0.5) * 255).clip(0, 255).astype(np.uint8)).filter(
            ImageFilter.GaussianBlur(0.7)
        ),
        dtype=float,
    )
    noise = (noise - 127.5) / 127.5
    return np.clip(field + noise[..., None] * amount, 0, 255)


def to_image(field):
    return Image.fromarray(field.clip(0, 255).astype(np.uint8), "RGB")


def color_layer(size, color, mask):
    layer = Image.new("RGBA", (size, size), rgb(color) + (255,))
    layer.putalpha(mask)
    return layer


def gradient_layer(size, stops, mask, angle=45.0):
    layer = to_image(linear_field(size, stops, angle)).convert("RGBA")
    layer.putalpha(mask)
    return layer


def vertical_mask(size, top=255, bottom=0):
    arr = np.linspace(top, bottom, size, dtype=float)
    return Image.fromarray(np.repeat(arr[:, None], size, axis=1).astype(np.uint8), "L")


def diagonal_mask(size, low=0, high=255, angle=45.0):
    yy, xx = np.mgrid[0:size, 0:size].astype(float) / (size - 1)
    rad = math.radians(angle)
    t = np.clip((xx - 0.5) * math.cos(rad) + (yy - 0.5) * math.sin(rad) + 0.5, 0, 1)
    return Image.fromarray((low + (high - low) * t).astype(np.uint8), "L")


# ---------------------------------------------------------------------------
# painting


def drop_shadow(mask, blur, offset=(0, 0), opacity=0.45, size=SIZE):
    canvas = Image.new("L", (size, size), 0)
    canvas.paste(mask, offset)
    canvas = canvas.filter(ImageFilter.GaussianBlur(blur))
    if opacity != 1:
        canvas = canvas.point(lambda v: int(v * opacity))
    return canvas


def inner_rim(mask, width=3):
    eroded = mask.filter(ImageFilter.MinFilter(width * 2 + 1))
    return ImageChops.subtract(mask, eroded)


def dither_alpha(mask, amplitude=2.0, seed=11):
    """Break 8-bit banding in the wide, low-contrast icon shadow."""
    rng = np.random.default_rng(seed)
    arr = np.asarray(mask, dtype=float)
    arr = np.clip(arr + rng.uniform(-amplitude, amplitude, arr.shape), 0, 255)
    return Image.fromarray(arr.astype(np.uint8), "L")


# ---------------------------------------------------------------------------
# styles


@dataclass
class Style:
    key: str
    name: str
    caption: str
    tile_stops: list
    tile_angle: float
    glows: list  # (color, strength, center, radius, power)
    rim_light: str
    rim_dark: str
    rim_strength: float
    bolt_stops: list
    bolt_angle: float
    shadow_color: str
    bolt_glow: tuple | None
    ambient_shadow: float = 0.30
    contact_shadow: float = 0.30
    bottom_shade: float = 0.30
    grain_amount: float = 2.6


STYLES = {
    "sunset": Style(
        key="sunset",
        name="Sunset",
        caption="品牌日落 · 暖橙到深紫 · 白色闪电",
        tile_stops=[
            (0.00, "#FFB26B"),
            (0.26, "#FF7D5E"),
            (0.54, "#F24A7C"),
            (0.78, "#C03AA6"),
            (1.00, "#57279B"),
        ],
        tile_angle=45,
        glows=[
            ("#FFF2D6", 0.34, (0.18, 0.10), 0.55, 1.9),
            ("#FF8FA8", 0.16, (0.86, 0.86), 0.55, 2.4),
        ],
        rim_light="#FFF6E8",
        rim_dark="#C08CFF",
        rim_strength=0.55,
        bolt_stops=[(0.0, "#FFFFFF"), (0.58, "#FFFCF6"), (1.0, "#FFD9BE")],
        bolt_angle=62,
        shadow_color="#2B0616",
        bolt_glow=None,
        ambient_shadow=0.20,
        contact_shadow=0.28,
        bottom_shade=0.30,
        grain_amount=2.4,
    ),
    "midnight": Style(
        key="midnight",
        name="Midnight",
        caption="午夜极光 · 深空底色 · 渐变闪电",
        tile_stops=[
            (0.00, "#2C1B44"),
            (0.42, "#170F26"),
            (1.00, "#08070F"),
        ],
        tile_angle=45,
        glows=[
            ("#FF5E62", 0.50, (0.50, 0.96), 0.44, 2.3),
            ("#FF9A5C", 0.24, (0.20, 0.98), 0.34, 2.2),
            ("#B23BFF", 0.36, (0.58, 0.55), 0.72, 3.0),
            ("#4E7CFF", 0.12, (0.06, 0.10), 0.50, 2.4),
        ],
        rim_light="#FFC2D2",
        rim_dark="#8A5BFF",
        rim_strength=0.72,
        bolt_stops=[
            (0.00, "#FFF4D6"),
            (0.30, "#FFB25E"),
            (0.62, "#FF4D7E"),
            (1.00, "#A94BFF"),
        ],
        bolt_angle=64,
        shadow_color="#000000",
        bolt_glow=("#FF5C86", 0.42),
        ambient_shadow=0.30,
        contact_shadow=0.34,
        bottom_shade=0.52,
        grain_amount=2.8,
    ),
    "graphite": Style(
        key="graphite",
        name="Graphite",
        caption="石墨金属 · 银色高光 · 纯白闪电",
        tile_stops=[
            (0.00, "#585862"),
            (0.38, "#34343C"),
            (0.78, "#1D1D23"),
            (1.00, "#101014"),
        ],
        tile_angle=45,
        glows=[
            ("#FFFFFF", 0.20, (0.18, 0.08), 0.60, 2.0),
            ("#7D7DFF", 0.10, (0.86, 0.92), 0.60, 2.6),
        ],
        rim_light="#FFFFFF",
        rim_dark="#AFAFBC",
        rim_strength=0.52,
        bolt_stops=[(0.0, "#FFFFFF"), (0.70, "#FCFCFF"), (1.0, "#E6E6EF")],
        bolt_angle=60,
        shadow_color="#000000",
        bolt_glow=("#FFFFFF", 0.10),
        ambient_shadow=0.30,
        contact_shadow=0.34,
        bottom_shade=0.42,
        grain_amount=2.6,
    ),
    "paper": Style(
        key="paper",
        name="Paper",
        caption="暖白纸感 · 珊瑚到紫罗兰 · 通透明亮",
        tile_stops=[
            (0.00, "#FFF9F0"),
            (0.45, "#F8EBDD"),
            (0.80, "#EFDCCB"),
            (1.00, "#E4CDBA"),
        ],
        tile_angle=45,
        glows=[
            ("#FFFFFF", 0.55, (0.20, 0.10), 0.60, 1.8),
            ("#FFD8C0", 0.22, (0.85, 0.90), 0.55, 2.4),
        ],
        rim_light="#FFFFFF",
        rim_dark="#D8BFA9",
        rim_strength=0.85,
        bolt_stops=[
            (0.00, "#FFB159"),
            (0.30, "#FF7A5E"),
            (0.62, "#F23F88"),
            (1.00, "#8B3FD6"),
        ],
        bolt_angle=62,
        shadow_color="#6B3B2A",
        bolt_glow=None,
        ambient_shadow=0.16,
        contact_shadow=0.22,
        bottom_shade=0.18,
        grain_amount=2.2,
    ),
}


# ---------------------------------------------------------------------------
# render


def render(style: Style, size=SIZE, ss=SS) -> Image.Image:
    tile_mask = mask_from_parts(cat_tile_parts(), size, ss)
    bolt_mask = mask_from_points(bolt_outline(), size, ss)

    # tile ---------------------------------------------------------------
    field = linear_field(size, style.tile_stops, style.tile_angle)
    for color, strength, center, radius, power in style.glows:
        field = add_glow(field, color, radial_alpha(size, center, radius, power) * strength)
    field = grain(field, style.grain_amount, seed=sum(map(ord, style.key)) * 37)

    if style.bottom_shade:
        yy, xx = np.mgrid[0:size, 0:size].astype(float) / (size - 1)
        t = np.clip((xx + yy) / 2, 0, 1) ** 1.7
        field = field * (1 - t[..., None] * style.bottom_shade * 0.6)

    tile = to_image(field).convert("RGBA")
    tile.putalpha(tile_mask)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # shadow -------------------------------------------------------------
    contact = drop_shadow(tile_mask, 9 * size / 1024, (0, 7 * size // 1024), style.contact_shadow, size)
    canvas = Image.alpha_composite(
        canvas, color_layer(size, style.shadow_color, dither_alpha(contact, 0.9))
    )
    soft = drop_shadow(tile_mask, 38 * size / 1024, (0, 20 * size // 1024), style.ambient_shadow, size)
    canvas = Image.alpha_composite(
        canvas, color_layer(size, style.shadow_color, dither_alpha(soft, 1.1))
    )

    canvas = Image.alpha_composite(canvas, tile)

    # rim light ----------------------------------------------------------
    rim = inner_rim(tile_mask, max(2, round(3 * size / 1024)))
    rim = ImageChops.multiply(rim, vertical_mask(size, 255, 60))
    rim_rgb = np.empty((size, size, 3), dtype=float)
    y = np.linspace(0, 1, size)[:, None]
    for c in range(3):
        rim_rgb[..., c] = rgb(style.rim_light)[c] * (1 - y) + rgb(style.rim_dark)[c] * y
    rim_layer = Image.fromarray(rim_rgb.clip(0, 255).astype(np.uint8), "RGB").convert("RGBA")
    rim_layer.putalpha(rim.point(lambda v: int(v * style.rim_strength)))
    canvas = Image.alpha_composite(canvas, rim_layer)

    # sculpted inner shadow at the bottom ---------------------------------
    inner = ImageChops.subtract(
        tile_mask,
        drop_shadow(tile_mask, 15 * size / 1024, (0, -13 * size // 1024), 1.0, size),
    )
    inner = ImageChops.multiply(inner, vertical_mask(size, 0, 210))
    canvas = Image.alpha_composite(
        canvas, color_layer(size, style.shadow_color, inner.point(lambda v: int(v * 0.50)))
    )

    # top glass sheen ------------------------------------------------------
    sheen = diagonal_mask(size, 150, 0, 90)
    sheen = ImageChops.multiply(sheen, tile_mask).filter(ImageFilter.GaussianBlur(20 * size / 1024))
    canvas = Image.alpha_composite(
        canvas, color_layer(size, "#FFFFFF", sheen.point(lambda v: int(v * 0.10)))
    )

    # bolt ----------------------------------------------------------------
    if style.bolt_glow:
        color, strength = style.bolt_glow
        glow = bolt_mask.filter(ImageFilter.GaussianBlur(26 * size / 1024))
        canvas = Image.alpha_composite(
            canvas, color_layer(size, color, glow.point(lambda v: int(v * strength)))
        )

    ambient = drop_shadow(bolt_mask, 18 * size / 1024, (0, 12 * size // 1024), 0.32, size)
    canvas = Image.alpha_composite(canvas, color_layer(size, style.shadow_color, ambient))
    contact = drop_shadow(bolt_mask, 5 * size / 1024, (0, 5 * size // 1024), 0.42, size)
    canvas = Image.alpha_composite(canvas, color_layer(size, style.shadow_color, contact))

    canvas = Image.alpha_composite(
        canvas, gradient_layer(size, style.bolt_stops, bolt_mask, style.bolt_angle)
    )

    # milled edge: light on the top-left, shade on the bottom-right --------
    off = max(2, round(2.4 * size / 1024))
    hi = ImageChops.subtract(bolt_mask, drop_shadow(bolt_mask, 1.2, (off, off), 1.0, size))
    hi = ImageChops.multiply(hi, vertical_mask(size, 255, 90))
    canvas = Image.alpha_composite(
        canvas, color_layer(size, "#FFFFFF", hi.point(lambda v: int(v * 0.55)))
    )
    lo = ImageChops.subtract(bolt_mask, drop_shadow(bolt_mask, 1.2, (-off, -off), 1.0, size))
    lo = ImageChops.multiply(lo, vertical_mask(size, 40, 200))
    canvas = Image.alpha_composite(
        canvas, color_layer(size, style.shadow_color, lo.point(lambda v: int(v * 0.38)))
    )

    return canvas


def export_iconset(image: Image.Image, iconset):
    iconset.mkdir(parents=True, exist_ok=True)
    image.resize((1024, 1024), Image.LANCZOS).save(iconset / "icon_512x512@2x.png")
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
        image.resize((edge, edge), Image.LANCZOS).save(iconset / name)
