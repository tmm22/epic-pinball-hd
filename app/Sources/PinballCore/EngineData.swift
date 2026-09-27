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
    /// Code addresses of the patterns the exporter matched (hex cs offsets by name).
    public var foundAt: [String: String]?
    /// The 5 ball slots as stored in the EXE's data image (inactive slots keep stale values).
    public var ballSlotsInitial: [BallSlot]?
    /// drain_check variants (tools/engine_overrides/EPn.json; nil = the EP1 loop over 5 slots).
    public var drain: Drain?
    /// Main-loop collision-buffer gates driven by ball position only (EP6 cs:0979, EP9 cs:0550).
    public var gates: [Gate]?

    public struct Drain: Decodable, Sendable {
        /// A multiball hand-over when a slot drains (EP2 cs:0A63..0AA3, EP4 cs:0A89..0ADA).
        public struct Transfer: Decodable, Sendable {
            public var fromSlots: [Int]
            public var toSlot: Int
            public var copies: [String]
            /// Only while this DS byte is 1 (EP4 ds:08FC, rule state); cleared with `ruleVarsCleared` first.
            public var requiresFlagVar: String?
            public var ruleVarsCleared: [String]?
            /// EP2: DS byte set to 0 after a transfer and when slots 1 and 2 are both inactive.
            public var ruleVarCleared: String?
        }
        /// Slots scanned, highest first (EP3: 2, EP8: 3); default 5.
        public var slots: Int?
        /// Serve when this many scanned slots are empty; null = never serve (EP8). Default = slots.
        public var serveWhenEmpty: Int?
        public var serveWhenEmptyPresent: Bool { _serveNull != true }
        var _serveNull: Bool?
        public var clearLayerOnDrain: Bool?
        public var transfer: Transfer?
        /// Per drained slot, DS writes (EP8 cs:0A4F..0A8A): `[addr, width, value]` or nested `{if, then, else}`.
        public var onDrainOps: [DSOp]?

        enum CodingKeys: String, CodingKey { case slots, serveWhenEmpty, clearLayerOnDrain, transfer, onDrainOps }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            slots = try c.decodeIfPresent(Int.self, forKey: .slots)
            if c.contains(.serveWhenEmpty) {
                if try c.decodeNil(forKey: .serveWhenEmpty) { _serveNull = true } else { serveWhenEmpty = try c.decode(Int.self, forKey: .serveWhenEmpty) }
            }
            clearLayerOnDrain = try c.decodeIfPresent(Bool.self, forKey: .clearLayerOnDrain)
            transfer = try c.decodeIfPresent(Transfer.self, forKey: .transfer)
            onDrainOps = try c.decodeIfPresent([DSOp].self, forKey: .onDrainOps)
        }
    }

    /// A conditional DS write list: `[addr, width, value]` or `{"if": [addr, width, value], "then": [...], "else": [...]}`.
    public indirect enum DSOp: Decodable, Sendable {
        case write(addr: Int, width: Int, value: Int)
        case branch(addr: Int, width: Int, equals: Int, then: [DSOp], else: [DSOp])
        enum K: String, CodingKey { case `if`, then, `else` }
        public init(from d: Decoder) throws {
            if var u = try? d.unkeyedContainer() {
                let a = try u.decode(String.self), w = try u.decode(Int.self), v = try u.decode(Int.self)
                self = .write(addr: Int(a.dropFirst(2), radix: 16) ?? 0, width: w, value: v)
                return
            }
            let c = try d.container(keyedBy: K.self)
            var u = try c.nestedUnkeyedContainer(forKey: .if)
            let a = try u.decode(String.self), w = try u.decode(Int.self), v = try u.decode(Int.self)
            self = .branch(addr: Int(a.dropFirst(2), radix: 16) ?? 0, width: w, equals: v,
                           then: try c.decodeIfPresent([DSOp].self, forKey: .then) ?? [],
                           else: try c.decodeIfPresent([DSOp].self, forKey: .else) ?? [])
        }
    }

    public struct Gate: Decodable, Sendable {
        public struct PosTest: Decodable, Sendable {
            public var flagNe: Int?
            public var ball: Int?
            public var xLe: Int?
            public var xGe: Int?
        }
        public struct Pixels: Decodable, Sendable {
            public var half: Int?
            public var offsets: [Int]?
        }
        public struct SideVar: Decodable, Sendable { public var `var`: String; public var closed: Int; public var open: Int }
        public var id: String
        public var kind: String
        public var flagVar: String?
        public var closeIf: PosTest?
        public var openIf: PosTest?
        public var valueClosed: Int?
        public var valueOpen: Int?
        public var sideVar: SideVar?
        /// One pixel list (ball-position gates); rule-timer gates have a list of them and run as rules glue.
        public var pixelList: Pixels?
        enum CodingKeys: String, CodingKey { case id, kind, flagVar, closeIf, openIf, valueClosed, valueOpen, sideVar, pixels }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(String.self, forKey: .kind)
            flagVar = try c.decodeIfPresent(String.self, forKey: .flagVar)
            closeIf = try c.decodeIfPresent(PosTest.self, forKey: .closeIf)
            openIf = try c.decodeIfPresent(PosTest.self, forKey: .openIf)
            valueClosed = try c.decodeIfPresent(Int.self, forKey: .valueClosed)
            valueOpen = try c.decodeIfPresent(Int.self, forKey: .valueOpen)
            sideVar = try c.decodeIfPresent(SideVar.self, forKey: .sideVar)
            pixelList = try? c.decodeIfPresent(Pixels.self, forKey: .pixels)
        }
    }

    public struct BallSlot: Decodable, Sendable {
        public var active: Int, x: Int, y: Int, vx: Int, vy: Int, accx: Int, accy: Int, layer: Int
    }

    public struct Params: Decodable, Sendable {
        public var names: [String]
        public var values: [Int]
        /// DS offset of the 10-word block (hex string), used to bind it for the rules interpreter.
        public var ds: String?
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
        /// Value stored when x < min_x (EP5 cs:1328 stores 0); default min_x.
        public var minXSet: Int?
        /// EP8 cs:17A8: (u16) x > max_x -> max_x, before the signed min_x test.
        public var maxX: Int?
    }

    public struct Gravity: Decodable, Sendable {
        public var cutoff: Int
        public var extraVar: String?
        public var extraInitial: Int
        public struct SlotBonus: Decodable, Sendable { public var slot: Int; public var add: Int }
        public var slotBonus: SlotBonus?
        /// Gravity terms after params.gravity: add/sub a DS word (EP9-13 subtract a second one).
        public struct Term: Decodable, Sendable { public var op: String; public var `var`: String?; public var initial: Int? }
        public var terms: [Term]?
        /// Ball slots the gravity/sensor loop visits (EP9-13: 3); default 5.
        public var slots: Int?
    }

    public struct ProbeRing: Decodable, Sendable {
        /// `dy*320+dx` from the ball's top-left, index k-1 for probe k = 1...48.
        public var offsets: [Int]
    }

    public struct ClassTable: Decodable, Sendable {
        public var codes: [String]
        /// Per level (0 table, 1 ramp): class code per palette index (256 entries).
        public var lut: [[Int]]
        /// EP8 cs:185D: the level-0 lower bound is the DS byte [level0_lo_var] (EBh / FFh at run time);
        /// indices below it are empty, the rest keep their class.
        public var level0LoVar: String?
        public var level0LoInitial: Int?
    }

    public struct OcclusionTable: Decodable, Sendable {
        public var codes: [String]
        public var lut: [[Int]]
        public var ranges: [[Int]]?
        /// EP8 cs:16AF: level-0 bounds from DS: v <= [front_max] in front, v <= [occludes_max]
        /// occludes the ball, v <= level0_sensor_max sensor, else in front.
        public struct Bounds: Decodable, Sendable { public var frontMax: String; public var occludesMax: String }
        public struct BoundsInitial: Decodable, Sendable { public var frontMax: Int; public var occludesMax: Int }
        public var level0BoundsVars: Bounds?
        public var level0BoundsInitial: BoundsInitial?
        public var level0SensorMax: Int?
    }

    public struct Kicker: Decodable, Sendable {
        public var cooldownFrames: Int
        public var tiltDisables: Bool
        // EP2 window / contact_on_fire, EP5/EP6 shared lockout, EP11-13 kick override
        public struct WindowTest: Decodable, Sendable { public var coord: String; public var noContactIf: String; public var value: Int }
        public struct KickConst: Decodable, Sendable { public var y: Int; public var kick: Int }
        public var activeMax: Int?
        public var window: [WindowTest]?
        public var coolingContact: Bool?
        public var contactOnFire: Bool?
        public var cooldownIsSensorLockout: Bool?
        public var cooldownSetWhenTilted: Bool?
        public var requiresLayer0: Bool?
        public var kickConstantWhenYAtLeast: KickConst?
        /// EP11-13 kicker_hit: kick = `kick` when (u16) y >= `minY` (unreachable in practice).
        public struct KickOverride: Decodable, Sendable { public var minY: Int?; public var kick: Int }
        public var kickOverride: KickOverride?
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
        /// Flipper contacts with (u16) y < side_min_y take the plain push-out (EP4 cs:1B9B, EP12 cs:19C3).
        public var sideMinY: Int?
        public var topMinY: Int?
        public struct UpperKick: Decodable, Sendable {
            public struct Side: Decodable, Sendable {
                public struct RuleTimer: Decodable, Sendable { public var `var`: String; public var size: Int; public var value: Int }
                public var angleGroup: Int, dx: Int, dy: Int
                public var vxSub: [Int], vySub: [Int]
                public var ruleTimer: RuleTimer?
            }
            /// Side chosen by (u16) x >= split_x (EP4); nil = always `right` (EP11-13).
            public var splitX: Int?
            public var right: Side
            public var left: Side?
        }
        public var upperKick: UpperKick?
    }

    public struct NudgeImpulse: Decodable, Sendable {
        public var minTimer: Int, dirMin: Int, dirMax: Int, vyShift: Int, vx: Int
        /// Slots that never get the impulse (EP3 cs:1A85: the captive ball).
        public var skipSlots: [Int]?
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
        /// false: the lane guard has no ball_layer test (EP2 cs:0BB4, EP5, EP6); default true.
        public var laneLayerTest: Bool?
        /// "charge" (lane plunger) or "launch_flag" (EP8 cs:0B62: no lane, the ball is placed on release).
        public var kind: String?
        public struct Launch: Decodable, Sendable { public var x: Int, y: Int, vx: Int, vy: Int }
        public var launch: Launch?
        public var lanePresent: Bool?
        /// EP8 cs:0B62..0C65 details (tools/engine_overrides/EP8.json).
        public struct LaunchBlock: Decodable, Sendable {
            public struct ServeDelay: Decodable, Sendable { public var `var`: String; public var opsAt1: [DSOp]? }
            public struct Message: Decodable, Sendable { public var bx: String; public var ax: Int; public var di: String }
            public var serveDelay: ServeDelay?
            public var releaseDsOps: [DSOp]?
            public var releaseMessage: Message?
            public var flagVar: String?
        }
        public var launchBlock: LaunchBlock?
        public var launchServeDelayVar: String? { launchBlock?.serveDelay?.var }
        /// EP8 launch flag word (plunger.launch_block.flag_var).
        public var launchFlagVar: String? { launchBlock?.flagVar }
    }

    public struct Serve: Decodable, Sendable {
        public var x: Int, y: Int, delay: Int
        public var vx: Int?
        /// Level byte stored for slot 0 (EP2 cs:0AFB: 1, EP7 cs:0A27: 0); nil = unchanged (EP1).
        public var layer: Int?
        /// false: the table has no serve code (EP8).
        public var present: Bool?
    }

    public struct Nudge: Decodable, Sendable {
        public var tiltAdd: Int, frames: Int, tiltThreshold: Int, laneMinX: Int, laneMaxY: Int
        /// false (EP8 cs:0E23): no plunger-lane exemption, but some ball in slots 0..2 must be active.
        public var laneTest: Bool?
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
        /// DS offsets (hex strings) of the physics variables the handlers use (`level`, `lockout`,
        /// `obj_x`, `ball_x.0`, ...), used to bind them for the rules interpreter.
        public var vars: [String: String]?
        /// DS offsets the engine owns (rule code must not keep private copies of them).
        public var forbiddenVars: [String]?
        /// "word": a sensor pixel fires only under a non-zero ball-sprite word (EP2 cs:184F).
        public var spriteMask: String?
        /// Lockout-bypass value found in this table's scan; `alwaysFiresKnown` and nil = none (EP2, EP5, ...).
        public var alwaysFires: Int?
        public var alwaysFiresKnown = false
        /// EP9-13: one sensor lockout per ball slot (array, stride, slots, scratch copy).
        public struct LockoutPerBall: Decodable, Sendable {
            public var array: String; public var stride: Int; public var slots: Int
            public var scratch: String?; public var currentVar: String?
        }
        public var lockoutPerBall: LockoutPerBall?

        /// Where the sensor handlers jump when done (the dispatcher's exit, hex cs offset).
        public var exitIp: String?
        enum CodingKeys: String, CodingKey { case levels, alwaysFiresValue, vars, forbiddenVars, spriteMask, alwaysFires, lockoutPerBall, exitIp }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            levels = try c.decode([[String: SensorHandler]].self, forKey: .levels)
            alwaysFiresValue = try c.decode(Int.self, forKey: .alwaysFiresValue)
            vars = try c.decodeIfPresent([String: String].self, forKey: .vars)
            forbiddenVars = try c.decodeIfPresent([String].self, forKey: .forbiddenVars)
            spriteMask = try c.decodeIfPresent(String.self, forKey: .spriteMask)
            if c.contains(.alwaysFires) {
                alwaysFiresKnown = true
                alwaysFires = try c.decodeIfPresent(Int.self, forKey: .alwaysFires)
            }
            lockoutPerBall = try c.decodeIfPresent(LockoutPerBall.self, forKey: .lockoutPerBall)
            exitIp = try? c.decodeIfPresent(String.self, forKey: .exitIp)
        }
        /// The value that fires during a lockout (nil = none).
        public var lockoutBypass: Int? { alwaysFiresKnown ? alwaysFires : alwaysFiresValue }
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
