# Rallo pet art — source of truth

## Provenance

The `idle` pose was supplied by the user on 2026-09-30 as
`rallo_exact_nudge.svg` (title "Rallo — A Gentle Nudge Pose"), an SVG
whose only content is a single `<image>` embedding a base64 PNG
(285x255px, RGB, no alpha, opaque cream background `#FCF8EF`, with a
baked-in "A gentle nudge" text caption below the character). The
character (a seated red panda with a raised paw and a soft ground
shadow) was cut out, background-matted, and resampled to sprite size.
The text caption was discarded — it is not part of the character art.

## Files

| File | Size (px) | Notes |
|---|---|---|
| `pet-idle.png` | 110 x 92 | @1x, used on standard-DPI displays |
| `pet-idle@2x.png` | 220 x 184 | @2x, used on Retina displays |

Point size in the app: 110 x 92 pt (`PetPanel.spriteSize`). The
character was cropped to its tight bounds plus a small even margin, so
the source (245x201px content inside a 285x255px canvas) comfortably
covers the @2x export without upscaling.

## How these were produced

`scripts/import-pet-art.py` (repo root) is the reproducible pipeline:

```
scripts/import-pet-art.py rallo_exact_nudge.svg --pose idle --width 110 \
    --out-dir assets/pet/rallo
```

It: (1) decodes the embedded base64 PNG losslessly; (2) removes the
solid background with a local-gradient flood fill that follows smooth
gradients (the soft ground shadow) from the border inward but stops at
any sharp edge (the character's silhouette), so interior colors that
merely resemble the background — e.g. the cream muzzle — are never
touched, while the shadow is kept as a genuine soft translucent shape
instead of being clipped or left as a solid halo; (3) finds the largest
connected opaque blob and crops to its tight bounds plus a small even
margin, which also discards separate smaller blobs such as the baked-in
text caption; (4) resamples to the target point width (aspect
preserved) with premultiplied-alpha-aware Lanczos resizing, which
avoids dark/light fringing on transparent edges that a naive resize
would introduce.

Re-run this script whenever a new pose arrives as a similar SVG.

## blink / sleep

Not derived from this source. A hand-repainted "closed eyes" attempt
(cloning fur texture over the pupils and drawing a lid curve) was tried
and rejected — at this resolution and with Pillow-only tooling it
produced visible rectangular cloning artifacts and did not match the
source's soft painterly shading. `pet-blink@2x.png` and
`pet-sleep@2x.png` in `apps/macos/Rallo/Resources/Sprites/` are still
the placeholder art from `scripts/generate-placeholder-sprites.py`.
Matching source art (a version of this red panda with genuinely closed
eyes, drawn by the same artist/process) is needed to replace them.
