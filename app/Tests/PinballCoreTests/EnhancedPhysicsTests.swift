import Foundation
import XCTest
@testable import PinballCore

/// Unit tests of the enhanced physics on synthetic data (EngineFixture: made-up numbers, no game
/// data): distance fields, sync with the integer ball fields, gravity, swept collision, flipper
/// shapes, buffer updates, determinism, and the classic path staying untouched.
final class EnhancedPhysicsTests: XCTestCase {

    // MARK: Distance fields

    func testExactDistanceTransformMatchesBruteForce() {
        var rng = EnhancedValidation.SplitMix(seed: 42)
        let w = 37, h = 29
        for _ in 0..<5 {
            var mask = [UInt8](repeating: 0, count: w * h)
            for i in mask.indices where Int.random(in: 0..<40, using: &rng) == 0 { mask[i] = 1 }
            mask[Int.random(in: 0..<(w * h), using: &rng)] = 1
            let d = DistanceField.squaredEDT(mask: mask, w: w, h: h, feature: 1)
            for y in 0..<h {
                for x in 0..<w {
                    var best = Float.greatestFiniteMagnitude
                    for yy in 0..<h { for xx in 0..<w where mask[yy * w + xx] != 0 {
                        best = min(best, Float((x - xx) * (x - xx) + (y - yy) * (y - yy)))
                    } }
                    XCTAssertEqual(d[y * w + x], best, "cell \(x),\(y)")
                }
            }
        }
    }

    func testFieldOfOnePixelIsDistanceToItsSquare() {
        var m = [UInt8](repeating: 0, count: 41 * 41)
        m[20 * 41 + 20] = 1
        let f = DistanceField(originX: 0, originY: 0, w: 41, h: 41, solid: m, cap: 30)
        XCTAssertEqual(f.rawValue(cellX: 30, cellY: 20), 9.5, accuracy: 1e-5)
        XCTAssertEqual(f.rawValue(cellX: 20, cellY: 20), -0.5, accuracy: 1e-5)
        // Smoothed value near the true distance at radius ~7, gradient pointing away.
        let s = f.sample(20.5 + 5, 20.5 + 5)
        XCTAssertEqual(s.value, 50.0.squareRoot() - 0.5, accuracy: 0.15)
        let n = s.normal
        XCTAssertEqual(n.x, 0.5.squareRoot(), accuracy: 0.02)
        XCTAssertEqual(n.y, 0.5.squareRoot(), accuracy: 0.02)
    }

