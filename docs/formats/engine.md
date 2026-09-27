# Epic Pinball engine: main loop, timing, ball physics, audio

Static reverse engineering of `EP1.EXE` (CD v2.1), cross-checked against all 13
table EXEs (EP2 and EP10 checked in detail). No emulator trace was used. A
reference re-implementation (`scratch/engine/ep1_physics_ref.py`) runs the
transcribed step on the real EP1 collision map. It launches a ball up the
plunger lane, round the top arc, through the bumpers/slingshots, and into the
drain between the flippers, which is plausible behaviour and supports the model.

Confidence tags: **[H]** read directly from code/data, **[M]** inferred from
code with a small gap, **[L]** guess.

Addresses: `cs:XXXX` = EP1 code segment 0x3223 (file `0x32630 + XXXX`);
`ds:XXXX` = EP1 data segment 0x0015 (file `0x550 + XXXX`). Other tables keep the
same code but at different offsets. `scratch/engine/compare_tables.py` finds
them by byte pattern.

Tools:

```
.venv/bin/python tools/disasm.py func physics_step          # annotated listing
.venv/bin/python tools/disasm.py xref p_gravity             # who reads/writes
.venv/bin/python tools/disasm.py --exe original/EP10.EXE io 40
.venv/bin/python scratch/engine/compare_tables.py           # constants, all tables
.venv/bin/python scratch/engine/flippers.py 1               # flipper outlines -> json/png
.venv/bin/python scratch/engine/ep1_physics_ref.py 900 --flip-at 380
```

Symbols: `scratch/engine/ep1_symbols.json` (58 routines, ~107 DS variables, 22 CS variables).

---

## 1. Video mode and frame rate  [H]

`set_mode_x` (cs:4565) sets mode 13h, then unchains it (SEQ 04=06), writes Misc
Output `0xE3` (25.175 MHz dot clock, 480-line sync polarity) and loads a CRTC table
from `seg 0x2623:0004` (the "data segment X"): `06=0D 07=3E 09=41 10=EA 11=AC 12=DF
14=00 15=E7 16=06 17=E3`. This is the standard **320x240 Mode X**. The table is the
same in EP1, EP2 and EP10.

* Vertical total = 0x20D = 525 lines -> **59.94 Hz**, 16.683 ms, **~19,906 PIT ticks per frame**.
* Line compare (CRTC 18h) is set from `ds:0B36` (0x1B9 = scan line 441 of 480, i.e.
  row ~220): split screen. Rows 0..~220 show the scrolling playfield and the rest
  shows the score/DMD panel. `set_split_line` (cs:4683) animates the panel sliding
  in and out (Enter toggles it, cs:0E9D).
* Two pages, with CRTC start 0x0640 / 0x8340 (`set_scroll` cs:46E3). Camera row `ds:6A38`,
  target = max(ball y) - 120, eased by `delta >> ds:5873` each frame (cs:308D;
  key T opens the "BALL TRACKING" prompt, where I/F/S choose 0/2/3, cs:0D1D). [M]

## 2. Main loop and timing source

### PIT programming  [H]
All writes go to channel 0 (`out 43h,34h` = ch0, lo/hi, mode 2 rate generator):

| cs: | divisor | rate | use |
|---|---|---|---|
| 126F | 0x1900 = 6400 | 186.4 Hz (5.364 ms) | main loop reached vsync first (fallback / first frame): restart schedule |
| 3014 | 0x189C = 6300 | 189.4 Hz (5.280 ms) | **physics tick** |
| 2FF9 | 0xFFFE | 18.2 Hz | long timeout while ISR busy-waits for vsync (EP1 only) |
| 3027 | 0xFFFF | 18.2 Hz | same, menu mode |
| 303C | 0x4BF0 = 19440 | 61.38 Hz (16.29 ms) | menu mode: re-arm just before the next vsync (19440 < 19906) |
| 155B | 0 (mode 3) | 18.2065 Hz | restore BIOS rate at exit |

### Scheduler (timer ISR `cs:2FC6`, main loop end `cs:1243`)  [H]
The PIT is phase-locked to vertical retrace, so the physics runs at
**exactly 3 steps per video frame**:

