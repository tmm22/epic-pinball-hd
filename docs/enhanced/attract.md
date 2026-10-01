# Attract mode: the original's demo, ported

The DOS game has a demo mode. PINBALL.EXE starts a table EXE with players `'D'` on the command line
(engine.md section 8), and the table then plays itself until any key is pressed or the game ends,
and then exits back to the menu. The port runs that demo code bit for bit (`PinballCore`), and the
app uses it as an attract mode for an idle table and an idle table picker.

Confidence tags as in docs/formats: **[H]** read in the code *and* checked by running the original
in the Unicorn harness (tools/emu), **[M]** read in the code but not exercised, **[L]** a guess.
Addresses are EP1 (`cs` = code segment 0x3223, `ds` = data segment 0x0015) unless a table is named.
Disassembly: `.venv/bin/python tools/disasm.py --syms scratch/engine/ep1_symbols.json range 0C48 0D1D`.

## 1. What the original does

### PINBALL.EXE (the launcher) [M]

* The menu loop (file 0x838..0x876) counts frames without a key in `cs:[002E]`. At 900
  (`cmp word cs:[2Eh],384h`, file 0x848) it calls the demo routine (file 0x4EB2) and clears the
  counter. A key clears it as well (file 0x887). The menu's frame rate was not measured. At 60 Hz
  900 frames is 15 s.
* A menu item (file 0x9B7, item 5) calls the same routine directly.
* The demo routine temporarily sets the players byte of the command-line template to `'D'`
  (`mov byte cs:[6A70h],44h`, file 0x4EC7). It then picks **the first installed table** (the first
  `cs:[6969h+2i] == 1`, set at start-up when that table's files open, file 0x3EF) and launches it
  through the normal path (file 0x3C7F). So with every table installed, the original's demo is
  always table 1.

### The table EXE in demo mode [H]

`EP1.EXE` cs:007A: players `'D'` sets `demo_mode` ds:6C5A = 1 and one player (ds:6761). Every demo
branch tests that byte. In EP1 the readers are cs:03CB, 0493, 04AD, 0B44, 0B79, 0C48, 13C8, 13E3,
34C3, 3AFF and 44A0 (`tools/disasm.py xref 6c5a`):

| where | normal game | demo mode |
|---|---|---|
| init cs:03CB / 04AD | idle text, intro message | both skipped |
| intro scroll cs:0493 | - | a key down calls pause_menu (quit) |
| plunger cs:0B44 | Ctrl / Space charge 12 per frame | charges as if held, while ball 0 is in the lane |
| plunger cs:0B79 | - | **EP1 only**: once the charge is past 700, release (vy -= 708) |
| cs:0C48 `attract_autoflip` | jumps to the keys cs:0D1D | the block below, then `jmp 0E8A` |
| cs:0D1D..0E8A | Esc / P / T / Enter keys, split line, **nudge and tilt** | not run |
| dmd_idle_text cs:3AFF | ball / player text in the strip | dot message ds:6C5B (AX=0100h, DI=E100h: font8, row 180) |
| score_refresh cs:44A0 | score digits | nothing |
| game over cs:34C3 | end-of-game texts, then the menu | dmd_clear, then pause_menu, which quits |
| pause_menu cs:13E3 | quit prompt | straight to the quit path cs:14FA |

`attract_autoflip` (cs:0C48..0D1A), once per frame:

1. The flip timer ds:000B counts down. When it reaches 0, both flipper keys (cs:028D / 028F) are
   released.
2. For ball slots 0..2 (`di < 6`) that are active:
   * **Stuck ball**: if x and y equal the last frame's (word arrays ds:0018 / ds:0026 + 2*slot),
     ds:0034 += 1, and when it reaches 25, `vx += 1`. Otherwise the position is stored and the
     counter cleared. All slots share one counter. Slot 2's x word is ds:001C, which save_ball_bg
     also reads (cs:56F4) [M].
   * **Auto-flip**: if `y >= 350` and `x` is in 88..138, set the left key; if `x` is in 148..193, set
     the right key. In both cases the timer is set to 10 and the loop ends. All compares are
     unsigned.
3. **Key test** (cs:0CFF): if the key-repeat counter ds:000A is 0 and a key is down
   (`last_scancode < 80h`), pause_menu runs. In demo mode that is the quit path, so any key ends the
   demo. Otherwise a non-zero counter is decremented.

**Per table** [H, signature in every EXE, run in the harness]: EP2-EP4 and EP6-EP13 have the same
block byte for byte (only addresses differ: EP10 block cs:0C54, flag ds:4831, timer ds:0097, stuck
ds:00C0 / 00A4 / 00B2). EP5 (cs:091E) has an older version: ball 0 only, no active test, no stuck-ball
nudge. **Only EP1 has the release test cs:0B79.** In EP2-EP13 the demo holds the plunger at its
maximum forever. In the harness, after 900 frames of `players='D'` on every table, ball 0 never
leaves the lane in EP2-EP13 (EP8, which has no lane, never launches), while EP1 plays a whole game.
Its 17,134-frame demo ends with the int 21h exit at game over.

## 2. The port (`PinballCore`)

* `Attract.swift`: `AttractLayout.discover(code:)` finds the block in the user's EXE by its byte
  signature (two variants: the 12-table block and EP5's). It returns the DS addresses (flag, timer,
  key repeat, stuck counter and arrays), the constants (350, 88..138, 148..193, 10, 25, 20, slot
  count), the cs:0B79-style release test, and the block / keys / resume addresses.
  `RulesRuntime.attract` holds it.
* `ClassicEngine+Attract.swift`: `demoMode` reads the DS flag (through the rules' data segment, so
  rule code run from the EXE takes its own demo branches: idle text, score refresh, game over).
  `attractBlock` is the block above. The demo's state lives at the original's DS addresses.
* `ClassicEngine.swift`: in demo mode the frame input is the demo's own key flags (`demoKeys`; the
  original reads no keyboard), and the plunger lane / EP8's launch block take the demo branches.
  `rulesFrameLogic` runs the block in place of nudge/tilt (EP1 path), and
  `RulesRuntime.demoSchedule` does the same for the automatic main loop of EP2-EP13 (it also drops
  any hook inside [keys, resume)). As in the harness, the block runs only in `full` mode.
  `physics` / `rules` mode keep the harness ranges, where only the plunger's demo test is inside a
  range.
