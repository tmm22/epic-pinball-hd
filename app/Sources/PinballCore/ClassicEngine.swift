import Foundation

// Integer-exact re-implementation of the original table engine ("classic" mode).
//
// Transcribed from EP1.EXE (code segment 0x3223, data segment 0x15); every routine
// below names the EP1 cs:ip it mirrors. All game numbers (probe ring, normal and
// push-out tables, parameter block, colour classes, flipper outlines, caps, ...)
// come from `EngineData` (engine.json, parsed from the user's own EXE) at runtime.
//
// 16-bit semantics: ball words are Int16 and use wrapping (&+, &-, &*) arithmetic,
// unsigned compares go through UInt16(bitPattern:), `imul` is Int32 maths and `idiv`
// is Int32 division truncating toward zero with the quotient truncated to 16 bits
// (a real 8086 would raise a divide error instead; `divideFaults` counts those cases).
// Nothing here uses floating point.

/// Per-frame buttons. Bits 1/2/4 are the trace-contract bits.
public struct FrameInput: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let leftFlipper = FrameInput(rawValue: 1)
    public static let rightFlipper = FrameInput(rawValue: 2)
    /// Plunger only (the original's Ctrl key, cs:0297).
    public static let plunger = FrameInput(rawValue: 4)
    /// Nudge A: Z or ',' (cs:0298). Adds +20 to vx in the nudge impulse.
    public static let nudgeA = FrameInput(rawValue: 8)
    /// Nudge B: '/' (cs:0299). Adds -20 to vx in the nudge impulse.
    public static let nudgeB = FrameInput(rawValue: 16)
    /// Space (cs:0296): plunger while the ball is in the lane, nudge elsewhere.
    public static let space = FrameInput(rawValue: 32)
}

/// One ball slot, in the original's raw encoding (ds:6A00.. arrays, EP1).
public struct BallState: Sendable, Equatable {
    public var active: UInt16 = 0   // ds:6A3A
    public var x: Int16 = 0         // ds:6A46 top-left of the 15x14 box
    public var y: Int16 = 0         // ds:6A52
    public var vx: Int16 = 0        // ds:6A00, 1/128 px per physics step
    public var vy: Int16 = 0        // ds:6A0C
    public var accx: Int16 = 0      // ds:6A18, sub-pixel accumulator (1/128 px)
    public var accy: Int16 = 0      // ds:6A24
    public var layer: UInt8 = 0     // ds:6772 (byte, stride 2): 1 = ramp level
    public init() {}
    public init(x: Int16, y: Int16, vx: Int16 = 0, vy: Int16 = 0, accx: Int16 = 0, accy: Int16 = 0, layer: UInt8 = 0) {
        self.active = 1; self.x = x; self.y = y; self.vx = vx; self.vy = vy
        self.accx = accx; self.accy = accy; self.layer = layer
    }
}

public struct FlipperGroupState: Sendable, Equatable {
    public var angle: Int16   // EP1 ds:6CD2 / 6CD4: 0 = up ... 9 = rest
    public var drawn: Int16   // ds:6CD6 / 6CD8: outline currently in the buffer
    public var moving: Bool   // ds:676F / 6770: moved up on the last flipper_update
}

/// One collision_response call, captured right after contact_dir is stored (cs:1AEC).
public struct ResponseRecord: Sendable, Equatable {
    public var ball: Int
    public var k: UInt8
    /// collided_this_step was still 0, i.e. this response may change velocity.
    public var first: Bool
    public var flipperContact: UInt8
    public var kick: UInt8
}

/// What happened during one physics step (for traces and tests).
public struct StepReport: Sendable, Equatable {
    /// `collided_this_step` (ds:6C59) after the step.
    public var collided = false
    /// contact_dir (ds:586E) of the last response in this step, 1...48.
    public var lastDir: UInt8?
    /// contact_dir of the first response in this step.
    public var firstDir: UInt8?
    /// Number of collision_response calls (wall loop iterations with hits).
    public var responses = 0
    /// Every collision_response call in this step, in order (all balls, incl. ball-ball).
    public var log: [ResponseRecord] = []
}

public final class ClassicEngine {
    public enum WallClass: UInt8 { case empty, wall, active, flipper }
    public enum OccClass: UInt8 { case front, occludes, sensor }

    public let data: EngineData
    /// Start-up collision buffer (collision_idx.npy): playfield with flipper art removed.
    public let startBuffer: [UInt8]
    /// Live collision buffer (flipper outlines written/erased as the original does).
    public private(set) var buffer: [UInt8]

    // Tables (from engine.json).
    let ring: [UInt16]
    let t0: [Int16], t1: [Int16], p0: [Int16], p1: [Int16]
    let wallLUT: [[WallClass]]
    let occLUT: [[OccClass]]
    let fx: [Int16], fy: [Int16]
    let sensorHandlers: [[Int: EngineData.SensorHandler]]
    let groupMembers: [[Int]]

