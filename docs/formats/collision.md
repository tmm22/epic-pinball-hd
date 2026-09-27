# Collision and table geometry (EPn.EXE)

Status: decoded for all 13 tables by static analysis. Nothing here has been
checked by running the game (no DOSBox debugger trace yet).
Extractor: `tools/collision.py`. Disassembly helper: `scratch/collision/epdis.py N <ip-hex> <count> [seg-hex]`.

Addresses are EP1 unless stated. `cs:XXXX` is an offset in the EP1 code segment
0x3223, so file offset = 0x32630 + XXXX. `DS:XXXX` is an offset in the EP1 data
segment 0x0015, so file offset = 0x550 + XXXX. Other tables have the same code
at different addresses. `collision.json` gives the per-table addresses.

Confidence tags: **[high]** means the code was read and the result checks out
visually or in several tables. **[med]** means a reading of the code that is
probably right but was not cross-checked. **[low]** means a guess.

## 1. There is no separate collision map. The playfield pixels are the collision data **[high]**

The ball collides with the **palette indices of the 320x400 playfield bitmap**.
The display (VRAM) is initialised from this memory at start-up (`cs:03A8`..`cs:03BD`),
before the substitution described below. Artists painted the
collision geometry into the art using reserved index ranges. What each index
means is hard-coded per table in the table's own copy of the engine.

* The two playfield segments (EP1 0x06e3 / 0x1683) are returned by far stubs
  at `cs:4530` / `cs:4540` (`mov ax,seg; retf`). They are stored at
  `DS:6C10` (top) and `DS:6C12` (= top+0FA0h, bottom) at `cs:038A`.
* At start-up (`cs:03D5`..`cs:0417`, both halves), after the bitmap has been
  copied to VRAM, every in-memory pixel with 0xD3 <= v <= 0xE6 is replaced by
  0x2A. That index range holds the 2x10-colour flipper sweep art printed in
  the bitmap (per-index counts are nearly identical in EP1-6 and EP10). EP9,
  EP11, EP12 and EP13 also run the loop, but their bitmaps contain almost no
  D3-E6 pixels (19, 0, 0, 0), so there it changes (almost) nothing. After this step
  the RAM copy is the **collision buffer**. `collision_idx.npy` holds it.
  EP7 and EP8 have no such loop.
* The third chain segment, "data segment X" (EP1 0x2623, 49152 bytes), is
  **not** collision data. It is the data segment of the graphics library at
  `cs:4565`ff. That code sets `DS=ES=2623h`, stores the Mode X pitch 0x50 at
  `[0035h]`, builds a 480-entry row-offset table at `[0039h]`, a page table at
  `[03F9h]` and a 256-byte bit-reverse table at `[0409h]`. The rest of the
  segment holds sprite and font pixels. **[high]** for the variables,
  **[med]** that the rest is sprites (only histograms and a visual check).

### Addressing **[high]**
Per-ball state is held in word arrays indexed by `di` = 2*ball (up to 5 balls):
`[di+6A46]` x and `[di+6A52]` y (integer pixels, the top-left of the ball's
15x14 box), `[di+6A00]` vx, `[di+6A0C]` vy, `[di+6A18]`/`[di+6A24]` sub-pixel
accumulators (1/128 px), `[di+6772]` level byte (0 = table, 1 = ramp/wire level).

Sampling (`cs:1837`): `ES = [6C10] + y*14h` (14h paragraphs = 320 bytes, so ES
points at row y and runs on into the bottom half), `BX = x + ring[k]`,
`cmp es:[bx], ...`.

## 2. Ball ring: 48 probe points **[high]**
`DS:6C6E`..`DS:6CCC` holds 48 words, read as `[si+6C6C]` for si = 60h, 5Eh, .. 2.
Each word is y*320+x relative to the ball's top-left. Probe k=1..48 runs
counter-clockwise from the right-hand side (k=1 (14,6), k=12 top (7,0), k=24
left (0,6), k=36 bottom (7,13), k=48 (14,7)). The points trace the outline of
the 15x14 ball sprite (sprite at `DS:6B36`: word w, word h (0x0F, 0x0E), then pixels; copied to
`DS:6A5E` each frame). The table is identical in all 13 tables.
`collision.json: ball.ring_xy`, `ball.png`.

## 3. Wall test and the per-index LUT **[high]**
Loop `cs:1846`..`cs:18C3`. EP1 register setup for level 0 is
`dl=DF al=CF ah=EF dh=D3`. If `[di+6772]==1` (ramp level) it is
`dh=0 al=BC ah=C7`. For each probe:

