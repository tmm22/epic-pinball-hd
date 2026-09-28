import Foundation

/// Measurement and fuzz tools for the enhanced physics (used by the tests and by
/// docs/enhanced/physics.md). Everything runs headless on a table's own engine data.
public enum EnhancedValidation {

    // MARK: - Synthetic scenes

    /// A palette index the level-0 wall LUT classes as `wall`, and one it classes as empty.
    public static func wallAndEmptyIndex(_ d: EngineData) -> (wall: UInt8, empty: UInt8)? {
        let codes = d.wall.codes
        func cls(_ v: Int) -> String { let c = d.wall.lut[0][v]; return codes.indices.contains(c) ? codes[c] : "empty" }
        guard let w = (0..<256).first(where: { cls($0) == "wall" }) else { return nil }
        let e = d.flipperEraseValue & 0xFF
        let empty = cls(e) == "empty" ? e : ((0..<256).first(where: { cls($0) == "empty" }) ?? 0)
        return (UInt8(w), UInt8(empty))
    }

    /// A 320x400 buffer that is empty except for the half plane behind a straight wall through
    /// `point` whose outward normal (pointing into the free side) is `normal`.
    public static func halfPlaneBuffer(_ d: EngineData, point: SIMD2<Double>, normal: SIMD2<Double>) -> [UInt8] {
        let (wall, empty) = wallAndEmptyIndex(d) ?? (0xD5, 0x2A)
        let w = TableGeometry.width, h = TableGeometry.height
        var b = [UInt8](repeating: empty, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let p = SIMD2(Double(x) + 0.5, Double(y) + 0.5) - point
                if (p * normal).sum() < 0 { b[y * w + x] = wall }
            }
        }
        return b
    }

    // MARK: - Bounce study (restitution per wall angle)

    public struct Bounce: Sendable {
        /// Outward wall normal angle (degrees, screen coordinates: 0 = +x, 90 = +y).
        public var wallAngle: Double
        /// Incidence angle from the normal (degrees; sign = side of the tangent).
        public var incidence: Double
        public var speed: Double
        public var vIn: SIMD2<Double>
        public var vOut: SIMD2<Double>?
        public var normal: SIMD2<Double>
        /// -(vOut.n)/(vIn.n)
        public var normalRestitution: Double? {
            guard let o = vOut else { return nil }
            return -(o * normal).sum() / (vIn * normal).sum()
        }
        /// (vOut.t)/(vIn.t) (nil for head-on shots)
        public var tangentialRatio: Double? {
            guard let o = vOut else { return nil }
            let t = SIMD2(-normal.y, normal.x)
            let a = (vIn * t).sum()
            return abs(a) < 0.1 * (vIn * vIn).sum().squareRoot() ? nil : (o * t).sum() / a
        }
        /// Direction of vOut (degrees, screen coordinates).
        public var outAngle: Double? { vOut.map { atan2($0.y, $0.x) * 180 / .pi } }
        public var outSpeed: Double? { vOut.map { ($0 * $0).sum().squareRoot() } }
    }

    /// Fires a ball (no gravity, no rules) at a straight wall and returns its velocity after it
    /// has left the wall. `config == nil` runs the classic integer engine.
    public static func bounce(data d: EngineData, wallAngle: Double, incidence: Double, speed: Double,
                              config: EnhancedPhysicsConfig?) throws -> Bounce {
        let a = wallAngle * .pi / 180
        let n = SIMD2(cos(a), sin(a))
        let t = SIMD2(-n.y, n.x)
        let centre = SIMD2<Double>(160, 200)
        let buf = halfPlaneBuffer(d, point: centre, normal: n)
        let e = try ClassicEngine(data: d, startBuffer: buf)
        e.resetToRest()
        e.sensorsEnabled = false
        for i in e.balls.indices { e.balls[i].active = 0 }
        let psi = incidence * .pi / 180
        let vIn = speed * (-cos(psi) * n + sin(psi) * t)
        // Start 9 px of clearance away, offset along the tangent so it hits near the centre.
        let start = centre + n * (7 + 9) - vIn / max(speed, 1e-9) * 0 - t * (9 * tan(psi))
        let tl = start - SIMD2(7.5, 7.0)
        var b = BallState()
        b.active = 1
        b.x = Int16(tl.x.rounded(.down)); b.y = Int16(tl.y.rounded(.down))
        b.accx = Int16(((tl.x - tl.x.rounded(.down)) * 128).rounded(.down))
        b.accy = Int16(((tl.y - tl.y.rounded(.down)) * 128).rounded(.down))
        b.vx = Int16((vIn.x * 128).rounded()); b.vy = Int16((vIn.y * 128).rounded())
        e.balls[0] = b
        let vInQ = SIMD2(Double(b.vx), Double(b.vy)) / 128
        var model: EnhancedPhysics?
        if let c = config { model = EnhancedPhysics.install(on: e, config: c) }
        var touched = false, free = 0
        for _ in 0..<600 {
            if let m = model { m.step(e) } else { e.physicsStep() }
            let v = SIMD2(Double(e.balls[0].vx), Double(e.balls[0].vy)) / 128
            let c = SIMD2(Double(e.balls[0].x) + Double(e.balls[0].accx) / 128 + 7.5, Double(e.balls[0].y) + Double(e.balls[0].accy) / 128 + 7.0)
            let dist = ((c - centre) * n).sum() - 7
            if e.lastStep.collided || dist < 1.0 { touched = true; free = 0; continue }
            if touched && (v * n).sum() > 0 {
                free += 1
                if free >= 3 { return Bounce(wallAngle: wallAngle, incidence: incidence, speed: speed, vIn: vInQ, vOut: v, normal: n) }
            }
        }
        return Bounce(wallAngle: wallAngle, incidence: incidence, speed: speed, vIn: vInQ, vOut: nil, normal: n)
    }

    // MARK: - Flipper shots

    public struct Shot: Sendable {
        /// Horizontal position of the ball box's left edge relative to the flipper pivot (px).
        public var offset: Int
        /// Frames between the ball's start and the flipper press.
        public var delay: Int
        public var vOut: SIMD2<Double>
        public var speed: Double { (vOut * vOut).sum().squareRoot() }
        /// Direction (degrees, screen: -90 = straight up).
        public var angle: Double { atan2(vOut.y, vOut.x) * 180 / .pi }
    }

    /// Ball box top-left y at which the ball just rests on the table's surface below x (no probe hit).
    static func restingY(_ e: ClassicEngine, x: Int16, from y0: Int16) -> Int16? {
        let lut = e.wallLUT[0]
        for y in y0..<Int16(380) {
            let rowBase = Int(y) * TableGeometry.width
            for k in 1...48 {
                let o = rowBase + Int(UInt16(bitPattern: x) &+ e.ring[k - 1])
                if lut[Int(e.pixel(o))] != .empty { return y - 1 }
            }
        }
        return nil
    }

    /// Flipper shots on a real table (rules off, sensors off): the ball starts `drop` px above the
    /// resting position on the left flipper group's first flipper, at `offset` px right of its
    /// pivot, falling at `vy0` px/step; the flipper is pressed after `delay` frames; the velocity is
    /// read 12 frames after the press. `config == nil` = classic engine.
    public static func flipperShot(data d: EngineData, buffer: [UInt8], offset: Int, delay: Int, drop: Int, vy0: Double,
                                   config: EnhancedPhysicsConfig?) throws -> Shot? {
        let e = try ClassicEngine(data: d, startBuffer: buffer)
        e.resetToRest()
        e.sensorsEnabled = false
        e.ballLostResets = false
        guard let fi = d.flippers.firstIndex(where: { d.flipperGroups[$0.group].key == "left" }) else { return nil }
        let shape = FlipperShape(index: fi, flipper: d.flippers[fi])
        let x = Int16(Int(shape.pivot.x) + offset)
        guard let ry = restingY(e, x: x, from: 250) else { return nil }
        for i in e.balls.indices { e.balls[i].active = 0 }
        e.balls[0] = BallState(x: x, y: ry - Int16(drop), vx: 0, vy: Int16((vy0 * 128).rounded()))
        if let c = config { EnhancedPhysics.install(on: e, config: c) }
        let group = d.flippers[fi].group
        let key: FrameInput = d.flipperGroups[group].key == "left" ? .leftFlipper : .rightFlipper
        for f in 0..<(delay + 12) {
            e.input = f >= delay ? key : []
            e.runFrame()
            if e.balls[0].active == 0 { return nil }
        }
        return Shot(offset: offset, delay: delay, vOut: SIMD2(Double(e.balls[0].vx), Double(e.balls[0].vy)) / 128)
    }

    // MARK: - Fuzz

    public struct FuzzReport: Sendable, CustomStringConvertible {
        public var table = 0
        public var launches = 0
        public var steps = 0
        public var nanResets = 0
        public var nonFinite = 0
        /// Steps that ended with the ball more than `tunnelDepth` px inside solid pixels.
        public var tunnelViolations = 0
        public var maxPenetration = 0.0
        public var sweepExhausted = 0
        public var deepContacts = 0
        public var drained = 0
        public var slowestLaunchSeconds = 0.0
        public var seconds = 0.0
        public var examples: [String] = []
        public var description: String {
            String(format: "EP%d: %d launches, %d steps, NaN %d/%d, tunnel>%.1fpx %d (max pen %.2f px), sweepExhausted %d, deep %d, drained %d, slowest launch %.1f ms, %.1f s",
                   table, launches, steps, nanResets, nonFinite, EnhancedValidation.tunnelDepth, tunnelViolations, maxPenetration,
                   sweepExhausted, deepContacts, drained, slowestLaunchSeconds * 1000, seconds)
        }
    }

    /// Penetration (px beyond the contact radius) that counts as tunnelling into a wall.
    public static let tunnelDepth = 2.0

    /// Deterministic PRNG (SplitMix64).
    public struct SplitMix: RandomNumberGenerator, Sendable {
        var s: UInt64
        public init(seed: UInt64) { s = seed }
        public mutating func next() -> UInt64 {
            s &+= 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Random launches on `engine` (physics only, the exported sensor handlers on): a ball at a
    /// random free spot of level 0 with a random velocity up to `maxSpeed` px/step, random flipper
    /// presses, `frames` frames or until it drains. Checks every step for non-finite state and for
    /// penetration deeper than `tunnelDepth` into the live collision buffer's solid pixels.
    public static func fuzz(engine e: ClassicEngine, config: EnhancedPhysicsConfig, launches: Int, frames: Int,
                            maxSpeed: Double = 8, seed: UInt64 = 1) -> FuzzReport {
        var rep = FuzzReport()
        rep.table = e.data.table
        e.resetToRest()
        e.rulesMode = .off
        e.sensorsEnabled = true
        e.ballLostResets = false
        let m = EnhancedPhysics.install(on: e, config: config)
        var rng = SplitMix(seed: seed &+ UInt64(e.data.table) &* 7919)
        let t0 = Date()
        var steps = 0
        e.onStep = { _, _, _ in
            steps += 1
            for i in 0..<5 where e.balls[i].active == 1 {
                if let c = m.ballCentre(i), let v = m.ballVelocity(i), !(c.x.isFinite && c.y.isFinite && v.x.isFinite && v.y.isFinite) {
                    rep.nonFinite += 1
                }
                let p = m.wallPenetration(e, ball: i)
                if p > rep.maxPenetration { rep.maxPenetration = p }
                if p > tunnelDepth {
                    rep.tunnelViolations += 1
                    if rep.examples.count < 8, let c = m.ballCentre(i), let v = m.ballVelocity(i) {
                        rep.examples.append(String(format: "launch %d step %d ball %d at (%.2f, %.2f) v (%.2f, %.2f) layer %d pen %.2f",
                                                   rep.launches, steps, i, c.x, c.y, v.x, v.y, e.balls[i].layer, p))
                    }
                }
            }
        }
        for _ in 0..<launches {
            rep.launches += 1
            // A free spot: clearance > 1 px from every wall, kicker and flipper on level 0.
            var st = BallState()
            for _ in 0..<200 {
                let cx = Double.random(in: 10...310, using: &rng), cy = Double.random(in: 10...370, using: &rng)
                let s = m.wallSample(level: 0, SIMD2(cx, cy)).value
                let a = m.actives[0].sample(cx, cy).value
                if s > m.maxContactRadius + 1 && a > m.maxContactRadius + 1 {
                    let tl = SIMD2(cx, cy) - m.centreOffset
                    st = BallState(x: Int16(tl.x.rounded(.down)), y: Int16(tl.y.rounded(.down)))
                    st.accx = Int16(((tl.x - tl.x.rounded(.down)) * 128).rounded(.down))
                    st.accy = Int16(((tl.y - tl.y.rounded(.down)) * 128).rounded(.down))
                    break
                }
            }
            let ang = Double.random(in: 0..<(2 * .pi), using: &rng), sp = Double.random(in: 0...maxSpeed, using: &rng)
            st.vx = Int16((cos(ang) * sp * 128).rounded()); st.vy = Int16((sin(ang) * sp * 128).rounded())
            for i in e.balls.indices { e.balls[i].active = 0 }
            st.active = 1
            e.balls[0] = st
            e.tilted = false; e.nudgeTimer = 0; e.tiltMeter = 0; e.serveDelay = 0; e.plungerCharge = 0
            let l0 = Date()
            var inputs: FrameInput = []
            for _ in 0..<frames {
                if Int.random(in: 0..<12, using: &rng) == 0 { inputs.formSymmetricDifference(.leftFlipper) }
                if Int.random(in: 0..<12, using: &rng) == 0 { inputs.formSymmetricDifference(.rightFlipper) }
                e.input = inputs
                e.runFrame()
                // drain_check serves a new ball once the slot drains: this launch is over.
                if e.serveDelay != 0 || e.balls[0].active != 1 { rep.drained += 1; break }
            }
            rep.slowestLaunchSeconds = max(rep.slowestLaunchSeconds, Date().timeIntervalSince(l0))
        }
        e.onStep = nil
        rep.steps = steps
        rep.nanResets = m.stats.nanResets
        rep.sweepExhausted = m.stats.sweepExhausted
        rep.deepContacts = m.stats.deepContacts
        rep.seconds = Date().timeIntervalSince(t0)
        return rep
    }
}

// MARK: - Autoplay with a stuck-ball rescue

extension EnhancedValidation {
    public struct GameReport: Sendable {
        public var report: AutoPlayReport
        /// Times the ball sat still outside the lane for 2 s and the player flipped both flippers.
        public var rescueFlips: Int
        /// Times flipping did not free it and the player nudged.
        public var rescueNudges: Int
        public var sensorDispatches: Int
        public var distinctSensors: Int
        /// Ball box top-left where each rescue started.
        public var rescueSpots: [SIMD2<Int>] = []
    }

    /// `AutoPlay.run` with the same `AutoPlayer`, plus what a player does with a ball that has come
    /// to rest outside the plunger lane (in a nook, on a flipper pivot): after 120 still frames
    /// both flippers flip for 12 frames; after 3 flips without effect, one nudge.
    public static func autoplay(engine e: ClassicEngine, frames: Int, options: RulesOptions = RulesOptions(),
                                plungeFrames: Int = 45) -> GameReport {
        let sim = GameSimulation(engine: e, options: options)
        var player = AutoPlayer(engine: e)
        player.plungeFrames = plungeFrames
        var sounds = 0, messages = 0, drains = 0, flips = 0, nudges = 0
        var last = PresentationState()
        var wasServing = e.serveDelay != 0
        var n = 0
        var still = 0, attempts = 0, rescueLeft = 0, nudgeLeft = 0
        var lastPos = (e.balls[0].x, e.balls[0].y)
        var spots: [SIMD2<Int>] = []
        let d = e.data
        while n < frames {
            var input = player.input(for: e)
            let b = e.balls[0]
            let inLane = UInt16(bitPattern: b.x) >= UInt16(truncatingIfNeeded: d.plunger.laneMinX)
                && UInt16(bitPattern: b.y) >= UInt16(truncatingIfNeeded: d.plunger.laneMinY)
            if b.active == 1 && !inLane && abs(Int(b.x) - Int(lastPos.0)) + abs(Int(b.y) - Int(lastPos.1)) == 0 { still += 1 } else { still = 0; attempts = 0 }
            lastPos = (b.x, b.y)
            if still >= 120 && rescueLeft == 0 && nudgeLeft == 0 {
                spots.append(SIMD2(Int(b.x), Int(b.y)))
                if attempts < 3 { rescueLeft = 12; flips += 1 } else { nudgeLeft = 2; nudges += 1; attempts = -1 }
                attempts += 1
                still = 0
            }
            if rescueLeft > 0 { input.insert([.leftFlipper, .rightFlipper]); rescueLeft -= 1 }
            if nudgeLeft > 0 { input.insert(.nudgeA); nudgeLeft -= 1 }
            sim.input = input
            sim.stepFrame()
            n += 1
            let s = sim.takePresentation()
            sounds += s.soundEvents.count
            if s.message != nil && last.message?.exeOffset != s.message?.exeOffset { messages += 1 }
            last = s
            let serving = e.serveDelay != 0
            if serving && !wasServing { drains += 1 }
            wasServing = serving
            if s.gameOver { break }
        }
        let r = e.rules
        let rep = AutoPlayReport(table: e.data.table, frames: n, rules: r != nil, rulesLoadError: e.rulesLoadError,
                                 score: last.scores.first ?? 0, ballNumber: last.ballNumber, drains: drains,
                                 gameOver: last.gameOver, soundEvents: sounds, messages: messages,
                                 lampsLit: last.lamps.filter { $0 }.count, loopGuardTrips: e.loopGuardTrips,
                                 divideFaults: e.divideFaults, ruleWarnings: r?.warnings ?? [],
                                 ruleFaults: Array(Set(r?.machine.faults ?? [])).sorted())
        return GameReport(report: rep, rescueFlips: flips, rescueNudges: nudges, sensorDispatches: e.sensorDispatchCount,
                          distinctSensors: e.sensorHits.filter { $0 > 0 }.count, rescueSpots: spots)
    }
}

// MARK: - Kicker study

extension EnhancedValidation {
    public struct KickerShot: Sendable {
        public var component: Int
        public var direction: Int
        public var speedIn: Double
        public var kicked: Bool
        public var speedOut: Double
    }

    /// Centres of the connected groups of kicker ("active") pixels on level 0 (4-connected, at least
    /// 6 pixels).
    public static func kickerCentres(_ e: ClassicEngine) -> [SIMD2<Double>] {
        let w = TableGeometry.width, h = TableGeometry.height
        var seen = [Bool](repeating: false, count: w * h)
        var out: [SIMD2<Double>] = []
        for p in 0..<(w * h) where !seen[p] && e.wallLUT[0][Int(e.buffer[p])] == .active {
            var stack = [p], pts: [Int] = []
            seen[p] = true
            while let q = stack.popLast() {
                pts.append(q)
                let x = q % w, y = q / w
                for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
                    let r = ny * w + nx
                    if !seen[r] && e.wallLUT[0][Int(e.buffer[r])] == .active { seen[r] = true; stack.append(r) }
                }
            }
            guard pts.count >= 6 else { continue }
            let c = pts.reduce(SIMD2<Double>(0, 0)) { $0 + SIMD2(Double($1 % w) + 0.5, Double($1 / w) + 0.5) } / Double(pts.count)
            out.append(c)
        }
        return out
    }

    /// Balls fired at every kicker group from 8 directions (rules off, sensors off): exit speed
    /// 20 frames later. `config == nil` = classic engine.
    public static func kickerShots(data d: EngineData, buffer: [UInt8], speed: Double, config: EnhancedPhysicsConfig?) throws -> [KickerShot] {
        let probe = try ClassicEngine(data: d, startBuffer: buffer)
        probe.resetToRest()
        let centres = kickerCentres(probe)
        let free = EnhancedPhysics(engine: probe)
        var out: [KickerShot] = []
        for (ci, c) in centres.enumerated() {
            for dir in 0..<8 {
                let a = Double(dir) * .pi / 4
                let u = SIMD2(cos(a), sin(a))
                // Start where the ball is clear, 12..40 px out along u.
                var start: SIMD2<Double>?
                var r = 12.0
                while r <= 40 {
                    let p = c + u * r
                    if p.x > 10 && p.x < 310 && p.y > 10 && p.y < 370,
                       free.wallSample(level: 0, p).value > free.maxContactRadius + 1.5,
                       free.actives[0].sampleRaw(p.x, p.y) > free.maxContactRadius + 1.5 { start = p; break }
                    r += 2
                }
                guard let s = start else { continue }
                let e = try ClassicEngine(data: d, startBuffer: buffer)
                e.resetToRest()
                e.sensorsEnabled = false
                e.ballLostResets = false
                for i in e.balls.indices { e.balls[i].active = 0 }
                let tl = s - free.centreOffset
                let v = -u * speed
                var b = BallState(x: Int16(tl.x.rounded(.down)), y: Int16(tl.y.rounded(.down)),
                                  vx: Int16((v.x * 128).rounded()), vy: Int16((v.y * 128).rounded()))
                b.accx = Int16(((tl.x - tl.x.rounded(.down)) * 128).rounded(.down))
                b.accy = Int16(((tl.y - tl.y.rounded(.down)) * 128).rounded(.down))
                e.balls[0] = b
                if let cf = config { EnhancedPhysics.install(on: e, config: cf) }
                var kicked = false
                for _ in 0..<20 {
                    e.runFrame()
                    if e.kickerCooldown != 0 || (e.data.kicker.cooldownIsSensorLockout == true && e.eventLockout != 0) { kicked = true }
                    if e.balls[0].active == 0 { break }
                }
                let vo = SIMD2(Double(e.balls[0].vx), Double(e.balls[0].vy)) / 128
                out.append(KickerShot(component: ci, direction: dir, speedIn: speed, kicked: kicked, speedOut: (vo * vo).sum().squareRoot()))
            }
        }
        return out
    }
}

