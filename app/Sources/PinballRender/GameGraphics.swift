import CoreGraphics
import Foundation
import ImageIO
import PinballCore

/// A palette-indexed rectangle. `x`,`y` is the record's own playfield position (planar
/// records are position-bound; digits get theirs at runtime).
public struct IndexedSprite: Sendable, Equatable {
    public var name: String
    public var x: Int, y: Int, w: Int, h: Int
    /// Row-major palette indices, `w * h`.
    public var pixels: [UInt8]
    public init(name: String, x: Int, y: Int, w: Int, h: Int, pixels: [UInt8]) {
        self.name = name; self.x = x; self.y = y; self.w = w; self.h = h; self.pixels = pixels
    }
}

/// Non-playfield graphics for one table (docs/formats/sprites.md), decoded as palette
/// indices so palette effects (lamp colours 200-254, DAC 255 for messages) apply to them.
///
/// Source of truth is the user's `EPn.EXE`, read at the `file_offset`s that
/// `tools/sprites.py` recorded in `sprites.json`. Without the EXE the RGBA PNGs are mapped
/// back to indices through the table palette (first matching entry; lamp colours that
/// duplicate other entries can then come out as the wrong index). Fonts need the EXE.
public final class GameGraphics: @unchecked Sendable {
    /// Lamp slot k owns pointer-table entries 2k ("a") and 2k+1 ("b") (cs:4882).
    public let lampA: [IndexedSprite?]
    public let lampB: [IndexedSprite?]
    /// Per lamp: true if record "a" matches the baked playfield better than "b"
    /// (sprites.json playfield_match), i.e. drawing "a" leaves the table as extracted.
    public let lampRestIsA: [Bool]
    public let byName: [String: IndexedSprite]
    /// Big score digits 0-9 then blank (cs:4A3F table), empty if the table has none.
    public let digits: [IndexedSprite]
    public let pause: IndexedSprite?
    /// Where the pause banner goes in the strip (sprites.json display_x/y).
    public let pausePosition: (x: Int, y: Int)
    public let plunger: IndexedSprite?
    /// font8: 8 bytes per glyph from ' ' (MSB = leftmost); font5: 5 bytes per glyph.
    public let font8: [[UInt8]]
    public let font5: [[UInt8]]
    /// EP9-13 second 5x5 font (used by their AH=2 dot text).
    public let font5b: [[UInt8]]
    public let displayRows: Int?
    public let codeSegment: Int
    public let dataSegment: Int
    public let table: Int
    /// "exe" or "png".
    public let source: String
    public let warnings: [String]

    init(lampA: [IndexedSprite?], lampB: [IndexedSprite?], lampRestIsA: [Bool], byName: [String: IndexedSprite], digits: [IndexedSprite],
         pause: IndexedSprite?, pausePosition: (Int, Int), plunger: IndexedSprite?, font8: [[UInt8]], font5: [[UInt8]],
         font5b: [[UInt8]], displayRows: Int?, codeSegment: Int, dataSegment: Int, table: Int, source: String, warnings: [String]) {
        self.lampA = lampA; self.lampB = lampB; self.lampRestIsA = lampRestIsA; self.byName = byName; self.digits = digits
        self.pause = pause; self.pausePosition = pausePosition; self.plunger = plunger
        self.font8 = font8; self.font5 = font5; self.font5b = font5b; self.displayRows = displayRows
        self.codeSegment = codeSegment; self.dataSegment = dataSegment; self.table = table
        self.source = source; self.warnings = warnings
    }

    public var lampCount: Int { max(lampA.count, lampB.count) }

    // MARK: decoding

    /// Planar Mode X record (sprites.md 2.1): u16 x, y, w4, h, then per row plane0..3 of w4 bytes.
    static func decodePlanar(_ exe: TableExe, at o: Int, name: String) -> IndexedSprite? {
        let x = exe.u16(o), y = exe.u16(o + 2), w4 = exe.u16(o + 4), h = exe.u16(o + 6)
        guard w4 > 0, h > 0, w4 <= 200, h <= 400, o + 8 + w4 * 4 * h <= exe.bytes.count else { return nil }
        let w = w4 * 4
        var px = [UInt8](repeating: 0, count: w * h)
        var p = o + 8
        for r in 0..<h {
            for plane in 0..<4 {
                for i in 0..<w4 { px[r * w + 4 * i + plane] = exe.bytes[p]; p += 1 }
            }
        }
        return IndexedSprite(name: name, x: x, y: y, w: w, h: h, pixels: px)
    }

    /// Chunky banner (2.2): u16 x, y, w, h then w*h bytes.
    static func decodeChunky(_ exe: TableExe, at o: Int, name: String) -> IndexedSprite? {
        let x = exe.u16(o), y = exe.u16(o + 2), w = exe.u16(o + 4), h = exe.u16(o + 6)
        guard w > 0, h > 0, w <= 320, h <= 240, o + 8 + w * h <= exe.bytes.count else { return nil }
        return IndexedSprite(name: name, x: x, y: y, w: w, h: h, pixels: Array(exe.bytes[(o + 8)..<(o + 8 + w * h)]))
    }

