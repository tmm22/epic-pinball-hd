// HD asset pack generator: the Swift port of tools/hdpack/make_pack.py (xbrz and nearest
// methods, and its --verify alignment check), so the app can make packs without Python.
//
// Reads a runtime-data root laid out like extracted/ or an imported library (tables/EPn/:
// playfield_idx.npy, palette.json, sprites/sprites.json + the sprite PNGs, engine.json for the
// ball) and writes the pack layout HDPack.load reads (docs/enhanced/rendering.md, "HD asset
// packs"). The pixels equal the Python tool's (HDPackTests); the PNG bytes do not (ImageIO
// and Pillow's zlib compress differently) and pack.json differs only in generator.tool.
//
// A pack is derived from the user's own copy of the game: it lives in user data directories
// (Application Support/EpicPinballHD/HDPacks, extracted/hdpacks) and is never committed or bundled.
import CryptoKit
import Foundation
import PinballCore

public enum HDPackMaker {
    public enum Method: String, Sendable, CaseIterable {
        /// The built-in xBRZ (XBRZScaler.swift = tools/hdpack/xbrz.py, the renderer's filter).
        case xbrz
        /// Pixel replication (pipeline / alignment tests).
        case nearest
    }

    public static let format = "epic-pinball-hdpack"
    public static let version = 1
    public static let scales = 2...8
    /// pack.json generator.tool (make_pack.py writes "tools/hdpack/make_pack.py").
    public static let tool = "EpicPinball HDPackMaker"
    /// Context pixels around position-bound sprites (xBRZ reads 2).
    static let margin = 3
    static let packGroups: Set<String> = ["lamp", "flipper", "plunger", "digit", "display"]
    static let contextGroups: Set<String> = ["lamp", "flipper", "plunger"]

    public struct Result: Sendable {
        public var table: Int
        public var scale: Int
        public var directory: URL
        public var sprites: Int
        public var ball: Bool
        public var font8Glyphs: Int
        public var seconds: Double
    }

    /// `<root>/EP<n>`: where a pack for table n goes under a packs root.
    public static func packDirectory(root: URL, table n: Int) -> URL { root.appendingPathComponent("EP\(n)", isDirectory: true) }

