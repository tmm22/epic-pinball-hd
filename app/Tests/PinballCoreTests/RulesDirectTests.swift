import Foundation
import XCTest
@testable import PinballCore

/// The direct-EXE rules backend (docs/enhanced/rules-direct.md), with the user's own files
/// (skipped without them):
///
/// * `testDiscoveryMatchesLiftedProgram`: the Swift discovery finds, in each EXE, exactly what
///   tools/rules.py wrote to rules.json: engine roles, lamps, player block, jump table, dispatcher,
///   every hook (entry, stops, kind, when, continues) and the display stub routines.
final class RulesDirectTests: XCTestCase {
    static let project = DataLocator.packageRelativeDefault.deletingLastPathComponent()
    static let dataRoot = DataLocator.packageRelativeDefault

    static func exe(_ n: Int) -> [UInt8]? {
        guard let u = RulesRuntime.locateEXE(dataRoot: dataRoot, table: n) else { return nil }
        return (try? Data(contentsOf: u)).map { [UInt8]($0) }
    }

    static func lifted(_ n: Int) -> RulesProgram? {
        try? RulesProgram.load(contentsOf: RulesRuntime.rulesURL(dataRoot: dataRoot, table: n))
    }

    /// Differences between the discovered program and rules.json (empty = identical).
    static func compare(_ p: RulesProgram, _ q: RulesProgram) -> [String] {
        var out: [String] = []
        func eq<T: Equatable>(_ what: String, _ a: T, _ b: T) { if a != b { out.append("\(what): direct \(a) lifted \(b)") } }
        eq("code segment", p.codeSegment, q.codeSegment)
        eq("data segment", p.dataSegment, q.dataSegment)
        eq("ds file offset", p.dsFileOffset, q.dsFileOffset)
        eq("ds size", p.dsSize, q.dsSize)
        eq("dispatcher", p.dispatcherIP, q.dispatcherIP)
        eq("sensor table", p.sensorTable, q.sensorTable)
        eq("player block", p.playerBlock, q.playerBlock)
        eq("lamp first", p.lampFirst, q.lampFirst)
        eq("lamp count", p.lampCount, q.lampCount)
        eq("lamp phase", p.lampPhase, q.lampPhase)
        for k in Set(p.engineVars.keys).union(q.engineVars.keys).sorted() {
            let a = p.engineVars[k].map { "\(hex4($0.addr))/\($0.size)" } ?? "-"
            let b = q.engineVars[k].map { "\(hex4($0.addr))/\($0.size)" } ?? "-"
            eq("engine var \(k)", a, b)
        }
        for k in Set(p.hooks.keys).union(q.hooks.keys).sorted() {
            guard let a = p.hooks[k], let b = q.hooks[k] else {
                out.append("hook \(k): direct \(p.hooks[k].map { hex4($0.entryIP) } ?? "-") lifted \(q.hooks[k].map { hex4($0.entryIP) } ?? "-")")
                continue
            }
            eq("hook \(k) entry", a.entryIP, b.entryIP)
            eq("hook \(k) stops", a.stops, b.stops)
            eq("hook \(k) kind", a.kind, b.kind)
            eq("hook \(k) when", a.when, b.when)
            eq("hook \(k) continues", a.continues, b.continues)
        }
        for k in Set(p.stubs.keys).union(q.stubs.keys).sorted() {
            eq("stub \(hex4(k))", p.stubs[k].map { "\($0.kind)/\($0.far)" } ?? "-", q.stubs[k].map { "\($0.kind)/\($0.far)" } ?? "-")
        }
        return out
    }

    // MARK: - lifted vs direct on long games

    /// An engine for table `n` with the rules of `backend` attached (nil without the user's files).
    static func engine(_ n: Int, _ backend: RulesBackend) throws -> ClassicEngine? {
        let fm = FileManager.default
        for f in ["tables/EP\(n)/engine.json", "tables/EP\(n)/collision_idx.npy"] where !fm.fileExists(atPath: dataRoot.appendingPathComponent(f).path) {
            return nil
        }
        if backend == .lifted, !fm.fileExists(atPath: RulesRuntime.rulesURL(dataRoot: dataRoot, table: n).path) { return nil }
        guard RulesRuntime.locateEXE(dataRoot: dataRoot, table: n) != nil else { return nil }
        let e = try EngineAssets.makeEngine(dataRoot: dataRoot, table: n, rules: false)
        let r = try RulesRuntime.load(dataRoot: dataRoot, table: n, backend: backend)
        XCTAssertEqual(r.backend, backend)
        r.attach(to: e, mode: .off)
        return e
    }

