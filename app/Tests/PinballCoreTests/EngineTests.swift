import Foundation
import XCTest
@testable import PinballCore

/// Response maths golden values, derived by hand from EP1 cs:1C0A..1CF5 (imul, cwd, idiv
/// truncating toward zero, 16-bit stores) and cross-checked with an independent Python
/// evaluation (scratch/port/golden_reflect.py). Inputs are synthetic.
final class ReflectionTests: XCTestCase {
    func testFloorLikeNormal() {
        // A = 192/-40 = -4; P = -4*100 + 64*300 = 18800; B = -2560/3 = -853; D = -857
        // wx = -(18800 / -857) = 21; E = 144/1600 + 64 = 64; wy = -(18800/64) = -293
        // dvx = 21*20/17 = 24; dvy = -293*20/17 = -344
        let r = ClassicEngine.reflect(vx: 100, vy: 300, nx: 3, ny: -40, divX: 17, divY: 17)
        XCTAssertEqual(r.a, -4); XCTAssertEqual(r.p, 18800); XCTAssertEqual(r.b, -853); XCTAssertEqual(r.d, -857)
        XCTAssertEqual(r.wx, 21); XCTAssertEqual(r.e, 64); XCTAssertEqual(r.wy, -293)
        XCTAssertEqual(r.dvx, 24); XCTAssertEqual(r.dvy, -344)
        XCTAssertEqual(r.faults, 0)
    }

    func testSpecialCase7FF8WhenNySquaredIsOne() {
        // ny = 1: E = 0x7FF8 (cs:1C9D). A = -3904; P = -3904*200 - 3200 = -784000 (needs 32 bits)
        // B = 64/-61 = -1; D = -3905; wx = -(-784000/-3905) = -200; wy = -(-784000/32760) = 23
        let r = ClassicEngine.reflect(vx: 200, vy: -50, nx: -61, ny: 1, divX: 17, divY: 17)
        XCTAssertEqual(r.e, 0x7FF8)
        XCTAssertEqual(r.p, -784_000)
        XCTAssertEqual(r.d, -3905)
        XCTAssertEqual(r.wx, -200); XCTAssertEqual(r.wy, 23)
        XCTAssertEqual(r.dvx, -235); XCTAssertEqual(r.dvy, 27)
    }

    func testSixteenVersusSixtyFourQuirk() {
        // 45-degree normal: a symmetric formula would give E = 64*1+64 = 128 and wy = wx = -128.
        // The code uses 16*nx^2: E = 16+64 = 80, wy = -(16384/80) = -204.
        let r = ClassicEngine.reflect(vx: 0, vy: 256, nx: 30, ny: 30, divX: 17, divY: 17)
        XCTAssertEqual(r.d, 128); XCTAssertEqual(r.wx, -128)
        XCTAssertEqual(r.e, 80); XCTAssertEqual(r.wy, -204)
        XCTAssertEqual(r.dvx, -150); XCTAssertEqual(r.dvy, -240)
    }

    func testDifferentDivisors() {
        let r = ClassicEngine.reflect(vx: -500, vy: 120, nx: 45, ny: -20, divX: 20, divY: 17)
        XCTAssertEqual(r.a, -144); XCTAssertEqual(r.p, 79680); XCTAssertEqual(r.b, -28); XCTAssertEqual(r.e, 145)
        XCTAssertEqual(r.wx, 463); XCTAssertEqual(r.wy, -549)
        XCTAssertEqual(r.dvx, 463); XCTAssertEqual(r.dvy, -645)
    }

    func testIdivTruncatesTowardZeroAndFlagsOverflow() {
        XCTAssertEqual(ClassicEngine.idiv16(-7, 2).0, -3)
        XCTAssertEqual(ClassicEngine.idiv16(7, -2).0, -3)
        XCTAssertEqual(ClassicEngine.idiv16(-7, -2).0, 3)
        XCTAssertFalse(ClassicEngine.idiv16(65534, 2).1)       // 32767 fits
        XCTAssertTrue(ClassicEngine.idiv16(65536, 2).1)        // 32768 would be #DE on a real CPU
        XCTAssertTrue(ClassicEngine.idiv16(5, 0).1)
        // quotient overflow in the scaled step: wx*20/div with a tiny divisor faults like cs:1CD7
        let r = ClassicEngine.reflect(vx: 30000, vy: 0, nx: -61, ny: 1, divX: 1, divY: 17)
        XCTAssertGreaterThan(r.faults, 0)
    }
}

