# Front end and packaging (enhanced version)

The AppKit/SwiftUI front end of `EpicPinball` (target `app/Sources/EpicPinball/`) and the release
packaging (`tools/package_app.sh`). Classic mode is untouched: the front end only chooses settings,
feeds input and presents frames; the headless `--trace`, `--snapshot` and `--autoplay` modes work
as before.

## Start-up

| How it is started | What opens |
|---|---|
| Finder / no arguments | the **launcher** (table picker), or the **import screen** if no game data is found |
| `--table N` (or `--exit-after`, `--window-capture`, `--demo`, `--autopilot`, the presentation flags, `--legacy-window`) | straight into table N, as in earlier builds (developer / smoke-test runs; settings are not saved) |
| `--launcher [--table N] [--autostart]` | the launcher with N preselected; `--autostart` presses Play (smoke test of the picker-to-game path) |
| `--import`, `--import-from P` | the import screen (with P: imports P at once, no file panel) |
| `--headless-import P [--library DIR]` | no window: imports P (.iso or folder) with the Swift importer, prints progress, exits |
| `--trace`, `--snapshot`, `--autoplay N` | headless, unchanged |

Data lookup (`GameLibrary.locate`, `TableCatalog.swift`):
1. `--data DIR` (the `extracted/` directory, contains `tables/EPn/`);
2. the imported library, `~/Library/Application Support/EpicPinballHD/Library` (`PinballImport.LibraryLocation`);
3. `$EPIC_PINBALL_DATA`;
4. outside a `.app` only: the developer `../extracted` candidates (`DataLocator`). Inside a packaged
   app this fallback is skipped, so a fresh install shows the import screen.

The user's original files (EPn.EXE, EPn.DAT, IDn.DAT, SFXn.PIN, SONGn.PSM) are looked for in
`--original DIR`, `$EPIC_PINBALL_ORIGINAL`, `<root>/original`, `<root>`, then `original/` next to
the root.

Headless modes and direct starts (`resolveDataRoot`, main.swift): `--data DIR`; `--library DIR`;
`$EPIC_PINBALL_DATA`; outside a `.app` only the developer `../extracted` candidates (so the
differential harness, which passes no `--data`, is unchanged); then the imported library. For
an explicit `--data` / `--library` and for the library, `--original` defaults to the original
folder next to the root (`<root>/original`), so rules, fonts, messages and audio all come from
the library; for the developer candidates the loaders keep their own order (harness traces unchanged).

`--support-dir DIR` replaces `~/Library/Application Support/EpicPinballHD` (settings, high scores,
library) for tests and screenshots, and turns off the window-frame memory in the user defaults (see
"Cabinet"); `--library DIR` replaces only the library location (import target and data root).

Other developer flags: `--rules direct|lifted` (the same as `EPIC_PINBALL_RULES`), `--physics
classic|enhanced`, `--filter nearest|smooth|xbrz|crt`, `--hd-pack`, `--lighting off|subtle|vivid`,
`--high-refresh`, `--full` (whole table), `--render SPEC` (the same as `EPIC_PINBALL_RENDER`). In a
direct start the render and physics flags go into the (unsaved) session settings, so they take the
same path as the Settings panel; in `--snapshot` they are applied on top of `EPIC_PINBALL_RENDER`.

## Launcher

`LauncherUI.swift`, `AppModel.swift`. A grid of the 13 tables (5 columns): preview = the table's own
table-select screen (`EPn.DAT`, ZSoft PCX decoded by `PCXImage`), else `tables/EPn/preview.png`,
cropped to the table art (`TableCatalog.tableArt`: the 320x200 screen has the art in columns
0-159 and an empty high-score box in the right half, the same on all 13 tables), shown portrait
(160x200, 1.2x taller with the VGA pixel shape); name = `IDn.DAT` (20 bytes, space padded, 0x1A
terminated), else "Table n". Both are read at
runtime from the user's files; nothing about the tables is in the app. A table whose runtime files
(`playfield_idx.npy`, `palette.json`, `engine.json`) are missing is greyed out. The side panel shows
the selected table's top 10, its statistics (below), players (1-4) and balls (3/5), and Play.

Keys: arrows move, Return / Space play, Cmd-, settings. Game controller: D-pad / left stick move,
A plays, Menu opens Settings.

## Settings

`SettingsUI.swift`, `Settings.swift`. Saved at once to
`~/Library/Application Support/EpicPinballHD/settings.json`:

```json
{ "version": 1, "game": { GameSettings }, "frontEnd": { FrontEndSettings } }
```

* `game` is the shared `PinballCore.GameSettings` (physics mode, upscale filter, HD pack, dynamic
  lighting and `lightingStrength` (subtle / vivid), `outputScaling` (auto / integer / fill), high
  refresh, full-table view, music / effects volume, `enhancedPreset` (classicFeel / modern),
  `audioInterpolation` (original / smooth), `displayRotation` in degrees, `scoreWindow`, `scoreWindowRotation`, and the
  enhanced renderer's options `crtScanlines` (0...1, default 0.75), `crtCurvature` (0...0.08, default
  0.025), `crtMask` (0...1, default 0.18), `roundDots`, `stripInFullTable`, `rotateFlippers` (all three
  default on); their defaults are `RenderSettings`' built-in values, so a file without them renders
  as before, and `RenderSettings(game)` clamps the CRT values to those ranges). `dynamicLighting` stays the on/off switch, so a file
  written before `lightingStrength` existed keeps its meaning (on = subtle); the panel shows the two
  as one Off / Subtle / Vivid choice (`GameSettings.lightingChoice`). Other tracks extend it, so the
  stored object is merged over the encoded defaults before decoding: a field added later keeps its
  default, and a stored value that no longer decodes is dropped field by field
  (`StoredSettings.mergeDecode`).
