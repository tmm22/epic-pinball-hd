# Table rules: EP1 decode and the `epic-pinball-rules/1` format

Status: EP1's sensor handlers and the rule fragments in its main loop are decoded and
lifted to JSON by `tools/rules.py`. A differential test runs the lifted rules
against the original machine code in an emulator and they agree. EP2 and EP10 go
through the same lifter without annotations to test how far the format stretches.
Everything here is static analysis, plus emulation of isolated routines with Unicorn.
The game itself has not been run in DOSBox-X.

Confidence tags: **[H]** read from code and confirmed by the differential test,
**[M]** read from code, meaning inferred (for example what a sensor is physically),
**[L]** guess.

Addresses: `cs:XXXX` is EP1 code segment 0x3223 (file `0x32630+XXXX`) and `ds:XXXX`
is EP1 data segment 0x0015 (file `0x550+XXXX`), as in engine.md.

```
.venv/bin/python tools/rules.py 1 2 10 --report          # -> extracted/tables/EPn/rules.json
.venv/bin/python tools/rules.py 1 --no-write --dump h2379 # one handler as readable text ("all" for everything)
.venv/bin/python scratch/rules/verify_ir.py 1 300          # IR interpreter vs Unicorn on the real code
.venv/bin/python scratch/rules/render_sensors.py 1         # scratch/rules/ep1_sensors.png (annotated map)
.venv/bin/python scratch/rules/summary.py 10               # compact per-handler summary
```

Scratch files: `scratch/rules/ep1_lifted.txt` (all EP1 handlers and hooks, readable),
`ep2_lifted.txt`, `ep10_lifted.txt`, and `ep1_handlers_raw.asm` (a linear disassembly of cs:1F23..2FC6).
Symbols: 35 code labels and 71 data names were added to `scratch/engine/ep1_symbols.json`
(entries tagged `"added_by": "rules"`; existing entries were not changed).

---

## 1. How rules run in the engine (EP1) [H]

1. **Per frame, per ball** (`gravity_and_objects` cs:11A7): the ball slot is copied into a working
   copy (`ball.x/y/vx/vy` = ds:6A30/6A32/6A36/6A34, and the current level `ds:677E`). The writeback flag
   `ds:589A` is cleared and `ball_pixel_scan` (cs:1679) runs. Afterwards the level is copied back.
   If the writeback flag is set, x, y, vx and vy are copied back too (cs:1208).
   Rule code therefore moves or stops a ball by writing the working copy and setting the flag.
   Multiball code writes the slot arrays directly.
2. `ball_pixel_scan` visits all 15x14 pixels under the ball in the collision buffer. Any value above the
   occluder range (> 0xCF at level 0, > 0xC7 at level 1) calls the dispatcher `cs:1E3B` when
   **`sensor_lockout` (ds:676B) is 0 or the value is 0xFE**, and **`sensor_cooldown` (ds:676A) is 0**.
   The lockout is re-read after every call (cs:16E9). A handler that sets the lockout
   therefore stops further dispatches in the same scan, and one that does not may run once
   for every matching pixel. Both counters drop by 1 per frame (cs:09EC, cs:0A02).
3. **Dispatcher filters** (cs:1E3D..1E64): values < 0xAA do nothing. At level 1 only F1, F8 and F9 pass.
   At level 0, while tilted, only F0 and F6 pass. Then it jumps to `cs:[1E77 + 2*(v-0xAA)]`, 86 words for AA..FF.
4. **Entry state of a handler**: `AX = value | (lockout << 8)`. In practice AH = 0, because only 0xFE can
   dispatch during a lockout. `BX` = the handler address, `DI/SI/CX/DX/ES` = scan state. Handlers leave through
   the shared epilogue `popa; pop es; ret` (cs:2FC3). Apart from AL (the colour, which `drop_targets` uses as the
   target index), only one handler reads an entry register: the diverter reset uses AH (see `left_hole`).
5. **Position tests**: several physical sensors share one colour. The handler tells them apart
   with tests on `ball.x`/`ball.y`, which is the ball's **top-left** corner, not its centre (the F6, F8, F9 and FA splits below).

Rule code outside the table: `kicker_hit` (cs:19C1, bumpers and slings), a number of main-loop fragments
(section 3.3) and the end-of-ball code.

## 2. EP1 sensors

Annotated map: `scratch/rules/ep1_sensors.png` (the playfield dimmed; sensor pixels coloured by
handler and labelled; bumper/sling pixels orange; gate0 red; position-test splits dashed).
Each position below is the pixel bounding box of the sensor colour in the collision buffer.