    // Ball + engine state (DS variables).
    public var balls = [BallState](repeating: BallState(), count: 5)
    public var groups: [FlipperGroupState]
    /// Parameter block ds:6781 (10 words), editable like the original's F1 editor.
    public var params: [Int16]
    public var input: FrameInput = []
    public var collidedThisStep = false   // ds:6C59
    public var flipperContact: UInt8 = 0  // ds:6768
    public var kickStrength: UInt8 = 0    // ds:676C
    public var kickerCooldown: UInt8 = 0  // ds:6769
    public var contactDir: UInt8 = 0      // ds:586E
    public var contactDirOpp: UInt8 = 0   // ds:586F
    public var crDvx: Int16 = 0           // ds:6C57
    public var crDvy: Int16 = 0           // ds:6C55
    public private(set) var hitList: [UInt8] = []  // ds:6C20 (count ds:6C1E)
    var responseLog: [ResponseRecord] = []
    public var nudgeTimer: UInt8 = 0      // ds:5870
    public var tiltMeter: UInt8 = 0       // ds:5871
    public var tilted = false             // ds:5872
    public var plungerCharge: UInt16 = 0  // ds:5897
    public var serveDelay: UInt8 = 0      // ds:5896
    public var extraGravity: Int16 = 0    // ds:06D7 (EP1)
    public var eventLockout: UInt8 = 0    // ds:676B
    public var eventCooldown: UInt8 = 0   // ds:676A
    public var curLayer: UInt8 = 0        // ds:677E
    var obj = (x: Int16(0), y: Int16(0), vx: Int16(0), vy: Int16(0))  // ds:6A30..6A36
    var writeback: UInt8 = 0              // ds:589A

    /// How many physics steps run before the per-frame main-loop logic (gravity etc.)
    /// inside one frame. The trace contract (tools/emu/trace_schema.json) defines a frame
    /// as main-loop work followed by the 3 steps, i.e. 0. In the real game the main loop
    /// runs asynchronously to the 3 timer-ISR steps, so the true phase is load dependent.
    public var gravityPhase = 0
    /// Run ball_pixel_scan's sensor dispatch (the exported physics-only handlers: ramp
    /// level enter/leave, debounce). Off = the harness's "physics" mode.
    public var sensorsEnabled = true
    /// Apply ball_lost_fade's resets (tilt off, ramp flags cleared) when the serve delay
    /// reaches 1. The harness skips that call, so traces turn this off.
    public var ballLostResets = true
    public private(set) var frameCount = 0
    public private(set) var stepCount = 0
    /// The original loops until no probe hits; this only guards against a hang.
    public var maxResponseIterations = 10_000
    public private(set) var divideFaults = 0
    public private(set) var loopGuardTrips = 0
    /// Report for the last physics step (ball-independent, as the original's flags are).
    public private(set) var lastStep = StepReport()
    /// Called after every physics step with (frame, step index within frame, report).
    public var onStep: ((Int, Int, StepReport) -> Void)?

    public init(data: EngineData, startBuffer: [UInt8]) throws {
        guard startBuffer.count == TableGeometry.width * TableGeometry.height else {
            throw EngineDataError.invalid("collision buffer has \(startBuffer.count) bytes, expected 128000")
        }
        self.data = data
        self.startBuffer = startBuffer
        self.buffer = startBuffer
        ring = data.probeRing.offsets.map { UInt16(truncatingIfNeeded: $0) }
        t0 = data.normals.map { Int16(truncatingIfNeeded: $0[0]) }
        t1 = data.normals.map { Int16(truncatingIfNeeded: $0[1]) }
        p0 = data.pushout.map { Int16(truncatingIfNeeded: $0[0]) }
        p1 = data.pushout.map { Int16(truncatingIfNeeded: $0[1]) }
        fx = data.flipperKick.fx.map { Int16(truncatingIfNeeded: $0) }
        fy = data.flipperKick.fy.map { Int16(truncatingIfNeeded: $0) }
        func wallClass(_ name: String) -> WallClass {
            switch name {
            case "wall", "wall_conditional": return .wall
            case "active", "active_conditional": return .active
            case "flipper": return .flipper
            default: return .empty
            }
        }
        let wcodes = data.wall.codes.map(wallClass)
        wallLUT = data.wall.lut.map { $0.map { wcodes.indices.contains($0) ? wcodes[$0] : .empty } }
        func occClass(_ name: String) -> OccClass {
            switch name {
            case "occludes_ball": return .occludes
            case "sensor", "sensor_conditional": return .sensor
            default: return .front
            }
        }
        let ocodes = data.occlusion.codes.map(occClass)
        occLUT = data.occlusion.lut.map { $0.map { ocodes.indices.contains($0) ? ocodes[$0] : .front } }
        sensorHandlers = data.sensors.levels.map { level in
            var m: [Int: EngineData.SensorHandler] = [:]
            for (k, v) in level { if let n = Int(k) { m[n] = v } }
            return m
        }
        groupMembers = data.flipperGroups.indices.map { g in data.flippers.indices.filter { data.flippers[$0].group == g } }
        groups = data.flipperGroups.map {
            FlipperGroupState(angle: Int16($0.initAngle), drawn: Int16($0.initDrawn), moving: false)
        }
        params = data.params.values.map { Int16(truncatingIfNeeded: $0) }
        extraGravity = Int16(truncatingIfNeeded: data.gravity.extraInitial)
        hitList.reserveCapacity(64)
    }

