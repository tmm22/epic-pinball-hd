import Foundation
import XCTest
@testable import PinballCore

/// The rules.json loader and interpreter on synthetic documents (RulesFixture): expression and
/// condition semantics of docs/formats/rules.md 3.2/3.3 (as the reference interpreter
/// scratch/rules/verify_ir.py implements them), engine bindings and dispatch.
final class RulesInterpreterTests: XCTestCase {
    typealias F = RulesFixture

    /// Runs one block with `ops` on a fresh machine (no engine) and returns the machine.
    func run(_ ops: [[String: Any]], end: [String: Any] = ["return": true], extra: [String: Any] = [:],
             registers: [String: Int] = [:]) throws -> RulesMachine {
        var blocks: [String: Any] = ["L1000": F.block(0x1000, ops, end: end)]
        for (k, v) in extra { blocks[k] = v }
        let p = try F.program(F.rules(blocks: blocks))
        let m = try RulesMachine(program: p, exe: F.exe())
        m.call(p.labels["L1000"]!, registers: registers)
        return m
    }

    func testDecodeResolvesLabelsVarsAndTables() throws {
        let p = try F.program()
        XCTAssertEqual(p.table, 1)
        XCTAssertEqual(p.sensorTable, F.jumpTable, "cs:0100 is hex without 0x")
        XCTAssertEqual(p.dsFileOffset, F.dsFileOffset)
        XCTAssertEqual(p.address(of: "counter"), .init(addr: F.counter, size: 1))
        XCTAssertEqual(p.address(of: "score.hi"), .init(addr: F.score + 2, size: 2))
        XCTAssertEqual(p.hooks["kicker"]?.entryIP, 0x0700)
        XCTAssertEqual(p.colourHandler[F.sensorColour], "h0500")
        XCTAssertEqual(p.lampFirst, F.lampFirst)
        XCTAssertEqual(p.gates.first?.offsets, [20 * 320 + 10, 20 * 320 + 11])
        XCTAssertEqual(p.sweeps.first?.stepIDVars, [F.sweepStep])
        XCTAssertEqual(p.sweeps.first?.endIDVars, [F.sweepEnd])
    }

    func testDecodeRejectsBadDocuments() {
        XCTAssertThrowsError(try F.program(F.rules { $0["schema"] = "epic-pinball-rules/2" }))
        XCTAssertThrowsError(try F.program(F.rules(blocks: ["L1000": F.block(0x1000, [], end: ["goto": "L9999"])])))
        XCTAssertThrowsError(try F.program(F.rules(blocks: ["L1000": F.block(0x1000, [["op": "frobnicate", "ip": "0x10"]])])))
        XCTAssertThrowsError(try F.program(F.rules(blocks: ["L1000": F.block(0x1000, [["op": "set", "var": "nope", "w": 1, "val": 1]])])))
        XCTAssertThrowsError(try F.program(F.rules(blocks: ["L1000": F.block(0x1000, [
            ["op": "sound_sweep_start", "sweep": "0099", "active": 1]])])), "unknown sweep role must not be dropped silently")
    }

    /// Unliftable pieces load: `asm` marks its block (the handler runs from the EXE), `out` is dropped,
    /// `call` becomes a native call, and a computed pixel offset is evaluated at run time.
    func testUnliftableOpsLoad() throws {
        let p = try F.program(F.rules(blocks: ["L1000": F.block(0x1000, [
            ["op": "asm", "ip": "0x1010", "text": "mov byte ptr es:[di], al"],
            ["op": "asm", "ip": "0x1014", "text": "out dx, al"],
            ["op": "call", "target": "0x2000", "ip": "0x1018"],
            ["op": "pixels", "val": 7, "half": 1, "offset": ["add", 100, 20]]])]))
        let b = p.blocks[p.labels["L1000"]!]
        XCTAssertEqual(b.ops.count, 3)
        XCTAssertEqual(b.ops[0], .asm(ip: 0x1010))
        XCTAssertEqual(b.ops[1], .native(target: 0x2000, ip: 0x1018))
        XCTAssertTrue(p.nativeBlocks.contains(p.labels["L1000"]!))
    }

