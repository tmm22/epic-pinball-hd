// tools/sprites.py in Swift: every non-playfield graphic located through engine code
// signatures (lamp overlays, flippers, digits, animations, ball, pause banner, plunger, fonts,
// EP8's centre sets), written as RGBA PNGs plus sprites.json with the same entries.
import Foundation

final class SpriteExtract {
    struct Planar { var x: Int, y: Int, w: Int, h: Int, pixels: [UInt8], size: Int }

    /// Visual identifications of tables no code signature classifies (tools/sprites.py NAME_GUESS).
    static let nameGuess: [String: String] = [
        "6:0x26560": "centre award plaque (15 captions + blank)",
        "6:0x29817": "falling apple animation",
        "2:0x3d8fc": "spinner rotation frames",
        "3:0x3bce2": "spinner rotation frames",
        "4:0x2f05d": "ball-lock indicator: [0] empty background, [1..6] ball in slot",
        "9:0x3b20f": "two-digit red LED counter frames",
        "10:0x3c2e0": "eye blink (sequence ping-pongs open->closed->open)",
    ]

    let n: Int
    let exe: MZImage
    let d: [UInt8]
    let pf: [UInt8]
    let pal: [UInt8]
    let paletteOffset: Int?
    /// Whether each file offset starts a plausible planar record (tools/sprites.py valid_planar).
    private var validCache: [Bool] = []

    // outputs
    var entries: [JSONObject] = []
    var images: [(name: String, w: Int, h: Int, rgba: [UInt8])] = []
    var composites: [(name: String, pixels: [UInt8])] = []
    var meta = JSONObject()

    init(table n: Int, exe: MZImage, playfield: [UInt8], palette: [UInt8], paletteOffset: Int?) {
        self.n = n; self.exe = exe; d = exe.data; pf = playfield; pal = palette; self.paletteOffset = paletteOffset
    }

    func validPlanar(_ o: Int) -> Bool {
        if o < 0 || o + 8 > d.count { return false }
        if o < validCache.count { return validCache[o] }
        return SpriteExtract.validPlanarRaw(d, o)
    }

    static func validPlanarRaw(_ d: [UInt8], _ o: Int) -> Bool {
        if o < 0 || o + 8 > d.count { return false }
        let x = Int(d[o]) | Int(d[o + 1]) << 8, y = Int(d[o + 2]) | Int(d[o + 3]) << 8
        let w4 = Int(d[o + 4]) | Int(d[o + 5]) << 8, h = Int(d[o + 6]) | Int(d[o + 7]) << 8
        return x < 320 && y < 400 && 1 <= w4 && w4 <= 30 && 1 <= h && h <= 100 && o + 8 + w4 * 4 * h <= d.count
    }

    func decodePlanar(_ o: Int) -> Planar {
        let x = exe.u16(o), y = exe.u16(o + 2), w4 = exe.u16(o + 4), h = exe.u16(o + 6)
        let w = w4 * 4
        var px = [UInt8](repeating: 0, count: w * h)
        var p = o + 8
        for r in 0..<h { for plane in 0..<4 { for i in 0..<w4 { px[r * w + 4 * i + plane] = d[p]; p += 1 } } }
        return Planar(x: x, y: y, w: w, h: h, pixels: px, size: 8 + w4 * 4 * h)
    }

    func decodeChunky(_ o: Int, header: Int) -> (x: Int?, y: Int?, w: Int, h: Int, pixels: [UInt8]) {
        let x: Int?, y: Int?, w: Int, h: Int
        if header == 8 { x = exe.u16(o); y = exe.u16(o + 2); w = exe.u16(o + 4); h = exe.u16(o + 6) }
        else { w = exe.u16(o); h = exe.u16(o + 2); x = nil; y = nil }
        return (x, y, w, h, Array(d[(o + header)..<(o + header + w * h)]))
    }