    /// Generates the pack for `table` from `dataRoot` into `output` (replaced as a whole once the
    /// pack is complete: a failed or cancelled run leaves an existing pack alone). `progress`
    /// reports 0...1 for this table; `isCancelled` is polled between assets (and per playfield
    /// row) and makes the call throw `CancellationError`.
    @discardableResult
    public static func make(table n: Int, dataRoot: URL, output: URL, scale S: Int, method: Method = .xbrz,
                            progress: (@Sendable (ImportProgress) -> Void)? = nil,
                            isCancelled: (@Sendable () -> Bool)? = nil) throws -> Result {
        guard scales.contains(S) else { throw ImportError("HD pack scale must be \(scales.lowerBound)...\(scales.upperBound), got \(S)") }
        let started = Date()
        func check() throws { if isCancelled?() == true { throw CancellationError() } }
        let t = try TableData.load(dataRoot: dataRoot, table: n)
        let fm = FileManager.default
        let parent = output.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // staging directories left behind by a run that was killed (the app quit mid-pack)
        let partial = ".\(output.lastPathComponent).partial-"
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix(partial) {
            try? fm.removeItem(at: parent.appendingPathComponent(name))
        }
        let staging = parent.appendingPathComponent(partial + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging.appendingPathComponent("sprites"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        func opaque(_ px: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
            method == .nearest ? XBRZ.nearest(px, width: w, height: h, scale: S)
                : XBRZ.scaleRGBA8(px, width: w, height: h, scale: S, cancelled: isCancelled)
        }
        func save(_ rel: String, _ px: [UInt8], _ w: Int, _ h: Int) throws {
            try PNGFile.write(staging.appendingPathComponent(rel), width: w, height: h, rgba: px)
        }

        let W = TableGeometry.width, H = TableGeometry.height
        let field = t.fieldRGBA
        progress?(ImportProgress(fraction: 0, message: "EP\(n): playfield \(W * S)x\(H * S) (\(method.rawValue))"))
        let pf = opaque(field, W, H)
        try check()
        try save("playfield.png", pf, W * S, H * S)
        // The playfield is about half of the work (lamp contexts are the other half).
        progress?(ImportProgress(fraction: 0.5, message: "EP\(n): sprites"))

        var spriteEntries: [(String, JSONValue)] = []
        let candidates = t.sprites.filter { s in
            guard let f = s["format"]?.stringValue, f == "planar" || f == "chunky",
                  let g = s["group"]?.stringValue, packGroups.contains(g) else { return false }
            return true
        }
        for (k, s) in candidates.enumerated() {
            try check()
            guard let name = s["name"]?.stringValue, let group = s["group"]?.stringValue,
                  let rec = PNGFile.readStraight(t.spriteDir.appendingPathComponent(name + ".png")) else { continue }
            var px = rec.rgba
            for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
            let hd: [UInt8]
            if contextGroups.contains(group), let x = s["x"]?.intValue, let y = s["y"]?.intValue {
                hd = contextScaled(field: field, record: px, w: rec.w, h: rec.h, x: x, y: y, scale: S, opaque: opaque)
            } else {
                hd = opaque(px, rec.w, rec.h)
            }
            try check()
            let rel = "sprites/\(name).png"
            try save(rel, hd, rec.w * S, rec.h * S)
            var e: [(String, JSONValue)] = [("file", .string(rel)), ("w", .int(rec.w)), ("h", .int(rec.h)), ("group", .string(group))]
            if let x = s["x"] { e.append(("x", x)); e.append(("y", s["y"] ?? .null)) }
            spriteEntries.append((name, .object(JSONObject(e))))
            progress?(ImportProgress(fraction: 0.5 + 0.45 * Double(k + 1) / Double(max(1, candidates.count)), message: "EP\(n): sprites"))
        }

        var ballEntry: JSONValue?
        if let b = t.ball {
            var ball = [UInt8](repeating: 0, count: b.w * b.h * 4)
            for i in 0..<(b.w * b.h) where b.pixels[i] != b.transparent {
                let c = Int(b.pixels[i]) * 3
                ball[i * 4] = t.palette[c]; ball[i * 4 + 1] = t.palette[c + 1]; ball[i * 4 + 2] = t.palette[c + 2]; ball[i * 4 + 3] = 255
            }
            let pw = b.w + 4, ph = b.h + 4
            let padded = pad(ball, w: b.w, h: b.h, by: 2, alpha: 0)
            let up = method == .nearest ? XBRZ.nearest(padded, width: pw, height: ph, scale: S)
                : XBRZ.scaleRGBA8(padded, width: pw, height: ph, scale: S)
            let hd = crop(up, w: pw * S, x: 2 * S, y: 2 * S, cw: b.w * S, ch: b.h * S)
            try save("sprites/ball.png", hd, b.w * S, b.h * S)
            ballEntry = .object(JSONObject([("file", .string("sprites/ball.png")), ("w", .int(b.w)), ("h", .int(b.h))]))
        }

        // font8 coverage atlas (glyph g at rows g*8S), white = covered; always xBRZ on the bits.
        var glyphs: [Int: String] = [:]
        for s in t.sprites where s["format"]?.stringValue == "font8" {
            if let c = s["char"]?.intValue, let name = s["name"]?.stringValue { glyphs[c] = name }
        }
        var fonts: [(String, JSONValue)] = []
        var glyphCount = 0
        if let last = glyphs.keys.max(), last >= 0x20 {
            try check()
            let first = 0x20, cell = 8 * S
            glyphCount = last - first + 1
            var atlas = [UInt8](repeating: 0, count: glyphCount * cell * cell * 4)
            for i in stride(from: 3, to: atlas.count, by: 4) { atlas[i] = 255 }
            for ch in first...last {
                guard let name = glyphs[ch], let g = PNGFile.readStraight(t.spriteDir.appendingPathComponent(name + ".png")),
                      g.w == 8, g.h == 8 else { continue }
                var bits = [UInt8](repeating: 0, count: 8 * 8 * 4)
                for i in 0..<64 {
                    let a = g.rgba[i * 4 + 3], m = max(g.rgba[i * 4], g.rgba[i * 4 + 1], g.rgba[i * 4 + 2])
                    if a > 0 && m > 0 { bits[i * 4] = 255; bits[i * 4 + 1] = 255; bits[i * 4 + 2] = 255 }
                    bits[i * 4 + 3] = 255
                }
                let hdm: [UInt8]
                if method == .nearest {
                    hdm = XBRZ.nearest(bits, width: 8, height: 8, scale: S)
                } else {
                    let padded = pad(bits, w: 8, h: 8, by: 2, alpha: 255)
                    hdm = crop(XBRZ.scaleRGBA8(padded, width: 12, height: 12, scale: S), w: 12 * S, x: 2 * S, y: 2 * S, cw: cell, ch: cell)
                }
                let base = (ch - first) * cell * cell * 4
                atlas.replaceSubrange(base..<(base + hdm.count), with: hdm)
            }
            try fm.createDirectory(at: staging.appendingPathComponent("fonts"), withIntermediateDirectories: true)
            try save("fonts/font8.png", atlas, cell, glyphCount * cell)
            fonts.append(("font8", .object(JSONObject([
                ("file", .string("fonts/font8.png")), ("first", .int(0)), ("cell", .int(8)), ("glyphs", .int(glyphCount)),
                ("layout", .string("vertical, glyph index from ' ', red channel = coverage")),
            ]))))
        }

        // pack.json: make_pack.py's keys in its order (ball is added after "note" there).
        var manifest: [(String, JSONValue)] = [
            ("format", .string(format)), ("version", .int(version)), ("table", .int(n)), ("scale", .int(S)),
            ("generator", .object(JSONObject([("tool", .string(tool)), ("method", .string(method.rawValue)),
                                              ("upscaler_cmd", .null), ("anchor", .int(0))]))),
            ("source", .object(JSONObject([("playfield_idx_sha256", .string(sha256(t.indices))),
                                           ("palette_sha256", .string(sha256(t.palette)))]))),
            ("playfield", .string("playfield.png")),
            ("sprites", .object(JSONObject(spriteEntries))),
            ("fonts", .object(JSONObject(fonts))),
            ("note", .string("Generated from the user's own game data. Do not distribute.")),
        ]
        if let b = ballEntry { manifest.append(("ball", b)) }
        try Data(serialize(.object(JSONObject(manifest)), style: .indent(1)).utf8)
            .write(to: staging.appendingPathComponent("pack.json"))
        try check()

        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        try fm.moveItem(at: staging, to: output)
        progress?(ImportProgress(fraction: 1, message: "EP\(n): done"))
        return Result(table: n, scale: S, directory: output, sprites: spriteEntries.count, ball: ballEntry != nil,
                      font8Glyphs: glyphCount, seconds: Date().timeIntervalSince(started))
    }

    /// make_pack.py context_crop: a position-bound opaque record upscaled inside the playfield
    /// (pasted with a margin, scaled, cropped) so its HD edges meet the HD playfield. Records that
    /// reach outside the table are upscaled on their own.
    static func contextScaled(field: [UInt8], record: [UInt8], w: Int, h: Int, x: Int, y: Int, scale S: Int,
                              opaque: ([UInt8], Int, Int) -> [UInt8]) -> [UInt8] {
        let W = TableGeometry.width, H = TableGeometry.height
        guard x >= 0, y >= 0, x + w <= W, y + h <= H else { return opaque(record, w, h) }
        let cy0 = max(0, y - margin), cy1 = min(H, y + h + margin)
        let cx0 = max(0, x - margin), cx1 = min(W, x + w + margin)
        let rw = cx1 - cx0, rh = cy1 - cy0
        var region = [UInt8](repeating: 0, count: rw * rh * 4)
        for ry in 0..<rh {
            for rx in 0..<rw {
                let fy = cy0 + ry, fx = cx0 + rx
                let src: Int
                let inside = fx >= x && fx < x + w && fy >= y && fy < y + h
                let d = (ry * rw + rx) * 4
                if inside { src = ((fy - y) * w + (fx - x)) * 4 } else { src = (fy * W + fx) * 4 }
                let buf = inside ? record : field
                region[d] = buf[src]; region[d + 1] = buf[src + 1]; region[d + 2] = buf[src + 2]; region[d + 3] = buf[src + 3]
            }
        }
        let hd = opaque(region, rw, rh)
        return crop(hd, w: rw * S, x: (x - cx0) * S, y: (y - cy0) * S, cw: w * S, ch: h * S)
    }

    static func pad(_ px: [UInt8], w: Int, h: Int, by p: Int, alpha: UInt8) -> [UInt8] {
        let pw = w + 2 * p, ph = h + 2 * p
        var out = [UInt8](repeating: 0, count: pw * ph * 4)
        if alpha != 0 { for i in stride(from: 3, to: out.count, by: 4) { out[i] = alpha } }
        for y in 0..<h {
            let s = y * w * 4, d = ((y + p) * pw + p) * 4
            out.replaceSubrange(d..<(d + w * 4), with: px[s..<(s + w * 4)])
        }
        return out
    }

    static func crop(_ px: [UInt8], w: Int, x: Int, y: Int, cw: Int, ch: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cw * ch * 4)
        for r in 0..<ch {
            let s = ((y + r) * w + x) * 4
            out.replaceSubrange((r * cw * 4)..<((r + 1) * cw * 4), with: px[s..<(s + cw * 4)])
        }
        return out
    }

    static func sha256(_ bytes: [UInt8]) -> String { SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() }

    /// The inputs of one table (make_pack.py load_table).
    struct TableData {
        var indices: [UInt8]       // 320 x 400 playfield indices
        var palette: [UInt8]       // 256 x RGB
        var sprites: [JSONValue]   // sprites.json "sprites"
        var spriteDir: URL
        var ball: (w: Int, h: Int, pixels: [UInt8], transparent: UInt8)?

        var fieldRGBA: [UInt8] {
            var out = [UInt8](repeating: 255, count: indices.count * 4)
            for (i, v) in indices.enumerated() {
                let c = Int(v) * 3
                out[i * 4] = palette[c]; out[i * 4 + 1] = palette[c + 1]; out[i * 4 + 2] = palette[c + 2]
            }
            return out
        }

        static func load(dataRoot: URL, table n: Int) throws -> TableData {
            let dir = dataRoot.appendingPathComponent("tables/EP\(n)", isDirectory: true)
            func json(_ rel: String) throws -> JSONValue {
                let u = dir.appendingPathComponent(rel)
                guard let d = try? Data(contentsOf: u) else { throw ImportError("EP\(n): cannot read \(u.path)") }
                return try parseJSON(d)
            }
            let npy = try NPYReader.read(contentsOf: dir.appendingPathComponent("playfield_idx.npy"))
            guard npy.rows == TableGeometry.height, npy.columns == TableGeometry.width else {
                throw ImportError("EP\(n): playfield_idx.npy is \(npy.rows)x\(npy.columns), expected 400x320")
            }
            var pal: [UInt8] = []
            for e in try json("palette.json").arrayValue ?? [] {
                for c in e.arrayValue ?? [] { pal.append(UInt8(clamping: c.intValue ?? 0)) }
            }
            guard pal.count == 768 else { throw ImportError("EP\(n): palette.json is not 256 RGB entries") }
            let sprites = try json("sprites/sprites.json")["sprites"]?.arrayValue ?? []
            let engine = try json("engine.json")
            var ball: (Int, Int, [UInt8], UInt8)?
            if let b = engine["ball"], let px = b["pixels"]?.arrayValue, !px.isEmpty,
               let w = b["w"]?.intValue, let h = b["h"]?.intValue, px.count == w * h {
                ball = (w, h, px.map { UInt8(clamping: $0.intValue ?? 0) }, UInt8(clamping: b["transparent"]?.intValue ?? 0))
            }
            return TableData(indices: npy.data, palette: pal, sprites: sprites,
                             spriteDir: dir.appendingPathComponent("sprites", isDirectory: true), ball: ball)
        }
    }
}

// MARK: - alignment check (make_pack.py --verify)

extension HDPackMaker {
    public struct AssetCheck: Sendable, Equatable {
        public var boxMAE: Double
        public var centreExact: Double
        public var bestShift: (dy: Int, dx: Int)
        public var shift0Error: Double
        public var aligned: Bool
        public static func == (a: AssetCheck, b: AssetCheck) -> Bool {
            a.boxMAE == b.boxMAE && a.centreExact == b.centreExact && a.bestShift == b.bestShift
                && a.shift0Error == b.shift0Error && a.aligned == b.aligned
        }
    }

