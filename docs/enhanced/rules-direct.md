# Table rules straight from the user's EXE (direct backend)

The app no longer needs `rules.json` (the Python lifter's output, `tools/rules.py`). Each table's
sensor dispatcher, sensor handlers, kicker routine and main-loop / end-of-ball rule fragments are
located in the user's own `EPn.EXE` at load time and executed from its bytes by `MiniX86`, with every
engine-owned data-segment byte bound to `ClassicEngine`, exactly as the lifted interpreter
(`RulesMachine`) does. Nothing from the game is in the source: only code shapes (byte signatures) and,
for EP1, the addresses of its hand-annotated hooks.

Status (2026-09-28), details in [Verification](#verification):

* Discovery reproduces rules.json on all 13 tables: every engine role, the lamp table, the player
  block, the jump table, the dispatcher, all 12-19 hooks per table (entry, stops, kind, when,
  continues, including EP5's dropped hook) and the display stubs. **0 differences.**
* Against the original machine code (Unicorn harness, `tools/emu/run_suite.py`), direct backend:
  **physics 415/415, rules 415/415, full 413/415** (the 2 EP8 harness errors, as for the lifted backend).
* Lifted vs direct, whole data segment + every sfx_play/dmd_message call + all ball slots after every
  frame: **830/830 scenario runs identical** (139,423 frames), and long random games on all 13 tables
  (see below) identical frame by frame, including the collision buffer and the PresentationState.
* EP1 per-frame check against the original (RulesLiveTests): **13,406 frames identical** (data segment,
  sounds, messages) on both backends.
* Cost: at most **0.1 ms per frame** (release, EP2/EP8, ~1,000 emulated instructions per frame); the
  frame budget at 59.94 Hz is 16.7 ms. Loading (discovery) takes 60-100 ms per table in a debug build.

## Using it

```swift
let r = try RulesRuntime.load(dataRoot: root, table: n)                 // default backend
let r = try RulesRuntime.load(dataRoot: root, table: n, backend: .lifted) // rules.json
let r = try RulesRuntime.direct(exe: bytes, table: n)                    // from EXE bytes
r.backend                                                                // .direct / .lifted
```

* `RulesBackend.default` is **direct**; `EPIC_PINBALL_RULES=lifted` (or `direct`) overrides it for the
  app, `--trace` and the harness (`EPIC_PINBALL_RULES=lifted .venv/bin/python tools/emu/run_suite.py ...`:
  the variable passes through diff_traces.py to the Swift binary).
* If discovery fails on some EXE and a rules.json exists, `load` falls back to the lifted backend and
  records a warning. The lifted backend is unchanged otherwise and passes the same suites.
* The EXE is looked up in `originalDir`, `$EPIC_PINBALL_ORIGINAL`, `<dataRoot>/../original` (development
  layout) and `<dataRoot>/original` (the PinballImport library layout). The engine data (engine.json /
  the importer's equivalent) is still needed for the physics and for the engine bindings.

## What runs from the EXE, what is stubbed

Executed by MiniX86 (`RulesRuntime.runDirect`), all registers 0 at entry as in the lifted graphs:

| piece | entry | registers |
|---|---|---|
| sensor dispatch | the dispatcher routine the pixel scan calls (EP1 cs:1E3B): its level/tilt filters, jump table, the handler, and the dispatcher tail (EP2/3/4/7/8/10) | AX = colour, AH = lockout |
| kicker | the wall loop's kicker call target (EP1 cs:19C1) | DI = 2 x slot, ES:[BX] = the probed pixel (a pseudo segment returning it) |
| main-loop hooks | every `every_frame` hook at its entry, in the same schedule as the lifted backend (ClassicEngine+Rules.swift) | - |
| end of ball | the `ball_end` hooks following `continues`; EP1's annotated ball_end / bonus hooks | - |
| subroutines | every near call and far call into the code segment that is not a stub below (the lifted gosubs and `call` ops: EP6 cs:31E1, EP8 cs:3613 ring reload, EP10 cs:358A, ...), and num_to_text (EP12's reads its powers of ten through DS = another segment of the load image) | caller's |

A run ends like the lifted graphs return: `ret` at depth 0, the dispatcher epilogue (`popa; pop es; ret`
and variants), or a hook stop (the union of all hooks' stops, rules.py `Lifter.stops`). A stop reached
inside a subroutine returns from that subroutine (the lifted gosub returns there); an epilogue inside a
subroutine is executed normally (x86 semantics).

Handled without executing the callee (`RulesRuntime.classifyCall`, shared by both backends):

* display: dmd_message (-> `PresentationState.message`), the dot-message text routines (-> `texts`),
  score_refresh, routines that switch DS/ES to a display segment, the EP1 display routines;
* sound: sfx_play (-> `SoundEvent` at the live rate, same pan rule), far calls into the MASI driver;
* engine: ball_lost_fade, pause_menu (game over), lamp_update (EP1's order table), EP8's palette ring;
* port I/O: `out` is ignored (VGA), `in` returns 0 except 3DAh (bit 3 toggles, as in the harness).

## Discovery (Swift ports, all in `app/Sources/PinballCore/Rules/`)

| file | port of | finds |
|---|---|---|
| `X86Decoder.swift` | capstone (16-bit) | instructions with capstone's mnemonics and operands |
| `ExeImage.swift` | tools/epexe.py, tools/disasm.py `Image.explore` | MZ layout, data segment and size (the playfield chain), recursive-descent disassembly, byte-signature search (the Python regexes, bytes mapped to private-use code points) |
| `EngineDiscovery.swift` | tools/emu/discover.py | frame sync, main loop, ball arrays, kicker call, dispatcher, keyboard ISR flags, physics-mode ranges, ball_lost_fade, drain line, counters |
| `RulesDiscovery.swift` | tools/rules.py `Table.discover` + the collision.py shapes it reads | engine roles (score, ball working copy + writeback, sound queue/rate/now, sweeps, tilt, lockout, cooldown, kicker, extra gravity, gates), routine roles, lamp table, player block, jump table, dispatcher tail |
| `HookDiscovery.swift` | tools/rules.py `Lifter.discover`, `rule_like`, `auto_hooks` and helpers, the "does not lift completely" drop | hooks (entry, stops, kind, when, continues), the global stop set, gosubs, stub routines; EP1: rules.py EP1_HOOKS (addresses only) |
| `DirectProgram.swift` | - | a `RulesProgram` with `direct = true`, no blocks |

The drop rule needs to know which instructions the lifter cannot express; `HookDiscovery.expressible`
models that per instruction (unsupported mnemonics, `adc`/`sbb`/`rcl` without the flag producer the
lifter pairs them with, SS reads, writes outside DS/playfield, calls to non-stub routines). On the 13
EXEs it drops exactly what rules.py drops (EP5 `ball_end_1f4a`).

## MiniX86 coverage (step 1)

`RulesDirectTests.testEveryReachableInstructionIsSupported` walks everything the direct backend can
execute (dispatcher, every jump-table entry, kicker, every hook, every callee the callout executes) and
checks each instruction against MiniX86's subset: **no unsupported instruction and no unresolved call in
any table** (432 to 1,966 instructions per table, 61 to 100 instruction forms). The forms used: the ALU
group on registers, `[disp]`, `[bx|di|si+d]`, `[bx+di+d]`, `es:[..]` (collision buffer) and `cs:[..]`
(keyboard flags, CS tables); `adc`/`sbb` pairs, `mul`/`div`, shifts, `rcl`; `push`/`pop` of registers and
segments, `pusha`/`popa`; `lea`; `loop`; `lodsb`/`stosb`; near/far calls, `ret`, `retf`, `jmp r16` (the
dispatcher's `jmp bx`); `mov sreg` (display segments, checked at run time); `out dx, al` (EP9).

Added to MiniX86 for this (beyond the glue subset): hook stops with subroutine returns, the epilogue
stop, a call-frame stack, far calls into CS with `retf`, `ret`/`retf imm`, a byte-addressed private SS
with BP-based operands and `enter`/`leave`, `jmp`/`call r/m16`, `pushf`/`popf`, `lahf`/`sahf`, `cmc`,
`std` (string direction), `cmps`/`scas` with `repe`/`repne`, `xlat`, `imul` (all forms), `idiv`,
`rcl`/`rcr`, `xchg ax,r`, `jcxz`, `loope`/`loopne`, `push imm`, `les`/`lds`, `in`, read-only access to any
segment of the EXE's load image, the kicker's contact-pixel segment, and an instruction counter. The
glue ranges run exactly as before (MiniX86Tests has a test per feature).

## Verification

Commands (the Swift binary from `app/`, the user's files in `original/` and `extracted/`):

```sh
cd app && swift test --filter RulesDirectTests                 # discovery == rules.json, coverage, parity, library layout
EP_PARITY_FRAMES=60000 swift test --filter RulesDirectTests.testLiftedAndDirect   # long random games
swift test -c release -Xswiftc -enable-testing --filter RulesDirectTests.testPerFrameCost   # cost (EP_BENCH_FRAMES)
EPIC_PINBALL_RULES=direct .venv/bin/python tools/emu/run_suite.py --modes physics,rules,full
EPIC_PINBALL_RULES=lifted .venv/bin/python tools/emu/run_suite.py --modes physics,rules,full
swift test --filter RulesLiveTests                              # EP1 vs the original, both backends
```

Differential suite against the original (`run_suite.py`, 415 scenarios per mode):

| backend | physics | rules | full |
|---|---|---|---|
| lifted | 415/415 | 415/415 | 413/415 |
| direct | 415/415 | 415/415 | 413/415 |

The two full-mode failures are EP8 `hand/ball_ball_hit` and `hand/ball_ball_slot2`, HARNESS_ERROR on the
original side (emulation.md section 12), for both backends.

Lifted vs direct on the suite's scenarios (every table and set, rules and full mode, `--state` traces:
the data-segment diff after every frame, every sfx_play and dmd_message call with its registers, all 5
ball slots and the counters): 830/830 identical, 139,423 frames.

Long random games (`testLiftedAndDirectBackendsAgreeOnLongRandomGames`): both backends side by side from
a new game, AutoPlayer plus seeded random flips and nudges (tilts happen), 1-3 players, new game after
game over; after every frame the whole data segment, the collision buffer, the ball slots, the flipper
angles and the PresentationState (lamps, lamp sprites, scores, player, ball, message, texts, sounds,
palette ring, game over) are compared. LONGRUN

What the comparison found (fixed; both backends now agree and match the original where checked):

* The lifted loader dropped non-constant dmd_message modes (EP8 L2975, EP13 L2372/L2d75 pass AX from a
  register) and reported AX = 0; it now evaluates the expression (EP13 `x_rules_sensor_C6`: AX 0x105).
* The end-of-ball score panel of EP10/11/13 (e.g. EP10 cs:341B, reached through the `continues` cut
  call) calls a dot-message text routine rules.py did not list (cs:4D93), so the run stopped there in
  both backends and skipped `mov word [0619],1; mov byte [00C5],0FFh`. Text routines are now recognised
  by their prologue (`RulesRuntime.textRoutines`).
* Direct-only (found by the parity runs, fixed before the numbers above): the flipper keys must read as
  engine input in rule code (the lifted `["input", ...]`), and the gate routines must run from the EXE
  (the lifted backend drew them from rules.json `gates`).

Cost (release build, `testPerFrameCostOfTheRulesBackends`, 6,000 frames of AutoPlayer games per table,
Apple silicon): the direct backend's whole frame (engine + rules + presentation) takes 0.008-0.097 ms
(EP2 0.097, EP8 0.094, others <= 0.027), executing 28-1,095 x86 instructions per frame; the lifted
backend 0.006-0.089 ms. Both are below 0.6 % of the 16.68 ms frame.

## Limits and open items

* EP1's hooks are rules.py's hand annotation (addresses); discovery only checks that the EXE is EP1
  (code/data segments, kicker entry) before using them, like TableGlue does for EP1's glue.
* Display routines stay stubs (as in the lifted backend): the DMD renderer's own state in its segment
  (the message line pointer [050C]) is not modelled; text lines are reported as `TextRef`s.
* Variable names exist only in rules.json (EP1's annotation); RulesLiveTests resolves EP1 names through
  rules.json when it is present. The direct backend itself needs no names.
* Discovery depends on the same EXE shapes as the Python tools; an unknown EXE version falls back to
  rules.json if present, else loads without rules (physics only) with the error in `rulesLoadError`.
