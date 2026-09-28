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
            let probe = stride(from: 0, to: 600, by: 10).map { $0 }
            var best = -1, bestAt = 0
            if d.count >= 600 {
                d.withUnsafeBufferPointer { p in
                    for i in 0...(d.count - 600) {
                        var c = 0
                        for q in probe where p[i + q] == ref[q] { c += 1 }
                        if c > best { best = c; bestAt = i; if c == probe.count { break } }
                    }
                }
            }
            off = bestAt
            method = "preview-match"
        }
        guard off >= 0, off + 768 <= d.count else { throw ImportError("\(exe.name): palette offset 0x\(String(off, radix: 16)) is outside the file") }
        var same = 0
        for i in 0..<600 where d[off + i] == ref[i] { same += 1 }
        return (off, Double(same) / 600.0, method)
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
