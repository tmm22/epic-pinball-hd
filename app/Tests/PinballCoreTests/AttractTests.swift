import Foundation
import XCTest
@testable import PinballCore

/// Demo ("attract") mode, docs/enhanced/attract.md: the block found in every table's EXE, the demo
/// playing itself, the app's launch policy, and (live) the port against the original's demo in the
/// Unicorn harness. Every test skips per table without the user's files.
final class AttractTests: XCTestCase {
    static let dataRoot = DataLocator.packageRelativeDefault
    static let project = dataRoot.deletingLastPathComponent()

    func engine(_ n: Int, backend: RulesBackend = .default) throws -> ClassicEngine {
        let fm = FileManager.default
        for f in ["tables/EP\(n)/engine.json", "tables/EP\(n)/collision_idx.npy"] {
            guard fm.fileExists(atPath: Self.dataRoot.appendingPathComponent(f).path) else { throw XCTSkip("no extracted \(f)") }
        }
        guard RulesRuntime.locateEXE(dataRoot: Self.dataRoot, table: n) != nil else { throw XCTSkip("no original/EP\(n).EXE") }
        let e = try EngineAssets.makeEngine(dataRoot: Self.dataRoot, table: n, rules: false)
        let r = try RulesRuntime.load(dataRoot: Self.dataRoot, table: n, backend: backend)
        r.attach(to: e, mode: .off)
        return e
    }

    /// (block, keys, resume, flag) per table, from the disassembly (tools/disasm.py xref of the flag)
    /// and the harness runs; EP5 is the older single-ball block.
    static let expected: [Int: (Int, Int, Int, Int)] = [
        1: (0x0C48, 0x0D1D, 0x0E8A, 0x6C5A), 2: (0x0D2E, 0x0E03, 0x0F6E, 0x64E0), 3: (0x099E, 0x0A73, 0x0BE0, 0x5D65),
        4: (0x0D62, 0x0E37, 0x0FA4, 0x6CBB), 5: (0x091E, 0x099D, 0x0B0A, 0x536F), 6: (0x0C7B, 0x0D50, 0x0EBD, 0x6BB7),
        7: (0x0BBC, 0x0C91, 0x0DFE, 0x64BF), 8: (0x0C6A, 0x0D3F, 0x0EB9, 0x7285), 9: (0x0E03, 0x0ED8, 0x104F, 0x513E),
        10: (0x0C54, 0x0D29, 0x0EA0, 0x4831), 11: (0x0CB1, 0x0D86, 0x0EFD, 0x4D0A), 12: (0x0B9A, 0x0C6F, 0x0DE6, 0x4EED),
        13: (0x0B3B, 0x0C10, 0x0D87, 0x4F10),
    ]

    func testLayoutFoundInEveryTable() throws {
        var found = 0
        for n in 1...13 {
            let e: ClassicEngine
            do { e = try engine(n) } catch is XCTSkip { continue }
            let a = try XCTUnwrap(e.attractLayout, "EP\(n): demo block not found")
            let x = try XCTUnwrap(Self.expected[n])
            XCTAssertEqual([a.block, a.keys, a.resume, a.flag], [x.0, x.1, x.2, x.3], "EP\(n)")
            XCTAssertEqual(a.flipMinY, 350, "EP\(n)")
            XCTAssertEqual(a.leftX, 88...138, "EP\(n)")
            XCTAssertEqual(a.rightX, 148...193, "EP\(n)")
            XCTAssertEqual(a.flipFrames, 10, "EP\(n)")
            XCTAssertEqual(a.keyRepeatFrames, 20, "EP\(n)")
            XCTAssertEqual(a.releaseAtMax, n == 1, "EP\(n): only EP1 releases the plunger in demo mode (cs:0B79)")
            if n == 5 {
                XCTAssertEqual(a.slots, 1); XCTAssertFalse(a.activeTest); XCTAssertNil(a.stuck)
            } else {
                XCTAssertEqual(a.slots, 3, "EP\(n)"); XCTAssertTrue(a.activeTest, "EP\(n)")
                XCTAssertEqual(a.stuck?.limit, 25, "EP\(n)")
            }
            // the lifted backend sees the same code
            if n == 1 || n == 10 { XCTAssertEqual(try engine(n, backend: .lifted).attractLayout, a, "EP\(n) lifted") }
            found += 1
        }
        if found == 0 { throw XCTSkip("no table data") }
    }

    /// The automatic main loop (EP2-EP13) in demo mode: the block right after the lane, no nudge/tilt.
    func testDemoScheduleReplacesNudge() throws {
        var checked = 0
        for n in 2...13 {
            let e: ClassicEngine
            do { e = try engine(n) } catch is XCTSkip { continue }
            let r = try XCTUnwrap(e.rules), a = try XCTUnwrap(e.attractLayout)
            guard r.hasAutomaticHooks else { continue }
            let normal = r.schedule(engine: e), demo = r.demoSchedule(engine: e, layout: a)
            XCTAssertTrue(normal.contains(.nudge), "EP\(n)")
            XCTAssertFalse(demo.contains(.nudge), "EP\(n)")
            let lane = try XCTUnwrap(demo.firstIndex(of: .lane), "EP\(n)")
            XCTAssertEqual(demo[lane + 1], .attract, "EP\(n)")
            XCTAssertEqual(demo.filter { $0 != .attract }, normal.filter { $0 != .nudge && demo.contains($0) }, "EP\(n)")
            checked += 1
        }
        if checked == 0 { throw XCTSkip("no table data") }
    }

