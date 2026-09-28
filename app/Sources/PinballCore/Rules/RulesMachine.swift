import Foundation

// Interpreter for the lifted table rules (`RulesProgram`), a Swift port of the reference interpreter
// scratch/rules/verify_ir.py (class `IR`), which the rules verifier checked against the original code
// (docs/formats/rules.md section 5).
//
// Memory model (docs/formats/rules.md 3.1, 5):
// * `mem` is the table's 64 KB data-segment window. Offsets 0 ..< dsSize start as the bytes the
//   user's EXE holds at `data_segment_file_offset`. Past dsSize the original's window overlaps the
//   playfield image, i.e. the live collision buffer: reads and writes there go to the host's buffer
//   (only reached with out-of-range counters, rules.md 4 item 5).
// * Bytes the physics engine owns (ball working copy and slots, lockout, cooldown, kicker, tilt,
//   extra gravity, serve delay, parameter block, ...) are *bound* to the engine: reads and writes go
//   straight to the engine's fields (byte-exact, also for partial writes to a word), so engine and
//   rules never disagree. Everything else lives in `mem`.
// Arithmetic follows the schema: values are mathematical integers (Int64 here), truncated at stores,
// conditions, memory addresses and in lo/hi/shr/div/join/setlo/sethi/shl/neg.

/// A DS byte range owned by the physics engine.
public enum EngineField: Hashable, Sendable {
    case objX, objY, objVX, objVY, writeback, layer
    case slotX(Int), slotY(Int), slotVX(Int), slotVY(Int), slotAccX(Int), slotAccY(Int), slotActive(Int), slotLayer(Int)
    case lockout, cooldown, kickerCooldown, kickStrength, tilted, extraGravity, serveDelay, plungerCharge
    case nudgeTimer, tiltMeter, hitCount, flipperAngle(Int), flipperDrawn(Int), flipperMoving(Int)
    case param(Int)
    /// EP9-13 per-ball sensor lockout byte of slot i.
    case lockoutSlot(Int)
}

/// The engine side of the bus. `ClassicEngine` implements it.
public protocol RulesHost: AnyObject {
    /// Current value of a bound field (as the unsigned bits of its width).
    func rulesField(_ f: EngineField) -> Int
    func rulesSetField(_ f: EngineField, _ v: Int)
    /// Collision buffer byte (linear offset into the 320x400 buffer; out of range reads 0).
    func rulesPixel(_ i: Int) -> UInt8
    func rulesSetPixel(_ i: Int, _ v: UInt8)
    /// 0 = left flipper key, 1 = right flipper key (1 = held).
    func rulesInput(_ which: Int) -> Int
}

/// Display-side effects of rule code (the routines the lift stubs out).
public enum RulesEvent: Sendable, Equatable {
    /// dot-matrix message: string at DS `ds`; `mode` = AX (AH placement/font, AL effect); `pos` = DI.
    case message(ds: Int, mode: Int, pos: Int)
    /// score-strip text at DS `ds`, position DI, drawn by `routine` (cs offset).
    case text(ds: Int, pos: Int, routine: Int)
    /// num_to_text: `value` formatted into the DS buffer `buf` (the digits are written by the machine).
    case number(value: UInt32, buf: Int)
    case scoreRefresh
    /// Other display routines: "clear" (dmd_clear), "idle_text" (dmd_idle_text), ...
    case display(String)
    /// A write the original sends outside the playfield (EP1 diverter bug); not applied.
    case outsideWrite(offset: Int, value: UInt8)
}

public final class RulesMachine {
    public let program: RulesProgram
    /// The code segment (64 KB) of the user's EXE, for `cmem` reads and `MiniX86`.
    public let code: [UInt8]
    /// The data segment as stored in the EXE (dsSize bytes).
    public let initialDS: [UInt8]
    public weak var host: RulesHost?

    public private(set) var mem: [UInt8]
    private var tags: [Int16]
    private var bindings: [(field: EngineField, addr: Int, size: Int)] = []

    // per invocation
    private var regs: [Int64]
    private var defined: [Bool]
    private enum StackItem { case value(Int64?), regs([Int64], [Bool]) }
    private var stack: [StackItem] = []
    private var steps = 0
    private var currentBlock = -1
    private var depth = 0
    /// The pixel value the kicker probe hit (EP2/EP10 `contact_colour`).
    public var contactColour = 0