    public struct Verification: Sendable {
        public var table: Int
        public var scale: Int
        /// playfield, the sprites (sorted), ball; nil = size mismatch.
        public var assets: [(name: String, check: AssetCheck?)]
        public var aggregateBestShift: (dy: Int, dx: Int)
        public var ok: Bool
        /// verify.json, as make_pack.py writes it.
        public var json: JSONValue

        public var allAligned: Bool { assets.allSatisfy { $0.check?.aligned ?? true } }
        public var summary: JSONValue { json["summary"] ?? .null }
    }

    /// Downsamples every asset of the pack back and compares it with the original pixels:
    /// box-average error, exact centre samples, and the box-average error of the HD image shifted
    /// by -S/2...S/2 pixels (circularly, like np.roll); the unshifted grid must fit best (ties
    /// for flat records; tiny repetitive records are decided by the centre samples), and the
    /// pixel-weighted sum over all assets must be minimal at (0, 0). Writes `verify.json` into
    /// the pack (`write: false` skips that). Computed in Double (numpy uses float32 means), so
    /// the numbers can differ from Python's in the last rounded digit.
    public static func verify(pack dir: URL, dataRoot: URL, table n: Int, write: Bool = true) throws -> Verification {
        let t = try TableData.load(dataRoot: dataRoot, table: n)
        guard let md = try? Data(contentsOf: dir.appendingPathComponent("pack.json")) else {
            throw ImportError("no pack.json in \(dir.path)")
        }
        let man = try parseJSON(md)
        guard let S = man["scale"]?.intValue, scales.contains(S) else { throw ImportError("\(dir.path)/pack.json: bad scale") }
        func hdImage(_ rel: String?) throws -> (w: Int, h: Int, rgba: [UInt8]) {
            guard let rel, let img = PNGFile.readStraight(dir.appendingPathComponent(rel)) else {
                throw ImportError("cannot read \(rel ?? "?") in \(dir.path)")
            }
            return img
        }
        let shifts: [(Int, Int)] = {
            let r = S / 2
            var c = [(0, 0)]
            for dy in -r...r { for dx in -r...r where (dy, dx) != (0, 0) { c.append((dy, dx)) } }
            return c
        }()
        var totals = [Double](repeating: 0, count: shifts.count)
        var assets: [(String, AssetCheck?)] = []
        var ok = true

        func run(_ name: String, hd: (w: Int, h: Int, rgba: [UInt8]), orig: [UInt8], ow: Int, oh: Int, alpha: Bool) {
            guard hd.w >= ow * S, hd.h >= oh * S else { assets.append((name, nil)); ok = false; return }
            let c = checkAsset(hd: hd, orig: orig, ow: ow, oh: oh, alpha: alpha, scale: S, shifts: shifts)
            for (k, e) in c.errors.enumerated() { totals[k] += e * Double(ow * oh) }
            assets.append((name, c.check))
            ok = ok && c.check.aligned
        }

        let field = t.fieldRGBA
        run("playfield", hd: try hdImage(man["playfield"]?.stringValue), orig: field, ow: TableGeometry.width, oh: TableGeometry.height, alpha: false)
        let sprites = man["sprites"]?.objectValue
        for name in (sprites?.keys ?? []).sorted() {
            let hd = try hdImage(sprites?[name]?["file"]?.stringValue)
            guard let orig = PNGFile.readStraight(t.spriteDir.appendingPathComponent(name + ".png")) else {
                throw ImportError("EP\(n): no original sprite \(name).png")
            }
            if orig.w * S != hd.w || orig.h * S != hd.h { assets.append((name, nil)); ok = false; continue }
            run(name, hd: hd, orig: orig.rgba, ow: orig.w, oh: orig.h, alpha: false)
        }
        if let e = man["ball"], let b = t.ball {
            var orig = [UInt8](repeating: 255, count: b.w * b.h * 4)
            for i in 0..<(b.w * b.h) {
                let c = Int(b.pixels[i]) * 3
                orig[i * 4] = t.palette[c]; orig[i * 4 + 1] = t.palette[c + 1]; orig[i * 4 + 2] = t.palette[c + 2]
                if b.pixels[i] == b.transparent { orig[i * 4 + 3] = 0 }
            }
            run("ball", hd: try hdImage(e["file"]?.stringValue), orig: orig, ow: b.w, oh: b.h, alpha: true)
        }

        // min over (total, not (0, 0)) in candidate order, as Python's min(dict, key=...)
        var agg = 0
        for k in 1..<shifts.count where totals[k] < totals[agg] { agg = k }
        let aggShift = shifts[agg]
        ok = ok && agg == 0

        func entry(_ c: AssetCheck?) -> JSONValue {
            guard let c else { return .object(JSONObject([("error", .string("size mismatch"))])) }
            return .object(JSONObject([
                ("box_mae", .double(c.boxMAE)), ("centre_exact", .double(c.centreExact)),
                ("best_shift", .array([.int(c.bestShift.dy), .int(c.bestShift.dx)])),
                ("shift0_err", .double(c.shift0Error)), ("aligned", .bool(c.aligned)),
            ]))
        }
        let checked = assets.compactMap { a in a.1.map { (a.0, $0) } }
        let others = checked.filter { $0.0 != "playfield" }
        func mean(_ v: [Double], _ empty: Double) -> Double { v.isEmpty ? empty : v.reduce(0, +) / Double(v.count) }
        let pair = JSONValue.array([.int(aggShift.0), .int(aggShift.1)])
        let summary = JSONObject([
            ("assets", .int(checked.count)),
            ("all_aligned", .bool(checked.allSatisfy { $0.1.aligned })),
            ("aggregate_best_shift (all assets, pixel-weighted)", pair),
            ("best_shift_nonzero", .array(checked.filter { $0.1.bestShift != (0, 0) }.map(\.0).sorted().map { .string($0) })),
            ("playfield", entry(checked.first { $0.0 == "playfield" }?.1)),
            ("sprites_box_mae_mean", .double(pyRound(mean(others.map(\.1.boxMAE), 0), 3))),
            ("sprites_centre_exact_mean", .double(pyRound(mean(others.map(\.1.centreExact), 1), 4))),
        ])
        let report = JSONValue.object(JSONObject([
            ("table", .int(n)), ("scale", .int(S)),
            ("assets", .object(JSONObject(assets.map { ($0.0, entry($0.1)) }))),
            ("aggregate_best_shift", pair),
            ("summary", .object(summary)),
        ]))
        if write { try Data(serialize(report, style: .indent(1)).utf8).write(to: dir.appendingPathComponent("verify.json")) }
        return Verification(table: n, scale: S, assets: assets.map { (name: $0.0, check: $0.1) },
                            aggregateBestShift: (aggShift.0, aggShift.1), ok: ok, json: report)
    }