| colour | where (x, y) | handler | what it is | conf |
|---|---|---|---|---|
| F0 | 78-99/62-79, 157-175/109-124, 261-302/117-141 | `ramp_enter` cs:206F | entries of the wire ramps (ball goes to level 1, extra gravity 13 for 13 frames) | H code, M physical |
| F1 | 11 pieces: ramp ends at 90-178/114-151, 253-267/147-207, inlanes 44-54/333 and 250-257/332 | `ramp_exit` cs:2082 | back to level 0; if y >= 200 the ball is stopped (dropped onto the inlane) | H |
| F2 F3 F4 | x=49, y 214-224 / 230-240 / 245-255 | `drop_targets` cs:20BD | bank of 3 targets, index = colour - F2 | H |
| F5 | 7-18/16-19 | `test_hole` cs:21BD | top-left hole: kickout via the centre scoop | H |
| F6, x<220 | 183-195/146-153 | `center_hole` (cs:2384) | centre hole | H |
| F6, x>=220 / F7 | 257-267/208-216 (F7 has no pixels) | `right_sink` cs:24CC | right sink hole | H |
| F8, x>=145 | 246-258/229-239 | `right_hole` (cs:2874) | right hole ("physical systems") | H |
| F8, 50<x<145 | 82-83/268-272 | `diverter_switch` cs:27E6 | switch that toggles the upper-level diverter | H code, M physical |
| F8, x<=50, y<=320 | 7-17/252-254 | `left_hole` cs:2658 | left hole (also on level 1) | H |
| F8, x<=50, y>320 | 29-33/391 | `left_kickback` cs:279B | bottom of the left outlane: kickback | H |
| F9, x<75 | 38/52-61 (level 0 and 1) | `ramps` (cs:2AC2) | left ramp made | H code, M physical |
| F9, x>280 | 300/112-147 | `ramps` (cs:2D55) | right ramp made | H code, M physical |
| FA | 169/31-32, 200/33-34, 230/33-34, 261/41-43 | `top_lanes` cs:1F31 | 4 top rollover lanes (lane from x: <180, <210, <243, else) | H |
| FB | 96-100/26-35 | `left_lane` cs:2EA2 | left lane | H |
| FC | 244/369-370 | `post_debounce` cs:2F3C | lockout 15 only | H |
| FD | 140-156/11-28 | `one_way_gate_left` cs:2F44 | lets the ball pass only when it moves right | H |
| FE | 269-288/20-39 | `one_way_gate_right` cs:2F83 | plunger-lane exit: lets the ball pass only when it moves left; fires during lockout | H |
| CF-D2 | pop bumpers (two discs), slingshots | `kicker_hit` cs:19C1 (hook `kicker`) | bumpers (y<200) and slings | H |
| AA-C7, C8-CF, D0-EF, FF | | no-op / lockout only | C8..CF can never dispatch at level 0 | H |

Note that FD/FE reflect the ball in rule code (`vx = -vx`, `x += 3` / `x -= 3`). They are one-way gates
made from sensor pixels, not walls.

### 2.1 Handler details (all [H] unless marked)
Values are from `rules.json`, where they were read from the EXE. "5 frames after entry" means the countdown timer
reached `hold - 5`.

* **top_lanes (FA)**: lane `i` from ball x. If `i == skill_lane`: `skill_value += 1,000,000`, then the new
  `skill_value` is scored, so the first skill shot pays 2,000,000. After that `skill_lane = 0xFFFF`. A lane already made
  (`top_lanes[i] == 1`) only sets lockout 15. A new lane: sound 0x0C, +50,000. When all 4 are made they reset
  to 2, `bonus_mult` +1 (max 5) with its digit patched into a message string, and +2,000,000. Lamps 2..5 mirror
  `top_lanes` (1 = sprite a = lit art).
* **Lane change** (hook `flipper_lane_change`, cs:102E): on a new press of either flipper the 4 lane states
  rotate left by one, the lamps are re-mirrored, and `lamp[2+skill_lane]` blinks again. The skill lane itself
  does not move.
* **drop_targets (F2-F4)**: new target: lamps 26+i and 29+i = 2, +10,000, sound 1. Bank complete:
  reset, +1,000,000, objective bits `req_ai|=8` and `req_activate|=1`, and a falling-pitch sound
  whose start rate rises with `target_bank_count`. If `phys_armed`: `phys_level+1` (max 7), test
  steps reset, lamp 40+level blinks, and the "shoot right hole" hint is shown.
* **test_hole (F5)**: kickout, 70 frames, eject at (178,150) v=(-65,170), i.e. through the centre scoop.
  On entry: counters, objective bits, lamp 52. 5 frames after entry: in mode 2, double jackpot
  +60,000,000 and the mode ends. Otherwise, if `phys_level == 0`, a hint. Otherwise the award is the dword at
  `ds:0821 + (level-1)*32 + test_step` (5 dwords per level), the test-step lamp 13+step/4 lights, the level's test
  message is shown with its digit patched in (`store` into the message string), and `test_step += 4` (max 16).
* **center_hole (F6, x<220)**: kickout, 50 frames, eject (178,150). 5 frames after entry, if not tilted:
  `power_level+1`, lamp 31+level blinks, +500,000, with a pitch that rises per level. When already at 10, the power
  lamps reset and +10,000,000 is scored.
