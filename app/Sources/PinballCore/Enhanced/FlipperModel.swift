import Foundation

/// Collision geometry of one flipper for the enhanced physics, derived from its ten per-angle
/// outline pixel lists in engine.json (the same pixels the original draws into its collision map).
///
/// * Consecutive identical outlines (EP4/EP12's upper flippers have 4 distinct ones) are merged
///   into one *pose* placed at the mean of their angle indices.
/// * Every pose gets its own smoothed distance field on a world-aligned grid, so at a whole angle
///   index the collision surface is exactly the original outline.
/// * A rigid-rotation fit (principal axis per pose, least-squares pivot from the pose centroids)
///   gives a pivot and a rotation per pose. At a fractional angle index the flipper is the blend
///   of the two neighbouring poses, each rotated about the pivot to the interpolated angle, so it
///   moves continuously; the surface velocity at a contact point is `omega x (p - pivot)`.
public struct FlipperShape: Sendable {
    public struct Pose: Sendable {
        /// Angle index (0 = up ... 9 = rest) this pose stands for (the mean of its run).
        public var alpha: Double
        /// Rotation relative to the rest pose (radians, screen coordinates, y down).
        public var theta: Double
        var field: DistanceField
    }

    public let index: Int
    public let group: Int
    public let pivot: SIMD2<Double>
    public let poses: [Pose]
    /// Pose (run of identical outlines) of each whole angle index 0...9.
    public let poseOfIndex: [Int]
    /// Largest distance from the pivot to any outline pixel centre, plus the field margin.
    public let reach: Double
    /// Field margin around each outline (also the far value).
    public let margin: Double
    /// Mean chamfer distance (px) between each outline and the rest outline rotated by its fitted
    /// angle: how rigid the fit is (0.4 .. 0.9 px on the main flippers).
    public let fitError: Double

