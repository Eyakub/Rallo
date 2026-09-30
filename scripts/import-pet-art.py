#!/usr/bin/env python3
"""Import Rallo's pet poses from supplied SVGs (each an embedded base64
PNG) into clean, transparent, pixel-perfect sprites, all sharing one
common canvas so switching poses never makes the pet jump in size or
position.

The expected input for each pose is an SVG whose only drawable content
is a single <image href="data:image/png;base64,...">, e.g. what design
tools export when "flattening" a raster illustration. The PNG is
usually composited onto a solid background color (and may have a text
caption baked in below the character) rather than carrying real alpha.

For each pose this script:
  1. Extracts the embedded PNG losslessly (exact base64 decode).
  2. Mattes the character with a foreground-aware technique:
       - A local-gradient flood fill from the border finds the
         background-connected region; everything else is the character
         mask M.
       - Near the silhouette boundary (within a few px on either side),
         the true foreground colour F is estimated from nearby
         confidently-interior character pixels, and alpha is the
         orthogonal projection of the pixel colour onto the
         background->foreground line (alpha = dot(C-B,F-B)/|F-B|^2).
         Partial pixels are recoloured to F (defringing/colour-bleed)
         instead of keeping their background-contaminated blend, which
         is what caused a pale fringe on dark backdrops previously.
         Thin structures with no nearby interior neighbour (whiskers,
         tufts) fall back to a distance ratio normalised by the nearest
         character colour, so they stay dark rather than pale.
       - A separate ground-shadow pass looks in a band just below the
         character for pixels that are a near-uniform darkening of the
         background (a soft drop shadow rather than character fur) and
         re-expresses them as a warm paw-ink tone at an alpha derived
         from luma falloff, so the shadow reads as a darkening on any
         backdrop instead of a solid halo.
  3. Finds the largest connected character blob (M) plus any shadow
     pixels found near it, and crops to that tight union, which also
     discards a separate smaller blob such as a baked-in text caption.
  4. When multiple poses are given together, normalises their scale
     (matched via the geometric mean of each character's own silhouette
     bounding box, calibrated against the smallest-source pose so
     nothing is ever upscaled beyond its native resolution) and
     composites every pose onto one shared canvas, bottom-centre
     aligned so the feet/shadow baseline lines up across poses.
  5. Resamples with premultiplied-alpha-aware Lanczos resizing, which
     avoids dark/light fringing on the transparent edges that a naive
     resize produces.

Usage (all poses together, recommended -- scale is relative, so add a
new pose by re-running the full set):
    scripts/import-pet-art.py \\
        --pose idle=hero.svg --pose sleep=resting.svg \\
        --pose nudge=nudge.svg --pose celebrate=all_done.svg \\
        --shadow-band-bottom celebrate=30 \\
        --out-dir assets/pet/rallo

Usage (single pose, fit to its own content -- no cross-pose scale
normalisation or shared canvas):
    scripts/import-pet-art.py --pose idle=hero.svg --width 110 \\
        --out-dir assets/pet/rallo

Requires Pillow (developer-only), no other dependencies.
"""
import argparse
import base64
import io
import re
import sys
from collections import Counter, deque
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


