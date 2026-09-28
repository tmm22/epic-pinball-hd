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
| [rendering.md](rendering.md) | Enhanced rendering: smooth / xBRZ / CRT filters in Metal, HD asset packs (`tools/hdpack/make_pack.py`), dynamic lighting, high-refresh interpolation, full-table view, GPU timings |

## What is done

| Area | State | Evidence (2026-09-28, integration run) |
|---|---|---|
| Classic parity | unchanged | `run_suite.py --modes physics,rules`: **830/830 with `EPIC_PINBALL_RULES=direct` and 830/830 with `lifted`**; `swift test` includes the classic byte-identical render goldens |
| Importer | done | the app imports the 1995 CD image in about 2 s (debug build); `PinballImportTests`: all 4,133 files equal the Python outputs; the library has no rules.json (`ImportOptions(rules: .none)`) |
| Rules from the EXE | done, default | direct and lifted agree on all 830 suite runs; every game below reports `rulesBackend: direct` from a Swift-imported library |
| Front end | done | first launch: `--launcher --import-from CD.iso` into an empty support dir ends on the picker with 13 named tables; picker -> game with enhanced settings from settings.json; a 1-ball classic game reached game over, initials typed through the key path, `highscores.json` written |
| Enhanced physics | done (classic-feel preset in the app) | autoplay from the imported library, packaged release binary: **all 13 tables reach game over with enhanced physics** (and with classic), 0 rule faults, 0 loop-guard trips |
| Enhanced rendering | done | window runs report `render: filter xbrz, hd pack active, lighting subtle, interpolate true` with a 4x pack made from the imported library; crt + full table and smooth + enhanced physics also run; GPU 4.2 ms mean at 3840x2160 worst case (rendering.md) |
| Packaging | done | `tools/package_app.sh`: ad-hoc signed .app + zip, 5 dylibs embedded, no game data; runtime check imports the CD with the packaged binary **inside a sandbox that hides extracted/, original/, the build trees and Python**, plays table 1 (classic) and 10 (enhanced) to game over and renders an xbrz + lighting snapshot |
| Tests | pass | `swift test`: 229 tests, 0 failures, 4 opt-in skips (perf, snapshots, live audio, library writer), including the 27 `EpicPinballTests` |

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
```

Settings (`GameSettings`, shared by all tracks; Settings panel or `settings.json` in the support
dir): physics classic / enhanced, upscale filter nearest / smooth / xbrz / crt, HD pack, dynamic
lighting, high refresh, full-table view, volumes. The defaults are the classic game.

## Known gaps

* **Not observed on a real screen in this session.** The display was asleep and the session locked
  during integration, so window runs drew from a 60 Hz timer instead of the display link (the smoke
  test says so) and were checked through captured frames. Not verified: 120 Hz on a ProMotion display
  (only a 60 Hz display was available), full-screen switching, the settings panel's appearance, and
  game controllers and haptics with real hardware (the GameController code compiles and runs with no
  controller attached; key bindings, not controllers, have unit tests).
* **HD packs need Python.** `tools/hdpack/make_pack.py` generates them; there is no "Generate HD
  pack" button in the app yet (it would need a Swift port of the generator, or a call into it).
* **Settings are simpler than the renderer and physics.** GameSettings has on/off lighting (subtle;
  vivid only through `--lighting vivid` / `--render`), no scaling choice (auto: integer for nearest,
  fill otherwise), and only the classic-feel physics preset (the `modern` preset is reachable only
  from code and tests).
* Rendering (rendering.md): flippers are cross-faded between the game's frames, not rotated; EP9-13
  strip dots are round only with an HD pack; the xBRZ shader and generator are an own implementation
  of the published (GPL-3) xBRZ rules, so check this against the project's licence plans.
* Physics (physics.md): the renderer draws the ball from the integer fields (1/128 px), not
  `EnhancedPhysics.ballCentre`; modern-preset flipper shots on EP11-13 are much stronger than the
  original's; EP12 has a lane the rules close with a gate while the ball is inside (the classic ball
  gets trapped there too).
* Rules: EP12 can add 2,258,632,704 points from sensor C3. This is the original's own `loop`-with-CX=0
  bug (cs:2883), reproduced exactly. EP3/EP5 show messages rarely in long games; only EP1's messages
  are checked frame by frame against the original.
* Importer: GOG editions are found by DOS file names only (no GOG release was available to test).
* The app is ad-hoc signed, not notarized (right-click > Open after downloading).
* Classic-port limitations (message effects, attract mode, etc.) are listed in app/README.md.