    func decodeFont(_ o: Int, count: Int, bpg: Int, rows: Int, cols: Int) -> [[UInt8]] {
        (0..<count).map { g in
            var img = [UInt8](repeating: 0, count: rows * cols)
            for r in 0..<rows { let b = Int(d[o + g * bpg + r]); for c in 0..<cols { img[r * cols + c] = UInt8((b >> (7 - c)) & 1) } }
            return img
        }
    }

    func table(_ off: Int, _ count: Int) -> [Int] { (0..<count).map { exe.u16(off + 2 * $0) } }

    // MARK: locate

    struct Bounded { var bound: Int, clamp: Int, count: Int, seg: Int?, tbl: Int, csIP: Int, ctx: [UInt8] }
    struct Found {
        var cs = 0, ds = 0
        var objseg: Int?
        var lamp: (seg: Int, tbl: Int, csIP: Int)?
        var bounded: [Bounded] = []
        var anim: [(tbl: Int, count: Int?, csIP: Int)] = []
        var balls: [Int] = []
        var ballCode: Int?
        var ballOcclusion: [(Int, Int)]?
        var pause: Int?
        var plunger: Int?
        var displayRows: Int?
        var font8: Int?
        var font5: [Int] = []
        var sets: (seg: Int, count: Int, on: Int, off: Int, csIP: Int)?
    }