// MARK: - Flipper shots from real play

extension EnhancedValidation {
    /// The ball 4 frames before a flipper shot in classic play (both flippers at rest), and the
    /// player's inputs from then until 12 frames after the shot.
    public struct ShotSnapshot: Sendable {
        public var ball: BallState
        public var inputs: [FrameInput]
    }

    /// Classic autoplay games (`autoplay`, one per plunge strength, `frames` each) on `engine` (with
    /// rules): every frame in which ball 0 turns from falling to rising faster than 1 px/step below
    /// y 290 with both flippers at rest 4 frames earlier gives a snapshot. Most are flipper shots;
    /// a few are slingshot kicks, which the replay also compares.
    public static func flipperShotSnapshots(engine e: ClassicEngine, plunges: [Int], frames: Int) -> [ShotSnapshot] {
        var snaps: [ShotSnapshot] = []
        for pf in plunges {
            e.resetToPowerOn()
            var hist: [(BallState, FrameInput, Bool)] = []
            var prev = BallState(), pending: Int?
            let saved = e.onStep
            e.onStep = { _, st, _ in
                guard st == e.data.timing.stepsPerFrame - 1 else { return }
                let b = e.balls[0]
                hist.append((b, e.input, e.groups.indices.allSatisfy { Int(e.groups[$0].angle) == e.data.flipperGroups[$0].restAngle }))
                let now = hist.count - 1
                if let at = pending, now >= at + 12 {
                    let s0 = at - 4
                    if s0 >= 0 && hist[s0].2 && hist[s0].0.active == 1 {
                        snaps.append(ShotSnapshot(ball: hist[s0].0, inputs: (s0 + 1...at + 12).map { hist[$0].1 }))
                    }
                    pending = nil
                }
                if pending == nil && b.active != 0 && b.y > 290 && prev.vy >= 0 && b.vy < -128 { pending = now }
                prev = b
            }
            _ = autoplay(engine: e, frames: frames, plungeFrames: pf)
            e.onStep = saved
        }
        return snaps
    }

