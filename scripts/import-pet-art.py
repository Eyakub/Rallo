#!/usr/bin/env python3
"""Import a pet pose from a supplied SVG (an embedded base64 PNG) into
clean, transparent, pixel-perfect sprites for the Rallo pet.

The expected input is an SVG whose only drawable content is a single
<image href="data:image/png;base64,...">, e.g. what design tools export
when "flattening" a raster illustration. The PNG is usually composited
onto a solid background color (and may have a text caption baked in
below the character) rather than carrying real alpha.

This script:
  1. Extracts the embedded PNG losslessly (exact base64 decode).
  2. Removes the solid background with a local-gradient flood fill: it
     follows smooth gradients (a soft ground shadow) from the border
     inward, but stops at any sharp edge (the character's silhouette),
     so interior colors that merely resemble the background (e.g. cream
     muzzle fur) are never touched while a soft shadow is kept as
     translucent rather than being clipped or left as a solid halo.
  3. Finds the largest connected opaque blob (the character + its
     shadow) and crops to its tight bounds plus a small even margin,
     which also discards any separate smaller blob such as a baked-in
     text caption.
  4. Resamples to the requested @1x point width (aspect preserved) using
     premultiplied-alpha-aware Lanczos resizing, which avoids dark/light
     fringing on the transparent edges that a naive resize produces.

Usage:
    scripts/import-pet-art.py <input.svg> --pose idle --width 110 \\
        --out-dir assets/pet/rallo

Requires Pillow (developer-only), no other dependencies.
"""
import argparse
import base64
import re
import sys
from collections import deque
from pathlib import Path

from PIL import Image


def extract_png(svg_path: Path) -> bytes:
    data = svg_path.read_text(encoding="utf-8")
    matches = re.findall(r'<image[^>]*href="data:image/png;base64,([^"]+)"', data)
    if not matches:
        raise SystemExit(f"no embedded base64 PNG <image> found in {svg_path}")
    if len(matches) > 1:
        print(f"warning: {len(matches)} <image> elements found, using the first", file=sys.stderr)

    stripped = re.sub(r"<svg[^>]*>", "", data)
    stripped = re.sub(r"</svg>", "", stripped)
    stripped = re.sub(r"<title>.*?</title>", "", stripped, flags=re.S)
    stripped = re.sub(r"<image[^>]*/?>", "", stripped, flags=re.S)
    stripped = re.sub(r"<image[^>]*>.*?</image>", "", stripped, flags=re.S)
    if stripped.strip():
        print(
            "warning: SVG has vector content beyond the embedded <image>; "
            "this script only extracts the raster image — render the SVG "
            "separately (e.g. qlmanage -t) and compare.",
            file=sys.stderr,
        )

    return base64.b64decode(matches[0])


def _dist(a, b):
    return abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2])


def local_gradient_matte(im: Image.Image, step_tol=14, t0=6, t1=130) -> Image.Image:
    """Flood-fills the background from the border, following smooth local
    gradients (soft shadow) but stopping at hard silhouette edges, then
    turns the connected region into a properly anti-aliased alpha ramp
    with background color removed from partially-transparent edges."""
    im = im.convert("RGB")
    w, h = im.size
    px = im.load()

    from collections import Counter

    counts = Counter()
    for x in range(w):
        counts[px[x, 0]] += 1
        counts[px[x, h - 1]] += 1
    for y in range(h):
        counts[px[0, y]] += 1
        counts[px[w - 1, y]] += 1
    bg = counts.most_common(1)[0][0]

    def idx(x, y):
        return y * w + x

    connected = bytearray(w * h)
    visited = bytearray(w * h)
    q = deque()

    for x in range(w):
        for y in (0, h - 1):
            i = idx(x, y)
            if not visited[i]:
                visited[i] = 1
                connected[i] = 1
                q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            i = idx(x, y)
            if not visited[i]:
                visited[i] = 1
                connected[i] = 1
                q.append((x, y))

    while q:
        x, y = q.popleft()
        c0 = px[x, y]
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h:
                ni = idx(nx, ny)
                if not visited[ni]:
                    c1 = px[nx, ny]
                    if _dist(c0, c1) <= step_tol:
                        visited[ni] = 1
                        connected[ni] = 1
                        q.append((nx, ny))

    out = Image.new("RGBA", (w, h))
    opx = out.load()
    for y in range(h):
        for x in range(w):
            i = idx(x, y)
            c = px[x, y]
            if connected[i]:
                d = _dist(c, bg)
                a = max(0.0, min(1.0, (d - t0) / (t1 - t0)))
                if a <= 0.003:
                    opx[x, y] = (bg[0], bg[1], bg[2], 0)
                elif a >= 0.995:
                    opx[x, y] = (c[0], c[1], c[2], 255)
                else:
                    r = max(0, min(255, round(bg[0] + (c[0] - bg[0]) / a)))
                    g = max(0, min(255, round(bg[1] + (c[1] - bg[1]) / a)))
                    b = max(0, min(255, round(bg[2] + (c[2] - bg[2]) / a)))
                    opx[x, y] = (r, g, b, round(a * 255))
            else:
                opx[x, y] = (c[0], c[1], c[2], 255)
    return out


