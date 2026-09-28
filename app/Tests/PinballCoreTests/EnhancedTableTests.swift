import Foundation
import XCTest
@testable import PinballCore

/// The enhanced physics on the user's own tables (each test skips without the extracted data /
/// EXE): flipper fits, fuzzed launches (no NaN, no tunnelling, no livelock), classic-feel
/// comparisons against the integer engine, and full autoplay games with the rules.
///
/// Sizes scale with environment variables for the full validation runs documented in
/// docs/enhanced/physics.md (run them in release:
/// `swift test -c release -Xswiftc -enable-testing --filter EnhancedTableTests`):
/// `EP_ENHANCED_FUZZ` (launches per table and preset, default 20), `EP_ENHANCED_FUZZ_FRAMES` (default 90),
/// `EP_ENHANCED_GAMES=1` (autoplay games on all 13 tables, default EP1 and EP10 only).
final class EnhancedTableTests: XCTestCase {
    static let dataRoot = DataLocator.packageRelativeDefault
    static let env = ProcessInfo.processInfo.environment

    func data(_ n: Int) throws -> (EngineData, [UInt8]) {
        let fm = FileManager.default
        for f in ["tables/EP\(n)/engine.json", "tables/EP\(n)/collision_idx.npy"] {
            guard fm.fileExists(atPath: Self.dataRoot.appendingPathComponent(f).path) else { throw XCTSkip("no extracted \(f)") }
        }
        return try EngineAssets.load(dataRoot: Self.dataRoot, table: n)
    }

    func rulesEngine(_ n: Int) throws -> ClassicEngine {
        _ = try data(n)
        guard FileManager.default.fileExists(atPath: Self.dataRoot.appendingPathComponent("tables/EP\(n)/rules.json").path) else { throw XCTSkip("no rules.json") }
        guard RulesRuntime.locateEXE(dataRoot: Self.dataRoot, table: n) != nil else { throw XCTSkip("no original/EP\(n).EXE") }
        return try EngineAssets.makeEngine(dataRoot: Self.dataRoot, table: n)
    }

    /// Every flipper's outlines fit a rigid rotation about one pivot to within about a pixel
    /// (EP4's upper flippers, whose four distinct outlines are not rotations of each other, less).
    func testFlipperShapesFitOutlines() throws {
        for n in 1...13 {
            guard let (d, _) = try? data(n) else { continue }
            for (i, f) in d.flippers.enumerated() {
                let s = FlipperShape(index: i, flipper: f)
                let rest = d.flipperGroups[f.group].restAngle
                XCTAssertEqual(s.poses.last?.alpha ?? -1, Double(rest), accuracy: 0.51, "EP\(n) flipper \(i)")
                let lower = f.positions[rest].allSatisfy { $0 / 320 > 300 }
                XCTAssertLessThan(s.fitError, lower ? 1.0 : 4.0, "EP\(n) flipper \(i) fit")
                // At a whole angle index the field is the outline itself.
                for a in [0, 4, 9] {
                    for o in f.positions[a].prefix(20) {
                        let p = SIMD2(Double(o % 320) + 0.5, Double(o / 320) + 0.5)
                        XCTAssertLessThan(s.rawValue(p, alpha: Double(a)), 0, "EP\(n) flipper \(i) angle \(a)")
                    }
                }
                let up = s.theta(alpha: 0).theta, restTheta = s.theta(alpha: Double(rest)).theta
                XCTAssertGreaterThan(abs(up - restTheta), lower ? 0.5 : 0.1, "EP\(n) flipper \(i) swings")
            }
        }
    }

    /// Random launches on every table: no NaN, never more than `tunnelDepth` px inside a wall,
    /// kicker or flipper outline, every launch finishes quickly (no livelock).
    func testFuzzLaunches() throws {
        let launches = Int(Self.env["EP_ENHANCED_FUZZ"] ?? "") ?? 20
        let frames = Int(Self.env["EP_ENHANCED_FUZZ_FRAMES"] ?? "") ?? 90
        var ran = 0
        for n in 1...13 {
            guard let (d, buf) = try? data(n) else { continue }
            for cfg in [EnhancedPhysicsConfig.classicFeel, .modern] {
                let e = try ClassicEngine(data: d, startBuffer: buf)
                let r = EnhancedValidation.fuzz(engine: e, config: cfg, launches: launches, frames: frames)
                print("fuzz \(cfg.preset.rawValue): \(r)")
                for x in r.examples { print("    \(x)") }
                XCTAssertEqual(r.nonFinite, 0, "EP\(n) \(cfg.preset)")
                XCTAssertEqual(r.nanResets, 0, "EP\(n) \(cfg.preset)")
                XCTAssertEqual(r.tunnelViolations, 0, "EP\(n) \(cfg.preset): \(r.examples)")
                XCTAssertEqual(r.sweepExhausted, 0, "EP\(n) \(cfg.preset)")
                XCTAssertLessThan(r.slowestLaunchSeconds, 5, "EP\(n) \(cfg.preset)")
                ran += 1
            }
        }
        if ran == 0 { throw XCTSkip("no extracted tables") }
    }

