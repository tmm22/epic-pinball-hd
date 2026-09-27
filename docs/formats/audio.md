# Audio: SFX banks, music, the MASI API, and the Swift player

Static analysis of `PINBALL.EXE`, all 13 `EPn.EXE` and the Sound Blaster driver
`MDRV004R.MUS` (CD v2.1). There is no dynamic confirmation yet: nothing was captured
from DOSBox-X. Confidence tags are as in engine.md: **[H]** read directly from code or data,
**[M]** inferred with a small gap, **[L]** guess.

Addresses:
* `PINBALL.EXE`: MZ header 0x400 bytes. `pb:XXXX` is an offset in the launcher's
  first code segment (file = `0x400 + XXXX`). Its MASI library segment is 0x708
  (`708:XXXX`, file = `0x7480 + XXXX`).
* `cs:`/`ds:` are EP1 as in engine.md. `MDRV004R.MUS` offsets are file offsets
  (the driver is a flat image with a `REAL16`/`MASISBSERIES` header).

This extends engine.md section 7 and does not repeat it. No game data is reproduced here.

## 1. Which bank and song each table uses [H]

| Caller | AX passed to the loader `pb:0CCA` | Files loaded |
|---|---|---|
| startup `pb:0520`, back from a table `pb:3E5C` / `pb:44E8` | 0 | `song0.psm`, `sfx0.pin` (launcher menus) |
| table launch `pb:3CFB..3D03` | `[pb:6C5C] + 1` | `songN.psm`, `sfxN.pin` for `EPN.EXE` |
| `pb:25F8` (a launcher screen, not identified) | 0xFFFF | name becomes `song00.psm` (not on the CD) and `sfx5.pin` [M: purpose] |

* `[pb:6C5C]` is the selected table 0..12. The same index picks the EXE name from the
  pointer table at `pb:64AE`, which gives `ep1.exe` .. `ep13.exe`. So **table N uses SFXN.PIN and SONGN.PSM**.
* `pb:0CCA` builds the song name in place from the template at `pb:0CBD` (`song` + 1 or 2
  decimal digits + `.psm`). It loads it with `708:0934`, then calls the SFX loader `pb:197D`
  with the same AX. That loader indexes the pointer table `pb:188B` into the string list
  `sfx0.pin` .. `sfx20.pin`.
* The loader then starts the module (`708:0217`: driver function 8 = stop, set up, 7 = play,
  from the start), and sets the music and SFX volumes (`708:054F` = driver function 0x1A with
  `[pb:6226] << 5`, `708:0569` = 0x1B with `[pb:6291] << 5`). Before running the table
  (`pb:3D0A`) it pauses the music (`708:033E` = function 9, AX = 1).
* Every PSM on the CD has exactly one subsong. libopenmpt names it after the launcher's
  `MAINSONG` chunk (string at file 0x4FC; the module loader compares chunk ids with `SONG` at `pb:7C11`).
  SONG0 and SONG13 have 8 channels, the others 4.

## 2. What the tables do with music [H]

All 13 table EXEs make exactly the same kinds of MASI calls. Found by locating the API stub by its
byte signature and every far call to it (EP1 stub `3D35:0000`, file 0x3D750):