```
vsync (3DAh bit 3) ─┬─ ISR: set vsync_flag, PIT=6300, physics_step #1
                    │  main loop sees flag -> isr_steps_left = 3, waits for end of retrace, starts frame
  +6300 ticks  ISR: steps_left 3->2, physics_step #2
 +12600 ticks  ISR: steps_left 2->1, physics_step #3
 +18900 ticks  ISR: steps_left 1->0, busy-wait for next vsync (~1000 ticks), then step #1 of next frame
```

* The physics step rate is 3 x 59.94 = **179.8 Hz**. Steps are spaced 6300, 6300 and
  ~7306 PIT ticks apart (5.28 / 5.28 / 6.12 ms).
* Every tick also calls `pc_speaker_tick` (cs:44C8) and chains to the old BIOS
  int 8 (so the DOS clock runs fast in-game).
* If the main loop overruns a frame, `isr_steps_left` stays 0. Ticks then only set
  the flag and no physics runs, so the game slows down (frame-locked) and does not
  skip steps. [H]
* `opt_no_timer` (`ds:679B`, launcher "SLOW PC/FAST PC"-style flag, PSP:A1 bit 2) leaves
  int 8 alone. The main loop then runs 3 `physics_step` calls back-to-back at each vsync (cs:1263). [H] (menu mapping [M])
* In menus/attract (`wait_frame` cs:0249, `cs:028C`=1) the ISR only emulates a
  60 Hz vsync interrupt and runs no physics.
* Raster-bar profiler: `raster_bar` (cs:44AE) writes the VGA overscan colour at
  section boundaries when `cs:44AD` is set (F9 in the pause menu).

### Per-frame main loop (`main_loop` cs:04D2 .. cs:129F)  [H]
Timers/counters, DMD text, pitch sweeps for SFX, **drain check** (y >= 0x18F), new-ball
serve, camera, plunger, attract auto-flip, stuck-ball nudge, **nudge/tilt**,
pause-menu keys, lane-lamp rotation on flipper press, flipper sprites
(`frame = (angle+2)/3`, 4 drawn frames per flipper), score, then **gravity** and the
per-ball rules scan (`ball_pixel_scan` cs:1679, which dispatches `colour_event_dispatch`
cs:1E3B), render (`render_frame` cs:3E35), then sync.

Gravity is added **once per frame** in the main loop. The 3 steps run in the ISR,
asynchronously to it. The exact phase of the gravity add relative to the 3 steps
depends on how long the main loop takes. [M]

## 3. Ball state  [H]

Five ball slots. Each quantity is an array of five s16 words, stride 2 (`di` = 0,2,..,8):

| var | EP1 ds: | meaning |
|---|---|---|
| ball_active | 6A3A | slot in play |
| ball_x, ball_y | 6A46, 6A52 | integer pixel position of the **top-left of the 15x14 ball box** in the 320x400 playfield |
| ball_vx, ball_vy | 6A00, 6A0C | velocity, **1/128 px per physics step** (y down positive) |
| ball_accx, ball_accy | 6A18, 6A24 | sub-pixel accumulators (7 fractional bits) |
| ball_layer | 6772 (bytes, stride 2) | 1 = upper level (ramp/habitrail): different colour classes |
| ball_w/h | 6B36/6B38 | 15, 14 |

Fixed point: effectively **position = int + acc/128**. Position and fraction are kept in separate words, and `acc` can hold more than one pixel of backlog when the cap applies.
Velocity units: **1 u = 1/128 px/step = 1.405 px/s**.

### Integration (`physics_step` cs:1724, per axis, per step)
```
acc += v                               ; s16
if acc >= 0: m = acc >> 7 ; if m > CAP: m = CAP ; acc = min(acc, 2000)
             pos += m ; acc -= m << 7
else:        m = (-acc) >> 7 ; if m > CAP: m = CAP ; acc = max(acc, -2000)
             pos -= m ; acc += m << 7
x = max(x, 1);  if y < 1: y = 3, vy = 0
```
CAP = 5 px/step in EP1 (x and y). EP2 uses 4/4 and EP10 uses x 4 / y 5 (see §9). Motion past
the cap is not lost: it is held in `acc` (up to 2000 = 15.6 px) and paid out on
later steps. Collision is skipped while y >= 0x180 (384). The ball drains at y >= 0x18F.

## 4. Collision model  [H]

