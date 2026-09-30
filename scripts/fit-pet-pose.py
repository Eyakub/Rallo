#!/usr/bin/env python3
"""Fits a pose edited from an existing sprite onto that sprite's canvas.

For art made by editing one pose (same body, new face), e.g. in an image
generator: cuts the character out with import-pet-art.py's matte, then
places it at the scale and offset where its silhouette overlaps the
reference's most, so the body stays put when the app switches between them.
Maximising overlap (rather than matching bounding boxes) keeps a changed
part, such as a paw moved further out, from rescaling the whole pet.

    scripts/fit-pet-pose.py drowsy=assets/pet/rallo/rallo_drowsy.png:assets/pet/rallo/pet-sleep@2x.png

Writes pet-<name>@2x.png and pet-<name>.png next to the reference and
prints how much of the reference's silhouette the result overlaps.
"""
import importlib.util
import sys
from pathlib import Path

import numpy as np
from PIL import Image

spec = importlib.util.spec_from_file_location("import_pet_art", Path(__file__).with_name("import-pet-art.py"))
import_pet_art = importlib.util.module_from_spec(spec)
spec.loader.exec_module(import_pet_art)


def silhouette(image):
    alpha = np.asarray(image.convert("RGBA"))[..., 3] > 128
    ys, xs = np.nonzero(alpha)
    return alpha, (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)


def place(image, scale, offset, size):
    scaled = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    canvas = Image.new(image.mode, size)
    canvas.paste(scaled.crop((-offset[0], -offset[1], size[0] - offset[0], size[1] - offset[1])))
    return canvas


def best_fit(matted, ref_alpha, ref_box, size):
    """Scale and offset with the highest silhouette overlap, starting from
    the bounding-box match and searching ±4 % scale and ±6 px."""
    rl, rt, rr, rb = ref_box
    alpha = matted.getchannel("A")
    _, (nl, nt, nr, nb) = silhouette(matted)
    guess = (((rr - rl) * (rb - rt)) / ((nr - nl) * (nb - nt))) ** 0.5
    best = (-1.0, guess, (0, 0))
    for scale in np.linspace(guess * 0.96, guess * 1.04, 33):
        centre = (round((rl + rr) / 2 - (nl + nr) / 2 * scale), round(rb - nb * scale))
        for dx in range(-6, 7):
            for dy in range(-6, 7):
                offset = (centre[0] + dx, centre[1] + dy)
                placed = np.asarray(place(alpha, scale, offset, size)) > 128
                overlap = (placed & ref_alpha).sum() / (placed | ref_alpha).sum()
                if overlap > best[0]:
                    best = (overlap, scale, offset)
    return best[1], best[2]


def fit(name, source, reference):
    ref_image = Image.open(reference).convert("RGBA")
    ref_alpha, ref_box = silhouette(ref_image)
    matted, _, _ = import_pet_art.local_gradient_matte(Image.open(source))
    scale, offset = best_fit(matted, ref_alpha, ref_box, ref_image.size)
    scaled = import_pet_art.resize_premultiplied(
        matted, (round(matted.width * scale), round(matted.height * scale)))
    canvas = Image.new("RGBA", ref_image.size)
    canvas.alpha_composite(scaled.crop((-offset[0], -offset[1], canvas.width - offset[0], canvas.height - offset[1])))
    out_2x = Path(reference).with_name(f"pet-{name}@2x.png")
    canvas.save(out_2x)
    import_pet_art.resize_premultiplied(canvas, (canvas.width // 2, canvas.height // 2)).save(
        str(out_2x).replace("@2x", ""))
    alpha, _ = silhouette(canvas)
    overlap = (alpha & ref_alpha).sum() / (alpha | ref_alpha).sum()
    print(f"{name}: scale {scale:.4f}, silhouette overlap with {Path(reference).name} {overlap:.1%}")


def main():
    for arg in sys.argv[1:]:
        name, paths = arg.split("=", 1)
        source, reference = paths.split(":", 1)
        fit(name, source, reference)


if __name__ == "__main__":
    main()
