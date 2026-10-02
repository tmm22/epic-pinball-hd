import Foundation

// Coordinate system used throughout PinballCore: table pixels of the 320x400
// playfield, origin at the top-left, +x right, +y DOWN (towards the flippers).

public typealias Vec2 = SIMD2<Double>

/// How the simulation is *presented* (the physics is chosen separately with
/// `GameSimulation.physicsMode` / `GameSettings.physicsMode`).
public enum SimulationMode: String, Sendable, CaseIterable {
    /// The ball is drawn at its integer position like the original.
    case classic
    /// The ball is drawn at a sub-pixel position interpolated between frames. This does not
    /// change the physics: with `physicsMode == .classic` the engine stays the bit-exact integer
    /// engine; `physicsMode == .enhanced` installs `EnhancedPhysics` (Enhanced/).
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
    /// Ball 0 position (top-left of the box, `ballPosition(0)`: x + acc/128, y + acc/128, or the
    /// enhanced model's smooth position) before and after the last frame.
    public private(set) var previousBall: Vec2
    public private(set) var currentBall: Vec2
    /// The same per drawn slot (`drawnBallSlots`), nil while the slot is not in play.
    public private(set) var previousBalls: [Vec2?] = []
    public private(set) var currentBalls: [Vec2?] = []

    public var frameDuration: Double { 1.0 / engine.data.timing.frameHz }

    /// Ball physics: `.classic` = the original integer engine (bit-exact), `.enhanced` =
    /// `EnhancedPhysics` with `enhancedConfig`. Switching takes effect at the next step.
    public var physicsMode: GameSettings.PhysicsMode = .classic {
        didSet { if physicsMode != oldValue { installPhysics() } }
    }
    /// Tunables of the enhanced physics (applied to the installed model at the next step).
    public var enhancedConfig: EnhancedPhysicsConfig = .classicFeel {
        didSet { if enhancedConfig != oldValue, physicsMode == .enhanced { enhanced?.config = enhancedConfig } }
    }
    /// The installed enhanced model (nil in classic physics).
    public var enhanced: EnhancedPhysics? { engine.ballPhysics as? EnhancedPhysics }

    /// How many times a ball physics model was installed or removed (`installPhysics`): a switch
    /// enhanced -> classic -> enhanced between two frames leaves `physicsMode` as it was but installs
    /// a new model, which the replay recorder must see (Replay/Replay.swift).
    public private(set) var physicsInstalls = 0

    func installPhysics() {
        physicsInstalls &+= 1
        switch physicsMode {
        case .classic: EnhancedPhysics.uninstall(from: engine)
        case .enhanced: EnhancedPhysics.install(on: engine, config: enhancedConfig)
        }
    }

    public init(engine: ClassicEngine, mode: SimulationMode = .classic, options: RulesOptions = RulesOptions(),
                physics: GameSettings.PhysicsMode = .classic, enhancedConfig: EnhancedPhysicsConfig = .classicFeel) {
        self.engine = engine
        self.mode = mode
        self.physicsMode = physics
        self.enhancedConfig = enhancedConfig
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
        currentBalls = slotPositions()
        previousBalls = currentBalls
        // An enhanced model the caller installed on the engine stays (e.g. `AutoPlay.run` on it).
        if physics == .enhanced { installPhysics() } else if let m = engine.ballPhysics as? EnhancedPhysics {
            physicsMode = .enhanced
            self.enhancedConfig = m.config
        }
    }

    static func subpixel(_ b: BallState) -> Vec2 {
        Vec2(Double(b.x) + Double(b.accx) / 128, Double(b.y) + Double(b.accy) / 128)
    }

    /// Ball slots the original draws each frame: every active slot in its per-ball loop, in slot
    /// order (EP1 cs:11A7..1233 over 5 slots, EP9-13 over 3, e.g. EP10 cs:114F..11ED; each draw is
    /// ball_pixel_scan's blit, EP1 cs:171E). Verified with the harness: every active slot is blitted
    /// once per frame, slot 0 empty or not.
    public var drawnBallSlots: Int { min(engine.balls.count, engine.data.gravity.slots ?? 5) }