* `frontEnd` (`FrontEndSettings`): key bindings, controller on/off, haptics, start in full screen,
  pixel aspect (square / VGA), master volume, players, balls, last table, score strip shown,
  `pauseWhenInactive` (default on), `screenshotFolder` (empty = `~/Pictures/Epic Pinball HD`),
  `showPerfOverlay` (default off), `attractMode` (default on; attract.md). Lenient decoding with
  clamping.

Tabs: Game (physics, enhanced physics feel, players, balls, pause when inactive), Display in four
sections: Picture (filter, pixel shape, scaling, full table, strip, high refresh, dynamic lighting
off / subtle / vivid, HD pack, full screen, performance overlay), Enhanced rendering (round message
dots, score strip in the whole-table view, **Rotate flippers (high refresh)**, and CRT scanlines / curvature /
shadow mask sliders with a Reset each; they only change the enhanced path, the original picture is
untouched), Cabinet (picture rotation, score window and its rotation), Screenshots (folder); Audio (master, music, effects,
resampling), Controls (every binding, Set / Add by pressing a key; "Original keys"; controller and
haptics switches and the connected controllers; a note that 1-4 choose the practice save slot),
Library (paths, Import again, Show in Finder,
clear the table's scores, clear the table's statistics or all of them, clear the table's practice
save states, and **HD art packs**: what
is installed, scale 2x / 3x / 4x, all tables or the selected one, "Generate HD packs" with progress
and Cancel, run off the main thread by `AppModel.generateHDPacks` through
`PinballImport.HDPackMaker` into `<support dir>/HDPacks/EPn`; see rendering.md, "Without Python").