* **right_sink (F6 x>=220, F7)**: kickout, 80 frames, eject (247,232) v=(-120,90). On entry: objective bits
  (basic io 4, ai 4, ai2 4, database 2), `bonus_ramps+1`, `sink_count_for_gate+1`. The 3rd entry lights lamp 61 and **opens
  gate0**. 5 frames after entry: if `kicker_lit`, `bumper_value += 30,000` and it is displayed. Otherwise +50,000 and one
  of three hint messages (alternating; the third depends on the gate).
* **left_hole (F8 left, y<=320)**: forces level 0. Kickout, 80 frames, shares `center_hole_timer` (ds:0AD5) with
  the centre hole, eject at the centre scoop. 5 frames after entry: millions award, `millions_count` x 1,000,000
  (count 1..9 per ball, digit patched into the message). 25 frames after entry: lamps, and the diverter pixels are
  rewritten with **AH from the handler entry** (0), i.e. cleared.
* **left_kickback (F8 left, y>320)**: `vx=0, vy=-300`, lamp 59 on for 5 frames (`lamp_flash`), lamp 61 off, sound 3,
  **gate0 opens** and `gate_timer = 120`. When the timer runs out (hook `frame_timers`), the gate closes, lamp 61 goes
  off and the sink count resets. [M] for the physical reading: gate0 (24 pixels, x 22-38, y 366-373)
  is a wall (0xEB) across the left outlane above the kickback sensor. When it is open (0x01) the ball can reach the
  kickback, and it stays open 120 frames so the ball can come back up.
* **diverter_switch (F8 middle)**: toggles `diverter_state`, lamps 57/60 = state+1, lockout 20. It rewrites 15
  pixels around (40-47, 200-205) with 0xC0 (a wall on level 1; on level 0 not solid, but inside the B5-CF occluder range, so the ball is drawn under it) or 0x01. [M]: a diverter
  on the left wire ramp. **Game bug [H]**: offset `0x529-0x63A` wraps to 0xFEEF inside the bottom-half
  segment. That is past its 64000 bytes, so the write lands in the graphics data segment (bit-reverse table
  entry 0xE6, object seg +0x4EF). `rules.json` records it as `outside_playfield`.
* **right_hole (F8, x>=145)**: kickout, 50 frames, eject (239,236) v=(-190,90). 5 frames after entry:
  `phys_level==0` gives level 1 and armed (message). Complete gives a message. Armed gives a hint. Otherwise it arms,
  lamp 40+level = 2, shows the body-part message (table ds:06D9), and scores +5,000,000. At levels 3 and 5 it also
  starts **2-ball multiball**: slots 0 and 1 are placed in the plunger lane with vy -400/-380, mode 1, 30 s, lamp 8
  blinks. At level 7 it starts **3-ball multiball** (mode 2, 30 s) and sets `phys_complete`.
* **ramps (F9)**: left ramp: in mode 3, super jackpot +100,000,000 (mode ends). Otherwise the main progression
  `android_level` 0..6. Level 0 shows a hint (+100,000). Level n advances when its objective byte is complete:
  BASIC IO `req_basic_io==7`, AI `req_ai==0x0F`, AI2 `req_ai2==0x1F`, DATABASE `req_database==0x0F`, ACTIVATE
  `req_activate==1`. The awards are 5M, 10M, 20M and 35M. After AI and DATABASE the **virus mode** (mode 4) starts for 10 s. The
  mode timer starts at `mode_frame = -40/-50`, so the first "second" is longer. ACTIVATE starts **super jackpot mode**
  (mode 3, 30 s) and relights lamps. Right ramp: in mode 4 the virus is flushed for +15,000,000. At level 0 the **computer link**
  is made (`android_level=1`, `iq=99`). Otherwise the **I.Q. upgrade** scores `iq x 10,000` and shows I.Q.
  The objective bits come from: left ramp 1, right ramp 2, right sink 4 (and the unused middle branch 4); drop target bank
  (AI 8, ACTIVATE 1); test hole (AI2 8, DATABASE 8); left lane (AI2 0x10); right hole (DATABASE 1); centre hole (DATABASE 4).
* **left_lane (FB)**: `kicker_lit=1` (lamp 7 blinks), `req_ai2|=0x10`. In mode 1: jackpot +15,000,000, mode ends.
  Otherwise a hint.
* **one_way_gate_left/right (FD/FE)**: see the table. Sound 0x11 at a speed-dependent rate (`3000+100*|vx|` up to 12000,
  `6000+100*vx` up to 15000). FE sets `sensor_cooldown` instead of the lockout.

### 2.2 Hooks (rule code outside the jump table) [H]

