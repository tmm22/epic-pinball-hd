import Foundation
import Metal
import XCTest
import PinballCore
@testable import PinballRender

/// FNV-1a 64 over rendered bytes (golden values recorded from the renderer before the
/// enhanced pipeline existed, so classic output is proven byte-identical).
func fnv64(_ bytes: [UInt8]) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in bytes { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
    return String(format: "%016llx", h)
}

/// A table loaded the way the front end does it (assets, EXE graphics, strip spec, composer),
/// or nil when the user's extracted data / EXE is not present.
struct RealTable {
    let assets: TableAssets
    let engine: EngineData
    let composer: ClassicComposer
    let dataRoot: URL

    static func load(_ n: Int) -> RealTable? {
        let root = DataLocator.packageRelativeDefault
        guard let assets = try? TableAssets.load(dataRoot: root, table: n),
              let engine = try? EngineData.load(contentsOf: assets.directory.appendingPathComponent("engine.json")),
              let exeURL = TableExe.locate(table: n, dataRoot: root, environment: [:]),
              let exe = try? TableExe(contentsOf: exeURL),
              let gfx = try? GameGraphics.load(tableDirectory: assets.directory, palette: assets.palette, exe: exe) else { return nil }
        var spec = StripSpec.scan(exe: exe, codeSegment: gfx.codeSegment, dataSegment: gfx.dataSegment, table: n, displayRows: gfx.displayRows)
        if gfx.plunger == nil { spec.fallbacks.removeAll { $0 == "plunger base" } }
        let c = ClassicComposer(graphics: gfx, spec: spec, exe: exe, playfield: assets.indices, engine: engine)
        return RealTable(assets: assets, engine: engine, composer: c, dataRoot: root)
    }

    var stripRows: Int { max(0, ScreenLayout.screenRows - composer.spec.windowRows) }

    /// Flippers at rest (last frame), ball at a fixed spot.
    func scene(viewTop: Double, full: Bool = false, ballAt: Vec2 = Vec2(200, 250)) -> SceneState {
        let flippers = engine.flippers.enumerated().map { i, f in
            SceneState.FlipperSprite(index: i, frame: (f.sprite?.frames.count ?? 4) - 1, pivot: .zero, tip: .zero, radius: 3)
        }
        let ball = SceneState.BallSprite(topLeft: ballAt, width: engine.ball.w, height: engine.ball.h, pixels: engine.ball.pixels)
        return SceneState(viewTop: full ? 0 : viewTop, viewHeight: full ? 400 : Double(composer.spec.windowRows),
                          ball: ball, flippers: flippers)
    }

    func state(lampsA: Bool = true) -> PresentationState {
        var s = PresentationState()
        s.lamps = Array(repeating: lampsA, count: composer.graphics.lampCount)
        s.scores = [98_765_430]
        s.ballNumber = 2
        s.currentPlayer = 0
        return s
    }

    func message() -> DotMessage? {
        guard let exe = composer.exe else { return nil }
        if assets.table == 1 { return DotMessage(text: exe.cString(at: 0x873, max: 64), ax: 0x1, di: 0x12C0) }
        if assets.table == 10 { return DotMessage(text: exe.cString(at: 0x11DC, max: 64), ax: 0x101, di: 3 * 320) }
        return nil
    }
}

final class EnhancedRenderTests: XCTestCase {
    static var printGolden: Bool { ProcessInfo.processInfo.environment["EP_PRINT_GOLDEN"] != nil }

    func synthAssets() throws -> TableAssets {
        let w = TableGeometry.width, h = TableGeometry.height
        var idx = [UInt8](repeating: 0, count: w * h)
        // Blocks, diagonals and single pixels so every filter branch sees edges.
        for y in 0..<h {
            for x in 0..<w {
                var v = ((x / 8) + (y / 8) * 3) & 0x3F
                if (x + y) % 23 == 0 { v = 200 }
                if x % 37 == 5 && y % 29 == 7 { v = 255 }
                idx[y * w + x] = UInt8(v)
            }
        }
        var entries: [Palette.RGB] = []
        for i in 0..<256 { entries.append(Palette.RGB(r: UInt8((i * 37) & 0xFF), g: UInt8((i * 91 + 17) & 0xFF), b: UInt8((i * 13 + 90) & 0xFF))) }
        return TableAssets(table: 1, indices: idx, palette: try Palette(entries: entries), directory: URL(fileURLWithPath: "/"))
    }

