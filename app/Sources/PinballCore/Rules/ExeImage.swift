import Foundation

// The user's table EXE as the rules discovery sees it: MZ layout, the entry code segment (64 KB),
// the data segment and its size (tools/epexe.py), a byte-signature search (the regexes of
// tools/emu/discover.py and tools/rules.py) and a recursive-descent disassembly from the entry point
// (tools/disasm.py `Image.explore`). Nothing is stored: every address is found in the EXE bytes.

public struct ExeImage: Sendable {
    public let data: [UInt8]
    public let headerSize: Int
    public let entryCS: Int, entryIP: Int
    /// Relocated segment values -> number of fixups that reference them.
    public let segValues: [Int: Int]
    public let dataSegment: Int
    /// The playfield chain (top half, bottom half, the segment after it), 0xFA0 paragraphs apart.
    public let playfieldTop: Int
    /// Code segment bytes (the entry CS, 64 KB, zero padded past the end of the file).
    public let code: [UInt8]
    /// Data segment bytes (dsSize = everything before the playfield top half).
    public let dsBytes: [UInt8]
    public var dsFileOffset: Int { imageOffset(dataSegment) }
    public var dsSize: Int { dsBytes.count }

    public enum LoadError: Error, CustomStringConvertible {
        case notMZ, noDataSegment, noPlayfield(Int)
        public var description: String {
            switch self {
            case .notMZ: return "not an MZ executable"
            case .noDataSegment: return "no data segment setup at the entry point"
            case let .noPlayfield(n): return "expected one 3-segment playfield chain, found \(n)"
            }
        }
    }

    public func imageOffset(_ seg: Int, _ off: Int = 0) -> Int { headerSize + seg * 16 + off }

    public init(exe: [UInt8]) throws {
        data = exe
        guard exe.count >= 0x40, exe[0] == 0x4D, exe[1] == 0x5A else { throw LoadError.notMZ }
        func u16(_ o: Int) -> Int { o + 1 < exe.count ? Int(exe[o]) | Int(exe[o + 1]) << 8 : 0 }
        let nreloc = u16(6)
        headerSize = u16(8) * 16
        entryIP = u16(0x14)
        entryCS = u16(0x16)
        let relocOff = u16(0x18)
        var segs: [Int: Int] = [:]
        for i in 0..<nreloc {
            let off = u16(relocOff + 4 * i), seg = u16(relocOff + 4 * i + 2)
            let v = u16(headerSize + seg * 16 + off)
            segs[v, default: 0] += 1
        }
        segValues = segs
        // entry: push ds / mov ax,0 / push ax / mov ax,<DS> / mov ds,ax
        let e = headerSize + entryCS * 16 + entryIP
        var ds: Int?
        for i in e..<min(e + 30, exe.count - 4) where exe[i] == 0xB8 && exe[i + 3] == 0x8E && exe[i + 4] == 0xD8 {
            ds = u16(i + 1); break
        }
        guard let d = ds else { throw LoadError.noDataSegment }
        dataSegment = d
        let half = 0xFA0
        let starts = segs.keys.sorted().filter { segs[$0 + half] != nil && segs[$0 - half] == nil && segs[$0 + 2 * half] != nil }
        guard starts.count == 1 else { throw LoadError.noPlayfield(starts.count) }
        playfieldTop = starts[0]
        let cb = headerSize + entryCS * 16
        var c = [UInt8](repeating: 0, count: 0x10000)
        if cb < exe.count { let n = min(0x10000, exe.count - cb); c.replaceSubrange(0..<n, with: exe[cb..<(cb + n)]) }
        code = c
        let dsb = headerSize + d * 16, dsEnd = min(exe.count, headerSize + playfieldTop * 16)
        dsBytes = dsb < dsEnd ? Array(exe[dsb..<dsEnd]) : []
    }

    public func csWord(_ a: Int) -> Int { Int(code[a & 0xFFFF]) | Int(code[(a + 1) & 0xFFFF]) << 8 }
    public func dsByte(_ a: Int) -> Int { a >= 0 && a < dsBytes.count ? Int(dsBytes[a]) : 0 }
    public func dsWord(_ a: Int) -> Int { dsByte(a) | dsByte(a + 1) << 8 }
}

