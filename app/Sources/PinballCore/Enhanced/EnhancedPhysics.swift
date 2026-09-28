import Foundation

/// Enhanced ball physics (`GameSettings.PhysicsMode.enhanced`): the same tables, collision art,
/// rules and main loop as the classic engine, with smooth floating-point ball motion.
///
/// * **Fixed timestep**: every classic physics step (3 per 59.94 Hz frame) runs `substeps`
///   deterministic substeps (8 -> 1438.6 Hz, 10 -> 1798 Hz).
/// * **Collision world**: smoothed signed distance fields built from the live collision buffer's
///   wall classes (per level: walls and kicker pixels separately), updated locally whenever a gate or
///   rule code writes the buffer (`ClassicEngine.bufferWriteLog`) or the level-0 classes change
///   (EP8). Flipper outline pixels are excluded; flippers are `FlipperShape`s that rotate
///   continuously between the original's angle indices.
/// * **Swept motion**: conservative advancement on the distance fields (a ball never moves further
///   than its clearance), so no speed can tunnel through a wall, and every loop is bounded.
/// * **Responses**: static walls use the original's reflection maths for the smooth wall angle
///   (`classicMap`) or restitution + friction; kickers call the original kicker code (rules hook or
///   `kickerHit`) and apply its kick; flippers give a physically based impulse from the flipper's
///   angular velocity at the contact point; balls collide as equal discs.
/// * **Sync**: after every step the integer ball fields (`x`, `y`, `accx`, `accy`, `vx`, `vy`) are
///   written back; changes made by the main loop or rules between steps (serve, plunger release,
///   lane `vx = 0`, sensor write-backs, rule kicks) are detected against the last written values
///   and applied (positions as teleports, velocities as deltas). Gravity comes through
///   `frameGravity` and is spread over the frame's substeps.
public final class EnhancedPhysics: BallPhysics {
    public var config: EnhancedPhysicsConfig {
        didSet { if config.contactPadding != oldValue.contactPadding { updateRadii() } }
    }

    /// Diagnostics (cumulative).
    public struct Stats: Sendable, Equatable {
        public var substeps = 0
        /// Conservative-advancement loops that ran out of iterations (the rest of the substep is dropped).
        public var sweepExhausted = 0
        /// Contacts deeper than 2 px (teleports, gates closing on the ball, level switches over a wall).
        public var deepContacts = 0
        /// Deep contacts resolved by moving the ball to the nearest free position.
        public var escapes = 0
        /// Ball searches (a ball at rest in a nook kicked free).
        public var ballSearches = 0
        /// Non-finite ball states replaced by the last good state.
        public var nanResets = 0
        /// The original's edge clamps (x < min_x, y < min_y) applied.
        public var edgeClamps = 0
        public var wallImpacts = 0
        public var flipperImpacts = 0
        public var kicks = 0
        public var ballBallImpacts = 0
        public var fieldUpdates = 0
    }
    public private(set) var stats = Stats()

    /// Ball box top-left -> centre (the probe ring's centre, (7.5, 7.0) in every table).
    public let centreOffset: SIMD2<Double>
    /// Contact radius per whole degree of outward normal (before `contactPadding`).
    let ringRadius: [Double]
    /// Largest / smallest contact radius over all directions (with padding).
    public private(set) var maxContactRadius = 7.0
    public private(set) var minContactRadius = 6.0
    /// The ball outline for contacts: `perimeterCount` points, direction `u` (outward from the
    /// centre) at the contact radius of a wall facing `-u`.
    static let perimeterCount = 48
    private(set) var perimeter: [(u: SIMD2<Double>, r: Double)] = []
    // Scratch buffers for `contacts`.
    var scratchDepth = [Double](repeating: 0, count: 48)
    var scratchNorm = [SIMD2<Double>](repeating: .zero, count: 48)
    var scratchIn = [Bool](repeating: false, count: 48)

    func updateRadii() {
        maxContactRadius = (ringRadius.max() ?? 7) + config.contactPadding
        minContactRadius = (ringRadius.min() ?? 6) + config.contactPadding
        perimeter = (0..<Self.perimeterCount).map { j in
            let a = Double(j) * 2 * .pi / Double(Self.perimeterCount)
            let u = SIMD2(cos(a), sin(a))
            return (u, contactRadius(normal: -u))
        }
    }
    public let flippers: [FlipperShape]

    struct Body {
        var active = false
        var c = SIMD2<Double>(0, 0)
        var v = SIMD2<Double>(0, 0)
        var spin = 0.0              // angular velocity x radius (px/step), modern preset
        var layer: UInt8 = 0
        var written: BallState?
        var gravityBudget = 0.0     // px/step still to add this frame
        var gravityRate = 0.0       // px/step per substep
        var lastGood = (SIMD2<Double>(0, 0), SIMD2<Double>(0, 0))
        // per classic step
        var kickedThisStep = false
        var nudgedThisStep = false
        var bigHitThisStep = false
        var ruleTimerThisStep = false
        /// Kicker pixels switched on (EP2's position window) while the ball overlapped them: they
        /// stay intangible for this ball until it is clear of them.
        var activeGhost = false
        /// Ball search bookkeeping: steps at rest, last support normal, flipper contact this step.
        var stillSteps = 0
        var supportNormal = SIMD2<Double>(0, -1)
        var onFlipper = false
        var searches = 0
    }
    var bodies = [Body](repeating: Body(), count: 5)

    // Collision world.
    static let pad = 16
    let gridW = TableGeometry.width + 2 * pad, gridH = TableGeometry.height + 2 * pad
    /// Per level: static walls, kicker ("active") pixels.
    var walls: [DistanceField] = []
    var actives: [DistanceField] = []
    /// Class masks per level (0 empty, 1 wall, 2 active) over the 320x400 buffer.
    var classes: [[UInt8]] = []
    var flipperPixel: [Bool]
    var builtGeneration = -1
    var builtDynState: (Int, Int, Int) = (-2, -2, -2)
    var builtLUT: [[ClassicEngine.WallClass]] = []

    // Flipper motion within the current step.
    var alphaStart: [Double] = []
    var alphaEnd: [Double] = []
    var alphaNow: [Double] = []
    var subIndex = 0

    // Classic response tables.
    let probeAngles: [Double]   // degrees, strictly increasing, 48 + 1 (wrap)
    let tableNormals: [SIMD2<Double>]
    /// Per whole degree of the smooth outward wall normal (screen angle): the original's table
    /// normal averaged over the probe-hit patterns a straight wall at that angle produces (0 .. 2 px
    /// beyond first contact), and the most frequent contact direction. See `classicDirectionTable`.
    let classicNormalByAngle: [SIMD2<Double>]
    let classicDirByAngle: [UInt8]
    /// Direction histogram per degree (weights of each k), for the reflection maps.
    let classicDirWeights: [[(Int, Double)]]
    /// Per level and degree: the original's reflection as a linear map (row-major 2x2), averaged
    /// over the same hit patterns, for the divisors in `mapParams`.
    var classicMaps: [[SIMD4<Double>]] = []
    var mapParams: [Int16] = []
    var stepReport = StepReport()