```
v <  al or v > ah      -> no contact
v <  dh                -> contact + call cs:19C1 (active surface; rules code)
v == dl                -> contact; if the flipper on that side (x<=8Ch = left) is
                          moving up, set [6768]=1/2 (flipper-contact flag)
else                   -> contact
```
Each contact appends k to the list `DS:6C20` and bumps the count `DS:6C1E`.
The comparison chain differs slightly between tables. EP2 adds more position
checks. EP8 has no upper bound and loads `al` from the variable `DS:04A7`
(start value 0xEB, and code sets it to 0xFF). The extractor therefore does not
pattern-match ranges. It **runs the chain symbolically** for all 256 index values
at both levels and records which code path each value takes
(`wall_lut`, `wall_lut_ranges`, `wall_events` in collision.json).

| Table | sample ip | Level 0 (table) | Level 1 (ramp) | Ball-overlap scan, level 0 | flippers |
|---|---|---|---|---|---|
| EP1 | 1863 | CF-D2 active, D3-DE wall, DF flipper, E0-EF wall | BC-C7 wall | B5-CF occludes, D0-FF sensor | 2 |
| EP2 | 19d1 | CF-D0 active (conditional), D3-DE wall, DF flipper, E0-FF wall | BC-C7 wall | B0-B4 sensor, B5-CE occludes, CF-FF sensor | 2 |
| EP3 | 15e3 | D0-D2 active, D3-DE wall, DF flipper, E0-EF wall | BC-C7 wall | C0-CF occludes, D0-FF sensor | 2 |
| EP4 | 18c6 | D1-D2 active, D3-DE wall, DF flipper, E0-FD wall | B0-BB wall | A8-C6 occludes, C7-D0 sensor | 4 |
| EP5 | 13dc | D0-D2 active, D3-DE wall, DF flipper, E0-EF wall | C3-C6 wall | C0-CF occludes, D0-FF sensor | 2 |
| EP6 | 1840 | D0-D2 active, D3-DE wall, DF flipper, E0-EF wall | C3-C6 wall | C0-C5 occludes, C6-FF sensor | 2 |
| EP7 | 18c5 | E4-E6 active, E7-FE wall, FF flipper | C8-CF wall | C3-D7 occludes, D8-FF sensor | 2 |
| EP8 | 1872 (seg 353a) | EB-EF active, F0-FE wall, FF flipper (threshold variable) | B0-FE wall (level probably unused) | E1-F0 sensor | 2 |
| EP9 | 19d2 | D0-D2 active, D3-DE wall, DF flipper, E0-FD wall | B0-BB wall | A8-BB occludes, BC-D0 sensor | 2 |
| EP10 | 1800 | D1-D2 active, D3-DE wall, DF flipper, E0-FD wall | B0-BB wall | B0-C6 occludes, C7-D0 sensor | 2 |
| EP11 | 1871 | D0-D2 active, D3-DE wall, DF flipper, E0-FD wall | A8-B7 wall | 88-C0 occludes, C1-D0 sensor | 2 |
| EP12 | 175a | D0-D2 active, D3-DE wall, DF flipper, E0-FD wall | A1-A7 wall | 98-AF occludes, B0-D0 sensor | 3 |
| EP13 | 16fb | D0-D2 active, D3-DE wall, DF flipper, E0-FD wall | B2-B6 wall | B2-B7 occludes, B8-D0 sensor | 2 |

Notes:
* Start-up substitution removes D3-E6 from the buffer. Static walls are therefore
  E7..top-of-range, and D3-E6 only appear when the engine writes them at run
  time: the flipper outline (DF), and gates. **[high]**
* "active" = bumpers and slingshots. In EP1 the handler at `cs:19C1` sets
  `[676C]=[6785]` (8). It then scores based on position: y<200 means one of two
  bumpers (split at x=CBh), otherwise a slingshot (split at x=91h). Both the
  test and the response live in table-specific code. **[high]** for EP1.
* EP2 differs: for CF-D0, if `[5560]` is 0 and the ball is inside an x/y window
  (x<=104h, y>=4Bh), the handler `cs:1B47` is called and the probe is then
  counted as a **miss** (`cs:1A2E` jumps to the miss path). If `[5560]` is not 0
  it is a plain wall. D1-D2 never collide in EP2. **[high]** (read from code)
* On the ramp level only the ramp-rail range collides. Everything else on the
  table is passed through. **[high]**

