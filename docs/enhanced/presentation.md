# Presentation fidelity: message effects, palette fades, EP9-13 colours, EP8's robot

These features change what the classic presentation shows (classic and enhanced rendering alike), so the
screen follows the original more closely. They change nothing in the rules' data segment or the physics: the
parity suite is unchanged (830/830 with both rules backends). Everything is read from the user's EXE at run
time; no game data is stored.

| Feature | Where | Tables |
|---|---|---|
| Dot-message effects (moving and dying dots, DAC 255 fades, per-dot colour cycling) | `PinballCore/Presentation/DotEffects.swift` (render_frame run from the EXE), `PinballRender/MessageAnimator.swift`, `EpicPinball/Presentation.swift` | all 13 |
| EP9-13 message and text colours | `RulesRuntime` -> `MessageRef.colour`, `TextRef.colour` | EP9-13 |
| EP9-13 strip background while a dot message is shown (render_frame's own clear) | `StripSpec.dotBorder` / `dotFill`, `ClassicComposer.buildStrip` | EP9-13 |
| Palette fades (boot fade-in end state, ball-loss dim, release restore; EP7's darkened base palette) | `PinballCore/Presentation/PaletteFade.swift`, `RulesRuntime` -> `paletteOverrides` | EP1-8 |
| Visible screen fades (boot fade-in at every game start, end-of-game fade-out) | `PinballCore/Presentation/ScreenFade.swift` (`ScreenFadePlayer`), `RulesRuntime.screenMachine`, `EpicPinball/App.swift` (`GameController`) | all 13 |
| EP8's robot set (kept across VRAM resets and state loads) | `PinballCore/Presentation/SpriteSets.swift`, `PinballRender/SpriteSetGraphics.swift`, `ClassicComposer.applySpriteSet` / `syncSpriteSets` | EP8 |

Confidence marks: [H] read in the code and checked by running the original (harness or DOSBox-X capture), [M]
read in the code or inferred, not checked by running.

## 1. Dot-message effects

### What the original does (EP1 addresses; EP10 in brackets)

* **dmd_message** cs:15DE [EP10 cs:1563]: the font routine writes the dot list at ds:10C2 [ds:0F48], one word
  `y*320 + x` per dot from the window origin (EP1-8) or the strip origin (EP9-13), then three zero words, and
  leaves the line pointer at 2623:050C. Then: step index ds:0B3B = 0, effect byte ds:0B3A = AL, delay buffer
  ds:4586 (546h words) [ds:2208, 4B0h] = 0, counter ds:0B3D = 1, DAC 255 = 3F,3F,3F [3F,0,0]. EP9-13 also fill a
  colour array (word i at list + 960h, low byte = ds:00C5, cs:15F0) and first store FFF8h into cs:3E20
  (effect 12's band position). A string longer than 30 characters, or too wide to centre, returns at once
  (cs:15FC) and changes nothing. [H]
* **render_frame** cs:3E35 [cs:38E1] once per frame: if the counter is 0 nothing happens. Otherwise the block
  for the effect byte runs (cs:3E3F..4370 [cs:38EC..3ED4]), then all blocks join at cs:4373 [cs:3ED7]: the dots
  of the previous frame are restored, and if the counter is 0FFFFh it becomes 0 and nothing is plotted (the
  message is gone; EP9-13 then redraw their idle display, which is itself a dot message, cs:3EF2). Otherwise the
  plot loop (cs:43D5 [cs:3EF8]) draws every list word other than 1 up to the zero terminator (the first word is
  tested like the others, so an empty list plots offset 0) in DAC 255 (EP1-8) or in the dot's colour byte
  (EP9-13, which also skip words above 2580h, the 30-row strip). A dead dot is the word 1. [H]
* The effect blocks, EP1 constants (each table has its own; they are executed, not transcribed) [H code, all
  effects compared frame by frame on several tables, see 1.3]:

| AL | EP1 block | what moves | ends |
|---|---|---|---|
| 0 | none | nothing; the counter stays 1 | only when replaced or cleared |
| 1 | cs:3E3F | from count 200 every live dot adds its velocity from the 50-word table ds:0B40 (cycled); dots outside x 7..313 / y 7..195 die; DAC 255 grey from 3Eh down 1 per frame, sound 700Dh at 200 | grey reaches 1 |
| 2 | cs:3EDC | from 100: a wave, table ds:0BA6 (step index ds:0B3B) fed through the delay buffer, so each dot gets the step the previous dot had a frame earlier; x <= 10 dies | count > 800 |
| 3 | cs:3F60 | every frame, the wave of table ds:0BF6 in groups of 7 dots; the counter does not advance | never |
| 4 | cs:3FF1 | from 50: wave of table ds:0C4A; dots past offset C1C0h (below the window) die | count 650 |
| 5 | cs:406B | from 30: wave of table ds:0C5C (179 words); x <= 10 dies; from 350 a grey fade from 3Eh | grey reaches 1 |
| 6 | cs:4117 | nothing moves; from 200 a grey fade from 3Fh | grey reaches 1 |
| 7 | cs:4158 | EP1-8: the wave of table ds:0BF6 in groups of 4 dots. EP9-13 [cs:3C18]: every ds:00C3 + 1 frames `xor 0Fh` on the colour byte of every 4th dot, the start dot rotating over 5 phases (cs:3C14/3C16) | never |
| 8 / 9 | cs:41C2 / 4229 | from 100 to 180 every dot moves 4 px left / right; dies at x <= 5 / x >= 315; sound 0Eh at 105 | count 180 |
| 10 | cs:4291 | from 150: dots move by minus the absolute table value plus a fall speed ds:0B38 that grows by one row every 8 frames (they burst up and fall); grey fade from 3Fh | grey reaches 1 |
| 11 | cs:4313 | from 120 to 150 every dot moves up one row per frame, dies at offset <= 140h; sound 0Eh at 125 | count 150 |
| 12 | EP9-13 only [cs:3E22] | a band of subtractions on the colour bytes (6, 6, 0Ah, F6h, FAh, FAh on 6 neighbouring dots, at 5 places 32 dots apart) moves along the colour array by one dot per frame (cs:3E20) | never |

  EP9-13 fades write red (cs:391D: the level into R, 0 into G and B) and kill flying dots outside the strip
  (EP10 effect 1: y 1..30).

### How the port runs it

`DotEffects` finds the layout by code signature in all 13 EXEs (`DotEffects.find`: the dmd_message prologue
`push es; pusha; cmp ah,2; jbe; sub ah,3`, its stores, and render_frame's `cmp word [counter],0 / cmp byte
[effect],1` head; the end of the blocks is effect 1's `jae +3; jmp END`). It keeps a private copy of the data
segment (a `RulesMachine` with no engine attached, built from the EXE) and:

* `start` does what dmd_message does after its font routine (the list comes from `DotText`, which is the
  original's list word for word, checked against the harness);
* `step` runs the effect blocks cs:3E35..4373 from the EXE in `MiniX86` (recursive-descent validated; CS
  variables kept privately; `MiniX86.portWrite`, a new optional hook that is nil for the rules, captures the
  DAC writes; the effect sounds are collected in `sounds`: the presentation ignores them, EP1's glue and on EP2-EP13
  the rules runtime's own copy of the effect blocks play them, section 6);
* `plotted` reads the list back as the plot loop would.

Nothing is written into the rules' data segment. The rules runtime reports, additively in `PresentationState`:
`MessageRef.serial` (dmd_message calls), `renderFrames` (render_frame calls since the call), `counter` (EP1:
the counter the rules keep exactly, including values other code stores, such as the boot's 32h at cs:04C1),
and `TextRef.messageSerial` / `afterRenders` (where a draw_text line joins the list). `MessageAnimator.follow`
replays this once per original frame: a new serial restarts the list, then one render_frame per tick with the
lines appended between the calls they were drawn between, then the counter is taken from the rules where they
know it. What is shown is the result of the last render_frame call, so a message started after the frame's
render_frame (from a physics step) is first drawn in the next frame, as in the original. `ClassicPresentation`
hands the dots to the composer (`DotMessage.liveDots` / `liveColours`) and DAC 255 to the palette pass. A
message given with `--message` animates from its first frame (`--frames N` shows frame N).

### Verification

* `DotEffectsTests.testMatchesOriginalCodeLive`: 104 cases on all 13 tables (every effect on EP1 and EP10,
  effects 1, 3, 5, 8, 10 and on EP9-13 also 7 and 12 elsewhere, a font5 message per table, draw_text lines added
  while EP1 effect 5 and EP10 effect 12 run). The harness (`tools/emu/dot_effects.py`) calls the original's
  dmd_message and render_frame; after every render_frame call the plotted dots, the EP9-13 colour bytes, DAC 255
  and the end frame must be identical: **25,863 frames, all identical** [H].
* `DotEffectsTests.testGameMessagesMatchOriginalLive`: EP1 in full mode, the 31 one-player scenarios of
  RulesLiveTests, both rules backends: after every frame the dots the port shows equal the dots the original's
  plot loop drew in that frame (or both nothing), and DAC 255 on every frame with dots: **5,212 frames with
  dots, all identical, on both backends** [H].
* DOSBox-X captures of the running game (`scratch/present/frames`, compared after 6-bit DAC rounding): EP10's
  start-of-game message (file 0x11DC, AX 7 = colour cycling, colour 4Bh) rendered with
  `--message 0x11dc:0x7:0x640:0x4b --frames 39` equals the captured strip at frames 240-420, **0 of 9,280
  strip pixels differ**, including the dots in the second colour. Its idle display and two hint messages equal
  frames 60-180, 480-600 and 660-780 (0 pixels). EP1 whole frames: section 2.

## 2. EP9-13 message colours and strip

* dmd_message copies the DS colour byte (EP10/EP9 ds:00C5, EP11-13 ds:0039) into the colour of every dot
  (cs:15F0); the rule code stores it just before the call and puts back FFh after (EP10 cs:04F6/0501). The text
  routines that append lines read the same byte into a CS variable and store it per dot (EP10 cs:4C65, 4CB2).
  The runtime now reads the byte at each call (`DotEffects.find` gives the address, `textColourVars` the
  routines): `MessageRef.colour` / `TextRef.colour`, which replace the table's most common stored value. [H:
  every EP9-13 case in 1.3 checks the colours]
* While a dot message is plotted (the idle display included), render_frame clears the strip itself: row 0 to
  11h/22h/10h/10h/10h and rows 1-29 to 3Fh/AEh/1Eh/1Eh/00h in EP9/10/11/12/13 (EP10 cs:3F07 / cs:3F1D;
  EP11 cs:3F0C stores 2222h then 1010h). The port drew draw_status_panel's row-0 colour (EP10 23h) and EP9's
  dmd_clear colour (AEh). `StripSpec.dotBorder` / `dotFill` are scanned from the code. [H: harness VRAM after 30
  frames of each table, and the EP10 captures above, where row 0 was the only difference before]

## 3. Palette fades (EP1-8)

What the original does (EP1; EP2-8 have the same routines at other addresses) [H code; checked as below]:

* **Boot fade-in** (cs:1301, from init cs:0421): working palette W (ds:5012, 6-bit) = 0, then 17 passes (15 in
  EP7, `cmp ch,11h`) of `if W < B>>2: W += ((B>>2 - W) >> 3) + 1` over the base palette B (ds:0DC0), one frame
  each. 17 passes do not reach B>>2 for bright colours (63 ends at 60): **the first ball is played with this
  palette**, 1-2 levels darker in 125 of 768 EP1 components.
* **Ball lost** (ball_lost_fade cs:32E9..3333): 3 passes of `if W: W -= (W >> 3) + 1` written straight to the
  DAC (no frame wait, an immediate dim), then the between-balls flag ds:096F = 1.
* **Next plunger release** with the flag set (cs:0BD3..0C46): W = B>>2, DAC 0..254 = W, flag = 0.
* **EP7** darkens B itself at boot (cs:0311..0324: `B -= B >> 2`), so the whole game is a quarter darker than the
  palette in the EXE (and in palette.json). No other table changes B (checked in the harness for EP1-8).
* EP3, EP5 and EP8 have the boot fade-in but no ball-loss dim. EP9-13 fade in during their boot intro to
  exactly B>>2 (EP10: W = B>>2 after boot in the harness), so they play with the base palette.

`PaletteFade.find` takes W, B, the pass counts and the flag from the code (the flag must be set only after the
dim and cleared only next to the B -> W copy). The rules runtime mirrors W: the boot result at `boot()`; the dim
when the flag goes 0 -> 1; the restore when it goes 1 -> 0. On every table the rules now set and clear the flag
as the original does (2026-10-01): EP1 through its glue (`fadeTail`, `release3`), EP2-EP7 through the end-of-ball
hook after the palette loop (EP2 cs:35F0 `mov byte [0713h],1`, docs/formats/rules.md 4.1 item 5) and the plunger
lane's `release2` glue (EP2 cs:0CB8..0CFA: with the flag set, the next-ball message ds:0714, the bonus counters
ds:0169..016F cleared, W = B >> 2, flag 0). The earlier workaround (dim at the ball_lost_fade call, restore at the
next release, [M]) is gone. [H: `tools/emu/scenarios/EP{2,4,6,7}/fidelity/release.json` watch the flag frame by
frame; PaletteFadeTests below] Entries 0..254 where W
differs from the EXE palette go out as `paletteOverrides` (6-bit values widened like the DAC read-back); EP8's
ring overrides come after them; DAC 255 stays the message colour.

Verification:

* `PaletteFadeTests.testMatchesOriginalLive`: EP1-8, a drain, the end of the ball and the next plunge, 420 frames
  in full mode; the harness's working palette after every frame (EP8 without its rotating ring entries) equals
  the port's: **420/420 frames on every table and both backends**, with the dim and the restore on EP1, 2, 4, 6
  and 7 [H].
* DOSBox-X: EP1 rendered with the lifted rules at frames 340, 400 and 460 equals the captures at 540, 600 and 660:
  **0 of 76,800 pixels differ**. The build before this work differs in **9,713 pixels** of frame 400 (all of
  them the boot fade-in's darker colours: every colour in the capture is a W colour, 41 are not in B>>2). Later
  captures show other hint messages (the DOSBox run typed keys), so they cannot be compared. EP4 frame 210 equals
  capture 480 (0 pixels differ).

### 3.1 The visible fades (all 13 tables)

What the original does (EP1 addresses; EP10 in brackets) [H code, checked by running as below]:

* **Boot fade-in, EP1-EP8**: init (cs:0421) calls cs:1301 with the display start at row 0: W = 0, then 17 passes (EP7
  15) as in section 3, each written to DAC 0..255 (DAC 255 too) and followed by one wait_frame (cs:0249). Then the
  intro scroll (cs:0479: display start 80*k for k = 1..177, one wait_frame each) shows the table at that palette.
* **Boot fade-in, EP9-EP13** [EP10 cs:12B6, called from the intro loop cs:0478 before each wait_frame]: while the
  intro frame counter ds:4843 is below 22h, one pass with `>> 4` instead of `>> 3`; the scroll starts at row 1 and runs
  182 frames. 34 passes, 32 of which change W; it ends at exactly B >> 2.
* **Fade-out** (cs:136F [cs:131B]): 18 passes (`cmp ch,12h`) of `if W: W -= (W >> 3) + 1` over DAC entries 0 ..< n,
  n = ds:0AD3 [ds:060B] (0 = all 256), one wait_frame each. Only the quit path calls it (pause_menu cs:13DD, cs:14FA),
  and the table EXE exits to the launcher after it. The end of a game goes there directly (cs:351C..3529: DI = 3039h,
  ds:0AD2 = 1, n = FFh, so DAC 255, the message colour, stays). EP1-EP8: after the 5th pass (`cmp ch,4`, cs:13BC), with
  ds:0AD2 = 1 and not in demo mode, the final-score screen cs:3832 runs (a dot message, held until a key or 410 frames),
  then the other 13 passes. EP9-EP13 show their final-score screen before pause_menu (EP10 cs:0533) and fade all 18
  passes after it. The quit prompt (Esc, then Y) and a key in demo mode take the same path with n = 0.
* **The P pause does not fade** (cs:0DCB: dmd_clear, the PAUSED picture cs:49DE, wait for a key), and neither does the
  quit prompt itself (cs:13DD shows a dot message and waits). cs:1301 is called from init only, so there is no fade-in
  after a pause either.
* EP8: wait_frame (cs:0240) first calls the palette rotation (cs:1281), and the intro loop calls it once more per frame
  (cs:0435), so the ring rotates inside W during every fade: the boot leaves W's ring rotated and the rotation counter
  ds:04A5 at 3, not the ring at B >> 2.

How the port shows them: `ScreenFade.find` takes the routines, pass counts, shifts, the counts' DS bytes and the intro
length from the code (the fade-out by `mov ah,[di+W]; cmp ah,0; je; shr ah,3; inc ah; sub [di+W],ah ... cmp al,[N]`,
the EP1-EP8 fade-in through `PaletteFade.find`, EP9-EP13 by `cmp word [cnt],N; jae; pusha; ... lea si,[B]`), and
`ScreenFade.boot` / `fadeOut` replay them on a copy of W and the DAC (with EP8's rotation in every wait_frame). In the
app (`GameController`, `ScreenFadePlayer`, one DAC frame per original frame as palette overrides over everything
else):

* every game start (the first one, New Game, R, Watch again, attract games) shows the boot fade-in from black, 17 (EP7
  15) frames on EP1-EP8 and 34 on EP9-EP13, and the game waits for it as the original's main loop does. The intro scroll
  is not shown: the fade plays over the port's starting view (EP9-EP13's fade runs during the original's intro, so its
  34 frames are frames the port adds before play);
* at game over (the rules' pause_menu call) the fade-out starts from the palette on screen (`RulesRuntime.screenMachine`:
  the mirrored W, EP8's ring and DAC ring from the rules) over entries 0..254: EP1-EP8 its first 5 passes, then the
  picture stays at that palette while the port's game-over panel (its final-score screen) is up; EP9-EP13 hold the full
  palette. The panel is shown at once, not after the passes. The next game runs the remaining passes (13, EP9-EP13 all
  18) and then the boot fade-in, as the original's quit path and the next table start do;
* the P pause and the port's Esc menu do not fade, so neither is delayed; a practice state load drops a running fade.
  `EPIC_PINBALL_NO_SCREEN_FADE=1` turns the visible fades off. `--snapshot` frame counts are unchanged (they count frames
  from the first main-loop arrival, after the boot).

EP8's rules now start from the boot's end state: `RulesRuntime.boot` writes W's ring (ds:5138..51F7) and the rotation
counter ds:04A5 from `ScreenFade.boot` and sets the DAC ring the boot left, instead of `PaletteCycle.bootRing`'s B >> 2
(which stays for tables whose fade routines are not found). [H: `tools/emu/scenarios/EP8/fidelity/palette_ring.json`
watches the counter and the 192 ring bytes for 120 frames from the boot: EXACT in full mode, while the old start
diverges at frame 0; parity 830/830 on both backends.]

Verification:

* `ScreenFadeTests.testMatchesOriginalLive` (tools/emu/screen_fades.py boots the original and records the DAC at every
  wait_frame, then calls the fade-out with n = 0 and n = FFh): on **all 13 tables** every fade-in frame (17/15/34), every
  intro-scroll frame (except EP8's rotating ring), W after the boot, EP8's rotation counter and speed, and all 2 x 18
  fade-out passes are identical, 772 DAC frames. Not compared there: DAC 255 after the boot (the boot's dmd_message sets it
  after the fade, EP1 cs:166F) and on EP3 / EP5 entries B0h..BFh, which lamp_update's colour-lamp pulse writes in every
  intro frame (EP3 cs:3A6C -> cs:3B5A, lamps above 32h; the port does not model these colour lamps). [H]
* `ScreenFadeTests.testPlayerSequence` (the app's sequence on a synthetic fade) and
  `ReplayFrontEndTests.testScreenFadesAroundAGame` (EP1: the session's first game fades in, a one-ball game ends with 5
  passes over 255 entries and the panel up, New Game queues 13 + 17 frames). A window capture of EP1 at 0.05 s and
  0.15 s after the first frame shows the table partly faded in, with no engine frames run yet.

## 4. EP8's robot set

* cs:A42F (`push ds; pusha; push es; mov dx,3F88h; mov ds,dx; mov cx,6; ...`) blits 6 planar records from
  segment 3F88h into both VRAM pages, from the pointer table 9238h when AL = 1 (the robot figure over the centre,
  x 88..211, y 200..358) and 922Ch otherwise (the background pieces that restore the empty centre). The row
  table it uses (267F:0035) is built at boot and is `y*80` (harness). [H]
* Sensor handler EAh calls it: with ball y >= 250 (and ds:5D07 != 3) it holds the ball each frame and counts
  ds:0739 down from 500 (cs:2E8C); at count 1EAh (the 10th frame) it draws the robot (AL 1, cs:2F27) and shows a
  message, at 0 the background (AL 0, cs:2F0D) and the ball is put at (58, 271). The three show steps jump back to
  the `dec` (cs:2F52, 2F78, 2F88), so the background comes on the 497th frame. [H]
* Both rules backends treat the routine as a display call (no change). The runtime now reports each call as
  `PresentationState.spriteSets` (direct backend: AL from the registers; lifted backend: the `mov al,imm` before
  the call in the executing block, `RulesMachine.currentBlockIP`). `ClassicPresentation` collects them across
  frames and the composer blits the records into VRAM like lamp overlays, before that frame's lamp changes; the
  HD replay finds them through `ClassicComposer.extraSprites`.
* `SpriteSetTests.testRobotShowMatchesOriginalLive`: a patch of sensor colour EAh under a resting ball in full
  mode: the original calls cs:A42F in frames 9 (AL 1) and 496 (AL 0), and so does the port on both backends [H].
* What VRAM holds: the original never redraws the robot set except through these calls, and nothing at boot calls
  cs:A42F (its only callers are cs:2F0F and cs:2F29), so a new game (a fresh table start) shows the playfield as
  loaded. The background ("off") records are the playfield's own pixels [H: `SpriteSetTests.testComposerBlitsRobot`,
  VRAM after on + off equals the playfield]. The rules now report the last call per routine since boot
  (`PresentationState.spriteSetsShown`, additive, nil when the producer does not track it; kept in save states,
  cleared at boot), and the composer draws that state again after it resets VRAM (lamp slots back to "not drawn": a new
  game, a practice state load) and whenever a state load changes it (`ClassicComposer.syncSpriteSets`). Before, a reset
  dropped the robot while the rules still held it. [H code; `SpriteSetTests.testComposerKeepsRobotAcrossReset`,
  `testRulesTrackRobotState`] Not decided by running: after such a reset the robot is drawn before the lamps, while in
  the original a lamp drawn before the robot stays covered until it changes [M].

## 5. Tools and hooks

```sh
.venv/bin/python tools/emu/dot_effects.py --table 10 --string 0x11dc --ax 0x7 --di 0x640 --colour 0x4b --frames 120
.venv/bin/python tools/emu/dot_effects.py --batch CASES.json -o OUT.json     # what DotEffectsTests runs
.venv/bin/python tools/emu/dot_effects.py --games GAMES.json -o OUT.json     # full-mode scenarios: dots, DAC 255,
                                                                              # working palette, sprite-set calls
.venv/bin/python tools/emu/screen_fades.py --tables 1,8,10 -o OUT.json       # boot DAC per frame, fade-out passes
.venv/bin/python tools/emu/plot_skip_check.py --tables 9,10,11,12,13         # EP9-13 render_frame plot skip
swift run EpicPinball --table 1 --message 0x8de:0x101:0x12c0 --frames 215 --snapshot out.png   # effect 1, frame 215
```

## 6. Not done

* (Done 2026-10-01) EP2-13's rules keep render_frame's message counter in their data segment (EP2 ds:0A22,
  EP8 ds:0A83, `DotEffects.Layout.counter`): the effect blocks run from the EXE on a private data segment with an
  empty dot list (`RulesRuntime.counterEffects`), the counter and step words are copied back, and the effect
  sounds (e.g. EP2 700Dh when an effect-1 fade starts) are played. Values other code stores (the boot's 32h, EP2
  cs:049A, run by the `bootTail` glue) are taken over, and `MessageRef.counter` is now set on every table. The effect
  sounds go through sfx_play (`RulesRuntime.sfxPlay`, the path EP1's glue uses) into `PresentationState.soundEvents`
  and the app's audio [H: the harness records every `call far sfx_play` of the effect blocks (EP1 cs:3E6B, 41EF,
  4256, 4340): in `DotEffectsTests.testMatchesOriginalCodeLive` the sounds of all 104 cases (26 sounds) equal the
  port's frame by frame; `testRulesPlayEffectSoundsAllTables`: an effect-1 message plays its sound once on EP2-EP13
  with both backends (EP2-EP8 at the 199th render_frame, EP9-EP13 at the 149th; EP5's effect blocks play none)].
  Frame waits inside ball_lost_fade step render_frame as the original's wait_frame does (EP2 cs:0244 calls
  cs:3EDD). [H: the fidelity scenarios watch the counter word frame by frame on EP2-EP13] Not copied back: the
  other bytes the effect blocks write (EP2's fade level ds:0A24, the dot list, the delay buffer), which only
  render_frame reads.
* EP9-13 render_frame's plot skip (EP10 cs:3ED7 `cmp word [0619h],2; ja`): ds:0619 is 0 after every dmd_message
  (cs:1614), 1 at the end of the idle display (cs:341B, store cs:34D4) and counts render_frame calls while non-zero
  (cs:3F7E); above 2 the call clears nothing and plots nothing (and leaves an ended message's counter at 0FFFFh, which the
  rules runtime models, `renderTail`). Checked by running (`tools/emu/plot_skip_check.py`, EP9-EP13, the demo for 4,000
  frames and a one-player game with plunges and flips until the original waits for a key, 1,529 to 3,902 frames) [H]:
  * **the dots do not change**: at every skipped call (281 to 2,617 per table) the counter is not 0FFFFh and the dots and
    colours the plot loop would draw equal its last plot (the idle display is effect 0 and was drawn twice before the
    skip). No call was skipped in the demo runs (why was not looked into);
  * **but other writes into the strip stay**: the main loop's background restore (EP13 cs:0F7E -> cs:4724, `rep movsb`
    cs:478A; the same routine 86 bytes after `cmp word [1Ch],84D0h` on EP9, EP11, EP12) restores a draining ball (row
    392..401) on the second VRAM page (base 84D0h), whose rows past A000:FFFF wrap to A000:0000, the strip: offsets
    21..904, strip rows 0..11 (EP13 frames 133 and 135). Without the skip the next render_frame clears the strip; during a
    skip these bytes stay on screen until the next dmd_message. Seen on EP9, EP11, EP12 and EP13 (EP10's run had none).
  The port draws neither the wrap nor the skip, so its strip stays clean there; modelling the skip alone would change no
  pixel. Not modelled: the wrapped restore into the strip (the composer has no second page) [H for the mechanism; how long
  the residue stays depends on the next message].
* (Done) The robot set is kept across VRAM resets (section 4).
* (Resolved by the counter above for messages whose end does not depend on the dot list; kept for the record.)
  Two views of "the message is alive" on EP2-13: the rules kept reporting `state.message` after render_frame's
  effect had ended it (they did not run the counter), while `ClassicPresentation.currentMessage()` returns nil from
  that frame on. `MessageAnimator.follow` stops stepping there (no render_frame runs without an active message;
  later draw_text lines still join the unplotted list, as in the original). Consumers of `state.message` other
  than the presentation (audio, diagnostics) still see the message. `DotEffectsTests.testFollowRulesMessagesAllTables`
  plays 2,500 auto-player frames per table with the real rules through `follow` (EP2, 4, 6, 7, 8 and 12 reach the
  ended-but-reported case).
* (Done) EP8's ring starts as the boot leaves it (section 3.1), not from B >> 2.
* EP3 / EP5 colour lamps: lamp_update drives lamps above 32h through DAC entries B0h..BFh (EP3 cs:3A6C -> cs:3B5A,
  per-frame pulse through cs:3820), not through sprites. Found while checking the fades (the harness DAC, `ScreenFadeTests`);
  not modelled.
* The fades are palette overrides: they reach everything the classic path draws through the palette. HD-pack
  sprites and playfields in the enhanced path are RGB textures, so the dim and the boot palette probably do not
  reach them [L: not checked].
