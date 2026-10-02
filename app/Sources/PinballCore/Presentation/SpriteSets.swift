import Foundation

/// A routine that blits one of two sets of planar records from an extra segment into both VRAM
/// pages, chosen by AL (EP8 cs:A42F, the only one in the 13 tables [H, signature scan]):
///
///     push ds; pusha; push es; mov dx,SEG; mov ds,dx; mov cx,N; mov bx,0
///     lea di,[ON]; cmp al,1; je +4; lea di,[OFF]
///     loop N times: si = [bx+di]; record = x, y, w4, h + planar rows (sprites.md 2.1), drawn opaque at
///     VRAM row offset es:[2y+35h] (y*80, built at boot) + 640h (below the 20-row strip) + x/4, and
///     again 7D00h further (the second page); bx += 2
///
/// EP8's rule code calls it with AL = 1 (cs:2F27, the large robot figure over the centre, x 88..211,
/// y 200..358) and AL = 0 (cs:2F0D, the matching background pieces that restore the empty centre).
/// Both rules backends treat it as a display routine; the runtime reports each call as a
/// `SpriteSetEvent` and the classic composer blits the records like lamp overlays.
public struct SpriteSetRoutine: Sendable, Equatable {
    /// Routine entry (cs offset), the records' segment, record count and the two pointer tables.
    public var entry: Int, segment: Int, count: Int
    public var onTable: Int, offTable: Int

    public static func find(code c: [UInt8]) -> [SpriteSetRoutine] {
        func b(_ i: Int) -> Int { Int(c[i & 0xFFFF]) }
        func w(_ i: Int) -> Int { b(i) | b(i + 1) << 8 }
        var out: [SpriteSetRoutine] = []
        for p in 3..<0xFFE0 where c[p] == 0xBA && c[p + 3] == 0x8E && c[p + 4] == 0xDA && c[p + 5] == 0xB9 && c[p + 7] == 0x00
            && c[p + 8] == 0xBB && c[p + 9] == 0 && c[p + 10] == 0 && c[p + 11] == 0x8D && c[p + 12] == 0x3E
            && c[p + 15] == 0x3C && c[p + 16] == 0x01 && c[p + 17] == 0x74 && c[p + 18] == 0x04 && c[p + 19] == 0x8D && c[p + 20] == 0x3E
            && c[p - 3] == 0x1E && c[p - 2] == 0x60 && c[p - 1] == 0x06 {
            out.append(SpriteSetRoutine(entry: p - 3, segment: w(p + 1), count: b(p + 6), onTable: w(p + 13), offTable: w(p + 21)))
        }
        return out
    }

    /// The AL a call site loads right before calling `entry` (`mov al,imm; call far / near entry`),
    /// searched forward from `from` (a lifted block's ip) for at most `limit` bytes.
    public func selector(code c: [UInt8], from: Int, limit: Int = 0x80) -> Int? {
        for p in from..<min(0xFFF8, from + limit) where c[p] == 0xB0 {
            let t = p + 2
            if c[t] == 0x9A, Int(c[t + 1]) | Int(c[t + 2]) << 8 == entry { return Int(c[p + 1]) }
            if c[t] == 0xE8, (t + 3 + (Int(c[t + 1]) | Int(c[t + 2]) << 8)) & 0xFFFF == entry { return Int(c[p + 1]) }
        }
        return nil
    }
}
