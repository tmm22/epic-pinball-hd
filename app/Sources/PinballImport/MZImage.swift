// Structural parser for the table executables (tools/epexe.py): MZ header, relocation
// table, the playfield segment chain and the data segment named at the entry point.
import Foundation

public struct ImportError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

final class MZImage: @unchecked Sendable {
    static let half = 320 * 200
    static let halfParas = half / 16   // 0xFA0

    let name: String
    let data: [UInt8]
    let headerSize: Int
    let entryCS: Int
    let entryIP: Int
    /// (seg, off) of each fixup, in table order.
    let relocs: [(Int, Int)]
    /// Relocated segment value -> reference count (insertion order kept in `segOrder`).
    let segValues: [Int: Int]

    init(name: String, data: [UInt8]) throws {
        self.name = name
        self.data = data
        guard data.count >= 0x1C, data[0] == 0x4D, data[1] == 0x5A else { throw ImportError("\(name): not an MZ executable") }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        let nreloc = u16(6)
        headerSize = u16(8) * 16
        entryIP = u16(0x14)
        entryCS = u16(0x16)
        let relocOff = u16(0x18)
        var relocs: [(Int, Int)] = []
        var segs: [Int: Int] = [:]
        for i in 0..<nreloc {
            let o = relocOff + i * 4
            guard o + 4 <= data.count else { throw ImportError("\(name): relocation table is truncated") }
            let off = u16(o), seg = u16(o + 2)
            relocs.append((seg, off))
            let at = headerSize + seg * 16 + off
            guard at + 2 <= data.count else { throw ImportError("\(name): relocation points outside the file") }
            segs[u16(at), default: 0] += 1
        }
        self.relocs = relocs
        segValues = segs
    }

    /// File offset of a load-image seg:off address.
    func imageOff(_ seg: Int, _ off: Int = 0) -> Int { headerSize + seg * 16 + off }

    func u8(_ o: Int) -> Int { Int(data[o]) }
    func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
    func s16(_ o: Int) -> Int { let v = u16(o); return v >= 0x8000 ? v - 0x10000 : v }

    /// (top, bottom, after): the three relocated segments 0xFA0 paragraphs apart.
    func playfieldSegments() throws -> (Int, Int, Int) {
        let segs = segValues
        let starts = segs.keys.sorted().filter { segs[$0 + MZImage.halfParas] != nil && segs[$0 - MZImage.halfParas] == nil }
        let chains = starts.filter { segs[$0 + 2 * MZImage.halfParas] != nil }
        guard chains.count == 1 else { throw ImportError("\(name): expected one 3-segment playfield chain, found \(chains.count)") }
        let a = chains[0]
        return (a, a + MZImage.halfParas, a + 2 * MZImage.halfParas)
    }

    /// 320x400 palette indices.
    func playfield() throws -> [UInt8] {
        let top = try playfieldSegments().0
        let start = imageOff(top)
        guard start + 2 * MZImage.half <= data.count else { throw ImportError("\(name): playfield runs past the end of the file") }
        return Array(data[start..<(start + 2 * MZImage.half)])
    }

    /// Entry code: push ds / mov ax,0 / push ax / mov ax,<DS> / mov ds,ax.
    func dataSegment() throws -> Int {
        let entry = imageOff(entryCS, entryIP)
        guard entry < data.count, let m = rx(#"\xb8(..)\x8e\xd8"#).search(data, in: entry..<min(data.count, entry + 32)) else {
            throw ImportError("\(name): could not find the DS setup at the entry point")
        }
        return m.u16(1)
    }
}
