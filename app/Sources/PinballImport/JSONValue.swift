// Ordered JSON values with Python `json` compatible output, so the library files match what
// tools/*.py write (key order, separators, float spelling, ASCII escaping) and can be diffed.
import Foundation

public indirect enum JSONValue: Sendable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public var description: String { serialize(self, style: .python) }
}

/// A JSON object that keeps insertion order (Python dicts do).
public struct JSONObject: Sendable {
    public private(set) var keys: [String] = []
    public private(set) var values: [String: JSONValue] = [:]
    public init() {}
    public init(_ pairs: [(String, JSONValue)]) { for (k, v) in pairs { self[k] = v } }
    public subscript(key: String) -> JSONValue? {
        get { values[key] }
        set {
            if let v = newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = v
            } else if values[key] != nil {
                values[key] = nil
                keys.removeAll { $0 == key }
            }
        }
    }
    public var pairs: [(String, JSONValue)] { keys.map { ($0, values[$0]!) } }
    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }
}

extension JSONValue: Equatable {
    /// Structural equality: objects compare as unordered maps, int and double compare by value.
    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.double(x), .double(y)): return x == y
        case let (.int(x), .double(y)), let (.double(y), .int(x)): return Double(x) == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)):
            guard x.count == y.count else { return false }
            for k in x.keys { guard let v = y.values[k], v == x.values[k]! else { return false } }
            return true
        default: return false
        }
    }
}

extension JSONObject: Equatable {
    public static func == (a: JSONObject, b: JSONObject) -> Bool { JSONValue.object(a) == JSONValue.object(b) }
}

// MARK: convenience

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }
    public subscript(index: Int) -> JSONValue? {
        if case let .array(a) = self, index >= 0, index < a.count { return a[index] }
        return nil
    }
    public var intValue: Int? {
        switch self {
        case let .int(v): return v
        case let .double(d) where d == d.rounded(): return Int(d)
        case let .bool(b): return b ? 1 : 0
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self { case let .int(v): return Double(v); case let .double(d): return d; default: return nil }
    }
    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case let .array(a) = self { return a }; return nil }
    public var objectValue: JSONObject? { if case let .object(o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }
    /// Python truthiness.
    public var truthy: Bool {
        switch self {
        case .null: return false
        case let .bool(b): return b
        case let .int(i): return i != 0
        case let .double(d): return d != 0
        case let .string(s): return !s.isEmpty
        case let .array(a): return !a.isEmpty
        case let .object(o): return !o.isEmpty
        }
    }
    /// "0x1a2b" -> 0x1a2b (Python `int(s, 16)`); ints pass through.
    public var hexInt: Int? {
        if let s = stringValue { return pyInt(s, base: 16) }
        return intValue
    }
}

func pyInt(_ s: String, base: Int) -> Int? {
    var t = s.trimmingCharacters(in: .whitespaces).lowercased()
    var neg = false
    if t.hasPrefix("-") { neg = true; t.removeFirst() }
    if base == 16, t.hasPrefix("0x") { t.removeFirst(2) }
    guard let v = Int(t, radix: base) else { return nil }
    return neg ? -v : v
}

/// Python `hex(v)`.
func pyHex(_ v: Int) -> String { v < 0 ? "-0x" + String(-v, radix: 16) : "0x" + String(v, radix: 16) }

/// Python `round(x, n)` (correctly rounded, ties to even on the exact binary value).
func pyRound(_ x: Double, _ n: Int) -> Double { Double(String(format: "%.\(n)f", x)) ?? x }

// Builders
extension JSONValue {
    static func hex(_ v: Int) -> JSONValue { .string(pyHex(v)) }
    static func hexOrNull(_ v: Int?) -> JSONValue { v.map { .string(pyHex($0)) } ?? .null }
    static func intOrNull(_ v: Int?) -> JSONValue { v.map { .int($0) } ?? .null }
    static func ints(_ a: [Int]) -> JSONValue { .array(a.map { .int($0) }) }
    static func strings(_ a: [String]) -> JSONValue { .array(a.map { .string($0) }) }
    static func obj(_ pairs: [(String, JSONValue)]) -> JSONValue { .object(JSONObject(pairs)) }
}