def _luma(c):
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def local_gradient_matte(
    im: Image.Image,
    step_tol=14,
    boundary_radius=3,
    fg_radius=4,
    shadow_ink=(43, 26, 19),
    shadow_spread_max=0.15,
    shadow_ratio_max=0.995,
    shadow_band_frac=0.06,
    shadow_band_min=10,
    shadow_band_max=20,
    shadow_band_bottom=None,
):
    """Foreground-aware matte. Returns (rgba_image, body_bbox, shadow_bbox).

    body_bbox is the tight bounds of the largest connected character
    blob (M); shadow_bbox is the tight bounds of any ground-shadow
    pixels found near its bottom edge, or None if none were found.
    """
    im = im.convert("RGB")
    w, h = im.size
    px = im.load()

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

    # --- border flood fill: connected = background-reachable region ---
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
    # M = character mask = not connected

    # --- largest connected component of M -> body_bbox (excludes any
    # baked-in text caption, which forms its own small M component) ---
    visited2 = bytearray(w * h)
    body_bbox = None
    body_size = 0
    for y in range(h):
        for x in range(w):
            i = idx(x, y)
            if visited2[i] or connected[i]:
                continue
            qq = deque([(x, y)])
            visited2[i] = 1
            minx = maxx = x
            miny = maxy = y
            size = 0
            while qq:
                cx, cy = qq.popleft()
                size += 1
                minx, maxx = min(minx, cx), max(maxx, cx)
                miny, maxy = min(miny, cy), max(maxy, cy)
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = cx + dx, cy + dy
                    if 0 <= nx < w and 0 <= ny < h:
                        ni = idx(nx, ny)
                        if not visited2[ni] and not connected[ni]:
                            visited2[ni] = 1
                            qq.append((nx, ny))
            if size > body_size:
                body_size = size
                body_bbox = (minx, miny, maxx + 1, maxy + 1)
    if body_bbox is None:
        raise SystemExit("no opaque content found (character mask empty)")
    bl, bt, br, bb = body_bbox
    body_h = bb - bt

    # Ground shadow is searched for only in a band hugging the body's
    # bottom edge, not the whole canvas -- this is what lets a soft
    # drop shadow be recovered even where the flood fill already
    # swallowed it as "background", while a baked-in text caption
    # further below (which reads as a near-uniform darkening too) is
    # never reached. Grounded poses need only a small band; a floating
    # pose with a real gap to its shadow needs shadow_band_bottom raised
    # via the CLI.
    shadow_margin = max(shadow_band_min, min(shadow_band_max, round(shadow_band_frac * body_h)))
    bottom_margin = shadow_band_bottom if shadow_band_bottom is not None else shadow_margin
    band_top = bb - shadow_margin
    band_bottom = bb + bottom_margin
    band_left = bl - max(shadow_margin, bottom_margin)
    band_right = br + max(shadow_margin, bottom_margin)

    def in_shadow_band(x, y):
        return band_left <= x < band_right and band_top <= y < band_bottom

    # --- distance transforms (capped at boundary_radius) ---
    INF = boundary_radius + 1
    dist_to_bg = [INF] * (w * h)  # for M pixels: distance to nearest BGCONN pixel
    dist_to_m = [INF] * (w * h)   # for BGCONN pixels: distance to nearest M pixel

    dq = deque()
    for y in range(h):
        for x in range(w):
            i = idx(x, y)
            if connected[i]:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and connected[idx(nx, ny)]:
                    dist_to_bg[i] = 1
                    dq.append((x, y))
                    break
    while dq:
        x, y = dq.popleft()
        d = dist_to_bg[idx(x, y)]
        if d >= boundary_radius:
            continue
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h:
                ni = idx(nx, ny)
                if not connected[ni] and dist_to_bg[ni] > d + 1:
                    dist_to_bg[ni] = d + 1
                    dq.append((nx, ny))

    dq = deque()
    for y in range(h):
        for x in range(w):
            i = idx(x, y)
            if not connected[i]:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and not connected[idx(nx, ny)]:
                    dist_to_m[i] = 1
                    dq.append((x, y))
                    break
    while dq:
        x, y = dq.popleft()
        d = dist_to_m[idx(x, y)]
        if d >= boundary_radius:
            continue
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h:
                ni = idx(nx, ny)
                if connected[ni] and dist_to_m[ni] > d + 1:
                    dist_to_m[ni] = d + 1
                    dq.append((nx, ny))

    def is_shadow_color(c):
        r = [c[k] / bg[k] if bg[k] else 1.0 for k in range(3)]
        mx, mn = max(r), min(r)
        return (mx - mn) <= shadow_spread_max and mx < shadow_ratio_max

    def shadow_alpha(c):
        lbg = _luma(bg)
        link = _luma(shadow_ink)
        lc = _luma(c)
        if lbg - link <= 0:
            return 0.0
        return max(0.0, min(1.0, (lbg - lc) / (lbg - link)))

    def estimate_fg(x, y):
        """Weighted average colour of nearby confidently-interior (eroded)
        character pixels, within fg_radius. None if none are found."""
        total_w = 0.0
        sr = sg = sb = 0.0
        r2 = fg_radius * fg_radius
        for dy in range(-fg_radius, fg_radius + 1):
            for dx in range(-fg_radius, fg_radius + 1):
                d2 = dx * dx + dy * dy
                if d2 > r2:
                    continue
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h:
                    ni = idx(nx, ny)
                    if not connected[ni] and dist_to_bg[ni] >= boundary_radius:
                        wgt = 1.0 / (1.0 + d2 ** 0.5)
                        c = px[nx, ny]
                        sr += wgt * c[0]
                        sg += wgt * c[1]
                        sb += wgt * c[2]
                        total_w += wgt
        if total_w == 0.0:
            return None
        return (sr / total_w, sg / total_w, sb / total_w)

    def nearest_character(x, y, max_r=8):
        """Weighted average colour of nearby character pixels (no erosion
        requirement), used as a fallback colour-bleed source."""
        total_w = 0.0
        sr = sg = sb = 0.0
        r2 = max_r * max_r
        for dy in range(-max_r, max_r + 1):
            for dx in range(-max_r, max_r + 1):
                d2 = dx * dx + dy * dy
                if d2 > r2:
                    continue
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h:
                    ni = idx(nx, ny)
                    if not connected[ni]:
                        wgt = 1.0 / (1.0 + d2 ** 0.5)
                        c = px[nx, ny]
                        sr += wgt * c[0]
                        sg += wgt * c[1]
                        sb += wgt * c[2]
                        total_w += wgt
        if total_w == 0.0:
            return bg
        return (sr / total_w, sg / total_w, sb / total_w)

    def boundary_alpha_color(x, y, c):
        F = estimate_fg(x, y)
        if F is not None:
            fb = (F[0] - bg[0], F[1] - bg[1], F[2] - bg[2])
            denom = fb[0] * fb[0] + fb[1] * fb[1] + fb[2] * fb[2]
            if denom < 25.0:
                F = None
        if F is None:
            # No confidently-interior neighbour close enough, or its colour
            # is itself too close to bg to project reliably (thin
            # whisker/tuft, or a light fur highlight near the cream
            # backdrop): fall back to a distance ratio normalised by the
            # nearest character colour instead, and bleed that colour so
            # partial pixels stay close to real fur/ink tone rather than a
            # pale straight-line blend with bg.
            nc = nearest_character(x, y)
            norm = max(_dist(bg, nc), 40.0)
            a = max(0.0, min(1.0, _dist(bg, c) / norm))
            return a, nc
        cb = (c[0] - bg[0], c[1] - bg[1], c[2] - bg[2])
        dot = cb[0] * fb[0] + cb[1] * fb[1] + cb[2] * fb[2]
        a = max(0.0, min(1.0, dot / denom))
        if a >= 0.995:
            return 1.0, c
        if a <= 0.003:
            return 0.0, bg
        return a, F

    out = Image.new("RGBA", (w, h))
    opx = out.load()
    shadow_minx = shadow_miny = None
    shadow_maxx = shadow_maxy = None
    for y in range(h):
        for x in range(w):
            i = idx(x, y)
            c = px[x, y]
            is_shadow = False
            if connected[i]:
                if in_shadow_band(x, y) and is_shadow_color(c):
                    a = shadow_alpha(c)
                    color = shadow_ink
                    is_shadow = True
                else:
                    d = dist_to_m[i]
                    if d <= boundary_radius:
                        a, color = boundary_alpha_color(x, y, c)
                    else:
                        a, color = 0.0, bg
            else:
                d = dist_to_bg[i]
                if d > boundary_radius:
                    a, color = 1.0, c
                else:
                    a, color = boundary_alpha_color(x, y, c)

            if a <= 0.003:
                opx[x, y] = (bg[0], bg[1], bg[2], 0)
            else:
                cc = (
                    max(0, min(255, round(color[0]))),
                    max(0, min(255, round(color[1]))),
                    max(0, min(255, round(color[2]))),
                )
                if a >= 0.995:
                    opx[x, y] = (cc[0], cc[1], cc[2], 255)
                else:
                    opx[x, y] = (cc[0], cc[1], cc[2], round(a * 255))
                if is_shadow:
                    shadow_minx = x if shadow_minx is None else min(shadow_minx, x)
                    shadow_maxx = x if shadow_maxx is None else max(shadow_maxx, x)
                    shadow_miny = y if shadow_miny is None else min(shadow_miny, y)
                    shadow_maxy = y if shadow_maxy is None else max(shadow_maxy, y)

    shadow_bbox = None
    if shadow_minx is not None:
        shadow_bbox = (shadow_minx, shadow_miny, shadow_maxx + 1, shadow_maxy + 1)
    return out, body_bbox, shadow_bbox


