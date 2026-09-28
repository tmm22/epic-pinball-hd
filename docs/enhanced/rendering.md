# Enhanced rendering

The renderer (`app/Sources/PinballRender`) has two paths:

* **Classic** (`RenderSettings.classic`, the default): the original two passes from the classic port (palette
  lookup + ball + dot messages at native 320 px, then an integer nearest upscale). Its output is byte-identical
  to the renderer before the enhanced work (`EnhancedRenderTests.testClassicNearestIsByteIdentical*`, golden hashes
  recorded from that renderer on synthetic scenes and on EP1/EP8/EP10). Classic mode never runs anything below.
* **Enhanced**: any other setting (a filter other than nearest, HD pack, lighting, interpolation or fractional
  scaling) runs `EnhancedPipeline`.

Nothing game-derived lives in the app or in git. The HD packs are generated from the user's own extracted data
and stay in user data directories.

## Settings

`PinballRenderer.settings: RenderSettings` (`RenderSettings.swift`):

| field | meaning |
|---|---|
| `filter` | `nearest`, `smooth`, `xbrz`, `crt` (`UpscaleFilter`; `"xbrz-like"` still parses as `xbrz`) |
| `useHDPack` | draw the table's HD pack if one is installed (per-asset fallback) |
| `lighting` | `off`, `subtle` (default when enabled), `vivid` |
| `interpolate` | draw ball, camera and flippers between the last two simulation frames |
| `scaling` | `integer`, `fill` (fractional, aspect kept) or `auto` (integer for nearest without an HD pack, else fill) |
| `stripInFullTable` | full-table view (400 rows) shows the display strip below the table |
| `roundDots` | round anti-aliased message dots (not with the nearest filter) |
| `crtCurvature`, `crtScanlines`, `crtMask` | CRT look (defaults 0.025, 0.75, 0.18) |

`RenderSettings(GameSettings)` maps the shared settings: `upscaleFilter` -> `filter`, `useHDPack`,
`dynamicLighting` -> `lighting = .subtle`, `highRefresh` -> `interpolate`. Default `GameSettings` maps to
classic. `fullTableView` is the front end's camera (`Camera.showFullTable`); the renderer draws whatever
`SceneState.viewHeight` says and adds the strip below a full table.

Developer override: `EPIC_PINBALL_RENDER="filter=xbrz,hd=1,lighting=subtle,interp=1,scaling=fill"` is read when a
renderer is created, so the headless snapshot mode can show enhanced output:

```sh
EPIC_PINBALL_RENDER="hd=1,lighting=subtle" swift run EpicPinball --table 1 --snapshot out.png --size 1920x1080 --autoplay 400 --filter smooth
```

## Pipeline

All passes are in `Shaders/Pinball.metal` (one runtime-compiled file; the classic functions are unchanged).
Per frame (only what the settings need):

1. **HD VRAM replay** (HD pack only, `quad_*`). The composer logs every opaque VRAM blit in the game's order
   (`ClassicComposer.VRAMOp`: lamp overlays, flipper frames, plunger rows, resets). They are replayed into an HD
   VRAM texture (320S x 400S) from the pack's sprites, or from the original record (nearest) where the pack has
   none. When the pack is switched on mid-game the compacted live list (`liveVRAMOps`) rebuilds it.
2. **Scene** (`scene_enhanced` native, or `scene_hd` at S x): the window rows (camera origin, +1 row for a
   fractional scroll), without the ball and the dot messages, which are drawn later at output resolution.
   High refresh cross-fades flipper frames. `scene_hd` adds the **palette delta**: the pack is drawn in the base
   palette's colours, and every HD pixel is shifted by `palette[i] - basePalette[i]` of its original pixel's index
   `i`, so lamp colour changes, EP8's palette ring and DAC 255 still apply to HD art.
3. **Strip**: native strip indices -> RGBA (`strip_rgb`), or with an HD pack the HD strip, rebuilt when the strip
   or the palette changes from the composer's `StripOp`s: the plain panel (nearest), HD digit / pause sprites,
   font8 glyphs from the pack's coverage masks tinted with the palette colour (7 rows, as the strip routine
   draws), and round dots.
4. **xBRZ prepass** (`xbrz_prepass`, compute, filter `xbrz` without HD): corner analysis of the window frame, the
   strip and the ball sprite.
5. **Glow** (lighting): `glow_emissive` (lamp emissive mask + brightened palette entries) then a separable
   Gaussian (`glow_blur`, sigma 4 px, radius 12 px, native resolution).
