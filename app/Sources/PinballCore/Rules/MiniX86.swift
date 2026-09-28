import Foundation

// A 16-bit x86 (8086/80186) interpreter for the original table code, executed from the user's EXE:
//
// * the unlifted main-loop fragments of the lifted backend (TableGlue ranges: the sound queue, the
//   serve and plunger-release side effects, the tilt message, the end-of-ball player switch,
//   dmd_idle_text, ...), and rule-code `call`/`asm` ops;
// * every sensor handler, the dispatcher, the kicker routine and every main-loop / end-of-ball hook
//   of the direct-EXE backend (`RulesBackend.direct`, docs/enhanced/rules-direct.md).
//
// All data accesses go through the `RulesMachine` memory bus, so engine-owned bytes (ball slots,
// serve delay, tilt, ...) stay bound to `ClassicEngine`. Calls are resolved by a callout (display
// stubs, sfx_play, gate_draw, ...), which may also ask to execute the callee (near calls and far calls
// into the table's own code segment). An unknown call, an unsupported instruction or a jump out of the
// range stops execution and is reported, never guessed.
//
// Memory: DS is the table's data segment (or CS while `mov ds, cs` is in effect); ES may be DS, CS,
// a playfield half (the live collision buffer, through the DS words that hold the playfield segments)
// or the kicker's contact-pixel segment; SS is a private 64 KB stack (push/pop, BP-based operands).
// CS-relative data (the keyboard flags) goes through `csRead`/`csWrite`. Port reads return 0 except
// 3DAh (bit 3 toggles on every read, as in the emulator harness); port writes are ignored (VGA).

public final class MiniX86 {
    public enum Stop: Equatable, Sendable, CustomStringConvertible {
        /// Reached the end address of the range (or a hook stop, see `stops`).
        case completed
        /// `ret` at call depth 0 (routine mode), or the dispatcher epilogue (`stopAtEpilogue`).
        case returned
        /// A jump left the range (target cs offset).
        case jumpedOut(Int)
        /// An instruction outside the supported subset (cs offset, first opcode byte).
        case unsupported(Int, UInt8)
        /// A call the callout did not handle (cs offset of the call, target).
        case unknownCall(Int, Int)
        /// The callout asked to stop (e.g. game over).
        case halted(Int)
        case stepLimit(Int)

        public var description: String {
            switch self {
            case .completed: return "completed"
            case .returned: return "returned"
            case let .jumpedOut(t): return String(format: "jumped out to cs:%04X", t)
            case let .unsupported(ip, op): return String(format: "unsupported opcode %02X at cs:%04X", op, ip)
            case let .unknownCall(ip, t): return String(format: "unknown call at cs:%04X to %04X", ip, t)
            case let .halted(ip): return String(format: "halted at cs:%04X", ip)
            case let .stepLimit(ip): return String(format: "step limit at cs:%04X", ip)
            }
        }
    }

    /// What the callout decided for a call.
    public enum CallResult {
        /// Handled (the callee's effect was applied); continue after the call.
        case handled
        /// Execute the callee's code (near calls, and far calls into the table's code segment).
        case follow
        /// Not known: stop with `.unknownCall`.
        case unknown
        /// Stop execution (`.halted`).
        case halt
    }

