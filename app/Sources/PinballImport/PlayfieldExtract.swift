// tools/extract.py: playfield indices, in-game palette (fade-code signature, preview
// fallback) and the table-select preview (EPn.DAT, PCX).
import Foundation

struct PlayfieldExtract {
    let table: Int
    let playfield: [UInt8]        // 320x400
    let palette: [UInt8]          // 768
    let preview: PCXImage
    let manifest: JSONValue       // extract.py manifest entry

    static let layeredTables: Set<Int> = [8]

    /// Returns (file offset, match score vs the preview's first 200 colours, method).
    static func findPalette(_ exe: MZImage, previewPalette: [UInt8]) throws -> (Int, Double, String) {
        let d = exe.data
        let ref = Array(previewPalette.prefix(600))
        let codeStart = exe.imageOff(exe.entryCS)
        var off: Int
        let method: String
        if codeStart < d.count, let m = rx(#"\x8d\x3e..\xb9\x00\x03\xb0\x00\xf3\xaa\x8d\x36(..)"#).search(d, in: codeStart..<d.count) {
            off = exe.imageOff(try exe.dataSegment(), m.u16(1))
            method = "fade-code"
        } else {
            // numpy: coarse = (sliding_window_view(d, 600)[:, probe] == ref[probe]).mean(axis=1); argmax (first max)
            off = coarsePreviewMatch(d, ref: ref)
            method = "preview-match"
        }
        guard off >= 0, off + 768 <= d.count else { throw ImportError("\(exe.name): palette offset 0x\(String(off, radix: 16)) is outside the file") }
        var same = 0
        for i in 0..<600 where d[off + i] == ref[i] { same += 1 }
        return (off, Double(same) / 600.0, method)
    }

    /// Probe positions of extract.py's coarse search: 0, 10, ..., 590.
    static let coarseProbes: [Int] = Array(stride(from: 0, to: 600, by: 10))

    /// numpy `(sliding_window_view(d, 600)[:, probe] == ref[probe]).mean(axis=1).argmax()`, i.e. the
    /// first offset with the most probe matches, computed exactly but without counting every probe at
    /// every offset: pass 1 takes a lower bound B from the offsets whose first two probes match; pass 2
    /// counts each offset only until it can no longer reach B (more than 60 - B misses). Every offset
    /// that can reach the maximum (>= B) is counted in full, so the first maximum is the same as the
    /// full scan's (`coarsePreviewMatchNaive`, checked in UnitTests).
    static func coarsePreviewMatch(_ d: [UInt8], ref: [UInt8]) -> Int {
        guard d.count >= 600, ref.count >= 600 else { return 0 }
        let probes = coarseProbes
        let np = probes.count
        let last = d.count - 600
        return d.withUnsafeBufferPointer { p -> Int in
            ref.withUnsafeBufferPointer { r -> Int in
                let rv = probes.map { r[$0] }
                func fullCount(_ i: Int) -> Int {
                    var c = 0
                    for k in 0..<np where p[i + probes[k]] == rv[k] { c += 1 }
                    return c
                }
                // pass 1: a lower bound for the maximum
                var bound = 0
                let r0 = rv[0], r1 = rv[1]
                var i = 0
                while i <= last {
                    if p[i] == r0 && p[i + 10] == r1 {
                        let c = fullCount(i)
                        if c > bound { bound = c; if c == np { break } }
                    }
                    i += 1
                }
                // pass 2: exact first argmax among offsets that can reach the bound
                let allowedMisses = np - bound
                var best = -1, bestAt = 0
                i = 0
                while i <= last {
                    var c = 0, miss = 0, k = 0
                    while k < np {
                        if p[i + probes[k]] == rv[k] { c += 1 } else {
                            miss += 1
                            if miss > allowedMisses { break }
                        }
                        k += 1
                    }
                    if k == np, c > best {
                        best = c; bestAt = i
                        if c == np { break }
                    }
                    i += 1
                }
                return bestAt
            }
        }
    }

    /// The literal full scan (reference for tests).
    static func coarsePreviewMatchNaive(_ d: [UInt8], ref: [UInt8]) -> Int {
        guard d.count >= 600, ref.count >= 600 else { return 0 }
        var best = -1, bestAt = 0
        for i in 0...(d.count - 600) {
            var c = 0
            for q in coarseProbes where d[i + q] == ref[q] { c += 1 }
            if c > best { best = c; bestAt = i }
        }
        return bestAt
    }

    static func run(table n: Int, exe: MZImage, dat: [UInt8]) throws -> PlayfieldExtract {
        let prev = try PCXImage.decode(dat, name: "EP\(n).DAT")
        let (top, bottom, after) = try exe.playfieldSegments()
        let (palOff, score, method) = try findPalette(exe, previewPalette: prev.palette)
        let pal = Array(exe.data[palOff..<(palOff + 768)])
        let pf = try exe.playfield()
        let info = JSONValue.obj([
            ("table", .int(n)),
            ("playfield_file_offset", .hex(exe.imageOff(top))),
            ("segments", .strings([pyHex(top), pyHex(bottom), pyHex(after)])),
            ("data_segment", .hex(try exe.dataSegment())),
            ("palette_file_offset", .hex(palOff)),
            ("palette_match", .double(pyRound(score, 2))),
            ("palette_method", .string(method)),
            ("layered_not_decoded", .bool(layeredTables.contains(n))),
        ])
        return PlayfieldExtract(table: n, playfield: pf, palette: pal, preview: prev, manifest: info)
    }

    /// palette.json: 256 [r, g, b] lists (json.dump default separators).
    var paletteJSON: String {
        var rows: [JSONValue] = []
        for i in 0..<256 {
            let r = Int(palette[i * 3]), g = Int(palette[i * 3 + 1]), b = Int(palette[i * 3 + 2])
            rows.append(.ints([r, g, b]))
        }
        return serialize(.array(rows), style: .python)
    }

    func write(to dir: URL) throws {
        try NPYFile.data(uint8: playfield, shape: [400, 320]).writeAtomically(to: dir.appendingPathComponent("playfield_idx.npy"))
        try Data(paletteJSON.utf8).writeAtomically(to: dir.appendingPathComponent("palette.json"))
        try PNGFile.writeIndexed(dir.appendingPathComponent("playfield.png"), width: 320, height: 400, indices: playfield, palette: palette)
        try PNGFile.writeIndexed(dir.appendingPathComponent("preview.png"), width: preview.width, height: preview.height,
                                 indices: preview.pixels, palette: preview.palette)
    }
}
