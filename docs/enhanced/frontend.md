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
| `--import` | the import screen |
| `--trace`, `--snapshot`, `--autoplay N` | headless, unchanged |

Data lookup (`GameLibrary.locate`, `TableCatalog.swift`):
1. `--data DIR` (the `extracted/` directory, contains `tables/EPn/`);
2. the imported library, `~/Library/Application Support/EpicPinballHD/Library` (`PinballImport.LibraryLocation`);
3. `$EPIC_PINBALL_DATA`;
4. outside a `.app` only: the developer `../extracted` candidates (`DataLocator`). Inside a packaged
   app this fallback is skipped, so a fresh install shows the import screen.

The user's original files (EPn.EXE, EPn.DAT, IDn.DAT, SFXn.PIN, SONGn.PSM) are looked for in
`--original DIR`, `$EPIC_PINBALL_ORIGINAL`, `<root>/original`, `<root>`, then `original/` next to
the root. Headless and direct starts keep the old order and use the library only when nothing else
is found.

`--support-dir DIR` replaces `~/Library/Application Support/EpicPinballHD` (settings, high scores,
library) for tests and screenshots.

## Launcher

`LauncherUI.swift`, `AppModel.swift`. A grid of the 13 tables: preview = the table's own
table-select screen (`EPn.DAT`, ZSoft PCX decoded by `PCXImage`), else `tables/EPn/preview.png`;
name = `IDn.DAT` (20 bytes, space padded, 0x1A terminated), else "Table n". Both are read at
runtime from the user's files; nothing about the tables is in the app. A table whose runtime files
(`playfield_idx.npy`, `palette.json`, `engine.json`) are missing is greyed out. The side panel shows
the selected table's top 10, players (1-4) and balls (3/5), and Play.

Keys: arrows move, Return / Space play, Cmd-, settings. Game controller: D-pad / left stick move,
A plays, Menu opens Settings.

## Settings

`SettingsUI.swift`, `Settings.swift`. Saved at once to
`~/Library/Application Support/EpicPinballHD/settings.json`:

```json
{ "version": 1, "game": { GameSettings }, "frontEnd": { FrontEndSettings } }
```

* `game` is the shared `PinballCore.GameSettings` (physics mode, upscale filter, HD pack, dynamic
  lighting, high refresh, full-table view, music / effects volume). Other tracks extend it, so the
  stored object is merged over the encoded defaults before decoding: a field added later keeps its
  default, and a stored value that no longer decodes is dropped field by field
  (`StoredSettings.mergeDecode`).
* `frontEnd` (`FrontEndSettings`): key bindings, controller on/off, haptics, start in full screen,
  pixel aspect (square / VGA), master volume, players, balls, last table, score strip shown. Lenient
  decoding with clamping.

