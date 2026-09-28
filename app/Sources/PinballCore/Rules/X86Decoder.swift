import Foundation

// A 16-bit (8086/80186) instruction decoder for the static analyses that find a table's rule code in
// the user's EXE at run time (`TableDiscovery`, `HookDiscovery`): the Swift counterpart of the
// capstone-based passes in tools/rules.py and tools/emu/discover.py. It only decodes; `MiniX86`
// executes. Mnemonics follow capstone's names (`lcall`, `ljmp`, `rep movsb`, `jae`, ...) so the
// ported passes read like the Python they come from.

public struct X86Mem: Equatable, Sendable {
    /// Segment override (0 es, 1 cs, 2 ss, 3 ds) or nil.
    public var seg: Int?
    /// ModRM r/m code (0 bx+si, 1 bx+di, 2 bp+si, 3 bp+di, 4 si, 5 di, 6 bp, 7 bx); nil = direct address.
    public var rm: Int?
    /// Displacement (the 16-bit address for a direct operand; sign-extended for disp8).
    public var disp: Int
    /// Operand width in bytes (1, 2 or 4 for far pointers).
    public var size: Int

    /// The displacement as a DS offset.
    public var offset: Int { disp & 0xFFFF }
    /// A direct `[disp16]` operand.
    public var isDirect: Bool { rm == nil }
    /// Uses BP as a base register (SS-relative unless overridden).
    public var usesBP: Bool { rm.map { [2, 3, 6].contains($0) } ?? false }
    /// Data segment (no override or DS, and not BP-based).
    public var isDS: Bool { seg == 3 || (seg == nil && !usesBP) }
    /// Capstone's view: segment register absent (0) or DS; BP-based operands without override count.
    public var capstoneDS: Bool { seg == nil || seg == 3 }
    /// Base register names (capstone's base/index).
    public var registers: [String] {
        switch rm {
        case nil: return []
        case 0?: return ["bx", "si"]
        case 1?: return ["bx", "di"]
        case 2?: return ["bp", "si"]
        case 3?: return ["bp", "di"]
        case 4?: return ["si"]
        case 5?: return ["di"]
        case 6?: return ["bp"]
        default: return ["bx"]
        }
    }
}

public enum X86Operand: Equatable, Sendable {
    /// General register: index (ax cx dx bx sp bp si di / al cl dl bl ah ch dh bh), width 1 or 2.
    case reg(Int, Int)
    /// Segment register (0 es, 1 cs, 2 ss, 3 ds).
    case sreg(Int)
    case mem(X86Mem)
    /// Immediate (as capstone reports it: 83-form immediates are sign-extended) and its width.
    case imm(Int, Int)
    /// Direct far pointer (seg, off).
    case far(Int, Int)

    public var memValue: X86Mem? { if case let .mem(m) = self { return m }; return nil }
    public var immValue: Int? { if case let .imm(v, _) = self { return v }; return nil }
    public var size: Int {
        switch self {
        case let .reg(_, w): return w
        case .sreg: return 2
        case let .mem(m): return m.size
        case let .imm(_, w): return w
        case .far: return 4
        }
    }
    static let r16 = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di"]
    static let r8 = ["al", "cl", "dl", "bl", "ah", "ch", "dh", "bh"]
    static let sregs = ["es", "cs", "ss", "ds"]
    /// Register name (capstone spelling), nil for non-registers.
    public var regName: String? {
        switch self {
        case let .reg(i, w): return w == 1 ? Self.r8[i] : Self.r16[i]
        case let .sreg(i): return Self.sregs[i]
        default: return nil
        }
    }
}

public struct X86Insn: Sendable {
    public var ip: Int
    public var length: Int
    /// Primary opcode byte (after prefixes).
    public var opcode: UInt8
    /// capstone-style mnemonic ("mov", "jne", "lcall", "rep movsb", ...).
    public var mn: String
    public var ops: [X86Operand]
    /// Segment override prefix (0 es, 1 cs, 2 ss, 3 ds).
    public var seg: Int?

    public var next: Int { (ip + length) & 0xFFFF }
    /// Near branch / call target (jcc, jmp, call, loop*, jcxz with an immediate operand).
    public var target: Int? {
        if ops.count == 1, case let .imm(v, _) = ops[0], isBranchOrCall { return v & 0xFFFF }
        return nil
    }
    public var farTarget: (seg: Int, off: Int)? {
        if ops.count == 1, case let .far(s, o) = ops[0] { return (s, o) }
        return nil
    }
    var isBranchOrCall: Bool { mn.hasPrefix("j") || mn.hasPrefix("loop") || mn == "call" }
    public static let jccNames: Set<String> = ["jo", "jno", "jb", "jae", "je", "jne", "jbe", "ja", "js", "jns", "jp", "jnp",
                                               "jl", "jge", "jle", "jg"]
    public var isJcc: Bool { Self.jccNames.contains(mn) }
    /// Any operand uses a CS override (`cs:[..]`).
    public var usesCS: Bool { ops.contains { $0.memValue?.seg == 1 } }
}

