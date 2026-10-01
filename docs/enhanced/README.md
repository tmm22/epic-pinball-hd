# Epic Pinball HD: the enhanced version

The enhanced version builds on the classic port (`app/`, bit-exact against the original machine
code: [app/README.md](../../app/README.md), [docs/formats/README.md](../formats/README.md)) and adds a Mac front end,
a pure-Swift importer, table rules executed straight from the user's EXE, an optional enhanced
physics model and an enhanced renderer. **Classic mode is unchanged**: with the default settings the app
runs the same integer engine and the same renderer passes as before.

No game data is in the repository or in the app. Everything game-derived (art, sounds, texts,
numeric tables, HD packs) is read or generated at runtime from the user's own CD or install and
lives in per-user directories: `~/Library/Application Support/EpicPinballHD/` in the app, and the
gitignored `extracted/` (Python tools) and `extracted/hdpacks/` during development.

## Documents

| Document | Contents |
|---|---|
| [frontend.md](frontend.md) | Launcher, settings, input (key remapping, game controllers, haptics), pause / game-over menus, high scores, first-launch import, data lookup, packaging (`tools/package_app.sh`) and its runtime check, smoke-test hooks |
| [import.md](import.md) | `PinballImport`: ISO 9660 / folder / GOG-style sources, the Swift port of the extraction pipeline, the library layout (`library.json`), parity with the Python tools, performance |
| [rules-direct.md](rules-direct.md) | The direct rules backend: the table's sensor handlers, hooks and helpers run from the user's EPn.EXE in `MiniX86`, found at run time (no rules.json); verification against the original and the lifted backend |
| [physics.md](physics.md) | `EnhancedPhysics`: the `BallPhysics` hook, the sub-stepped model (distance field, flipper model, `classicKick`), the classic-feel and modern presets, the validation studies (fuzz, classic comparison, full games) |
| [presentation.md](presentation.md) | Classic presentation fidelity: dot-message effects run from the EXE, EP9-13 message colours and strip clear, the EP1-8 palette fades, EP8's robot set; checks against the harness and DOSBox-X captures |
| [replays.md](replays.md) | Replays (input-only `.epreplay` files, determinism, playback at 1x/2x/4x, high-score links) and practice mode (full save states: engine, rules data segment, MiniX86, physics, presentation) |
| [attract.md](attract.md) | Attract mode: the original's demo (players 'D') ported from the EXE and diffed against it on all 13 tables; idle table / launcher attract in the app |
| [rendering.md](rendering.md) | Enhanced rendering: smooth / xBRZ / CRT filters in Metal, HD asset packs (`tools/hdpack/make_pack.py`), dynamic lighting, high-refresh interpolation, full-table view, GPU timings |

## What is done

