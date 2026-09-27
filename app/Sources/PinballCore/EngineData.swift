import Foundation

/// Everything the classic engine needs that comes from the game, decoded from
/// `extracted/tables/EP<n>/engine.json` (written by `tools/export_engine_data.py`
/// from the user's own EXE). Nothing in here is compiled into the app.
///
/// Field names follow the JSON (snake_case converted to camelCase).
public struct EngineData: Decodable, Sendable {
    public static let formatName = "epic-pinball-engine"
    public static let supportedVersion = 1

    public var format: String
    public var version: Int
    public var table: Int
    public var params: Params
    public var integration: Integration
    public var gravity: Gravity
    public var probeRing: ProbeRing
    /// 48 `(t0, t1)` pairs; the velocity normal for direction k is `(-t0, t1)` at index k-1.
    public var normals: [[Int]]
    /// 48 `(p0, p1)` pairs: `x -= p0; y += p1`.
    public var pushout: [[Int]]
    public var wall: ClassTable
    public var occlusion: OcclusionTable
    public var kicker: Kicker
    public var collision: Collision
    public var flipperKick: FlipperKick
    public var nudgeImpulse: NudgeImpulse
    public var flipperGroups: [FlipperGroup]
    public var flippers: [Flipper]
    public var flipperMap: FlipperMap
    /// Colour written over the previous outline (0x2A in every table).
    public var flipperEraseValue: Int
    public var plunger: Plunger
    public var serve: Serve
    public var drainY: Int
    public var nudge: Nudge
    public var ballBall: BallBall
    public var ball: BallSprite
    public var sensors: Sensors
    public var timing: Timing
    public var fallbacks: [String]
    /// The 5 ball slots as stored in the EXE's data image (inactive slots keep stale values).
    public var ballSlotsInitial: [BallSlot]?

    public struct BallSlot: Decodable, Sendable {
        public var active: Int, x: Int, y: Int, vx: Int, vy: Int, accx: Int, accy: Int, layer: Int
    }

    public struct Params: Decodable, Sendable {
        public var names: [String]
        public var values: [Int]
    }

    public struct Integration: Decodable, Sendable {
        public struct Caps: Decodable, Sendable { public var xPos: Int, xNeg: Int, yPos: Int, yNeg: Int }
        public var stepCap: Caps
        public var accClampPos: Int
        public var accClampNeg: Int
        public var minX: Int
        public var minY: Int
        public var yReset: Int
        public var collisionYLimit: Int
    }

    public struct Gravity: Decodable, Sendable {
        public var cutoff: Int
        public var extraVar: String?
        public var extraInitial: Int
    }

    public struct ProbeRing: Decodable, Sendable {
        /// `dy*320+dx` from the ball's top-left, index k-1 for probe k = 1...48.
        public var offsets: [Int]
    }

    public struct ClassTable: Decodable, Sendable {
        public var codes: [String]
        /// Per level (0 table, 1 ramp): class code per palette index (256 entries).
        public var lut: [[Int]]
    }

    public struct OcclusionTable: Decodable, Sendable {
        public var codes: [String]
        public var lut: [[Int]]
        public var ranges: [[Int]]?
    }

    public struct Kicker: Decodable, Sendable {
        public var cooldownFrames: Int
        public var tiltDisables: Bool
    }

    public struct Collision: Decodable, Sendable {
        public var flipperContactSplitX: Int
    }

    public struct FlipperKick: Decodable, Sendable {
        public struct Ranges: Decodable, Sendable { public var lo: Int, sideMax: Int, topMax: Int, sideIndex: Int, tipIndex: Int }
        public var ranges: Ranges
        public var vyZeroSide: Int
        public var vyZeroTop: Int
        public var fx: [Int]
        public var fy: [Int]
    }

    public struct NudgeImpulse: Decodable, Sendable {
        public var minTimer: Int, dirMin: Int, dirMax: Int, vyShift: Int, vx: Int
    }

    public struct FlipperGroup: Decodable, Sendable {
        public var key: String
        public var value: Int
        public var restAngle: Int
        public var initAngle: Int
        public var initDrawn: Int
    }

    public struct Flipper: Decodable, Sendable {
        public struct Sprite: Decodable, Sendable {
            public var frames: [String]
            public var x: Int, y: Int, w: Int, h: Int
        }
        public var group: Int
        /// Ten outlines (angle 0 = up ... 9 = rest) as linear offsets into the 320x400 buffer.
        public var positions: [[Int]]
        public var sprite: Sprite?
    }

    public struct FlipperMap: Decodable, Sendable {
        public var contact1Moving: Int, contact2Moving: Int, contact1Angle: Int, contact2Angle: Int
    }

    public struct Plunger: Decodable, Sendable {
        public var step: Int
        public var max: Int
        /// "ja" (add while charge <= max) or "jae" (add while charge < max).
        public var cmp: String
        public var laneMinX: Int
        public var laneMinY: Int
    }

    public struct Serve: Decodable, Sendable { public var x: Int, y: Int, delay: Int }

    public struct Nudge: Decodable, Sendable {
        public var tiltAdd: Int, frames: Int, tiltThreshold: Int, laneMinX: Int, laneMaxY: Int
    }

    public struct BallBall: Decodable, Sendable {
        public var divisor: Int
        public var maxDx: Int
        public var maxDy: Int
    }

    public struct BallSprite: Decodable, Sendable {
        public var w: Int
        public var h: Int
        public var transparent: Int
        public var pixels: [UInt8]?
    }

