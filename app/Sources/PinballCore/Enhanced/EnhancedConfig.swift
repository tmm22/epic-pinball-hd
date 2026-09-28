import Foundation

/// Tunables of the enhanced ball physics (`EnhancedPhysics`). Units: pixels of the 320x400 table
/// and *classic physics steps* (1 step = 1 / (59.94 x 3) s = 5.56 ms), so velocities are in
/// px/step like the original's `v / 128`.
///
/// Two presets: `classicFeel` (fitted to the classic engine, see docs/enhanced/physics.md) and
/// `modern` (plain physically based restitution/friction, livelier flippers).
public struct EnhancedPhysicsConfig: Sendable, Equatable, Codable {
    public enum Preset: String, Sendable, Codable, CaseIterable {
        case classicFeel
        case modern
    }

    /// How a static wall changes the ball's velocity on impact.
    public enum WallResponse: String, Sendable, Codable {
        /// The original's reflection maths (rank-one impulse with the 16-vs-64 y bias and its
        /// elliptical normal table), evaluated in floating point for the smooth wall angle.
        case classicMap
        /// Normal restitution `wallRestitution` and Coulomb friction `wallFriction` along the
        /// smooth normal.
        case restitution
    }

    public var preset: Preset
    /// Substeps per classic physics step (8 -> 1438.6 Hz, 10 -> 1798 Hz). Deterministic fixed dt.
    public var substeps: Int
    /// Added to the ball's contact radius. The radius itself depends on the direction and comes
    /// from the table's probe ring (15 x 14 box, centre (7.5, 7.0)): the distance from the centre
    /// to a straight wall's pixel edge at which the original's first probe enters the wall, i.e.
    /// the ring's support function minus half a pixel (6.0 px up/down, 6.5 px left/right in
    /// every table). `EnhancedPhysics.contactRadius(normal:)`.
    public var contactPadding: Double
    /// Ball radius for ball-ball contacts.
    public var ballRadius: Double
    public var wallResponse: WallResponse
    public var wallRestitution: Double
    public var wallFriction: Double
    /// `classicMap` only: tangential speed lost per impact, `a + b * sin^2(incidence)` (fitted to the
    /// original, which re-contacts a grazing wall several times in its push-out loop).
    public var wallTangentialLoss: Double = 0
    public var wallGrazingLoss: Double = 0
    /// Approach speeds below this (px/step) end in resting contact instead of a bounce.
    public var restingSpeed: Double
    /// Flipper impulse: restitution of the ball relative to the flipper surface.
    public var flipperRestitution: Double
    public var flipperFriction: Double
    /// Scale on the flipper surface velocity used for the impulse (the geometry always moves at
    /// the original's 1 angle per step). 1 = purely kinematic.
    public var flipperGain: Double
    /// Scale on the kicker (bumper/slingshot) impulse `kick * |n|`.
    public var kickerScale: Double
    /// Kick along the table's elliptical normal (classic) or the smooth wall normal.
    public var kickerAlongTableNormal: Bool
    /// Restitution of kicker rubber for the incoming normal velocity (classic: 0, the kick is
    /// added to the incoming velocity).
    public var kickerRestitution: Double
    public var ballBallRestitution: Double
    /// Per-axis motion caps in px/step (classic: the table's step caps, the original moves at most
    /// that many pixels per step). nil = use `speedCap` on the magnitude only.
    public var classicAxisCaps: Bool
    /// Magnitude cap on the velocity (px/step), a safety net in both presets.
    public var speedCap: Double
    /// Fraction of speed lost per classic step while rolling on the playfield (0 = none, classic).
    public var rollingDrag: Double
    /// Scale on the per-frame gravity the rules/main loop add (classic: 1).
    public var gravityScale: Double
    /// Ball search (what real machines do for a stuck ball): a ball at rest for `ballSearchSeconds`
    /// outside the plunger lane, not on a flipper (cradling is fine), not held by rule code and not
    /// tilted gets a `ballSearchKick` px/step kick away from what it rests on. 0 = off. The original
    /// has nooks a ball can settle in (a flipper pivot notch, EP12's upper-left ledge) and rattles
    /// there; the smooth ball comes to a true rest.
    public var ballSearchSeconds: Double = 3
    public var ballSearchKick: Double = 2.5
    /// Model ball spin (rolling contact couples spin and tangential velocity).
    public var spin: Bool
    /// Spin coupling at contacts (0..1): fraction of the slip removed per impact.
    public var spinCoupling: Double

    public static let classicFeel = EnhancedPhysicsConfig(
        preset: .classicFeel, substeps: 8, contactPadding: 0, ballRadius: 7.0,
        wallResponse: .classicMap, wallRestitution: 0.18, wallFriction: 0,
        restingSpeed: 0.06, flipperRestitution: 0.25, flipperFriction: 0.0, flipperGain: 1.3,
        kickerScale: 1.0, kickerAlongTableNormal: true, kickerRestitution: 0,
        ballBallRestitution: 0.45, classicAxisCaps: true, speedCap: 10,
        rollingDrag: 0, gravityScale: 1, spin: false, spinCoupling: 0)

    public static let modern = EnhancedPhysicsConfig(
        preset: .modern, substeps: 10, contactPadding: 0, ballRadius: 7.0,
        wallResponse: .restitution, wallRestitution: 0.42, wallFriction: 0.08,
        restingSpeed: 0.06, flipperRestitution: 0.45, flipperFriction: 0.10, flipperGain: 1.35,
        kickerScale: 0.85, kickerAlongTableNormal: false, kickerRestitution: 0.3,
        ballBallRestitution: 0.85, classicAxisCaps: false, speedCap: 7.0,
        rollingDrag: 0.0004, gravityScale: 1, spin: true, spinCoupling: 0.3)

    public static func preset(_ p: Preset) -> EnhancedPhysicsConfig { p == .classicFeel ? classicFeel : modern }

    /// Substep rate in Hz for a table running `frameHz` frames of `stepsPerFrame` steps.
    public func substepHz(frameHz: Double = 59.94, stepsPerFrame: Int = 3) -> Double {
        frameHz * Double(stepsPerFrame * max(1, substeps))
    }
}
