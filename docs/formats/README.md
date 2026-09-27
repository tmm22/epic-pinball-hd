# Epic Pinball file formats (CD v2.1, 1995)

Findings from static analysis of the user's own CD. Offsets are file offsets
unless noted. Extractor: `tools/extract.py`, `tools/sfx.py`.

| File | Format | Status |
|---|---|---|
| `EPn.EXE` (n=1..13) | One MZ executable per table: engine + rules + art. Real-mode asm, not packed. Refuses to run unless launched by `PINBALL.EXE`. | Playfield, palette, collision, sprites and physics decoded (static analysis) |
| `EPn.DAT` | ZSoft PCX v5, 320x200 8bpp: table-select preview screen | Decoded |
| `REG.DAT` | PCX 320x400 | Decoded (not yet examined) |
| `SFXn.PIN` | Sound bank: `(u16 len, u16 offset_paras)` table, then signed 8-bit PCM | Decoded. Launcher plays from (paras+1)*16 for len-40 bytes, raw signed 8-bit; base rate 11000 Hz with live pitch (engine.md section 7). Table N uses SFXN/SONGN; SFX0/SONG0 belong to the launcher |
| `SONGn.PSM` | Epic MegaGames MASI / ProTracker Studio module, 4ch | Plays in libopenmpt |
| `MDRVnnnR.MUS` | Sound-card drivers (`REAL16`/`MLPR` signature) | Not needed for port |
| `PINnn.TFP` | `TFP` signature, launcher text/help pages | Not examined |
| `INTRO.PIN`, `END.PIN` | Launcher intro/outro data | Not examined |
| `IDn.DAT` | 20-byte table name, space padded, `0x1A` terminated | Trivial |

## Table EXE layout

* Relocation table references a chain of three segments exactly `0xFA0`
  paragraphs (64000 bytes) apart: `[playfield top 320x200][playfield bottom 320x200][data seg]`.
  The playfield is therefore raw 320x400 8bpp, no compression.
  The third segment is heavily referenced from code (31-40 fixups) - prime
  suspect for collision / object data. **Next RE target.**
* Entry: `push ds; mov ax,0; push ax; mov ax,<DS>; mov ds,ax`, then parses
  the command line passed by `PINBALL.EXE` (PSP:0x82 digit '1'-'4', PSP:0x9E == '@').
* Palette: 768 bytes 8-bit RGB inside DS; engine converts with `shr al,2`
  into a 6-bit working buffer for fades (`lea si,[pal]; lea di,[buf]; mov cx,300h; lodsb; shr al,2; stosb`).
  Indices 0-199 = static art, 200-254 = lamp / flasher colours rewritten at runtime.
* VGA: sequencer (3C4h) and CRTC (3D4h) programming present -> unchained
  Mode X with hardware scrolling across the 400-line playfield.

## Detailed docs

* [collision.md](collision.md): collision uses the playfield's own palette indices (no separate map); 48-probe ball test, normal/push-out tables, flipper outlines, sensor jump table, runtime gates. Tool: `tools/collision.py`.
* [sprites.md](sprites.md): Mode X blitter record format; flippers, ball, plunger, lamp a/b overlays, score digits, fonts; EP8 explained (every toy is an overlay; palette at file `0x5138`). Tool: `tools/sprites.py`.
* [emulation.md](emulation.md): Unicorn harness that boots the user's EP1.EXE and runs the original physics code (`tools/emu/`); DOSBox-X headless capture for checking against the running game. Differential test vs the Swift port: `tools/emu/diff_traces.py`.
* [rules.md](rules.md): table rules as JSON block graphs lifted from the handler code (`epic-pinball-rules/1`), extracted by `tools/rules.py` for EP1, EP2, EP10; messages referenced by EXE offset only.
* [audio.md](audio.md): table-to-bank/song mapping, SFX voice allocation (4 channels round-robin), pitch as retriggered trains, music never changes song or order in-table; `PinballAudio` API.
* [engine.md](engine.md): 59.94 Hz frames, 3 physics steps per frame, velocity in 1/128 px per step, physics parameter block at ds:6781 (edited by a hidden F1 parameter editor), per-table constants ("classic" preset), sound path. Tools: `tools/disasm.py`, `scratch/engine/ep1_physics_ref.py`.

The third segment of the playfield chain turned out to be the graphics library's data segment (row tables and sprites), not collision data.

## Known gaps

* The emulator harness only maps EP1. The other 12 tables use the same engine through `engine.json`, but none of them have been checked against the original code yet. Some of the exporter's fields fall back to EP1 values (EP3 and EP9-13 ball slots, the EP8 plunger/serve).
* The rules are lifted for EP1/EP2/EP10, but the Swift port doesn't run them yet. With rules on, 8 of 45 scenarios diverge, all at handlers the port doesn't have (0xF5, 0xF6 saucer, 0xF8 kickback, 0xF9 ramp scoring).
* Main-loop rule hooks (timers, drain, bonus, light shows) are annotated by hand for EP1 only.
* The checks against the running game (DOSBox-X) cover about 150 frames of EP1 demo play; after that the paths drift apart for a reason that hasn't been found.