    /// A stair-stepped 1:2 slope: the smoothed normal at contact distance varies by well under a
    /// degree along the wall (a raw pixel normal would jump between the step directions).
    func testSmoothNormalOnStairStepWall() {
        let w = 120, h = 120
        var m = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w where 2 * y > x + 60 { m[y * w + x] = 1 } }   // y > x/2 + 30
        let f = DistanceField(originX: 0, originY: 0, w: w, h: h, solid: m)
        let nTrue = SIMD2(1.0, -2.0) / 5.0.squareRoot()   // outward (towards smaller y)
        var worst = 0.0
        for i in 0..<40 {
            let x = 30 + Double(i) * 0.37
            let surf = SIMD2(x, x / 2 + 30)
            let p = surf + nTrue * 6.5
            let n = f.sample(p.x, p.y).normal
            let ang = acos(min(1, (n * nTrue).sum())) * 180 / .pi
            worst = max(worst, ang)
            XCTAssertEqual(f.sample(p.x, p.y).value, 6.5, accuracy: 0.6)
        }
        XCTAssertLessThan(worst, 1.5, "normal jitter on a pixel staircase")
    }

    func testLocalUpdateMatchesFullRecompute() {
        let w = 90, h = 70
        var m = [UInt8](repeating: 0, count: w * h)
        for x in 0..<w { m[50 * w + x] = 1 }
        var f = DistanceField(originX: 0, originY: 0, w: w, h: h, solid: m, cap: 12)
        var cells: [(Int, Int, Bool)] = []
        for y in 20..<24 { for x in 40..<46 { cells.append((x, y, true)); m[y * w + x] = 1 } }
        cells.append((10, 50, false)); m[50 * w + 10] = 0
        f.update(cells: cells)
        let g = DistanceField(originX: 0, originY: 0, w: w, h: h, solid: m, cap: 12)
        for y in 0..<h { for x in 0..<w {
            XCTAssertEqual(f.rawValue(cellX: x, cellY: y), g.rawValue(cellX: x, cellY: y), accuracy: 1e-5)
        } }
        for p in [(43.0, 30.0), (12.0, 44.0), (70.2, 10.9)] {
            XCTAssertEqual(f.sample(p.0, p.1).value, g.sample(p.0, p.1).value, accuracy: 1e-5)
        }
    }

    // MARK: Engine integration (fixture)

    static let wall = UInt8(EngineFixture.wallIndex)

    func floorEngine(floorY: Int = 250) throws -> ClassicEngine {
        var buf = [UInt8](repeating: 0, count: 320 * 400)
        for x in 0..<320 { for y in floorY..<(floorY + 3) { buf[y * 320 + x] = Self.wall } }
        let e = try EngineFixture.engine(buffer: buf)
        e.resetToRest()
        e.sensorsEnabled = false
        for i in e.balls.indices { e.balls[i].active = 0 }
        return e
    }

    func testClassicBallPhysicsIsIdenticalToNoModel() throws {
        let a = try floorEngine(), b = try floorEngine()
        b.ballPhysics = ClassicBallPhysics()
        for e in [a, b] { e.balls[0] = BallState(x: 100, y: 180, vx: 90, vy: 70) }
        for f in 0..<200 {
            let inp: FrameInput = f % 17 < 5 ? .leftFlipper : []
            a.input = inp; b.input = inp
            a.runFrame(); b.runFrame()
            XCTAssertEqual(a.balls, b.balls, "frame \(f)")
            XCTAssertEqual(a.lastStep, b.lastStep)
        }
        XCTAssertEqual(a.buffer, b.buffer)
    }

    func testBallFallsOntoFloorAndRests() throws {
        let e = try floorEngine()
        let m = EnhancedPhysics.install(on: e)
        e.balls[0] = BallState(x: 150, y: 200, vx: 0, vy: 0)
        for _ in 0..<600 { e.runFrame() }
        let c = try XCTUnwrap(m.ballCentre(0))
        // Floor top at y = 250: centre rests contactRadius above it.
        XCTAssertEqual(c.y, 250 - m.contactRadius(normal: SIMD2(0, -1)), accuracy: 0.3)
        XCTAssertLessThan(abs(m.ballVelocity(0)!.y), 0.05)
        XCTAssertLessThan(m.wallPenetration(e, ball: 0), 0.3)
        XCTAssertEqual(m.stats.nanResets, 0)
        // The integer fields follow the smooth state.
        XCTAssertEqual(Double(e.balls[0].y) + Double(e.balls[0].accy) / 128 + m.centreOffset.y, c.y, accuracy: 1.0 / 128 + 1e-9)
    }

    func testFrameGravityMatchesClassicRate() throws {
        let e = try floorEngine(floorY: 390)
        let m = EnhancedPhysics.install(on: e)
        e.balls[0] = BallState(x: 150, y: 20, vx: 0, vy: 0)
        for _ in 0..<10 { e.runFrame() }
        // 10 frames of params[9] = 5 (fixture) = 50/128 px/step, no cutoff reached.
        XCTAssertEqual(m.ballVelocity(0)!.y, 50.0 / 128, accuracy: 1e-9)
        XCTAssertEqual(e.balls[0].vy, 50)
    }

    func testExternalWritesAreApplied() throws {
        let e = try floorEngine()
        let m = EnhancedPhysics.install(on: e)
        e.balls[0] = BallState(x: 100, y: 100, vx: 64, vy: 0)
        e.runFrame()
        let before = m.ballVelocity(0)!
        // A rule kick: vy -= 300 on the integer field -> delta on the smooth velocity.
        e.balls[0].vy &-= 300
        e.physicsStepForTest(m)
        XCTAssertEqual(m.ballVelocity(0)!.y, before.y - 300.0 / 128, accuracy: 0.02)
        // A teleport (serve / sensor write-back).
        e.balls[0].x = 40; e.balls[0].y = 60; e.balls[0].accx = 0; e.balls[0].accy = 0
        e.physicsStepForTest(m)
        let c = m.ballCentre(0)!
        XCTAssertEqual(c.x, 40 + m.centreOffset.x + m.ballVelocity(0)!.x, accuracy: 0.05)
        // vx = 0 forced (the plunger lane) is exact.
        e.balls[0].vx = 0
        e.physicsStepForTest(m)
        XCTAssertEqual(m.ballVelocity(0)!.x, 0)
        // Deactivation and re-activation.
        e.balls[0].active = 0
        e.physicsStepForTest(m)
        XCTAssertNil(m.ballCentre(0))
        e.balls[0] = BallState(x: 200, y: 50, vx: 0, vy: 128)
        e.physicsStepForTest(m)
        XCTAssertEqual(m.ballCentre(0)!.y, 50 + m.centreOffset.y + 1, accuracy: 1e-6)
    }

    /// The main loop's order is gravity, then the sensor scan (rule code). A kick-out hole holds
    /// the ball by writing v = 0 after the gravity: the held ball must not creep (the gravity of that
    /// frame is overridden, as in the original), the rules see the classic `vy` (with the gravity),
    /// and a plunger-style delta written before the gravity survives it.
    func testRuleVelocityWritesAfterGravity() throws {
        let e = try floorEngine()
        let m = EnhancedPhysics.install(on: e)
        e.balls[0] = BallState(x: 100, y: 100)
        m.step(e)
        let c0 = try XCTUnwrap(m.ballCentre(0))
        for _ in 0..<90 {
            XCTAssertTrue(m.frameGravity(e, ball: 0, amount: 5))
            XCTAssertEqual(e.balls[0].vy, 5, "the scan sees the gravity like the original")
            e.balls[0].vx = 0; e.balls[0].vy = 0   // the hold
            for _ in 0..<3 { m.step(e) }
        }
        XCTAssertEqual(m.ballCentre(0)!, c0)
        XCTAssertEqual(m.ballVelocity(0)!, SIMD2(0, 0))
        // Release: vy -= 600 before this frame's gravity.
        e.balls[0].vy &-= 600
        _ = m.frameGravity(e, ball: 0, amount: 5)
        XCTAssertEqual(e.balls[0].vy, -595)
        for _ in 0..<3 { m.step(e) }
        XCTAssertEqual(m.ballVelocity(0)!.y, -595.0 / 128, accuracy: 1e-9)
        // An eject that sets an absolute velocity after the gravity gets exactly that velocity.
        _ = m.frameGravity(e, ball: 0, amount: 5)
        e.balls[0].vx = 30; e.balls[0].vy = 100
        for _ in 0..<3 { m.step(e) }
        XCTAssertEqual(m.ballVelocity(0)!.x, 30.0 / 128, accuracy: 1e-9)
        XCTAssertEqual(m.ballVelocity(0)!.y, 100.0 / 128, accuracy: 1e-9)
    }

    /// A ball far faster than anything in the game (40 px/step, one substep) against a 1-px wall:
    /// conservative advancement stops it at the wall.
    func testNoTunnellingThroughThinWallAtExtremeSpeed() throws {
        var buf = [UInt8](repeating: 0, count: 320 * 400)
        for y in 0..<400 { buf[y * 320 + 200] = Self.wall }
        let e = try EngineFixture.engine(buffer: buf)
        e.resetToRest(); e.sensorsEnabled = false
        for i in e.balls.indices { e.balls[i].active = 0 }
        var cfg = EnhancedPhysicsConfig.modern
        cfg.substeps = 1; cfg.speedCap = 60; cfg.classicAxisCaps = false
        let m = EnhancedPhysics.install(on: e, config: cfg)
        for (vx, vy) in [(5120, 0), (5120, 900), (4000, -3000)] {
            e.balls[0] = BallState(x: 100, y: 180, vx: Int16(vx), vy: Int16(vy))
            for _ in 0..<12 {
                m.step(e)
                let c = m.ballCentre(0)!
                XCTAssertLessThan(c.x, 200 - m.contactRadius(normal: SIMD2(-1, 0)) + 0.05, "tunnelled: \(c)")
            }
        }
        XCTAssertEqual(m.stats.nanResets, 0)
    }

    func testGateWriteUpdatesTheCollisionWorld() throws {
        let e = try floorEngine()
        let m = EnhancedPhysics.install(on: e)
        let p = SIMD2(100.5, 100.5)
        XCTAssertGreaterThan(m.wallSample(level: 0, p).value, 20)
        for x in 95..<106 { e.rulesSetPixel(100 * 320 + x, Self.wall) }   // rule code draws a gate
        e.balls[0] = BallState(x: 10, y: 10)
        m.step(e)
        XCTAssertLessThan(m.wallSample(level: 0, SIMD2(100.5, 97.5)).value, 3.5)
        for x in 95..<106 { e.rulesSetPixel(100 * 320 + x, 0) }
        m.step(e)
        XCTAssertGreaterThan(m.wallSample(level: 0, p).value, 20)
    }

    func testDeterministic() throws {
        func run() throws -> [BallState] {
            let e = try floorEngine()
            EnhancedPhysics.install(on: e, config: .modern)
            e.balls[0] = BallState(x: 30, y: 60, vx: 400, vy: -100)
            var out: [BallState] = []
            for f in 0..<400 { e.input = f % 20 < 8 ? .leftFlipper : []; e.runFrame(); out.append(e.balls[0]) }
            return out
        }
        XCTAssertEqual(try run(), try run())
    }

    func testClassicReflectionMatchesIntegerMaths() {
        // Same linear map as ClassicEngine.reflect (up to the integer truncation).
        for (nx, ny) in [(-61, 1), (48, 24), (-2, 40), (28, -35)] as [(Int16, Int16)] {
            for (vx, vy) in [(300, 500), (-640, 120), (50, -600)] as [(Int16, Int16)] {
                let r = ClassicEngine.reflect(vx: vx, vy: vy, nx: nx, ny: ny, divX: 17, divY: 17)
                let f = EnhancedPhysics.classicReflection(v: SIMD2(Double(vx), Double(vy)), n: SIMD2(Double(nx), Double(ny)), divX: 17, divY: 17)
                XCTAssertEqual(f.x, Double(r.dvx), accuracy: 4, "n \(nx),\(ny) v \(vx),\(vy)")
                XCTAssertEqual(f.y, Double(r.dvy), accuracy: 4, "n \(nx),\(ny) v \(vx),\(vy)")
            }
        }
    }

    /// The original's own contact direction for a straight wall: an east wall (normal pointing
    /// west) gives the table normal pointing west; the most frequent direction is the one
    /// `ClassicEngine.contactDirection` gives for the centred hit span.
    func testClassicDirectionTable() throws {
        let e = try floorEngine()
        let m = EnhancedPhysics(engine: e)
        for deg in stride(from: 0, to: 360, by: 5) {
            let a = Double(deg) * .pi / 180
            let n = SIMD2(cos(a), sin(a))
            let tn = m.classicNormal(n)
            XCTAssertGreaterThan((tn * n).sum() / (tn * tn).sum().squareRoot(), 0.8, "table normal points out of the wall at \(deg) deg")
        }
    }

    func testClosedFlipperOutlinesAreFilled() {
        let w = 12, h = 10
        var m = [UInt8](repeating: 0, count: w * h)
        for x in 2...9 { m[2 * w + x] = 1; m[7 * w + x] = 1 }
        for y in 2...7 { m[y * w + 2] = 1; m[y * w + 9] = 1 }
        var open = [UInt8](repeating: 0, count: w * h)
        for x in 1...10 { open[5 * w + x] = 1 }
        FlipperShape.fillEnclosed(&m, w, h)
        FlipperShape.fillEnclosed(&open, w, h)
        XCTAssertEqual(m[4 * w + 5], 1, "interior of a closed outline is solid")
        XCTAssertEqual(m[0], 0)
        XCTAssertEqual(open.filter { $0 != 0 }.count, 10, "an open outline stays as it is")
    }

    /// A ball at rest on the playfield (not in the lane, not on a flipper) is kicked after
    /// `ballSearchSeconds`; a ball resting in the plunger lane is not; with the search off nothing is.
    func testBallSearchKicksARestingBall() throws {
        func run(search: Double, x: Int16) throws -> EnhancedPhysics {
            let e = try floorEngine()
            var cfg = EnhancedPhysicsConfig.classicFeel
            cfg.ballSearchSeconds = search
            let m = EnhancedPhysics.install(on: e, config: cfg)
            e.balls[0] = BallState(x: x, y: 230)
            for _ in 0..<(60 * 5) { e.runFrame() }
            return m
        }
        XCTAssertGreaterThanOrEqual(try run(search: 3, x: 100).stats.ballSearches, 1)
        XCTAssertEqual(try run(search: 3, x: 290).stats.ballSearches, 0, "the plunger lane is exempt")
        let off = try run(search: 0, x: 100)
        XCTAssertEqual(off.stats.ballSearches, 0)
        XCTAssertLessThan((off.ballVelocity(0)! * off.ballVelocity(0)!).sum(), 9e-4)   // at rest (< 0.03 px/step)
    }

    func testGameSimulationPhysicsMode() throws {
        let sim = GameSimulation(engine: try EngineFixture.engine(), physics: .enhanced)
        XCTAssertNotNil(sim.enhanced)
        sim.engine.balls[0] = BallState(x: 100, y: 100, vx: 70, vy: 30)
        for _ in 0..<30 { sim.stepFrame() }
        XCTAssertNotNil(sim.enhanced?.ballCentre(0))
        sim.physicsMode = .classic
        XCTAssertNil(sim.engine.ballPhysics)
        sim.physicsMode = .enhanced
        XCTAssertNotNil(sim.enhanced)
        sim.enhancedConfig = .modern
        XCTAssertEqual(sim.enhanced?.config, .modern)
    }
}

extension ClassicEngine {
    /// One step of the installed model (frame logic not run).
    func physicsStepForTest(_ m: BallPhysics) { m.step(self) }
}