Applied live to a running table (`GameController.apply(settings:)`):
`renderer.settings = RenderSettings(game)` (filter, HD pack, lighting and its strength, scaling,
interpolation, the CRT parameters, round dots, strip in the full-table view, flipper rotation;
`$EPIC_PINBALL_RENDER` still overrides it, and also takes `scanlines=` and `mask=` now), `renderer.aspect`, `camera.showFullTable`,
`sim.enhancedConfig = .preset(enhancedPreset)` and `sim.physicsMode` (classic = the bit-exact
integer engine, enhanced = `EnhancedPhysics`), the presentation mode (enhanced physics draws the
ball at sub-pixel positions), the strip, audio volumes and resampling
(`AudioEngine.setInterpolation`: an `.interpolation` command through the lock-free queue; the mixer
switches effects and the loaded songs' libopenmpt filter from the next render block), the display
rate, bindings, controller options, pause when inactive, the screenshot folder and the performance
overlay. A direct start (`--table N` and the developer flags) sets the lighting strength from
`--lighting` and uses the defaults for scaling, preset, resampling and the enhanced-rendering
options, so it does not depend on the stored file. The in-game keys (Tab, F, A, E, Enter,
`-`/`=`, `[`/`]`) write to the same settings, so the panel and the file stay in step.

## Input

`Input.swift`.

* `GameAction`: every bindable action. Held actions (flippers, plunger, Space, the two nudges,
  scroll) become `FrameInput` bits each frame; the rest fire on key press (volume keys repeat).
* Defaults are the original's keys (keyboard_isr EP1 cs:314B, `docs/formats/engine.md` section 5):
  Left Shift / Left = left flipper; Right Shift / Right / `.` / X = right flipper; Ctrl (either) =
  plunger; Space = plunger in the lane, nudge elsewhere; Z / `,` = nudge A (vx +20); `/` = nudge B
  (vx -20); Up/Down scroll; Return strip; P pause; M music; S effects; R new game. Port keys: Tab full
  table, F filter, A aspect, E physics, `-`/`=`, `[`/`]` volumes, **Esc = menu**, F12 screenshot,
  F10 performance overlay. The two function keys never shadow a table key: the original reads no
  function key in play (keyboard_isr EP1 cs:314B; F1 only inside its quit prompt, engine.md section
  5) [H, from the documented key table; not re-disassembled for this change]. Game > Save
  Screenshot (Shift-Cmd-S) and View > Performance Overlay do the same from the menu bar (F-keys on
  a Mac keyboard need Fn unless set as standard function keys).
* A settings file from an older build lacks the new actions: they get their default keys only
  where the user has not bound those keys to something else (`KeyBindings.init(from:)`), so no key
  ever drives two actions after an update.
* Modifier keys are tracked per side from the device-dependent flag bits of `flagsChanged`
  (`KeyboardState`), so Left and Right Shift are separate keys and can be rebound like any other.
  The menu action can never be left without a key (Esc is restored).
* Game controllers (`GamepadInput`, GameController framework, polled once per display frame):
  L1/L2 and R1/R2 flip, A / D-pad down / right stick down hold the plunger, B = Space, left stick
  right / left = nudge A / B, right stick up scrolls, Menu opens the pause menu. Menus: D-pad, A, B.
  Haptics (optional): a short transient on flipper presses, a stronger one on nudges (CoreHaptics
  through `GCController.haptics`).
* Keyboard and controller input are merged into `sim.input`. The first game key or button takes
  over from `--autopilot`, as before.

## In-game menus and high scores

`GameOverlay.swift`, `HighScores.swift`. A SwiftUI overlay above the Metal view; keyboard and
controller input are routed to it by `GameController` (the Metal view keeps first responder), and
the mouse works on its buttons.

* **Esc**: pause menu (Resume, New Game, Settings…, Choose Table, Quit). The simulation and music
  pause; P is still the original's pause with the strip banner.
* **Settings during a game** (Cmd-, or the menu bar; `AppDelegate.openSettings`,
  `GameController.settingsWillOpen` / `settingsDidClose`): a running game pauses with the P pause
  (frozen, music paused, the original's pause sign in the strip) and **no** pause menu opens behind
  the sheet, whatever "Pause when inactive" says (the sheet taking the key window does not count as
  inactivity). Closing Settings returns to that paused game, with a "press P to continue" note; P
  (or Esc > Resume) continues. Opened from the pause menu (Esc > Settings…), closing returns to the
  pause menu. Over the initials entry or the game-over panel nothing else changes.
* **Pause when inactive** (default on): when the game window resigns key (another window takes
  focus; not the Settings sheet, above), the app is deactivated, or a game controller disconnects while
  controllers are enabled, held input is dropped (as before) and the pause menu opens
  (`GameController.pauseForInactivity`). Nothing happens over a menu, during initials entry, after
  game over or in the P pause. Off: only the input is released, as in earlier builds. Smoke tests
  (`--exit-after`) do not auto-pause, so a focus change cannot stop an unattended run, unless
  `EPIC_PINBALL_TEST_AUTOPAUSE=1` is set.
* **Game over** (the rules' `PresentationState.gameOver`): for each player whose score makes the
  table's top 10, in player order, the **initials entry**, in the original's style: three letters,
  flippers or Up/Down step through `A-Z 0-9 . space`, plunger / Space / Return takes the letter,
  Delete steps back, typing a letter sets it directly, Esc skips. Then the game-over panel with the
  final scores and the top 10 (new entries highlighted), New Game / Choose Table / Settings / Quit.
* Storage: `~/Library/Application Support/EpicPinballHD/highscores.json`,
  `{"version":1,"tables":{"1":[{"initials","score","date","players","player","physics"}]}}`. Top 10
  per table, higher score first; a tie does not pass an existing entry; score 0 never qualifies. A
  damaged file is moved to `highscores.json.bad` rather than overwritten.

## Statistics

`Stats.swift`. Per table and physics mode, in `stats.json` in the support directory:

```json
{ "version": 1, "tables": { "1": { "classic": { "games", "abandoned", "balls", "totalScore",
  "scores", "bestScore", "playSeconds" }, "enhanced": { ... } } } }
```

* `GameStatsTracker` follows the rules' per-frame `PresentationState` (only with table rules; a
  physics-only run records nothing). A game starts at its first running frame and ends at the
  `gameOver` frame, or when it is left early (New Game, Choose Table, Quit, closing the window).
* `games`: games that reached game over plus games left early with a non-zero score (`abandoned`
  counts the latter); a game left at 0 points adds only its play time. `balls`: distinct (player,
  round) pairs reported during the game, rounds above balls-per-game excluded (the round counter
  passes the last ball as the game ends), so an extra ball on the same round is not counted again.
  `totalScore` / `scores`: every player's final score (a 2-player game adds two), average =
  total / scores; `bestScore` the highest of them. `playSeconds`: original frames run while the game
  was in progress (paused and menu time excluded), at the table's frame rate, credited to the
  physics mode of each frame; the game itself goes to the mode at its end (as in the high scores).
* A damaged file is moved to `stats.json.bad`; fields decode leniently.
* Statistics are for human play. The rule is one predicate, `GameController.recordsStatistics`
  (`countsForStatistics(recordsResults:autopilotPlayed:automatedRun:)`, next to `recordsResults`):
  a game counts when `recordsResults` holds (a normal game: not practice, not a watched replay, not
  attract mode), the auto-player (`--autopilot`) ran **no** frame of it (a game key takes over from
  the auto-player, but that game stays uncounted; the next one counts), and the run is not a smoke
  test (`--exit-after`, or any `EPIC_PINBALL_TEST_*` hook in the environment). A game started
  directly with `--table N` and played by hand counts like a launcher game. Headless runs
  (`--autoplay`, `--trace`, `--snapshot`, `--play-replay`, `--ui-snapshot`) have no statistics store
  at all. A normal game turned into practice from the pause menu is closed as an abandoned game
  first. The predicate only gates the statistics: high scores and replays still follow
  `recordsResults` (the smoke tests type initials through `EPIC_PINBALL_TEST_INITIALS`).
* The launcher's side panel shows Games, Balls, Best, Average and Play time, one column per mode
  played; Settings > Library clears the selected table's statistics or all of them.

## Screenshots and performance overlay

* The screenshot action (F12, Shift-Cmd-S) works in play and over the pause / game-over menus. The
  next output frame is copied from the drawable (the view leaves framebuffer-only mode for that
  frame), written off the main thread by `PNGWriter` (sRGB PNG, drawable size, the same writer and
  BGRA read-back as `--window-capture`), to `<folder>/<table name> YYYY-MM-DD at HH.MM.SS.png`
  (a number is added if that exists). The SwiftUI menus are not in the drawable, so they are not in
  the picture. A capsule at the bottom confirms it for 2.5 s (`HUDModel`, a click-through hosting
  view above the menus).
* Performance overlay (Settings > Display, F10, View menu; off by default): top left, refreshed
  every 0.5 s (`PerfMeter`): display frames per second, CPU time of `GameSimulation.advance` per
  display frame (mean and max, with the number of game frames run), and for the newest flipper key
  press the time from the key event's timestamp to the end of the first `advance` that sampled the
  flipper bit ("to sim"), and to that frame's `CAMetalDrawable.presentedTime` ("to screen"; n/a when
  the system reports 0, i.e. the frame was not shown, as for a window that is not on screen).
  Keyboard only: controller buttons are polled once per display frame and have no event time.

## Display

* Window: resizable, full screen (View > Enter Full Screen, Ctrl-Cmd-F; "Start in full screen"),
  the cursor hides while playing. Retina: the drawable tracks backing pixels
  (`autoResizeDrawable`), the renderer letterboxes and scales.
* Refresh rate: 60 Hz by default; with **High refresh** the view asks for the screen's maximum
  (`NSScreen.maximumFramesPerSecond`, 120 on ProMotion) and hands the renderer
  `MotionInterpolation(simulation:)` every display frame (alpha = accumulator / frame period, the
  last two ball positions, the frame counter; camera easing only with the original camera). The
  simulation still runs whole 59.94 Hz frames from wall-clock time (`GameSimulation.advance`), so
  classic physics stays bit-exact at any display rate.

### Cabinet: rotated monitor, score window

`Cabinet.swift`; the rotation itself is the renderer's (rendering.md "Display rotation").

* **Rotate picture** (`GameSettings.displayRotation`: none, 90 clockwise, 180, 270; `--rotate D`): for a monitor
  mounted on its side. 90 = the picture's top at the screen's right-hand edge (a monitor turned anticlockwise).
  The picture and the SwiftUI layers over it turn; keys and controllers are unchanged. With the whole-table view
  and 90 / 270 the table fills a portrait monitor. Leave it at none when macOS already rotates that display.
* **Overlays turn with the picture** (`OverlayRotation.swift`): the pause menu, initials entry, game-over panel,
  the practice / REPLAY banner and the status HUD (screenshot toast, performance overlay) are laid out upright in
  a frame of the swapped size and turned clockwise about the window's centre (`CabinetRotated`, a SwiftUI
  `rotationEffect`; `OverlayTransform` is the same mapping in points, the clockwise convention of
  `DisplayTransform`). Because the turn is a SwiftUI transform, mouse clicks land on the turned buttons; keyboard
  and controller input go through the controller as before. `GameController.apply` sets the rotation
  (`OverlayOrientation`) from the render settings, so a change in Settings turns them at once. With `.none` the
  views are exactly as before (no GeometryReader, no transform). `--ui-snapshot P --ui-screen pause|initials|gameover
  --rotate D` draws a turned overlay screen.