    /// Classic nearest output must stay byte-identical to the pre-enhanced renderer.
    func testClassicNearestIsByteIdenticalSynthetic() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let assets = try synthAssets()
        var atlas = [UInt8]()
        for row in 0..<8 { for c in 0..<6 { atlas += row < 4 ? [255, UInt8(c * 40), 0, 255] : [0, 255, UInt8(c * 40), c == 2 ? 0 : 255] } }
        let sprites = FlipperSpriteSet(entries: [.init(x: 60, y: 300, w: 6, h: 4, frameRows: [0, 4])], atlasWidth: 6, atlasHeight: 8, atlas: atlas)
        var ball = [UInt8](repeating: 0, count: 210)
        for i in 0..<210 where (i % 15) > 2 && (i % 15) < 12 && i / 15 > 1 && i / 15 < 12 { ball[i] = UInt8(100 + i % 7) }
        let cases: [(String, SceneState, Int, Int, PixelAspect)] = [
            ("2x window", SceneState(viewTop: 37, viewHeight: 200, ball: .init(topLeft: Vec2(100, 60), pixels: ball),
                                     flippers: [.init(index: 0, frame: 1, pivot: .zero, tip: .zero, radius: 3)]), 640, 400, .square),
            ("fit 1000x700 frac", SceneState(viewTop: 120.4, viewHeight: 200, ball: .init(topLeft: Vec2(40.5, 200.25), pixels: ball),
                                             flippers: []), 1000, 700, .square),
            ("vga 5x", SceneState(viewTop: 0, viewHeight: 200, ball: .init(topLeft: Vec2(10, 10), pixels: nil), flippers: []), 1600, 1200, .vga),
            ("full", SceneState(viewTop: 0, viewHeight: 400, ball: nil,
                                flippers: [.init(index: 0, frame: 0, pivot: Vec2(40, 300), tip: Vec2(80, 310), radius: 3)]), 640, 800, .square),
            ("tiny", SceneState(viewTop: 3, viewHeight: 200, ball: nil, flippers: []), 200, 150, .square),
        ]
        let golden = ["2x window": "65bc64600eb2d3dd", "fit 1000x700 frac": "a9988d422a5a2dae", "vga 5x": "212de15622e302f1",
                      "full": "04279aa49328fd0d", "tiny": "a2f9683502921b48"]
        var failures: [String] = []
        for (name, scene, w, h, aspect) in cases {
            let r = try PinballRenderer(device: device, assets: assets, flipperSprites: sprites)
            r.aspect = aspect
            let px = try r.renderOffscreen(scene: scene, width: w, height: h)
            let hash = fnv64(px)
            if Self.printGolden { print("GOLDEN synthetic \"\(name)\": \"\(hash)\",") }
            if golden[name] != hash { failures.append("\(name): \(hash) != \(golden[name] ?? "-")") }
        }
        if !Self.printGolden { XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; ")) }
    }

