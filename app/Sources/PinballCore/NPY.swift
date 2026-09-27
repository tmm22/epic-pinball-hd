import Foundation

/// Minimal reader for NumPy `.npy` files holding a 2-D `uint8` array.
///
/// Format (numpy/lib/format.py): 6-byte magic `\x93NUMPY`, 1-byte major and
/// 1-byte minor version, then a little-endian header length (u16 for v1.x,
/// u32 for v2.x/v3.x), then an ASCII (v3: UTF-8) Python dict literal with keys
/// `descr`, `fortran_order`, `shape`, padded with spaces and terminated by `\n`.
/// Raw array data follows immediately.
public struct NPYArray2D: Sendable, Equatable {
    public let rows: Int
    public let columns: Int
    /// Row-major (C order) bytes, `rows * columns` long.
    public let data: [UInt8]

    public init(rows: Int, columns: Int, data: [UInt8]) {
        self.rows = rows
        self.columns = columns
        self.data = data
    }

    public subscript(row: Int, column: Int) -> UInt8 {
        data[row * columns + column]
    }
}

public enum NPYError: Error, Equatable, CustomStringConvertible {
    case tooShort
    case badMagic
    case unsupportedVersion(UInt8, UInt8)
    case malformedHeader(String)
    case unsupportedDType(String)
    case unsupportedShape(String)
    case truncatedData(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .tooShort: return "file is too short to be a .npy array"
        case .badMagic: return "missing \\x93NUMPY magic - not a .npy file"
        case let .unsupportedVersion(a, b): return "unsupported .npy version \(a).\(b)"
        case let .malformedHeader(s): return "malformed .npy header: \(s)"
        case let .unsupportedDType(s): return "unsupported dtype '\(s)' (need uint8: '|u1')"
        case let .unsupportedShape(s): return "unsupported shape \(s) (need a 2-D C-order array)"
        case let .truncatedData(e, a): return "array data truncated: expected \(e) bytes, found \(a)"
        }
    }
}

public enum NPYReader {
    static let magic: [UInt8] = [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59] // \x93NUMPY

    public static func read(contentsOf url: URL) throws -> NPYArray2D {
        try parse(Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> NPYArray2D {
        let bytes = [UInt8](data)
        guard bytes.count >= 10 else { throw NPYError.tooShort }
        guard Array(bytes[0..<6]) == magic else { throw NPYError.badMagic }
        let major = bytes[6], minor = bytes[7]
        let headerLength: Int
        let headerStart: Int
        switch major {
        case 1:
            headerLength = Int(bytes[8]) | Int(bytes[9]) << 8
            headerStart = 10
        case 2, 3:
            guard bytes.count >= 12 else { throw NPYError.tooShort }
            headerLength = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
            headerStart = 12
        default:
            throw NPYError.unsupportedVersion(major, minor)
        }
        let dataStart = headerStart + headerLength
        guard dataStart <= bytes.count else { throw NPYError.tooShort }
        guard let header = String(bytes: bytes[headerStart..<dataStart], encoding: major == 3 ? .utf8 : .ascii) else {
            throw NPYError.malformedHeader("header is not text")
        }

        let descr = try stringValue(for: "descr", in: header)
        // uint8 has no byte order: numpy writes '|u1'; accept the equivalent spellings.
        guard ["|u1", "u1", "<u1", ">u1", "=u1", "|B", "B"].contains(descr) else {
            throw NPYError.unsupportedDType(descr)
        }
        let fortran = try rawValue(for: "fortran_order", in: header)
        guard fortran == "False" else { throw NPYError.unsupportedShape("fortran_order=\(fortran)") }

        let shapeText = try tupleValue(for: "shape", in: header)
        let dims = shapeText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let ints = dims.compactMap { Int($0) }
        guard ints.count == 2, dims.count == 2, ints.allSatisfy({ $0 > 0 }) else {
            throw NPYError.unsupportedShape("(\(shapeText))")
        }
        let expected = ints[0] * ints[1]
        let available = bytes.count - dataStart
        guard available >= expected else { throw NPYError.truncatedData(expected: expected, actual: available) }
        return NPYArray2D(rows: ints[0], columns: ints[1], data: Array(bytes[dataStart..<(dataStart + expected)]))
    }

    // MARK: - tiny dict-literal helpers (the header is always a flat dict)

    private static func valueStart(for key: String, in header: String) throws -> String.Index {
        for quote in ["'", "\""] {
            if let r = header.range(of: "\(quote)\(key)\(quote)") {
                guard let colon = header[r.upperBound...].firstIndex(of: ":") else { break }
                var i = header.index(after: colon)
                while i < header.endIndex, header[i] == " " { i = header.index(after: i) }
                return i
            }
        }
        throw NPYError.malformedHeader("missing key '\(key)'")
    }

    private static func stringValue(for key: String, in header: String) throws -> String {
        let start = try valueStart(for: key, in: header)
        guard start < header.endIndex else { throw NPYError.malformedHeader("no value for '\(key)'") }
        let quote = header[start]
        guard quote == "'" || quote == "\"" else { throw NPYError.malformedHeader("'\(key)' is not a string") }
        let bodyStart = header.index(after: start)
        guard let end = header[bodyStart...].firstIndex(of: quote) else {
            throw NPYError.malformedHeader("unterminated string for '\(key)'")
        }
        return String(header[bodyStart..<end])
    }

    private static func rawValue(for key: String, in header: String) throws -> String {
        let start = try valueStart(for: key, in: header)
        let end = header[start...].firstIndex(where: { $0 == "," || $0 == "}" }) ?? header.endIndex
        return header[start..<end].trimmingCharacters(in: .whitespaces)
    }

    private static func tupleValue(for key: String, in header: String) throws -> String {
        let start = try valueStart(for: key, in: header)
        guard start < header.endIndex, header[start] == "(" else {
            throw NPYError.malformedHeader("'\(key)' is not a tuple")
        }
        let bodyStart = header.index(after: start)
        guard let end = header[bodyStart...].firstIndex(of: ")") else {
            throw NPYError.malformedHeader("unterminated tuple for '\(key)'")
        }
        return String(header[bodyStart..<end])
    }
}