    /// Receives every display event synchronously, in program order (display routines with DS
    /// side effects, e.g. dmd_idle_text, must act at that point).
    public var eventSink: ((RulesEvent) -> Void)?
    /// Executes an unlifted call (target, call-site ip, registers in/out); false if it could not.
    public var nativeCall: ((Int, Int, inout [String: UInt16]) -> Bool)?
    static let machineRegisters = ["ax", "bx", "cx", "dx", "si", "di", "bp"]
    /// Interpreter faults (reads of undefined registers, divide by zero, step-limit trips). Never
    /// expected on a feasible path; kept so tests and callers can assert none happened.
    public private(set) var faults: [String] = []
    public var maxStepsPerCall = 400_000
    /// Blocks executed during the last `call` (only tracked for labels in `watched`).
    public var watched: Set<Int> = []
    public private(set) var watchedHits: Set<Int> = []
    /// The hook stop (cs ip) the last top-level `call` returned at, nil if it returned elsewhere
    /// (the automatic ball_end hooks continue there, rules.json `continues`).
    public private(set) var lastStopIP: Int?
    /// Block coverage (labels executed) when non-nil, for tests.
    public var coverage: Set<Int>?

    public init(program: RulesProgram, exe: [UInt8]) throws {
        self.program = program
        guard exe.count >= 0x40, exe[0] == 0x4D, exe[1] == 0x5A else { throw RulesError.invalid("\(program.exe) is not an MZ executable") }
        let headerSize = Int(UInt16(exe[8]) | UInt16(exe[9]) << 8) * 16
        let dsEnd = program.dsFileOffset + program.dsSize
        guard program.dsFileOffset >= headerSize, dsEnd <= exe.count else {
            throw RulesError.invalid("\(program.exe) is too short for its data segment")
        }
        guard program.dsFileOffset == headerSize + program.dataSegment * 16 else {
            throw RulesError.invalid("\(program.exe): data segment 0x\(String(program.dataSegment, radix: 16)) does not match data_segment_file_offset")
        }
        initialDS = Array(exe[program.dsFileOffset..<dsEnd])
        let cs = headerSize + program.codeSegment * 16
        var c = [UInt8](repeating: 0, count: 0x10000)
        if cs < exe.count {
            let n = min(0x10000, exe.count - cs)
            c.replaceSubrange(0..<n, with: exe[cs..<(cs + n)])
        }
        code = c
        mem = [UInt8](repeating: 0, count: 0x10000)
        tags = [Int16](repeating: -1, count: 0x10000)
        regs = [Int64](repeating: 0, count: max(1, program.registerNames.count))
        defined = [Bool](repeating: true, count: regs.count)
        reset()
    }

    /// Back to the EXE's initial data segment (engine-bound bytes are the engine's business).
    public func reset() {
        mem = [UInt8](repeating: 0, count: 0x10000)
        mem.replaceSubrange(0..<initialDS.count, with: initialDS)
        faults.removeAll()
        stack.removeAll()
    }

    /// Binds `size` bytes at `addr` to an engine field. Later bindings win on overlap.
    public func bind(_ f: EngineField, addr: Int, size: Int) {
        guard addr >= 0, size > 0, addr + size <= 0x10000 else { return }
        let i = Int16(bindings.count)
        bindings.append((f, addr, size))
        for a in addr..<(addr + size) { tags[a] = i }
    }

    public func isBound(_ addr: Int) -> Bool { tags[addr & 0xFFFF] >= 0 }

    /// The data segment (dsSize bytes) as the rules see it, engine-bound bytes included.
    public func snapshot() -> [UInt8] {
        var out = Array(mem[0..<program.dsSize])
        for b in bindings where b.addr < program.dsSize {
            for a in b.addr..<min(b.addr + b.size, program.dsSize) { out[a] = read8(a) }
        }
        return out
    }
    public var boundFields: [(field: EngineField, addr: Int, size: Int)] { bindings }

    public func emit(_ e: RulesEvent) { eventSink?(e) }

    public func clearFaults() { faults.removeAll() }

    func fault(_ s: String) {
        if faults.count < 64 { faults.append(s) }
    }

    // MARK: - memory

    @inline(__always)
    public func read8(_ address: Int) -> UInt8 {
        let a = address & 0xFFFF
        let t = tags[a]
        if t >= 0, let h = host {
            let b = bindings[Int(t)]
            return UInt8(truncatingIfNeeded: h.rulesField(b.field) >> (8 * (a - b.addr)))
        }
        if a >= program.dsSize, let h = host { return h.rulesPixel(a - program.dsSize) }
        return mem[a]
    }

