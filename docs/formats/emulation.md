# Emulation harness: the original EP1.EXE physics as ground truth

`tools/emu/` runs the **original EP1.EXE machine code** under the Unicorn CPU emulator
(x86, 16-bit real mode) and writes per-physics-step traces that the Swift port can be
diffed against. The EXE is read from the user's own `original/EP1.EXE` at run time.
Nothing from the game (code, tables, art) is copied into `tools/` or `docs/`: the harness
contains only code addresses and variable offsets found by reverse engineering.

Confidence tags as in the other docs: **[H]** checked by running code (harness and/or
DOSBox-X), **[M]** read from code but not exercised, **[L]** guess.
Addresses: `cs:XXXX` = EP1 code segment 0x3223, `ds:XXXX` = EP1 data segment 0x0015
(unrelocated, as in engine.md / collision.md).

## Quick start

```sh
.venv/bin/pip install unicorn jsonschema          # unicorn 2.1.4 was used
.venv/bin/python tools/emu/make_scenarios.py      # (re)writes tools/emu/scenarios/*.json
.venv/bin/python tools/emu/run_scenario.py tools/emu/scenarios/bumper_hit.json -o scratch/emu/traces/bumper_hit.jsonl
.venv/bin/python tools/emu/run_scenario.py SCN.json --mode full        # whole real main loop
.venv/bin/python tools/emu/compare_ref.py [--plunger-adapter] [-v]     # vs scratch/engine/ep1_physics_ref.py
.venv/bin/python scratch/emu/validate_traces.py                        # schema check of scenarios + traces
.venv/bin/python scratch/emu/compare_modes.py                          # physics vs rules vs full mode
```

A 600-frame scenario takes about 0.9 s including the boot (0.5 s). Runs are deterministic:
the same scenario gives byte-identical output in separate processes and after in-process
snapshot restores (checked for all 18 scenarios).

| File | Purpose |
|---|---|
| `tools/emu/ep_emu.py` | Loader, boot, stubs, range/call runner, state accessors, snapshots |
| `tools/emu/run_scenario.py` | Scenario JSON -> JSONL trace (the contract) |
| `tools/emu/trace_schema.json` | JSON Schema for scenarios and trace records (field names, units) |
| `tools/emu/make_scenarios.py`, `tools/emu/scenarios/*.json` | The scenario set (18) |
| `tools/emu/compare_ref.py` | Step-by-step diff against the Python reference |
| `scratch/emu/traces/*.jsonl` | Traces of all scenarios (physics mode) |
| `scratch/emu/compare_modes.py`, `validate_traces.py` | Mode comparison, schema validation |
| `scratch/emu/dosbox/`, `demo_check.py`, `gravity_phase_experiment.py`, `zmbv_frames.py` | DOSBox-X dynamic check (section 8) |

## 1. Loading and booting [H]

* The MZ load image (file 0x400 .. end of last page, 250,763 bytes) is written at segment
  `LOAD_SEG = 0x1000` and all 173 relocations get `+0x1000`. Memory is one flat 1.06 MB map
  (VRAM at A000 is plain RAM).
* PSP at 0x0FF0 with the command tail PINBALL.EXE would pass (engine.md section 8): `82` players
  `'1'` (or `'D'` for demo), `83..92` sixteen bytes 0xC8 (invalid sound pointer digits, so the
  game itself clears `snd_present` at cs:00DE and never calls the MASI stub), `9E '@'`, `9F '3'`
  balls, `A0 '1'` table angle "normal" (gravity +0), `A1 '0'` options (no sfx/music, timer mode).
* Entry CS:IP and SS:SP come from the header (SS:SP = image+0 : 0x014A). The real entry and init code
  run until the first arrival at the main loop top `cs:04D2`: command-line parse, video mode query
  and mode 13h/Mode X setup, get/set vector for int 8 and int 9 (recorded as cs:2FC6 and cs:314B,
  never installed), playfield copy to "VRAM", the D3..E6 -> 2A substitution (cs:03D5), palette fade,
  and the 177-frame intro scroll (each `wait_frame` ends at once because of the 3DAh stub).