    /// A deterministic "player": AutoPlayer plus random flips and rare nudges (tilts), from a seed.
    struct RandomPlayer {
        var auto: AutoPlayer
        var state: UInt64
        init(engine: ClassicEngine, seed: UInt64) { auto = AutoPlayer(engine: engine); state = seed | 1 }
        mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
        mutating func input(for e: ClassicEngine) -> FrameInput {
            var i = auto.input(for: e)
            let r = next() % 1000
            if r < 40 { i.insert(.leftFlipper) } else if r < 80 { i.insert(.rightFlipper) } else if r < 84 { i.insert(.nudgeA) }
            else if r < 88 { i.insert(.nudgeB) }
            return i
        }
    }

    /// Plays both backends side by side from the same new game with the same inputs and compares,
    /// after every frame: the whole data segment, the collision buffer, every ball slot and flipper,
    /// and the PresentationState (lamps, scores, message, texts, sounds, palette, game over).
    /// Returns (frames compared, games started, sounds, messages) or the first difference.
    static func playBoth(table n: Int, frames: Int, seed: UInt64, players: Int) throws -> (Int, Int, Int, Int, String?)? {
        guard let a = try engine(n, .lifted), let b = try engine(n, .direct) else { return nil }
        var opts = RulesOptions(); opts.players = players
        a.startGame(options: opts); b.startGame(options: opts)
        var pa = RandomPlayer(engine: a, seed: seed)
        var games = 1, sounds = 0, messages = 0
        for f in 0..<frames {
            let input = pa.input(for: a)
            a.input = input; b.input = input
            a.runFrame(); b.runFrame()
            let sa = a.takePresentation(), sb = b.takePresentation()
            func fail(_ what: String) -> (Int, Int, Int, Int, String?) { (f, games, sounds, messages, "EP\(n) frame \(f): \(what)") }
            let da = a.rules!.machine.snapshot(), db = b.rules!.machine.snapshot()
            if da != db {
                let d = (0..<da.count).filter { da[$0] != db[$0] }.prefix(8).map { String(format: "ds:%04X lifted %d direct %d", $0, da[$0], db[$0]) }
                return fail("data segment differs: \(d.joined(separator: ", "))")
            }
            if a.buffer != b.buffer { return fail("collision buffer differs") }
            if a.balls != b.balls { return fail("balls differ: \(a.balls) / \(b.balls)") }
            if a.groups.map(\.angle) != b.groups.map(\.angle) { return fail("flipper angles differ") }
            if sa.soundEvents != sb.soundEvents { return fail("sounds differ: \(sa.soundEvents) / \(sb.soundEvents)") }
            if sa.message != sb.message { return fail("message differs: \(String(describing: sa.message)) / \(String(describing: sb.message))") }
            if sa.texts != sb.texts { return fail("texts differ") }
            if sa.lamps != sb.lamps || sa.lampStates != sb.lampStates || sa.lampSprites != sb.lampSprites { return fail("lamps differ") }
            if sa.scores != sb.scores || sa.currentPlayer != sb.currentPlayer || sa.ballNumber != sb.ballNumber || sa.tilted != sb.tilted {
                return fail("score/player/ball differ: \(sa.scores) \(sa.currentPlayer) \(sa.ballNumber) / \(sb.scores) \(sb.currentPlayer) \(sb.ballNumber)")
            }
            if sa.paletteOverrides != sb.paletteOverrides || sa.gameOver != sb.gameOver { return fail("palette/game over differ") }
            sounds += sa.soundEvents.count
            if sa.message != nil { messages += 1 }
            if sa.gameOver {
                games += 1
                a.startGame(options: opts); b.startGame(options: opts)
            }
        }
        XCTAssertEqual(a.rules!.machine.faults.filter { !$0.contains("display-clobbered") }, [], "EP\(n) lifted faults")
        let w = b.rules!.warnings
        XCTAssertEqual(w, [], "EP\(n) direct warnings")
        return (frames, games, sounds, messages, nil)
    }