    // MARK: - Setup helpers

    /// Restores the power-on state: start-up buffer, flippers at their initial angle
    /// (2 in every table) with that outline recorded as drawn, no balls.
    public func resetToPowerOn() {
        buffer = startBuffer
        balls = [BallState](repeating: BallState(), count: 5)
        if let slots = data.ballSlotsInitial {
            for (i, sl) in slots.prefix(5).enumerated() {
                var b = BallState(x: Int16(truncatingIfNeeded: sl.x), y: Int16(truncatingIfNeeded: sl.y),
                                  vx: Int16(truncatingIfNeeded: sl.vx), vy: Int16(truncatingIfNeeded: sl.vy),
                                  accx: Int16(truncatingIfNeeded: sl.accx), accy: Int16(truncatingIfNeeded: sl.accy),
                                  layer: UInt8(truncatingIfNeeded: sl.layer))
                b.active = UInt16(truncatingIfNeeded: sl.active)
                balls[i] = b
            }
        }
        groups = data.flipperGroups.map {
            FlipperGroupState(angle: Int16($0.initAngle), drawn: Int16($0.initDrawn), moving: false)
        }
        params = data.params.values.map { Int16(truncatingIfNeeded: $0) }
        collidedThisStep = false; flipperContact = 0; kickStrength = 0; kickerCooldown = 0
        contactDir = 0; contactDirOpp = 0; crDvx = 0; crDvy = 0; hitList.removeAll()
        nudgeTimer = 0; tiltMeter = 0; tilted = false; plungerCharge = 0; serveDelay = 0
        extraGravity = Int16(truncatingIfNeeded: data.gravity.extraInitial)
        eventLockout = 0; eventCooldown = 0; curLayer = 0; writeback = 0
        frameCount = 0; stepCount = 0; divideFaults = 0; loopGuardTrips = 0
        lastStep = StepReport()
    }

    /// Power-on followed by the flippers dropping from their initial angle to rest,
    /// exactly as the first physics steps of a real game do (no balls, no keys).
    /// This is the state in which a game is normally played.
    public func resetToRest() {
        resetToPowerOn()
        let saved = input
        input = []
        for _ in 0..<16 where groups.indices.contains(where: { groups[$0].angle != Int16(data.flipperGroups[$0].restAngle) }) {
            flipperUpdate()
        }
        input = saved
        for i in groups.indices { groups[i].moving = false }
    }

    /// Puts ball 0 at the serve position (what drain_check does when all slots are empty).
    public func serveBall() {
        balls[0].active = 1
        balls[0].x = Int16(truncatingIfNeeded: data.serve.x)
        balls[0].y = Int16(truncatingIfNeeded: data.serve.y)
        balls[0].vx = 0
        balls[0].vy = 0
        serveDelay = UInt8(truncatingIfNeeded: data.serve.delay)
    }

    /// Moves a flipper group to `angle` using the original's erase/draw sequence.
    public func setFlipperAngle(group g: Int, angle: Int) {
        groups[g].angle = Int16(max(0, min(9, angle)))
        redraw(group: g)
    }

    // MARK: - Frame

    /// One video frame: 3 physics steps with the main-loop logic after `gravityPhase` of them.
    public func runFrame() {
        let steps = data.timing.stepsPerFrame
        for s in 0..<steps {
            if s == gravityPhase { frameLogic() }
            physicsStep()
            onStep?(frameCount, s, lastStep)
        }
        if gravityPhase >= steps { frameLogic() }
        frameCount += 1
    }

    /// Per-frame main-loop logic (main_loop cs:04D2 .. cs:1236), physics-relevant parts only.
    public func frameLogic() {
        // cs:06E2 extra gravity timer
        if extraGravity != 0 { extraGravity &-= 1 }
        // cs:09EC..0A09 per-frame counters
        if eventLockout != 0 { eventLockout -= 1 }
        if kickerCooldown != 0 { kickerCooldown -= 1 }
        if eventCooldown != 0 { eventCooldown -= 1 }
        drainCheck()
        plungerLane()
        nudgeTilt()
        gravityAndScan()
    }

    /// drain_check cs:0A31: slots 4..0; y >= drain -> inactive; all empty -> serve.
    func drainCheck() {
        var empty = 0
        for i in stride(from: 4, through: 0, by: -1) {
            if balls[i].active == 0 { empty += 1; continue }
            if UInt16(bitPattern: balls[i].y) < UInt16(truncatingIfNeeded: data.drainY) { continue }
            balls[i].active = 0
            empty += 1
        }
        if empty == 5 { serveBall() }
    }

