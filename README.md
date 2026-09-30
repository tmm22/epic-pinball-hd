# Epic Pinball HD

A native macOS reimplementation of the engine of the 1993 DOS pinball game
*Epic Pinball*. It has an exact **classic** mode and an **enhanced** mode with
upscaled graphics, dynamic lighting, smoother physics, 120 Hz, controller support
and high scores.

> [!IMPORTANT]
> **You need a legal copy of Epic Pinball to use this.** This project contains
> **no game assets**: no artwork, music, sounds, table data, text or code from
> the original game. All it does is use the original assets from **your own
> copy**. On first launch the app imports your CD image or installed game files
> and reads the originals at runtime. You can buy the game as
> [*Epic Pinball: The Complete Collection*](https://www.gog.com/en/game/epic_pinball_the_complete_collection)
> on GOG.com. Anything made from your copy (the imported library, `extracted/`,
> HD packs) is for your own use and must not be redistributed. See [NOTICE](NOTICE).

*Epic Pinball* was developed by Digital Extremes and published by Epic MegaGames
(now Epic Games). This is an unofficial fan project, not affiliated with or
endorsed by any rights holder.

## Status

- **Classic mode** is checked against the original machine code, which runs in
  an emulator on your own copy. It matches on every scenario tested, across all
  13 tables: physics 415/415, rules 415/415, full main loop 413/415.
- **Enhanced mode:**
  - xBRZ, smooth and CRT filters, optional HD packs generated from your copy,
    lamp glow and ball shading.
  - Swept-collision physics with a "classic feel" preset.
  - 120 Hz with motion interpolation, and a full-table view.
- **App:**
  - Table picker, settings, remappable keys, game controllers, top-10 high
    scores.
  - Importing your data happens in the app, with no Python needed.

## Build and run

Requirements: an Apple silicon Mac with macOS 14 or later, and Swift 6.x. The
repo's `.swift-version` pins swiftly to 6.4.0; Xcode 26's Swift 6.3 also works.
You also need Homebrew `libopenmpt` and `pkgconf`.

```sh
brew install libopenmpt pkgconf
tools/package_app.sh                 # builds build/EpicPinballHD.app (no game data inside)
open build/EpicPinballHD.app         # first launch: choose your CD image or game folder
```

For development:

```sh
cd app && swift build && swift test
swift run EpicPinball --library DIR --table 1
```

Keys, command-line flags and the list of render and physics options are in
[app/README.md](app/README.md).

## Repository layout

| Path | Contents |
|---|---|
| `app/` | SwiftPM package: `PinballCore` (engine, rules, enhanced physics), `PinballRender` (Metal), `PinballAudio`, `PinballImport` (Swift importer), `EpicPinball` (app) |
| `tools/` | Python reverse-engineering and verification tools. `tools/emu/` is the differential test harness that runs the original code in Unicorn. `tools/hdpack/` builds HD packs |
| `docs/formats/` | File-format and engine documentation for the original game |
| `docs/enhanced/` | Design docs for the enhanced version |

These folders are gitignored and must never be committed: `original/` (your game
files), `extracted/` (data made from them), `scratch/` and `build/`.

## License

This project is licensed under [GPL-3.0-or-later](LICENSE). Third-party
components are listed in [NOTICE](NOTICE). The license covers this project's own
code and documentation only. It grants no rights to *Epic Pinball* or its
content.