* **Score display in its own window** (`GameSettings.scoreWindow`; `--score-window` for a direct start): while a
  table with the classic presentation runs, `ScoreWindowController` opens a second window ("Epic Pinball HD -
  Score") whose Metal view draws only the display strip (`PinballRenderer.encodeStrip`, all strip rows) with the
  current filter, letterboxed in backing pixels. **Rotate score window** (`GameSettings.scoreWindowRotation`,
  `--score-rotate D`) turns it on its own, since the backglass screen may be mounted differently from the
  playfield's; the playfield rotation does not apply to it. A score window opened with 90 / 270 and no remembered
  frame starts tall (strip rows x 3 by 960 points). It has its own display link (60 Hz) and can be
  moved to another display (a backglass screen) and made full screen there. The main window then shows the
  playfield only: `GameController.apply` hides the strip there (the original's strip-hidden layout, 240 window
  rows and its camera limit, the same as Enter), whatever "Score strip visible" says. Keys typed while the score
  window is key still play (its view forwards them like the main view), and input is released when either window
  loses focus. Closing the score window turns the option off; it closes by itself when the game ends.
* **Remembered placement**: both windows use AppKit frame autosave in the user defaults
  (`EpicPinballHD.ScoreWindow`, `EpicPinballHD.MainWindow`; the saved frame includes the screen layout, and a
  frame on a display that is no longer attached is moved onto a visible one). The main window only starts
  remembering its frame once the score window has been used, so ordinary and smoke-test windows keep their
  centred 960x720 default. Whether the score window was in full screen is remembered too
  (`EpicPinballHD.ScoreWindow.fullScreen`). A `--support-dir` run (tests, smoke runs) neither reads nor writes
  any of these keys (`AppPaths.remembersWindows`), so it cannot change the user's saved window placement.
* Verification hooks: `--score-snapshot P [--score-size WxH] [--score-rotate D]` (headless: the strip as the score
  window draws it; turned without `--score-size`, e.g. 58x640 for EP10 at `--scale 2 --score-rotate 270`);
  the window smoke test (`--exit-after S --window-capture P`) prints the score window's frame, screen and drawable
  and writes `P-score.png`.

Overlay and score-window rotation, verified by running code (2026-10-01, debug build, 60 Hz built-in display):
`CabinetRotationTests` checks the transform maths (bijection, centre fixed, pixel centres agree with
`DisplayTransform` for all four rotations, rectangles keep their size, 90 puts the overlay's top at the right-hand
edge) and **mouse hit testing in a real `NSHostingView`** in an offscreen window: for each rotation, synthetic
mouse-down / up events at the transformed centre and at an inner corner of a turned button trigger it, a click at the
button's upright position (90 / 180 / 270) does not. `--ui-snapshot ... --ui-screen gameover --rotate 90 / 270` and a
window run (`EPIC_PINBALL_TEST_MENU=1 --table 10 --filter xbrz --rotate 90 --score-window --score-rotate 90
--exit-after 4 --window-capture`) were looked at: the pause menu is turned with the table (its title at the right-hand
edge), the score window (160x778 points) shows the strip turned 90 degrees. The score window's rotation keeps its own
setting (`testScoreWindowRotationSetting`: an old settings.json without it decodes to none, 45 is dropped, the rest of
the file kept). A release-build `--watch` window run at 4x with `--rotate 270 --filter xbrz --lighting subtle
--high-refresh` and the performance overlay (F10 through the key path) captured the REPLAY bar and the performance
overlay turned with the picture (`-hud.png`, `-status.png`; looked at). Not verified: real mouse clicks by hand, a
physically rotated monitor. The REPLAY bar and the performance overlay both sit at the overlay's top-left corner and
overlap when both are shown (also unrotated; not changed here).

Verified by running code (2026-10-01, 60 Hz built-in Retina display, display awake): `--table 10 --score-window
--rotate 90 --exit-after 4 --window-capture` drew 229 frames; the main drawable (1920x1440) showed the 240-row
playfield turned clockwise with no strip, the score window was 960x119 points (1920x174 drawable) with the strip.
Frames written to the defaults were restored on the next run (a score window set to 800x150 at 100,50 and a main
window of 700x740 came back exactly). Settings decoding (`CabinetSettingsTests`): an old settings.json without the
fields keeps the defaults, a rotation of 45 is dropped field by field. Not verified: a real second display (only
the built-in one was attached), full screen of the score window on it, typing into the score window, closing it
by hand, and the panel's appearance.

## First launch: import

`ImportView` (LauncherUI.swift), `AppModel.runImport`, `ImporterHookup.swift`. Explains that the
user's own copy is needed, then *Choose CD image…* (NSOpenPanel, .iso) or *Choose game folder…*
(a folder with EP1.EXE…). The import runs off the main thread through the
`PinballImport.GameDataImporting` protocol (`validate`, then `importGame(from:to:progress:)` into
`AppPaths.libraryRoot`); progress and messages are shown, errors are shown with a retry. On
success the import-done screen (`ImportDonePanel`, ImportDone.swift) shows what was imported and
offers **HD art packs**: a "Make HD art packs now" box (ticked), a 2x / 3x / 4x choice (4x by
default) and one button, "Make HD packs and choose a table" (or "Choose a table" with the box
unticked: skipped). Making them runs `AppModel.generateHDPacks` for every imported table in the
background (`useWhenDone`: Display > Use HD art pack is switched on once at least one pack was made)
while the picker opens; a bar at the bottom of the picker (`HDPackProgressBar`) shows the progress
with Cancel and then the result. The same job is in Settings > Library. `--import-hd-packs S|skip`
answers the offer for smoke tests (`AppModel.importHDPacksAnswer`). An import without tables goes
straight to the picker.

`libraryImporter()` in `ImporterHookup.swift` is the one line that names the concrete importer:
`PinballImport.GameDataImporter(options: ImportOptions(rules: .none))` (pure Swift; CD image or
game folder; about 2 s for all 13 tables from the 1995 CD in a debug build). `rules: .none`: the
library never carries a lifted rules.json (the importer's `.automatic` would copy one from a
developer checkout), so a library is the same on every Mac and the rules always run from the EXE. A folder that already contains `tables/EPn/` (a
developer `extracted/` directory) is handled by `ExtractedFolderImporter`, which copies it and the
originals next to it into the library (staged, then moved into place). Developer fallback:
`--data ../extracted`.

Games started from the library get `originalDir = <library>/original` for the rules, the classic
presentation and the audio (`EngineAssets.makeEngine(..., originalDir:)` is given `--original` /
the library's original folder everywhere: window, snapshot, autoplay, trace; without `--original`
the loaders keep their own search order, so traces are unchanged). The rules then run from the
user's EXE (`RulesBackend.direct`, the default) whether or not the library has `rules.json`.

## Packaging

```sh
tools/package_app.sh [--bundle-id ID] [--version X.Y] [--no-zip] [--skip-build] [--original DIR] \
                     [--scratch-path DIR] [--no-run-check] [--lenient] [--iso FILE] [--keep-check DIR] \
                     [--hardened] [--sign IDENTITY] [--notarize PROFILE] [--entitlements FILE]
# -> build/EpicPinballHD.app, build/EpicPinballHD.zip

# distribution (Developer ID + notarization), see "Signing and notarization" below:
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=epic-notary \
    tools/package_app.sh --bundle-id org.example.EpicPinballHD --version 1.0
```

`--scratch-path` builds in a private directory (other work sharing `app/.build` is not disturbed).

1. `swift build -c release --arch arm64 --product EpicPinball`.
2. Bundle: `Contents/MacOS/EpicPinball`, `Info.plist` from `app/Resources/Info.plist` (bundle id
   `com.example.EpicPinballHD` by default, LSMinimumSystemVersion 14.0, high resolution, game
   controller keys), `PkgInfo`, the PinballRender resource bundle (the Metal shader source) and a
   copy of `Pinball.metal` in `Contents/Resources`.
3. Icon: `app/Resources/make_icon.swift` draws it with CoreGraphics (original artwork: a chrome
   ball over two flippers on a dark rounded square; no game art), `iconutil` makes `AppIcon.icns`.
4. Dylibs: every non-system dependency, found recursively from the binary with `otool -L`
   (libopenmpt, mpg123, ogg, vorbis, vorbisfile), is copied to `Contents/Frameworks`. Their ids
   become `@rpath/NAME`, references between them `@loader_path/NAME`, the executable's
   `@rpath/NAME` with an `@executable_path/../Frameworks` rpath; rpaths into Homebrew, the build tree or the Xcode toolchain
   are removed (left: `/usr/lib/swift @loader_path @executable_path/../Frameworks`). The script fails if any `otool -L` line still points at `/opt/homebrew`,
   `/usr/local` or the repository.
5. No game data: the script fails if the bundle contains any game-like file type (.exe, .dat, .pin,
   .psm, .iso, .npy, .pcx, .mus, .wav, .png, playfield / palette / engine / rules / sprites /
   collision files), or any table name read from the user's `original/IDn.DAT`.
6. Ad-hoc signature (`codesign --sign -`, dylibs first), `codesign --verify --strict`. This is the default
   and unchanged; the Developer ID / hardened variants are below.
7. Runtime check (`--no-run-check` skips it): the packaged binary runs with `DYLD_PRINT_LIBRARIES`
   and must load every non-system dylib from its own `Contents/Frameworks` (none from Homebrew or
   the repository). Under the hardened runtime dyld ignores `DYLD_*` variables, so there the binary
   lists its own loaded images (`--list-dylibs`, `_dyld_get_image_name`) and all embedded dylibs must
   appear. Then, **as on a Mac that never built the app and has no Python**: under
   `sandbox-exec` with `extracted/`, `.venv`, `app/.build`, the release build dir (and `original/`
   when a CD image is used) unreadable and `python` not executable, and with the build tree's
   resource bundle renamed away, the packaged binary
   * imports the CD image (`--iso`, default the first `*.iso` in the repository root; else
     `original/`) into a fresh `--support-dir` with `--headless-import`;
   * checks that the library has no `rules.json`;
   * plays table 1 (classic physics) and table 10 (enhanced physics) to game over with `--autoplay`,
     requiring `gameOver` and `rulesBackend: direct` in the report;
   * renders an xbrz + lighting `--snapshot` of table 1 from that library, with no
     "EXE not found" warning;
   * makes table 1's 4x HD pack with `--make-hd-pack 1 --scale 4 --verify-hd-pack` (the Swift
     generator; Python is not executable in the sandbox) into `<support>/HDPacks/EP1` and renders a
     `--filter smooth --hd-pack` snapshot with it, requiring "hd pack on" and no HD pack warning.
   A failure stops the script before the zip (`--lenient`: warning only). `--keep-check DIR` keeps
   the logs, reports and snapshot. Paths are physical (`pwd -P`) because dyld reports resolved paths.