    /// Replays `snapshots` on a fresh copy of the table (rules and sensors off, flippers at rest, level
    /// 0) with the recorded inputs; returns the most upward velocity reached in each (px/step).
    /// `config == nil` = the classic engine. One engine and model serve all replays.
    public static func replayShots(data d: EngineData, buffer: [UInt8], snapshots: [ShotSnapshot],
                                   config: EnhancedPhysicsConfig?) throws -> [SIMD2<Double>] {
        let e = try ClassicEngine(data: d, startBuffer: buffer)
        e.sensorsEnabled = false
        e.ballLostResets = false
        let m = config.map { EnhancedPhysics.install(on: e, config: $0) }
        var out: [SIMD2<Double>] = []
        for sn in snapshots {
            e.resetToRest()
            for i in e.balls.indices { e.balls[i].active = 0 }
            if let m { m.step(e) }   // retires the previous replay's body
            var b = sn.ball
            b.layer = 0
            e.balls[0] = b
            var best = SIMD2<Double>(0, 0)
            for inp in sn.inputs {
                e.input = inp
                e.runFrame()
                let v = SIMD2(Double(e.balls[0].vx), Double(e.balls[0].vy)) / 128
                if v.y < best.y { best = v }
            }
            out.append(best)
        }
        return out
    }

