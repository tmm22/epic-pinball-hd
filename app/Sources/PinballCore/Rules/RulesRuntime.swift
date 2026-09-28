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
///   `texts` = score-strip text drawn this frame (draw_text routines), same referencing.
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
    private struct LastMessage { var ds: Int; var ax: Int; var pos: Int }
    private var message: LastMessage?
    private var localCounter = 0
    private var localEffect = 0
    private var msgCounter: Int {
        get { glue.ds["msg_counter"].map { Int(machine.read($0, 2)) } ?? localCounter }
        set { if let a = glue.ds["msg_counter"] { machine.write(a, 2, Int64(newValue)) } else { localCounter = newValue & 0xFFFF } }
    }
    private var msgEffect: Int {
        get { glue.ds["msg_effect"].map { Int(machine.read8($0)) } ?? localEffect }
        set { if let a = glue.ds["msg_effect"] { machine.write8(a, UInt8(newValue & 0xFF)) } else { localEffect = newValue & 0xFF } }
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
        glue = TableGlue.make(program: program, machine: machine)
        x86 = MiniX86(machine: machine)
        paletteCycle = PaletteCycle.find(code: machine.code)
        textRoutines = Self.textRoutines(code: machine.code)
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
        paletteCycle?.bootRing(machine)   // the boot fade-in leaves the ring at base >> 2
        dacRing = nil
        gameOver = false
        message = nil
        localCounter = 0
        localEffect = 0
        pendingSounds.removeAll()
        pendingTexts.removeAll()
        lampDrawn = [UInt8](repeating: 0, count: lampDrawn.count)
        sfxPendingDelay = 0
        let d = glue.ds
        // entry cs:0019..0055: players '1'..'4', option bits, balls digit; cs:00CA..: sound pointers.
        if let a = d["player_count"] { machine.write8(a, UInt8(max(1, min(4, options.players)))) }
        if let a = d["balls_per_game"] { machine.write8(a, UInt8(max(0, min(9, options.ballsPerGame)))) }
        if let a = d["opt_sfx"] { machine.write8(a, options.sfx ? 1 : 0) }
        if let a = d["opt_music"] { machine.write8(a, options.music ? 1 : 0) }
        if let a = d["snd_present"] { machine.write8(a, options.soundPresent ? 1 : 0) }
        if let idle = glue.routines["idle_text"], glue.range("idleText") != nil { runRoutine(idle, "idle_text") }
        _ = runRange("init")
        pendingSounds.removeAll()
    }

    // MARK: - main-loop pieces (called by ClassicEngine)

    // MARK: - automatic main loop (EP2-EP13, full mode)

    /// Tables whose main-loop hooks were found by rules.py's pattern search (rules.md 4.1).
    public var hasAutomaticHooks: Bool { program.hooks.values.contains { $0.when != nil } }

    public enum MainLoopItem: Equatable, Sendable {
        case hook(String), glue(String)
        case decay, gates, sound, counters, drain, lane, nudge, lamps, gravity, render, paletteCycle
    }
    private var cachedSchedule: [MainLoopItem]?

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
        let glueRanges = ["preFrame", "postTimers", "ruleTimers", "preGravity"].compactMap { n in glue.range(n).map { (n, $0) } }
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
        items.append((0x10000, 0, .render))
        // The main loop's call (EP8 cs:0843; its intro loop's call cs:0435 lies before the first hook).
        let loopStart = every.map(\.entryIP).min() ?? 0
        for s in paletteCycle?.callSites ?? [] where s >= loopStart { items.append((s, 0, .paletteCycle)) }
        let s = items.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
        cachedSchedule = s
        return s
    }

    /// End of ball for tables with automatic hooks: the `ball_end` hooks from the first one, following
    /// `continues` after each cut (rules.md 4.1), then the end-of-turn counters (player switch, ball
    /// number, game over) if the hooks did not run that code (TableGlue.discoverEndOfTurn).
    func automaticBallEnd() {
        let ends = program.hooks.values.filter { $0.when == "ball_end" }.sorted { $0.entryIP < $1.entryIP }
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
            while let cur = name, n < 16 {
                var stopIP: Int?
                if program.direct {
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
                name = stopIP.flatMap { program.hooks[cur]?.continues[$0] }
                // The cut is the call the lift could not express (EP6 cs:31D8 call 3BD4, the gate
                // redraw; cs:31CB the idle text): run it from the EXE, then continue after it.
                if name != nil, let stop = stopIP, machine.code[stop] == 0xE8 {
                    let t = (stop + 3 + (Int(machine.code[stop + 1]) | Int(machine.code[stop + 2]) << 8)) & 0xFFFF
                    var regs: [String: UInt16] = [:]
                    _ = nativeCall(target: t, from: stop, registers: &regs)
                }
            }
            machine.watched = []
        }
        let d = glue.ds
        guard let pA = d["current_player"], let pcA = d["player_count"], let bA = d["ball_number"], let bpgA = d["balls_per_game"] else { return }
        if !countedByHooks {
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
    func runDirect(_ entry: Int, _ what: String, watch: Range<Int>? = nil, setup: (MiniX86) -> Void = { _ in })
        -> (result: MiniX86.Stop, stop: Int?, watchHit: Bool) {
        let saved = x86.r, savedES = x86.es
        let savedStops = x86.stops, savedEpi = x86.stopAtEpilogue, savedWatch = x86.watch, savedStopIP = x86.stopIP
        x86.resetRegisters()
        x86.r[4] = saved[4] == 0 ? MiniX86.initialSP : saved[4] &- 0x100
        x86.stops = stopBitmap
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
        let s = x86.run(from: r.start, to: r.end)
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
        var c = msgCounter
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
            pendingTexts.append(textRef(ds: ds, pos: pos, routine: routine))
        case let .display(what):
            if what == "idle_text", let idle = glue.routines["idle_text"], glue.range("idleText") != nil {
                runRoutine(idle, "idle_text")
            } else if what == "idle_text" {
                // Tables without the glue: the one rule-visible effect (EP1 cs:3B16..3B1D).
                if let t = program.engineVars["tilted"], machine.read(t.addr, t.size) == 1, let m = program.vars["mode"] { machine.write(m, 0) }
            }
        case .number, .scoreRefresh, .outsideWrite:
            break
        }
    }

    /// A dmd_message call made by engine-side code (EP8's launch, cs:0C30).
    public func showMessage(ds: Int, ax: Int, di: Int) { startMessage(ds: ds, ax: ax, pos: di) }

    private func startMessage(ds: Int, ax: Int, pos: Int) {
        // dmd_message cs:15DE: [0B3B] = 0, [0B3A] = AL, text rendered, [0B3D] = 1.
        if traceCalls { messageCalls.append([ds, ax & 0xFFFF, pos & 0xFFFF]) }
        message = LastMessage(ds: ds, ax: ax, pos: pos)
        if let a = glue.ds["msg_scroll"] { machine.write(a, 2, 0) }
        msgEffect = ax & 0xFF
        msgCounter = 1
    }

    private func textRef(ds: Int, pos: Int, routine: Int) -> TextRef {
        TextRef(exeOffset: program.dsFileOffset + ds, dsOffset: ds, position: pos, routine: routine, bytes: machine.string(at: ds))
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
        case none, sfx, lampUpdate, gameOver, ballLostFade, gates([Int]), liftedHook(Int), message, text, number, paletteStep
    }

    /// The callout's decision for a call to `target` (`farSeg` nil = near): run the callee, apply
    /// an effect, stop, or unknown. `direct` = direct-backend rule code is running.
    func classifyCall(_ target: Int, _ farSeg: Int?, direct: Bool) -> (MiniX86.CallResult, CallEffect) {
        let csSeg = Int(x86.csValue)
        if let seg = farSeg, let api = glue.soundAPISegment, seg == api { return (.handled, .none) }   // MASI driver
        let r = glue.routines
        if target == r["sfx_play"] { return (.handled, .sfx) }
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
            state.message = ref
        } else {
            state.message = nil
        }
        state.soundEvents = pendingSounds
        state.texts = pendingTexts
        if let pc = paletteCycle, let d = dacRing {
            // 6-bit DAC values -> 8-bit (v << 2 | v >> 4), for the renderer's palette pass.
            func c(_ v: UInt8) -> UInt8 { let x = v & 0x3F; return x << 2 | x >> 4 }
            state.paletteOverrides = (0..<pc.colours).compactMap { k in
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
