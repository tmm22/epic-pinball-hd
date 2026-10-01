import Foundation
import Metal
import PinballCore
import PinballRender
import XCTest
@testable import EpicPinball

// The remaining front-end gaps closed on feat2/frontend-rest: statistics only for human play, the
// renderer options in Settings > Display (decoding), practice save states on disk (format, damaged
// files, and a state saved in one run continuing identically in a new run).

final class StatisticsRuleTests: XCTestCase {
    /// `GameController.countsForStatistics`: only a normal, non-attract game that no automation drove.
    func testOnlyHumanGamesCount() {
        XCTAssertTrue(GameController.countsForStatistics(recordsResults: true, autopilotPlayed: false, automatedRun: false))
        XCTAssertFalse(GameController.countsForStatistics(recordsResults: false, autopilotPlayed: false, automatedRun: false),
                       "practice, watched replays and attract games")
        XCTAssertFalse(GameController.countsForStatistics(recordsResults: true, autopilotPlayed: true, automatedRun: false),
                       "--autopilot")
        XCTAssertFalse(GameController.countsForStatistics(recordsResults: true, autopilotPlayed: false, automatedRun: true),
                       "--exit-after smoke tests and EPIC_PINBALL_TEST_* hooks")
    }

    func testTestHooksAreRecognised() {
        XCTAssertFalse(GameController.testHooksActive([:]))
        XCTAssertFalse(GameController.testHooksActive(["EPIC_PINBALL_RENDER": "filter=xbrz", "EPIC_PINBALL_DATA": "/x"]))
        XCTAssertTrue(GameController.testHooksActive(["EPIC_PINBALL_TEST_INITIALS": "ABC"]))
        XCTAssertTrue(GameController.testHooksActive(["EPIC_PINBALL_TEST_FLIPPER": "1"]))
    }

    /// On a real table (EP1; skips without the user's data or Metal): a game played through
    /// `sim.input` (as the keyboard does) is recorded; a game the auto-player drives, and a game in
    /// a smoke-test run, are not.
    @MainActor
    func testAutopilotAndSmokeTestGamesAreNotRecorded() throws {
        let root = try requireTable(1)
        let dir = try tempDir()
        var o = Options()
        o.table = 1
        o.balls = 1
        o.mute = true
        let c = try GameScreen.make(options: o, dataRoot: root, preloaded: nil, app: nil).controller
        defer { c.stop() }
        let book = StatsStore(fileURL: dir.appendingPathComponent("stats.json"))
        c.stats = book
        c.rulesOptions.ballsPerGame = 1
        XCTAssertFalse(c.automatedRun, "no --exit-after, no test hook")

        func playToGameOver(autopilot: Bool) {
            var player = AutoPlayer(engine: c.sim.engine)
            if autopilot {
                var p2 = AutoPlayer(engine: c.sim.engine)
                c.sim.inputProvider = { p2.input(for: $0) }
            } else {
                c.sim.inputProvider = nil
            }
            for _ in 0..<40_000 {
                if !autopilot { c.sim.input = player.input(for: c.sim.engine) }
                c.noteInputSource()
                c.sim.stepFrame()
                let st = c.sim.takePresentation()
                c.trackStatistics(st)
                if st.gameOver { return }
            }
            XCTFail("no game over")
        }

        c.newGame()
        playToGameOver(autopilot: false)
        XCTAssertEqual(book.stats(table: 1)["classic"]?.games, 1, "a game played by hand counts")
        let after = book.stats(table: 1)

        c.newGame()
        XCTAssertTrue(c.recordsStatistics)
        playToGameOver(autopilot: true)
        XCTAssertFalse(c.recordsStatistics)
        XCTAssertEqual(book.stats(table: 1), after, "an autopilot game adds nothing (not even play time)")

        // The next game, without the auto-player, counts again; in a smoke-test run nothing does.
        c.newGame()
        XCTAssertTrue(c.recordsStatistics)
        c.automatedRun = true
        playToGameOver(autopilot: false)
        XCTAssertEqual(book.stats(table: 1), after)
        XCTAssertEqual(StatsStore(fileURL: dir.appendingPathComponent("stats.json")).stats(table: 1), after)
    }
}

