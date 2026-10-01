import PinballCore
import XCTest

// `ReplayRecorder(resuming:simulation:)` and `snapshot(scores:)` (practice save states on disk keep
// the game up to the state as a replay prefix and keep recording after a load). Synthetic engine,
// no game data.
final class ReplayResumeTests: XCTestCase {
    func testResumedRecordingEqualsAContinuousOne() throws {
        var buf = [UInt8](repeating: 0, count: 320 * 400)
        for x in 0..<320 { buf[300 * 320 + x] = UInt8(EngineFixture.wallIndex); buf[20 * 320 + x] = UInt8(EngineFixture.wallIndex) }
        for y in 20..<300 { buf[y * 320 + 10] = UInt8(EngineFixture.wallIndex); buf[y * 320 + 300] = UInt8(EngineFixture.wallIndex) }
        for physics in GameSettings.PhysicsMode.allCases {
            let e = try EngineFixture.engine(buffer: buf)
            let sim = GameSimulation(engine: e, physics: physics)
            e.balls[0] = BallState(x: 100, y: 100, vx: 300, vy: -200)
            let rec = ReplayRecorder(simulation: sim)
            func input(_ f: Int) -> FrameInput { f % 37 < 6 ? .leftFlipper : (f % 50 == 3 ? .nudgeA : []) }
            for f in 0..<120 { sim.input = input(f); sim.stepFrame() }
            // A physics switch between frames 119 and 120 (the E key just before K): not in the
            // prefix yet, recorded at frame 120 by both recordings.
            sim.physicsMode = physics == .classic ? .enhanced : .classic
            let cut = rec.snapshot(scores: [7])
            XCTAssertEqual(cut.header.frames, 120)
            XCTAssertEqual(cut.header.finalScores, [7])
            XCTAssertEqual(cut.header.finalDigest, sim.stateDigest().hex)
            XCTAssertEqual(cut.inputs.count, 120)
            let saved = sim.snapshot()
            for f in 120..<300 { sim.input = input(f); sim.stepFrame() }
            let whole = rec.finish(scores: [], gameOver: false)
            XCTAssertEqual(whole.header.events.count, 1)

            sim.restore(saved)
            let resumed = ReplayRecorder(resuming: cut, simulation: sim)
            for f in 120..<300 { sim.input = input(f); sim.stepFrame() }
            let again = resumed.finish(scores: [], gameOver: false)
            XCTAssertEqual(again.inputs, whole.inputs, "\(physics)")
            XCTAssertEqual(again.header.events, whole.header.events, "\(physics)")
            XCTAssertEqual(again.header.finalDigest, whole.header.finalDigest, "\(physics)")
            XCTAssertEqual(again.header.frames, 300)
        }
    }
}