    /// Long random games, every table: lifted and direct agree frame by frame. `EP_PARITY_FRAMES`
    /// sets the frames per table (default 1500, 25 s of play; the documented run used 60000).
    func testLiftedAndDirectBackendsAgreeOnLongRandomGames() throws {
        let frames = ProcessInfo.processInfo.environment["EP_PARITY_FRAMES"].flatMap(Int.init) ?? 1500
        var ran = 0
        var lines: [String] = []
        for n in 1...13 {
            guard let r = try Self.playBoth(table: n, frames: frames, seed: UInt64(0x9E37_79B9 &* n), players: 1 + n % 3) else { continue }
            if let msg = r.4 { XCTFail(msg) }
            lines.append("EP\(n): \(r.0) frames, \(r.1) games, \(1 + n % 3) players, \(r.2) sounds, \(r.3) message frames\(r.4 == nil ? ", identical" : "")")
            ran += 1
        }
        print(lines.joined(separator: "\n"))
        if ran == 0 { throw XCTSkip("no user tables with rules.json") }
    }

    func testDiscoveryMatchesLiftedProgram() throws {
        var compared = 0
        var report: [String] = []
        for n in 1...13 {
            guard let exe = Self.exe(n), let q = Self.lifted(n) else { continue }
            let t0 = Date()
            let (p, _, h) = try RulesProgram.discover(exe: exe, table: n)
            let ms = Date().timeIntervalSince(t0) * 1000
            let d = Self.compare(p, q)
            report.append(String(format: "EP%d: %d differences, %d hooks, %d stubs, dropped %@, %.0f ms", n, d.count, p.hooks.count, p.stubs.count,
                                 h.dropped.description, ms))
            for x in d { XCTFail("EP\(n) \(x)") }
            compared += 1
        }
        print(report.joined(separator: "\n"))
        if compared == 0 { throw XCTSkip("no original EXEs with rules.json") }
    }
}

extension RulesDirectTests {
    /// Step 1 of docs/enhanced/rules-direct.md: every instruction the direct backend can reach (from
    /// the dispatcher, all jump-table handlers, the kicker, every hook, and every callee the callout
    /// executes) is in MiniX86's subset, and every call resolves (display/sound/engine stub or
    /// executed). Prints the instruction-form inventory over the 13 tables.
    func testEveryReachableInstructionIsSupported() throws {
        var all: [String: Int] = [:]
        var lines: [String] = []
        var ran = 0
        for n in 1...13 {
            guard let exe = Self.exe(n) else { continue }
            let r = try RulesRuntime.direct(exe: exe, table: n)
            let rep = r.directCodeReport()
            for (f, c) in rep.forms { all[f, default: 0] += c }
            XCTAssertEqual(rep.unsupported.map { String(format: "cs:%04X %@", $0.0, $0.1) }, [], "EP\(n) unsupported")
            let unknown = rep.unknownCalls.filter { $0.1 >= 0 }
            XCTAssertEqual(unknown.map { String(format: "cs:%04X -> %04X%@", $0.0, $0.1, $0.2.map { String(format: " (seg %04X)", $0) } ?? "") }, [],
                           "EP\(n) unresolved calls")
            lines.append("EP\(n): \(rep.instructions) instructions, \(rep.forms.count) forms, \(rep.followed.count) routines executed, "
                         + "\(rep.handledCalls.count) stubbed, \(rep.unknownCalls.count) indirect calls, \(rep.segmentLoads.count) segment loads")
            ran += 1
        }
        if ran == 0 { throw XCTSkip("no original EXEs") }
        print(lines.joined(separator: "\n"))
        print("instruction forms (all tables): " + all.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: "; "))
    }
}