## 4. Contact normal and response (`cs:1A66`..`cs:1D46`) **[high] for the geometry, [med] for the maths**
1. Take the min and max of the probe indices that hit. If min=1 and max=48 (the
   run wraps past the right-hand side), the code computes
   `list[last] + (list[0]+48-list[last])/2` from the first and last list
   entries. Probes are appended in descending k order (48..1), so those entries
   are always 48 and 1 and the result is **always k=48**. This is not a true
   wrap average; a port that wants to match should use 48. Otherwise
   k = min + (max-min)/2, adding 24 if the span is over 24 (then wrap mod 48).
   k is stored at `[586E]`, and the opposite direction k-1+24 at `[586F]`.
2. Normal table `DS:589C`: 48 entries of (nx,ny) words, stride 4, index k-1.
   These are not unit vectors: the magnitudes run from about 61 (horizontal)
   down to 40 (vertical). The table is the same in every table. The code uses
   **(-nx, +ny)** in screen coordinates (y points down). For example, a hit at
   the top probe gives (-2,+40), which pushes the ball down.
3. Push-out table `DS:5964` (same indexing): `x -= px; y += py`. Entries are
   in {-1,0,1}, so the ball is moved one pixel out of the wall.
4. If `[6C59]` shows a contact already handled this step, stop here.
5. Active surface (`[676C]` != 0): `v += [676C] * N` (a kick along the normal)
   with no reflection.
6. Otherwise:
   `A = (64*nx/ny)*vx + 64*vy`,
   `dvx = -A / (64*ny/nx + 64*nx/ny)` (the x part of the projection of v on N),
   `dvy = -A / (16*nx²/ny² + 64)`.
   The 16 in place of 64 is what the code does. Whether it was meant is unknown.
   Then `dvx = dvx*20/[6781]` and `dvy = dvy*20/[6783]` (EP1: 17 and 17; on
   the ramp level `[6791]`/`[678F]` = 3 is added to the divisor), and
   `v += dv`. Intermediates are 32-bit (`imul` into dx:ax, then 32/16 `idiv`).
   With the true 64 this would be a uniform restitution of about 3/17=0.18. With
   the code's 16 the dvy term is too large whenever nx/ny != 0. Emulating the
   integer maths (verifier script `scratch/verify-collision/response.py`, static
   only) for a head-on hit at |v|=256 gives e=0.18 for axis-aligned normals
   (k=1,13,25,37), but e of about 0.3-0.56 plus a tangential kick of up to about
   190 on diagonal normals (k=4,7,19,28,43...). A control run with 64 gives
   0.17-0.18 everywhere. So the damping is strong on horizontal and vertical
   walls and much weaker, with a skew, on diagonal walls. **[med]** (static
   emulation, not measured in-game)
7. Flipper contact (`[6768]` != 0): `y -= 1`. If k-1 is in 32..40 (the ball
   sits on the flipper), the kick is taken from per-position tables (`DS:679C`
   vx and `DS:67B2` vy, 10 words each, scaled by `[6787]`=4 and `[6789]`=5).
   Other contact directions get a fixed nudge along normal 31 or 41.
8. Ball-ball contact `cs:1D47`: the same ring is tested against the other
   ball's offset, then `cs:1A66` is run for both balls and velocities are
   exchanged. **[med]**

Movement (`cs:1724`): `acc += v`, and the ball moves in steps of at most 5 px
(acc>>7). The accumulator is clamped to ±7D0h. After the move, the wall test
runs. After a response it jumps back (`cs:18FA` -> `cs:1826`) with `[6C59]=1`
and re-probes. Later passes only apply the 1-px push-out, so this is a
push-out loop that repeats until no probe hits. y<1 is clamped to 3. y>=180h leaves the loop (drain). Gravity `cs:11AE`:
if vy<=140h, `vy += [6793] + [06D7]` (EP1: 4, and ramp extra = 0 or 0Dh, set by
the ramp-entry sensor). **[med]**

## 5. Flippers are written into the collision buffer every frame **[high]**
`cs:3CDD` (left) and `cs:3D79` (right). Each flipper has a position counter
0..9 (`[6CD2]`/`[6CD4]`, 9 = rest, 0 = fully up) and a table of 10 pointers
(`DS:5AE1` left, `DS:5AF7` right). Each pointer leads to a word count followed
by that many y*320+x offsets. The offsets are added to a base (`+283h` left,
`+284h` right) inside the **bottom** half. Each frame, if the position counter
changes (or is forced to rest by `[5872]`), the routine writes 0x2A over the old
outline and DF over the new one. An idle flipper at rest is not rewritten.
Outlines are 58-74 px in EP1-9 (59-75 in EP10) and 96-108 px in EP11-13. EP4
has 4 flippers and EP12 has 3. EP4's fourth and EP12's third use the top half.
The others use the bottom half. EP7 and EP8
use 0xFF. Output: `collision.json: flippers[].positions[].pixels` (playfield
x,y), drawn in white/yellow on `collision.png`.