**The collision map is the playfield image itself.** `pf_seg_top/bottom`
(ds:6C10/6C12) = segments 0x06E3/0x1683, the same 320x400 bytes that
`tools/extract.py` exports as `playfield_idx.npy`. At init (cs:03D5), every pixel
with value 0xD3..0xE6 (the flipper artwork, which is identical in every table) is
overwritten with 0x2A (empty) in the in-memory copy, after the art is copied to VRAM.
Flippers are then drawn into this map at runtime as outlines of colour 0xDF.

Colour classes (EP1, lower layer / upper layer). They differ per table, see §9:

| colours | effect |
|---|---|
| <= 0xB4 | nothing (floor art) |
| 0xB5..0xCF | drawn **over** the ball (occluder); not solid |
| 0xCF..0xEF | **solid** |
| 0xCF..0xD2 | solid + **kicker** (bumper if y<200 else slingshot) |
| 0xDF | runtime flipper outline |
| > 0xCF (and 0xFE always) | rule events via jump table cs:1E77[colour-0xAA] (rollovers, targets, ramps; 0xF0..0xFE are sensors: non-solid, event only) |
| upper layer | solid 0xBC..0xC7, occluder 0xBC..0xC7, no kickers |

**Contact sampling.** There are 48 perimeter points (`tbl_ball_samples` ds:6C6C, word offsets
`dy*320+dx` from the ball's top-left). Index 1 is east (14,6), index 13 is north, 25 is
west and 37 is south, going counter-clockwise; the list is in `scratch/engine/ep1_flippers.json`.
The sampler runs index 48 down to 1 and records every index whose pixel is solid.

**Direction.** From the hit indices: `lo=min, hi=max`.
* If `lo==1 && hi==48` (wrap): `dir = last + ((first + 48 - last) >> 1)`, wrapped to 1..48.
  With the 48->1 recording order this always gives 48 (a quirk).
* Else, with `d = hi-lo`: `dir = lo + d/2 (+24 and wrap if d > 24)`.

**Response loop** (`collision_response` cs:1A66). After each response the
sampling is repeated at the new position until there are no hits. Only the first response
in a step changes velocity (`collided_this_step` ds:6C59). The flag is cleared once per
`physics_step` (cs:1726), not per ball, so with several balls in play the first ball to collide
in a step blocks the velocity response (reflection, kick, top-of-flipper kick, nudge impulse) of the
later balls in that step. Their push-out and flipper side kicks still happen. Every iteration pushes
the ball 1 px along `tbl_pushout[dir-1]` (ds:5964: `x -= p0; y += p1`).

Normal vectors `tbl_normals` (ds:589C, 48 pairs `(t0,t1)`): `n = (nx, ny) = (-t0, t1)`.
They are elliptical, with |nx| up to 61 and |ny| up to 40, and never 0 (which avoids divide by zero).

Reflection (non-kicker, non-moving-flipper), exact 16/32-bit integer arithmetic
with truncating `idiv`:
```
A  = (64*nx) / ny                     ; s16
P  = A*vx + 64*vy                     ; s32
D  = A + (64*ny)/nx ; if D == 0: D = 1
wx = -(P / D)
E  = (ny*ny == 1) ? 0x7FF8 : (16*nx*nx)/(ny*ny) + 64
wy = -(P / E)
vx += (wx*20) / (REST_X + (upper ? UP_X : 0))     ; REST_X = ds:6781
vy += (wy*20) / (REST_Y + (upper ? UP_Y : 0))     ; REST_Y = ds:6783
```
`wx` is the exact projection `-(v.n) nx/|n|^2`. `wy` uses `16*nx^2` where a symmetric
formula would use 64, so wall hits get a y-impulse up to 4x larger than a true
reflection (this looks like a bug, but it is part of the "feel"). With divisor 17,
the normal component is scaled by 20/17, i.e. **restitution about 0.18** on
floor-like surfaces. There is no tangential friction, **no rolling/air friction,
and no velocity damping anywhere else**: energy is lost only in collisions. [H]

**Nudge impulse** (end of cs:1A66): while `nudge_timer` (ds:5870) >= 2 and
`4 <= dir <= 42`: `vy -= nudge_timer*8`, and `vx += 20` (Z or `,` held),
`vx -= 20` (`/` held), or 0 (Space).

**Kickers** (`kicker_hit` cs:19C1). When a kicker colour is hit and `kicker_cooldown` (ds:6769) is 0,
the step's response becomes `v += KICK * n` with no reflection (incoming velocity is kept).
KICK = ds:6785 = 8, so the kick is up to 488 u in x and 320 u in y. Cooldown = 3 frames.
Disabled while tilted.

**Ball-ball** (`ball_ball_collide` cs:1D47, pairs (0,1),(0,2),(1,2), same layer,
|dx|<=15, |dy|<=14): perimeter overlap gives the direction. Both balls go through the same
response with both divisors forced to **35** (EP3: 45). The two impulses are exchanged.

## 5. Flippers  [H]

**Input.** The int 9 handler (`keyboard_isr` cs:314B) reads port 60h and sets CS flags:

| key (set-1 scancode) | flag |
|---|---|
| LShift 2A/AA, Left 4B/CB | `key_lflip` cs:028D |
| RShift 36/B6, Right 4D/CD (also `.` 34, `X` 2D on press) | `key_rflip` cs:028F |
| Space 39 / Ctrl 1D | plunger (Space also nudges outside the lane) |
| Z 2C, `,` 33 | nudge A (cs:0298) ; `/` 35 nudge B (cs:0299) |
| Up/Down 48/50 | manual scroll ; Alt 38 cs:0294 |
| other | `last_scancode` cs:029B: Esc/Q quit prompt (F1 there = param editor), P pause, M music, S sfx, T ball tracking, Enter panel |

The joystick code (port 201h, cs:0714) exists but is skipped by an unconditional jump at cs:0711.

**Motion** (`flipper_update` cs:3CDD, called at the end of **every physics step**):
the angle (`lflip_angle` ds:6CD2 / `rflip_angle` ds:6CD4) runs 9 (rest) .. 0 (up) and
changes by **one step per physics step** in both directions. Full travel takes 9 steps,
**50 ms up and 50 ms down**. `lflip_moving` (ds:676F/6770) is 1 only on steps where the
flipper actually moved up. On each change the old outline is erased (0x2A) and the new one drawn
(0xDF) into the collision map from `tbl_lflip_outline` (ds:5AE1, 10 pointers to
`count, offsets...`, +0x283 into the bottom half; right: ds:5AF7, +0x284). The decoded
outlines are in `scratch/engine/ep1_flippers.json` (left pivot box x 88..135, y 360..396; right
x 167..214). A tilt forces both flippers to rest.

**Hits.** A ball touching 0xDF on a **moving** flipper sets `flipper_contact` (1 = left if
x <= 0x8C, else 2). The ball is moved up 1 px on every loop iteration and:
* contact index k=dir-1 in 5..31, or k < 5 / k >= 41 (side/tip): `v += (-t0,t1)[k'] * (FLIP_SIDE_X, FLIP_SIDE_Y)`
  with k' = 31 for k in 5..31 (normal (28,-35) -> **(+56, -140)**) and k' = 41 for k < 5 or k >= 41
  (normal (-35,-32) -> **(-70, -128)**), per iteration, after first zeroing vy if vy >= 30.
  The choice depends on the contact direction, not on which flipper was hit. (Verifier correction:
  an earlier version said (+-56, -140) for both.) This runs on every push-out iteration, not just the
  first, and there is no 1 px push-out on this path (only `y -= 1`).
* k in 32..40 (ball resting on top; first response of the step only): zero vy if vy >= 40, then
  `vx += +-fx[angle]*FLIP_TOP_X ; vy -= fy[angle]*FLIP_TOP_Y` with
  `fx = -3,-2,-1,-1,1,2,3,4,4,5`, `fy = 48,49,50,50,49,49,48,47,46,46` (ds:679C/67B2).
  In EP1 that is vy -= 230..250 u per step of contact.

A flipper that is not moving is an ordinary wall (reflection).

## 6. Plunger, nudge, tilt, misc  [H]
* Plunger: works while ball 0 is in the lane (x >= 280, y >= 220). Holding Ctrl/Space adds 12/frame to
  `plunger_charge` (ds:5897) while it is <= 700, so the maximum is 708. On release: `vy -= charge; y -= 1`. A new ball
  is served at (284, 336), velocity 0.
* Nudge (cs:0DFD): Z/`,`/`/`/Space outside the lane, accepted only when `nudge_timer` = 0.
  Sets `nudge_timer` = 10 frames, `tilt_meter` (ds:5871) += 35, camera shake -10 rows.
  The meter decays by 1 per frame. **meter > 80 means TILT** (`tilted` ds:5872: flippers and kickers off).
* Stuck ball: if x,y are unchanged for 25 consecutive frames, vx += 1 once. **Demo mode only**: cs:0C48..0C5D skips this when demo_mode (ds:6C5A) != 1 (found by the emulator harness, see emulation.md).
* Plunger lane: while the ball is in the lane (layer 0, x>=0x118, y>=0xDC, serve delay 0) and the plunger is not held, vx is forced to 0 every frame (cs:0B83).
* Boot: both flippers start at angle 2, not rest, and fall to rest over the first steps; the first flipper_update erases a never-drawn angle-2 outline (removes 4 wall pixels in EP1).
* Push-out loop (cs:1826..18FA) has no iteration cap and runs inside the timer ISR with interrupts off: a fast ball straddling 1-px wall art can hang the original game. The port caps it (10,000 iterations).
* `extra_gravity_timer` (ds:06D7): a rule event sets it to 13. It is added to gravity
  each frame while it decays to 0 (a temporary extra pull). [M]

## 7. Audio  [H]

**Architecture.** Table EXEs do not program the sound hardware. `PINBALL.EXE`
stays resident with the **MASI** sound system (Joshua C. Jensen, 1994; drivers
`MDRV00nR.MUS`: 000 = software mixer "MLPR", 001 none, 002 PC speaker, 003 GUS,
004 SB/SBPro/SB16/clone, 005 PAS). It passes two far pointers on the command line
as hex nibble pairs (`'0'+n`): PSP:83..8A -> `ds:0000` (API entry), PSP:8B..92 ->
`ds:0004` (its array of 25 x 0x60-byte sample descriptors). The table calls the API through
the stub at seg 0x3D35:0000 (file 0x3D750) with BX = function (0x0C play sample ES:DI,
0x0F stop voice, 0x11 set pan, 0x09/0x0A music, 0x1C at exit; names [M]).
If the digits are invalid (the launcher writes 0xC8 when there is no card), `snd_present` = 0 and
the PC-speaker fallback (`pc_speaker_tick`, PIT ch2, one note per timer tick) is used.

**SFX sample rate = 11000 Hz.** `sfx_play` (cs:014A) writes the word `sfx_rate_hz`
(ds:0ADC, file 0x102C, initial value **11000**) into the descriptor at +0x45 before every
play. The SB driver's play routine (MDRV004R.MUS file 0x8E9) loads that dword and
computes the voice step as the 16.16 value `rate / mix_rate` (file 0xB03). So +0x45 is the sample's playback rate in
Hz, and the hardware output rate is independent of it. The launcher's own default at load is 8000
(PINBALL.EXE file 0x1E16: `mov dword cs:[di+45h],1F40h`), but the table overwrites
it on every play. All 13 tables initialise the variable to 11000, and the common queued-SFX
path (`sfx_pending`, cs:08BB..08CE) saves it, forces 11000 for the play and then restores it.
So 11000 Hz is the natural rate of the samples. `sfx_rate_hz` is a live pitch variable, not a constant:
EP1 has about 30 writers (19 immediate stores; 9 to 32 per table), including speed-dependent rates
`3000 + 100*|vx|` (cap 12000) and `6000 + 100*vx` (cap 15000) at cs:2F50/2F8F. Some effects temporarily
use other rates for pitch: 3000..24000 Hz sweeps at cs:08E1/0923/0975, and fixed
values of 4000..22000 in rule code. Pan = `(ah>>4)` or ball x/20, clamped 0..15,
sent as `n*16-128`. Voices are allocated round-robin over 4 channels.

**Output rate (DSP time constant).** Only the MASI driver programs the DSP, and the rate it uses is the
user's mixing-rate choice from SETUP (menus allow SB 4000-44100, SBPro 8000-44100,
SB16 8000-88200, clone 8000-22050). MDRV004R file 0x247D..0x250D:
* DSP >= 4.00: cmd **0x41** + 16-bit rate. The value sent (and stored as `mix_rate`) is
  dword `[0x263] >> 1`. Why it is halved was not traced. [M]
