import Foundation
import PinballCore

/// The records a sprite-set routine draws (`SpriteSetRoutine`, EP8 cs:A42F: the robot figure and the
/// background pieces that restore the empty centre), decoded as palette indices from the user's EXE:
/// pointer tables at SEG:ON / SEG:OFF, each entry a planar record in SEG (sprites.md 2.1), placed at
/// its own x, y (the routine's row table is y*80, verified in the harness after boot).
public struct SpriteSetGraphics: Sendable {
    public let routine: SpriteSetRoutine
    public let on: [IndexedSprite]
    public let off: [IndexedSprite]

    public static func load(exe: TableExe, codeSegment: Int) -> [SpriteSetGraphics] {
        let cb = exe.fileOffset(segment: codeSegment)
        var code = [UInt8](repeating: 0, count: 0x10000)
        let n = max(0, min(0x10000, exe.bytes.count - cb))
        if n > 0 { code.replaceSubrange(0..<n, with: exe.bytes[cb..<(cb + n)]) }
        return SpriteSetRoutine.find(code: code).compactMap { r in
            func records(_ table: Int, _ tag: String) -> [IndexedSprite]? {
                var out: [IndexedSprite] = []
                for k in 0..<r.count {
                    let ptr = exe.u16(exe.fileOffset(segment: r.segment, offset: table + 2 * k))
                    let name = String(format: "spriteset_%04x_%@_%d", r.entry, tag, k)
                    guard let s = GameGraphics.decodePlanar(exe, at: exe.fileOffset(segment: r.segment, offset: ptr), name: name) else { return nil }
                    out.append(s)
                }
                return out
            }
            guard let on = records(r.onTable, "on"), let off = records(r.offTable, "off") else { return nil }
            return SpriteSetGraphics(routine: r, on: on, off: off)
        }
    }
}