| Area | State | Evidence (2026-09-28 integration run; rows marked 2026-10-01 from the `enhanced-additions` integration) |
|---|---|---|
| Classic parity | unchanged | `run_suite.py --modes physics,rules`: **830/830 with `EPIC_PINBALL_RULES=direct` and 830/830 with `lifted`**; `swift test` includes the classic byte-identical render goldens |
| Importer | done | the app imports the 1995 CD image in about 2 s (debug build); `PinballImportTests`: all 4,133 files equal the Python outputs; the library has no rules.json (`ImportOptions(rules: .none)`) |
| Rules from the EXE | done, default | direct and lifted agree on all 830 suite runs; every game below reports `rulesBackend: direct` from a Swift-imported library |
| Front end | done | first launch: `--launcher --import-from CD.iso` into an empty support dir ends on the picker with 13 named tables; picker -> game with enhanced settings from settings.json; a 1-ball classic game reached game over, initials typed through the key path, `highscores.json` written |
| Enhanced physics | done (classic-feel preset in the app) | autoplay from the imported library, packaged release binary: **all 13 tables reach game over with enhanced physics** (and with classic), 0 rule faults, 0 loop-guard trips |
| Enhanced rendering | done | window runs report `render: filter xbrz, hd pack active, lighting subtle, interpolate true` with a 4x pack made from the imported library; crt + full table and smooth + enhanced physics also run; GPU 4.2 ms mean at 3840x2160 worst case (rendering.md) |
| Packaging | done | `tools/package_app.sh`: ad-hoc signed .app + zip, 5 dylibs embedded, no game data; runtime check imports the CD with the packaged binary **inside a sandbox that hides extracted/, original/, the build trees and Python**, plays table 1 (classic) and 10 (enhanced) to game over, renders an xbrz + lighting snapshot, then makes table 1's 4x HD pack with the Swift generator and renders with it (2026-10-01: all steps pass, 5,950,000 / 13,220,000; 2026-10-02 after the rules fidelity work: 5,950,000 / 9,720,000) |
| Settings and UX (2026-10-01) | done | lighting strength, scaling, physics preset, audio resampling, pause when inactive, screenshots, per-table statistics, performance overlay (frontend.md). A settings.json in the pre-merge format decodes with every new field at its default (`IntegratedSettingsTests`; launcher start reported `lighting subtle, scaling auto`, preset `classicFeel`); a window autopilot game wrote `stats.json` (1 game, 3 balls, best 5,950,000, 55.9 s) |
| Render motion (2026-10-01) | done | enhanced-physics ball drawn at full precision; every active ball slot drawn (EP1-8: 5, EP9-13: 3; harness `check_ball_draw.py`), so EP3's captive ball and multiball balls now show in classic too; HD flippers rotated with high refresh (not EP8). Single-ball classic render goldens unchanged |
| Presentation fidelity (2026-10-01) | done | dot-message effects run from the EXE (104 harness cases, 25,863 frames identical), EP1-8 palette fades (420/420 frames per table), EP9-13 message colours, EP8 robot set (presentation.md); `MessageAnimator` no longer hangs on EP2-13 (rules-driven test on all 13 tables) |
| HD packs in Swift (2026-10-01) | done | Swift port of `make_pack.py`, pixel-identical on all 13 tables at 4x; `--make-hd-pack 10 --scale 4 --verify-hd-pack` from an imported library: 175 assets aligned, best shift (0, 0), MAE 1.464; window run with that pack reported `hd pack active` |
| Replays and practice (2026-10-01) | done | an app-recorded classic EP1 game (5,950,000, 3,352 frames) and a headless enhanced EP10 game (13,220,000, 1,853 frames) both play back with `matches: true`; `--watch` at 4x reached the recorded final state and recorded no score or statistics (replays.md) |
| Attract mode (2026-10-01) | done | the original's demo, ported and diffed (52/52 attract scenarios EXACT on both backends, attract.md); `--attract` window run on EP10 and snapshot on EP1 play themselves; demo games record no replay, statistics or high score |
| Display rest (2026-10-01, `feat2/display-rest`) | done | overlays turn with the picture (`CabinetRotationTests`: transform maths and synthetic clicks on a turned button in a real `NSHostingView`, all four rotations), the score window has its own rotation (`testRotatedStripIsTheUprightStripTurned`), flippers rotate without a pack for smooth / xBRZ / CRT (`testRotatedFlipperWithoutPack`, snapshots looked at); GPU at 4K: rotation pass 0.42 ms, no-pack flipper rotation +0.06-0.20 ms; replays at 4x run at 240 frames/s in a release build, classic and enhanced; `swift test` on the branch: 322 tests, 0 failures, 7 skips (the new 4K rotation perf test is opt-in; the golden-trace differential test skipped in the worktree) |
| Cabinet and distribution (2026-10-01) | done (signing with real credentials not done) | `--rotate 90/270` snapshots turned correctly (checked by eye; rotation tests compare with `np.rot90`); `--score-snapshot` writes the strip alone; `package_app.sh` hardened path (`HARDENED=true`) passes its runtime check with `--list-dylibs` (5 dylibs) |
| Classic rules fidelity (2026-10-01, `feat2/classic-fidelity`) | done | EP2-EP13: end-of-ball chain past the palette loop and the frame waits (`via`, `native_hooks`), the plunger lane's rule fragments, the boot tail, the timed message, EP9-13's between-balls display and score refresh, render_frame's message counter in the data segment (docs/formats/rules.md 4.1, 7). `attract_check.py`: 52/52 scenarios identical on both backends; `tools/emu/scenarios/EPn/fidelity`: 71/71 EXACT in full mode on both backends (messages, counter, between-balls flag watched); parity 830/830 on both backends, full mode 413/415 (the 2 known EP8 harness errors); `swift test` 315 tests, 0 failures |
| Classic presentation fades (2026-10-02, `feat2/classic-fidelity`) | done | the boot fade-in at every game start and the end-of-game fade-out on all 13 tables, every DAC frame equal to the original's (772 frames, `ScreenFadeTests`); EP2-13 effect sounds checked against the original (26 sounds in 104 cases) and played on both backends; EP8's palette ring starts as the boot leaves it (scenario `EP8/fidelity/palette_ring.json` EXACT); EP8's robot set kept across VRAM resets; EP9-13's plot skip checked by running (presentation.md 3.1, 4, 6). Parity 830/830 direct and lifted |
| Front-end gaps (2026-10-01, feat2/frontend-rest) | done | statistics only for human games (one predicate, `GameController.recordsStatistics`); Cmd-, pauses for Settings without the pause menu; Settings > Display exposes the CRT parameters, round dots, strip in the whole table and Rotate flippers; the import-done screen offers HD packs (13 4x packs made in the background from `--import-from CD.iso --import-hd-packs 4`); practice save states on disk, 4 slots per table: a state saved in one process loaded in another to the same digest, and `PracticeAcrossRunsTests` continues it identically to the first run (frontend.md, replays.md 3a) |
| Integration of the feat2 branches (2026-10-02, `enhanced-additions`) | done | classic-fidelity, frontend-rest and display-rest merged; `swift build` after each merge. Parity: physics+rules **830/830 direct and 830/830 lifted** (after regenerating the lifted rules.json files), full mode 413/415 (the 2 known EP8 harness errors); fidelity scenarios 72/72 EXACT in full mode on both backends. Headless classic games to game over: EP1 5,950,000 (3,352 frames), EP2 4,555,000 (2,176 frames, same with lifted; no rule faults or warnings); both replays play back with `matches: true`, and `--watch` of the EP2 replay reached its recorded final state. Window runs (throwaway `--support-dir`s): EP1 enhanced + xBRZ + 4x HD pack + subtle lighting + high refresh (`hd pack active, interpolate true`); EP2 at `--rotate 90` with the pause menu turned with the picture; practice slot 1 saved in one process and loaded in the next to the same digest (52d6dfe0b236e23b); score window at 90 with the user defaults left unchanged. No-pack rotated flippers checked in the smooth / xBRZ / CRT snapshot sheet. `package_app.sh` (ad-hoc): sandboxed runtime check passes (5 dylibs; EP1 classic 5,950,000, EP10 enhanced 9,720,000, xBRZ + lighting snapshot, Swift 4x HD pack). Data audit of `main...enhanced-additions`: no binaries, no game text or tables; one quoted prompt text replaced by a description |
| Tests | pass | `swift test`: 344 tests, 0 failures (2026-10-02), 6 opt-in skips (three GPU perf tests, snapshot writer, live audio, library writer), including the `EpicPinballTests` front-end tests and the golden-trace test (needs `scratch/diff/golden`); 24-29 minutes |

