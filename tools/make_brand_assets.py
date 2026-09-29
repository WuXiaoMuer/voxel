#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VoxelCraft brand asset generator.

Every pixel here is drawn in code -- an isometric voxel cube rasteriser, a
radial-gradient plate, a rounded-square mask.  Nothing is loaded from an art
file, which keeps the repo's "the whole game is generated" rule intact and
means the icon can be re-rendered at any size, in any palette, forever.

    python tools/make_brand_assets.py --all
    python tools/make_brand_assets.py --icon --variant deep
    python tools/make_brand_assets.py --social --banner
    python tools/make_brand_assets.py --shots

Outputs land in assets/.
"""

import argparse
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets")
ICON_DIR = os.path.join(ASSETS, "icon")
SHOT_DIR = os.path.join(ASSETS, "screenshots")
PREVIEWS = os.path.join(ROOT, "previews")
FONTS = "C:/Windows/Fonts"

# --------------------------------------------------------------------------
# palette
# --------------------------------------------------------------------------

C = {
    "grass": (120, 186, 80),
    "dirt": (152, 110, 73),
    "stone": (146, 148, 154),
    "diamond": (96, 224, 204),
    "outline": (24, 15, 8),
    "ink": (255, 255, 255),
}

# per-variant background plate: (inner, outer)
BG = {
    "deep": ((46, 74, 107), (11, 17, 27)),
    "sky": ((116, 192, 244), (34, 88, 156)),
    "stack": ((60, 44, 82), (14, 11, 20)),
}

GLOW = {
    "deep": (124, 189, 82),
    "sky": (255, 255, 255),
    "stack": (150, 120, 220),
}


def font(name, size):
    path = os.path.join(FONTS, name)
    if os.path.exists(path):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def _cells_for(size):
    """Pick how many voxels per face, and the supersample factor."""
    if size >= 256:
        return 16, 2
    if size >= 96:
        return 8, 4
    return 4, 4


def _shade(rgb, f):
    return tuple(max(0, min(255, int(c * f))) for c in rgb)


def _jitter(rgb, amt, rng):
    return tuple(max(0, min(255, c + rng.randint(-amt, amt))) for c in rgb)


def radial_bg(size, inner, outer, center=(0.5, 0.36), radius=0.95):
    """A radial gradient, computed small and scaled up -- smooth and fast."""
    res = 192
    small = Image.new("RGB", (res, res))
    px = small.load()
    cx, cy = center
    for y in range(res):
        for x in range(res):
            dx = (x + 0.5) / res - cx
            dy = (y + 0.5) / res - cy
            t = min(1.0, math.hypot(dx, dy) / radius)
            t = t * t * (3 - 2 * t)  # smoothstep, softer falloff
            px[x, y] = tuple(int(inner[i] + (outer[i] - inner[i]) * t) for i in range(3))
    return small.resize((size, size), Image.BICUBIC)


# --------------------------------------------------------------------------
# the cube rasteriser
# --------------------------------------------------------------------------

def draw_cube(img, cx, cy, w, h, n, top_rgb, side_rgb, rng,
              light_top=1.0, light_left=0.90, light_right=0.70,
              grass_band=0.30, outline_w=0, band_ragged=0.35):
    """Draw one isometric cube.

    `w` is the half-width of the top rhombus, `h` the height of a side face,
    `n` the number of voxels per face.  `cx, cy` is the centre of the top face.
    """
    d = ImageDraw.Draw(img)
    N = (cx, cy + w * 0.5)          # near corner (bottom of the rhombus)
    E = (cx + w, cy)                # right
    F = (cx, cy - w * 0.5)          # far corner (top)
    W = (cx - w, cy)                # left
    Nb = (cx, cy + w * 0.5 + h)
    Eb = (cx + w, cy + h)
    Wb = (cx - w, cy + h)

    def top_pt(u, v):
        return (N[0] + u * (E[0] - N[0]) + v * (W[0] - N[0]),
                N[1] + u * (E[1] - N[1]) + v * (W[1] - N[1]))

    def left_pt(u, v):
        return (N[0] + u * (W[0] - N[0]), N[1] + u * (W[1] - N[1]) + v * h)

    def right_pt(u, v):
        return (N[0] + u * (E[0] - N[0]), N[1] + u * (E[1] - N[1]) + v * h)

    def quad(fn, i, j):
        u0, u1 = i / n, (i + 1) / n
        v0, v1 = j / n, (j + 1) / n
        return [fn(u0, v0), fn(u1, v0), fn(u1, v1), fn(u0, v1)]

    # ragged grass fringe, one depth per column, so the sides don't line up
    left_band = [grass_band * (1.0 - band_ragged * rng.random()) for _ in range(n)]
    right_band = [grass_band * (1.0 - band_ragged * rng.random()) for _ in range(n)]

    # ---- two side faces first, so the top face paints over their seam
    for i in range(n):
        for j in range(n):
            v0 = j / n
            v1 = (j + 1) / n
            base = top_rgb if v0 < left_band[i] else side_rgb
            f = light_left * (1.0 - 0.14 * v1)
            d.polygon(quad(left_pt, i, j), fill=_jitter(_shade(base, f), 7, rng))

            base = top_rgb if v0 < right_band[i] else side_rgb
            f = light_right * (1.0 - 0.14 * v1)
            d.polygon(quad(right_pt, i, j), fill=_jitter(_shade(base, f), 7, rng))

    # ---- top face, lit from the upper-left of the screen
    for i in range(n):
        for j in range(n):
            u1 = (i + 1) / n
            v1 = (j + 1) / n
            f = light_top * (1.0 + 0.12 * (v1 - 0.5) - 0.08 * (u1 - 0.5))
            d.polygon(quad(top_pt, i, j), fill=_jitter(_shade(top_rgb, f), 7, rng))

    # ---- edges
    if outline_w:
        ink = C["outline"] + (255,)
        outer = [F, E, Eb, Nb, Wb, W]
        d.line(outer + [outer[0]], fill=ink, width=outline_w, joint="curve")
        d.line([N, E], fill=ink, width=outline_w)
        d.line([N, W], fill=ink, width=outline_w)

    return dict(N=N, E=E, F=F, W=W, Nb=Nb, Eb=Eb, Wb=Wb)


def cube_glow(img, poly, rgb, blur, alpha=130):
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).polygon(poly, fill=rgb + (alpha,))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    img.alpha_composite(layer)


def cube_shadow(img, cx, cy, w, h, blur, alpha=110):
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).ellipse(
        [cx - w * 0.95, cy - h * 0.30, cx + w * 0.95, cy + h * 0.30],
        fill=(0, 0, 0, alpha))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    img.alpha_composite(layer)


def _sky_detail(img, S, rng):
    """Sun + chunky pixel clouds, for the `sky` variant."""
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    sun = int(S * 0.078)
    sx, sy = int(S * 0.775), int(S * 0.165)
    d.ellipse([sx - sun * 1.7, sy - sun * 1.7, sx + sun * 1.7, sy + sun * 1.7],
              fill=(255, 246, 205, 45))
    d.ellipse([sx - sun, sy - sun, sx + sun, sy + sun], fill=(255, 238, 176, 240))

    cell = max(2, S // 56)

    def cloud(bx, by, cells, alpha=225):
        for k in range(cells):
            tall = 1 <= k <= cells - 2
            top = by - (cell if tall else 0)
            d.rectangle([bx + k * cell, top, bx + (k + 1) * cell - 1, by + cell - 1],
                        fill=(255, 255, 255, alpha))
            d.rectangle([bx + k * cell, by + cell, bx + (k + 1) * cell - 1, by + 2 * cell - 1],
                        fill=(230, 240, 250, alpha))

    cloud(int(S * 0.11), int(S * 0.15), 4)
    cloud(int(S * 0.60), int(S * 0.07), 3)
    cloud(int(S * 0.05), int(S * 0.55), 3)
    img.alpha_composite(layer)


def render_icon(size, variant="deep", seed=7):
    cells, ss = _cells_for(size)
    S = size * ss
    rng = random.Random(seed)

    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # ---- rounded-square background plate
    inner, outer = BG[variant]
    bg = radial_bg(S, inner, outer, center=(0.5, 0.34), radius=0.98)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1],
                                           radius=int(S * 0.225), fill=255)
    img.paste(bg, (0, 0), mask)

    if variant == "sky":
        _sky_detail(img, S, rng)

    ow = max(2, int(S * 0.013))
    gb = 0.30 if size >= 64 else 0.25

    if variant == "stack":
        # a three-block column: stone, dirt, grass -- a voxel totem
        w = S * 0.215
        h = S * 0.196
        top_y = S * 0.5 - (w + 3 * h) * 0.5 + w * 0.5
        layers = [
            (2, C["stone"], C["stone"]),
            (1, C["dirt"], C["dirt"]),
            (0, C["grass"], C["dirt"]),
        ]
        for k, top_rgb, side_rgb in layers:
            cy = top_y + k * h
            cube_shadow(img, S * 0.5, cy + w * 0.5 + h, w, h, S * 0.030, 95 if k == 2 else 0)
            faces = draw_cube(img, S * 0.5, cy, w, h, cells, top_rgb, side_rgb, rng,
                              grass_band=gb if k == 0 else 0.0,
                              outline_w=ow)
            if k == 0:
                top_glow = [faces["F"], faces["E"], faces["N"], faces["W"]]
                cube_glow(img, top_glow, GLOW[variant], S * 0.045, 80)
    else:
        w = S * 0.315
        h = S * 0.292
        cy = S * 0.5 - h * 0.5 - S * 0.015
        cube_shadow(img, S * 0.5, cy + w * 0.5 + h, w, h, S * 0.050)
        faces = draw_cube(img, S * 0.5, cy, w, h, cells,
                          C["grass"], C["dirt"], rng,
                          grass_band=gb, outline_w=ow)
        halo = [faces["F"], faces["E"], faces["Eb"], faces["Nb"],
                faces["Wb"], faces["W"]]
        cube_glow(img, halo, GLOW[variant], S * 0.060, 150)

    if ss > 1:
        img = img.resize((size, size), Image.LANCZOS)
    return img


# --------------------------------------------------------------------------
# vector icon
# --------------------------------------------------------------------------

def render_icon_svg(size=512, variant="deep", seed=7, cells=8):
    """The same cube, as a real SVG: rounded plate + crisp-edged voxel rects."""
    rng = random.Random(seed)
    inner, outer = BG[variant]
    w = size * 0.290
    h = size * 0.268
    cx = size * 0.5
    cy = size * 0.5 - h * 0.5 - size * 0.020

    N = (cx, cy + w * 0.5)
    E = (cx + w, cy)
    F = (cx, cy - w * 0.5)
    W = (cx - w, cy)
    Nb = (cx, cy + w * 0.5 + h)
    Eb = (cx + w, cy + h)
    Wb = (cx - w, cy + h)

    def top_pt(u, v):
        return (N[0] + u * (E[0] - N[0]) + v * (W[0] - N[0]),
                N[1] + u * (E[1] - N[1]) + v * (W[1] - N[1]))

    def left_pt(u, v):
        return (N[0] + u * (W[0] - N[0]), N[1] + u * (W[1] - N[1]) + v * h)

    def right_pt(u, v):
        return (N[0] + u * (E[0] - N[0]), N[1] + u * (E[1] - N[1]) + v * h)

    def rgb(r, g, b):
        return "#%02x%02x%02x" % (max(0, min(255, int(r))),
                                  max(0, min(255, int(g))),
                                  max(0, min(255, int(b))))

    parts = []
    n = cells
    for i in range(n):
        for j in range(n):
            v0, v1 = j / n, (j + 1) / n
            u1 = (i + 1) / n
            f = 0.80 * (1.0 - 0.20 * v1)
            base = C["grass"] if v0 < 0.22 else C["dirt"]
            pts = [left_pt(i / n, v0), left_pt(u1, v0), left_pt(u1, v1), left_pt(i / n, v1)]
            parts.append((pts, _jitter(_shade(base, f), 9, rng)))
    for i in range(n):
        for j in range(n):
            v0, v1 = j / n, (j + 1) / n
            u1 = (i + 1) / n
            f = 0.60 * (1.0 - 0.20 * v1)
            base = C["grass"] if v0 < 0.22 else C["dirt"]
            pts = [right_pt(i / n, v0), right_pt(u1, v0), right_pt(u1, v1), right_pt(i / n, v1)]
            parts.append((pts, _jitter(_shade(base, f), 9, rng)))
    for i in range(n):
        for j in range(n):
            u1, v1 = (i + 1) / n, (j + 1) / n
            f = 1.0 * (1.0 + 0.11 * (v1 - 0.5) - 0.07 * (u1 - 0.5))
            pts = [top_pt(i / n, j / n), top_pt(u1, j / n), top_pt(u1, v1), top_pt(i / n, v1)]
            parts.append((pts, _jitter(_shade(C["grass"], f), 9, rng)))

    body = "\n".join(
        '    <polygon points="%s" fill="%s"/>'
        % (" ".join("%.1f,%.1f" % p for p in pts), rgb(*col))
        for pts, col in parts)

    outer_pts = " ".join("%.1f,%.1f" % p for p in [F, E, Eb, Nb, Wb, W])
    ink = rgb(*C["outline"])
    ow = max(1.0, size * 0.011)

    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}">
  <defs>
    <radialGradient id="plate" cx="50%" cy="34%" r="98%">
      <stop offset="0" stop-color="{rgb(*inner)}"/>
      <stop offset="1" stop-color="{rgb(*outer)}"/>
    </radialGradient>
  </defs>
  <rect width="{size}" height="{size}" rx="{size * 0.225:.0f}" fill="url(#plate)"/>
  <g shape-rendering="crispEdges">
{body}
  </g>
  <polygon points="{outer_pts}" fill="none" stroke="{ink}" stroke-width="{ow:.1f}"
           stroke-linejoin="miter"/>
  <polyline points="{N[0]:.1f},{N[1]:.1f} {E[0]:.1f},{E[1]:.1f}" fill="none" stroke="{ink}" stroke-width="{ow:.1f}"/>
  <polyline points="{N[0]:.1f},{N[1]:.1f} {W[0]:.1f},{W[1]:.1f}" fill="none" stroke="{ink}" stroke-width="{ow:.1f}"/>
</svg>
'''


# --------------------------------------------------------------------------
# icon set
# --------------------------------------------------------------------------

SIZES = [1024, 512, 256, 128, 64, 48, 32, 16]


def build_icon_set(variant="deep", seed=7):
    os.makedirs(ICON_DIR, exist_ok=True)
    made = []
    for s in SIZES:
        im = render_icon(s, variant, seed)
        p = os.path.join(ICON_DIR, "voxelcraft_%s_%d.png" % (variant, s))
        im.save(p)
        made.append(p)
    big = render_icon(256, variant, seed)
    ico = os.path.join(ICON_DIR, "voxelcraft_%s.ico" % variant)
    big.save(ico, sizes=[(16, 16), (24, 24), (32, 32), (48, 48),
                         (64, 64), (128, 128), (256, 256)])
    made.append(ico)
    return made


# --------------------------------------------------------------------------
# promo cards
# --------------------------------------------------------------------------

def _fit(d, text, fnt, max_w):
    """Shrink a font until the string fits."""
    size = fnt.size
    while size > 8:
        f = fnt.font_variant(size=size) if hasattr(fnt, "font_variant") else fnt
        if d.textlength(text, font=f) <= max_w:
            return f
        size -= 2
        f = ImageFont.truetype(fnt.path, size)
    return f


def _text(d, xy, text, fnt, fill, anchor="la", shadow=None, blur=False):
    x, y = xy
    if shadow:
        d.text((x + 3, y + 3), text, font=fnt, fill=shadow, anchor=anchor)
    d.text((x, y), text, font=fnt, fill=fill, anchor=anchor)


def render_social(lang="en", W=1280, H=640):
    rng = random.Random(11)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    bg = radial_bg(W, (34, 56, 84), (10, 14, 22), center=(0.28, 0.30), radius=1.25)
    img.paste(bg, (0, 0))
    img = img.resize((W, H)) if img.size != (W, H) else img

    # voxel scenery on the right
    d = ImageDraw.Draw(img, "RGBA")
    plate = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw_cube(plate, 1020, 230, 132, 122, 16, C["grass"], C["dirt"], rng,
              grass_band=0.22, outline_w=3)
    draw_cube(plate, 890, 430, 82, 76, 12, (124, 126, 132), (124, 126, 132), rng,
              outline_w=3)
    draw_cube(plate, 1165, 452, 70, 65, 10, C["diamond"], C["diamond"], rng,
              outline_w=3)
    glow = plate.filter(ImageFilter.GaussianBlur(26))
    img.alpha_composite(glow)
    img.alpha_composite(plate)
    d = ImageDraw.Draw(img, "RGBA")

    # darken the left half so the type reads
    veil = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    vd = ImageDraw.Draw(veil)
    for x in range(0, int(W * 0.62)):
        a = int(200 * (1 - x / (W * 0.62)) ** 1.4)
        vd.line([(x, 0), (x, H)], fill=(6, 10, 16, a))
    img.alpha_composite(veil)

    # the icon itself, top-left
    icon = render_icon(200, "deep", 7)
    img.alpha_composite(icon, (72, 88))

    title_f = font("segoeuib.ttf", 104)
    sub_f = font("msyhbd.ttc", 30) if lang == "zh" else font("segoeuib.ttf", 30)
    chip_f = font("msyhbd.ttc", 22) if lang == "zh" else font("segoeuib.ttf", 22)
    d = ImageDraw.Draw(img, "RGBA")

    if lang == "zh":
        title = "VOXELCRAFT"
        sub = "用 Godot 4.5 从零代码搭建的 3D 体素沙盒"
        chips = ["无限地形", "生存 + 创造", "合成与电路", "联机"]
    else:
        title = "VOXELCRAFT"
        sub = "A complete 3D voxel sandbox in Godot 4.5"
        chips = ["Infinite terrain", "Survival + Creative", "Crafting & circuits", "Multiplayer"]

    d.text((72, 312), title, font=title_f, fill=(255, 255, 255, 255))
    d.text((78, 438), sub, font=sub_f, fill=(150, 208, 255, 255))

    x = 78
    y = 512
    chips_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    cl = ImageDraw.Draw(chips_layer)
    for c in chips:
        tw = d.textlength(c, font=chip_f)
        cl.rounded_rectangle([x, y, x + tw + 34, y + 46], radius=23,
                             fill=(255, 255, 255, 30), outline=(255, 255, 255, 90), width=2)
        cl.text((x + 17, y + 23), c, font=chip_f, fill=(228, 238, 250, 255), anchor="lm")
        x += tw + 34 + 16
    img.alpha_composite(chips_layer)

    out = os.path.join(ASSETS, "social_preview%s.png" % ("" if lang == "en" else "_zh"))
    img.convert("RGB").save(out)
    return out


def render_banner(lang="en", W=1280, H=340):
    rng = random.Random(5)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    bg = radial_bg(W, (32, 54, 82), (9, 13, 21), center=(0.30, 0.10), radius=1.35)
    img.paste(bg, (0, 0))
    img = img.resize((W, H)) if img.size != (W, H) else img

    plate = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw_cube(plate, 1075, 128, 92, 84, 12, C["grass"], C["dirt"], rng,
              grass_band=0.22, outline_w=3)
    draw_cube(plate, 895, 234, 58, 53, 10, (124, 126, 132), (124, 126, 132), rng, outline_w=2)
    draw_cube(plate, 1200, 244, 48, 44, 10, C["diamond"], C["diamond"], rng, outline_w=2)
    img.alpha_composite(plate.filter(ImageFilter.GaussianBlur(22)))
    img.alpha_composite(plate)

    veil = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    vd = ImageDraw.Draw(veil)
    for x in range(0, int(W * 0.70)):
        a = int(205 * (1 - x / (W * 0.70)) ** 1.4)
        vd.line([(x, 0), (x, H)], fill=(6, 10, 16, a))
    img.alpha_composite(veil)

    icon = render_icon(150, "deep", 7)
    img.alpha_composite(icon, (58, 95))

    d = ImageDraw.Draw(img, "RGBA")
    title_f = font("segoeuib.ttf", 76)
    sub_f = font("msyhbd.ttc", 26) if lang == "zh" else font("segoeuib.ttf", 26)
    d.text((238, 104), "VOXELCRAFT", font=title_f, fill=(255, 255, 255, 255))
    sub = ("用 Godot 4.5 从零代码搭建的 3D 体素沙盒"
           if lang == "zh" else
           "A complete 3D voxel sandbox in Godot 4.5")
    d.text((242, 200), sub, font=sub_f, fill=(150, 208, 255, 255))

    out = os.path.join(ASSETS, "banner%s.png" % ("" if lang == "en" else "_zh"))
    img.convert("RGB").save(out)
    return out


# --------------------------------------------------------------------------
# promo screenshots
# --------------------------------------------------------------------------

PICKS = [
    ("world_aerial", "Infinite procedural terrain", "无限程序化地形"),
    ("glass_tower", "Build anything, block by block", "一块一块，想建什么就建什么"),
    ("ocean", "Oceans, caves and biomes", "海洋、洞穴与生物群系"),
    ("play_hud", "Survival: hearts, hunger, drops", "生存：生命、饥饿与掉落物"),
    ("mobs", "Mobs that wander and hunt", "会游荡、会追人的生物"),
    ("crack.png", "Mining with real feedback", "挖掘有真实的碎裂反馈"),
    ("menu_inventory", "Inventory, crafting, palette", "背包、合成与方块面板"),
    ("world_night", "Survive the night", "在夜里活下去"),
]


def build_promo_shots(lang="en", max_w=1120):
    os.makedirs(SHOT_DIR, exist_ok=True)
    made = []
    idx = 1
    for name, en, zh in PICKS:
        src = os.path.join(PREVIEWS, name if name.endswith(".png") else name + ".png")
        if not os.path.exists(src):
            continue
        shot = Image.open(src).convert("RGB")
        shot = shot.resize((max_w, int(max_w * 9 / 16)), Image.LANCZOS)
        w, h = shot.size

        pad, bar, radius = 24, 68, 20
        card = Image.new("RGBA", (w + pad * 2, h + bar + pad * 2), (0, 0, 0, 0))
        cd = ImageDraw.Draw(card)

        # drop shadow
        sh = Image.new("RGBA", card.size, (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle(
            [pad + 5, pad + 12, pad + w + 5, pad + h + 12], radius=radius,
            fill=(0, 0, 0, 150))
        card.alpha_composite(sh.filter(ImageFilter.GaussianBlur(16)))

        mask = Image.new("L", (w, h), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius=radius, fill=255)
        card.paste(shot, (pad, pad), mask)

        edge = Image.new("RGBA", card.size, (0, 0, 0, 0))
        ImageDraw.Draw(edge).rounded_rectangle(
            [pad, pad, pad + w - 1, pad + h - 1], radius=radius,
            outline=(255, 255, 255, 55), width=2)
        card.alpha_composite(edge)

        # caption bar
        cd.rounded_rectangle([pad, pad + h + 10, pad + w, pad + h + bar - 12], radius=13,
                             fill=(16, 22, 32, 255))
        cap_f = font("msyhbd.ttc", 27) if lang == "zh" else font("segoeuib.ttf", 27)
        cd.text((pad + 20, pad + h + 10 + (bar - 22) // 2), zh if lang == "zh" else en,
                font=cap_f, fill=(228, 238, 250, 255), anchor="lm")

        suffix = "" if lang == "en" else "_zh"
        out = os.path.join(SHOT_DIR, "promo_%02d_%s%s.png" % (idx, name.replace(".png", ""), suffix))
        card.quantize(colors=256, method=Image.FASTOCTREE).save(out, optimize=True)
        made.append(out)
        idx += 1
    return made


def build_feature_grid(lang="en"):
    """One 3x3 contact sheet of the promo shots, for the top of a README."""
    files = sorted(f for f in os.listdir(SHOT_DIR)
                   if f.startswith("promo_") and f.endswith(".png")
                   and (("_zh" in f) == (lang == "zh")))
    if not files:
        return None
    cols = 4
    rows = (len(files) + cols - 1) // cols
    tw = 300
    ims = []
    for f in files:
        im = Image.open(os.path.join(SHOT_DIR, f)).convert("RGB")
        im = im.resize((tw, int(tw * im.height / im.width)), Image.LANCZOS)
        ims.append(im)
    th = max(i.height for i in ims)
    pad = 18
    W = cols * tw + (cols + 1) * pad
    H = rows * th + (rows + 1) * pad
    grid = Image.new("RGB", (W, H), (11, 15, 22))
    for k, im in enumerate(ims):
        r, c = divmod(k, cols)
        grid.paste(im, (pad + c * (tw + pad), pad + r * (th + pad)))
    out = os.path.join(ASSETS, "features%s.png" % ("" if lang == "en" else "_zh"))
    grid.quantize(colors=256, method=Image.MEDIANCUT).save(out, optimize=True)
    return out


# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--icon", action="store_true")
    ap.add_argument("--social", action="store_true")
    ap.add_argument("--banner", action="store_true")
    ap.add_argument("--shots", action="store_true")
    ap.add_argument("--svg", action="store_true")
    ap.add_argument("--variant", default="deep", choices=sorted(BG))
    ap.add_argument("--all-variants", action="store_true")
    args = ap.parse_args()

    if not any([args.all, args.icon, args.social, args.banner, args.shots, args.svg]):
        args.all = True

    os.makedirs(ASSETS, exist_ok=True)
    made = []

    if args.all or args.svg:
        p = os.path.join(ROOT, "icon.svg")
        with open(p, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(render_icon_svg(512, args.variant))
        made.append(p)
        print("icon.svg")

    if args.all or args.icon:
        variants = sorted(BG) if (args.all_variants or args.all) else [args.variant]
        for v in variants:
            for p in build_icon_set(v):
                made.append(p)
            print("icon set: %s" % v)

    if args.all or args.social:
        for lang in ("en", "zh"):
            made.append(render_social(lang))
        print("social preview")

    if args.all or args.banner:
        for lang in ("en", "zh"):
            made.append(render_banner(lang))
        print("banner")

    if args.all or args.shots:
        for lang in ("en", "zh"):
            made += build_promo_shots(lang)
            g = build_feature_grid(lang)
            if g:
                made.append(g)
        print("promo screenshots")

    print("\n%d files written under %s" % (len(made), ASSETS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