    public let machine: RulesMachine
    /// ax cx dx bx sp bp si di
    public var r = [UInt16](repeating: 0, count: 8)
    public var es: UInt16 = 0
    var cf = false, zf = false, sf = false, of = false, pf = false, af = false, df = false
    /// The private stack segment (SS), byte addressed like the real one, so `add sp, n` after a far
    /// call's arguments and `[bp+n]` frames work.
    private var ss = [UInt8](repeating: 0, count: 0x10000)
    private var depth = 0
    private var runDepth = 0
    /// Open calls: return ip, SP before the call pushed its return address, far call.
    private var frames: [(ret: Int, sp: UInt16, far: Bool)] = []
    static let initialSP: UInt16 = 0xFF00
    public var maxSteps = 2_000_000
    /// Routine mode (`end < 0`): also stop with `.completed` when ip reaches this address at depth 0
    /// (a sensor handler's `jmp` to the dispatcher exit).
    public var stopIP: Int?
    /// Hook stops (rules.py `Lifter.stops`, direct backend): reaching one of these addresses (other
    /// than where the run started) ends the run at depth 0 (`lastStop`), and returns from the
    /// current subroutine at depth > 0, as the lifted graphs do.
    public var stops: [Bool]?
    /// Direct backend: the dispatcher epilogue (`popa; pop es; ret` and its variants) ends a run at
    /// depth 0 with `.returned` (the lifted graphs return there).
    public var stopAtEpilogue = false
    /// The stop address the last run ended at (nil if it ended otherwise).
    public private(set) var lastStop: Int?
    /// Set when an instruction inside `watch` executed during the last run.
    public var watch: Range<Int>?
    public private(set) var watchHit = false
    /// Subroutine returns forced by a hook stop (diagnostic).
    public private(set) var forcedReturns = 0
    /// Instructions executed (all runs; for performance measurements).
    public private(set) var executed = 0
    /// cs:[a] reads/writes (keyboard flags live in the code segment).
    public var csRead: ((Int) -> UInt8)?
    public var csWrite: ((Int, UInt8) -> Void)?
    /// (x86, call site ip, target offset, far segment or nil for near calls) -> result. Far calls
    /// into the table's own code segment use the same offsets as near calls.
    public var callout: ((MiniX86, Int, Int, Int?) -> CallResult)?
    /// Data segment value (`mov ax, ds` loads it; ES must equal it for ES accesses, or be a
    /// playfield segment, see `playfieldSegmentVars`).
    public let dsValue: UInt16
    /// Code segment value (`mov r, cs`); `mov ds, r` with it makes DS the code segment until DS is
    /// restored (EP9 cs:A48D reads a table through DS = CS).
    public let csValue: UInt16
    /// The current DS value: the data segment, the code segment, or another segment of the EXE's
    /// load image (read only, through `imageRead`; EP12 cs:5092 num_to_text reads its powers of ten
    /// with DS = 2445h).
    private var dsSeg: UInt16 = 0
    private var dsIsDS: Bool { dsSeg == dsValue }
    /// Byte at a linear offset of the EXE's load image (segment * 16 + offset, unrelocated), nil if
    /// outside it. Reads through DS/ES values that are neither the data segment, the code segment
    /// nor a playfield half use it; writes there stop execution.
    public var imageRead: ((Int) -> UInt8?)?
    /// DS offsets of the variables holding the playfield segments (collision.json `top_seg_var`,
    /// `bottom_seg_var`) -> half (0 top, 1 bottom). `mov es, [var]` makes ES:[off] address the live
    /// collision buffer (half * 64000 + off) through the machine's host.
    public var playfieldSegmentVars: [Int: Int] = [:]
    /// Segment values the playfield-segment variables read as inside MiniX86 (top half, bottom half
    /// = top + 0xFA0 paragraphs), so segment arithmetic such as EP8 cs:42D7 `add di, 7D0h` works.
    static let playfieldSeg: UInt16 = 0x8000
    static let playfieldParas = 0x1F40
    /// ES value under which every byte read is `contactColour`: the kicker routine reads the probed
    /// pixel as `es:[bx]` with the probe loop's ES (EP2 cs:1B79); the direct backend enters the
    /// kicker with this ES.
    public static let contactSegment: UInt16 = 0x7777
    public var contactColour: UInt8 = 0
    private var retraceBit = false
    /// ES -> linear collision-buffer offset of ES:0 (nil if ES is not a playfield segment).
    @inline(__always) func playfieldBase(_ seg: UInt16) -> Int? {
        let d = Int(seg) - Int(Self.playfieldSeg)
        return d >= 0 && d < Self.playfieldParas ? d * 16 : nil
    }

    public init(machine: RulesMachine) {
        self.machine = machine
        dsValue = UInt16(truncatingIfNeeded: machine.program.dataSegment)
        csValue = UInt16(truncatingIfNeeded: machine.program.codeSegment)
        dsSeg = dsValue
    }

    // MARK: registers

    public var ax: UInt16 { get { r[0] } set { r[0] = newValue } }
    public var cx: UInt16 { get { r[1] } set { r[1] = newValue } }
    public var dx: UInt16 { get { r[2] } set { r[2] = newValue } }
    public var bx: UInt16 { get { r[3] } set { r[3] = newValue } }
    public var sp: UInt16 { get { r[4] } set { r[4] = newValue } }
    public var si: UInt16 { get { r[6] } set { r[6] = newValue } }
    public var di: UInt16 { get { r[7] } set { r[7] = newValue } }

    func reg8(_ i: Int) -> UInt8 { i < 4 ? UInt8(r[i] & 0xFF) : UInt8(r[i - 4] >> 8) }
    func setReg8(_ i: Int, _ v: UInt8) {
        if i < 4 { r[i] = (r[i] & 0xFF00) | UInt16(v) } else { r[i - 4] = (r[i - 4] & 0x00FF) | UInt16(v) << 8 }
    }

    public func resetRegisters() {
        r = [UInt16](repeating: 0, count: 8)
        r[4] = Self.initialSP
        es = dsValue
        dsSeg = dsValue
        df = false
        depth = 0
        frames.removeAll(keepingCapacity: true)
    }

    // MARK: code fetch

    @inline(__always) private func cb(_ a: Int) -> Int { Int(machine.code[a & 0xFFFF]) }
    @inline(__always) private func cw(_ a: Int) -> Int { cb(a) | cb(a + 1) << 8 }

    // MARK: operand decoding

    private enum Seg { case ds, es, cs, ss }
    private enum Loc { case reg(Int), mem(Int, Seg) }

    private struct ModRM {
        var mod: Int, reg: Int, rm: Int
        var loc: Loc
        var length: Int   // bytes after the opcode, including displacement
    }

