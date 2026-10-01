import Foundation
import XCTest
@testable import PinballCore

/// Replays and save states (Replay/). The format and the synthetic-engine checks run anywhere; the
/// determinism checks play real games on the user's tables and skip without their files.
final class ReplayTests: XCTestCase {
    static let dataRoot = DataLocator.packageRelativeDefault

    // MARK: format (synthetic)

    func header(frames: Int = 0) -> ReplayHeader {
        var h = ReplayHeader(table: 3, date: Date(timeIntervalSince1970: 1_700_000_000), physics: .enhanced,
                             enhancedConfig: .classicFeel, rulesBackend: "direct", options: RulesOptions())
        h.frames = frames
        h.finalScores = [1234, 5678]
        h.finalDigest = "0123456789abcdef"
        h.events = [ReplayEvent(frame: 7, physics: .classic, enhancedConfig: nil)]
        return h
    }

    func testRunLengthRoundTrip() throws {
        var inputs: [UInt8] = []
        for i in 0..<5000 { inputs.append(i % 700 < 45 ? 4 : (i % 90 < 10 ? 1 : (i % 333 == 0 ? 0x2A : 0))) }
        inputs += [UInt8](repeating: 3, count: 200_000)   // a run longer than 2^14 (3-byte LEB128)
        let r = Replay(header: header(frames: inputs.count), inputs: inputs)
        let data = try r.encoded()
        XCTAssertEqual(try Replay.decode(data), r)
        XCTAssertLessThan(data.count, 4000, "run-length encoded inputs should be small")
        XCTAssertEqual(Replay.runs([1, 1, 2, 2, 2, 0]).map { $0.1 }, [2, 3, 1])
        // An empty game is valid.
        let e = Replay(header: header(frames: 0), inputs: [])
        XCTAssertEqual(try Replay.decode(try e.encoded()), e)
    }

    func testDamagedFilesAreRejected() throws {
        let r = Replay(header: header(frames: 3), inputs: [1, 1, 2])
        let good = try r.encoded()
        XCTAssertThrowsError(try Replay.decode(Data("EPXX".utf8) + good.dropFirst(4)))
        XCTAssertThrowsError(try Replay.decode(good.prefix(good.count - 1)))   // last run length cut
        var wrongVersion = good
        wrongVersion[4] = 99
        XCTAssertThrowsError(try Replay.decode(wrongVersion))
        var h = header(frames: 5)   // runs add up to 3
        h.frames = 5
        XCTAssertThrowsError(try Replay.decode(try Replay(header: h, inputs: [1, 1, 2]).encoded()))
    }

    /// A header claiming a negative or huge frame count is rejected before anything is allocated.
    func testImplausibleFrameCountsAreRejected() throws {
        for frames in [-1, ReplayFormat.maxFrames + 1, Int(Int32.max), 1 << 40] {
            // `encoded()` writes whatever the header says
            let data = try Replay(header: header(frames: frames), inputs: []).encoded()
            XCTAssertThrowsError(try Replay.decode(data), "frames \(frames)")
        }
        // More runs than frames.
        var d = try Replay(header: header(frames: 1), inputs: [1]).encoded()
        d.replaceSubrange((d.count - 6)..<(d.count - 2), with: [0xFF, 0xFF, 0xFF, 0x0F])
        XCTAssertThrowsError(try Replay.decode(d))
    }