## 6. Ball-overlap scan: draw order and sensors (`cs:1679`) **[high]**
Each frame, for the current ball, every pixel under its 15x14 box is read from
the collision buffer (`mov al,es:[di]`). With `bl=B4 bh=CF` at level 0, or
`BB/C7` when `[677E]` (the current ball's level) is 1:
* `v <= bl`: the ball is drawn in front.
* `bl < v <= bh`: the pixel is copied into the ball sprite, so it is drawn
  over the ball (ramps and rails the ball passes under).
* `v > bh`: this is a sensor candidate. It fires only when the debounce
  counter `[676B]` is 0 (it counts down each frame, `cs:09EC`), or when v=0xFE,
  and only if `[676A]` is 0 as well. It then calls `cs:1E3B`.

`cs:1E3B` filters the value (at ramp level EP1 only passes F9/F8/F1). It then
jumps through a 85-entry table `cs:1E77` indexed by `v-0AAh`. Most entries are
no-ops. The rest are the table's rules: rollovers, lane and hole sensors,
ramp entry and exit. The extractor lists, per level, every index that reaches
a real handler (`sensors`), and tags handlers whose first block does
`mov [level],1` (`enters_ramp_level`) or `mov [level],0` (`leaves_ramp_level`),
or only resets the debounce counter (`debounce_only`). In EP1, F0 starts the
ramp level (`[677E]=1`, ramp gravity 0Dh) and F1 ends it. The tagging is
heuristic and only looks at the handler's first basic block. It finds no
ramp-entry handler in EP2 or EP8. EP2's does exist: sensor D2 dispatches to
EP2 `cs:2BBA`, which does `cmp [62B8],0BEh; jbe` and then `mov [5574],1`, so it
enters the ramp level only when ball y <= BEh. The heuristic stops at the
`jmp` taken for other y values. EP2 `cs:2792`/`cs:27E1` also set `[5574]=1`
outside the dispatch table. **[med]**

## 7. Other run-time edits of the collision buffer **[high] that they exist, [low] for their meaning**
Code that loads ES from `[6C10]`/`[6C12]` and stores bytes elsewhere:
EP1 `cs:2706`/`cs:2817` (a 3x3+ block near bottom-half offset 529h is set to
C0h or 01h) and `cs:4488` (24 pixels at x 22-38, y 366-373 are set to 0xEB wall
or 0x01 open, gated on `[5ADE]`; this looks like a left outlane gate). These are
listed per table in `runtime_buffer_writers`. They are table rules and are
**not** applied to the exported buffer. The extracted buffer is the start-up
state.

## 8. EP8 **[med]**
EP8's code segment is 0x353A. Its collision buffer is still the playfield chain
(seg 0x073F, pointer `DS:723B`). That chain image is a background texture
(indices A0-DF) with the outline and wire lanes in F0-FE. The wall threshold
comes from `DS:04A7` (EB, or FF, which switches almost all walls off), and the
occlusion bounds come from `DS:04A6`/`04A9`. The ball sprite is chosen from a
pointer table `DS:6DF0`. No ramp-entry sensor was found, so level 1 (which
would treat the whole texture as wall) is probably never used. Bumpers and
other objects on EP8 are not visible in the collision buffer. They must be
drawn into it at run time, or handled by code, and this has **not** been
worked out.

## Outputs (per table, `extracted/tables/EPn/`)
| File | Content |
|---|---|
| `collision_idx.npy` | 400x320 uint8 collision buffer (start-up state) |
| `collision.npy` | (2,400,320) uint8 class per pixel for level 0 and 1: 0 empty, 1 wall, 2 wall on some code paths, 3 active, 4 active/conditional, 5 flipper value |
| `collision.json` | code addresses, wall/occlusion LUTs (256 entries per level), threshold variables, ring, normal and push-out tables, flipper outlines, sensor dispatch table and handler tags, run-time writers |
| `collision.png` | 2x-scaled level 0 / level 1 overlay. Red wall, orange active, yellow flipper value, white/yellow flipper outlines, green ramp entry, magenta ramp exit, cyan other sensors |
| `ball.png` | ball sprite |
| `../collision_summary.json` | per-table ranges |

## Gaps
* Nothing has been checked at run time (for example, a DOSBox-X debugger
  breakpoint on `cs:1863`).
* Sensor handler semantics (which rollover is which, scoring) are not
  decoded. Only their addresses and tags are known.
* Run-time gate edits (section 7) and EP8's run-time objects are listed but
  not modelled.
* The meaning of the 16-vs-64 constant in the dvy formula, and the exact
  flipper kick behaviour, need a run-time check.
