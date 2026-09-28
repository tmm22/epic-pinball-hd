import Foundation

/// The hook through which `ClassicEngine` runs its ball physics.
///
/// `ClassicEngine.ballPhysics == nil` (the default) runs the original integer engine directly
/// (`physicsStep()` and the main loop's integer gravity add), bit-exact with the original code.
/// An installed model replaces both; everything else (main-loop order, rules, timers, lamps,
/// sensor scan, drain/serve, plunger, nudge/tilt, flipper angles and outlines) still runs in the
/// engine on the original 59.94 Hz frame cadence and reads the ball through `ClassicEngine.balls`,
/// which the model keeps in sync (integer position + 1/128 accumulators + 1/128 px/step
/// velocity) after every step.
public protocol BallPhysics: AnyObject {
    /// One physics step (1/`stepsPerFrame` of a frame) in place of `ClassicEngine.physicsStep()`.
    /// Must call `engine.flipperUpdate()` once (the original does it at the end of every step),
    /// and finish with `engine.finishExternalStep(_:)`.
    func step(_ engine: ClassicEngine)

    /// The main loop's gravity for ball `i` this frame (the original's `vy += g` in
    /// gravity_and_objects, in 1/128 px/step, already including the extra-gravity terms and only
    /// called when the original would add it). Return `true` if the model takes it over, `false`
    /// to let the engine add it to `vy` itself.
    func frameGravity(_ engine: ClassicEngine, ball i: Int, amount: Int16) -> Bool
}

/// The classic integer engine as a `BallPhysics` (identical to having no model installed).
public final class ClassicBallPhysics: BallPhysics {
    public init() {}
    public func step(_ engine: ClassicEngine) { engine.physicsStep() }
    public func frameGravity(_ engine: ClassicEngine, ball i: Int, amount: Int16) -> Bool { false }
}
