# Table rules: EP1 decode and the `epic-pinball-rules/1` format

Status: EP1's sensor handlers and the rule fragments in its main loop are decoded and
lifted to JSON by `tools/rules.py`, with names and descriptions. **All 13 tables** go through
the same lifter; for EP2-EP13 the main-loop and end-of-ball rule fragments (hooks) are found
automatically by pattern (section 4.1). A differential test (`tools/emu/verify_rules.py`,
section 5) runs every lifted handler and hook against the original machine code in an emulator:
**0 failures on all 13 tables**. Everything here is static analysis plus emulation of isolated
routines with Unicorn. The game itself has not been run in DOSBox-X for rules.

**The Swift port runs these rules** (`app/Sources/PinballCore/Rules/`, section 7): rules.json is interpreted against the
live data segment read from the user's EXE, and the unlifted pieces (EP1's annotated main-loop fragments, the `call`/`asm`
ops, EP10's two physics-side fragments) are executed from the EXE bytes by a small x86 interpreter (`MiniX86`). Against the
original code in the emulator harness, rules mode is exact on all 13 tables' scenario sets (emulation.md section 12), and for
EP1 the whole data segment outside display buffers plus every sfx_play / dmd_message call is identical after every frame.

Confidence tags: **[H]** read from code and confirmed by the differential test,
**[M]** read from code, meaning inferred (for example what a sensor is physically),
**[L]** guess.

Addresses: `cs:XXXX` is EP1 code segment 0x3223 (file `0x32630+XXXX`) and `ds:XXXX`
is EP1 data segment 0x0015 (file `0x550+XXXX`), as in engine.md.

