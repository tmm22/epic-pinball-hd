import Foundation
import XCTest
@testable import PinballCore
@testable import PinballRender

/// Message effects (`DotEffects`, render_frame run from the EXE) against the ORIGINAL code in the
/// harness (tools/emu/dot_effects.py): the dot list dmd_message writes and, after every render_frame
/// call, the dots the plot loop draws, their EP9-13 colour bytes, DAC 255 and the frame the message
/// ends. Needs the user's EXEs, the extracted data and .venv (skipped without them).
final class DotEffectsTests: XCTestCase {
    static let project = DataLocator.packageRelativeDefault.deletingLastPathComponent()

    /// Every table's layout is found and its effect blocks decode for MiniX86.
    func testLayoutAllTables() throws {
        var found = 0
        for n in 1...13 {
            guard let exe = RulesDirectTests.exe(n) else { continue }
            guard let fx = DotEffects(exe: exe, table: n) else { XCTFail("EP\(n): no DotEffects layout"); continue }
            let l = fx.layout
            XCTAssertEqual(l.colourVar != nil, n >= 9, "EP\(n) colour array")
            XCTAssertEqual(l.plotLimit != nil, n >= 9, "EP\(n) plot limit")
            XCTAssertGreaterThan(l.effectsEnd, l.renderFrame)
            found += 1
        }
        if found == 0 { throw XCTSkip("no original EXEs") }
        // EP1 addresses from the disassembly (cs:3E35..4373, ds:0B3A/0B3B/0B3D/10C2/4586).
        if let exe = RulesDirectTests.exe(1), let l = DotEffects(exe: exe, table: 1)?.layout {
            XCTAssertEqual([l.dmdMessage, l.renderFrame, l.effectsEnd, l.effect, l.step, l.counter, l.list, l.delay, l.delayWords],
                           [0x15DE, 0x3E35, 0x4373, 0x0B3A, 0x0B3B, 0x0B3D, 0x10C2, 0x4586, 0x546])
            XCTAssertEqual(l.startDAC, [63, 63, 63])
        }
        if let exe = RulesDirectTests.exe(10), let l = DotEffects(exe: exe, table: 10)?.layout {
            XCTAssertEqual([l.renderFrame, l.effectsEnd, l.list, l.colourVar ?? -1, l.colourOffset, l.plotLimit ?? -1],
                           [0x38E2, 0x3ED7, 0x0F48, 0x00C5, 0x960, 0x2580])
            XCTAssertEqual(l.startDAC, [63, 0, 0])
        }
    }

    /// Synthetic: a dead dot (word 1) is not plotted and the first word is tested like the others.
    func testPlottedSkipsDeadDots() throws {
        guard let exe = RulesDirectTests.exe(1), let fx = DotEffects(exe: exe, table: 1) else { throw XCTSkip("no EP1.EXE") }
        fx.start(dots: [1, 700, 1, 900], effect: 0)
        XCTAssertEqual(fx.plotted().dots, [700, 900])
        XCTAssertTrue(fx.step())
        XCTAssertEqual(fx.counter, 1, "effect 0 has no block: the counter stays")
        fx.append(dots: [1234])
        XCTAssertEqual(fx.plotted().dots, [700, 900, 1234])
        fx.stop()
        XCTAssertEqual(fx.plotted().dots, [])
    }

