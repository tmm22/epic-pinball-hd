import Foundation

/// How much of the original main loop the rules layer runs (the emulator harness's modes,
/// docs/formats/emulation.md section 2).
public enum RulesMode: String, Sendable, CaseIterable {
    /// No rules: the physics-only engine (the harness's `physics` mode, the trace contract).
    case off
    /// The harness's `rules` mode: the physics main-loop ranges plus sensor dispatch
    /// (EP1: cs:06E2..0711, 09EC..0A0D, 0A31..0A9A, 0A9D..0C48 without ball_lost_fade, 0DFD..0E8A,
    /// 119F..1236 with ball_pixel_scan).
    case rules
    /// The whole main loop (the harness's `full` mode and the game): timers, sound, lamps, messages,
    /// end of ball, bonus, player switch.
    case full
}

/// Game options that PINBALL.EXE passes on the command line (engine.md section 8).
public struct RulesOptions: Sendable, Equatable {
    public var players = 1
    public var ballsPerGame = 3
    public var sfx = true
    public var music = true
    /// A sound card is present (sfx_play's MASI path; without it the original uses the PC speaker,
    /// which is not ported, so no sound events are produced).
    public var soundPresent = true
    /// Demo mode: PINBALL.EXE's players 'D' (EP1 cs:007A: demo_mode = 1, one player). The table then
    /// plays itself (Attract.swift); off by default.
    public var demo = false
    public init() {}
    /// What the emulator harness passes (emulation.md section 1): 1 player, 3 balls, no sfx/music,
    /// invalid sound pointers (no sound card).
    public static var harness: RulesOptions {
        var o = RulesOptions(); o.sfx = false; o.music = false; o.soundPresent = false; return o
    }
}

/// Runs a table's lifted rules (rules.json) against a `ClassicEngine`: sensor handlers, the kicker
/// hook, the main-loop hooks and the unlifted main-loop fragments (`TableGlue`, executed by
/// `MiniX86` from the user's EXE), and turns the result into `PresentationState`.
///
/// # PresentationState mapping (all from the live data segment; EP1 addresses in brackets)
/// * `lamps[i]` = lamp slot i currently shows sprite "a" (lamp_update drew "a" last: state 1 -> 5 or
///   a blink phase 3 -> 4); false = "b" drawn or never drawn. `lampStates[i]` = the raw state byte
///   [lamps.first + i] (0 off, 1/2 draw a/b once, 3/4 blinking, 5/6 steady a/b; sprites.md 3.1).
///   lamp_update [cs:478D] is run exactly (3 lamps per frame, pending draws first, then the phase
///   byte [lamps.phase] walks the order table read from the EXE).
/// * `scores` = the score dword [engine_vars.score] (plain binary, as the original adds it) as
///   UInt32 for the current player, and for the other players the same offset inside their saved
///   player blocks (pointers at [6571]). `playerCount` [6761], `currentPlayer` = [6760] - 1,
///   `ballNumber` = [675F] (the round number dmd_idle_text prints), `tilted` = [tilted] != 0.
/// * `message` = the active dot-matrix message: `exeOffset` = data_segment_file_offset + DS offset
///   of the string, `mode` = AL (the effect byte render_frame animates, [0B3A]), `modeWord` = AX
///   (AH = font/centring), `position` = DI, `bytes` = the live string (rules patch digits into it),
///   `framesRemaining` from render_frame's per-effect counter [0B3D] ([M], see TableGlue).
///   `serial` counts dmd_message calls, `renderFrames` = render_frame calls since the last one (the
///   clock `DotEffects` replays the effects with); EP9-13 `colour` = the dot colour byte at the call
///   (EP10 ds:00C5, read by dmd_message cs:15F0).
///   `texts` = score-strip text drawn this frame (draw_text routines), same referencing; EP9-13 `colour`
///   = the routine's colour byte (EP10 cs:4C65), `messageSerial`/`afterRenders` place the line in the list.
/// * `soundEvents` = one event per sfx_play call [cs:014A] made this frame: sample = AL, rateHz =
///   the live sfx_rate_hz [engine_vars.sound.rate] at that call, sweepFrames = 0 (the original's
///   sweeps are re-trigger trains, audio.md section 4), pan = AH >> 4 if non-zero, else
///   min((ball 0 x as u16 / 20) & 0xFF, 15). Queued sounds [sound.queue] play at a forced 11000 Hz and
///   then block the queue for 5 frames; all of this is the original's own code (cs:0898..09DC).
/// * `music` stays nil: the tables never change song or order (audio.md section 2 [H]).
///
/// Verification (RulesLiveTests, EP1): in the harness's rules and full modes the whole data segment
/// outside display buffers (lamps, lamp phase, score, player blocks, rule variables, sound queue and
/// sweeps, message effect/counter, ball slots) is identical to the original after every frame, and
/// every sfx_play (AX, rate, pan) and dmd_message (string, AX, DI) call matches [H]. Derived only:
/// `lamps` (which sprite was blitted last) and `framesRemaining` [M].
public final class RulesRuntime {
    public let program: RulesProgram
    public let machine: RulesMachine
    public let glue: TableGlue
    public let x86: MiniX86
    public var options: RulesOptions
    public private(set) weak var engine: ClassicEngine?

    public private(set) var gameOver = false
    /// Diagnostics for differential tests: record every sfx_play call (before the option checks) as
    /// [AX, rate, pan] and every dmd_message call as [DS, AX, DI].
    public var traceCalls = false
    public private(set) var sfxCalls: [[Int]] = []
    public private(set) var messageCalls: [[Int]] = []
    public func clearCallLog() { sfxCalls.removeAll(keepingCapacity: true); messageCalls.removeAll(keepingCapacity: true) }
    /// Load-time and run-time problems (each distinct problem once).
    public private(set) var warnings: [String] = []
    private var reported = Set<String>()
    /// sfx_play calls that happened since the last `takePresentation`.
    public private(set) var pendingSounds: [SoundEvent] = []
    private var pendingTexts: [TextRef] = []
    /// The last dmd_message call (string DS offset, AX, DI). Whether it is still shown is decided by
    /// the message counter (DS [0B3D] when the glue knows it, else `localCounter`).
    private struct LastMessage { var ds: Int; var ax: Int; var pos: Int; var colour: Int = -1 }
    private var message: LastMessage?
    /// dmd_message calls so far and render_frame calls since the last one (`MessageRef.serial` /
    /// `renderFrames`; presentation only, nothing reads them back).
    private var messageSerial = 0
    private var messageRenders = 0
    /// EP9-13: the DS colour byte dmd_message copies into its per-dot colour array (EP10 ds:00C5,
    /// cs:15F0) and the text routines' colour bytes (EP10 cs:4C65 `mov al,[00C5h]`), by routine.
    private let messageColourVar: Int?
    private let textColourVars: [Int: Int]
    /// The palette the original's fades leave in the DAC (`PaletteFade`: boot fade-in end state,
    /// ball-loss dim, release restore), followed through the between-balls flag; presentation only.
    public let paletteFade: PaletteFade?
    /// The base palette as the running game has it (EP7 darkens it at boot) and as the EXE stores it
    /// (the renderer's base palette, palette.json).
    private let fadeBase: [UInt8]
    private let fadeEXEBase: [UInt8]
    private var fadeWorking: [UInt8]?
    /// The mirrored working palette (6-bit, 768) as of the last `takePresentation` (tests).
    public var fadedPalette: [UInt8]? { fadeWorking }
    /// The between-balls flag F as of the last `takePresentation`: set by ball_lost_fade after its dim
    /// (EP1 glue `fadeTail`; EP2-EP7 the end-of-ball hook after the palette loop, EP2 cs:35F0) and
    /// cleared by the release code next to the W = B >> 2 copy (EP1 `release3`; EP2-EP7 lane glue
    /// `release2`, EP2 cs:0CFA), both run from the rules.
    private var fadeFlag: UInt8 = 0
    /// The visible whole-screen fades (boot fade-in, end-of-game fade-out; `ScreenFade`), for the front
    /// end, and the state the boot leaves (EP8: W's ring and the rotation counter, written at `boot`).
    public let screenFade: ScreenFade?
    private let screenFadeBootEnd: ScreenFade.Machine?
    /// Sprite-set routines (EP8 cs:A42F) and the calls made since the last `takePresentation`.
    public let spriteSetRoutines: [SpriteSetRoutine]
    private var pendingSpriteSets: [SpriteSetEvent] = []
    /// The last call of each sprite-set routine since boot (`PresentationState.spriteSetsShown`).
    private var spriteSetsShown: [Int: Int] = [:]
    private var localCounter = 0
    private var localEffect = 0
    /// EP2-EP13: render_frame's effect blocks run from the EXE on a private data segment with an empty
    /// dot list (`DotEffects`), only for the message counter they keep in the rules' data segment
    /// (EP2 ds:0A22, EP8 ds:0A83, EP10 ds:..., `DotEffects.Layout.counter`: 1 after dmd_message, +1 per
    /// render_frame, 0 once the effect has ended) and the sounds they play. Rule code reads the
    /// counter (EP8 cs:296E shows its transport message only while no message runs). EP1 keeps its
    /// glue model (`TableGlue.messageEffects`, checked frame by frame in RulesLiveTests).
    let counterEffects: DotEffects?
    /// EP9-EP13: the flag dmd_message clears and the idle display sets (EP10 ds:0619, cs:1614 / cs:34D4)
    /// and the idle routine render_frame calls when a message ends while the flag is <= 2 (EP10 cs:3ED7:
    /// `cmp word [S],2; ja; ...; cmp word [C],-1; jne; mov word [C],0; call 341Bh`), found by that shape.
    let renderTail: (at: Int, shown: Int, idle: Int)?
    /// EP9-EP13 call render_frame after frame_sync's physics steps (EP10 cs:1238), not at the end of the
    /// main-loop body (EP1 cs:1236): `ClassicEngine.runFrame` then calls `renderFrame` after the steps.
    public let renderAfterSteps: Bool
    private var msgCounterAddr: Int? { glue.ds["msg_counter"] ?? counterEffects?.layout.counter }
    private var msgCounter: Int {
        get { msgCounterAddr.map { Int(machine.read($0, 2)) } ?? localCounter }
        set { if let a = msgCounterAddr { machine.write(a, 2, Int64(newValue)) } else { localCounter = newValue & 0xFFFF } }
    }
    private var msgEffect: Int {
        get { (glue.ds["msg_effect"] ?? counterEffects?.layout.effect).map { Int(machine.read8($0)) } ?? localEffect }
        set {
            if let a = glue.ds["msg_effect"] ?? counterEffects?.layout.effect { machine.write8(a, UInt8(newValue & 0xFF)) }
            else { localEffect = newValue & 0xFF }
        }
    }
    /// Per lamp slot: 0 never drawn, 1 sprite a, 2 sprite b.
    public private(set) var lampDrawn: [UInt8]
    private var genericLampTick = 0
    private var sfxPendingDelay = 0
    private var hookByIP: [Int: Int] = [:]
    private var gatesByRoutine: [Int: [Int]] = [:]
    private var nextBallSkillEntry: Int?
    private var dispatchTable: [Int: (entry: Int, ip: Int)] = [:]
    /// Handler entries whose graph contains an unliftable instruction: run from the EXE (MiniX86).
    private var nativeEntries: Set<Int> = []
    /// Where sensor handlers jump when done (engine.json sensors.exit_ip / the dispatcher's tail).
    public var dispatcherExitIP: Int?
    /// The table's main-loop palette rotation (EP8 cs:1281), if it has one.
    public let paletteCycle: PaletteCycle?
    /// The table's demo-mode code (attract_autoflip EP1 cs:0C48 and its state), if found.
    public let attract: AttractLayout?
    /// The boot's intro loop calls flipper_update every frame (EP9-EP13, EP9 cs:04DE), so the flippers
    /// are at rest at the first main-loop arrival; EP1-EP8 arrive with them at the boot angle.
    public let introSettlesFlippers: Bool
    /// DAC entries the palette rotation wrote last (6-bit; `paletteCycle.firstIndex`...), nil = the
    /// base palette is shown.
    private var dacRing: [UInt8]?
    /// > 0 while a rule-code `call` op runs from the EXE: unknown near calls in there are followed
    /// (MiniX86 still stops at anything outside its subset: port I/O, ES outside DS/playfield).
    private var nativeDepth = 0
    /// Which implementation runs the rule code (`RulesProgram.direct`).
    public let backend: RulesBackend
    /// Direct backend: > 0 while a handler or hook runs from the EXE (the callout then executes
    /// every near call and far call into the code segment that is not a display, sound or engine
    /// routine, as the lifted graphs' gosubs and `call` ops do).
    private var directDepth = 0
    /// EP9-EP13's score_refresh (EP12 cs:3FFE): `cmp byte [demo],1; je R; cmp word [shown],0; je R;
    /// call idle_text; R: ret`. Unlike EP1-8's (a strip redraw, display only), it shows the idle
    /// display again with the new score while that is the message shown (the flag is set at the end of
    /// idle_text, EP12 cs:34F6, and cleared by dmd_message, cs:156E): it runs from the EXE.
    public private(set) var idleScoreRefresh: Int?
    /// EP5, EP6: dmd_message starts `cmp byte [demo],1; jne +0Ah; lea bx,[T]; mov ax,imm; mov di,imm`
    /// (EP6 cs:15AF): in demo mode every message is replaced by the demo's idle text.
    public private(set) var demoMessage: (flag: Int, bx: Int, ax: Int, di: Int)?
    /// `mov word [a],imm` stores just before dmd_message's `popa; pop es; ret` (EP6 cs:1658, EP7, EP9-13).
    public private(set) var messageExitStores: [(Int, Int)] = []
    /// Dot-message text routines (`textRoutines(code:)`): text calls wherever they come from.
    public private(set) var textRoutines = Set<Int>()
    /// Direct backend: the hook stops as a 64 K bitmap for MiniX86.
    private var stopBitmap: [Bool] = []
    /// Direct backend: where the per-frame rule code spends its time (instructions executed by
    /// MiniX86 in handlers and hooks since the last reset), for performance measurements.
    public var directInstructions: Int { x86.executed }