// MARK: serialisation (Python json.dump)

enum JSONStyle {
    /// json.dump(x): ", " and ": ".
    case python
    /// json.dump(x, separators=(",", ":")).
    case compact
    /// json.dump(x, indent=n).
    case indent(Int)
}

func serialize(_ v: JSONValue, style: JSONStyle) -> String {
    var out = ""
    out.reserveCapacity(4096)
    write(v, style: style, level: 0, into: &out)
    return out
}

private func write(_ v: JSONValue, style: JSONStyle, level: Int, into out: inout String) {
    switch v {
    case .null: out += "null"
    case let .bool(b): out += b ? "true" : "false"
    case let .int(i): out += String(i)
    case let .double(d): out += pyFloat(d)
    case let .string(s): writeString(s, into: &out)
    case let .array(a):
        if a.isEmpty { out += "[]"; return }
        out += "["
        switch style {
        case .python, .compact:
            let sep = { if case .compact = style { return "," } else { return ", " } }()
            for (i, x) in a.enumerated() {
                if i > 0 { out += sep }
                write(x, style: style, level: level + 1, into: &out)
            }
        case let .indent(n):
            let pad = String(repeating: " ", count: n * (level + 1))
            for (i, x) in a.enumerated() {
                out += i > 0 ? ",\n" : "\n"
                out += pad
                write(x, style: style, level: level + 1, into: &out)
            }
            out += "\n" + String(repeating: " ", count: n * level)
        }
        out += "]"
    case let .object(o):
        if o.isEmpty { out += "{}"; return }
        out += "{"
        switch style {
        case .python, .compact:
            let compact: Bool = { if case .compact = style { return true } else { return false } }()
            for (i, (k, x)) in o.pairs.enumerated() {
                if i > 0 { out += compact ? "," : ", " }
                writeString(k, into: &out)
                out += compact ? ":" : ": "
                write(x, style: style, level: level + 1, into: &out)
            }
        case let .indent(n):
            let pad = String(repeating: " ", count: n * (level + 1))
            for (i, (k, x)) in o.pairs.enumerated() {
                out += i > 0 ? ",\n" : "\n"
                out += pad
                writeString(k, into: &out)
                out += ": "
                write(x, style: style, level: level + 1, into: &out)
            }
            out += "\n" + String(repeating: " ", count: n * level)
        }
        out += "}"
    }
}

/// Python float repr.
func pyFloat(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
    var s = "\(d)"   // Swift: shortest round-trip, e.g. "1.0", "0.76", "1e-05"
    if s.contains("e") {
        // Python: 1e-05, 1e+16, 1.5e-07
        let parts = s.split(separator: "e")
        var mant = String(parts[0]), ex = String(parts[1])
        if mant.hasSuffix(".0") { mant.removeLast(2) }
        var sign = "+"
        if ex.hasPrefix("-") { sign = "-"; ex.removeFirst() } else if ex.hasPrefix("+") { ex.removeFirst() }
        if ex.count < 2 { ex = "0" + ex }
        s = mant + "e" + sign + ex
    }
    return s
}

private func writeString(_ s: String, into out: inout String) {
    out += "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if u.value < 0x20 || u.value > 0x7E {
                if u.value > 0xFFFF {
                    let v = u.value - 0x10000
                    out += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
                } else {
                    out += String(format: "\\u%04x", u.value)
                }
            } else {
                out.unicodeScalars.append(u)
            }
        }
    }
    out += "\""
}

// MARK: parsing

struct JSONParseError: Error, CustomStringConvertible {
    var offset: Int
    var message: String
    var description: String { "JSON parse error at byte \(offset): \(message)" }
}

func parseJSON(_ data: Data) throws -> JSONValue {
    var p = JSONParser(b: [UInt8](data))
    p.ws()
    let v = try p.value()
    p.ws()
    guard p.i == p.b.count else { throw JSONParseError(offset: p.i, message: "trailing data") }
    return v
}

func parseJSON(_ s: String) throws -> JSONValue { try parseJSON(Data(s.utf8)) }

private struct JSONParser {
    let b: [UInt8]
    var i = 0

    mutating func ws() { while i < b.count, [0x20, 0x0A, 0x0D, 0x09].contains(b[i]) { i += 1 } }

