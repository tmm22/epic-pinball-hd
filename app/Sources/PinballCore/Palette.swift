import Foundation

/// 256-entry RGB palette, 8 bits per channel.
///
/// The game's in-game palette is 768 bytes of 8-bit RGB stored in the data
/// segment; indices 200-254 are lamp colours rewritten at runtime (see
/// docs/formats/README.md). Keeping the palette separate from the indexed
/// playfield lets the renderer animate lamps by editing entries only.
public struct Palette: Sendable, Equatable {
    public struct RGB: Sendable, Equatable {
        public var r: UInt8, g: UInt8, b: UInt8
        public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
    }

    public static let count = 256
    /// Palette indices the original rewrites at runtime for lamp effects.
    public static let lampRange: ClosedRange<Int> = 200...254

    public var entries: [RGB]

    public init(entries: [RGB]) throws {
        guard entries.count == Palette.count else { throw PaletteError.wrongCount(entries.count) }
        self.entries = entries
    }

    public subscript(index: Int) -> RGB {
        get { entries[index] }
        set { entries[index] = newValue }
    }

    /// RGBA8 bytes (alpha 255), 1024 bytes - the layout the GPU palette texture uses.
    public var rgba8: [UInt8] {
        var out = [UInt8](); out.reserveCapacity(Palette.count * 4)
        for e in entries { out += [e.r, e.g, e.b, 255] }
        return out
    }

    /// Parses `palette.json` as written by tools/extract.py: a JSON array of
    /// 256 `[r, g, b]` arrays with 0-255 components.
    public static func parseJSON(_ data: Data) throws -> Palette {
        let raw: [[Int]]
        do { raw = try JSONDecoder().decode([[Int]].self, from: data) } catch {
            throw PaletteError.notJSON(String(describing: error))
        }
        guard raw.count == count else { throw PaletteError.wrongCount(raw.count) }
        var entries: [RGB] = []
        for (i, c) in raw.enumerated() {
            guard c.count == 3, c.allSatisfy({ (0...255).contains($0) }) else {
                throw PaletteError.badEntry(index: i)
            }
            entries.append(RGB(r: UInt8(c[0]), g: UInt8(c[1]), b: UInt8(c[2])))
        }
        return try Palette(entries: entries)
    }

    public static func load(contentsOf url: URL) throws -> Palette {
        try parseJSON(Data(contentsOf: url))
    }
}

public enum PaletteError: Error, Equatable, CustomStringConvertible {
    case notJSON(String)
    case wrongCount(Int)
    case badEntry(index: Int)

    public var description: String {
        switch self {
        case let .notJSON(e): return "palette is not a JSON array of [r,g,b] arrays (\(e))"
        case let .wrongCount(n): return "palette has \(n) entries, expected 256"
        case let .badEntry(i): return "palette entry \(i) is not three integers in 0...255"
        }
    }
}
