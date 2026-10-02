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
| `rotateFlippers` | high refresh: rotate the flippers between the game's frames, with an HD pack in the scene pass, without one at output resolution for the smooth / xBRZ / CRT filters (default on; nearest and EP8 keep the cross-fade; Settings > Display "Rotate flippers (high refresh)", or `flippers=fade` in `EPIC_PINBALL_RENDER`, turns it off) |
| `crtCurvature`, `crtScanlines`, `crtMask` | CRT look (defaults 0.025, 0.75, 0.18) |
| `rotation` | cabinet / portrait monitors: the finished picture turned 0, 90, 180 or 270 degrees clockwise (below); independent of `isClassic` |

`RenderSettings(GameSettings)` maps the shared settings: `upscaleFilter` -> `filter`, `useHDPack`,
`dynamicLighting` + `lightingStrength` -> `lighting` (off, or `subtle` / `vivid` while on; a settings file
without `lightingStrength` gets `subtle`, the old meaning of "on"), `outputScaling` -> `scaling`,
`highRefresh` -> `interpolate`, `displayRotation` -> `rotation`, and (feat2/frontend-rest) `crtScanlines` /
`crtCurvature` / `crtMask` (clamped to 0...1, 0...0.08, 0...1), `roundDots`, `stripInFullTable` and
`rotateFlippers` one to one; their `GameSettings` defaults are the values above, so
`RenderSettings(GameSettings()) == RenderSettings()` (`DisplaySettingsTests`). `EPIC_PINBALL_RENDER` also
takes `scanlines=` and `mask=`. Default `GameSettings` maps to classic (`outputScaling = .integer` with the
nearest filter also stays on the classic path; `fill` does not). Settings > Display has all of them. `fullTableView` is the front end's camera (`Camera.showFullTable`); the renderer draws whatever
`SceneState.viewHeight` says and adds the strip below a full table.

Developer override: `EPIC_PINBALL_RENDER="filter=xbrz,hd=1,lighting=subtle,interp=1,scaling=fill,rotate=90"` is read when a
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
   High refresh rotates the flippers (HD pack, see "Rotated flippers"; without a pack the present pass rotates them,
   "Rotated flippers without an HD pack") or cross-fades their frames. `scene_hd` adds the **palette delta**: the pack is drawn in the base
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
* **The balls** are drawn at output resolution on top (every ball in play, see "Multiball"): with interpolation it moves in sub-pixel steps, which a
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

`alpha` = time since the last simulation frame / frame period (`GameSimulation.accumulator`). Each ball is drawn at
`previous + (current - previous) * alpha` (jumps over 24 px, such as a serve, snap). The positions are
`GameSimulation.ballPosition(i)`: `x + acc/128` with classic physics (unchanged), and with enhanced physics the model's
own centre `EnhancedPhysics.ballCentre(i) - centreOffset` at full double precision (the integer fields are its
truncation to 1/128 px, `syncOut`; when rules or the main loop moved the ball after the step, the fields no longer
hold that truncation and they are used instead). `SceneState.ball.topLeft` (enhanced presentation mode) comes from
the same positions. The renderer keeps a per-simulation-frame history (by `frame`) of the camera top, the flipper
frames and the flippers' angle indices (`SceneState.FlipperSprite.angle`: `EnhancedPhysics.flipperAlpha` with
enhanced physics, else the group's angle): the camera eases between the last two tops (for the original's per-frame
camera; off when the front end already moves it continuously), and a moving flipper is drawn rotated to the
interpolated angle (HD pack; without one for smooth / xBRZ / CRT) or cross-fades from the previous frame (only pixels that still show the flipper record,
so a lamp blitted over it is left alone). Simulation timing is not touched; the picture is up to one frame (16.7 ms)
behind the simulation, as usual for interpolation. Tests: `testInterpolatedBallPosition`,
`testInterpolatedCameraAndFlipperCrossfade`, `testBallPositionFromEnhancedPhysics`, `testRotatedFlipperHD`.