    /// The same on the user's real tables (lamps, flippers, strip, dot messages); skipped without data.
    func testClassicNearestIsByteIdenticalRealTables() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let golden: [String: String] = [
            "EP1 3x": "29b7caa074f3ab4d", "EP1 vga5": "835108d00297f249", "EP1 full2": "a8f3d120c9d4830d",
            "EP8 3x": "6df79c3ad45a9d32", "EP8 vga5": "0f88af3a6121100d", "EP8 full2": "6c3bd5071e111f15",
            // EP10 3x / vga5 re-recorded: strip row 0 is render_frame's clear colour 22h, not the panel's 23h
            // (EP10 cs:3F07; harness VRAM and DOSBox-X capture, docs/enhanced/presentation.md section 2).
            // Only those 320 strip pixels changed.
            "EP10 3x": "098b4e0a9c4efb73", "EP10 vga5": "04154ba33ce25895", "EP10 full2": "4e933d8365cbeead",
        ]
        var ran = 0
        var failures: [String] = []
        for n in [1, 8, 10] {
            guard let t = RealTable.load(n) else { continue }
            ran += 1
            let variants: [(String, SceneState, Int, Int, PixelAspect, Bool)] = [
                ("3x", t.scene(viewTop: 150), 960, 720, .square, true),
                ("vga5", t.scene(viewTop: 60), 1600, 1440, .vga, false),
                ("full2", t.scene(viewTop: 0, full: true), 640, 800, .square, true),
            ]
            for (name, scene, w, h, aspect, lampsA) in variants {
                let r = try PinballRenderer(device: device, assets: t.assets)
                let c = ClassicComposer(graphics: t.composer.graphics, spec: t.composer.spec, exe: t.composer.exe,
                                        playfield: t.assets.indices, engine: t.engine)
                r.attach(composer: c)
                r.aspect = aspect
                r.stripRows = t.stripRows
                r.present(t.state(lampsA: lampsA), message: t.message(), flippers: scene.flippers, plungerY: nil)
                let px = try r.renderOffscreen(scene: scene, width: w, height: h)
                let key = "EP\(n) \(name)"
                let hash = fnv64(px)
                if Self.printGolden { print("GOLDEN real \"\(key)\": \"\(hash)\",") }
                if let g = golden[key], g != hash { failures.append("\(key): \(hash) != \(g)") }
            }
        }
        if ran == 0 { throw XCTSkip("no extracted data / original EXEs") }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    // MARK: - snapshots / measurements (opt-in)

    /// Renders one real-table frame with the given settings.
    static func render(_ t: RealTable, device: MTLDevice, settings: RenderSettings, width: Int, height: Int,
                       viewTop: Double = 150, full: Bool = false, lampsA: Bool = true, ballAt: Vec2 = Vec2(200, 250),
                       interpolation: MotionInterpolation? = nil, aspect: PixelAspect = .square) throws -> (PinballRenderer, [UInt8]) {
        let r = try PinballRenderer(device: device, assets: t.assets)
        let c = ClassicComposer(graphics: t.composer.graphics, spec: t.composer.spec, exe: t.composer.exe,
                                playfield: t.assets.indices, engine: t.engine)
        r.attach(composer: c)
        r.settings = settings
        r.aspect = aspect
        r.stripRows = t.stripRows
        r.interpolation = interpolation
        let scene = t.scene(viewTop: viewTop, full: full, ballAt: ballAt)
        r.present(t.state(lampsA: lampsA), message: t.message(), flippers: scene.flippers, plungerY: nil)
        let px = try r.renderOffscreen(scene: scene, width: width, height: height)
        return (r, px)
    }

    static func variants() -> [(String, RenderSettings)] {
        var out: [(String, RenderSettings)] = [("nearest", .classic)]
        for f in [UpscaleFilter.smooth, .xbrz, .crt] { var s = RenderSettings(); s.filter = f; out.append((f.rawValue, s)) }
        var l = RenderSettings(); l.filter = .xbrz; l.lighting = .subtle; out.append(("xbrz+light", l))
        var h = RenderSettings(); h.useHDPack = true; h.filter = .smooth; out.append(("hd", h))
        var hl = h; hl.lighting = .subtle; out.append(("hd+light", hl))
        return out
    }

