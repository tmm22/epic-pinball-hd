// A 16-bit real-mode x86 decoder whose output (mnemonic, operand text, operand details,
// written registers) follows capstone 5 (CS_MODE_16, Intel syntax), which is what the Python
// extraction tools use. The analyses in this module were written against that output (text
// matching such as `op_str == "si, 1"`), so reproducing it keeps them identical.
//
// Covered: the whole 8086/80186/80286 one-byte opcode map with segment, rep/repne and lock
// prefixes, including capstone's quirks (`cwde`/`cdq` for 98/99, `pushaw`/`popaw`, `bnd`/
// `notrack`/`repz ret`, `lcall a, b` vs `ljmp a:b`, xabort/xbegin). Not covered (returns nil,
// capstone would decode them): 0F two-byte opcodes, x87 escapes D8-DF, and the 66/67
// operand/address-size prefixes. None of these occur in the table code the analyses walk;
// the checks in PinballImportTests compare every byte offset of the 13 code segments
// against capstone when it is available.
import Foundation

public struct X86Operand: Equatable, Sendable {
    public enum Kind: Sendable { case reg, imm, mem }
    public var kind: Kind
    /// Operand size in bytes (capstone `op.size`).
    public var size: Int
    public var reg: String = ""
    public var imm: Int = 0
    public var segment: String? = nil
    public var base: String? = nil
    public var index: String? = nil
    public var disp: Int = 0

    static func r(_ name: String, _ size: Int) -> X86Operand { X86Operand(kind: .reg, size: size, reg: name) }
    static func i(_ v: Int, _ size: Int) -> X86Operand { X86Operand(kind: .imm, size: size, imm: v) }
}

public struct X86Instruction: Sendable {
    public var address: Int
    public var size: Int
    public var mnemonic: String
    public var opStr: String
    public var operands: [X86Operand]
    /// Registers the instruction writes, restricted to al..dh / ax..dx (capstone `regs_access()`
    /// written list; 32-bit names such as popa's eax are not included, as in capstone).
    public var written: [String]

    public var text: String { opStr.isEmpty ? mnemonic : "\(mnemonic) \(opStr)" }
}

enum X86 {
    static let r8 = ["al", "cl", "dl", "bl", "ah", "ch", "dh", "bh"]
    static let r16 = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di"]
    static let sregs = ["es", "cs", "ss", "ds", "fs", "gs"]
    static let tracked: Set<String> = ["al", "ah", "bl", "bh", "cl", "ch", "dl", "dh", "ax", "bx", "cx", "dx"]
    static let alu = ["add", "or", "adc", "sbb", "and", "sub", "xor", "cmp"]
    static let shifts = ["rol", "ror", "rcl", "rcr", "shl", "shr", "sal", "sar"]
    static let jcc = ["jo", "jno", "jb", "jae", "je", "jne", "jbe", "ja", "js", "jns", "jp", "jnp", "jl", "jge", "jle", "jg"]

    /// capstone printImm: decimal up to 9, hex above, negative values with a minus sign.
    static func imm(_ v: Int) -> String {
        if v >= 0 { return v > 9 ? String(format: "0x%llx", Int64(v)) : "\(v)" }
        return v < -9 ? String(format: "-0x%llx", Int64(-v)) : "-\(-v)"
    }
    static func hexU(_ v: Int) -> String { v > 9 ? String(format: "0x%x", v) : "\(v)" }

    struct Mem {
        var seg: String?
        var base: String?
        var index: String?
        var disp: Int
        var direct: Bool
    }

    static func memText(_ m: Mem, ptr: String) -> String {
        var s = ptr
        if let sg = m.seg { s += "\(sg):" }
        s += "["
        if m.base == nil && m.index == nil {
            s += hexU(m.disp & 0xFFFF)
        } else {
            var parts: [String] = []
            if let b = m.base { parts.append(b) }
            if let i = m.index { parts.append(i) }
            s += parts.joined(separator: " + ")
            if m.disp > 0 { s += " + " + hexU(m.disp) }
            else if m.disp < 0 { s += " - " + hexU(-m.disp) }
        }
        return s + "]"
    }

