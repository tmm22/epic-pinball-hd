import Foundation

// A small 16-bit x86 interpreter for the main-loop fragments of the original table code that
// rules.json does not lift (docs/formats/rules.md 4, item 1: the hooks are annotated by hand, EP1
// only, and a few short pieces between them are not hooks at all: the sound queue, the serve and
// plunger-release side effects, the tilt message, the end-of-ball player switch, dmd_idle_text).
//
// Rather than transcribing those pieces (and their constants) into Swift, the runtime executes the
// user's own EXE bytes for exactly those address ranges. All data accesses go through the
// `RulesMachine` memory bus, so engine-owned bytes (ball slots, serve delay, tilt, ...) stay bound to
// `ClassicEngine`. Calls are resolved by a callout (display stubs, sfx_play, gate_draw, lifted hooks);
// an unknown call, an unsupported instruction or a jump out of the range stops execution and is
// reported, never guessed.
//
// Supported: the usual integer subset with 16-bit ModRM addressing on DS (and ES when ES == DS),
// CS-relative byte/word data (the keyboard flags) through `csRead`/`csWrite`, a private stack for
// push/pop/pusha/popa and nested near calls that the callout asks to follow.

public final class MiniX86 {
    public enum Stop: Equatable, Sendable, CustomStringConvertible {
        /// Reached the end address of the range.
        case completed
        /// `ret` at call depth 0 (routine mode).
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
        /// Execute the callee's code (near calls only).
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
    var cf = false, zf = false, sf = false, of = false, pf = false
    /// A private stack segment (SS is not the data segment), addressed by SP like the real one, so
    /// `add sp, n` after a far call's arguments works.
    private var stackMem = [UInt16](repeating: 0, count: 0x8000)
    private var depth = 0
    static let initialSP: UInt16 = 0xFF00
    public var maxSteps = 2_000_000
    /// Routine mode (`end < 0`): also stop with `.completed` when ip reaches this address at depth 0
    /// (a sensor handler's `jmp` to the dispatcher exit).
    public var stopIP: Int?
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
    private var dsIsCS = false
    /// DS offsets of the variables holding the playfield segments (collision.json `top_seg_var`,
    /// `bottom_seg_var`) -> half (0 top, 1 bottom). `mov es, [var]` makes ES:[off] address the live
    /// collision buffer (half * 64000 + off) through the machine's host.
    public var playfieldSegmentVars: [Int: Int] = [:]
    /// Segment values the playfield-segment variables read as inside MiniX86 (top half, bottom half
    /// = top + 0xFA0 paragraphs), so segment arithmetic such as EP8 cs:42D7 `add di, 7D0h` works.
    static let playfieldSeg: UInt16 = 0x8000
    static let playfieldParas = 0x1F40
    /// ES -> linear collision-buffer offset of ES:0 (nil if ES is not a playfield segment).
    @inline(__always) func playfieldBase(_ seg: UInt16) -> Int? {
        let d = Int(seg) - Int(Self.playfieldSeg)
        return d >= 0 && d < Self.playfieldParas ? d * 16 : nil
    }

    public init(machine: RulesMachine) {
        self.machine = machine
        dsValue = UInt16(truncatingIfNeeded: machine.program.dataSegment)
        csValue = UInt16(truncatingIfNeeded: machine.program.codeSegment)
    }

    // MARK: registers

    public var ax: UInt16 { get { r[0] } set { r[0] = newValue } }
    public var cx: UInt16 { get { r[1] } set { r[1] = newValue } }
    public var dx: UInt16 { get { r[2] } set { r[2] = newValue } }
    public var bx: UInt16 { get { r[3] } set { r[3] = newValue } }
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
        dsIsCS = false
        depth = 0
    }

    // MARK: code fetch

    @inline(__always) private func cb(_ a: Int) -> Int { Int(machine.code[a & 0xFFFF]) }
    @inline(__always) private func cw(_ a: Int) -> Int { cb(a) | cb(a + 1) << 8 }

    // MARK: operand decoding

    private enum Seg { case ds, es, cs }
    private enum Loc { case reg(Int), mem(Int, Seg) }

    private struct ModRM {
        var mod: Int, reg: Int, rm: Int
        var loc: Loc
        var length: Int   // bytes after the opcode, including displacement
    }

