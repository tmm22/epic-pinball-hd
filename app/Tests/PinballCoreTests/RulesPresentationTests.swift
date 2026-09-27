import Foundation
import XCTest
@testable import PinballCore

/// PresentationState from the rules state (mapping documented on `RulesRuntime`), on the synthetic
/// table: lamps, score, tilt, messages by EXE offset with live bytes, and sound events (queue at the
/// forced base rate with its gap, sweep trains at the live rate with sweepFrames = 0, the pan rule).
final class RulesPresentationTests: XCTestCase {
    typealias F = RulesFixture

    func testLampsScoreTiltAndPlayers() throws {
        let (e, r) = try F.engine()
        let m = r.machine
        m.write8(F.lampFirst + 0, 1)      // draw a once
        m.write8(F.lampFirst + 1, 2)      // draw b once
        m.write8(F.lampFirst + 2, 3)      // blinking
        m.write(F.score, 4, 0xDEAD_BEEF)
        m.write8(F.tilted, 1)
        r.lampUpdate()
        let s = e.takePresentation()
        XCTAssertEqual(s.lampStates.count, F.lampCount)
        XCTAssertEqual(Array(s.lampStates.prefix(4)), [5, 6, 3, 0], "1 -> 5 and 2 -> 6 once drawn")
        XCTAssertEqual(Array(s.lamps.prefix(4)), [true, false, false, false], "lit = sprite a drawn")
        XCTAssertEqual(s.scores, [0xDEAD_BEEF])
        XCTAssertEqual(s.playerCount, 1)
        XCTAssertEqual(s.currentPlayer, 0)
        XCTAssertTrue(s.tilted)
        XCTAssertNil(s.music, "the tables never change song (audio.md section 2)")
    }

    func testMessageIsReferencedByEXEOffsetWithLiveBytes() throws {
        let blocks: [String: Any] = ["L1000": F.block(0x1000, [
            ["op": "store", "w": 1, "addr": F.message + 2, "val": 0x39],
            ["op": "message", "msg": F.message, "pos": ["x": 0, "y": 2, "raw": 0x280], "mode": 0x0103],
            ["op": "text", "msg": F.message, "pos": ["reg", "di"], "routine": "0x5000"],
        ])]
        let (e, r) = try F.engine(rules: F.rules(blocks: blocks))
        r.machine.call(r.program.labels["L1000"]!, registers: ["di": 0x1234])
        let s = e.takePresentation()
        let msg = try XCTUnwrap(s.message)
        XCTAssertEqual(msg.exeOffset, F.dsFileOffset + F.message)
        XCTAssertEqual(msg.dsOffset, F.message)
        XCTAssertEqual(msg.mode, 0x03, "AL = effect")
        XCTAssertEqual(msg.modeWord, 0x0103)
        XCTAssertEqual(msg.position, 0x280)
        XCTAssertEqual(msg.bytes, Array("AB9".utf8), "digits the rules patched in")
        XCTAssertEqual(s.texts.map(\.position), [0x1234])
        XCTAssertEqual(s.texts.first?.routine, 0x5000)
        XCTAssertTrue(e.takePresentation().texts.isEmpty, "texts are per presentation")
    }

    func testQueuedSoundPlaysAtBaseRateThenBlocks() throws {
        let (e, r) = try F.engine(mode: .full)
        let m = r.machine
        e.balls[0] = BallState(x: 100, y: 50)
        m.write(F.rate, 2, 8000)
        m.write(F.queue, 2, 0x0005)
        r.soundBlock()
        m.write(F.queue, 2, 0x0006)
        for _ in 0..<3 { r.soundBlock() }
        var s = e.takePresentation()
        XCTAssertEqual(s.soundEvents.map(\.sample), [5])
        XCTAssertEqual(s.soundEvents.first?.rateHz, 11000, "sfx_pending forces the base rate")
        XCTAssertEqual(m.read(F.rate, 2), 8000, "and restores the live rate")
        for _ in 0..<3 { r.soundBlock() }
        s = e.takePresentation()
        XCTAssertEqual(s.soundEvents.map(\.sample), [6], "the next queued id waits out the gap")
        XCTAssertEqual(s.soundEvents.first?.pan, 5, "pan = ball x / 20")
        XCTAssertEqual(s.soundEvents.first?.sweepFrames, 0)
    }

    func testSweepIsATrainOfRetriggersAtSteppedRates() throws {
        let (e, r) = try F.engine(mode: .full)
        let m = r.machine
        m.write8(F.sweep, 1)
        m.write(F.rate, 2, 11000)
        m.write(F.sweepStep, 2, 0x0007)
        m.write(F.sweepEnd, 2, 0x0009)
        for _ in 0..<16 { r.soundBlock() }
        let s = e.takePresentation()
        // every 4th frame (mask 3, phase 1): +1000 Hz; at the limit the rate is reset to the base
        // first and the end id plays at that rate (EP1 cs:0945..0958)
        XCTAssertEqual(s.soundEvents.map(\.sample), [7, 7, 9])
        XCTAssertEqual(s.soundEvents.map(\.rateHz), [12000, 13000, 11000])
        XCTAssertTrue(s.soundEvents.allSatisfy { $0.sweepFrames == 0 && $0.sweepPerFrame == 0 })
        XCTAssertEqual(m.read(F.rate, 2), 11000)
        XCTAssertEqual(m.read8(F.sweep), 0)
        XCTAssertEqual(m.read(F.sweepEnd, 2), 0, "the end id is played once")
    }

    func testSoundNowUsesTheLiveRateAndPanRule() throws {
        let (e, r) = try F.engine(mode: .full)
        let m = r.machine
        m.write(F.rate, 2, 9500)
        func play(_ ax: Int, ballX: Int16) -> SoundEvent? {
            e.balls[0].x = ballX
            m.write(F.now, 2, Int64(ax))
            r.soundBlock()
            return e.takePresentation().soundEvents.first
        }
        XCTAssertEqual(play(0x0003, ballX: 100), SoundEvent(sample: 3, rateHz: 9500, pan: 5))
        XCTAssertEqual(play(0xF004, ballX: 100)?.pan, 15, "high nibble of the id wins")
        XCTAssertEqual(play(0x1004, ballX: 300)?.pan, 1)
        XCTAssertEqual(play(0x0003, ballX: 319)?.pan, 15, "x / 20 clamped to 15")
        XCTAssertEqual(play(0x0003, ballX: 5180)?.pan, 3, "the original clamps the low byte of the quotient")
        XCTAssertEqual(m.read(F.now, 2), 0, "sfx_now is cleared after playing")
    }

    func testSoundsAccumulateAcrossFramesUntilTaken() throws {
        let (e, r) = try F.engine(mode: .full)
        let m = r.machine
        m.write(F.now, 2, 1)
        e.runFrame()
        m.write(F.now, 2, 2)
        e.runFrame()
        XCTAssertEqual(e.takePresentation().soundEvents.map(\.sample), [1, 2])
        XCTAssertTrue(e.takePresentation().soundEvents.isEmpty)
    }

    func testStartGameWithoutRulesServesABall() throws {
        let e = try EngineFixture.engine()
        e.startGame()
        XCTAssertEqual(e.balls[0].active, 1)
        XCTAssertEqual(e.rulesMode, .off)
        XCTAssertTrue(e.takePresentation().soundEvents.isEmpty)
    }
}