    @inline(__always)
    public func write8(_ address: Int, _ v: UInt8) {
        let a = address & 0xFFFF
        let t = tags[a]
        if t >= 0, let h = host {
            let b = bindings[Int(t)]
            let sh = 8 * (a - b.addr)
            let old = h.rulesField(b.field)
            h.rulesSetField(b.field, (old & ~(0xFF << sh)) | (Int(v) << sh))
            return
        }
        if a >= program.dsSize, let h = host { h.rulesSetPixel(a - program.dsSize, v); return }
        mem[a] = v
    }

    /// Little-endian read of `w` bytes (unsigned).
    public func read(_ address: Int, _ w: Int) -> Int64 {
        var v: Int64 = 0
        for i in 0..<w { v |= Int64(read8(address + i)) << (8 * i) }
        return v
    }

    public func write(_ address: Int, _ w: Int, _ value: Int64) {
        for i in 0..<w { write8(address + i, UInt8(truncatingIfNeeded: value >> (8 * i))) }
    }

    public func read(_ v: RulesProgram.Var) -> Int64 { read(v.addr, v.size) }
    public func write(_ v: RulesProgram.Var, _ value: Int64) { write(v.addr, v.size, value) }

    /// A named variable (`vars` / `engine_vars`), if the program has it.
    public func value(of name: String) -> Int64? { program.address(of: name).map { read($0) } }
    public func set(_ name: String, _ value: Int64) {
        if let v = program.address(of: name) { write(v, value) }
    }

    /// NUL-terminated DS string at `ds` (at most `limit` bytes), as the display routines read it.
    public func string(at ds: Int, limit: Int = 64) -> [UInt8] {
        var out: [UInt8] = []
        for i in 0..<limit {
            let b = read8(ds + i)
            if b == 0 { break }
            out.append(b)
        }
        return out
    }

    // MARK: - running graphs

    /// Runs a graph from block `entry` until it returns. Every register starts at 0 (rules.md 3.5:
    /// the only entry registers read are `ax` for sensor handlers and `di` for the kicker hook) except
    /// the ones given (by name).
    public func call(_ entry: Int, registers: [String: Int] = [:]) {
        for i in regs.indices { regs[i] = 0; defined[i] = true }
        for (name, v) in registers {
            if let i = program.registerNames.firstIndex(of: name) { regs[i] = Int64(v & 0xFFFF) }
        }
        stack.removeAll(keepingCapacity: true)
        steps = 0
        depth = 0
        watchedHits.removeAll(keepingCapacity: true)
        lastStopIP = nil
        run(entry)
    }

    @discardableResult
    public func callHook(_ name: String, registers: [String: Int] = [:]) -> Bool {
        guard let h = program.hooks[name] else { return false }
        call(h.entry, registers: registers)
        return true
    }

    private func run(_ entry: Int) {
        depth += 1
        defer { depth -= 1 }
        if depth > 64 { fault("gosub depth"); return }
        var label = entry
        let blocks = program.blocks
        while label >= 0 {
            steps += 1
            if steps > maxStepsPerCall { fault("step limit at \(blocks[label].label)"); return }
            if !watched.isEmpty, watched.contains(label) { watchedHits.insert(label) }
            if coverage != nil { coverage!.insert(label) }
            let b = blocks[label]
            currentBlock = label
            for o in b.ops { exec(o) }
            switch b.end {
            case .ret:
                if depth == 1 { lastStopIP = b.stopRet }
                return
            case let .goto(l): label = l
            case let .branch(c, t, e):
                let taken = cond(c)
                label = taken ? t : e
                if label < 0 && depth == 1 { lastStopIP = taken ? b.stopThen : b.stopElse }
            }
        }
    }

    // MARK: expressions

    @inline(__always)
    private static func s16(_ v: Int64) -> Int64 { let u = v & 0xFFFF; return u >= 0x8000 ? u - 0x10000 : u }

