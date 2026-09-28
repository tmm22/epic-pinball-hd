import Foundation
import XCTest
@testable import PinballCore

/// The rules port against the ORIGINAL table code, with the user's own files (skipped without them):
///
/// * `testRulesAndFullModeTracesMatchOriginalLive`: every tools/emu scenario in the harness's `rules`
///   and `full` modes (ball traces, as tools/emu/diff_traces.py compares them).
/// * `testRuleStateMatchesOriginalLive`: scenarios aimed at the EP1 rules (kickouts, multiball,
///   ramps, drop targets, lanes, modes, tilt, end of ball, bonus, player switch, sound sweeps): after
///   every frame the whole data segment (outside display-only buffers) must be identical, and so
///   must every sfx_play call (AX, live rate, pan) and every dmd_message call (string, AX, DI).
///   The harness side is a small Python driver over tools/emu (below); DS offsets for pokes are
///   resolved by name from rules.json.
/// * `testUserTablesRunAFullGame`: EP1, EP2 and EP10 rules load, validate and play 3000 frames
///   without interpreter faults, with a consistent PresentationState.
///
/// Every check runs on both rules backends (rules.json interpreted, and the direct-EXE backend).
final class RulesLiveTests: XCTestCase {
    static let project = DataLocator.packageRelativeDefault.deletingLastPathComponent()
    static let dataRoot = DataLocator.packageRelativeDefault
    static var python: URL { project.appendingPathComponent(".venv/bin/python") }

    func requireTable(_ n: Int) throws {
        let fm = FileManager.default
        for f in ["tables/EP\(n)/engine.json", "tables/EP\(n)/collision_idx.npy", "tables/EP\(n)/rules.json"] {
            guard fm.fileExists(atPath: Self.dataRoot.appendingPathComponent(f).path) else { throw XCTSkip("no extracted \(f)") }
        }
        guard RulesRuntime.locateEXE(dataRoot: Self.dataRoot, table: n) != nil else { throw XCTSkip("no original/EP\(n).EXE") }
    }

    /// An engine for table `n` with `backend`'s rules attached (inactive until a scenario/game).
    func engine(_ n: Int, _ backend: RulesBackend) throws -> ClassicEngine {
        let e = try EngineAssets.makeEngine(dataRoot: Self.dataRoot, table: n, rules: false)
        let r = try RulesRuntime.load(dataRoot: Self.dataRoot, table: n, backend: backend)
        XCTAssertEqual(r.backend, backend)
        r.attach(to: e, mode: .off)
        return e
    }

    func requireHarness() throws {
        if ProcessInfo.processInfo.environment["EP_SKIP_LIVE_DIFF"] != nil { throw XCTSkip("EP_SKIP_LIVE_DIFF is set") }
        guard FileManager.default.isExecutableFile(atPath: Self.python.path),
              FileManager.default.fileExists(atPath: Self.project.appendingPathComponent("tools/emu/run_scenario.py").path) else {
            throw XCTSkip("needs .venv/bin/python (with unicorn) and tools/emu/")
        }
    }