def resize_premultiplied(im: Image.Image, size) -> Image.Image:
    """Lanczos-resamples an RGBA image in premultiplied-alpha space
    (via compositing over black) so transparent edges don't pick up a
    dark or light fringe from the naive straight-alpha average."""
    im = im.convert("RGBA")
    w, h = im.size
    size = (max(1, size[0]), max(1, size[1]))
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


def _geo_mean_wh(bbox):
    l, t, r, b = bbox
    return ((r - l) * (b - t)) ** 0.5


def _union_bbox(a, b):
    if b is None:
        return a
    return (min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3]))


def _parse_kv(args, cast=str):
    out = {}
    for item in args or []:
        if "=" not in item:
            raise SystemExit(f"expected name=value, got {item!r}")
        name, _, value = item.partition("=")
        out[name] = cast(value)
    return out


def process_pose(svg_path: Path, shadow_band_bottom=None):
    png_bytes = extract_png(svg_path)
    src = Image.open(io.BytesIO(png_bytes))
    print(f"  source PNG: {src.size[0]}x{src.size[1]} {src.mode}")
    kwargs = {} if shadow_band_bottom is None else {"shadow_band_bottom": shadow_band_bottom}
    matted, body_bbox, shadow_bbox = local_gradient_matte(src, **kwargs)
    content_bbox = _union_bbox(body_bbox, shadow_bbox)
    return dict(matted=matted, body_bbox=body_bbox, shadow_bbox=shadow_bbox, content_bbox=content_bbox)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument(
        "--pose", action="append", required=True, metavar="name=svg",
        help="pose name and input SVG, e.g. --pose idle=hero.svg (repeatable)",
    )
    ap.add_argument(
        "--shadow-band-bottom", action="append", metavar="name=px",
        help="override the ground-shadow search depth (source px below the "
             "character) for a specific pose, e.g. a floating pose with a "
             "real gap to its shadow: --shadow-band-bottom celebrate=30",
    )
    ap.add_argument("--width", type=int, default=110, help="single-pose mode only: target @1x width in points (default 110)")
    ap.add_argument("--margin", type=int, default=6, help="single-pose mode only: transparent margin in source px around the tight bbox (default 6)")
    ap.add_argument("--margin-x", type=int, default=10, help="shared-canvas mode: left/right breathing room in scaled px (default 10)")
    ap.add_argument("--margin-top", type=int, default=10, help="shared-canvas mode: headroom above the tallest pose in scaled px (default 10)")
    ap.add_argument("--margin-bottom", type=int, default=6, help="shared-canvas mode: gap below the baseline in scaled px (default 6)")
    ap.add_argument("--out-dir", type=Path, default=Path("assets/pet/rallo"), help="output directory")
    args = ap.parse_args()

    poses = _parse_kv(args.pose, cast=Path)
    shadow_overrides = _parse_kv(args.shadow_band_bottom, cast=int)
    unknown = set(shadow_overrides) - set(poses)
    if unknown:
        raise SystemExit(f"--shadow-band-bottom for unknown pose(s): {sorted(unknown)}")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    results = {}
    for name, svg_path in poses.items():
        print(f"pose {name!r}: {svg_path}")
        results[name] = process_pose(svg_path, shadow_overrides.get(name))
        print(f"  body_bbox={results[name]['body_bbox']} shadow_bbox={results[name]['shadow_bbox']} "
              f"content_bbox={results[name]['content_bbox']}")

    if len(results) == 1:
        # Single-pose mode: fit to this pose's own content, independent of
        # any shared canvas (no cross-pose scale normalisation possible
        # with only one pose).
        (name, r), = results.items()
        l, t, rr, b = r["content_bbox"]
        w, h = r["matted"].size
        l = max(0, l - args.margin)
        t = max(0, t - args.margin)
        rr = min(w, rr + args.margin)
        b = min(h, b + args.margin)
        cropped = r["matted"].crop((l, t, rr, b))
        cw, ch = cropped.size
        target_w1 = args.width
        target_h1 = round(target_w1 * ch / cw)
        target_w2, target_h2 = target_w1 * 2, target_h1 * 2
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
        out_1x = args.out_dir / f"pet-{name}.png"
        out_2x = args.out_dir / f"pet-{name}@2x.png"
        sprite_1x.save(out_1x)
        sprite_2x.save(out_2x)
        print(f"wrote {out_1x} ({sprite_1x.size[0]}x{sprite_1x.size[1]})")
        print(f"wrote {out_2x} ({sprite_2x.size[0]}x{sprite_2x.size[1]})")
        print(f"point size: {target_w1} x {target_h1} pt")
        return

    # Shared-canvas mode: normalise scale across poses via the geometric
    # mean of each character's own silhouette bbox (body_bbox, not
    # including its shadow), calibrated against the smallest-source pose
    # so nothing is ever upscaled beyond its native resolution.
    ref_val = min(_geo_mean_wh(r["body_bbox"]) for r in results.values())
    for name, r in results.items():
        r["scale"] = ref_val / _geo_mean_wh(r["body_bbox"])
        l, t, rr, b = r["content_bbox"]
        r["scaled_w"] = (rr - l) * r["scale"]
        r["scaled_h"] = (b - t) * r["scale"]
        print(f"pose {name!r}: scale={r['scale']:.4f} scaled_content={r['scaled_w']:.1f}x{r['scaled_h']:.1f}")

    content_w = max(r["scaled_w"] for r in results.values())
    content_h = max(r["scaled_h"] for r in results.values())
    canvas_w2 = round(content_w + 2 * args.margin_x)
    canvas_h2 = round(content_h + args.margin_top + args.margin_bottom)
    if canvas_w2 % 2:
        canvas_w2 += 1
    if canvas_h2 % 2:
        canvas_h2 += 1
    target_w1, target_h1 = canvas_w2 // 2, canvas_h2 // 2
    print(f"common canvas: {target_w1}x{target_h1} pt ({canvas_w2}x{canvas_h2} @2x)")

    for name, r in results.items():
        matted = r["matted"]
        l, t, rr, b = r["content_bbox"]
        bl, bt, br, bb = r["body_bbox"]
        cropped = matted.crop((l, t, rr, b))

        for scale_mul, canvas_w, canvas_h, suffix in (
            (1.0, canvas_w2, canvas_h2, "@2x"),
            (0.5, target_w1, target_h1, ""),
        ):
            tw = max(1, round(r["scaled_w"] * scale_mul))
            th = max(1, round(r["scaled_h"] * scale_mul))
            scaled = resize_premultiplied(cropped, (tw, th))
            canvas = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
            body_center_local = ((bl + br) / 2 - l) * r["scale"] * scale_mul
            px_off = round(canvas_w / 2 - body_center_local)
            py_off = canvas_h - th - round(args.margin_bottom * scale_mul)
            canvas.paste(scaled, (px_off, py_off), scaled)
            out_path = args.out_dir / f"pet-{name}{suffix}.png"
            canvas.save(out_path)
            print(f"wrote {out_path} ({canvas.size[0]}x{canvas.size[1]})")


if __name__ == "__main__":
    main()