    func testShiftCountsAreMasked() throws {
        let m = try run([
            ["op": "set", "var": "temp", "w": 2, "val": ["shl", 3, 33]],       // x86: count & 31 = 1 -> 6
            ["op": "set", "var": "temp2", "w": 2, "val": ["shr", 0x8000, 47]], // 15 -> 1
        ])
        XCTAssertEqual(m.read(F.temp, 2), 6)
        XCTAssertEqual(m.read(F.temp2, 2), 1)
    }

    func testArithmeticTruncatesWhereTheSchemaSays() throws {
        let m = try run([
            ["op": "set", "var": "temp", "w": 2, "val": ["shl", 0x8001, 1]],                 // 0x0002
            ["op": "set", "var": "temp2", "w": 2, "val": ["neg", 5]],                         // 0xFFFB
            ["op": "set", "var": "mode", "w": 2, "val": ["sar", 0x8000, 4]],                  // 0xF800
            ["op": "set", "var": "last_ax", "w": 2, "val": ["setlo", 0x1234, 0x1FF]],         // 0x12FF
            ["op": "set", "var": "last_bx", "w": 2, "val": ["div32", ["join", 1, 0], 16]],    // 0x1000
            ["op": "set", "var": "counter", "w": 1, "val": ["mod32", ["join", 0, 1000], 7]],  // 6
            ["op": "set", "var": "contact", "w": 1, "val": ["ltu", 0xFFFF, 1, 1]],            // 0xFF < 1: 0
        ])
        XCTAssertEqual(m.read(F.temp, 2), 0x0002)
        XCTAssertEqual(m.read(F.temp2, 2), 0xFFFB)
        XCTAssertEqual(m.read(F.mode, 2), 0xF800)
        XCTAssertEqual(m.read(F.lastAX, 2), 0x12FF)
        XCTAssertEqual(m.read(F.lastBX, 2), 0x1000)
        XCTAssertEqual(m.read(F.counter, 1), 6)
        XCTAssertEqual(m.read(F.contact, 1), 0)
        XCTAssertTrue(m.faults.isEmpty)
    }

    func testConditionsCompareAtTheirWidthSignedAndUnsigned() throws {
        func taken(_ c: [String: Any]) throws -> Bool {
            let m = try run([], end: ["if": c, "then": "L1100", "else": "@return"],
                            extra: ["L1100": F.block(0x1100, [["op": "set", "var": "counter", "w": 1, "val": 1]])])
            return m.read(F.counter, 1) == 1
        }
        XCTAssertTrue(try taken(["cmp": "slt", "a": 0x80, "b": 1, "w": 1]), "0x80 is -128 as a byte")
        XCTAssertFalse(try taken(["cmp": "slt", "a": 0x80, "b": 1, "w": 2]), "0x0080 is +128 as a word")
        XCTAssertTrue(try taken(["cmp": "ugt", "a": 0x80, "b": 1, "w": 1]))
        XCTAssertTrue(try taken(["cmp": "eq", "a": 0x1FF, "b": 0xFF, "w": 1]), "compared after truncation")
        XCTAssertTrue(try taken(["cmp": "sge", "a": ["neg", 3], "b": ["neg", 4], "w": 2]))
        XCTAssertFalse(try taken(["cmp": "uge", "a": ["neg", 4], "b": ["neg", 3], "w": 2]))
    }

