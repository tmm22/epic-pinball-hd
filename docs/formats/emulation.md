# Emulation harness: the original table code as ground truth

`tools/emu/` runs the **original EPn.EXE machine code** (all 13 tables) under the Unicorn CPU
emulator (x86, 16-bit real mode) and writes per-physics-step traces that the Swift port can be
diffed against. The EXE is read from the user's own `original/EPn.EXE` at run time.
Nothing from the game (code, tables, art) is copied into `tools/` or `docs/`: the harness
contains only code addresses and variable offsets, and for tables other than EP1 even those
are found at run time by byte signatures (`tools/emu/discover.py`, section 10) and cached in
`tools/emu/tables/EPn.json`.

Sections 1-9 describe the harness on EP1, where it was built and checked in most depth.
Section 10 covers the per-table configuration, section 11 the per-table scenario sets, and
section 12 the differential results for every table.

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

.venv/bin/python tools/emu/discover.py [N ...] [-v]                    # (re)write tools/emu/tables/EPn.json (all 13 by default)
.venv/bin/python tools/emu/discover.py --check                         # EP1 config == the hand-verified ep_emu.EP1 dict
.venv/bin/python tools/emu/make_scenarios.py --table 4 12 | --all      # generated sets -> tools/emu/scenarios/EPn/
.venv/bin/python tools/emu/diff_traces.py -q --table 4                 # original EP4 vs `EpicPinball --trace ... --table 4`
.venv/bin/python tools/emu/verify_rules.py 1 2 3 | --all               # rules.json vs the original code (rules.md section 5)
```

A 600-frame scenario takes about 0.9 s including the boot (0.5 s). Runs are deterministic:
the same scenario gives byte-identical output in separate processes and after in-process
snapshot restores (checked for all 18 scenarios).

| File | Purpose |
|---|---|
| `tools/emu/ep_emu.py` | Loader, boot, stubs, range/call runner, state accessors, snapshots (any table: `EpEmu(table=n)`) |
| `tools/emu/discover.py`, `tools/emu/tables/EPn.json` | Per-table code/variable search and its cached result (section 10) |
| `tools/emu/scenegen.py`, `tools/emu/scenarios/EPn/*.json` | Per-table scenario generator and sets (section 11) |
| `tools/emu/diff_traces.py` | Differential test harness vs the Swift port (`--table N`) |
| `tools/emu/verify_rules.py` | Differential test of lifted rules vs the original code (rules.md section 5) |
| `tools/emu/run_scenario.py` | Scenario JSON -> JSONL trace (the contract) |
| `tools/emu/trace_schema.json` | JSON Schema for scenarios and trace records (field names, units) |
| `tools/emu/make_scenarios.py`, `tools/emu/scenarios/*.json` | EP1's hand-made scenario set (43 + 2 pathological) and the entry point for the per-table sets |
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

`full` on EP9-EP13 also runs render_frame after the 3 steps (`EpEmu.post_frame`, 2026-10-01): those tables call it after
frame_sync's physics steps (EP10 cs:1238, after the retrace wait cs:11F0 and the steps cs:1210..1229), outside the body,
so before this the harness never advanced their message effects or the idle display render_frame shows when a message
ends (EP10 cs:3EEC). EP1-EP8 call render_frame inside the body (EP1 cs:1236); `post_frame` does nothing there. Ball traces
are not affected (render_frame writes no physics state; the full suite is unchanged at 413/415). The port does the same
(`RulesRuntime.renderAfterSteps`). Its calls count for the next frame's record.

Optional scenario key `"watch": {"ds": [[offset, width], ...], "messages": true}` (rules and full mode; ignored in
physics mode): the last record of every frame gets `extra.watch_ds` (those data-segment values after the frame) and
`extra.messages` (the frame's dmd_message calls as [BX = string DS offset, AX, DI], from the entry in rules.json
`stub_routines`), on both sides, so diff_traces.py compares them like any other field. Used by
`tools/emu/scenarios/EPn/fidelity/` (make_fidelity_scenarios.py).

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
   game. engine.md section 6 lists it as general behaviour. Demo mode as a whole is now ported and diffed
   (docs/enhanced/attract.md): `EpEmu(players='D')` boots it, and scenarios turn it on with
   `"pokes": {"demo_mode": 1}` (run_scenario.py then pokes no keys: the demo writes the flipper flags itself) or
   start from the real boot with `"start": "boot"`. Only EP1's demo plunges: EP2-EP13 lack cs:0B79 and hold the
   plunger forever (900 frames on every table).
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

* **EP1 has the deepest checks.** Every table boots and runs through the same harness (sections 10-12),
  but the DOSBox-X check (section 8), the Python reference (section 6) and the adversarial scenarios exist
  for EP1 only.
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

## 10. Per-table configuration: `tools/emu/tables/EPn.json` [H: every table boots and runs]

`EpEmu(table=n)` takes every address from `tools/emu/tables/EPn.json`. `tools/emu/discover.py` writes the file from byte
signatures in the user's `EPn.EXE`. The signatures are EP1 code shapes (cited as EP1 cs:ip below), generalised with wildcards
and followed structurally: call targets, jump targets, loop ends.
The file is regenerated when it is missing or the EXE's SHA-1 changes. `"overrides"` is hand-maintained, survives rewrites and
is applied on top of `"auto"`. `"evidence"` gives the code address of every match, and `"missing"` lists anything not found.
`discover.py --check` confirms that EP1's effective config equals the hand-verified `ep_emu.EP1` dict. Only addresses,
counts and small integers are stored; nothing from the game is.

What is searched (EP1 addresses):

| item | signature / method |
|---|---|
| `frame_sync`, `physics_step`, `main_loop` | `mov byte cs:[mode],0; mov dx,3DAh; in; and al,8; jne; cmp cs:[vsync],0; je` (cs:1243); the no-timer path's 3 calls give physics_step; the `jmp` after the retrace wait gives the main-loop top |
| ball arrays, slots | physics_step head (`pusha; push es; mov [collided],0; mov di,0; cmp [di+active],1`), slot loop `add di,2; cmp di,2N`, and the two integration blocks (vx/accx/x, vy/accy/y) |
| contact direction hook, hit list | collision_response (`mov bx,[hitcount]; dec bx; mov al,[bx+list]`) and the `k+24` wrap code; the hook address is the byte after the `contact_dir` store (cs:1AEC) |
| wall test | `mov si,60h; mov dl,FLIP; mov al,LO or mov al,[VAR]; mov ah,HI; mov dh,ACTIVE; cmp [di+layer],1; jne; mov dh,0; mov al,LO1; mov ah,HI1` (cs:184A) -> `wall_test` |
| kicker | `cmp byte [KC],0; jne; [x/y window]; call KICKER` in the wall loop (cs:18A1) -> `kicker_hit`, `ds_vars.kicker_cooldown` |
| flipper-kick y gates | `cmp byte [flipper_contact],0; je; cmp word [di+y],Y; jb` after the direction store -> `flipper_kick_min_y` |
| sensor dispatch | `mov bl,al; xor bh,bh; sub bx,0AAh; shl bx,1; mov bx,cs:[bx+T]; jmp bx` (cs:1E66) plus its layer/tilt filters |
| keyboard flags | the int 9 ISR (`push cs; pop ds; in al,60h`) parsed as `cmp al,SC; je/jne; mov byte cs:[X],V` per scancode |
| flipper groups, outlines | flipper_update (the call after the slot loop) key/moving/rest groups, and every outline draw site `mov si,[ANGLE]; shl si,1; mov si,[si+T]; lodsw; mov cx,ax; mov dl,C; lodsw; mov di,ax; [add di,B]; mov es:[di],dl; [mov es:[di+320],dl]; loop` with its ES segment |
| main-loop ranges | extra-gravity decay, the per-frame counters run that holds the sensor lockout, the drain loop and serve, the plunger lane (or EP8's launch block) with its `ball_lost_fade` call, nudge/tilt, and gravity + object scan (skipping `save_ball_bg` and, in physics mode, `ball_pixel_scan`) |
| plunger | `cmp word [P],MAX; ja/jae; add word [P],STEP` in the lane block; EP8: `mov word [P],700` while held and the constant launch stores |
| code-integrity window | the end of flipper_update, and every byte written through a `cs:` override below it |

**Result: every item is found automatically in all 13 tables (`missing: []`).** The only overrides are EP1's. They keep the
hand-verified EP1 values so that EP1 traces stay byte-identical: the first physics range is cs:06E2..0711, which also includes the
kickback-gate timer that `gate_draw` uses to edit the collision buffer (the automatic range is the decay only, 06E2..06ED), and
the original code-integrity window (cs:0000..4470 with its CS variables; the automatic window ends at flipper_update, cs:3E35).
The EP1 original-side traces of all 45 scenarios, in physics and rules mode, are byte-identical before and after the change to
per-table configs.

Per-table variants found (cs/ds = entry code segment / data segment, unrelocated):

| table | cs / ds | main loop / physics_step / flipper_update | outlines (colour) | level-0 wall lo..hi | plunger step/max | serve | extra gravity | sensor lockout | kicker cooldown | flipper y gates |
|---|---|---|---|---|---|---|---|---|---|---|
| EP1 | 3223 / 0015 | 04d2 / 1724 / 3cdd | 2 (DF) | CF..EF | 12/700 ja | (284,336) | ds:06d7 | ds:676b | ds:6769 | - |
| EP2 | 3310 / 000e | 04ab / 1892 / 3d85 | 2 (DF) | CF..FF | 12/700 ja | (284,338) | - | ds:5562 | ds:5560 (+ x/y window) | - |
| EP3 | 30e2 / 000e | 04af / 14a4 / 2ea3 | 2 (DF) | D0..EF | 12/700 ja | (297,350) | - | ds:4dcf | ds:4dcd | - |
| EP4 | 304f / 000e | 04af / 1787 / 3786 | 4 (DF) | D1..FD | 10/400 jae | (284,336) | - | ds:595f | ds:595d | 300/310 |
| EP5 | 2e2c / 000e | 04f3 / 129d / 24c6 | 2 (DF) | D0..EF | 12/700 jae | (297,346) vx=2 | - | ds:43de | = lockout | - |
| EP6 | 33bb / 000e | 04e0 / 1701 / 339f | 2 (DF) | D0..EF | 12/700 ja | (297,346) vx=2 | - | ds:5c3a | = lockout | - |
| EP7 | 30c4 / 000e | 047e / 1786 / 3a6e | 2 (FF) | E4..FF | 12/700 ja | (284,336) | - | ds:5532 | ds:5530 | - |
| EP8 | 353a / 000e | 0459 / 1724 / 3ab1 | 2 (FF) | ds:04a7..FD | launch flag 700; launch (148,396) v=(-147,-600) | none | - | ds:5f3e | ds:5f3c | 300/310 |
| EP9 | 309a / 000e | 0513 / 1893 / 3524 | 2 (DF) | D0..FD | 10/700 jae | (290,354) | ds:41bb | ds:418e (per ball ds:4183) | ds:4181 | 300 |
| EP10 | 31a4 / 000e | 050c / 16c1 / 3783 | 2 (DF) | D1..FD | 10/800 jae | (284,336) | ds:38b6 | ds:388b (per ball ds:3880) | ds:387e | 300 |
| EP11 | 2d1d / 000e | 050e / 1732 / 3774 | 2 (DF), 2 rows | D0..FD | 20/800 jae | (284,336) | ds:3781 | ds:3756 (per ball ds:374b) | ds:3749 | 300/310 |
| EP12 | 2e82 / 000e | 049a / 161b / 37a2 | 3 (DF), 2 rows | D0..FD | 20/800 jae | (284,336) | ds:3744 | ds:3719 (per ball ds:370e) | ds:370c | 300/310 |
| EP13 | 2b43 / 000e | 0497 / 15bc / 3475 | 2 (DF), 2 rows | D0..FD | 20/800 jae | (284,336) | ds:377d | ds:3752 (per ball ds:3747) | ds:3745 | 300/310 |

Notes on the variants, all [H] from the code and exercised by the harness:
* **EP4** draws 4 outlines on 2 key groups: the upper-left outline has no base offset, and the upper-right one is in the *top*
  half (ES = `pf_seg_top`). **EP12** draws 3; its upper-right one is in the top half. **EP11-13** draw every outline pixel
  twice (`mov es:[di+320],dl`, a second row). **EP7/EP8** draw with 0xFF.
* **EP8**: the level-0 lower bound is the variable ds:04A7 (0xEB at boot; the drain code cs:0A5B resets it to 0xEB, and other
  code sets 0xFF, collision.md section 8).
  There is **no plunger lane and no serve**. While no ball is active (slots 0..2), holding the plunger sets ds:5AEC to 700.
  On release the launch block (cs:0C3F..0C65) places slot 0 at (148,396) with v=(-147,-600). Its drain loop handles 3 slots;
  physics_step runs 5.
* **EP5/EP6** use one counter, ds:43DE / ds:5C3A, as both the sensor lockout and the kicker cooldown. They serve at (297,346)
  with **vx = 2**.
* **EP9-EP13** keep one sensor lockout per ball (the gravity loop copies `[di+ARR]` into the lockout before the scan) and have
  no sensor cooldown.
* **Flipper-kick y gates** (EP4, EP8-13): a flipper contact with ball y < 300 skips the side/tip kick and gets the normal
  1 px push-out (every iteration; EP12 cs:19C3 -> 1A29..1A38). On the first response it then takes the EP1 top kick (EP9,
  EP10: no second gate) or, below the second gate y < 310 (EP4, EP8, EP11-13), the **upper-flipper kick**: if vy > 0 then
  vy = 0; y += 1; x -= 1 (right) / += 1 (left); vx -= UX[a]; vy -= UY[a] with the group angle a and two 10-word DS tables
  (EP12 cs:1A91..1ABC, tables ds:374B / ds:3761; EP4 cs:1C62 picks right/left by x >= 145, tables ds:598F/59A5 and
  ds:59BB/59D1, and the left kick sets rule timer ds:081C = 400). It is not a plain wall reflection. engine.json
  `flipper_kick.side_min_y / top_min_y / upper_kick` (the tables are read from the EXE by the exporter). Reached only by EP4's and
  EP12's upper flippers; in EP10, EP11 and EP13 every lower-flipper contact has y >= 334 (not checked for EP8/EP9's outlines).
* **Gravity**: EP9-13 do `vy += g + extra - [sub]` (EP9: `sub ax,[41B9]`). EP3 adds +2 for slot 2 only (`cmp di,4; jne; add
  [di+vy],2`). The exporter now writes both into engine.json (`gravity.terms`, `gravity.slot_bonus`).
* **EP2's active surface** (cs:1A0F): D1/D2 are no contact; while the cooldown is set, CF/D0 are plain wall; outside x <= 260,
  y >= 75 they are no contact; and a probe that fires the kicker is **not** added to the hit list (`jmp` past the append).
  engine.json `kicker.{active_max, cooling_contact, window, contact_on_fire}` describes this.
* Kicker cooldown values (frames): EP1, EP3, EP4 = 3; EP2, EP7, EP8 = 2; EP5, EP6, EP9-13 = 4. EP9-13 set it *before* the tilt test, so a
  tilted contact still starts the cooldown (`kicker.cooldown_set_when_tilted`).

## 11. Per-table scenario sets (`tools/emu/scenarios/EPn/`)

`make_scenarios.py --table N` (or `--all` for EP2..EP13) calls `tools/emu/scenegen.py`. Without arguments, make_scenarios.py
writes EP1's hand-made set exactly as before (verified byte-identical). The generator boots the table, warms up the flippers,
and classifies the live collision buffer with the table's own wall LUT (`collision.json`; EP8 picks the LUT variant for the
runtime value of ds:04A7). It reads the flipper rest outlines from the pointer tables named in EPn.json. Each candidate start
is then **simulated on the original code** with probe capture (`EpEmu.capture_probes`: the buffer values under the probes of
every response). A candidate is kept only if the first response of ball 0 is the advertised kind. The search is seeded per
table and kind, so reruns give the same files (about 6 s per table).

| kind | placement | verified |
|---|---|---|
| `plunger_launch`, `plunger_short` | the table's serve position; held until the charge saturates (from step/max/cmp) / 20 frames. EP8: slot 0 inactive, plunger held 10 frames | ball leaves the lane / is launched |
| `fall_<o>_flipper_held/_released`, `<o>_flipper_shot` | above each rest outline `<o>` (`left`, `right`, `upper_left`, `upper_right`), straight drop through a clear corridor; for tucked-in upper flippers, aimed shots from nearby clear spots; shot = press 1..6 frames before landing | first contact is a flipper-colour probe on that outline; shot has `flipper_contact` set |
| `bumper_hit[_i]`, `slingshot_hit[_i]` | kicker-colour clusters (active LUT class, 8-connected after 2 px dilation) above/below y=200, approached from 16 directions | first contact is on that cluster, with a kick |
| `flat_wall_hit`, `flat_ceiling_hit`, `diagonal_wall_hit` | seeded random clear starts | first contact is plain wall with k in {1,25} / 13 / {7,19,31,43} |
| `multi_bounce_upper` | best of 12 fast upper-playfield starts | 4+ responses |
| `upper_layer_loop` | tables with 200+ level-1 wall pixels; best of 12 layer-1 starts near level-1 walls | 3+ responses |
| `long_600_scripted` | launch, flips every 45 frames, drain + the table's own serve, second plunge | no hang (the flipper phase is shifted if the original livelocks) |

**Demo-mode sets** (`tools/emu/make_attract_scenarios.py` -> `tools/emu/scenarios/EPn/attract/`, 4 per table: the
real `'D'` boot, the serve, a drop onto each flipper; full mode only, not part of `run_suite.py`'s sets):
`diff_traces.py -q --mode full --table N tools/emu/scenarios/EPn/attract`, and `tools/emu/attract_check.py` for the
dmd_message calls (and EP1's data segment) frame by frame. Results in docs/enhanced/attract.md.

Sets written (the generated EP1 set is a check of the generator): EP1 18, EP2 19, EP3 19, EP4 21 (all 4 flippers), EP5 18 (no
upper-layer scenario: 78 level-1 pixels), EP6 19, EP7 19, EP8 13 (no bumper/slingshot: EP8's toys are not in its collision
buffer, collision.md section 8; no `plunger_short`, since the launch is constant), EP9 18, EP10 18, EP11 18, EP12 21 (3 flippers),
EP13 18. EP4 has one kicker cluster only: its slingshots are plain wall in its LUT (active is D1-D2). The scenario files are
scenario JSON as in section 3 with `table: n`. New optional fields (additive): `ball.active`, `balls` (slots 1..4, as the Swift
port reads them), `extra_balls` (explicit slots).

## 12. Differential results per table (2026-09-27)

`diff_traces.py --table N` runs `tools/emu/scenarios/EPn/` plus its `hand/` and `extra/` subdirectories (table 1: the old default
dirs), passes `--table N` to the port, and writes traces to `scratch/diff/traces/EPn/`. `run_suite.py` runs every table's sets (`EPn/`, `EPn/hand/`, `EPn/extra/`; the
subdirectories hold directed scenarios, because `make_scenarios.py --table N` rewrites `EPn/*.json`) in any modes, in parallel,
and prints the table in docs/formats/README.md ("Differential results"). Current state: **physics 415/415, rules 415/415,
full 413/415** over all 13 tables.

History: the first all-table physics run was 223 of 239 exact; every divergence was a port feature that was missing (EP2's active
surface, the flipper y gates and upper-flipper kick in EP4/EP12, EP8's launch block). The per-table checks (hand/extra sets)
then found, and the port now implements: EP2 serve layer, lane without layer test, drain transfer, kick constant for y >= 200,
sensor sprite mask, kicker off the ramp level; EP3 slot-2 gravity bonus, 2-slot drain, slot-2 nudge skip; EP4 drain layer clear
and multiball transfer; EP5/EP6 shared lockout/kicker counter, serve vx = 2, EP5 x clamp stores 0; EP6/EP9 ball-position gates;
EP7 serve clears the level; EP8 no serve, 3-slot drain, x max clamp 304, dynamic wall threshold and scan bounds, any-ball nudge
condition; EP9-13 per-ball sensor lockout, 3 gravity slots, cooldown set before the tilt test; EP11/12 computed-offset pixel ops;
the scenario's `active` flags. The rules port's `rules` mode had one lifter bug (EP3 kicker through `ah`, tools/rules.py) and the
RULES_GAP attribution used the old ported-sensor list (now: rules.json handlers).

Full mode, the three scenarios that end in **ORIG_CRASH** (`diff_traces.py`: passes when every record before is identical): a ball
reaches x < 0 (EP10/EP13 `upper_layer_loop` at x = -1, EP5 `hand/x_clamp_left` starting at x = -18) and the next frame's
ball-background save, a planar VRAM copy whose `rep movsb` width comes from x (EP5 cs:378E, EP10 cs:4A50, EP13 cs:46E8), writes
over the table's code segment [H: memory-write hook on the code range]. The original then hangs or faults on its corrupted code;
the real game would crash the same way. `run_scenario.py` checks the code segment after every full-mode main loop and raises
`CodeOverwritten`. The two EP8 full-mode failures (`hand/ball_ball_hit`, `hand/ball_ball_slot2`) are HARNESS_ERRORs: with two
balls placed directly by the scenario, the background restore (cs:54EE) reads a record that was never saved, and the main loop
does not finish within 200M instructions [M]. Both are exact in physics and rules mode.

Exporter errors this found and fixed (`tools/export_engine_data.py`; EP1's engine.json only gained keys):
* kicker cooldown fell back to EP1's 3 in EP2, EP5 and EP9-13 because the call pattern assumed `jne +3`. It is now 2 (EP2)
  and 4 (the others); EP7/EP8 (2) were already found. This fixed EP5, EP9, EP10 and EP13 bumper/ceiling scenarios.
* serve fell back to EP1's (284,336) in EP5/EP6; the real serve is (297,346) with vx=2. This fixed EP6 `long_600_scripted`.
* `ball_slots_initial` was missing for EP3 and EP9-13 (patterns tolerate EP3's `jne +3; jmp` and EP9-13's lockout copy).
* tilt handling: `tilt_disables` was false for EP9-13 (their tilt test is `jne +3; jmp short`).

EP10's two unlifted main-loop fragments (cs:053E ball steering, cs:0571 top gate; rules.md 4.3) sit outside the physics ranges
and run in full mode only; the port runs them from the EXE (TableGlue `preFrame` / `postTimers`).
