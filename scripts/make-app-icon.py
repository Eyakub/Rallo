#!/usr/bin/env python3
"""Builds apps/macos/Rallo/Resources/AppIcon.icns from the pet art.

    scripts/make-app-icon.py [--preview PNG]

macOS icon template: a 824 pt rounded square on a 1024 canvas with a soft
drop shadow. The tile is the art's own cream background with the red panda's
head and shoulders, cropped tight so the face still reads at 16 px. Needs
Pillow; `iconutil` ships with macOS.
"""
import subprocess, sys, tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets/pet/rallo/rallo_happy.png"
OUT = ROOT / "apps/macos/Rallo/Resources/AppIcon.icns"
CANVAS, TILE, RADIUS = 1024, 824, 186
# Head-and-shoulders square in the 1381x1139 source (face centred, ears in),
# and a head-only square for 16/32 px, where the body is just noise.
CROP = (40, 110, 1000, 1070)
CROP_SMALL = (90, 150, 790, 850)


def tile_mask(scale=4):
    big = Image.new("L", (TILE * scale, TILE * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, TILE * scale - 1, TILE * scale - 1), RADIUS * scale, fill=255)
    return big.resize((TILE, TILE), Image.LANCZOS)


def icon(crop=CROP):
    art = Image.open(SOURCE).convert("RGB").crop(crop).resize((TILE, TILE), Image.LANCZOS)
    # A faint warm vignette toward the bottom edge gives the flat cream some depth.
    shade = Image.new("L", (TILE, TILE), 0)
    ImageDraw.Draw(shade).rectangle((0, int(TILE * 0.72), TILE, TILE), fill=34)
    shade = shade.filter(ImageFilter.GaussianBlur(70))
    art = Image.composite(Image.new("RGB", (TILE, TILE), (214, 150, 110)), art, shade)
    mask = tile_mask()
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = ((CANVAS - TILE) // 2, (CANVAS - TILE) // 2)
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (offset[0], offset[1] + 12), mask)
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(18)))
    tile = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    tile.paste(art, (0, 0), mask)
    canvas.alpha_composite(tile, offset)
    return canvas


def main():
    image, small = icon(), icon(CROP_SMALL)
    if len(sys.argv) == 3 and sys.argv[1] == "--preview":
        image.save(sys.argv[2])
        small.save(sys.argv[2].replace(".png", "-small.png"))
        return
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale, suffix in ((1, ""), (2, "@2x")):
                pixels = size * scale
                source = small if pixels <= 32 else image
                source.resize((pixels, pixels), Image.LANCZOS).save(iconset / f"icon_{size}x{size}{suffix}.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT)], check=True)
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