6. **Present** (`present_enhanced`, specialised by function constants per configuration): filter of window and
   strip, glow (additive), ball contact shadow, ball (own layer), dot messages, CRT post-process.

### Why the composed frame, and which layers are separate

The static picture (playfield + lamp overlays + flipper frames + plunger) is filtered as **one composed frame**,
because that is what the original's VRAM holds: every overlay record is an opaque rectangle with the background
baked in, so filtering it together with the playfield gives seamless edges, where filtering records on their own
would show their rectangle borders. Separate layers are only used where compositing first would be wrong:

* **Window and strip** are separate images (VGA split screen): they scroll independently (fractional camera
  offsets in enhanced mode) and must not bleed into each other across the split line.
* **The ball** is drawn at output resolution on top: with interpolation it moves in sub-pixel steps, which a
  native-grid composite would quantise to whole table pixels (9 output pixels at 4K). Its occlusion stays exact:
  table pixels whose collision index hides the ball at its level (`ball_pixel_scan`'s occlusion classes from
  engine.json) mask it. The level is inferred each frame by checking which level's occlusion reproduces the
  engine's composited ball pixels at the ball's integer position.
* **Dot messages** are drawn last (as the original plots them after the ball), screen-relative, as round
  anti-aliased dots (square with the nearest filter).

### Filters

* `nearest`: sharp bilinear (one hardware tap): exactly nearest at integer scales, a one-output-pixel transition at
  texel edges at fractional scales, so uneven pixel widths never appear.
* `smooth`: Catmull-Rom bicubic (9 bilinear taps).
* `xbrz`: xBRZ (after Zenju's xBRZ; independent implementation of the published rules): the prepass stores, per
  2x2 block, the blend type (none / normal / dominant) of each of the four corners from the YCbCr gradient sums;
  the present pass evaluates, per output pixel, the corner / 45 degree / shallow / steep line blends of its source
  pixel analytically with one output pixel of anti-aliasing, so it works at any scale, fractional included. Colours
  are compared as RGB after the palette, so palette entries with identical colours count as equal (the tables have
  duplicates); the ball sprite uses the alpha-aware distance. `tools/hdpack/xbrz.py` implements the same maths in
  numpy; `testGPUXbrzMatchesPackGenerator` renders the EP1 playfield at 4x with the GPU filter and compares it with
  the generated pack: 195 of 6,144,000 channels differ by more than 2 (float ties in threshold comparisons).
* `crt`: each source row sampled horizontally with Catmull-Rom, then scanlines with a brightness-dependent beam width
  (sigma 0.26-0.42 of a row, weaker below 3.5x), a 3-output-pixel aperture-grille mask, gamma-2 space, vignette and a
  subtle barrel curvature. The ball and dots get the scanlines too (post-process).
* With an HD pack the pack replaces the upscaler: HD pixels are resampled bicubically (sharp bilinear for `nearest`),
  `crt` scans the HD image at the original row pitch.

## Dynamic lighting (subtle by default, off in classic)

* **Lamp glow**: lamp slot *k* has records "a" and "b"; which is the lit look differs by table (EP1 mostly "b", EP8
  and EP10 mostly "a"). The renderer does not trust the letter: a pixel of the record currently shown emits in
  proportion to how much brighter it is than the same table pixel in the slot's other record (or the playfield
  where that record does not cover it) (`LampLighting`). Palette entries that the frame's overrides make brighter
  than the base palette also emit. The emissive colour is the pixel's current colour; it is blurred and added.
* **Flasher pulses**: a lamp switching to its brighter record outside the blinking states (lamp state 3/4) gets a
  short pulse (x(1 + 0.8), decaying 0.8x per simulation frame; vivid 1.6).
* **Ball**: a soft contact shadow offset away from a top-left light (not where the ball is hidden), a specular spot,
  and the nearby glow reflected on the ball.

`testLightingGlowAroundLitLamp`: EP10 with every lamp lit gets 5.8 % brighter on average (27.76 -> 29.37), capped below
25 % by the test.

## High refresh

The front end renders at the display rate and fills `PinballRenderer.interpolation` every display frame:

```swift
renderer.interpolation = MotionInterpolation(simulation: sim, interpolateCamera: sim.mode == .classic)
```