    func testMultiWriteEvaluatesBeforeStoringAndStackOps() throws {
        let m = try run([
            ["op": "set", "var": "temp", "w": 2, "val": 7],
            ["op": "set", "var": "temp2", "w": 2, "val": 9],
            ["op": "reg", "r": "ax", "val": 0x1234],
            ["op": "push", "val": ["reg", "ax"]],
            ["op": "push_all"],
            ["op": "reg", "r": "ax", "val": 1],
            ["op": "pop_all"],
            ["op": "set", "var": "last_ax", "w": 2, "val": ["reg", "ax"]],     // restored 0x1234
            ["op": "reg", "r": "ax", "val": 0],
            ["op": "pop", "r": "bx"],
            ["op": "set", "var": "last_bx", "w": 2, "val": ["reg", "bx"]],     // 0x1234
            ["op": "gosub", "entry": "L1200"],
            ["op": "set", "var": "counter", "w": 1, "val": ["reg", "cf"]],
        ], extra: ["L1200": F.block(0x1200, [["op": "reg", "r": "cf", "val": 1]])])
        XCTAssertEqual(m.read(F.lastAX, 2), 0x1234)
        XCTAssertEqual(m.read(F.lastBX, 2), 0x1234)
        XCTAssertEqual(m.read(F.counter, 1), 1, "gosub may leave cf set")
        XCTAssertTrue(m.faults.isEmpty)
    }

    func testUnknownRegisterReadIsAFaultNotAValue() throws {
        let m = try run([
            ["op": "reg", "r": "cx", "val": ["unknown", "0x1234"]],
            ["op": "set", "var": "counter", "w": 1, "val": ["reg", "cx"]],
        ])
        XCTAssertFalse(m.faults.isEmpty)
    }

    func testScoreLampNumberTextAndStores() throws {
        let m = try run([
            ["op": "score", "add": ["var", "temp", 2]],
            ["op": "lamp", "slot": 3, "state": 2],
            ["op": "lamps", "slot": 0, "count": 2, "states16": 0x0605],
            ["op": "store", "w": 1, "addr": ["add", F.message, 2], "val": 0x37],     // patch a digit into the string
            ["op": "number_text", "value": ["join", 0, 1205], "buf": F.temp2],
        ])
        XCTAssertEqual(m.read(F.lampFirst + 3, 1), 2)
        XCTAssertEqual(m.read(F.lampFirst, 2), 0x0605)
        XCTAssertEqual(m.string(at: F.message), Array("AB7".utf8))
        // num_to_text: digits at buf+1...buf+10, leading positions untouched, 0 at buf+12
        XCTAssertEqual((1...10).map { m.read8(F.temp2 + $0) }, [0, 0, 0, 0, 0, 0, 0x31, 0x32, 0x30, 0x35])
        XCTAssertEqual(m.read8(F.temp2 + 12), 0)
    }

    func testScoreIsA32BitWrappingAdd() throws {
        let p = try F.program(F.rules(blocks: ["L1000": F.block(0x1000, [["op": "score", "add": 0x20]])]))
        let m = try RulesMachine(program: p, exe: F.exe())
        m.write(F.score, 4, 0xFFFF_FFF0)
        m.call(p.labels["L1000"]!)
        XCTAssertEqual(m.read(F.score, 4), 0x10)
    }

    func testBindingsReachTheEngineByteExact() throws {
        let (e, r) = try F.engine()
        e.balls[1].x = 0x1234
        let m = r.machine
        XCTAssertEqual(m.read(F.slotX + 2, 2), 0x1234, "slot 1 x through the bus")
        m.write8(F.slotX + 3, 0x56)          // high byte only
        XCTAssertEqual(e.balls[1].x, 0x5634)
        m.write(F.objVX, 2, 0xFFF6)
        XCTAssertEqual(e.rulesField(.objVX), 0xFFF6)
        m.write8(F.tilted, 1)
        XCTAssertTrue(e.tilted)
        // past the data segment the window overlaps the live collision buffer
        m.write8(F.dsSize + 5 * 320 + 7, 0xAB)
        XCTAssertEqual(e.buffer[5 * 320 + 7], 0xAB)
        XCTAssertEqual(m.read8(F.dsSize + 5 * 320 + 7), 0xAB)
    }

    func testGateDrawUsesTheControlByte() throws {
        let (e, r) = try F.engine()
        r.machine.write(F.temp, 2, 0)
        r.machine.drawGate(0)
        XCTAssertEqual(e.buffer[20 * 320 + 10], 200)
        r.machine.write(F.temp, 2, 1)
        r.machine.drawGate(0)
        XCTAssertEqual(e.buffer[20 * 320 + 11], 1)
    }