* high-speed/stereo path: TC16 = 65536 - 256000000/rate (high byte sent with cmd 0x40).
* else cmd **0x40**, TC = 256 - 1000000/rate. The true output rate
  (1000000/(256-TC)) is stored and used as `mix_rate`, so SFX pitch stays correct.

Example: 22050 selected gives TC 211, and the hardware runs at 22222 Hz. The configured value is not on the CD.

**SFX bank loading (for `tools/sfx.py`).** PINBALL.EXE file 0x1D7F..0x1E30 reads the
0x64-byte header (25 entries of `u16 len, u16 paras`), seeks to **`(paras+1)*16`** and
loads **`len - 0x28`** bytes (8-bit, descriptor flag 0x10). That means the first 16 bytes at `paras*16`
and the last 24 bytes are not played. [H for the code; M for why]

## 8. Command line from PINBALL.EXE  [H]
`PSP:82` players '1'..'4' (or 'D' = demo); `83..92` sound pointers; `9E` '@';
`9F` balls per game (launcher byte cs:3B9F); `A0` **table angle** 0/1/2 -> gravity
param += -1/0/+1 (the launcher option "NORM ANGLE"; per-table setting) [M for the menu labels];
`A1` bits: 0 sfx on, 1 music on, 2 no-timer mode, 3 sprite option.
Launcher template at PINBALL.EXE file 0x6E6E; the digits are written at cs:3DD8..3E01.

