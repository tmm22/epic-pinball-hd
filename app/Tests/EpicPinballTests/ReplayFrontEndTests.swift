import Foundation
import Metal
import PinballCore
import XCTest
@testable import EpicPinball

// Replays and practice in the front end: the Replays directory, high-score links, menus per
// session and the practice keys. Synthetic replays only (no game data).

final class ReplayFrontEndTests: XCTestCase {
    func replay(table: Int, score: UInt32, date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Replay {
        var h = ReplayHeader(table: table, date: date, physics: .classic, enhancedConfig: nil, rulesBackend: "direct", options: RulesOptions())
        h.frames = 4
        h.finalScores = [score]
        return Replay(header: h, inputs: [4, 4, 0, 1])
    }

    func testOldHighScoreFilesStillDecode() throws {
        let json = #"{"version":1,"tables":{"1":[{"initials":"ABC","score":5,"date":"2026-01-01T00:00:00Z","players":1,"player":1,"physics":"classic"}]}}"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let b = try dec.decode(HighScoreBook.self, from: Data(json.utf8))
        XCTAssertNil(b.entries(table: 1).first?.replay)
        var e = b.entries(table: 1)[0]
        e.replay = "EP1-hs-x.epreplay"
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let back = try dec.decode(HighScoreEntry.self, from: enc.encode(e))
        XCTAssertEqual(back.replay, "EP1-hs-x.epreplay")
    }

    @MainActor
    func testLibraryKeepsLastHighScoreAndSavedReplays() throws {
        let saved = AppPaths.overrideRoot
        defer { AppPaths.overrideRoot = saved }
        AppPaths.overrideRoot = try tempDir()
        let lib = ReplayLibrary()
        XCTAssertNil(lib.lastURL(table: 2))
        try lib.saveLast(replay(table: 2, score: 10))
        try lib.saveLast(replay(table: 2, score: 20))   // replaces the last game
        let last = try XCTUnwrap(lib.lastURL(table: 2))
        XCTAssertEqual(try Replay.load(contentsOf: last).header.finalScores, [20])
        let hs1 = try lib.keep(replay(table: 2, score: 30), kind: .highScore)
        let hs2 = try lib.keep(replay(table: 2, score: 30), kind: .highScore)   // same name: numbered
        XCTAssertNotEqual(hs1, hs2)
        XCTAssertTrue(hs1.hasPrefix("EP2-hs-") && hs1.hasSuffix(".epreplay"))
        let s = try lib.keep(replay(table: 2, score: 40, date: Date(timeIntervalSince1970: 1_800_000_000)), kind: .saved)
        _ = try lib.keep(replay(table: 2, score: 50), kind: .saved)
        XCTAssertEqual(lib.saved(table: 2).first?.name, s, "newest first")
        XCTAssertEqual(lib.saved(table: 2).count, 2)
        XCTAssertTrue(lib.saved(table: 3).isEmpty)
        // An entry pushed off the list: its replay goes; saved and last games stay.
        lib.prune(table: 2, referenced: [hs2])
        XCTAssertFalse(lib.exists(hs1))
        XCTAssertTrue(lib.exists(hs2))
        XCTAssertTrue(lib.exists(s))
        XCTAssertNotNil(lib.lastURL(table: 2))
    }

    @MainActor
    func testMenusPerSession() {
        let m = OverlayModel()
        m.mode = .pauseMenu
        XCTAssertEqual(m.items, [.resume, .newGame, .practice, .settings, .chooseTable, .quit])
        m.session = .practice
        XCTAssertEqual(m.items, [.resume, .saveState, .newGame, .endPractice, .settings, .chooseTable, .quit])
        m.stateSaved = true
        XCTAssertTrue(m.items.contains(.loadState))
        m.mode = .gameOver
        XCTAssertEqual(m.gameOverTitle, "Practice Over")
        XCTAssertFalse(m.items.contains(.saveReplay), "practice games have no replay")
        m.session = .watching
        XCTAssertEqual(m.items, [.watchAgain, .chooseTable, .quit])
        m.session = .normal
        XCTAssertEqual(m.items, [.newGame, .chooseTable, .settings, .quit])
        m.replayAvailable = true
        XCTAssertEqual(m.items, [.newGame, .saveReplay, .watchReplay, .chooseTable, .settings, .quit])
        XCTAssertEqual(m.label(.saveReplay), "Save Replay")
        m.replaySaved = true
        XCTAssertEqual(m.label(.saveReplay), "Replay Saved")
    }

    func testPracticeKeysAndOldBindingFiles() throws {
        XCTAssertEqual(KeyBindings.defaults.actions(for: KeyCode.k), [.saveState])
        XCTAssertEqual(KeyBindings.defaults.actions(for: KeyCode.l), [.loadState])
        // A settings file from before the practice keys gets their defaults.
        let old = #"{"leftFlipper":[56],"menu":[53]}"#
        let b = try JSONDecoder().decode(KeyBindings.self, from: Data(old.utf8))
        XCTAssertEqual(b.keys(.saveState), [KeyCode.k])
        XCTAssertEqual(b.keys(.leftFlipper), [KeyCode.leftShift])
        XCTAssertFalse(GameAction.saveState.isHeld)
        // A key the user bound to something else does not also get a new action's default.
        let taken = #"{"leftFlipper":[40],"rightFlipper":[37],"menu":[53]}"#
        let t = try JSONDecoder().decode(KeyBindings.self, from: Data(taken.utf8))
        XCTAssertEqual(t.actions(for: KeyCode.k), [.leftFlipper])
        XCTAssertEqual(t.actions(for: KeyCode.l), [.rightFlipper])
        XCTAssertEqual(t.keys(.saveState), [])
        XCTAssertEqual(t.keys(.loadState), [])
        // A stored action keeps its keys even where a default would collide.
        let both = #"{"saveState":[40],"leftFlipper":[40]}"#
        XCTAssertEqual(try JSONDecoder().decode(KeyBindings.self, from: Data(both.utf8)).actions(for: KeyCode.k), [.leftFlipper, .saveState])
    }

    /// `recordsResults` / recording per session on a real table (EP1; skips without the user's
    /// data or a Metal device): a normal game is recorded and offers its score for the high scores;
    /// a practice game and a watched replay record nothing and add no score.
    @MainActor
    func testOnlyNormalGamesRecordReplaysAndScores() throws {
        let root = DataLocator.packageRelativeDefault
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("tables/EP1/engine.json").path),
              RulesRuntime.locateEXE(dataRoot: root, table: 1) != nil else { throw XCTSkip("no extracted EP1 / original EP1.EXE") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let saved = AppPaths.overrideRoot
        defer { AppPaths.overrideRoot = saved }
        AppPaths.overrideRoot = try tempDir()
        var o = Options()
        o.table = 1
        o.balls = 1
        o.mute = true
        let lib = ReplayLibrary()

        func play(_ c: GameController) -> PresentationState {
            var player = AutoPlayer(engine: c.sim.engine)
            var last = PresentationState()
            for _ in 0..<30_000 {
                c.sim.input = player.input(for: c.sim.engine)
                c.sim.stepFrame()
                last = c.sim.takePresentation()
                if last.gameOver { break }
            }
            XCTAssertTrue(last.gameOver)
            return last
        }
        func screen(_ session: SessionKind, replay: Replay? = nil) throws -> GameController {
            var oo = o
            oo.practice = session == .practice
            let c = try GameScreen.make(options: oo, dataRoot: root, preloaded: nil, app: nil, replay: replay).controller
            XCTAssertEqual(c.session, session)
            c.keepsReplays = true
            c.highScores = HighScoreStore(fileURL: AppPaths.highScoresFile)
            c.newGame()   // the session's game, now with replays and scores on
            return c
        }

        // practice: nothing recorded, no initials, no files
        let p = try screen(.practice)
        XCTAssertFalse(p.recordsResults)
        XCTAssertFalse(p.isRecording)
        p.handleGameOver(play(p))
        XCTAssertEqual(p.overlay.mode, .gameOver)
        XCTAssertNil(lib.lastURL(table: 1))
        XCTAssertTrue(lib.names().isEmpty)
        p.stop()

        // normal: recorded from frame 0, written at game over, the score goes to initials entry
        let n = try screen(.normal)
        XCTAssertTrue(n.recordsResults)
        XCTAssertTrue(n.isRecording)
        n.handleGameOver(play(n))
        XCTAssertFalse(n.isRecording)
        XCTAssertEqual(n.overlay.mode, .initials, "an empty table list takes any score")
        let url = try XCTUnwrap(lib.lastURL(table: 1))
        let replay = try Replay.load(contentsOf: url)
        n.stop()

        // watching it: no recording, game over adds nothing
        let w = try screen(.watching, replay: replay)
        XCTAssertFalse(w.recordsResults)
        XCTAssertFalse(w.isRecording)
        let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let rp = try XCTUnwrap(w.replayPlayer)
        var last = PresentationState()
        while rp.stepFrame(w.sim) { last = w.sim.takePresentation() }
        w.handleGameOver(last)
        XCTAssertNotEqual(w.overlay.mode, .initials)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, mtime)
        XCTAssertEqual(w.sim.stateDigest().hex, replay.header.finalDigest, "the watched replay reproduces")
        XCTAssertEqual(HighScoreStore(fileURL: AppPaths.highScoresFile).entries(table: 1).count, 0)
        w.stop()
    }

