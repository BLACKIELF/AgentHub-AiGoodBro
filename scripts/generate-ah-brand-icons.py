#!/usr/bin/env python3
"""AiGoodBro (AH) brand icon generator.

Product-informed mark: AH ligature (AiGoodBro / AgentHub) whose shared
crossbar carries a reset-cycle hub — the workspace's distinctive 5h/7d
window. Drawn in a normalized 0-100 glyph box and rasterized with PIL at
heavy supersampling so Resources PNG/ICNS rebuild byte-identically:

    python3 scripts/generate-ah-brand-icons.py --candidates docs/images/ah-brand-0911v1/candidates
    python3 scripts/generate-ah-brand-icons.py --final
    python3 scripts/generate-ah-brand-icons.py --board docs/images/ah-brand-0911v1/ah-brand-acceptance-board.png

`--final` rewrites Resources/codexU-icon.png and Resources/codexU.icns.
"""

import argparse
import math
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

# ---------------------------------------------------------------------------
# Geometry (normalized 0-100 glyph box, y down)
# ---------------------------------------------------------------------------

A_LEFT_FOOT = (17.0, 85.0)
A_APEX = (35.0, 15.0)
A_RIGHT_FOOT = (53.0, 85.0)
CROSSBAR_Y = 55.0
H_RIGHT_X = 83.0
H_TOP = 15.0
H_BOTTOM = 85.0
STROKE = 10.5
HUB_CENTER = (64.5, CROSSBAR_Y)
HUB_RADIUS = 11.0
HUB_RING = 3.4
FINAL_VARIANT = "c5"


def crossbar_x_left():
    # x of the A left leg at CROSSBAR_Y
    t = (A_LEFT_FOOT[1] - CROSSBAR_Y) / (A_LEFT_FOOT[1] - A_APEX[1])
    return A_LEFT_FOOT[0] + t * (A_APEX[0] - A_LEFT_FOOT[0])


def glyph_segments():
    """Polylines forming the AH ligature."""
    return [
        [A_LEFT_FOOT, A_APEX, A_RIGHT_FOOT],
        [(crossbar_x_left(), CROSSBAR_Y), (H_RIGHT_X, CROSSBAR_Y)],
        [(H_RIGHT_X, H_TOP), (H_RIGHT_X, H_BOTTOM)],
    ]


# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------

TILE_TOP = (64, 112, 255)      # #4070FF
TILE_BOTTOM = (28, 62, 196)    # #1C3EC4
GLYPH_WHITE = (255, 255, 255)
GLYPH_TINT = (196, 214, 255)
FRAME_WHITE = (255, 255, 255, 56)


# ---------------------------------------------------------------------------
# Drawing primitives (all coordinates in glyph-box units, scaled by `u`)
# ---------------------------------------------------------------------------

def draw_polyline(draw, points, u, width, color):
    pts = [(x * u, y * u) for x, y in points]
    draw.line(pts, fill=color, width=int(round(width * u)), joint="curve")
    r = width * u / 2.0
    for x, y in (pts[0], pts[-1]):
        draw.ellipse([x - r, y - r, x + r, y + r], fill=color)


def draw_glyph(draw, u, color, stroke=STROKE, hub=None):
    """Draw the AH ligature. `hub`: None, 'dot', 'ring', or 'reset'."""
    for segment in glyph_segments():
        draw_polyline(draw, segment, u, stroke, color)
    if hub is None:
        return
    cx, cy = HUB_CENTER[0] * u, HUB_CENTER[1] * u
    r = HUB_RADIUS * u
    if hub == "dot":
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=color)
        return
    ring_w = max(1, int(round(HUB_RING * u)))
    bbox = [cx - r, cy - r, cx + r, cy + r]
    if hub == "ring":
        draw.ellipse(bbox, outline=color, width=ring_w)
        return
    if hub == "reset":
        # PIL arcs: 0° = 3 o'clock, increasing clockwise. Leave a gap at
        # ~1 o'clock so the hub reads as a returning window, not a blob.
        draw.arc(bbox, start=40, end=320, fill=color, width=ring_w)
        ang = math.radians(40)
        ax = cx + r * math.cos(ang)
        ay = cy + r * math.sin(ang)
        tangent = ang + math.pi / 2
        ah = max(3.0, 4.6 * u)
        aw = max(2.2, 3.2 * u)
        tip = (ax + ah * math.cos(tangent), ay + ah * math.sin(tangent))
        left = (ax - aw * math.cos(ang), ay - aw * math.sin(ang))
        right = (ax + aw * math.cos(ang), ay + aw * math.sin(ang))
        draw.polygon([tip, left, right], fill=color)