    /// cs:0A9D..0BC7: serve delay and plunger, only while ball 0 sits in the lane.
    func plungerLane() {
        let b = balls[0]
        guard b.active != 0, b.layer == 0,
              UInt16(bitPattern: b.x) >= UInt16(truncatingIfNeeded: data.plunger.laneMinX),
              UInt16(bitPattern: b.y) >= UInt16(truncatingIfNeeded: data.plunger.laneMinY) else { return }
        if serveDelay != 0 {
            serveDelay -= 1
            if serveDelay == 1 {   // cs:0AFD ball_lost_fade: clears tilt and the ramp flags
                if ballLostResets {
                    tilted = false
                    balls[0].layer = 0
                    balls[1].layer = 0
                }
                return
            }
        }
        // cs:0B44: Ctrl or Space held (demo mode not modelled)
        if input.contains(.plunger) || input.contains(.space) {
            let maxC = UInt16(truncatingIfNeeded: data.plunger.max)
            let canAdd = data.plunger.cmp == "jae" ? plungerCharge < maxC : plungerCharge <= maxC
            if canAdd { plungerCharge &+= UInt16(truncatingIfNeeded: data.plunger.step) }
            return
        }
        // cs:0B83 released: vx = 0 every frame; fire if charged
        balls[0].vx = 0
        guard plungerCharge != 0 else { return }
        balls[0].vy &-= Int16(bitPattern: plungerCharge)
        plungerCharge = 0
        balls[0].y &-= 1
    }

    /// nudge_tilt cs:0DFD.
    func nudgeTilt() {
        let n = data.nudge
        if !input.isDisjoint(with: [.nudgeA, .nudgeB, .space]) && !tilted {
            let inLane = UInt16(bitPattern: balls[0].x) >= UInt16(truncatingIfNeeded: n.laneMinX)
                && UInt16(bitPattern: balls[0].y) > UInt16(truncatingIfNeeded: n.laneMaxY)
            if !inLane && nudgeTimer == 0 {
                tiltMeter &+= UInt8(truncatingIfNeeded: n.tiltAdd)
                nudgeTimer = UInt8(truncatingIfNeeded: n.frames)
            }
        }
        if nudgeTimer != 0 { nudgeTimer -= 1 }
        if tiltMeter != 0 { tiltMeter -= 1 }
        if tiltMeter > UInt8(truncatingIfNeeded: n.tiltThreshold) && !tilted { tilted = true }
    }

    /// gravity_and_objects cs:11A7 + ball_pixel_scan cs:1679 (sensors only).
    func gravityAndScan() {
        kickStrength = 0   // cs:119F
        let cutoff = Int16(truncatingIfNeeded: data.gravity.cutoff)
        for i in 0..<5 where balls[i].active != 0 {
            if balls[i].vy <= cutoff { balls[i].vy &+= params[9] &+ extraGravity }
            curLayer = balls[i].layer
            obj = (balls[i].x, balls[i].y, balls[i].vx, balls[i].vy)
            writeback = 0
            if sensorsEnabled { pixelScan() }
            balls[i].layer = curLayer
            if writeback != 0 {
                balls[i].x = obj.x; balls[i].y = obj.y; balls[i].vy = obj.vy; balls[i].vx = obj.vx
            }
        }
    }

    /// ball_pixel_scan cs:1679: sensor candidates under the 15x14 box fire table rules.
    func pixelScan() {
        let occ = occLUT[curLayer == 1 ? 1 : 0]
        let alwaysFires = UInt8(truncatingIfNeeded: data.sensors.alwaysFiresValue)
        var lockout = eventLockout
        var dy = UInt16(bitPattern: obj.y)
        let rowBase = Int(UInt16(bitPattern: obj.y) &* 20) * 16
        var diRow = UInt16(bitPattern: obj.x)
        for _ in 0..<data.ball.h {
            dy &+= 1
            if dy > 0x190 { break }
            var di = diRow
            for _ in 0..<data.ball.w {
                let v = pixel(rowBase + Int(di))
                if occ[Int(v)] == .sensor, v == alwaysFires || lockout == 0, eventCooldown == 0 {
                    dispatchSensor(Int(v))
                    lockout = eventLockout
                }
                di &+= 1
            }
            diRow &+= UInt16(TableGeometry.width)
        }
    }

    func dispatchSensor(_ v: Int) {
        guard let h = sensorHandlers[curLayer == 1 ? 1 : 0][v] else { return }
        if !(h.always ?? true) && tilted { return }
        run(h.ops)
    }

    func run(_ ops: [SensorOp]) {
        for op in ops {
            switch op {
            case let .set(name, expr):
                setVar(name, eval(expr))
            case let .branch(lhs, cmp, rhs, size, thenOps, elseOps):
                let mask: UInt16 = size == 8 ? 0xFF : 0xFFFF
                let l = eval(lhs) & mask, r = eval(rhs) & mask
                let ls = size == 8 ? Int(Int8(truncatingIfNeeded: l)) : Int(Int16(bitPattern: l))
                let rs = size == 8 ? Int(Int8(truncatingIfNeeded: r)) : Int(Int16(bitPattern: r))
                let taken: Bool
                switch cmp {
                case "eq": taken = l == r
                case "ne": taken = l != r
                case "b": taken = l < r
                case "ae": taken = l >= r
                case "a": taken = l > r
                case "be": taken = l <= r
                case "lt": taken = ls < rs
                case "ge": taken = ls >= rs
                case "gt": taken = ls > rs
                case "le": taken = ls <= rs
                default: taken = false
                }
                run(taken ? thenOps : elseOps)
            }
        }
    }