## Build, run, package

```sh
cd app
swift build && swift test

swift run EpicPinball                                   # launcher; import screen on first launch
swift run EpicPinball --support-dir /tmp/eps --launcher # throwaway settings / scores / library

# importer without a window, then play or render from that library (no Python, no extracted/)
swift run EpicPinball --headless-import "../Epic Pinball ... .iso" --library /tmp/eplib
swift run EpicPinball --library /tmp/eplib --table 10 --physics enhanced --autoplay 100000
swift run EpicPinball --library /tmp/eplib --table 1 --snapshot /tmp/s.png --launch --sim-time 1 \
                      --filter xbrz --lighting subtle [--hd-pack]
swift run EpicPinball --library /tmp/eplib --table 4 --physics enhanced --filter crt --full --high-refresh

# HD pack in Swift (as Settings > Library does), into <support dir>/HDPacks/EP10
swift run EpicPinball --library /tmp/eplib --make-hd-pack 10 --scale 4 --verify-hd-pack
# HD pack (developer tool, Python): from extracted/ or from an imported library
../.venv/bin/python ../tools/hdpack/make_pack.py --table 10 --scale 4 --data /tmp/eplib --verify
    # -> /tmp/eplib/hdpacks/EP10 (also found: ~/Library/Application Support/EpicPinballHD/HDPacks/EP10)

../tools/package_app.sh --scratch-path /tmp/ep-rel [--keep-check DIR]   # build/EpicPinballHD.app + .zip
```