    /// Runs `python` with `args`; returns stderr on failure (skips on missing modules).
    func runPython(_ args: [String]) throws {
        let p = Process()
        p.executableURL = Self.python
        p.currentDirectoryURL = Self.project
        p.arguments = args
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: data, as: UTF8.self)
            if msg.contains("No module named") { throw XCTSkip("harness dependencies missing: \(msg.suffix(200))") }
            throw NSError(domain: "RulesLiveTests", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(msg.suffix(800))])
        }
    }

    // MARK: - ball traces in rules and full mode

    func testRulesAndFullModeTracesMatchOriginalLive() throws {
        try requireTable(1)
        try requireHarness()
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ep-rules-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: tmp) }
        let scnDir = tmp.appendingPathComponent("scenarios"), outDir = tmp.appendingPathComponent("out")
        try fm.createDirectory(at: scnDir, withIntermediateDirectories: true)
        var names: [String] = []
        for url in DifferentialTests.scenarioURLs() {
            guard var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  (root["table"] as? Int ?? 1) == 1 else { continue }
            for mode in ["rules", "full"] {
                root["mode"] = mode
                let name = url.deletingPathExtension().lastPathComponent + "." + mode
                try JSONSerialization.data(withJSONObject: root).write(to: scnDir.appendingPathComponent(name + ".json"))
                names.append(name)
            }
        }
        if names.isEmpty { throw XCTSkip("no scenarios in tools/emu/") }
        try runPython([Self.project.appendingPathComponent("tools/emu/run_scenario.py").path, "--batch", outDir.path, scnDir.path])
        for backend in RulesBackend.allCases {
            let engine = try engine(1, backend)
            var compared = 0
            for name in names {
                guard let ref = try? String(contentsOf: outDir.appendingPathComponent(name + ".jsonl"), encoding: .utf8) else { continue }
                let sc = try Scenario.load(contentsOf: scnDir.appendingPathComponent(name + ".json"))
                let port = DifferentialTests.parseLines(TraceRunner.run(sc, engine: engine))
                if let msg = DifferentialTests.compare(reference: DifferentialTests.parseLines(ref), port: port) { XCTFail("\(backend) \(name): \(msg)") }
                XCTAssertEqual(engine.rules?.machine.faults ?? [], [], "\(backend) \(name)")
                compared += 1
            }
            XCTAssertEqual(compared, names.count, "the harness wrote a trace for every scenario")
            XCTAssertEqual(engine.rules?.warnings ?? [], [], "\(backend)")
        }
    }

    // MARK: - rule state, sounds and messages frame by frame

    /// EP1 display-only / physics-scratch DS ranges not compared: sound-driver pointers and video
    /// mode, key repeat, palettes and the DMD dot and blit buffers (0DC0..5870), the PC-speaker id,
    /// VRAM/segment pointers, the probe hit list and collision temporaries, flipper contact, the
    /// camera row, the composited ball sprite and render_frame's own counters.
    static let ignored: [Range<Int>] = [0x0000..<0x0008, 0x0009..<0x000B, 0x0DC0..<0x5870, 0x5315..<0x5317,
                                        0x6C10..<0x6C1C, 0x6C1E..<0x6C6C, 0x586E..<0x5870, 0x6768..<0x6769,
                                        0x6A38..<0x6A3A, 0x6A5E..<0x6B36, 0x0B38..<0x0B3D, 0x0B3F..<0x0B40]

    /// (name, ball x, y, vx, vy, layer, frames, on_drain, pokes by rules.json variable name, raw pokes, extras)
    struct Case {
        var name: String
        var ball: (Int, Int, Int, Int, Int)
        var frames: Int
        var onDrain = "stop"
        var vars: [String: Int] = [:]
        var pokes: [String: Int] = [:]
        var inputs: [Int] = []
        var players: Int?
    }

    static let cases: [Case] = [
        Case(name: "test_hole", ball: (6, 11, 0, 40, 0), frames: 200),
        Case(name: "test_hole_level", ball: (6, 11, 0, 40, 0), frames: 200, vars: ["phys_level": 3, "test_step": 8]),
        Case(name: "test_hole_double_jackpot", ball: (6, 11, 0, 40, 0), frames: 200, vars: ["mode": 2, "mode_seconds": 20]),
        Case(name: "center_hole", ball: (182, 143, 0, 40, 0), frames: 200),
        Case(name: "center_hole_power10", ball: (182, 143, 0, 40, 0), frames: 200, vars: ["power_level": 10]),
        Case(name: "right_sink_third", ball: (255, 206, 0, 40, 0), frames: 200, vars: ["sink_count_for_gate": 2]),
        Case(name: "right_sink_kicker_lit", ball: (255, 206, 0, 40, 0), frames: 200, vars: ["kicker_lit": 1]),
        Case(name: "right_hole_multiball2", ball: (245, 228, 0, 40, 0), frames: 500, onDrain: "continue", vars: ["phys_level": 3, "phys_armed": 0]),
        Case(name: "right_hole_multiball3", ball: (245, 228, 0, 40, 0), frames: 500, onDrain: "continue", vars: ["phys_level": 7, "phys_armed": 0]),
        Case(name: "right_hole_arm", ball: (245, 228, 0, 40, 0), frames: 200, vars: ["phys_level": 0]),
        Case(name: "left_hole", ball: (5, 246, 0, 40, 0), frames: 200, vars: ["millions_count": 5]),
        Case(name: "kickback_gate", ball: (24, 378, 0, 150, 0), frames: 300, onDrain: "continue"),
        Case(name: "diverter", ball: (76, 263, 0, 120, 0), frames: 120),
        Case(name: "left_ramp_level1", ball: (31, 60, 0, -250, 1), frames: 150, vars: ["android_level": 1, "req_basic_io": 7]),
        Case(name: "left_ramp_level2", ball: (31, 60, 0, -250, 1), frames: 150, vars: ["android_level": 2, "req_ai": 0xF]),
        Case(name: "left_ramp_level5", ball: (31, 60, 0, -250, 1), frames: 150, vars: ["android_level": 5, "req_activate": 1]),
        Case(name: "left_ramp_super_jackpot", ball: (31, 60, 0, -250, 1), frames: 150, vars: ["mode": 3, "mode_seconds": 20]),
        Case(name: "right_ramp_link", ball: (286, 150, 0, -250, 0), frames: 150),
        Case(name: "right_ramp_iq", ball: (286, 150, 0, -250, 0), frames: 150, vars: ["android_level": 2, "iq": 120]),
        Case(name: "right_ramp_virus", ball: (286, 150, 0, -250, 0), frames: 150, vars: ["mode": 4, "mode_seconds": 9]),
        Case(name: "drop_bank", ball: (55, 212, -250, 40, 0), frames: 150, vars: ["phys_armed": 1, "phys_level": 3],
             pokes: ["drop_targets": 1, "drop_targets+2": 1]),
        Case(name: "top_lanes_all", ball: (163, 25, 0, 80, 0), frames: 120, pokes: ["top_lanes+1": 1, "top_lanes+2": 1, "top_lanes+3": 1],
             inputs: []),
        Case(name: "top_lane_skill", ball: (163, 25, 0, 80, 0), frames: 120, vars: ["skill_lane": 0]),
        Case(name: "left_lane_jackpot", ball: (91, 24, 0, 80, 0), frames: 120, vars: ["mode": 1, "mode_seconds": 20]),
        Case(name: "lane_change", ball: (150, 100, 0, 0, 0), frames: 60, inputs: [Int](repeating: 0, count: 10) + [1, 1, 1, 0, 0, 2, 2, 0, 3, 3]),
        Case(name: "mode_expiry", ball: (284, 336, 0, 0, 0), frames: 200, vars: ["mode": 4, "mode_seconds": 2, "mode_frame": 0]),
        Case(name: "tilt_then_drain", ball: (150, 300, 0, 200, 0), frames: 400, onDrain: "continue", pokes: ["tilt_meter": 0x60]),
        Case(name: "drain_bonus", ball: (150, 330, 0, 300, 0), frames: 360, onDrain: "continue",
             vars: ["bonus_tests": 120, "bonus_ramps": 3, "bonus_left_lanes": 9, "bonus_mult": 3, "score_at_ball_start": 1]),
        Case(name: "drain_no_score", ball: (150, 330, 0, 300, 0), frames: 360, onDrain: "continue"),
        Case(name: "two_players", ball: (150, 330, 0, 300, 0), frames: 360, onDrain: "continue", vars: ["score_at_ball_start": 1], players: 2),
        Case(name: "plunge_and_play", ball: (284, 336, 0, 0, 0), frames: 600, onDrain: "continue",
             inputs: [Int](repeating: 4, count: 50) + [Int](repeating: 0, count: 60) + [1, 1, 1, 1, 0, 0, 2, 2, 2, 2] + [Int](repeating: 0, count: 40) + [3, 3, 3, 3, 3]),
        Case(name: "sweep_up", ball: (150, 100, 0, 0, 0), frames: 60,
             pokes: ["sound.sweep@0ade": 1, "sound.rate": 5000, "sound.sweep@0ade.step_id": 0xF, "sound.sweep@0ade.end_id": 7]),
    ]

    static let driver = """
    import json, sys
    import numpy as np
    sys.path.insert(0, 'tools/emu'); sys.path.insert(0, 'tools')
    import ep_emu, run_scenario
    from unicorn import UC_HOOK_CODE
    from unicorn.x86_const import UC_X86_REG_AX, UC_X86_REG_BX, UC_X86_REG_DI
    job = json.load(open(sys.argv[1])); out = {}
    size = job['ds_size']; exe = open(job['exe'], 'rb').read(); ds0 = exe[job['ds_file']:job['ds_file'] + size]
    bases = {}
    for c in job['cases']:
        scn = c['scenario']; mode = scn['mode']; players = scn.get('players', 1)
        if players not in bases:
            if players == 1:
                bases[players] = None
            else:
                e = ep_emu.EpEmu(table=1, players=str(players)); e.reset_play_state()
                for _ in range(run_scenario.WARMUP_STEPS): e.physics_step()
                bases[players] = (e, e.snapshot())
        saved = run_scenario._BASE.get(1)
        if bases[players] is not None: run_scenario._BASE[1] = bases[players]
        emu = run_scenario.setup(scn, mode)
        if bases[players] is not None:
            if saved: run_scenario._BASE[1] = saved
            else: del run_scenario._BASE[1]
        for a, v, w in scn.get('ds_pokes', []):
            emu.uc.mem_write(emu.ds * 16 + a, int(v & ((1 << (8 * w)) - 1)).to_bytes(w, 'little'))
        calls = {'sfx': [], 'msg': []}
        def on_sfx(uc, address, size_, _):
            ax = uc.reg_read(UC_X86_REG_AX); pan = ax >> 12
            if pan == 0: pan = (emu.rw(emu.ds, 0x6a46, signed=False) // 20) & 0xff
            calls['sfx'].append([ax, emu.rw(emu.ds, 0x0adc, signed=False), min(pan, 15)])
        def on_msg(uc, address, size_, _):
            calls['msg'].append([uc.reg_read(UC_X86_REG_BX), uc.reg_read(UC_X86_REG_AX), uc.reg_read(UC_X86_REG_DI)])
        h1 = emu.uc.hook_add(UC_HOOK_CODE, on_sfx, None, emu.lin(emu.cs, 0x014a), emu.lin(emu.cs, 0x014a))
        h2 = emu.uc.hook_add(UC_HOOK_CODE, on_msg, None, emu.lin(emu.cs, 0x15de), emu.lin(emu.cs, 0x15de))
        prev = np.frombuffer(ds0, dtype=np.uint8); frames = []; err = None
        inputs = scn.get('inputs', [])
        for f in range(scn['frames']):
            if scn.get('on_drain', 'stop') == 'stop' and emu.dsw('ball_y') >= 0x18f: break
            emu.set_keys(inputs[f] if f < len(inputs) else 0)
            try:
                if mode == 'full': emu.main_loop_full()
                else: emu.main_loop_physics(mode)
                for s in range(3): emu.physics_step()
            except ep_emu.EmuError as e:
                err = str(e)[:200]; break
            cur = np.frombuffer(bytes(emu.uc.mem_read(emu.ds * 16, size)), dtype=np.uint8)
            idx = np.nonzero(cur != prev)[0]
            ch = [[int(i), int(cur[i])] for i in idx]
            prev = cur
            b = emu.ball(0)
            frames.append(dict(ds=ch, sfx=calls['sfx'], msg=calls['msg'], ball=[b['x'], b['y'], b['vx'], b['vy']]))
            calls = {'sfx': [], 'msg': []}
        emu.uc.hook_del(h1); emu.uc.hook_del(h2)
        out[c['name']] = dict(frames=frames, error=err)
    json.dump(out, open(sys.argv[2], 'w'))
    """

    func testRuleStateMatchesOriginalLive() throws {
        try requireTable(1)
        try requireHarness()
        // variable names (EP1's annotation) resolve through rules.json; both backends are compared
        let named = try EngineAssets.makeEngine(dataRoot: Self.dataRoot, table: 1)
        let rules = try XCTUnwrap(named.rules, named.rulesLoadError ?? "")
        let p = try RulesProgram.load(contentsOf: RulesRuntime.rulesURL(dataRoot: Self.dataRoot, table: 1))
        func addr(_ spec: String) throws -> (Int, Int) {
            var name = spec, off = 0
            if let plus = spec.lastIndex(of: "+"), let o = Int(spec[spec.index(after: plus)...]) { name = String(spec[..<plus]); off = o }
            if let v = p.address(of: name) { return (v.addr + off, v.size) }
            if let a = rules.glue.ds[name] { return (a + off, name == "plunger_charge" ? 2 : 1) }
            throw XCTSkip("rules.json has no variable \(name) (not the annotated EP1 rules?)")
        }
        // scenario documents (port extension keys ds_pokes/players; the driver applies the same pokes)
        var job: [[String: Any]] = []
        var scenarios: [String: Scenario] = [:]
        for c in Self.cases {
            for mode in ["rules", "full"] {
                var pokes: [[Int]] = []
                for (k, v) in c.vars.sorted(by: { $0.key < $1.key }) { let (a, w) = try addr(k); pokes.append([a, v, w]) }
                for (k, v) in c.pokes.sorted(by: { $0.key < $1.key }) { let (a, w) = try addr(k); pokes.append([a, v, w]) }
                var s: [String: Any] = ["table": 1, "frames": c.frames, "mode": mode, "on_drain": c.onDrain, "inputs": c.inputs,
                                        "ball": ["x": c.ball.0, "y": c.ball.1, "vx": c.ball.2, "vy": c.ball.3, "layer": c.ball.4],
                                        "ds_pokes": pokes]
                if let pl = c.players { s["players"] = pl }
                let name = "\(c.name).\(mode)"
                job.append(["name": name, "scenario": s])
                scenarios[name] = try Scenario.parse(JSONSerialization.data(withJSONObject: s))
            }
        }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ep-rulestate-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let exe = try XCTUnwrap(RulesRuntime.locateEXE(dataRoot: Self.dataRoot, table: 1))
        let jobURL = tmp.appendingPathComponent("job.json"), outURL = tmp.appendingPathComponent("out.json")
        let script = tmp.appendingPathComponent("driver.py")
        try Data(Self.driver.utf8).write(to: script)
        try JSONSerialization.data(withJSONObject: ["cases": job, "exe": exe.path, "ds_file": p.dsFileOffset, "ds_size": p.dsSize])
            .write(to: jobURL)
        let t0 = Date()
        try runPython([script.path, jobURL.path, outURL.path])
        print("rule-state harness: \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        let t1 = Date()
        defer { print("rule-state port + compare: \(String(format: "%.1f", Date().timeIntervalSince(t1))) s") }
        let ref = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: outURL)) as? [String: [String: Any]])

        var skip = [Bool](repeating: false, count: p.dsSize)
        for r in Self.ignored { for a in r where a < p.dsSize { skip[a] = true } }
        func ints(_ v: Any?) -> [[Int]] { (v as? [[Any]] ?? []).map { $0.compactMap { ($0 as? NSNumber)?.intValue } } }
        for backend in RulesBackend.allCases {
        let engine = try engine(1, backend)
        let rules = try XCTUnwrap(engine.rules)
        XCTAssertEqual(rules.program.dsSize, p.dsSize)
        var totalFrames = 0
        for entry in job {
            let name = entry["name"] as! String
            let sc = scenarios[name]!
            let port = DifferentialTests.parseLines(TraceRunner.run(sc, engine: engine, state: true))
                .filter { (($0["extra"] as? [String: Any])?["ds"]) != nil }
            let orig = try XCTUnwrap(ref[name]?["frames"] as? [[String: Any]], name)
            let err = ref[name]?["error"] as? String
            XCTAssertEqual(rules.machine.faults, [], name)
            if err == nil { XCTAssertEqual(orig.count, port.count, "\(name): frame count") }
            var a = rules.machine.initialDS, b = rules.machine.initialDS
            for f in 0..<min(orig.count, port.count) {
                let ex = port[f]["extra"] as! [String: Any]
                for pair in ints(orig[f]["ds"]) where !skip[pair[0]] { a[pair[0]] = UInt8(pair[1]) }
                for pair in ints(ex["ds"]) where !skip[pair[0]] { b[pair[0]] = UInt8(pair[1]) }
                let diffs = a == b ? [] : (0..<p.dsSize).filter { a[$0] != b[$0] }
                if !diffs.isEmpty {
                    XCTFail("\(backend) \(name) frame \(f): DS differs at " + diffs.prefix(6).map { String(format: "ds:%04X orig %d port %d", $0, a[$0], b[$0]) }.joined(separator: ", "))
                    break
                }
                if ints(orig[f]["sfx"]) != ints(ex["sfx"]) || ints(orig[f]["msg"]) != ints(ex["msg"]) {
                    XCTFail("\(backend) \(name) frame \(f): calls differ: original sfx \(ints(orig[f]["sfx"])) msg \(ints(orig[f]["msg"])), port sfx \(ints(ex["sfx"])) msg \(ints(ex["msg"]))")
                    break
                }
                totalFrames += 1
            }
        }
        XCTAssertGreaterThan(totalFrames, 5000, "\(backend)")
        XCTAssertEqual(rules.warnings, [], "\(backend)")
        print("rule state vs original, \(backend) backend: \(totalFrames) frames identical")
        }
    }

    // MARK: - glue discovery

    /// The structural search for the sound code (used for tables without annotated glue) finds
    /// exactly the hand-annotated EP1 ranges, and finds one in EP2 and EP10.
    func testSoundGlueDiscoveryReproducesEP1Annotation() throws {
        var found = 0
        for n in [1, 2, 10] {
            do { try requireTable(n) } catch { continue }
            let r = try RulesRuntime.load(dataRoot: Self.dataRoot, table: n)
            var g = TableGlue()
            TableGlue.discoverSound(program: r.program, machine: r.machine, into: &g)
            XCTAssertNotNil(g.range("sound"), "EP\(n)")
            XCTAssertNotNil(g.range("flipperLeft"), "EP\(n)")
            XCTAssertNotNil(g.range("flipperRight"), "EP\(n)")
            XCTAssertNotNil(g.ds["snd_present"], "EP\(n)")
            if n == 1 {
                XCTAssertEqual(g.range("sound"), r.glue.range("sound"))
                XCTAssertEqual(g.range("flipperLeft"), r.glue.range("flipperLeft"))
                XCTAssertEqual(g.range("flipperRight"), r.glue.range("flipperRight"))
                XCTAssertEqual(g.routines["sfx_play"], r.glue.routines["sfx_play"])
                XCTAssertEqual(g.ds["snd_present"], r.glue.ds["snd_present"])
            } else {
                XCTAssertEqual(r.glue.range("sound"), g.range("sound"), "EP\(n) uses the discovered range")
            }
            found += 1
        }
        if found == 0 { throw XCTSkip("no user tables with rules.json") }
    }

    // MARK: - EP1, EP2, EP10 play

    func testUserTablesRunAFullGame() throws {
        var ran = 0
        for n in [1, 2, 10] {
            do { try requireTable(n) } catch { continue }
            for backend in RulesBackend.allCases {
            let engine = try engine(n, backend)
            let r = try XCTUnwrap(engine.rules, "EP\(n): \(engine.rulesLoadError ?? "")")
            if n == 1 {
                XCTAssertEqual(r.glue.ranges.count, 18, "EP1 glue ranges all decode: \(r.glue.warnings)")
                XCTAssertEqual(r.glue.warnings, [])
                XCTAssertFalse(r.glue.lampOrder.isEmpty)
                XCTAssertFalse(r.glue.messageEffects.isEmpty)
            }
            engine.startGame()
            XCTAssertEqual(engine.rulesMode, .full)
            let exeSize = (try? FileManager.default.attributesOfItem(atPath: RulesRuntime.locateEXE(dataRoot: Self.dataRoot, table: n)!.path)[.size] as? Int) ?? 0
            var sounds = 0, messages = 0
            var script: [FrameInput] = Array(repeating: .plunger, count: 60)
            while script.count < 3000 { script += Array(repeating: [], count: 25) + Array(repeating: [.leftFlipper, .rightFlipper], count: 8) }
            for input in script {
                engine.input = input
                engine.runFrame()
                let s = engine.takePresentation()
                XCTAssertEqual(s.lamps.count, r.program.lampCount)
                XCTAssertEqual(s.lampStates.count, r.program.lampCount)
                XCTAssertEqual(s.scores.count, s.playerCount)
                for e in s.soundEvents {
                    XCTAssert((0...15).contains(e.pan) && e.rateHz > 0 && e.sweepFrames == 0, "EP\(n) \(e)")
                }
                if let m = s.message {
                    XCTAssertEqual(m.exeOffset - r.program.dsFileOffset, m.dsOffset)
                    XCTAssert(m.exeOffset > 0 && m.exeOffset < exeSize)
                    messages += 1
                }
                sounds += s.soundEvents.count
                if s.gameOver { break }
            }
            if !r.warnings.isEmpty { print("EP\(n) rules warnings: \(r.warnings)") }
            XCTAssertEqual(r.machine.faults, [], "EP\(n)")
            XCTAssertEqual(r.warnings.filter { $0.hasPrefix("glue") || $0.hasPrefix("routine") }, [], "EP\(n)")
            XCTAssertGreaterThan(sounds, 0, "EP\(n) made sounds (flipper sounds at least)")
            if n != 2 { XCTAssertGreaterThan(messages, 0, "EP\(n) showed messages") }
            ran += 1
            }
        }
        if ran == 0 { throw XCTSkip("no user tables with rules.json") }
    }
}