    /// EP1's demo (players 'D'): it plunges, flips by itself and scores, and the demo idle text
    /// (dmd_idle_text cs:3AFF -> ds:6C5B, AX 0100h, DI E100h) is shown; the player's input is ignored.
    func testEP1DemoPlaysItself() throws {
        let e = try engine(1)
        var o = RulesOptions.harness
        o.demo = true
        e.startGame(options: o)
        XCTAssertTrue(e.demoMode)
        let r = try XCTUnwrap(e.rules)
        r.traceCalls = true
        var minY = Int16.max, flips = 0, launched = false
        for _ in 0..<3000 {
            e.input = [.plunger, .nudgeA]          // ignored in demo mode
            e.runFrame()
            minY = min(minY, e.balls[0].y)
            if !e.demoKeys.isEmpty { flips += 1 }
            if e.balls[0].vy < -500 { launched = true }
        }
        XCTAssertTrue(launched, "the demo releases the plunger")
        XCTAssertLessThan(minY, 50, "the ball reached the top of the table")
        XCTAssertGreaterThan(flips, 20, "the demo flips")
        XCTAssertEqual(e.tiltMeter, 0, "no nudges in demo mode")
        XCTAssertGreaterThan(r.score, 0)
        XCTAssertTrue(r.messageCalls.contains { $0 == [0x6C5B, 0x100, 0xE100] }, "demo idle text \(r.messageCalls.prefix(8))")
        XCTAssertEqual(r.warnings, [])
    }

    /// EP2-EP13 never plunge in the original's demo; `attractLaunch` (the app) releases at full charge.
    func testLaunchPolicyOnTablesWithoutRelease() throws {
        let e = try engine(10)
        var o = RulesOptions.harness
        o.demo = true
        e.startGame(options: o)
        for _ in 0..<600 { e.runFrame() }
        XCTAssertGreaterThanOrEqual(e.balls[0].y, 330, "the original's EP10 demo keeps the ball in the lane")
        XCTAssertEqual(Int(e.plungerCharge), e.data.plunger.max)
        e.startGame(options: o)
        e.attractLaunch = true
        var minY = Int16.max
        for _ in 0..<1200 { e.runFrame(); minY = min(minY, e.balls[0].y) }
        XCTAssertLessThan(minY, 200, "with attractLaunch the demo plays")
    }

    /// Demo off (the default): the engine reads the player's input and the flag is clear.
    func testDemoOffByDefault() throws {
        let e = try engine(1)
        e.startGame(options: .harness)
        XCTAssertFalse(e.demoMode)
        e.input = [.leftFlipper]
        e.runFrame()
        XCTAssertEqual(e.input, [.leftFlipper])
        XCTAssertLessThan(e.groups[0].angle, 9, "the player's flipper moves")
        e.setDemoMode(true)
        XCTAssertTrue(e.demoMode)
        e.setDemoMode(false)
        XCTAssertFalse(e.demoMode)
    }

    /// Live: the attract scenarios of EP1 and EP10 (tools/emu/scenarios/EPn/attract) through the original
    /// code in the harness and through `TraceRunner`, record for record.
    func testMatchesOriginalDemoLive() throws {
        if ProcessInfo.processInfo.environment["EP_SKIP_LIVE_DIFF"] != nil { throw XCTSkip("EP_SKIP_LIVE_DIFF is set") }
        let fm = FileManager.default
        let python = Self.project.appendingPathComponent(".venv/bin/python")
        let runner = Self.project.appendingPathComponent("tools/emu/run_scenario.py")
        guard fm.isExecutableFile(atPath: python.path), fm.fileExists(atPath: runner.path) else {
            throw XCTSkip("needs .venv/bin/python (with unicorn) and tools/emu/run_scenario.py")
        }
        var compared = 0
        for n in [1, 10] {
            let e: ClassicEngine
            do { e = try engine(n) } catch is XCTSkip { continue }
            let dir = Self.project.appendingPathComponent("tools/emu/scenarios/EP\(n)/attract")
            guard fm.fileExists(atPath: dir.path) else { continue }
            let out = fm.temporaryDirectory.appendingPathComponent("ep-attract-\(ProcessInfo.processInfo.processIdentifier)-\(n)")
            defer { try? fm.removeItem(at: out) }
            let p = Process()
            p.executableURL = python
            p.currentDirectoryURL = Self.project
            p.arguments = [runner.path, "--batch", out.path, dir.path]
            let err = Pipe()
            p.standardOutput = FileHandle.nullDevice
            p.standardError = err
            try p.run()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let msg = String(decoding: errData, as: UTF8.self)
                if msg.contains("No module named") { throw XCTSkip("harness dependencies missing") }
                XCTFail("harness failed: \(msg.suffix(600))"); continue
            }
            for name in try fm.contentsOfDirectory(atPath: dir.path).filter({ $0.hasSuffix(".json") }).sorted() {
                let sc = try Scenario.load(contentsOf: dir.appendingPathComponent(name))
                let ref = try String(contentsOf: out.appendingPathComponent(name.replacingOccurrences(of: ".json", with: ".jsonl")), encoding: .utf8)
                let port = DifferentialTests.parseLines(TraceRunner.run(sc, engine: e))
                if let m = DifferentialTests.compare(reference: DifferentialTests.parseLines(ref), port: port) { XCTFail("EP\(n) \(name): \(m)") }
                compared += 1
            }
        }
        if compared == 0 { throw XCTSkip("no attract scenarios or table data") }
    }
}