* **The in-RAM collision buffer after boot is byte-identical to `extracted/tables/EP1/collision_idx.npy`**
  (all 128,000 bytes). This confirms the start-up substitution in collision.md dynamically.

### What is emulated vs stubbed

| Item | Treatment |
|---|---|
| All game code that runs (init, main loop pieces, physics_step, collision_response, kicker_hit, flipper_update, rule handlers in rules/full mode) | **Executed** from the user's EXE |
| int 10h | AH=0Fh returns mode 3; everything else is a logged no-op |
| int 21h | AH=35h returns a dummy IRET vector, AH=25h records the vector, AH=09h logs the string, AH=4Ch stops |
| int 0 (divide error) | reported as an error (never seen) |
| Port 3DAh | bit 3 toggles on every read, so every retrace busy-wait finishes on the next read |
| Port 201h (joystick) | 0xFF (no buttons; the joystick code is dead anyway, cs:0711) |
| Other ports (VGA sequencer/CRTC/DAC, PIT, speaker, 60h/61h) | reads 0, writes ignored (loggable with `log_io=True`) |
| Timer ISR (int 8, cs:2FC6) | **Not delivered.** Its physics work is done by calling `physics_step` cs:1724 three times per frame |
| Keyboard ISR (int 9, cs:314B) | **Not delivered.** The harness pokes its CS flags (below) |
| MASI sound API (seg 0x3D35) | Never reached (`snd_present = 0`). PC-speaker path runs but its port writes are ignored |

Keyboard flags poked per frame (engine.md section 5): `cs:028D` left flipper, `cs:028F` right flipper,
`cs:0297` Ctrl = plunger. Space (`cs:0296`) is deliberately not used for the plunger because
outside the lane it also nudges (cs:0E0D). `cs:029B` (last scancode) is held at 0x8C (a key
release) so no menu or pause key is ever pending.

## 2. The frame driver [H]

A frame is: **main-loop work for frame f, then three calls of `physics_step` cs:1724**
(which ends with `flipper_update` cs:3CDD). Inputs for frame f are poked before the main-loop
work and stay set for its 3 steps.

Why this is the original order: the timer ISR runs step 1 of each frame at vertical retrace
(cs:2FF9..3021), then the main loop starts (frame_sync cs:127F..129F). Gravity (cs:11AE) is near the end of the
main loop but before rendering, and steps 2 and 3 follow at +6300 and +12600 PIT ticks.
So if the main loop reaches cs:11AE within 5.28 ms of retrace, the step sequence is
`S1 | main loop (plunger, gravity, render) | S2 S3 | S1' | ...`. That is the same sequence as
"main loop, then 3 steps" with the frame boundary placed at the start of the main loop. The DOSBox-X
check (section 8) confirms this steady-state order.

Three modes (`--mode` or `"mode"` in the scenario):

| mode | per frame | use |
|---|---|---|
| `physics` (default, the contract) | Only the ball-relevant main-loop ranges below, then 3 steps. No sensor/rule dispatch | Swift physics diff |
| `rules` | Same, plus `ball_pixel_scan` cs:1679 (sensors, rule handlers, `obj_writeback`) | Rules work |
| `full` | The whole real main-loop body cs:04D2..1243 (everything except `frame_sync`), then 3 steps | Reference |

Main-loop ranges run in `physics` mode, in the original order (call sites in brackets are NOPed
for the range, with the translation cache invalidated):

