# Rallo pet art — source of truth

## Provenance

The full pose set was supplied by the user on 2026-09-30 as a
collection of SVGs, each an embedded base64 PNG of the same red panda
character on an opaque cream background (`#FCF8EF`-ish), some with a
baked-in text caption below the character:

| Pose (`pet-<name>`) | Source SVG | Source PNG | Caption |
|---|---|---|---|
| `idle` | `rallo_exact_hero.svg` ("Rallo — Hero Pose") | 500x370, sitting, alert, tilted head | none |
| `sleep` | `rallo_exact_resting.svg` ("Resting") | 290x235, curled up asleep | "Resting" |
| `nudge` | `rallo_exact_nudge.svg` ("A Gentle Nudge") | 285x255, waving paw | "A gentle nudge" |
| `celebrate` | `rallo_exact_all_done.svg` ("All done") | 280x280, floating, closed happy eyes | "All done" |

Pose → app state mapping: `idle` = notes open, nothing due; `sleep` =
no open notes; `nudge` = a reminder is due; `celebrate` = a reminder
was just completed. (`rallo_exact_sheet.svg`, a combined character
sheet, was not used directly — the four poses above were extracted
from their own individual SVGs instead.)

Each character was cut out with a foreground-aware matte (see below),
its caption discarded, and all four composited onto one shared canvas
so switching poses never changes the pet's apparent size or the height
of its feet/shadow baseline.

Note: the `celebrate` (and to a lesser extent `sleep`/`nudge`) source
art is a noticeably more painterly/textured illustration style than
`idle`'s flatter cel-shaded style — that mismatch is inherent to the
supplied source SVGs, not something this pipeline corrects.

## Files

| File | Size (px) | Notes |
|---|---|---|
| `pet-idle.png`, `pet-sleep.png`, `pet-nudge.png`, `pet-celebrate.png` | 143 x 118 | @1x, standard-DPI |
| `pet-idle@2x.png`, `pet-sleep@2x.png`, `pet-nudge@2x.png`, `pet-celebrate@2x.png` | 286 x 236 | @2x, Retina |

Point size in the app: 143 x 118 pt (`PetPanel.spriteSize`). Every pose
shares this exact canvas: the character is scaled so it reads as the
same size across poses (see below) and is bottom-centre aligned so its
feet/shadow baseline sits at the same row in every file — `celebrate`
floats slightly above its own shadow rather than touching it, matching
its source art.

## How these were produced

`scripts/import-pet-art.py` (repo root) is the reproducible pipeline.
Run all four poses together in one command so their relative scale is
computed consistently:

```
scripts/import-pet-art.py \
    --pose idle=rallo_exact_hero.svg \
    --pose sleep=rallo_exact_resting.svg \
    --pose nudge=rallo_exact_nudge.svg \
    --pose celebrate=rallo_exact_all_done.svg \
    --shadow-band-bottom celebrate=30 \
    --out-dir assets/pet/rallo
```

It, per pose: (1) decodes the embedded base64 PNG losslessly; (2)
mattes the character with a foreground-aware technique — a
local-gradient flood fill from the border finds the background, and
near the silhouette boundary the true foreground colour is estimated
from nearby confidently-interior pixels so edge alpha comes from
projecting the pixel onto the background→foreground colour line
instead of a fixed distance threshold (which is what previously caused
a pale fringe around high-contrast fur on dark backdrops); thin
isolated structures (whiskers, hair tufts) fall back to a
nearest-character colour bleed so they stay dark instead of pale; (3)
a separate pass looks in a band below the character for a near-uniform
darkening of the background (a soft ground shadow) and re-expresses it
as a warm paw-ink tone with alpha from luma falloff, so it reads as a
darkening on any backdrop rather than a solid pale halo — `celebrate`
floats above its shadow with a real gap, so it needs a deeper search
band (`--shadow-band-bottom celebrate=30`) to reach it without also
catching its caption; (4) finds the largest connected character blob
plus any shadow found near it and crops to that tight union, discarding
a separate smaller blob such as the baked-in caption; (5) with more
than one `--pose` given, normalises scale across poses via the
geometric mean of each character's own silhouette bounding box
(`sqrt(w·h)`, pose-aspect-independent), calibrated against whichever
supplied pose has the smallest native size so nothing is ever upscaled
beyond its source resolution (`nudge` turned out to be the limiting
pose here), then composites every pose onto one shared canvas sized to
the largest scaled pose plus a small margin, bottom-centre aligned;
(6) resamples with premultiplied-alpha-aware Lanczos resizing, which
avoids dark/light fringing on transparent edges that a naive resize
would introduce.

Re-run the full four-pose command above (not a single `--pose`) when a
new pose arrives, so its size is calibrated against the existing set
rather than in isolation — dropping a single `--pose` on its own fits
that pose to its own content, independent of the shared canvas.

## Faces edited from existing poses

Made on 2026-09-30 by editing an existing @2x sprite in an image generator
(same body, only the named part changed; prompts in
`image-edit-prompts.txt`), each 1381 x 1139 on flat cream:

| Pose (`pet-<name>`) | Source | Edited from | Used for |
|---|---|---|---|
| `drowsy` | `rallo_drowsy.png` | `sleep` | cursor arrives on the sleeping pet (one eye peeks) |
| `content` | `rallo_content.png` | `sleep` | petting the sleeping pet |
| `grumpy` | `rallo_grumpy.png` | `idle` | tickling it again once it's up |
| `happy` | `rallo_happy.png` | `idle` | a save (with the hop and ✓) |
| `wave2` | `rallo_wave2.png` | `nudge` | second frame of the due wave |
| `listening` | `rallo_listening.png` | `idle` | voice typing is on (paw cupped to the perked ear; added 2026-10-02, prompt in `listening-edit-prompt.txt`) |

`scripts/fit-pet-pose.py` cuts each one out with this pipeline's matte and
places it at the scale and offset where its silhouette overlaps the pose it
was edited from most, so switching between them doesn't jump (overlap:
drowsy 99.1 %, content 98.9 %, happy 96.6 %, wave2 95.4 %, grumpy 94.6 %, listening 94.0 %;
the rest is the changed ears, face, or paw):

```
scripts/fit-pet-pose.py \
    drowsy=assets/pet/rallo/rallo_drowsy.png:assets/pet/rallo/pet-sleep@2x.png \
    content=assets/pet/rallo/rallo_content.png:assets/pet/rallo/pet-sleep@2x.png \
    grumpy=assets/pet/rallo/rallo_grumpy.png:assets/pet/rallo/pet-idle@2x.png \
    happy=assets/pet/rallo/rallo_happy.png:assets/pet/rallo/pet-idle@2x.png \
    wave2=assets/pet/rallo/rallo_wave2.png:assets/pet/rallo/pet-nudge@2x.png \
    listening=assets/pet/rallo/rallo_listening.png:assets/pet/rallo/pet-idle@2x.png
```

`pet-idle-base` / `pet-idle-eyes` split the idle pose's eyes onto their own
layer so they can follow the cursor: `scripts/split-pet-eyes.py
assets/pet/rallo/pet-idle@2x.png`.

Copy the outputs to `apps/macos/Rallo/Resources/Sprites/`.

## blink

Retired. `pet-blink@2x.png` (placeholder art from
`scripts/generate-placeholder-sprites.py`) has been deleted along with
the `PetView.Pose.blink` case — there is no matching source art for a
genuinely closed-eyes blink pose. `celebrate` (closed happy eyes) is
the closest available expression.