    static func ptrName(_ size: Int) -> String {
        switch size {
        case 1: return "byte ptr "
        case 2: return "word ptr "
        case 4: return "dword ptr "
        default: return ""
        }
    }

    /// Decodes one instruction from `bytes[start ..< limit]`, reporting `address` as its ip.
    static func decode(_ bytes: [UInt8], start: Int, limit: Int, address: Int) -> X86Instruction? {
        var p = start
        let end = min(limit, bytes.count, start + 15)
        var seg: String? = nil
        var rep: UInt8 = 0
        var lock = false
        var segByte: UInt8 = 0
        func byte() -> UInt8? {
            guard p < end else { return nil }
            let b = bytes[p]; p += 1; return b
        }
        var op: UInt8 = 0
        var prefixBytes: [UInt8] = []
        prefixes: while true {
            guard let b = byte() else { return nil }
            switch b {
            case 0x26: seg = "es"; segByte = b
            case 0x2E: seg = "cs"; segByte = b
            case 0x36: seg = "ss"; segByte = b
            case 0x3E: seg = "ds"; segByte = b
            case 0x64: seg = "fs"; segByte = b
            case 0x65: seg = "gs"; segByte = b
            case 0xF2, 0xF3: rep = b
            case 0xF0: lock = true
            case 0x66, 0x67: return nil
            default: op = b; break prefixes
            }
            prefixBytes.append(b)
        }
        func u8() -> Int? { byte().map { Int($0) } }
        func s8() -> Int? { u8().map { $0 >= 0x80 ? $0 - 0x100 : $0 } }
        func u16() -> Int? { guard let a = u8(), let b = u8() else { return nil }; return a | b << 8 }
        func s16() -> Int? { u16().map { $0 >= 0x8000 ? $0 - 0x10000 : $0 } }

        // ModRM
        struct ModRM { var mod: Int; var reg: Int; var rm: Int; var mem: Mem? }
        func modrm() -> ModRM? {
            guard let b = u8() else { return nil }
            let mod = b >> 6, reg = (b >> 3) & 7, rm = b & 7
            if mod == 3 { return ModRM(mod: mod, reg: reg, rm: rm, mem: nil) }
            let bases: [(String?, String?)] = [("bx", "si"), ("bx", "di"), ("bp", "si"), ("bp", "di"), ("si", nil), ("di", nil), ("bp", nil), ("bx", nil)]
            var m = Mem(seg: seg, base: bases[rm].0, index: bases[rm].1, disp: 0, direct: false)
            if mod == 0 && rm == 6 {
                guard let d = s16() else { return nil }
                m.base = nil; m.index = nil; m.disp = d; m.direct = true
            } else if mod == 1 {
                guard let d = s8() else { return nil }
                m.disp = d
            } else if mod == 2 {
                guard let d = s16() else { return nil }
                m.disp = d
            }
            return ModRM(mod: mod, reg: reg, rm: rm, mem: m)
        }

        var mn = ""
        var ops: [X86Operand] = []
        var texts: [String] = []
        var written: [String] = []

        func regOp(_ name: String, _ size: Int) { ops.append(.r(name, size)); texts.append(name) }
        func immOp(_ v: Int, _ size: Int, text: String? = nil) { ops.append(.i(v, size)); texts.append(text ?? imm(v)) }
        func memOp(_ m: Mem, _ size: Int, ptr: String? = nil) {
            ops.append(X86Operand(kind: .mem, size: size, segment: m.seg, base: m.base, index: m.index, disp: m.disp))
            texts.append(memText(m, ptr: ptr ?? ptrName(size)))
        }
        func rmOp(_ r: ModRM, _ size: Int, ptr: String? = nil) {
            if let m = r.mem { memOp(m, size, ptr: ptr) } else { regOp(size == 1 ? r8[r.rm] : r16[r.rm], size) }
        }
        func gReg(_ r: ModRM, _ size: Int) -> String { size == 1 ? r8[r.reg] : r16[r.reg] }
        func write(_ names: String...) { for n in names where tracked.contains(n) && !written.contains(n) { written.append(n) } }
        func rmWritten(_ r: ModRM, _ size: Int) { if r.mem == nil { write(size == 1 ? r8[r.rm] : r16[r.rm]) } }
        func rel(_ d: Int) -> Int { (address + (p - start) + d) & 0xFFFF_FFFF }
        var lockable = false

        switch op {
        case 0x00...0x3F where (op & 7) < 6:
            let name = alu[Int(op >> 3)]
            mn = name
            let form = op & 7
            switch form {
            case 0, 1:
                let size = form == 0 ? 1 : 2
                guard let r = modrm() else { return nil }
                rmOp(r, size); regOp(gReg(r, size), size)
                if name != "cmp" { rmWritten(r, size) }
                lockable = r.mem != nil && name != "cmp"
            case 2, 3:
                let size = form == 2 ? 1 : 2
                guard let r = modrm() else { return nil }
                regOp(gReg(r, size), size); rmOp(r, size)
                if name != "cmp" { write(gReg(r, size)) }
                lockable = r.mem != nil && name != "cmp"
            case 4:
                guard let v = u8() else { return nil }
                regOp("al", 1); immOp(v, 1)
                if name != "cmp" { write("al") }
            default:
                guard let v = u16() else { return nil }
                regOp("ax", 2); immOp(v, 2)
                if name != "cmp" { write("ax") }
            }
        case 0x06, 0x0E, 0x16, 0x1E:
            mn = "push"; regOp(sregs[Int(op >> 3)], 2)
        case 0x07, 0x17, 0x1F:
            mn = "pop"; regOp(sregs[Int(op >> 3)], 2)
        case 0x27: mn = "daa"
        case 0x2F: mn = "das"
        case 0x37: mn = "aaa"
        case 0x3F: mn = "aas"
        case 0x40...0x47: mn = "inc"; regOp(r16[Int(op & 7)], 2); write(r16[Int(op & 7)])
        case 0x48...0x4F: mn = "dec"; regOp(r16[Int(op & 7)], 2); write(r16[Int(op & 7)])
        case 0x50...0x57: mn = "push"; regOp(r16[Int(op & 7)], 2)
        case 0x58...0x5F: mn = "pop"; regOp(r16[Int(op & 7)], 2); write(r16[Int(op & 7)])
        case 0x60: mn = "pushaw"
        case 0x61: mn = "popaw"
        case 0x62:
            guard let r = modrm(), r.mem != nil else { return nil }
            mn = "bound"; regOp(gReg(r, 2), 2); rmOp(r, 4); write(gReg(r, 2))
        case 0x63:
            guard let r = modrm() else { return nil }
            mn = "arpl"; rmOp(r, 2); regOp(gReg(r, 2), 2); rmWritten(r, 2)
        case 0x68:
            guard let v = u16() else { return nil }
            mn = "push"; immOp(v, 2)
        case 0x69, 0x6B:
            guard let r = modrm() else { return nil }
            let v: Int
            if op == 0x69 { guard let x = u16() else { return nil }; v = x } else { guard let x = s8() else { return nil }; v = x }
            mn = "imul"; regOp(gReg(r, 2), 2); rmOp(r, 2); immOp(v, 2); write(gReg(r, 2))
        case 0x6A:
            guard let v = s8() else { return nil }
            mn = "push"; immOp(v, 2)
        case 0x6C, 0x6D:
            let size = op == 0x6C ? 1 : 2
            mn = size == 1 ? "insb" : "insw"
            memOp(Mem(seg: "es", base: "di", index: nil, disp: 0, direct: false), size); regOp("dx", 2)
        case 0x6E, 0x6F:
            let size = op == 0x6E ? 1 : 2
            mn = size == 1 ? "outsb" : "outsw"
            regOp("dx", 2); memOp(Mem(seg: seg, base: "si", index: nil, disp: 0, direct: false), size)
        case 0x70...0x7F:
            guard let d = s8() else { return nil }
            mn = jcc[Int(op & 0xF)]; immOp(rel(d), 2, text: String(format: "0x%x", rel(d)))
        case 0x80, 0x81, 0x82, 0x83:
            guard let r = modrm() else { return nil }
            let size = (op == 0x81 || op == 0x83) ? 2 : 1
            let name = alu[r.reg]
            var v: Int
            if op == 0x81 { guard let x = u16() else { return nil }; v = x }
            else if op == 0x83 { guard let x = s8() else { return nil }; v = x }
            else { guard let x = u8() else { return nil }; v = x }
            mn = name
            rmOp(r, size)
            if op == 0x83 && ["and", "or", "xor"].contains(name) { v &= 0xFFFF }
            immOp(v, size)
            if name != "cmp" { rmWritten(r, size) }
            lockable = r.mem != nil && name != "cmp"
        case 0x84, 0x85:
            let size = op == 0x84 ? 1 : 2
            guard let r = modrm() else { return nil }
            mn = "test"; rmOp(r, size); regOp(gReg(r, size), size)
        case 0x86, 0x87:
            let size = op == 0x86 ? 1 : 2
            guard let r = modrm() else { return nil }
            mn = "xchg"; rmOp(r, size); regOp(gReg(r, size), size)
            rmWritten(r, size); write(gReg(r, size))
            lockable = r.mem != nil
        case 0x88, 0x89:
            let size = op == 0x88 ? 1 : 2
            guard let r = modrm() else { return nil }
            mn = "mov"; rmOp(r, size); regOp(gReg(r, size), size); rmWritten(r, size)
        case 0x8A, 0x8B:
            let size = op == 0x8A ? 1 : 2
            guard let r = modrm() else { return nil }
            mn = "mov"; regOp(gReg(r, size), size); rmOp(r, size); write(gReg(r, size))
        case 0x8C:
            guard let r = modrm(), r.reg < 6 else { return nil }
            mn = "mov"; rmOp(r, 2); regOp(sregs[r.reg], 2); rmWritten(r, 2)
        case 0x8D:
            guard let r = modrm(), r.mem != nil else { return nil }
            mn = "lea"; regOp(gReg(r, 2), 2); rmOp(r, 2, ptr: ""); write(gReg(r, 2))
        case 0x8E:
            guard let r = modrm(), r.reg < 6 else { return nil }
            mn = "mov"; regOp(sregs[r.reg], 2); rmOp(r, 2)
        case 0x8F:
            guard let r = modrm(), r.reg == 0 else { return nil }
            mn = "pop"; rmOp(r, 2); rmWritten(r, 2)
        case 0x90:
            if rep == 0xF3 { mn = "pause" } else { mn = "nop" }
        case 0x91...0x97:
            mn = "xchg"; regOp(r16[Int(op & 7)], 2); regOp("ax", 2); write("ax", r16[Int(op & 7)])
        case 0x98: mn = "cwde"
        case 0x99: mn = "cdq"
        case 0x9A:
            guard let off = u16(), let sg = u16() else { return nil }
            mn = "lcall"
            ops = [.i(sg, 2), .i(off, 4)]
            texts = [imm(sg), imm(off)]
        case 0x9B: mn = "wait"
        case 0x9C: mn = "pushf"
        case 0x9D: mn = "popf"
        case 0x9E: mn = "sahf"
        case 0x9F: mn = "lahf"; write("ah")
        case 0xA0...0xA3:
            guard let a = u16() else { return nil }
            let size = (op & 1) == 0 ? 1 : 2
            let m = Mem(seg: seg, base: nil, index: nil, disp: a, direct: true)
            let reg = size == 1 ? "al" : "ax"
            mn = "mov"
            if op < 0xA2 { regOp(reg, size); memOp(m, size); write(reg) } else { memOp(m, size); regOp(reg, size) }
        case 0xA4, 0xA5:
            let size = op == 0xA4 ? 1 : 2
            mn = size == 1 ? "movsb" : "movsw"
            memOp(Mem(seg: "es", base: "di", index: nil, disp: 0, direct: false), size)
            memOp(Mem(seg: seg, base: "si", index: nil, disp: 0, direct: false), size)
        case 0xA6, 0xA7:
            let size = op == 0xA6 ? 1 : 2
            mn = size == 1 ? "cmpsb" : "cmpsw"
            memOp(Mem(seg: seg, base: "si", index: nil, disp: 0, direct: false), size)
            memOp(Mem(seg: "es", base: "di", index: nil, disp: 0, direct: false), size)
        case 0xA8:
            guard let v = u8() else { return nil }
            mn = "test"; regOp("al", 1); immOp(v, 1)
        case 0xA9:
            guard let v = u16() else { return nil }
            mn = "test"; regOp("ax", 2); immOp(v, 2)
        case 0xAA, 0xAB:
            let size = op == 0xAA ? 1 : 2
            mn = size == 1 ? "stosb" : "stosw"
            memOp(Mem(seg: "es", base: "di", index: nil, disp: 0, direct: false), size); regOp(size == 1 ? "al" : "ax", size)
        case 0xAC, 0xAD:
            let size = op == 0xAC ? 1 : 2
            mn = size == 1 ? "lodsb" : "lodsw"
            regOp(size == 1 ? "al" : "ax", size); memOp(Mem(seg: seg, base: "si", index: nil, disp: 0, direct: false), size)
            write(size == 1 ? "al" : "ax")
        case 0xAE, 0xAF:
            let size = op == 0xAE ? 1 : 2
            mn = size == 1 ? "scasb" : "scasw"
            regOp(size == 1 ? "al" : "ax", size); memOp(Mem(seg: "es", base: "di", index: nil, disp: 0, direct: false), size)
        case 0xB0...0xB7:
            guard let v = u8() else { return nil }
            mn = "mov"; regOp(r8[Int(op & 7)], 1); immOp(v, 1); write(r8[Int(op & 7)])
        case 0xB8...0xBF:
            guard let v = u16() else { return nil }
            mn = "mov"; regOp(r16[Int(op & 7)], 2); immOp(v, 2); write(r16[Int(op & 7)])
        case 0xC0, 0xC1, 0xD0, 0xD1, 0xD2, 0xD3:
            guard let r = modrm() else { return nil }
            let size = (op & 1) == 0 ? 1 : 2
            mn = shifts[r.reg]
            rmOp(r, size)
            if op == 0xC0 || op == 0xC1 { guard let v = u8() else { return nil }; immOp(v, 1) }
            else if op == 0xD0 || op == 0xD1 {
                // capstone quirk: `rcl mem, 1` has a size-0 immediate and no ", 1" in the text
                if r.reg == 2 && r.mem != nil { ops.append(.i(1, 0)) } else { immOp(1, size) }
            }
            else { regOp("cl", 1) }
            rmWritten(r, size)
        case 0xC2, 0xCA:
            guard let v = u16() else { return nil }
            mn = op == 0xC2 ? "ret" : "retf"; immOp(v, 2)
        case 0xC3: mn = "ret"
        case 0xCB: mn = "retf"
        case 0xC4, 0xC5:
            guard let r = modrm(), r.mem != nil else { return nil }
            mn = op == 0xC4 ? "les" : "lds"; regOp(gReg(r, 2), 2); rmOp(r, 2, ptr: "ptr "); write(gReg(r, 2))
        case 0xC6, 0xC7:
            guard let r = modrm() else { return nil }
            let size = op == 0xC6 ? 1 : 2
            if r.reg == 7 && r.mod == 3 && r.rm == 0 {
                if op == 0xC6 { guard let v = u8() else { return nil }; mn = "xabort"; immOp(v, 2) }
                else { guard let d = s16() else { return nil }; mn = "xbegin"; immOp(rel(d), 2, text: String(format: "0x%x", rel(d))) }
                break
            }
            guard r.reg == 0 else { return nil }
            let v: Int
            if size == 1 { guard let x = u8() else { return nil }; v = x } else { guard let x = u16() else { return nil }; v = x }
            mn = "mov"; rmOp(r, size); immOp(v, size); rmWritten(r, size)
        case 0xC8:
            guard let a = s16(), let b = s8() else { return nil }
            mn = "enter"; immOp(a, 2); immOp(b, 2)
        case 0xC9: mn = "leave"
        case 0xCC: mn = "int3"
        case 0xCD:
            guard let v = u8() else { return nil }
            mn = "int"; immOp(v, 1)
        case 0xCE: mn = "into"
        case 0xCF: mn = "iret"
        case 0xD4, 0xD5:
            guard let v = u8() else { return nil }
            mn = op == 0xD4 ? "aam" : "aad"; immOp(v, 1)
        case 0xD6: mn = "salc"; write("al")
        case 0xD7: mn = "xlatb"
        case 0xE0...0xE3:
            guard let d = s8() else { return nil }
            mn = ["loopne", "loope", "loop", "jcxz"][Int(op & 3)]
            immOp(rel(d), 2, text: String(format: "0x%x", rel(d)))
            if op != 0xE3 { write("cx") }
        case 0xE4, 0xE5:
            guard let v = u8() else { return nil }
            let size = op == 0xE4 ? 1 : 2
            mn = "in"; regOp(size == 1 ? "al" : "ax", size); immOp(v, 1); write(size == 1 ? "al" : "ax")
        case 0xE6, 0xE7:
            guard let v = u8() else { return nil }
            let size = op == 0xE6 ? 1 : 2
            mn = "out"; immOp(v, 1); regOp(size == 1 ? "al" : "ax", size)
        case 0xE8, 0xE9:
            guard let d = s16() else { return nil }
            mn = op == 0xE8 ? "call" : "jmp"; immOp(rel(d), 2, text: String(format: "0x%x", rel(d)))
        case 0xEA:
            guard let off = u16(), let sg = u16() else { return nil }
            mn = "ljmp"
            ops = [.i(sg, 2), .i(off, 4)]
            texts = [imm(sg) + ":" + imm(off)]
        case 0xEB:
            guard let d = s8() else { return nil }
            mn = "jmp"; immOp(rel(d), 2, text: String(format: "0x%x", rel(d)))
        case 0xEC: mn = "in"; regOp("al", 1); regOp("dx", 2); write("al")
        case 0xED: mn = "in"; regOp("ax", 2); regOp("dx", 2); write("ax")
        case 0xEE: mn = "out"; regOp("dx", 2); regOp("al", 1)
        case 0xEF: mn = "out"; regOp("dx", 2); regOp("ax", 2)
        case 0xF1: mn = "int1"
        case 0xF4: mn = "hlt"
        case 0xF5: mn = "cmc"
        case 0xF6, 0xF7:
            guard let r = modrm() else { return nil }
            let size = op == 0xF6 ? 1 : 2
            let names = ["test", "test", "not", "neg", "mul", "imul", "div", "idiv"]
            mn = names[r.reg]
            rmOp(r, size)
            switch r.reg {
            case 0, 1:
                // capstone quirk: the /1 alias of `test r/m8` reports a sign-extended immediate
                var v: Int
                if size == 1 { guard let x = u8() else { return nil }; v = x } else { guard let x = u16() else { return nil }; v = x }
                if r.reg == 1 && size == 1 && v >= 0x80 { v -= 0x100 }
                immOp(v, size)
            case 2, 3: rmWritten(r, size); lockable = r.mem != nil
            case 4, 5: if size == 1 { write("al", "ax") } else { write("ax", "dx") }
            default: if size == 1 { write("ah", "al") } else { write("ax", "dx") }
            }
        case 0xF8: mn = "clc"
        case 0xF9: mn = "stc"
        case 0xFA: mn = "cli"
        case 0xFB: mn = "sti"
        case 0xFC: mn = "cld"
        case 0xFD: mn = "std"
        case 0xFE:
            guard let r = modrm(), r.reg < 2 else { return nil }
            mn = r.reg == 0 ? "inc" : "dec"; rmOp(r, 1); rmWritten(r, 1); lockable = r.mem != nil
        case 0xFF:
            guard let r = modrm() else { return nil }
            switch r.reg {
            case 0, 1: mn = r.reg == 0 ? "inc" : "dec"; rmOp(r, 2); rmWritten(r, 2); lockable = r.mem != nil
            case 2: mn = "call"; rmOp(r, 2)
            case 3: guard r.mem != nil else { return nil }; mn = "lcall"; rmOp(r, 4, ptr: "")
            case 4: mn = "jmp"; rmOp(r, 2)
            case 5: guard r.mem != nil else { return nil }; mn = "ljmp"; rmOp(r, 4, ptr: "")
            case 6: mn = "push"; rmOp(r, 2)
            default: return nil
            }
        default:
            return nil   // 0F, D8-DF (x87), and anything else outside the covered map
        }

        // lock / xacquire / xrelease, in capstone's order-dependent spelling
        let xchgMem = (op == 0x86 || op == 0x87) && lockable
        if lock && !lockable { return nil }
        let firstIsRep = prefixBytes.first == 0xF2 || prefixBytes.first == 0xF3
        let hleByte: UInt8 = firstIsRep ? prefixBytes[0] : 0
        if lock || xchgMem {
            let showHLE = firstIsRep && (prefixBytes.count == 1 || prefixBytes[1] == 0xF0)
            let showLock = lock && (firstIsRep ? prefixBytes == [hleByte, 0xF0] : rep == 0)
            if showLock { mn = "lock " + mn }
            if showHLE { mn = (hleByte == 0xF3 ? "xrelease " : "xacquire ") + mn }
        }
        // rep / bnd / notrack decoration
        let isString = ["movsb", "movsw", "stosb", "stosw", "lodsb", "lodsw", "insb", "insw", "outsb", "outsw"].contains(mn)
        let isCompare = ["cmpsb", "cmpsw", "scasb", "scasw"].contains(mn)
        if isString || isCompare {
            if rep == 0xF3 { mn = (isCompare ? "repe " : "rep ") + mn; write("cx") }
            else if rep == 0xF2 { mn = "repne " + mn; write("cx") }
        } else if rep == 0xF3 && op == 0xC3 || rep == 0xF3 && op == 0xC2 {
            mn = "repz " + mn
        } else if rep == 0xF2 && !xchgMem && !lock {
            let branch = (0x70...0x7F).contains(op) || [0xE8, 0xE9, 0xEB, 0xC2, 0xC3, 0xCA, 0xCB].contains(op)
                || (op == 0xFF && (mn == "call" || mn == "jmp"))
            if branch { mn = "bnd " + mn }
        }
        if segByte == 0x3E && ((op == 0xFF && (mn == "call" || mn == "jmp")) || [0xE8, 0xE9, 0xEB].contains(op)) {
            mn = "notrack " + mn
        }
        return X86Instruction(address: address, size: p - start, mnemonic: mn, opStr: texts.joined(separator: ", "),
                              operands: ops, written: written)
    }
}

/// Lazy disassembler over one code segment of an EXE image (tools/collision.py `Code`):
/// `at(ip)` decodes the (at most) 16 bytes at `base + ip`.
final class X86Code: @unchecked Sendable {
    let data: [UInt8]
    let base: Int
    private var cache: [Int: X86Instruction?] = [:]

    init(data: [UInt8], base: Int) { self.data = data; self.base = base }

    func at(_ ip: Int) -> X86Instruction? {
        if let c = cache[ip] { return c }
        let s = base + ip
        let ins = s >= 0 && s < data.count ? X86.decode(data, start: s, limit: min(data.count, s + 16), address: ip) : nil
        cache[ip] = ins
        return ins
    }

    func linear(_ ip: Int, _ n: Int) -> [X86Instruction] {
        var out: [X86Instruction] = []
        var a = ip
        for _ in 0..<n {
            guard let i = at(a) else { break }
            out.append(i)
            a += i.size
        }
        return out
    }
}