8. With `NOTARY_PROFILE` / `--notarize`: notarization and stapling (below).
9. `ditto -c -k --keepParent` to the zip (of the stapled app when notarized).

Dylibs: verified, the packaged binary loads libopenmpt, mpg123, ogg, vorbis and vorbisfile from
`Contents/Frameworks` and nothing from Homebrew (runtime check, and `DYLD_PRINT_LIBRARIES` during a
game with music).

**Shader lookup (fixed).** SwiftPM's generated `Bundle.module` for PinballRender only looks at
`<App>.app/EpicPinball_PinballRender.bundle` (the bundle root, which codesign refuses to seal) and at
the absolute build path, and calls `fatalError` when neither exists. `PinballRenderer.shaderSource()`
therefore looks in the `.app`'s own `Contents/Resources` first (`Pinball.metal`, then the copied
resource bundle) whenever it runs from a `.app`, and uses `Bundle.module` only for `swift run` and
the tests. The runtime check above covers it (resource bundle renamed away).

Checked on 2026-09-28 (`tools/package_app.sh --scratch-path /tmp/ep-rel`): 5 dylibs from
Contents/Frameworks; the sandboxed import of the 1995 CD image gave 13 tables; table 1 classic
reached game over (5,950,000), table 10 enhanced reached game over (13,220,000), both with rules
direct; the xbrz + lighting snapshot was 960x720. A negative control (the same sandbox,
`--data extracted`) fails with "missing .../extracted/tables/EP1/playfield_idx.npy", so the
sandbox really hides the developer data.

