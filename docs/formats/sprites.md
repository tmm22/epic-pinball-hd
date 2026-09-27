# Epic Pinball: non-playfield graphics (sprites, fonts, EP8 layers)

This covers the graphics stored in the table EXEs outside the 320x400 playfield:
lamp and insert overlays, drop targets, slingshots, flippers, the ball, the plunger,
the score digits, the "pause" banner, the two text fonts, per-table animations,
and how EP8 is built up from layers.

Extractor: `tools/sprites.py`. It writes `extracted/tables/EPn/sprites/*.png` (RGBA),
`sprites.json` and `_sheet_<group>.png` contact sheets. For EP8 it also writes
`extracted/tables/EP8/playfield_composited.png` and `playfield_composited_robot.png`.
Scratch scripts are in `scratch/sprites/` (disassembler, scanners, coverage map).

Addresses are EP1 `cs:ip` in the entry code segment 0x3223. The file offset of an
EP1 code address is `0x32630 + ip`. The object segment ("data seg X", 0x2623) starts at
file 0x26630. Confidence: **H** = read in the disassembly and checked against the data,
**M** = strongly suggested but not traced end to end, **L** = guess.

## 1. What is where (EP1)

| File range | Contents | Conf. |
|---|---|---|
| `0x00400-0x0054f` | segment 0 (small code/data) | M |
| `0x00550-0x0722f` | DS 0x15: strings, variables, palette at `0x1310`, ball template at `0x7086`, program tables at `0x5860-0x7000` (lists and word tables, not graphics) | H for the palette and ball; the rest was not examined in detail |
| `0x07230-0x2662f` | playfield, 2 x 64000 bytes | H |
| `0x26630-0x27b4a` | object segment variables: VRAM row table (`+0x39`, 480 x `row*80`), bit-reverse table (`+0x409`, 256 bytes), dot-list buffer (`+0x10c2`) and so on. Mostly zero in the file | H |
| `0x27b4b` | "pause" banner, chunky 66x13 | H |
| `0x27ead` | plunger, planar 8x45 | H |
| `0x2802d` | lamp/overlay pointer table, 124 x u16 | H |
| `0x28125-0x32244` | 124 planar overlay records, packed back to back | H |
| `0x32256` | 8x8 font, 71 glyphs from `' '` | H |
| `0x3248e` | 5x5 font, 71 glyphs from `' '` | H |
| `0x325f1` | u32 powers of ten, used for score formatting | H |
| `0x32630-0x38308` | code, with the score-digit table and records embedded at `cs:4a3f` (file `0x3706f`) | H |
| `0x38309` | flipper pointer table, 8 x u16 (CS-relative) | H |
| `0x38319-0x3d698` | 8 flipper frame records | H |
| `0x3d750` | seg 0x3d35: a 51-byte far-call thunk into the runtime-loaded music driver (not graphics) | H |

`scratch/sprites/coverage.py N` prints the remaining unexplained ranges for any table.
In EP1, EP2, EP8 and EP10 everything left is either code, DS variables, or DS
word tables. None of it looks like pixel data (entropy and autocorrelation checked,
byte dumps inspected).

## 2. Sprite formats

### 2.1 Planar record: overlays, flippers, digits, plunger, animations (H)

```
u16 x      absolute playfield x in pixels (always a multiple of 4 in practice)
u16 y      absolute playfield y (0..399)
u16 w4     bytes per plane per row  (width = 4*w4)
u16 h      rows
h rows of: plane0[w4] plane1[w4] plane2[w4] plane3[w4]
           pixel (4*i + p) of the row = plane p, byte i
```

The Mode X blitter is at `cs:472f` (file `0x36d5f`). It reads x and y, uses `di = rowtab[y]`,
and adds the back-page offset `[0x1c]` if `y > 4`. It then does `di += x>>2`, sets map mask
`0x11` and rotates it per plane with `rep movsb`. It is **opaque**: there is no colour key, so
every overlay is a full rectangle with the playfield background baked in. It rejects records
with `w4 > 30` or `h > 100`. The flipper blitter at `cs:b0bf` is a copy with limits of 20 and 50 in EP1. EP10's copy (`cs:9cc8`) has no
size limits. EP10's flipper records are each followed by one unused padding row (60 or 64 bytes) that the blitter never draws.
x and y come from the record, so overlays are position-bound.