    /// Evaluates a handler expression with 16-bit wrapping semantics.
    func eval(_ e: SensorExpr) -> UInt16 {
        switch e {
        case let .constant(n): return UInt16(truncatingIfNeeded: n)
        case let .variable(name): return getVar(name)
        case let .unary(_, a): return 0 &- eval(a)
        case let .binary(op, a, b):
            let x = eval(a), y = eval(b)
            switch op {
            case "add": return x &+ y
            case "mul": return x &* y
            case "shl": return x &<< (y & 15)
            case "shr": return x &>> (y & 15)
            case "sar": return UInt16(bitPattern: Int16(bitPattern: x) &>> Int16(y & 15))
            default: return 0
            }
        }
    }

    /// Physics variables a sensor handler may read/write (names from engine.json `sensors.vars`).
    func getVar(_ name: String) -> UInt16 {
        switch name {
        case "level": return UInt16(curLayer)
        case "lockout": return UInt16(eventLockout)
        case "event_cooldown": return UInt16(eventCooldown)
        case "writeback": return UInt16(writeback)
        case "extra_gravity": return UInt16(bitPattern: extraGravity)
        case "obj_x": return UInt16(bitPattern: obj.x)
        case "obj_y": return UInt16(bitPattern: obj.y)
        case "obj_vx": return UInt16(bitPattern: obj.vx)
        case "obj_vy": return UInt16(bitPattern: obj.vy)
        default:
            guard let (field, i) = Self.ballVar(name) else { return 0 }
            switch field {
            case "ball_x": return UInt16(bitPattern: balls[i].x)
            case "ball_y": return UInt16(bitPattern: balls[i].y)
            case "ball_vx": return UInt16(bitPattern: balls[i].vx)
            case "ball_vy": return UInt16(bitPattern: balls[i].vy)
            case "ball_active": return balls[i].active
            default: return 0
            }
        }
    }

    func setVar(_ name: String, _ value: UInt16) {
        let w = Int16(bitPattern: value), b = UInt8(truncatingIfNeeded: value)
        switch name {
        case "level": curLayer = b
        case "lockout": eventLockout = b
        case "event_cooldown": eventCooldown = b
        case "writeback": writeback = b
        case "extra_gravity": extraGravity = w
        case "obj_x": obj.x = w
        case "obj_y": obj.y = w
        case "obj_vx": obj.vx = w
        case "obj_vy": obj.vy = w
        default:
            guard let (field, i) = Self.ballVar(name) else { return }
            switch field {
            case "ball_x": balls[i].x = w
            case "ball_y": balls[i].y = w
            case "ball_vx": balls[i].vx = w
            case "ball_vy": balls[i].vy = w
            case "ball_active": balls[i].active = value
            default: break
            }
        }
    }

    static func ballVar(_ name: String) -> (String, Int)? {
        let parts = name.split(separator: ".")
        guard parts.count == 2, let i = Int(parts[1]), (0..<5).contains(i) else { return nil }
        return (String(parts[0]), i)
    }

    // MARK: - Physics step (timer ISR -> physics_step cs:1724)

    public func physicsStep() {
        var report = StepReport()
        responseLog.removeAll(keepingCapacity: true)
        collidedThisStep = false
        let limit = UInt16(truncatingIfNeeded: data.integration.collisionYLimit)
        for i in 0..<5 where balls[i].active == 1 {
            flipperContact = 0
            kickStrength = 0
            integrate(ball: i)
            var iterations = 0
            while UInt16(bitPattern: balls[i].y) < limit {
                probe(ball: i)
                if hitList.isEmpty { break }
                collisionResponse(ball: i)
                if report.firstDir == nil { report.firstDir = contactDir }
                report.lastDir = contactDir
                report.responses += 1
                collidedThisStep = true
                kickStrength = 0
                flipperContact = 0
                iterations += 1
                if iterations >= maxResponseIterations { loopGuardTrips += 1; break }
            }
        }
        flipperUpdate()
        ballBallChecks()
        report.collided = collidedThisStep
        report.log = responseLog
        lastStep = report
        stepCount += 1
    }

    /// cs:174A..1823: accumulate, cap the pixel move, clamp the backlog.
    func integrate(ball i: Int) {
        let c = data.integration
        var b = balls[i]
        _ = Self.integrateAxis(pos: &b.x, acc: &b.accx, v: b.vx, capPos: c.stepCap.xPos, capNeg: c.stepCap.xNeg,
                               clampPos: c.accClampPos, clampNeg: c.accClampNeg)
        if b.x < Int16(c.minX) { b.x = Int16(c.minX) }
        let up = Self.integrateAxis(pos: &b.y, acc: &b.accy, v: b.vy, capPos: c.stepCap.yPos, capNeg: c.stepCap.yNeg,
                                    clampPos: c.accClampPos, clampNeg: c.accClampNeg)
        if up && b.y < Int16(c.minY) {   // only checked on the upward branch (cs:1813)
            b.y = Int16(truncatingIfNeeded: c.yReset)
            b.vy = 0
        }
        balls[i] = b
    }