    public struct Sensors: Decodable, Sendable {
        public var levels: [[String: SensorHandler]]
        /// Palette index that fires even while the event lockout is set (EP1 0xFE).
        public var alwaysFiresValue: Int
    }

    public struct SensorHandler: Decodable, Sendable {
        public var always: Bool?
        public var ops: [SensorOp]
    }

    public struct Timing: Decodable, Sendable {
        public var frameHz: Double
        public var stepsPerFrame: Int
    }

    // MARK: loading

    public static func decode(_ data: Data) throws -> EngineData {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let e: EngineData
        do { e = try dec.decode(EngineData.self, from: data) } catch {
            throw EngineDataError.decode(String(describing: error))
        }
        try e.validate()
        return e
    }

    public static func load(contentsOf url: URL) throws -> EngineData {
        try decode(Data(contentsOf: url))
    }

    /// Structural checks so the engine can index without bounds surprises.
    public func validate() throws {
        func req(_ ok: Bool, _ why: String) throws { if !ok { throw EngineDataError.invalid(why) } }
        try req(format == Self.formatName, "format is '\(format)', expected '\(Self.formatName)'")
        try req(version == Self.supportedVersion, "version \(version) is not supported (need \(Self.supportedVersion))")
        try req(params.values.count == 10, "params.values must have 10 entries")
        try req(probeRing.offsets.count == 48, "probe_ring.offsets must have 48 entries")
        try req(normals.count == 48 && normals.allSatisfy { $0.count == 2 }, "normals must be 48 pairs")
        try req(pushout.count == 48 && pushout.allSatisfy { $0.count == 2 }, "pushout must be 48 pairs")
        try req(wall.lut.count == 2 && wall.lut.allSatisfy { $0.count == 256 }, "wall.lut must be 2 x 256")
        try req(occlusion.lut.count == 2 && occlusion.lut.allSatisfy { $0.count == 256 }, "occlusion.lut must be 2 x 256")
        try req(flipperKick.fx.count == 10 && flipperKick.fy.count == 10, "flipper_kick.fx/fy must have 10 entries")
        try req(!flipperGroups.isEmpty, "no flipper groups")
        for (i, f) in flippers.enumerated() {
            try req(flipperGroups.indices.contains(f.group), "flippers[\(i)].group out of range")
            try req(f.positions.count == 10, "flippers[\(i)] must have 10 positions")
        }
        for g in flipperGroups {
            try req((0...9).contains(g.initAngle) && (0...9).contains(g.initDrawn) && (0...9).contains(g.restAngle),
                    "flipper group angles must be 0...9")
        }
        for i in [flipperMap.contact1Moving, flipperMap.contact2Moving, flipperMap.contact1Angle, flipperMap.contact2Angle] {
            try req(flipperGroups.indices.contains(i), "flipper_map index \(i) out of range")
        }
        if let p = ball.pixels { try req(p.count == ball.w * ball.h, "ball.pixels must have w*h entries") }
        try req(sensors.levels.count == 2, "sensors.levels must have 2 entries")
        try req(ballBall.divisor != 0, "ball_ball.divisor must not be 0")
    }
}

/// A sensor handler operation (see `tools/export_engine_data.py`, `sensors()`).
public indirect enum SensorOp: Decodable, Sendable, Equatable {
    case set(variable: String, value: SensorExpr)
    /// `lhs cmp rhs` in `size` bits (b/ae/a/be unsigned, lt/ge/gt/le signed, eq/ne).
    case branch(lhs: SensorExpr, cmp: String, rhs: SensorExpr, size: Int, then: [SensorOp], else: [SensorOp])

    private enum Keys: String, CodingKey { case op, `var`, expr, lhs, cmp, rhs, size, then, `else` }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "set":
            self = .set(variable: try c.decode(String.self, forKey: .var), value: try c.decode(SensorExpr.self, forKey: .expr))
        case "if":
            self = .branch(lhs: try c.decode(SensorExpr.self, forKey: .lhs), cmp: try c.decode(String.self, forKey: .cmp),
                           rhs: try c.decode(SensorExpr.self, forKey: .rhs), size: try c.decode(Int.self, forKey: .size),
                           then: try c.decode([SensorOp].self, forKey: .then), else: try c.decode([SensorOp].self, forKey: .else))
        default:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown sensor op '\(op)'")
        }
    }
}

/// 16-bit expression over physics variables: `["const", n]`, `["var", name]`, `["neg", e]`,
/// `["add", a, b]`, `["mul", a, b]`, `["shl"|"shr"|"sar", a, b]`.
public indirect enum SensorExpr: Decodable, Sendable, Equatable {
    case constant(Int)
    case variable(String)
    case unary(String, SensorExpr)
    case binary(String, SensorExpr, SensorExpr)

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let tag = try c.decode(String.self)
        switch tag {
        case "const": self = .constant(try c.decode(Int.self))
        case "var": self = .variable(try c.decode(String.self))
        case "neg": self = .unary(tag, try c.decode(SensorExpr.self))
        case "add", "mul", "shl", "shr", "sar": self = .binary(tag, try c.decode(SensorExpr.self), try c.decode(SensorExpr.self))
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown expression '\(tag)'")
        }
    }
}

public enum EngineDataError: Error, CustomStringConvertible, Equatable {
    case decode(String)
    case invalid(String)

    public var description: String {
        switch self {
        case let .decode(s): return "engine.json could not be decoded: \(s)"
        case let .invalid(s): return "engine.json is invalid: \(s)"
        }
    }
}