### 2.2 Chunky banner (H)
`u16 x, y, w, h` followed by `w*h` linear bytes. The only instance is the "pause" banner
(`cs:49de`, file `0x3700e`). It is drawn opaque into the display strip, one pixel at a time,
with a rotating plane mask.

### 2.3 Ball template (H)
`u16 w=15, u16 h=14` followed by 210 linear bytes. **Index 0 is transparent.**
`cs:1679` copies it (`mov cx,0D6h; rep movsb`) into a work buffer at DS:0x6a5e and composites it
with the playfield (see §5). `cs:54d8` (file `0x37b08`) then draws it with an `or al,al; je skip` colour key.
EP1-7 and EP9-13 have one ball. EP8 has a 5-entry ball table (DS:0x6df0) indexed by a
per-level variable, `[0x5f35]-1`.

### 2.4 Fonts (H)
* **font8**: 8 bytes per glyph, 7 rows used (EP1 glyph 0x62 also uses row 8), MSB = leftmost pixel, first glyph `' '`.
  EP1-8 have 71 glyphs (codes 0x20-0x66). Codes 0x20-0x5D are ASCII; codes 0x5E-0x66 (the `^` and `_`
  slots plus 7 more) hold 9 accented capitals, the Polish set (A-ogonek, C/E/L/N/O/S/Z accented, Z-dot).
  [verifier fix: previously said ' '..'_' followed by 7 accented capitals]. EP9-13 have 65 glyphs.
  `cs:5a34` (file `0x38064`) draws it into the display strip: 40 columns x 2 text lines at rows 2 and 10.
  The glyph byte is turned into plane masks through the bit-reverse table (object seg +0x409).
  The low nibble gives the mask for the first 4 pixels and the high nibble for the next 4.
  Colour is the parameter in `bl`.
* **font5**: 5 bytes per glyph, 5 rows, bits 7..3 = 5 columns, first glyph `' '`.
  EP1-8 have one 71-glyph font. EP9-13 have two 64-glyph fonts back to back (`font5a`, `font5b`).
* `cs:584b`, `58b8`, `5926` and `59ac` turn a string into a list of *pixel positions* in the
  playfield. Each set font bit becomes one pixel. Columns are 2 px apart and rows 2 lines
  (`+0x280`) apart, which gives the dotted "dot-matrix" look. Characters are 16 px (font8) or
  11 px (font5) wide, centred at `cs:1600`. `cs:43d5` (file `0x36a05`) plots the list in
  colour 255 (set to white at `cs:166a`) and saves the old pixels for restore by `cs:43a4`.
  Both routines lower-case-fold by subtracting 0x20 from codes above 0x60. **H** for the mechanism.
  Which messages use which font was not checked.

### 2.5 Display strip (M)
Mode X runs at **320x240** (misc output `0xE3` at `cs:460d`). The CRTC line-compare register is
set to scanline 441 in EP1-8 and 421 in EP9-13. VRAM rows 0..19 (EP1-8, page offset `0x640`)
or 0..29 (EP9-13, offset `0x960`) hold the score/message strip, and the two scrolling playfield
pages start after it (`0x640` and `0x8340`, which is `+0x7d00`). By VGA split-screen rules the
strip shows **below** the split line, i.e. at the bottom of the screen. This was not confirmed at runtime.
The strip is cleared to colour 0x2f (`cs:5c23`, `5c58`).

## 3. Sprite groups and how the code uses them

### 3.1 Lamp / insert / target overlays (H)
The pointer table sits in the object segment. The update routine is `cs:478d-48b7` (file
`0x36dbd`); the draw call is at `cs:4882: mov si,[bx+19fdh]`. Lamp *k* owns entries
`2k` ("a") and `2k+1` ("b"). Per-lamp state byte:

| state | draws | next state |
|---|---|---|
| 1 | a | 5 (steady) |
| 2 | b | 6 (steady) |
| 3 | a | 4 |
| 4 | b | 3 (3 and 4 alternate = blinking) |

The routine also has a phase counter (1..0x3d) that picks which lamps to service. It was only
partly traced. **M** for the phase logic, **H** for the a/b mapping.

"a" and "b" are code slots, not "off" and "on". Which one matches the baked playfield
depends on the table (see `playfield_match` in `sprites.json`):

