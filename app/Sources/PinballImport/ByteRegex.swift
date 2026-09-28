// A small backtracking regular-expression engine over bytes with Python `re` semantics
// (bytes patterns, DOTALL), so the extraction patterns of tools/*.py can be carried over
// literally: `\xNN` escapes, `.`, classes `[...]`, groups `(...)` / `(?:...)`, alternation,
// `? * + {m,n}` (greedy), backreferences `\1`..`\9`, `^` and `$` (end, or before a final
// newline, as in Python).
//
// Patterns are given as bytes, exactly like Python's `rb"..."` + `struct.pack(...)`
// concatenations: a raw byte that happens to be a regex metacharacter keeps its meaning
// (tools/collision.py builds a few patterns that way), `ByteRegex.literal` escapes.
import Foundation

public struct ByteRegexError: Error, CustomStringConvertible {
    public var message: String
    public var description: String { "byte regex: \(message)" }
}

public final class ByteRegex: @unchecked Sendable {
    indirect enum Node {
        case byte(UInt8)
        case any
        case set([Bool])
        case group(Int?, [[Node]])      // capture index (1-based) or nil
        case rep(Node, Int, Int)        // min, max (Int.max = unbounded), greedy
        case backref(Int)
        case start
        case end
    }

    let seq: [Node]
    let groupCount: Int
    /// Bytes a match can start with (nil = any).
    let first: [Bool]?

    public struct Match {
        /// Absolute offsets into the searched buffer.
        public let range: Range<Int>
        let caps: [Int]      // 2 per group, -1 = unset
        let data: [UInt8]
        public var start: Int { range.lowerBound }
        public var end: Int { range.upperBound }
        public func group(_ i: Int) -> Range<Int>? {
            let s = caps[2 * (i - 1)], e = caps[2 * (i - 1) + 1]
            return s < 0 ? nil : s..<e
        }
        public func bytes(_ i: Int) -> [UInt8]? { group(i).map { Array(data[$0]) } }
        /// Little-endian u16 of a 2-byte group.
        public func u16(_ i: Int) -> Int {
            let r = group(i)!
            return Int(data[r.lowerBound]) | Int(data[r.lowerBound + 1]) << 8
        }
        public func s16(_ i: Int) -> Int { let v = u16(i); return v >= 0x8000 ? v - 0x10000 : v }
        public func u8(_ i: Int) -> Int { Int(data[group(i)!.lowerBound]) }
        public func s8(_ i: Int) -> Int { let v = u8(i); return v >= 0x80 ? v - 0x100 : v }
        public func has(_ i: Int) -> Bool { group(i) != nil }
        public var length: Int { range.count }
    }

    public convenience init(_ pattern: String) throws {
        try self.init(bytes: Array(pattern.utf8))
    }

    public init(bytes p: [UInt8]) throws {
        var parser = Parser(p: p)
        let alts = try parser.parseAlternation()
        guard parser.i == p.count else { throw ByteRegexError(message: "unbalanced ')' at \(parser.i)") }
        seq = alts.count == 1 ? alts[0] : [.group(nil, alts)]
        groupCount = parser.groups
        first = ByteRegex.firstSet(seq)
    }