/// Contact direction from the hit list (cs:1A66..1ACC). Lists are in recording order (48 -> 1).
final class ContactDirectionTests: XCTestCase {
    func dir(_ h: [UInt8]) -> UInt8 { ClassicEngine.contactDirection(h) }

    func testSingleAndContiguous() {
        XCTAssertEqual(dir([13]), 13)
        XCTAssertEqual(dir([14, 13, 12]), 13)
        XCTAssertEqual(dir([15, 14, 13, 12]), 13)         // lo + (hi-lo)/2 truncates
        XCTAssertEqual(dir([25, 1]), 13)                  // span exactly 24: no +24
    }

    func testSpanOver24AddsHalfTurn() {
        XCTAssertEqual(dir([40, 5]), 46)                  // 5 + 17 + 24
        XCTAssertEqual(dir([47, 20]), 9)                  // 20 + 13 + 24 = 57 -> 57-48
    }

    func testWrapCaseAlwaysGives48() {
        // lo == 1 && hi == 48: list[last] + (list[0] + 48 - list[last]) / 2 with list[0]=48, list[last]=1
        XCTAssertEqual(dir([48, 1]), 48)
        XCTAssertEqual(dir([48, 47, 2, 1]), 48)
        XCTAssertEqual(dir([48, 30, 1]), 48)
        XCTAssertEqual(dir([48, 47, 46, 45, 44, 1]), 48)  // a true average would be ~46
    }
}

final class IntegrationTests: XCTestCase {
    func step(_ pos: Int16, _ acc: Int16, _ v: Int16, cap: Int = 5) -> (Int16, Int16, Bool) {
        var p = pos, a = acc
        let neg = ClassicEngine.integrateAxis(pos: &p, acc: &a, v: v, capPos: cap, capNeg: cap, clampPos: 2000, clampNeg: -2000)
        return (p, a, neg)
    }

    func testAccumulatorAndCaps() {
        XCTAssertTrue(step(10, 0, 100) == (10, 100, false))
        XCTAssertTrue(step(10, 100, 100) == (11, 72, false))       // 200 -> 1 px, 72 left
        XCTAssertTrue(step(10, 0, 2000) == (15, 1360, false))      // capped at 5 px, 2000 not > 2000
        XCTAssertTrue(step(10, 0, 3000) == (15, 1360, false))      // clamped to 2000 first
        XCTAssertTrue(step(10, 0, -129) == (9, -1, true))
        XCTAssertTrue(step(10, 0, -3000) == (5, -1360, true))
        XCTAssertTrue(step(10, 0, -3000, cap: 4) == (6, -1488, true))
        // 16-bit wrap of the accumulator: 32000 + 1000 -> -32536 (negative branch)
        XCTAssertTrue(step(10, 32000, 1000) == (5, -1360, true))
    }

    func testYClampOnlyOnUpwardMove() throws {
        let e = try EngineFixture.engine()
        e.resetToRest()
        e.balls[0] = BallState(x: 0, y: 2, vx: 0, vy: -300)
        e.physicsStep()
        XCTAssertEqual(e.balls[0].x, 1)       // x < 1 -> 1
        XCTAssertEqual(e.balls[0].y, 3)       // moved to 0 -> reset to 3, vy = 0
        XCTAssertEqual(e.balls[0].vy, 0)
        e.balls[0] = BallState(x: 50, y: -5, vx: 0, vy: 10)
        e.physicsStep()
        XCTAssertEqual(e.balls[0].y, -5)      // downward branch never clamps
    }
}