* `RulesOptions.demo`: the boot writes demo_mode = 1 and one player (cs:0081), and skips the
  boot's idle text (cs:03CB). EP1's init glue takes its own demo branches.
* `ClassicEngine.attractLaunch` (off unless the app sets it): **a deliberate deviation for the
  app**. On tables without cs:0B79 the demo releases the plunger at full charge, as EP1's does,
  because the original's demo on those tables shows a ball parked in the lane. Traces never set it.

Off by default: with demo_mode 0 none of this runs, and the classic engine is unchanged (suite below).

## 3. The app (`EpicPinball`)

`AttractMode.swift`, hooks in `GameController` / `AppDelegate`; `FrontEndSettings.attractMode`
(Settings > Game, "Attract mode when idle", **default on** as in the original).

* **Table**: a table whose game has not started (no flipper / plunger / nudge input since it was
  set up), or whose game-over panel is left alone, waits `900 / 59.94 ≈ 15 s` (PINBALL.EXE's 900
  frames). It then starts a demo game (`RulesOptions.demo`, players 'D', with `attractLaunch`). The
  strip slides out because the demo never sets the split line (cs:0E9D..0F54 skipped). The original
  shows black rows there instead (DOSBox-X capture, emulation.md section 8). Music and effects play
  as in the original.