    /// Decodes the ModRM at `p`; returns nil for addressing we do not model (bp-based = SS).
    private func modrm(_ p: Int, seg: Seg?) -> ModRM? {
        let b = cb(p)
        let mod = b >> 6, reg = (b >> 3) & 7, rm = b & 7
        if mod == 3 { return ModRM(mod: mod, reg: reg, rm: rm, loc: .reg(rm), length: 1) }
        var len = 1
        var base: Int
        switch rm {
        case 0: base = Int(r[3]) + Int(r[6])
        case 1: base = Int(r[3]) + Int(r[7])
        case 2, 3: return nil
        case 4: base = Int(r[6])
        case 5: base = Int(r[7])
        case 6:
            if mod == 0 { base = cw(p + 1); len += 2 } else { return nil }  // [bp+disp]
        default: base = Int(r[3])
        }
        if mod == 1 {
            let d = cb(p + 1); base += d >= 0x80 ? d - 0x100 : d; len += 1
        } else if mod == 2 {
            base += cw(p + 1); len += 2
        }
        return ModRM(mod: mod, reg: reg, rm: rm, loc: .mem(base & 0xFFFF, seg ?? .ds), length: len)
    }

    private var fault: Bool = false

    private func rd(_ l: Loc, _ w: Bool) -> Int {
        switch l {
        case let .reg(i): return w ? Int(r[i]) : Int(reg8(i))
        case let .mem(a, s):
            switch s {
            case .cs:
                let lo = Int(csRead?(a) ?? UInt8(cb(a)))
                if !w { return lo }
                return lo | Int(csRead?((a + 1) & 0xFFFF) ?? UInt8(cb(a + 1))) << 8
            case .es:
                if let pb = playfieldBase(es), let h = machine.host {
                    let base = pb + a
                    return Int(h.rulesPixel(base)) | (w ? Int(h.rulesPixel(base + 1)) << 8 : 0)
                }
                if es != dsValue { fault = true; return 0 }
                return Int(machine.read(a, w ? 2 : 1))
            case .ds:
                if dsIsCS { return w ? cw(a) : cb(a) }
                if let half = playfieldSegmentVars[a] {   // the playfield segment words (collision.json)
                    let v = Int(Self.playfieldSeg) + half * 0xFA0
                    return w ? v : v & 0xFF
                }
                return Int(machine.read(a, w ? 2 : 1))
            }
        }
    }