final class DisplaySettingsTests: XCTestCase {
    /// A settings file from before the new Display options decodes with each at the renderer's
    /// built-in value, so it renders exactly as before.
    func testOldFileKeepsTheRenderersDefaults() {
        let s = StoredSettings.decode(Data(IntegratedSettingsTests.oldFile.utf8))
        let d = GameSettings()
        XCTAssertEqual(s.game.crtScanlines, d.crtScanlines)
        XCTAssertEqual(s.game.crtCurvature, d.crtCurvature)
        XCTAssertEqual(s.game.crtMask, d.crtMask)
        XCTAssertTrue(s.game.roundDots)
        XCTAssertTrue(s.game.stripInFullTable)
        XCTAssertTrue(s.game.rotateFlippers)
        // GameSettings defaults map onto the renderer's defaults, field by field.
        let built = RenderSettings(GameSettings()), plain = RenderSettings()
        XCTAssertEqual(built.crtScanlines, plain.crtScanlines)
        XCTAssertEqual(built.crtCurvature, plain.crtCurvature)
        XCTAssertEqual(built.crtMask, plain.crtMask)
        XCTAssertEqual(built.roundDots, plain.roundDots)
        XCTAssertEqual(built.stripInFullTable, plain.stripInFullTable)
        XCTAssertEqual(built.rotateFlippers, plain.rotateFlippers)
        XCTAssertEqual(built, plain)
        XCTAssertTrue(RenderSettings(s.game).rotateFlippers)
    }

    func testNewFieldsRoundTripClampAndBadValuesDrop() throws {
        var g = GameSettings()
        g.crtScanlines = 0.3
        g.crtCurvature = 0
        g.crtMask = 0.9
        g.roundDots = false
        g.stripInFullTable = false
        g.rotateFlippers = false
        let data = try StoredSettings(game: g, frontEnd: FrontEndSettings()).encoded()
        let back = StoredSettings.decode(data)
        XCTAssertEqual(back.game, g)
        let r = RenderSettings(back.game)
        XCTAssertEqual(r.crtScanlines, 0.3)
        XCTAssertEqual(r.crtCurvature, 0)
        XCTAssertEqual(r.crtMask, 0.9)
        XCTAssertFalse(r.roundDots)
        XCTAssertFalse(r.stripInFullTable)
        XCTAssertFalse(r.rotateFlippers)

        // A mistyped field keeps its default, the others are kept; out-of-range values are clamped
        // for the renderer.
        let json = #"{"version":1,"game":{"crtScanlines":"deep","crtCurvature":5,"crtMask":-1,"rotateFlippers":false,"roundDots":1}}"#
        let s = StoredSettings.decode(Data(json.utf8))
        XCTAssertEqual(s.game.crtScanlines, GameSettings().crtScanlines)
        XCTAssertFalse(s.game.rotateFlippers)
        let c = RenderSettings(s.game)
        XCTAssertEqual(Double(c.crtCurvature), GameSettings.crtCurvatureRange.upperBound, accuracy: 1e-6)
        XCTAssertEqual(c.crtMask, 0)
    }

    func testEnvironmentSpecTakesTheNewKeys() {
        let r = RenderSettings.fromEnvironment(["EPIC_PINBALL_RENDER": "filter=crt,scanlines=0.4,mask=0.5,curvature=0,dots=0,strip=0,flippers=fade"])
        XCTAssertEqual(r?.crtScanlines, 0.4)
        XCTAssertEqual(r?.crtMask, 0.5)
        XCTAssertEqual(r?.crtCurvature, 0)
        XCTAssertEqual(r?.roundDots, false)
        XCTAssertEqual(r?.stripInFullTable, false)
        XCTAssertEqual(r?.rotateFlippers, false)
    }
}

final class PracticeStateFileTests: XCTestCase {
    func sample(table: Int = 3, slot: Int = 2, frames: Int = 4) throws -> PracticeStateFile {
        var h = ReplayHeader(table: table, physics: .classic, enhancedConfig: nil, rulesBackend: "direct", options: RulesOptions())
        h.frames = frames
        h.finalDigest = "00000000deadbeef"
        let r = Replay(header: h, inputs: Array(repeating: 4, count: frames))
        return PracticeStateFile(table: table, slot: slot, date: Date(timeIntervalSince1970: 1_800_000_000), frame: frames,
                                 scores: [12_340], gameOver: false, physics: .classic, enhancedConfig: nil,
                                 digest: h.finalDigest, replay: try r.encoded())
    }

