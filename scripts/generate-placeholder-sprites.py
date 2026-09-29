#!/usr/bin/env python3
"""Draws the TEMPORARY placeholder pet sprites (original art, not final).

Final release art replaces these in M3. Requires Pillow (developer-only).
Usage: scripts/generate-placeholder-sprites.py [output_dir]
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 192          # @2x pixels for a 96 pt sprite
SS = 4              # supersampling factor for antialiasing
S = SIZE * SS

BODY = (244, 162, 97, 255)
BODY_DARK = (214, 124, 64, 255)
BELLY = (255, 236, 214, 255)
INK = (46, 34, 40, 255)
CHEEK = (255, 138, 128, 150)
NOSE = (120, 62, 64, 255)


def px(v):
    return int(v * S)


def ellipse(draw, cx, cy, rx, ry, fill):
    draw.ellipse([px(cx - rx), px(cy - ry), px(cx + rx), px(cy + ry)], fill=fill)


def critter(pose):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse([px(0.22), px(0.86), px(0.78), px(0.95)], fill=(0, 0, 0, 70))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(px(0.02))))

    d = ImageDraw.Draw(img)
    # Tail
    ellipse(d, 0.80, 0.70, 0.13, 0.09, BODY_DARK)
    ellipse(d, 0.86, 0.66, 0.06, 0.05, BELLY)
    # Ears
    for side in (-1, 1):
        cx = 0.5 + side * 0.21
        d.polygon([(px(cx - 0.11), px(0.34)), (px(cx + side * 0.03), px(0.08)), (px(cx + 0.11), px(0.34))], fill=BODY)
        d.polygon([(px(cx - 0.055), px(0.31)), (px(cx + side * 0.02), px(0.16)), (px(cx + 0.055), px(0.31))], fill=BODY_DARK)
    # Body and belly
    ellipse(d, 0.5, 0.58, 0.33, 0.31, BODY)
    ellipse(d, 0.5, 0.70, 0.20, 0.17, BELLY)
    # Feet
    ellipse(d, 0.38, 0.88, 0.08, 0.04, BODY_DARK)
    ellipse(d, 0.62, 0.88, 0.08, 0.04, BODY_DARK)

    # Face
    blush = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(blush)
    ellipse(bd, 0.30, 0.58, 0.055, 0.035, CHEEK)
    ellipse(bd, 0.70, 0.58, 0.055, 0.035, CHEEK)
    img.alpha_composite(blush)
    d = ImageDraw.Draw(img)

    for cx in (0.37, 0.63):
        if pose == "idle":
            ellipse(d, cx, 0.50, 0.042, 0.052, INK)
            ellipse(d, cx + 0.014, 0.485, 0.014, 0.016, (255, 255, 255, 255))
        else:  # blink / sleep: closed, gently curved eyes
            d.arc([px(cx - 0.045), px(0.47), px(cx + 0.045), px(0.53)], 20, 160, fill=INK, width=px(0.014))
    ellipse(d, 0.5, 0.56, 0.022, 0.016, NOSE)
    d.arc([px(0.46), px(0.555), px(0.5), px(0.60)], 20, 160, fill=INK, width=px(0.009))
    d.arc([px(0.5), px(0.555), px(0.54), px(0.60)], 20, 160, fill=INK, width=px(0.009))

    if pose == "sleep":
        for (x, y, h) in ((0.80, 0.26, 0.06), (0.89, 0.15, 0.045)):
            w = px(0.009)
            d.line([(px(x - h / 2), px(y - h / 2)), (px(x + h / 2), px(y - h / 2)),
                    (px(x - h / 2), px(y + h / 2)), (px(x + h / 2), px(y + h / 2))], fill=INK, width=w, joint="curve")

    return img.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "assets/pet/placeholder")
    out.mkdir(parents=True, exist_ok=True)
    for pose in ("idle", "blink", "sleep"):
        critter(pose).save(out / f"pet-{pose}@2x.png", optimize=True)
        print(out / f"pet-{pose}@2x.png")


if __name__ == "__main__":
    main()