    func eval(_ x: RExpr) -> Int64 {
        switch x {
        case let .k(v): return v
        case let .memAt(w, a): return read(a, w)
        case let .mem(w, a): return read(Int(eval(a) & 0xFFFF), w)
        case let .cmem(w, a):
            let base = Int(eval(a) & 0xFFFF)
            var v: Int64 = 0
            for i in 0..<w { v |= Int64(code[(base + i) & 0xFFFF]) << (8 * i) }
            return v
        case let .reg(i):
            if !defined[i] { fault("read of undefined register \(program.registerNames[i]) in \(currentBlock >= 0 ? program.blocks[currentBlock].label : "?")") }
            return regs[i]
        case let .input(w): return Int64(host?.rulesInput(w) ?? 0)
        case .contactColour: return Int64(contactColour)
        case let .unknown(ip):
            fault(String(format: "read of a display-clobbered value (cs:%04x)", ip))
            return 0
        case let .ltu(a, b, w):
            let m: Int64 = w >= 8 ? -1 : (Int64(1) << (8 * Int64(w))) - 1
            return (eval(a) & m) < (eval(b) & m) ? 1 : 0
        case let .unary(op, a):
            let v = eval(a)
            switch op {
            case .neg: return (0 &- v) & 0xFFFF
            case .lo: return v & 0xFF
            case .hi: return (v >> 8) & 0xFF
            case .lo16: return v & 0xFFFF
            case .hi16: return (v >> 16) & 0xFFFF
            case .sext8: let b = v & 0xFF; return (b >= 0x80 ? b - 0x100 : b) & 0xFFFF
            }
        case let .binary(op, a, b):
            // setlo/sethi keep the other half of a register the lift may not know (a display call
            // clobbered it, e.g. EP2 L373a `mov al, [balls]` after a cut): not a fault.
            let x: Int64
            if op == .setlo || op == .sethi, case let .reg(i) = a, !defined[i] { x = regs[i] } else { x = eval(a) }
            let y = eval(b)
            switch op {
            case .add: return x &+ y
            case .sub: return x &- y
            case .mul: return x &* y
            case .and: return x & y
            case .or: return x | y
            case .xor: return x ^ y
            // x86 masks shift counts to 5 bits (rules.md 3.2; EP9 cs:2E07 shifts by a count >= 32)
            case .shl: return (x << (y & 31)) & 0xFFFF
            case .shr: return (x & 0xFFFF) >> (y & 31)
            case .sar: return (Self.s16(x) >> (y & 31)) & 0xFFFF
            case .setlo: return (x & 0xFF00) | (y & 0xFF)
            case .sethi: return (x & 0x00FF) | ((y & 0xFF) << 8)
            case .join: return ((x & 0xFFFF) << 16) | (y & 0xFFFF)
            case .mul32: return (x & 0xFFFF) * (y & 0xFFFF)
            case .div32:
                let d = y & 0xFFFF
                if d == 0 { fault("div32 by zero"); return 0 }
                return ((x & 0xFFFF_FFFF) / d) & 0xFFFF
            case .mod32:
                let d = y & 0xFFFF
                if d == 0 { fault("mod32 by zero"); return 0 }
                return (x & 0xFFFF_FFFF) % d
            case .div:
                let d = y & 0xFF
                if d == 0 { fault("div by zero"); return 0 }
                return ((x & 0xFFFF) / d) & 0xFF
            case .mod:
                let d = y & 0xFF
                if d == 0 { fault("mod by zero"); return 0 }
                return (x & 0xFFFF) % d
            }
        }
    }

    func cond(_ c: RCond) -> Bool {
        let bits = Int64(8 * c.w)
        let m: Int64 = c.w >= 8 ? -1 : (Int64(1) << bits) - 1
        let a = eval(c.a) & m, b = eval(c.b) & m
        let top: Int64 = c.w >= 8 ? Int64.min : Int64(1) << (bits - 1)
        let sa = c.w < 8 && a & top != 0 ? a - (Int64(1) << bits) : a
        let sb = c.w < 8 && b & top != 0 ? b - (Int64(1) << bits) : b
        switch c.cmp {
        case .eq: return a == b
        case .ne: return a != b
        case .ult: return UInt64(bitPattern: a) < UInt64(bitPattern: b)
        case .ule: return UInt64(bitPattern: a) <= UInt64(bitPattern: b)
        case .ugt: return UInt64(bitPattern: a) > UInt64(bitPattern: b)
        case .uge: return UInt64(bitPattern: a) >= UInt64(bitPattern: b)
        case .slt: return sa < sb
        case .sle: return sa <= sb
        case .sgt: return sa > sb
        case .sge: return sa >= sb
        }
    }

    // MARK: ops