    func testRoundTripMissingDamagedAndNewer() throws {
        let store = PracticeStateStore(directory: try tempDir().appendingPathComponent("SaveStates"))
        guard case .missing = store.load(table: 3, slot: 2) else { return XCTFail("empty slot") }
        let f = try sample()
        try store.write(f)
        XCTAssertEqual(PracticeStateStore.fileName(table: 3, slot: 2), "EP3-slot2.epstate")
        XCTAssertEqual(store.occupiedSlots(table: 3), [2])
        guard case let .ok(back, replay) = store.load(table: 3, slot: 2) else { return XCTFail("decodes") }
        XCTAssertEqual(back, f)
        XCTAssertEqual(replay.inputs.count, 4)
        XCTAssertEqual(back.version, PracticeStateFile.currentVersion)
        let raw = try String(contentsOf: store.url(table: 3, slot: 2), encoding: .utf8)
        XCTAssertTrue(raw.contains("\"format\" : \"epic-pinball-practice-state\""))
        XCTAssertTrue(raw.contains("\"version\" : 1"))

        // A newer format is left alone.
        let newer = raw.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 7")
        try newer.write(to: store.url(table: 3, slot: 2), atomically: true, encoding: .utf8)
        guard case .unsupported = store.load(table: 3, slot: 2) else { return XCTFail("newer version") }
        XCTAssertTrue(store.exists(table: 3, slot: 2))

        // Damaged: moved aside to .bad, the slot is free again.
        try Data("{\"format\":\"epic-pinball-practice-state\",\"version\":1,\"table\":3".utf8).write(to: store.url(table: 3, slot: 2))
        guard case let .damaged(_, moved) = store.load(table: 3, slot: 2) else { return XCTFail("damaged") }
        XCTAssertEqual(moved?.lastPathComponent, "EP3-slot2.epstate.bad")
        XCTAssertFalse(store.exists(table: 3, slot: 2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(table: 3, slot: 2).path + ".bad"))
        guard case .missing = store.load(table: 3, slot: 2) else { return XCTFail("free after moving aside") }

        // Bad replay bytes inside valid JSON are damage too; a frame count that does not match the
        // stored game as well.
        var bad = try sample()
        bad.replay = Data([1, 2, 3])
        try store.write(bad)
        guard case .damaged = store.load(table: 3, slot: 2) else { return XCTFail("bad replay data") }
        var mismatch = try sample()
        mismatch.frame = 99
        try store.write(mismatch)
        guard case .damaged = store.load(table: 3, slot: 2) else { return XCTFail("frame mismatch") }

        // Another table's file under this name is not loaded.
        let other = try sample(table: 5, slot: 2)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(other).write(to: store.url(table: 3, slot: 2))
        guard case .unsupported = store.load(table: 3, slot: 2) else { return XCTFail("other table") }

        store.clear(table: 3)
        XCTAssertEqual(store.occupiedSlots(table: 3), [])
    }
}

final class PracticeSlotAndSettingsPauseTests: XCTestCase {
    @MainActor
    func testSlotLabelsAndKeys() {
        let m = OverlayModel()
        m.mode = .pauseMenu
        m.session = .practice
        m.stateSlot = 3
        XCTAssertEqual(m.label(.saveState), "Save State (Slot 3)")
        XCTAssertEqual(m.label(.loadState), "Restore State (Slot 3)")
        XCTAssertEqual(m.label(.resume), "Resume")
        // Digits 1-4 select the slot; none of them is a default binding (so they work out of the box).
        XCTAssertEqual(Set(GameController.stateSlotKeys.values), Set(1...PracticeStateFile.slotCount))
        for code in GameController.stateSlotKeys.keys { XCTAssertTrue(KeyBindings.defaults.actions(for: code).isEmpty, KeyCode.name(code)) }
    }

    /// Cmd-, (Settings) over a running game pauses it without the pause menu, focus loss while the
    /// sheet is up opens no menu, and closing Settings leaves the game paused; opened from the
    /// pause menu it returns to the pause menu. EP1; skips without the user's data or Metal.
    @MainActor
    func testSettingsPausesTheGameAndReturnsToIt() throws {
        let root = try requireTable(1)
        var o = Options()
        o.table = 1
        o.mute = true
        let c = try GameScreen.make(options: o, dataRoot: root, preloaded: nil, app: nil).controller
        defer { c.stop() }
        XCTAssertFalse(c.paused)
        c.settingsWillOpen()
        XCTAssertTrue(c.paused)
        XCTAssertEqual(c.overlay.mode, .none, "no pause menu behind the sheet")
        c.pauseForInactivity()   // the sheet takes the key window
        XCTAssertEqual(c.overlay.mode, .none)
        c.settingsDidClose()
        XCTAssertTrue(c.paused, "back to the paused game")
        XCTAssertEqual(c.overlay.mode, .none)
        c.setPaused(false)

        c.openMenu()
        XCTAssertEqual(c.overlay.mode, .pauseMenu)
        c.settingsWillOpen()
        c.settingsDidClose()
        XCTAssertEqual(c.overlay.mode, .pauseMenu, "opened from the pause menu: back to it")
        XCTAssertTrue(c.paused)
        c.closeMenu()
        XCTAssertFalse(c.paused)
    }
}

/// A practice state saved in one run and loaded in a new one (a new engine, presentation and
/// controller, the slot file the only link) continues exactly as the first run did; a state saved
/// from the loaded game again loads to the same point. EP1 classic and EP10 with a switch to
/// enhanced physics just before the save. Skips without the user's data or Metal.
final class PracticeAcrossRunsTests: XCTestCase {
    @MainActor
    func testSavedStateContinuesIdenticallyInANewRun() throws {
        try check(table: 1, saveAt: 600, continueFor: 900, switchToEnhancedBeforeSave: false)
    }