    func testPlatformFamilyIgnoresMinorOSUpdates() {
        XCTAssertEqual(ReplayHeader.platformFamily("arm64 macOS 26.5.2"), "arm64 macOS 26")
        XCTAssertEqual(ReplayHeader.platformFamily("arm64 macOS 26.6.0"), ReplayHeader.platformFamily("arm64 macOS 26.5.2"))
        XCTAssertNotEqual(ReplayHeader.platformFamily("x86_64 macOS 26.5.2"), ReplayHeader.platformFamily("arm64 macOS 26.5.2"))
        XCTAssertNotEqual(ReplayHeader.platformFamily("arm64 macOS 27.0.0"), ReplayHeader.platformFamily("arm64 macOS 26.5.2"))
        // An enhanced replay from the same machine after a minor update gets no note.
        var h = header()
        h.platform = ReplayHeader.platformFamily(ReplayHeader.currentPlatform) + ".99.1"
        XCTAssertEqual(ReplayPlayer.notes(for: h, simulation: nil, dataRoot: nil, originalDir: nil), [])
        h.platform = "riscv macOS 1.0.0"
        XCTAssertEqual(ReplayPlayer.notes(for: h, simulation: nil, dataRoot: nil, originalDir: nil).count, 1)
    }

    func testDigestIsStable() {
        var a = StateHasher(), b = StateHasher()
        a.add([UInt8]([1, 2, 3])); a.add(Int16(-5)); a.add(true)
        b.add([UInt8]([1, 2, 3])); b.add(Int16(-5)); b.add(true)
        XCTAssertEqual(a.value, b.value)
        b.add(0)
        XCTAssertNotEqual(a.value, b.value)
        // FNV-1a 64 of nothing is the offset basis.
        XCTAssertEqual(StateHasher().hex, "cbf29ce484222325")
    }

    // MARK: save states on the synthetic engine (no game data)

    /// A ball bouncing in a synthetic box with flipper presses: snapshot, run on, restore, run the
    /// same inputs again: identical state; also after unrelated frames in between.
    func testSaveRestoreOnSyntheticEngine() throws {
        var buf = [UInt8](repeating: 0, count: 320 * 400)
        for x in 0..<320 { buf[300 * 320 + x] = UInt8(EngineFixture.wallIndex); buf[20 * 320 + x] = UInt8(EngineFixture.wallIndex) }
        for y in 20..<300 { buf[y * 320 + 10] = UInt8(EngineFixture.wallIndex); buf[y * 320 + 300] = UInt8(EngineFixture.wallIndex) }
        for physics in GameSettings.PhysicsMode.allCases {
            let e = try EngineFixture.engine(buffer: buf)
            let sim = GameSimulation(engine: e, physics: physics)
            e.balls[0] = BallState(x: 100, y: 100, vx: 300, vy: -200)
            func input(_ f: Int) -> FrameInput { f % 37 < 6 ? .leftFlipper : (f % 50 == 3 ? .nudgeA : []) }
            for f in 0..<120 { sim.input = input(f); sim.stepFrame() }
            let snap = sim.snapshot()
            XCTAssertEqual(snap.frame, 120)
            for f in 120..<400 { sim.input = input(f); sim.stepFrame() }
            let reference = sim.stateDigest().value
            sim.restore(snap)
            XCTAssertEqual(e.frameCount, 120)
            for f in 120..<400 { sim.input = input(f); sim.stepFrame() }
            XCTAssertEqual(sim.stateDigest().value, reference, "\(physics): restore + same inputs")
            for f in 0..<90 { sim.input = f % 2 == 0 ? .rightFlipper : .nudgeB; sim.stepFrame() }
            XCTAssertNotEqual(sim.stateDigest().value, reference)
            sim.restore(snap)
            for f in 120..<400 { sim.input = input(f); sim.stepFrame() }
            XCTAssertEqual(sim.stateDigest().value, reference, "\(physics): other frames, restore, same inputs")
        }
    }

    // MARK: the user's tables

    func engine(_ n: Int, backend: RulesBackend = .default) throws -> ClassicEngine {
        let fm = FileManager.default
        var files = ["tables/EP\(n)/engine.json", "tables/EP\(n)/collision_idx.npy"]
        if backend == .lifted { files.append("tables/EP\(n)/rules.json") }
        for f in files where !fm.fileExists(atPath: Self.dataRoot.appendingPathComponent(f).path) { throw XCTSkip("no extracted \(f)") }
        guard RulesRuntime.locateEXE(dataRoot: Self.dataRoot, table: n) != nil else { throw XCTSkip("no original/EP\(n).EXE") }
        let e = try EngineAssets.makeEngine(dataRoot: Self.dataRoot, table: n, backend: backend)
        XCTAssertNil(e.rulesLoadError)
        XCTAssertEqual(e.rules?.backend, backend)
        return e
    }