`alpha` = time since the last simulation frame / frame period (`GameSimulation.accumulator`). The ball is drawn at
`previous + (current - previous) * alpha` (sub-pixel positions `x + acc/128`; jumps over 24 px, such as a serve, snap).
The renderer keeps a per-simulation-frame history (by `frame`) of the camera top and the flipper frames: the camera
eases between the last two tops (for the original's per-frame camera; off when the front end already moves it
continuously) and a flipper whose frame changed cross-fades from the previous frame (only pixels that still show the
flipper record, so a lamp blitted over it is left alone). Simulation timing is not touched; the picture is up to one
frame (16.7 ms) behind the simulation, as usual for interpolation. Tests: `testInterpolatedBallPosition`,
`testInterpolatedCameraAndFlipperCrossfade`.

## Full table and aspect

`scaling = .fill` places the screen (window + strip, or the 400-row table + strip) at the largest fractional scale
that fits, keeping the pixel aspect (`square` or `vga` 1.2); `integer` is `ViewportFit` exactly. Everything outside
the viewport is black. Any window size works; the filters are all defined for fractional scales
(`testFillFitKeepsAspectAndIntegerMatchesClassic`).

## HD asset packs

A pack is a directory `EP<n>/` holding high-resolution replacements at an integer scale factor `S` (2...8):

```
EP1/
  pack.json
  playfield.png          320S x 400S, RGBA (alpha ignored)
  sprites/<name>.png     w*S x h*S per sprites.json record (lamp overlays, flipper frames, plunger, digits, pause)
  sprites/ball.png       ball 0 (engine.json ball), (w*S) x (h*S), straight alpha = coverage
  fonts/font8.png        font8 coverage atlas: 8S wide, glyph g (index from ' ') at rows g*8S ..< (g+1)*8S, red = coverage
  verify.json            (optional) alignment report written by make_pack.py --verify
```

`pack.json`:

```json
{
 "format": "epic-pinball-hdpack", "version": 1, "table": 1, "scale": 4,
 "generator": {"tool": "tools/hdpack/make_pack.py", "method": "xbrz", "upscaler_cmd": null, "anchor": 0},
 "source": {"playfield_idx_sha256": "<sha256 of playfield_idx bytes>", "palette_sha256": "<sha256 of palette bytes>"},
 "playfield": "playfield.png",
 "sprites": {"lamp000_a": {"file": "sprites/lamp000_a.png", "w": 40, "h": 38, "x": 160, "y": 49, "group": "lamp"}, "...": {}},
 "ball": {"file": "sprites/ball.png", "w": 15, "h": 14},
 "fonts": {"font8": {"file": "fonts/font8.png", "first": 0, "cell": 8, "glyphs": 96}}
}
```

Rules:

* **Grid alignment**: HD pixel (X, Y) belongs to original pixel (X / S, Y / S). Every asset is exactly S times its
  original record and is drawn at the record's position times S. Sprite keys are the `sprites.json` names.
* **Colours**: assets are in the base palette's colours (`palette.json`); runtime palette changes are applied as a
  per-pixel delta (see the pipeline).
* **Collision never uses the pack**: physics, occlusion and sensors stay on the original pixels.
* **Validation and fallback** (`HDPack.load`): wrong `format`/`version`/`table`/`scale` rejects the pack; a playfield
  whose `source.playfield_idx_sha256` does not match the user's playfield (a stale pack) is ignored; any asset with the
  wrong size, or a name the table does not have, is dropped with a warning. Missing assets fall back one by one to the
  original record (nearest), the original ball, or the original glyph bits (`PinballRenderer.hdPackWarnings`).
* **Location** (`HDPack.locate`): `$EPIC_PINBALL_HDPACKS/EP<n>`, then `<data>/hdpacks/EP<n>` (development:
  `extracted/hdpacks/`, gitignored), then `~/Library/Application Support/EpicPinballHD/HDPacks/EP<n>` in the app.

### Generating a pack: `tools/hdpack/make_pack.py`

```sh
.venv/bin/python tools/hdpack/make_pack.py --table 1 --scale 4 --verify          # built-in xBRZ, ~1.5 s per table
.venv/bin/python tools/hdpack/make_pack.py --table 1 --scale 4 --method nearest  # pipeline test
.venv/bin/python tools/hdpack/make_pack.py --table 1 --scale 4 \
    --upscaler-cmd 'realesrgan-ncnn-vulkan -i {in} -o {out} -s {scale} -n realesrgan-x4plus-anime' --verify
.venv/bin/python tools/hdpack/make_pack.py --table 1 --verify-only
```