def vertical_gradient(size, top, bottom):
    grad = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(1, size - 1)
        grad.putpixel(
            (0, y),
            tuple(int(round(top[i] + (bottom[i] - top[i]) * t)) for i in range(3)),
        )
    return grad.resize((size, size))


def render_icon(px, variant, supersample=8):
    """Render the full macOS tile icon at `px` pixels.

    variant: c4 ring hub | c5 ring + workspace frame | c6 reset-cycle hub + frame
    Returns an RGBA image with transparent surroundings (safe area respected).
    """
    S = px * supersample
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # macOS icon safe area: artwork inside the central ~82.4% squircle.
    tile = int(round(S * 0.824))
    off = (S - tile) // 2
    radius = int(round(tile * 0.2237))

    mask = Image.new("L", (tile, tile), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle([0, 0, tile - 1, tile - 1], radius=radius, fill=255)
    img.paste(vertical_gradient(tile, TILE_TOP, TILE_BOTTOM), (off, off), mask)

    # glyph box inside the tile (66% of tile side, centered); small sizes get
    # optical sizing: larger glyph box and heavier stroke to survive 16/32px.
    if px <= 32:
        box_ratio, stroke = 0.74, 11.5
    else:
        box_ratio, stroke = 0.66, STROKE
    u = tile * box_ratio / 100.0
    gx = off + (tile - 100 * u) / 2.0
    gy = off + (tile - 100 * u) / 2.0

    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)

    if variant in ("c5", "c6"):
        # Inner workspace window: the AgentHub surface sitting inside the app tile.
        fd = ImageDraw.Draw(img)
        inset = tile * 0.11
        frame = [
            off + inset,
            off + inset,
            off + tile - inset,
            off + tile - inset,
        ]
        fd.rounded_rectangle(
            frame,
            radius=int(round(tile * 0.16)),
            outline=(255, 255, 255, 64 if px >= 64 else 90),
            width=max(1, int(round(tile * (0.018 if px >= 64 else 0.028)))),
        )

    if variant == "c1":
        draw_glyph(ld, u, GLYPH_WHITE, stroke=stroke)
    elif variant == "c2":
        draw_glyph(ld, u, GLYPH_WHITE, stroke=stroke, hub="dot")
    elif variant == "c3":
        draw_polyline(ld, glyph_segments()[0], u, stroke, GLYPH_WHITE)
        for seg in glyph_segments()[1:]:
            draw_polyline(ld, seg, u, stroke, GLYPH_TINT)
    elif variant == "c4":
        draw_glyph(ld, u, GLYPH_WHITE, stroke=stroke, hub="ring")
    elif variant == "c5":
        draw_glyph(ld, u, GLYPH_WHITE, stroke=stroke, hub="ring")
    elif variant == "c6":
        draw_glyph(ld, u, GLYPH_WHITE, stroke=stroke, hub="reset")
    else:
        raise ValueError(f"unknown variant {variant}")

    # translate glyph layer into the tile
    img.alpha_composite(layer, (int(round(gx)), int(round(gy))))
    return img.resize((px, px), Image.LANCZOS)


def render_template(px, color=(0, 0, 0), stroke_scale=1.0, supersample=8):
    """Glyph-only monochrome template image (transparent background)."""
    S = px * supersample
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    box = S * 0.86
    u = box / 100.0
    ox = (S - box) / 2.0
    oy = (S - box) / 2.0
    sub = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sub)
    draw_glyph(sd, u, color, stroke=STROKE * stroke_scale, hub="ring")
    img.alpha_composite(sub, (int(round(ox)), int(round(oy))))
    return img.resize((px, px), Image.LANCZOS)


# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