## 9. Physics constants ("classic" preset)

The ten words at ds:6781..6793 are a parameter block. This is confirmed by a hidden developer
editor: in the pause/quit prompt, press F1 ("ENTER PARAMS"), then type 2-digit decimal
values into successive words (cs:1408..1475).

| name | EP1 addr | raw | fixed-point / units | meaning | conf |
|---|---|---|---|---|---|
| physics step rate | cs:3014 + CRTC | 3/frame | 179.8 Hz (frame 59.94 Hz) | steps per video frame | H |
| PIT tick divisor | cs:3018 | 0x189C | 6300 -> 5.28 ms | spacing of steps 2 and 3 | H |
| position | ds:6A46/6A52 + acc 6A18/6A24 | - | px + acc/128 | ball top-left, 15x14 box | H |
| velocity unit | ds:6A00/6A0C | - | 1/128 px/step = 1.405 px/s | | H |
| p_rest_div_x | ds:6781 | 17 | dvx = wx*20/17 | x reflection divisor (restitution ~0.18) | H |
| p_rest_div_y | ds:6783 | 17 | dvy = wy*20/17 | y reflection divisor | H |
| p_kicker | ds:6785 | 8 | v += 8*n, n up to (61,40) | bumper/slingshot kick | H |
| p_flip_top_x | ds:6787 | 4 | x fx[angle] | moving flipper, ball on top, vx gain | H |
| p_flip_top_y | ds:6789 | 5 | x fy[angle] (46..50) | moving flipper, vy kick ~ -230..-250 u | H |
| p_flip_side_x | ds:678B | 2 | x 28 = +56 u (k'=31) or x -35 = -70 u (k'=41) | moving flipper side/tip, per push-out iteration | H |
| p_flip_side_y | ds:678D | 4 | x -35 = -140 u (k'=31) or x -32 = -128 u (k'=41) | same, upward | H |
| p_up_div_y | ds:678F | 3 | added to 17 | upper-layer y divisor | H |
| p_up_div_x | ds:6791 | 3 | added to 17 | upper-layer x divisor | H |
| p_gravity | ds:6793 | 4 | u per **frame** (+-1 table angle) | 240 u/s^2 = 337 px/s^2 | H |
| gravity cutoff | cs:11AE | 0x140 | 320 u = 2.5 px/step | no gravity while vy > 320 | H |
| step cap | cs:175E/17C9 | 5 | px/step/axis | 899 px/s | H |
| accumulator clamp | cs:1766 | 0x7D0 | +-2000 = 15.6 px | backlog limit | H |
| ball-ball divisor | cs:1DC3 | 0x23 | 35 | both balls | H |
| kicker cooldown | cs:19D3 | 3 | frames | | H |
| flipper steps | cs:3CF5 | 9 | 10 angles, 1/step | 50 ms full travel | H |
| plunger step / max | cs:0B5B/0B63 | 12 / 700 | u per frame; max 708 u | release: vy -= charge | H |
| nudge | cs:0E32/0E37 | 35 / 10 | tilt add / frames | impulse vy -= 8*timer, vx +-20 | H |
| tilt threshold | cs:0E64 | 0x50 | 80, decay 1/frame | | H |
| stuck-ball (demo only) | cs:0C8E | 25 | frames | vx += 1 | H |
| drain line | cs:0A3E | 0x18F | y px | | H |
| SFX rate | ds:0ADC | 11000 | Hz | per-play sample rate | H |