    @MainActor
    func testStateSavedRightAfterAPhysicsSwitchLoadsIdentically() throws {
        try check(table: 10, saveAt: 500, continueFor: 400, switchToEnhancedBeforeSave: true)
    }

    @MainActor
    private func check(table: Int, saveAt: Int, continueFor: Int, switchToEnhancedBeforeSave: Bool) throws {
        let root = try requireTable(table)
        let dir = try tempDir()
        let store = PracticeStateStore(directory: dir.appendingPathComponent("SaveStates"))
        var o = Options()
        o.table = table
        o.mute = true
        o.practice = true

        func run() throws -> GameController {
            let c = try GameScreen.make(options: o, dataRoot: root, preloaded: nil, app: nil).controller
            XCTAssertEqual(c.session, .practice)
            c.practiceStore = store
            c.stats = StatsStore(fileURL: dir.appendingPathComponent("stats.json"))
            c.highScores = HighScoreStore(fileURL: dir.appendingPathComponent("highscores.json"))
            return c
        }
        func step(_ c: GameController, _ inputs: [FrameInput]) -> [UInt32] {
            var scores: [UInt32] = []
            for i in inputs {
                c.sim.input = i
                c.sim.stepFrame()
                let st = c.sim.takePresentation()
                c.trackStatistics(st)
                scores = st.scores
            }
            return scores
        }

        // Run 1: play, save to slot 1, play on.
        let a = try run()
        var player = AutoPlayer(engine: a.sim.engine)
        for _ in 0..<saveAt { a.sim.input = player.input(for: a.sim.engine); a.sim.stepFrame(); _ = a.sim.takePresentation() }
        if switchToEnhancedBeforeSave { a.sim.physicsMode = .enhanced }   // as the E key between two frames
        a.saveState()
        let savedDigest = a.sim.stateDigest().hex
        XCTAssertTrue(store.exists(table: table, slot: 1), "the state is written to the slot's file")
        var cont: [FrameInput] = []
        for _ in 0..<continueFor {
            let i = player.input(for: a.sim.engine)
            cont.append(i)
            a.sim.input = i
            a.sim.stepFrame()
            _ = a.sim.takePresentation()
        }
        let endDigest = a.sim.stateDigest().hex
        let endFrame = a.sim.engine.frameCount
        XCTAssertNotEqual(endDigest, savedDigest)
        // Within the run (memory slot) as before.
        a.loadState()
        XCTAssertEqual(a.sim.stateDigest().hex, savedDigest)
        let scoresA = step(a, cont)
        XCTAssertEqual(a.sim.stateDigest().hex, endDigest)
        a.stop()

        // Run 2: a new table session; some other play first, then L from the file.
        let b = try run()
        var other = AutoPlayer(engine: b.sim.engine)
        for _ in 0..<77 { b.sim.input = other.input(for: b.sim.engine); b.sim.stepFrame(); _ = b.sim.takePresentation() }
        b.loadState()
        XCTAssertEqual(b.sim.engine.frameCount, saveAt)
        XCTAssertEqual(b.sim.stateDigest().hex, savedDigest, "loaded from disk: the saved state exactly")
        XCTAssertEqual(b.sim.physicsMode, switchToEnhancedBeforeSave ? .enhanced : .classic)
        let scoresB = step(b, cont)
        XCTAssertEqual(b.sim.engine.frameCount, endFrame)
        XCTAssertEqual(b.sim.stateDigest().hex, endDigest, "continues exactly as the first run did")
        XCTAssertEqual(scoresB, scoresA)
        // Save the continued game to slot 2 (the recording resumed from the file's game).
        b.selectStateSlot(2)
        b.saveState()
        b.stop()

        // Run 3: slot 2 from disk is the end of run 1.
        let c = try run()
        c.selectStateSlot(2)
        c.loadState()
        XCTAssertEqual(c.sim.engine.frameCount, endFrame)
        XCTAssertEqual(c.sim.stateDigest().hex, endDigest)
        c.stop()

        // Practice games never reach the statistics or the high scores.
        XCTAssertTrue(StatsStore(fileURL: dir.appendingPathComponent("stats.json")).book.tables.isEmpty)
        XCTAssertTrue(HighScoreStore(fileURL: dir.appendingPathComponent("highscores.json")).entries(table: table).isEmpty)
    }
}

/// The user's data for `table` and a Metal device, or skip.
func requireTable(_ table: Int) throws -> URL {
    let root = DataLocator.packageRelativeDefault
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("tables/EP\(table)/engine.json").path),
          RulesRuntime.locateEXE(dataRoot: root, table: table) != nil else { throw XCTSkip("no extracted EP\(table) / original EP\(table).EXE") }
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    return root
}