final class FlipperTests: XCTestCase {
    func testPowerOnDropsFromAngle2ToRestIn7Steps() throws {
        let e = try EngineFixture.engine()
        e.resetToPowerOn()
        XCTAssertEqual(e.groups[0].angle, 2)
        for n in 1...7 {
            e.flipperUpdate()
            XCTAssertEqual(e.groups[0].angle, Int16(2 + n))
            XCTAssertFalse(e.groups[0].moving)   // moving is only set on upward steps
        }
        e.flipperUpdate()
        XCTAssertEqual(e.groups[0].angle, 9)
        // rest outline drawn, the ones passed through erased to 0x2A
        let pos = e.data.flippers[0].positions
        XCTAssertTrue(pos[9].allSatisfy { e.buffer[$0] == UInt8(EngineFixture.flipperIndex) })
        let restSet = Set(pos[9])
        XCTAssertTrue(pos[2].filter { !restSet.contains($0) }.allSatisfy { e.buffer[$0] == 0x2A })
    }

    func testOneAnglePerStepBothWays() throws {
        let e = try EngineFixture.engine()
        e.resetToRest()
        e.input = [.leftFlipper]
        for n in 1...9 {
            e.flipperUpdate()
            XCTAssertEqual(e.groups[0].angle, Int16(9 - n))
            XCTAssertTrue(e.groups[0].moving)
            XCTAssertTrue(e.data.flippers[0].positions[9 - n].allSatisfy { e.buffer[$0] == UInt8(EngineFixture.flipperIndex) })
        }
        e.flipperUpdate()                          // held at the top: not moving, no redraw
        XCTAssertEqual(e.groups[0].angle, 0)
        XCTAssertFalse(e.groups[0].moving)
        e.input = []
        for n in 1...9 {
            e.flipperUpdate()
            XCTAssertEqual(e.groups[0].angle, Int16(n))
            XCTAssertFalse(e.groups[0].moving)
        }
        // a full cycle is 9 physics steps = 3 frames each way
        e.input = [.leftFlipper]
        e.runFrame()
        XCTAssertEqual(e.groups[0].angle, 6)
    }

    func testTiltForcesRest() throws {
        let e = try EngineFixture.engine()
        e.resetToRest()
        e.input = [.leftFlipper]
        for _ in 0..<5 { e.flipperUpdate() }
        e.tilted = true
        e.flipperUpdate()
        XCTAssertEqual(e.groups[0].angle, 9)
        XCTAssertFalse(e.groups[0].moving)
    }

    func testSpriteFrameRule() {
        // cs:10F5: frame = (angle + 2) / 3 -> angle 0 only for frame 0, 7..9 = rest frame
        XCTAssertEqual((0...9).map { ClassicEngine.spriteFrame(angle: $0, frameCount: 4) }, [0, 1, 1, 1, 2, 2, 2, 3, 3, 3])
    }
}

final class EngineBehaviourTests: XCTestCase {
    /// A floor of wall pixels under a falling ball: first response reflects, push-out repeats
    /// until no probe hits, later responses only push out.
    func testFloorResponseAndPushOut() throws {
        var buf = [UInt8](repeating: 0, count: 320 * 400)
        for y in 213..<260 { for x in 0..<320 { buf[y * 320 + x] = UInt8(EngineFixture.wallIndex) } }
        let e = try EngineFixture.engine(buffer: buf)
        e.resetToRest()
        e.balls[0] = BallState(x: 100, y: 197, vx: 40, vy: 400)
        e.physicsStep()
        let log = e.lastStep.log
        XCTAssertGreaterThan(log.count, 0)
        XCTAssertTrue(log[0].first)
        XCTAssertTrue(log.dropFirst().allSatisfy { !$0.first })
        XCTAssertTrue(e.lastStep.collided)
        // no probe hits at the final position
        let b = e.balls[0]
        let ring = e.data.probeRing.offsets
        XCTAssertTrue(ring.allSatisfy { buf[Int(b.y) * 320 + Int(b.x) + $0] == 0 })
        XCTAssertLessThan(e.balls[0].vy, 400)
    }