    /// Returns true when the negative (upward/leftward) branch ran.
    @inline(__always)
    static func integrateAxis(pos: inout Int16, acc: inout Int16, v: Int16, capPos: Int, capNeg: Int,
                              clampPos: Int, clampNeg: Int) -> Bool {
        acc = acc &+ v
        if acc >= 0 {
            var m = UInt16(bitPattern: acc) >> 7
            if m > UInt16(capPos) {
                m = UInt16(capPos)
                if acc > Int16(truncatingIfNeeded: clampPos) { acc = Int16(truncatingIfNeeded: clampPos) }
            }
            pos = pos &+ Int16(bitPattern: m)
            acc = acc &- Int16(bitPattern: m &<< 7)
            return false
        } else {
            var m = UInt16(bitPattern: 0 &- acc) >> 7
            if m > UInt16(capNeg) {
                m = UInt16(capNeg)
                if acc < Int16(truncatingIfNeeded: clampNeg) { acc = Int16(truncatingIfNeeded: clampNeg) }
            }
            pos = pos &- Int16(bitPattern: m)
            acc = acc &+ Int16(bitPattern: m &<< 7)
            return true
        }
    }

    @inline(__always)
    func pixel(_ linear: Int) -> UInt8 {
        // Beyond the 320x400 buffer the original reads the next segment; treat as empty.
        (linear >= 0 && linear < buffer.count) ? buffer[linear] : 0
    }

    /// Wall loop cs:1831..18C3: probe k = 48 down to 1, record hits.
    func probe(ball i: Int) {
        hitList.removeAll(keepingCapacity: true)
        let b = balls[i]
        let rowBase = Int(UInt16(bitPattern: b.y) &* 20) * 16
        let x = UInt16(bitPattern: b.x)
        let lut = wallLUT[b.layer == 1 ? 1 : 0]
        let split = UInt16(truncatingIfNeeded: data.collision.flipperContactSplitX)
        let map = data.flipperMap
        for k in stride(from: 48, through: 1, by: -1) {
            let v = pixel(rowBase + Int(x &+ ring[k - 1]))
            switch lut[Int(v)] {
            case .empty: continue
            case .wall: break
            case .active:
                if kickerCooldown == 0 { kickerHit() }
            case .flipper:
                if x <= split {
                    if groups[map.contact1Moving].moving { flipperContact = 1 }
                } else if groups[map.contact2Moving].moving {
                    flipperContact = 2
                }
            }
            hitList.append(UInt8(k))
        }
    }

    /// kicker_hit cs:19C1 (physics part; scoring is table rules).
    func kickerHit() {
        if data.kicker.tiltDisables && tilted { return }
        kickStrength = UInt8(truncatingIfNeeded: params[2])
        kickerCooldown = UInt8(truncatingIfNeeded: data.kicker.cooldownFrames)
    }

    // MARK: - collision_response cs:1A66

    /// Contact direction from the hit list (cs:1A66..1ACC), u8 arithmetic.
    public static func contactDirection(_ hits: [UInt8]) -> UInt8 {
        precondition(!hits.isEmpty)
        var lo = hits[hits.count - 1], hi = lo
        var i = hits.count - 2
        while i >= 0 {
            let c = hits[i]
            if c < lo { lo = c }
            if c > hi { hi = c }
            i -= 1
        }
        if lo == 1 && hi == 48 {
            // wrap case: first/last recorded entries (always 48 and 1 -> result 48)
            let first = hits[0], last = hits[hits.count - 1]
            var al = (first &+ 48) &- last
            al >>= 1
            var dir = last &+ al
            if dir > 48 { dir &-= 48 }
            return dir
        }
        var d = hi &- lo
        if d > 24 {
            d >>= 1
            var dir = lo &+ d &+ 24
            if dir > 48 { dir &-= 48 }
            return dir
        }
        d >>= 1
        return lo &+ d
    }

    /// Outcome of the idiv-based reflection maths, exposed for unit tests.
    public struct Reflection: Equatable, Sendable {
        public var a: Int16, p: Int32, b: Int16, d: Int16, e: Int16
        public var wx: Int16, wy: Int16    // before the restitution scaling
        public var dvx: Int16, dvy: Int16  // added to the velocity
        public var faults: Int
    }

    /// x86 `idiv r16` on a 32-bit dividend: quotient truncated toward zero. Returns the
    /// low 16 bits and whether a real CPU would have raised a divide error.
    @inline(__always)
    public static func idiv16(_ dividend: Int32, _ divisor: Int16) -> (Int16, Bool) {
        if divisor == 0 { return (0, true) }
        if dividend == Int32.min && divisor == -1 { return (Int16(truncatingIfNeeded: dividend), true) }
        let q = dividend / Int32(divisor)
        return (Int16(truncatingIfNeeded: q), q < Int32(Int16.min) || q > Int32(Int16.max))
    }