def write_candidates(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for variant in ("c4", "c5", "c6"):
        render_icon(256, variant).save(os.path.join(out_dir, f"candidate-{variant}-256.png"))
        strip = Image.new("RGBA", (64 + 32 + 16 + 16, 64), (0, 0, 0, 0))
        x = 0
        for size in (64, 32, 16):
            icon = render_icon(size, variant)
            strip.alpha_composite(icon, (x, 64 - size))
            x += size + 8
        strip.save(os.path.join(out_dir, f"candidate-{variant}-small-strip.png"))
        dark = Image.new("RGBA", (256, 256), (28, 30, 34, 255))
        dark.alpha_composite(render_icon(200, variant), (28, 28))
        dark.save(os.path.join(out_dir, f"candidate-{variant}-on-dark.png"))
    print(f"candidates written to {out_dir}")


def write_final(resources_dir):
    os.makedirs(resources_dir, exist_ok=True)
    icon1024 = render_icon(1024, FINAL_VARIANT)
    png_path = os.path.join(resources_dir, "codexU-icon.png")
    icon1024.save(png_path)

    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "ah.iconset")
        os.makedirs(iconset)
        entries = {
            "icon_16x16.png": 16,
            "icon_16x16@2x.png": 32,
            "icon_32x32.png": 32,
            "icon_32x32@2x.png": 64,
            "icon_128x128.png": 128,
            "icon_128x128@2x.png": 256,
            "icon_256x256.png": 256,
            "icon_256x256@2x.png": 512,
            "icon_512x512.png": 512,
            "icon_512x512@2x.png": 1024,
        }
        for name, size in entries.items():
            if size <= 64:
                # optical sizing: direct redraw keeps the glyph legible
                img = render_icon(size, FINAL_VARIANT)
            else:
                img = icon1024.resize((size, size), Image.LANCZOS)
            img.save(os.path.join(iconset, name))
        subprocess.run(
            ["iconutil", "-c", "icns", iconset, "-o", os.path.join(resources_dir, "codexU.icns")],
            check=True,
        )
    print(f"final icons written to {resources_dir}")


def write_board(board_path):
    os.makedirs(os.path.dirname(board_path) or ".", exist_ok=True)
    W, H = 1560, 980
    board = Image.new("RGBA", (W, H), (244, 245, 247, 255))
    d = ImageDraw.Draw(board)

    def panel(x, y, w, h, fill):
        d.rounded_rectangle([x, y, x + w, y + h], radius=18, fill=fill)

    # top row: 512 color icon on light and dark panels, template pair beside
    panel(30, 30, 600, 600, (255, 255, 255, 255))
    board.alpha_composite(render_icon(512, FINAL_VARIANT), (74, 74))
    panel(660, 30, 600, 600, (30, 32, 38, 255))
    board.alpha_composite(render_icon(512, FINAL_VARIANT), (704, 74))
    panel(1290, 30, 240, 290, (30, 32, 38, 255))
    board.alpha_composite(render_template(160, color=(255, 255, 255)), (1330, 95))
    panel(1290, 340, 240, 290, (255, 255, 255, 255))
    board.alpha_composite(render_template(160), (1330, 405))

    # bottom row: scale ramp 128/64/32/16, color and template, light and dark
    panel(30, 660, 740, 290, (255, 255, 255, 255))
    x = 55
    for size in (128, 64, 32, 16):
        board.alpha_composite(render_icon(size, FINAL_VARIANT), (x, 660 + 145 - size // 2))
        x += size + 30
    for size in (128, 64, 32, 16):
        board.alpha_composite(render_template(size, stroke_scale=1.12 if size <= 32 else 1.0), (x, 660 + 145 - size // 2))
        x += size + 30
    panel(800, 660, 730, 290, (30, 32, 38, 255))
    x = 830
    for size in (128, 64, 32, 16):
        board.alpha_composite(render_icon(size, FINAL_VARIANT), (x, 660 + 145 - size // 2))
        x += size + 30
    for size in (128, 64, 32, 16):
        board.alpha_composite(render_template(size, color=(255, 255, 255), stroke_scale=1.12 if size <= 32 else 1.0), (x, 660 + 145 - size // 2))
        x += size + 30

    board.convert("RGB").save(board_path)
    print(f"acceptance board written to {board_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidates", metavar="DIR", help="render 3 candidate previews into DIR")
    parser.add_argument("--final", action="store_true", help="rewrite Resources/codexU-icon.png and codexU.icns")
    parser.add_argument("--board", metavar="PATH", help="render the brand acceptance board PNG")
    parser.add_argument("--resources", default="Resources", help="resources directory for --final")
    args = parser.parse_args()

    if not (args.candidates or args.final or args.board):
        parser.print_help()
        return 1
    if args.candidates:
        write_candidates(args.candidates)
    if args.final:
        write_final(args.resources)
    if args.board:
        write_board(args.board)
    return 0


if __name__ == "__main__":
    sys.exit(main())