    /// make_pack.py verify().check for one asset. `orig` is RGBA (w x h); `alpha` compares
    /// premultiplied colour (the ball), otherwise RGB only.
    static func checkAsset(hd: (w: Int, h: Int, rgba: [UInt8]), orig: [UInt8], ow: Int, oh: Int, alpha: Bool, scale S: Int,
                           shifts: [(Int, Int)]) -> (check: AssetCheck, errors: [Double]) {
        let HW = hd.w, HH = hd.h
        // HD source values (premultiplied when comparing with alpha), 3 per pixel
        func values(_ px: [UInt8], _ count: Int) -> [Double] {
            var v = [Double](repeating: 0, count: count * 3)
            for i in 0..<count {
                let a = alpha ? Double(px[i * 4 + 3]) / 255 : 1
                for c in 0..<3 { v[i * 3 + c] = Double(px[i * 4 + c]) * a }
            }
            return v
        }
        let src = values(hd.rgba, HW * HH), ref = values(orig, ow * oh)
        // centre samples
        var good = 0, total = 0
        for y in 0..<oh {
            for x in 0..<ow {
                if alpha && orig[(y * ow + x) * 4 + 3] != 255 { continue }
                let hi = ((y * S + S / 2) * HW + x * S + S / 2) * 4
                var exact = true
                for c in 0..<3 where abs(Int(hd.rgba[hi + c]) - Int(orig[(y * ow + x) * 4 + c])) > 1 { exact = false }
                total += 1
                if exact { good += 1 }
            }
        }
        let centre = total == 0 ? 1.0 : Double(good) / Double(total)

        let cut = min(ow, oh) > 4 ? 1 : 0
        let inv = 1.0 / Double(S * S)
        // per shift: (error inside the cut, error over every block; the latter only for (0, 0))
        var results = [(Double, Double)](repeating: (0, 0), count: shifts.count)
        results.withUnsafeMutableBufferPointer { rb in
            let out = UnsafeMutableSendable(rb)
            DispatchQueue.concurrentPerform(iterations: shifts.count) { k in
                let (dy, dx) = shifts[k]
                var sum = 0.0, all = 0.0
                for by in 0..<oh {
                    let inCutY = by >= cut && by < oh - cut
                    if !inCutY && k != 0 { continue }
                    for bx in 0..<ow {
                        let inCut = inCutY && bx >= cut && bx < ow - cut
                        if !inCut && k != 0 { continue }
                        var acc = (0.0, 0.0, 0.0)
                        for sy in 0..<S {
                            // np.roll(hd, dy, 0)[Y] = hd[(Y - dy) mod HH]
                            let yy = ((by * S + sy - dy) % HH + HH) % HH
                            for sx in 0..<S {
                                let xx = ((bx * S + sx - dx) % HW + HW) % HW
                                let p = (yy * HW + xx) * 3
                                acc.0 += src[p]; acc.1 += src[p + 1]; acc.2 += src[p + 2]
                            }
                        }
                        let r = (by * ow + bx) * 3
                        let e = abs(acc.0 * inv - ref[r]) + abs(acc.1 * inv - ref[r + 1]) + abs(acc.2 * inv - ref[r + 2])
                        if inCut { sum += e }
                        if k == 0 { all += e }
                    }
                }
                out.buffer[k] = (sum / Double((ow - 2 * cut) * (oh - 2 * cut) * 3), all / Double(ow * oh * 3))
            }
        }
        let errors = results.map(\.0)
        let mae = results[0].1
        var best = 0
        for k in 1..<shifts.count where errors[k] < errors[best] - 1e-9 { best = k }
        let small = ow * oh < 400
        let aligned = errors[0] <= errors[best] + 0.1 || (small && centre >= 0.9)
        let check = AssetCheck(boxMAE: pyRound(mae, 3), centreExact: pyRound(centre, 4), bestShift: shifts[best],
                               shift0Error: pyRound(errors[0], 3), aligned: aligned)
        return (check, errors)
    }
}