    /// cs:1C0A..1CF5: the reflection impulse for velocity (vx, vy) against normal
    /// (nx, ny) = (-t0, t1), with divisors divX/divY (param[0]/[1], plus the ramp terms).
    public static func reflect(vx: Int16, vy: Int16, nx: Int16, ny: Int16, divX: Int16, divY: Int16) -> Reflection {
        var faults = 0
        func div(_ a: Int32, _ b: Int16) -> Int16 {
            let (q, f) = idiv16(a, b)
            if f { faults += 1 }
            return q
        }
        // A = 64*nx / ny   (imul; cwd sign-extends the low word; idiv)
        let a = div(Int32(Int16(truncatingIfNeeded: Int32(64) * Int32(nx))), ny)
        // P = A*vx + 64*vy (32-bit)
        let p = (Int32(a) * Int32(vx)) &+ (Int32(vy) * 64)
        // B = 64*ny / nx ; D = A + B, never 0
        let b = div(Int32(Int16(truncatingIfNeeded: Int32(64) * Int32(ny))), nx)
        var d = b &+ a
        if d == 0 { d = 1 }
        let wx = 0 &- div(p, d)
        // E = 16*nx^2 / ny^2 + 64, or 0x7FF8 when (u16)(ny*ny) == 1
        let nx2 = Int16(truncatingIfNeeded: Int32(nx) * Int32(nx))
        let num = Int32(nx2) * 16
        let ny2 = Int16(truncatingIfNeeded: Int32(ny) * Int32(ny))
        let e: Int16 = ny2 == 1 ? 0x7FF8 : div(num, ny2) &+ 64
        let wy = 0 &- div(p, e)
        let dvx = div(Int32(wx) * 20, divX)
        let dvy = div(Int32(wy) * 20, divY)
        return Reflection(a: a, p: p, b: b, d: d, e: e, wx: wx, wy: wy, dvx: dvx, dvy: dvy, faults: faults)
    }

    func collisionResponse(ball i: Int) {
        let dir = Self.contactDirection(hitList)
        contactDir = dir
        responseLog.append(ResponseRecord(ball: i, k: dir, first: !collidedThisStep, flipperContact: flipperContact, kick: kickStrength))
        let k = Int(dir &- 1)
        var opp = UInt8(truncatingIfNeeded: k) &+ 24
        if opp > 48 { opp &-= 48 }
        contactDirOpp = opp
        guard k < 48 else { return }  // cannot happen (dir is 1...48)
        var b = balls[i]
        defer { balls[i] = b }
        let r = data.flipperKick.ranges
        if flipperContact != 0 {
            // cs:1AF3: y -= 1; side/tip kick along a fixed normal on every iteration
            b.y &-= 1
            var kp: Int?
            if k > r.sideMax {
                kp = k > r.topMax ? r.tipIndex : nil
            } else {
                kp = k < r.lo ? r.tipIndex : r.sideIndex
            }
            if let kp {
                b.vx &+= (0 &- t0[kp]) &* params[5]
                if b.vy >= Int16(truncatingIfNeeded: data.flipperKick.vyZeroSide) { b.vy = 0 }
                b.vy &+= t1[kp] &* params[6]
                return
            }
        } else {
            // cs:1B4A: one pixel of push-out
            b.x &-= p0[k]
            b.y &+= p1[k]
        }
        if collidedThisStep { return }  // cs:1B5D: only the first response changes velocity
        if flipperContact != 0 {
            // cs:1B6E: ball resting on a moving flipper
            if b.vy >= Int16(truncatingIfNeeded: data.flipperKick.vyZeroTop) { b.vy = 0 }
            if flipperContact == 1 {
                let a = Int(groups[data.flipperMap.contact1Angle].angle)
                b.vx &+= fx[a] &* params[3]
                b.vy &-= fy[a] &* params[4]
            } else {
                let a = Int(groups[data.flipperMap.contact2Angle].angle)
                b.vx &-= fx[a] &* params[3]
                b.vy &-= fy[a] &* params[4]
            }
            return
        }
        let nx = 0 &- t0[k], ny = t1[k]
        crDvx = nx
        crDvy = ny
        if kickStrength != 0 {
            // cs:1BE2: kicker: v += kick * n, no reflection
            let kick = Int16(kickStrength)
            b.vx &+= kick &* crDvx
            b.vy &+= kick &* crDvy
            return
        }
        let up = b.layer == 1
        let divX = params[0] &+ (up ? params[8] : 0)
        let divY = params[1] &+ (up ? params[7] : 0)
        let ref = Self.reflect(vx: b.vx, vy: b.vy, nx: nx, ny: ny, divX: divX, divY: divY)
        divideFaults += ref.faults
        crDvx = ref.dvx
        crDvy = ref.dvy
        b.vx &+= ref.dvx
        b.vy &+= ref.dvy
        // cs:1D06: nudge impulse
        let ni = data.nudgeImpulse
        if nudgeTimer >= UInt8(truncatingIfNeeded: ni.minTimer)
            && contactDir >= UInt8(truncatingIfNeeded: ni.dirMin) && contactDir <= UInt8(truncatingIfNeeded: ni.dirMax) {
            b.vy &-= Int16(nudgeTimer &<< UInt8(truncatingIfNeeded: ni.vyShift))
            let kx = Int16(truncatingIfNeeded: ni.vx)
            b.vx &+= kx
            if !input.contains(.nudgeA) {
                if !input.contains(.nudgeB) { b.vx &+= kx }
                b.vx &-= kx &* 2
            }
        }
    }

    // MARK: - flipper_update cs:3CDD (end of every physics step)