Invariants to re-check after changes to `PinballCore/ClassicEngine*`, `Physics.swift` or `Rules/`:

```sh
cd app && swift build && swift test
cd .. && EPIC_PINBALL_RULES=direct .venv/bin/python tools/emu/run_suite.py --modes physics,rules   # 830/830
         EPIC_PINBALL_RULES=lifted .venv/bin/python tools/emu/run_suite.py --modes physics,rules   # 830/830
.venv/bin/python tools/emu/run_suite.py --modes full                       # 413/415 (2 known EP8 harness errors)
# rules fidelity (not in run_suite's sets), both backends: 72 scenarios EXACT
for n in $(seq 2 13); do .venv/bin/python tools/emu/diff_traces.py --table $n --mode full -q tools/emu/scenarios/EP$n/fidelity; done
```

The lifted backend reads the gitignored `extracted/tables/EPn/rules.json`. After a change to
`tools/rules.py` (as in the classic-fidelity round) regenerate it before lifted runs:
`.venv/bin/python tools/rules.py 2 3 4 5 6 7 8 9 10 11 12 13`.

Settings (`GameSettings`, shared by all tracks; Settings panel or `settings.json` in the support
dir): physics classic / enhanced (preset classic feel / modern), upscale filter nearest / smooth /
xbrz / crt, scaling, HD pack, dynamic lighting off / subtle / vivid, high refresh, full-table view,
volumes, audio resampling, cabinet display (picture rotation, score window; frontend.md "Cabinet").
The defaults are the classic game.

## Known gaps

* **Needs a human with real hardware.** Every window run so far (including the 2026-10-02
  integration) drew on a 60 Hz display or from a 60 Hz timer and was checked through captured
  frames and offscreen UI snapshots. Not verified: 120 Hz on a ProMotion display; game controllers
  and haptics (including the auto-pause when a controller disconnects, and a pad Start press while
  the Settings sheet is open, which is not blocked); full-screen switching; the score window on a
  second display and a physically rotated monitor; real keyboard use of Cmd-, (checked through the
  menu action and a unit test), F10 / F12 / Shift-Cmd-S, the practice K / L and slot 1-4 keys (test
  hooks send them through the same key path); mouse use of the turned overlays (synthetic clicks
  only), the REPLAY bar, the launcher's watch buttons, the import-done HD pack checkbox and the HD
  pack progress / Cancel; and Developer ID signing plus notarization with real credentials (the
  script's flow was run with stand-in tools and the hardened runtime with the ad-hoc identity only;
  no build has been notarized).
* Front end: Settings > Library "Clear this table's save states" acts on the launcher's selected
  table and leaves this session's in-memory slots, so L can still restore a cleared slot until the
  game ends. Loading a practice state from disk re-simulates the saved game on the main thread
  (seconds for a long game in a debug build; release timing not measured), and the presentation
  after the load is rebuilt by replaying, not compared. The REPLAY bar and the performance overlay
  overlap at the top-left corner. The Settings sheet and the launcher stay upright on a rotated
  cabinet (the in-game overlays turn).
* Cabinet: the score window keeps showing the strip during attract mode and does not get the
  screen-fade palette; Enter (strip) does nothing useful while it is open.