### Signing and notarization

All optional; without these variables or flags the script signs ad-hoc exactly as before.

| Input | Effect |
|---|---|
| `DEVELOPER_ID="Developer ID Application: Name (TEAMID)"` or `--sign ID` (name or SHA-1 from `security find-identity -v -p codesigning`) | dylibs, then the app, signed with that identity, `--options runtime` (hardened runtime), `--timestamp` (secure timestamp) and `app/Resources/EpicPinballHD.entitlements`. Checked: hardened flag on the executable and every dylib, no `get-task-allow`, one Team ID on the app and every dylib (library validation), a timestamp. |
| `HARDENED=1` or `--hardened` (or `--sign -`) | the same hardened signing with the ad-hoc identity, to check the hardened path on a Mac without a certificate. Not for distribution. |
| `NOTARY_PROFILE=P` or `--notarize P` (needs a Developer ID) | after the runtime check: zip, `xcrun notarytool submit --keychain-profile P --wait`, stop unless the status is `Accepted` (the notary log is fetched to `build/notarize-log.json`), `xcrun stapler staple` + `stapler validate`, `spctl --assess --type execute`, then the final zip of the stapled app. |
| `--entitlements FILE` | another entitlements file. |

**Entitlements** (`app/Resources/EpicPinballHD.entitlements`): deliberately empty, because nothing the app does at
run time needs a hardened-runtime exception. Checked against what it does:

* runtime Metal shader compilation (`makeLibrary(source:)`): compiled by the system's out-of-process Metal
  compiler; the app maps no writable+executable memory, so no `allow-jit` / `allow-unsigned-executable-memory`.
  Verified: the hardened binary renders the xbrz + lighting snapshot and runs windowed with xbrz.
* libopenmpt and the four libraries it pulls in: embedded and signed with the app's identity, so library
  validation passes without `disable-library-validation`. Verified the other way round: hardened + ad-hoc fails
  to start with "mapping process and mapped file (non-platform) have different Team IDs", because ad-hoc signatures
  have no Team ID. The ad-hoc hardened check therefore (and only it) signs with a temporary copy of the file plus
  `com.apple.security.cs.disable-library-validation`.