### Per-table parameters (from `compare_tables.py`)  [H]
`params` = [rest_x, rest_y, kicker, flip_top_x, flip_top_y, flip_side_x, flip_side_y, up_y, up_x, gravity]

| table | params | step cap x/y | ball-ball | solid / kicker< / flipper colour | upper solid |
|---|---|---|---|---|---|
| 1 | 17 17 8 4 5 2 4 3 3 4 | 5/5 | 35 | CF..EF / D3 / DF | BC..C7 |
| 2 | 17 17 6 4 5 2 4 3 3 4 | 4/4 | 35 | CF..FF / D2 / DF | BC..C7 |
| 3 | 17 17 4 4 5 2 4 3 3 4 | 4/4 | 45 | D0..EF / D3 / DF | BC..C7 |
| 4 | 17 17 4 4 6 2 4 3 3 4 | 4/5 | 35 | D1..FD / D3 / DF | B0..BB |
| 5 | 16 16 6 2 4 1 3 4 4 3 | 4/4 | 35 | D0..EF / D3 / DF | C3..C6 |
| 6 | 15 15 8 4 6 2 5 4 4 4 | 4/4 | 35 | D0..EF / D3 / DF | C3..C6 |
| 7 | 17 17 5 4 5 2 4 3 3 4 | 5/5 | 35 | E4..FF / E7 / FF | C8..CF |
| 8 | 17 17 9 4 6 2 4 3 3 4 | 4/5 | 35 | lower bound from ds:04A7 (runtime), upper FD / EF / FF | B0..BB |
| 9 | 17 17 7 4 6 2 4 3 3 4 | 4/5 | 35 | D0..FD / D3 / DF | B0..BB |
| 10 | 17 17 9 4 6 2 4 3 3 5 | 4/5 | 35 | D1..FD / D3 / DF | B0..BB |
| 11 | 17 17 5 2 2 2 2 3 3 5 | 4/5 | 35 | D0..FD / D3 / DF | A8..B7 |
| 12 | 17 17 5 2 2 2 2 3 3 4 | 4/5 | 35 | D0..FD / D3 / DF | A1..A7 |
| 13 | 17 17 5 2 2 2 2 3 3 4 | 4/5 | 35 | D0..FD / D3 / DF | B2..B6 |