Without high refresh nothing is gained by rotating: a flipper moves one angle index per physics step, three per
frame, so at frame boundaries a moving flipper is at angle 9, 6, 3 or 0, exactly the angles the four frames are
drawn at (below). Enhanced physics also ends every step on a whole angle index (`flipperAlpha` is continuous only
inside a step), so the flippers are rotated only while interpolating.

### Rotated flippers (HD pack, high refresh)

The game's flipper frames are opaque records with the background baked in (draw_flipper_sprite, EP1 cs:3C12), and
the playfield under them is not the background either: EP1, EP4 and EP10 have a flat placeholder shape there, EP8
and EP12 the rest frame [H, compared on those five tables' data]. The flipper colours differ by table (only EP8 uses
the 0xD3..0xE6 range the EP1 init at cs:03D5 treats as flipper art). So `FlipperArt` (PinballRender) splits the
frames into a flipper sprite per frame and the background, from the frames alone:

* Frame k shows angle index 3k, the last frame 9 (rest): the frame rule is (angle + 2) / 3 (EP1 cs:10F5), and the
  frames' fitted art angles match the lower flippers' collision outlines at angles 3 and 6 within 0.07 rad (mostly
  under 0.04) and at angle 0 within 0.05 rad on EP1-7 and EP9-13 [H, measured, `testFlipperArtSplitOnRealTables`].
* A pixel's background is what the frame whose flipper points furthest away from it shows (angle around the pivot);
  where every frame's flipper is close (a disc around the pivot) it is unknown. A frame's mask is every pixel that
  differs from the background (largest 8-connected part, holes filled); unknown-background pixels count as flipper
  unless their colour is almost only ever seen as background, and their background is filled in from the
  neighbours. A first pass uses the collision outlines' rigid fit (`FlipperShape`: pivot, angle per index); then the
  pivot and each frame's angle are refitted from the masks (principal axis, centroid least squares) and the split
  is repeated.
* The split is used only if the frames behave like one rigid sprite turning one way (each frame-to-frame rotation
  at least 0.04 rad with the same sign, mean fit error under 0.6 px, pivot near the rectangle). It holds for every
  flipper with at least two frames except EP8's two (their colours are close to the table's; the masks are not
  clean), which keep the cross-fade; EP13's right flipper has a single frame. Fit errors are 0.39-0.46 px.

`FlipperRotationData` then builds, at the pack's scale, the clean HD sprite of every frame (premultiplied; alpha 1
inside the native mask, 0 outside it, and on the one-pixel edge band from the HD pixel's difference to the HD
background, with the background unmixed out of the colour) and the HD background (per native pixel from a frame
that shows it with no flipper pixel around it, so xBRZ edge blends are not picked up). It runs once per table on a
background queue (51 ms in a release build for EP10's two flippers; several seconds in a debug build); the
cross-fade is drawn until it is ready.

`scene_hd` then draws, where VRAM still shows one of the flipper's frames (a lamp blitted over it is left alone):
the background with the two frames around the angle composited on top, each rotated about the art's pivot by the
difference between the angle and its own art angle (the art angle moves linearly with the angle index between two
frames), cross-faded over the middle 40 % of the interval. At a frame's own angle that is the frame itself: EP10's
rotated output equals the plain HD frame within a mean of 0.012 per channel (`testRotatedFlipperHD`, which also
checks that the flipper moves between frames and differs from the cross-fade).

### Rotated flippers without an HD pack (smooth, xBRZ, CRT)

Without a pack the scene pass is native 320 px, where a rotated sprite would be resampled to the game's pixel grid.
So the rotation moves to the output resolution, in `present_enhanced` (function constant `FC_ROTATE`, only compiled
in while a flipper is rotated; `NativeFlipperRotation` in FlipperRotation.swift):

* **Sprites through the active filter.** Once per table, filter and sprite scale K, a background job upscales every
  flipper frame K times on the GPU with the active filter's own shader functions (`flipper_upscale`: `xbrz_sample`
  after `xbrz_prepass` for xBRZ, the Catmull-Rom `bicubic` for smooth and for CRT, whose scanlines are applied
  afterwards over the whole picture). Each frame is upscaled in a crop of the base playfield with a 3 px margin, so
  its edges blend as in context. The results go through the same split as an HD pack's frames
  (`FlipperRotationData` at scale K: `FlipperArt` masks, premultiplied sprites, difference-keyed edge band). K is the
  output scale rounded up, 2...8 (about 9x at 4K gives 8); a window resize that changes K rebuilds in the
  background and keeps the previous sprites meanwhile.