| hook | code | what |
|---|---|---|
| `kicker` | cs:19C1 | bumper (y<200): lamp 0 (x<203) or 1 flashes 3 frames, scores `bumper_value` (initially 10,000), `iq+1` once linked. Sling: 5,000, lamp 50/51 flashes 5 frames. Sets the physics kick (engine.md) |
| `frame_timers` | cs:06E2..0711 | extra-gravity decay; the kickback gate closes when `gate_timer` hits 0 |
| `frame_counters` | cs:09DC..0A17 | `skill_lane_rng` = frame counter mod 4; lockout/cooldown/kicker-cooldown decrement; calls `mode_timer` once a game is running |
| `mode_timer` | cs:3B6E | `mode_seconds` countdown (60 frames per second, shown as 2 digits with the mode title from table ds:066F). At 0: lamp 8 off, the virus/super-jackpot lamps restored, `mode=0` |
| `flipper_lane_change` | cs:102E..1080 | see top_lanes |
| `lamp_flash` | cs:10D0..10F5 | `lamp_flash_slot` (1-based) returns to state 1 after `lamp_flash_frames` |
| `iq_display` | cs:1134..119F | shows I.Q. when it changed and is >= 100 |
| `drain` | cs:0A31..0A9A | a ball at y >= 399 frees its slot. In mode 1 a drain ends the mode. When all slots are empty a new ball is served at (284,336) |
| `ball_end` | cs:333E..33E4 | power level reset. **No-score rule**: if not tilted and the score is unchanged since the ball started, a message is shown and the same player plays again. Tilt clears the per-ball counters |
| `bonus_count` | cs:35D1 | `bonus_total` = tests x400,000 + centre hole x100,000 + right hole x200,000 + ramps/sink x60,000 + left lane x300,000 (each count capped at 99) |
| `bonus_multiplier_payout` | cs:33E7..340D | adds `bonus_total` once per multiplier step, then `bonus_mult = 1` |
| `next_ball_skill` | cs:358E | remembers the score for the no-score rule, picks `skill_lane` from `skill_lane_rng`, blinks its lamp, plays a rising sound |

Not lifted (display or engine code): the per-player save/restore (cs:3473/353A copies ds:5A6C..5AE0, 116
bytes, to and from per-player areas via table ds:6571; after a restore, lamp states 5/6 become 1/2 so they are redrawn), the
bonus-count screen timing, and attract mode.

**Extra ball**: `ds:5885` is tested at the end of a ball (a "shoot again" path) and cleared, but no instruction sets
it to 1. The extra-ball message string has no code reference either. EP1 therefore has **no extra-ball award** [H that no writer
exists, found by instruction and byte search; M for the conclusion].

### 2.3 State variables (names now in `ep1_symbols.json`)

* **Per player** (the 116-byte block ds:5A6C..5AE0, saved and restored at player change): `score` 5A6D (dword),
  lamp phase 5A71, **62 lamp states 5A72..5AAF** (FF at 5AB0), `iq` 5AB1, objective bytes
  `req_basic_io/ai/ai2/database/activate` 5AB3..5AB7, `skill_value` 5AB8 (dword), `drop_targets` 5ABC[3],
  `target_bank_count` 5AC2, `bonus_mult` 5AC4, `phys_level` 5AC6, `android_level` 5ACC, `phys_armed` 5ACD,
  `bumper_value` 5ACF (dword), `test_step` 5AD3, `kicker_lit` 5AD5, `phys_complete` 5AD6, `top_lanes` 5AD7[4],
  `diverter_state` 5ADD, `kickback_gate_open` 5ADE (gate0 control), `sink_count_for_gate` 5ADF.
* **Per ball / game**: `mode` 588E (0 none, 1 jackpot, 2 double jackpot, 3 super jackpot, 4 virus), `mode_seconds` 5886,
  `mode_frame` 5888, hole timers 0AD4..0AD7, `power_level` 0AD0, bonus counters 03A1..03AB, `skill_lane` 0B2B,
  `skill_lane_rng` 0B2A, `gate_timer` 06D6, `extra_gravity` 06D7, `lamp_flash_slot/frames` 6762/6763,
  `score_at_ball_start` 0B2D.
* **Sound**: `sfx_pending` 0012 is queued and played next frame at 11000 Hz, with a 5-frame gap before another queued id. `sfx_now` 0ADF
  plays at the current `sfx_rate_hz` 0ADC. Three **pitch sweeps**, each a counter byte stepped every frame
  (`rules.json: sound_sweeps`): 0ADE +2000 Hz every 8 frames up to 24000, playing `step_id` (0AE1) each step and
  `end_id` (0AE3) at the end; 0AE6 -1000 Hz every 16 frames down to 3000 (ids 0AE7/0AE9); 0AE5 +500 Hz every 32 frames
  up to 10500 (sound 0x12). The rate goes back to 11000 when a sweep ends.

### 2.4 Lamp slots (EP1, [M] from the code that writes each slot; `rules.json: lamp_slots` adds sprite boxes)