    /// PNG fallback: RGBA -> first palette index with the same RGB (alpha 0 -> index 0).
    static func decodePNGIndexed(_ url: URL, palette: Palette, name: String, x: Int, y: Int) -> IndexedSprite? {
        guard let img = FlipperSpriteSet.decodePNG(url) else { return nil }
        var lut: [UInt32: UInt8] = [:]
        for i in stride(from: 255, through: 0, by: -1) {
            let e = palette[i]
            lut[UInt32(e.r) << 16 | UInt32(e.g) << 8 | UInt32(e.b)] = UInt8(i)
        }
        var px = [UInt8](repeating: 0, count: img.w * img.h)
        for i in 0..<px.count {
            let r = img.rgba[i * 4], g = img.rgba[i * 4 + 1], b = img.rgba[i * 4 + 2], a = img.rgba[i * 4 + 3]
            px[i] = a == 0 ? 0 : (lut[UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)] ?? 0)
        }
        return IndexedSprite(name: name, x: x, y: y, w: img.w, h: img.h, pixels: px)
    }

    static func hex(_ v: Any?) -> Int? {
        if let s = v as? String { return s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s) }
        if let n = v as? Int { return n }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    /// Loads `<tableDir>/sprites/sprites.json` and decodes everything from `exe` (preferred)
    /// or the PNGs next to it.
    public static func load(tableDirectory dir: URL, palette: Palette, exe: TableExe?) throws -> GameGraphics {
        let spriteDir = dir.appendingPathComponent("sprites", isDirectory: true)
        let jsonURL = spriteDir.appendingPathComponent("sprites.json")
        guard let data = try? Data(contentsOf: jsonURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["sprites"] as? [[String: Any]] else {
            throw RenderError.resourceCreation("cannot read \(jsonURL.path) (run tools/sprites.py)")
        }
        var warnings: [String] = []
        let table = hex(root["table"]) ?? 0
        let useEXE = exe != nil
        var byName: [String: IndexedSprite] = [:]
        var lampA: [Int: IndexedSprite] = [:], lampB: [Int: IndexedSprite] = [:]
        var matchA: [Int: Double] = [:], matchB: [Int: Double] = [:]
        var font8: [Int: [UInt8]] = [:], font5: [Int: [UInt8]] = [:], font5b: [Int: [UInt8]] = [:]
        var pausePos = (64, 3)
        var digitNames: [String] = []
        for s in list {
            guard let name = s["name"] as? String, let format = s["format"] as? String else { continue }
            let group = s["group"] as? String ?? ""
            let off = hex(s["file_offset"])
            var sprite: IndexedSprite?
            switch format {
            case "planar":
                if let exe, let off { sprite = decodePlanar(exe, at: off, name: name) }
                else if !useEXE {
                    sprite = decodePNGIndexed(spriteDir.appendingPathComponent(name + ".png"), palette: palette, name: name,
                                              x: hex(s["x"]) ?? 0, y: hex(s["y"]) ?? 0)
                }
            case "chunky":
                if let exe, let off { sprite = decodeChunky(exe, at: off, name: name) }
                else if !useEXE {
                    sprite = decodePNGIndexed(spriteDir.appendingPathComponent(name + ".png"), palette: palette, name: name, x: 0, y: 0)
                }
                if let dx = hex(s["display_x"]), let dy = hex(s["display_y"]) { pausePos = (dx, dy) }
            case "font8", "font5":
                guard let exe, let off, let ch = hex(s["char"]) else { continue }
                let n = format == "font8" ? 8 : 5
                let glyph = Array(exe.bytes[off..<min(exe.bytes.count, off + n)])
                if format == "font8" { font8[ch] = glyph } else if name.hasPrefix("font5b") { font5b[ch] = glyph } else { font5[ch] = glyph }
                continue
            default:
                continue
            }
            if group == "lamp", let k = hex(s["lamp"]), let m = (s["playfield_match"] as? NSNumber)?.doubleValue {
                if (s["state"] as? String)?.hasPrefix("a") == true { matchA[k] = m } else { matchB[k] = m }
            }
            guard let sp = sprite else {
                if format == "planar" || format == "chunky" { warnings.append("\(name): could not decode") }
                continue
            }
            byName[name] = sp
            if group == "lamp", let k = hex(s["lamp"]) {
                if (s["state"] as? String)?.hasPrefix("a") == true { lampA[k] = sp } else { lampB[k] = sp }
            }
            if group == "digit" { digitNames.append(name) }
        }
        if !useEXE { warnings.append("no EPn.EXE: sprites mapped from PNG colours, fonts unavailable (pass --original DIR)") }
        let nLamps = (max(lampA.keys.max() ?? -1, lampB.keys.max() ?? -1)) + 1
        func glyphs(_ d: [Int: [UInt8]], n: Int) -> [[UInt8]] {
            guard let hi = d.keys.max() else { return [] }
            return (0x20...hi).map { d[$0] ?? [UInt8](repeating: 0, count: n) }
        }
        let digits: [IndexedSprite] = (0..<10).compactMap { byName["digit_\($0)"] } + [byName["digit_blank"]].compactMap { $0 }
        let cs = hex(root["code_segment"]) ?? 0, ds = hex(root["data_segment"]) ?? 0
        return GameGraphics(lampA: (0..<max(0, nLamps)).map { lampA[$0] }, lampB: (0..<max(0, nLamps)).map { lampB[$0] },
                            lampRestIsA: (0..<max(0, nLamps)).map { (matchA[$0] ?? 0) >= (matchB[$0] ?? 0) },
                            byName: byName, digits: digits.count == 11 ? digits : [], pause: byName["pause"],
                            pausePosition: pausePos, plunger: byName["plunger"],
                            font8: glyphs(font8, n: 8), font5: glyphs(font5, n: 5), font5b: glyphs(font5b, n: 5),
                            displayRows: hex(root["display_rows"]), codeSegment: cs, dataSegment: ds, table: table,
                            source: useEXE ? "exe" : "png", warnings: warnings)
    }
}