```
.venv/bin/python tools/rules.py 1 2 3 4 5 6 7 8 9 10 11 12 13 --report   # -> extracted/tables/EPn/rules.json
.venv/bin/python tools/rules.py 1 --no-write --dump h2379 # one handler as readable text ("all" for everything)
.venv/bin/python tools/rules.py 1 --hooks-check            # automatic hook discovery (EP1: compared with EP1_HOOKS)
.venv/bin/python tools/rules.py 2 10 --no-auto-hooks       # the output before automatic hooks (kicker/dispatch_tail only)
.venv/bin/python tools/emu/verify_rules.py --all [--trials 300] [--json OUT]   # lift vs original code, every table
.venv/bin/python scratch/rules/verify_ir.py 1 300          # the original EP1/EP2/EP10 verifier (superseded)
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

Also run by the port from the EXE, not lifted (app/Sources/PinballCore/Rules/TableGlue.swift lists every range): the
flipper_update sound fragments cs:3D1F..3D2B / cs:3DBD..3DC9 (a flipper leaving rest queues its sound with a left/right
pan and clears the queue delay), the sound block cs:0898..09DC, the serve/release/tilt side effects, dmd_idle_text and the
end-of-turn player switch. `sound_sweeps[0]` (ds:0AE5, +500 Hz every 32 frames) lists empty `step_id`/`end_id` although
it plays sound 0x12 (the id is loaded inside the sound block, not by the sweep's own code); the port runs the real code, so
this is only a schema gap.

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
| `hooks` | `kicker`, `dispatch_tail` (EP2, EP3, EP4, EP7, EP8, EP10), the EP1 main-loop fragments (hand annotation) and, for EP2-EP13, the automatic ones (section 4.1): `{entry, stops, desc, conf, summary}`. Automatic hooks (`conf: "auto"`) add `kind` (`frame_timers`, `frame_counters`, `drain`, `flipper_press`, `lamp_timer`, `main`, `ball_end`), `when` (`every_frame`: run in main-loop order once per frame; `ball_end`: from the end-of-ball routine) and, for `ball_end` hooks, `continues` (`{cut ip: next hook}`: where the original resumes after the display call that ends the hook) |
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
  `lo/hi/shr/div/join/setlo/sethi/shl/neg`**. This reproduces 16-bit two's-complement behaviour.
  **Shift counts are taken mod 32** (`shl/shr/sar`), as on the 80186 and later: EP9 cs:2e07 shifts by a
  counter that can exceed 31, where `1 << 33` is 2, not 0 [H, differential test]. No EP1/EP2/EP10 code reaches a count above 15. `join(hi,lo)`
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
| `text` | `msg`, `pos`, `routine` | a text line appended to the active dot message: draw_text (EP1 cs:59AC, font5) and draw_text_hi (cs:5926, font8) check and advance the message's line pointer [0x50C]. Not score-strip text (runtime-confirmed with DOSBox-X captures) |
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
| `asm` / `call` | `ip`, `text` / `target` | not liftable (none in EP1, EP2 or EP10; EP6, EP8, EP9 have a few, section 4.4 item 8). The Swift port executes the target (or, for a graph with `asm`, the whole handler) from the EXE |

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
`bonus_multiplier_payout` / `next_ball_skill` at the end of a ball. EP2-EP13: run the `when: "every_frame"` hooks once per frame
in `entry` order (main-loop order), and at the end of a ball the `ball_end` hooks from the first one, following `continues`
after each stop (a stop without a `continues` entry ends the sequence; the regions in between are display code).
Implement the sound queue and sweeps from `sound_sweeps`, lamp drawing from the lamp bytes, and messages from the live DS bytes.

Entry registers (checked with a def-use pass over the graphs, `scratch/verify-rules/entry_regs.py`): sensor handlers read
only `ax` (EP1 h20bd/h2869/h2658/h279b/h27e6, EP2 h20d5/h2bba). The `kicker` hook reads `di` = **2 x ball slot index**
(it addresses `ball_slots.*` as `mem[di + base]`) in EP1, EP2 and EP10, and EP2's kicker reads the contact pixel through
`contact_colour`. `flipper_lane_change` (EP1) and EP2 `kicker` read a register only through `setlo($r, ...)`, whose high byte is
never used, so the interpreter only needs *some* defined value there: start every invocation with all registers set to 0.

---

## 4. All tables (same engine family; names only for EP1)

`tools/rules.py N` finds the engine variables by code patterns: score (add/adc pairs), ball working copy and writeback,
lamp table (the `lamp_update` caller inside the player block), player block, sound queue/rate/now/sweeps, tilt, lockout,
cooldown, kicker, gates, and the dispatcher tail. The ball slot arrays, the keyboard flags (`["input", ...]`) and the main-loop
layout come from the emulator harness's per-table search (`tools/emu/discover.py`, emulation.md section 10), because EP3,
EP5 and EP6 lay the slot arrays out differently from EP1. Results (300 random trials per target plus the directed phase):

| table | handlers | hooks | blocks | ops semantic / state / low-level / unexpressed | named vars (roles) | differential test: equal / compared, failures | blocks executed |
|---|---|---|---|---|---|---|---|
| EP1 | 20 | 12 (EP1_HOOKS, hand) | 303 | 348 / 221 / 168 / 0 | 69 of 101 | 9660 / 9675, 0 | 293 / 303 |
| EP2 | 10 | 17: kicker, dispatch_tail, 10 main-loop, 5 end-of-ball | 491 | 339 / 343 / 261 / 0 | 6 of 120 | 8299 / 8376, 0 | 460 / 491 |
| EP3 | 19 | 10: kicker, dispatch_tail, 5 + 3 | 175 | 168 / 93 / 78 / 0 | 5 of 56 | 8671 / 8727, 0 | 175 / 175 |
| EP4 | 12 | 13: kicker, dispatch_tail, 7 + 4 | 325 | 281 / 237 / 255 / 0 | 7 of 103 | 7472 / 7551, 0 | 291 / 325 |
| EP5 | 14 | 7: kicker, 3 + 3 | 106 | 105 / 49 / 68 / 0 | 5 of 32 | 6249 / 6300, 0 | 103 / 106 |
| EP6 | 17 | 10: kicker, 4 + 5 | 270 | 275 / 183 / 165 / 1 | 5 of 81 | 8109 / 8127, 0 | 268 / 270 |
| EP7 | 13 | 14: kicker, dispatch_tail, 7 + 5 | 385 | 325 / 288 / 250 / 0 | 7 of 120 | 8148 / 8208, 0 | 369 / 385 |
| EP8 | 18 | 16: kicker, dispatch_tail, 10 + 4 | 325 | 458 / 181 / 119 / 3 | 6 of 85 | 10095 / 10242, 0 | 309 / 325 |
| EP9 | 16 | 19: kicker, 14 + 4 | 348 | 148 / 255 / 298 / 22 | 4 of 164 | 10069 / 10527, 0 | 305 / 348 |
| EP10 | 12 | 15: kicker, dispatch_tail, 9 + 4 | 370 | 311 / 242 / 302 / 0 | 5 of 111 | 8157 / 8208, 0 | 326 / 370 |
| EP11 | 15 | 15: kicker, 11 + 3 | 391 | 317 / 211 / 282 / 0 | 5 of 117 | 9030 / 9045, 0 | 358 / 391 |
| EP12 | 19 | 17: kicker, 13 + 3 | 431 | 335 / 251 / 345 / 0 | 5 of 130 | 10617 / 10839, 0 | 395 / 431 |
| EP13 | 20 | 16: kicker, 12 + 3 | 374 | 273 / 217 / 293 / 0 | 5 of 115 | 10802 / 10833, 0 | 343 / 374 |

"compared" counts every random and directed trial. The ones not "equal" are `undefined` (the IR reads a register that a stubbed
display call clobbers; the original's result then depends on the display routine, which the test does not model) or `skipped`
(an op the IR cannot run, the interpreter's step limit, or the original not returning, as in section 4.4 item 8). None is a mismatch. EP1's `rules.json` is byte-identical to the
earlier output, and EP2/EP10 are byte-identical with `--no-auto-hooks`.

### 4.1 Main-loop hook discovery by pattern [H for EP1's six fragments, M for the others]

`auto_hooks()` in `tools/rules.py` replaces the EP1-only hand annotation for EP2-EP13; `EP1_HOOKS` stays as EP1's override.

1. **Main loop** (`main_loop`..`frame_sync` from discover.py). It is split into *statements*: an instruction boundary that no
   branch crosses (a branch may land on it) and that does not separate a flag setter from its jcc. Jumps back to the main-loop
   head ("restart the frame", EP10 cs:0bb9) are treated as exits. Each statement is therefore single-entry and single-exit.
2. The engine's own ball fragments are excluded (plunger lane/launch, nudge/tilt, gravity plus object scan). The per-frame counters
   and the drain loop stay as candidates: they are rule code too (EP1 `frame_counters`, `drain`).
3. A statement is kept if it **lifts completely**. That means only rule-like near calls (gosub) and the display, sound and gate
   routines the lifter stubs; no port I/O, interrupts, string ops, far calls into the graphics library or indirect jumps.
   It must also **write rule state**. Rule state is a DS address the sensor handlers or the kicker read or write, the lamp
   table, the score, or an engine role other than the ball and sound. It grows to a fixpoint: a statement is rule code if it
   writes something that rule code reads. Writes that touch only sound/sweep variables or the ball slot arrays do not count.
4. Adjacent kept statements are merged, with the register set-up statements between them. Statements of more than 12
   instructions form their own hook. A counters or drain fragment is always one hook.
5. **End of ball**: `ball_lost_fade` (discover.py) is cut into *regions*. Control flow is followed from the routine entry and
   cut at every instruction the lifter cannot express (fades, waits, graphics calls); the instruction after a cut starts the
   next region. Regions that write rule state and do not pop values pushed before their start become `ball_end_XXXX` hooks,
   with `continues` giving the next region after each cut.
6. After lifting, any automatic hook with an unexpressed op is dropped and the table is lifted again (EP5 cs:1f4a).

**Check on EP1** (`--hooks-check`): the automatic run finds all six EP1 main-loop fragments of `EP1_HOOKS` with the same entry
and stop: `frame_timers` 06E2..0711, `frame_counters` 09DC..0A17, `drain` 0A31..0A9A, `flipper_lane_change` 102E..1080,
`lamp_flash` 10D0..10F5, `iq_display` 1134..119F. It also finds two display-side fragments the annotation leaves out: 04D2..06E2
(the attract/high-score text cycle, which writes the number buffer ds:5875) and 111E..1134 (a score redraw request, flag
ds:06D5). `mode_timer` and `bonus_count` are included as gosubs. The end-of-ball annotation (`ball_end` 333E..33E4,
`bonus_multiplier_payout` 33E7..340D, `next_ball_skill` 358E) is covered by regions with other boundaries: 3320 (through
bonus count and payout, cut at the display calls 3436 and 358E) and 3593 (`next_ball_skill` after its first display call).
So the end-of-ball split is **not** reproduced exactly. The code is covered, but at different cut points.

`kind` is a shape label only: `frame_timers` (contains the extra-gravity decay), `frame_counters` (decrements the sensor lockout
or another per-frame counter from discover.py), `drain` (compares a ball y with the drain line), `flipper_press` (reads a
flipper key flag), `lamp_timer` (a countdown that writes lamp slots), `main` (anything else), `ball_end`.

### 4.2 Lifter changes made for the other tables (EP1 output unchanged)

* `sbb` after a register `sub` (32-bit subtract in a register pair, EP9-13 number formatting), and `shl lo,1; rcl hi,1`
  (32-bit shift, EP4 cs:2911 and EP7 cs:1a7b): lifted with `ltu` / the shifted-out bit.
* **Flags across a join** (EP8 kicker cs:1b18): when every block that can supply the flags of a jcc ends with a compare of the
  same width, those blocks copy their operands to `fa`/`fb` and the join tests `cmp(fa, fb)`.
* **Dead-register elimination across gosubs**: a `gosub` now reads the registers its callee reads before writing them. The old
  pass deleted `mov si,0Fh` before EP3 `call 2D1Ch` (a delay loop counted by SI). The verifier found this; EP1, EP2 and EP10
  have no such case, so their output did not change.
* Display routines that switch DS to a constant segment before any write (EP4 cs:c5cb, EP6 cs:41a0, EP8 cs:a42f) are stubbed
  like the message and text routines (`display` op). This is not applied to EP1.
* A hook may start where another hook stops (adjacent automatic hooks). Only control flow *reaching* a stop from elsewhere
  returns there.

### 4.3 Findings per table (unannotated) [H for the code, M for any physical meaning]

* **EP2**: kickout back to the plunger lane (B1: hold 70, eject (284,338) v=0); level changes on D1/D2/B1/D0; score values from
  DS tables (`ds:084E + 4*n`); per-player lamp tables inside the player block (lamps at ds:530A, 60 slots); three pitch sweeps.
  The null handler and the dispatcher's non-dispatch exit both jump to **shared rule code at cs:3045 (`dispatch_tail`)**,
  a progression check that runs on every dispatcher call. **Game bug**: cs:2185/2197/21A9/21B4/2DEB/2DFD/2E08/2E1A/2E25 (nine sites; every `adc` aimed at this dword) do `add [535E],lo; adc [535E],hi`.
  The high half goes into the low word again, so these value increments lose their high word. It is lifted faithfully with `ltu`.
* **EP10**: 3 kickouts (hold 90), a ball lock (L23ED: the ball is re-served in the plunger lane and slots 1/2 are cleared, lock count `v35d0`) and a 3-ball multiball after the second lock (L2444) via slot writes [M for the reading], 4 pitch sweeps, and a dispatcher tail at cs:2BAF (a
  6-target bank bitmask check). Rule **subroutines** (cs:2C6D returns its result in the carry flag, `stc`/`clc`; cs:2CF1 advances
  a 10-step lamp ladder) are lifted as `gosub` + `cf`.

* **EP10 main-loop fragments outside the harness's physics ranges** (run by the port as TableGlue `preFrame` /
  `postTimers`): cs:053E..0566 steers ball 0 near the top (when -5 < vy < 5 and y < 200: vx += 2, then vx -= 4 if x >= 145, so a net -2 on the right);
  cs:0571..05D2 is the top gate: cs:4313 draws the pixel list at ds:062C closed or open according to ds:062B, with ds:00C2
  and the ds:046C/046B countdown.
* **EP6 / EP9 ball-position gates** (physics, emulation.md section 10): EP6 cs:0979..0990 closes a one-way gate (32 pixels at
  ds:6BCC, value 0xEC, via cs:3BD4) once ball 0 has x <= 0xE6; only ball_lost_fade reopens it. EP9 cs:0550..0577 opens or
  closes 14 pixels at ds:04FE (0xFA or 0xC0, via cs:4091) by ball 0's x. EP9's rule timer cs:058B..05C2 ([3F1E], set to 120
  by cs:241A) swaps the bottom-half lists ds:051C/053E between 0xFA and 0x01. engine.json `gates` and TableGlue `ruleTimers`.
* **EP8 rule-driven main-loop code** (TableGlue `ruleTimers` / `preGravity`): the magnet cs:05D4 (while [0454]==1 ball 0
  within 60 px of ([0456],[0458]) is pulled by d*[0460]/max(d.d,20)), the ball transport and level switch cs:06B2..0843
  ([04A4]/[04A3]/[04AA], wall threshold [04A7] EB/FF, scan bounds [04A6]/[04A9]) and the lamp-driven toy shapes cs:1095..10A9
  (cs:429E draws or clears each lamp's collision shape). **Palette ring** [H]: cs:1281, called once per main-loop frame
  (cs:0843) and from the frame wait cs:0240, counts [04A5] up to the speed byte [5D0C] (4 at boot; 3/1/2 set by handlers
  cs:2329/262B/2AF4), then writes palette entries 0xA0..0xDF from the working palette ds:5138 (6-bit) and rotates those 64
  colours by one. cs:3613 reloads the ring from one of four colour sets (table ds:525C, by [5D07]) at level changes and ball
  end. DOSBox-X captures (frames 240 and 600) match a pure rotation of base >> 2 on 54 of 64 indices (the rest are covered);
  later frames show a reloaded set. The port emits the ring as `PresentationState.paletteOverrides` (PaletteCycle.swift).
  [M]: the ring's rotation phase after the intro is not reproduced (the original rotates it during its intro fade).
* **All tables**: the hook discovery finds a `frame_counters` hook in all 12. It finds a `drain` hook in EP2, EP4, EP7, EP8 and
  EP10-13; in EP3, EP5, EP6 and EP9 the drain fragment writes nothing that counts as rule state, so there is no drain hook. It
  finds an extra-gravity `frame_timers` hook in EP9-13 (the tables with an extra-gravity term) and a `flipper_press` hook (EP1's
  lane-change shape) in EP2, EP3, EP6, EP7, EP9, EP11, EP12 and EP13.

### 4.4 What the schema could not express, or expresses only generically
1. **Main-loop rule fragments are found by pattern, not understood.** Section 4.1 finds them for EP2-EP13 and names them only by
   shape (`frame_counters`, `drain`, `flipper_press`, `main`, ...). What a `main_XXXX` hook means (a light show, a mode timer, an
   attract-mode text cycle) is not known. Some automatic hooks are display-side code that happens to write rule state; they lift
   and verify, so running them is harmless, but they are not all rules.
2. **Unnamed state.** Without annotations, 95% of the EP2-EP13 variables are `vXXXX`. The graphs are exact but opaque (for example
   progression bytes, mode numbers and lamp meanings).
3. **Dispatcher-tail rules** (EP2, EP3, EP4, EP7, EP8, EP10) run after every sensor event, even for colours without a handler and while
   tilted. They are a hook, not a sensor action. The app must call `dispatch_tail` on every dispatcher call.
4. **Engine-coupled conditions live outside the rules**: EP2's conditional active surface (collision.md: CF-D0 only when
   `[5560]==0` inside an x/y window) sits in the collision loop. The kicker hook reads `contact_colour`. EP8's runtime
   wall threshold is also outside.
5. **Out-of-range memory**: EP1's diverter pixel past the playfield half, and EP10 cs:27FC reading `ds:049F + 4*(n-1)` with a
   counter that only stays in 1..5 in normal play. With a counter outside its normal range the original reads past `data_segment_size` into the playfield bytes.
   The EP10 differential failures (4 of 4200 trials, all in h2759) are this case, with random counter values the game should
   never reach. They disappear when the interpreter models the full 64 KB window (`FULLSEG=1`).
6. **Light shows / animations** (EP2 `show_table_pointers`, the spinner, EP10's eye) are main-loop display code, not rules.
7. Flag-dependent branches the lifter cannot model produce `["flags"]` conditions. The one case in the 13 tables, EP8's kicker
   (cs:1b20 `jne` after a join of two compare paths), is now resolved (section 4.2); none remain. `jb/jae` after `inc/dec`
   (CF unchanged) would still hit this.
8. **Not expressible, left as `asm`/`call` ops** (`coverage.unexpressed`): EP6 cs:31e1 (1 call; the ball-number and score
   panel: far text calls cs:4FCA, score_refresh cs:416B), EP8 cs:3613 (3 calls; copies with `rep movs` into DS, the palette
   ring reload) and cs:0240 (the frame wait, used as a delay in a light show), and EP9 handler h29c6 (22 ops: `out` port writes
   and writes through a non-DS segment into the collision buffer, 2x2 blocks at top-half 0x47BD / 0x4F44). The verifier cannot
   run h29c6 (every trial is skipped); everything else in these tables runs. The Swift port runs all of them from the EXE
   (MiniX86): display routines (DS switched to a constant segment, or ES = A000h) are skipped, unknown near calls inside a
   `call` are followed (EP10-13 cs:358A-style num_to_text), and the EP8 palette routines are handled natively. EP5's end-of-ball region cs:1f4a was dropped because an `adc` there has no preceding `add` to pair with.

## 5. Verification

`tools/emu/verify_rules.py` (all tables; it generalises `scratch/rules/verify_ir.py`) runs, for every handler and hook in
`rules.json`, (a) the JSON IR interpreter (the same ~300-line class an app implements) and (b) Unicorn on the **original code**
from the handler/hook entry. Handlers get the dispatcher's stack frame; hooks run to their `stops`. Only the display routines
are stubbed. DS bytes, collision-buffer bytes and display calls (message with its mode, text, number, refresh) are compared.
The flipper keys (`["input", ...]`) are random, and both sides see them at the table's CS key bytes (discover.py). Two phases
per target:

* **Random** (N trials, default 300): a state from the EXE's initial DS, with rule variables randomised towards the constants the
  target compares against, the ball inside the sensor's regions, and random registers.
* **Directed**: for every block the random phase never executed, the verifier takes a random path from the entry. It runs the
  path's `reg`/`set`/`store`/`lamp`/`ball` ops symbolically so each branch condition is an expression over the *initial* state.
  It solves the conditions on variables, memory, ball, lamp, slot and input fields against constants greedily (it also sees
  through `and` masks and `add`/`sub` offsets). It tries small +-1/+-2 offsets and "array fill" variants (the same value in
  neighbouring bytes/words, for loops over tables). It keeps a state only if the interpreter really reaches the block, and then
  runs that state differentially.
* The whole 64 KB DS window is modelled by default: past `data_segment_size` it is the playfield image, as in the original.
  `--no-fullseg` compares only the exported range, and then EP1, EP2 and EP10 show 3, 11 and 17 failures, all reads or writes past
  `data_segment_size` (section 4.4 item 5).

**Results (2026-09-27, 300 random trials per target + directed): 0 failures on all 13 tables**. The per-table numbers are in the
section 4 table. EP1 gives the same result as before (0 failures), and the directed phase now reaches 293 of EP1's 303 blocks
automatically. The earlier hand-written `scratch/verify-rules/directed.py` reached 49 of the 50 missing blocks. The 10 still
unreached include L2017, which is dead code. EP3 reaches all 175 blocks. Blocks never executed per table: EP1 10, EP2 31, EP3 0,
EP4 34, EP5 3, EP6 2, EP7 16, EP8 16, EP9 43 (2 of them in the unrunnable handler h29c6), EP10 44, EP11 33, EP12 36,
EP13 31. Lists are in the verifier's JSON (`never`).
A second run with 2,000 random trials per target (seed 99; 772,000 random trials plus the directed phase over the 13 tables)
also has **0 failures**. It executes EP1 298/303, EP2 461/491, EP3 174/175, EP4 302/325, EP5 103/106, EP6 269/270,
EP7 374/385, EP8 308/325, EP9 313/348, EP10 335/370, EP11 365/391, EP12 401/431 and EP13 347/374 blocks.

What the verifier found and what was fixed:
* **Lifter bug**: dead-register elimination ignored registers read by a gosub callee. The EP3 end-of-ball delay loop ran 0x3908
  times instead of 15 (section 4.2). Fixed.
* **IR semantics**: shift counts mod 32 (section 3.2, EP9 cs:2e07). The interpreter must mask the count.
* EP8 kicker: a `["flags"]` join that made all its trials unrunnable. Now lifted (section 4.2).
* A verifier bug (full-segment writes into the playfield alias were not folded back) caused false failures in the EP2/EP3
  player save/restore regions. Fixed in the verifier.

Caveats: this checks the lift against the code, not the code against the running game. Random and directed states can be unreachable
ones. Display calls are compared by arguments only; the digits `number_text` writes and the `outside_playfield` write are not
compared. Some automatic hooks are display-side code (section 4.4 item 1): they verify, but that says nothing about their meaning.

## 6. Open items

* Name EP2-EP13 state and hooks (the automatic hooks give entry/stop and a shape label only). Reproduce EP1's end-of-ball
  split (section 4.1 differs at the cut points).
* EP9 h29c6 (port and segment writes) and EP8 cs:3613 (`rep movs` into DS) still have no op; the port executes them from the
  EXE (section 4.4 item 8), which is exact in every harness scenario but not a schema-level description.
* The per-frame data-segment check (RulesLiveTests) is EP1-only; the other tables are checked on ball traces (emulation.md 12).
* EP2-EP13 boot: the port starts the data segment from the EXE image plus the command-line options; the intro/boot tail
  that EP1's TableGlue `init` runs is not annotated for the others (visible only as the attract text state and EP8's palette
  phase).
* Message effects (render_frame's per-dot animation, fades) are decoded for timing only; the renderer shows static dots.
* Runtime check in DOSBox-X: break on cs:1E6A (dispatch) and cs:19C1 (kicker) and compare with `verify_ir.py` traces.

## 7. The Swift port's interpreter (`app/Sources/PinballCore/Rules/`)

* `RulesProgram` loads rules.json; `RulesMachine` interprets the block graphs over the 64 KB data-segment window read from the
  user's EXE, with every engine-owned byte bound to `ClassicEngine` (partial writes included) and shift counts taken mod 32.
* `MiniX86` executes unlifted code from the EXE (the `call`/`asm` ops, TableGlue ranges); an unknown call outside a rule
  `call`, an unsupported instruction or a jump out of range stops it and is reported, never guessed.
* `RulesRuntime` does sensor dispatch (cs:1E3B semantics, jump table read from the EXE, per-ball lockout for EP9-13), the
  kicker hook, the main-loop schedule (EP1: annotated order; EP2-13: `every_frame` hooks in entry order interleaved with the
  engine's pieces at their `found_at` ips), end of ball (`ball_end` hooks following `continues`, then the end-of-turn
  counters), lamp_update, render_frame's message counter, sfx_play -> `SoundEvent`, the EP8 palette ring, and fills
  `PresentationState` (mapping in the comment block on `RulesRuntime`).
* `PaletteCycle` (EP8 cs:1281) and `TableGlue` hold the only per-table code knowledge, as addresses or code signatures.