    /// EP_RENDER_SNAPSHOTS=<dir>: writes EP1/EP8/EP10 in every variant (for viewing).
    func testWriteEnhancedSnapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["EP_RENDER_SNAPSHOTS"] else { throw XCTSkip("set EP_RENDER_SNAPSHOTS=<dir>") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let w = Int(ProcessInfo.processInfo.environment["EP_RENDER_W"] ?? "1280") ?? 1280
        let h = Int(ProcessInfo.processInfo.environment["EP_RENDER_H"] ?? "960") ?? 960
        let only = ProcessInfo.processInfo.environment["EP_RENDER_ONLY"]
        for n in [1, 8, 10] {
            guard let t = RealTable.load(n) else { continue }
            let lampsA = ProcessInfo.processInfo.environment["EP_RENDER_LAMPS"].map { $0 == "a" } ?? true
            for (name, s) in Self.variants() where only == nil || only!.split(separator: ",").contains(Substring(name)) {
                let (r, px) = try Self.render(t, device: device, settings: s, width: w, height: h, lampsA: lampsA)
                let url = URL(fileURLWithPath: dir).appendingPathComponent("ep\(n)_\(name)\(lampsA ? "" : "_b").png")
                try PNGWriter.write(rgba: px, width: w, height: h, to: url)
                print("wrote \(url.path) hd=\(r.hdPackActive) warnings=\(r.hdPackWarnings.prefix(3))")
            }
        }
    }

    // MARK: - enhanced behaviour

    func testFilterNamesAndSettingsMapping() {
        XCTAssertEqual(UpscaleFilter(rawValue: "xbrz-like"), .xbrz)
        XCTAssertEqual(UpscaleFilter(rawValue: "smooth"), .smooth)
        XCTAssertEqual(UpscaleFilter.allCases.map(\.rawValue), ["nearest", "smooth", "xbrz", "crt"])
        XCTAssertTrue(RenderSettings(GameSettings()).isClassic, "default GameSettings must render classic")
        var g = GameSettings()
        g.upscaleFilter = .crt; g.dynamicLighting = true; g.useHDPack = true; g.highRefresh = true
        let s = RenderSettings(g)
        XCTAssertEqual(s.filter, .crt); XCTAssertEqual(s.lighting, .subtle); XCTAssertTrue(s.useHDPack); XCTAssertTrue(s.interpolate)
        XCTAssertFalse(s.isClassic)
    }

    /// Lighting strength and output scaling (Settings > Display): the strength only matters while
    /// lighting is on; integer scaling of the nearest filter stays on the classic path.
    func testLightingStrengthAndScalingMapping() {
        var g = GameSettings()
        g.lightingStrength = .vivid
        XCTAssertEqual(RenderSettings(g).lighting, .off)
        XCTAssertTrue(RenderSettings(g).isClassic)
        g.dynamicLighting = true
        XCTAssertEqual(RenderSettings(g).lighting, .vivid)
        g.lightingStrength = .subtle
        XCTAssertEqual(RenderSettings(g).lighting, .subtle)
        g = GameSettings()
        XCTAssertEqual(RenderSettings(g).scaling, .auto)
        g.outputScaling = .integer
        XCTAssertEqual(RenderSettings(g).scaling, .integer)
        XCTAssertTrue(RenderSettings(g).isClassic)
        g.outputScaling = .fill
        XCTAssertEqual(RenderSettings(g).scaling, .fill)
        XCTAssertFalse(RenderSettings(g).isClassic)
    }