    /// Top-left of ball `i`'s box for drawing, at full precision: with enhanced physics the model's
    /// smooth centre (`EnhancedPhysics.ballCentre`), as long as the integer fields still hold its
    /// truncation (rules and the main loop move balls between steps: then the fields win); else
    /// x + acc/128. Classic physics: always x + acc/128.
    public func ballPosition(_ i: Int) -> Vec2 {
        let q = Self.subpixel(engine.balls[i])
        if let m = enhanced, let c = m.ballCentre(i) {
            let t = c - m.centreOffset
            let eps = 1e-9, step = 1.0 / 128
            if t.x >= q.x - eps, t.x < q.x + step + eps, t.y >= q.y - eps, t.y < q.y + step + eps { return t }
        }
        return q
    }

    func slotPositions() -> [Vec2?] {
        (0..<drawnBallSlots).map { engine.balls[$0].active != 0 ? ballPosition($0) : nil }
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

    /// Called once per frame with the frame's input, just before the frame runs (replay recording,
    /// Replay/Replay.swift). Nil = nothing is observed.
    public var frameObserver: ((GameSimulation, FrameInput) -> Void)?

    /// Runs exactly one original frame with the current input.
    public func stepFrame() {
        previousBall = ballPosition(0)
        previousBalls = slotPositions()
        engine.input = inputProvider.map { $0(engine) } ?? input
        frameObserver?(self, engine.input)
        engine.runFrame()
        currentBall = ballPosition(0)
        currentBalls = slotPositions()
    }

    /// A new game with the attached rules (full mode), as at start-up. With `powerOn` (the engine's
    /// snapshot taken before its first game) the engine, rules and MiniX86 first go back to that
    /// state and the ball physics model is installed afresh after the start, exactly the order of a
    /// newly loaded table (`init`), so a replay of this game can start from a new engine.
    public func newGame(options: RulesOptions = RulesOptions(), powerOn: EngineSnapshot?) {
        guard let p = powerOn else { newGame(options: options); return }
        engine.restore(p)
        newGame(options: options)
        installPhysics()
    }

    /// A new game with the attached rules (full mode), as at start-up.
    public func newGame(options: RulesOptions = RulesOptions()) {
        engine.startGame(options: options)
        _ = engine.takePresentation()   // drop the previous game's queued events
        accumulator = 0
        previousBall = Self.subpixel(engine.balls[0])
        currentBall = previousBall
        currentBalls = slotPositions()
        previousBalls = currentBalls
    }

    /// New ball at the plunger (the original does this itself after a drain).
    public func resetBall() {
        for i in 1..<5 { engine.balls[i].active = 0 }
        engine.balls[0] = BallState()
        engine.plungerCharge = 0
        engine.serveBall()
        previousBall = Self.subpixel(engine.balls[0])
        currentBall = previousBall
        currentBalls = slotPositions()
        previousBalls = currentBalls
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

    /// The same for any slot (slot 0: `renderBallTopLeft`); a slot that just came into play is drawn
    /// where it is.
    public func renderBallTopLeft(_ i: Int) -> Vec2 {
        if i == 0 { return renderBallTopLeft }
        let b = engine.balls[i]
        guard mode == .enhanced, currentBalls.indices.contains(i), let p1 = currentBalls[i] else {
            return Vec2(Double(b.x), Double(b.y))
        }
        guard let p0 = previousBalls[i] else { return p1 }
        let a = min(max(accumulator / frameDuration, 0), 1)
        return p0 + (p1 - p0) * a
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

// MARK: - Save states (Replay/SimulationSnapshot.swift)

extension GameSimulation {
    /// The driver's own fields (physics choice, held input, real-time accumulator, interpolation).
    public struct State {
        var physicsMode: GameSettings.PhysicsMode
        var enhancedConfig: EnhancedPhysicsConfig
        var input: FrameInput
        var accumulator: Double
        var previousBall: Vec2, currentBall: Vec2
    }

    public func saveState() -> State {
        State(physicsMode: physicsMode, enhancedConfig: enhancedConfig, input: input, accumulator: accumulator,
              previousBall: previousBall, currentBall: currentBall)
    }

    /// Restores the driver's fields. A physics switch installs a fresh model here; the engine
    /// snapshot restored after this (`restore(_:)` in SimulationSnapshot.swift) fills it.
    func restoreState(_ s: State) {
        physicsMode = s.physicsMode
        enhancedConfig = s.enhancedConfig
        input = s.input; accumulator = s.accumulator; previousBall = s.previousBall; currentBall = s.currentBall
    }

    /// Installs the model for `physicsMode` afresh (a new `EnhancedPhysics`, or none in classic).
    public func reinstallPhysics() { installPhysics() }
}