    public init(engine e: ClassicEngine, config: EnhancedPhysicsConfig = .classicFeel) {
        self.config = config
        let d = e.data
        let w = TableGeometry.width
        let ring = d.probeRing.offsets.map { SIMD2(Double($0 % w) + 0.5, Double($0 / w) + 0.5) }
        let cen = ring.reduce(SIMD2(0, 0), +) / Double(max(1, ring.count))
        centreOffset = cen
        ringRadius = (0..<360).map { deg in
            let a = Double(deg) * .pi / 180
            let n = SIMD2(cos(a), sin(a))
            let h = ring.map { (($0 - cen) * -n).sum() }.max() ?? 7
            return h - 0.5 * (abs(n.x) + abs(n.y))
        }
        var ang = ring.map { p -> Double in
            let a = atan2(-(p.y - cen.y), p.x - cen.x) * 180 / .pi
            return a < 0 ? a + 360 : a
        }
        for k in 1..<ang.count {
            while ang[k] < ang[k - 1] - 180 { ang[k] += 360 }
            if ang[k] <= ang[k - 1] + 0.25 { ang[k] = ang[k - 1] + 0.25 }
        }
        ang.append(ang[0] + 360)
        probeAngles = ang
        tableNormals = d.normals.map { SIMD2(-Double($0[0]), Double($0[1])) }
        (classicNormalByAngle, classicDirByAngle, classicDirWeights) = Self.classicDirectionTable(ring: ring, centre: cen, normals: tableNormals)
        flippers = d.flippers.enumerated().map { FlipperShape(index: $0.offset, flipper: $0.element) }
        var fp = [Bool](repeating: false, count: w * TableGeometry.height)
        for f in d.flippers { for p in f.positions { for o in p where o >= 0 && o < fp.count { fp[o] = true } } }
        flipperPixel = fp
        alphaStart = e.groups.map { Double($0.angle) }
        alphaEnd = alphaStart
        alphaNow = alphaStart
        updateRadii()
        rebuildWorld(e)
    }

    /// Installs a new model on `engine` (replacing any other) and returns it.
    @discardableResult
    public static func install(on engine: ClassicEngine, config: EnhancedPhysicsConfig = .classicFeel) -> EnhancedPhysics {
        let p = EnhancedPhysics(engine: engine, config: config)
        engine.ballPhysics = p
        engine.bufferWriteLog = []
        return p
    }

    /// Removes an installed model (the engine runs the original integer physics again).
    public static func uninstall(from engine: ClassicEngine) {
        engine.ballPhysics = nil
        engine.bufferWriteLog = nil
    }

    // MARK: - Public state for presentation

    /// Ball centre in table pixels (smooth), nil if the slot is not simulated.
    public func ballCentre(_ i: Int) -> SIMD2<Double>? { bodies[i].active ? bodies[i].c : nil }
    public func ballVelocity(_ i: Int) -> SIMD2<Double>? { bodies[i].active ? bodies[i].v : nil }
    /// Continuous angle index (0 = up ... 9 = rest) of flipper group `g` at the end of the last step.
    public func flipperAlpha(group g: Int) -> Double { alphaNow.indices.contains(g) ? alphaNow[g] : 9 }
    /// Rotation of flipper `i` relative to its rest outline (radians, y down) and its pivot.
    public func flipperPose(_ i: Int) -> (pivot: SIMD2<Double>, theta: Double) {
        let f = flippers[i]
        return (f.pivot, f.theta(alpha: flipperAlpha(group: f.group)).theta)
    }

    // MARK: - Collision world

    func classOf(_ e: ClassicEngine, level: Int, value v: UInt8, pixel p: Int) -> UInt8 {
        switch e.wallLUT[level][Int(v)] {
        case .empty: return 0
        case .wall: return 1
        case .flipper: return flipperPixel[p] ? 0 : 1
        case .active:
            if let am = e.data.kicker.activeMax, Int(v) > am { return 0 }
            return flipperPixel[p] ? 0 : 2
        }
    }

    func gridMask(level: Int, want: UInt8) -> [UInt8] {
        var m = [UInt8](repeating: 0, count: gridW * gridH)
        let p = Self.pad, w = TableGeometry.width
        for gy in 0..<gridH {
            for gx in 0..<gridW {
                let x = gx - p, y = gy - p
                if y >= TableGeometry.height { continue }   // below the table: open (drain)
                if x < 0 || x >= w || y < 0 {
                    if want == 1 { m[gy * gridW + gx] = 1 }   // outside the art: wall
                    continue
                }
                if classes[level][y * w + x] == want { m[gy * gridW + gx] = 1 }
            }
        }
        return m
    }

    func rebuildWorld(_ e: ClassicEngine) {
        let n = TableGeometry.width * TableGeometry.height
        classes = (0..<2).map { l in
            var c = [UInt8](repeating: 0, count: n)
            for p in 0..<n { c[p] = classOf(e, level: l, value: e.buffer[p], pixel: p) }
            return c
        }
        walls = (0..<2).map { DistanceField(originX: -Self.pad, originY: -Self.pad, w: gridW, h: gridH, solid: gridMask(level: $0, want: 1)) }
        actives = (0..<2).map { DistanceField(originX: -Self.pad, originY: -Self.pad, w: gridW, h: gridH, solid: gridMask(level: $0, want: 2)) }
        builtGeneration = e.bufferGeneration
        builtDynState = e.dynState
        builtLUT = e.wallLUT
        e.bufferWriteLog?.removeAll()
        stats.fieldUpdates += 1
    }

    /// Re-derives the classes of `pixels` and updates the fields where they changed.
    func updatePixels(_ e: ClassicEngine, _ pixels: [Int]) {
        let w = TableGeometry.width
        var wc: [[(Int, Int, Bool)]] = [[], []], ac: [[(Int, Int, Bool)]] = [[], []]
        for p in Set(pixels) where p >= 0 && p < e.buffer.count {
            for l in 0..<2 {
                let c = classOf(e, level: l, value: e.buffer[p], pixel: p)
                let old = classes[l][p]
                guard c != old else { continue }
                classes[l][p] = c
                let gx = p % w + Self.pad, gy = p / w + Self.pad
                if old == 1 || c == 1 { wc[l].append((gx, gy, c == 1)) }
                if old == 2 || c == 2 { ac[l].append((gx, gy, c == 2)) }
            }
        }
        for l in 0..<2 {
            if !wc[l].isEmpty { walls[l].update(cells: wc[l]); stats.fieldUpdates += 1 }
            if !ac[l].isEmpty { actives[l].update(cells: ac[l]); stats.fieldUpdates += 1 }
        }
    }

