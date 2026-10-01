import Foundation
import Metal
import XCTest
@testable import PinballCore
@testable import PinballRender

/// Enhanced-renderer motion (docs/enhanced/rendering.md): every ball in play drawn (multiball),
/// the smooth ball position from the enhanced physics, and flippers rotated between the game's
/// frames with an HD pack. Real-data tests skip without the user's extracted data / EXE / packs.
final class MotionRenderTests: XCTestCase {
    static let env = ProcessInfo.processInfo.environment

    func synthAssets() throws -> TableAssets {
        let w = TableGeometry.width, h = TableGeometry.height
        var idx = [UInt8](repeating: 0, count: w * h)
        for i in idx.indices { idx[i] = UInt8(((i % w) / 8 + (i / w) / 8 * 3) & 0x3F) }
        var entries: [Palette.RGB] = []
        for i in 0..<256 { entries.append(Palette.RGB(r: UInt8((i * 37) & 0xFF), g: UInt8((i * 91 + 17) & 0xFF), b: UInt8((i * 13 + 90) & 0xFF))) }
        return TableAssets(table: 1, indices: idx, palette: try Palette(entries: entries), directory: URL(fileURLWithPath: "/"))
    }

    // MARK: - multiball

    /// Every ball in `extraBalls` is drawn like ball 0, in the classic passes and in the enhanced
    /// pipeline (where each one is interpolated with its own slot's motion).
    func testMultiballDrawsEveryBall() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let assets = try synthAssets()
        let solid = [UInt8](repeating: 77, count: 210)
        let c77 = assets.palette[77]
        let ballRGB = [c77.r, c77.g, c77.b]
        let scene = SceneState(viewTop: 0, viewHeight: 200, ball: .init(topLeft: Vec2(40, 40), pixels: solid), flippers: [],
                               extraBalls: [.init(topLeft: Vec2(110, 100), pixels: solid, slot: 1),
                                            .init(topLeft: Vec2(200, 40), pixels: solid, slot: 2),
                                            .init(topLeft: Vec2(260, 150), pixels: nil, slot: 4)])
        // Classic passes, 2x.
        let r = try PinballRenderer(device: device, assets: assets)
        let px = try r.renderOffscreen(scene: scene, width: 640, height: 400)
        func at(_ p: [UInt8], _ x: Int, _ y: Int) -> [UInt8] { let o = (y * 640 + x) * 4; return Array(p[o..<o + 3]) }
        XCTAssertEqual(at(px, 2 * 47, 2 * 47), ballRGB, "ball 0")
        XCTAssertEqual(at(px, 2 * 117, 2 * 107), ballRGB, "slot 1")
        XCTAssertEqual(at(px, 2 * 207, 2 * 47), ballRGB, "slot 2")
        let bgProc = at(try r.renderOffscreen(scene: SceneState(viewTop: 0, viewHeight: 200, ball: nil, flippers: []), width: 640, height: 400), 2 * 267, 2 * 157)
        XCTAssertNotEqual(at(px, 2 * 267, 2 * 157), bgProc, "slot 4: procedural fallback ball")
        // Without extra balls the classic output is what it was (only ball 0).
        let one = SceneState(viewTop: 0, viewHeight: 200, ball: scene.ball, flippers: [])
        let px1 = try r.renderOffscreen(scene: one, width: 640, height: 400)
        XCTAssertNotEqual(at(px1, 2 * 117, 2 * 107), ballRGB)