* EP1-4, EP6 and EP7: "a" matches the playfield (the unlit or up state is baked in).
  EP7 is the weakest case: only 8 of 37 "a" records are pixel-exact (20 at 95% or better; mean 0.85).
  Pixel-exact counts per table (a/b), verifier re-run: EP1 43/8, EP2 40/0, EP3 38/0, EP4 36/0, EP5 6/1,
  EP6 44/3, EP7 8/0, EP8 0/53, EP9 3/42, EP10 4/32, EP11 0/46, EP12 0/40, EP13 0/39.
* EP8-13: "b" matches.
* EP5 matches neither well. Its overlays are mostly pop bumpers (lit states), a 4-frame
  diverter, and one small shared placeholder record used by 79 slots
  (`shared_by_slots` in the JSON).

The group covers lamps, inserts, drop targets (up/down pairs), slingshot kick frames, kicker
states, captions and so on. Names are `lampNNN_a/b`. Semantic names were not assigned.
Slots of 4x1 pixels, or whose header would overrun the next record, are marked `dummy`
(6 in EP8, including lamp 36; 10 in EP9; 44 in EP13; 2 in EP6). The table has no length field. It ends where the first record it
points at begins, which was checked in all 13 tables.

### 3.2 Flippers (H)
`cs:b0ac` (file `0x3d6dc`) clamps `bx` with `cmp bx,7` and then reads `mov si,cs:[bx*2+5cd9h]`.
There are 4 frames per flipper. Frame 0 is fully raised and frame 3 is at rest (checked visually).
The frames are opaque and include the background and shadow. Counts:

| Tables | Frames | Flippers |
|---|---|---|
| EP1-3, EP5-11, EP13 | 8 | left and right |
| EP4 | 16 | 4 flippers: 2 extra upper ones |
| EP12 | 12 | 3 flippers |

Frames that share one x,y are grouped as a single flipper: `flipper<k><L|R>_<frame>`.
**L** for the claim that the game only has 4 rotation steps plus the rest pose. The code
can only select these frames, so there is no finer rotation.

### 3.3 Score digits (H)
`cs:5371` (file `0x379a1`) takes 11 CS-relative pointers at `cs:4a3f` (digits 0-9, then blank).
Each digit is 12x17. It sets x = `0x4c + 12*pos` and y = 2 at runtime, then calls the blitter,
drawing into the display strip. EP2-7 keep this table in the object segment instead.
In EP9-13 the table is a 1x1 stub, so the big digits are unused there. My guess is that the
score is drawn with the font (**L**).

### 3.4 Plunger (H)
`cs:4959` (file `0x36f89`). The record is at object seg `+0x187d`. y is patched on every call
(`mov [0x187f],ax`) and every row is written to both pages. EP1 is 8x45 at x=288. There is no
plunger routine in EP8 (ENIGMA has no plunger sprite). EP9-13 use a 30-row display offset.

### 3.5 Animations (H for the mechanism, L for the names)

| Table | Pointer table (file) | Frames | Driven by | Looks like |
|---|---|---|---|---|
| EP2 | `0x3d8fc` | 6 | cs frame counter, wraps at 5 | spinner |
| EP3 | `0x3bce2` | 6 | same | spinner |
| EP10 | `0x3c2e0` | 13-entry sequence of 6 images | same | eye blink (ping-pong) |
| EP4 | `0x2f05d` | 7 | `cmp bx,6` | ball-lock indicator (background + 6 ball slots) |
| EP9 | `0x3b20f` | 15 | `cmp bx,0eh` | red two-digit LED readout |
| EP6 | `0x26560` | 15 | EP6 `cs:41a0`: 1-based index in `ax`, `DS=0x2616`, `mov si,[si+0]`, drawn to both pages (`cs:434f` blit + `cs:4955`, twice) | centre award plaques |
| EP6 | `0x29817` | 12 | EP6 `cs:5206`: per-instance frame counter `[si+31fh]` wraps at 12, `mov si,[si+337h]`; the record's x is patched from `[si+32dh]` | falling apple |

The EP6 plaque table lives in segment 0x2616. That segment is referenced once and is the
segment `extract.py` reports as "after" for EP6. EP6's real object segment is 0x290e.