    // MARK: dispatch

    /// A buffer with sensor pixels under a ball at (100, 100).
    func sensorBuffer() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 320 * 400)
        for y in 102..<108 { for x in 104..<108 { b[y * 320 + x] = UInt8(F.sensorColour) } }
        return b
    }

    func testDispatchRunsTheHandlerWithEntryRegistersAndLockout() throws {
        let (e, r) = try F.engine(buffer: sensorBuffer())
        e.balls[0] = BallState(x: 100, y: 100, vx: 50, vy: 0)
        e.runFrame()
        XCTAssertEqual(r.machine.read(F.counter, 1), 1, "the handler sets lockout 2, so it runs once per scan")
        XCTAssertEqual(r.machine.read(F.lastAX, 2), Int64(F.sensorColour), "AX = colour | lockout << 8 (lockout 0)")
        XCTAssertEqual(r.machine.read(F.lastBX, 2), 0x0500, "BX = handler address from the jump table")
        XCTAssertEqual(e.eventLockout, 2)
        XCTAssertTrue(r.machine.faults.isEmpty)
    }

    func testDispatchFiltersTiltAndLevel() throws {
        do {
            let (e, r) = try F.engine(buffer: sensorBuffer())
            e.balls[0] = BallState(x: 100, y: 100, vx: 50, vy: 0)
            e.tilted = true
            e.runFrame()
            XCTAssertEqual(r.machine.read(F.counter, 1), 0, "tilted: only fires_when_tilted colours pass")
        }
        do {
            let sensors: [[String: Any]] = [["colour": "FA", "value": F.sensorColour, "level": 0, "handler": "h0500",
                                             "fires_when_tilted": true, "ignores_lockout": false, "regions": [Any]()]]
            let (e, r) = try F.engine(rules: F.rules(sensors: sensors), buffer: sensorBuffer())
            e.balls[0] = BallState(x: 100, y: 100, vx: 50, vy: 0)
            e.tilted = true
            e.runFrame()
            XCTAssertEqual(r.machine.read(F.counter, 1), 1)
        }
        do {
            let (e, r) = try F.engine(buffer: sensorBuffer())
            e.balls[0] = BallState(x: 100, y: 100, vx: 50, vy: 0, layer: 1)
            r.dispatch(value: F.sensorColour, layer: 1, tilted: false, lockout: 0)
            XCTAssertEqual(r.machine.read(F.counter, 1), 0, "level 1: only level-1 sensor colours pass")
            r.dispatch(value: 0xA0, layer: 0, tilted: false, lockout: 0)
            XCTAssertEqual(r.machine.read(F.counter, 1), 0, "values below 0xAA never dispatch")
        }
    }

    func testDispatchWritesBackTheBallThroughTheWorkingCopy() throws {
        let (e, _) = try F.engine(buffer: sensorBuffer())
        e.balls[0] = BallState(x: 100, y: 100, vx: 50, vy: 0)
        e.runFrame()
        XCTAssertLessThan(e.balls[0].vx, 0, "handler negated vx via ball + ball_commit")
    }

    func testKickerHookGetsSlotAndContactPixel() throws {
        let (e, r) = try F.engine()
        e.balls[0] = BallState(x: 10, y: 10)
        e.balls[2] = BallState(x: 10, y: 10)
        XCTAssertTrue(r.kicker(ball: 2, contact: 0xCF))
        XCTAssertEqual(r.machine.read(F.contact, 1), 0xCF)
        XCTAssertEqual(e.kickStrength, 5)
        XCTAssertEqual(e.kickerCooldown, 3)
        XCTAssertEqual(r.score, 100)
    }

    func testPhysicsModeIgnoresAttachedRules() throws {
        let (e, r) = try F.engine(buffer: sensorBuffer())
        e.rulesMode = .off
        e.balls[0] = BallState(x: 100, y: 100, vx: 50, vy: 0)
        e.runFrame()
        XCTAssertEqual(r.machine.read(F.counter, 1), 0)
    }
}