    func testFillFitKeepsAspectAndIntegerMatchesClassic() {
        for (w, h) in [(3840, 2160), (1000, 700), (2560, 1600), (300, 200)] {
            for aspect in PixelAspect.allCases {
                let i = EnhancedFit.fit(sourceWidth: 320, sourceHeight: 240, outputWidth: w, outputHeight: h, aspect: aspect, scaling: .integer)
                let v = ViewportFit.fit(sourceWidth: 320, sourceHeight: 240, outputWidth: w, outputHeight: h, aspect: aspect)
                XCTAssertEqual([i.x, i.y, i.width, i.height, i.scaleX, i.scaleY], [v.x, v.y, v.width, v.height, v.scaleX, v.scaleY])
                let f = EnhancedFit.fit(sourceWidth: 320, sourceHeight: 240, outputWidth: w, outputHeight: h, aspect: aspect, scaling: .fill)
                XCTAssertEqual(f.scaleY / f.scaleX, aspect.heightOverWidth, accuracy: 1e-9)
                XCTAssertTrue(abs(f.width - Double(w)) < 1e-6 || abs(f.height - Double(h)) < 1e-6, "fill touches an edge")
                XCTAssertLessThanOrEqual(f.width, Double(w) + 1e-6); XCTAssertLessThanOrEqual(f.height, Double(h) + 1e-6)
            }
        }
        // 4K full table (320x400 + 19 strip rows): fill uses the whole height.
        let f = EnhancedFit.fit(sourceWidth: 320, sourceHeight: 419, outputWidth: 3840, outputHeight: 2160, aspect: .square, scaling: .fill)
        XCTAssertEqual(f.height, 2160, accuracy: 1e-6)
    }