    private func wr(_ l: Loc, _ w: Bool, _ v: Int) {
        switch l {
        case let .reg(i): if w { r[i] = UInt16(truncatingIfNeeded: v) } else { setReg8(i, UInt8(truncatingIfNeeded: v)) }
        case let .mem(a, s):
            switch s {
            case .cs:
                csWrite?(a, UInt8(truncatingIfNeeded: v))
                if w { csWrite?((a + 1) & 0xFFFF, UInt8(truncatingIfNeeded: v >> 8)) }
            case .es:
                if let pb = playfieldBase(es), let h = machine.host {
                    let base = pb + a
                    h.rulesSetPixel(base, UInt8(truncatingIfNeeded: v))
                    if w { h.rulesSetPixel(base + 1, UInt8(truncatingIfNeeded: v >> 8)) }
                    return
                }
                if es != dsValue { fault = true; return }
                machine.write(a, w ? 2 : 1, Int64(v))
            case .ds:
                if dsIsCS { fault = true; return }
                machine.write(a, w ? 2 : 1, Int64(v))
            }
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
        case 3, 5, 7:
            let c = op == 3 && cf ? 1 : 0
            res = a - b - c
            cf = res < 0
            of = ((a ^ b) & (a ^ res) & top) != 0
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
        setSZP(res, w)
        return res
    }

    /// Shift group: 4 shl, 5 shr, 7 sar, 0 rol, 1 ror. Count already masked.
    private func shift(_ op: Int, _ v: Int, _ count: Int, _ w: Bool) -> Int? {
        let bits = w ? 16 : 8, m = w ? 0xFFFF : 0xFF
        if count == 0 { return v & m }
        var x = v & m
        switch op {
        case 4:
            for _ in 0..<count { cf = x & (1 << (bits - 1)) != 0; x = (x << 1) & m }
            of = (x & (1 << (bits - 1)) != 0) != cf
        case 5:
            of = x & (1 << (bits - 1)) != 0
            for _ in 0..<count { cf = x & 1 != 0; x >>= 1 }
        case 7:
            let sign = x & (1 << (bits - 1))
            for _ in 0..<count { cf = x & 1 != 0; x = (x >> 1) | sign }
            of = false
        case 0:
            for _ in 0..<count { let t = x >> (bits - 1); x = ((x << 1) | t) & m; cf = t != 0 }
            return x
        case 1:
            for _ in 0..<count { let t = x & 1; x = (x >> 1) | (t << (bits - 1)); cf = t != 0 }
            return x
        default:
            return nil
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

    private func push(_ v: UInt16) { r[4] &-= 2; stackMem[Int(r[4] >> 1)] = v }
    private func pop() -> UInt16 { let v = stackMem[Int(r[4] >> 1)]; r[4] &+= 2; return v }

    // MARK: run

    /// Executes from `start` until `end` is reached (`end < 0`: until `ret` at depth 0).
    /// Registers keep their current values (call `resetRegisters()` first for a clean frame).
    @discardableResult
    public func run(from start: Int, to end: Int) -> Stop {
        var ip = start & 0xFFFF
        var steps = 0
        // Re-entrant: a callout may run another fragment on this interpreter (e.g. a lifted hook that
        // shows the idle text); the caller's call depth and fault flag survive it.
        let savedDepth = depth, savedFault = fault
        defer { depth = savedDepth; fault = savedFault }
        depth = 0
        fault = false
        let lo = end >= 0 ? min(start, end) : 0, hi = end >= 0 ? max(start, end) : 0x10000
        func jump(_ t: Int) -> Stop? {
            let t = t & 0xFFFF
            if end >= 0 && depth == 0 {
                if t == end { ip = t; return .completed }
                if t < lo || t >= hi { return .jumpedOut(t) }
            }
            ip = t
            return nil
        }
        while true {
            if end >= 0 && ip == end && depth == 0 { return .completed }
            if end < 0, depth == 0, let s = stopIP, ip == s { return .completed }
            steps += 1
            if steps > maxSteps { return .stepLimit(ip) }
            let at = ip
            var p = ip
            var seg: Seg?
            var rep = false
            // prefixes
            while true {
                let b = cb(p)
                if b == 0x2E { seg = .cs; p += 1 } else if b == 0x26 { seg = .es; p += 1 }
                else if b == 0x3E { seg = .ds; p += 1 } else if b == 0xF3 { rep = true; p += 1 } else { break }
            }
            let op = cb(p)
            p += 1
            func bad() -> Stop { .unsupported(at, UInt8(op)) }
            switch op {
            // ALU r/m,r ; r,r/m ; al/ax,imm
            case 0x00...0x3D where op & 7 < 6 && ![0x26, 0x27, 0x2E, 0x2F, 0x36, 0x37, 0x3E, 0x3F].contains(op):
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
            case 0x50...0x57: push(r[op - 0x50])
            case 0x58...0x5F: r[op - 0x58] = pop()
            case 0x60:
                let sp = r[4]
                for i in 0..<8 { push(i == 4 ? sp : r[i]) }
            case 0x61:
                for i in stride(from: 7, through: 0, by: -1) { let v = pop(); if i != 4 { r[i] = v } }
            case 0x06: push(es)
            case 0x07: es = pop()
            case 0x1E: push(dsIsCS ? csValue : dsValue)
            case 0x1F:
                let v = pop()
                if v == dsValue { dsIsCS = false } else if v == csValue { dsIsCS = true } else { return bad() }
            case 0x70...0x7F:
                let d = cb(p); p += 1
                if cond(op - 0x70) {
                    if let s = jump(p + (d >= 0x80 ? d - 0x100 : d)) { return s }
                    continue
                }
            case 0x80, 0x81, 0x83:
                guard let m = modrm(p, seg: seg) else { return bad() }
                let w = op != 0x80
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
                case 3: wr(m.loc, true, Int(dsIsCS ? csValue : dsValue))
                default: return bad()
                }
                p += m.length
            case 0x8E:   // mov sreg, r/m (only es; ds must stay the data segment)
                guard let m = modrm(p, seg: seg) else { return bad() }
                var v = UInt16(truncatingIfNeeded: rd(m.loc, true))
                switch m.reg {
                case 0: es = v
                case 3:
                    if v == dsValue { dsIsCS = false } else if v == csValue { dsIsCS = true } else { return bad() }
                default: return bad()
                }
                p += m.length
            case 0x8D:
                guard let m = modrm(p, seg: nil), case let .mem(a, _) = m.loc else { return bad() }
                r[m.reg] = UInt16(a)
                p += m.length
            case 0x90, 0xFA, 0xFB, 0xFC: break
            case 0xEE, 0xEF: break                 // out dx, al/ax: VGA palette/registers (display only)
            case 0xE6, 0xE7: p += 1                // out imm8, al/ax
            case 0x98: r[0] = UInt16(bitPattern: Int16(Int8(bitPattern: reg8(0))))
            case 0x99: r[2] = r[0] & 0x8000 != 0 ? 0xFFFF : 0
            case 0xA0...0xA3:
                let a = cw(p); p += 2
                let w = op & 1 == 1
                let l = Loc.mem(a, seg ?? .ds)
                if op < 0xA2 { wr(.reg(0), w, rd(l, w)) } else { wr(l, w, rd(.reg(0), w)) }
            case 0xAA, 0xAB, 0xAC, 0xAD, 0xA4, 0xA5:
                let w = op & 1 == 1, n = w ? 2 : 1
                var count = rep ? Int(r[1]) : 1
                while count > 0 {
                    switch op {
                    case 0xAA, 0xAB: wr(.mem(Int(r[7]), .es), w, Int(r[0])); r[7] &+= UInt16(n)
                    case 0xAC, 0xAD: wr(.reg(0), w, rd(.mem(Int(r[6]), seg ?? .ds), w)); r[6] &+= UInt16(n)
                    default:
                        wr(.mem(Int(r[7]), .es), w, rd(.mem(Int(r[6]), seg ?? .ds), w))
                        r[6] &+= UInt16(n); r[7] &+= UInt16(n)
                    }
                    count -= 1
                }
                if rep { r[1] = 0 }
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
                guard let v = shift(m.reg, rd(m.loc, w), count, w) else { return bad() }
                wr(m.loc, w, v)
            case 0xC3:
                if depth == 0 { return .returned }
                depth -= 1
                ip = Int(pop())
                continue
            case 0xCB:
                if depth == 0 { return .returned }
                return bad()
            case 0xC6, 0xC7:
                guard let m = modrm(p, seg: seg), m.reg == 0 else { return bad() }
                let w = op == 0xC7
                p += m.length
                let imm = w ? cw(p) : cb(p)
                p += w ? 2 : 1
                wr(m.loc, w, imm)
            case 0xE2:
                let d = cb(p); p += 1
                r[1] &-= 1
                if r[1] != 0 {
                    if let s = jump(p + (d >= 0x80 ? d - 0x100 : d)) { return s }
                    continue
                }
            case 0xE8, 0x9A:
                let far = op == 0x9A
                let target = far ? cw(p) : (p + 2 + cw(p)) & 0xFFFF
                let next = p + (far ? 4 : 2)
                switch callout?(self, at, target, far ? cw(p + 2) : nil) ?? .unknown {
                case .handled:
                    ip = next
                    continue
                case .follow:
                    guard !far else { return .unknownCall(at, target) }
                    push(UInt16(next & 0xFFFF))
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
                case 0:
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
                default: return bad()
                }
            case 0xFF where (cb(p) >> 3) & 7 == 6:   // push r/m16
                guard let m = modrm(p, seg: seg) else { return bad() }
                push(UInt16(truncatingIfNeeded: rd(m.loc, true)))
                p += m.length
            case 0xFE, 0xFF:
                guard let m = modrm(p, seg: seg), m.reg <= 1 else { return bad() }
                let w = op == 0xFF
                let savedCF = cf
                wr(m.loc, w, incdec(rd(m.loc, w), w, dec: m.reg == 1))
                cf = savedCF
                p += m.length
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
        var p = ip0
        while [0x2E, 0x26, 0x3E, 0xF3].contains(cb(p)) { p += 1 }
        let op = cb(p)
        p += 1
        func mrm() -> Int? {
            let b = cb(p), mod = b >> 6, rm = b & 7
            if mod == 3 { return 1 }
            if mod == 0 { return rm == 6 ? 3 : ([2, 3].contains(rm) ? nil : 1) }
            if [2, 3].contains(rm) || (rm == 6) { return nil }
            return mod == 1 ? 2 : 3
        }
        switch op {
        case 0x00...0x3D where op & 7 < 6 && ![0x26, 0x27, 0x2E, 0x2F, 0x36, 0x37, 0x3E, 0x3F].contains(op):
            if op & 7 >= 4 { return p - ip0 + (op & 1 == 1 ? 2 : 1) }
            return mrm().map { p - ip0 + $0 }
        case 0x40...0x61, 0x06, 0x07, 0x1E, 0x1F, 0x90, 0x98, 0x99, 0xAA...0xAD, 0xA4, 0xA5, 0xC3, 0xCB, 0xFA, 0xFB, 0xFC:
            return p - ip0
        case 0xEE, 0xEF: return p - ip0
        case 0x70...0x7F, 0xEB, 0xE2, 0xA8, 0xB0...0xB7, 0xE6, 0xE7: return p - ip0 + 1
        case 0xA9, 0xB8...0xBF, 0xA0...0xA3, 0xE8, 0xE9: return p - ip0 + 2
        case 0x9A: return p - ip0 + 4
        case 0x80, 0x83, 0xC0, 0xC1, 0xC6: return mrm().map { p - ip0 + $0 + 1 }
        case 0x81, 0xC7: return mrm().map { p - ip0 + $0 + 2 }
        case 0x84...0x8E, 0xD0...0xD3, 0xFE, 0xFF: return mrm().map { p - ip0 + $0 }
        case 0xF6, 0xF7:
            guard let n = mrm() else { return nil }
            let reg = (cb(p) >> 3) & 7
            return p - ip0 + n + (reg == 0 ? (op == 0xF7 ? 2 : 1) : 0)
        default: return nil
        }
    }
}