These are the same in every table: timing (PIT 0x189C/0x1900/0x4BF0, 3 steps/frame), the
integration scheme and ±2000 clamp, gravity cutoff 320, plunger 12/700, nudge tilt add 35
(nudge window 10 frames, except **EP3 = 9**), tilt 80, flipper kick tables fx/fy, the normal table, and SFX rate 11000.
EP1, EP9, EP10, EP11, EP12 and EP13 add a second, event-driven term to gravity (`gravity_extra` in the script
output; EP1's is `extra_gravity_timer`). EP2-EP8 add only the parameter. Only EP1 programs the 0xFFFE timeout.
EP7/EP8 use a different flipper colour (0xFF) and EP8 builds its lower solid
bound at runtime. Their colour classes need checking before the port uses them.

## 10. Not determined / caveats
* No dynamic confirmation (DOSBox-X debugger trace) was done. Everything here is static. The gravity
  phase relative to the 3 ISR steps is load-dependent.
* Rule/event handlers (cs:1E3B jump table, 86 colour cases) are not documented here:
  ramps/layer switching, targets, kickbacks, `gate_draw`, the `extra_gravity_timer` trigger.
* Several render/DMD routines are named only loosely (see `conf` in the symbol file).
* The MASI API function-number meanings are inferred from call sites. The launcher's
  API layer between the table stub and the driver jump table was not traced.
* Menu labels for the angle digit (only "NORM ANGLE" is a literal string) and the no-timer flag are [M].
* The user's configured mixing rate (SETUP output) is not on the CD, so the actual DSP time
  constant used in a given install is unknown. SFX pitch does not depend on it.