    // MARK: - loading

    public static func rulesURL(dataRoot: URL, table: Int) -> URL {
        dataRoot.appendingPathComponent("tables/EP\(table)/rules.json")
    }

    /// The user's EPn.EXE: `originalDir`, `$EPIC_PINBALL_ORIGINAL`, `<dataRoot>/../original` (the
    /// development layout next to extracted/), or `<dataRoot>/original` (an imported library,
    /// PinballImport `LibraryLayout.originalDirectory`).
    public static func locateEXE(dataRoot: URL, table: Int, originalDir: URL? = nil) -> URL? {
        var dirs: [URL] = []
        if let o = originalDir { dirs.append(o) }
        if let e = ProcessInfo.processInfo.environment["EPIC_PINBALL_ORIGINAL"], !e.isEmpty { dirs.append(URL(fileURLWithPath: e)) }
        dirs.append(dataRoot.deletingLastPathComponent().appendingPathComponent("original"))
        dirs.append(dataRoot.appendingPathComponent("original"))
        for d in dirs {
            for name in ["EP\(table).EXE", "ep\(table).exe", "Ep\(table).exe"] {
                let u = d.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: u.path) { return u }
            }
        }
        return nil
    }

    /// Loads the table's rules for `backend`: direct = the user's EXE only (the rule code is found
    /// and run from it); lifted = rules.json and the EXE. The direct backend falls back to the
    /// lifted one (with a warning) if the discovery fails and rules.json exists. Throws
    /// `RulesError.missingFile` when a needed file is absent.
    public static func load(dataRoot: URL, table: Int, originalDir: URL? = nil, options: RulesOptions = RulesOptions(),
                            backend: RulesBackend = .default) throws -> RulesRuntime {
        if backend == .direct {
            guard let exeURL = locateEXE(dataRoot: dataRoot, table: table, originalDir: originalDir) else {
                throw RulesError.missingFile("cannot find your EP\(table).EXE (looked in $EPIC_PINBALL_ORIGINAL and \(dataRoot.deletingLastPathComponent().appendingPathComponent("original").path))")
            }
            let exe: [UInt8]
            do { exe = [UInt8](try Data(contentsOf: exeURL)) } catch { throw RulesError.missingFile("cannot read \(exeURL.path): \(error)") }
            do {
                return try direct(exe: exe, table: table, options: options, exeName: exeURL.lastPathComponent)
            } catch {
                guard FileManager.default.fileExists(atPath: rulesURL(dataRoot: dataRoot, table: table).path) else { throw error }
                let r = try load(dataRoot: dataRoot, table: table, originalDir: originalDir, options: options, backend: .lifted)
                r.warn("direct rules backend unavailable (\(error)); using rules.json")
                return r
            }
        }
        let url = rulesURL(dataRoot: dataRoot, table: table)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RulesError.missingFile("missing \(url.path)\nRun `.venv/bin/python tools/rules.py \(table)` (reads your own original/EP\(table).EXE) first.")
        }
        let program = try RulesProgram.load(contentsOf: url)
        guard program.table == table else { throw RulesError.invalid("\(url.path) belongs to table \(program.table)") }
        // collision.json (tools/collision.py): the DS variables that hold the playfield segments
        var segVars: [Int: Int] = [:]
        let colURL = dataRoot.appendingPathComponent("tables/EP\(table)/collision.json")
        if let d = try? Data(contentsOf: colURL), let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let cb = root["collision_buffer"] as? [String: Any] {
            for (k, half) in [("top_seg_var", 0), ("bottom_seg_var", 1)] {
                if let s = cb[k] as? String, let a = Int(s.hasPrefix("0x") ? String(s.dropFirst(2)) : s, radix: 16) { segVars[a] = half }
            }
        }
        guard let exeURL = locateEXE(dataRoot: dataRoot, table: table, originalDir: originalDir) else {
            throw RulesError.missingFile("cannot find your EP\(table).EXE (looked in $EPIC_PINBALL_ORIGINAL and \(dataRoot.deletingLastPathComponent().appendingPathComponent("original").path))")
        }
        let exe: [UInt8]
        do { exe = [UInt8](try Data(contentsOf: exeURL)) } catch { throw RulesError.missingFile("cannot read \(exeURL.path): \(error)") }
        let r = try RulesRuntime(program: program, exe: exe, options: options)
        r.x86.playfieldSegmentVars = segVars
        return r
    }

    /// The direct backend for `exe` (no rules.json): `RulesProgram.discover` finds the rule code.
    public static func direct(exe: [UInt8], table: Int, options: RulesOptions = RulesOptions(), exeName: String? = nil) throws -> RulesRuntime {
        let program: RulesProgram
        do { program = try RulesProgram.discover(exe: exe, table: table, exeName: exeName).0 } catch {
            throw RulesError.invalid("EP\(table): the rule code was not found in the EXE (\(error))")
        }
        let r = try RulesRuntime(program: program, exe: exe, options: options)
        r.x86.playfieldSegmentVars = program.segmentVars
        return r
    }

    public init(program: RulesProgram, exe: [UInt8], options: RulesOptions = RulesOptions()) throws {
        self.program = program
        self.options = options
        backend = program.direct ? .direct : .lifted
        machine = try RulesMachine(program: program, exe: exe)
        let image = try? ExeImage(exe: exe)
        let layout = image.flatMap { try? EngineLayout.discover(image: $0, search: ByteSearch($0.code)) }
        glue = TableGlue.make(program: program, machine: machine, layout: layout)
        counterEffects = glue.ds["msg_counter"] == nil ? DotEffects(exe: exe, table: program.table) : nil
        let codeBytes = machine.code
        renderTail = counterEffects.flatMap { Self.findRenderTail(code: codeBytes, layout: $0.layout) }
        if let rf = counterEffects?.layout.renderFrame, let fs = layout?.frameSync {
            renderAfterSteps = (fs..<min(0xFFFD, fs + 0x80)).contains { x in
                codeBytes[x] == 0xE8 && Self.isRenderEntry((x + 3 + (Int(codeBytes[x + 1]) | Int(codeBytes[x + 2]) << 8)) & 0xFFFF, rf, codeBytes)
            }
        } else { renderAfterSteps = false }
        x86 = MiniX86(machine: machine)
        paletteCycle = PaletteCycle.find(code: machine.code)
        messageColourVar = DotEffects.find(code: machine.code)?.colourVar
        textColourVars = messageColourVar == nil ? [:] : DotEffects.textColourVars(code: machine.code)
        spriteSetRoutines = SpriteSetRoutine.find(code: machine.code)
        let fade = PaletteFade.find(code: machine.code)
        let ds = machine.initialDS
        if let f = fade, f.base >= 0, f.base + 768 <= ds.count {
            paletteFade = f
            fadeEXEBase = Array(ds[f.base..<(f.base + 768)])
            fadeBase = f.runtimeBase(fadeEXEBase)
        } else {
            paletteFade = nil
            fadeBase = []
            fadeEXEBase = []
        }
        screenFade = ScreenFade.find(code: machine.code, ds: ds)
        // EP8 only (the rotation runs in every wait_frame of the boot); the other tables leave nothing in DS here
        // that the rules runtime mirrors.
        if let sf = screenFade, sf.cycle != nil, sf.base + 768 <= ds.count { screenFadeBootEnd = sf.boot(ds: ds).end } else { screenFadeBootEnd = nil }
        attract = AttractLayout.discover(code: machine.code)
        if let img = image, let l = layout, let fu = l.flipperUpdate {
            let c = img.code
            introSettlesFlippers = (0..<max(0, l.mainLoop - 3)).contains { c[$0] == 0xE8 && EngineLayout.rel16(c, $0) == fu }
        } else { introSettlesFlippers = false }
        textRoutines = Self.textRoutines(code: machine.code)
        let code = machine.code
        if let t = program.stubs.first(where: { $0.value.kind == "message" })?.key, t + 17 < 0x10000,
           code[t] == 0x80, code[t + 1] == 0x3E, code[t + 4] == 1, code[t + 5] == 0x75, code[t + 6] == 0x0A,
           code[t + 7] == 0x8D, code[t + 8] == 0x1E, code[t + 11] == 0xB8, code[t + 14] == 0xBF {
            func w(_ i: Int) -> Int { Int(code[i]) | Int(code[i + 1]) << 8 }
            demoMessage = (w(t + 2), w(t + 9), w(t + 12), w(t + 15))
        }
        if let dm = counterEffects?.layout.dmdMessage ?? DotEffects.find(code: code)?.dmdMessage,
           let e = (dm..<min(0xFFF0, dm + 0x140)).first(where: { code[$0] == 0x61 && code[$0 + 1] == 0x07 && code[$0 + 2] == 0xC3 }) {
            var i = e
            while i >= 6, code[i - 6] == 0xC7, code[i - 5] == 0x06 {
                i -= 6
                messageExitStores.insert((Int(code[i + 2]) | Int(code[i + 3]) << 8, Int(code[i + 4]) | Int(code[i + 5]) << 8), at: 0)
            }
        }
        idleScoreRefresh = program.stubs.first { t, st in
            st.kind == "score_refresh" && !st.far && t + 17 < 0x10000 && code[t] == 0x80 && code[t + 1] == 0x3E && code[t + 4] == 1
                && code[t + 5] == 0x74 && code[t + 6] == 0x0A && code[t + 7] == 0x83 && code[t + 8] == 0x3E && code[t + 11] == 0
                && code[t + 12] == 0x74 && code[t + 13] == 0x03 && code[t + 14] == 0xE8 && code[t + 17] == 0xC3
        }?.key
        lampDrawn = [UInt8](repeating: 0, count: max(program.lampCount, program.lampSlotCount))
        warnings += glue.warnings
        if program.direct {
            stopBitmap = [Bool](repeating: false, count: 0x10000)
            for s in program.hookStops { stopBitmap[s & 0xFFFF] = true }
        }
        for h in program.hooks.values { hookByIP[h.entryIP] = h.entry }
        for (i, g) in program.gates.enumerated() { if let r = g.routine { gatesByRoutine[r, default: []].append(i) } }
        nextBallSkillEntry = program.hooks["next_ball_skill"]?.entry
        // The dispatcher's jump table (source.sensor_table), read from the EXE: colour -> handler.
        if let t = program.sensorTable, !program.direct {
            for v in 0xAA...0xFF {
                let a = (t + 2 * (v - 0xAA)) & 0xFFFF
                let ip = Int(machine.code[a]) | Int(machine.code[(a + 1) & 0xFFFF]) << 8
                if let e = program.labels[String(format: "L%04x", ip)] { dispatchTable[v] = (e, ip) }
            }
        }
        for (v, name) in program.colourHandler where !program.direct {
            guard let h = program.handlers[name] else { continue }
            if let d = dispatchTable[v], d.entry != h.entry {
                warn("jump table entry for colour \(String(format: "%02X", v)) is cs:\(hex4(d.ip)) but rules.json lists \(name)")
            }
            if dispatchTable[v] == nil { dispatchTable[v] = (h.entry, h.entryIP) }
        }
        // Graphs that reach a block with an `asm` op run natively (EP9 h29c6: writes through ES).
        if !program.nativeBlocks.isEmpty {
            for h in program.handlers.values where reaches(h.entry, program.nativeBlocks) { nativeEntries.insert(h.entry) }
            for (name, h) in program.hooks where reaches(h.entry, program.nativeBlocks) {
                warn("hook \(name) contains an unlifted instruction; its asm ops are skipped")
            }
        }
        machine.nativeCall = { [unowned self] t, ip, regs in self.nativeCall(target: t, from: ip, registers: &regs) }
        machine.eventSink = { [unowned self] e in self.handle(e) }
        x86.csRead = { [unowned self] a in self.csRead(a) }
        // other segments of the load image (read only): the EXE bytes after the MZ header
        let header = Int(exe[8]) | Int(exe[9]) << 8
        x86.imageRead = { [exe] lin in
            let o = header * 16 + lin
            return lin >= 0 && o < exe.count ? exe[o] : nil
        }
        x86.csWrite = { _, _ in }
        x86.callout = { [unowned self] x, ip, target, seg in self.callout(x, ip, target, seg) }
    }

    /// Whether the graph from `entry` (following gotos, branches and gosubs) reaches any of `targets`.
    func reaches(_ entry: Int, _ targets: Set<Int>) -> Bool {
        var seen = Set<Int>(), stack = [entry]
        while let b = stack.popLast() {
            guard b >= 0, seen.insert(b).inserted else { continue }
            if targets.contains(b) { return true }
            let blk = program.blocks[b]
            for o in blk.ops { if case let .gosub(l) = o { stack.append(l) }; if case let .callHook(l) = o { stack.append(l) } }
            switch blk.end {
            case let .goto(l): stack.append(l)
            case let .branch(_, t, e): stack.append(t); stack.append(e)
            case .ret: break
            }
        }
        return false
    }

    /// An unlifted near call from rule code, executed from the EXE with the caller's registers.
    func nativeCall(target: Int, from ip: Int, registers regs: inout [String: UInt16]) -> Bool {
        if let pc = paletteCycle, target == pc.routine || target == pc.waitRoutine {
            // EP8 cs:0240 (frame wait: rotation, cs:3C0F flash effect, vsync) used as a delay: the
            // rotation is the rule-visible part; the flash is display only.
            paletteCycleStep()
            return true
        }
        let saved = x86.r, savedES = x86.es
        nativeDepth += 1
        defer { x86.r = saved; x86.es = savedES; nativeDepth -= 1 }
        x86.resetRegisters()
        x86.r[4] = saved[4] == 0 ? MiniX86.initialSP : saved[4] &- 0x100
        let idx = ["ax": 0, "cx": 1, "dx": 2, "bx": 3, "bp": 5, "si": 6, "di": 7]
        for (n, v) in regs { if let i = idx[n] { x86.r[i] = v } }
        let s = x86.run(from: target, to: -1)
        guard s == .returned else {
            warn(String(format: "call cs:%04X from rule code (cs:%04X): %@", target, ip, s.description))
            return false
        }
        for (n, i) in idx { regs[n] = x86.r[i] }
        return true
    }

    func warn(_ s: String) {
        if reported.insert(s).inserted { warnings.append(s) }
    }

    // MARK: - engine attachment

    /// Binds every engine-owned DS byte to `engine` and makes the engine run these rules.
    public func attach(to e: ClassicEngine, mode: RulesMode = .full) {
        engine = e
        machine.host = e
        e.rules = self
        e.rulesMode = mode
        let ev = program.engineVars
        func bind(_ role: String, _ f: EngineField) {
            if let v = ev[role] { machine.bind(f, addr: v.addr, size: v.size) }
        }
        func slots(_ role: String, _ f: (Int) -> EngineField) {
            guard let v = ev[role] else { return }
            for i in 0..<5 { machine.bind(f(i), addr: v.addr + v.stride * i, size: v.size) }
        }
        func hexAddr(_ s: String?) -> Int? {
            guard let s else { return nil }
            return Int(s.hasPrefix("0x") ? String(s.dropFirst(2)) : s, radix: 16)
        }
        // engine.json first (physics-side names), then rules.json roles, then the table glue.
        if let p = hexAddr(e.data.params.ds) { for i in 0..<10 { machine.bind(.param(i), addr: p + 2 * i, size: 2) } }
        if let v = hexAddr(e.data.gravity.extraVar) { machine.bind(.extraGravity, addr: v, size: 2) }
        if let vars = e.data.sensors.vars {
            let map: [String: (EngineField, Int)] = ["level": (.layer, 1), "lockout": (.lockout, 1), "event_cooldown": (.cooldown, 1),
                                                     "writeback": (.writeback, 1), "extra_gravity": (.extraGravity, 2),
                                                     "obj_x": (.objX, 2), "obj_y": (.objY, 2), "obj_vx": (.objVX, 2), "obj_vy": (.objVY, 2)]
            for (k, s) in vars {
                guard let a = hexAddr(s) else { continue }
                if let (f, w) = map[k] { machine.bind(f, addr: a, size: w); continue }
                if let (field, i) = ClassicEngine.ballVar(k) {
                    switch field {
                    case "ball_x": machine.bind(.slotX(i), addr: a, size: 2)
                    case "ball_y": machine.bind(.slotY(i), addr: a, size: 2)
                    case "ball_vx": machine.bind(.slotVX(i), addr: a, size: 2)
                    case "ball_vy": machine.bind(.slotVY(i), addr: a, size: 2)
                    case "ball_active": machine.bind(.slotActive(i), addr: a, size: 2)
                    default: break
                    }
                }
            }
        }
        bind("ball.x", .objX); bind("ball.y", .objY); bind("ball.vx", .objVX); bind("ball.vy", .objVY)
        bind("ball.writeback", .writeback); bind("ball.layer", .layer)
        slots("ball_slots.x", EngineField.slotX); slots("ball_slots.y", EngineField.slotY)
        slots("ball_slots.vx", EngineField.slotVX); slots("ball_slots.vy", EngineField.slotVY)
        slots("ball_slots.active", EngineField.slotActive); slots("ball_slots.layer", EngineField.slotLayer)
        bind("sensor_lockout", .lockout); bind("sensor_cooldown", .cooldown); bind("kicker_cooldown", .kickerCooldown)
        bind("kick_strength", .kickStrength); bind("tilted", .tilted); bind("extra_gravity", .extraGravity)
        // (EP5/EP6 test the sensor lockout there: that byte stays bound to `.lockout`.)
        if ev["kicker_cooldown"] == nil, e.data.kicker.cooldownIsSensorLockout != true, let a = kickerCooldownAddress() {
            machine.bind(.kickerCooldown, addr: a, size: 1)
        }
        let d = glue.ds
        func g(_ k: String, _ f: EngineField, _ w: Int) { if let a = d[k] { machine.bind(f, addr: a, size: w) } }
        g("serve_delay", .serveDelay, 1); g("plunger_charge", .plungerCharge, 2); g("nudge_timer", .nudgeTimer, 1)
        g("tilt_meter", .tiltMeter, 1); g("hit_count", .hitCount, 2)
        g("flipper_angle_left", .flipperAngle(0), 2); g("flipper_angle_right", .flipperAngle(1), 2)
        g("flipper_drawn_left", .flipperDrawn(0), 2); g("flipper_drawn_right", .flipperDrawn(1), 2)
        g("flipper_moving_left", .flipperMoving(0), 1); g("flipper_moving_right", .flipperMoving(1), 1)
        if let a = d["acc_x"] { for i in 0..<5 { machine.bind(.slotAccX(i), addr: a + 2 * i, size: 2) } }
        if let a = d["acc_y"] { for i in 0..<5 { machine.bind(.slotAccY(i), addr: a + 2 * i, size: 2) } }
        for (name, f, w) in [("serve_delay", EngineField.serveDelay, 1), ("plunger_charge", .plungerCharge, 2),
                             ("nudge_timer", .nudgeTimer, 1), ("tilt_meter", .tiltMeter, 1)] where d[name] == nil {
            if let v = program.vars[name] { machine.bind(f, addr: v.addr, size: w) }
        }
        if d["serve_delay"] == nil, program.vars["serve_delay"] == nil, let a = serveDelayAddress(e.data) {
            machine.bind(.serveDelay, addr: a, size: 1)
        }
        dispatcherExitIP = hexAddr(e.data.sensors.exitIp)
        // EP8's launch block: its serve delay and launch flag (engine.json plunger.launch_block).
        if let lb = e.data.plunger.launchBlock {
            if let a = hexAddr(lb.serveDelay?.var) { machine.bind(.serveDelay, addr: a, size: 1) }
        }
        if let a = hexAddr(e.data.plunger.launchFlagVar) { machine.bind(.plungerCharge, addr: a, size: 2) }
        // EP9-13: one sensor lockout per ball slot; the scan's scratch copy stays bound to `.lockout`.
        if let pb = e.data.sensors.lockoutPerBall, let a = hexAddr(pb.array) {
            for i in 0..<min(pb.slots, 5) { machine.bind(.lockoutSlot(i), addr: a + pb.stride * i, size: 1) }
            if let sc = hexAddr(pb.scratch ?? pb.currentVar) { machine.bind(.lockout, addr: sc, size: 1) }
        }
        // Rule code that writes an engine-owned byte we could not bind would silently keep a private
        // copy: report it (engine.json `sensors.forbidden_vars`).
        let forbidden = Set((e.data.sensors.forbiddenVars ?? []).compactMap { hexAddr($0) })
        var seen = Set<Int>()
        for b in program.blocks {
            for o in b.ops {
                var addrs: [Int] = []
                switch o {
                case let .storeAt(s, _): addrs = Array(s.addr..<(s.addr + s.w))
                case let .storeMany(l): addrs = l.flatMap { Array($0.slot.addr..<($0.slot.addr + $0.slot.w)) }
                default: break
                }
                for a in addrs where forbidden.contains(a) && !machine.isBound(a) && seen.insert(a).inserted {
                    warn(String(format: "rule code writes engine byte ds:%04X, which is not bound (block %@)", a, b.label))
                }
            }
        }
    }

    /// The byte the probe loop tests before calling the kicker hook: `cmp byte [addr], 0; jne +3;
    /// call kicker` (EP1 cs:18A1, EP10 cs:183E). Used when rules.json has no `kicker_cooldown` role
    /// (EP10), because the hook sets it and the engine must see it.
    func kickerCooldownAddress() -> Int? {
        guard let k = program.hooks["kicker"]?.entryIP else { return nil }
        let c = machine.code
        for ip in 7..<0xFFF0 where c[ip] == 0xE8 {
            let target = (ip + 3 + (Int(c[ip + 1]) | Int(c[ip + 2]) << 8)) & 0xFFFF
            guard target == k else { continue }
            let p = ip - 7
            if c[p] == 0x80, c[p + 1] == 0x3E, c[p + 4] == 0x00, c[p + 5] == 0x75, c[p + 6] == 0x03 {
                return Int(c[p + 2]) | Int(c[p + 3]) << 8
            }
        }
        return nil
    }

    /// The serve delay byte, from the drain code's serve (EP1 cs:0A77, EP2 cs:0AD8, EP10 cs:0A06):
    /// `mov byte [addr], serve.delay` directly followed by `mov word [ball_slots.y], serve.y`.
    func serveDelayAddress(_ d: EngineData) -> Int? {
        guard let sy = program.engineVars["ball_slots.y"]?.addr else { return nil }
        let c = machine.code
        func w(_ i: Int) -> Int { Int(c[i]) | Int(c[i + 1]) << 8 }
        for ip in 0..<0xFFF0 where c[ip] == 0xC6 && c[ip + 1] == 0x06 && Int(c[ip + 4]) == d.serve.delay
            && c[ip + 5] == 0xC7 && c[ip + 6] == 0x06 && w(ip + 7) == sy && w(ip + 9) == d.serve.y & 0xFFFF {
            return w(ip + 2)
        }
        return nil
    }

    // MARK: - boot

    /// The data segment as the original's entry and init code leave it at the first arrival at the
    /// main loop: EXE bytes, the command-line options, dmd_idle_text (EP1 cs:03D2), the intro loop and
    /// the boot tail (glue `init`). Called by `Scenario.apply` / game start after the engine reset.
    public func boot() {
        machine.reset()
        counterEffects?.reset()
        dacRing = nil
        if let pc = paletteCycle, let sf = screenFade, let end = screenFadeBootEnd, sf.cycle?.ring == pc.ring,
           pc.ring - sf.working >= 0, pc.ring - sf.working + pc.ringBytes <= 768, 3 * pc.firstIndex + pc.ringBytes <= 768 {
            // EP8: the boot's fade-in and intro scroll rotate the ring inside W in every wait_frame (cs:0240 ->
            // cs:1281), so the main loop starts with W's ring, the counter and the DAC ring as `ScreenFade.boot`
            // leaves them (ScreenFadeTests: equal to the original's after boot).
            let r0 = pc.ring - sf.working, d0 = 3 * pc.firstIndex
            for k in 0..<pc.ringBytes { machine.write8(pc.ring + k, end.working[r0 + k]) }
            machine.write8(pc.counter, end.counter)
            dacRing = Array(end.dac[d0..<(d0 + pc.ringBytes)])
        } else {
            paletteCycle?.bootRing(machine)
        }
        fadeWorking = paletteFade?.bootPalette(base: fadeBase)
        fadeFlag = 0
        gameOver = false
        message = nil
        localCounter = 0
        localEffect = 0
        pendingSounds.removeAll()
        pendingTexts.removeAll()
        pendingSpriteSets.removeAll()
        spriteSetsShown = [:]   // nothing at boot draws them (EP8: cs:A42F is called only from cs:2F0F / 2F29)
        lampDrawn = [UInt8](repeating: 0, count: lampDrawn.count)
        sfxPendingDelay = 0
        let d = glue.ds
        // entry cs:0019..0055: players '1'..'4', option bits, balls digit; cs:00CA..: sound pointers.
        if let a = d["player_count"] { machine.write8(a, UInt8(options.demo ? 1 : max(1, min(4, options.players)))) }
        if options.demo, let a = d["demo_mode"] ?? attract?.flag { machine.write8(a, 1) }   // cs:0081
        if let a = d["balls_per_game"] { machine.write8(a, UInt8(max(0, min(9, options.ballsPerGame)))) }
        if let a = d["opt_sfx"] { machine.write8(a, options.sfx ? 1 : 0) }
        if let a = d["opt_music"] { machine.write8(a, options.music ? 1 : 0) }
        if let a = d["snd_present"] { machine.write8(a, options.soundPresent ? 1 : 0) }
        // cs:03CB: the demo skips the boot's idle text (the init glue takes its own demo branches)
        if !options.demo, let idle = glue.routines["idle_text"], glue.range("idleText") != nil { runRoutine(idle, "idle_text") }
        _ = runRange("init")
        _ = runRange("bootTail")   // EP2-EP13 (TableGlue.discoverBootTail)
        pendingSounds.removeAll()
    }

    // MARK: - main-loop pieces (called by ClassicEngine)

    // MARK: - automatic main loop (EP2-EP13, full mode)

    /// Tables whose main-loop hooks were found by rules.py's pattern search (rules.md 4.1).
    public var hasAutomaticHooks: Bool { program.hooks.values.contains { $0.when != nil } }

    public enum MainLoopItem: Equatable, Sendable {
        case hook(String), glue(String)
        case decay, gates, sound, counters, drain, lane, nudge, lamps, gravity, render, paletteCycle
        /// Demo mode's attract_autoflip block (EP1 cs:0C48), in `demoSchedule` only.
        case attract
    }
    private var cachedSchedule: [MainLoopItem]?
    private var cachedTimeline: [(ip: Int, item: MainLoopItem)]?
    private var cachedDemoSchedule: [MainLoopItem]?

    /// The full-mode main loop in demo mode: `schedule` with the attract block after the plunger lane
    /// and without what the demo jumps over (cs:0D1D..0E8A: the nudge/tilt piece and any hook there).
    public func demoSchedule(engine e: ClassicEngine, layout a: AttractLayout) -> [MainLoopItem] {
        if let s = cachedDemoSchedule { return s }
        _ = schedule(engine: e)
        var out: [MainLoopItem] = []
        for (ip, item) in cachedTimeline ?? [] {
            switch item {
            case .nudge: continue
            case .hook, .glue: if ip >= a.keys && ip < a.resume { continue }
            default: break
            }
            out.append(item)
            if item == .lane { out.append(.attract) }
        }
        cachedDemoSchedule = out
        return out
    }

    /// The full-mode main loop for tables with automatic hooks, in the original's code order: every
    /// `when: every_frame` hook at its entry ip, interleaved with the engine's own pieces at the ips
    /// where engine.json found them (`found_at`: drain, lane, nudge_lane, active_array). A
    /// `frame_timers` / `frame_counters` / `drain` hook replaces the engine's decay / counters /
    /// drain (it is the same code plus the rule state around it). Hooks that start inside a glue
    /// range are skipped (the glue runs that code from the EXE). [M]: the order of pieces the
    /// search could not place (lamp_update, render_frame) follows EP1.
    public func schedule(engine e: ClassicEngine) -> [MainLoopItem] {
        if let s = cachedSchedule { return s }
        func ip(_ k: String) -> Int? { e.data.foundAt?[k].flatMap { ClassicEngine.hexAddr($0) } }
        var items: [(Int, Int, MainLoopItem)] = []   // (ip, tie order, item)
        let every = program.hooks.values.filter { $0.when == "every_frame" }
        let kinds = Set(every.compactMap(\.kind))
        let glueRanges = ["betweenBalls", "preFrame", "postTimers", "ruleTimers", "preGravity"].compactMap { n in glue.range(n).map { (n, $0) } }
        for h in every {
            if glueRanges.contains(where: { h.entryIP >= $0.1.start && h.entryIP < $0.1.end }) { continue }
            items.append((h.entryIP, 1, .hook(h.name)))
        }
        for (n, r) in glueRanges { items.append((r.start, 0, .glue(n))) }
        let timersIP = every.first { $0.kind == "frame_timers" }?.entryIP ?? 0
        if !kinds.contains("frame_timers") { items.append((0, 0, .decay)) }
        items.append((timersIP, 2, .gates))
        if let snd = glue.range("sound") { items.append((snd.start, 0, .sound)) } else { items.append((timersIP, 3, .sound)) }
        let drainIP = every.first { $0.kind == "drain" }?.entryIP ?? ip("drain") ?? 0x0A31
        if !kinds.contains("frame_counters") { items.append((drainIP, -1, .counters)) }
        if !kinds.contains("drain") { items.append((drainIP, 0, .drain)) }
        let laneIP = ip("lane") ?? e.data.plunger.launchBlock.flatMap { _ in ip("plunger") } ?? drainIP + 1
        items.append((max(laneIP, drainIP + 1), 0, .lane))
        let nudgeIP = ip("nudge_lane") ?? ip("nudge") ?? laneIP + 1
        items.append((nudgeIP, 0, .nudge))
        let gravIP = ip("active_array") ?? ip("gravity") ?? 0xFFFE
        items.append((gravIP, -1, .lamps))
        items.append((gravIP, 0, .gravity))
        if !renderAfterSteps { items.append((0x10000, 0, .render)) }
        // The main loop's call (EP8 cs:0843; its intro loop's call cs:0435 lies before the first hook).
        let loopStart = every.map(\.entryIP).min() ?? 0
        for s in paletteCycle?.callSites ?? [] where s >= loopStart { items.append((s, 0, .paletteCycle)) }
        let sorted = items.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        cachedTimeline = sorted.map { (ip: $0.0, item: $0.2) }
        let s = sorted.map(\.2)
        cachedSchedule = s
        return s
    }

    /// End of ball for tables with automatic hooks: the `ball_end` hooks from the first one, following
    /// `continues` after each cut (rules.md 4.1), then the end-of-turn counters (player switch, ball
    /// number, game over) if the hooks did not run that code (TableGlue.discoverEndOfTurn).
    func automaticBallEnd() {
        // lifted (or, direct backend, EXE) hooks and the regions that do not lift (`nativeHooks`, run
        // from the EXE by both backends: EP5 cs:1F4A, where the chain starts)
        func endHook(_ n: String) -> (RulesProgram.Hook, native: Bool)? {
            if let h = program.hooks[n] { return (h, false) }
            return program.nativeHooks[n].map { ($0, true) }
        }
        let ends = (program.hooks.values.filter { $0.when == "ball_end" } + program.nativeHooks.values.filter { $0.when == "ball_end" })
            .sorted { $0.entryIP < $1.entryIP }
        var countedByHooks = false
        // Lifted blocks that start within the end-of-turn test (its first 24 bytes): if a ball_end
        // hook ran one, the hooks did the counting (EP10 ball_end_30a6 starts there).
        var counterLabels = Set<Int>()
        if let t = glue.routines["end_of_turn"] {
            for (i, b) in program.blocks.enumerated() where b.ip >= t && b.ip < t + 24 { counterLabels.insert(i) }
        }
        if let first = ends.first {
            var name: String? = first.name
            var n = 0
            while let cur = name, let (hk, native) = endHook(cur), n < 16 {
                var stopIP: Int?
                if native {
                    let watch = glue.routines["end_of_turn"].map { $0..<($0 + 24) }
                    let res = runDirect(hk.entryIP, "hook \(cur)", watch: watch, stops: nativeStops(hk))
                    if res.watchHit { countedByHooks = true }
                    stopIP = res.stop
                } else if program.direct {
                    // the counting code ran if any of its instructions executed (the lifted check:
                    // a block starting there ran)
                    let watch = glue.routines["end_of_turn"].map { $0..<($0 + 24) }
                    let res = runDirect(program.hooks[cur]!.entryIP, "hook \(cur)", watch: watch)
                    if res.watchHit { countedByHooks = true }
                    stopIP = res.stop
                } else {
                    machine.watched = counterLabels
                    machine.callHook(cur)
                    if !machine.watchedHits.isEmpty { countedByHooks = true }
                    stopIP = machine.lastStopIP
                }
                n += 1
                name = stopIP.flatMap { hk.continues[$0] }
                // The cut is the call the lift could not express (EP6 cs:31D8 call 3BD4, the gate
                // redraw; cs:31CB the idle text): run it from the EXE, then continue after it, through
                // the cuts of the straight-line code in between (`via`: EP9 cs:2F36 frame wait, cs:2F39
                // the second dmd_idle_text call).
                if name != nil, let stop = stopIP {
                    for c in [stop] + (hk.via[stop] ?? []) where !runBallEndCut(c) { name = nil; break }
                }
            }
            machine.watched = []
        }
        let d = glue.ds
        guard let pA = d["current_player"], let pcA = d["player_count"], let bA = d["ball_number"], let bpgA = d["balls_per_game"] else { return }
        // The counting code is part of the hooks on every table now (the chain follows `via`): if they
        // did not run it, the original skipped it too (EP2 cs:365C no-score rule, EP5 cs:1F51 demo mode).
        let covered = glue.routines["end_of_turn"].map { program.ballEndHooksCover($0..<($0 + 24)) } ?? false
        if !countedByHooks && !covered {
            // EP1 cs:343E..3465 / 352F: next player, or next ball round (game over past the last one)
            let p = machine.read8(pA)
            if machine.read8(pcA) > p {
                machine.write8(pA, p &+ 1)
            } else {
                machine.write8(bA, machine.read8(bA) &+ 1)
                machine.write8(pA, 0)
                if machine.read8(bA) != machine.read8(bpgA) &+ 1 { machine.write8(pA, 1) }
            }
        }
        if machine.read8(bA) == machine.read8(bpgA) &+ 1 { gameOver = true }   // the original calls pause_menu
    }

    private var nativeStopCache: [Int: [Bool]] = [:]
    /// The stop bitmap of a native hook: its own cuts (both backends).
    private func nativeStops(_ h: RulesProgram.Hook) -> [Bool] {
        if let b = nativeStopCache[h.entryIP] { return b }
        var b = [Bool](repeating: false, count: 0x10000)
        for s in h.stops { b[s & 0xFFFF] = true }
        nativeStopCache[h.entryIP] = b
        return b
    }

    /// A call target that is render_frame (`DotEffects.Layout.renderFrame`, or EP9-13's `push es` in front of it, EP10 cs:38E1).
    static func isRenderEntry(_ t: Int, _ rf: Int, _ c: [UInt8]) -> Bool { t == rf || (t == rf - 1 && c[t & 0xFFFF] == 0x06) }

    static func findRenderTail(code c: [UInt8], layout l: DotEffects.Layout) -> (at: Int, shown: Int, idle: Int)? {
        func w(_ i: Int) -> Int { Int(c[i & 0xFFFF]) | Int(c[(i + 1) & 0xFFFF]) << 8 }
        // dmd_message ends `mov word [S],0; popa; pop es; ret`
        guard let k = (l.dmdMessage..<min(0xFFF0, l.dmdMessage + 0xC0)).first(where: { i in
            c[i] == 0xC7 && c[i + 1] == 0x06 && w(i + 4) == 0 && c[i + 6] == 0x61 && c[i + 7] == 0x07 && c[i + 8] == 0xC3
        }) else { return nil }
        let sh = w(k + 2), cn = l.counter
        let a = l.effectsEnd
        guard a + 26 < 0x10000, c[a] == 0x83, c[a + 1] == 0x3E, w(a + 2) == sh, c[a + 4] == 2, c[a + 5] == 0x77,
              c[a + 7] == 0x53, c[a + 8] == 0xB3, c[a + 10] == 0xE8, c[a + 13] == 0x5B,
              c[a + 14] == 0x83, c[a + 15] == 0x3E, w(a + 16) == cn, c[a + 18] == 0xFF, c[a + 19] == 0x75,
              c[a + 21] == 0xC7, c[a + 22] == 0x06, w(a + 23) == cn, w(a + 25) == 0, c[a + 27] == 0xE8 else { return nil }
        return (a + 27, sh, (a + 30 + w(a + 28)) & 0xFFFF)
    }

    /// One cut of the automatic end-of-ball chain, as the original executes it at that point: a near
    /// call is run from the EXE, except a frame wait (`mov dx,3DAh; in al,dx` near its entry, EP2
    /// cs:0244; EP8's wait steps the palette ring) and the game-over menu (`mov di,3039h` before the
    /// call, a routine that starts `cmp di,3039h`: EP2 cs:3817 -> cs:1550), where the chain ends (the
    /// port's game over follows the counters). Far calls and port I/O are display only. Returns false
    /// when the chain ends.
    func runBallEndCut(_ c: Int) -> Bool {
        let code = machine.code
        func w(_ i: Int) -> Int { Int(code[i & 0xFFFF]) | Int(code[(i + 1) & 0xFFFF]) << 8 }
        if code[c & 0xFFFF] == 0x9A, w(c + 3) == Int(x86.csValue), frameWait(w(c + 1)) {   // far wrapper (EP3 cs:0279)
            doFrameWait(w(c + 1))
            return true
        }
        guard code[c & 0xFFFF] == 0xE8 else { return true }
        let t = (c + 3 + w(c + 1)) & 0xFFFF
        if frameWait(t) { doFrameWait(t); return true }
        if paletteCycle.map({ t == $0.routine }) != true, code[t] == 0x81, code[(t + 1) & 0xFFFF] == 0xFF,
           ((c - 16)..<c).contains(where: { code[$0 & 0xFFFF] == 0xBF && w($0 + 1) == w(t + 2) }) { return false }
        // routines that call far into code the callout does not know (EP2 cs:3CBA -> cs:A357, called with
        // BX = 3 / 7 between the frame waits: music and screen effects) are display and sound only: skipped
        guard cutRunnable(t) else { return true }
        var regs: [String: UInt16] = [:]
        _ = nativeCall(target: t, from: c, registers: &regs)
        return true
    }

    private var cutRunnableCache: [Int: Bool] = [:]
    /// Whether a routine run from the EXE as nativeCall runs it would only make calls the callout handles:
    /// follows its jumps and near calls (depth 3) and classifies every far call into the code segment.
    func cutRunnable(_ t0: Int) -> Bool {
        if let v = cutRunnableCache[t0] { return v }
        let code = machine.code, cs = Int(x86.csValue)
        nativeDepth += 1
        defer { nativeDepth -= 1 }
        var seen = Set<Int>(), work = [(t0, 0)], ok = true
        scan: while let (start, depth) = work.popLast() {
            var ip = start
            while seen.insert(ip).inserted, let i = X86Decoder.decode(code, ip) {
                if i.mn == "lcall", let f = i.farTarget {
                    if f.seg == cs, classifyCall(f.off, cs, direct: false).0 == .unknown { ok = false; break scan }
                } else if i.mn == "call", let t = i.target {
                    let (res, _) = classifyCall(t, nil, direct: false)
                    if res == .unknown { ok = false; break scan }
                    if res == .follow, depth < 3 { work.append((t, depth + 1)) }
                } else if Reach.jcc.contains(i.mn) || i.mn == "loop" || i.mn == "jcxz", let t = i.target {
                    work.append((t, depth))
                } else if i.mn == "jmp" {
                    guard let t = i.target else { break }
                    ip = t
                    continue
                } else if ["ret", "retf", "iret"].contains(i.mn) {
                    break
                }
                ip = i.next
                if seen.count > 4000 { break scan }
            }
        }
        cutRunnableCache[t0] = ok
        return ok
    }

    private var frameWaitCache: [Int: Bool] = [:]
    /// A frame wait (wait_frame: `push ds; pusha; [call palette_cycle;] call render_frame; ...; mov dx,3DAh;
    /// in al,dx`, EP2 cs:0244, EP8 cs:0240) or a far wrapper around one (`push ds; pusha; mov ax,DS; mov
    /// ds,ax; call wait_frame; popa; pop ds; retf`, EP3 cs:0279, which the lift treats as a display call).
    func frameWait(_ t: Int) -> Bool {
        if let v = frameWaitCache[t] { return v }
        let code = machine.code
        func w(_ i: Int) -> Int { Int(code[i & 0xFFFF]) | Int(code[(i + 1) & 0xFFFF]) << 8 }
        var v = paletteCycle.map({ t == $0.waitRoutine }) == true
        if !v, code[t & 0xFFFF] == 0x1E, code[(t + 1) & 0xFFFF] == 0x60 {
            // `mov dx,3DAh; in al,dx` before the routine's first ret
            var ip = t
            for _ in 0..<16 {
                if code[ip & 0xFFFF] == 0xBA, w(ip + 1) == 0x3DA, code[(ip + 3) & 0xFFFF] == 0xEC { v = true; break }
                if [0xC3, 0xCB, 0xCF].contains(code[ip & 0xFFFF]) { break }
                guard let n = x86.length(at: ip & 0xFFFF) else { break }
                ip += n
            }
        }
        if !v, code[t & 0xFFFF] == 0x1E, code[(t + 1) & 0xFFFF] == 0x60,
           let k = (t..<(t + 12)).first(where: { code[$0 & 0xFFFF] == 0xE8 }), code[(k + 3) & 0xFFFF] == 0x61,
           code[(k + 4) & 0xFFFF] == 0x1F, code[(k + 5) & 0xFFFF] == 0xCB {
            let inner = (k + 3 + w(k + 1)) & 0xFFFF
            v = inner != t && frameWait(inner)
        }
        frameWaitCache[t] = v
        return v
    }

    /// One frame wait as the original runs it: EP8's palette-ring step, and the render_frame call
    /// the wait makes (the message effect advances one frame; EP1's glue model keeps EP1's counter).
    func doFrameWait(_ t: Int) {
        let code = machine.code
        func w(_ i: Int) -> Int { Int(code[i & 0xFFFF]) | Int(code[(i + 1) & 0xFFFF]) << 8 }
        var target = t
        if code[t & 0xFFFF] == 0x1E, code[(t + 1) & 0xFFFF] == 0x60, code[(t + 2) & 0xFFFF] != 0xE8,
           let k = (t..<(t + 12)).first(where: { code[$0 & 0xFFFF] == 0xE8 }), code[(k + 5) & 0xFFFF] == 0xCB {
            target = (k + 3 + w(k + 1)) & 0xFFFF   // the far wrapper's wait
        }
        if let pc = paletteCycle, target == pc.waitRoutine { paletteCycleStep() }
        guard let rf = counterEffects?.layout.renderFrame else { return }
        // the render_frame call before the wait's ret (EP2 cs:0246 first; EP7 cs:025E after the retrace wait)
        var ip = target
        for _ in 0..<24 {
            let op = code[ip & 0xFFFF]
            if op == 0xE8, Self.isRenderEntry((ip + 3 + w(ip + 1)) & 0xFFFF, rf, code) { renderFrame(); return }
            if [0xC3, 0xCB, 0xCF].contains(op) { return }
            guard let n = x86.length(at: ip & 0xFFFF) else { return }
            ip += n
        }
    }

    /// Runs a lifted hook if the table has it.
    @discardableResult
    public func hook(_ name: String) -> Bool {
        guard let h = program.hooks[name] else { return false }
        if program.direct { runDirect(h.entryIP, "hook \(name)") } else { machine.callHook(name) }
        return true
    }

    /// Direct backend: runs rule code from the EXE at `entry` until `ret` at depth 0, the dispatcher
    /// epilogue or a hook stop (rules.py's `@return` points), with every register 0 except the ones
    /// `setup` sets (as the lifted graphs start). Returns the stop address reached, if any, and
    /// whether an instruction in `watch` ran.
    @discardableResult
    func runDirect(_ entry: Int, _ what: String, watch: Range<Int>? = nil, stops: [Bool]? = nil, setup: (MiniX86) -> Void = { _ in })
        -> (result: MiniX86.Stop, stop: Int?, watchHit: Bool) {
        let saved = x86.r, savedES = x86.es
        let savedStops = x86.stops, savedEpi = x86.stopAtEpilogue, savedWatch = x86.watch, savedStopIP = x86.stopIP
        x86.resetRegisters()
        x86.r[4] = saved[4] == 0 ? MiniX86.initialSP : saved[4] &- 0x100
        x86.stops = stops ?? stopBitmap
        x86.stopAtEpilogue = true
        x86.watch = watch
        x86.stopIP = nil
        setup(x86)
        directDepth += 1
        let s = x86.run(from: entry, to: -1)
        directDepth -= 1
        let out = (s, x86.lastStop, x86.watchHit)
        x86.r = saved; x86.es = savedES
        x86.stops = savedStops; x86.stopAtEpilogue = savedEpi; x86.watch = savedWatch; x86.stopIP = savedStopIP
        switch s {
        case .completed, .returned, .halted: break
        default: warn(String(format: "%@ (cs:%04X): %@", what, entry, s.description))
        }
        return out
    }

    /// Runs a glue range; nil if the table has no such range.
    @discardableResult
    public func runRange(_ name: String, di: Int? = nil) -> MiniX86.Stop? {
        guard let r = glue.range(name) else { return nil }
        let saved = x86.r, savedES = x86.es
        let savedStops = x86.stops, savedEpi = x86.stopAtEpilogue, savedWatch = x86.watch, savedDD = directDepth
        x86.stops = nil; x86.stopAtEpilogue = false; x86.watch = nil; directDepth = 0
        defer { x86.r = saved; x86.es = savedES; x86.stops = savedStops; x86.stopAtEpilogue = savedEpi; x86.watch = savedWatch; directDepth = savedDD }
        x86.resetRegisters()
        x86.r[4] = saved[4] == 0 ? MiniX86.initialSP : saved[4] &- 0x100
        if let di { x86.di = UInt16(truncatingIfNeeded: di) }
        let follow = glue.followNearCalls.contains(name)
        if follow { nativeDepth += 1 }
        let s = x86.run(from: r.start, to: r.end)
        if follow { nativeDepth -= 1 }
        switch s {
        case .completed, .returned, .jumpedOut, .halted: break
        default: warn("glue \(name): \(s)")
        }
        return s
    }

    @discardableResult
    func runRoutine(_ entry: Int, _ name: String) -> MiniX86.Stop {
        let saved = x86.r, savedES = x86.es
        let savedStops = x86.stops, savedEpi = x86.stopAtEpilogue, savedWatch = x86.watch, savedDD = directDepth
        x86.stops = nil; x86.stopAtEpilogue = false; x86.watch = nil; directDepth = 0
        defer { x86.stops = savedStops; x86.stopAtEpilogue = savedEpi; x86.watch = savedWatch; directDepth = savedDD }
        x86.resetRegisters()
        x86.r[4] = saved[4] &- 0x100   // below the caller's frame
        let s = x86.run(from: entry, to: -1)
        switch s {
        case .returned, .halted: break
        default: warn("routine \(name) cs:\(hex4(entry)): \(s)")
        }
        x86.r = saved
        x86.es = savedES
        return s
    }

    /// colour_event_dispatch (EP1 cs:1E3B): values < 0xAA exit; on the ramp level only the level-1
    /// colours pass; on level 0 while tilted only the tilt colours pass; then the jump table (read
    /// from the EXE) with AX = value | lockout << 8 and BX = the handler address. EP2/EP10 exit
    /// through their dispatcher tail, which is rule code too (rules.md 4 item 3).
    public func dispatch(value v: Int, layer: UInt8, tilted: Bool, lockout: UInt8) {
        if program.direct, let d = program.dispatcherIP {
            // the dispatcher itself (filters, jump table, handler, tail) from the EXE
            runDirect(d, "sensor dispatch \(String(format: "%02X", v))") { $0.ax = UInt16(truncatingIfNeeded: v | Int(lockout) << 8) }
            return
        }
        var pass = v >= 0xAA
        if pass {
            if layer == 1 { pass = program.level1Colours.contains(v) }
            else if tilted && !program.tiltColours.contains(v) { pass = false }
        }
        let ax = v | Int(lockout) << 8
        if pass, let h = dispatchTable[v], nativeEntries.contains(h.entry) {
            // A handler the lift cannot express (EP9 h29c6 writes the collision buffer through ES).
            let saved = x86.r, savedES = x86.es
            x86.resetRegisters()
            x86.ax = UInt16(truncatingIfNeeded: ax)
            x86.bx = UInt16(truncatingIfNeeded: h.ip)
            x86.stopIP = dispatcherExitIP
            let s = x86.run(from: h.ip, to: -1)
            x86.stopIP = nil
            x86.r = saved; x86.es = savedES
            if s != .completed && s != .returned { warn(String(format: "native handler cs:%04X: %@", h.ip, s.description)) }
        } else if pass, let h = dispatchTable[v] {
            machine.call(h.entry, registers: ["ax": ax, "bx": h.ip])
        } else if let tail = program.hooks["dispatch_tail"] {
            machine.call(tail.entry, registers: ["ax": ax])
        }
    }

    /// kicker_hit (EP1 cs:19C1, called from the probe loop when kicker_cooldown == 0): the physics
    /// kick plus bumper/sling scoring. DI = 2 x ball slot; `contact` = the probed pixel (EP2).
    /// Returns false when the table has no kicker hook (the engine then applies its own kick).
    public func kicker(ball i: Int, contact: UInt8) -> Bool {
        guard let k = program.hooks["kicker"] else { return false }
        if program.direct {
            // the probe loop's registers: DI = 2 x slot, ES:[BX] = the probed pixel
            x86.contactColour = contact
            runDirect(k.entryIP, "kicker") { $0.di = UInt16(2 * i); $0.es = MiniX86.contactSegment }
            return true
        }
        machine.contactColour = Int(contact)
        machine.call(k.entry, registers: ["di": 2 * i])
        return true
    }

    /// ball_lost_fade (EP1 cs:32E9) after its palette fade: fadeTail glue, ball_end, and unless that
    /// took the no-score shortcut into next_ball_skill: bonus_count, the payout, then the end-of-turn
    /// glue (extra ball, player switch, game over) and next_ball_skill.
    public func ballLostFade() {
        guard program.hooks["ball_end"] != nil else {
            if hasAutomaticHooks { automaticBallEnd() }
            return
        }
        runRange("fadeTail")
        var shortcut = false
        if program.direct {
            let nb = program.hooks["next_ball_skill"]?.entryIP
            shortcut = runDirect(program.hooks["ball_end"]!.entryIP, "hook ball_end", watch: nb.map { $0..<($0 + 1) }).watchHit
        } else {
            if let nb = nextBallSkillEntry { machine.watched = [nb] }
            hook("ball_end")
            shortcut = nextBallSkillEntry.map { machine.watchedHits.contains($0) } ?? false
            machine.watched = []
        }
        if shortcut { return }
        hook("bonus_count")
        hook("bonus_multiplier_payout")
        let s = runRange("endOfTurn")
        if s == .completed { hook("next_ball_skill") }
    }

    /// The main loop's sound code (EP1 cs:0898..09DC) run from the EXE; tables without that glue get
    /// a generic version built from rules.json `sound_sweeps` ([M]).
    public func soundBlock() {
        if runRange("sound") != nil { return }
        genericSoundBlock()
    }

    /// lamp_update on the play lamp table (EP1 cs:10C2..10C6: si = lamps.phase).
    public func lampUpdate() {
        guard let phase = program.lampPhase else { return }
        lampUpdate(phaseAddr: phase)
    }

    /// One call of the palette rotation (EP8 main loop cs:0843 `call 1281`).
    public func paletteCycleStep() {
        if let pc = paletteCycle, let d = pc.step(machine) { dacRing = d }
    }

    /// render_frame's message counter (EP1 cs:3E35..3E4D and the per-effect blocks, cs:43C5): advance,
    /// play the effect's sounds, end the message.
    public func renderFrame() {
        messageRenders &+= 1
        var c = msgCounter
        if let fx = counterEffects {
            // EP9-13 render_frame's end (EP10 cs:3F77): the idle-display flag counts render_frame calls
            defer {
                if let t = renderTail { let v = machine.read(t.shown, 2); if v != 0 { machine.write(t.shown, 2, Int64((v + 1) & 0xFFFF)) } }
            }
            guard c != 0 else { return }
            // other code stored into the counter or the effect byte: render_frame goes on from there
            if fx.counter != c { fx.setCounter(c) }
            if !fx.active { return }
            fx.step()
            for ax in fx.sounds { sfxPlay(ax: ax) }
            machine.write(fx.layout.step, 2, Int64(fx.stepWord))
            guard fx.rawCounter == 0xFFFF else { msgCounter = fx.counter; return }
            if let t = renderTail {
                // EP10 cs:3ED7..3EF2: while the flag is <= 2, an ended message gives way to the idle display
                // (counter 0, then cs:341B, whose dmd_message sets it to 1); past 2 the counter stays 0FFFFh.
                guard machine.read(t.shown, 2) <= 2 else { msgCounter = 0xFFFF; return }
                msgCounter = 0
                var regs: [String: UInt16] = [:]
                _ = nativeCall(target: t.idle, from: t.at, registers: &regs)
            } else {
                msgCounter = 0   // EP1-8: the plot loop turns 0FFFFh into 0 (EP1 cs:43C5), the message is gone
            }
            return
        }
        guard c != 0 else { return }
        if let fx = glue.messageEffects[msgEffect], fx.endCount > 0 {
            c = (c + 1) & 0xFFFF
            for s in fx.sounds where s.count == c { sfxPlay(ax: s.ax) }
            let done = fx.fadeFrames > 0 ? c >= fx.endCount + fx.fadeFrames - 1 : c > fx.endCount
            if done { c = 0xFFFF }
        }
        msgCounter = c == 0xFFFF ? 0 : c      // cs:43C5: 0FFFFh -> 0, the message is gone
    }

    // MARK: - display events and callouts

    private func handle(_ e: RulesEvent) {
        switch e {
        case let .message(ds, mode, pos):
            startMessage(ds: ds, ax: mode, pos: pos)
        case let .text(ds, pos, routine):
            // EP3 cs:0279 (wait_frame's far wrapper) is listed as a text routine by the lift
            if counterEffects != nil, frameWait(routine) { doFrameWait(routine); break }
            pendingTexts.append(textRef(ds: ds, pos: pos, routine: routine))
        case let .display(what):
            // lifted rules: a frame wait the lift treats as display (EP3 cs:0279 far wrapper)
            if counterEffects != nil, what.hasPrefix("routine_"), let t = Int(what.dropFirst(8), radix: 16), frameWait(t) { doFrameWait(t) }
            // lifted rules: `display routine_a42f`; AL is the `mov al,imm` before that call in the block
            if what.hasPrefix("routine_"), let t = Int(what.dropFirst(8), radix: 16),
               let ss = spriteSetRoutines.first(where: { $0.entry == t }), let ip = machine.currentBlockIP,
               let al = ss.selector(code: machine.code, from: ip) {
                pendingSpriteSets.append(SpriteSetEvent(routine: t, selector: al))
                spriteSetsShown[t] = al
            }
            if what == "idle_text", let idle = glue.routines["idle_text"], glue.range("idleText") != nil {
                runRoutine(idle, "idle_text")
            } else if what == "idle_text" {
                // Tables without the glue: the one rule-visible effect (EP1 cs:3B16..3B1D).
                if let t = program.engineVars["tilted"], machine.read(t.addr, t.size) == 1, let m = program.vars["mode"] { machine.write(m, 0) }
            }
        case .scoreRefresh:
            // EP9-13: score_refresh re-shows the idle display (dmd_message) when it is the one shown
            if let t = idleScoreRefresh { var regs: [String: UInt16] = [:]; _ = nativeCall(target: t, from: t, registers: &regs) }
        case .number, .outsideWrite:
            break
        }
    }

    /// A dmd_message call made by engine-side code (EP8's launch, cs:0C30).
    public func showMessage(ds: Int, ax: Int, di: Int) { startMessage(ds: ds, ax: ax, pos: di) }

    private func startMessage(ds ds0: Int, ax ax0: Int, pos pos0: Int) {
        // dmd_message cs:15DE: [0B3B] = 0, [0B3A] = AL, text rendered, [0B3D] = 1.
        if traceCalls { messageCalls.append([ds0, ax0 & 0xFFFF, pos0 & 0xFFFF]) }
        var ds = ds0, ax = ax0, pos = pos0
        // EP5/EP6: in demo mode every message is the demo's idle text (EP6 cs:15AF)
        if let o = demoMessage, machine.read8(o.flag) == 1 { ds = o.bx; ax = o.ax; pos = o.di }
        // the stores at dmd_message's common exit run on every path (EP6 cs:1658 [577Ah] = -40, a rule
        // timer; EP10 cs:1614 [0619h] = 0, the idle-display flag)
        defer { for (a, v) in messageExitStores { machine.write(a, 2, Int64(v)) } }
        // AH 0..2: a string longer than 30 characters, or too wide to centre, leaves everything as it
        // was (EP6 cs:15D1..1600: `jmp` to the exit)
        let ah = (ax >> 8) & 0xFF
        if ah <= 2 {
            let len = machine.string(at: ds, limit: 0x20).count
            if len > 0x1E || 0x140 - (ah == 2 ? 8 : (ah == 0 ? 11 : 16)) * len < 0 { return }
        }
        message = LastMessage(ds: ds, ax: ax, pos: pos, colour: messageColourVar.map { Int(machine.read8($0)) } ?? -1)
        messageSerial &+= 1
        messageRenders = 0
        if let a = glue.ds["msg_scroll"] ?? counterEffects?.layout.step { machine.write(a, 2, 0) }
        msgEffect = ax & 0xFF
        msgCounter = 1
        counterEffects?.start(dots: [], effect: ax & 0xFF, colour: UInt8(truncatingIfNeeded: message?.colour ?? 0xFF))
    }

    private func textRef(ds: Int, pos: Int, routine: Int) -> TextRef {
        var t = TextRef(exeOffset: program.dsFileOffset + ds, dsOffset: ds, position: pos, routine: routine, bytes: machine.string(at: ds))
        if let v = textColourVars[routine] { t.colour = Int(machine.read8(v)) }
        t.messageSerial = messageSerial
        t.afterRenders = messageRenders
        return t
    }

    private func csRead(_ a: Int) -> UInt8 {
        let k = glue.csKeys
        let input = engine?.input ?? []
        switch a {
        case k["left"]: return input.contains(.leftFlipper) ? 1 : 0
        case k["right"]: return input.contains(.rightFlipper) ? 1 : 0
        case k["ctrl"]: return input.contains(.plunger) ? 1 : 0
        case k["space"]: return input.contains(.space) ? 1 : 0
        case k["nudge_a"]: return input.contains(.nudgeA) ? 1 : 0
        case k["nudge_b"]: return input.contains(.nudgeB) ? 1 : 0
        case k["up"], k["down"]: return 0
        case k["scancode"]: return 0x8C   // a key release: no pending menu key
        default:
            // direct rule code: the flipper flags the lifted rules read as ["input", ...]
            if directDepth > 0, let w = program.inputKeys[a] { return engine.map { UInt8($0.rulesInput(w)) } ?? 0 }
            return machine.code[a & 0xFFFF]
        }
    }

    /// What a call from x86 code does (the callout's decision, shared with `directCodeReport`).
    enum CallEffect: Equatable {
        case none, sfx, lampUpdate, gameOver, ballLostFade, gates([Int]), liftedHook(Int), message, text, number, paletteStep, spriteSet
        /// A frame wait (EP2-13: `doFrameWait`, render_frame steps the message counter).
        case frameWait
    }

    /// The callout's decision for a call to `target` (`farSeg` nil = near): run the callee, apply
    /// an effect, stop, or unknown. `direct` = direct-backend rule code is running.
    func classifyCall(_ target: Int, _ farSeg: Int?, direct: Bool) -> (MiniX86.CallResult, CallEffect) {
        let csSeg = Int(x86.csValue)
        if let seg = farSeg, let api = glue.soundAPISegment, seg == api { return (.handled, .none) }   // MASI driver
        let r = glue.routines
        if target == r["sfx_play"] { return (.handled, .sfx) }
        if counterEffects != nil, farSeg == nil || farSeg == csSeg, frameWait(target) { return (.handled, .frameWait) }
        // a display routine for the rules (stub / isDisplayRoutine): only reported to the presentation
        if spriteSetRoutines.contains(where: { $0.entry == target }) { return (.handled, .spriteSet) }
        if target == r["idle_text"] || target == r["gate_top"] || glue.follow.contains(target) || program.gateRoutines.contains(target) {
            return (farSeg == nil ? .follow : .unknown, .none)
        }
        if target == r["lamp_update"] { return (.handled, .lampUpdate) }
        if target == r["pause_menu"] { return (.halt, .gameOver) }
        if target == r["ball_lost_fade"] { return (.handled, .ballLostFade) }
        if let gs = gatesByRoutine[target] { return (.handled, .gates(gs)) }
        if let h = hookByIP[target] {
            if program.direct { return (farSeg == nil || farSeg == csSeg ? .follow : .unknown, .none) }
            return (.handled, .liftedHook(h))
        }
        if target == idleScoreRefresh { return (farSeg == nil ? .follow : .unknown, .none) }
        if let stub = program.stubs[target] {
            // direct rule code runs num_to_text from the EXE (it writes the digits into DS)
            if stub.kind == "number", direct { return (.follow, .none) }
            switch stub.kind {
            case "message": return (.handled, .message)
            case "text": return (.handled, .text)
            case "number": return (.handled, .number)
            default: return (.handled, .none)   // score_refresh, dmd_clear: display only
            }
        }
        if target == r["text3"] || textRoutines.contains(target) { return (.handled, .text) }
        for name in ["wait_frame", "wait_frame_far", "set_scroll", "draw_plunger", "pause_overlay", "split_line", "flipper_sprite",
                     "raster_bar", "restore_ball_bg", "save_ball_bg", "camera_update", "blit_list", "render_frame"] where r[name] == target {
            return (.handled, .none)
        }
        if let pc = paletteCycle, target == pc.routine || target == pc.waitRoutine { return (.handled, .paletteStep) }
        if isDisplayRoutine(target) { return (.handled, .none) }
        // Inside a rule-code `call` (EP10 cs:341B -> cs:358A num_to_text): execute the callee.
        if nativeDepth > 0, farSeg == nil { return (.follow, .none) }
        // Glue calling rule code (EP2 lane cs:0CAF -> cs:3BAF dmd_idle_text, a gosub of the hooks).
        if farSeg == nil, program.isRuleSubroutine(target) { return (.follow, .none) }
        // Direct rule code: gosubs and the lifted backend's `call` ops (far calls into the code segment too).
        if direct, farSeg == nil || farSeg == csSeg { return (.follow, .none) }
        return (.unknown, .none)
    }

    private func callout(_ x: MiniX86, _ ip: Int, _ target: Int, _ farSeg: Int?) -> MiniX86.CallResult {
        let (res, eff) = classifyCall(target, farSeg, direct: directDepth > 0)
        switch eff {
        case .none: break
        case .sfx: sfxPlay(ax: Int(x.ax))
        case .lampUpdate: lampUpdate(phaseAddr: Int(x.si))
        case .gameOver: gameOver = true
        case .ballLostFade: ballLostFade()
        case let .gates(gs): for gi in gs { machine.drawGate(gi) }
        case let .liftedHook(h): machine.call(h)
        case .message: startMessage(ds: Int(x.bx), ax: Int(x.ax), pos: Int(x.di))
        case .text: pendingTexts.append(textRef(ds: Int(x.bx), pos: Int(x.di), routine: target))
        case .number: machine.writeNumber(UInt32(x.dx) << 16 | UInt32(x.ax), buffer: Int(x.bx))
        case .paletteStep: paletteCycleStep()
        case .frameWait: doFrameWait(target)
        case .spriteSet:
            pendingSpriteSets.append(SpriteSetEvent(routine: target, selector: Int(x.ax & 0xFF)))
            spriteSetsShown[target] = Int(x.ax & 0xFF)
        }
        return res
    }

    /// Routines that append a text line to the active dot message (EP1 draw_text cs:59AC / draw_text_hi
    /// cs:5926, EP10 cs:4C65 / 4CFB / 4D93): `[mov al,[c]; mov cs:[x],al;] mov ax,ds; mov es,ax;
    /// push ds; mov ax,SEG; mov ds,ax; mov si,[P]; mov word [P],0; pop ds` (P = the message's line
    /// pointer in the display segment). rules.json lists only the ones rule code calls; glue and
    /// natively run code (EP10 cs:341B, the end-of-ball score panel) call others.
    static func textRoutines(code c: [UInt8]) -> Set<Int> {
        var out = Set<Int>()
        for i in 0..<(0x10000 - 22) where c[i] == 0x8C && c[i + 1] == 0xD8 && c[i + 2] == 0x8E && c[i + 3] == 0xC0 && c[i + 4] == 0x1E
            && c[i + 5] == 0xB8 && c[i + 8] == 0x8E && c[i + 9] == 0xD8 && c[i + 10] == 0x8B && c[i + 11] == 0x36
            && c[i + 14] == 0xC7 && c[i + 15] == 0x06 && c[i + 16] == c[i + 12] && c[i + 17] == c[i + 13]
            && c[i + 18] == 0 && c[i + 19] == 0 && c[i + 20] == 0x1F {
            if i >= 7, c[i - 7] == 0xA0, c[i - 4] == 0x2E, c[i - 3] == 0xA2 { out.insert(i - 7) } else { out.insert(i) }
        }
        return out
    }

    private var displayRoutineCache: [Int: Bool] = [:]

    /// A routine that switches DS to a constant graphics segment or ES to VGA memory (A000h) within
    /// its first instructions cannot change the table's DS state: its call is display only (EP6
    /// cs:5150 dmd_clear, the same shape rules.py's `far_ds_display` lifts as a display op).
    func isDisplayRoutine(_ t: Int) -> Bool {
        if let v = displayRoutineCache[t] { return v }
        let c = machine.code
        var ip = t, lastImm: (reg: Int, v: Int)?, result = false
        for _ in 0..<16 {   // EP6 cs:4FCA: 8 pushes and 2 register moves before `mov ds, ax`
            let op = Int(c[ip & 0xFFFF])
            if (0xB8...0xBF).contains(op) {
                let v = Int(c[(ip + 1) & 0xFFFF]) | Int(c[(ip + 2) & 0xFFFF]) << 8
                if v == 0xA000 { result = true; break }
                lastImm = (op - 0xB8, v)
            } else if op == 0x8E, let li = lastImm {
                let m = Int(c[(ip + 1) & 0xFFFF])
                if m >> 6 == 3, m & 7 == li.reg, (m >> 3) & 7 == 3, li.v != Int(x86.dsValue) { result = true; break }
            } else if op == 0x8B || op == 0x8C || op == 0x89, Int(c[(ip + 1) & 0xFFFF]) >> 6 == 3 {
                // register-register move (EP6 cs:4FCA mov cx,di; mov ax,ds): drops a tracked constant
                let m = Int(c[(ip + 1) & 0xFFFF])
                let dst = op == 0x8B ? (m >> 3) & 7 : m & 7
                if lastImm?.reg == dst { lastImm = nil }
            } else if ![0xFC, 0x1E, 0x06, 0x60, 0x50, 0x51, 0x52, 0x53, 0x55, 0x56, 0x57].contains(op) {
                if op != 0x8E { break }
            }
            guard let n = x86.length(at: ip) else { break }
            ip += n
        }
        displayRoutineCache[t] = result
        return result
    }

    // MARK: - sound

    /// sfx_play (EP1 cs:014A): returns unless SFX are on and a card is present (the PC-speaker path
    /// is not ported), then plays sample AL at the global rate with the pan rule. Round-robin voice
    /// allocation is the audio side's (PinballAudio mirrors it).
    func sfxPlay(ax: Int) {
        guard let rate = program.engineVars["sound.rate"] else { return }
        let hz = Int(machine.read(rate.addr, 2))
        var pan = (ax >> 12) & 0xF
        if pan == 0 {
            let x = UInt16(bitPattern: engine?.balls[0].x ?? 0)
            pan = Int((x / 20) & 0xFF)
        }
        pan = min(pan, 15)
        if traceCalls { sfxCalls.append([ax & 0xFFFF, hz, pan]) }
        if let a = glue.ds["opt_sfx"], machine.read8(a) == 0 { return }
        if let a = glue.ds["snd_present"], machine.read8(a) == 0 { return }
        pendingSounds.append(SoundEvent(sample: ax & 0xFF, rateHz: hz, sweepPerFrame: 0, sweepFrames: 0, pan: pan))
    }

    /// For tables whose sound code is not in the glue: the EP1 shape with rules.json's sweep
    /// parameters ([M]: queue at 11000 Hz with a 5-frame gap, sweeps stepped when
    /// (counter & mask) == phase, rate back to 11000 at the limit, step/end ids from their DS words).
    func genericSoundBlock() {
        let ev = program.engineVars
        guard let rate = ev["sound.rate"] else { return }
        if let q = ev["sound.queue"] {
            let id = Int(machine.read(q.addr, 2))
            if id != 0xFFFF {
                if sfxPendingDelay == 0 {
                    let saved = machine.read(rate.addr, 2)
                    machine.write(rate.addr, 2, 11000)
                    sfxPlay(ax: id)
                    machine.write(rate.addr, 2, saved)
                    sfxPendingDelay = 5
                    machine.write(q.addr, 2, 0xFFFF)
                }
                sfxPendingDelay = max(0, sfxPendingDelay - 1)
            }
        }
        for s in program.sweeps {
            var c = Int(machine.read8(s.counter))
            guard c != 0 else { continue }
            c = (c + 1) & 0xFF
            machine.write8(s.counter, UInt8(c))
            guard c & s.mask == s.phase else { continue }
            var hz = Int(machine.read(rate.addr, 2)) + s.rateStep
            machine.write(rate.addr, 2, Int64(hz & 0xFFFF))
            hz &= 0xFFFF
            let finished = s.rateStep >= 0 ? hz >= s.rateLimit : hz <= s.rateLimit
            if finished {
                machine.write(rate.addr, 2, 11000)
                machine.write8(s.counter, 0)
                for a in s.endIDVars {
                    let id = Int(machine.read(a, 2))
                    if id != 0 { sfxPlay(ax: id); machine.write(a, 2, 0) }
                }
            } else {
                for a in s.stepIDVars { sfxPlay(ax: Int(machine.read(a, 2))) }
                for id in s.stepConstIDs { sfxPlay(ax: id) }
            }
        }
        if let n = ev["sound.now"] {
            let id = Int(machine.read(n.addr, 2))
            if id != 0 { sfxPlay(ax: id); machine.write(n.addr, 2, 0) }
        }
    }

    // MARK: - lamps

    /// lamp_update (EP1 cs:478D) on the table whose phase byte is at `si0` (lamp slot k at si0+1+k):
    /// 3 visits per frame. A lamp in state 1/2 (draw once) is served first (-> 5/6); otherwise the
    /// phase byte picks the next lamp from the order table and wraps past the limit; a blinking lamp
    /// (3/4) is redrawn and toggled; 0 and steady lamps are skipped.
    func lampUpdate(phaseAddr si0: Int) {
        guard !glue.lampOrder.isEmpty else { genericLampUpdate(phaseAddr: si0); return }
        for _ in 0..<3 {
            var si = si0 + 1, cx = 1, found = false
            while cx <= 256 {
                let s = machine.read8(si)
                if s == 0xFF { break }
                if s == 1 || s == 2 { found = true; break }
                cx += 1; si += 1
            }
            if !found {
                let phase = Int(machine.read8(si0))
                let cl = glue.lampOrder[phase & 0xFF]
                let next = (phase + 1) & 0xFF
                machine.write8(si0, UInt8(next))
                if next > glue.lampPhaseLimit { machine.write8(si0, 1); continue }
                si = si0 + cl
                cx = cl
            }
            let slot = cx - 1
            let st = machine.read8(si)
            if st > 4 {
                if st == 0xFF { machine.write8(si0, 1) }
                continue
            }
            switch st {
            case 0: continue
            case 1: machine.write8(si, 5); drew(slot, 1)
            case 2: machine.write8(si, 6); drew(slot, 2)
            case 3: machine.write8(si, 4); drew(slot, 1)
            default: machine.write8(si, 3); drew(slot, 2)
            }
        }
    }

    private func drew(_ slot: Int, _ sprite: UInt8) {
        if slot >= 0 && slot < lampDrawn.count { lampDrawn[slot] = sprite }
    }

    /// Tables without a decoded order table ([L]): pending draws at once, blinking every 16 frames.
    func genericLampUpdate(phaseAddr si0: Int) {
        genericLampTick += 1
        let n = lampDrawn.count
        for slot in 0..<n {
            let a = si0 + 1 + slot
            switch machine.read8(a) {
            case 0xFF: return
            case 1: machine.write8(a, 5); drew(slot, 1)
            case 2: machine.write8(a, 6); drew(slot, 2)
            case 3 where genericLampTick % 16 == 0: machine.write8(a, 4); drew(slot, 1)
            case 4 where genericLampTick % 16 == 0: machine.write8(a, 3); drew(slot, 2)
            default: break
            }
        }
    }

    // MARK: - presentation

    public var score: UInt32 {
        guard let s = program.engineVars["score"] else { return 0 }
        return UInt32(truncatingIfNeeded: machine.read(s.addr, 4))
    }

    /// The palette on screen as the fades' machine (`ScreenFade.Machine`): W (the mirrored fades, else the base
    /// palette >> 2; EP8's ring from the data segment), the DAC (W with EP8's DAC ring) and EP8's rotation
    /// counter and speed. Entry 255 is the message colour, which the end-of-game fade-out leaves alone.
    public func screenMachine() -> ScreenFade.Machine? {
        guard let sf = screenFade else { return nil }
        let ds = machine.initialDS
        guard sf.base >= 0, sf.base + 768 <= ds.count else { return nil }
        var w = fadeWorking ?? sf.runtimeBase(Array(ds[sf.base..<(sf.base + 768)])).map { $0 >> 2 }
        var dac = w
        var counter: UInt8 = 0, speed: UInt8 = 0
        if let pc = paletteCycle, pc.ring - sf.working >= 0, pc.ring - sf.working + pc.ringBytes <= 768 {
            let r0 = pc.ring - sf.working
            for k in 0..<pc.ringBytes { w[r0 + k] = machine.read8(pc.ring + k) }
            dac = w
            let d0 = 3 * pc.firstIndex
            if let d = dacRing, d0 + d.count <= 768 { dac.replaceSubrange(d0..<(d0 + d.count), with: d) }
            counter = machine.read8(pc.counter)
            speed = machine.read8(pc.speed)
        }
        return ScreenFade.Machine(working: w, dac: dac, counter: counter, speed: speed)
    }

    /// DAC entries 0..254 where the faded working palette differs from the base palette (6-bit -> 8-bit
    /// like the ring below). The flag going to 1 is ball_lost_fade's dim, back to 0 the release restore.
    private func fadeOverrides() -> [PaletteOverride] {
        guard let pf = paletteFade, var w = fadeWorking else { return [] }
        if let f = pf.flag {
            let v = machine.read8(f)
            if v != fadeFlag {
                if v == 1 { pf.dim(&w) } else if v == 0 { w = pf.restored(base: fadeBase) }
                fadeFlag = v
                fadeWorking = w
            }
        }
        func c(_ v: UInt8) -> UInt8 { let x = v & 0x3F; return x << 2 | x >> 4 }
        let e = fadeEXEBase
        var out: [PaletteOverride] = []
        for i in 0..<255 {
            let k = 3 * i
            if w[k] == e[k] >> 2 && w[k + 1] == e[k + 1] >> 2 && w[k + 2] == e[k + 2] >> 2 { continue }
            out.append(PaletteOverride(index: UInt8(i), r: c(w[k]), g: c(w[k + 1]), b: c(w[k + 2])))
        }
        return out
    }

    /// Fills the rules-derived fields of `state` and clears the per-frame queues (sounds, texts).
    public func takePresentation(into state: inout PresentationState) {
        let d = glue.ds
        let n = program.lampCount
        state.lamps = (0..<n).map { $0 < lampDrawn.count && lampDrawn[$0] == 1 }
        state.lampStates = (0..<n).map { machine.read8(program.lampFirst + $0) }
        state.lampSprites = lampDrawn
        let players = d["player_count"].map { max(1, min(4, Int(machine.read8($0)))) } ?? 1
        let current = d["current_player"].map { max(1, min(players, Int(machine.read8($0)))) } ?? 1
        state.playerCount = players
        state.currentPlayer = current - 1
        var scores = [UInt32](repeating: 0, count: players)
        let live = score
        if let tbl = d["player_blocks"], let pb = program.playerBlock, let s = program.engineVars["score"] {
            for p in 1...players {
                if p == current { scores[p - 1] = live; continue }
                let base = Int(machine.read(tbl + 2 * (p - 1), 2))
                scores[p - 1] = UInt32(truncatingIfNeeded: machine.read(base + (s.addr - pb.lowerBound), 4))
            }
        } else {
            scores[current - 1] = live
        }
        state.scores = scores
        if let a = d["ball_number"] { state.ballNumber = Int(machine.read8(a)) }
        if let t = program.engineVars["tilted"] { state.tilted = machine.read(t.addr, t.size) != 0 }
        let counter = msgCounter
        if let m = message, counter != 0 {
            var ref = MessageRef(exeOffset: program.dsFileOffset + m.ds, mode: UInt8(msgEffect), framesRemaining: -1)
            if let fx = glue.messageEffects[msgEffect], fx.endCount > 0 {
                let end = fx.fadeFrames > 0 ? fx.endCount + fx.fadeFrames - 1 : fx.endCount + 1
                ref.framesRemaining = max(0, end - counter)
            }
            ref.dsOffset = m.ds
            ref.modeWord = UInt16(truncatingIfNeeded: m.ax)
            ref.position = m.pos
            ref.bytes = machine.string(at: m.ds)
            ref.colour = m.colour
            ref.serial = messageSerial
            ref.renderFrames = messageRenders
            if msgCounterAddr != nil { ref.counter = counter }
            state.message = ref
        } else {
            state.message = nil
        }
        state.soundEvents = pendingSounds
        state.texts = pendingTexts
        state.spriteSets = pendingSpriteSets
        if !spriteSetRoutines.isEmpty {
            state.spriteSetsShown = spriteSetsShown.keys.sorted().map { SpriteSetEvent(routine: $0, selector: spriteSetsShown[$0]!) }
        }
        pendingSpriteSets.removeAll(keepingCapacity: true)
        state.paletteOverrides = fadeOverrides()
        if let pc = paletteCycle, let d = dacRing {
            // 6-bit DAC values -> 8-bit (v << 2 | v >> 4), for the renderer's palette pass.
            func c(_ v: UInt8) -> UInt8 { let x = v & 0x3F; return x << 2 | x >> 4 }
            state.paletteOverrides += (0..<pc.colours).compactMap { k in
                let i = pc.firstIndex + k
                guard i < 256 else { return nil }
                return PaletteOverride(index: UInt8(i), r: c(d[3 * k]), g: c(d[3 * k + 1]), b: c(d[3 * k + 2]))
            }
        }
        state.gameOver = gameOver
        state.music = nil
        pendingSounds.removeAll(keepingCapacity: true)
        pendingTexts.removeAll(keepingCapacity: true)
    }
}