    func testKickerKicksAlongNormalAndCoolsDown() throws {
        var buf = [UInt8](repeating: 0, count: 320 * 400)
        for y in 213..<220 { for x in 0..<320 { buf[y * 320 + x] = UInt8(EngineFixture.activeIndex) } }
        let e = try EngineFixture.engine(buffer: buf)
        e.resetToRest()
        e.balls[0] = BallState(x: 100, y: 197, vx: 0, vy: 400)
        e.physicsStep()
        let first = try XCTUnwrap(e.lastStep.log.first)
        XCTAssertEqual(first.kick, 7)                        // params[2] of the fixture
        let k = Int(first.k) - 1
        let n = (x: -e.data.normals[k][0], y: e.data.normals[k][1])
        XCTAssertEqual(Int(e.balls[0].vx), 7 * n.x)          // v += kick * n, no reflection
        XCTAssertEqual(Int(e.balls[0].vy), 400 + 7 * n.y)
        XCTAssertEqual(e.kickerCooldown, 3)
        e.frameLogic()
        XCTAssertEqual(e.kickerCooldown, 2)
        e.tilted = true
        e.kickerCooldown = 0
        e.balls[0] = BallState(x: 100, y: 197, vx: 0, vy: 400)
        e.physicsStep()
        XCTAssertEqual(e.lastStep.log.first?.kick, 0)        // no kicks while tilted
    }

    func testPlungerChargeReleaseAndLaneVx() throws {
        let e = try EngineFixture.engine()
        e.resetToRest()
        e.balls[0] = BallState(x: 284, y: 336, vx: 55, vy: 0)
        e.input = [.plunger]
        for _ in 0..<10 { e.frameLogic() }
        XCTAssertEqual(e.plungerCharge, 60)                  // ja: adds while charge <= 50
        XCTAssertEqual(e.balls[0].vx, 55)                    // held: vx untouched
        let vy = e.balls[0].vy
        e.input = []
        e.frameLogic()
        XCTAssertEqual(e.balls[0].vx, 0)                     // released in the lane: vx = 0
        XCTAssertEqual(e.balls[0].y, 335)
        XCTAssertEqual(e.balls[0].vy, vy - 60 + 5)           // -charge, then gravity (+5 in the fixture)
        XCTAssertEqual(e.plungerCharge, 0)
    }

    func testNudgeTiltMeter() throws {
        let e = try EngineFixture.engine()
        e.resetToRest()
        e.balls[0] = BallState(x: 100, y: 100)
        e.input = [.nudgeA]
        e.frameLogic()
        XCTAssertEqual(e.nudgeTimer, 9)                      // set to 10, decremented the same frame
        XCTAssertEqual(e.tiltMeter, 34)
        e.frameLogic()                                       // still held but timer running: no new nudge
        XCTAssertEqual(e.tiltMeter, 33)
        for _ in 0..<8 { e.frameLogic() }
        e.frameLogic()                                       // timer 0 -> nudge again
        XCTAssertGreaterThan(e.tiltMeter, 50)
        for _ in 0..<10 { e.frameLogic() }
        XCTAssertTrue(e.tilted)
    }

    func testDrainServesNewBall() throws {
        let e = try EngineFixture.engine()
        e.resetToRest()
        e.balls[0] = BallState(x: 150, y: 399, vx: 10, vy: 10, accx: 5, accy: 6)
        e.frameLogic()
        XCTAssertEqual(e.balls[0].active, 1)
        XCTAssertEqual(e.balls[0].x, 284)
        XCTAssertEqual(e.balls[0].y, 336)
        XCTAssertEqual(e.balls[0].vx, 0)
        XCTAssertEqual(e.balls[0].accx, 5)                   // accumulators are not cleared
        XCTAssertEqual(e.serveDelay, 6)                      // set to 7, then the lane block (same frame) decrements it
    }

    func testSensorOpsOneWayGate() throws {
        var buf = [UInt8](repeating: 0, count: 320 * 400)
        buf[105 * 320 + 60] = UInt8(EngineFixture.sensorIndex)
        let e = try EngineFixture.engine(buffer: buf)
        e.resetToRest()
        e.balls[0] = BallState(x: 55, y: 100, vx: -80, vy: 0)
        e.frameLogic()
        XCTAssertEqual(e.balls[0].vx, 80)                    // vx <= 0 -> negated, x += 3
        XCTAssertEqual(e.balls[0].x, 58)
        XCTAssertEqual(e.eventLockout, 2)
        e.sensorsEnabled = false
        e.balls[0] = BallState(x: 55, y: 100, vx: -80, vy: 0)
        e.eventLockout = 0
        e.frameLogic()
        XCTAssertEqual(e.balls[0].vx, -80)
    }