    /// The original's visible fades in the app (EP1; skips without the user's data or a Metal device): the boot
    /// fade-in blocks play at the session's start and at every new game, the game-over fade-out runs its first
    /// 5 passes and holds behind the panel, and the next game runs the other 13 before the fade-in.
    @MainActor
    func testScreenFadesAroundAGame() throws {
        let root = DataLocator.packageRelativeDefault
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("tables/EP1/engine.json").path),
              RulesRuntime.locateEXE(dataRoot: root, table: 1) != nil else { throw XCTSkip("no extracted EP1 / original EP1.EXE") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let saved = AppPaths.overrideRoot
        defer { AppPaths.overrideRoot = saved }
        AppPaths.overrideRoot = try tempDir()
        var o = Options()
        o.table = 1
        o.balls = 1
        o.mute = true
        let c = try GameScreen.make(options: o, dataRoot: root, preloaded: nil, app: nil).controller
        defer { c.stop() }
        c.highScores = HighScoreStore(fileURL: AppPaths.highScoresFile)
        var f = try XCTUnwrap(c.screenFade)
        XCTAssertTrue(f.blocksPlay, "the session's first game fades in")
        XCTAssertEqual(f.pending, 16, "17 frames, the first on screen")
        XCTAssertEqual(c.presentation?.screenOverrides?.count, 256)
        while f.blocksPlay { f.step() }
        f.step()
        c.screenFade = f
        var player = AutoPlayer(engine: c.sim.engine)
        var last = PresentationState()
        for _ in 0..<30_000 {
            c.sim.input = player.input(for: c.sim.engine)
            c.sim.stepFrame()
            last = c.sim.takePresentation()
            if last.gameOver { break }
        }
        XCTAssertTrue(last.gameOver)
        c.rulesGameOver(last)
        f = try XCTUnwrap(c.screenFade)
        XCTAssertTrue(f.holding)
        XCTAssertEqual(f.pending, 4, "5 passes before the final-score screen")
        XCTAssertEqual(c.presentation?.screenOverrides?.count, 255, "DAC 255 is left alone")
        XCTAssertNotEqual(c.overlay.mode, .none, "the panel is not delayed")
        while f.blocksPlay { f.step() }
        c.screenFade = f
        c.newGame()
        f = try XCTUnwrap(c.screenFade)
        XCTAssertEqual(f.pending, 13 + 17 - 1)
        XCTAssertFalse(f.holding)
        XCTAssertEqual(c.overlay.mode, .none)
    }
}
