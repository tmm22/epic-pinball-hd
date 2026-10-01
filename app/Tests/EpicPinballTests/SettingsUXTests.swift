import Foundation
import PinballCore
import XCTest
@testable import EpicPinball

// Settings added for the front end's settings / UX work (lighting strength, scaling, physics
// preset, audio resampling, pause when inactive, screenshots, performance overlay) and the
// per-table statistics. Synthetic data only.

final class SettingsUXTests: XCTestCase {
    /// A settings.json written before these fields existed (dynamic lighting on).
    static let oldFile = #"""
    {"version":1,
     "game":{"physicsMode":"enhanced","upscaleFilter":"xbrz","useHDPack":false,"dynamicLighting":true,
             "highRefresh":false,"fullTableView":false,"musicVolume":0.8,"sfxVolume":0.5},
     "frontEnd":{"controllerEnabled":true,"haptics":true,"startFullscreen":false,"pixelAspect":"vga",
                 "masterVolume":0.9,"players":1,"ballsPerGame":3,"lastTable":4,"showStrip":true,
                 "keyBindings":{"leftFlipper":[56,123],"rightFlipper":[60,124,47,7],"plunger":[59,62],
                   "launchOrNudge":[49],"nudgeA":[6,43],"nudgeB":[44],"scrollUp":[126],"scrollDown":[125],
                   "toggleStrip":[36,76],"pause":[35],"menu":[53],"restart":[15],"toggleMusic":[46],
                   "toggleSfx":[1],"volumeDown":[27],"volumeUp":[24],"musicDown":[33],"musicUp":[30],
                   "fullTable":[48],"cycleFilter":[3],"pixelAspect":[0],"physicsMode":[14]}}}
    """#

    func testOldSettingsFileKeepsItsMeaning() {
        let s = StoredSettings.decode(Data(Self.oldFile.utf8))
        XCTAssertEqual(s.game.physicsMode, .enhanced)
        XCTAssertEqual(s.game.upscaleFilter, .xbrz)
        XCTAssertTrue(s.game.dynamicLighting)
        XCTAssertEqual(s.game.lightingChoice, .subtle, "lighting on in an old file = subtle, as before")
        XCTAssertEqual(s.game.outputScaling, .auto)
        XCTAssertEqual(s.game.enhancedPreset, .classicFeel)
        XCTAssertEqual(s.game.audioInterpolation, .original)
        XCTAssertEqual(s.frontEnd.lastTable, 4)
        XCTAssertEqual(s.frontEnd.pixelAspect, "vga")
        XCTAssertTrue(s.frontEnd.pauseWhenInactive)
        XCTAssertFalse(s.frontEnd.showPerfOverlay)
        XCTAssertEqual(s.frontEnd.screenshotFolder, "")
        XCTAssertEqual(s.frontEnd.screenshotDirectory, AppPaths.defaultScreenshotFolder)
        // The new actions get their default keys (nobody else has them).
        XCTAssertEqual(s.frontEnd.keyBindings.keys(.screenshot), [KeyCode.f12])
        XCTAssertEqual(s.frontEnd.keyBindings.keys(.perfOverlay), [KeyCode.f10])
    }

    func testDefaultsAreTheClassicGame() {
        let g = GameSettings()
        XCTAssertFalse(g.dynamicLighting)
        XCTAssertEqual(g.lightingChoice, .off)
        XCTAssertEqual(g.outputScaling, .auto)
        XCTAssertEqual(g.enhancedPreset, .classicFeel)
        XCTAssertEqual(g.audioInterpolation, .original)
        let fe = FrontEndSettings()
        XCTAssertTrue(fe.pauseWhenInactive)
        XCTAssertFalse(fe.showPerfOverlay)
    }

    func testNewFieldsRoundTripAndBadValuesDrop() throws {
        var s = StoredSettings()
        s.game.lightingChoice = .vivid
        s.game.outputScaling = .fill
        s.game.enhancedPreset = .modern
        s.game.audioInterpolation = .smooth
        s.frontEnd.pauseWhenInactive = false
        s.frontEnd.showPerfOverlay = true
        s.frontEnd.screenshotFolder = "~/Desktop/shots"
        let back = StoredSettings.decode(try s.encoded())
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.game.lightingChoice, .vivid)
        XCTAssertTrue(back.frontEnd.screenshotDirectory.path.hasSuffix("/Desktop/shots"))
        XCTAssertFalse(back.frontEnd.screenshotDirectory.path.contains("~"))

        let bad = #"{"game":{"lightingStrength":"blinding","outputScaling":3,"enhancedPreset":"modern","audioInterpolation":"cubic"},"#
            + #""frontEnd":{"pauseWhenInactive":"sometimes","showPerfOverlay":true,"screenshotFolder":7}}"#
        let d = StoredSettings.decode(Data(bad.utf8))
        XCTAssertEqual(d.game.lightingStrength, .subtle)
        XCTAssertEqual(d.game.outputScaling, .auto)
        XCTAssertEqual(d.game.enhancedPreset, .modern)
        XCTAssertEqual(d.game.audioInterpolation, .original)
        XCTAssertTrue(d.frontEnd.pauseWhenInactive)
        XCTAssertTrue(d.frontEnd.showPerfOverlay)
        XCTAssertEqual(d.frontEnd.screenshotFolder, "")
    }

    func testLightingChoiceKeepsTheBoolInStep() {
        var g = GameSettings()
        g.lightingChoice = .vivid
        XCTAssertTrue(g.dynamicLighting); XCTAssertEqual(g.lightingStrength, .vivid)
        g.lightingChoice = .off
        XCTAssertFalse(g.dynamicLighting)
        XCTAssertEqual(g.lightingStrength, .vivid, "the strength is remembered for the next time it is switched on")
        g.dynamicLighting = true
        XCTAssertEqual(g.lightingChoice, .vivid)
        g.lightingChoice = .subtle
        XCTAssertEqual(g.lightingStrength, .subtle)
    }
}

final class BindingClashTests: XCTestCase {
    func testDefaultsHaveNoClashes() {
        var owner: [UInt16: GameAction] = [:]
        for a in GameAction.allCases {
            for k in KeyBindings.defaults.keys(a) {
                XCTAssertNil(owner[k], "\(KeyCode.name(k)) bound to both \(owner[k].map { "\($0)" } ?? "") and \(a)")
                owner[k] = a
            }
        }
        XCTAssertEqual(KeyBindings.defaults.keys(.screenshot), [KeyCode.f12])
        XCTAssertEqual(KeyBindings.defaults.keys(.perfOverlay), [KeyCode.f10])
    }

    /// The original's own keys (engine.md section 5: flippers, Ctrl, Space, nudges, P, M, S, T,
    /// Esc/Q, Enter, F1 in the quit prompt) are never taken by the new front-end keys.
    func testNewKeysAvoidTheOriginalKeys() {
        let original: Set<UInt16> = [KeyCode.leftShift, KeyCode.rightShift, KeyCode.left, KeyCode.right, KeyCode.period,
                                     KeyCode.x, KeyCode.leftControl, KeyCode.rightControl, KeyCode.space, KeyCode.z,
                                     KeyCode.comma, KeyCode.slash, KeyCode.p, KeyCode.m, KeyCode.s, 17 /* T */,
                                     KeyCode.escape, 12 /* Q */, KeyCode.returnKey, 122 /* F1 */]
        for a in [GameAction.screenshot, .perfOverlay] {
            XCTAssertTrue(Set(KeyBindings.defaults.keys(a)).isDisjoint(with: original), "\(a)")
        }
    }

    /// A file from before the new actions, where the user already put F12 on a flipper: F12 stays
    /// a flipper only, the screenshot action gets no key (Shift-Cmd-S still works) and can be set.
    func testNewActionDefaultsYieldToUserBindings() throws {
        let json = #"{"leftFlipper":[111],"menu":[53],"rightFlipper":[60]}"#
        var b = try JSONDecoder().decode(KeyBindings.self, from: Data(json.utf8))
        XCTAssertEqual(b.actions(for: KeyCode.f12), [.leftFlipper])
        XCTAssertEqual(b.keys(.screenshot), [])
        XCTAssertEqual(b.keys(.perfOverlay), [KeyCode.f10])
        // Actions missing from the file whose default keys are free keep them.
        XCTAssertEqual(b.keys(.pause), [KeyCode.p])
        b.bind(KeyCode.f12, to: .screenshot, replace: true)
        XCTAssertEqual(b.actions(for: KeyCode.f12), [.screenshot])
        XCTAssertEqual(b.keys(.leftFlipper), [])
        // Every key drives at most one action after decoding.
        for code in Set(GameAction.allCases.flatMap { b.keys($0) }) { XCTAssertEqual(b.actions(for: code).count, 1, KeyCode.name(code)) }
    }
}

final class StatsTests: XCTestCase {
    private func frame(player: Int = 0, ball: Int, scores: [UInt32], players: Int = 1, over: Bool = false) -> PresentationState {
        var s = PresentationState()
        s.currentPlayer = player; s.ballNumber = ball; s.scores = scores; s.playerCount = players; s.gameOver = over
        return s
    }

    func testTrackerCountsBallsTimeAndScore() {
        var t = GameStatsTracker(ballsPerGame: 3)
        let dt = 1 / 59.94
        for b in 1...3 { for _ in 0..<60 { XCTAssertNil(t.frame(frame(ball: b, scores: [UInt32(b * 1000)]), physics: "classic", frameSeconds: dt)) } }
        // The round counter passes the last ball on the way to game over: not a ball.
        XCTAssertNil(t.frame(frame(ball: 4, scores: [3500]), physics: "classic", frameSeconds: dt))
        let g = try! XCTUnwrap(t.frame(frame(ball: 4, scores: [3500], over: true), physics: "classic", frameSeconds: dt))
        XCTAssertTrue(g.completed); XCTAssertTrue(g.counts)
        XCTAssertEqual(g.balls, 3)
        XCTAssertEqual(g.scores, [3500])
        XCTAssertEqual(g.seconds["classic"] ?? 0, 181 * dt, accuracy: 1e-9)
        XCTAssertFalse(t.active)
        // Frames after game over (none run, but be safe) start nothing.
        XCTAssertNil(t.frame(frame(ball: 4, scores: [3500], over: true), physics: "classic", frameSeconds: dt))
        XCTAssertNil(t.abandon(physics: "classic"))
    }

    func testTwoPlayersAndModeSwitch() {
        var t = GameStatsTracker(ballsPerGame: 3)
        _ = t.frame(frame(player: 0, ball: 1, scores: [10, 0], players: 2), physics: "classic", frameSeconds: 1)
        _ = t.frame(frame(player: 1, ball: 1, scores: [10, 20], players: 2), physics: "enhanced", frameSeconds: 2)
        _ = t.frame(frame(player: 0, ball: 2, scores: [30, 20], players: 2), physics: "enhanced", frameSeconds: 2)
        let g = t.abandon(physics: "enhanced")!
        XCTAssertFalse(g.completed); XCTAssertTrue(g.counts)
        XCTAssertEqual(g.balls, 3)
        XCTAssertEqual(g.scores, [30, 20])
        XCTAssertEqual(g.seconds, ["classic": 1, "enhanced": 4])
        var book = StatsBook()
        book.record(g, table: 2)
        XCTAssertEqual(book.stats(table: 2, physics: "classic").playSeconds, 1)
        XCTAssertEqual(book.stats(table: 2, physics: "classic").games, 0)
        let e = book.stats(table: 2, physics: "enhanced")
        XCTAssertEqual(e.games, 1); XCTAssertEqual(e.abandoned, 1); XCTAssertEqual(e.balls, 3)
        XCTAssertEqual(e.scores, 2); XCTAssertEqual(e.totalScore, 50); XCTAssertEqual(e.bestScore, 30)
        XCTAssertEqual(e.averageScore, 25); XCTAssertEqual(e.playSeconds, 4)
    }

    func testBookAccumulatesAndSkipsEmptyAbandonedGames() {
        var book = StatsBook()
        book.record(FinishedGame(physics: "classic", scores: [1_000_000], balls: 3, seconds: ["classic": 300], completed: true), table: 1)
        book.record(FinishedGame(physics: "classic", scores: [3_000_000], balls: 4, seconds: ["classic": 200], completed: true), table: 1)
        // Started and left at once: the time counts, the game does not.
        book.record(FinishedGame(physics: "classic", scores: [0], balls: 1, seconds: ["classic": 5], completed: false), table: 1)
        let s = book.stats(table: 1, physics: "classic")
        XCTAssertEqual(s.games, 2); XCTAssertEqual(s.abandoned, 0); XCTAssertEqual(s.balls, 7)
        XCTAssertEqual(s.bestScore, 3_000_000); XCTAssertEqual(s.averageScore, 2_000_000)
        XCTAssertEqual(s.playSeconds, 505)
        XCTAssertTrue(book.stats(table: 2).isEmpty)
        XCTAssertNil(TableStats().averageScore)
        // Scores beyond UInt32 in total do not overflow.
        var big = StatsBook()
        for _ in 0..<3 { big.record(FinishedGame(physics: "enhanced", scores: [UInt32.max], balls: 1, seconds: [:], completed: true), table: 12) }
        XCTAssertEqual(big.stats(table: 12, physics: "enhanced").totalScore, 3 * UInt64(UInt32.max))
        XCTAssertEqual(big.stats(table: 12, physics: "enhanced").averageScore, UInt32.max)
    }

    @MainActor
    func testStorePersistsClearsAndKeepsDamagedFileAside() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("stats.json")
        let a = StatsStore(fileURL: url)
        a.record(FinishedGame(physics: "classic", scores: [500], balls: 3, seconds: ["classic": 60], completed: true), table: 5)
        a.record(FinishedGame(physics: "classic", scores: [700], balls: 3, seconds: ["classic": 60], completed: true), table: 6)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 1)
        let b = StatsStore(fileURL: url)
        XCTAssertEqual(b.stats(table: 5)["classic"]?.bestScore, 500)
        b.clear(table: 5)
        XCTAssertTrue(StatsStore(fileURL: url).stats(table: 5).isEmpty)
        XCTAssertEqual(StatsStore(fileURL: url).stats(table: 6)["classic"]?.games, 1)
        b.clearAll()
        XCTAssertTrue(StatsStore(fileURL: url).book.tables.isEmpty)

        try Data("{ not json".utf8).write(to: url)
        let c = StatsStore(fileURL: url)
        XCTAssertTrue(c.book.tables.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("bad").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing written until something is recorded")
    }

    func testLenientTableStatsDecoding() throws {
        let json = #"{"version":1,"tables":{"3":{"classic":{"games":2,"bestScore":"lots","playSeconds":-4,"future":1}}}}"#
        let b = try JSONDecoder().decode(StatsBook.self, from: Data(json.utf8))
        let s = b.stats(table: 3, physics: "classic")
        XCTAssertEqual(s.games, 2); XCTAssertEqual(s.bestScore, 0); XCTAssertEqual(s.playSeconds, 0)
    }

    func testPlayTimeFormat() {
        XCTAssertEqual(formatPlayTime(42), "42 s")
        XCTAssertEqual(formatPlayTime(12 * 60 + 5), "12 min")
        XCTAssertEqual(formatPlayTime(3600 + 5 * 60), "1 h 05 min")
    }
}

final class ScreenshotAndPerfTests: XCTestCase {
    func testScreenshotNames() throws {
        let dir = try tempDir()
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 1; c.hour = 14; c.minute = 3; c.second = 27
        let date = Calendar.current.date(from: c)!
        let u = GameController.screenshotURL(in: dir, table: "Some: Table/Name", date: date)
        XCTAssertEqual(u.lastPathComponent, "Some- Table-Name 2026-10-01 at 14.03.27.png")
        try Data().write(to: u)
        XCTAssertEqual(GameController.screenshotURL(in: dir, table: "Some: Table/Name", date: date).lastPathComponent,
                       "Some- Table-Name 2026-10-01 at 14.03.27 2.png")
        XCTAssertTrue(GameController.screenshotURL(in: dir, table: "  ", date: date).lastPathComponent.hasPrefix("Epic Pinball 2026"))
    }

    func testPerfMeterLatencyAndSummary() {
        var m = PerfMeter(period: 0.5)
        XCTAssertNil(m.frame(now: 10.000, ran: 1, simSeconds: 0.001, flipperHeld: false))
        m.flipperPressed(at: 10.010)
        // A display frame that runs no game frame does not apply the key yet.
        XCTAssertNil(m.frame(now: 10.016, ran: 0, simSeconds: 0, flipperHeld: true))
        let k = m.frame(now: 10.033, ran: 1, simSeconds: 0.002, flipperHeld: true)
        XCTAssertEqual(k, 10.010)
        XCTAssertEqual(m.lastKeyToSim ?? 0, 23, accuracy: 1e-6)
        m.presented(keyTime: 10.010, at: 10.050)
        XCTAssertEqual(m.lastKeyToPresent ?? 0, 40, accuracy: 1e-6)
        // Only the first frame applies a press.
        XCTAssertNil(m.frame(now: 10.050, ran: 1, simSeconds: 0.001, flipperHeld: true))
        XCTAssertTrue(m.summary.isEmpty)
        var t = 10.050
        while m.summary.isEmpty { t += 1 / 60; _ = m.frame(now: t, ran: 1, simSeconds: 0.001, flipperHeld: false) }
        XCTAssertEqual(m.summary.count, 3)
        XCTAssertTrue(m.summary[0].contains("fps"))
        XCTAssertTrue(m.summary[2].contains("23.0 ms"), m.summary[2])
        XCTAssertTrue(m.summary[2].contains("40.0 ms"), m.summary[2])
    }
}
