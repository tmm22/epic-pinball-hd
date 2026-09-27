import Foundation

// Coordinate system used throughout PinballCore: table pixels of the 320x400
// playfield, origin at the top-left, +x right, +y DOWN (towards the flippers).

public typealias Vec2 = SIMD2<Double>

/// How the simulation is presented / integrated.
public enum SimulationMode: String, Sendable, CaseIterable {
    /// Bit-exact original engine at 59.94 frames/s; the ball is drawn at its integer
    /// position like the original.
    case classic
    /// Hook for a smoothed mode. Physics is still the classic integer engine (so it
    /// stays deterministic and comparable); only presentation differs: the ball is drawn
    /// at a sub-pixel position interpolated between frames. Float sub-stepping or other
    /// "feel" changes belong here and must never touch `ClassicEngine`.
    case enhanced
}

/// Real-time driver: turns wall-clock time into whole original frames (3 physics
/// steps each) and holds the per-frame input.
public final class GameSimulation {
    public let engine: ClassicEngine
    public var mode: SimulationMode
    /// Buttons currently held (sampled once per original frame).
    public var input: FrameInput = []
    public private(set) var accumulator: Double = 0
    /// Upper bound on real time consumed per `advance` call (no catch-up spiral).
    public var maxFrameTime: Double = 0.1
    /// Ball 0 position (x + acc/128, y + acc/128) before and after the last frame.
    public private(set) var previousBall: Vec2
    public private(set) var currentBall: Vec2

    public var frameDuration: Double { 1.0 / engine.data.timing.frameHz }

    public init(engine: ClassicEngine, mode: SimulationMode = .classic, options: RulesOptions = RulesOptions()) {
        self.engine = engine
        self.mode = mode
        if engine.rules != nil {
            engine.startGame(options: options)   // table rules in full mode (ClassicEngine+Rules.swift)
        } else {
            engine.resetToRest()
            for i in engine.balls.indices { engine.balls[i].active = 0 }
            engine.serveBall()
        }
        let p = Self.subpixel(engine.balls[0])
        previousBall = p
        currentBall = p
    }

    static func subpixel(_ b: BallState) -> Vec2 {
        Vec2(Double(b.x) + Double(b.accx) / 128, Double(b.y) + Double(b.accy) / 128)
    }

    /// Consumes real time; returns the number of original frames executed.
    @discardableResult
    public func advance(by realTime: Double) -> Int {
        accumulator += min(max(realTime, 0), maxFrameTime)
        let h = frameDuration
        var n = 0
        while accumulator + 1e-9 >= h {
            stepFrame()
            accumulator -= h
            n += 1
        }
        accumulator = max(accumulator, 0)
        return n
    }

    /// Per-frame input source (e.g. `AutoPlayer`); when set it replaces `input` for every frame.
    public var inputProvider: ((ClassicEngine) -> FrameInput)?

    /// Runs exactly one original frame with the current input.
    public func stepFrame() {
        previousBall = Self.subpixel(engine.balls[0])
        engine.input = inputProvider.map { $0(engine) } ?? input
        engine.runFrame()
        currentBall = Self.subpixel(engine.balls[0])
    }

    /// A new game with the attached rules (full mode), as at start-up.
    public func newGame(options: RulesOptions = RulesOptions()) {
        engine.startGame(options: options)
        _ = engine.takePresentation()   // drop the previous game's queued events
        accumulator = 0
        previousBall = Self.subpixel(engine.balls[0])
        currentBall = previousBall
    }

    /// New ball at the plunger (the original does this itself after a drain).
    public func resetBall() {
        for i in 1..<5 { engine.balls[i].active = 0 }
        engine.balls[0] = BallState()
        engine.plungerCharge = 0
        engine.serveBall()
        previousBall = Self.subpixel(engine.balls[0])
        currentBall = previousBall
    }

    /// Everything to present since the previous call (sound events of all frames run in between
    /// are kept, in order). See `RulesRuntime` for the field mapping.
    public func takePresentation() -> PresentationState { engine.takePresentation() }

    /// Top-left of ball 0's 15x14 box for drawing (integer in classic mode).
    public var renderBallTopLeft: Vec2 {
        let b = engine.balls[0]
        switch mode {
        case .classic:
            return Vec2(Double(b.x), Double(b.y))
        case .enhanced:
            let a = min(max(accumulator / frameDuration, 0), 1)
            return previousBall + (currentBall - previousBall) * a
        }
    }

    public var ballVisible: Bool { engine.balls[0].active != 0 }

    private var capsuleCache: [[(Vec2, Vec2)?]] = []

    /// Procedural fallback shape for flipper `i` at `angle` (cached; derived from its outline).
    public func flipperCapsule(flipper i: Int, angle: Int) -> (Vec2, Vec2) {
        if capsuleCache.isEmpty { capsuleCache = engine.data.flippers.map { _ in Array(repeating: nil, count: 10) } }
        if let c = capsuleCache[i][angle] { return c }
        let c = SceneState.capsule(outline: engine.data.flippers[i].positions[angle])
        capsuleCache[i][angle] = c
        return c
    }
}
