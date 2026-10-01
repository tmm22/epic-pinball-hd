import Foundation
import XCTest
@testable import PinballImport

/// HDPackMaker (the Swift port of tools/hdpack/make_pack.py): the pack layout and alignment
/// check on a synthetic table (no game data), and pixel parity with the Python tool on that
/// table and on the user's EP1 / EP10 (skipped without extracted/ or the venv).
final class HDPackTests: XCTestCase {
    // MARK: synthetic fixture (made-up shapes and colours, not game data)

    /// tables/EP<n>/ with a playfield of shapes, a lamp, a flipper frame that crosses the table's
    /// right edge, a digit, a display record, two font8 glyphs, a font5 glyph (not packed) and a ball.
    static func writeSyntheticTable(root: URL, table n: Int = 1) throws {
        let dir = root.appendingPathComponent("tables/EP\(n)", isDirectory: true)
        let sdir = dir.appendingPathComponent("sprites", isDirectory: true)
        try FileManager.default.createDirectory(at: sdir, withIntermediateDirectories: true)
        var pal = [UInt8](repeating: 0, count: 768)
        for i in 1..<256 { pal[i * 3] = UInt8((i * 37) % 256); pal[i * 3 + 1] = UInt8((i * 91 + 40) % 256); pal[i * 3 + 2] = UInt8((255 - i * 13 % 256) % 256) }
        let W = 320, H = 400
        var idx = [UInt8](repeating: 0, count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                var v = UInt8(1 + (x / 40 + y / 50) % 4)
                let dx = x - 160, dy = y - 200
                if dx * dx + dy * dy < 3600 { v = 10 }
                if dx * dx + dy * dy < 900 { v = 11 }
                if abs(x - y / 2) < 2 { v = 20 }
                if (250..<290).contains(x), (300..<340).contains(y), (x + y) % 2 == 0 { v = 30 }
                if (120..<140).contains(x), (60..<64).contains(y) { v = 40 }
                idx[y * W + x] = v
            }
        }
        try NPYFile.data(uint8: idx, shape: [H, W]).write(to: dir.appendingPathComponent("playfield_idx.npy"))
        let palJSON = "[" + (0..<256).map { "[\(pal[$0 * 3]), \(pal[$0 * 3 + 1]), \(pal[$0 * 3 + 2])]" }.joined(separator: ", ") + "]"
        try Data(palJSON.utf8).write(to: dir.appendingPathComponent("palette.json"))