0/1 bumper flashes; 2-5 top lanes; 7 left lane (kicker lit); 8 jackpot mode; 10 physical systems armed; 11/12 activated;
13-17 test steps; 18 computer link; 19/20 virus; 21-25 android levels; 26-28 and 29-31 drop targets (two sprites each);
32-41 power 1-10; 41-47 physical levels 1-7 (**slot 41 is shared** by power 10 and physical level 1, a real overlap in
the code); 48 super jackpot; 50/51 sling flashes; 52 test hole; 53 centre eject; 54/55 right sink and right hole;
57/60 diverter (two lamps); 58 left hole; 59 kickback flash; 61 kickback gate. Lamp state 1 shows sprite "a" and state 2 shows
"b" (sprites.md 3.1). Which of the two is the "lit" art depends on the slot: lamps 2-5 have "b" baked into the playfield, lamps 0/1 have "a".

### 2.5 What is fully understood and what is not

* **Fully understood [H]**: all 20 handler entries and the 4 position sub-branches; the dispatch path, lockout and cooldown;
  kickouts (hold and eject); multiball; modes and timers; the progression bytes; the skill shot; the bonus multiplier and bonus
  count; the no-score rule; gate0; the lamp flash; sounds and sweeps. Every one of them agrees with the original code in the differential test (section 5).
* **Physical meaning inferred [M]**: which ramp or lane a sensor is (from its position and messages); gate0 and
  the diverter as a kickback lane gate and a wire-ramp diverter; lamp slot meanings.
* **Not determined**: message placement parameters (`message.mode`: AH picks the font/centring, AL is stored
  in ds:0B3A and was not traced [M]); what `ds:5890` is; the exact on-screen layout of `text` ops.

---

## 3. The `epic-pinball-rules/1` format

`extracted/tables/EPn/rules.json` (user-owned output, gitignored). The design choice: **rules are lifted
code, not a hand-written rule list**. Each handler is a small control-flow graph whose ops are semantic
where the lifter recognised an idiom (score, lamp, sound, ball set, kickout, layer, gate, message) and generic
where it did not (named-variable updates, register temporaries). The generic ops keep the lift exact. An
app implements a ~300-line interpreter (like `scratch/rules/verify_ir.py`, class `IR`) and hooks the semantic ops
to rendering and audio.

### 3.1 Top level

| key | content |
|---|---|
| `schema`, `table`, `exe`, `annotated` | identity; `annotated` = names and descriptions present (EP1 only) |
| `source` | code/data segment, dispatcher ip, sensor jump table |
| `memory` | `data_segment_file_offset`/`size`: **the app reads this byte range from the user's `EPn.EXE` as the initial state**. All `var`/`mem` addresses are 16-bit offsets into it. Offsets past `size` (only reached with out-of-range counters) are, in the original, the first bytes of the playfield image that follows DS in the same 64 KB window. `player_block` (start/end) is saved and restored per player. `lamps`: `first` slot byte, `count`, `phase` byte, state meanings, other lamp tables (attract), EP2's light-show pointer table |
| `lamp_slots` | per slot: sprite a/b boxes and `playfield_match` (from `sprites.json`); EP1 `name` |
| `engine_vars` | roles the engine owns: `score`, `ball.x/y/vx/vy` (working copy), `ball.writeback`, `ball.layer`, `ball_slots.*` (5 slots, stride 2), `sensor_lockout`, `sensor_cooldown`, `tilted`, `kick_strength`, `kicker_cooldown`, `extra_gravity`, `sound.queue/rate/now`, `sound.sweep@XXXX[.step_id/.end_id]`, `gateN.open` |
| `vars` | every DS address the lifted code touches directly: `addr`, `size`, `init` (from the EXE), `scope` (player/game), `role`, and for EP1 `desc`/`conf`. Unnamed ones are `vXXXX`; the high word of a dword is `name.hi` |
| `messages` | string references by DS offset: `ds`, `file_offset`, `length`, `printable`. **No text**: the app reads the bytes from its live DS copy, because rules patch digits into strings (see `store`) |
| `message_tables` | DS word tables of string pointers indexed by rule code |
| `gates` | runtime collision edits done by a routine: `pixels` [[x,y]], `control_var`, value when the control is 0 / non-zero |
| `sound_sweeps` | per sweep counter: `every_frames_mask`, `phase`, `rate_step`, `rate_limit`, `ids` (played each step / at end) |
| `stub_routines` | display-only routines called from rule code (message/text/number/refresh), near or far. Exception: EP1 `0x3af8` (`display:idle_text`, hand-classified) also does `if tilted == 1: mode = 0` (cs:3B16..3B1D). Inside the lifted hooks it is only called from `next_ball_skill`, where `tilted` is always 0, but the main loop calls it when a message times out (cs:0A2E), so an app must reproduce that write |
| `sensors` | list of `{colour, value, level, handler, fires_when_tilted, ignores_lockout, regions:[{bbox, pixels, branch, branch_name}]}`. `branch` = the first block reached after the handler's position tests for a ball centred on that region |
| `handlers` | `hXXXX` -> `{entry, colours, summary, op_counts, kickouts, name, desc, conf, tags}` |
| `hooks` | `kicker`, `dispatch_tail` (EP2/EP10), and the EP1 main-loop fragments: `{entry, stops, desc, summary}` |
| `blocks` | `Lxxxx` -> `{ip, ops:[...], end}`. Shared between handlers, hooks and gosubs |
| `coverage` | op counts: semantic / state updates / low-level / unexpressed |