    mutating func value() throws -> JSONValue {
        guard i < b.count else { throw JSONParseError(offset: i, message: "unexpected end") }
        switch b[i] {
        case UInt8(ascii: "{"):
            i += 1; ws()
            var o = JSONObject()
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
            while true {
                ws()
                guard case let .string(k) = try value() else { throw JSONParseError(offset: i, message: "object key") }
                ws()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw JSONParseError(offset: i, message: "expected ':'") }
                i += 1; ws()
                o[k] = try value()
                ws()
                guard i < b.count else { throw JSONParseError(offset: i, message: "unterminated object") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                throw JSONParseError(offset: i, message: "expected ',' or '}'")
            }
        case UInt8(ascii: "["):
            i += 1; ws()
            var a: [JSONValue] = []
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
            while true {
                ws()
                a.append(try value())
                ws()
                guard i < b.count else { throw JSONParseError(offset: i, message: "unterminated array") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                throw JSONParseError(offset: i, message: "expected ',' or ']'")
            }
        case UInt8(ascii: "\""):
            i += 1
            var scalars = String.UnicodeScalarView()
            var bytes: [UInt8] = []
            func flush() { if !bytes.isEmpty { scalars.append(contentsOf: String(decoding: bytes, as: UTF8.self).unicodeScalars); bytes.removeAll() } }
            while true {
                guard i < b.count else { throw JSONParseError(offset: i, message: "unterminated string") }
                let c = b[i]
                i += 1
                if c == UInt8(ascii: "\"") { break }
                if c == UInt8(ascii: "\\") {
                    flush()
                    guard i < b.count else { throw JSONParseError(offset: i, message: "bad escape") }
                    let e = b[i]; i += 1
                    switch e {
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "u"):
                        guard i + 4 <= b.count, var v = UInt32(String(decoding: b[i..<(i + 4)], as: UTF8.self), radix: 16) else {
                            throw JSONParseError(offset: i, message: "bad \\u escape")
                        }
                        i += 4
                        if (0xD800..<0xDC00).contains(v), i + 6 <= b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u"),
                           let lo = UInt32(String(decoding: b[(i + 2)..<(i + 6)], as: UTF8.self), radix: 16), (0xDC00..<0xE000).contains(lo) {
                            v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)
                            i += 6
                        }
                        scalars.append(UnicodeScalar(v) ?? "\u{FFFD}")
                    default: scalars.append(UnicodeScalar(e))
                    }
                } else {
                    bytes.append(c)
                }
            }
            flush()
            return .string(String(scalars))
        case UInt8(ascii: "t"):
            guard b[i..<min(b.count, i + 4)].elementsEqual(Array("true".utf8)) else { throw JSONParseError(offset: i, message: "bad literal") }
            i += 4; return .bool(true)
        case UInt8(ascii: "f"):
            guard b[i..<min(b.count, i + 5)].elementsEqual(Array("false".utf8)) else { throw JSONParseError(offset: i, message: "bad literal") }
            i += 5; return .bool(false)
        case UInt8(ascii: "n"):
            guard b[i..<min(b.count, i + 4)].elementsEqual(Array("null".utf8)) else { throw JSONParseError(offset: i, message: "bad literal") }
            i += 4; return .null
        case UInt8(ascii: "N"):
            guard b[i..<min(b.count, i + 3)].elementsEqual(Array("NaN".utf8)) else { throw JSONParseError(offset: i, message: "bad literal") }
            i += 3; return .double(.nan)
        default:
            let s = i
            if b[i] == UInt8(ascii: "-") { i += 1 }
            var isFloat = false
            while i < b.count {
                let c = b[i]
                if c >= 0x30 && c <= 0x39 { i += 1 }
                else if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") || c == UInt8(ascii: "+") || c == UInt8(ascii: "-") { isFloat = true; i += 1 }
                else { break }
            }
            let t = String(decoding: b[s..<i], as: UTF8.self)
            if !isFloat, let v = Int(t) { return .int(v) }
            guard let d = Double(t) else { throw JSONParseError(offset: s, message: "bad number '\(t)'") }
            return .double(d)
        }
    }
}