    func record(_ n: Int, physics: GameSettings.PhysicsMode, frames: Int, options: RulesOptions = RulesOptions(),
                backend: RulesBackend = .default) throws -> (AutoPlayReport, Replay) {
        let e = try engine(n, backend: backend)
        var replay: Replay?
        let report = AutoPlay.run(engine: e, frames: frames, options: options, physics: physics) { replay = $0 }
        return (report, try XCTUnwrap(replay))
    }

    /// AutoPlayer games on several tables, classic and enhanced physics, 1 and 2 players: recorded,
    /// written, read back, and re-simulated on a new engine: the same frames, scores and final
    /// state digest (engine, rules data segment, MiniX86, enhanced bodies).
    func testReplaysReproduceAutoplayGames() throws {
        var checked = 0
        for n in [1, 2, 5, 8, 10, 13] {
            for physics in GameSettings.PhysicsMode.allCases {
                var o = RulesOptions()
                if n == 10 { o.players = 2; o.ballsPerGame = 2 }
                let (report, replay): (AutoPlayReport, Replay)
                do { (report, replay) = try record(n, physics: physics, frames: physics == .classic ? 20_000 : 3_000, options: o) } catch is XCTSkip { continue }
                XCTAssertEqual(replay.header.frames, report.frames)
                XCTAssertEqual(replay.header.physics, physics)
                XCTAssertGreaterThan(replay.header.finalScores.max() ?? 0, 0, "EP\(n) \(physics)")
                let back = try Replay.decode(try replay.encoded())
                XCTAssertEqual(back, replay)
                let check = try ReplayPlayer.verify(back, dataRoot: Self.dataRoot)
                XCTAssertTrue(check.matches, "EP\(n) \(physics): replay diverged: \(check)")
                XCTAssertEqual(check.frames, report.frames)
                XCTAssertEqual(check.scores.first, report.score)
                XCTAssertEqual(check.notes, [], "EP\(n) \(physics)")
                checked += 1
            }
        }
        if checked == 0 { throw XCTSkip("no tables") }
    }

    /// The lifted rules backend (rules.json + RulesMachine): recorded games reproduce on a new engine
    /// with the recorded backend, and the data digest covers rules.json.
    func testLiftedBackendReplaysReproduce() throws {
        var checked = 0
        for n in [1, 8, 10, 13] {
            for physics in GameSettings.PhysicsMode.allCases {
                let (report, replay): (AutoPlayReport, Replay)
                do { (report, replay) = try record(n, physics: physics, frames: physics == .classic ? 20_000 : 3_000, backend: .lifted) } catch is XCTSkip { continue }
                XCTAssertEqual(replay.header.rulesBackend, "lifted")
                var h = replay.header
                h.setDigests(dataRoot: Self.dataRoot, originalDir: nil)
                var direct = h
                direct.rulesBackend = RulesBackend.direct.rawValue
                direct.setDigests(dataRoot: Self.dataRoot, originalDir: nil)
                XCTAssertNotNil(h.dataDigest)
                XCTAssertNotEqual(h.dataDigest, direct.dataDigest, "the lifted digest includes rules.json")
                let check = try ReplayPlayer.verify(Replay(header: h, inputs: replay.inputs), dataRoot: Self.dataRoot)
                XCTAssertTrue(check.matches, "EP\(n) lifted \(physics): replay diverged: \(check)")
                XCTAssertEqual(check.frames, report.frames)
                XCTAssertEqual(check.notes, [], "EP\(n) lifted \(physics)")
                checked += 1
            }
        }
        if checked == 0 { throw XCTSkip("no tables with rules.json") }
    }