* **Background in the scene pass.** `scene_enhanced` writes, where VRAM still shows one of the flipper's frames
  (the same ownership test as `scene_hd`, so a lamp blitted over the flipper is left alone), the frames' background
  (`FlipperArt.background`, palette indices, live palette). The filter and the xBRZ prepass therefore see the table
  without the flipper, and the window around it is filtered seamlessly.
* **Present.** Per output pixel inside a flipper's union rectangle whose native pixel is owned: the two frames
  around the interpolated angle, each rotated about the art's pivot (`FlipperArt.pose`, as with a pack), sampled
  bilinearly from the K-scale sprites, cross-faded over the middle 40 %, composited over the filtered background, and
  shifted by the native pixel's palette delta like `scene_hd`. Then glow, balls, dots and the CRT post as usual.
* **Where it does not run.** Nearest (the pixel look) keeps the cross-fade, so does every flipper whose split fails
  the rigidity check (EP8's two) and the frames until the job is done. The classic default never reaches the enhanced
  pipeline, and without high refresh nothing is interpolated, so classic output is unchanged.

Verified by running code (`testRotatedFlipperWithoutPack`, EP10 full table at 4x, user data): smooth, xBRZ and CRT
rotate both flippers, nearest rotates none and its mid-swing frame is byte-identical to the cross-fade; still
flippers (angle 9, 6, 3, 0) differ from the plainly filtered frame in the left flipper's rectangle by a mean of
0.08-0.12 (smooth), 0.03-0.07 (xBRZ) and 1.6-1.9 (CRT: the window is sampled row by row, the sprite in both
directions) per channel; mid-swing (9 -> 6 at alpha 0.5) the picture differs from the cross-fade by a mean of
10.5-10.7 and moves at every alpha step. `testEP8FlippersKeepCrossFadeWithoutPack`: EP8 rotates none. The CPU split
(`FlipperRotationData.buildTime`, not counting the GPU upscale before it) takes 0.026-0.028 s in a release build
(`swift test -c release -Xswiftc -enable-testing`) and about 2.9 s in a debug build for EP10 at K = 4. The snapshot sheet
(`EP_RENDER_SNAPSHOTS=DIR`, `ep10_flipper_rotation_nopack.png`: still, quarter, half and three-quarter swing and the
cross-fade for each filter) was looked at: one solid flipper at each step, smooth edges, no ghost of the other frame
(the cross-fade shows two half-transparent flippers at alpha 0.5). Not checked: other tables by eye (the split is the
same code as with packs, usable on EP1-7 and EP9-13), a 120 Hz display.

### Multiball

The original draws every ball slot that is in play, each frame, in slot order: the per-ball loop (EP1 cs:11A7..1233
over 5 slots, EP9-13 over 3, e.g. EP10 cs:114F..11ED) calls ball_pixel_scan, which ends with the ball blit (EP1
cs:171E, EP10 cs:16BB). Verified with the harness on all 13 original EXEs (`tools/emu/check_ball_draw.py` hooks the
blit): EP1-8 blit all five slots when five are active, EP9-13 only slots 0-2, and slot 0 being empty does not stop
the others [H]. The one exception is a ball whose sensor handler set the "moved" flag that frame (EP1 [589Ah],
cs:170A): the original skips its blit for that frame; the port draws it (as it always did for ball 0). The renderer used to
draw only slot 0 (`SceneState.ball`), in the classic and the enhanced path, so the second and third balls of a
multiball, and EP3's captive ball (slot 2, active from boot in the original too), were invisible.

`SceneState.extraBalls` now carries the other slots in play (`GameSimulation.drawnBallSlots` = engine.json's
`gravity.slots`, else 5), each with its slot, its own composited pixels and the integer position they were
composited at; `MotionInterpolation.balls` carries their motion. The classic pass draws them after ball 0 with the
same code (`ExtraBalls`, buffer 1 of `scene_fragment`; with one ball the output is byte-identical, the goldens still
match). The enhanced pass gives every ball the treatment ball 0 gets: interpolation from its own slot's history,
the HD ball sprite, its own occlusion level (inferred per slot), contact shadow, specular and glow reflection.
Tests: `testMultiballDrawsEveryBall`, `testSceneCarriesEveryBallInPlay`.

## Full table and aspect

`scaling = .fill` places the screen (window + strip, or the 400-row table + strip) at the largest fractional scale
that fits, keeping the pixel aspect (`square` or `vga` 1.2); `integer` is `ViewportFit` exactly. Everything outside
the viewport is black. Any window size works; the filters are all defined for fractional scales
(`testFillFitKeepsAspectAndIntegerMatchesClassic`).

## Display rotation (cabinets, portrait monitors)

`RenderSettings.rotation` (`GameSettings.displayRotation`, Settings > Display "Rotate picture", `--rotate D`)
turns the picture for a monitor mounted on its side, as in a pinball cabinet. Rotations are clockwise: with 90 the
picture's top is at the output's right-hand edge, i.e. upright on a monitor turned 90 degrees anticlockwise (its
right-hand edge now at the top); 270 is the other way round. Input and simulation are untouched; the front end
turns the SwiftUI overlays (pause menu, initials, game over, replay bar, status HUD) by the same rotation
(frontend.md "Cabinet"). If macOS itself already rotates the display (System Settings > Displays > Rotation), leave
this at none.

How (`DisplayRotation.swift`, `present_rotate` in `Pinball.metal`): with a rotation, `encode` draws the frame
exactly as without one, but into a cached *upright* texture whose size is the output's with width and height swapped
for 90 / 270 (`DisplayTransform.logicalWidth/Height`). One more pass then reads that texture per output pixel at
`DisplayTransform.logical(fromPhysical:)` and writes it to the real target. So:

* every filter of both pipelines (nearest, smooth, xBRZ, CRT, HD pack, lighting, interpolation) letterboxes and
  scales in the upright texture by its usual rules (`ViewportFit` / `EnhancedFit`), in backing pixels, so Retina is
  handled the same way as unrotated; the turn itself moves whole pixels (no resampling);
* with 90 / 270 and the full-table view, the 320x400 table (+ strip) fills the portrait width: a 1920x1080 output
  gives 960x1200 at integer 3x with the classic look, 1080 px wide (3.375x) with fill scaling;
* the CRT mask and scanlines turn with the picture (as on a turned CRT);
* `rotation == .none` (the default) runs nothing new: no extra texture, no extra pass; the classic output is
  byte-identical (the existing golden-hash tests; `testNoRotationIsUnchanged`).

`PinballRenderer.fit(for:outputWidth:outputHeight:)` stays in upright coordinates; `DisplayTransform.physicalRect`
maps such a rectangle onto the output. Snapshots: `--rotate D` without `--size` writes the turned image (portrait
becomes landscape); with `--size WxH` that is the output size.

Verified by running code: `DisplayRotationTests` (transform bijection / inverse, clockwise corners, rect mapping,
the 1920x1080 cabinet letterbox at 1x and 2x backing, VGA aspect, settings mapping) and, with the user's data,
`testRotatedFramesAreTheUprightFrameTurned`: for nearest, smooth, xBRZ, CRT, xBRZ + lighting, smooth with the local
EP10 HD pack and xBRZ full table on EP10, the 90 / 180 / 270 frames are pixel-for-pixel the 0-degree frame of the swapped size turned on the CPU. The
same was checked on PNG snapshots (EP1 full table, EP10 window in all four filters, and a 1920x1080 output at 90
against a 1080x1920 output turned) and the snapshots were looked at; a window run (`--rotate 90 --score-window`)
captured the rotated drawable. GPU cost of the extra pass: 0.42 ms at 3840x2160 on an M1 (see "Performance").

## Score window (strip only)

`PinballRenderer.encodeStrip(rows:into:target:)` draws the display strip alone (all `maxStripRows` rows: 19 in
EP1-8, 29 in EP9-13) for the front end's score window (frontend.md "Cabinet"). Classic settings: the classic
`present_nearest` pass with no window rows (every output row is a strip row). Enhanced settings:
`EnhancedPipeline.encodeStrip` builds the strip layer as `encode` does (`strip_rgb`, or the HD strip when a pack is
active; the xBRZ prepass for xBRZ) and runs `present_enhanced` specialised with the strip only (no ball, dots or
lighting), so all filters and the CRT post apply. `stripFit` is the letterbox (integer for the classic look, else the
resolved scaling). It uses the strip the last `present` built and never touches the main frame's interpolation,
lighting or HD-loading state. It has its own rotation (`encodeStrip(rows:into:target:rotation:)`,
`GameSettings.scoreWindowRotation`, `--score-rotate D`), because a backglass screen may be mounted differently from the
playfield's: the strip is drawn upright into a cached texture of the swapped size (`stripRotationScratch`) and turned by
`present_rotate`, like the main picture; the main picture's rotation does not apply to it. `renderStripOffscreen` /
`--score-snapshot P` write it to PNG (turned too without `--score-size`). `testRotatedStripIsTheUprightStripTurned`:
for nearest, xBRZ and CRT the 90 / 180 / 270 strip is pixel for pixel the upright strip of the swapped size turned.
`testStripOnlyRenderMatchesTheMainFramesStrip`: at the main view's 3x scale the strip-only render equals the strip
rows of the main frame, exactly for nearest and within 1/255 for smooth and xBRZ (float rounding of `y - window
rows`), on EP1 and EP10.

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
  `extracted/hdpacks/`, gitignored), then `~/Library/Application Support/EpicPinballHD/HDPacks/EP<n>` in the app
  (`<support dir>/HDPacks` with `--support-dir`), where the app's own generator writes.

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

