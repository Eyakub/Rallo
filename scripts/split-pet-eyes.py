#!/usr/bin/env python3
"""Splits the idle pose's eyes onto their own layer so the app can move them.

Writes, next to the input, @2x and @1x of:
  pet-idle-base.png  the idle pose with the eyes painted over with fur
  pet-idle-eyes.png  only the eyes, on a transparent canvas of the same size

    scripts/split-pet-eyes.py assets/pet/rallo/pet-idle@2x.png

The eyes are the dark blobs in the top half that are taller than wide (the
ears, nose, and paws are wider or smaller). "Dark" is every channel under
140: the eyes fade to a lighter brown at the bottom, and the fur around them
is always brighter than that in red. Needs Pillow and numpy.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image


def components(mask):
    """4-connected components as lists of (y, x)."""
    seen = np.zeros_like(mask)
    height, width = mask.shape
    for y, x in zip(*np.nonzero(mask)):
        if seen[y, x]:
            continue
        seen[y, x] = True
        stack, points = [(y, x)], []
        while stack:
            cy, cx = stack.pop()
            points.append((cy, cx))
            for ny, nx in ((cy + 1, cx), (cy - 1, cx), (cy, cx + 1), (cy, cx - 1)):
                if 0 <= ny < height and 0 <= nx < width and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        yield points


def dilate(mask, steps):
    for _ in range(steps):
        grown = mask.copy()
        grown[1:] |= mask[:-1]
        grown[:-1] |= mask[1:]
        grown[:, 1:] |= mask[:, :-1]
        grown[:, :-1] |= mask[:, 1:]
        mask = grown
    return mask


def fill_holes(mask):
    """Adds enclosed gaps (the eye highlights) to the mask."""
    outside = np.zeros_like(mask)
    padded = np.pad(~mask, 1, constant_values=True)
    for points in components(padded):
        if any(y == 0 for y, _ in points):
            for y, x in points:
                if 0 < y <= mask.shape[0] and 0 < x <= mask.shape[1]:
                    outside[y - 1, x - 1] = True
            break
    return mask | ~outside


def eye_mask(rgba):
    dark = (rgba[..., :3].max(axis=-1) < 140) & (rgba[..., 3] > 200)
    eyes = np.zeros_like(dark)
    found = 0
    for points in components(dark):
        ys, xs = zip(*points)
        height, width = max(ys) - min(ys) + 1, max(xs) - min(xs) + 1
        if height >= 12 and height > width and np.mean(ys) < dark.shape[0] / 2:
            found += 1
            eyes[ys, xs] = True
    if found != 2:
        sys.exit(f"expected 2 eyes, found {found}")
    return fill_holes(eyes)


def inpaint(rgba, mask, iterations=600):
    """Fills `mask` smoothly from the pixels around it (premultiplied)."""
    alpha = rgba[..., 3:] / 255
    image = np.concatenate([rgba[..., :3] * alpha, alpha * 255], axis=-1)
    image[mask] = image[dilate(mask, 1) & ~mask].mean(axis=0)
    for _ in range(iterations):
        padded = np.pad(image, ((1, 1), (1, 1), (0, 0)), mode="edge")
        average = (padded[:-2, 1:-1] + padded[2:, 1:-1] + padded[1:-1, :-2] + padded[1:-1, 2:]) / 4
        image[mask] = average[mask]
    return unpremultiply(image)


def unpremultiply(image):
    alpha = image[..., 3:] / 255
    rgb = np.where(alpha > 0, image[..., :3] / np.maximum(alpha, 1e-6), 0)
    return np.concatenate([rgb, image[..., 3:]], axis=-1)


def save(rgba, path_2x):
    Image.fromarray(np.clip(rgba, 0, 255).round().astype(np.uint8)).save(path_2x)
    # @1x: premultiplied Lanczos, so transparent edges don't fringe.
    alpha = rgba[..., 3:] / 255
    premultiplied = np.concatenate([rgba[..., :3] * alpha, rgba[..., 3:]], axis=-1)
    size = (rgba.shape[1] // 2, rgba.shape[0] // 2)
    channels = [np.asarray(Image.fromarray(premultiplied[..., c].astype(np.float32)).resize(size, Image.LANCZOS))
                for c in range(4)]
    small = unpremultiply(np.stack(channels, axis=-1))
    Image.fromarray(np.clip(small, 0, 255).round().astype(np.uint8)).save(str(path_2x).replace("@2x", ""))


def main():
    source = Path(sys.argv[1])
    rgba = np.asarray(Image.open(source).convert("RGBA")).astype(float)
    eyes = eye_mask(rgba)
    # The eye layer takes the eyes plus half of their 1 px anti-aliased rim;
    # the base is painted over a pixel beyond that, so no dark edge shows
    # when the eyes move.
    soft = np.where(eyes, 1.0, np.where(dilate(eyes, 1), 0.5, 0.0))
    eyes_layer = rgba.copy()
    eyes_layer[..., 3] *= soft
    save(inpaint(rgba, dilate(eyes, 2)), source.with_name("pet-idle-base@2x.png"))
    save(eyes_layer, source.with_name("pet-idle-eyes@2x.png"))


if __name__ == "__main__":
    main()