/// Byte-signature search with the Python patterns: `\xHH` escapes, `.` = any byte, `(..)` groups,
/// `\1` back references, `(?:a|b)`, `[\x77\x73]`, `*`, `?`. Bytes are mapped to private-use code
/// points (U+E000 + byte) so that ICU's `.` never meets a line terminator (it would match CR LF as
/// one character).
public final class ByteSearch: @unchecked Sendable {
    public let bytes: [UInt8]
    private let text: String
    private let ns: NSString
    private var cache: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        var s = String.UnicodeScalarView()
        s.reserveCapacity(bytes.count)
        for b in bytes { s.append(Unicode.Scalar(0xE000 + UInt32(b))!) }
        text = String(s)
        ns = text as NSString
    }

    public struct Match {
        public let start: Int, end: Int
        let groups: [NSRange]
        let bytes: [UInt8]
        public var length: Int { end - start }
        /// Group g's bytes (nil if the group did not take part).
        public func group(_ g: Int) -> [UInt8]? {
            let r = groups[g]
            guard r.location != NSNotFound else { return nil }
            return Array(bytes[r.location..<(r.location + r.length)])
        }
        public func u8(_ g: Int) -> Int? { group(g).flatMap { $0.first.map(Int.init) } }
        public func u16(_ g: Int) -> Int? { group(g).flatMap { $0.count >= 2 ? Int($0[0]) | Int($0[1]) << 8 : nil } }
        public func s16(_ g: Int) -> Int? { u16(g).map { $0 >= 0x8000 ? $0 - 0x10000 : $0 } }
        public func groupLength(_ g: Int) -> Int { groups[g].location == NSNotFound ? 0 : groups[g].length }
    }

    /// `\xHH` -> `\x{E0HH}` (every other character is ICU syntax already).
    static func translate(_ p: String) -> String {
        var out = ""
        var it = Array(p)
        var i = 0
        while i < it.count {
            if it[i] == "\\", i + 3 < it.count, it[i + 1] == "x", it[i + 2].isHexDigit, it[i + 3].isHexDigit {
                out += "\\x{E0\(it[i + 2])\(it[i + 3])}"
                i += 4
                continue
            }
            if it[i] == "\\", i + 1 < it.count {
                out.append(it[i]); out.append(it[i + 1]); i += 2; continue
            }
            out.append(it[i])
            i += 1
        }
        it.removeAll()
        return out
    }

    /// A 16-bit value as a pattern fragment (discover.py `w(v)`).
    public static func w(_ v: Int) -> String { String(format: "\\x%02x\\x%02x", v & 0xFF, (v >> 8) & 0xFF) }
    public static func b(_ v: Int) -> String { String(format: "\\x%02x", v & 0xFF) }

    private func regex(_ p: String) -> NSRegularExpression? {
        lock.lock(); defer { lock.unlock() }
        if let r = cache[p] { return r }
        guard let r = try? NSRegularExpression(pattern: Self.translate(p), options: [.dotMatchesLineSeparators]) else { return nil }
        cache[p] = r
        return r
    }

    /// Every non-overlapping match inside [start, end).
    public func all(_ pattern: String, _ start: Int = 0, _ end: Int? = nil) -> [Match] {
        let e = min(end ?? bytes.count, bytes.count), s = max(0, start)
        guard s < e, let r = regex(pattern) else { return [] }
        return r.matches(in: text, options: [], range: NSRange(location: s, length: e - s)).map { m in
            Match(start: m.range.location, end: m.range.location + m.range.length,
                  groups: (0..<m.numberOfRanges).map { m.range(at: $0) }, bytes: bytes)
        }
    }

    public func first(_ pattern: String, _ start: Int = 0, _ end: Int? = nil) -> Match? {
        let e = min(end ?? bytes.count, bytes.count), s = max(0, start)
        guard s < e, let r = regex(pattern), let m = r.firstMatch(in: text, options: [], range: NSRange(location: s, length: e - s)) else { return nil }
        return Match(start: m.range.location, end: m.range.location + m.range.length,
                     groups: (0..<m.numberOfRanges).map { m.range(at: $0) }, bytes: bytes)
    }
}

/// Recursive-descent disassembly of the entry code segment (tools/disasm.py `Image.explore`):
/// from the entry point, following calls (near and far into CS), jumps, jump tables
/// (`jmp cs:[bx+T]`, `mov bx,cs:[bx+T]; jmp bx`), code pointers built for `mov r, cs` and int 21h
/// vector installs.
public final class CodeMap: @unchecked Sendable {
    public let image: ExeImage
    public var code: [UInt8] { image.code }
    public private(set) var insns: [Int: X86Insn] = [:]
    public private(set) var funcs = Set<Int>()
    public private(set) var sortedAddrs: [Int] = []
    private var cache: [Int: X86Insn?] = [:]

    public init(image: ExeImage, extraRoots: [Int] = []) {
        self.image = image
        explore(extraRoots)
        sortedAddrs = insns.keys.sorted()
    }