Reads `extracted/tables/EP<n>/` (playfield indices, palette, sprite PNGs, `sprites.json`, the ball from `engine.json`),
writes `extracted/hdpacks/EP<n>/` (or `--out`). Lamp overlays, flipper frames and the plunger are upscaled **in their
playfield context** (pasted into the playfield with a 3 px margin, scaled, cropped), so their HD edges meet the HD
playfield without seams. The ball is scaled with alpha (xBRZ's alpha-aware distance), font8 glyphs as coverage masks.

**External (AI) upscalers** (`--upscaler-cmd`): any command that reads PNG `{in}` and writes PNG `{out}` at `{scale}`
(e.g. Real-ESRGAN ncnn). It is used for the playfield and the opaque sprites; the ball alpha and the font masks always
use xBRZ. Its output is resized to the exact size if needed and then **anchored** to the original pixels by iterative
back-projection (`--anchor N`, default 3: add the per-block difference between the original pixel and the S x S
block mean), which keeps the pack aligned whatever the model does. `tools/hdpack/lanczos_upscaler.py` is a stand-in
with the same contract for testing the hook.

### Alignment check (`--verify`)

Every asset is downsampled back and compared with the original: box-average error, exact centre samples, and the
box-average error for the HD image shifted by -S/2...S/2 pixels in each axis; the unshifted grid must fit best (ties
allowed for flat records; tiny repetitive records are decided by the centre samples), and the pixel-weighted sum over
all assets must be minimal at (0, 0). Results for the 4x packs:

| pack | assets | playfield box MAE | playfield centre samples exact | sprite box MAE (mean) | best shift (aggregate) |
|---|---|---|---|---|---|
| EP1 xBRZ 4x | 147 | 1.54 / 255 | 95.3 % | 2.29 | (0, 0), all aligned |
| EP8 xBRZ 4x | 142 | 1.43 | 89.8 % | 2.17 | (0, 0), all aligned |
| EP10 xBRZ 4x | 175 | 1.46 | 93.2 % | 2.32 | (0, 0), all aligned |
| EP1 nearest 4x | 147 | 0.00 | 100 % | 0.00 | (0, 0) |
| EP1 Lanczos stand-in, anchor 3 | 147 | 0.31 | 53.8 % | 0.70 | (0, 0), all aligned |
| EP1 Lanczos stand-in, anchor 0 | 147 | 2.89 | 52.0 % | 5.29 | |

(xBRZ keeps pixel centres and reshapes edges, so its centre samples are mostly exact; a smooth resampler does not
keep centres but back-projection brings every block's mean back onto the original pixel.)

## Performance

GPU time per frame (`MTLCommandBuffer.gpuEndTime - gpuStartTime`) at **3840 x 2160** on an **Apple M1 (8-core GPU)**,
the slowest Apple-silicon GPU, EP1 with the strip, a ball and a dot message; 120 frames after 10 warm-up frames
(`EP_RENDER_PERF=1 swift test --filter testGPUFrameTime4K`). "window" = 320 x 240 screen filling 2880 x 2160,
"full" = 320 x 419 at 1650 x 2160.

| configuration | window mean / p95 (ms) | full table mean / p95 (ms) |
|---|---|---|
| classic nearest | 0.58 / 0.65 | 0.52 / 0.57 |
| smooth | 2.11 / 2.27 | 1.22 / 1.40 |
| xbrz | 3.82 / 4.17 | 1.87 / 2.94 |
| crt | 1.64 / 1.84 | 1.21 / 1.26 |
| xbrz + lighting | 4.17 / 4.35 | 3.22 / 3.98 |
| xbrz + lighting + interpolation | 4.09 / 4.30 | 1.97 / 2.17 |
| HD 4x pack (smooth) | 3.65 / 4.14 | 1.43 / 1.58 |
| HD 4x + lighting + interpolation | 2.75 / 2.92 | 2.00 / 2.19 |

Every configuration fits the 8.3 ms budget of 120 Hz at 4K with room to spare on the weakest chip (numbers vary by
about +-20 % between runs with GPU clocks). Specialising `present_enhanced` with function constants and using
hardware bilinear taps halved the first version's times (xbrz window 5.2 -> 3.8 ms, smooth 4.2 -> 2.1 ms).

## Known limitations

* The EP9-13 strip dots are round only with an HD pack; without one they go through the strip filter as pixels.
* Flipper motion at high refresh is a cross-fade between the game's sprite frames, not a rotation (the frames are
  opaque records with background baked in).
* Occlusion uses the static collision map and engine.json's classes (EP8's dynamic level-0 bounds at their initial
  values), with the level inferred from the engine's composited ball pixels; a level that has no occluders near the
  ball keeps the previous guess.
* The strip digits and pause banner from an HD pack are drawn in base-palette colours (palette changes re-render the
  strip but do not shift those sprites).
* Only ball 0 is drawn (as in the classic path's `SceneState`).
