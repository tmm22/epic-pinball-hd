import Foundation
import Metal
import XCTest
@testable import PinballCore
@testable import PinballRender

/// EP8's robot set (`SpriteSetRoutine`, cs:A42F): found in the EXE, reported by both rules backends
/// when sensor handler 0xEA's sequence draws it (cs:2EA4..2F29), and blitted by the composer.
final class SpriteSetTests: XCTestCase {
    func testFindsOnlyEP8Routine() throws {
        var found = 0
        for n in 1...13 {
            guard let exe = RulesDirectTests.exe(n), let image = try? ExeImage(exe: exe) else { continue }
            found += 1
            let r = SpriteSetRoutine.find(code: image.code)
            if n == 8 {
                XCTAssertEqual(r, [SpriteSetRoutine(entry: 0xA42F, segment: 0x3F88, count: 6, onTable: 0x9238, offTable: 0x922C)])
                XCTAssertEqual(r.first?.selector(code: image.code, from: 0x2F27), 1)
                XCTAssertEqual(r.first?.selector(code: image.code, from: 0x2EE0), 0)
            } else {
                XCTAssertEqual(r, [], "EP\(n)")
            }
        }
        if found == 0 { throw XCTSkip("no original EXEs") }
    }

    /// Handler 0xEA with the ball below y 250 holds the ball and counts ds:0739 down from 500 (cs:2E8C):
    /// the robot is drawn on the 10th call (count 1EAh, cs:2F27), the background when the count reaches
    /// 0 (cs:2F0D). The three show steps at 1EAh, 140h and 96h jump back to the `dec` (cs:2F52, 2F78,
    /// 2F88), so that is call 497; with the ball still there the next call starts the show again.
    func testHandlerReportsRobotBothBackends() throws {
        let root = DataLocator.packageRelativeDefault
        guard RulesDirectTests.exe(8) != nil, (try? EngineAssets.makeEngine(dataRoot: root, table: 8, rules: false)) != nil else {
            throw XCTSkip("no EP8 data")
        }
        var calls: [RulesBackend: [(Int, Int)]] = [:]
        for backend in RulesBackend.allCases {
            let e = try EngineAssets.makeEngine(dataRoot: root, table: 8, rules: false)
            let r = try RulesRuntime.load(dataRoot: root, table: 8, backend: backend)
            r.attach(to: e, mode: .full)
            e.startGame()
            _ = e.takePresentation()
            e.balls[0] = BallState(x: 150, y: 300, vx: 0, vy: 0, accx: 0, accy: 0, layer: 0)
            e.balls[0].active = 1
            var seen: [(Int, Int)] = []
            for f in 1...520 {
                // the scanned ball's position words the handler reads (ds:6CEA/6CEC, set by ball_pixel_scan
                // for the ball on the sensor): below y 250
                r.machine.write(0x6CEA, 2, 150)
                r.machine.write(0x6CEC, 2, 300)
                r.dispatch(value: 0xEA, layer: 0, tilted: false, lockout: 0)
                for s in e.takePresentation().spriteSets { seen.append((f, s.selector)) }
            }
            calls[backend] = seen
            XCTAssertEqual(seen.prefix(3).map(\.0), [10, 497, 507], "\(backend)")
            XCTAssertEqual(seen.prefix(3).map(\.1), [1, 0, 1], "\(backend)")
        }
    }