    /// Classic feel vs the integer engine on straight walls at every angle (EP1's normal table and
    /// divisors): the mean normal restitution per wall angle matches, and outgoing directions agree.
    func testClassicFeelBounceMatchesClassic() throws {
        let (d, _) = try data(1)
        var diffs: [Double] = [], angs: [Double] = []
        for wa in stride(from: 0.0, to: 360.0, by: 22.5) {
            var ce: [Double] = [], fe: [Double] = []
            for inc in [0.0, 30.0, -30.0] {
                let c = try EnhancedValidation.bounce(data: d, wallAngle: wa, incidence: inc, speed: 2.5, config: nil)
                let f = try EnhancedValidation.bounce(data: d, wallAngle: wa, incidence: inc, speed: 2.5, config: .classicFeel)
                if let a = c.normalRestitution, let b = f.normalRestitution { ce.append(a); fe.append(b) }
                if let a = c.outAngle, let b = f.outAngle {
                    var x = b - a; while x > 180 { x -= 360 }; while x < -180 { x += 360 }
                    angs.append(abs(x))
                }
            }
            guard !ce.isEmpty else { continue }
            diffs.append(abs(ce.reduce(0, +) / Double(ce.count) - fe.reduce(0, +) / Double(fe.count)))
        }
        let meanDiff = diffs.reduce(0, +) / Double(diffs.count), meanAng = angs.reduce(0, +) / Double(angs.count)
        print(String(format: "classic feel bounces: mean |e_n diff| per wall angle %.3f, mean |out angle diff| %.1f deg", meanDiff, meanAng))
        XCTAssertLessThan(meanDiff, 0.08)
        XCTAssertLessThan(meanAng, 15)
    }

    /// Classic feel flipper shots: mean shot speed within 15% of the integer engine's.
    func testClassicFeelFlipperShotsMatchClassic() throws {
        let (d, buf) = try data(1)
        var cs: [Double] = [], fs: [Double] = []
        for off in stride(from: 6, through: 30, by: 6) {
            for delay in [0, 3, 6] {
                guard let c = try EnhancedValidation.flipperShot(data: d, buffer: buf, offset: off, delay: delay, drop: 20, vy0: 1, config: nil),
                      let f = try EnhancedValidation.flipperShot(data: d, buffer: buf, offset: off, delay: delay, drop: 20, vy0: 1, config: .classicFeel) else { continue }
                cs.append(c.speed); fs.append(f.speed)
            }
        }
        XCTAssertGreaterThan(cs.count, 8)
        let mc = cs.reduce(0, +) / Double(cs.count), mf = fs.reduce(0, +) / Double(fs.count)
        print(String(format: "flipper shots: classic mean %.2f px/step, classic feel %.2f px/step (n %d)", mc, mf, cs.count))
        XCTAssertEqual(mf / mc, 1, accuracy: 0.15)
    }

    /// Full games with the rules in enhanced physics reach game over with the rules firing
    /// (sensor dispatches, score, sounds), on EP1 and EP10 (all 13 with EP_ENHANCED_GAMES=1). The
    /// player is `AutoPlayer` plus a rescue flip/nudge for a ball at rest outside the lane
    /// (`EnhancedValidation.autoplay`); the first of three plunge strengths that ends the game counts.
    func testAutoplayGamesEnhanced() throws {
        let tables = Self.env["EP_ENHANCED_GAMES"] == "1" ? Array(1...13) : [1, 10]
        var ran = 0
        for n in tables {
            guard let classicE = try? rulesEngine(n) else { continue }
            let cr = EnhancedValidation.autoplay(engine: classicE, frames: 30_000)
            let crate = Double(cr.sensorDispatches) / Double(max(1, cr.report.frames))
            for cfg in [EnhancedPhysicsConfig.classicFeel, .modern] {
                var over = false
                for plunge in [45, 30, 60] where !over {
                    let e = try rulesEngine(n)
                    let m = EnhancedPhysics.install(on: e, config: cfg)
                    let g = EnhancedValidation.autoplay(engine: e, frames: 30_000, plungeFrames: plunge)
                    let r = g.report
                    let rate = Double(g.sensorDispatches) / Double(max(1, r.frames))
                    print(String(format: "EP%d %@ plunge %d: frames %d (classic %d), score %d, sensors/frame %.2f (classic %.2f), distinct %d (classic %d), sounds %d, drains %d, rescues %d/%d, gameOver %@",
                                 n, cfg.preset.rawValue, plunge, r.frames, cr.report.frames, r.score, rate, crate, g.distinctSensors,
                                 cr.distinctSensors, r.soundEvents, r.drains, g.rescueFlips, g.rescueNudges, r.gameOver ? "yes" : "no"))
                    XCTAssertEqual(r.ruleFaults, [], "EP\(n) \(cfg.preset)")
                    XCTAssertEqual(m.stats.nanResets, 0)
                    XCTAssertGreaterThan(r.soundEvents, 0, "EP\(n) \(cfg.preset)")
                    XCTAssertGreaterThan(g.sensorDispatches, 0, "EP\(n) \(cfg.preset): no sensor fired")
                    XCTAssertGreaterThan(rate, crate * 0.2, "EP\(n) \(cfg.preset): sensors fire far less than in classic")
                    over = r.gameOver && r.drains >= 3 && r.score > 0
                }
                XCTAssertTrue(over, "EP\(n) \(cfg.preset): no game reached game over")
                ran += 1
            }
        }
        if ran == 0 { throw XCTSkip("no tables with rules") }
    }
}
