#!/usr/bin/env python3
"""Generate the menu bar (status item) template icon: the app icon's speech
bubble with the strike-through, reduced to a monochrome 18pt glyph so the
menu bar mark and the Dock icon read as the same identity.

Template image: pure black + alpha; macOS recolors it for menu bar state.
The strike gets a knockout gap through the bubble outline (like SF's
*.slash symbols) so it stays legible at 18px.

Run from repo root: python3 tools/gen_menubar_icon.py
Writes macapp/FillerKiller/Assets.xcassets/MenuBarIcon.imageset/*.png
(regeneration is deliberate; commit the PNGs so CI needs no Pillow).
"""

import json
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "macapp" / "FillerKiller" / "Assets.xcassets" / "MenuBarIcon.imageset"

# Supersample: draw at 16x the 1x point size, downsample with LANCZOS.
BASE = 18
SS = 16
CANVAS = BASE * SS  # 288


def draw_glyph() -> Image.Image:
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    stroke = 26  # ~1.6px at 18pt

    # Speech bubble outline + tail (proportions echo the app icon).
    bx0, by0 = 24, 34
    bx1, by1 = CANVAS - 24, 208
    draw.rounded_rectangle([bx0, by0, bx1, by1], radius=56,
                           outline=(0, 0, 0, 255), width=stroke)
    tail = [(96, by1 - stroke // 2), (166, by1 - stroke // 2), (84, 262)]
    draw.polygon(tail, fill=(0, 0, 0, 255))

    # The strike, −18° like the app icon, with a knockout gap so it reads
    # as a slash rather than merging with the outline.
    angle = math.radians(-18)
    cx, cy = CANVAS / 2, (by0 + by1) / 2
    half = (bx1 - bx0) / 2 + 30
    x0, y0 = cx - half * math.cos(angle), cy - half * math.sin(angle)
    x1, y1 = cx + half * math.cos(angle), cy + half * math.sin(angle)

    knockout = Image.new("L", (CANVAS, CANVAS), 0)
    kdraw = ImageDraw.Draw(knockout)
    kdraw.line([(x0, y0), (x1, y1)], fill=255, width=stroke * 3)
    for px, py in ((x0, y0), (x1, y1)):
        r = stroke * 3 // 2
        kdraw.ellipse([px - r, py - r, px + r, py + r], fill=255)
    alpha = img.getchannel("A")
    img.putalpha(ImageChops.subtract(alpha, knockout))

    draw = ImageDraw.Draw(img)
    draw.line([(x0, y0), (x1, y1)], fill=(0, 0, 0, 255), width=stroke)
    for px, py in ((x0, y0), (x1, y1)):
        r = stroke // 2
        draw.ellipse([px - r, py - r, px + r, py + r], fill=(0, 0, 0, 255))
    return img


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    master = draw_glyph()
    images = []
    for scale in (1, 2):
        px = BASE * scale
        master.resize((px, px), Image.LANCZOS).save(OUT / f"menubar_{px}.png")
        images.append({
            "idiom": "universal",
            "filename": f"menubar_{px}.png",
            "scale": f"{scale}x",
        })
    (OUT / "Contents.json").write_text(json.dumps(
        {
            "images": images,
            "info": {"version": 1, "author": "xcode"},
            "properties": {"template-rendering-intent": "template"},
        },
        indent=2,
    ))
    print(f"wrote MenuBarIcon 1x/2x to {OUT}")


if __name__ == "__main__":
    main()