        func record(_ name: String, x: Int, y: Int, w: Int, h: Int, recolour: (Int, Int, UInt8) -> UInt8) throws {
            var px = [UInt8](repeating: 0, count: w * h)
            for ry in 0..<h { for rx in 0..<w {
                let fy = min(H - 1, y + ry), fx = min(W - 1, x + rx)
                px[ry * w + rx] = recolour(rx, ry, idx[fy * W + fx])
            } }
            try PNGFile.writeIndexed(sdir.appendingPathComponent(name + ".png"), width: w, height: h, indices: px, palette: pal)
        }
        try record("lamp000_a", x: 150, y: 180, w: 24, h: 20) { rx, ry, v in (rx - 12) * (rx - 12) + (ry - 10) * (ry - 10) < 40 ? 50 : v }
        // (not a straight diagonal: one would fit the HD grid shifted along itself as well as unshifted,
        // a near-tie that float32 (numpy) and Double (Swift) break differently)
        try record("flipper0R_0", x: 300, y: 370, w: 30, h: 25) { rx, ry, v in (rx - 4) * (rx - 4) + ry * ry < 260 ? 60 : v }
        try record("digit_0", x: 0, y: 0, w: 12, h: 17) { rx, ry, _ in (rx == 2 || rx == 9 || ry == 1 || ry == 15) ? 70 : 0 }
        try record("pause", x: 0, y: 0, w: 40, h: 10) { rx, ry, _ in (rx / 4 + ry / 3) % 2 == 0 ? 80 : 81 }
        try record("font5_41", x: 0, y: 0, w: 5, h: 5) { _, _, _ in 1 }
        for (name, bits) in [("font8_20", [UInt8](repeating: 0, count: 8)), ("font8_41", [0x18, 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x00])] {
            var rgba = [UInt8](repeating: 0, count: 8 * 8 * 4)
            for y in 0..<8 { for x in 0..<8 where bits[y] & (0x80 >> x) != 0 {
                let i = (y * 8 + x) * 4
                rgba[i] = 255; rgba[i + 1] = 255; rgba[i + 2] = 255; rgba[i + 3] = 255
            } }
            try PNGFile.write(sdir.appendingPathComponent(name + ".png"), width: 8, height: 8, rgba: rgba)
        }
        let sprites = """
        {"table": \(n), "sprites": [
         {"name": "lamp000_a", "group": "lamp", "format": "planar", "w": 24, "h": 20, "x": 150, "y": 180},
         {"name": "flipper0R_0", "group": "flipper", "format": "planar", "w": 30, "h": 25, "x": 300, "y": 370},
         {"name": "digit_0", "group": "digit", "format": "planar", "w": 12, "h": 17},
         {"name": "pause", "group": "display", "format": "chunky", "w": 40, "h": 10},
         {"name": "missing_lamp", "group": "lamp", "format": "planar", "w": 4, "h": 4, "x": 0, "y": 0},
         {"name": "font5_41", "group": "font", "format": "font5", "w": 5, "h": 5, "char": 65},
         {"name": "font8_20", "group": "font", "format": "font8", "w": 8, "h": 8, "char": 32},
         {"name": "font8_41", "group": "font", "format": "font8", "w": 8, "h": 8, "char": 65}
        ]}
        """
        try Data(sprites.utf8).write(to: sdir.appendingPathComponent("sprites.json"))
        var ball: [Int] = []
        for y in 0..<14 { for x in 0..<15 { let d = (x - 7) * (x - 7) + (y - 7) * (y - 7); ball.append(d > 42 ? 0 : d > 20 ? 90 : d > 6 ? 91 : 92) } }
        try Data("{\"ball\": {\"w\": 15, \"h\": 14, \"transparent\": 0, \"pixels\": [\(ball.map(String.init).joined(separator: ", "))]}}".utf8)
            .write(to: dir.appendingPathComponent("engine.json"))
    }

    // MARK: scaler

    func testNearestAndFlatXBRZ() {
        let px: [UInt8] = [10, 20, 30, 255, 40, 50, 60, 255]
        XCTAssertEqual(XBRZ.nearest(px, width: 2, height: 1, scale: 2),
                       [10, 20, 30, 255, 10, 20, 30, 255, 40, 50, 60, 255, 40, 50, 60, 255,
                        10, 20, 30, 255, 10, 20, 30, 255, 40, 50, 60, 255, 40, 50, 60, 255])
        func flat(_ n: Int) -> [UInt8] { (0..<(n * 4)).map { $0 % 4 == 3 ? 255 : 77 } }
        for S in 2...4 { XCTAssertEqual(XBRZ.scaleRGBA8(flat(5 * 4), width: 5, height: 4, scale: S), flat(5 * S * 4 * S)) }
    }

    /// A diagonal edge is smoothed (new in-between pixels) but every pixel centre away from the edge keeps its colour.
    func testXBRZSmoothsADiagonalAndKeepsCentres() {
        let n = 8
        var px = [UInt8](repeating: 255, count: n * n * 4)
        for y in 0..<n { for x in 0..<n where x > y { px[(y * n + x) * 4] = 0; px[(y * n + x) * 4 + 1] = 0; px[(y * n + x) * 4 + 2] = 0 } }
        let S = 4
        let out = XBRZ.scaleRGBA8(px, width: n, height: n, scale: S)
        XCTAssertEqual(out.count, n * S * n * S * 4)
        var mixed = 0
        for i in stride(from: 0, to: out.count, by: 4) where out[i] != 0 && out[i] != 255 { mixed += 1 }
        XCTAssertGreaterThan(mixed, 0, "anti-aliased edge expected")
        for y in 0..<n { for x in 0..<n where abs(x - y) > 1 {
            let o = ((y * S + S / 2) * n * S + x * S + S / 2) * 4
            XCTAssertEqual(out[o], px[(y * n + x) * 4], "centre of (\(x), \(y))")
        } }
        XCTAssertTrue(out.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 255 })
    }

    func testPadCropAndContextFallback() {
        let px: [UInt8] = [1, 2, 3, 4]
        let p = HDPackMaker.pad(px, w: 1, h: 1, by: 1, alpha: 9)
        XCTAssertEqual(p.count, 9 * 4)
        XCTAssertEqual(Array(p[16..<20]), px)
        XCTAssertEqual(Array(p[0..<4]), [0, 0, 0, 9])
        XCTAssertEqual(HDPackMaker.crop(p, w: 3, x: 1, y: 1, cw: 1, ch: 1), px)
        // a record reaching outside the table is scaled on its own (no context)
        var called: (Int, Int)?
        _ = HDPackMaker.contextScaled(field: [], record: [UInt8](repeating: 0, count: 4 * 4 * 4), w: 4, h: 4, x: 318, y: 0, scale: 2) { r, w, h in
            called = (w, h); return XBRZ.nearest(r, width: w, height: h, scale: 2)
        }
        XCTAssertEqual(called.map { [$0.0, $0.1] }, [4, 4])
    }

    // MARK: pack layout, verify, cancellation

    func testSyntheticPackLayoutAndVerify() throws {
        let root = try tempDir("hdpack")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSyntheticTable(root: root)
        for (method, S) in [(HDPackMaker.Method.xbrz, 3), (.nearest, 2)] {
            let out = root.appendingPathComponent("packs-\(method.rawValue)/EP1", isDirectory: true)
            let fractions = LockedFractions()
            let r = try HDPackMaker.make(table: 1, dataRoot: root, output: out, scale: S, method: method, progress: { fractions.append($0.fraction) })
            XCTAssertEqual(r.sprites, 4)
            XCTAssertTrue(r.ball)
            XCTAssertEqual(r.font8Glyphs, 0x41 - 0x20 + 1)
            XCTAssertEqual(fractions.values.last, 1)
            XCTAssertEqual(fractions.values, fractions.values.sorted())
            let man = try parseJSON(Data(contentsOf: out.appendingPathComponent("pack.json")))
            XCTAssertEqual(man.objectValue?.keys, ["format", "version", "table", "scale", "generator", "source", "playfield", "sprites", "fonts", "note", "ball"])
            XCTAssertEqual(man["format"]?.stringValue, "epic-pinball-hdpack")
            XCTAssertEqual(man["scale"]?.intValue, S)
            XCTAssertEqual(man["generator"]?["method"]?.stringValue, method.rawValue)
            XCTAssertEqual(man["sprites"]?.objectValue?.keys, ["lamp000_a", "flipper0R_0", "digit_0", "pause"])
            XCTAssertEqual(man["sprites"]?["lamp000_a"]?.objectValue?.keys, ["file", "w", "h", "group", "x", "y"])
            let idx = try Data(contentsOf: root.appendingPathComponent("tables/EP1/playfield_idx.npy"))   // header + 400 x 320 bytes
            XCTAssertEqual(man["source"]?["playfield_idx_sha256"]?.stringValue, HDPackMaker.sha256(Array(idx.suffix(320 * 400))))
            for (rel, w, h) in [("playfield.png", 320, 400), ("sprites/lamp000_a.png", 24, 20), ("sprites/flipper0R_0.png", 30, 25),
                                ("sprites/ball.png", 15, 14), ("fonts/font8.png", 8, 8 * (0x41 - 0x20 + 1))] {
                let img = try XCTUnwrap(PNGFile.readStraight(out.appendingPathComponent(rel)), rel)
                XCTAssertEqual([img.w, img.h], [w * S, h * S], rel)
            }
            // the ball keeps its transparent corners; the glyph 'A' has coverage, ' ' none
            let ball = try XCTUnwrap(PNGFile.readStraight(out.appendingPathComponent("sprites/ball.png")))
            XCTAssertEqual(ball.rgba[3], 0)
            XCTAssertEqual(ball.rgba[((7 * S) * ball.w + 7 * S) * 4 + 3], 255)
            let atlas = try XCTUnwrap(PNGFile.readStraight(out.appendingPathComponent("fonts/font8.png")))
            let cell = 8 * S
            XCTAssertTrue((0..<(cell * cell)).allSatisfy { atlas.rgba[$0 * 4] == 0 })
            XCTAssertTrue(((0x41 - 0x20) * cell * cell..<(0x42 - 0x20) * cell * cell).contains { atlas.rgba[$0 * 4] == 255 })

            let v = try HDPackMaker.verify(pack: out, dataRoot: root, table: 1)
            XCTAssertTrue(v.ok, "\(v.json)")
            XCTAssertEqual(v.assets.map(\.name), ["playfield", "digit_0", "flipper0R_0", "lamp000_a", "pause", "ball"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("verify.json").path))
            if method == .nearest {
                XCTAssertTrue(v.assets.allSatisfy { $0.check?.boxMAE == 0 && $0.check?.centreExact == 1 }, "\(v.json)")
            }
        }
    }

    func testVerifyDetectsAShiftedPack() throws {
        let root = try tempDir("hdpack-shift")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSyntheticTable(root: root)
        let out = root.appendingPathComponent("packs/EP1", isDirectory: true)
        try HDPackMaker.make(table: 1, dataRoot: root, output: out, scale: 2, method: .nearest)
        // shift the HD playfield by 1 HD pixel (half an original pixel) right and down
        let url = out.appendingPathComponent("playfield.png")
        let pf = try XCTUnwrap(PNGFile.readStraight(url))
        var moved = pf.rgba
        for y in 0..<pf.h { for x in 0..<pf.w {
            let s = (((y - 1 + pf.h) % pf.h) * pf.w + (x - 1 + pf.w) % pf.w) * 4, d = (y * pf.w + x) * 4
            for c in 0..<4 { moved[d + c] = pf.rgba[s + c] }
        } }
        try PNGFile.write(url, width: pf.w, height: pf.h, rgba: moved)
        let v = try HDPackMaker.verify(pack: out, dataRoot: root, table: 1, write: false)
        let check = try XCTUnwrap(v.assets.first { $0.name == "playfield" }?.check)
        XCTAssertFalse(check.aligned)
        XCTAssertEqual([check.bestShift.dy, check.bestShift.dx], [-1, -1])
        XCTAssertFalse(v.ok)
    }

    func testCancellationKeepsTheExistingPackAndBadScaleThrows() throws {
        let root = try tempDir("hdpack-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSyntheticTable(root: root)
        let out = root.appendingPathComponent("packs/EP1", isDirectory: true)
        try HDPackMaker.make(table: 1, dataRoot: root, output: out, scale: 2, method: .nearest)
        let before = try Data(contentsOf: out.appendingPathComponent("pack.json"))
        let calls = LockedFractions()
        XCTAssertThrowsError(try HDPackMaker.make(table: 1, dataRoot: root, output: out, scale: 3, isCancelled: {
            calls.append(0); return calls.values.count > 3
        })) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("pack.json")), before)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: out.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["EP1"])
        XCTAssertThrowsError(try HDPackMaker.make(table: 1, dataRoot: root, output: out, scale: 9))
        XCTAssertThrowsError(try HDPackMaker.make(table: 2, dataRoot: root, output: root.appendingPathComponent("x/EP2"), scale: 2))
    }

    // MARK: parity with tools/hdpack/make_pack.py

    /// Runs make_pack.py (with --verify) into `pyOut`, the Swift maker (+ verify) into `swOut`,
    /// and compares the decoded pixels of every asset (Pillow decodes both), pack.json (except
    /// generator.tool) and verify.json (numbers to 0.0015: Python averages in float32).
    func comparePacks(table: Int, scale: Int, method: HDPackMaker.Method, dataRoot: URL) throws {
        let tmp = try tempDir("hdpack-parity")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pyOut = tmp.appendingPathComponent("py/EP\(table)"), swOut = tmp.appendingPathComponent("swift/EP\(table)")
        let run = """
        import runpy, sys
        sys.argv = ["make_pack.py"] + sys.argv[1:]
        try:
            runpy.run_path("tools/hdpack/make_pack.py", run_name="__main__")
        except SystemExit as e:
            if e.code not in (0, None, 1): raise
        """
        guard let r = Repo.runPython(run, args: ["--table", "\(table)", "--scale", "\(scale)", "--method", method.rawValue,
                                                 "--data", dataRoot.path, "--out", pyOut.path, "--verify"]),
              r.status == 0, FileManager.default.fileExists(atPath: pyOut.appendingPathComponent("verify.json").path) else {
            throw XCTSkip(".venv/bin/python with numpy and Pillow not available")
        }
        let t0 = Date()
        try HDPackMaker.make(table: table, dataRoot: dataRoot, output: swOut, scale: scale, method: method)
        let made = Date().timeIntervalSince(t0)
        let v = try HDPackMaker.verify(pack: swOut, dataRoot: dataRoot, table: table)
        print("EP\(table) \(scale)x \(method.rawValue): Swift pack in \(String(format: "%.2f", made)) s, verify ok \(v.ok)")
        guard let c = Repo.runPython(Self.compareScript, args: [pyOut.path, swOut.path]), c.status == 0,
              let j = try JSONSerialization.jsonObject(with: Data(c.out.utf8)) as? [String: Any] else {
            return XCTFail("compare script failed")
        }
        XCTAssertEqual(j["manifest_equal"] as? Bool, true, "\(j)")
        XCTAssertEqual(j["files_differing"] as? Int, 0, "\(j)")
        XCTAssertEqual((j["verify_diff"] as? [Any])?.count, 0, "\(j)")
        XCTAssertGreaterThan(j["files"] as? Int ?? 0, 3)
    }

    static let compareScript = """
    import json, os, sys
    import numpy as np
    from PIL import Image
    a, b = sys.argv[1], sys.argv[2]
    ma, mb = json.load(open(os.path.join(a, "pack.json"))), json.load(open(os.path.join(b, "pack.json")))
    ma["generator"].pop("tool"); mb["generator"].pop("tool")
    files = [ma["playfield"]] + [e["file"] for e in ma["sprites"].values()] + ([ma["ball"]["file"]] if "ball" in ma else []) \\
        + [f["file"] for f in ma["fonts"].values()]
    diff = []
    for f in files:
        x = np.array(Image.open(os.path.join(a, f)).convert("RGBA")).astype(int)
        y = np.array(Image.open(os.path.join(b, f)).convert("RGBA")).astype(int)
        if x.shape != y.shape or np.any(x != y): diff.append(f)
    va, vb = json.load(open(os.path.join(a, "verify.json"))), json.load(open(os.path.join(b, "verify.json")))
    vdiff = [] if list(va["assets"]) == list(vb["assets"]) else ["asset order"]
    for k, p in va["assets"].items():
        q = vb["assets"].get(k, {})
        for f, x in p.items():
            ok = abs(x - q.get(f, 1e9)) <= 0.0015 if isinstance(x, float) else x == q.get(f)
            if not ok: vdiff.append([k, f, x, q.get(f)])
    for k, x in va["summary"].items():
        y = vb["summary"].get(k)
        ok = abs(x - y) <= 0.0015 if isinstance(x, float) else (x == y if k != "playfield" else all(
            abs(x[f] - y[f]) <= 0.0015 if isinstance(x[f], float) else x[f] == y[f] for f in x))
        if not ok: vdiff.append(["summary", k, x, y])
    if va["aggregate_best_shift"] != vb["aggregate_best_shift"]: vdiff.append("aggregate")
    print(json.dumps({"manifest_equal": ma == mb and list(ma) == list(mb), "files": len(files), "files_differing": len(diff),
                      "differing": diff[:10], "verify_diff": vdiff[:20]}))
    """

    /// No game data needed: the synthetic table through both generators, at three scales and both methods.
    func testSyntheticTableMatchesPython() throws {
        let root = try tempDir("hdpack-synth")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSyntheticTable(root: root)
        for (S, m) in [(2, HDPackMaker.Method.xbrz), (3, .xbrz), (4, .xbrz), (3, .nearest)] {
            try comparePacks(table: 1, scale: S, method: m, dataRoot: root)
        }
    }

    /// The user's own tables (extracted/ by the Python tools): EP1 and EP10 at 4x, pixel-identical.
    func testUserTablesMatchPython() throws {
        try Repo.requireExtracted()
        for n in [1, 10] { try comparePacks(table: n, scale: 4, method: .xbrz, dataRoot: Repo.extracted) }
    }
}

final class LockedFractions: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [Double] = []
    func append(_ x: Double) { lock.lock(); v.append(x); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return v }
}