### 3.2 Expressions

JSON values: an integer, or a list `[op, args...]`:

* `["var", name, w]` reads w bytes of a named variable. `["mem", w, addrExpr]` is a raw DS read (indexed tables).
  `["ball", "x"|"y"|"vx"|"vy"]` is the working copy. `["ball_slot", n, field]`. `["lamp", slotExpr]`.
  `["reg", r]` is a register or temporary (`ax bx cx dx si di bp`, and `fa fb cf t_*`).
  `["input", "flipper_left"|"flipper_right"]` (EP1 keyboard flags). `["contact_colour"]` is the pixel the kicker probe hit (EP2).
  `["cmem", w, a]` reads the code segment. `["unknown", ip]` is a value clobbered by a display call. Assigning it is
  allowed, but reading it is an error that never happens on a feasible path (see 5).
* Arithmetic: `add sub mul and or xor shl shr sar neg lo hi setlo sethi join lo16 hi16 mul32 div32 mod32 div mod
  sext8 ltu`. Evaluate on mathematical integers and **truncate at stores, conditions, memory addresses, and in
  `lo/hi/shr/div/join/setlo/sethi/shl/neg`**. This reproduces 16-bit two's-complement behaviour. `join(hi,lo)`
  builds a dword. `ltu(a,b,w)` is 1 if a < b unsigned (the carry of an add).

### 3.3 Ops

| op | fields | effect |
|---|---|---|
| `score` | `add` | 32-bit add to `score` (the display refresh is separate) |
| `lamp` | `slot`, `state` | `lamps.first[slot] = state` (states 1-6, sprites.md) |
| `lamps` | `slot`, `count:2`, `states16` | word store over two slots (the lamp mirror copies) |
| `ball` | `set:{x,y,vx,vy}` | write the working copy. Takes effect only with `ball_commit` (the writeback flag) |
| `ball_commit` | `val` | writeback flag |
| `ball_slot` | `slot`, `set:{x,y,vx,vy,active,layer}` | direct slot write (multiball, serve) |
| `layer` | `val` | the current ball's level (0 table, 1 ramps) |
| `extra_gravity` | `frames` | extra gravity term, decays 1 per frame (engine.md) |
| `lockout` / `cooldown` | `frames` | sensor lockout / cooldown counters |
| `sound` | `id` | queue a sound (next frame, 11000 Hz) |
| `sound_now` | `id` | play next frame at the current `sound_rate` |
| `sound_rate` | `hz` | set the rate for sound_now and sweeps |
| `sound_sweep_start` | `sweep`, `active`, `step_id`, `end_id` | start (active=1) or stop a sweep (`sound_sweeps`) |
| `sound_play` | `id` | direct play (not used by EP1 rules) |
| `message` | `msg`, `pos{x,y,raw}`, `mode` | dot-matrix message: `msg` = DS string offset; `mode` AH = font/centring (3+ = not centred), AL = effect [M] |
| `text` | `msg`, `pos`, `routine` | score-strip text (two routines, normal/highlight) |
| `number_text` | `value`, `buf` | format dword `value` as decimal into DS buffer `buf` (10 chars, space padded). **The app must write the digits** because later `text` ops print the buffer |
| `score_refresh`, `display` | | redraw hints |
| `pixels` | `val`, `xy` / `outside_playfield` | collision-buffer writes (diverters). `val` may depend on registers |
| `gate` | `gate` | redraw a gate from its control variable |
| `set` | `var`, `w`, `val` | named variable update |
| `store` | `w`, `addr`, `val` | indexed DS store (arrays, patched message digits) |
| `reg` | `r`, `val` | register or temporary assignment |
| `push`/`pop`/`push_all`/`pop_all` | | a per-invocation stack (discarded on return) |
| `gosub` | `entry` | run another block graph until `return`, then continue. It may leave `cf` set |
| `call_hook` | `hook` | run a hook |
| `asm` / `call` | `ip`, `text` / `target` | not liftable (none in EP1, EP2 or EP10) |

`end` of a block: `{"goto": L}`, `{"if": {"cmp", "a", "b", "w"}, "then": L, "else": L}` with `cmp` in `eq ne ult ule ugt uge slt sle
sgt sge` compared at width `w`, or `{"return": true}`. `L` may be `@return`. Conditions are evaluated **after** all ops of
the block. The lifter captures values into `fa`/`fb` when a later op would change them.