## 4. EP8 (ENIGMA, "layered") explained (H)

* The playfield segments hold only the background, the wire rails and the flipper inlanes.
* **Every toy is a lamp overlay.** The table at file `0x278c1` has 120 entries pointing into
  object seg 0x267f. The records span file `0x279b1-0x353bf` (about 55.8 KB), the largest of any table. For EP8 the "b" slot matches the
  empty playfield (53 of 60 pixel-exact, 55 of 60 at 99.5% or better) and the "a" slot holds the object (bumpers, targets,
  teddy, monkey, lollipop, spikes, "GRAVITY+/-", "LEVEL 1234" and so on). Objects appear and
  disappear as lamps are switched, presumably per level. Several late slots (55, 56, 58, 59)
  are alternate states of earlier objects at the same place, for example a ball held in a
  kicker or in the ball lock.
* **Segment 0x3f88** (file `0x3fc80-0x48ecf`) is the only genuinely extra segment. `cs:a42f`
  sets `DS=0x3f88` and draws 6 planar records to **both** pages from one of two 6-pointer tables:
  - `DS:0x9238` (`al==1`): a large robot figure over the centre, x 88..211, y 200..358
  - `DS:0x922c`: the matching background pieces, which restore the empty centre
* `0x353a` is just EP8's entry code segment, not art. `0x48ad` is the music-driver far-call thunk.
* **Palette:** the fade routine loads DS:0x4c58, which is **file `0x5138`**. `extracted/tables/manifest.json`
  lists `0x55f6` (match 0.29), which is wrong. That is why `EP8/playfield.png` looks purple. With
  `0x5138` the playfield matches the `EP8.DAT` preview. `tools/sprites.py` finds palettes through
  the fade code (`lea di,[w]; mov cx,300h; mov al,0; rep stosb; lea si,[pal]`) for EP1-8. For EP9-13
  it falls back to `palette.json`, which agrees with the fade-code result wherever both exist.
* The ball has 5 variants, and the ball-occlusion range comes from variables (`[0x4a6]`, `[0x4a9]`)
  instead of constants. That suggests per-level balls and depth rules (**M**).

`playfield_composited.png` is the playfield plus every non-dummy "a" overlay, in slot order.
Overlays that fall inside an already drawn one are skipped, so it shows the primary art.
`playfield_composited_robot.png` adds the 0x3f88 robot set. This is **not** a proven in-game
frame. Which toys are visible at a given moment depends on game state that was not traced.

## 5. Ball depth / occlusion rule (H, useful for the port)

`cs:1679-1723` (file `0x33ca9`) does the following for each of the 15x14 ball pixels:

```
p = playfield[y+r][x+c]
if lo < p <= hi:          ball_buf[r][c] = p     # object in front: ball hidden here
elif p > hi and (p == 0xFE or ah == 0) and !flag: call cs:1e3b   # side effect, not traced
```

After this the buffer is drawn with colour key 0. **Palette indices in `(lo, hi]` are
therefore "in front of the ball"** (wire rails, ramps, posts). Two ranges exist per table.
The second one is used when `[0x677e]==1`, which is probably the ball being on an upper
level or ramp (**M**). Values per table are in `sprites.json:ball_occlusion_ranges`:

| Table | Primary range | Alternate range |
|---|---|---|
| EP1 | (180, 207] | (187, 199] |
| EP2 | (175, 206] | (187, 199] |
| EP3 | (191, 207] | (187, 199] |
| EP4 | (167, 198] | (175, 187] |
| EP5 | (191, 207] | (194, 194] (empty) |
| EP6 | (191, 197] | (194, 194] (empty) |
| EP7 | (194, 215] | (199, 199] (empty) |
| EP8 | from variables | (175, 187] |
| EP9 | (167, 187] | (175, 175] |
| EP10 | (175, 198] | (175, 187] |
| EP11 | (135, 192] | (167, 192] |
| EP12 | (151, 175] | (167, 175] |
| EP13 | (177, 183] | (177, 177] |

## 6. How `tools/sprites.py` finds things (code signatures)

Every location is found from code, so the same routine works for all 13 EXEs:

| Item | Signature (hex, `..` = operand) |
|---|---|
| lamp table | `BA seg 8E DA 8B B7 tbl 56 9A` (`mov dx,seg; mov ds,dx; mov si,[bx+tbl]; push si; call far`) |
| flippers, digits, misc | `83 FB n (72\|76) 03 BB n 00 [53] D1 E3 [2E] 8B B7 tbl` → n+1 entries |
| frame animations | `2E 8B 1E cnt D1 E3 2E 8B B7 tbl`, with the wrap from `2E 83 3E cnt N 76` |
| ball | `8D 36 ball 8D 3E .. B9 D6 00 F3 A4` (EP8: `8B B7 tbl` table variant) |
| pause | `BA seg 8E DA 8D 36 p 8B 0C 8B 44 02 83 C6 04` |
| plunger | `8D 36 p A3 .. B8 seg 8E C0 FC 55 8B EC AD 8B C8 AD 8B F8 D1 E7 26 8B BD .. 81 C7 pageofs` |
| font8 | `8D 36 f 2C 20 3C 80` |
| font5 | `BB 05 00 F7 E3 8B D8 B1 01 B2 05 53 57 8A 87 f` |
| EP8 sets | `BA seg 8E DA B9 n 00 BB 00 00 8D 3E a 3C 01 74 04 8D 3E b` |

Anything that is only reached through a pointer table the heuristic finds (u16 runs that point
at valid planar headers) goes to group `unknown`, or `anim` if a visual `name_guess` exists.

## 7. Per-table summary

| T | object seg | lamp table (file) / entries | flipper frames | ball | plunger WxH | fonts | extra |
|---|---|---|---|---|---|---|---|
| 1 | 0x2623 | 0x2802d / 124 | 8 (68x40) | 0x7086 | 8x45 | 8x8 (71), 5x5 (71) | digits |
| 2 | 0x25a4 | 0x278d9 / 112 | 8 | 0x689c | 12x43 | same | digits, spinner |
| 3 | 0x252f | 0x27181 / 80 | 8 | 0x6113 | 12x32 | same | digits, spinner |
| 4 | 0x2622 | 0x280dd / 106 | 16 | 0x7077 | 12x46 | same | digits, lock indicator |
| 5 | 0x2490 | 0x276cb / 96 (18 distinct) | 8 | 0x571d | 12x37 | same | digits |
| 6 | 0x290e | 0x2baf3 / 106 | 8 | 0x6f73 | 12x39 | same | digits, plaques, apple |
| 7 | 0x25a2 | 0x2782d / 74 | 8 | 0x686f | 8x47 | same | digits |
| 8 | 0x267f | 0x278c1 / 120 | 8 | 5 balls @0x72dc.. | none | same | digits, robot set |
| 9 | 0x246a | 0x26116 / 148 | 8 | 0x54e2 | 12x29 | 8x8 (65), 2 x 5x5 (64) | LED frames |
| 10 | 0x23da | 0x258ee / 164 | 8 | 0x4bed | 12x47 | same | eye blink |
| 11 | 0x2427 | 0x25c3a / 114 | 8 (52x43) | 0x50b9 | 8x22 | same | |
| 12 | 0x2445 | 0x25e7e / 126 | 12 | 0x52ab | 12x23 | same | |
| 13 | 0x2447 | 0x25fb2 / 132 (44 dummy) | 8 | 0x52ce | 12x46 | same | |

"pause" appears in EP1-8 only. EP9-13 have no chunky pause banner and the text is probably
drawn with the font (**L**).

## 8. Not determined / caveats

* **Nothing was verified at runtime (DOSBox-X was not driven).** Everything is static
  analysis plus visual checks of the decoded images. The plane order, lamp a/b slots, flipper
  frame order and ball compositing are self-consistent: about half of all overlays match the
  playfield pixel-for-pixel, and frames look correct.
* No semantic names for individual lamps (which slot is which insert or rule). That needs the
  rules code.
* The EP8 toy set per level, and when the robot set is drawn (the caller's `al`), were not traced.
* The phase/timing logic of the lamp updater, and the side-effect routine `cs:1e3b` triggered
  by palette index 0xFE under the ball, were not traced.
* It is not confirmed that the display strip is at the bottom of the screen; that follows
  from VGA line-compare semantics.
* Lamp colours 200-254 are animated through the palette (see README). Some "lamps" are
  therefore palette effects with no overlay record at all, which is likely why EP5 has so few.