    /// High refresh: the ball is drawn between the last two simulation positions.
    func testInterpolatedBallPosition() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let assets = try synthAssets()
        var ball = [UInt8](repeating: 0, count: 210)
        for i in 0..<210 { ball[i] = 77 }                      // solid 15x14 box, colour 77
        let r = try PinballRenderer(device: device, assets: assets)
        var st = RenderSettings(); st.interpolate = true; st.scaling = .integer
        r.settings = st
        let scene = SceneState(viewTop: 0, viewHeight: 200, ball: .init(topLeft: Vec2(110, 60), pixels: ball), flippers: [])
        r.interpolation = MotionInterpolation(alpha: 0.5, ballPrevious: Vec2(100, 60), ballCurrent: Vec2(110, 60), frame: 1)
        let px = try r.renderOffscreen(scene: scene, width: 640, height: 400)
        func at(_ x: Int, _ y: Int) -> [UInt8] { let o = (y * 640 + x) * 4; return Array(px[o..<o + 3]) }
        let c77 = assets.palette[77]
        let ballRGB = [c77.r, c77.g, c77.b]
        // Drawn box spans table x 105..<120 (output 210..<240 at 2x), not 110..<125.
        XCTAssertEqual(at(211, 130), ballRGB)
        XCTAssertEqual(at(238, 130), ballRGB)
        XCTAssertNotEqual(at(245, 130), ballRGB)
        XCTAssertNotEqual(at(205, 130), ballRGB)
        // Without interpolation it is at the current position.
        r.settings.interpolate = false
        r.settings.scaling = .fill   // keep the enhanced path
        let px2 = try r.renderOffscreen(scene: scene, width: 640, height: 400)
        let o = (130 * 640 + 245) * 4
        XCTAssertEqual(Array(px2[o..<o + 3]), ballRGB)
    }

    /// The GPU xBRZ and tools/hdpack/xbrz.py implement the same filter: the renderer's xbrz
    /// upscale of the bare playfield at 4x equals the generated pack's playfield.png.
    func testGPUXbrzMatchesPackGenerator() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let root = DataLocator.packageRelativeDefault
        guard let assets = try? TableAssets.load(dataRoot: root, table: 1),
              let dir = HDPack.locate(table: 1, dataRoot: root, environment: [:]),
              let pack = try? HDPack.load(from: dir, table: 1, playfield: assets.indices), pack.scale == 4,
              let pf = pack.playfield else { throw XCTSkip("no EP1 data / 4x pack (tools/hdpack/make_pack.py --table 1)") }
        let r = try PinballRenderer(device: device, assets: assets)
        var st = RenderSettings(); st.filter = .xbrz; st.scaling = .integer
        r.settings = st
        let px = try r.renderOffscreen(scene: SceneState(viewTop: 0, viewHeight: 400, ball: nil, flippers: []), width: 1280, height: 1600)
        var maxDiff = 0, over2 = 0
        for i in 0..<(1280 * 1600) {
            for k in 0..<3 {
                let d = abs(Int(px[i * 4 + k]) - Int(pf.pixels[i * 4 + k]))
                maxDiff = max(maxDiff, d)
                if d > 2 { over2 += 1 }
            }
        }
        print("GPU xBRZ vs pack: max channel diff \(maxDiff), channels off by > 2: \(over2) of \(1280 * 1600 * 3)")
        XCTAssertLessThan(Double(over2) / Double(1280 * 1600 * 3), 0.001)
    }

    /// HD pack: loading, per-asset validation, stale-pack rejection, and palette effects
    /// shifting the HD colour (synthetic pack in a temp directory).
    func testHDPackPlayfieldPaletteDeltaAndFallback() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let assets = try synthAssets()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hdpack-test-\(UUID().uuidString)")
        let dir = tmp.appendingPathComponent("EP1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let S = 2, W = 320 * S, H = 400 * S
        // HD playfield: the base colour, with the top-left HD pixel of every block darkened by 40.
        var rgba = [UInt8](repeating: 255, count: W * H * 4)
        for y in 0..<H { for x in 0..<W {
            let e = assets.palette[Int(assets.indices[(y / S) * 320 + x / S])]
            let dark: UInt8 = (x % S == 0 && y % S == 0) ? 40 : 0
            let o = (y * W + x) * 4
            rgba[o] = e.r &- min(e.r, dark); rgba[o + 1] = e.g &- min(e.g, dark); rgba[o + 2] = e.b &- min(e.b, dark)
        } }
        try PNGWriter.write(rgba: rgba, width: W, height: H, to: dir.appendingPathComponent("playfield.png"))
        func manifest(hash: String, playfield: String = "playfield.png") throws {
            let m: [String: Any] = ["format": "epic-pinball-hdpack", "version": 1, "table": 1, "scale": S,
                                    "source": ["playfield_idx_sha256": hash], "playfield": playfield]
            try JSONSerialization.data(withJSONObject: m).write(to: dir.appendingPathComponent("pack.json"))
        }
        try manifest(hash: HDPack.playfieldHash(assets.indices))
        let pack = try HDPack.load(from: dir, table: 1, playfield: assets.indices)
        XCTAssertNotNil(pack.playfield)
        XCTAssertEqual(pack.playfield?.pixels.count, rgba.count)
        XCTAssertEqual(pack.playfield.map { Array($0.pixels.prefix(4000)) }, Array(rgba.prefix(4000)), "PNG round trip is exact")

        setenv("EPIC_PINBALL_HDPACKS", tmp.path, 1)
        defer { unsetenv("EPIC_PINBALL_HDPACKS") }
        let r = try PinballRenderer(device: device, assets: assets)
        var st = RenderSettings(); st.useHDPack = true; st.filter = .nearest; st.scaling = .integer
        r.settings = st
        let scene = SceneState(viewTop: 0, viewHeight: 400, ball: nil, flippers: [])
        var px = try r.renderOffscreen(scene: scene, width: W, height: H)
        XCTAssertTrue(r.hdPackActive, "\(r.hdPackWarnings)")
        XCTAssertEqual(Array(px[0..<3]), Array(rgba[0..<3]), "HD pixel drawn 1:1")
        XCTAssertEqual(Array(px[4..<7]), Array(rgba[4..<7]))
        // Palette override on index 200 (the diagonal): HD colour shifts by the entry's change.
        let i200 = (0..<(320 * 400)).first { assets.indices[$0] == 200 }!
        let tx = i200 % 320, ty = i200 / 320
        let base = assets.palette[200]
        r.applyPaletteOverrides([PaletteOverride(index: 200, r: base.r / 2, g: base.g / 2, b: base.b / 2)])
        px = try r.renderOffscreen(scene: scene, width: W, height: H)
        let o = ((ty * S + 1) * W + tx * S + 1) * 4
        XCTAssertEqual(Int(px[o]), Int(rgba[o]) - (Int(base.r) - Int(base.r / 2)), accuracy: 1)
        XCTAssertEqual(Int(px[o + 1]), Int(rgba[o + 1]) - (Int(base.g) - Int(base.g / 2)), accuracy: 1)

        // Stale pack (made from another playfield): the HD playfield is refused, the original is drawn.
        try manifest(hash: String(repeating: "0", count: 64))
        let stale = try HDPack.load(from: dir, table: 1, playfield: assets.indices)
        XCTAssertNil(stale.playfield)
        XCTAssertTrue(stale.warnings.contains { $0.contains("different playfield") })
        // Wrong size: rejected with a warning.
        try PNGWriter.write(rgba: [UInt8](repeating: 9, count: 16 * 16 * 4), width: 16, height: 16, to: dir.appendingPathComponent("small.png"))
        try manifest(hash: HDPack.playfieldHash(assets.indices), playfield: "small.png")
        let bad = try HDPack.load(from: dir, table: 1, playfield: assets.indices)
        XCTAssertNil(bad.playfield)
        XCTAssertTrue(bad.warnings.contains { $0.contains("expected 640x800") })
        let r2 = try PinballRenderer(device: device, assets: assets)
        r2.settings = st
        let px2 = try r2.renderOffscreen(scene: scene, width: W, height: H)
        let e0 = assets.palette[Int(assets.indices[0])]
        XCTAssertEqual(Array(px2[0..<3]), [e0.r, e0.g, e0.b], "fallback: original pixel, nearest")
    }

    /// Lighting brightens lit lamps' surroundings and is off in classic settings.
    func testLightingGlowAroundLitLamp() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        guard let t = RealTable.load(10) else { throw XCTSkip("no EP10 data") }
        var off = RenderSettings(); off.filter = .smooth
        var on = off; on.lighting = .subtle
        let (_, a) = try Self.render(t, device: device, settings: off, width: 640, height: 480, full: true)
        let (_, b) = try Self.render(t, device: device, settings: on, width: 640, height: 480, full: true)
        var sumA = 0, sumB = 0
        for i in stride(from: 0, to: a.count, by: 4) { sumA += Int(a[i]) + Int(a[i + 1]) + Int(a[i + 2]); sumB += Int(b[i]) + Int(b[i + 1]) + Int(b[i + 2]) }
        print("EP10 lamps lit: mean brightness without lighting \(Double(sumA) / Double(a.count / 4) / 3), with \(Double(sumB) / Double(b.count / 4) / 3)")
        XCTAssertGreaterThan(sumB, sumA)
        XCTAssertLessThan(Double(sumB) / Double(sumA), 1.25, "subtle")
    }

    /// EP_RENDER_PERF=1: GPU time per frame at 3840x2160 for every variant (EP1 data).
    func testGPUFrameTime4K() throws {
        guard ProcessInfo.processInfo.environment["EP_RENDER_PERF"] != nil else { throw XCTSkip("set EP_RENDER_PERF=1") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        guard let t = RealTable.load(1) else { throw XCTSkip("no EP1 data") }
        let W = 3840, H = 2160
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        d.usage = [.renderTarget]; d.storageMode = .private
        let target = device.makeTexture(descriptor: d)!
        var fullHD = RenderSettings(); fullHD.useHDPack = true; fullHD.filter = .smooth; fullHD.lighting = .subtle; fullHD.interpolate = true
        var all = Self.variants(); all.append(("hd+light+interp", fullHD))
        var xl = RenderSettings(); xl.filter = .xbrz; xl.lighting = .subtle; xl.interpolate = true; all.append(("xbrz+light+interp", xl))
        for (name, s) in all {
            for full in [false, true] {
                let (r, _) = try Self.render(t, device: device, settings: s, width: 64, height: 48, full: full)
                let scene = t.scene(viewTop: 150, full: full)
                var times: [Double] = []
                for f in 0..<130 {
                    r.interpolation = MotionInterpolation(alpha: Double(f % 2) * 0.5, ballPrevious: Vec2(200, 250), ballCurrent: Vec2(203, 252), frame: f / 2)
                    let cb = r.commandQueue.makeCommandBuffer()!
                    try r.encode(scene: scene, into: cb, target: target)
                    cb.commit(); cb.waitUntilCompleted()
                    if f >= 10 { times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
                }
                times.sort()
                let mean = times.reduce(0, +) / Double(times.count)
                print(String(format: "PERF 3840x2160 %@ %-22@ mean %.3f ms  p50 %.3f  p95 %.3f  max %.3f ms",
                             full ? "full " : "window", name, mean, times[times.count / 2], times[times.count * 95 / 100], times.last!))
            }
        }
    }

    /// High refresh: the camera eases between the last two frames' tops and flipper frames
    /// cross-fade (real EP1 data).
    func testInterpolatedCameraAndFlipperCrossfade() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        guard let t = RealTable.load(1) else { throw XCTSkip("no EP1 data") }
        var st = RenderSettings(); st.interpolate = true; st.scaling = .integer
        let r = try PinballRenderer(device: device, assets: t.assets)
        let c = ClassicComposer(graphics: t.composer.graphics, spec: t.composer.spec, exe: t.composer.exe, playfield: t.assets.indices, engine: t.engine)
        r.attach(composer: c); r.settings = st; r.stripRows = t.stripRows
        func frame(_ n: Int, top: Double, flipperFrame: Int, alpha: Double) throws -> [UInt8] {
            var scene = t.scene(viewTop: top)
            scene.ball = nil
            for i in scene.flippers.indices { scene.flippers[i].frame = flipperFrame }
            r.present(t.state(), message: nil, flippers: scene.flippers, plungerY: nil)
            r.interpolation = MotionInterpolation(alpha: alpha, ballPrevious: nil, ballCurrent: nil, frame: n)
            return try r.renderOffscreen(scene: scene, width: 640, height: 480)
        }
        _ = try frame(1, top: 150, flipperFrame: 3, alpha: 1)
        let mid = try frame(2, top: 170, flipperFrame: 0, alpha: 0.5)
        // Reference renders without interpolation.
        let ref = try PinballRenderer(device: device, assets: t.assets)
        let rc = ClassicComposer(graphics: t.composer.graphics, spec: t.composer.spec, exe: t.composer.exe, playfield: t.assets.indices, engine: t.engine)
        ref.attach(composer: rc); var rs = RenderSettings(); rs.scaling = .fill; ref.settings = rs; ref.stripRows = t.stripRows
        func refFrame(top: Double, flipperFrame: Int) throws -> [UInt8] {
            var scene = t.scene(viewTop: top); scene.ball = nil
            for i in scene.flippers.indices { scene.flippers[i].frame = flipperFrame }
            ref.present(t.state(), message: nil, flippers: scene.flippers, plungerY: nil)
            return try ref.renderOffscreen(scene: scene, width: 640, height: 480)
        }
        let at160up = try refFrame(top: 160, flipperFrame: 0)
        let at160rest = try refFrame(top: 160, flipperFrame: 3)
        // Rows well above the flippers: identical to a camera at 160 (halfway between 150 and 170).
        XCTAssertEqual(Array(mid[0..<(640 * 300 * 4)]), Array(at160up[0..<(640 * 300 * 4)]))
        // Inside the left flipper rect the pixels are between the two frames.
        let f = t.engine.flippers[0].sprite!
        var between = 0, differ = 0
        for y in f.y..<(f.y + f.h) {
            for x in f.x..<(f.x + f.w) {
                let sy = (y - 160) * 2, sx = x * 2
                guard sy >= 0, sy < 442 else { continue }
                let o = (sy * 640 + sx) * 4
                let a = Int(at160up[o]), b = Int(at160rest[o]), m = Int(mid[o])
                if a != b { differ += 1; if abs(m - (a + b) / 2) <= 2 { between += 1 } }
            }
        }
        XCTAssertGreaterThan(differ, 50)
        XCTAssertGreaterThan(Double(between) / Double(differ), 0.9, "cross-fade halfway")
    }
}