### Without Python: `PinballImport.HDPackMaker`

The app makes packs itself with a Swift port of `make_pack.py` (`app/Sources/PinballImport/HDPackMaker.swift`) and of
`xbrz.py` (`XBRZScaler.swift`): the `xbrz` and `nearest` methods, the in-context lamp / flipper / plunger scaling,
the ball and the font8 atlas, the same `pack.json`, and the `--verify` alignment check (`HDPackMaker.verify`, which
writes the same `verify.json`). Entry points:

* **Settings > Library > HD art packs**: scale 2x / 3x / 4x, all tables or the selected one, "Generate HD packs"
  with a progress bar and Cancel. It runs off the main thread (`AppModel.generateHDPacks`, one table after another;
  the playfield's rows are scaled in parallel) and writes `~/Library/Application Support/EpicPinballHD/HDPacks/EP<n>`
  (`AppPaths.hdPacksRoot`), the per-user root `HDPack.locate` searches. A table picks up a new pack the next time it
  is started.
* **`--make-hd-pack N|all [--scale S] [--hd-method xbrz|nearest] [--verify-hd-pack] [--hd-pack-out DIR]`**, headless,
  from the data root (`--data` / `--library`); default scale 4, default output `<support dir>/HDPacks`.
  `--support-dir DIR` also points `HDPack.userPacksRoot` at `DIR/HDPacks` (`HDPack.userPacksRootOverride`).
* `tools/package_app.sh`'s sandboxed runtime check (no Python, no `extracted/`) makes table 1's 4x pack with the
  packaged binary and renders a `--hd-pack` snapshot with it ("hd pack on", no warnings).

A pack is built in `.EP<n>.partial-<uuid>` next to the output and moved into place only when complete, so a failed
or cancelled run leaves the previous pack alone (staging directories of a killed run are removed by the next run).

**Same pixels as the Python tool.** `XBRZScaler.swift` follows numpy 2's type rules for `xbrz.py` operation by
operation: the colour work is float32 (the arrays are float32 and Python float constants are "weak" scalars, cast to
float32 via double), the half-plane coverages are float64 (they divide by `np.hypot(*n)` of Python floats, a float64
scalar, which promotes) and are rounded to float32 where the Python code calls `.astype(np.float32)`; `hypotf` /
`hypot` are the same libm functions numpy calls, and Swift does not fuse multiply-adds. Verified by running both
generators and decoding every asset with Pillow (`HDPackTests`; `make_pack.py` from the venv):

| run | files compared | pixels differing | pack.json | verify.json |
|---|---|---|---|---|
| all 13 tables, xBRZ 4x (from `extracted/`, release build) | 98...176 per table | 0 | equal except `generator.tool` | same flags, best shifts and summary; one rounded number differs in the last digit (EP1, one lamp's `shift0_err` 5.737 vs 5.738) |
| EP1 4x and EP13 4x from a Swift-imported library | 148, 144 | 0 | equal except `generator.tool` | |
| EP8 xBRZ 3x, EP13 xBRZ 2x, EP1 nearest 2x | 143, 144, 148 | 0 | equal except `generator.tool` | equal within 0.0015 |
| synthetic table (tests, no game data): xBRZ 2x / 3x / 4x, nearest 3x | 7 each | 0 | equal except `generator.tool` | equal within 0.0015 |

A `--snapshot` of EP10 (smooth + lighting, 4x, launched for 1 s) rendered with the Swift-made pack is byte-identical to
the one rendered with the Python-made pack. Tolerances and their reasons: the **PNG bytes** differ (ImageIO and
Pillow's zlib compress differently; the Swift packs are about 25 % larger, 25 MB for all 13 tables at 4x), and
`verify` averages in Double where numpy averages float32, so its rounded numbers can differ in the last digit and an
exact tie between two shifts could in principle be broken differently (seen only with a synthetic record that is a
pure diagonal edge, which fits the grid shifted along itself equally well).

At 2x, EP13's verify reports 44 lamp records as not aligned (best shift (-1, -1), with `make_pack.py` exactly as with
the port; the aggregate is (0, 0)): a shift of one HD pixel is half an original pixel there, and the check's
tolerance is tuned for 4x. The app does not run the check.

Not ported: `--method ai` / `--upscaler-cmd` / `--anchor` (an external upscaler command; that stays a Python developer
tool) and `--verify-only` (`HDPackMaker.verify` is public; the CLI verifies right after making).

Time per table (release build, Apple M1 8-core, machine shared with other builds; written to a fresh directory):

| | xBRZ 4x, per table | all 13 tables |
|---|---|---|
| Swift, `--make-hd-pack all --scale 4` from an imported library | 0.19...0.28 s | 2.9 s |
| Swift, same from `extracted/` with `--verify-hd-pack` (generate / verify) | 0.24...0.66 s / 0.22...0.86 s | 10.1 s |
| Python `make_pack.py` (numpy) | about 1.5 s | |
| Swift debug build | about 2.5 s | |

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

With motion (EP10, HD 4x + lighting + interpolation, flippers flipping every frame, `testGPUFrameTimeMotion4K`,
measured on the same M1 while the machine was shared with other builds, so the absolute numbers are higher than
above):

| configuration | window mean / p95 (ms) | full table mean / p95 (ms) |
|---|---|---|
| flippers cross-fade, 1 ball | 2.44 / 2.86 | 2.41 / 2.94 |
| flippers rotated, 1 ball | 2.47 / 3.47 | 2.34 / 2.93 |
| flippers rotated, 3 balls | 3.10 / 3.91 | 2.61 / 3.29 |

Rotation costs nothing measurable (it only runs in the flipper rectangles); each extra ball adds roughly 0.1-0.3 ms
at 4K (the present pass tests every pixel against every ball's box).

Display rotation and flipper rotation without an HD pack (`EP_RENDER_PERF=1 swift test --filter
testGPURotationCost4K`, 2026-10-01, same M1, machine shared with other agents' builds): EP10, flippers flipping, a new
simulation frame every second display frame; the two configurations of each row are rendered alternately frame by
frame (200 frames each after 40 warm-up) so clock and load changes hit both, and medians are compared.

| change | window p50 (ms) | full table p50 (ms) |
|---|---|---|
| `present_rotate` alone (one 3840x2160 read + write) | 0.42 | |
| classic nearest, display rotation 0 -> 90 | 0.57 -> 0.86 (+0.29) | 0.51 -> 0.92 (+0.41) |
| smooth + interpolation, flippers cross-fade -> rotated (no pack) | 1.78 -> 1.99 (+0.20) | 1.24 -> 1.30 (+0.06) |
| xBRZ + interpolation, same | 3.66 -> 3.74 (+0.08) | 3.44 -> 3.56 (+0.12) |
| CRT + interpolation, same | 1.84 -> 2.02 (+0.19) | 1.23 -> 1.30 (+0.07) |

With the enhanced filters, rotating the display by 90 also changes how much picture there is (the logical target is
2160x3840: the 320x240 window fills 2160x1620 instead of 2880x2160, the full table 2160x2828 instead of
1650x2160), so its total changes by more than the pass (xBRZ + lighting + interpolation: window 4.18 -> 3.11 ms, full
2.82 -> 4.49 ms); the pass itself is the 0.42 ms above. The first version of the output-resolution flipper rotation
compiled it into the full-screen present draw and cost 0.5-1.5 ms at 4K even where no flipper is, so the present pass
now draws twice: once without `FC_ROTATE` over the viewport, then once with it, scissored to the flippers'
rectangles (same per-pixel result, `testRotatedFlipperWithoutPack` unchanged). With CRT curvature the scissor is
widened by `curveMargin(k)` = max(0.03, k/2 + 0.005) of the larger side: the barrel warp moves a pixel by up to
k/2 of the size, and Settings > Display allows k up to 0.08 (`testRotationScissorCoversCurvature`).

Every configuration fits the 8.3 ms budget of 120 Hz at 4K with room to spare on the weakest chip (numbers vary by
about +-20 % between runs with GPU clocks). Specialising `present_enhanced` with function constants and using
hardware bilinear taps halved the first version's times (xbrz window 5.2 -> 3.8 ms, smooth 4.2 -> 2.1 ms).

## Known limitations

* The EP9-13 strip dots are round only with an HD pack; without one they go through the strip filter as pixels.
* Flippers are rotated only with high refresh (with an HD pack, or without one for smooth / xBRZ / CRT); with the
  nearest filter, on EP8 (whose frames cannot be split cleanly) and until the sprites are built, high refresh
  cross-fades the frames. Without a pack the rotated sprite is the frame upscaled on its own (in a playfield crop), so
  a still flipper differs slightly from the plainly filtered frame (most with CRT, whose window is sampled per row). The rotated pixels take the palette delta of the pixel VRAM
  shows there (flipper and background colours are not animated on the tables checked).
* Occlusion uses the static collision map and engine.json's classes (EP8's dynamic level-0 bounds at their initial
  values), with the level inferred from the engine's composited ball pixels; a level that has no occluders near the
  ball keeps the previous guess.
* The strip digits and pause banner from an HD pack are drawn in base-palette colours (palette changes re-render the
  strip but do not shift those sprites).