    func testOcclusionComposite() throws {
        var buf = [UInt8](repeating: 0, count: 320 * 400)
        buf[52 * 320 + 43] = UInt8(EngineFixture.occluderIndex)
        let e = try EngineFixture.engine(buffer: buf)
        e.resetToRest()
        e.balls[0] = BallState(x: 40, y: 50)
        let px = try XCTUnwrap(e.compositedBallPixels())
        XCTAssertEqual(px[2 * 15 + 3], UInt8(EngineFixture.occluderIndex))
        XCTAssertEqual(px[0], 0)
        XCTAssertEqual(px[1], 9)
    }
}

final class EngineDataTests: XCTestCase {
    func testDecodesSyntheticEngineJSON() throws {
        let d = try EngineData.decode(EngineFixture.json())
        XCTAssertEqual(d.params.values.count, 10)
        XCTAssertEqual(d.probeRing.offsets.count, 48)
        XCTAssertEqual(d.flippers[0].positions.count, 10)
        XCTAssertEqual(d.flipperGroups[0].initAngle, 2)
        XCTAssertEqual(d.integration.stepCap.xNeg, 4)
        XCTAssertEqual(d.ball.pixels?.count, 210)
        guard case let .branch(_, cmp, _, size, then, els)? = d.sensors.levels[0]["250"]?.ops.first else {
            return XCTFail("sensor op not decoded")
        }
        XCTAssertEqual(cmp, "gt"); XCTAssertEqual(size, 16); XCTAssertEqual(then.count, 1); XCTAssertEqual(els.count, 4)
    }

    func testRejectsBadEngineJSON() {
        XCTAssertThrowsError(try EngineData.decode(EngineFixture.json { $0["version"] = 99 }))
        XCTAssertThrowsError(try EngineData.decode(EngineFixture.json { $0["normals"] = [[1, 2]] }))
        XCTAssertThrowsError(try EngineData.decode(EngineFixture.json { $0["format"] = "nope" }))
        XCTAssertThrowsError(try EngineData.decode(Data("{".utf8)))
        XCTAssertThrowsError(try EngineData.decode(EngineFixture.json {
            $0["flipper_map"] = ["contact1_moving": 5, "contact2_moving": 0, "contact1_angle": 0, "contact2_angle": 0]
        }))
    }

    /// Uses the user's own extracted engine.json files when present.
    func testDecodesExtractedEngineJSONIfPresent() throws {
        let root = DataLocator.packageRelativeDefault
        var found = 0
        for n in 1...TableGeometry.tableCount {
            let url = root.appendingPathComponent("tables/EP\(n)/engine.json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let d = try EngineData.load(contentsOf: url)
            XCTAssertEqual(d.table, n)
            for f in d.flippers {
                for p in f.positions { XCTAssertTrue(p.allSatisfy { (0..<128_000).contains($0) }, "EP\(n) outline out of range") }
            }
            found += 1
        }
        if found == 0 { throw XCTSkip("no extracted engine.json under \(root.path)") }
    }

    /// EP1's start-up buffer is its playfield with the flipper art (0xD3...0xE6) set to 0x2A (cs:03D5).
    func testEP1StartBufferMatchesPlayfieldSubstitution() throws {
        let root = DataLocator.packageRelativeDefault
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("tables/EP1/engine.json").path) else {
            throw XCTSkip("no extracted EP1 data")
        }
        let (_, buf) = try EngineAssets.load(dataRoot: root, table: 1)
        let pf = try TableAssets.load(dataRoot: root, table: 1).indices
        let expected = pf.map { (0xD3...0xE6).contains($0) ? UInt8(0x2A) : $0 }
        XCTAssertEqual(buf, expected)
    }
}

