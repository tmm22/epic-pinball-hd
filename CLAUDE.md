# Epic Pinball HD: notes for Claude

A native macOS reimplementation of the DOS game *Epic Pinball* (13 tables). It has
a bit-exact **classic** engine and an **enhanced** mode. The user owns the original
game. Read `README.md` and `NOTICE` for the legal position.

## Hard rules

- **No game data in git or in the app bundle, ever.** That includes art, music,
  sound, table data, text/strings, and numeric tables copied out of the EXEs. All
  game-derived data is loaded at runtime from the user's own files: `original/`
  and `extracted/` during development, and
  `~/Library/Application Support/EpicPinballHD/` in the app. HD packs
  (`extracted/hdpacks/`) are made from the user's data and stay local.
  `.gitignore` covers `*.iso`, `original/`, `extracted/`, `scratch/` and `build/`.
  Check `git status` before committing.
- **Classic mode must stay bit-exact** with the original code. After touching
  `PinballCore` (`ClassicEngine`, `Rules/`, `Physics`), run the parity suite and
  keep it at **830/830**:
  `.venv/bin/python tools/emu/run_suite.py --modes physics,rules`.
  Full mode is 413/415; the 2 misses are known EP8 harness errors. Both rules
  backends (`EPIC_PINBALL_RULES=direct|lifted`) must pass.
- New artwork (icons, UI) must be original. Never recreate the game's
  characters, logos or table art.
- Docs describe formats, offsets and code behaviour. Do not paste the game's
  rule or manual text. Reference strings by EXE offset.
- Only fetch game files from the user's own copy. Never from download sites.

## Commands

```sh
cd app && swift build && swift test          # 229 tests; 4 opt-in skips (live audio, perf, ...)
swift run EpicPinball --table 1              # dev run; --library DIR, --physics enhanced,
                                             # --render/--filter, --snapshot out.png, --autoplay N,
                                             # --trace scenario.json, --headless-import CD.iso
tools/package_app.sh                         # build/EpicPinballHD.app + zip; sandboxed runtime check
.venv/bin/python tools/emu/diff_traces.py --table N [--mode physics|rules|full] -q
.venv/bin/python tools/emu/run_suite.py --modes physics,rules
```

- Toolchain: Swift 6.4 via swiftly (`.swift-version`). Xcode 26's 6.3.3 also works.
  After switching compilers, delete `app/.build`.
- Homebrew dependencies: `libopenmpt`, `pkgconf`. `dosbox-x` is optional and
  only used for checks against the running game.
- Python venv `.venv` (numpy, pillow, capstone, unicorn) is used for the tools
  only. The app needs no Python.
- `swift test` takes about 10 minutes. The live differential tests need the
  user's data and skip cleanly without it.

## Layout

- `app/Sources/PinballCore`: `ClassicEngine` (integer physics port),
  `Rules/` (rules runtime; `MiniX86` runs handlers straight from the EXE; direct
  backend is the default), `Enhanced/` (swept-collision physics),
  `Presentation/PresentationState.swift` and `Settings/GameSettings.swift`.
  Those last two are shared contracts: extend them additively only.
- `app/Sources/PinballRender`: Metal. Classic path is `encodeClassic`;
  `EnhancedPipeline`, `HDPack` and `Lighting` are the enhanced path. The shader
  source is compiled at runtime.
- `app/Sources/PinballAudio`: SFX/PSM playback (libopenmpt via `COpenMPT`).
  `app/Sources/PinballImport`: Swift importer (ISO 9660 + extraction pipeline),
  parity-tested against the Python tools. `app/Sources/EpicPinball`: AppKit app.
- `tools/`: Python RE tools (`epexe`, `extract`, `collision`, `sprites`, `rules`,
  `export_engine_data`, `disasm`). `tools/emu/` is the Unicorn harness that runs
  the user's original EXE; it is the ground truth. `tools/engine_overrides/`
  holds per-table verified constants (addresses and flags only).
- `docs/formats/` holds the original game's formats and engine (start at
  `README.md`). `docs/enhanced/` holds the enhanced-version design.

## How to work here

- The original machine code (via the harness) is ground truth. When the port and
  the original diverge, find the first differing step with `diff_traces.py`,
  read the disassembly (`tools/disasm.py`), and cite `EPn cs:ip` in code and
  docs.
- Mark reverse-engineering claims with a confidence level ([H]/[M]/[L]), and
  separate what was verified by running code from what was inferred statically.
- Add a differential scenario (`tools/emu/scenarios/EPn/`) for every physics or
  rules fix.
- The original game has real bugs: a push-out livelock, and an x<0 background
  save that corrupts its own code. The port reproduces behaviour up to that
  point, then recovers; the harness reports these as `ORIG_HANG`/`ORIG_CRASH`.
  Don't "fix" them in classic mode.
- License is GPL-3.0-or-later (partly because the xBRZ filter is a
  reimplementation of GPL-3 xBRZ). Bundled third-party licenses are copied into
  the app by `package_app.sh`. Keep `NOTICE` current when dependencies change.