    public func flipperUpdate() {
        for g in groups.indices {
            let info = data.flipperGroups[g]
            let rest = Int16(info.restAngle)
            let held = info.key == "left" ? input.contains(.leftFlipper) : input.contains(.rightFlipper)
            if tilted {
                groups[g].angle = rest
                groups[g].moving = false
                redraw(group: g)
            } else if held {
                if groups[g].angle == 0 {
                    groups[g].moving = false
                } else {
                    groups[g].moving = true
                    groups[g].angle -= 1
                    redraw(group: g)
                }
            } else {
                groups[g].moving = false
                if groups[g].angle != rest {
                    groups[g].angle += 1
                    redraw(group: g)
                }
            }
        }
        if tilted {  // cs:3E17
            for g in groups.indices {
                groups[g].angle = Int16(data.flipperGroups[g].restAngle)
                groups[g].moving = false
            }
        }
    }

    /// Erase the drawn outline (erase colour) and draw the current one (flipper value).
    func redraw(group g: Int) {
        let value = UInt8(truncatingIfNeeded: data.flipperGroups[g].value)
        let erase = UInt8(truncatingIfNeeded: data.flipperEraseValue)
        let old = Int(groups[g].drawn), new = Int(groups[g].angle)
        for m in groupMembers[g] {
            let f = data.flippers[m]
            if f.positions.indices.contains(old) {
                for o in f.positions[old] where o >= 0 && o < buffer.count { buffer[o] = erase }
            }
            if f.positions.indices.contains(new) {
                for o in f.positions[new] where o >= 0 && o < buffer.count { buffer[o] = value }
            }
        }
        groups[g].drawn = groups[g].angle
    }

    // MARK: - ball_ball_collide cs:1D47 (pairs checked at cs:1903..19BB)

    func ballBallChecks() {
        func near(_ a: Int, _ b: Int) -> Bool {
            let dx = balls[b].x &- balls[a].x, dy = balls[b].y &- balls[a].y
            let mdx = Int16(truncatingIfNeeded: data.ballBall.maxDx), mdy = Int16(truncatingIfNeeded: data.ballBall.maxDy)
            return dx <= mdx && dx >= -mdx && dy <= mdy && dy >= -mdy && balls[a].layer == balls[b].layer
        }
        if balls[1].active == 1 && near(0, 1) { ballBall(0, 1) }
        if balls[2].active == 1 && near(0, 2) { ballBall(0, 2) }
        if balls[1].active != 0 && balls[2].active != 0 && near(1, 2) { ballBall(1, 2) }
    }

    func ballBall(_ a: Int, _ b: Int) {
        collidedThisStep = false
        flipperContact = 0
        hitList.removeAll(keepingCapacity: true)
        var di = a, si = b
        if UInt16(bitPattern: balls[di].y) >= UInt16(bitPattern: balls[si].y) { swap(&di, &si) }
        let rel = UInt16(bitPattern: balls[di].y &- balls[si].y) &* 320
        let off = rel &+ UInt16(bitPattern: balls[di].x) &- UInt16(bitPattern: balls[si].x)
        for k in 1...48 {
            let target = ring[k - 1]
            for m in stride(from: 48, through: 1, by: -1) where off &+ ring[m - 1] == target {
                hitList.append(UInt8(m))
            }
        }
        let saved0 = params[0], saved1 = params[1]
        let div = Int16(truncatingIfNeeded: data.ballBall.divisor)
        params[0] = div
        params[1] = div
        defer { params[0] = saved0; params[1] = saved1 }
        guard !hitList.isEmpty else { return }
        let vxd = balls[di].vx, vyd = balls[di].vy, vxs = balls[si].vx, vys = balls[si].vy
        collisionResponse(ball: di)
        let dvx1 = crDvx, dvy1 = crDvy
        hitList = [contactDirOpp]
        collisionResponse(ball: si)
        let ay = dvy1 &- crDvy, cx = dvx1 &- crDvx
        balls[si].vy = vys &- ay
        balls[si].vx = vxs &- cx
        balls[di].vy = vyd &+ ay
        balls[di].vx = vxd &+ cx
    }

    // MARK: - Rendering helpers (read-only)

    /// The ball sprite composited like ball_pixel_scan does: collision-buffer indices in the
    /// level's occlusion range replace the ball's own pixels (drawn in front of it).
    /// Index 0 = transparent. Nil when engine.json has no ball pixels.
    public func compositedBallPixels(ball i: Int = 0) -> [UInt8]? {
        guard var out = data.ball.pixels else { return nil }
        let b = balls[i]
        let occ = occLUT[b.layer == 1 ? 1 : 0]
        let rowBase = Int(UInt16(bitPattern: b.y) &* 20) * 16
        var dy = UInt16(bitPattern: b.y)
        var diRow = UInt16(bitPattern: b.x)
        for r in 0..<data.ball.h {
            dy &+= 1
            if dy > 0x190 { break }
            var di = diRow
            for c in 0..<data.ball.w {
                let v = pixel(rowBase + Int(di))
                if occ[Int(v)] == .occludes { out[r * data.ball.w + c] = v }
                di &+= 1
            }
            diRow &+= UInt16(TableGeometry.width)
        }
        return out
    }

    /// Sprite frame for a flipper at `angle` (cs:10F5: (angle + 2) / 3).
    public static func spriteFrame(angle: Int, frameCount: Int) -> Int {
        max(0, min(frameCount - 1, (angle + 2) / 3))
    }
}