    func refreshWorld(_ e: ClassicEngine) {
        if e.bufferGeneration != builtGeneration {
            // Power-on reset: the buffer is the start-up buffer again; diff against it.
            let n = TableGeometry.width * TableGeometry.height
            var changed: [Int] = []
            for l in 0..<2 {
                for p in 0..<n where classOf(e, level: l, value: e.buffer[p], pixel: p) != classes[l][p] { changed.append(p) }
            }
            updatePixels(e, changed)
            builtGeneration = e.bufferGeneration
            e.bufferWriteLog?.removeAll()
        }
        if e.dynState != builtDynState || e.wallLUT[0] != builtLUT[0] || e.wallLUT[1] != builtLUT[1] {
            builtDynState = e.dynState
            builtLUT = e.wallLUT
            let n = TableGeometry.width * TableGeometry.height
            var changed: [Int] = []
            for l in 0..<2 {
                for p in 0..<n where classOf(e, level: l, value: e.buffer[p], pixel: p) != classes[l][p] { changed.append(p) }
            }
            updatePixels(e, changed)
        }
        if let log = e.bufferWriteLog, !log.isEmpty {
            updatePixels(e, log)
            e.bufferWriteLog?.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - BallPhysics

    public func frameGravity(_ e: ClassicEngine, ball i: Int, amount: Int16) -> Bool {
        guard bodies[i].active else { return false }   // not simulated here: the integer add
        let g = Double(amount) / 128 * config.gravityScale
        bodies[i].gravityBudget += g
        bodies[i].gravityRate = g / Double(e.data.timing.stepsPerFrame * max(1, config.substeps))
        return true
    }

    public func step(_ e: ClassicEngine) {
        e.refreshDynamicClasses()
        refreshWorld(e)
        stepReport = StepReport()
        e.collidedThisStep = false
        // The flippers move by one angle index per step exactly as in the original (sounds,
        // outlines, sprites); the physics sees them rotate continuously during the step.
        alphaStart = e.groups.map { Double($0.angle) }
        e.flipperUpdate()
        alphaEnd = e.groups.map { Double($0.angle) }
        syncIn(e)
        for i in 0..<5 {
            bodies[i].onFlipper = false
            bodies[i].kickedThisStep = false; bodies[i].nudgedThisStep = false
            bodies[i].bigHitThisStep = false; bodies[i].ruleTimerThisStep = false
        }
        let n = max(1, config.substeps)
        let dt = 1.0 / Double(n)
        for s in 0..<n {
            subIndex = s
            let tau = Double(s + 1) / Double(n)
            alphaNow = zip(alphaStart, alphaEnd).map { $0 + ($1 - $0) * tau }
            for i in 0..<5 where bodies[i].active { substep(e, i, dt) }
            ballBall(e)
            stats.substeps += 1
        }
        alphaNow = alphaEnd
        for i in 0..<5 where bodies[i].active { ballSearch(e, i) }
        syncOut(e)
        stepReport.collided = e.collidedThisStep
        e.finishExternalStep(stepReport)
    }

    // MARK: - Sync with the integer ball fields

    func centre(of b: BallState) -> SIMD2<Double> {
        SIMD2(Double(b.x) + Double(b.accx) / 128, Double(b.y) + Double(b.accy) / 128) + centreOffset
    }

    func syncIn(_ e: ClassicEngine) { for i in 0..<5 { syncIn(e, i) } }

    func syncIn(_ e: ClassicEngine, _ i: Int) {
        let s = e.balls[i]
        var b = bodies[i]
        let simulate = s.active == 1
        if !simulate {
            if b.active { b.active = false; b.gravityBudget = 0 }
            b.written = s
            bodies[i] = b
            return
        }
        if !b.active || b.written == nil {
            b = Body()
            b.active = true
            b.c = centre(of: s)
            b.v = SIMD2(Double(s.vx), Double(s.vy)) / 128
            b.lastGood = (b.c, b.v)
        } else if let w = b.written {
            if s.x != w.x || s.y != w.y || s.accx != w.accx || s.accy != w.accy { b.c = centre(of: s) }
            if s.vx != w.vx { b.v.x = s.vx == 0 ? 0 : b.v.x + Double(Int(s.vx) - Int(w.vx)) / 128 }
            if s.vy != w.vy { b.v.y = s.vy == 0 ? 0 : b.v.y + Double(Int(s.vy) - Int(w.vy)) / 128 }
            if s.x != w.x || s.y != w.y || s.vx != w.vx || s.vy != w.vy { b.stillSteps = 0 }   // rule code moves it
        }
        b.layer = s.layer
        b.written = s
        bodies[i] = b
    }

    func syncOut(_ e: ClassicEngine) { for i in 0..<5 where bodies[i].active { syncOut(e, i) } }

    func syncOut(_ e: ClassicEngine, _ i: Int) {
        var s = e.balls[i]
        let t = bodies[i].c - centreOffset
        let fx = t.x.rounded(.down), fy = t.y.rounded(.down)
        s.x = Int16(clamping: Int(fx)); s.y = Int16(clamping: Int(fy))
        s.accx = Int16(clamping: Int(((t.x - fx) * 128).rounded(.down)))
        s.accy = Int16(clamping: Int(((t.y - fy) * 128).rounded(.down)))
        s.vx = Int16(clamping: Int((bodies[i].v.x * 128).rounded()))
        s.vy = Int16(clamping: Int((bodies[i].v.y * 128).rounded()))
        e.balls[i] = s
        bodies[i].written = s
    }

    // MARK: - Substep

    struct Contact {
        enum Kind { case wall, kicker, flipper(Int) }
        var kind: Kind
        /// Outward surface normal (from the wall towards the ball).
        var normal: SIMD2<Double>
        /// How far the ball's outline is inside the surface (> 0: penetrating).
        var depth: Double
        var point: SIMD2<Double>
        var surfaceVelocity: SIMD2<Double>
    }

    /// Contact radius (ball centre to a pixel edge at first contact) for outward normal `n`.
    public func contactRadius(normal n: SIMD2<Double>) -> Double {
        guard n.x != 0 || n.y != 0 else { return maxContactRadius }
        var a = atan2(n.y, n.x) * 180 / .pi
        if a < 0 { a += 360 }
        let i0 = Int(a.rounded(.down)) % 360, t = a - a.rounded(.down)
        return ringRadius[i0] + (ringRadius[(i0 + 1) % 360] - ringRadius[i0]) * t + config.contactPadding
    }

    /// The top-left y at or beyond which the original skips all collisions (0x180).
    func collides(_ e: ClassicEngine, _ c: SIMD2<Double>) -> Bool {
        (c.y - centreOffset.y).rounded(.down) < Double(e.data.integration.collisionYLimit)
    }

    func activeContactAllowed(_ e: ClassicEngine, _ i: Int, _ c: SIMD2<Double>) -> Bool {
        let k = e.data.kicker
        if e.kickerCoolingNow && k.coolingContact == false { return false }
        if let win = k.window, !win.isEmpty {
            let t = c - centreOffset
            let x = UInt16(truncatingIfNeeded: Int(t.x.rounded(.down))), y = UInt16(truncatingIfNeeded: Int(t.y.rounded(.down)))
            for w in win {
                let cv = w.coord == "x" ? x : y
                let val = UInt16(truncatingIfNeeded: w.value)
                switch w.noContactIf {
                case "ja": if cv > val { return false }
                case "jae": if cv >= val { return false }
                case "jb": if cv < val { return false }
                case "jbe": if cv <= val { return false }
                default: break
                }
            }
        }
        return true
    }

    func flipperCollides(_ e: ClassicEngine, _ f: FlipperShape, level: Int) -> Bool {
        let v = e.data.flipperGroups[f.group].value & 0xFF
        return e.wallLUT[level][v] != .empty
    }

    /// A collision obstacle for ball `i`: exact distance, smoothed gradient.
    enum Obstacle { case wall(Int), active(Int), flipper(Int) }

    func obstacles(_ e: ClassicEngine, _ i: Int, _ c: SIMD2<Double>) -> [Obstacle] {
        guard collides(e, c) else { return [] }
        let l = bodies[i].layer == 1 ? 1 : 0
        var o: [Obstacle] = [.wall(l)]
        if !actives[l].isEmpty && activeEnabled(e, i, c) { o.append(.active(l)) }
        for f in flippers where flipperCollides(e, f, level: l) { o.append(.flipper(f.index)) }
        return o
    }

    /// `activeContactAllowed` with the ghost hysteresis (updated once per substep in `substep`).
    func activeEnabled(_ e: ClassicEngine, _ i: Int, _ c: SIMD2<Double>) -> Bool {
        !bodies[i].activeGhost && activeContactAllowed(e, i, c)
    }

    func updateActiveGhost(_ e: ClassicEngine, _ i: Int) {
        let l = bodies[i].layer == 1 ? 1 : 0
        guard !actives[l].isEmpty else { bodies[i].activeGhost = false; return }
        let c = bodies[i].c
        let overlapping = actives[l].sampleRaw(c.x, c.y) < maxContactRadius - 0.5
        if !activeContactAllowed(e, i, c) {
            bodies[i].activeGhost = overlapping
        } else if bodies[i].activeGhost && !overlapping {
            bodies[i].activeGhost = false
        }
    }

    @inline(__always)
    func rawDistance(_ o: Obstacle, _ p: SIMD2<Double>) -> Double {
        switch o {
        case let .wall(l): return walls[l].sampleRaw(p.x, p.y)
        case let .active(l): return actives[l].sampleRaw(p.x, p.y)
        case let .flipper(f): return flippers[f].rawValue(p, alpha: alphaNow[flippers[f].group])
        }
    }

    @inline(__always)
    func gradient(_ o: Obstacle, _ p: SIMD2<Double>) -> SIMD2<Double> {
        let s: FieldSample
        switch o {
        case let .wall(l): s = walls[l].sample(p.x, p.y)
        case let .active(l): s = actives[l].sample(p.x, p.y)
        case let .flipper(f): s = flippers[f].sample(p, alpha: alphaNow[flippers[f].group])
        }
        return SIMD2(s.gx, s.gy)
    }

    /// Clearance at `c`: exact distance to the nearest obstacle minus the largest contact radius
    /// (a lower bound on how far the ball can move before any part of it touches).
    func clearance(_ e: ClassicEngine, _ i: Int, _ c: SIMD2<Double>) -> Double {
        let obs = obstacles(e, i, c)
        guard !obs.isEmpty else { return .greatestFiniteMagnitude }
        let rm = maxContactRadius
        var d = Double.greatestFiniteMagnitude
        for o in obs { d = min(d, rawDistance(o, c) - rm) }
        return d
    }

    /// Contacts of the ball outline at `c`: for each obstacle the perimeter points inside (or
    /// within `slop` of) it, grouped into runs of neighbouring points with similar normals; one
    /// contact per run (deepest depth, depth-weighted normal). A ball in a narrow channel gets
    /// one contact per side.
    func contacts(_ e: ClassicEngine, _ i: Int, _ c: SIMD2<Double>, slop: Double) -> [Contact] {
        let obs = obstacles(e, i, c)
        guard !obs.isEmpty else { return [] }
        let rm = maxContactRadius
        let per = perimeter
        let n = per.count
        var out: [Contact] = []
        for o in obs {
            if rawDistance(o, c) - rm > slop + 0.01 { continue }
            var any = false
            for j in 0..<n {
                let p = c + per[j].u * per[j].r
                let d = -rawDistance(o, p)
                scratchDepth[j] = d
                scratchIn[j] = d > -slop
                if d > -slop {
                    any = true
                    // Normal from the smoothed field 1 px inside the ball (clear of thin walls' far side).
                    var g = gradient(o, p - per[j].u)
                    let gl = (g * g).sum().squareRoot()
                    g = gl > 0.2 ? g / gl : -per[j].u
                    scratchNorm[j] = g
                }
            }
            guard any else { continue }
            let depth = scratchDepth, norm = scratchNorm, inRun = scratchIn
            // Runs of penetrating points (circular), split where the normal turns by > 50 degrees.
            var startJ = 0
            if inRun.allSatisfy({ $0 }) { startJ = 0 } else { while inRun[startJ] { startJ = (startJ + 1) % n }; startJ = (startJ + 1) % n }
            var k = 0
            var run: [Int] = []
            func flush() {
                guard !run.isEmpty else { return }
                var nsum = SIMD2<Double>(0, 0), psum = SIMD2<Double>(0, 0), dmax = -slop
                for j in run {
                    let w = depth[j] + slop + 1e-3
                    nsum += norm[j] * w
                    psum += per[j].u * per[j].r
                    dmax = max(dmax, depth[j])
                }
                let l = (nsum * nsum).sum().squareRoot()
                let nn = l > 1e-9 ? nsum / l : -(psum / Double(run.count)) / max(1e-9, ((psum * psum).sum().squareRoot() / Double(run.count)))
                let pt = c + psum / Double(run.count)
                var kind: Contact.Kind = .wall
                var vs = SIMD2<Double>(0, 0)
                switch o {
                case .wall: kind = .wall
                case .active: kind = .kicker
                case let .flipper(fi):
                    kind = .flipper(fi)
                    let f = flippers[fi]
                    vs = f.surfaceVelocity(at: pt, omega: flipperOmega(f))
                }
                out.append(Contact(kind: kind, normal: nn, depth: dmax, point: pt, surfaceVelocity: vs))
                run.removeAll()
            }
            var j = startJ
            while k < n {
                if inRun[j] {
                    if let last = run.last, (norm[last] * norm[j]).sum() < 0.64 { flush() }
                    run.append(j)
                } else { flush() }
                j = (j + 1) % n
                k += 1
            }
            flush()
        }
        // The nearest feature seen from the centre (a single pixel can fall between two outline
        // points): deepen the matching contact or add one.
        for o in obs {
            let g = gradient(o, c)
            let gl = (g * g).sum().squareRoot()
            guard gl > 0.75 else { continue }   // on a ridge: the outline points see both sides
            let nn = g / gl
            let dc = contactRadius(normal: nn) - rawDistance(o, c)
            guard dc > -slop else { continue }
            if let k = out.indices.first(where: { sameObstacle(out[$0].kind, o) && (out[$0].normal * nn).sum() > 0.8 }) {
                if dc > out[k].depth { out[k].depth = dc }
                continue
            }
            var kind: Contact.Kind = .wall
            var vs = SIMD2<Double>(0, 0)
            let pt = c - nn * contactRadius(normal: nn)
            switch o {
            case .wall: kind = .wall
            case .active: kind = .kicker
            case let .flipper(fi):
                kind = .flipper(fi)
                let f = flippers[fi]
                vs = f.surfaceVelocity(at: pt, omega: flipperOmega(f))
            }
            out.append(Contact(kind: kind, normal: nn, depth: dc, point: pt, surfaceVelocity: vs))
        }
        return out
    }

    /// Angular velocity (rad per step) of flipper `f` in the current step, times `flipperGain`.
    func flipperOmega(_ f: FlipperShape) -> Double {
        f.rotation(from: alphaStart[f.group], to: alphaEnd[f.group]) * config.flipperGain
    }

    func sameObstacle(_ k: Contact.Kind, _ o: Obstacle) -> Bool {
        switch (k, o) {
        case (.wall, .wall), (.kicker, .active): return true
        case let (.flipper(a), .flipper(b)): return a == b
        default: return false
        }
    }

    func substep(_ e: ClassicEngine, _ i: Int, _ dt: Double) {
        var b = bodies[i]
        // Gravity for this frame, spread over its substeps.
        if b.gravityBudget != 0 {
            let dv = b.gravityBudget > 0 ? min(b.gravityBudget, abs(b.gravityRate)) : max(b.gravityBudget, -abs(b.gravityRate))
            b.v.y += dv
            b.gravityBudget -= dv
            if abs(b.gravityBudget) < 1e-12 { b.gravityBudget = 0 }
        }
        if config.rollingDrag > 0 { b.v *= 1 - config.rollingDrag * dt }
        bodies[i] = b
        updateActiveGhost(e, i)
        // 1. Contacts at the start (flippers move, teleports, gates).
        resolve(e, i)
        // 2. Swept advance: never move further than the clearance.
        var remaining = dt
        var iter = 0
        while remaining > 1e-12 {
            iter += 1
            if iter > 24 { stats.sweepExhausted += 1; break }
            let mv = motionVelocity(e, bodies[i].v)
            let speed = (mv * mv).sum().squareRoot()
            if speed * remaining < 1e-9 { break }
            let d = clearance(e, i, bodies[i].c)
            if d >= speed * remaining * 1.4143 {
                bodies[i].c += mv * remaining
                remaining = 0
                break
            }
            if d > 0.25 {
                // Bilinear fields are sqrt(2)-Lipschitz at worst.
                let t = min(remaining, d / 1.4143 / speed)
                bodies[i].c += mv * t
                remaining -= t
                continue
            }
            // In contact: respond, then move on (now sliding or separating) by at most 0.3 px
            // beyond the clearance, so no outline point can get more than 0.3 px into a wall
            // (half of the thinnest wall) before the next contact pass.
            resolve(e, i)
            let mv2 = motionVelocity(e, bodies[i].v)
            let s2 = (mv2 * mv2).sum().squareRoot()
            let d2 = clearance(e, i, bodies[i].c)
            let allowed = max(d2, 0) + 0.3
            if s2 * remaining > allowed {
                let t = min(remaining, allowed / max(s2, 1e-9))
                bodies[i].c += mv2 * t
                remaining -= t
                resolve(e, i)
            } else {
                bodies[i].c += mv2 * remaining
                remaining = 0
            }
        }
        // 3. Penetration correction and responses at the end position.
        resolve(e, i)
        b = bodies[i]
        // Velocity safety cap (magnitude).
        let sp = (b.v * b.v).sum().squareRoot()
        if sp > config.speedCap { b.v *= config.speedCap / sp }
        // The original's edge clamps (cs:17A8.. / cs:1813), as a last resort.
        let ig = e.data.integration
        var t = b.c - centreOffset
        if let mx = ig.maxX, t.x > Double(mx) + 1 { t.x = Double(mx); stats.edgeClamps += 1 }
        if t.x < Double(ig.minX) { t.x = Double(ig.minXSet ?? ig.minX); stats.edgeClamps += 1 }
        if t.y < Double(ig.minY) && b.v.y < 0 { t.y = Double(ig.yReset); b.v.y = 0; stats.edgeClamps += 1 }
        b.c = t + centreOffset
        if !(b.c.x.isFinite && b.c.y.isFinite && b.v.x.isFinite && b.v.y.isFinite && b.spin.isFinite) {
            (b.c, b.v) = b.lastGood
            b.spin = 0
            stats.nanResets += 1
        } else {
            b.lastGood = (b.c, b.v)
        }
        bodies[i] = b
    }

    /// Velocity used for motion: the original moves at most `step_cap` px per step per axis.
    func motionVelocity(_ e: ClassicEngine, _ v: SIMD2<Double>) -> SIMD2<Double> {
        guard config.classicAxisCaps else { return v }
        let c = e.data.integration.stepCap
        return SIMD2(min(Double(c.xPos), max(-Double(c.xNeg), v.x)), min(Double(c.yPos), max(-Double(c.yNeg), v.y)))
    }

    /// True when no outline point of a ball centred at `p` is inside an obstacle.
    func isFree(_ e: ClassicEngine, _ i: Int, _ p: SIMD2<Double>) -> Bool {
        let obs = obstacles(e, i, p)
        let rmin = minContactRadius
        for o in obs {
            let dc = rawDistance(o, p)
            if dc < rmin - 0.05 { return false }
            if dc >= maxContactRadius { continue }
            for q in perimeter where rawDistance(o, p + q.u * q.r) < -0.05 { return false }
        }
        return true
    }

    /// The nearest free position within 16 px (rings of 32 directions, 0.5 px apart), for a ball
    /// that starts deep inside something (a level switch over a post, a gate drawn onto it, a
    /// teleport). The original's push-out loop does the same job one pixel at a time.
    func escape(_ e: ClassicEngine, _ i: Int) -> Bool {
        let c = bodies[i].c
        var d = 0.5
        while d <= 16 {
            for j in 0..<32 {
                let a = Double(j) * 2 * .pi / 32
                let p = c + d * SIMD2(cos(a), sin(a))
                if isFree(e, i, p) { bodies[i].c = p; return true }
            }
            d += 0.5
        }
        return false
    }

    /// Resolves all current contacts of ball `i` (a few relaxation passes).
    func resolve(_ e: ClassicEngine, _ i: Int) {
        for pass in 0..<4 {
            var cs = contacts(e, i, bodies[i].c, slop: 0.02)
            if cs.isEmpty { return }
            // Deep: an outline point more than 2 px in, or something smaller than the ball inside it.
            let rmin = minContactRadius
            if pass == 0, cs.contains(where: { $0.depth > 2 })
                || obstacles(e, i, bodies[i].c).contains(where: { rawDistance($0, bodies[i].c) < rmin - 2 }) {
                stats.deepContacts += 1
                if escape(e, i) {
                    stats.escapes += 1
                    cs = contacts(e, i, bodies[i].c, slop: 0.02)
                    if cs.isEmpty { return }
                }
            }
            var moved = false
            for c in cs {
                respond(e, i, c)
                if c.depth > 0 {
                    bodies[i].c += c.normal * min(c.depth, 2.0)
                    moved = true
                }
            }
            if !moved { return }
        }
    }

    // MARK: - Responses

    /// Fractional contact-direction index (1 ..< 49) of the contact point direction `-n`.
    func directionIndex(_ n: SIMD2<Double>) -> Double {
        var a = atan2(n.y, -n.x) * 180 / .pi   // angle of -n with y up: atan2(-(-n.y), -n.x)
        if a < probeAngles[0] { a += 360 }
        if a >= probeAngles[48] { a -= 360 }
        var k = 0
        while k < 47 && probeAngles[k + 1] <= a { k += 1 }
        let t = (a - probeAngles[k]) / (probeAngles[k + 1] - probeAngles[k])
        return Double(k + 1) + min(1, max(0, t))
    }

    /// For each whole degree of outward wall normal: which contact directions the original's
    /// probe ring and `contact_direction` (cs:1A66) produce for a straight wall penetrating the
    /// ring by 0 .. 2 px (sampled every 0.05 px), the mean table normal over them and the most
    /// frequent direction.
    static func classicDirectionTable(ring: [SIMD2<Double>], centre: SIMD2<Double>, normals: [SIMD2<Double>])
        -> ([SIMD2<Double>], [UInt8], [[(Int, Double)]]) {
        var ns: [SIMD2<Double>] = [], ks: [UInt8] = [], ws: [[(Int, Double)]] = []
        for deg in 0..<360 {
            let a = Double(deg) * .pi / 180
            let inward = -SIMD2(cos(a), sin(a))   // from the ball centre towards the wall
            let proj = ring.map { (($0 - centre) * inward).sum() }
            let deepest = proj.max() ?? 7
            var sum = SIMD2<Double>(0, 0), count = 0
            var hist = [Int](repeating: 0, count: 49)
            var d0 = deepest - 0.001
            while d0 > deepest - 2 {
                var hits: [UInt8] = []
                for k in stride(from: 48, through: 1, by: -1) where proj[k - 1] > d0 { hits.append(UInt8(k)) }
                if !hits.isEmpty {
                    let k = Int(ClassicEngine.contactDirection(hits))
                    sum += normals[k - 1]; count += 1; hist[k] += 1
                }
                d0 -= 0.05
            }
            ns.append(count > 0 ? sum / Double(count) : SIMD2(cos(a), sin(a)))
            ks.append(UInt8(hist.indices.max(by: { hist[$0] < hist[$1] }) ?? 1))
            ws.append(hist.indices.filter { hist[$0] > 0 }.map { ($0, Double(hist[$0]) / Double(max(1, count))) })
        }
        return (ns, ks, ws)
    }

    /// The original's reflection (cs:1C0A..1CF5) for direction k as a linear map dv = M v:
    /// dv = -(v.n) (20 nx / (divX |n|^2), 64 * 20 / (ny E divY)), E = 16 nx^2/ny^2 + 64, or 0x7FF8
    /// when (u16)(ny*ny) == 1 (the quirk that gives vertical walls a larger y impulse).
    static func classicMap(normal n: SIMD2<Double>, divX: Double, divY: Double) -> SIMD4<Double> {
        let nx = n.x, ny = n.y
        let ux = 20 * nx / (divX * (nx * nx + ny * ny))
        let e = abs(ny * ny - 1) < 1e-9 ? 32760 : 16 * nx * nx / (ny * ny) + 64
        let uy = 20 * 64 / (ny * e * divY)
        return SIMD4(-ux * nx, -ux * ny, -uy * nx, -uy * ny)
    }

    func refreshClassicMaps(_ e: ClassicEngine) {
        let p = e.params
        let key = [p[0], p[1], p[7], p[8]]
        guard key != mapParams else { return }
        mapParams = key
        classicMaps = (0..<2).map { l in
            let up = l == 1
            let dx = Double(p[0] &+ (up ? p[8] : 0)), dy = Double(p[1] &+ (up ? p[7] : 0))
            return classicDirWeights.map { ws in
                var m = SIMD4<Double>(0, 0, 0, 0)
                for (k, w) in ws { m += w * Self.classicMap(normal: tableNormals[k - 1], divX: dx == 0 ? 1 : dx, divY: dy == 0 ? 1 : dy) }
                return m
            }
        }
    }

    /// The averaged classic reflection map for smooth outward normal `n` on `level`.
    func classicMapFor(_ n: SIMD2<Double>, level: Int) -> SIMD4<Double> {
        var a = atan2(n.y, n.x) * 180 / .pi
        if a < 0 { a += 360 }
        let i0 = Int(a.rounded(.down)) % 360, t = a - a.rounded(.down)
        let x = classicMaps[level][i0], y = classicMaps[level][(i0 + 1) % 360]
        return x + (y - x) * t
    }

    /// The classic table normal for a smooth outward normal `n` (interpolated between degrees).
    func classicNormal(_ n: SIMD2<Double>) -> SIMD2<Double> {
        var a = atan2(n.y, n.x) * 180 / .pi
        if a < 0 { a += 360 }
        let i0 = Int(a.rounded(.down)) % 360, t = a - a.rounded(.down)
        let x = classicNormalByAngle[i0], y = classicNormalByAngle[(i0 + 1) % 360]
        return x + (y - x) * t
    }

    func classicDir(_ n: SIMD2<Double>) -> UInt8 {
        var a = atan2(n.y, n.x) * 180 / .pi
        if a < 0 { a += 360 }
        return classicDirByAngle[Int(a.rounded()) % 360]
    }

    /// The original's normal (-t0, t1) for a fractional direction index (interpolated).
    func tableNormal(_ kf: Double) -> SIMD2<Double> {
        let k0 = Int(kf.rounded(.down)) - 1
        let t = kf - kf.rounded(.down)
        let a = tableNormals[((k0 % 48) + 48) % 48], b = tableNormals[(k0 + 1) % 48]
        return a + (b - a) * t
    }

    static func roundDir(_ kf: Double) -> UInt8 {
        var k = Int(kf.rounded())
        if k > 48 { k -= 48 }
        if k < 1 { k += 48 }
        return UInt8(k)
    }

    /// cs:1C0A..1CF5 in floating point: the reflection impulse for velocity `v` against table
    /// normal `n` with divisors (divX, divY). Linear in `v`.
    public static func classicReflection(v: SIMD2<Double>, n: SIMD2<Double>, divX: Double, divY: Double) -> SIMD2<Double> {
        let m = classicMap(normal: n, divX: divX, divY: divY)
        return SIMD2(m.x * v.x + m.y * v.y, m.z * v.x + m.w * v.y)
    }

    func respond(_ e: ClassicEngine, _ i: Int, _ c: Contact) {
        var b = bodies[i]
        let n = c.normal
        guard (n * n).sum() > 0.5 else { return }
        let k = classicDir(n)
        let vrel = b.v - c.surfaceVelocity
        let vn = (vrel * n).sum()
        func log(flipper: UInt8 = 0, kick: UInt8 = 0) {
            let first = !e.collidedThisStep
            e.collidedThisStep = true
            if stepReport.firstDir == nil { stepReport.firstDir = k }
            stepReport.lastDir = k
            stepReport.responses += 1
            stepReport.log.append(ResponseRecord(ball: i, k: k, first: first, flipperContact: flipper, kick: kick))
        }
        switch c.kind {
        case .kicker:
            if !b.kickedThisStep && !e.kickerCoolingNow && (vn < 0 || c.depth > 0) {
                b.kickedThisStep = true
                bodies[i] = b
                syncOut(e, i)
                e.kickStrength = 0
                let v = nearestPixelValue(e, c: b.c, level: b.layer == 1 ? 1 : 0, cls: 2) ?? 0
                if !(e.rulesActive && e.rules!.kicker(ball: i, contact: v)) { e.kickerHit(ball: i) }
                syncIn(e, i)   // rule code may have moved the ball
                b = bodies[i]
                let kick = Double(e.kickStrength)
                e.kickStrength = 0
                if kick != 0 {
                    stats.kicks += 1
                    let tn = classicNormal(n)
                    let vn2 = ((b.v - c.surfaceVelocity) * n).sum()
                    if config.kickerRestitution > 0 && vn2 < 0 { b.v -= (1 + config.kickerRestitution) * vn2 * n }
                    if config.kickerAlongTableNormal {
                        b.v += kick * tn / 128 * config.kickerScale
                    } else {
                        b.v += kick * (tn * tn).sum().squareRoot() / 128 * config.kickerScale * n
                    }
                    log(kick: UInt8(kick))
                    bodies[i] = b
                    return
                }
            }
            fallthrough
        case .wall:
            b.supportNormal = n
            guard vn < 0 else { bodies[i].supportNormal = n; return }
            stats.wallImpacts += 1
            if !b.bigHitThisStep && e.rulesActive && -vn > config.restingSpeed {
                b.bigHitThisStep = true
                bodies[i] = b
                bigHit(e, i, n)
                b = bodies[i]
            }
            if -vn < config.restingSpeed {
                b.v -= vn * n   // resting contact: no bounce
            } else {
                switch config.wallResponse {
                case .classicMap:
                    refreshClassicMaps(e)
                    let m = classicMapFor(n, level: b.layer == 1 ? 1 : 0)
                    b.v += SIMD2(m.x * b.v.x + m.y * b.v.y, m.z * b.v.x + m.w * b.v.y)
                    let after = (b.v * n).sum()
                    if after < 0 { b.v -= after * n }   // never leave it approaching
                    let tng = SIMD2(-n.y, n.x)
                    let vt0 = (vrel * tng).sum()
                    let sin2 = vt0 * vt0 / max(1e-12, vt0 * vt0 + vn * vn)
                    let loss = min(0.9, max(0, config.wallTangentialLoss + config.wallGrazingLoss * sin2))
                    if loss > 0 { b.v -= loss * (b.v * tng).sum() * tng }
                case .restitution:
                    b.v -= (1 + config.wallRestitution) * vn * n
                    applyFriction(&b, n: n, jn: -(1 + config.wallRestitution) * vn, mu: config.wallFriction, surface: .zero)
                }
            }
            nudgeImpulse(e, i, &b, k)
            log()
        case let .flipper(fi):
            b.onFlipper = true
            bodies[i].onFlipper = true
            guard vn < 0 else { return }
            stats.flipperImpacts += 1
            let e0 = -vn < config.restingSpeed ? 0 : config.flipperRestitution
            let jn = -(1 + e0) * vn
            b.v += jn * n
            applyFriction(&b, n: n, jn: jn, mu: config.flipperFriction, surface: c.surfaceVelocity)
            let g = flippers[fi].group
            let moving = alphaEnd[g] < alphaStart[g]
            if moving { upperKickTimer(e, i, &b) }
            log(flipper: moving ? UInt8(1 + (g % 2)) : 0)
        }
        bodies[i] = b
    }

    /// Kicks a ball that has sat still for `ballSearchSeconds` (see `EnhancedPhysicsConfig`).
    func ballSearch(_ e: ClassicEngine, _ i: Int) {
        guard config.ballSearchSeconds > 0 else { return }
        var b = bodies[i]
        let t = b.c - centreOffset
        let lane = t.x >= Double(e.data.plunger.laneMinX) && t.y >= Double(e.data.plunger.laneMinY)
        let still = (b.v * b.v).sum() < 0.03 * 0.03
        if !still || lane || b.onFlipper || e.tilted { b.stillSteps = 0; bodies[i] = b; return }
        b.stillSteps += 1
        let limit = Int(config.ballSearchSeconds * e.data.timing.frameHz) * e.data.timing.stepsPerFrame
        if b.stillSteps >= limit {
            b.stillSteps = 0
            b.searches += 1
            // Along the most open direction (ray-marched, upper half, alternating between the two
            // best on repeated searches), falling back to the support normal.
            bodies[i] = b
            let dir = searchDirection(e, i, alternate: b.searches % 2 == 0) ?? b.supportNormal
            b.v += dir * config.ballSearchKick
            stats.ballSearches += 1
        }
        bodies[i] = b
    }

    /// The direction (upper half plane) in which a ball at rest can travel furthest before touching
    /// anything (2 px ray steps up to 80 px, 32 directions).
    func searchDirection(_ e: ClassicEngine, _ i: Int, alternate: Bool) -> SIMD2<Double>? {
        let c = bodies[i].c
        var best: [(Double, SIMD2<Double>)] = []
        for j in 0..<32 {
            let a = Double(j) * 2 * .pi / 32
            let u = SIMD2(cos(a), sin(a))
            guard u.y <= 0.1 else { continue }
            var d = 2.0
            while d <= 80 && isFree(e, i, c + u * d) { d += 2 }
            best.append((d, u))
        }
        best.sort { $0.0 > $1.0 }
        guard let first = best.first, first.0 > 4 else { return nil }
        if alternate, best.count > 1, best[1].0 > first.0 * 0.75 { return best[1].1 }
        return first.1
    }

    func applyFriction(_ b: inout Body, n: SIMD2<Double>, jn: Double, mu: Double, surface: SIMD2<Double>) {
        let tng = SIMD2(-n.y, n.x)
        let vt = ((b.v - surface) * tng).sum()
        if config.spin {
            // Rolling contact: slip = vt + spin; a solid sphere takes 2/7 of the correction in v.
            let slip = vt + b.spin
            var dv = -slip * config.spinCoupling * 2 / 7
            if mu > 0 { dv = max(-mu * jn, min(mu * jn, dv)) }
            b.v += dv * tng
            b.spin += dv * 5 / 2
            b.spin *= 0.999
        } else if mu > 0 {
            let dv = max(-mu * jn, min(mu * jn, -vt))
            b.v += dv * tng
        }
    }

    /// cs:1D06: the nudge impulse after a wall response (once per step per ball here).
    func nudgeImpulse(_ e: ClassicEngine, _ i: Int, _ b: inout Body, _ k: UInt8) {
        guard !b.nudgedThisStep else { return }
        let ni = e.data.nudgeImpulse
        if let sk = ni.skipSlots, sk.contains(i) { return }
        guard e.nudgeTimer >= UInt8(truncatingIfNeeded: ni.minTimer),
              k >= UInt8(truncatingIfNeeded: ni.dirMin), k <= UInt8(truncatingIfNeeded: ni.dirMax) else { return }
        b.nudgedThisStep = true
        var dvx = 0, dvy = -(Int(e.nudgeTimer) << ni.vyShift)
        let kx = ni.vx
        dvx += kx
        if !e.input.contains(.nudgeA) {
            if !e.input.contains(.nudgeB) { dvx += kx }
            dvx -= kx * 2
        }
        b.v += SIMD2(Double(dvx), Double(dvy)) / 128
    }

    /// EP4 cs:1CE8 (upper flipper kick): the rule timer write when a moving upper flipper hits.
    func upperKickTimer(_ e: ClassicEngine, _ i: Int, _ b: inout Body) {
        let fk = e.data.flipperKick
        guard !b.ruleTimerThisStep, let top = fk.topMinY, let uk = fk.upperKick else { return }
        let t = b.c - centreOffset
        guard t.y < Double(top) else { return }
        let side: EngineData.FlipperKick.UpperKick.Side
        if let sx = uk.splitX, let left = uk.left, t.x < Double(sx) { side = left } else { side = uk.right }
        b.ruleTimerThisStep = true
        if let rt = side.ruleTimer, let addr = ClassicEngine.hexAddr(rt.var) { e.dsWrite(addr, rt.size, rt.value) }
    }

    /// cs:18C5 hard-hit glue: the probe hits of the ball 1 px into the wall, pre-impact velocity.
    func bigHit(_ e: ClassicEngine, _ i: Int, _ n: SIMD2<Double>) {
        guard let r = e.rules else { return }
        let saved = bodies[i].c
        bodies[i].c -= n
        let pushed = bodies[i].c
        syncOut(e, i)
        e.setHitList(probeHits(e, e.balls[i]))
        r.runRange("bigHit", di: 2 * i)
        syncIn(e, i)                                 // velocity deltas / teleports by the glue
        if bodies[i].c == pushed { bodies[i].c = saved }
        e.setHitList([])
    }

    /// The original's probe ring over the wall classes (no side effects).
    func probeHits(_ e: ClassicEngine, _ s: BallState) -> [UInt8] {
        let rowBase = Int(UInt16(bitPattern: s.y)) * TableGeometry.width
        let lut = e.wallLUT[s.layer == 1 ? 1 : 0]
        var hits: [UInt8] = []
        for k in stride(from: 48, through: 1, by: -1) {
            let o = rowBase + Int(UInt16(bitPattern: s.x) &+ e.ring[k - 1])
            if lut[Int(e.pixel(o))] != .empty { hits.append(UInt8(k)) }
        }
        return hits
    }

    /// Palette index of the nearest pixel of class `cls` around centre `c`.
    func nearestPixelValue(_ e: ClassicEngine, c: SIMD2<Double>, level: Int, cls: UInt8) -> UInt8? {
        let w = TableGeometry.width, h = TableGeometry.height
        let r = Int(maxContactRadius.rounded(.up)) + 3
        let cx = Int(c.x.rounded(.down)), cy = Int(c.y.rounded(.down))
        var best: (Double, UInt8)?
        for y in max(0, cy - r)...min(h - 1, max(0, cy + r)) {
            for x in max(0, cx - r)...min(w - 1, max(0, cx + r)) where classes[level][y * w + x] == cls {
                let d = (Double(x) + 0.5 - c.x) * (Double(x) + 0.5 - c.x) + (Double(y) + 0.5 - c.y) * (Double(y) + 0.5 - c.y)
                if best == nil || d < best!.0 { best = (d, e.buffer[y * w + x]) }
            }
        }
        return best?.1
    }

    // MARK: - Ball-ball (pairs (0,1), (0,2), (1,2) like cs:1903..19BB)

    func ballBall(_ e: ClassicEngine) {
        for (a, b) in [(0, 1), (0, 2), (1, 2)] where bodies[a].active && bodies[b].active && bodies[a].layer == bodies[b].layer {
            let d = bodies[a].c - bodies[b].c
            let dist = (d * d).sum().squareRoot()
            let r2 = 2 * config.ballRadius
            guard dist < r2 else { continue }
            let n = dist > 1e-9 ? d / dist : SIMD2(0, -1)
            let pen = r2 - dist
            bodies[a].c += n * (pen / 2)
            bodies[b].c -= n * (pen / 2)
            let vrel = ((bodies[a].v - bodies[b].v) * n).sum()
            if vrel < 0 {
                let j = -(1 + config.ballBallRestitution) * vrel / 2
                bodies[a].v += j * n
                bodies[b].v -= j * n
                stats.ballBallImpacts += 1
            }
        }
    }

    // MARK: - Diagnostics

    /// How far ball `i` is inside solid pixels of its level (walls, kickers and the flipper outlines
    /// as drawn in the live buffer, classified by the wall LUT; independent of the distance fields
    /// and flipper shapes; at the end of a step the flippers stand exactly at their drawn angle):
    /// the contact radius (in the direction of the pixel) minus the
    /// exact distance from the ball centre to the nearest solid pixel square (<= 0: not touching).
    public func wallPenetration(_ e: ClassicEngine, ball i: Int) -> Double {
        guard bodies[i].active else { return -.greatestFiniteMagnitude }
        let c = bodies[i].c
        guard collides(e, c) else { return -.greatestFiniteMagnitude }
        let l = bodies[i].layer == 1 ? 1 : 0
        let w = TableGeometry.width, h = TableGeometry.height
        let r = Int(maxContactRadius.rounded(.up)) + 2
        let cx = Int(c.x.rounded(.down)), cy = Int(c.y.rounded(.down))
        var best = -Double.greatestFiniteMagnitude
        let allowActive = activeEnabled(e, i, c)
        for y in (cy - r)...(cy + r) {
            for x in (cx - r)...(cx + r) {
                let solid: Bool
                if y >= h { solid = false } else if x < 0 || x >= w || y < 0 { solid = true } else {
                    let v = e.buffer[y * w + x]
                    switch e.wallLUT[l][Int(v)] {
                    case .empty: solid = false
                    case .wall, .flipper: solid = true   // flipper outlines as drawn for the current angle
                    case .active: solid = allowActive && (e.data.kicker.activeMax.map { Int(v) <= $0 } ?? true)
                    }
                }
                guard solid else { continue }
                // Nearest point of the pixel square; the outward normal points from it to the centre.
                let q = SIMD2(min(max(c.x, Double(x)), Double(x + 1)), min(max(c.y, Double(y)), Double(y + 1)))
                let d = c - q
                let dist = (d * d).sum().squareRoot()
                let n = dist > 1e-9 ? d / dist : SIMD2<Double>(0, 0)
                best = max(best, contactRadius(normal: n) - dist)
            }
        }
        return best
    }

    /// Distance-field clearance of ball `i` including flippers (for tests).
    public func clearance(_ e: ClassicEngine, ball i: Int) -> Double {
        bodies[i].active ? clearance(e, i, bodies[i].c) : .greatestFiniteMagnitude
    }

    /// Wall field sample at a point (for tests and calibration).
    public func wallSample(level: Int, _ p: SIMD2<Double>) -> FieldSample { walls[level].sample(p.x, p.y) }
}