    func locate() throws -> Found {
        var f = Found()
        let cs = exe.entryCS, cb = exe.imageOff(cs)
        let ds = try exe.dataSegment()
        f.cs = cs; f.ds = ds
        let code = cb..<d.count
        func rel(_ m: ByteRegex.Match) -> Int { m.start - cb }

        if let m = rx(#"\xba(..)\x8e\xda\x8b\xb7(..)\x56\x9a"#).search(d, in: code) {
            f.objseg = m.u16(1)
            f.lamp = (m.u16(1), m.u16(2), rel(m))
        }
        for m in rx(#"\x83\xfb(.)(\x72|\x76)\x03\xbb(.)\x00(\x53)?\xd1\xe3(\x2e)?\x8b\xb7(..)"#).all(d, in: code) {
            let bound = m.u8(1)
            let s = rel(m)
            f.bounded.append(Bounded(bound: bound, clamp: m.u8(3), count: bound + 1, seg: m.has(5) ? cs : nil, tbl: m.u16(6), csIP: s,
                                     ctx: Array(d[(cb + max(0, s - 8))..<(cb + s)])))
        }
        for m in rx(#"\x2e\x8b\x1e(..)\xd1\xe3\x2e\x8b\xb7(..)"#).all(d, in: code) {
            let tbl = m.u16(2)
            let s = rel(m)
            let pat = #"\x2e\x83\x3e"# + ByteRegex.literal(m.bytes(1)!) + #"(.)\x76"#
            let w = rx(pat).search(d, in: (cb + max(0, s - 64))..<(cb + s))
            if !f.anim.contains(where: { $0.tbl == tbl }) { f.anim.append((tbl, w.map { $0.u8(1) + 1 }, s)) }
        }
        if let m = rx(#"\x8d\x36(..)\x8d\x3e..\xb9\xd6\x00\xf3\xa4"#).search(d, in: code) {
            f.balls = [exe.imageOff(ds, m.u16(1))]
            f.ballCode = rel(m)
        } else if let m = rx(#"\x83\xfb(.)\x76\x03\xbb\x00\x00\xd1\xe3\x8b\xb7(..)\x8d\x3e..\xb9\xd6\x00\xf3\xa4"#).search(d, in: code) {
            f.balls = table(exe.imageOff(ds, m.u16(2)), m.u8(1) + 1).map { exe.imageOff(ds, $0) }
            f.ballCode = rel(m)
        }
        if let bc = f.ballCode {
            let r = (cb + bc)..<min(d.count, cb + bc + 0x80)
            f.ballOcclusion = rx(#"\xb3(.)\xb7(.)"#).all(d, in: r).map { ($0.u8(1), $0.u8(2)) }
        }
        if let m = rx(#"\xba(..)\x8e\xda\x8d\x36(..)\x8b\x0c\x8b\x44\x02\x83\xc6\x04"#).search(d, in: code) {
            f.pause = exe.imageOff(m.u16(1), m.u16(2))
        }
        if let m = rx(#"\x8d\x36(..)\xa3..\xb8(..)\x8e\xc0\xfc\x55\x8b\xec\xad\x8b\xc8\xad\x8b\xf8\xd1\xe7\x26\x8b\xbd..\x81\xc7(..)"#).search(d, in: code) {
            f.plunger = exe.imageOff(m.u16(2), m.u16(1))
            f.displayRows = m.u16(3) / 80
        }
        let oseg = f.objseg ?? ds
        if let m = rx(#"\x8d\x36(..)\x2c\x20\x3c\x80"#).search(d, in: code) { f.font8 = exe.imageOff(oseg, m.u16(1)) }
        let f5 = Set(rx(#"\xbb\x05\x00\xf7\xe3\x8b\xd8\xb1\x01\xb2\x05\x53\x57\x8a\x87(..)"#).all(d, in: code).map { $0.u16(1) }).sorted()
        f.font5 = f5.map { exe.imageOff(oseg, $0) }
        if let m = rx(#"\xba(..)\x8e\xda\xb9(.)\x00\xbb\x00\x00\x8d\x3e(..)\x3c\x01\x74\x04\x8d\x3e(..)"#).search(d, in: code) {
            f.sets = (m.u16(1), m.u8(2), m.u16(3), m.u16(4), rel(m))
        }
        return f
    }

    /// Heuristic: runs of u16 that all point at plausible planar headers (any relocated segment).
    func scanPointerTables(exclude: [Int], minrun: Int = 3) throws -> [(seg: Int, toff: Int, targets: [Int])] {
        let (top, bot, _) = try exe.playfieldSegments()
        let pfs = exe.imageOff(top), pfe = exe.imageOff(bot) + 64000
        var res: [(Int, Int, [Int])] = []
        for seg in exe.segValues.keys.sorted() where seg != top && seg != bot {
            let base = exe.imageOff(seg)
            for par in 0...1 {
                var o = 0x400 + par
                var run: [(Int, Int)] = []
                while o < d.count - 1 {
                    if pfs <= o && o < pfe { o = pfe + par; run = []; continue }
                    let v = Int(d[o]) | Int(d[o + 1]) << 8
                    let t = base + v
                    if v != 0 && validPlanar(t) && !(pfs <= t && t < pfe) {
                        run.append((o, t))
                    } else {
                        if run.count >= minrun && Set(run.map { $0.1 }).count >= max(2, run.count / 2) {
                            if !exclude.contains(where: { abs(run[0].0 - $0) < 2 * run.count }) {
                                res.append((seg, run[0].0, run.map { $0.1 }))
                            }
                        }
                        run = []
                    }
                    o += 2
                }
            }
        }
        return res
    }

    // MARK: output entries

    @discardableResult
    func add(_ name: String, _ w: Int, _ h: Int, _ img: [UInt8], _ fmt: String, _ off: Int, alpha: [UInt8]? = nil,
             x: Int? = nil, y: Int? = nil, group: String = "misc", extra: [(String, JSONValue)] = [], scaleFont: Bool = false) -> Int {
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            if scaleFont {
                if img[i] == 1 { rgba[i * 4] = 255; rgba[i * 4 + 1] = 255; rgba[i * 4 + 2] = 255; rgba[i * 4 + 3] = 255 }
            } else {
                let c = Int(img[i]) * 3
                rgba[i * 4] = pal[c]; rgba[i * 4 + 1] = pal[c + 1]; rgba[i * 4 + 2] = pal[c + 2]
                rgba[i * 4 + 3] = alpha?[i] ?? 255
            }
        }
        var e = JSONObject()
        e["name"] = .string(name); e["group"] = .string(group); e["format"] = .string(fmt)
        e["w"] = .int(w); e["h"] = .int(h); e["file_offset"] = .hex(off)
        if let x, let y {
            e["x"] = .int(x); e["y"] = .int(y)
            let xa = x & ~3
            if xa + w <= 320 && y + h <= 400 {
                var same = 0
                for r in 0..<h { for c in 0..<w where pf[(y + r) * 320 + xa + c] == img[r * w + c] { same += 1 } }
                e["playfield_match"] = .double(pyRound(Double(same) / Double(w * h), 3))
            }
        }
        for (k, v) in extra { e[k] = v }
        entries.append(e)
        if let i = images.firstIndex(where: { $0.name == name }) { images[i] = (name, w, h, rgba) } else { images.append((name, w, h, rgba)) }
        return entries.count - 1
    }

    func run() throws {
        let f = try locate()
        var knownTables: [Int] = []
        var notes: [String] = []
        var sequences = JSONObject()
        var lampRecords: [(i: Int, x: Int, y: Int, img: Planar, dummy: Bool)] = []
        var lampCount = 0
        // precompute valid_planar for every offset (used many times by the heuristic scan)
        validCache = (0..<d.count).map { SpriteExtract.validPlanarRaw(d, $0) }

        // ---- lamps / overlays
        if let L = f.lamp {
            let toff = exe.imageOff(L.seg, L.tbl)
            knownTables.append(toff)
            let base = exe.imageOff(L.seg)
            var ptrs: [Int] = []
            var k = 0
            while true {
                let p = exe.u16(toff + 2 * k)
                if !validPlanar(base + p) { break }
                ptrs.append(p)
                k += 1
                if toff + 2 * k >= ptrs.map({ base + $0 }).min()! { break }
            }
            let offs = Set(ptrs.map { base + $0 }).sorted()
            for (i, p) in ptrs.enumerated() {
                let src = base + p
                let r = decodePlanar(src)
                let nxt = offs.first { $0 > src }
                let dummy = r.w * r.h <= 16 || (nxt != nil && src + r.size > nxt!)
                let name = String(format: "lamp%03d_%@", i / 2, i % 2 == 0 ? "a" : "b")
                add(name, r.w, r.h, r.pixels, "planar", src, x: r.x, y: r.y, group: "lamp",
                    extra: [("index", .int(i)), ("lamp", .int(i / 2)), ("state", .string(i % 2 == 0 ? "a(state1)" : "b(state2)")), ("dummy", .bool(dummy))])
                lampRecords.append((i, r.x, r.y, r, dummy))
            }
            lampCount = ptrs.count
            var uses: [Int: Int] = [:]
            for p in ptrs { uses[base + p, default: 0] += 1 }
            for j in entries.indices where entries[j]["group"]?.stringValue == "lamp" {
                if let fo = entries[j]["file_offset"]?.hexInt, let u = uses[fo], u > 1 { entries[j]["shared_by_slots"] = .int(u) }
            }
        }

        // ---- bounded tables: flippers, big score digits, misc
        for bt in f.bounded {
            let seg = bt.seg ?? f.objseg ?? f.ds
            var toff = exe.imageOff(seg, bt.tbl)
            if toff + 2 * bt.count > d.count { continue }
            var ptrs = table(toff, bt.count)
            var base = exe.imageOff(seg)
            if bt.count == 11 && bt.bound == 10 && validPlanar(base + ptrs[0]) {
                let r0 = decodePlanar(base + ptrs[0])
                if r0.w * r0.h <= 16 {
                    notes.append("big score digit table at \(pyHex(toff)) is a 1x1 stub (big digits unused; score presumably drawn with the dot-matrix font)")
                    continue
                }
            }
            if !ptrs.allSatisfy({ validPlanar(base + $0) }) {
                base = exe.imageOff(f.ds)
                toff = exe.imageOff(f.ds, bt.tbl)
                ptrs = table(toff, bt.count)
                if !ptrs.allSatisfy({ validPlanar(base + $0) }) { continue }
            }
            knownTables.append(toff)
            let recs = ptrs.map { (decodePlanar(base + $0), base + $0) }
            let kind: String
            var names: [String] = []
            if bt.count == 11 && bt.bound == 10 {
                kind = "digit"
                if recs.allSatisfy({ $0.0.w * $0.0.h <= 16 }) {
                    notes.append("big score digit table at \(pyHex(toff)) is a 1x1 stub (big digits unused; score presumably drawn with the dot-matrix font)")
                    continue
                }
                names = (0..<10).map { "digit_\($0)" } + ["digit_blank"]
            } else if bt.ctx.suffix(2) == [0x8E, 0xDA] || (bt.seg == f.cs && recs[0].0.y > 300) {
                kind = "flipper"
                var k = -1, fr = 0
                var prev: (Int, Int)? = nil
                var side = "L"
                for (r, _) in recs {
                    if prev == nil || prev! != (r.x, r.y) {
                        k += 1; fr = 0; prev = (r.x, r.y)
                        side = Double(r.x) + Double(r.w) / 2 < 160 ? "L" : "R"
                    }
                    names.append("flipper\(k)\(side)_\(fr)")
                    fr += 1
                }
            } else {
                kind = "anim"
                names = recs.indices.map { String(format: "table%04x_%d", bt.tbl, $0) }
            }
            var seen: [Int: String] = [:]
            var seq: [String] = []
            for (i, ((r, so), nm)) in zip(recs, names).enumerated() {
                if let s = seen[so] { seq.append(s); continue }
                seen[so] = nm
                seq.append(nm)
                var extra: [(String, JSONValue)] = [("index", .int(i)), ("table_file_offset", .hex(toff))]
                if let g = SpriteExtract.nameGuess["\(n):\(pyHex(toff))"] { extra.append(("name_guess", .string(g))) }
                if kind == "flipper" { extra.append(("note", .string("frame 0 = fully raised ... last = at rest (verified visually on EP1/EP4/EP10/EP12)"))) }
                add(nm, r.w, r.h, r.pixels, "planar", so, x: kind != "digit" ? r.x : nil, y: kind != "digit" ? r.y : nil, group: kind, extra: extra)
            }
            sequences["\(kind)@\(pyHex(toff))"] = .strings(seq)
        }

        for a in f.anim {
            let toff = exe.imageOff(f.cs, a.tbl)
            knownTables.append(toff)
            let cnt = a.count ?? 6
            let base = exe.imageOff(f.cs)
            let ptrs = table(toff, cnt)
            if !ptrs.allSatisfy({ validPlanar(base + $0) }) { continue }
            var seen: [Int: String] = [:]
            var seq: [String] = []
            for (i, p) in ptrs.enumerated() {
                if let s = seen[base + p] { seq.append(s); continue }
                let r = decodePlanar(base + p)
                let nm = String(format: "anim%04x_%d", a.tbl, i)
                seen[base + p] = nm
                seq.append(nm)
                add(nm, r.w, r.h, r.pixels, "planar", base + p, x: r.x, y: r.y, group: "anim",
                    extra: [("index", .int(i)), ("table_file_offset", .hex(toff)), ("note", .string("cycled by a frame counter")),
                            ("name_guess", .string(SpriteExtract.nameGuess["\(n):\(pyHex(toff))"] ?? "unknown"))])
            }
            sequences["anim@\(pyHex(toff))"] = .strings(seq)
        }

        if let S = f.sets { knownTables += [exe.imageOff(S.seg, S.on), exe.imageOff(S.seg, S.off)] }

        // ---- heuristic leftovers
        for (seg, toff, targets) in try scanPointerTables(exclude: knownTables) {
            let guess = SpriteExtract.nameGuess["\(n):\(pyHex(toff))"]
            var seq: [String] = []
            for (i, t) in targets.enumerated() {
                if let dup = entries.first(where: { $0["file_offset"]?.stringValue == pyHex(t) }) {
                    seq.append(dup["name"]!.stringValue!); continue
                }
                let nm = String(format: "unk%05x_%d", toff, i)
                seq.append(nm)
                let r = decodePlanar(t)
                add(nm, r.w, r.h, r.pixels, "planar", t, x: r.x, y: r.y, group: guess != nil ? "anim" : "unknown",
                    extra: [("index", .int(i)), ("table_file_offset", .hex(toff)), ("table_seg", .hex(seg)),
                            ("name_guess", .string(guess ?? "unknown")),
                            ("note", .string("found by pointer-table heuristic only; name_guess is from visual inspection"))])
            }
            sequences["heuristic@\(pyHex(toff))"] = .strings(seq)
        }

        // ---- ball(s)
        for (i, bo) in f.balls.enumerated() {
            let c = decodeChunky(bo, header: 4)
            let alpha = c.pixels.map { $0 == 0 ? UInt8(0) : UInt8(255) }
            add(f.balls.count == 1 ? "ball" : "ball_\(i)", c.w, c.h, c.pixels, "ball", bo, alpha: alpha, group: "ball",
                extra: [("transparent_index", .int(0)), ("occlusion_ranges", .array((f.ballOcclusion ?? []).map { .ints([$0.0, $0.1]) }))])
        }
        if let p = f.pause {
            let c = decodeChunky(p, header: 8)
            add("pause", c.w, c.h, c.pixels, "chunky", p, group: "display",
                extra: [("display_x", .int(c.x!)), ("display_y", .int(c.y!)), ("note", .string("drawn into the split-screen display area"))])
        }
        if let p = f.plunger {
            let r = decodePlanar(p)
            add("plunger", r.w, r.h, r.pixels, "planar", p, x: r.x, y: r.y, group: "plunger",
                extra: [("note", .string("y is overwritten at runtime (pull distance); drawn to both pages"))])
        }

        // ---- fonts
        if let start = f.font8 {
            let end = f.font5.filter { $0 > start }.min() ?? (start + 96 * 8)
            let cnt = min((end - start) / 8, 96)
            for (gi, g) in decodeFont(start, count: cnt, bpg: 8, rows: 8, cols: 8).enumerated() {
                add(String(format: "font8_%02x", 0x20 + gi), 8, 8, g, "font8", start + gi * 8, group: "font", extra: [("char", .int(0x20 + gi))], scaleFont: true)
            }
        }
        for (fi, start) in f.font5.enumerated() {
            let cnt = f.font5.count == 1 ? 71 : (f.font5[1] - f.font5[0]) / 5
            let tag = f.font5.count > 1 ? (fi == 0 ? "a" : "b") : ""
            for (gi, g) in decodeFont(start, count: cnt, bpg: 5, rows: 5, cols: 5).enumerated() {
                add(String(format: "font5%@_%02x", tag, 0x20 + gi), 5, 5, g, "font5", start + gi * 5, group: "font", extra: [("char", .int(0x20 + gi))], scaleFont: true)
            }
        }

        // ---- EP8-style composite: all "state a" overlays that differ from the playfield
        var compositeNames: [String] = []
        if !lampRecords.isEmpty {
            func mean(_ suffix: String) -> Double {
                let v = entries.filter { $0["group"]?.stringValue == "lamp" && ($0["name"]?.stringValue ?? "").hasSuffix(suffix) }
                    .map { $0["playfield_match"]?.doubleValue ?? 1 }
                return v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count)
            }
            let meanA = mean("_a"), meanB = mean("_b")
            if let S = f.sets, meanB > 0.9, meanA < 0.7 {
                var comp = pf
                var drawn: [(Int, Int, Int, Int)] = []
                for rec in lampRecords where rec.i % 2 == 0 && !rec.dummy {
                    let h = rec.img.h, w = rec.img.w, xa = rec.x & ~3, y = rec.y
                    if drawn.contains(where: { xa >= $0.0 - 2 && y >= $0.1 - 2 && xa + w <= $0.0 + $0.2 + 2 && y + h <= $0.1 + $0.3 + 2 }) { continue }
                    drawn.append((xa, y, w, h))
                    for r in 0..<h where y + r < 400 { for c in 0..<w where xa + c < 320 { comp[(y + r) * 320 + xa + c] = rec.img.pixels[r * w + c] } }
                }
                composites.append(("playfield_composited", comp))
                compositeNames.append("playfield_composited")
                let base = exe.imageOff(S.seg)
                var c2 = comp
                var k1 = 0, k0 = 0
                for p in table(base + S.on, S.count) {
                    let r = decodePlanar(base + p)
                    let xa = r.x & ~3
                    for rr in 0..<r.h where r.y + rr < 400 { for c in 0..<r.w where xa + c < 320 { c2[(r.y + rr) * 320 + xa + c] = r.pixels[rr * r.w + c] } }
                    add("centre_set1_\(k1)", r.w, r.h, r.pixels, "planar", base + p, x: r.x, y: r.y, group: "centre"); k1 += 1
                }
                for p in table(base + S.off, S.count) {
                    let r = decodePlanar(base + p)
                    add("centre_set0_\(k0)", r.w, r.h, r.pixels, "planar", base + p, x: r.x, y: r.y, group: "centre"); k0 += 1
                }
                composites.append(("playfield_composited_robot", c2))
                compositeNames.append("playfield_composited_robot")
            }
        }

        var m = JSONObject()
        m["table"] = .int(n)
        m["palette_file_offset"] = paletteOffset.map { .hex($0) } ?? .string("from palette.json")
        m["code_segment"] = .hex(f.cs)
        m["data_segment"] = .hex(f.ds)
        m["object_segment"] = .hex(f.objseg ?? 0)
        if let L = f.lamp {
            m["lamp_table"] = .obj([("file_offset", .hex(exe.imageOff(L.seg, L.tbl))), ("entries", .int(lampCount)), ("code_cs_ip", .hex(L.csIP))])
        } else {
            m["lamp_table"] = .null
        }
        m["display_rows"] = .intOrNull(f.displayRows)
        m["ball_occlusion_ranges"] = f.ballOcclusion.map { .array($0.map { .ints([$0.0, $0.1]) }) } ?? .null
        m["composites"] = .strings(compositeNames)
        m["sequences"] = .object(sequences)
        m["notes"] = .strings(notes)
        m["sprites"] = .array(entries.map { .object($0) })
        meta = m
    }

    /// The fields engine.json / the renderer read, as parsed JSON (same shape as sprites.json).
    var json: JSONValue { .object(meta) }

    func write(to tableDir: URL) throws {
        let sdir = tableDir.appendingPathComponent("sprites", isDirectory: true)
        try FileManager.default.createDirectory(at: sdir, withIntermediateDirectories: true)
        for img in images where img.w > 0 && img.h > 0 {
            try PNGFile.write(sdir.appendingPathComponent(img.name + ".png"), width: img.w, height: img.h, rgba: img.rgba)
        }
        for c in composites {
            try PNGFile.writeIndexed(tableDir.appendingPathComponent(c.name + ".png"), width: 320, height: 400, indices: c.pixels, palette: pal)
        }
        try Data(serialize(.object(meta), style: .indent(1)).utf8).writeAtomically(to: sdir.appendingPathComponent("sprites.json"))
    }
}