    /// Decodes the ModRM at `p` (BP-based operands address SS unless overridden).
    private func modrm(_ p: Int, seg: Seg?) -> ModRM? {
        let b = cb(p)
        let mod = b >> 6, reg = (b >> 3) & 7, rm = b & 7
        if mod == 3 { return ModRM(mod: mod, reg: reg, rm: rm, loc: .reg(rm), length: 1) }
        var len = 1
        var base: Int
        var defSeg = Seg.ds
        switch rm {
        case 0: base = Int(r[3]) + Int(r[6])
        case 1: base = Int(r[3]) + Int(r[7])
        case 2: base = Int(r[5]) + Int(r[6]); defSeg = .ss
        case 3: base = Int(r[5]) + Int(r[7]); defSeg = .ss
        case 4: base = Int(r[6])
        case 5: base = Int(r[7])
        case 6:
            if mod == 0 { base = cw(p + 1); len += 2 } else { base = Int(r[5]); defSeg = .ss }
        default: base = Int(r[3])
        }
        if mod == 1 {
            let d = cb(p + 1); base += d >= 0x80 ? d - 0x100 : d; len += 1
        } else if mod == 2 {
            base += cw(p + 1); len += 2
        }
        return ModRM(mod: mod, reg: reg, rm: rm, loc: .mem(base & 0xFFFF, seg ?? defSeg), length: len)
    }

    private var fault: Bool = false

    @inline(__always) private func rdByte(_ a: Int, _ s: Seg) -> Int {
        let a = a & 0xFFFF
        switch s {
        case .ss: return Int(ss[a])
        case .cs: return Int(csRead?(a) ?? UInt8(cb(a)))
        case .es:
            if es == Self.contactSegment { return Int(contactColour) }
            if let pb = playfieldBase(es), let h = machine.host { return Int(h.rulesPixel(pb + a)) }
            if es == dsValue { return Int(machine.read8(a)) }
            return imageByte(es, a)
        case .ds:
            if dsIsDS { return Int(machine.read8(a)) }
            return imageByte(dsSeg, a)
        }
    }

    /// A byte of segment `seg` other than DS: the code segment, or the EXE image (read only).
    private func imageByte(_ seg: UInt16, _ a: Int) -> Int {
        if seg == csValue { return Int(csRead?(a) ?? UInt8(cb(a))) }
        if let v = imageRead?(Int(seg) * 16 + a) { return Int(v) }
        fault = true
        return 0
    }

    private func rd(_ l: Loc, _ w: Bool) -> Int {
        switch l {
        case let .reg(i): return w ? Int(r[i]) : Int(reg8(i))
        case let .mem(a, s):
            if s == .ds && dsIsDS, let half = playfieldSegmentVars[a] {   // the playfield segment words (collision.json)
                let v = Int(Self.playfieldSeg) + half * 0xFA0
                return w ? v : v & 0xFF
            }
            if s == .ds && dsIsDS { return Int(machine.read(a, w ? 2 : 1)) }
            let lo = rdByte(a, s)
            return w ? lo | rdByte(a + 1, s) << 8 : lo
        }
    }

    @inline(__always) private func wrByte(_ a: Int, _ s: Seg, _ v: UInt8) {
        let a = a & 0xFFFF
        switch s {
        case .ss: ss[a] = v
        case .cs: csWrite?(a, v)
        case .es:
            if let pb = playfieldBase(es), let h = machine.host { h.rulesSetPixel(pb + a, v); return }
            if es != dsValue { fault = true; return }
            machine.write8(a, v)
        case .ds:
            if !dsIsDS { fault = true; return }
            machine.write8(a, v)
        }
    }

    private func wr(_ l: Loc, _ w: Bool, _ v: Int) {
        switch l {
        case let .reg(i): if w { r[i] = UInt16(truncatingIfNeeded: v) } else { setReg8(i, UInt8(truncatingIfNeeded: v)) }
        case let .mem(a, s):
            if s == .ds && dsIsDS { machine.write(a, w ? 2 : 1, Int64(v)); return }
            wrByte(a, s, UInt8(truncatingIfNeeded: v))
            if w { wrByte(a + 1, s, UInt8(truncatingIfNeeded: v >> 8)) }
        }
    }

    // MARK: flags / ALU

    private func setSZP(_ v: Int, _ w: Bool) {
        let m = w ? 0xFFFF : 0xFF
        let x = v & m
        zf = x == 0
        sf = x & (w ? 0x8000 : 0x80) != 0
        pf = (x & 0xFF).nonzeroBitCount % 2 == 0
    }

    /// op: 0 add 1 or 2 adc 3 sbb 4 and 5 sub 6 xor 7 cmp. Returns the result (to store unless cmp).
    private func alu(_ op: Int, _ a: Int, _ b: Int, _ w: Bool) -> Int {
        let m = w ? 0xFFFF : 0xFF, top = w ? 0x8000 : 0x80
        let a = a & m, b = b & m
        var res: Int
        switch op {
        case 0, 2:
            let c = op == 2 && cf ? 1 : 0
            res = a + b + c
            cf = res > m
            of = ((a ^ res) & (b ^ res) & top) != 0
            af = ((a ^ b ^ res) & 0x10) != 0
        case 3, 5, 7:
            let c = op == 3 && cf ? 1 : 0
            res = a - b - c
            cf = res < 0
            of = ((a ^ b) & (a ^ res) & top) != 0
            af = ((a ^ b ^ res) & 0x10) != 0
        case 1: res = a | b; cf = false; of = false
        case 4: res = a & b; cf = false; of = false
        default: res = a ^ b; cf = false; of = false
        }
        res &= m
        setSZP(res, w)
        return res
    }

    private func incdec(_ v: Int, _ w: Bool, dec: Bool) -> Int {
        let m = w ? 0xFFFF : 0xFF, top = w ? 0x8000 : 0x80
        let res = (dec ? v - 1 : v + 1) & m
        of = dec ? (v & m) == top : (v & m) == top - 1
        af = dec ? (v & 0xF) == 0 : (v & 0xF) == 0xF
        setSZP(res, w)
        return res
    }