* HD packs: only the external-upscaler (`--upscaler-cmd`, AI) method still needs Python.
* Rendering (rendering.md): without a pack the rotated flipper is clipped to the native pixels the
  flipper owns (the HD path's rule), and a still flipper differs slightly from the plainly filtered
  frame (most with CRT); a replaced flipper-sprite job is not cancelled, and a failed one leaves the
  cross-fade until the filter or scale changes; EP9-13 strip dots are round only with an HD pack. The
  xBRZ shader and generator are an own implementation of the published (GPL-3) xBRZ rules, so check
  this against the project's licence plans.
* Physics (physics.md): modern-preset flipper shots on EP11-13 are much stronger than the
  original's; EP12 has a lane the rules close with a gate while the ball is inside (the classic ball
  gets trapped there too). EP11 has a classic-physics resting spot at x=197 y=120 (vx 0, vy 5) where
  an autopilot ball can stay for good; some multi-ball autoplay configurations (2 players x 2 balls,
  4 x 1, 1 x 5, 1 x 9) therefore do not reach game over in 40,000 frames. It is the same before and
  after the classic-fidelity work (the ball counting only reaches it one drain earlier).
* Rules: EP12 can add 2,258,632,704 points from sensor C3. This is the original's own `loop`-with-CX=0
  bug (cs:2883), reproduced exactly. Messages, the message counter and the between-balls flag are
  checked frame by frame against the original on all 13 tables (EP1: RulesLiveTests; EP2-EP13: the
  attract and `fidelity` scenarios), but the whole data segment only on EP1; on EP2-EP13 some lamp
  state bytes still differ (EP2 ds:52xx, ds:530D; the boot's intro loop that animates the lamps is not
  run). Only the counter, step word and sounds come back from the private render_frame copy. EP8 has
  no lane glue (its launch block has another shape; `ClassicEngine.launchBlock` still handles it).
  The `fidelity` scenarios are not in `run_suite.py`'s sets; run them with
  `diff_traces.py --table N --mode full tools/emu/scenarios/EPn/fidelity` after rules changes.
  Several hook detections are code-shape heuristics checked on the 13 available EXEs only.
* Lifted rules: `tools/rules.py` output changed in the classic-fidelity round (`via`,
  `native_hooks`, new glue). Every developer checkout must regenerate its local, gitignored
  `extracted/tables/EPn/rules.json` with `.venv/bin/python tools/rules.py 2 3 4 5 6 7 8 9 10 11 12 13`
  before `EPIC_PINBALL_RULES=lifted` (or lifted parity) matches; the direct backend, which the app
  uses, needs nothing.
* Importer: GOG editions are found by DOS file names only (no GOG release was available to test).
* Replays (replays.md): enhanced-physics replays are exact on the platform they were recorded on (libm
  trigonometry); other platforms are reported, not guaranteed. Replays and practice states recorded
  before the classic-fidelity round report a digest mismatch on EP2-13 (ball-end rules, boot tail,
  message counter and EP8's palette ring changed), although they still play.
* Attract mode (attract.md): the original's demo is ported exactly, but only EP1's plunges; on EP2-EP13 the app adds
  the plunge (`attractLaunch`). The launcher's idle time (900 menu frames) is read from PINBALL.EXE, which the
  harness does not run, and its frame rate is assumed to be 60 Hz. The demo screen's black band below the window is
  shown as a hidden strip, and the app demos the selected table rather than the first installed one.
* Other classic-port limitations are listed in app/README.md. Message effects, EP9-13 message colours, the in-game
  palette fades, the visible boot fade-in and end-of-game fade-out (all 13 tables, frame-exact against the harness;
  the P pause has no fade in the original) and EP8's robot set are shown, and EP2-13 effect sounds are played
  (presentation.md). Still missing there: the boot's intro scroll (the fade-in plays over the starting view; on
  EP9-13 the port's 34 fade frames are extra frames before play), the quit fade-out (the app's own menu and attract
  mode leave without it), EP3/EP5's colour lamps (DAC B0h..BFh), and on EP9-13 a draining ball's background restore
  that wraps from the second VRAM page into the strip and stays visible while render_frame skips its plot
  (EP13 cs:4724). After a VRAM reset EP8's robot is redrawn before the lamps (order [M]).