    public init(index: Int, flipper f: EngineData.Flipper, margin: Int = 14) {
        self.index = index
        group = f.group
        self.margin = Double(margin)
        let w = TableGeometry.width
        func points(_ o: [Int]) -> [SIMD2<Double>] {
            o.map { SIMD2(Double($0 % w) + 0.5, Double($0 / w) + 0.5) }
        }
        // Runs of identical outlines -> poses.
        var runs: [(alpha: Double, offsets: [Int])] = []
        var runOf: [Int] = []
        var a = 0
        let pos = f.positions
        while a < pos.count {
            var b = a
            let sa = Set(pos[a])
            while b + 1 < pos.count && Set(pos[b + 1]) == sa { b += 1 }
            for _ in a...b { runOf.append(runs.count) }
            runs.append((Double(a + b) / 2, pos[a]))
            a = b + 1
        }
        poseOfIndex = runOf
        // Principal axis angle per run, aligned in sign with its neighbour, unwrapped.
        var thetas: [Double] = []
        var centroids: [SIMD2<Double>] = []
        var prevAxis: SIMD2<Double>?
        for r in runs.reversed() {   // from rest (index 9) towards up
            let p = points(r.offsets)
            let c = p.isEmpty ? SIMD2<Double>(0, 0) : p.reduce(SIMD2(0, 0), +) / Double(p.count)
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for q in p { let d = q - c; sxx += d.x * d.x; syy += d.y * d.y; sxy += d.x * d.y }
            let ang = 0.5 * atan2(2 * sxy, sxx - syy)
            var axis = SIMD2(cos(ang), sin(ang))
            if let pa = prevAxis, (axis * pa).sum() < 0 { axis = -axis }
            prevAxis = axis
            thetas.append(atan2(axis.y, axis.x))
            centroids.append(c)
        }
        thetas.reverse(); centroids.reverse()
        for i in stride(from: thetas.count - 2, through: 0, by: -1) {   // unwrap relative to the rest end
            while thetas[i] - thetas[i + 1] > .pi { thetas[i] -= 2 * .pi }
            while thetas[i] - thetas[i + 1] < -.pi { thetas[i] += 2 * .pi }
        }
        let restTheta = thetas.last ?? 0
        let rel = thetas.map { $0 - restTheta }
        // Pivot: c_a = P + R(d_a)(c_rest - P)  =>  (I - R_a) P = c_a - R_a c_rest (least squares).
        let cRest = centroids.last ?? SIMD2(0, 0)
        var ata = (0.0, 0.0, 0.0), atb = SIMD2<Double>(0, 0)   // symmetric 2x2 (a11, a12, a22)
        for i in 0..<(runs.count - 1) {
            let cs = cos(rel[i]), sn = sin(rel[i])
            // M = I - R = [[1-c, s], [-s, 1-c]]
            let m11 = 1 - cs, m12 = sn, m21 = -sn, m22 = 1 - cs
            let rc = SIMD2(cs * cRest.x - sn * cRest.y, sn * cRest.x + cs * cRest.y)
            let rhs = centroids[i] - rc
            ata.0 += m11 * m11 + m21 * m21
            ata.1 += m11 * m12 + m21 * m22
            ata.2 += m12 * m12 + m22 * m22
            atb.x += m11 * rhs.x + m21 * rhs.y
            atb.y += m12 * rhs.x + m22 * rhs.y
        }
        let det = ata.0 * ata.2 - ata.1 * ata.1
        let piv: SIMD2<Double>
        if abs(det) > 1e-9 {
            piv = SIMD2((ata.2 * atb.x - ata.1 * atb.y) / det, (ata.0 * atb.y - ata.1 * atb.x) / det)
        } else {
            piv = cRest   // does not rotate: any pivot works, surface velocity is 0
        }
        pivot = piv
        // Fields per pose.
        var poses: [Pose] = []
        var reach = 0.0
        for (i, r) in runs.enumerated() {
            let p = points(r.offsets)
            for q in p { reach = max(reach, ((q - piv) * (q - piv)).sum().squareRoot()) }
            let xs = r.offsets.map { $0 % w }, ys = r.offsets.map { $0 / w }
            let x0 = (xs.min() ?? 0) - margin, y0 = (ys.min() ?? 0) - margin
            let gw = (xs.max() ?? 0) - (xs.min() ?? 0) + 1 + 2 * margin
            let gh = (ys.max() ?? 0) - (ys.min() ?? 0) + 1 + 2 * margin
            var mask = [UInt8](repeating: 0, count: gw * gh)
            for o in r.offsets { mask[(o / w - y0) * gw + (o % w - x0)] = 1 }
            Self.fillEnclosed(&mask, gw, gh)
            let field = DistanceField(originX: x0, originY: y0, w: gw, h: gh, solid: mask, cap: Float(margin))
            poses.append(Pose(alpha: r.alpha, theta: rel[i], field: field))
        }
        self.poses = poses
        self.reach = reach + Double(margin)
        // Rigidity of the fit (diagnostic).
        let restPts = points(runs.last?.offsets ?? [])
        var err = 0.0, n = 0
        for (i, r) in runs.enumerated() where i < runs.count - 1 && !restPts.isEmpty {
            let cs = cos(rel[i]), sn = sin(rel[i])
            let moved = restPts.map { q -> SIMD2<Double> in
                let d = q - piv
                return piv + SIMD2(cs * d.x - sn * d.y, sn * d.x + cs * d.y)
            }
            for q in points(r.offsets) {
                var best = Double.greatestFiniteMagnitude
                for m in moved { best = min(best, ((q - m) * (q - m)).sum()) }
                err += best.squareRoot(); n += 1
            }
        }
        fitError = n > 0 ? err / Double(n) : 0
    }

    /// Closed outlines (EP9-13 draw the whole flipper boundary) become solid shapes: every cell
    /// the grid border cannot reach through empty cells (4-connected) is marked solid, so a ball
    /// can never sit inside a flipper. Open outlines (EP1-8: the top edge and tip) are unchanged.
    static func fillEnclosed(_ mask: inout [UInt8], _ w: Int, _ h: Int) {
        var outside = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
        while let p = stack.popLast() {
            guard !outside[p], mask[p] == 0 else { continue }
            outside[p] = true
            let x = p % w, y = p / w
            if x > 0 { stack.append(p - 1) }
            if x < w - 1 { stack.append(p + 1) }
            if y > 0 { stack.append(p - w) }
            if y < h - 1 { stack.append(p + w) }
        }
        for p in 0..<(w * h) where !outside[p] { mask[p] = 1 }
    }

