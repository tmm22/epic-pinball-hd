# Replays and practice mode

Code: `app/Sources/PinballCore/Replay/` (format, recorder, player, save states), the `State` /
`saveState` / `restoreState` extensions at the end of `ClassicEngine.swift`, `RulesRuntime.swift`,
`RulesMachine.swift`, `MiniX86.swift`, `EnhancedPhysics.swift` and `Physics.swift`, and in the app
`Replays.swift` plus the replay / practice extension at the end of `App.swift`. Tests:
`PinballCoreTests/ReplayTests.swift`, `EpicPinballTests/ReplayFrontEndTests.swift`.

Nothing here runs unless a replay is recorded or played or a practice state is saved: the engine,
rules and physics code paths are unchanged, and the parity suite stays 830/830 with both rules
backends (section 6).

## 1. What makes a game reproducible

A replay stores only the per-frame input bits (`FrameInput`, one byte per 59.94 Hz frame) and the
start conditions. That is enough because the simulation reads nothing else:

* **Engine** (`ClassicEngine`): integer state, the table data and `input`. No clock, no randomness.
* **Rules, the original's only "random" number** [H, verified statically and by running]: the skill
  lane is picked from `skill_lane_rng` ds:0B2A, a main-loop counter mod 4 (EP1 cs:09DC
  `inc byte [0B2A]` / `cmp 4` / `mov 0`, read at cs:35A2 in next_ball_skill). In the port the main
  loop runs once per frame, so it is a function of the frame number.
* **MiniX86 port reads**: `in` returns 0 except 3DAh, whose retrace bit toggles on every read
  (`retraceBit`, part of the save state). A static scan of all 13 EXEs (`tools/disasm.py io`) finds
  reads of 3DAh, 201h (joystick, in the main loop the port does not run from the EXE), 60h/61h (the
  keyboard ISR) and DX-indirect sound-card ports; **no table reads the PIT (40h-43h are only
  written)** [H, static]. Segment-0040h (BIOS tick) reads would go through `imageRead` (the EXE
  image), which is constant; none were seen to fault in the runs below [M].
* **Swift hash seeds**: dictionary / set iteration order differs per process. The places in the
  runtime that iterate a dictionary or set either build lookup tables whose result does not depend
  on the order (sensor `vars` bindings: no two names share an address in any table's engine.json,
  checked with a script; `hookByIP`; register dictionaries, each key assigned independently) or
  rebuild distance fields from a bounding box (`EnhancedPhysics.updatePixels`, order independent).
  Checked by running: replays recorded in one process reproduce in another (section 5).
* **Enhanced physics** is floating point (Double, SIMD Float fields). With no threads and fixed
  substeps it is deterministic for the same binary on the same CPU architecture; `cos`, `sin` and
  `atan2` come from the system libm, so a replay recorded on another architecture or OS release may
  diverge. The header records `platform` (e.g. `arm64 macOS 26.5.2`) and playback reports a
  different architecture or major OS release (`ReplayHeader.platformFamily`: `arm64 macOS 26`)
  instead of claiming exactness; minor OS updates are not reported, so an update does not flag
  every enhanced replay [M: libm could in principle change in a minor update; not observed]. Not
  tested across machines (only one was available).