### 3.4 Derived annotations (read-only conveniences)

* `handlers[h].kickouts`: `{timer, hold_frames, eject:{x,y,vx,vy}, timer_values_with_actions}`, found as "countdown var
  + a block with vx=vy=0 + a block placing the ball". It is informative only; the block graph is authoritative.
* `summary`: scores, lamps, sounds, messages, writes, ball sets, conditions per handler. `regions[].branch_name`.

### 3.5 What the app has to provide (engine side)
Load DS from the EXE, then per frame and ball: copy the slot to `ball.*`, clear `ball.writeback`, scan pixels exactly as in section 1
(lockout/cooldown rules, dispatcher filters by level and tilt, entry `ax = value`, `bx = handler ip`), run the handler, write
back. Call the `kicker` hook on active-surface contact. EP1 hooks: run `frame_timers`, `frame_counters`,
`flipper_lane_change`, `lamp_flash`, `iq_display` every frame, `drain` on drain, and `ball_end` / `bonus_count` /
`bonus_multiplier_payout` / `next_ball_skill` at the end of a ball. Implement the sound queue and sweeps from
`sound_sweeps`, lamp drawing from the lamp bytes, and messages from the live DS bytes.

Entry registers (checked with a def-use pass over the graphs, `scratch/verify-rules/entry_regs.py`): sensor handlers read
only `ax` (EP1 h20bd/h2869/h2658/h279b/h27e6, EP2 h20d5/h2bba). The `kicker` hook reads `di` = **2 x ball slot index**
(it addresses `ball_slots.*` as `mem[di + base]`) in EP1, EP2 and EP10, and EP2's kicker reads the contact pixel through
`contact_colour`. `flipper_lane_change` (EP1) and EP2 `kicker` read a register only through `setlo($r, ...)`, whose high byte is
never used, so the interpreter only needs *some* defined value there: start every invocation with all registers set to 0.

---

## 4. Generic pass on EP2 and EP10 (same engine family, no annotations)

`tools/rules.py 2 10` finds the engine variables by code patterns: score (add/adc pairs), ball working copy and writeback,
lamp table (the `lamp_update` caller inside the player block), player block, sound queue/rate/now/sweeps, tilt, lockout,
cooldown, kicker, gates, and the dispatcher tail. Results:

| | EP1 | EP2 | EP10 |
|---|---|---|---|
| handlers / hooks / blocks | 20 / 12 / 303 | 10 / 2 / 293 | 12 / 2 / 172 |
| ops: semantic / state / low-level / unexpressed | 348 / 221 / 168 / 0 | 280 / 217 / 83 / 0 | 274 / 128 / 81 / 0 |
| named variables | 69 of 101 | 5 of 66 | 3 of 57 |
| differential test (handlers+hooks, 300 trials each) | 0 failures | 0 failures | 4 failures, all out-of-range state (item 5); 0 with `FULLSEG=1` |

What the lift found in them [H for the code, M for any physical meaning]:
* **EP2**: kickout back to the plunger lane (B1: hold 70, eject (284,338) v=0); level changes on D1/D2/B1/D0; score values from
  DS tables (`ds:084E + 4*n`); per-player lamp tables inside the player block (lamps at ds:530A, 60 slots); three pitch sweeps.
  The null handler and the dispatcher's non-dispatch exit both jump to **shared rule code at cs:3045 (`dispatch_tail`)**,
  a progression check that runs on every dispatcher call. **Game bug**: cs:2185/2197/21A9/21B4/2DEB/2DFD/2E08/2E1A/2E25 (nine sites; every `adc` aimed at this dword) do `add [535E],lo; adc [535E],hi`.
  The high half goes into the low word again, so these value increments lose their high word. It is lifted faithfully with `ltu`.
* **EP10**: 3 kickouts (hold 90), a ball lock (L23ED: the ball is re-served in the plunger lane and slots 1/2 are cleared, lock count `v35d0`) and a 3-ball multiball after the second lock (L2444) via slot writes [M for the reading], 4 pitch sweeps, and a dispatcher tail at cs:2BAF (a
  6-target bank bitmask check). Rule **subroutines** (cs:2C6D returns its result in the carry flag, `stc`/`clc`; cs:2CF1 advances
  a 10-step lamp ladder) are lifted as `gosub` + `cf`.

**What the schema could not express, or expresses only generically:**
1. **Main-loop rule fragments are not found automatically.** For EP1 they are listed by hand (`EP1_HOOKS`: entry and stop
   addresses). EP2 and EP10 get only `kicker` and `dispatch_tail`. Their timers, lane change, drain, end of ball, bonus and
   light-show code are missing until someone annotates them. This is the main gap.
2. **Unnamed state.** Without annotations, 95% of EP2/EP10 variables are `vXXXX`. The graphs are exact but opaque (for example
   progression bytes, mode numbers and lamp meanings).