    /// Rotation (relative to rest) at a fractional angle index, and d(theta)/d(alpha).
    public func theta(alpha: Double) -> (theta: Double, slope: Double) {
        let (i0, i1, t) = bracket(alpha)
        let p0 = poses[i0], p1 = poses[i1]
        if i0 == i1 { return (p0.theta, 0) }
        return (p0.theta + t * (p1.theta - p0.theta), p1.theta - p0.theta)
    }

    /// Poses of the whole angle indices around `alpha` and the blend weight: at a whole index
    /// exactly that index's outline; between two indices with different outlines a blend.
    func bracket(_ alpha: Double) -> (Int, Int, Double) {
        let n = poseOfIndex.count
        guard n > 1 else { return (0, 0, 0) }
        let a = min(Double(n - 1), max(0, alpha))
        let a0 = min(n - 1, Int(a.rounded(.down))), a1 = min(n - 1, a0 + 1)
        let i0 = poseOfIndex[a0], i1 = poseOfIndex[a1]
        let t = a - Double(a0)
        if i0 == i1 || t <= 0 { return (i0, i0, 0) }
        return (i0, i1, t)
    }

    /// Distance field value (to the outline pixel squares) and gradient at world point `c` with
    /// the flipper at fractional angle index `alpha`.
    public func sample(_ c: SIMD2<Double>, alpha: Double) -> FieldSample {
        let d = c - pivot
        if (d * d).sum() > reach * reach { return FieldSample(value: margin, gx: 0, gy: 0) }
        let (i0, i1, t) = bracket(alpha)
        let th = poses[i0].theta + t * (poses[i1].theta - poses[i0].theta)
        func one(_ p: Pose) -> FieldSample {
            let r = p.theta - th
            let cs = cos(r), sn = sin(r)
            let q = pivot + SIMD2(cs * d.x - sn * d.y, sn * d.x + cs * d.y)
            let f = p.field
            if q.x < Double(f.originX) || q.y < Double(f.originY) || q.x >= Double(f.originX + f.w) || q.y >= Double(f.originY + f.h) {
                return FieldSample(value: margin, gx: 0, gy: 0)
            }
            let s = f.sample(q.x, q.y)
            // Gradient back to world: rotate by -r.
            return FieldSample(value: s.value, gx: cs * s.gx + sn * s.gy, gy: -sn * s.gx + cs * s.gy)
        }
        let a = one(poses[i0])
        if i0 == i1 || t <= 0 { return a }
        let b = one(poses[i1])
        return FieldSample(value: a.value + (b.value - a.value) * t, gx: a.gx + (b.gx - a.gx) * t, gy: a.gy + (b.gy - a.gy) * t)
    }

    /// Exact (unsmoothed) distance to the outline at `c` with the flipper at `alpha`.
    public func rawValue(_ c: SIMD2<Double>, alpha: Double) -> Double {
        let d = c - pivot
        if (d * d).sum() > reach * reach { return margin }
        let (i0, i1, t) = bracket(alpha)
        let th = poses[i0].theta + t * (poses[i1].theta - poses[i0].theta)
        func one(_ p: Pose) -> Double {
            let r = p.theta - th
            let cs = cos(r), sn = sin(r)
            let q = pivot + SIMD2(cs * d.x - sn * d.y, sn * d.x + cs * d.y)
            let f = p.field
            if q.x < Double(f.originX) || q.y < Double(f.originY) || q.x >= Double(f.originX + f.w) || q.y >= Double(f.originY + f.h) {
                return margin
            }
            return f.sampleRaw(q.x, q.y)
        }
        let a = one(poses[i0])
        if i0 == i1 || t <= 0 { return a }
        return a + (one(poses[i1]) - a) * t
    }

    /// Velocity of the flipper surface at world point `p` for angular velocity `omega`.
    public func surfaceVelocity(at p: SIMD2<Double>, omega: Double) -> SIMD2<Double> {
        let d = p - pivot
        return SIMD2(-omega * d.y, omega * d.x)
    }

    /// Rotation between two angle indices (radians, for the angular velocity of a step).
    public func rotation(from a: Double, to b: Double) -> Double { theta(alpha: b).theta - theta(alpha: a).theta }
}