**Start order.** A replay starts from a newly loaded engine: `EngineAssets.makeEngine` with the
recorded rules backend, `gravityPhase`, then `GameSimulation.init` (start the game, then install the
physics model). The app starts every recorded game the same way: the first one is exactly that, and
each new game restores the engine's **power-on snapshot** (taken before its first game) and calls
`GameSimulation.newGame(options:powerOn:)` (start, then a fresh physics model). Without this a second
game would inherit session state that a fresh engine does not have (MiniX86's stack contents and
retrace toggle, `genericLampTick`, the enhanced model's substep counter), and its replay would not
reproduce. This is the one behaviour change outside replays: a new game in the app is now exactly a
newly loaded table (the harness and the parity suite always start fresh, so they are unaffected).
It also resets DS state the original keeps across games, such as the `skill_lane_rng` counter
ds:0B2A. Before this change the port carried that counter as (frames played so far) mod 4, because
it runs no frames between games; the original's value at the next start also depends on how long
the player waits between games [L, inferred: not checked against the running game], so neither is
"the" original value, and a stored copy of the DS segment would put game data in the file. The
fresh enhanced model is built on the main thread at each new game, the same work as pressing E.

## 2. File format (`.epreplay`, version 1)

Little-endian:

| Bytes | Contents |
|---|---|
| 4 | `EPRP` |
| 1 | format version (1) |
| 4 | header length |
| n | header, UTF-8 JSON (`ReplayHeader`, sorted keys, ISO 8601 date) |
| 4 | run count |
| per run | u8 input bits, LEB128 run length in frames |

The runs must add up to `header.frames`. Header fields: `format`, `engineVersion`
(`ReplayFormat.engineVersion`, bumped whenever the same inputs could produce a different game),
`appVersion`, `platform`, `table`, `date`, `physics` and `enhancedConfig` at frame 0, `events`
(physics switches with the frame they apply before: the E key or the settings mid-game; see below),
`rulesBackend`, the PINBALL.EXE options (`players`, `ballsPerGame`, `sfx`, `music`,
`soundPresent`), `gravityPhase`, `exeDigest` / `dataDigest` (FNV-1a 64 of the user's EPn.EXE and of
engine.json + collision_idx.npy, plus rules.json for the lifted backend, to detect other files;
never the files), and the result: `frames`,
`finalScores`, `finalDigest` (`StateHasher` over engine, rules data segment, machine memory, MiniX86
registers/stack/retrace bit, lamp and message bookkeeping, enhanced bodies bit for bit), `gameOver`,
and for high-score games `initials` / `player`. No game data is stored (no names, texts or numbers
from the EXE). AutoPlayer games take 500-1400 bytes.

**Events.** The recorder compares, at each frame boundary, the physics mode, the enhanced config
and `GameSimulation.physicsInstalls` (bumped by every `installPhysics`) with the previous frame. A
switch enhanced -> classic -> enhanced between two frames (E pressed twice while paused, or the
setting toggled twice) leaves the mode as it was but installs a fresh `EnhancedPhysics` (new
bodies, `stats.substeps` = 0); it is recorded as an event with `reinstall: true`, and playback calls
`reinstallPhysics()` for it. A classic -> enhanced -> classic round trip leaves nothing behind and is
not recorded. `reinstall` is optional (absent = false), so files without it still decode.

**Damaged files.** `decode` rejects a header whose `frames` is negative or above
`ReplayFormat.maxFrames` (2^27) and a run count above `frames` before allocating, so one bad file
in Replays/ cannot crash the launcher's list.

## 3. Save states (practice)

`GameSimulation.snapshot()` / `restore(_:)` (`SimulationSnapshot`), taken between frames:

* `ClassicEngine.State`: every mutable field (collision buffer, the EP8 dynamic class tables and
  their key, ball slots, flipper groups, params, counters, hit list, `obj`, `dsLocal`, frame/step
  counters, rules mode, `bufferWriteLog`, `bufferGeneration`, sensor statistics).
* `RulesRuntime.State`: `RulesMachine` memory (64 KB; engine-bound bytes live in the engine state),
  faults, contact colour; **MiniX86** registers, flags, its private 64 KB stack segment, DS/ES, the
  3DAh retrace toggle and run bookkeeping; options, game over, message (DS, AX, DI), local
  counter/effect, `lampDrawn`, `genericLampTick`, the sound-queue delay, the palette-ring DAC copy,
  and the queued sounds and texts (the audio-relevant rule state: the sound queue, sweeps and rate
  are DS bytes and come with the machine memory).
* `EnhancedPhysics.State`: config, statistics (`stats.substeps` times the flipper kicks), bodies,
  distance fields and class masks (value types, copy-on-write, so a save is cheap until the world
  changes), flipper motion, reflection-map cache.
* `GameSimulation.State`: physics mode and config, held input, accumulator, interpolation points.
  Restoring a state saved in the other physics mode installs or removes the model; the app then
  sets the stored physics setting to the restored mode (so the next settings change does not switch
  back) and the presentation mode follows it.

The app adds the presentation (`ClassicPresentation.Saved`: ingested state, dot-message lines,
original camera, plunger) and the window camera. Playing sound effects are stopped on restore (the
audio engine's voices are not simulation state); music keeps playing.

### 3a. Save states on disk

`PracticeStates.swift`. Each slot of each table is a file `<support>/SaveStates/EPn-slotK.epstate`
(JSON, `"format": "epic-pinball-practice-state"`, `"version": 1`): table, slot, date, frame, scores,
game over, the physics and enhanced config at the save, the `stateDigest` at the save, and
`replay`: the encoded `.epreplay` of the game from its first frame to the saved one (base64). The
full in-memory snapshot (64 KB machine memory, engine buffers, distance fields) is not serialized;
the state is the input history, which replays already reproduce exactly (sections 1, 5).

* Recording: a practice game with rules is recorded from frame 0 like a normal game
  (`GameController.practiceRecorder`); K takes `ReplayRecorder.snapshot(scores:)` (the prefix and the
  digest, recording goes on) into the slot's file, atomically, and keeps the `SimulationSnapshot` in
  memory for that slot.
* L with a state of this session: the in-memory restore (section 3), and the practice recording
  continues from the slot's prefix (`ReplayRecorder(resuming:simulation:)`, so a later K saves the
  right game). L without one (a new run): the file is read, the game is re-simulated on the running
  table (a new game from the power-on snapshot with the recorded physics and options, then every
  recorded frame through `ReplayPlayer`, its rules output into the classic presentation, no drawing
  and no sound), the recording resumes, and a physics switch made between the last frame and the save
  (E, then K) is applied as the key did. The digest is then compared with the saved one; a mismatch
  is shown ("not exactly the saved state", with the replay notes: other EXE or data, platform). A
  file saved with the other rules backend is refused (its frames mean something else).
* Damaged files (not JSON, bad replay bytes, a frame count that does not match the stored game) are
  moved aside to `EPn-slotK.epstate.bad` (an older .bad is replaced) and the slot is free again; a
  newer format version or another table's file is left in place and not loaded. Settings > Library
  shows the selected table's used slots and clears them.
* Practice states never affect high scores, statistics or replays: practice sessions have
  `recordsResults` false, and the practice recording has its own recorder that nothing writes as a
  replay.

## 4. Front end

* **Recording.** Every normal game with rules is recorded from frame 0 (`ReplayRecorder` on
  `GameSimulation.frameObserver`). At game over it is written to `Replays/EPn-last.epreplay` in the
  support directory (replacing the previous one). A game that enters the high-score list is also
  kept as `EPn-hs-<date>-<score>.epreplay` and the entry links to it (`HighScoreEntry.replay`, optional,
  so older highscores.json files decode); when an entry drops off the list its file is deleted. The
  game-over panel offers **Save Replay** (`EPn-saved-...`, kept until deleted by hand) and **Watch
  Replay**. A new game, practice mode or leaving the table discards the recording in progress.
* **Watching.** Launcher: a play button next to each high score with a replay, **Watch last game**,
  and a **Saved replays** menu; also `EpicPinball --watch FILE`. The replay runs on a newly loaded
  engine; the REPLAY bar has pause, 1x / 2x / 4x and Exit (keys: Space or P pause, 1 / 2 / 4, Esc
  menu with Watch Again). Game keys do nothing; view keys (strip, filter, full table, volume,
  scrolling) work. The recorded physics is kept whatever the settings say. Watching records no
  high scores, no statistics and no replay. At the end the panel says whether the final state
  digest and scores equal the recording.
* **Practice.** Launcher **Practice**, or Esc > **Practice Mode** in a running game (that game then
  continues as a practice game; its recording continues as the practice recording and is never
  written as a replay). A PRACTICE badge stays on screen. K saves the state, L restores it (Settings >
  Controls can rebind both; also in the pause menu, "Save State (Slot n)"); the digit keys 1-4 (main
  row or keypad, unless bound to an action) choose one of four slots per table. States are kept on
  disk (section 3a). A
  settings file from before these keys gets K / L only where the user has not bound K or L to
  another action. Practice
  games never enter the high scores, statistics or replays (`GameController.recordsResults` is the
  gate for all three; it is also false for attract-mode demo games). End Practice starts a normal game. The window title says "(Practice)" or
  "(Replay)" while that session runs. Clearing a table's scores in Settings also deletes its
  high-score replays.

## 5. Verification (2026-10-01)

Run here (debug build, Apple Silicon, macOS 26.5.2, the user's 1995 CD data):

* `ReplayTests.testReplaysReproduceAutoplayGames`: AutoPlayer games on EP1, 2, 5, 8, 10 (2 players,
  2 balls), 13 in classic and enhanced physics, recorded, encoded, decoded and re-simulated on a new
  engine: identical frames, scores and final digest. `testReplayWithPhysicsSwitches`: classic ->
  enhanced at frame 400 -> classic at 1300, reproduced. `testNewGameFromPowerOnIsReplayable`: the
  second game of a session (power-on restore) reproduces on a new engine, both physics.
  `testReinstallBetweenFramesIsRecorded`: enhanced -> classic -> enhanced between two frames (twice)
  plus plain switches: the events carry `reinstall`, the replay reproduces, and the same replay
  without the reinstall events does not (so the event is what keeps it exact).
  `testLiftedBackendReplaysReproduce`: EP1, 8, 10, 13, lifted rules, both physics, reproduce in
  process; the lifted data digest differs from the direct one (rules.json is included).
* `ReplayFrontEndTests.testOnlyNormalGamesRecordReplaysAndScores` (EP1, needs the user's data and
  Metal): a practice game records nothing and writes no file, a normal game is recorded from frame
  0 and written at game over and goes to initials entry, a watched replay records nothing, rewrites
  no file, adds no score and reaches the recorded digest.
* Save states on disk (feat2/frontend-rest): `PracticeAcrossRunsTests` (EpicPinballTests, needs the
  user's data and Metal): run 1 plays EP1 600 frames, saves slot 1 (file written), plays 900 more;
  run 2 (a new engine, presentation and controller, the file the only link) plays 77 other frames,
  loads slot 1 from disk: frame 600 and the saved digest; the same 900 inputs then give run 1's final
  digest and scores; it saves slot 2, and run 3 loads slot 2 to run 1's end digest. The same on EP10
  with a switch to enhanced physics between the last frame and the save. Neither run adds
  statistics or high scores. `ReplayResumeTests` (synthetic engine, both physics): a recording cut
  with `snapshot` and resumed after a restore equals the continuous one (inputs, events, digest).
  `PracticeStateFileTests`: round trip, missing, damaged (moved to `.bad`), bad replay bytes, frame
  mismatch, newer version, another table's file, clear. Across processes (window):
  `EPIC_PINBALL_TEST_STATES=300,600 --practice --autopilot --table 1 --exit-after 14 --support-dir D`
  saved slot 1 at frame 300 (digest 52d6dfe0b236e23b, an 855-byte file), then a new process
  `EPIC_PINBALL_TEST_LOAD_STATE=1 --practice --table 1 --exit-after 6 --support-dir D` printed
  `loaded slot 1 from disk -> frame 300 digest 52d6dfe0b236e23b (equals the saved digest)`.
* `ReplayTests.testSaveRestoreContinuesIdentically`: EP1, EP8, EP10 x direct and lifted rules x
  classic and enhanced: save at frame 700, play 1500 (enhanced 900) frames, play 400 other frames,
  restore, play the same inputs again: the presentation (scores, ball, lamp states, sound samples,
  message bytes, game over) is identical frame by frame and the final digest equal.
  `testSaveRestoreOnSyntheticEngine` does the same on the synthetic fixture (no game data).
* **Across processes** (`--autoplay 30000 --physics P --record-replay F` in one process,
  `--play-replay F` in another, so Swift's hash seed differs): all 13 tables, classic and enhanced,
  direct rules: all 26 replays `matches: true`, every game to game over (classic 1322-5202 frames,
  enhanced 1020-8852 frames; files 494-1398 bytes). Lifted rules (`EPIC_PINBALL_RULES=lifted` for
  recording; playback picks the recorded backend): EP1, EP8, EP10, EP13, both physics, all match.
* **App**: a direct start with `--autopilot --balls 1` reached game over, wrote `EP1-last` and
  `EP1-hs-...` (the high-score entry links to it), the game-over panel showed Save Replay / Watch
  Replay; `--play-replay` on the app's file matched; `--watch` at 4x (`EPIC_PINBALL_TEST_REPLAY_SPEED`)
  finished with "reached the recorded final state exactly" and added no high score; `--practice
  --autopilot` with `EPIC_PINBALL_TEST_STATES=300,600` saved at frame 300, restored at 600 back to
  frame 300 with the same digest, and wrote no replay or score. Window captures (`--window-capture`
  also writes `-hud.png` for the banner) and a launcher `--ui-snapshot` (watch buttons, Watch last
  game, Saved replays, Practice) were checked by eye. The test hooks press K / L and 1 / 2 / 4
  through `GameController.keyDown` (bindings -> command). An enhanced replay at 4x in the debug build
  runs slower than 4x (about 137 frames/s with drawing); it plays correctly, just slower. **Release build**
  (2026-10-01, M1, 60 Hz window, `--watch F --exit-after S` with `EPIC_PINBALL_TEST_REPLAY_SPEED=4`): a classic EP1
  replay (3,352 frames) ran 1,921 engine frames in 8.01 s = 240 frames/s (4 x 59.94), simulation 0.21 ms per display
  frame on average (0.68 max); an enhanced EP10 replay (1,853 frames) finished in under 8 s and "reached the recorded
  final state exactly", 240 frames/s by the performance overlay, 0.69 ms per display frame (1.62 max); the same
  enhanced replay with xBRZ, lighting, high refresh and `--rotate 270`: 1,434 frames in 6.00 s (239/s), 0.71 ms (1.73
  max). So 4x is real time in a release build for both physics models, with the simulation using under 5 % of a
  60 Hz frame. Not tested
  by running: clicks on the REPLAY bar and the launcher buttons, a physical keyboard, game
  controllers.

## 6. Limits

* Enhanced-physics replays are exact on the platform they were recorded on; across architectures or
  OS updates they are reported, not guaranteed (section 1).
* A replay recorded with other files (another EXE, a re-import that changes engine.json) or another
  `engineVersion` is played anyway and the difference is reported.
* A practice state from disk is re-simulated from the power-on state: loading costs the frames
  played up to it (about 3,000 frames/s in a debug build, so a 10-minute game is some seconds; a
  release build is much faster) and runs on the main thread. Enhanced-physics states load exactly on
  the platform they were saved on (as replays); elsewhere the digest check reports it. A state saved
  in a practice game that was not recorded from its first frame (no rules) stays in memory only.
* The renderer's display-rate interpolation and the camera easing are restored only as far as the
  saved camera; the first frame after a restore may ease.
* `swift run EpicPinball --autoplay N --physics enhanced` without `--record-replay` keeps its old
  behaviour (model installed before the start), so its numbers can differ slightly from a recorded
  run of the same table.