| range | what it does |
|---|---|
| cs:06E2..0711 | `extra_gravity_timer` decay; gate timer (may call `gate_draw`, which edits the collision buffer) |
| cs:09EC..0A0D | `event_lockout`, `kicker_cooldown`, `event_cooldown` decrements |
| cs:0A31..0A9A | drain check (y >= 0x18F) and serve of a new ball at (284,336) |
| cs:0A9D..0C48 [0AFD `ball_lost_fade`] | lane/plunger logic |
| cs:0DFD..0E8A | nudge/tilt timers (the harness never sets nudge keys, so they only decay) |
| cs:119F..1236 [11F3 `save_ball_bg`, 11FD `ball_pixel_scan`] | `kick_strength = 0`; per-ball gravity `if vy <= 320: vy += p_gravity + extra_gravity_timer` |

`rules` mode uses the same ranges without the 11FD skip. `save_ball_bg` must stay skipped:
it appends a record to a list in graphics segment 0x2623 that only `restore_ball_bg` (cs:10BD, not in
these ranges) empties. Run unpaired, the list grows past 2623:C000 (= cs:0000) and after about 185 frames
it overwrites the game's own code. That was a harness bug, found and fixed. The runner now checks
that cs:0000..4470 (minus the CS variables 028B..02A2, 307B, 3C82..3C89, 44AD) is unchanged at the end
of every run and fails if it is not.

The skipped parts of the main loop really do not affect the ball: `rules` and `full` produce
**identical traces on all 18 scenarios** (`scratch/emu/compare_modes.py`). `physics` differs
from `full` only when a sensor handler acts. For example, in `plunger_launch` at frame 100 the top-lane sensor 0xFD
(handler cs:2F44) reverses vx through `obj_writeback`. The first such difference is at step 6 to 1278
depending on the scenario. 10 of the 18 scenarios are identical in all three modes.

### Scenario setup (before frame 0)

1. Boot (above), then `reset_play_state`: all 5 balls inactive; `serve_delay`, `kicker_cooldown`,
   `event_lockout`, `event_cooldown`, `nudge_timer`, `tilt_meter`, `tilted`, `plunger_charge`,
   `extra_gravity_timer` = 0; all key flags 0.
2. **Warm-up: 12 physics steps with no ball.** At boot the flippers are at angle **2** with "drawn
   angle" 2 but **no outline in the collision buffer** (0 pixels of 0xDF). The first 7 steps move them
   to rest (9), and the first one erases the angle-2 outline, which was never drawn (see finding 1).
3. Parameter overrides (`params`), then ball slot 0 from the scenario (`x, y, xf, yf, vx, vy, layer`),
   `ball_active[0] = 1`. Optional raw `pokes`.