    /// Shift group: 0 rol, 1 ror, 2 rcl, 3 rcr, 4 shl, 5 shr, 6 sal, 7 sar. Count already masked.
    private func shift(_ op: Int, _ v: Int, _ count: Int, _ w: Bool) -> Int {
        let bits = w ? 16 : 8, m = w ? 0xFFFF : 0xFF, top = 1 << (bits - 1)
        if count == 0 { return v & m }
        var x = v & m
        switch op {
        case 4, 6:
            for _ in 0..<count { cf = x & top != 0; x = (x << 1) & m }
            of = (x & top != 0) != cf
        case 5:
            of = x & top != 0
            for _ in 0..<count { cf = x & 1 != 0; x >>= 1 }
        case 7:
            let sign = x & top
            for _ in 0..<count { cf = x & 1 != 0; x = (x >> 1) | sign }
            of = false
        case 0:
            for _ in 0..<count { let t = x >> (bits - 1); x = ((x << 1) | t) & m; cf = t != 0 }
            of = (x & top != 0) != cf
            return x
        case 1:
            for _ in 0..<count { let t = x & 1; x = (x >> 1) | (t << (bits - 1)); cf = t != 0 }
            of = ((x ^ (x << 1)) & top) != 0
            return x
        case 2:
            for _ in 0..<count { let t = x & top != 0; x = ((x << 1) | (cf ? 1 : 0)) & m; cf = t }
            of = (x & top != 0) != cf
            return x
        default:   // rcr
            of = (x & top != 0) != cf
            for _ in 0..<count { let t = x & 1 != 0; x = (x >> 1) | (cf ? top : 0); cf = t }
            return x
        }
        setSZP(x, w)
        return x
    }

    private func cond(_ c: Int) -> Bool {
        switch c {
        case 0: return of
        case 1: return !of
        case 2: return cf
        case 3: return !cf
        case 4: return zf
        case 5: return !zf
        case 6: return cf || zf
        case 7: return !cf && !zf
        case 8: return sf
        case 9: return !sf
        case 10: return pf
        case 11: return !pf
        case 12: return sf != of
        case 13: return sf == of
        case 14: return zf || sf != of
        default: return !zf && sf == of
        }
    }

    private var flagsWord: UInt16 {
        get {
            var f: UInt16 = 0x0002
            if cf { f |= 0x0001 }; if pf { f |= 0x0004 }; if af { f |= 0x0010 }; if zf { f |= 0x0040 }
            if sf { f |= 0x0080 }; if df { f |= 0x0400 }; if of { f |= 0x0800 }
            return f | 0x0200
        }
        set {
            cf = newValue & 0x0001 != 0; pf = newValue & 0x0004 != 0; af = newValue & 0x0010 != 0; zf = newValue & 0x0040 != 0
            sf = newValue & 0x0080 != 0; df = newValue & 0x0400 != 0; of = newValue & 0x0800 != 0
        }
    }

    private func push(_ v: UInt16) {
        r[4] &-= 2
        let a = Int(r[4])
        ss[a] = UInt8(v & 0xFF); ss[(a + 1) & 0xFFFF] = UInt8(v >> 8)
    }
    private func pop() -> UInt16 {
        let a = Int(r[4])
        let v = UInt16(ss[a]) | UInt16(ss[(a + 1) & 0xFFFF]) << 8
        r[4] &+= 2
        return v
    }

    static func isEpilogue(_ c: [UInt8], _ a: Int) -> Bool {
        let b0 = c[a & 0xFFFF], b1 = c[(a + 1) & 0xFFFF], b2 = c[(a + 2) & 0xFFFF]
        return (b0 == 0x61 && b1 == 0x07 && b2 == 0xC3) || (b0 == 0x07 && b1 == 0x61 && b2 == 0xC3) || (b0 == 0x61 && b1 == 0xC3)
    }

    // MARK: run