* files: the app is not sandboxed, so reading the user-chosen CD image or folder and writing
  `~/Library/Application Support/EpicPinballHD` need no entitlement (an NSOpenPanel choice in Downloads or on a
  removable volume is the user's own grant). Going sandboxed would need `app-sandbox`,
  `files.user-selected.read-only` and a container-aware support path; not done.
* game controllers (GameController framework) and audio output: no entitlement outside the sandbox. Verified:
  music plays (libopenmpt) and the controller service starts in the hardened binary; no controller was attached.

Checked on 2026-10-01 (`tools/package_app.sh --scratch-path /tmp/ep-rel-cabdist --hardened`): the hardened
ad-hoc app passes the whole runtime check (5 dylibs from Contents/Frameworks via `--list-dylibs`, sandboxed import
of the CD, tables 1 classic and 10 enhanced to game over, the xbrz + lighting snapshot); the hardened binary also
ran a window session (`--score-window --rotate 270 --filter xbrz`, music playing) and the launcher. The default
ad-hoc run still passes unchanged. The Developer ID and notarization branch was run end to end with stand-in
`security` / `codesign` / `xcrun` / `spctl` commands (an identity in the keychain, `--timestamp` and a Team ID
faked, `notarytool` answering `Accepted`), which checks the script's flow and parsing only, not Apple's side.
No certificate or notary credentials were available, so nothing has been notarized.

**Remaining steps for a notarized release** (on a Mac with an Apple Developer Program membership):

1. Create a *Developer ID Application* certificate (Xcode > Settings > Accounts > Manage Certificates, or the
   developer website) and check it is in the login keychain: `security find-identity -v -p codesigning`.
2. Store notary credentials once, with an app-specific password from appleid.apple.com (or an App Store Connect
   API key with `--key/--key-id/--issuer`):
   `xcrun notarytool store-credentials epic-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID --password APP-SPECIFIC-PASSWORD`.
3. Run with a bundle id you own:
   `DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=epic-notary tools/package_app.sh --bundle-id org.example.EpicPinballHD --version 1.0`.
   The script signs, runs the runtime check (the hardened, Developer-ID-signed binary), submits, staples and
   zips. A rejection prints the status and writes `build/notarize-log.json`.
4. Check the result on another Mac (or after `xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" EpicPinballHD.app`):
   it should open with a double-click, and `spctl -a -vvv -t exec EpicPinballHD.app` should say
   `source=Notarized Developer ID`.

Until then the published zip is ad-hoc signed: after downloading, Gatekeeper wants right-click > Open (or
System Settings > Privacy & Security > Open Anyway).

## Verification hooks

* `--attract` starts a table in attract mode (window) or runs the demo before a `--snapshot`;
  `--attract-delay S` sets the idle time (default 15 s) and enables idle attract in `--exit-after`
  smoke tests, e.g. `--launcher --attract-delay 2 --exit-after 12 --window-capture OUT.png` (attract.md).
* `--ui-snapshot OUT.png --ui-screen launcher|launcher-hdpacks|import|import-done|settings[-game|-display|-audio|-controls|-library]|pause|initials|gameover [--size WxH]`
  renders a front-end screen in an offscreen window (the overlays with sample scores over the
  table's preview) and exits. `import-done` is the end of an import with the HD pack offer,
  `launcher-hdpacks` the picker with a sample generation progress bar. For the Settings screens
  `--size 620xH` sets the sheet height (the default sheet is 620x520), so a tall size shows every
  row of a tab at once. `settings-library` opens the Library tab; with
  `EPIC_PINBALL_UI_HDPACK_SCALE=S` it first starts "Generate HD packs" for all tables, so the
  snapshot shows the job running.
* `--make-hd-pack N|all [--scale S] [--hd-method xbrz|nearest] [--verify-hd-pack] [--hd-pack-out DIR]`
  makes HD packs without a window (default: 4x into `<support dir>/HDPacks`) and prints the time per
  table and, with `--verify-hd-pack`, the alignment check.
* `--launcher --exit-after S --window-capture OUT.png` captures the launcher window;
  `--launcher --table N --autostart --exit-after S` goes through the picker into a game.
* The smoke-test output adds `rules: direct|lifted|none (why)`, `render: filter …, hd pack
  active|requested, none found|off, lighting …, interpolate …, scaling …, full table …`, the overlay
  state, the table's high-score count, `stats: table N: <mode> games … balls … best … time …`, the
  performance overlay's lines, `focus: app active …, window key …`, the audio resampling and, for
  enhanced physics, the preset. `--window-capture` also writes `<name>-status.png` when the status HUD shows
  something. `--ui-screen settings-game|display|audio|controls|library` opens Settings on that tab.
  `EPIC_PINBALL_TEST_SCREENSHOT=1` presses the screenshot key after the first frame;
  `EPIC_PINBALL_TEST_FLIPPER=1` taps the left flipper's first ordinary key every 0.5 s through
  `NSWindow.sendEvent` (latency check). When the main display is asleep or the session is locked (MTKView's
  display link does not fire then), `--exit-after` runs drive the same `draw(in:)` from a 60 Hz timer
  and say so;
  `EPIC_PINBALL_TEST_INITIALS=ABC` types those initials through the normal key path when the entry
  opens, e.g. `--table 1 --autopilot --balls 1 --mute --exit-after 60` plays a game to the end and
  records it.
* `EPIC_PINBALL_TEST_SETTINGS=OPEN,CLOSE` opens Settings through the Cmd-, menu action after OPEN
  seconds and closes it after CLOSE seconds, printing `test settings:` lines (paused, overlay, sheet).
* Replays and practice ([replays.md](replays.md)): `--watch FILE` (with `EPIC_PINBALL_TEST_REPLAY_SPEED=N`),
  `--practice` (with `EPIC_PINBALL_TEST_STATES=SAVE,LOAD`: save / restore at those engine frames, and
  `EPIC_PINBALL_TEST_LOAD_STATE=SLOT`: select SLOT and restore it at the first frame, i.e. from the
  slot's file of an earlier run),
  headless `--autoplay N --record-replay F` and `--play-replay F`. The smoke-test output adds a
  `session:` line (recording, replay frame, the end-of-replay check, the test save/restore digests);
  `--window-capture` also writes `-hud.png` (the PRACTICE / REPLAY banner) in those sessions.
  Tests: `ReplayFrontEndTests.swift`.
* Unit tests: `app/Tests/EpicPinballTests/FrontEndTests.swift` (settings merge / leniency / clamping,
  store persistence, bindings and modifier sides, high-score ranking / ties / capacity / damaged
  file, initials entry, PCX and ID decoding with synthetic files, library discovery, the folder
  importer, the importer choice, the preview crop, `--original`) and
  `testImportUsersCDImageIntoEmptySupportDir` (skipped without an `.iso` in the checkout): the
  user's CD through `makeImporter` into an empty support directory, then `GameLibrary.locate` finds
  it, the catalog has 13 available tables with names from IDn.DAT and 160x200 art, and tables 1, 8,
  10 load with their rules from `<library>/original`. They run in the package's `EpicPinballTests`
  target (`swift test --filter EpicPinballTests`). `HDPackFrontEndTests` (3 tests,
  synthetic table data) covers the `--make-hd-pack` options, the Library tab's job end to end (off
  the main thread, progress, the pack found by `HDPack.locate` through the `--support-dir` override
  and accepted by `HDPack.load` without warnings), cancellation and the no-library error.
* `SettingsUXTests.swift`: an old settings.json (no new fields, lighting on) decodes to subtle
  lighting, auto scaling, classic-feel preset, original resampling, pause when inactive on, overlay
  off, and the new actions get F12 / F10; new fields round-trip and bad values drop per field; the
  lighting choice keeps the Bool in step; default bindings have no key on two actions and the new
  keys avoid the original's; an old file with F12 already on a flipper leaves the screenshot action
  unbound; statistics tracking (balls, rounds past the last ball, two players, mode switch, abandoned
  games, overflow), store persistence / clearing / damaged file; screenshot file names; the
  performance meter. `MixerTests.testInterpolationSwitchesLive` and
  `EnhancedRenderTests.testLightingStrengthAndScalingMapping` cover the audio and render mapping.

Verified by running (2026-10-01, debug build, the user's extracted data, a throwaway
`--support-dir`): a 1-ball classic autopilot game on table 1 with `EPIC_PINBALL_TEST_SCREENSHOT=1`
wrote a 960x720 PNG to the configured folder, reached game over and wrote `stats.json` (1 game,
1 ball, best = the final score, 20.5 s of play; since feat2/frontend-rest such autopilot / smoke-test
games are no longer recorded, see Statistics); the HUD capture showed the overlay and the
confirmation. A launcher start of table 10 from a settings.json with enhanced + modern, smooth
filter, vivid lighting, fill scaling and smooth resampling reported `lighting vivid, scaling fill`,
`physics enhanced preset modern` and `resampling smooth`, and its screenshot filled the window
height. With `EPIC_PINBALL_TEST_AUTOPAUSE=1`, the app brought to the front and then Finder activated, the run ended with
`overlay pauseMenu` and the engine stopped at the switch. Synthetic flipper taps through
`NSWindow.sendEvent` measured 3.5-6 ms key to sim and 46 ms key to screen at 60 Hz (screen time is
n/a while the app is in the background: `presentedTime` is 0 there). Not verified: a real game
controller disconnecting (no controller attached; it calls the same `pauseForInactivity`), and F12
/ Shift-Cmd-S on a real keyboard (they call the same function as the hook).

Statistics rule, Settings pause, Display options, import offer, Settings layout (feat2/frontend-rest,
2026-10-01, debug build, the user's data, throwaway `--support-dir`s under /tmp):

* Tests (`app/Tests/EpicPinballTests/FrontEndRestTests.swift`): `StatisticsRuleTests` (the predicate's
  truth table; `EPIC_PINBALL_TEST_*` detection; on EP1 a game fed through `sim.input` is recorded,
  an `--autopilot` game and a game in a smoke-test run add nothing, not even play time),
  `DisplaySettingsTests` (an old settings.json gets every new Display field at the renderer's value;
  round trip, a mistyped field dropped, out-of-range CRT values clamped; `EPIC_PINBALL_RENDER` keys),
  `PracticeSlotAndSettingsPauseTests` (slot labels and keys; on EP1: Settings pauses a running game
  without the pause menu, a focus loss during the sheet opens none, closing leaves the game paused;
  from the pause menu it returns there).
* By running: a window `--autopilot --balls 1 --table 1` game without `--exit-after` (stopped after
  45 s) reached game over (it wrote `Replays/EP1-last.epreplay`) and wrote no `stats.json`.
  `EPIC_PINBALL_TEST_SETTINGS=2,4 EPIC_PINBALL_TEST_AUTOPAUSE=1 --autopilot --table 1 --exit-after 6`
  printed `opened, paused true, overlay none, sheet true` and `closed, paused true, overlay none,
  hud Paused: press P to continue` (the app was not frontmost in that session, so the sheet's
  focus change itself was not exercised; the unit test calls `pauseForInactivity` instead).
  Launcher starts (`--launcher --autostart`) from a settings.json with the CRT filter, scanlines 0,
  curvature 0.08, mask 1, whole table, strip in the whole table off and round dots off reported
  exactly those values in the `render:` line, and the capture showed the stronger curvature, the
  darker mask and no strip, against a run with the defaults. `--launcher --import-from CD.iso
  --import-hd-packs 4` into an empty support dir: picker, 13 tables, "Made 13 4x packs in 28.7 s;
  Display > Use HD art pack is on", `useHDPack: true` in settings.json; without the flag it stays on
  the import-done screen (`screen importer`), with `skip` it goes to the picker with no packs.
* UI snapshots of every Settings tab, at the sheet size and 620x1500, and of `import-done` /
  `launcher-hdpacks`, inspected by eye. Fixed: the Controls tab had no inset (its controller row,
  list and "Original keys" touched the tab box edge while the other tabs are grouped forms), and the
  import-done panel's checkbox and scale picker, and the progress bar, were drawn in the light
  appearance on the dark launcher (now forced to the dark scheme). The Display tab is now grouped in
  sections; it still scrolls at the default sheet size (as does Controls), nothing is clipped
  sideways. Not checked: the sheets in a real interactive session (mouse, a real Cmd-,).