    private func exec(_ o: ROp) {
        switch o {
        case let .reg(i, e, mask):
            let v = eval(e)
            regs[i] = mask ? v & 0xFFFF : v
            defined[i] = true
        case let .regUnknown(i):
            defined[i] = false
        case let .storeAt(s, e):
            write(s.addr, s.w, eval(e))
        case let .store(w, a, e):
            let addr = Int(eval(a) & 0xFFFF)
            write(addr, w, eval(e))
        case let .storeMany(list):
            let vals = list.map { eval($0.value) }
            for (w, v) in zip(list, vals) { write(w.slot.addr, w.slot.w, v) }
        case let .score(e):
            guard let s = program.engineVars["score"] else { fault("no score variable"); return }
            write(s.addr, 4, read(s.addr, 4) &+ eval(e))
        case let .lamp(slot, state):
            let a = (program.lampFirst + Int(eval(slot))) & 0xFFFF
            write8(a, UInt8(truncatingIfNeeded: eval(state)))
        case let .pixels(e, offs, outside):
            let v = UInt8(truncatingIfNeeded: eval(e))
            for o in offs { host?.rulesSetPixel(o, v) }
            if let outside { emit(.outsideWrite(offset: outside, value: v)) }
        case let .pixelAt(e, half, off):
            host?.rulesSetPixel(half * 64000 + Int(eval(off) & 0xFFFF), UInt8(truncatingIfNeeded: eval(e)))
        case let .native(target, ip):
            var r: [String: UInt16] = [:]
            for n in Self.machineRegisters {
                if let i = program.registerNames.firstIndex(of: n) { r[n] = UInt16(truncatingIfNeeded: regs[i]) }
            }
            if nativeCall?(target, ip, &r) == true {
                for (n, v) in r { if let i = program.registerNames.firstIndex(of: n) { regs[i] = Int64(v); defined[i] = true } }
            } else {
                fault(String(format: "call cs:%04X (from cs:%04X) not executed", target, ip))
            }
        case let .asm(ip):
            fault(String(format: "unlifted instruction at cs:%04X skipped", ip))
        case let .gate(i):
            drawGate(i)
        case let .message(m, pos, mode):
            emit(.message(ds: Int(eval(m) & 0xFFFF), mode: Int(eval(mode) & 0xFFFF), pos: Int(eval(pos) & 0xFFFF)))
        case let .text(m, pos, routine):
            emit(.text(ds: Int(eval(m) & 0xFFFF), pos: Int(eval(pos) & 0xFFFF), routine: routine))
        case let .numberText(v, buf):
            let value = UInt32(truncatingIfNeeded: eval(v))
            let b = Int(eval(buf) & 0xFFFF)
            writeNumber(value, buffer: b)
            emit(.number(value: value, buf: b))
        case .scoreRefresh:
            emit(.scoreRefresh)
        case let .display(what):
            emit(.display(what))
        case let .push(e):
            if case .reg(let i) = e, !defined[i] { stack.append(.value(nil)) } else { stack.append(.value(eval(e) & 0xFFFF)) }
        case let .pop(i):
            guard case let .value(v)? = stack.popLast() else { fault("pop from an empty stack"); return }
            regs[i] = v ?? 0
            defined[i] = v != nil
        case .pushAll:
            stack.append(.regs(regs, defined))
        case .popAll:
            guard case let .regs(r, d)? = stack.popLast() else { fault("pop_all without push_all"); return }
            regs = r
            defined = d
        case let .gosub(l), let .callHook(l):
            run(l)
        }
    }

    /// gate_draw (EP1 cs:4470): every gate pixel gets the value for its control byte.
    public func drawGate(_ i: Int) {
        guard program.gates.indices.contains(i) else { return }
        let g = program.gates[i]
        let v = read8(g.controlVar) == 0 ? g.valueIfZero : g.valueIfNonzero
        for o in g.offsets { host?.rulesSetPixel(o, v) }
    }

    public func drawAllGates() { for i in program.gates.indices { drawGate(i) } }

    /// num_to_text (EP1 cs:5BB3): dword -> decimal digits at buf+1 ... buf+10 (10^9 ... 10^0).
    /// Leading-zero positions are left untouched (callers pre-fill spaces), the ones digit is always
    /// written and buf+12 gets a 0 terminator (cs:5BEA..5C1C).
    public func writeNumber(_ value: UInt32, buffer b: Int) {
        var v = value
        var significant = false
        var p: UInt32 = 1_000_000_000
        for i in 0..<9 {
            let d = v / p
            v -= d * p
            if d != 0 || significant {
                significant = true
                write8(b + 1 + i, UInt8(0x30 + d))
            }
            p /= 10
        }
        write8(b + 10, UInt8(0x30 + v))
        write8(b + 12, 0)
    }
}