    /// The same show in a full game against the original (harness): a patch of sensor colour EAh
    /// under a resting ball; the frames in which cs:A42F is called, and its AL, must agree.
    func testRobotShowMatchesOriginalLive() throws {
        if ProcessInfo.processInfo.environment["EP_SKIP_LIVE_DIFF"] != nil { throw XCTSkip("EP_SKIP_LIVE_DIFF is set") }
        let project = DotEffectsTests.project, fm = FileManager.default, root = DataLocator.packageRelativeDefault
        let python = project.appendingPathComponent(".venv/bin/python"), tool = project.appendingPathComponent("tools/emu/dot_effects.py")
        guard fm.isExecutableFile(atPath: python.path), fm.fileExists(atPath: tool.path), RulesDirectTests.exe(8) != nil,
              (try? EngineAssets.makeEngine(dataRoot: root, table: 8, rules: false)) != nil else { throw XCTSkip("needs .venv, tools/emu and EP8") }
        let fill = [140, 295, 40, 30, 0xEA]
        let game: [String: Any] = ["table": 8, "frames": 540, "mode": "full", "on_drain": "continue",
                                   "ball": ["x": 150, "y": 300, "vx": 0, "vy": 0, "layer": 0], "collision_fill": [fill], "sprite_routine": 0xA42F]
        let dir = fm.temporaryDirectory.appendingPathComponent("ep-robot-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let input = dir.appendingPathComponent("g.json"), output = dir.appendingPathComponent("o.json")
        try JSONSerialization.data(withJSONObject: [game]).write(to: input)
        let p = Process()
        p.executableURL = python
        p.currentDirectoryURL = project
        p.arguments = [tool.path, "--games", input.path, "-o", output.path]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let res = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [[String: Any]])?.first)
        let frames = res["frames"] as? [[String: Any]] ?? []
        var want: [[Int]] = []
        for (f, r) in frames.enumerated() { for al in r["sprites"] as? [Int] ?? [] { want.append([f, al]) } }
        XCTAssertEqual(want, [[9, 1], [496, 0]], "the original's show")
        for backend in RulesBackend.allCases {
            let e = try EngineAssets.makeEngine(dataRoot: root, table: 8, rules: false)
            let r = try RulesRuntime.load(dataRoot: root, table: 8, backend: backend)
            r.attach(to: e, mode: .off)
            let sc = try Scenario.parse(JSONSerialization.data(withJSONObject: game))
            sc.apply(to: e)
            for y in fill[1]..<(fill[1] + fill[3]) { for x in fill[0]..<(fill[0] + fill[2]) { e.rulesSetPixel(y * 320 + x, UInt8(fill[4])) } }
            _ = e.takePresentation()
            var got: [[Int]] = []
            for f in 0..<frames.count {
                e.input = sc.input(frame: f)
                e.runFrame()
                for s in e.takePresentation().spriteSets { got.append([f, s.selector]) }
            }
            XCTAssertEqual(got, want, "\(backend)")
        }
    }

    func testComposerBlitsRobot() throws {
        guard let t = RealTable.load(8) else { throw XCTSkip("no EP8 data") }
        let c = t.composer
        let g = try XCTUnwrap(c.spriteSets[0xA42F])
        XCTAssertEqual(g.on.count, 6)
        XCTAssertEqual(g.on.first.map { [$0.x, $0.y, $0.w, $0.h] }, [116, 200, 60, 25])
        let before = c.vram
        c.applySpriteSet(SpriteSetEvent(routine: 0xA42F, selector: 1))
        let changed = (0..<before.count).filter { before[$0] != c.vram[$0] }
        XCTAssertGreaterThan(changed.count, 1000)
        // every changed pixel lies inside the robot's records (x 88..211, y 200..358)
        XCTAssertTrue(changed.allSatisfy { ($0 % 320) >= 88 && ($0 % 320) < 212 && ($0 / 320) >= 200 && ($0 / 320) < 359 })
        c.applySpriteSet(SpriteSetEvent(routine: 0xA42F, selector: 0))
        // the "off" records are the playfield's own pixels: a boot (playfield as loaded) shows the empty centre
        XCTAssertEqual(c.vram, before, "background records = playfield")
        if let dir = ProcessInfo.processInfo.environment["EP_RENDER_SNAPSHOTS"], let device = MTLCreateSystemDefaultDevice() {
            let r = try PinballRenderer(device: device, assets: t.assets)
            r.attach(composer: c)
            // lamps first (they were drawn long before), then the robot as the handler draws it
            var s = t.state(lampsA: false)
            let scene = t.scene(viewTop: 160)
            r.present(s, message: nil, flippers: scene.flippers)
            s.spriteSets = [SpriteSetEvent(routine: 0xA42F, selector: 1)]
            r.present(s, message: nil, flippers: scene.flippers)
            let px = try r.renderOffscreen(scene: scene, width: 640, height: 480)
            try PNGWriter.write(rgba: px, width: 640, height: 480, to: URL(fileURLWithPath: dir).appendingPathComponent("ep8_robot.png"))
        }
    }

    /// A VRAM reset (lamp slots back to "not drawn": a new game, a state load) keeps the robot when the rules
    /// still hold it (`spriteSetsShown`), and a new game (nothing since boot) shows the playfield.
    func testComposerKeepsRobotAcrossReset() throws {
        guard let t = RealTable.load(8) else { throw XCTSkip("no EP8 data") }
        let c = t.composer
        let base = c.vram
        let on = SpriteSetEvent(routine: 0xA42F, selector: 1)
        var lamps = [UInt8](repeating: 0, count: c.graphics.lampCount)
        lamps[0] = 1
        c.applyLampSprites(lamps)
        c.spriteSetsWanted = [on]
        c.applySpriteSet(on)
        let robot = c.vram
        XCTAssertNotEqual(robot, base)
        // a state load: lamp 0 back to "not drawn", the robot still up
        c.applyLampSprites([UInt8](repeating: 0, count: lamps.count))
        c.syncSpriteSets()
        let inRobot = (0..<base.count).filter { ($0 % 320) >= 88 && ($0 % 320) < 212 && ($0 / 320) >= 200 && ($0 / 320) < 359 }
        XCTAssertEqual(inRobot.filter { c.vram[$0] != robot[$0] }.count, 0, "the robot is redrawn after the reset")
        // the same without a reset (a load that only changes the robot's state)
        c.spriteSetsWanted = []
        c.syncSpriteSets()
        XCTAssertEqual(c.vram, base, "nothing since boot: the playfield")
        c.spriteSetsWanted = [on]
        c.syncSpriteSets()
        XCTAssertEqual(inRobot.filter { c.vram[$0] != robot[$0] }.count, 0)
        // a producer that does not track it changes nothing
        c.spriteSetsWanted = nil
        c.syncSpriteSets()
        XCTAssertEqual(inRobot.filter { c.vram[$0] != robot[$0] }.count, 0)
    }

    /// The rules report the robot's state from the calls since boot, keep it in save states and clear it at boot.
    func testRulesTrackRobotState() throws {
        let root = DataLocator.packageRelativeDefault
        guard RulesDirectTests.exe(8) != nil, (try? EngineAssets.makeEngine(dataRoot: root, table: 8, rules: false)) != nil else {
            throw XCTSkip("no EP8 data")
        }
        for backend in RulesBackend.allCases {
            let e = try EngineAssets.makeEngine(dataRoot: root, table: 8, rules: false)
            let r = try RulesRuntime.load(dataRoot: root, table: 8, backend: backend)
            r.attach(to: e, mode: .full)
            e.startGame()
            XCTAssertEqual(e.takePresentation().spriteSetsShown, [], "\(backend): nothing at boot")
            e.balls[0] = BallState(x: 150, y: 300, vx: 0, vy: 0, accx: 0, accy: 0, layer: 0)
            e.balls[0].active = 1
            var saved: RulesRuntime.State?
            for f in 1...12 {
                r.machine.write(0x6CEA, 2, 150)
                r.machine.write(0x6CEC, 2, 300)
                r.dispatch(value: 0xEA, layer: 0, tilted: false, lockout: 0)
                let s = e.takePresentation()
                if f == 9 { XCTAssertEqual(s.spriteSetsShown, [], "\(backend)"); saved = r.saveState() }
                if f >= 10 { XCTAssertEqual(s.spriteSetsShown, [SpriteSetEvent(routine: 0xA42F, selector: 1)], "\(backend) call \(f)") }
            }
            r.restoreState(try XCTUnwrap(saved))
            XCTAssertEqual(e.takePresentation().spriteSetsShown, [], "\(backend): restored")
            r.boot()
            XCTAssertEqual(e.takePresentation().spriteSetsShown, [], "\(backend): boot")
        }
    }
}