final class TraceTests: XCTestCase {
    func testScenarioParsingAndRecordFormat() throws {
        let json = """
        {"table": 1, "frames": 4, "ball": {"x": 100, "y": 100, "vx": 10, "vy": -20},
         "inputs": [1, 1], "params": {"rest_x": 20, "gravity": 7}, "on_drain": "stop"}
        """
        let sc = try Scenario.parse(Data(json.utf8))
        XCTAssertEqual(sc.paramOverrides[0], 20)
        XCTAssertEqual(sc.paramOverrides[9], 7)
        XCTAssertEqual(sc.input(frame: 1), [.leftFlipper])
        XCTAssertEqual(sc.input(frame: 3), [])
        let text = TraceRunner.run(sc, engine: try EngineFixture.engine())
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 12)                       // 3 physics steps per frame
        let rec = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        for k in ["frame", "step", "ball", "collided", "k", "left_flipper_pos", "right_flipper_pos", "extra"] {
            XCTAssertNotNil(rec[k], k)
        }
        let ball = try XCTUnwrap(rec["ball"] as? [String: Any])
        XCTAssertEqual(Set(ball.keys), ["x", "y", "xf", "yf", "vx", "vy"])
        // gravity (7 here) is applied in the main-loop work before step 0
        XCTAssertEqual(ball["vy"] as? Int, -13)
        let last = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[5].utf8)) as? [String: Any])
        XCTAssertEqual(last["left_flipper_pos"] as? Int, 3)   // 6 steps held from rest
    }

    func testArrayParamsWithNullsAndDrainStop() throws {
        let json = """
        {"table": 1, "frames": 10, "ball": {"x": 100, "y": 398, "vy": 300}, "params": [null, 19, null, null, null, null, null, null, null, null]}
        """
        let sc = try Scenario.parse(Data(json.utf8))
        XCTAssertEqual(sc.paramOverrides, [1: 19])
        let lines = TraceRunner.run(sc, engine: try EngineFixture.engine()).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)                        // frame 1 starts with y >= 399 -> stop
    }

    func testSchemaFieldNames() throws {
        let schemaURL = DataLocator.packageRelativeDefault.deletingLastPathComponent()
            .appendingPathComponent("tools/emu/trace_schema.json")
        if let d = try? Data(contentsOf: schemaURL) {
            let (n, warnings) = TraceFieldNames.fromSchema(d)
            XCTAssertEqual(n, TraceFieldNames(), "the harness schema should use the contract's names")
            XCTAssertEqual(warnings, [])
        }
        let synthetic = """
        {"properties": {"f": {}, "s": {}, "ball": {"properties": {"x": {}, "y": {}, "accx": {}, "accy": {}, "vx": {}, "vy": {}}},
         "collided": {}, "dir": {}, "left_flipper": {}, "right_flipper": {}}}
        """
        let (n, _) = TraceFieldNames.fromSchema(Data(synthetic.utf8))
        XCTAssertEqual(n.frame, "f"); XCTAssertEqual(n.xf, "accx"); XCTAssertEqual(n.k, "dir"); XCTAssertEqual(n.leftFlipper, "left_flipper")
    }
    // The differential tests against the original code are in DifferentialTests.swift.
}

final class GameSimulationTests: XCTestCase {
    func testRealTimeRunsWholeFramesAt5994Hz() throws {
        let sim = GameSimulation(engine: try EngineFixture.engine())
        XCTAssertEqual(sim.advance(by: 1.0 / 59.94 * 2.5), 2)
        XCTAssertEqual(sim.engine.frameCount, 2)
        XCTAssertEqual(sim.advance(by: 1.0 / 59.94 * 0.5 + 1e-6), 1)   // remainder carried over
        XCTAssertEqual(sim.advance(by: 5.0), 5)                        // clamped to maxFrameTime (0.1 s)
        XCTAssertEqual(sim.engine.stepCount, 8 * 3)
    }

    func testEnhancedModeOnlyChangesPresentation() throws {
        let a = GameSimulation(engine: try EngineFixture.engine(), mode: .classic)
        let b = GameSimulation(engine: try EngineFixture.engine(), mode: .enhanced)
        a.engine.balls[0] = BallState(x: 100, y: 100, vx: 70, vy: 30)
        b.engine.balls[0] = a.engine.balls[0]
        for _ in 0..<30 { a.stepFrame(); b.stepFrame() }
        XCTAssertEqual(a.engine.balls, b.engine.balls)
        XCTAssertEqual(a.renderBallTopLeft, Vec2(Double(a.engine.balls[0].x), Double(a.engine.balls[0].y)))
    }
}