    /// `\xNN` escape text for literal bytes (re.escape / w() in the Python tools).
    public static func literal(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "\\x%02x", $0) }.joined()
    }
    /// `\xLL\xHH` for a 16-bit little-endian word.
    public static func word(_ v: Int) -> String { literal([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }

    // MARK: parsing

    struct Parser {
        let p: [UInt8]
        var i = 0
        var groups = 0

        mutating func parseAlternation() throws -> [[Node]] {
            var alts: [[Node]] = [try parseSequence()]
            while i < p.count, p[i] == UInt8(ascii: "|") {
                i += 1
                alts.append(try parseSequence())
            }
            return alts
        }

        mutating func parseSequence() throws -> [Node] {
            var out: [Node] = []
            while i < p.count {
                let c = p[i]
                if c == UInt8(ascii: "|") || c == UInt8(ascii: ")") { break }
                var atom = try parseAtom()
                // quantifiers
                while i < p.count {
                    let q = p[i]
                    var mn = -1, mx = -1
                    if q == UInt8(ascii: "?") { mn = 0; mx = 1; i += 1 }
                    else if q == UInt8(ascii: "*") { mn = 0; mx = Int.max; i += 1 }
                    else if q == UInt8(ascii: "+") { mn = 1; mx = Int.max; i += 1 }
                    else if q == UInt8(ascii: "{"), let (a, b, len) = braces(at: i) { mn = a; mx = b; i += len }
                    else { break }
                    if i < p.count, p[i] == UInt8(ascii: "?") { throw ByteRegexError(message: "lazy quantifiers are not supported") }
                    atom = .rep(atom, mn, mx)
                }
                out.append(atom)
            }
            return out
        }

        /// `{m}`, `{m,}`, `{,n}`, `{m,n}`; anything else is a literal '{' (Python).
        func braces(at s: Int) -> (Int, Int, Int)? {
            var j = s + 1
            var a = "", b = ""
            var comma = false
            while j < p.count, p[j] != UInt8(ascii: "}") {
                let c = p[j]
                if c == UInt8(ascii: ",") { if comma { return nil }; comma = true }
                else if c >= 0x30 && c <= 0x39 { if comma { b.append(Character(UnicodeScalar(c))) } else { a.append(Character(UnicodeScalar(c))) } }
                else { return nil }
                j += 1
            }
            guard j < p.count else { return nil }
            if !comma { guard let v = Int(a) else { return nil }; return (v, v, j - s + 1) }
            return (Int(a) ?? 0, b.isEmpty ? Int.max : Int(b)!, j - s + 1)
        }

        mutating func hexByte() throws -> UInt8 {
            guard i + 2 <= p.count, let v = UInt8(String(decoding: p[i..<(i + 2)], as: UTF8.self), radix: 16) else {
                throw ByteRegexError(message: "bad \\x escape at \(i)")
            }
            i += 2
            return v
        }

        mutating func parseAtom() throws -> Node {
            let c = p[i]
            i += 1
            switch c {
            case UInt8(ascii: "."): return .any
            case UInt8(ascii: "^"): return .start
            case UInt8(ascii: "$"): return .end
            case UInt8(ascii: "("):
                var index: Int? = nil
                if i + 1 < p.count, p[i] == UInt8(ascii: "?") {
                    guard p[i + 1] == UInt8(ascii: ":") else { throw ByteRegexError(message: "unsupported group type at \(i)") }
                    i += 2
                } else {
                    groups += 1
                    index = groups
                }
                let alts = try parseAlternation()
                guard i < p.count, p[i] == UInt8(ascii: ")") else { throw ByteRegexError(message: "missing ')'") }
                i += 1
                return .group(index, alts)
            case UInt8(ascii: "["):
                return try parseSet()
            case UInt8(ascii: "\\"):
                guard i < p.count else { throw ByteRegexError(message: "trailing backslash") }
                let e = p[i]
                i += 1
                if e == UInt8(ascii: "x") { return .byte(try hexByte()) }
                if e >= UInt8(ascii: "1") && e <= UInt8(ascii: "9") { return .backref(Int(e) - 0x30) }
                if (e >= 0x30 && e <= 0x39) || (e >= 0x41 && e <= 0x5A) || (e >= 0x61 && e <= 0x7A) {
                    throw ByteRegexError(message: "unsupported escape \\\(Character(UnicodeScalar(e)))")
                }
                return .byte(e)
            case UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "?"):
                throw ByteRegexError(message: "nothing to repeat at \(i - 1)")
            case UInt8(ascii: "{"):
                if braces(at: i - 1) != nil { throw ByteRegexError(message: "nothing to repeat at \(i - 1)") }
                return .byte(c)
            default:
                return .byte(c)
            }
        }

        mutating func parseSet() throws -> Node {
            var set = [Bool](repeating: false, count: 256)
            var negate = false
            if i < p.count, p[i] == UInt8(ascii: "^") { negate = true; i += 1 }
            var firstItem = true
            func item(_ me: inout Parser) throws -> UInt8 {
                let c = me.p[me.i]
                me.i += 1
                if c == UInt8(ascii: "\\") {
                    guard me.i < me.p.count else { throw ByteRegexError(message: "bad class") }
                    let e = me.p[me.i]
                    me.i += 1
                    if e == UInt8(ascii: "x") { return try me.hexByte() }
                    if (e >= 0x30 && e <= 0x39) || (e >= 0x41 && e <= 0x5A) || (e >= 0x61 && e <= 0x7A) {
                        throw ByteRegexError(message: "unsupported class escape")
                    }
                    return e
                }
                return c
            }
            while true {
                guard i < p.count else { throw ByteRegexError(message: "unterminated class") }
                if p[i] == UInt8(ascii: "]") && !firstItem { i += 1; break }
                firstItem = false
                let a = try item(&self)
                if i + 1 < p.count, p[i] == UInt8(ascii: "-"), p[i + 1] != UInt8(ascii: "]") {
                    i += 1
                    let b = try item(&self)
                    guard a <= b else { throw ByteRegexError(message: "bad range") }
                    for v in Int(a)...Int(b) { set[v] = true }
                } else {
                    set[Int(a)] = true
                }
            }
            if negate { set = set.map { !$0 } }
            return .set(set)
        }
    }

    static func firstSet(_ seq: [Node]) -> [Bool]? {
        var acc = [Bool](repeating: false, count: 256)
        for n in seq {
            switch firstOf(n) {
            case .none: return nil
            case let .some((s, canBeEmpty)):
                for v in 0..<256 where s[v] { acc[v] = true }
                if !canBeEmpty { return acc }
            }
        }
        return nil   // the whole sequence can match empty
    }

    /// (first bytes, can match empty) or nil if unknown/any.
    static func firstOf(_ n: Node) -> ([Bool], Bool)? {
        switch n {
        case let .byte(b): var s = [Bool](repeating: false, count: 256); s[Int(b)] = true; return (s, false)
        case .any: return nil
        case let .set(s): return (s, false)
        case .start, .end: return ([Bool](repeating: false, count: 256), true)
        case .backref: return nil
        case let .rep(inner, mn, _):
            guard let (s, e) = firstOf(inner) else { return nil }
            return (s, e || mn == 0)
        case let .group(_, alts):
            var acc = [Bool](repeating: false, count: 256)
            var empty = false
            for a in alts {
                var altEmpty = true
                for n in a {
                    guard let (s, e) = firstOf(n) else { return nil }
                    for v in 0..<256 where s[v] { acc[v] = true }
                    if !e { altEmpty = false; break }
                }
                if altEmpty { empty = true }
            }
            return (acc, empty)
        }
    }

    // MARK: matching

    final class State {
        let d: [UInt8]
        let lo: Int, hi: Int
        var caps: [Int]
        init(d: [UInt8], lo: Int, hi: Int, groups: Int) {
            self.d = d; self.lo = lo; self.hi = hi
            caps = [Int](repeating: -1, count: 2 * groups)
        }
    }

    func matchSeq(_ s: State, _ seq: [Node], _ i: Int, _ pos: Int, _ k: (Int) -> Bool) -> Bool {
        if i == seq.count { return k(pos) }
        return matchNode(s, seq[i], pos) { p in self.matchSeq(s, seq, i + 1, p, k) }
    }

    func matchNode(_ s: State, _ n: Node, _ pos: Int, _ k: (Int) -> Bool) -> Bool {
        switch n {
        case let .byte(b):
            return pos < s.hi && s.d[pos] == b && k(pos + 1)
        case .any:
            return pos < s.hi && k(pos + 1)
        case let .set(set):
            return pos < s.hi && set[Int(s.d[pos])] && k(pos + 1)
        case .start:
            return pos == s.lo && k(pos)
        case .end:
            return (pos == s.hi || (pos == s.hi - 1 && s.d[pos] == 0x0A)) && k(pos)
        case let .backref(g):
            let a = s.caps[2 * (g - 1)], b = s.caps[2 * (g - 1) + 1]
            guard a >= 0 else { return false }
            let len = b - a
            guard pos + len <= s.hi else { return false }
            for j in 0..<len where s.d[a + j] != s.d[pos + j] { return false }
            return k(pos + len)
        case let .group(idx, alts):
            for alt in alts {
                if let g = idx {
                    let oa = s.caps[2 * (g - 1)], ob = s.caps[2 * (g - 1) + 1]
                    let ok = matchSeq(s, alt, 0, pos) { p in
                        let sa = s.caps[2 * (g - 1)], sb = s.caps[2 * (g - 1) + 1]
                        s.caps[2 * (g - 1)] = pos; s.caps[2 * (g - 1) + 1] = p
                        if k(p) { return true }
                        s.caps[2 * (g - 1)] = sa; s.caps[2 * (g - 1) + 1] = sb
                        return false
                    }
                    if ok { return true }
                    s.caps[2 * (g - 1)] = oa; s.caps[2 * (g - 1) + 1] = ob
                } else {
                    if matchSeq(s, alt, 0, pos, k) { return true }
                }
            }
            return false
        case let .rep(inner, mn, mx):
            func step(_ count: Int, _ p: Int) -> Bool {
                if count < mx {
                    let more = matchNode(s, inner, p) { q in q != p && step(count + 1, q) }
                    if more { return true }
                }
                return count >= mn && k(p)
            }
            return step(0, pos)
        }
    }

    /// Match anchored at `pos`, within `range` (`$` = range end).
    public func match(_ d: [UInt8], at pos: Int, in range: Range<Int>? = nil) -> Match? {
        let r = range ?? 0..<d.count
        let s = State(d: d, lo: r.lowerBound, hi: r.upperBound, groups: groupCount)
        var endPos = -1
        if matchSeq(s, seq, 0, pos, { p in endPos = p; return true }) {
            return Match(range: pos..<endPos, caps: s.caps, data: d)
        }
        return nil
    }

    /// First match in `range` (Python `re.search` over `d[range]`); offsets are absolute.
    public func search(_ d: [UInt8], in range: Range<Int>? = nil) -> Match? {
        var it = matches(d, in: range)
        return it.next()
    }

    /// All non-overlapping matches (Python `re.finditer`); offsets are absolute.
    public func all(_ d: [UInt8], in range: Range<Int>? = nil) -> [Match] {
        var out: [Match] = []
        var it = matches(d, in: range)
        while let m = it.next() { out.append(m) }
        return out
    }

    public struct Iterator: IteratorProtocol {
        let re: ByteRegex
        let d: [UInt8]
        let lo: Int, hi: Int
        var pos: Int
        public mutating func next() -> Match? {
            let s = State(d: d, lo: lo, hi: hi, groups: re.groupCount)
            while pos <= hi {
                let p = pos
                if let f = re.first {
                    if p >= hi || !f[Int(d[p])] { pos += 1; continue }
                }
                for j in 0..<s.caps.count { s.caps[j] = -1 }
                var endPos = -1
                if re.matchSeq(s, re.seq, 0, p, { e in endPos = e; return true }) {
                    pos = endPos > p ? endPos : endPos + 1
                    return Match(range: p..<endPos, caps: s.caps, data: d)
                }
                pos += 1
            }
            return nil
        }
    }

    public func matches(_ d: [UInt8], in range: Range<Int>? = nil) -> Iterator {
        let r = range ?? 0..<d.count
        let lo = max(0, min(r.lowerBound, d.count)), hi = max(lo, min(r.upperBound, d.count))
        return Iterator(re: self, d: d, lo: lo, hi: hi, pos: lo)
    }
}

/// Compiled-pattern cache (patterns are fixed strings; many are used once per table).
final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    private var cache: [[UInt8]: ByteRegex] = [:]
    private let lock = NSLock()
    func get(_ p: [UInt8]) throws -> ByteRegex {
        lock.lock(); defer { lock.unlock() }
        if let r = cache[p] { return r }
        let r = try ByteRegex(bytes: p)
        cache[p] = r
        return r
    }
}

/// `rx("...")`: compile (cached). Patterns in this module are fixed and tested; a bad one is a bug.
func rx(_ p: String) -> ByteRegex {
    do { return try RegexCache.shared.get(Array(p.utf8)) } catch { fatalError("\(error) in \(p)") }
}

func rx(bytes p: [UInt8]) throws -> ByteRegex { try RegexCache.shared.get(p) }