    /// Executes from `start` until `end` is reached (`end < 0`: until `ret` at depth 0).
    /// Registers keep their current values (call `resetRegisters()` first for a clean frame).
    @discardableResult
    public func run(from start: Int, to end: Int) -> Stop {
        var ip = start & 0xFFFF
        var steps = 0
        // Re-entrant: a callout may run another fragment on this interpreter (e.g. a lifted hook that
        // shows the idle text); the caller's call state and fault flag survive it.
        let savedDepth = depth, savedFault = fault, savedFrames = frames
        let nested = runDepth > 0, outerStop = lastStop, outerWatch = watchHit
        runDepth += 1
        defer {
            depth = savedDepth; fault = savedFault; frames = savedFrames; executed &+= steps; runDepth -= 1
            if nested { lastStop = outerStop; watchHit = outerWatch }
        }
        depth = 0
        frames.removeAll(keepingCapacity: true)
        fault = false
        lastStop = nil
        watchHit = false
        let lo = end >= 0 ? min(start, end) : 0, hi = end >= 0 ? max(start, end) : 0x10000
        let stopSet = stops
        let code = machine.code
        func jump(_ t: Int) -> Stop? {
            let t = t & 0xFFFF
            if end >= 0 && depth == 0 {
                if t == end { ip = t; return .completed }
                if t < lo || t >= hi { return .jumpedOut(t) }
            }
            ip = t
            return nil
        }
        /// `ret`/`retf` from a followed call (x86 semantics: the return address comes off the stack).
        func returnFromCall(far: Bool, extra: Int) {
            ip = Int(pop())
            if far { _ = pop() }
            r[4] &+= UInt16(truncatingIfNeeded: extra)
            depth -= 1
            if !frames.isEmpty { frames.removeLast() }
        }
        while true {
            if end >= 0 && ip == end && depth == 0 { return .completed }
            if depth == 0 {
                if end < 0, let s = stopIP, ip == s { return .completed }
                if let st = stopSet, st[ip], steps > 0 { lastStop = ip; return .completed }
                if stopAtEpilogue, Self.isEpilogue(code, ip) { return .returned }
            } else if let st = stopSet, st[ip], let f = frames.last {
                // a hook stop inside a subroutine: return from it (the lifted gosub returns there)
                ip = f.ret; r[4] = f.sp; depth -= 1; frames.removeLast(); forcedReturns += 1
                continue
            }
            steps += 1
            if steps > maxSteps { return .stepLimit(ip) }
            if let w = watch, w.contains(ip) { watchHit = true }
            let at = ip
            var p = ip
            var seg: Seg?
            var rep = 0   // 0 none, 1 rep/repe, 2 repne
            // prefixes
            prefixes: while true {
                switch cb(p) {
                case 0x2E: seg = .cs
                case 0x26: seg = .es
                case 0x3E: seg = .ds
                case 0x36: seg = .ss
                case 0xF3: rep = 1
                case 0xF2: rep = 2
                case 0xF0: break
                default: break prefixes
                }
                p += 1
            }
            let op = cb(p)
            p += 1
            func bad() -> Stop { .unsupported(at, UInt8(op)) }
            switch op {
            // ALU r/m,r ; r,r/m ; al/ax,imm
            case 0x00...0x3D where op & 7 < 6:
                let aop = op >> 3, form = op & 7, w = op & 1 == 1
                if form >= 4 {
                    let imm = w ? cw(p) : cb(p)
                    let res = alu(aop, rd(.reg(0), w), imm, w)
                    if aop != 7 { wr(.reg(0), w, res) }
                    p += w ? 2 : 1
                } else {
                    guard let m = modrm(p, seg: seg) else { return bad() }
                    let regLoc = Loc.reg(m.reg)
                    if form < 2 {   // r/m, r
                        let res = alu(aop, rd(m.loc, w), rd(regLoc, w), w)
                        if aop != 7 { wr(m.loc, w, res) }
                    } else {        // r, r/m
                        let res = alu(aop, rd(regLoc, w), rd(m.loc, w), w)
                        if aop != 7 { wr(regLoc, w, res) }
                    }
                    p += m.length
                }
            case 0x40...0x4F:
                let i = op & 7, savedCF = cf
                r[i] = UInt16(incdec(Int(r[i]), true, dec: op >= 0x48))
                cf = savedCF
            case 0x50...0x57:
                push(op == 0x54 ? r[4] : r[op - 0x50])
            case 0x58...0x5F: let v = pop(); r[op - 0x58] = v
            case 0x60:
                let spv = r[4]
                for i in 0..<8 { push(i == 4 ? spv : r[i]) }
            case 0x61:
                for i in stride(from: 7, through: 0, by: -1) { let v = pop(); if i != 4 { r[i] = v } }
            case 0x68: push(UInt16(cw(p))); p += 2
            case 0x6A: let v = cb(p); p += 1; push(UInt16(truncatingIfNeeded: v >= 0x80 ? v - 0x100 : v))
            case 0x69, 0x6B:
                guard let m = modrm(p, seg: seg) else { return bad() }
                p += m.length
                var imm: Int
                if op == 0x69 { imm = cw(p); p += 2; if imm >= 0x8000 { imm -= 0x10000 } } else { imm = cb(p); p += 1; if imm >= 0x80 { imm -= 0x100 } }
                let a = Int(Int16(bitPattern: UInt16(rd(m.loc, true))))
                let prod = a * imm
                r[m.reg] = UInt16(truncatingIfNeeded: prod)
                cf = prod != Int(Int16(truncatingIfNeeded: prod)); of = cf
            case 0x06: push(es)
            case 0x07: es = pop()
            case 0x0E: push(csValue)
            case 0x16: push(0)            // SS (private)
            case 0x1E: push(dsSeg)
            case 0x1F: dsSeg = pop()
            case 0x70...0x7F:
                let d = cb(p); p += 1
                if cond(op - 0x70) {
                    if let s = jump(p + (d >= 0x80 ? d - 0x100 : d)) { return s }
                    continue
                }
            case 0x80...0x83:
                guard let m = modrm(p, seg: seg) else { return bad() }
                let w = op & 1 == 1
                p += m.length
                var imm: Int
                if op == 0x81 { imm = cw(p); p += 2 } else { imm = cb(p); p += 1; if op == 0x83 && imm >= 0x80 { imm |= 0xFF00 } }
                let res = alu(m.reg, rd(m.loc, w), imm, w)
                if m.reg != 7 { wr(m.loc, w, res) }
            case 0x84, 0x85:
                guard let m = modrm(p, seg: seg) else { return bad() }
                let w = op == 0x85
                _ = alu(4, rd(m.loc, w), rd(.reg(m.reg), w), w)
                p += m.length
            case 0xA8: _ = alu(4, Int(reg8(0)), cb(p), false); p += 1
            case 0xA9: _ = alu(4, Int(r[0]), cw(p), true); p += 2
            case 0x86, 0x87:
                guard let m = modrm(p, seg: seg) else { return bad() }
                let w = op == 0x87
                let a = rd(m.loc, w), b = rd(.reg(m.reg), w)
                wr(m.loc, w, b); wr(.reg(m.reg), w, a)
                p += m.length
            case 0x88...0x8B:
                guard let m = modrm(p, seg: seg) else { return bad() }
                let w = op & 1 == 1
                if op < 0x8A { wr(m.loc, w, rd(.reg(m.reg), w)) } else { wr(.reg(m.reg), w, rd(m.loc, w)) }
                p += m.length
            case 0x8C:   // mov r/m, sreg
                guard let m = modrm(p, seg: seg) else { return bad() }
                switch m.reg {
                case 0: wr(m.loc, true, Int(es))
                case 1: wr(m.loc, true, Int(csValue))
                case 2: wr(m.loc, true, 0)
                case 3: wr(m.loc, true, Int(dsSeg))
                default: return bad()
                }
                p += m.length
            case 0x8E:   // mov sreg, r/m (es; ds only to the data or code segment)
                guard let m = modrm(p, seg: seg) else { return bad() }
                let v = UInt16(truncatingIfNeeded: rd(m.loc, true))
                switch m.reg {
                case 0: es = v
                case 3: dsSeg = v
                default: return bad()
                }
                p += m.length
            case 0x8D:
                guard let m = modrm(p, seg: nil), case let .mem(a, _) = m.loc else { return bad() }
                r[m.reg] = UInt16(a)
                p += m.length
            case 0x8F:
                guard let m = modrm(p, seg: seg), m.reg == 0 else { return bad() }
                let v = pop()
                wr(m.loc, true, Int(v))
                p += m.length
            case 0x90, 0xFA, 0xFB, 0x9B: break
            case 0xFC: df = false
            case 0xFD: df = true
            case 0xF5: cf.toggle()
            case 0xF8: cf = false
            case 0xF9: cf = true
            case 0x91...0x97: let t = r[0]; r[0] = r[op - 0x90]; r[op - 0x90] = t
            case 0x9C: push(flagsWord)
            case 0x9D: flagsWord = pop()
            case 0x9E: let a = UInt16(reg8(4)); flagsWord = (flagsWord & 0xFF00) | a
            case 0x9F: setReg8(4, UInt8(flagsWord & 0xFF))
            case 0xEE, 0xEF: break                 // out dx, al/ax: VGA palette/registers (display only)
            case 0xE6, 0xE7: p += 1                // out imm8, al/ax
            case 0xEC, 0xED, 0xE4, 0xE5:           // in: 3DAh toggles bit 3 (retrace), else 0
                let port = op >= 0xEC ? Int(r[2]) : cb(p)
                if op < 0xEC { p += 1 }
                var v = 0
                if port == 0x3DA { retraceBit.toggle(); v = retraceBit ? 0x08 : 0 }
                if op & 1 == 1 { r[0] = UInt16(v) } else { setReg8(0, UInt8(v)) }
            case 0x98: r[0] = UInt16(bitPattern: Int16(Int8(bitPattern: reg8(0))))
            case 0x99: r[2] = r[0] & 0x8000 != 0 ? 0xFFFF : 0
            case 0xA0...0xA3:
                let a = cw(p); p += 2
                let w = op & 1 == 1
                let l = Loc.mem(a, seg ?? .ds)
                if op < 0xA2 { wr(.reg(0), w, rd(l, w)) } else { wr(l, w, rd(.reg(0), w)) }
            case 0xA4...0xA7, 0xAA...0xAF:
                let w = op & 1 == 1, n = UInt16(w ? 2 : 1)
                let step: (UInt16) -> UInt16 = { [df] v in df ? v &- n : v &+ n }
                let src = seg ?? .ds
                var count = rep != 0 ? Int(r[1]) : 1
                while count > 0 {
                    var stopCmp = false
                    switch op {
                    case 0xAA, 0xAB: wr(.mem(Int(r[7]), .es), w, Int(r[0])); r[7] = step(r[7])
                    case 0xAC, 0xAD: wr(.reg(0), w, rd(.mem(Int(r[6]), src), w)); r[6] = step(r[6])
                    case 0xA4, 0xA5:
                        wr(.mem(Int(r[7]), .es), w, rd(.mem(Int(r[6]), src), w))
                        r[6] = step(r[6]); r[7] = step(r[7])
                    case 0xA6, 0xA7:
                        _ = alu(7, rd(.mem(Int(r[6]), src), w), rd(.mem(Int(r[7]), .es), w), w)
                        r[6] = step(r[6]); r[7] = step(r[7])
                        stopCmp = true
                    default:   // scas
                        _ = alu(7, rd(.reg(0), w), rd(.mem(Int(r[7]), .es), w), w)
                        r[7] = step(r[7])
                        stopCmp = true
                    }
                    count -= 1
                    if rep != 0 { r[1] &-= 1 }
                    if fault { return bad() }
                    if stopCmp && rep != 0 && ((rep == 1 && !zf) || (rep == 2 && zf)) { break }
                }
                if fault { return bad() }
            case 0xB0...0xB7: setReg8(op - 0xB0, UInt8(cb(p))); p += 1
            case 0xB8...0xBF: r[op - 0xB8] = UInt16(cw(p)); p += 2
            case 0xC0, 0xC1, 0xD0, 0xD1, 0xD2, 0xD3:
                guard let m = modrm(p, seg: seg) else { return bad() }
                let w = op & 1 == 1
                p += m.length
                var count: Int
                if op <= 0xC1 { count = cb(p); p += 1 } else if op <= 0xD1 { count = 1 } else { count = Int(r[1] & 0xFF) }
                count &= 0x1F
                wr(m.loc, w, shift(m.reg, rd(m.loc, w), count, w))
            case 0xC2, 0xC3:
                let extra = op == 0xC2 ? cw(p) : 0
                if depth == 0 { return .returned }
                returnFromCall(far: false, extra: extra)
                continue
            case 0xCA, 0xCB:
                let extra = op == 0xCA ? cw(p) : 0
                if depth == 0 { return .returned }
                returnFromCall(far: true, extra: extra)
                continue
            case 0xC4, 0xC5:
                guard let m = modrm(p, seg: seg), case .mem = m.loc else { return bad() }
                guard case let .mem(a, s) = m.loc else { return bad() }
                let off = rd(.mem(a, s), true), sv = UInt16(truncatingIfNeeded: rd(.mem(a + 2, s), true))
                r[m.reg] = UInt16(truncatingIfNeeded: off)
                if op == 0xC4 { es = sv } else { dsSeg = sv }
                p += m.length
            case 0xC6, 0xC7:
                guard let m = modrm(p, seg: seg), m.reg == 0 else { return bad() }
                let w = op == 0xC7
                p += m.length
                let imm = w ? cw(p) : cb(p)
                p += w ? 2 : 1
                wr(m.loc, w, imm)
            case 0xC8:
                let size = cw(p), level = cb(p + 2) & 0x1F
                p += 3
                push(r[5])
                let frame = r[4]
                if level > 0 {
                    for _ in 1..<max(1, level) { r[5] &-= 2; push(UInt16(ss[Int(r[5])]) | UInt16(ss[Int(r[5] &+ 1)]) << 8) }
                    push(frame)
                }
                r[5] = frame
                r[4] &-= UInt16(truncatingIfNeeded: size)
            case 0xC9: r[4] = r[5]; r[5] = pop()
            case 0xD7:
                let a = (Int(r[3]) + Int(reg8(0))) & 0xFFFF
                setReg8(0, UInt8(truncatingIfNeeded: rd(.mem(a, seg ?? .ds), false)))
            case 0xE0, 0xE1, 0xE2:
                let d = cb(p); p += 1
                r[1] &-= 1
                let take = r[1] != 0 && (op == 0xE2 || (op == 0xE1 ? zf : !zf))
                if take {
                    if let s = jump(p + (d >= 0x80 ? d - 0x100 : d)) { return s }
                    continue
                }
            case 0xE3:
                let d = cb(p); p += 1
                if r[1] == 0 {
                    if let s = jump(p + (d >= 0x80 ? d - 0x100 : d)) { return s }
                    continue
                }
            case 0xE8, 0x9A:
                let far = op == 0x9A
                let target = far ? cw(p) : (p + 2 + cw(p)) & 0xFFFF
                let farSeg: Int? = far ? cw(p + 2) : nil
                let next = (p + (far ? 4 : 2)) & 0xFFFF
                switch callout?(self, at, target, farSeg) ?? .unknown {
                case .handled:
                    ip = next
                    continue
                case .follow:
                    if far {
                        guard farSeg == Int(csValue) else { return .unknownCall(at, target) }
                        let spBefore = r[4]
                        push(csValue); push(UInt16(next))
                        frames.append((next, spBefore, true))
                    } else {
                        let spBefore = r[4]
                        push(UInt16(next))
                        frames.append((next, spBefore, false))
                    }
                    depth += 1
                    ip = target
                    continue
                case .unknown: return .unknownCall(at, target)
                case .halt: return .halted(at)
                }
            case 0xE9:
                let t = p + 2 + cw(p)
                if let s = jump(t) { return s }
                continue
            case 0xEB:
                let d = cb(p)
                if let s = jump(p + 1 + (d >= 0x80 ? d - 0x100 : d)) { return s }
                continue
            case 0xF6, 0xF7:
                guard let m = modrm(p, seg: seg) else { return bad() }
                let w = op == 0xF7
                p += m.length
                let v = rd(m.loc, w)
                switch m.reg {
                case 0, 1:
                    let imm = w ? cw(p) : cb(p); p += w ? 2 : 1
                    _ = alu(4, v, imm, w)
                case 2: wr(m.loc, w, ~v)
                case 3:
                    let res = alu(5, 0, v, w)
                    cf = (v & (w ? 0xFFFF : 0xFF)) != 0
                    wr(m.loc, w, res)
                case 4:
                    if w {
                        let prod = Int(r[0]) * v
                        r[0] = UInt16(prod & 0xFFFF); r[2] = UInt16((prod >> 16) & 0xFFFF)
                        cf = r[2] != 0; of = cf
                    } else {
                        let prod = Int(reg8(0)) * v
                        r[0] = UInt16(prod & 0xFFFF)
                        cf = r[0] >> 8 != 0; of = cf
                    }
                case 5:
                    if w {
                        let prod = Int(Int16(bitPattern: r[0])) * Int(Int16(truncatingIfNeeded: v))
                        r[0] = UInt16(truncatingIfNeeded: prod); r[2] = UInt16(truncatingIfNeeded: prod >> 16)
                        cf = prod != Int(Int16(truncatingIfNeeded: prod)); of = cf
                    } else {
                        let prod = Int(Int8(bitPattern: reg8(0))) * Int(Int8(truncatingIfNeeded: v))
                        r[0] = UInt16(truncatingIfNeeded: prod)
                        cf = prod != Int(Int8(truncatingIfNeeded: prod)); of = cf
                    }
                case 6:
                    guard v != 0 else { return bad() }
                    if w {
                        let n = Int(r[2]) << 16 | Int(r[0])
                        let q = n / v
                        guard q <= 0xFFFF else { return bad() }
                        r[0] = UInt16(q); r[2] = UInt16(n % v)
                    } else {
                        let n = Int(r[0])
                        let q = n / v
                        guard q <= 0xFF else { return bad() }
                        r[0] = UInt16(n % v) << 8 | UInt16(q)
                    }
                default:
                    let dv = w ? Int(Int16(truncatingIfNeeded: v)) : Int(Int8(truncatingIfNeeded: v))
                    guard dv != 0 else { return bad() }
                    if w {
                        let n = Int(Int32(bitPattern: UInt32(r[2]) << 16 | UInt32(r[0])))
                        let q = n / dv, rem = n % dv
                        guard q >= -0x8000 && q <= 0x7FFF else { return bad() }
                        r[0] = UInt16(truncatingIfNeeded: q); r[2] = UInt16(truncatingIfNeeded: rem)
                    } else {
                        let n = Int(Int16(bitPattern: r[0]))
                        let q = n / dv, rem = n % dv
                        guard q >= -0x80 && q <= 0x7F else { return bad() }
                        r[0] = UInt16(UInt8(truncatingIfNeeded: rem)) << 8 | UInt16(UInt8(truncatingIfNeeded: q))
                    }
                }
            case 0xFE, 0xFF:
                guard let m = modrm(p, seg: seg) else { return bad() }
                let w = op == 0xFF
                switch m.reg {
                case 0, 1:
                    let savedCF = cf
                    wr(m.loc, w, incdec(rd(m.loc, w), w, dec: m.reg == 1))
                    cf = savedCF
                    p += m.length
                case 2 where w:   // call r/m16
                    let target = rd(m.loc, true)
                    let next = (p + m.length) & 0xFFFF
                    switch callout?(self, at, target, nil) ?? .unknown {
                    case .handled: ip = next; continue
                    case .follow:
                        let spBefore = r[4]
                        push(UInt16(next)); frames.append((next, spBefore, false)); depth += 1; ip = target; continue
                    case .unknown: return .unknownCall(at, target)
                    case .halt: return .halted(at)
                    }
                case 4 where w:   // jmp r/m16 (the dispatcher's `jmp bx`)
                    let t = rd(m.loc, true)
                    if let s = jump(t) { return s }
                    continue
                case 6 where w:
                    push(UInt16(truncatingIfNeeded: rd(m.loc, true)))
                    p += m.length
                default: return bad()
                }
            default:
                return bad()
            }
            if fault { return bad() }
            ip = p & 0xFFFF
        }
    }