    /// Enhanced -> classic -> enhanced between two frames (E pressed twice while paused) leaves the
    /// mode as it was but installs a fresh model; the recorder notes it and playback does the same.
    /// Without the event the replay diverges (the check that the event matters).
    func testReinstallBetweenFramesIsRecorded() throws {
        let e = try engine(1)
        let sim = GameSimulation(engine: e, physics: .enhanced)
        let rec = ReplayRecorder(simulation: sim, options: RulesOptions())
        var player = AutoPlayer(engine: e)
        var last = PresentationState()
        for f in 0..<2500 {
            if f == 500 || f == 1400 { sim.physicsMode = .classic; sim.physicsMode = .enhanced }
            if f == 900 { sim.physicsMode = .classic; sim.physicsMode = .enhanced; sim.physicsMode = .classic }   // a plain switch
            if f == 1000 { sim.physicsMode = .enhanced }
            if f == 1100 { sim.physicsMode = .classic; sim.physicsMode = .enhanced; sim.physicsMode = .classic; sim.physicsMode = .enhanced; sim.physicsMode = .classic }
            if f == 1200 { sim.physicsMode = .enhanced }
            sim.input = player.input(for: e)
            sim.stepFrame()
            last = sim.takePresentation()
            if last.gameOver { break }
        }
        let replay = rec.finish(scores: [last.scores[0]], gameOver: last.gameOver)
        let ev = replay.header.events
        XCTAssertEqual(ev.map(\.frame), [500, 900, 1000, 1100, 1200, 1400])
        XCTAssertEqual(ev.map(\.physics), [.enhanced, .classic, .enhanced, .classic, .enhanced, .enhanced])
        XCTAssertEqual(ev.map(\.reinstall), [true, nil, nil, nil, nil, true])
        let check = try ReplayPlayer.verify(try Replay.decode(try replay.encoded()), dataRoot: Self.dataRoot)
        XCTAssertTrue(check.matches, "\(check)")
        var stripped = replay
        stripped.header.events.removeAll { $0.reinstall == true }
        XCTAssertFalse(try ReplayPlayer.verify(stripped, dataRoot: Self.dataRoot).matches, "a fresh model changes the game")
    }

    /// A game that switches physics twice (classic -> enhanced at frame 400, back at 1300): the
    /// switches are recorded as events and the replay reproduces the game.
    func testReplayWithPhysicsSwitches() throws {
        let e = try engine(1)
        let sim = GameSimulation(engine: e)
        let rec = ReplayRecorder(simulation: sim, options: RulesOptions())
        var player = AutoPlayer(engine: e)
        var last = PresentationState()
        for f in 0..<2400 {
            if f == 400 { sim.physicsMode = .enhanced }
            if f == 1300 { sim.physicsMode = .classic }
            sim.input = player.input(for: e)
            sim.stepFrame()
            last = sim.takePresentation()
            if last.gameOver { break }
        }
        let replay = rec.finish(scores: [last.scores[0]], gameOver: last.gameOver)
        XCTAssertEqual(replay.header.events.map(\.frame), [400, 1300])
        XCTAssertEqual(replay.header.events.map(\.physics), [.enhanced, .classic])
        let check = try ReplayPlayer.verify(try Replay.decode(try replay.encoded()), dataRoot: Self.dataRoot)
        XCTAssertTrue(check.matches, "\(check)")
    }

