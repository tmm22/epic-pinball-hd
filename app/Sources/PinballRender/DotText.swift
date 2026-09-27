import Foundation

/// A dot-matrix message as the original's `dmd_message` receives it (EP1 cs:15DE):
/// text bytes (read at runtime from the user's EXE or from the live DS copy the rules
/// patch), AX (AH = font/centring, AL = effect, stored in ds:0B3A) and DI (target offset
/// `y*320 + x` before centring, relative to the visible window in EP1-8 and to the strip
/// in EP9-13).
public struct DotMessage: Sendable, Equatable {
    public var text: [UInt8]
    public var ax: Int
    public var di: Int
    /// Lines appended to the same dot list afterwards by draw_text (font5, cs:59AC) or
    /// draw_text_hi (font8, cs:5926): explicit DI, no centring (rules.json `text` ops).
    public var appended: [DotLine]
    /// Dot colour. EP1-8 always plot DAC 255 (render_frame cs:43D5); EP9-13 store a colour
    /// byte before the call (EP10 ds:00C5), nil = the table's most common one.
    public var colour: UInt8?
    public init(text: [UInt8], ax: Int, di: Int, appended: [DotLine] = [], colour: UInt8? = nil) {
        self.text = text; self.ax = ax; self.di = di; self.appended = appended; self.colour = colour
    }

    public var font: Int { (ax >> 8) & 0xFF }
    public var effect: Int { ax & 0xFF }
}

public struct DotLine: Sendable, Equatable {
    public var text: [UInt8]
    /// true = draw_text_hi (font8, 16 px per character), false = draw_text (font5, 11 px).
    public var font8: Bool
    public var di: Int
    /// Dot colour (EP9-13 strip dots carry one per dot; EP1-8 always plot DAC 255).
    public var colour: UInt8
    public init(text: [UInt8], font8: Bool, di: Int, colour: UInt8 = 255) {
        self.text = text; self.font8 = font8; self.di = di; self.colour = colour
    }
}

/// Dot-list generation, a transcription of dmd_message + the three dot fonts (EP1 cs:15DE,
/// cs:584B font8, cs:58B8 font5, cs:5925 = no-op; EP10 cs:4BF8 = 4-column font5b).
public enum DotText {
    /// Pixel offsets (`y*320 + x`, relative to the target origin), in plotting order.
    /// Returns [] where the original draws nothing (string longer than 31, too wide to centre,
    /// or a font the table does not have).
    public static func dots(_ m: DotMessage, font8: [[UInt8]], font5: [[UInt8]], font5b: [[UInt8]]) -> [Int] {
        var ah = m.font
        var di = m.di
        if ah <= 2 {
            // Centre: cx = strlen (the scan gives up after 31 characters).
            var len = 0
            while len < m.text.count, m.text[len] != 0 {
                len += 1
                if len > 0x1E { return [] }
            }
            let charW = ah == 2 ? 8 : (ah == 0 ? 11 : 16)
            let cx = 0x140 - charW * len
            if cx < 0 { return [] }
            di += cx / 2 + 1
        } else {
            ah -= 3
        }
        // Font geometry: glyph bytes, rows, columns (bits 7..), advance.
        let glyphs: [[UInt8]], rows: Int, cols: Int, advance: Int
        switch ah {
        case 1: glyphs = font8; rows = 7; cols = 7; advance = 16
        case 0: glyphs = font5; rows = 5; cols = 5; advance = 11
        case 2:
            guard !font5b.isEmpty else { return [] }  // EP1-8: cs:5925 is a bare retf
            glyphs = font5b; rows = 5; cols = 4; advance = 8
        default: return []
        }
        guard !glyphs.isEmpty else { return [] }
        var out: [Int] = []
        plot(m.text, glyphs: glyphs, rows: rows, cols: cols, advance: advance, di: di, into: &out)
        return out
    }

    /// Dots of a line appended by draw_text / draw_text_hi (no centring).
    public static func lineDots(_ line: DotLine, font8: [[UInt8]], font5: [[UInt8]]) -> [Int] {
        var out: [Int] = []
        if line.font8 {
            plot(line.text, glyphs: font8, rows: 7, cols: 7, advance: 16, di: line.di, into: &out)
        } else {
            plot(line.text, glyphs: font5, rows: 5, cols: 5, advance: 11, di: line.di, into: &out)
        }
        return out
    }

    static func plot(_ text: [UInt8], glyphs: [[UInt8]], rows: Int, cols: Int, advance: Int, di start: Int, into out: inout [Int]) {
        var di = start
        for var c in text {
            if c == 0 { break }
            if c > 0x60 { c &-= 0x20 }       // lower-case fold (cs:5851)
            let g = Int(c &- 0x20)
            let glyph = g < glyphs.count ? glyphs[g] : []
            for col in 0..<cols {
                for row in 0..<rows where row < glyph.count && (glyph[row] << col) & 0x80 != 0 {
                    out.append(di + col * 2 + row * 0x280)
                }
            }
            di += advance
        }
    }
}