// MARK: - Save states (Replay/SimulationSnapshot.swift)

extension RulesRuntime {
    /// The rules' mutable state: the machine's data segment, MiniX86 (registers, stack, retrace
    /// toggle), the message / lamp / sound bookkeeping and the queued presentation events. The
    /// program, glue and caches are derived from the EXE and stay.
    public struct State {
        var machine: RulesMachine.State
        var x86: MiniX86.State
        var options: RulesOptions
        var gameOver: Bool
        var sfxCalls: [[Int]], messageCalls: [[Int]]
        var warnings: [String], reported: Set<String>
        var pendingSounds: [SoundEvent], pendingTexts: [TextRef]
        var message: (ds: Int, ax: Int, pos: Int)?
        var localCounter: Int, localEffect: Int
        var lampDrawn: [UInt8]
        var genericLampTick: Int, sfxPendingDelay: Int
        var dacRing: [UInt8]?
        var nativeDepth: Int, directDepth: Int
        var counterEffects: DotEffects.State?
        var fadeWorking: [UInt8]?, fadeFlag: UInt8
        var spriteSetsShown: [Int: Int] = [:]
    }

    public func saveState() -> State {
        State(machine: machine.saveState(), x86: x86.saveState(), options: options, gameOver: gameOver, sfxCalls: sfxCalls,
              messageCalls: messageCalls, warnings: warnings, reported: reported, pendingSounds: pendingSounds,
              pendingTexts: pendingTexts, message: message.map { ($0.ds, $0.ax, $0.pos) }, localCounter: localCounter,
              localEffect: localEffect, lampDrawn: lampDrawn, genericLampTick: genericLampTick, sfxPendingDelay: sfxPendingDelay,
              dacRing: dacRing, nativeDepth: nativeDepth, directDepth: directDepth, counterEffects: counterEffects?.saveState(),
              fadeWorking: fadeWorking, fadeFlag: fadeFlag, spriteSetsShown: spriteSetsShown)
    }

