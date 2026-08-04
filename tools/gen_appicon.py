#!/usr/bin/env python3
"""Generate the Filler Killer app icon per the design spec: a speech bubble
with lowercase "um" struck out, on a Signal Indigo gradient squircle.

Run from repo root: python3 tools/gen_appicon.py
Writes macapp/FillerKiller/Assets.xcassets/AppIcon.appiconset/*.png
(regeneration is deliberate; commit the PNGs so CI needs no Pillow).
"""

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "macapp" / "FillerKiller" / "Assets.xcassets" / "AppIcon.appiconset"

CANVAS = 1024
MARGIN = 100  # transparent margin around the squircle (macOS convention)
TOP = (0x6E, 0x6C, 0xF0)
BOTTOM = (0x46, 0x44, 0xB8)
CORAL = (0xFF, 0x6B, 0x5E)
WORD_COLOR = (0x46, 0x44, 0xB8)


def rounded_gradient() -> Image.Image:
    size = CANVAS - 2 * MARGIN
    gradient = Image.new("RGBA", (size, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        row = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)) + (255,)
        for x in range(size):
            gradient.putpixel((x, y), row)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=int(size * 0.225), fill=255
    )
    gradient.putalpha(mask)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(gradient, (MARGIN, MARGIN), gradient)
    return canvas


def load_font(px: int) -> ImageFont.FreeTypeFont:
    for candidate in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansBold.ttf",
    ):
        if Path(candidate).exists():
            return ImageFont.truetype(candidate, px)
    raise SystemExit("no bold TTF font found")


def draw_icon() -> Image.Image:
    icon = rounded_gradient()
    draw = ImageDraw.Draw(icon)

    # Speech bubble
    bw, bh = 620, 460
    bx = (CANVAS - bw) // 2
    by = (CANVAS - bh) // 2 - 30
    draw.rounded_rectangle([bx, by, bx + bw, by + bh], radius=120, fill=(255, 255, 255, 255))
    draw.polygon([(380, by + bh - 8), (520, by + bh - 8), (350, by + bh + 88)],
                 fill=(255, 255, 255, 255))

    # The word
    font = load_font(300)
    text_box = draw.textbbox((0, 0), "um", font=font)
    tw = text_box[2] - text_box[0]
    th = text_box[3] - text_box[1]
    tx = bx + (bw - tw) // 2 - text_box[0]
    ty = by + (bh - th) // 2 - text_box[1] - 10
    draw.text((tx, ty), "um", font=font, fill=WORD_COLOR + (255,))

    # The strike: −18° through the word, round caps, drawn over it
    import math
    angle = math.radians(-18)
    cx, cy = bx + bw / 2, by + bh / 2 - 10
    half = tw / 2 + 60
    x0, y0 = cx - half * math.cos(angle), cy - half * math.sin(angle)
    x1, y1 = cx + half * math.cos(angle), cy + half * math.sin(angle)
    draw.line([(x0, y0), (x1, y1)], fill=CORAL + (255,), width=56)
    for px, py in ((x0, y0), (x1, y1)):
        draw.ellipse([px - 28, py - 28, px + 28, py + 28], fill=CORAL + (255,))

    return icon


SIZES = [16, 32, 64, 128, 256, 512, 1024]


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    master = draw_icon()
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            master.resize((px, px), Image.LANCZOS).save(OUT / f"icon_{pt}x{pt}@{scale}x.png")
            images.append({
                "size": f"{pt}x{pt}",
                "idiom": "mac",
                "filename": f"icon_{pt}x{pt}@{scale}x.png",
                "scale": f"{scale}x",
            })
    (OUT / "Contents.json").write_text(json.dumps(
        {"images": images, "info": {"version": 1, "author": "xcode"}}, indent=2
    ))
    print(f"wrote {len(images)} icon sizes to {OUT}")


if __name__ == "__main__":
    main()
