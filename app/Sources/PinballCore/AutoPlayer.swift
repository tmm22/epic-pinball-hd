import Foundation

/// A deterministic stand-in for a player, for headless games (`EpicPinball --autoplay N`) and the
/// per-table smoke tests: it plunges a ball that waits in the lane (or, on EP8, launches when no ball
/// is in play), and flips a flipper when a ball falls into the flipper area on that side. It only sets
/// `FrameInput` bits, exactly like the keyboard, so everything else is the real engine and rules.
public struct AutoPlayer: Sendable {
    /// Frames the plunger is held before release (EP1 charges 12/frame up to 700).
    public var plungeFrames = 45
    /// Frames a flipper stays up after a trigger.
    public var flipFrames = 10
    private var plungeHeld = 0
    private var cooldown = 0
    private var leftHeld = 0
    private var rightHeld = 0
    private let flipperTopY: Int16
    private let splitX: Int16

    public init(engine: ClassicEngine) {
        // Flipper outlines at rest: the ball's box reaches them from about 40 px above their top row.
        let d = engine.data
        var top = Int.max
        for f in d.flippers {
            let g = d.flipperGroups[f.group]
            for o in f.positions[g.restAngle] where o >= 64000 { top = min(top, o / TableGeometry.width) }
        }
        flipperTopY = Int16(top == Int.max ? 330 : max(0, top - 40))
        splitX = Int16(truncatingIfNeeded: d.collision.flipperContactSplitX)
    }

    /// Input for the next frame.
    public mutating func input(for e: ClassicEngine) -> FrameInput {
        var i: FrameInput = []
        let d = e.data
        let b0 = e.balls[0]
        let launchFlag = d.plunger.kind == "launch_flag"
        let inLane: Bool
        if launchFlag {
            inLane = !e.balls.prefix(3).contains { $0.active == 1 }
        } else {
            inLane = b0.active != 0
                && UInt16(bitPattern: b0.x) >= UInt16(truncatingIfNeeded: d.plunger.laneMinX)
                && UInt16(bitPattern: b0.y) >= UInt16(truncatingIfNeeded: d.plunger.laneMinY)
        }
        if cooldown > 0 { cooldown -= 1 }
        if plungeHeld > 0 {
            plungeHeld -= 1
            if plungeHeld > 0 { i.insert(.plunger) } else { cooldown = 30 }
        } else if inLane && cooldown == 0 && e.serveDelay == 0 {
            plungeHeld = plungeFrames
            i.insert(.plunger)
        }
        // Flip at a ball falling into the flipper area (not at one resting on a raised flipper), then
        // let the flipper fall back for a while so a cradled ball rolls off.
        for b in e.balls where b.active == 1 && b.y >= flipperTopY && b.y < 400 && b.vy > 40 {
            if b.x <= splitX { if leftHeld == 0 { leftHeld = flipFrames + 20 } } else if rightHeld == 0 { rightHeld = flipFrames + 20 }
        }
        if leftHeld > 0 { leftHeld -= 1; if leftHeld >= 20 { i.insert(.leftFlipper) } }
        if rightHeld > 0 { rightHeld -= 1; if rightHeld >= 20 { i.insert(.rightFlipper) } }
        return i
    }
}

/// Result of a headless game (`AutoPlay.run`).
public struct AutoPlayReport: Sendable, Codable {
    public var table: Int
    public var frames: Int
    public var rules: Bool
    public var rulesLoadError: String?
    public var score: UInt32
    public var ballNumber: Int
    public var drains: Int
    public var gameOver: Bool
    public var soundEvents: Int
    public var messages: Int
    public var lampsLit: Int
    public var loopGuardTrips: Int
    public var divideFaults: Int
    public var ruleWarnings: [String]
    public var ruleFaults: [String]
}

public enum AutoPlay {
    /// Starts a game on `engine` (full rules when attached) and plays `frames` frames with the
    /// `AutoPlayer`. Stops early at game over.
    public static func run(engine e: ClassicEngine, frames: Int, options: RulesOptions = RulesOptions()) -> AutoPlayReport {
        let sim = GameSimulation(engine: e, options: options)
        var player = AutoPlayer(engine: e)
        var sounds = 0, messages = 0, drains = 0
        var last = PresentationState()
        var wasServing = e.serveDelay != 0
        var n = 0
        while n < frames {
            sim.input = player.input(for: e)
            sim.stepFrame()
            n += 1
            let s = sim.takePresentation()
            sounds += s.soundEvents.count
            if s.message != nil && last.message?.exeOffset != s.message?.exeOffset { messages += 1 }
            last = s
            // a serve (drain_check found every slot empty) or, on EP8, all balls gone
            let serving = e.serveDelay != 0
            if serving && !wasServing { drains += 1 }
            wasServing = serving
            if s.gameOver { break }
        }
        let r = e.rules
        return AutoPlayReport(table: e.data.table, frames: n, rules: r != nil, rulesLoadError: e.rulesLoadError,
                              score: last.scores.first ?? 0, ballNumber: last.ballNumber, drains: drains,
                              gameOver: last.gameOver, soundEvents: sounds, messages: messages,
                              lampsLit: last.lamps.filter { $0 }.count, loopGuardTrips: e.loopGuardTrips,
                              divideFaults: e.divideFaults, ruleWarnings: r?.warnings ?? [],
                              ruleFaults: Array(Set(r?.machine.faults ?? [])).sorted())
    }
}