    public func restoreState(_ s: State) {
        machine.restoreState(s.machine); x86.restoreState(s.x86)
        options = s.options; gameOver = s.gameOver; sfxCalls = s.sfxCalls; messageCalls = s.messageCalls
        warnings = s.warnings; reported = s.reported; pendingSounds = s.pendingSounds; pendingTexts = s.pendingTexts
        message = s.message.map { LastMessage(ds: $0.ds, ax: $0.ax, pos: $0.pos) }
        localCounter = s.localCounter; localEffect = s.localEffect; lampDrawn = s.lampDrawn
        genericLampTick = s.genericLampTick; sfxPendingDelay = s.sfxPendingDelay; dacRing = s.dacRing
        nativeDepth = s.nativeDepth; directDepth = s.directDepth
        if let c = s.counterEffects { counterEffects?.restoreState(c) }
        fadeWorking = s.fadeWorking; fadeFlag = s.fadeFlag; spriteSetsShown = s.spriteSetsShown
    }

    /// The rule-visible state: the whole data segment as the rules see it (engine-bound bytes
    /// included), the machine's memory beyond it, MiniX86 and the bookkeeping. Queued sounds and
    /// texts are outputs, not state, and are left out.
    func digest(into h: inout StateHasher) {
        h.add(machine.snapshot())
        h.add(machine.mem)
        x86.digest(into: &h)
        h.add(gameOver)
        if let m = message { h.add(m.ds); h.add(m.ax); h.add(m.pos) } else { h.add(-1) }
        h.add(localCounter); h.add(localEffect); h.add(lampDrawn); h.add(genericLampTick); h.add(sfxPendingDelay)
        h.add(dacRing ?? [])
    }
}