extension RulesDirectTests {
    /// Step 5: per-frame cost. Plays `EP_BENCH_FRAMES` frames (default 600) of AutoPlayer games per
    /// table with no rules (physics only, balls re-served), the lifted and the direct backend, and
    /// prints the mean time per original frame and MiniX86 instructions per frame. Build with
    /// `-c release -Xswiftc -enable-testing` for the numbers in docs/enhanced/rules-direct.md.
    func testPerFrameCostOfTheRulesBackends() throws {
        let frames = ProcessInfo.processInfo.environment["EP_BENCH_FRAMES"].flatMap(Int.init) ?? 600
        var lines: [String] = []
        var worstDirect = 0.0
        for n in 1...13 {
            guard let lifted = try Self.engine(n, .lifted), let direct = try Self.engine(n, .direct) else { continue }
            let physics = try EngineAssets.makeEngine(dataRoot: Self.dataRoot, table: n, rules: false)
            func play(_ e: ClassicEngine, rules: Bool) -> Double {
                if rules { e.startGame() } else { e.startGame(); e.rulesMode = .off }
                var p = AutoPlayer(engine: e)
                let t0 = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<frames {
                    e.input = p.input(for: e)
                    e.runFrame()
                    _ = e.takePresentation()
                    if rules, e.rules?.gameOver == true { e.startGame() }
                    if !rules, !e.balls.contains(where: { $0.active == 1 }) { e.serveBall() }
                }
                return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(frames)
            }
            let tp = play(physics, rules: false)
            let tl = play(lifted, rules: true)
            let i0 = direct.rules!.directInstructions
            let td = play(direct, rules: true)
            let ipf = Double(direct.rules!.directInstructions - i0) / Double(frames)
            worstDirect = max(worstDirect, td)
            lines.append(String(format: "EP%d: physics %.3f ms/frame, lifted %.3f, direct %.3f (rules: lifted +%.3f, direct +%.3f ms); %.0f x86 instructions/frame",
                                n, tp, tl, td, tl - tp, td - tp, ipf))
        }
        if lines.isEmpty { throw XCTSkip("no user tables") }
        print(lines.joined(separator: "\n"))
        XCTAssertLessThan(worstDirect, 1000.0 / 59.94, "a frame of the direct backend fits the original frame time")
    }
}

extension RulesDirectTests {
    /// The shipped setup: a library (PinballImport layout: tables/EPn/ + original/) with no rules.json
    /// at all. The rules load with the default (direct) backend from the EXE alone and play exactly
    /// like the development setup's direct backend.
    func testDirectBackendNeedsOnlyTheUsersEXE() throws {
        let fm = FileManager.default
        let n = 10
        guard let src = RulesRuntime.locateEXE(dataRoot: Self.dataRoot, table: n),
              fm.fileExists(atPath: Self.dataRoot.appendingPathComponent("tables/EP\(n)/engine.json").path) else { throw XCTSkip("no EP\(n)") }
        guard ProcessInfo.processInfo.environment["EPIC_PINBALL_ORIGINAL"] == nil else { throw XCTSkip("EPIC_PINBALL_ORIGINAL is set") }
        let lib = fm.temporaryDirectory.appendingPathComponent("ep-direct-lib-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: lib) }
        let tdir = lib.appendingPathComponent("tables/EP\(n)"), odir = lib.appendingPathComponent("original")
        try fm.createDirectory(at: tdir, withIntermediateDirectories: true)
        try fm.createDirectory(at: odir, withIntermediateDirectories: true)
        for f in ["engine.json", "collision_idx.npy"] {
            try fm.createSymbolicLink(at: tdir.appendingPathComponent(f), withDestinationURL: Self.dataRoot.appendingPathComponent("tables/EP\(n)/\(f)"))
        }
        try fm.createSymbolicLink(at: odir.appendingPathComponent("EP\(n).EXE"), withDestinationURL: src)
        XCTAssertFalse(fm.fileExists(atPath: RulesRuntime.rulesURL(dataRoot: lib, table: n).path))
        let e = try EngineAssets.makeEngine(dataRoot: lib, table: n)
        let r = try XCTUnwrap(e.rules, e.rulesLoadError ?? "")
        XCTAssertEqual(r.backend, RulesBackend.default)
        guard r.backend == .direct else { return }
        XCTAssertThrowsError(try RulesRuntime.load(dataRoot: lib, table: n, backend: .lifted), "lifted needs rules.json")
        let ref = try XCTUnwrap(try Self.engine(n, .direct))
        e.startGame(); ref.startGame()
        var p = AutoPlayer(engine: e)
        for f in 0..<1200 {
            let i = p.input(for: e)
            e.input = i; ref.input = i
            e.runFrame(); ref.runFrame()
            XCTAssertEqual(e.rules!.machine.snapshot(), ref.rules!.machine.snapshot(), "frame \(f)")
            if e.rules!.machine.snapshot() != ref.rules!.machine.snapshot() { break }
        }
        XCTAssertEqual(r.warnings, [])
    }
}