    public struct ShotComparison: Sendable, CustomStringConvertible {
        public var shots = 0
        public var classicMeanUp = 0.0, enhancedMeanUp = 0.0
        /// Mean |log(speed_enhanced / speed_classic)| per shot.
        public var meanAbsLogSpeedRatio = 0.0
        /// Median |direction difference| per shot (degrees).
        public var medianAngleDiff = 0.0
        /// Share of shots faster than 3.5 px/step upward (the original's double top kick).
        public var classicStrong = 0.0, enhancedStrong = 0.0
        public var description: String {
            String(format: "%d shots: up-speed classic %.2f / enhanced %.2f px/step, mean |log speed ratio| %.3f, median |d angle| %.1f deg, strong (>3.5) %.0f%% / %.0f%%",
                   shots, classicMeanUp, enhancedMeanUp, meanAbsLogSpeedRatio, medianAngleDiff, 100 * classicStrong, 100 * enhancedStrong)
        }
    }

    /// Paired comparison of replayed shots (only those the classic replay turns upward by more than
    /// 0.5 px/step).
    public static func compareShots(classic c: [SIMD2<Double>], enhanced x: [SIMD2<Double>]) -> ShotComparison {
        var r = ShotComparison()
        var lr: [Double] = [], ang: [Double] = [], cu: [Double] = [], eu: [Double] = []
        for (a, b) in zip(c, x) where -a.y > 0.5 {
            let sa = (a * a).sum().squareRoot(), sb = (b * b).sum().squareRoot()
            lr.append(abs(log(max(sb, 0.05) / max(sa, 0.05))))
            var d = (atan2(b.y, b.x) - atan2(a.y, a.x)) * 180 / .pi
            while d > 180 { d -= 360 }
            while d < -180 { d += 360 }
            ang.append(abs(d))
            cu.append(-a.y); eu.append(-b.y)
        }
        r.shots = lr.count
        guard r.shots > 0 else { return r }
        let n = Double(r.shots)
        r.classicMeanUp = cu.reduce(0, +) / n
        r.enhancedMeanUp = eu.reduce(0, +) / n
        r.meanAbsLogSpeedRatio = lr.reduce(0, +) / n
        r.medianAngleDiff = ang.sorted()[ang.count / 2]
        r.classicStrong = Double(cu.filter { $0 > 3.5 }.count) / n
        r.enhancedStrong = Double(eu.filter { $0 > 3.5 }.count) / n
        return r
    }
}