* **Any key or controller button** (gated by the demo's key-repeat counter, cs:0CFF) leaves attract
  mode for a fresh game on the same table, with the strip back. The key itself does nothing else,
  just as in the original, where it only quits. A demo game over (the original quits there) also goes back
  to the ready state, and attract starts again after the idle time.
* **Table picker**: after the same idle time, the selected table opens in attract mode. A key, a
  button or the demo's game over returns to the picker, as the original returns to its menu. The original always
  demos the first installed table; the app uses the selected one.
* **Never counted**: the demo's game over skips `handleGameOver`, so there is no initials entry and
  nothing goes to `highscores.json`. Attract mode does not start while `--autopilot` drives the game,
  in `--demo` (presentation demo) runs, while paused, in a menu, the settings sheet or the initials
  entry, or in `--exit-after` smoke tests (unless `--attract-delay` is given).
* Flags: `--attract` (window: start in attract mode; `--snapshot`: run the demo), `--attract-delay S`
  (idle time; also enables it in smoke tests).

## 4. Verification

By running code:

* **Ball traces, original vs port, all 13 tables** [H]: `tools/emu/scenarios/EPn/attract/`
  (`make_attract_scenarios.py`). Each table has 4 scenarios: `attract_boot` (the real start:
  `"start": "boot"` with players 'D', from the first main-loop arrival after the table's own boot),
  `attract_serve` (demo flag poked after the warm-up, ball at the serve position) and
  `attract_drop_left/right` (a ball dropped onto each resting flipper: auto-flip and stuck nudge).
  EP1 runs 6000 frames, the others 900 / 1200.
  `diff_traces.py -q --mode full --table N tools/emu/scenarios/EPn/attract`: **52/52 EXACT with
  `EPIC_PINBALL_RULES=direct` and 52/52 with `lifted`** (every physics step: position,
  accumulators, velocity, contact, flipper angles, plunger charge). The scenarios press both
  flippers on every table (except one side in a few drops), and EP1's boot and serve runs plunge,
  play, drain and serve again. The serve and drop scenarios are also EXACT in `physics` and `rules`
  mode (checked on EP1, 2, 5, 8 and 10).
* **Dot display and data segment** [H]: `tools/emu/attract_check.py` hooks the original's
  dmd_message entry (from rules.json `stub_routines`) and compares every call (string DS offset,
  AX, DI) frame by frame with the port's `--trace --state`. For EP1 it also compares the whole data
  segment outside display buffers (RulesLiveTests' ignore list). **EP1: all 4 scenarios identical**:
  14,400 frames, 59 dmd_message calls (including the demo's idle text ds:6C5B, AX 0100h, DI E100h,
  after every plunge), and an identical data segment after every frame, demo state included.
  **EP3, EP10: all identical.** On the other tables the check found differences that were not
  caused by demo mode; they were gaps in the EP2-EP13 rules runtime and are fixed (2026-10-01,
  docs/formats/rules.md 4.1 and 7): **all 52 scenarios now identical on all 13 tables, with
  `EPIC_PINBALL_RULES=direct` and with `lifted`** [H, run]. What was wrong:
  * EP2, EP4, EP6, EP7, EP8: the timed message (AX 6, DI 5F00h, every 281 frames until the first
    plunger release; EP2 cs:04AB..0530) is a main-loop statement that writes nothing rule code reads,
    so the hook search left it out; statements that call dmd_message are now hooks. EP4 and EP7's
    ball-end messages were in the ball_lost_fade code after the palette loop, which no hook covered
    (EP4 cs:3084..3148: the no-score rule, the tilt reset, the bonus count and its payout). EP8's
    extra messages (AX 5, DI 2580h, cs:2968) are shown by the original only while no message runs
    (cs:296E reads the message counter ds:0A83), which the port did not keep for EP2-EP13.
  * EP5, EP9, EP11, EP12, EP13 drops: the idle text twice in one frame (EP9 cs:2E49 and cs:2F39) needs
    the chain to go on past the frame wait cs:2F36 (`via`); EP5's port reported it twice because the
    first end-of-ball region (cs:1F4A, where demo mode jumps past the counting) did not lift and was
    dropped, so the chain started at cs:1FC9 (now a `native_hooks` entry run from the EXE). After
    those, EP9-EP13 differed in the between-balls display (EP12 cs:049A -> cs:4149) and in the idle
    display render_frame shows when a message ends (EP10 cs:3EEC); and EP6 in demo mode turns every
    message into the demo text inside dmd_message (cs:15AF), which the port now does too.
  The harness runs EP9-EP13's render_frame after the physics steps now (`EpEmu.post_frame`, EP10
  cs:1238, outside the main-loop body `main_loop_full` runs), as the port does.
  `tools/emu/scenarios/EPn/fidelity/` (make_fidelity_scenarios.py) adds demo-off and release
  scenarios that watch the messages, the message counter and the between-balls flag frame by frame.
* **Unit tests** (`AttractTests`, need the user's data): the layout found in all 13 EXEs (addresses,
  EP5's variant, the release test only in EP1; the lifted backend finds the same); the demo schedule
  of EP2-EP13 (block after the lane, no nudge); EP1's demo game from `startGame(options: demo)` plunges,
  flips, scores, ignores the player's input and shows the demo idle text; EP10's demo parks the ball
  without `attractLaunch` and plays with it; demo off reads the player's input; live: the EP1 and EP10
  attract scenarios against the harness. `SettingsPersistenceTests.testAttractModeSetting`: on by default, an old
  settings.json without the field keeps it on.
* **Classic parity unchanged**: `run_suite.py --modes physics,rules` 830/830 with both backends.
* **App**: snapshots with `--snapshot --attract --frames N` (EP1, EP10) and window smoke tests with
  `--attract` and with the idle timer (`--attract-delay`), table and launcher (section 5).

Inferred, not run: the launcher's idle count and table choice ([M], read from PINBALL.EXE, which
the harness does not run). What the screen shows below the window in demo mode ([M]: no split
line, black rows in the DOSBox-X capture).

## 5. App runs (2026-10-01, display asleep: frames driven by the 60 Hz timer)

* `--table 1 --attract --exit-after 14 --window-capture`: `attract true`, score 250,000 after 14 s.
  The capture shows the playfield over the whole 240 rows (strip slid out), with the ball in play.
* `--table 10 --attract-delay 2 --exit-after 10`: the idle timer starts the demo (`attract true`,
  750,000 points: the app's plunge on EP10). With `EPIC_PINBALL_TEST_KEY=8:49` (Space at 8 s) and
  `--exit-after 9.5`: `attract false`, score 0 (a fresh game).
* `--table 1 --attract-delay 2` with Space at 0.5 s (the game has started): no attract by 6 s.
  `--autopilot --attract-delay 1`: no attract.
* `--launcher --attract-delay 2 --exit-after 8`: the picker opens table 1 in attract mode (`attract
  true`). With a key at 4 s it returns to the picker (`launcher smoke test: screen picker`).
* `--table 1 --balls 1 --attract --exit-after 150` (support dir empty): the one-ball demo game ends,
  and the run finishes with `attract false, score 0, overlay none, high scores on table 1: 0`, and no
  `highscores.json` written. So the demo's game over led to a fresh game, with no initials entry.
  (A 3-ball run, `--exit-after 310`, was still in the demo when it exited: with the parity suite
  running in parallel, the timer-driven window got only 8,173 frames.)
* Snapshots: `--table 1|10 --attract --snapshot OUT --frames 600|700`: the demo has launched and
  is playing on both tables.

`EPIC_PINBALL_TEST_KEY=S:CODE` (a smoke-test hook, like `EPIC_PINBALL_TEST_MENU`) presses a key
through the normal key path S seconds after the first frame.
