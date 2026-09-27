import Foundation
import XCTest
@testable import PinballCore

/// A short headless game on every table the user has (skipped per table without its files): the
/// engine with the table's rules in full mode, driven by `AutoPlayer` (plunge, flip), exactly the
/// loop `EpicPinball --autoplay N` and the window run. Checks that nothing traps: the rules load,
/// no interpreter faults, no push-out loop-guard trips, a sane PresentationState every frame, and
/// that a game advances (score, sounds) and ends with game over within the frame budget.
final class HeadlessGameTests: XCTestCase {
    static let dataRoot = DataLocator.packageRelativeDefault

    func engine(_ n: Int) throws -> ClassicEngine {
        let fm = FileManager.default
        for f in ["tables/EP\(n)/engine.json", "tables/EP\(n)/collision_idx.npy", "tables/EP\(n)/rules.json"] {
            guard fm.fileExists(atPath: Self.dataRoot.appendingPathComponent(f).path) else { throw XCTSkip("no extracted \(f)") }
        }
        guard RulesRuntime.locateEXE(dataRoot: Self.dataRoot, table: n) != nil else { throw XCTSkip("no original/EP\(n).EXE") }
        return try EngineAssets.makeEngine(dataRoot: Self.dataRoot, table: n)
    }

    func play(_ n: Int, frames: Int = 12_000) throws {
        let e = try engine(n)
        XCTAssertNil(e.rulesLoadError, "EP\(n) rules must load")
        XCTAssertNotNil(e.rules)
        let r = AutoPlay.run(engine: e, frames: frames)
        XCTAssertEqual(r.loopGuardTrips, 0, "EP\(n): push-out loop guard tripped")
        XCTAssertEqual(r.ruleFaults, [], "EP\(n): interpreter faults")
        XCTAssertGreaterThan(r.frames, 300, "EP\(n): the game ended implausibly early")
        XCTAssertGreaterThan(r.score, 0, "EP\(n): no score in \(r.frames) frames")
        XCTAssertGreaterThan(r.soundEvents, 0, "EP\(n): no sound events")
        XCTAssertGreaterThanOrEqual(r.drains, 3, "EP\(n): fewer than 3 balls played in \(r.frames) frames")
        XCTAssertTrue(r.gameOver, "EP\(n): no game over after \(r.frames) frames (ball \(r.ballNumber))")
        // Presentation stays consistent after the game.
        let s = e.takePresentation()
        XCTAssertEqual(s.lamps.count, s.lampStates.count)
        XCTAssertEqual(s.scores.count, s.playerCount)
    }

    func testTable1() throws { try play(1) }
    func testTable2() throws { try play(2) }
    func testTable3() throws { try play(3) }
    func testTable4() throws { try play(4) }
    func testTable5() throws { try play(5) }
    func testTable6() throws { try play(6) }
    func testTable7() throws { try play(7) }
    func testTable8() throws { try play(8) }
    func testTable9() throws { try play(9) }
    func testTable10() throws { try play(10) }
    func testTable11() throws { try play(11) }
    func testTable12() throws { try play(12) }
    func testTable13() throws { try play(13) }

    /// Two players, two balls each: the end-of-turn counters switch players and the game ends after
    /// 2 x 2 balls (EP1 through its endOfTurn glue, EP10 through its automatic hooks).
    func testTwoPlayerGameEnds() throws {
        for n in [1, 10] {
            let e = try engine(n)
            var o = RulesOptions(); o.players = 2; o.ballsPerGame = 2
            let r = AutoPlay.run(engine: e, frames: 20_000, options: o)
            XCTAssertTrue(r.gameOver, "EP\(n): two-player game did not end")
            XCTAssertGreaterThanOrEqual(r.drains, 4, "EP\(n): 2 players x 2 balls")
        }
    }
}