    /// Decodes at `a` (cached; nil when invalid or past the segment).
    public func insn(_ a: Int) -> X86Insn? {
        guard a >= 0, a < 0x10000 else { return nil }
        if let c = cache[a] { return c }
        let i = X86Decoder.decode(image.code, a)
        cache[a] = i
        return i
    }

    /// `n` instructions from `a` (straight line).
    public func seq(_ a: Int, _ n: Int) -> [X86Insn] {
        var out: [X86Insn] = [], x = a
        while out.count < n, let i = insn(x) { out.append(i); x += i.length }
        return out
    }

    public var allInsns: [X86Insn] { sortedAddrs.map { insns[$0]! } }

    /// The nearest function entry at or below `a`.
    public func function(containing a: Int) -> Int? { funcs.filter { $0 <= a }.max() }

    private func explore(_ extra: [Int]) {
        var work: [Int] = [image.entryIP] + extra
        funcs.formUnion(work)
        var seenVec = Set<Int>()
        let cs = image.entryCS
        while let start = work.popLast() {
            var addr = start
            var prev: X86Insn?
            var hist: [X86Insn] = []
            while insns[addr] == nil {
                guard let i = insn(addr) else { break }
                insns[addr] = i
                let m = i.mn
                let t: Int? = { if let o = i.ops.first, case let .imm(v, _) = o { return v & 0xFFFF }; return nil }()
                var ft: Int?
                if (m == "lcall" || m == "ljmp"), let f = i.farTarget, f.seg == cs { ft = f.off }
                if m == "call", let t {
                    funcs.insert(t); work.append(t)
                } else if let ft {
                    funcs.insert(ft); work.append(ft)
                } else if (m.hasPrefix("j") || m.hasPrefix("loop")), let t {
                    work.append(t)
                }
                if m == "mov", i.ops.count == 2, case .sreg(1) = i.ops[1], prev != nil {
                    for h in hist.suffix(3) { codePointer(h, &seenVec, &work) }
                }
                if m == "int", i.ops.first?.immValue == 0x21, prev != nil { vector(at: addr, &seenVec, &work) }
                if m == "jmp", t == nil {
                    for tg in jumpTable(i, prev) { work.append(tg) }
                }
                if ["ret", "retf", "iret", "jmp", "ljmp", "hlt"].contains(m) { break }
                prev = i
                hist.append(i)
                addr = (addr + i.length) & 0xFFFF
            }
        }
    }

    private func codePointer(_ p: X86Insn, _ seen: inout Set<Int>, _ work: inout [Int]) {
        var v: Int?
        if p.mn == "lea", p.ops.count == 2, let m = p.ops[1].memValue { v = m.offset }
        else if p.mn == "mov", p.ops.count == 2, p.ops[0] == .reg(2, 2), let x = p.ops[1].immValue { v = x }
        if let v, !seen.contains(v), v < 0x10000 {
            seen.insert(v); funcs.insert(v); work.append(v)
        }
    }

    private func vector(at a: Int, _ seen: inout Set<Int>, _ work: inout [Int]) {
        var dx: Int?, ah: Int?
        for x in insns.keys.filter({ $0 >= a - 16 && $0 < a }).sorted() {
            let i = insns[x]!
            guard i.mn == "mov", i.ops.count == 2, let v = i.ops[1].immValue else { continue }
            if i.ops[0] == .reg(2, 2) { dx = v }
            if i.ops[0] == .reg(4, 1) { ah = v }
            if i.ops[0] == .reg(0, 2) { ah = v >> 8 }
        }
        if ah == 0x25, let d = dx, !seen.contains(d) { seen.insert(d); funcs.insert(d); work.append(d) }
    }

    private func jumpTable(_ i: X86Insn, _ prev: X86Insn?) -> [Int] {
        var tbl: Int?
        if let m = i.ops.first?.memValue, m.seg == 1, m.rm != nil { tbl = m.offset }
        else if case let .reg(r, 2)? = i.ops.first, let p = prev, p.mn == "mov", p.ops.count == 2,
                let src = p.ops[1].memValue, src.seg == 1, p.ops[0] == .reg(r, 2) { tbl = src.offset }
        guard var cur = tbl else { return [] }
        var out: [Int] = [], lowest = 0x10000
        while cur + 2 <= 0x10000, cur < lowest, out.count < 256 {
            let v = image.csWord(cur)
            guard v > 0, v < 0x10000, insn(v) != nil else { break }
            out.append(v)
            lowest = min(lowest, v)
            cur += 2
        }
        return out
    }
}