public enum X86Decoder {
    static let jcc = ["jo", "jno", "jb", "jae", "je", "jne", "jbe", "ja", "js", "jns", "jp", "jnp", "jl", "jge", "jle", "jg"]
    static let alu = ["add", "or", "adc", "sbb", "and", "sub", "xor", "cmp"]
    static let shifts = ["rol", "ror", "rcl", "rcr", "shl", "shr", "sal", "sar"]

    /// Decodes the instruction at `ip` of a 64 KB code segment; nil for an invalid/unknown encoding.
    public static func decode(_ c: [UInt8], _ ip0: Int) -> X86Insn? {
        let ip0 = ip0 & 0xFFFF
        func b(_ i: Int) -> Int { i < c.count ? Int(c[i]) : 0 }
        func w(_ i: Int) -> Int { b(i) | b(i + 1) << 8 }
        func s8(_ v: Int) -> Int { v >= 0x80 ? v - 0x100 : v }
        var p = ip0
        var seg: Int?
        var rep: String?
        var n = 0
        while n < 4 {
            switch b(p) {
            case 0x26: seg = 0
            case 0x2E: seg = 1
            case 0x36: seg = 2
            case 0x3E: seg = 3
            case 0xF3: rep = "rep"
            case 0xF2: rep = "repne"
            case 0xF0: break   // lock
            default: n = 99; continue
            }
            p += 1; n += 1
        }
        if n != 99 { return nil }
        let op = b(p)
        p += 1
        var ops: [X86Operand] = []
        var mn = ""
        // ModRM helpers
        func modrm(size: Int) -> (reg: Int, rm: X86Operand)? {
            let m = b(p)
            p += 1
            let mod = m >> 6, reg = (m >> 3) & 7, rm = m & 7
            if mod == 3 { return (reg, .reg(rm, size == 1 ? 1 : 2)) }
            var disp = 0
            var r: Int? = rm
            if mod == 0 && rm == 6 { disp = w(p); p += 2; r = nil }
            else if mod == 1 { disp = s8(b(p)); p += 1 }
            else if mod == 2 { disp = w(p); p += 2 }
            return (reg, .mem(X86Mem(seg: seg, rm: r, disp: disp, size: size)))
        }
        func imm(_ size: Int) -> X86Operand {
            let v = size == 1 ? b(p) : w(p)
            p += size
            return .imm(v, size)
        }
        func rel8() -> X86Operand { let d = s8(b(p)); p += 1; return .imm((p + d) & 0xFFFF, 2) }
        func rel16() -> X86Operand { let d = w(p); p += 2; return .imm((p + d) & 0xFFFF, 2) }
        func finish() -> X86Insn? {
            if mn.isEmpty { return nil }
            return X86Insn(ip: ip0, length: p - ip0, opcode: UInt8(op), mn: mn, ops: ops, seg: seg)
        }
        switch op {
        case 0x00...0x3F where op & 7 < 6:
            let size = op & 1 == 1 ? 2 : 1
            mn = alu[op >> 3]
            switch op & 7 {
            case 0, 1: guard let m = modrm(size: size) else { return nil }; ops = [m.rm, .reg(m.reg, size)]
            case 2, 3: guard let m = modrm(size: size) else { return nil }; ops = [.reg(m.reg, size), m.rm]
            case 4: ops = [.reg(0, 1), imm(1)]
            default: ops = [.reg(0, 2), imm(2)]
            }
        case 0x06, 0x0E, 0x16, 0x1E: mn = "push"; ops = [.sreg(op >> 3)]
        case 0x07, 0x17, 0x1F: mn = "pop"; ops = [.sreg(op >> 3)]
        case 0x27: mn = "daa"
        case 0x2F: mn = "das"
        case 0x37: mn = "aaa"
        case 0x3F: mn = "aas"
        case 0x40...0x47: mn = "inc"; ops = [.reg(op - 0x40, 2)]
        case 0x48...0x4F: mn = "dec"; ops = [.reg(op - 0x48, 2)]
        case 0x50...0x57: mn = "push"; ops = [.reg(op - 0x50, 2)]
        case 0x58...0x5F: mn = "pop"; ops = [.reg(op - 0x58, 2)]
        case 0x60: mn = "pusha"
        case 0x61: mn = "popa"
        case 0x62: mn = "bound"; guard let m = modrm(size: 4) else { return nil }; ops = [.reg(m.reg, 2), m.rm]
        case 0x68: mn = "push"; ops = [imm(2)]
        case 0x6A: mn = "push"; let v = s8(b(p)); p += 1; ops = [.imm(v & 0xFFFF, 2)]
        case 0x69, 0x6B:
            mn = "imul"
            guard let m = modrm(size: 2) else { return nil }
            if op == 0x69 { ops = [.reg(m.reg, 2), m.rm, imm(2)] } else { let v = s8(b(p)); p += 1; ops = [.reg(m.reg, 2), m.rm, .imm(v, 2)] }
        case 0x6C: mn = "insb"
        case 0x6D: mn = "insw"
        case 0x6E: mn = "outsb"
        case 0x6F: mn = "outsw"
        case 0x70...0x7F: mn = jcc[op - 0x70]; ops = [rel8()]
        case 0x80...0x83:
            let size = op & 1 == 1 ? 2 : 1
            guard let m = modrm(size: size) else { return nil }
            mn = alu[m.reg]
            if op == 0x83 { let v = s8(b(p)); p += 1; ops = [m.rm, .imm(v, 2)] } else { ops = [m.rm, imm(size)] }
        case 0x84, 0x85:
            let size = op == 0x85 ? 2 : 1
            guard let m = modrm(size: size) else { return nil }
            mn = "test"; ops = [m.rm, .reg(m.reg, size)]
        case 0x86, 0x87:
            let size = op == 0x87 ? 2 : 1
            guard let m = modrm(size: size) else { return nil }
            mn = "xchg"; ops = [m.rm, .reg(m.reg, size)]
        case 0x88...0x8B:
            let size = op & 1 == 1 ? 2 : 1
            guard let m = modrm(size: size) else { return nil }
            mn = "mov"; ops = op < 0x8A ? [m.rm, .reg(m.reg, size)] : [.reg(m.reg, size), m.rm]
        case 0x8C:
            guard let m = modrm(size: 2), m.reg < 4 else { return nil }
            mn = "mov"; ops = [m.rm, .sreg(m.reg)]
        case 0x8D:
            guard let m = modrm(size: 2), case .mem = m.rm else { return nil }
            mn = "lea"; ops = [.reg(m.reg, 2), m.rm]
        case 0x8E:
            guard let m = modrm(size: 2), m.reg < 4 else { return nil }
            mn = "mov"; ops = [.sreg(m.reg), m.rm]
        case 0x8F:
            guard let m = modrm(size: 2), m.reg == 0 else { return nil }
            mn = "pop"; ops = [m.rm]
        case 0x90: mn = "nop"
        case 0x91...0x97: mn = "xchg"; ops = [.reg(op - 0x90, 2), .reg(0, 2)]
        case 0x98: mn = "cbw"
        case 0x99: mn = "cwd"
        case 0x9A: mn = "lcall"; let o = w(p), s = w(p + 2); p += 4; ops = [.far(s, o)]
        case 0x9B: mn = "wait"
        case 0x9C: mn = "pushf"
        case 0x9D: mn = "popf"
        case 0x9E: mn = "sahf"
        case 0x9F: mn = "lahf"
        case 0xA0...0xA3:
            let size = op & 1 == 1 ? 2 : 1
            let m = X86Operand.mem(X86Mem(seg: seg, rm: nil, disp: w(p), size: size))
            p += 2
            mn = "mov"; ops = op < 0xA2 ? [.reg(0, size), m] : [m, .reg(0, size)]
        case 0xA4...0xA7, 0xAA...0xAF:
            let size = op & 1 == 1 ? 2 : 1
            let base = ["movs", "movs", "cmps", "cmps", "", "", "stos", "stos", "lods", "lods", "scas", "scas"][op - 0xA4]
            mn = base + (size == 1 ? "b" : "w")
            let src = X86Operand.mem(X86Mem(seg: seg, rm: 4, disp: 0, size: size))
            let dst = X86Operand.mem(X86Mem(seg: 0, rm: 5, disp: 0, size: size))
            switch base {
            case "movs": ops = [dst, src]
            case "cmps": ops = [src, dst]
            case "stos": ops = [dst, .reg(0, size)]
            case "lods": ops = [.reg(0, size), src]
            default: ops = [.reg(0, size), dst]
            }
            if let r = rep { mn = r + " " + mn }
        case 0xA8: mn = "test"; ops = [.reg(0, 1), imm(1)]
        case 0xA9: mn = "test"; ops = [.reg(0, 2), imm(2)]
        case 0xB0...0xB7: mn = "mov"; ops = [.reg(op - 0xB0, 1), imm(1)]
        case 0xB8...0xBF: mn = "mov"; ops = [.reg(op - 0xB8, 2), imm(2)]
        case 0xC0, 0xC1, 0xD0...0xD3:
            let size = op & 1 == 1 ? 2 : 1
            guard let m = modrm(size: size) else { return nil }
            mn = shifts[m.reg]
            if op <= 0xC1 { ops = [m.rm, imm(1)] } else if op <= 0xD1 { ops = [m.rm, .imm(1, 1)] } else { ops = [m.rm, .reg(1, 1)] }
        case 0xC2: mn = "ret"; ops = [imm(2)]
        case 0xC3: mn = "ret"
        case 0xC4, 0xC5:
            guard let m = modrm(size: 4), case .mem = m.rm else { return nil }
            mn = op == 0xC4 ? "les" : "lds"; ops = [.reg(m.reg, 2), m.rm]
        case 0xC6, 0xC7:
            let size = op == 0xC7 ? 2 : 1
            guard let m = modrm(size: size), m.reg == 0 else { return nil }
            mn = "mov"; ops = [m.rm, imm(size)]
        case 0xC8: mn = "enter"; let a = w(p), l = b(p + 2); p += 3; ops = [.imm(a, 2), .imm(l, 1)]
        case 0xC9: mn = "leave"
        case 0xCA: mn = "retf"; ops = [imm(2)]
        case 0xCB: mn = "retf"
        case 0xCC: mn = "int3"
        case 0xCD: mn = "int"; ops = [imm(1)]
        case 0xCE: mn = "into"
        case 0xCF: mn = "iret"
        case 0xD4: mn = "aam"; p += 1
        case 0xD5: mn = "aad"; p += 1
        case 0xD6: mn = "salc"
        case 0xD7: mn = "xlatb"
        case 0xD8...0xDF:
            guard modrm(size: 2) != nil else { return nil }
            mn = "fpu"
        case 0xE0: mn = "loopne"; ops = [rel8()]
        case 0xE1: mn = "loope"; ops = [rel8()]
        case 0xE2: mn = "loop"; ops = [rel8()]
        case 0xE3: mn = "jcxz"; ops = [rel8()]
        case 0xE4: mn = "in"; ops = [.reg(0, 1), imm(1)]
        case 0xE5: mn = "in"; ops = [.reg(0, 2), imm(1)]
        case 0xE6: mn = "out"; ops = [imm(1), .reg(0, 1)]
        case 0xE7: mn = "out"; ops = [imm(1), .reg(0, 2)]
        case 0xE8: mn = "call"; ops = [rel16()]
        case 0xE9: mn = "jmp"; ops = [rel16()]
        case 0xEA: mn = "ljmp"; let o = w(p), s = w(p + 2); p += 4; ops = [.far(s, o)]
        case 0xEB: mn = "jmp"; ops = [rel8()]
        case 0xEC: mn = "in"; ops = [.reg(0, 1), .reg(2, 2)]
        case 0xED: mn = "in"; ops = [.reg(0, 2), .reg(2, 2)]
        case 0xEE: mn = "out"; ops = [.reg(2, 2), .reg(0, 1)]
        case 0xEF: mn = "out"; ops = [.reg(2, 2), .reg(0, 2)]
        case 0xF4: mn = "hlt"
        case 0xF5: mn = "cmc"
        case 0xF6, 0xF7:
            let size = op == 0xF7 ? 2 : 1
            guard let m = modrm(size: size) else { return nil }
            switch m.reg {
            case 0, 1: mn = "test"; ops = [m.rm, imm(size)]
            case 2: mn = "not"; ops = [m.rm]
            case 3: mn = "neg"; ops = [m.rm]
            case 4: mn = "mul"; ops = [m.rm]
            case 5: mn = "imul"; ops = [m.rm]
            case 6: mn = "div"; ops = [m.rm]
            default: mn = "idiv"; ops = [m.rm]
            }
        case 0xF8: mn = "clc"
        case 0xF9: mn = "stc"
        case 0xFA: mn = "cli"
        case 0xFB: mn = "sti"
        case 0xFC: mn = "cld"
        case 0xFD: mn = "std"
        case 0xFE:
            guard let m = modrm(size: 1), m.reg <= 1 else { return nil }
            mn = m.reg == 0 ? "inc" : "dec"; ops = [m.rm]
        case 0xFF:
            let save = p
            let reg = (b(p) >> 3) & 7
            guard let m = modrm(size: reg == 3 || reg == 5 ? 4 : 2) else { return nil }
            switch reg {
            case 0: mn = "inc"
            case 1: mn = "dec"
            case 2: mn = "call"
            case 3: mn = "lcall"
            case 4: mn = "jmp"
            case 5: mn = "ljmp"
            case 6: mn = "push"
            default: p = save; return nil
            }
            ops = [m.rm]
        default:
            return nil
        }
        return finish()
    }

    /// Straight-line decode of cs:a..<b (stops at the first undecodable byte).
    public static func linear(_ c: [UInt8], _ a: Int, _ b: Int) -> [X86Insn] {
        var out: [X86Insn] = []
        var x = a
        while x < b, let i = decode(c, x) {
            out.append(i)
            x += i.length
        }
        return out
    }
}