def largest_component_bbox(alpha: Image.Image):
    """Finds the bounding box of the largest 4-connected component of
    non-zero alpha pixels, ignoring smaller separate blobs (e.g. a
    baked-in text caption below the character)."""
    w, h = alpha.size
    a = alpha.load()
    visited = bytearray(w * h)
    best_bbox = None
    best_size = 0

    def idx(x, y):
        return y * w + x

    for y in range(h):
        for x in range(w):
            i = idx(x, y)
            if visited[i] or a[x, y] == 0:
                continue
            q = deque([(x, y)])
            visited[i] = 1
            minx = maxx = x
            miny = maxy = y
            size = 0
            while q:
                cx, cy = q.popleft()
                size += 1
                minx, maxx = min(minx, cx), max(maxx, cx)
                miny, maxy = min(miny, cy), max(maxy, cy)
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = cx + dx, cy + dy
                    if 0 <= nx < w and 0 <= ny < h:
                        ni = idx(nx, ny)
                        if not visited[ni] and a[nx, ny] != 0:
                            visited[ni] = 1
                            q.append((nx, ny))
            if size > best_size:
                best_size = size
                best_bbox = (minx, miny, maxx + 1, maxy + 1)
    return best_bbox


def resize_premultiplied(im: Image.Image, size) -> Image.Image:
    """Lanczos-resamples an RGBA image in premultiplied-alpha space
    (via compositing over black) so transparent edges don't pick up a
    dark or light fringe from the naive straight-alpha average."""
    im = im.convert("RGBA")
    w, h = im.size
    black = Image.new("RGBA", (w, h), (0, 0, 0, 255))
    premult_rgb = Image.alpha_composite(black, im).convert("RGB")
    alpha = im.split()[-1]

    premult_small = premult_rgb.resize(size, Image.LANCZOS)
    alpha_small = alpha.resize(size, Image.LANCZOS)

    pw, ph = size
    pr = premult_small.load()
    ar = alpha_small.load()
    out = Image.new("RGBA", size)
    op = out.load()
    for y in range(ph):
        for x in range(pw):
            a = ar[x, y]
            if a <= 0:
                op[x, y] = (0, 0, 0, 0)
                continue
            r, g, b = pr[x, y]
            scale = 255.0 / a
            op[x, y] = (
                min(255, round(r * scale)),
                min(255, round(g * scale)),
                min(255, round(b * scale)),
                a,
            )
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("svg", type=Path, help="input SVG with an embedded base64 PNG")
    ap.add_argument("--pose", required=True, help="pose name, e.g. idle, blink, sleep")
    ap.add_argument("--width", type=int, default=110, help="target @1x width in points (default 110)")
    ap.add_argument("--margin", type=int, default=6, help="transparent margin in source px around the tight bbox (default 6)")
    ap.add_argument("--out-dir", type=Path, default=Path("assets/pet/rallo"), help="output directory")
    args = ap.parse_args()

    png_bytes = extract_png(args.svg)
    src = Image.open(__import__("io").BytesIO(png_bytes))
    print(f"source PNG: {src.size[0]}x{src.size[1]} {src.mode}")

    matted = local_gradient_matte(src)

    bbox = largest_component_bbox(matted.split()[-1])
    if bbox is None:
        raise SystemExit("no opaque content found after matting")
    l, t, r, b = bbox
    w, h = matted.size
    l = max(0, l - args.margin)
    t = max(0, t - args.margin)
    r = min(w, r + args.margin)
    b = min(h, b + args.margin)
    cropped = matted.crop((l, t, r, b))
    print(f"cropped to {cropped.size[0]}x{cropped.size[1]} (bbox {l},{t},{r},{b})")

    cw, ch = cropped.size
    target_w1 = args.width
    target_h1 = round(target_w1 * ch / cw)
    target_w2 = target_w1 * 2
    target_h2 = target_h1 * 2

    if target_w2 > cw:
        scale = cw / target_w2
        target_w1 = int(target_w1 * scale)
        target_h1 = round(target_w1 * ch / cw)
        target_w2, target_h2 = target_w1 * 2, target_h1 * 2
        print(
            f"note: source resolution ({cw}px wide) is smaller than the requested "
            f"2x target; reduced point width to {target_w1}pt so 2x stays <= source size",
            file=sys.stderr,
        )

    sprite_1x = resize_premultiplied(cropped, (target_w1, target_h1))
    sprite_2x = resize_premultiplied(cropped, (target_w2, target_h2))

    args.out_dir.mkdir(parents=True, exist_ok=True)
    out_1x = args.out_dir / f"pet-{args.pose}.png"
    out_2x = args.out_dir / f"pet-{args.pose}@2x.png"
    sprite_1x.save(out_1x)
    sprite_2x.save(out_2x)
    print(f"wrote {out_1x} ({sprite_1x.size[0]}x{sprite_1x.size[1]})")
    print(f"wrote {out_2x} ({sprite_2x.size[0]}x{sprite_2x.size[1]})")
    print(f"point size: {target_w1} x {target_h1} pt")


if __name__ == "__main__":
    main()