The booted + warmed-up state is snapshotted, so later scenarios in the same process start from an
identical state (`restore` also flushes Unicorn's translation cache).

## 3. Trace contract

See `tools/emu/trace_schema.json` (`$defs.scenario`, `$defs.record`). Summary:

* Record per physics step: `frame`, `step` (0..2), `ball {x, y, xf, yf, vx, vy}` = raw s16 values of
  ball slot 0 after the step: `ds:6A46/6A52` (top-left of the 15x14 box, table pixels), `ds:6A18/6A24`
  accumulators in 1/128 px (they can hold up to +-2000 of backlog when the 5 px/step cap applies), and
  `ds:6A00/6A0C` velocity in 1/128 px per step.
* `collided` = `ds:6C59` after the step (at least one response ran in this step, for any ball).
* `k` = contact direction **1..48** (`ds:586E`, 1 = east, 13 = north, 25 = west, 37 = south) of ball 0's
  **first** collision response of the step, the one that changes velocity. The normal/push-out entry
  used is `k-1`. It is `null` if there was no response. It is captured by a code hook at cs:1AEC, right after
  cs:1AD0 stores it.
* `left_flipper_pos` / `right_flipper_pos` = `ds:6CD2` / `ds:6CD4` (9 rest .. 0 up).
* `extra` (optional): layer, active, number of responses (push-out iterations) and all their k values,
  `flipper_contact` / `kick` at the first response, flipper moving flags, plunger charge.
* `on_drain: "stop"` (default) ends the trace before the first frame that starts with y >= 0x18F.
  `"continue"` lets the game's own serve code run (finding 5).

## 4. Scenario set (`tools/emu/scenarios/`, 18 files)

The start boxes are clear of solid colours with a 3 px margin, except the serve position.
The first contact of each wall/kicker scenario was checked in the trace.

| scenario | what it exercises (from the trace) |
|---|---|
| `plunger_launch` | 62 frames plunger held (charge saturates at 708), release, lane, top arc |
| `plunger_short` | 20-frame plunge (charge 240), ball falls back into the lane |
| `fall_left/right_flipper_held` | fall onto a raised (not moving) flipper: plain reflection |
| `fall_left/right_flipper_released` | fall onto the resting flipper, roll off, drain |
| `left_flipper_shot`, `right_flipper_shot` | flipper pressed as the ball lands: top kick (k-1 in 32..40) on 2 consecutive steps, vy about -245 then -490 |
| `left_flipper_side_kick` | contact k=30 on the moving flipper: side-kick path, (+56,-140) per push-out iteration, (+224,-560) after 4 |
| `bumper_hit` | right pop bumper, kick 8 (k=48), then several bumper and wall contacts |
| `slingshot_left_hit`, `slingshot_right_hit` | slingshot kicker contacts (k=28 / k=48, kick 8) |
| `diagonal_wall_hit` | first contact k=7, no kicker |
| `flat_wall_hit`, `flat_ceiling_hit` | first contact k=25 (west) / k=13 (north) |
| `multi_bounce_upper` | fast ball in the upper playfield, bumpers and walls |
| `upper_layer_loop` | ball on layer 1 (ramp): only BC..C7 collide, divisors 17+3, no kickers |
| `long_600_scripted` | 600 frames: launch, flipper presses every 45 frames, drain, serve (`on_drain: continue`), second plunge |

## 5. Findings from running the original code

1. **Boot-time flipper erase [H].** The DS image starts with both flipper angles and "drawn" angles
   at 2, and nothing draws the outline before play. The first `flipper_update` (cs:3CDD) writes
   0x2A over the angle-2 outline, which was never drawn, and so deletes whatever the art had there. In EP1
   that is 70 pixels: 66 floor pixels 0x28 -> 0x2A (harmless) and **4 solid wall pixels 0xE9 at
   (98,373), (100,374), (204,373), (202,374)**. It then walks to angle 9 and draws the rest outline (0xDF).
   So the collision buffer during play is `collision_idx.npy` with the angle-2 outline set to 0x2A
   and the rest outline set to 0xDF. The Swift port should do the same. `fall_right_flipper_released` touches
   the (204,373) pixel: k=40 in the original, k=41 with the pixel present.
2. **The push-out loop has no iteration cap [H].** cs:1826..18FA repeats until no probe hits. A ball
   straddling a thin wall oscillates forever. Example: start (120,60), vy=-400 (overlapping art
   around x 132..137), k alternates 48, 25, 48, 25, ... The original would hang inside the timer ISR. The
   harness raises `PushoutLivelock` after 1M instructions. The Python reference hides this with a
   64-iteration guard. Normal play is not known to reach this state.
3. **The stuck-ball nudge is demo-only [H for code, M for intent].** cs:0C48 jumps to cs:0D1D unless
   `demo_mode` is set, so the "x,y unchanged for 25 frames -> vx += 1" code (cs:0C76..0C95) never runs in a real
   game. engine.md section 6 lists it as general behaviour.
4. **Lane logic [H].** While ball 0 is in the lane (layer 0, x >= 0x118, y >= 0xDC, `serve_delay` = 0) and the
   plunger is not held, **vx is set to 0 every frame** (cs:0B83). On release: `vy -= charge; y -= 1`.
   The Python reference had none of this. With it added (`--plunger-adapter`), both plunger
   scenarios match step for step.
5. **Serve [H].** On drain (checked at the start of the frame), the ball is re-served in the same frame at
   (284,336) with vx = vy = 0, but **the accumulators are not cleared** (cs:0A77..0A94). `serve_delay` = 7
   frames, during which the plunger is ignored. After 6 frames `ball_lost_fade` would run (skipped in
   physics/rules mode, run in full mode).
6. **Rule handlers change the ball [H].** In rules/full mode the sensor handlers act through
   `obj_writeback` (cs:1208..1227). 0xFD at cs:2F44 reverses vx if vx <= 0 and moves x +3. 0xFE at cs:2F83
   does the mirror case (vx >= 0: reverse, x -3). Physics mode leaves these out on purpose.
7. **Start-up transient [H that it exists, cause not found].** Against the DOSBox-X video (section 8),
   the harness in full mode matches only if the **first** main-loop frame after boot has no gravity add.
   With it, frames 40..139 match in 36 of 93 compared frames. Without it, 90 of 93 match. An extra first-frame physics step (the
   frame_sync cs:125C path) does not explain it (36/93). It probably comes from how the ISR locks on in
   the first frames. It does not affect scenarios, which inject their state after the warm-up.

## 6. Cross-check against `scratch/engine/ep1_physics_ref.py`

`tools/emu/compare_ref.py` drives the reference `Sim` from the same raw state and inputs, and compares
every step (x, y, xf, yf, vx, vy, collided, k, flipper angles):

* **13/18 scenarios match step for step as is**, including every bumper, slingshot, wall, ceiling, diagonal,
  multi-bounce, flipper top-kick and flipper side-kick scenario (up to 600 steps each). So the
  transcription of integration, the 48-probe sampling, contact direction (including the k=48 wrap quirk),
  push-out, reflection (the 16-vs-64 term and 0x7FF8 case), kicker and flipper responses and
  `flipper_update` is exact on these paths.
* With `--plunger-adapter` (finding 4): **15/18**.
* What the reference gets wrong (the emulator wins):
  1. No main-loop lane/plunger logic (vx = 0 in lane, charge/release). Affects `plunger_launch`,
     `plunger_short`, `long_600_scripted`.
  2. Its collision buffer draws the rest outline over `collision_idx.npy` but skips the boot-time
     erase of the angle-2 outline (finding 1). It keeps 4 wall pixels the game deletes: `fall_right_flipper_released`,
     step 107, k 41 vs 40.
  3. No upper layer (layer 1: colour range BC..C7, no kickers, divisors +3): `upper_layer_loop` differs
     from step 1.
  4. No drain/serve (finding 5): `long_600_scripted` diverges at the serve, frame 326.
  5. The 64-iteration push-out guard (finding 2) is not in the original.
  6. It has no stuck-ball nudge. That is correct for normal play (finding 3), although engine.md says otherwise.

## 7. Timing notes (from code) [M]

* `frame_sync` (cs:124C) polls 3DAh **before** it checks `vsync_flag`. If the main loop sees retrace
  still active after the ISR's retrace step, it takes the "main loop reached vsync first" path
  (cs:126F): it restarts the PIT at 6400 and runs one more `physics_step`, which gives 4 steps in that frame. The
  retrace pulse is 2 scan lines (about 64 us, CRTC 10h/11h = EA/AC), so on a fast machine this is a real
  race. It was **not** seen in DOSBox-X: in the capped lane the ball moves exactly 15 px (3 x 5) per
  video frame. The harness always uses 3 steps.
* The harness does not model the interleaving of ISR steps with the main loop. Real-time races are
  therefore out of scope: gravity landing after S2 when the main loop is slow, a rule handler's
  `obj_writeback` writing back x/y/vx/vy captured before an ISR step (cs:11C1 capture, cs:120F writeback),
  and frame overruns (no steps until the next `frame_sync`).

## 8. Dynamic check against the real game in DOSBox-X [H]

`scratch/emu/dosbox/ep1_demo.conf`: DOSBox-X 2026.08.31, svga_s3, 486 normal core, `cycles=fixed 30000`,
no sound. It mounts a local copy of EP1.EXE and runs it directly with the synthesized launcher tail
`EP1.EXE Dzzzzzzzzzzzzzzzz00000000000@310` (demo mode, invalid sound digits) under `DX-CAPTURE /V`.
It runs headless with `SDL_VIDEODRIVER=dummy ... -time-limit 45`. The game runs without its launcher.
To reproduce (`scratch/emu/dosbox/c/` holds a local copy of the user's EP1.EXE; keep it out of git):

```sh
cd scratch/emu/dosbox && SDL_VIDEODRIVER=dummy dosbox-x -conf ep1_demo.conf -fastlaunch -nogui -nomenu -time-limit 45
cd ../../.. && .venv/bin/python scratch/emu/demo_check.py          # about 2 min; writes scratch/emu/demo_alignment.json
.venv/bin/python scratch/emu/gravity_phase_experiment.py           # gravity-phase / start-up variants
```

Captured frames (ZMBV 32 bpp) are decoded by `scratch/emu/zmbv_frames.py`. Screenshots:
`scratch/emu/dosbox_ep1_demo_lane.png`, `dosbox_ep1_demo_launch.png`, `dosbox_ep1_demo_grid.png`.

* **Display layout confirmed:** 320x240 Mode X (captured at 640x480), the playfield scrolls by hardware and the
  status panel sits at the bottom. It is hidden in demo mode.
* `scratch/emu/demo_check.py` finds the camera row in each captured frame by matching the playfield art,
  and the ball by template matching with EP1's own ball sprite (ds:6B36). It then compares with the harness booted in
  demo mode (`players='D'`) running `full` mode. Video frame i shows the state after harness frame i-213:
  the render at the end of main loop f+1 draws the ball after frame f's steps, and the plunger-release
  frame shows the main loop's `y -= 1` before any step, as the code says.
* Result of `demo_check.py`, with finding 7 applied. The sequences are aligned at the plunger release
  (video frame 272 = harness frame 59). Over the 150 frames after release (harness frames 59..209)
  **134/142 compared frames match exactly and 142/142 match within 1 px**, and **the camera row equals
  `ds:6A38` in 142/142**. This stretch covers the launch, 20 frames of capped lane travel at 15 px/frame
  (so 3 steps per frame), the first top-arc contacts, the roll along the top edge, the 0xFD/0xFE sensor
  reversals and the bounces in the top lane. All eight 1 px misses have template scores below 0.85, where
  rails cover part of the ball.
  Later the trajectories part (frames 40..700: 157/589 exact, 179/589 within 1 px). The cause may be
  the ISR/main-loop races of section 7 or detection errors. It was not traced further.
* The same check rejects the other gravity phases: gravity before step 1 or step 2 matches 36/93.

## 9. Limits

* **EP1 only.** Other tables need their own addresses (compare_tables.py can find them) and checks of
  their colour classes.
* The trace records ball slot 0 only. Multi-ball scenarios can be set up with `pokes`/`set_ball`, but
  only slot 0 is written out.
* Inputs are per frame (flippers, plunger). There are no nudge, tilt, pause or menu inputs. `params` overrides are written after
  boot, so they replace the command-line angle adjustment of gravity.
* No interrupts, so none of the ISR-vs-main-loop races of section 7. Blocking sequences in full mode (for example
  `ball_lost_fade`) finish inside one harness frame, and their internal `wait_frame`s are not counted.
* Unicorn pitfall (handled): `uc.mem_write` does not invalidate translated blocks. Code patches go
  through `_patch`, which calls `ctl_remove_cache`, and snapshot restore flushes the whole cache. Before this
  fix, running `full` then `physics` in one process could execute stale, unpatched blocks.
* Sound, video and PC-speaker output are ignored. Render code still runs in `full` mode and writes to fake VRAM.