    /// Decodes (without executing) and reports the first instruction outside the subset, if any.
    /// Only straight-line lengths are checked; used to validate glue ranges at load time.
    public func validate(from start: Int, to end: Int) -> Stop {
        var ip = start
        while ip < end {
            guard let n = length(at: ip) else { return .unsupported(ip, UInt8(cb(ip))) }
            ip += n
        }
        return ip == end ? .completed : .unsupported(ip, UInt8(cb(ip)))
    }

    /// Instruction length for the supported subset (nil if unsupported).
    public func length(at ip0: Int) -> Int? {
        guard let i = X86Decoder.decode(machine.code, ip0), Self.supports(i) else { return nil }
        return i.length
    }

    /// Whether `run` executes this instruction (the decoder's view of the subset above).
    public static func supports(_ i: X86Insn) -> Bool {
        let m = i.mn.hasPrefix("rep ") ? String(i.mn.dropFirst(4)) : (i.mn.hasPrefix("repne ") ? String(i.mn.dropFirst(6)) : i.mn)
        switch m {
        case "int", "int3", "into", "iret", "hlt", "ljmp", "insb", "insw", "outsb", "outsw", "bound", "daa", "das", "aaa", "aas",
             "aam", "aad", "salc", "fpu":
            return false
        case "pop":
            if case .sreg(let s)? = i.ops.first { return s != 2 }   // pop ss
            return true
        case "push":
            return true
        case "mov":
            if case .sreg(let s)? = i.ops.first { return s == 0 || s == 3 }
            return true
        case "lcall":
            return i.farTarget != nil     // direct far calls (indirect far calls: no)
        case "call", "jmp":
            if case .mem(let mm)? = i.ops.first { return mm.size == 2 }
            return true
        default:
            return true
        }
    }
}