    /// The app's new game (`newGame(options:powerOn:)`) after a finished game starts from the same
    /// state as a newly loaded table: its replay reproduces on a new engine.
    func testNewGameFromPowerOnIsReplayable() throws {
        for physics in GameSettings.PhysicsMode.allCases {
            let e = try engine(4)
            let powerOn = e.snapshot()
            let sim = GameSimulation(engine: e, physics: physics)
            var player = AutoPlayer(engine: e)
            for _ in 0..<20_000 {   // game 1 to its end
                sim.input = player.input(for: e)
                sim.stepFrame()
                if sim.takePresentation().gameOver { break }
            }
            var o = RulesOptions(); o.ballsPerGame = 2
            sim.newGame(options: o, powerOn: powerOn)
            XCTAssertEqual(e.frameCount, 0)
            XCTAssertEqual(sim.physicsMode, physics)
            XCTAssertEqual(e.ballPhysics is EnhancedPhysics, physics == .enhanced)
            let rec = ReplayRecorder(simulation: sim, options: o)
            player = AutoPlayer(engine: e)
            var last = PresentationState()
            for _ in 0..<(physics == .classic ? 20_000 : 5_000) {
                sim.input = player.input(for: e)
                sim.stepFrame()
                last = sim.takePresentation()
                if last.gameOver { break }
            }
            let replay = rec.finish(scores: [last.scores[0]], gameOver: last.gameOver)
            let check = try ReplayPlayer.verify(replay, dataRoot: Self.dataRoot)
            XCTAssertTrue(check.matches, "\(physics): second game's replay diverged: \(check)")
        }
    }

    /// Practice save states on real games, both rules backends and both physics models: save at
    /// frame 700, play 1500 frames (reference digest and per-frame presentation), play other frames,
    /// restore, play the same 1500 frames again: identical, frame by frame.
    func testSaveRestoreContinuesIdentically() throws {
        var checked = 0
        for n in [1, 8, 10] {
            for backend in RulesBackend.allCases {
                for physics in GameSettings.PhysicsMode.allCases {
                    let e: ClassicEngine
                    do { e = try engine(n, backend: backend) } catch is XCTSkip { continue }
                    let sim = GameSimulation(engine: e, physics: physics)
                    var player = AutoPlayer(engine: e)
                    for _ in 0..<700 { sim.input = player.input(for: e); sim.stepFrame(); _ = sim.takePresentation() }
                    let snap = sim.snapshot()
                    let savedPlayer = player
                    let frames = physics == .classic ? 1500 : 900
                    var inputs: [FrameInput] = [], reference: [String] = []
                    func summary(_ s: PresentationState) -> String {
                        "\(s.scores) \(s.ballNumber) \(s.lampStates) \(s.soundEvents.map { $0.sample }) \(s.message?.bytes ?? []) \(s.gameOver)"
                    }
                    for _ in 0..<frames {
                        let i = player.input(for: e)
                        inputs.append(i)
                        sim.input = i; sim.stepFrame()
                        reference.append(summary(sim.takePresentation()))
                    }
                    let refDigest = sim.stateDigest().value
                    // other frames (the player keeps flipping and nudging), then back
                    for f in 0..<400 { sim.input = f % 3 == 0 ? [.leftFlipper, .nudgeA] : .rightFlipper; sim.stepFrame(); _ = sim.takePresentation() }
                    sim.restore(snap)
                    XCTAssertEqual(e.frameCount, snap.frame)
                    for (k, i) in inputs.enumerated() {
                        sim.input = i; sim.stepFrame()
                        let s = summary(sim.takePresentation())
                        if s != reference[k] { XCTFail("EP\(n) \(backend) \(physics): frame \(k) after restore differs"); break }
                    }
                    XCTAssertEqual(sim.stateDigest().value, refDigest, "EP\(n) \(backend) \(physics)")
                    // The restored AutoPlayer copy gives the same inputs (sanity of the test itself).
                    sim.restore(snap)
                    player = savedPlayer
                    for _ in 0..<frames { sim.input = player.input(for: e); sim.stepFrame(); _ = sim.takePresentation() }
                    XCTAssertEqual(sim.stateDigest().value, refDigest, "EP\(n) \(backend) \(physics): autoplayer after restore")
                    checked += 1
                }
            }
        }
        if checked == 0 { throw XCTSkip("no tables") }
    }
}