    /// End to end on EP1 in full mode: the rules' PresentationState (serial, renderFrames, texts)
    /// replayed by `MessageAnimator.follow` gives, after every frame, exactly the dots the original's
    /// render_frame plotted in that frame (both rules backends).
    func testGameMessagesMatchOriginalLive() throws {
        if ProcessInfo.processInfo.environment["EP_SKIP_LIVE_DIFF"] != nil { throw XCTSkip("EP_SKIP_LIVE_DIFF is set") }
        let fm = FileManager.default
        let python = Self.project.appendingPathComponent(".venv/bin/python")
        let tool = Self.project.appendingPathComponent("tools/emu/dot_effects.py")
        guard fm.isExecutableFile(atPath: python.path), fm.fileExists(atPath: tool.path), let t = RealTable.load(1),
              let exe = t.composer.exe else { throw XCTSkip("needs .venv, tools/emu/dot_effects.py, EP1 data and EXE") }
        // RulesLiveTests' EP1 starts (holes, ramps, modes, multiball, tilt, drains with bonus, a plunge), rule
        // variables poked by their rules.json names; one player.
        let prog = try RulesProgram.load(contentsOf: RulesRuntime.rulesURL(dataRoot: DataLocator.packageRelativeDefault, table: 1))
        let glue = try XCTUnwrap(EngineAssets.makeEngine(dataRoot: DataLocator.packageRelativeDefault, table: 1).rules).glue
        func addr(_ spec: String) -> (Int, Int)? {
            var name = spec, off = 0
            if let plus = spec.lastIndex(of: "+"), let o = Int(spec[spec.index(after: plus)...]) { name = String(spec[..<plus]); off = o }
            if let v = prog.address(of: name) { return (v.addr + off, v.size) }
            if let a = glue.ds[name] { return (a + off, name == "plunger_charge" ? 2 : 1) }
            return nil
        }
        var games: [[String: Any]] = []
        for c in RulesLiveTests.cases where c.players == nil {
            var pokes: [[Int]] = []
            for (k, v) in (c.vars.merging(c.pokes) { a, _ in a }).sorted(by: { $0.key < $1.key }) {
                guard let (a, w) = addr(k) else { continue }
                pokes.append([a, v, w])
            }
            games.append(["table": 1, "frames": c.frames, "mode": "full", "on_drain": c.onDrain, "inputs": c.inputs,
                          "ball": ["x": c.ball.0, "y": c.ball.1, "vx": c.ball.2, "vy": c.ball.3, "layer": c.ball.4], "ds_pokes": pokes])
        }
        let dir = fm.temporaryDirectory.appendingPathComponent("ep-dotgame-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let input = dir.appendingPathComponent("games.json"), output = dir.appendingPathComponent("out.json")
        try JSONSerialization.data(withJSONObject: games).write(to: input)
        let p = Process()
        p.executableURL = python
        p.currentDirectoryURL = Self.project
        p.arguments = [tool.path, "--games", input.path, "-o", output.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self)
            if msg.contains("No module named") { throw XCTSkip("harness dependencies missing") }
            XCTFail("harness failed: \(msg.suffix(600))"); return
        }
        let results = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [[String: Any]])
        let g = t.composer.graphics, spec = t.composer.spec
        for backend in RulesBackend.allCases {
            let e = try EngineAssets.makeEngine(dataRoot: DataLocator.packageRelativeDefault, table: 1, rules: false)
            let r = try RulesRuntime.load(dataRoot: DataLocator.packageRelativeDefault, table: 1, backend: backend)
            r.attach(to: e, mode: .off)
            var compared = 0, plotted = 0
            for (doc, res) in zip(games, results) {
                let sc = try Scenario.parse(JSONSerialization.data(withJSONObject: doc))
                let a = try XCTUnwrap(MessageAnimator(exe: exe, graphics: g, spec: spec))
                sc.apply(to: e)
                _ = e.takePresentation()   // the boot's queues
                let frames = res["frames"] as? [[String: Any]] ?? []
                let drainY = Int16(truncatingIfNeeded: e.data.drainY)
                for (f, want) in frames.enumerated() {
                    if sc.onDrain == "stop" && e.balls[0].y >= drainY { break }
                    e.input = sc.input(frame: f)
                    e.runFrame()
                    let st = e.takePresentation()
                    let m = st.message.map { ref in
                        DotMessage(text: ref.bytes, ax: Int(ref.modeWord), di: ref.position, colour: ref.colour >= 0 ? UInt8(ref.colour) : nil)
                    }
                    a.follow(st.message, message: m, texts: st.texts) { tr in
                        spec.textRoutines[tr.routine].map { DotLine(text: tr.bytes, font8: $0, di: tr.position) }
                    }
                    let wantDots = want["dots"] as? [Int]
                    if a.shown?.dots != wantDots {
                        XCTFail("\(backend) case \(compared) frame \(f): port \(a.shown.map { "\($0.dots.count) dots" } ?? "nothing"), "
                                + "original \(wantDots.map { "\($0.count) dots" } ?? "nothing") (counter \(want["counter"] ?? ""))")
                        break
                    }
                    if wantDots != nil, let dac = want["dac255"] as? [Int] {
                        XCTAssertEqual(a.effects.dac255.map(Int.init), dac, "\(backend) frame \(f): DAC 255")
                        plotted += 1
                    }
                }
                compared += 1
            }
            XCTAssertGreaterThan(plotted, 0, "\(backend)")
            print("DotEffectsTests: EP1 games, \(backend): \(compared) scenarios, \(plotted) frames with dots identical")
        }
    }

    /// Every table with its real rules and the auto-player, messages followed by `MessageAnimator`
    /// the way the front end does it. Before 2026-10-01 EP2-13's rules did not run render_frame's
    /// counter, so they kept reporting a message after its effect had ended (with `renderFrames` still
    /// growing): `follow` must stop stepping there instead of looping (it used to spin forever on
    /// EP2/4/6/7/8/12). The rules now keep the counter, so that case is rare (it needs an effect whose
    /// end depends on the dot list); it is counted, not required.
    func testFollowRulesMessagesAllTables() throws {
        var played = 0, endedWhileReported = 0
        for n in 1...13 {
            guard let t = RealTable.load(n), let exe = t.composer.exe,
                  let e = try? EngineAssets.makeEngine(dataRoot: DataLocator.packageRelativeDefault, table: n), e.rules != nil,
                  let a = MessageAnimator(exe: exe, graphics: t.composer.graphics, spec: t.composer.spec) else { continue }
            let spec = t.composer.spec
            let sim = GameSimulation(engine: e)
            var player = AutoPlayer(engine: e)
            var messages = 0, ended = 0
            let start = Date()
            for _ in 0..<2500 {
                sim.input = player.input(for: e)
                sim.stepFrame()
                let st = sim.takePresentation()
                let m = st.message.map { ref in
                    DotMessage(text: ref.bytes, ax: Int(ref.modeWord), di: ref.position, colour: ref.colour >= 0 ? UInt8(ref.colour) : nil)
                }
                a.follow(st.message, message: m, texts: st.texts) { tr in
                    spec.textRoutines[tr.routine].map { DotLine(text: tr.bytes, font8: $0, di: tr.position) }
                }
                if let ref = st.message, ref.serial >= 0 {
                    messages += 1
                    if a.active { XCTAssertEqual(a.steps, ref.renderFrames, "EP\(n): one render_frame per tick while alive") }
                    if !a.active && a.steps < ref.renderFrames { ended += 1; XCTAssertNil(a.shown, "EP\(n): nothing shown after the end") }
                }
                if st.gameOver { break }
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 120, "EP\(n): follow took too long")
            if ended > 0 { endedWhileReported += 1 }
            print("DotEffectsTests: EP\(n) autoplay, \(messages) frames with a rules message, \(ended) after its effect ended")
            played += 1
        }
        if played == 0 { throw XCTSkip("needs the extracted data and the original EXEs") }
        print("DotEffectsTests: \(endedWhileReported) tables reported a message after its effect ended")
    }

    struct Case { var table: Int; var string: Int; var ax: Int; var di: Int; var frames: Int; var colour: Int?
        var lines: [(frame: Int, routine: Int, string: Int, di: Int, colour: Int?)] = [] }

    /// A printable message of 8-18 characters from the table's rules.json.
    static func message(_ n: Int, skip: Int = 0) -> Int? {
        let url = DataLocator.packageRelativeDefault.appendingPathComponent("tables/EP\(n)/rules.json")
        guard let d = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let list = root["messages"] as? [[String: Any]] else { return nil }
        let offs = list.compactMap { m -> Int? in
            guard (m["printable"] as? Bool) != false, let s = m["file_offset"] as? String, let len = m["length"] as? Int,
                  (8...18).contains(len) else { return nil }
            return Int(s.dropFirst(2), radix: 16)
        }
        return offs.count > skip ? offs[skip] : offs.first
    }

    static func cases() -> [Case] {
        var out: [Case] = []
        for n in 1...13 {
            guard let s = message(n) else { continue }
            let strip = n >= 9
            let di = strip ? 3 * 320 : 0x12C0
            // Every effect on EP1 and EP10; the shorter ones elsewhere. Effects without an end
            // (0, 3, 7, 12) run 150 frames.
            let effects = n == 1 || n == 10 ? Array(0...12) : [1, 3, 5, 8, 10] + (strip ? [7, 12] : [])
            for al in effects {
                let endless = [0, 3, 7, 12].contains(al)
                out.append(Case(table: n, string: s, ax: 0x100 | al, di: di, frames: endless ? 150 : 820, colour: strip ? 0x4B : nil))
            }
            out.append(Case(table: n, string: message(n, skip: 1) ?? s, ax: 0x002, di: di + 640, frames: 300, colour: strip ? 0xF2 : nil))
        }
        return out
    }

    /// EP2-EP13: the sounds render_frame's effect blocks play (`DotEffects.sounds`, compared with the original in
    /// `testMatchesOriginalCodeLive`) reach `PresentationState.soundEvents` through sfx_play, the path EP1's glue
    /// uses: an effect-1 message plays the sound of `mov ax,imm; call far sfx_play` (EP2 cs:3F10, 700Dh) once.
    func testRulesPlayEffectSoundsAllTables() throws {
        var checked = 0
        for n in 2...13 {
            guard let exe = RulesDirectTests.exe(n), let image = try? ExeImage(exe: exe), let l = DotEffects.find(code: image.code),
                  let e = try? EngineAssets.makeEngine(dataRoot: DataLocator.packageRelativeDefault, table: n, rules: false) else { continue }
            let c = image.code
            // effect 1's sound: the first `mov ax,imm16; call far` after render_frame
            // (EP5's effect blocks play no sound: none expected there)
            let site = (l.renderFrame..<l.effectsEnd).first(where: { c[$0] == 0xB8 && c[$0 + 3] == 0x9A })
            let want = site.map { [Int(c[$0 + 1])] } ?? []
            if n != 5 { XCTAssertNotNil(site, "EP\(n): effect sound") }
            for backend in RulesBackend.allCases {
                let r = try RulesRuntime.load(dataRoot: DataLocator.packageRelativeDefault, table: n, backend: backend)
                r.attach(to: e, mode: .full)
                r.boot()
                _ = e.takePresentation()
                let zero = try XCTUnwrap((0..<r.machine.initialDS.count).first { r.machine.initialDS[$0] == 0 })
                r.showMessage(ds: zero, ax: 0x0001, di: 0)
                var events: [(Int, Int)] = []
                for f in 0..<400 {
                    r.renderFrame()
                    for s in e.takePresentation().soundEvents { events.append((f, s.sample)) }
                }
                XCTAssertEqual(events.map(\.1), want, "EP\(n) \(backend): effect-1 sound")
                if n == 2 { XCTAssertEqual(want, [0x0D]) }
                if let f = events.first?.0 { print("effect sound EP\(n) \(backend): sample \(String(format: "%02X", events[0].1)) at render_frame \(f + 1)") }
                checked += 1
            }
        }
        if checked == 0 { throw XCTSkip("no tables") }
    }

    func testMatchesOriginalCodeLive() throws {
        if ProcessInfo.processInfo.environment["EP_SKIP_LIVE_DIFF"] != nil { throw XCTSkip("EP_SKIP_LIVE_DIFF is set") }
        let fm = FileManager.default
        let python = Self.project.appendingPathComponent(".venv/bin/python")
        let tool = Self.project.appendingPathComponent("tools/emu/dot_effects.py")
        guard fm.isExecutableFile(atPath: python.path), fm.fileExists(atPath: tool.path), RulesDirectTests.exe(1) != nil else {
            throw XCTSkip("needs .venv/bin/python (with unicorn), tools/emu/dot_effects.py and the original EXEs")
        }
        var cases = Self.cases()
        // draw_text lines appended to a running effect (EP1 draw_text cs:59AC; EP10 cs:4C65 with a colour).
        if let s = Self.message(1, skip: 2) { cases.append(Case(table: 1, string: Self.message(1)!, ax: 0x105, di: 0x12C0, frames: 420, colour: nil,
                                                                lines: [(0, 0x59AC, s, 0x2000, nil), (40, 0x5926, s, 0x3200, nil)])) }
        if let s = Self.message(10, skip: 2) { cases.append(Case(table: 10, string: Self.message(10)!, ax: 0x10C, di: 960, frames: 200, colour: 0x40,
                                                                 lines: [(3, 0x4C65, s, 18 * 320, 0x10)])) }
        guard !cases.isEmpty else { throw XCTSkip("no rules.json messages") }
        let json: [[String: Any]] = cases.map { c in
            var d: [String: Any] = ["table": c.table, "string": c.string, "ax": c.ax, "di": c.di, "frames": c.frames]
            if let col = c.colour { d["colour"] = col }
            d["lines"] = c.lines.map { l -> [String: Any] in
                var e: [String: Any] = ["frame": l.frame, "routine": l.routine, "string": l.string, "di": l.di]
                if let col = l.colour { e["colour"] = col }
                return e
            }
            return d
        }
        let dir = fm.temporaryDirectory.appendingPathComponent("ep-dotfx-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let input = dir.appendingPathComponent("cases.json"), output = dir.appendingPathComponent("out.json")
        try JSONSerialization.data(withJSONObject: json).write(to: input)
        let p = Process()
        p.executableURL = python
        p.currentDirectoryURL = Self.project
        p.arguments = [tool.path, "--batch", input.path, "-o", output.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self)
            if msg.contains("No module named") { throw XCTSkip("harness dependencies missing") }
            XCTFail("harness failed: \(msg.suffix(600))"); return
        }
        let results = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [[String: Any]])
        XCTAssertEqual(results.count, cases.count)
        var tables: [Int: RealTable] = [:]
        var frames = 0, sounds = 0
        for (c, r) in zip(cases, results) {
            guard let t = tables[c.table] ?? RealTable.load(c.table), let exe = t.composer.exe else { continue }
            tables[c.table] = t
            let a = try XCTUnwrap(MessageAnimator(exe: exe, graphics: t.composer.graphics, spec: t.composer.spec))
            let label = "EP\(c.table) ax=\(String(format: "%03X", c.ax))"
            // The live DS string the original used (boot patches some, e.g. EP5's).
            let text = (r["text"] as? [Int]).map { $0.map { UInt8($0) } } ?? exe.cString(at: c.string, max: 64)
            let m = DotMessage(text: text, ax: c.ax, di: c.di, colour: c.colour.map { UInt8($0) })
            XCTAssertTrue(a.start(m), label)
            // The list dmd_message writes (DotText) is the original's.
            XCTAssertEqual(DotText.dots(m, font8: t.composer.graphics.font8, font5: t.composer.graphics.font5,
                                        font5b: t.composer.graphics.font5b), r["list"] as? [Int], "\(label): dot list")
            func lines(_ f: Int) {
                for l in c.lines where l.frame == f {
                    let f8 = t.composer.spec.textRoutines[l.routine] ?? false
                    a.append(DotLine(text: exe.cString(at: l.string, max: 64), font8: f8, di: l.di, colour: UInt8(l.colour ?? 255)))
                }
            }
            lines(0)
            let recs = r["frames"] as? [[String: Any]] ?? []
            for (i, f) in recs.enumerated() {
                let alive = a.step()
                frames += 1
                let ended = f["ended"] as? Bool ?? false
                XCTAssertEqual(!alive, ended, "\(label) frame \(i): end")
                // the effect's sounds (`call far sfx_play`, EP1 cs:3E6B): the rules play these on EP2-EP13
                if let ws = f["sfx"] as? [Int] {
                    XCTAssertEqual(a.effects.sounds, ws, "\(label) frame \(i): sounds")
                    sounds += ws.count
                }
                if ended || !alive { break }
                let got = a.frame()
                let want = f["dots"] as? [Int] ?? []
                if got.dots != want {
                    XCTFail("\(label) frame \(i): \(got.dots.count) dots, original \(want.count); first difference at "
                            + "\(zip(got.dots, want).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(got.dots.count, want.count))")
                    break
                }
                if let wc = f["colours"] as? [Int] { XCTAssertEqual(got.colours.map(Int.init), wc, "\(label) frame \(i): colours") }
                if let d = f["dac"] as? [String: [Int]], let v = d["255"] {
                    XCTAssertEqual(a.effects.dac255.map(Int.init), v, "\(label) frame \(i): DAC 255")
                }
                lines(i + 1)
            }
        }
        XCTAssertGreaterThan(frames, 0)
        print("DotEffectsTests: \(cases.count) cases, \(frames) frames compared, \(sounds) effect sounds")
    }
}