3. **Dispatcher-tail rules** (EP2, EP10) run after every sensor event, even for colours without a handler and while
   tilted. They are a hook, not a sensor action. The app must call `dispatch_tail` on every dispatcher call.
4. **Engine-coupled conditions live outside the rules**: EP2's conditional active surface (collision.md: CF-D0 only when
   `[5560]==0` inside an x/y window) sits in the collision loop. The kicker hook reads `contact_colour`. EP8's runtime
   wall threshold is also outside.
5. **Out-of-range memory**: EP1's diverter pixel past the playfield half, and EP10 cs:27FC reading `ds:049F + 4*(n-1)` with a
   counter that only stays in 1..5 in normal play. With a counter outside its normal range the original reads past `data_segment_size` into the playfield bytes.
   The EP10 differential failures (4 of 4200 trials, all in h2759) are this case, with random counter values the game should
   never reach. They disappear when the interpreter models the full 64 KB window (`FULLSEG=1`).
6. **Light shows / animations** (EP2 `show_table_pointers`, the spinner, EP10's eye) are main-loop display code, not rules.
7. Flag-dependent branches the lifter cannot model produce `["flags"]` conditions. None occur in the three tables. `jb/jae` after
   `inc/dec` (CF unchanged) would hit this.

## 5. Verification

`scratch/rules/verify_ir.py N trials` builds a random DS state for each handler and hook. It starts from the EXE's initial DS,
randomises the rule variables towards the constants the handler compares against, puts the ball inside the sensor's regions,
and uses random registers. It then runs (a) the JSON IR interpreter and (b) Unicorn on the **original code** from the handler
entry, with the dispatcher's stack frame. Only the display routines are stubbed. The resulting DS bytes, collision-buffer bytes and
display calls (message/text/number/refresh) are compared.

* EP1, 300 trials each: all 20 handlers and 12 hooks agree (0 failures). `bonus_multiplier_payout` skips some trials where a
  random multiplier near 65535 exceeds the interpreter's step limit.
* EP2, 300 trials: 0 failures. EP10, 300 trials: 4 failures in h2759 (item 5 in section 4), and 0 with `FULLSEG=1`. Some EP10 trials read an `unknown` register
  (after a display call), and only for states where the original code would also use a clobbered register.

**Coverage of the random test (verifier, 2026-09-27).** At 300 trials per target, 42 of EP1's 303 blocks are never executed by
any target (74 of 402 per-target reachable blocks). They include the drop-target bank completion and physical-level advance
(L20EC..L2185), the whole right-hole award including both multiballs (L28F3..L2AB5), the android-level advances (L2B9E, L2C4B,
L2C87, L2CDF), the kicker-lit right-sink award (L25AE), mode expiry (L3BE9..L3C0B) and the drain slot-free path (L0A46..L0A77),
because the random states rarely hit the exact timer and level values. `scratch/verify-rules/directed.py` builds those states on
purpose (451 cases x 3 trials: every android level with its objective full/empty, every phys level at the right-hole award,
bank completion armed/unarmed, all modes on both ramps, mode expiry for every mode, drain masks). It found **0 mismatches**
and covers 49 of the 50 missing blocks. The one left, L2017 (clamping `bonus_mult` above 5 after the increment), is dead code.
With 20,000 random trials and `FULLSEG=1`, EP1 h21bd and h2869 show 1-byte collision-buffer differences. These are the same
out-of-range class: a random `test_step`/`phys_level` makes an indexed store land past `data_segment_size`, which in the
original aliases the playfield, but `FULLSEG` models that tail as a separate copy. Stubbed display calls are compared by
`bx`/`di` (and, in the verifier's copy, the message `ax` mode). The digits `number_text` writes and the `outside_playfield`
write are not compared. EP2 and EP10 have the same gap: at 300 trials 58 of 293 (EP2) and 42 of 172 (EP10) blocks are never executed,
and at 5,000 trials 49 and 16 still are. EP2's `kicker` body is only reached when slot 0's layer byte is 0 and the table is not tilted,
which the random state almost never sets. It agrees with the original when forced (`KLAYER0=1` in the verifier's copy). EP2/EP10
have not had a directed test.

Caveats: this checks the lift against the code, not the code against the running game. Random states can be unreachable ones.
Display calls are compared by arguments only.

## 6. Open items

* Annotate EP2-EP13 hooks (main-loop fragments) and names; a pattern search for the EP1 hook shapes (timer decrement blocks,
  flipper-press latch, drain loop) would find most of them.
* Trace `message.mode` (the effect byte, ds:0B3A) and the text-routine positions to place messages exactly.
* Runtime check in DOSBox-X: break on cs:1E6A (dispatch) and cs:19C1 (kicker) and compare with `verify_ir.py` traces.
* EP8's layered toys (lamp overlays switched by rules) need its rules lifted to decide what is solid when.