Tabs: Game (physics, players, balls), Display (filter, pixel shape, full table, strip, high
refresh, dynamic lighting, HD pack, full screen), Audio (master, music, effects), Controls (every
binding, Set / Add by pressing a key; "Original keys"; controller and haptics switches and the
connected controllers), Library (paths, Import again, Show in Finder, clear the table's scores).

Applied live to a running table (`GameController.apply(settings:)`):
`renderer.settings = RenderSettings(game)` (filter, HD pack, lighting, interpolation;
`$EPIC_PINBALL_RENDER` still overrides it), `renderer.aspect`, `camera.showFullTable`,
`sim.physicsMode` (classic = the bit-exact integer engine, enhanced = `EnhancedPhysics`), the
presentation mode (enhanced physics draws the ball at sub-pixel positions), the strip, audio
volumes, the display rate, bindings and controller options. The in-game keys (Tab, F, A, E, Enter,
`-`/`=`, `[`/`]`) write to the same settings, so the panel and the file stay in step.

## Input

`Input.swift`.

* `GameAction`: every bindable action. Held actions (flippers, plunger, Space, the two nudges,
  scroll) become `FrameInput` bits each frame; the rest fire on key press (volume keys repeat).
* Defaults are the original's keys (keyboard_isr EP1 cs:314B, `docs/formats/engine.md` section 5):
  Left Shift / Left = left flipper; Right Shift / Right / `.` / X = right flipper; Ctrl (either) =
  plunger; Space = plunger in the lane, nudge elsewhere; Z / `,` = nudge A (vx +20); `/` = nudge B
  (vx -20); Up/Down scroll; Return strip; P pause; M music; S effects; R new game. Port keys: Tab full
  table, F filter, A aspect, E physics, `-`/`=`, `[`/`]` volumes, **Esc = menu**.
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
* **Game over** (the rules' `PresentationState.gameOver`): for each player whose score makes the
  table's top 10, in player order, the **initials entry**, in the original's style: three letters,
  flippers or Up/Down step through `A-Z 0-9 . space`, plunger / Space / Return takes the letter,
  Delete steps back, typing a letter sets it directly, Esc skips. Then the game-over panel with the
  final scores and the top 10 (new entries highlighted), New Game / Choose Table / Settings / Quit.
* Storage: `~/Library/Application Support/EpicPinballHD/highscores.json`,
  `{"version":1,"tables":{"1":[{"initials","score","date","players","player","physics"}]}}`. Top 10
  per table, higher score first; a tie does not pass an existing entry; score 0 never qualifies. A
  damaged file is moved to `highscores.json.bad` rather than overwritten.

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

## First launch: import

`ImportView` (LauncherUI.swift), `AppModel.runImport`, `ImporterHookup.swift`. Explains that the
user's own copy is needed, then *Choose CD image…* (NSOpenPanel, .iso) or *Choose game folder…*
(a folder with EP1.EXE…). The import runs off the main thread through the
`PinballImport.GameDataImporting` protocol (`validate`, then `importGame(from:to:progress:)` into
`AppPaths.libraryRoot`); progress and messages are shown, errors are shown with a retry, and on
success the picker opens with the new library.

`libraryImporter()` in `ImporterHookup.swift` is the one line that names the concrete importer. A
folder that already contains `tables/EPn/` (a developer `extracted/` directory) is handled by
`ExtractedFolderImporter`, which copies it and the originals next to it into the library (staged,
then moved into place). Developer fallback: `--data ../extracted`.

## Packaging

```sh
tools/package_app.sh [--bundle-id ID] [--version X.Y] [--no-zip] [--skip-build] [--original DIR]
# -> build/EpicPinballHD.app, build/EpicPinballHD.zip
```

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
   `@rpath/NAME` with an `@executable_path/../Frameworks` rpath; rpaths into Homebrew or the build tree
   are removed. The script fails if any `otool -L` line still points at `/opt/homebrew`,
   `/usr/local` or the repository.
5. No game data: the script fails if the bundle contains any game-like file type (.exe, .dat, .pin,
   .psm, .iso, .npy, .pcx, .mus, .wav, .png, playfield / palette / engine / rules / sprites /
   collision files), or any table name read from the user's `original/IDn.DAT`.
6. Ad-hoc signature (`codesign --sign -`, dylibs first), `codesign --verify --strict`, then
   `ditto -c -k --keepParent` to the zip.

The packaged app runs without Homebrew as far as dylibs are concerned (`DYLD_PRINT_LIBRARIES`
shows all five loaded from `Contents/Frameworks`). **Open issue:** the shader lookup. SwiftPM's
generated `Bundle.module` accessor for PinballRender looks only at `<App>.app/EpicPinball_PinballRender.bundle`
(the bundle root, which codesign refuses to seal: "unsealed contents present in the bundle root")
and at the absolute build path. On the build machine the build path exists; on another Mac it does
not, and `Bundle.module` calls `fatalError`. Fix (render track, `PinballRenderer.shaderSource()`):
look for `Bundle.main.url(forResource: "Pinball", withExtension: "metal")` (the copy the script puts in
`Contents/Resources`) or `Bundle.main.resourceURL/EpicPinball_PinballRender.bundle` before touching
`Bundle.module`.

The app is ad-hoc signed, not notarized: after downloading, Gatekeeper wants right-click > Open.

## Verification hooks

* `--ui-snapshot OUT.png --ui-screen launcher|import|settings|pause|initials|gameover [--size WxH]`
  renders a front-end screen in an offscreen window (the overlays with sample scores over the
  table's preview) and exits.
* `--launcher --exit-after S --window-capture OUT.png` captures the launcher window;
  `--launcher --table N --autostart --exit-after S` goes through the picker into a game.
* The smoke-test output adds the overlay state and the table's high-score count;
  `EPIC_PINBALL_TEST_INITIALS=ABC` types those initials through the normal key path when the entry
  opens, e.g. `--table 1 --autopilot --balls 1 --mute --exit-after 60` plays a game to the end and
  records it.
* Unit tests: `app/Tests/EpicPinballTests/FrontEndTests.swift` (settings merge / leniency / clamping,
  store persistence, bindings and modifier sides, high-score ranking / ties / capacity / damaged
  file, initials entry, PCX and ID decoding with synthetic files, library discovery, the folder
  importer). They need a `EpicPinballTests` test target in Package.swift.
