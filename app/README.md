# Epic Pinball (native macOS remake)

A Swift package that plays the tables from **your own copy** of Epic Pinball with a
faithful, integer-exact reimplementation of the original engine, rendered with Metal.
No game data is bundled or copied into `app/`. Everything, including small numeric
tables (probe ring, normal and push-out tables, parameter block, flipper outlines), is
loaded at runtime from `extracted/` files that you produce from your own CD.

Status:
* **Classic physics is bit-exact for EP1.** In every trace compared against the original
  EP1 code (run by the emulator harness `tools/emu/`), the ball position, sub-pixel
  accumulators, velocity, contact direction and flipper angles match on every physics step
  (see [Verification](#verification)).
* The other 12 tables run on the same engine with their own constants. Those constants
  come from the same code patterns, and fields that could not be located are listed in
  each `engine.json`'s `fallbacks`. Only EP1 has been checked against the original.
* Table rules (scoring, lamps, captures, kickbacks, gates, multiball) are not ported yet.
  Only sensor handlers that touch nothing but physics state are run: ramp enter/leave,
  one-way gates and debounce.

## Requirements

- macOS 14 or later on Apple silicon (tested with Swift 6.3 / Xcode 26.6)
- Swift toolchain (Xcode or Command Line Tools). The shader is compiled at runtime, so
  you do not need the offline Metal compiler.
- Extracted data for each table under `extracted/tables/EP<n>/`:
  - `playfield_idx.npy`, `palette.json` (`tools/extract.py`)
  - `collision_idx.npy`, `collision.json` (`tools/collision.py`)
  - `sprites/*.png`, `sprites/sprites.json` (`tools/sprites.py`)
  - `engine.json` (**`tools/export_engine_data.py`**, reads `original/EP<n>.EXE` plus the
    two JSON files above)

```sh
.venv/bin/python tools/export_engine_data.py          # all 13 tables -> extracted/tables/EPn/engine.json
```

## Build, test, run

```sh
cd app
swift build
swift test                       # 52 tests (engine maths, flippers, decoding, differential vs original, GPU passes)
swift run EpicPinball            # window, table 1
swift run EpicPinball --table 5 --mode enhanced
swift run EpicPinball --data /path/to/extracted --table 10 --aspect vga
```

### Trace mode (headless, no window, no Metal)

```sh
swift run EpicPinball --trace ../tools/emu/scenarios/plunger_launch.json --out ../scratch/port/t.jsonl
```

Implements the shared trace contract `tools/emu/trace_schema.json` (field names are read
from that file when it is present, otherwise the contract defaults are used):
* A scenario gives `table`, `frames`, ball 0 in the original's raw words (`x`,`y` top-left
  pixel of the 15x14 box; `xf`,`yf` 1/128 px accumulators; `vx`,`vy` in 1/128 px per step;
  optional `layer`), per-frame `inputs` (1 = left flipper, 2 = right, 4 = plunger/Ctrl),
  optional `params` (by name or as 10 values with `null` = keep), `on_drain`
  (`stop`|`continue`), `mode` (`physics` = no sensor dispatch, `rules`/`full` = run the
  exported sensor handlers) and `pokes`.
* Output: one JSON line per physics step (3 per frame): `frame`, `step`, `ball`,
  `collided` (ds:6C59 after the step), `k` (contact direction 1-48 of ball 0's first,
  velocity-changing response), `left/right_flipper_pos` (angle 0 = up ... 9 = rest), and
  an `extra` object with the harness's diagnostics. It also has two port-only keys, written
  only in a step where they occur: `loop_guard` (the push-out loop hit the port's cap, which is
  where the original hangs) and `divide_faults` (idiv overflows).
* Frame order: main-loop work (counters, drain/serve, plunger lane, nudge/tilt, gravity,
  sensor scan), then 3 physics steps. `--gravity-phase N` moves the main-loop work after
  N steps. In the real game that phase depends on machine load.
* Extensions for testing beyond the contract: `"balls": [...]` for slots 1-4, input bits
  8/16/32 (nudge Z, nudge /, Space) and `--state` (all ball slots and counters in `extra`).

### Headless snapshot (no window)

```sh
swift run EpicPinball --table 1 --snapshot out.png --launch --sim-time 1.2   # plunge, run 1.2 s
swift run EpicPinball --table 1 --snapshot out.png --scenario ../tools/emu/scenarios/left_flipper_shot.json --frames 40
swift run EpicPinball --table 1 --snapshot out.png --full                   # whole 320x400 table
swift run EpicPinball --table 1 --snapshot raw.png --full --scale 1 --no-sprites
    # ^ matches extracted/tables/EP1/playfield.png exactly
```

Snapshot flags: `--scale N`, `--size WxH`, `--camera-y Y` (default: follow the ball),
`--sim-time S` or `--frames N` (original frames at 59.94 Hz), `--launch` (hold the plunger
to full charge, then release), `--flip left|right|both` (hold flippers), `--scenario FILE`,
`--no-sprites`, `--aspect square|vga`, `--mode classic|enhanced`.

### Window smoke test

```sh
swift run EpicPinball --table 2 --exit-after 2 --window-capture ../scratch/app/win.png
```

### Data location

`--data <dir>` points at the `extracted` directory (the one containing `tables/`).
Without it the app tries, in order: `$EPIC_PINBALL_DATA`, `../extracted` relative to this
package (resolved from the source path at compile time), then `../extracted` and
`extracted` relative to the current directory. Missing or malformed files produce an
error that names the exact file. A missing `engine.json` tells you to run the exporter.

### Keys (as in the original, keyboard_isr EP1 cs:314B)

| Key | Action |
| --- | --- |
| Left Shift / Left arrow, Right Shift / Right arrow | left / right flipper |
| Space | plunger while the ball is in the lane, nudge elsewhere |
| Ctrl | plunger |
| Z or `,` / `/` | nudge (vx +20 / -20 on the next contact); too many nudges = TILT |
| Up / Down | scroll the camera manually |
| Tab | full table (320x400) or scrolling 320x200 window |
| A | pixel aspect: square or VGA (1.2x tall pixels, 4:3) |
| E | classic or enhanced presentation |
| R | new ball at the plunger |
| Esc, Cmd-Q | quit |

## Layout

```
Sources/PinballCore/        Foundation only, unit tested
  EngineData.swift          engine.json decoder + validation (SensorOp/SensorExpr for handlers)
  ClassicEngine.swift       the integer engine: collision buffer, 48-probe test, contact
                            direction, response maths, push-out loop, kickers, flippers,
                            ball-ball, frame logic (drain/serve, plunger, nudge/tilt, gravity,
                            sensor scan), occlusion composite
  Trace.swift               EngineAssets loader, Scenario parser, TraceRunner (JSONL)
  Physics.swift             GameSimulation: wall clock -> 59.94 Hz frames; classic/enhanced
  Scene.swift               SceneState: ball sprite pixels, flipper frames, fallback shapes
  NPY.swift, Palette.swift, TableAssets.swift, Camera.swift
Sources/PinballRender/      Metal (no AppKit)
  SpriteSet.swift           flipper frame PNGs -> RGBA atlas (ImageIO)
  Renderer.swift            palette pass + sprites, present pass; Snapshot.swift
  Shaders/Pinball.metal
Sources/EpicPinball/        AppKit front end: main.swift, Options.swift, App.swift,
                            Snapshot.swift, TraceMode.swift
Tests/PinballCoreTests/     EngineTests (reflection goldens, directions, integration,
                            flippers, behaviour, decoding, traces), EngineFixture (synthetic
                            engine.json), RenderTests, AssetTests, CameraTests
```

## The classic engine (EP1 addresses; see docs/formats/engine.md, collision.md)

* **Timing**: 59.94 Hz frames with 3 physics steps each. Each step (`physics_step` cs:1724)
  integrates every active ball: `acc += v`, the pixel move is `|acc| >> 7` capped per axis
  (5 px in EP1), and the backlog is clamped to +-2000. `x < 1` becomes 1. `y < 1` is reset
  to 3 with `vy = 0`, but only after an upward move. Then the wall loop runs while
  `(u16)y < 384`, then `flipper_update`, then the ball-ball pairs (0,1), (0,2), (1,2).
* **Collision buffer**: `collision_idx.npy` (the playfield with the flipper art replaced).
  Flipper outlines are erased (0x2A) and drawn (flipper colour) into it exactly when and
  in the order the original does. Power-on starts at angle 2 with that outline recorded as
  drawn, then the flippers fall to rest over 7 steps.
* **Probes**: 48 ring offsets, probed 48 down to 1. Every probe is classified by the
  table's 256-entry colour LUT for the ball's level. `active` calls the kicker when its
  cooldown is 0. The `flipper` colour sets contact 1 or 2 by `(u16)x <= split`, but only if
  that flipper moved up on the previous step.
* **Direction**: min/max of the hit list, with the wrap case (always 48) and the +24 rule
  for spans over 24, all in u8 arithmetic.
* **Response**: moving-flipper side/tip kicks on every iteration (y -= 1, no push-out),
  otherwise 1 px of push-out. Only the first response of a step changes velocity: the
  flipper-top kick from the fx/fy tables, the kicker `v += kick*n`, or the reflection with
  `imul`/`idiv` 32-bit intermediates, the 16-vs-64 quirk, the `0x7FF8` case and 16-bit
  truncation. The nudge impulse follows the reflection. The loop repeats until no probe
  hits. The original has no iteration cap and can hang; the port stops at 10000 and counts
  `loopGuardTrips`. Real `idiv` overflows (a divide error on a real CPU) are counted in
  `divideFaults`.
* **Per frame** (main loop): extra-gravity/lockout/kicker/event counters, drain (y >= 399)
  and serve at (284,336), the plunger lane (vx = 0 in the lane when not held, charge
  +12/frame, release `vy -= charge; y -= 1`), nudge/tilt, `kick = 0`, then gravity
  `vy += g + extra` if `vy <= 320`, then the sensor scan with the exported handlers.

No floating point is used anywhere in `ClassicEngine`. `SimulationMode.enhanced` is the
hook for smoother play: it uses the same engine and only draws the ball at an
interpolated sub-pixel position.

## Rendering

1. **Scene pass** (native 320 x rows): the playfield index texture goes through the
   palette texture. The flipper sprite frame for the current angle is drawn on top
   (`frame = (angle + 2) / 3`, cs:10F5; opaque rectangles from the game's own sprite PNGs,
   packed into an atlas). Then the ball is drawn: its 15x14 sprite indices from engine.json,
   composited on the CPU like `ball_pixel_scan`, so collision-buffer indices in the level's
   occlusion range `(lo, hi]` replace ball pixels (rails and ramps pass in front). Index 0
   is transparent. Missing sprites fall back to procedural shapes: a capsule fitted to the
   current collision outline, and a shaded ball.
2. **Present pass**: integer-scaled, aspect-correct upscale (`ViewportFit`).

At 1x, flipper sprite pixels match the extracted PNGs exactly, and `--no-sprites` matches
`playfield.png` exactly.

## Verification

The ground truth is the **original EP1 machine code**, executed from your own
`original/EP1.EXE` by the Unicorn harness in `tools/emu/` (docs/formats/emulation.md).

### Differential test: `tools/emu/diff_traces.py`

Runs every scenario through both the original code (`tools/emu/run_scenario.py`, in-process)
and the port (`EpicPinball --trace`), and reports, per scenario, the first divergent physics
step with every field that differs (original value vs port value) plus a few records of
context. Exit status 0 only if everything passes.

```sh
.venv/bin/python tools/emu/diff_traces.py                  # all scenarios (about 7 s)
.venv/bin/python tools/emu/diff_traces.py -q               # one line per scenario
.venv/bin/python tools/emu/diff_traces.py tools/emu/scenarios/bumper_hit.json
.venv/bin/python tools/emu/diff_traces.py --modes rules,full tools/emu/scenarios
.venv/bin/python tools/emu/diff_traces.py --build          # swift build first
.venv/bin/python tools/emu/diff_traces.py --save-golden    # refresh scratch/diff/golden/ (see below)
.venv/bin/python tools/emu/diff_traces.py --a orig.jsonl --b port.jsonl   # diff two trace files
```

Traces go to `scratch/diff/traces/<name>.orig.jsonl` / `.port.jsonl`. Outcomes:
`EXACT`; `DIVERGES`; `LENGTH`; `ORIG_HANG` / `ORIG_FAULT` (the original never returns from
`physics_step`, or raises a divide error; this passes only if every earlier record is identical
and the port's record for that step carries `extra.loop_guard` / `extra.divide_faults`);
`RULES_GAP` (rules/full mode: a divergence that follows a rule handler the original ran and
the port does not have. The handler and the original's `event_lockout` are named. This still
counts as a failure).

Scenarios (`tools/emu/make_scenarios.py` writes them):
* `tools/emu/scenarios/`: the 18 contract scenarios and 25 adversarial ones (`adv_*`):
  5 px/step balls into 1-px walls (straddles on both probe arcs, the +24 rule), wrap-case
  contacts (hits containing both 1 and 48, where the original always gives k=48) and near-wrap
  ones, a ball resting on a raised flipper, flipper pressed, released and fluttered while the
  ball is in contact, both flippers at once, tip kicks on the wrap side, the y<1 and x<1 clamps,
  re-entry from below the y=384 collision limit, an over-charged plunger, and ramp (level 1)
  entry/exit through the F0/F1 sensors (rules mode).
* `tools/emu/scenarios_pathological/`: starts from which the original hangs in the push-out
  loop (below).

### `swift test`

`Tests/PinballCoreTests/DifferentialTests.swift`:
* `testMatchesOriginalCodeLive` runs all scenarios through the harness
  (`run_scenario.py --batch`, one boot, about 6 s) and through `TraceRunner` in-process, and
  requires identical traces (same rules as above). It is skipped when `.venv/bin/python`,
  `original/EP1.EXE` or the extracted data are missing, or when `EP_SKIP_LIVE_DIFF=1` is set.
* `testMatchesGoldenTraces` compares against `scratch/diff/golden/*.jsonl` (written by
  `diff_traces.py --save-golden`). It needs no Python, so it still catches regressions on a
  machine without the harness.

A deliberately broken wrap rule (`al >>= 2`) makes 24 scenarios diverge and both hang checks
fail, in the tool and in the tests alike, so both checks catch this kind of regression.

### Results (EP1)

* Physics mode (the contract): **43 of 43 scenarios identical** on every field of every record,
  `extra` included. The 2 pathological scenarios match up to the step where the original hangs,
  and the port flags its loop guard in that same step.
* Earlier random runs (`scratch/port/fuzz.py`, `fuzz_extra.py`): all identical except the runs in
  which the original itself livelocks.
* Rules/full mode: 36 of 43 identical. The 7 others all diverge right after a table rule the port
  does not have yet: the saucer capture 0xF6 (cs:2379), the outlane kickback 0xF8 (cs:2869),
  0xF5 (cs:21BD), and the ramp-scoring rule 0xF9 (cs:2AB8). 0xF9 sets `event_lockout = 35`,
  which delays the ported F1 ramp exit.
* **The original can hang.** The push-out loop (cs:1826..18FA) has no iteration cap. A ball
  that hits 1-px wall art at about 4.5 px/step or more can end up straddling it, and the loop
  then alternates between two k values forever. This happens inside the timer ISR with
  interrupts off (cs:2FC6 `cli`, and physics_step never re-enables them), so the real game
  freezes. Random fast starts reach this state quite often (9 of 150 fuzz runs). In 40 simulated
  games (120,000 frames) of plunging and flipping, it never happened. The port stops the loop
  after 10,000 iterations (`maxResponseIterations`) and counts `loopGuardTrips`.

The older `scratch/port/run_all.sh` and `diff_traces.py` from the port track still work, but
`tools/emu/diff_traces.py` replaces them.

## Known limitations

- Table rules are not ported (see above), so no score, lamps, ball locks, kickbacks or
  runtime gates (EP1 cs:4488 left outlane gate).
- Only EP1 has been verified against the original. EP8 has no plunger code (ENIGMA), so
  its plunger and serve values are EP1 fallbacks. EP2, EP5 and EP9-13 fall back for the
  kicker cooldown. The `fallbacks` list in each `engine.json` has the details.
- EP7/EP8 conditional colour classes and EP2's conditional kicker are treated as plain
  walls/kickers.
- Demo/attract mode (auto-flip, stuck-ball nudge) is not modelled.
- The plunger sprite, lamp overlays and the score strip are not drawn yet.