| Function (BX) | EP1 site | Meaning |
|---|---|---|
| 0x0C | cs:01E1 | play sample (ES:DI = descriptor), returns a voice handle |
| 0x0F | cs:01C0 | stop voice (the channel's previous handle) |
| 0x11 | cs:0235 | set pan, CX = `pan*16 - 128` |
| 0x0A | cs:046F (init, after fade-in, if `opt_music`), cs:0FA1 (M key) | resume music |
| 0x09 | cs:0FED (M key, AX = 1) | pause music |
| 0x1C | cs:1520 (exit) | shutdown |

The launcher's library wrappers confirm the numbers: `708:033E` loads AX from its argument
and calls driver function 9, and `708:0358` calls 0x0A. EP2's M-key code calls function 9 in
both branches. The second call's AX is not set there, so it is probably 0 = unpause [M].

**The tables never change song or order.** The music is SONGN's single subsong, started
from order 0 by the launcher. The table only pauses and resumes it, and otherwise
it loops by its own pattern flow. EP1 does not reach the player state any other way: its only other use of the
sound pointers is at exit, when it writes a score block into the sample-descriptor area (`pause_menu` cs:158D), which the launcher reads back
(not music). So `MusicRequest.order` is not needed for classic mode. It is supported for
the launcher, for remake features, and in case a later RE pass finds a jump.

## 3. SFX bank loading (launcher `pb:197F..1A33`) [H]

* Read 0x64 header bytes = 25 entries `(u16 len, u16 paras)`.
* For each entry in order: stop at the first `paras == 0`. Otherwise seek to `(paras+1)*16`,
  set descriptor `+0x36` (length) to `len - 0x28` and `+0x38` to 0, set flags byte `+0x00` = 0x10,
  and load (`708:0803`). Then set `+0x33` = 0xFF (no voice), `+0x43` = 7, `+0x44` = 0x64,
  and `+0x45` (rate) = 8000. Descriptors are 0x60 bytes, starting at `pb:0EBC`.
* `708:0803` reads the bytes. It calls the delta decoder `708:009D` (running sum) **only if
  flag 0x10 is clear**, so the banks are stored raw. Looking at the bytes, they are **signed 8-bit** (smooth
  waveforms around 0; the SB mixer indexes volume tables with the raw byte).
* Descriptor index = header index = the sound id the table passes in AL to `sfx_play`.
* Checked against all 14 banks: every loaded entry satisfies `(paras+1)*16 + len-40 <=` file size.
  The header `len` counts from `paras*16`, and neighbouring entries overlap by about 8 bytes.
  The launcher skips the first 16 and the last 24 bytes of each entry. Why is not known [M].
* Output rate: the driver's step is `rate / mix_rate` as 16.16 fixed point, computed when the sample starts
  (`MDRV004R` 0x9AF..0x9B4 -> 0xB03). **Pitch changes only at the next play.** Mixing is
  nearest neighbour (unrolled loop from 0x1254: `mov bl,es:[si]` + 16.16 add, no interpolation).

## 4. `sfx_play` semantics (EP1 cs:014A, same in all tables) [H]

1. If SFX are off (`opt_sfx`, the S key) or no driver is present, return. With no driver, the id goes to the PC-speaker path instead.
2. `sfx_channel_rr = (sfx_channel_rr + 1) mod 4`, so channels are used in the order 1, 2, 3, 0, 1, ...
3. Write the global `sfx_rate_hz` (ds:0ADC) into the sample's descriptor `+0x45`.
4. If the channel holds a voice handle, stop it (0x0F). Then play (0x0C) and store the new handle.
   **At most 4 effects sound at once, and the 5th cuts the oldest.**
5. Pan: `ah >> 4` if non-zero, else `ball_x / 20`, clamped to 15. Sent as `pan*16 - 128`.

The driver allocates the first free hardware voice (`MDRV004R` 0x8C4, owner byte 1 = SFX)
among `[0x2C1]` voices. That total is set at init and shared with the music. It is not
known whether 4 SFX voices plus the music ever run out [M].

**The rate is a global, live variable** (`sfx_rate_hz`). Any sound started while a sweep or a
rule has changed it plays at that rate. The main-loop sound code (cs:08A6..09D6) runs once per frame:

| Counter | Every | Rate change | Stops when | Plays each step / at end |
|---|---|---|---|---|
| `sfx_sweep_small` ds:0AE5 | 32 frames | +500 | >= 10500 (then 11000) | sound 0x12 / - |
| `sfx_sweep_up` ds:0ADE | 8 frames | +2000 | >= 24000 (then 11000) | `ds:0AE1` / `ds:0AE3` |
| `sfx_sweep_down` ds:0AE6 | 16 frames | -1000 | <= 3000 (then 11000) | `ds:0AE7` / `ds:0AE9` |
| `sfx_pending` ds:0012 | - | forced 11000 for this play, then restored | - | the queued id, then a 5-frame gap |
| `sfx_now` ds:0ADF | - | current rate | - | id, once |

So the original's "sweeps" are **trains of re-triggered sounds** at stepped rates, not glides
of a playing voice. They are lifted into `rules.json` (`sound_sweeps`, see rules.md). The producer
(the rules port) should emit one `SoundEvent` per trigger with the rate current at that
moment and `sweepFrames = 0`. That is exact. `SoundEvent.sweepPerFrame/sweepFrames` are a
continuous glide on the playing voice. The original tables never do that, but the mixer supports it.

## 5. Launcher volume settings [M]

`[pb:6226]` (music) and `[pb:6291]` (SFX) are levels 0..7. The menu at `pb:4B36` / `pb:4B99`
cycles them, and 0 turns that output off (`[pb:622B]` = music on). They are sent to driver
functions 0x1A/0x1B as `level << 5`. Built-in defaults are 4 and 4 (file 0x6626 / 0x6628),
but `config.pin` overrides them. The driver's volume curve and the music:SFX balance were not traced.

## 6. The Swift player (`app/Sources/PinballAudio`)

All data is read at runtime from the user's `original/` directory
(`OriginalDataLocator`: explicit path, `$EPIC_PINBALL_ORIGINAL`, `$EPIC_PINBALL_DATA/../original`,
`<package>/../original`).

### API

```swift
let audio = try AudioEngine(dataDir: originalDir, table: n)   // loads SFXn.PIN + SONGn.PSM
try audio.start()                        // AVAudioEngine + AVAudioSourceNode
audio.startTableMusic()                  // song n from order 0, unpaused (launcher + table init)
audio.present(state)                     // per frame: state.soundEvents + state.music
audio.submit(events: [SoundEvent])       // with SoundEvent.pan (0...15; -1 = centred)
audio.submit([SfxCommand(sample:rateHz:sweepPerFrame:sweepFrames:pan:)])  // with pan 0...15
audio.setMusic(MusicRequest(song:order:)) // song < 0 stops; order < 0 keeps position; loads on demand
audio.setMusicPaused(true/false)         // the tables' M key
audio.setVolumes(master:sfx:music:)      // linear; AudioVolumes.gain(forLauncherLevel:) maps 0...7
audio.stopAllSounds(); audio.stop()
```

Offline (tests, tools): `OfflineAudioRenderer(dataDir:table:)` or `(bank:modules:sampleRate:)`,
`render(script: [ScriptedAudioEvent], seconds:) -> RenderedAudio`, `.writeWAV(to:)` (16-bit
stereo). An event at game frame f is applied at output sample `floor(f * rate / 59.94)`.
`ClassicSoundMap` holds the table-to-file mapping and the constants above.
`SfxBank` and `MusicModule` are the loaders.

### Behaviour

* 4 logical channels, round-robin exactly as `sfx_play`. A new play replaces the voice on its
  channel. Invalid sample ids or a rate <= 0 are ignored and do not use up a channel.
* Resampling: 16.16 step `floor(rate * 65536 / outputRate)`, the driver's formula, at
  the output rate. `AudioOptions.interpolation = .original` (default) is nearest neighbour
  for SFX, with libopenmpt interpolation filter length 1 for music. `.smooth` uses linear SFX and
  libopenmpt's default filter. The original's aliasing depended on the user's mixing rate
  (not on the CD, see engine.md), so it is not reproduced.
* Sweeps (`sweepPerFrame`, `sweepFrames`): at each game-frame tick
  (`floor(k * outputRate / 59.94)`) the voice's rate changes by `sweepPerFrame` and its step is
  recomputed, `sweepFrames` times (minimum 1 Hz).
* Pan: `SoundEvent.pan` (0..15 as sfx_play computes it, -1 = centred; filled by the rules
  runtime) becomes `SfxCommand.pan`. `SfxCommand.pan` 0..15
  uses a balance law (`L = min(1, 2(1-x))`, `R = min(1, 2x)`, `x = pan/15`) [L: the
  driver's pan law was not traced]. `ClassicSoundMap.pan(forBallX:)` gives the original's fallback.
* Music: one libopenmpt module per song slot (0..31), repeat forever. Paused music outputs silence
  and keeps its position. Mix = `master * (sfx * sum(voices) + music * module)`, hard-clipped to
  +-1. Default gains master 0.9, SFX 0.5, music 1.0: the effects then measure about 5 dB above the music
  (EP1 renders), which is a guess at the balance [L].
* Real time: commands go through a lock-free SPSC ring (producers serialised by a lock the
  audio thread never takes; acquire/release helpers in `COpenMPT/shim.h`). The render callback
  touches only raw pointers: no allocation, no locks, no Swift arrays. Modules are created on
  the control thread and handed over by pointer. Slots are write-once and freed only when the
  engine is released. libopenmpt's `read_float_stereo` and `set_position_order_row` are
  treated as real-time safe. That is how libopenmpt is normally used, but it is not guaranteed [M].
* SFX start with render-block granularity in real time (the queue is drained once per block).
  Offline rendering is sample-exact to game frames.

### Tests (`app/Tests/PinballAudioTests`)

Synthetic banks check parsing and the launcher trim, rendered length and pitch at
3000..24000 Hz (exact 16.16 length, zero crossings), a frame-tick sweep against a
reference loop, round-robin and stop, pan, event timing, and the WAV header. With the user's files present:
all 14 banks parse within their files, SONG1 opens (psm, 4 channels, 1 subsong),
an order jump, music render and pause, the real AVAudioSourceNode graph in manual-rendering mode,
and WAVs written to `scratch/audio/` (`ep1_demo.wav`, `sfx1_all_11000.wav`). Tests that need
user files skip when those files are missing. `EP_AUDIO_LIVE=1 swift test --filter LiveOutputTests` plays about 1.5 s through the real output device (checked: starts, plays, stops, no dropped commands).

## 7. Not done / open

* No DOSBox-X audio capture to compare pitch, balance, or pan law against.
* The PC-speaker fallback (`pc_speaker_tick` cs:44C8, used when no card is present) is not ported.
* The purpose of the launcher's AX = 0xFFFF path (`pb:25F8`) was not identified.
* The MASI API function names are inferred from their use (0x09 pause, 0x0A resume,
  0x0C play, 0x0F stop voice, 0x11 pan, 0x1A/0x1B volumes, 0x1C shutdown, 7 play module, 8 stop module).