        // Enhanced, interpolated: slot 1 moves 10 px right over the frame, drawn halfway.
        var st = RenderSettings(); st.interpolate = true; st.scaling = .integer
        r.settings = st
        r.interpolation = MotionInterpolation(alpha: 0.5, ballPrevious: Vec2(40, 40), ballCurrent: Vec2(40, 40), frame: 1,
                                              balls: [.init(slot: 1, previous: Vec2(100, 100), current: Vec2(110, 100), integer: SIMD2(110, 100)),
                                                      .init(slot: 2, previous: nil, current: Vec2(200, 40), integer: SIMD2(200, 40))])
        let pe = try r.renderOffscreen(scene: scene, width: 640, height: 400)
        XCTAssertEqual(at(pe, 2 * 47, 2 * 47), ballRGB, "ball 0")
        XCTAssertEqual(at(pe, 2 * 106, 2 * 107), ballRGB, "slot 1 at 105..<120")
        XCTAssertNotEqual(at(pe, 2 * 121, 2 * 107), ballRGB, "slot 1 not at its current position's right edge")
        XCTAssertEqual(at(pe, 2 * 207, 2 * 47), ballRGB, "slot 2 (just in play: current position)")
        XCTAssertNotEqual(at(pe, 2 * 267, 2 * 157), at(pe, 2 * 300, 2 * 190), "slot 4 drawn")
    }

    /// The simulation reports every drawn slot (EP1: 5, EP9-13: 3, as the original's ball loops), and
    /// the scene carries them in slot order with their own composited pixels.
    func testSceneCarriesEveryBallInPlay() throws {
        let root = DataLocator.packageRelativeDefault
        var ran = 0
        for (n, slots) in [(1, 5), (10, 3)] {
            guard let (d, buf) = try? EngineAssets.load(dataRoot: root, table: n) else { continue }
            ran += 1
            let e = try ClassicEngine(data: d, startBuffer: buf)
            let sim = GameSimulation(engine: e)
            XCTAssertEqual(sim.drawnBallSlots, slots, "EP\(n)")
            for i in e.balls.indices { e.balls[i] = BallState(x: Int16(60 + 40 * i), y: 150) }
            e.balls[0].active = 0
            sim.stepFrame()
            let scene = SceneState(simulation: sim, camera: Camera())
            XCTAssertNil(scene.ball, "slot 0 empty")
            XCTAssertEqual(scene.extraBalls.map(\.slot), Array(1..<slots), "EP\(n)")
            for b in scene.extraBalls {
                XCTAssertEqual(b.pixelTopLeft, SIMD2(Int(e.balls[b.slot].x), Int(e.balls[b.slot].y)))
                XCTAssertEqual(b.pixels, e.compositedBallPixels(ball: b.slot))
            }
            let ip = MotionInterpolation(simulation: sim)
            XCTAssertEqual(ip.balls.map(\.slot), Array(1..<slots))
        }
        if ran == 0 { throw XCTSkip("no extracted data") }
    }

    // MARK: - smooth ball

    /// Enhanced physics: the drawn position is the model's centre (full precision) whenever the
    /// integer fields hold its truncation; classic physics: exactly x + acc/128 as before.
    func testBallPositionFromEnhancedPhysics() throws {
        let root = DataLocator.packageRelativeDefault
        guard let (d, buf) = try? EngineAssets.load(dataRoot: root, table: 1) else { throw XCTSkip("no extracted EP1") }
        for physics in [GameSettings.PhysicsMode.classic, .enhanced] {
            let e = try ClassicEngine(data: d, startBuffer: buf)
            let sim = GameSimulation(engine: e, mode: .enhanced, physics: physics)
            e.balls[0] = BallState(x: 150, y: 120, vx: 37, vy: 55)
            var smooth = 0
            for _ in 0..<60 {
                sim.stepFrame()
                let b = e.balls[0]
                let q = Vec2(Double(b.x) + Double(b.accx) / 128, Double(b.y) + Double(b.accy) / 128)
                let p = sim.ballPosition(0)
                XCTAssertEqual(sim.currentBall, p)
                if physics == .classic {
                    XCTAssertEqual(p, q)
                } else {
                    XCTAssertGreaterThanOrEqual(p.x, q.x - 1e-9); XCTAssertLessThan(p.x, q.x + 1.0 / 128 + 1e-9)
                    XCTAssertGreaterThanOrEqual(p.y, q.y - 1e-9); XCTAssertLessThan(p.y, q.y + 1.0 / 128 + 1e-9)
                    if let m = sim.enhanced, let c = m.ballCentre(0), c - m.centreOffset == p, p != q { smooth += 1 }
                }
            }
            if physics == .enhanced { XCTAssertGreaterThan(smooth, 50, "drawn from the model's centre, not the 1/128 px fields") }
        }
    }

    // MARK: - rotated flippers

    /// The frame split on every table: usable (rigid rotation, clean masks) everywhere but EP8, and
    /// the frames' fitted art angles follow the collision outlines' angles 0, 3, 6, 9.
    func testFlipperArtSplitOnRealTables() throws {
        var ran = 0, usable = 0, total = 0
        for n in 1...13 {
            guard let t = RealTable.load(n) else { continue }
            ran += 1
            for (i, frames) in t.composer.flipperFrames.enumerated() {
                guard let frames, frames.count >= 2 else { continue }   // EP13's right flipper has one frame
                total += 1
                let art = try XCTUnwrap(FlipperArt(frames: frames, palette: t.assets.palette, flipper: t.engine.flippers[i]))
                let shape = FlipperShape(index: i, flipper: t.engine.flippers[i])
                let outline = art.frameAngles.map { shape.theta(alpha: $0).theta }
                print(String(format: "EP%d flipper %d: usable %@, fit %.2f px, art pivot (%.1f, %.1f) vs outline (%.1f, %.1f), unknown bg %d px",
                             n, i, art.usable ? "yes" : "no", art.fitError, art.pivot.x, art.pivot.y, shape.pivot.x, shape.pivot.y, art.unknownBackground)
                      + ", art angles " + art.thetas.map { String(format: "%.3f", $0) }.joined(separator: " ")
                      + " / outline " + outline.map { String(format: "%.3f", $0) }.joined(separator: " "))
                if n == 8 { XCTAssertFalse(art.usable, "EP8 keeps the cross-fade"); continue }
                XCTAssertTrue(art.usable, "EP\(n) flipper \(i)")
                usable += 1
                // Lower flippers (all ten outlines distinct): art and outline angles agree.
                if Set(t.engine.flippers[i].positions.map { Set($0) }).count == 10 && frames.count == 4 {
                    for k in 1..<3 { XCTAssertEqual(art.thetas[k], outline[k], accuracy: 0.08, "EP\(n) flipper \(i) frame \(k)") }
                    XCTAssertEqual(art.thetas[0], outline[0], accuracy: 0.1, "EP\(n) flipper \(i) up frame")
                }
                // Pose mapping: a frame's own angle shows that frame unrotated; in between the art turns.
                for (k, a) in art.frameAngles.enumerated() {
                    let p = art.pose(alpha: a)
                    let (shown, r) = p.weight < 0.5 ? (p.k0, p.r0) : (p.k1, p.r1)
                    XCTAssertEqual(shown, k); XCTAssertEqual(r, 0, accuracy: 1e-12); XCTAssertTrue(p.weight == 0 || p.weight == 1)
                }
                let mid = art.pose(alpha: (art.frameAngles[0] + art.frameAngles[1]) / 2)
                XCTAssertEqual(mid.weight, 0.5, accuracy: 1e-12)
                XCTAssertEqual(mid.r0, (art.thetas[1] - art.thetas[0]) / 2, accuracy: 1e-12)
            }
        }
        if ran == 0 { throw XCTSkip("no extracted data / EXEs") }
        print("flipper split usable: \(usable) of \(total)")
    }

    /// EP10 with its HD pack: at a frame's own angle the rotated drawing reproduces the HD frame
    /// (clean sprite over the clean background == the original record); between frames the
    /// flipper is drawn turned, not cross-faded. EP_RENDER_SNAPSHOTS=<dir> writes the sequence.
    func testRotatedFlipperHD() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        guard let t = RealTable.load(10) else { throw XCTSkip("no EP10 data") }
        guard HDPack.locate(table: 10, dataRoot: t.dataRoot, environment: [:]) != nil else { throw XCTSkip("no EP10 HD pack") }
        func renderer(rotate: Bool) throws -> PinballRenderer {
            let r = try PinballRenderer(device: device, assets: t.assets)
            let c = ClassicComposer(graphics: t.composer.graphics, spec: t.composer.spec, exe: t.composer.exe, playfield: t.assets.indices, engine: t.engine)
            r.attach(composer: c)
            var st = RenderSettings(); st.useHDPack = true; st.filter = .nearest; st.scaling = .integer; st.interpolate = true
            st.rotateFlippers = rotate; st.stripInFullTable = false
            r.settings = st
            r.stripRows = t.stripRows
            return r
        }
        let W = 1280, H = 1600   // full table at 4x: HD pixels 1:1
        func frame(_ r: PinballRenderer, _ n: Int, angle: Double, alpha: Double) throws -> [UInt8] {
            var scene = t.scene(viewTop: 0, full: true)
            scene.ball = nil
            for i in scene.flippers.indices {
                let frames = t.engine.flippers[i].sprite?.frames.count ?? 4
                scene.flippers[i].frame = ClassicEngine.spriteFrame(angle: Int(angle), frameCount: frames)
                scene.flippers[i].angle = angle
            }
            r.present(t.state(), message: nil, flippers: scene.flippers, plungerY: nil)
            r.interpolation = MotionInterpolation(alpha: alpha, ballPrevious: nil, ballCurrent: nil, frame: n)
            return try r.renderOffscreen(scene: scene, width: W, height: H)
        }
        let rot = try renderer(rotate: true), fade = try renderer(rotate: false)
        _ = try frame(rot, 0, angle: 9, alpha: 1)   // starts the background build of the rotation resources
        rot.waitForFlipperRotation()
        _ = try frame(rot, 0, angle: 9, alpha: 1)
        XCTAssertEqual(rot.rotatedFlipperCount, 2)
        XCTAssertEqual(fade.rotatedFlipperCount, 0)
        let lf = t.engine.flippers[0].sprite!
        func diff(_ a: [UInt8], _ b: [UInt8]) -> (max: Int, mean: Double, over8: Int) {
            var mx = 0, sum = 0, n = 0, over = 0
            for y in (lf.y * 4)..<((lf.y + lf.h) * 4) {
                for x in (lf.x * 4)..<((lf.x + lf.w + 4) * 4) {
                    let o = (y * W + x) * 4
                    for k in 0..<3 { let d = abs(Int(a[o + k]) - Int(b[o + k])); mx = max(mx, d); sum += d; n += 1; if d > 8 { over += 1 } }
                }
            }
            return (mx, Double(sum) / Double(n), over)
        }
        var shots: [(String, [UInt8])] = []
        for (n, a) in [(1, 9.0), (2, 6.0), (3, 3.0), (4, 0.0)] {
            // Not moving (previous == current): the frame itself.
            _ = try frame(rot, 10 * n, angle: a, alpha: 1); _ = try frame(fade, 10 * n, angle: a, alpha: 1)
            let pr = try frame(rot, 10 * n + 1, angle: a, alpha: 1), pf = try frame(fade, 10 * n + 1, angle: a, alpha: 1)
            let d = diff(pr, pf)
            print(String(format: "EP10 angle %.0f: rotated vs frame in the left flipper rect: max %d, mean %.3f, channels > 8: %d", a, d.max, d.mean, d.over8))
            XCTAssertLessThan(d.mean, 1.0, "angle \(a)")
            XCTAssertLessThan(d.over8, 200, "angle \(a)")
            shots.append(("still_\(Int(a))", pr))
        }
        // Moving 9 -> 6 over one frame: drawn at 9, 8.25, 7.5, 6.75.
        _ = try frame(rot, 100, angle: 9, alpha: 1); _ = try frame(fade, 100, angle: 9, alpha: 1)
        var prev: [UInt8]?
        for (j, al) in [0.0, 0.25, 0.5, 0.75, 1.0].enumerated() {
            let pr = try frame(rot, 101, angle: 6, alpha: al)
            if j == 2 {
                let pf = try frame(fade, 101, angle: 6, alpha: al)
                let d = diff(pr, pf)
                print(String(format: "EP10 moving 9 -> 6, alpha 0.5: rotated vs cross-fade: max %d, mean %.2f", d.max, d.mean))
                XCTAssertGreaterThan(d.mean, 1.0, "rotation differs from the cross-fade")
            }
            if let p = prev { XCTAssertGreaterThan(diff(pr, p).mean, 0.3, "moves at alpha \(al)") }
            prev = pr
            shots.append(("move_\(j)", pr))
        }
        if let dir = Self.env["EP_RENDER_SNAPSHOTS"] {
            // Crops of the lower flippers, side by side.
            let cx = 60 * 4, cy = 340 * 4, cw = 200 * 4, ch = 60 * 4
            var sheet = [UInt8](repeating: 0, count: cw * ch * shots.count * 4)
            for (i, s) in shots.enumerated() {
                for y in 0..<ch { for x in 0..<cw {
                    let o = ((cy + y) * W + cx + x) * 4, d = ((i * ch + y) * cw + x) * 4
                    for k in 0..<4 { sheet[d + k] = s.1[o + k] }
                } }
            }
            let url = URL(fileURLWithPath: dir).appendingPathComponent("ep10_flipper_rotation.png")
            try PNGWriter.write(rgba: sheet, width: cw, height: ch * shots.count, to: url)
            print("wrote \(url.path): \(shots.map(\.0))")
        }
        if let bt = rot.flipperRotationBuildTime { print(String(format: "rotation resources built in %.3f s (background)", bt)) }
    }

    /// Without an HD pack, high refresh rotates the flippers at output resolution for the smooth,
    /// xBRZ and CRT filters (frames upscaled by that filter, rendering.md "Rotated flippers without an
    /// HD pack"); nearest keeps the cross-fade. Real EP10 data (EP8 below).
    func testRotatedFlipperWithoutPack() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        guard let t = RealTable.load(10) else { throw XCTSkip("no EP10 data") }
        let W = 1280, H = 1600   // full table at 4x
        func renderer(_ filter: UpscaleFilter, rotate: Bool) throws -> PinballRenderer {
            let r = try PinballRenderer(device: device, assets: t.assets)
            let c = ClassicComposer(graphics: t.composer.graphics, spec: t.composer.spec, exe: t.composer.exe, playfield: t.assets.indices, engine: t.engine)
            r.attach(composer: c)
            var st = RenderSettings(); st.filter = filter; st.scaling = .integer; st.interpolate = true
            st.rotateFlippers = rotate; st.stripInFullTable = false
            r.settings = st
            r.stripRows = t.stripRows
            return r
        }
        func frame(_ r: PinballRenderer, _ n: Int, angle: Double, alpha: Double) throws -> [UInt8] {
            var scene = t.scene(viewTop: 0, full: true)
            scene.ball = nil
            for i in scene.flippers.indices {
                let frames = t.engine.flippers[i].sprite?.frames.count ?? 4
                scene.flippers[i].frame = ClassicEngine.spriteFrame(angle: Int(angle), frameCount: frames)
                scene.flippers[i].angle = angle
            }
            r.present(t.state(), message: nil, flippers: scene.flippers, plungerY: nil)
            r.interpolation = MotionInterpolation(alpha: alpha, ballPrevious: nil, ballCurrent: nil, frame: n)
            return try r.renderOffscreen(scene: scene, width: W, height: H)
        }
        let lf = t.engine.flippers[0].sprite!
        func diff(_ a: [UInt8], _ b: [UInt8]) -> (max: Int, mean: Double, over8: Int) {
            var mx = 0, sum = 0, n = 0, over = 0
            for y in (lf.y * 4)..<((lf.y + lf.h) * 4) {
                for x in (lf.x * 4)..<((lf.x + lf.w + 4) * 4) {
                    let o = (y * W + x) * 4
                    for k in 0..<3 { let d = abs(Int(a[o + k]) - Int(b[o + k])); mx = max(mx, d); sum += d; n += 1; if d > 8 { over += 1 } }
                }
            }
            return (mx, Double(sum) / Double(n), over)
        }
        var shots: [(String, [UInt8])] = []
        for filter in [UpscaleFilter.smooth, .xbrz, .crt, .nearest] {
            let rot = try renderer(filter, rotate: true), fade = try renderer(filter, rotate: false)
            _ = try frame(rot, 0, angle: 9, alpha: 1)   // starts the background build
            rot.waitForFlipperRotation()
            _ = try frame(rot, 0, angle: 9, alpha: 1)
            XCTAssertEqual(rot.rotatedFlipperCount, filter == .nearest ? 0 : 2, "\(filter)")
            XCTAssertEqual(fade.rotatedFlipperCount, 0)
            if filter == .nearest {
                // Nearest: the same picture as with rotation off (the cross-fade), also mid-swing.
                _ = try frame(rot, 100, angle: 9, alpha: 1); _ = try frame(fade, 100, angle: 9, alpha: 1)
                XCTAssertEqual(try frame(rot, 101, angle: 6, alpha: 0.5), try frame(fade, 101, angle: 6, alpha: 0.5))
                continue
            }
            if let bt = rot.flipperRotationBuildTime { print(String(format: "EP10 %@: rotation resources (x4) built in %.3f s", filter.rawValue, bt)) }
            for (n, a) in [(1, 9.0), (2, 6.0), (3, 3.0), (4, 0.0)] {
                // Not moving: the upscaled frame over the filtered background, close to the filtered frame.
                _ = try frame(rot, 10 * n, angle: a, alpha: 1); _ = try frame(fade, 10 * n, angle: a, alpha: 1)
                let pr = try frame(rot, 10 * n + 1, angle: a, alpha: 1), pf = try frame(fade, 10 * n + 1, angle: a, alpha: 1)
                let d = diff(pr, pf)
                print(String(format: "EP10 %@ angle %.0f: rotated vs filtered frame in the left flipper rect: max %d, mean %.3f, channels > 8: %d",
                             filter.rawValue, a, d.max, d.mean, d.over8))
                // CRT samples the window row by row (crt_row); its sprite is upscaled with Catmull-Rom
                // in both directions so it can turn, hence the larger (row-structure) difference.
                XCTAssertLessThan(d.mean, filter == .crt ? 2.5 : 0.5, "\(filter) angle \(a)")
                if n == 1 { shots.append(("\(filter.rawValue)_still_9", pr)) }
            }
            _ = try frame(rot, 200, angle: 9, alpha: 1); _ = try frame(fade, 200, angle: 9, alpha: 1)
            var prev: [UInt8]?
            for (j, al) in [0.0, 0.25, 0.5, 0.75, 1.0].enumerated() {
                let pr = try frame(rot, 201, angle: 6, alpha: al)
                if j == 2 {
                    let pf = try frame(fade, 201, angle: 6, alpha: al)
                    let d = diff(pr, pf)
                    print(String(format: "EP10 %@ moving 9 -> 6, alpha 0.5: rotated vs cross-fade: max %d, mean %.2f", filter.rawValue, d.max, d.mean))
                    XCTAssertGreaterThan(d.mean, 1.0, "\(filter): rotation differs from the cross-fade")
                    shots.append(("\(filter.rawValue)_fade_mid", pf))
                }
                if let p = prev { XCTAssertGreaterThan(diff(pr, p).mean, 0.3, "\(filter) moves at alpha \(al)") }
                prev = pr
                if j == 1 || j == 2 || j == 3 { shots.append(("\(filter.rawValue)_move_\(j)", pr)) }
            }
        }
        if let dir = Self.env["EP_RENDER_SNAPSHOTS"] {
            let cx = 60 * 4, cy = 340 * 4, cw = 200 * 4, ch = 60 * 4
            var sheet = [UInt8](repeating: 0, count: cw * ch * shots.count * 4)
            for (i, s) in shots.enumerated() {
                for y in 0..<ch { for x in 0..<cw {
                    let o = ((cy + y) * W + cx + x) * 4, d = ((i * ch + y) * cw + x) * 4
                    for k in 0..<4 { sheet[d + k] = s.1[o + k] }
                } }
            }
            let url = URL(fileURLWithPath: dir).appendingPathComponent("ep10_flipper_rotation_nopack.png")
            try PNGWriter.write(rgba: sheet, width: cw, height: ch * shots.count, to: url)
            print("wrote \(url.path): \(shots.map(\.0))")
        }
    }

    /// EP8's flippers fail the rigidity check: without a pack they keep the cross-fade too.
    func testEP8FlippersKeepCrossFadeWithoutPack() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        guard let t = RealTable.load(8) else { throw XCTSkip("no EP8 data") }
        let r = try PinballRenderer(device: device, assets: t.assets)
        let c = ClassicComposer(graphics: t.composer.graphics, spec: t.composer.spec, exe: t.composer.exe, playfield: t.assets.indices, engine: t.engine)
        r.attach(composer: c)
        var st = RenderSettings(); st.filter = .xbrz; st.interpolate = true
        r.settings = st; r.stripRows = t.stripRows
        for n in 0..<3 {
            var scene = t.scene(viewTop: 160)
            for i in scene.flippers.indices { scene.flippers[i].angle = n == 2 ? 6 : 9 }
            r.present(t.state(), message: nil, flippers: scene.flippers, plungerY: nil)
            r.interpolation = MotionInterpolation(alpha: 0.5, ballPrevious: nil, ballCurrent: nil, frame: n)
            _ = try r.renderOffscreen(scene: scene, width: 640, height: 480)
            if n == 0 { r.waitForFlipperRotation() }
        }
        XCTAssertEqual(r.rotatedFlipperCount, 0)
    }

    func testNativeRotationScale() {
        XCTAssertEqual(NativeFlipperRotation.scale(forOutputScale: 1), 2)
        XCTAssertEqual(NativeFlipperRotation.scale(forOutputScale: 3), 3)
        XCTAssertEqual(NativeFlipperRotation.scale(forOutputScale: 4.5), 5)
        XCTAssertEqual(NativeFlipperRotation.scale(forOutputScale: 9), 8)
        // The classic default never runs the enhanced passes, so nothing is rotated there.
        XCTAssertTrue(RenderSettings(GameSettings()).isClassic)
    }

    /// The CRT scissor margin covers the barrel warp's largest shift (curvature / 2 of the size) over
    /// the whole Settings range, so no part of a rotated flipper falls outside the second draw.
    func testRotationScissorCoversCurvature() {
        XCTAssertEqual(EnhancedPipeline.curveMargin(0.025), 0.03)   // the default: as before
        for k in stride(from: 0.0, through: GameSettings.crtCurvatureRange.upperBound, by: 0.005) {
            XCTAssertGreaterThanOrEqual(EnhancedPipeline.curveMargin(k), k / 2, "curvature \(k)")
        }
    }

    /// EP_RENDER_PERF=1: GPU cost at 3840x2160 (EP10, flippers moving, high refresh) of the display
    /// rotation pass (rotation 0 vs 90, classic and enhanced; and the turn pass alone) and of rotating
    /// the flippers without an HD pack (cross-fade vs output-resolution rotation for smooth / xBRZ /
    /// CRT). The two configurations of a pair are rendered alternately frame by frame, so GPU clock
    /// and load changes on a shared machine hit both alike; medians are compared.
    func testGPURotationCost4K() throws {
        guard Self.env["EP_RENDER_PERF"] != nil else { throw XCTSkip("set EP_RENDER_PERF=1") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        guard let t = RealTable.load(10) else { throw XCTSkip("no EP10 data") }
        let W = 3840, H = 2160
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        d.usage = [.renderTarget]; d.storageMode = .private
        let target = device.makeTexture(descriptor: d)!
        func make(_ st: RenderSettings) throws -> PinballRenderer {
            let r = try PinballRenderer(device: device, assets: t.assets)
            let c = ClassicComposer(graphics: t.composer.graphics, spec: t.composer.spec, exe: t.composer.exe, playfield: t.assets.indices, engine: t.engine)
            r.attach(composer: c); r.stripRows = t.stripRows
            r.settings = st
            return r
        }
        func frame(_ r: PinballRenderer, _ f: Int, full: Bool) throws -> Double {
            var scene = t.scene(viewTop: 180, full: full)
            let angle = [9.0, 6, 3, 0, 3, 6][(f / 2) % 6]
            for i in scene.flippers.indices {
                scene.flippers[i].frame = ClassicEngine.spriteFrame(angle: Int(angle), frameCount: t.engine.flippers[i].sprite?.frames.count ?? 4)
                scene.flippers[i].angle = angle
            }
            r.present(t.state(), message: nil, flippers: scene.flippers, plungerY: nil)
            if r.settings.interpolate {
                r.interpolation = MotionInterpolation(alpha: Double(f % 2) * 0.5 + 0.25, ballPrevious: Vec2(200, 250), ballCurrent: Vec2(203, 252), frame: f / 2)
            }
            let cb = r.commandQueue.makeCommandBuffer()!
            try r.encode(scene: scene, into: cb, target: target)
            cb.commit(); cb.waitUntilCompleted()
            if f == 0 { r.waitForFlipperRotation() }
            return (cb.gpuEndTime - cb.gpuStartTime) * 1000
        }
        func median(_ a: [Double]) -> Double { let s = a.sorted(); return s[s.count / 2] }
        func p95(_ a: [Double]) -> Double { let s = a.sorted(); return s[s.count * 95 / 100] }
        func pair(_ name: String, _ a: RenderSettings, _ b: RenderSettings, full: Bool) throws {
            let ra = try make(a), rb = try make(b)
            var ta: [Double] = [], tb: [Double] = []
            for f in 0..<240 {
                let x = try frame(ra, f, full: full), y = try frame(rb, f, full: full)
                if f >= 40 { ta.append(x); tb.append(y) }
            }
            print(String(format: "PERF 3840x2160 EP10 %@ %-36@ p50 %.3f -> %.3f ms (+%.3f), p95 %.3f -> %.3f, flippers rotated %d -> %d",
                         full ? "full  " : "window", name, median(ta), median(tb), median(tb) - median(ta), p95(ta), p95(tb),
                         ra.rotatedFlipperCount, rb.rotatedFlipperCount))
        }
        for full in [false, true] {
            // Display rotation: one extra full-screen pass (upright texture -> target).
            var c90 = RenderSettings.classic; c90.rotation = .clockwise90
            try pair("classic, display rotation 0 -> 90", .classic, c90, full: full)
            var x = RenderSettings(); x.filter = .xbrz; x.lighting = .subtle; x.interpolate = true
            var x90 = x; x90.rotation = .clockwise90
            try pair("xbrz+light+interp, rotation 0 -> 90", x, x90, full: full)
            // Flipper rotation without an HD pack.
            for filter in [UpscaleFilter.smooth, .xbrz, .crt] {
                var s = RenderSettings(); s.filter = filter; s.interpolate = true; s.rotateFlippers = false
                var sr = s; sr.rotateFlippers = true
                try pair("\(filter.rawValue)+interp, flippers fade -> rotated", s, sr, full: full)
            }
        }
        // The turn pass alone (present_rotate, one 3840x2160 read + write).
        let r = try make(.classic)
        let ud = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: H, height: W, mipmapped: false)
        ud.usage = [.renderTarget, .shaderRead]; ud.storageMode = .private
        let upright = device.makeTexture(descriptor: ud)!
        var times: [Double] = []
        for f in 0..<200 {
            let cb = r.commandQueue.makeCommandBuffer()!
            try r.encodeTurn(upright, by: DisplayTransform(rotation: .clockwise90, outputWidth: W, outputHeight: H), into: cb, target: target)
            cb.commit(); cb.waitUntilCompleted()
            if f >= 20 { times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        }
        print(String(format: "PERF 3840x2160 present_rotate alone (90): p50 %.3f ms, p95 %.3f ms", median(times), p95(times)))
    }

    /// EP_RENDER_PERF=1: GPU time at 3840x2160 (EP10, HD 4x + lighting + interpolation) with the
    /// flippers moving (cross-fade vs rotation) and with one vs three balls.
    func testGPUFrameTimeMotion4K() throws {
        guard Self.env["EP_RENDER_PERF"] != nil else { throw XCTSkip("set EP_RENDER_PERF=1") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        guard let t = RealTable.load(10), HDPack.locate(table: 10, dataRoot: t.dataRoot, environment: [:]) != nil else { throw XCTSkip("no EP10 data / pack") }
        let W = 3840, H = 2160
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        d.usage = [.renderTarget]; d.storageMode = .private
        let target = device.makeTexture(descriptor: d)!
        let ball = t.engine.ball.pixels
        for (name, rotate, balls) in [("flippers cross-fade, 1 ball", false, 1), ("flippers rotated, 1 ball", true, 1),
                                      ("flippers rotated, 3 balls", true, 3)] {
            for full in [false, true] {
                let r = try PinballRenderer(device: device, assets: t.assets)
                let c = ClassicComposer(graphics: t.composer.graphics, spec: t.composer.spec, exe: t.composer.exe, playfield: t.assets.indices, engine: t.engine)
                r.attach(composer: c); r.stripRows = t.stripRows
                var st = RenderSettings(); st.useHDPack = true; st.filter = .smooth; st.lighting = .subtle; st.interpolate = true; st.rotateFlippers = rotate
                r.settings = st
                var times: [Double] = []
                for f in 0..<140 {
                    var scene = t.scene(viewTop: 180, full: full)
                    scene.extraBalls = (1..<balls).map { .init(topLeft: Vec2(140 + 30 * Double($0), 330), pixels: ball, slot: $0) }
                    let angle = [9.0, 6, 3, 0, 3, 6][(f / 2) % 6]   // flipping up and down, a new sim frame every 2nd display frame
                    for i in scene.flippers.indices {
                        scene.flippers[i].frame = ClassicEngine.spriteFrame(angle: Int(angle), frameCount: t.engine.flippers[i].sprite?.frames.count ?? 4)
                        scene.flippers[i].angle = angle
                    }
                    r.present(t.state(), message: nil, flippers: scene.flippers, plungerY: nil)
                    r.interpolation = MotionInterpolation(alpha: Double(f % 2) * 0.5 + 0.25, ballPrevious: Vec2(200, 250), ballCurrent: Vec2(203, 252),
                                                          frame: f / 2, balls: scene.extraBalls.map { .init(slot: $0.slot, previous: $0.topLeft - Vec2(2, 2), current: $0.topLeft, integer: SIMD2(Int($0.topLeft.x), Int($0.topLeft.y))) })
                    let cb = r.commandQueue.makeCommandBuffer()!
                    try r.encode(scene: scene, into: cb, target: target)
                    cb.commit(); cb.waitUntilCompleted()
                    if f == 0 { r.waitForFlipperRotation() }
                    if f >= 20 { times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
                }
                if rotate { XCTAssertEqual(r.rotatedFlipperCount, 2) }
                times.sort()
                let mean = times.reduce(0, +) / Double(times.count)
                print(String(format: "PERF 3840x2160 EP10 HD+light+interp %@ %-28@ mean %.3f ms  p50 %.3f  p95 %.3f  max %.3f ms",
                             full ? "full " : "window", name, mean, times[times.count / 2], times[times.count * 95 / 100], times.last!))
            }
        }
    }
}
