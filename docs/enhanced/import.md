# Importer (enhanced version): the user's CD or install -> the runtime library

`PinballImport` (`app/Sources/PinballImport/`) turns the user's own Epic Pinball files into
everything the app loads at runtime, in pure Swift (no Python at runtime). It reproduces the
Python extraction tools exactly: on the user's CD image every output file is byte-identical to
what `tools/extract.py`, `tools/collision.py`, `tools/sprites.py` and
`tools/export_engine_data.py` write into `extracted/` (see [Parity](#parity)).

Nothing game-derived is in the app or the repository. The library is written to a per-user
directory (default `~/Library/Application Support/EpicPinballHD/Library`,
`LibraryLocation.defaultRoot`) and contains only files read from, or computed from, the user's
own copy.

## API

```swift
import PinballImport

let importer = GameDataImporter()                        // GameDataImporting
let source = ImportSource.detect(url)                     // .isoImage for files, .directory for folders
let scan = try importer.scan(source)                      // where the game is, tables found / missing
let warnings = try importer.validate(source)              // quick check; throws if nothing importable
let lib = try importer.importGame(from: source, to: LibraryLocation.defaultRoot) { p in
    print(p.fraction, p.message)                          // called from any thread
}
// lib.root is a data root: pass it as --data / GameLibrary(dataRoot:), and
// LibraryLayout.originalDirectory(lib.root) as the original-files directory.
```

* `ImportOptions(rules:tables:)`: `rules` is `.automatic` (default: copy `rules.json` from the
  developer checkout's `extracted/` when it exists, else none), `.copy(from: dir)` or `.none`;
  `tables` restricts the import to some tables; `concurrency` (default: all cores).
* `LibraryLayout.load(root)` reads an existing library back (nil if it is missing or incomplete).
* `SourceScan` (from `scan`): `layout` (human-readable), `kind` (`iso`, `directory`,
  `directory-subfolder`, `disc-image-in-directory`), `gameFolder`, `discImage`, `volumeIdentifier`,
  `tables`, `missingTables`, `missingOptional`, `extraFiles`, `warnings`.
* Progress: 0-2 % reading the source, 2-15 % copying the original files, 15-95 % one step per
  finished table ("Table n: NAME"), then the manifests, 100 %.
* Errors are `ImportError` with a message that names the file or the missing piece. A table that
  fails is skipped with a warning; the import fails only if no table succeeds.

## Sources

Detection is by file names only (case-insensitive): the game folder is the folder with the most
of `EP1.EXE` ... `EP13.EXE` (the shallowest one on ties).

| Source | How it is read |
|---|---|
| ISO 9660 image (`.isoImage`) | `ISO9660Image`. The 1995 Complete Collection CD is a cooked 2048-byte image whose primary volume descriptor has system id `CD-RTOS CD-BRIDGE` (a CD-i Bridge / XA disc, volume `EPICPINCD21`); the XA system-use bytes after each name are ignored. Raw dumps are recognised by where `CD001` appears: 2352-byte sectors (Mode 1, or Mode 2 XA Form 1) and 2336-byte sectors. Only the primary volume descriptor (8.3 names, `;1` stripped) is used. Multi-extent files are rejected. |
| Folder with the files (`.directory`) | Installed DOS game (e.g. `C:\EPIC`), a mounted CD, or a copy of it: the files at the top level. |
| Folder with the files in a subfolder | Searched breadth first up to 6 levels (at most 50,000 entries, hidden and symlinked folders skipped). Covers installs where the game sits next to other files, e.g. a GOG DOSBox install (`dosbox*.conf`, `DOSBOX/`, game in a subfolder) and macOS app wrappers (`Epic Pinball.app/Contents/Resources/.../EPIC`). |
| Folder with a disc image | Files ending in `.iso`, `.gog`, `.bin`, `.img` or `.cdr` over 1 MB inside the folder tree are opened as ISO 9660 images (GOG ships some DOS games as `game.gog` = a raw BIN image, with a `game.ins` cue sheet). Used when it has more tables than any plain folder. A disc-image file passed as `.directory` is treated as `.isoImage`. |

GOG: the GOG edition could not be inspected (it cannot be downloaded here), so its layout is not
assumed. Any GOG layout whose files keep the DOS names (`EPn.EXE`, `EPn.DAT`, `IDn.DAT`,
`SFXn.PIN`, `SONGn.PSM`) in a folder up to 6 levels deep, or inside a `.gog`/`.iso`/`.bin` disc
image, is found. Layouts that rename or pack the files differently (e.g. an installer archive that
was not unpacked) are not supported and produce "no Epic Pinball table files" with the path.

### File set and validation

Per table n (1-13):

| File | Needed for | If missing |
|---|---|---|
| `EPn.EXE` | everything (playfield, palette, collision, sprites, engine data, rules, fonts, messages) | table not importable |
| `EPn.DAT` | preview screen; the palette check (EP9-13 find their palette by matching the preview's) | table not importable (warning names it) |
| `IDn.DAT` | table name | name "Table n", warning |
| `SFXn.PIN`, `SONGn.PSM` | sound effects and music (read at runtime by PinballAudio) | imported without sound, warning |

Launcher sounds `SFX0.PIN` / `SONG0.PSM` are copied when present (warning if not). `EP*.EXE` files
outside 1-13 are reported in `extraFiles` and ignored. `validate` also checks that each `EPn.EXE`
is an MZ executable with the playfield segment chain and the DS setup at its entry point.

## Library layout

The root is laid out like the developer `extracted/` directory, so it can be used as a data root
directly (`--data ROOT`, `GameLibrary(dataRoot: ROOT)`); the user's files are copied next to it.

```
<root>/                               e.g. ~/Library/Application Support/EpicPinballHD/Library
  library.json                        this import (format epic-pinball-library/1, below)
  original/                           copies of the user's files the engine reads at runtime
    EPn.EXE  EPn.DAT  IDn.DAT  SFXn.PIN  SONGn.PSM   (n = imported tables)
    SFX0.PIN  SONG0.PSM                              (launcher, if present)
  tables/
    manifest.json                     tools/extract.py manifest (palette offsets and methods)
    EPn/
      playfield_idx.npy               400x320 uint8 playfield            (extract.py)      TableAssets
      palette.json                    256 [r,g,b] in-game palette        (extract.py)      TableAssets
      playfield.png                   playfield in its palette           (extract.py)      snapshot checks
      preview.png                     table-select screen (EPn.DAT)      (extract.py)      launcher fallback
      collision_idx.npy               400x320 start-up collision buffer  (collision.py)    EngineAssets
      collision.npy                   (2,400,320) class map per level    (collision.py)    tools / debugging
      collision.json                  LUTs, ring, normals, flippers ...  (collision.py)    RulesRuntime (seg vars), engine export
      ball.png                        ball sprite                        (collision.py)
      engine.json                     everything ClassicEngine needs     (export_engine_data.py + engine_overrides)  EngineAssets
      rules.json                      only if a tools/rules.py output was available (see Rules)   RulesRuntime
      playfield_composited*.png       EP8 only: all toy overlays shown   (sprites.py)
      sprites/sprites.json            sprite records with EXE offsets    (sprites.py)      GameGraphics
      sprites/*.png                   RGBA sprites (lamps, flippers, digits, fonts, ...)   FlipperSpriteSet / PNG fallback
```

Not produced (development-only images of the Python tools): `collision.png` and the
`sprites/_sheet_*.png` contact sheets; also not the `extracted/music` / `extracted/sfx` WAV
renderings (the app plays `SONGn.PSM` / `SFXn.PIN` directly).

Re-importing into the same root replaces only `tables/`, `original/` and `library.json`
(`LibraryLayout.ownedItems`); other items in the root (e.g. HD packs) are left alone. The import is
built in `<root>/.import-<uuid>/` and moved into place at the end, so a failed import leaves the
previous library intact.

### library.json

```
format            "epic-pinball-library/1"
importer_version  1
created           ISO 8601 time
source            {kind: iso|directory, path, layout, detected (SourceScan.kind), game_folder, disc_image?, volume_id?}
data_root         "."            (the root is the data root)
original_root     "original"
tables[]          {number, name, directory ("tables/EPn"), exe_sha1, original_files[], sound (bool),
                   rules ("rules.json" | "direct-exe"), palette_method ("fade-code" | "preview-match"),
                   engine_fallbacks[] (engine.json fields that fell back to EP1 values; empty on the
                   CD), engine_overrides (bool), discover ("ok" | "failed: ..."), seconds}
missing_tables[]  extra_files[]  launcher_sound (bool)  warnings[]  import_seconds  note
```

## Pipeline

`TablePipeline.run` per table, in memory; tables run in parallel.

| Step | Swift | Python it reproduces |
|---|---|---|
| MZ header, relocations, playfield chain, data segment | `MZImage.swift` | `tools/epexe.py` |
| Playfield, palette (fade-in code signature; EP9-13: sliding match of the preview's first 200 colours), preview PCX | `PlayfieldExtract.swift`, `ImageFiles.swift` | `tools/extract.py`, `tools/pcx.py` |
| Collision buffer, class maps, wall/occlusion LUTs by symbolic execution of the classification code, sensor dispatch, flipper outlines | `CollisionAnalysis.swift` | `tools/collision.py` |
| Sprite records by code signature + pointer-table heuristic, fonts, EP8 composites | `SpriteExtract.swift` | `tools/sprites.py` |
| The part of the harness's search the exporter uses (physics step, kicker, serve/drain, plunger / EP8 launch block, counters) | `Discover.swift` | `tools/emu/discover.py` (subset) |
| engine.json incl. the sensor-handler interpreter and the overrides merge | `EngineExport.swift`, `EngineSensors.swift` | `tools/export_engine_data.py` |

Two pieces make the port literal rather than a re-implementation:

* `ByteRegex.swift`: a backtracking byte regex engine with Python `re` semantics (DOTALL, groups,
  classes, alternation, backreferences, `$` before a final newline, raw bytes keeping their regex
  meaning, as in `rb"..." + struct.pack(...)` patterns), so every code signature is carried over
  as written in the Python tools.
* `X86Decoder.swift`: a 16-bit x86 decoder whose mnemonic, operand text, operand details and
  written-register list follow capstone 5, which the Python analyses use (they match operand text
  such as `si, 1`). It covers the 8086/186/286 one-byte map with prefixes and capstone's quirks;
  `0F`, x87, VEX/XOP and 66/67-prefixed instructions (none occur in the code the analyses walk)
  return nil. `DecoderParityTests` compares it with capstone at every byte offset of the 13 code
  segments: 567,786 offsets identical, 6,330 outside the covered map, 0 different.

### Engine overrides

`tools/engine_overrides/EPn.json` (hand-verified code addresses, constants and flags; no game data:
tables and pixel lists are referenced by DS offset and read from the user's EXE) are embedded in
`EngineOverrides.swift`, so the importer needs no bundle resources. `ContractTests.
testEmbeddedOverridesMatchTools` fails if the two drift. Regenerate after editing an override:

```sh
python3 - <<'EOF'
import os
out = ['// Generated from tools/engine_overrides/EPn.json (hand-verified code addresses, engine constants and',
       '// flags for tools/export_engine_data.py; no game data: pixel lists and tables are referenced by DS',
       "// offset and read from the user's EXE). Embedded so the importer needs no bundle resources.",
       '// PinballImportTests.testEmbeddedOverridesMatchTools checks this file against tools/engine_overrides.',
       '// Regenerate: see docs/enhanced/import.md ("Engine overrides").', '',
       'enum EngineOverrides {', '    /// table number -> override JSON text', '    static let json: [Int: String] = [']
for n in range(1, 14):
    p = f'tools/engine_overrides/EP{n}.json'
    if os.path.exists(p):
        out += [f'        {n}: #"""', open(p).read().rstrip('\n'), '"""#,']
out += ['    ]', '}']
open('app/Sources/PinballImport/EngineOverrides.swift', 'w').write('\n'.join(out) + '\n')
EOF
```

## Rules

`rules.json` comes from `tools/rules.py` (2,700 lines of lifting) and is not ported. The app's
default rules backend is now the direct one (`RulesBackend.direct`, docs/enhanced/rules-direct.md):
`RulesRuntime.load` finds and runs the rule code in `EPn.EXE` and needs no `rules.json`; it
falls back to `rules.json` (with a warning) only if the discovery fails, and
`EPIC_PINBALL_RULES=lifted` selects the lifted backend. So:

* The importer records `"rules": "direct-exe"` for a table without `rules.json`; this is the normal
  case for users and is not a warning.
* With `ImportOptions.rules` `.automatic` (default: the developer `extracted/`, if present) or
  `.copy(from: dir)`, `tables/EPn/rules.json` is copied and recorded as `"rules": "rules.json"`,
  but only if it was lifted from the same EXE: `rules.json` holds EXE addresses and no hash, so when
  `<dir>/../original/EPn.EXE` exists it must be byte-identical to the imported `EPn.EXE`; otherwise
  it is skipped with a warning (and the table uses the direct backend).
* What the direct backend reads from the library: `original/EPn.EXE` (found by
  `RulesRuntime.locateEXE` via `<dataRoot>/original`). The lifted backend also reads
  `tables/EPn/collision.json` `collision_buffer.top_seg_var` / `bottom_seg_var`. Both are written.

## Parity

All in `app/Tests/PinballImportTests` (they skip cleanly when the user's data is absent):

* `PipelineParityTests`: all 13 tables from `original/`, in memory, against `extracted/`:
  `playfield_idx.npy`, `collision_idx.npy`, `collision.npy`, `palette.json` byte-identical;
  `collision.json`, `sprites/sprites.json`, `engine.json` structurally equal and byte-identical as
  serialized; the `manifest.json` entry equal.
* `ISOImportTests.testFullImportFromISOMatchesPythonOutputs`: the full import from the user's CD
  image into a temporary library: 4,133 files checked (the files above plus `rules.json`; every
  PNG the Python tools wrote except contact sheets, by decoded pixels; the copied originals),
  0 different. One reference file is stale: `extracted/tables/EP8/ball.png` was written by
  collision.py before EP8's `palette.json` last changed; it is checked against that palette
  applied to the reference ball indices instead (a fresh collision.py run gives the same result).
* `ISOImportTests.testISOReaderListsTheCDAndMatchesExtractedFiles`: 109 files on the CD equal the
  files in `original/`.
* `SourceLayoutTests`: installed folder, GOG-style subfolder with lower-case names, an app bundle,
  a disc image in a folder, missing and extra tables (built from symlinks, nothing copied).
* `DecoderParityTests` (needs `.venv` with capstone), unit tests for the regex engine, decoder
  spelling, JSON/NPY writers, and synthetic ISO images (2048 and raw 2352 Mode 2 sectors).
* `PaletteSearchTests`: the bounded preview-match palette search (EP9-13) returns the same offset as
  the literal full scan, on 40 synthetic inputs (small alphabets, ties, planted partial copies,
  all-zero data) and on the user's EP9.EXE with the real and a non-matching reference.

App-level check (`scratch/importer/lib_vs_extracted.py`, 2026-09-28, app at HEAD with the default
direct rules backend): a library imported from the CD image, then every scenario in
`tools/emu/scenarios` (413) in physics, rules and full mode traced with `--data <library>` and with
`--data extracted`, `EPIC_PINBALL_*` unset and no `--original`: **1,239 of 1,239 traces
byte-identical** (624,960 records); the rules find `original/EPn.EXE` inside the library.
Snapshots of EP1/4/8/10/12 (`--lamps a --score 12345670 --launch --sim-time 1.5`) are byte-identical
PNGs with `--data <library> --original <library>/original`; without `--original` the headless
snapshot does not find the EXE for the presentation (see Loader notes).

## Performance

Full import of all 13 tables from the CD image (read, copy 6.4 MB of originals, extract, write
36 MB), 8 cores: about 2.1 s in a debug build (tests, `DevLibraryTests`), 0.73 s in a
release build. The slowest step used to be the EP9-13 palette search (extract.py's sliding
preview match: 60 probes at every file offset, 3.6-5.3 s per table in debug); it now takes a lower
bound from the offsets whose first two probes match and stops counting an offset once it cannot
reach it (exact, see `PaletteSearchTests`), 0.02-0.2 s per table in debug.

## Loader notes (other tracks)

State after integration (2026-09-28), all resolved:

* Rules: `RulesRuntime.locateEXE` includes `<dataRoot>/original`.
* Window app: `GameLibrary` (TableCatalog.swift) finds `<root>/original` and App.swift passes it as
  `originalDir`.
* Headless / direct starts: `resolveDataRoot` (main.swift) fills `originalDir` with
  `GameLibrary.findOriginal(near:)` for an explicit `--data`, `--library` and the imported library
  (not for the developer `extracted/` candidates, so harness traces keep the old search order).
* `TableExe.locate` (PinballRender) now also tries `<dataRoot>/original`, and
  `OriginalDataLocator.candidates` (PinballAudio) `$EPIC_PINBALL_DATA/original`.
* The app imports with `ImportOptions(rules: .none)` (ImporterHookup.swift): libraries never carry
  a lifted rules.json, the rules run from the copied EXE.
* `--headless-import SRC [--library DIR]` runs this importer without a window; the packaging
  script's runtime check uses it from the packaged binary (docs/enhanced/frontend.md, Packaging).
