import Foundation
import PinballCore

/// The game's flipper frames split into a clean flipper sprite per frame and the table background
/// under the flipper, so the enhanced renderer can draw the flipper rotated to any angle
/// (docs/enhanced/rendering.md, "Rotated flippers").
///
/// The frames are opaque, position-bound records with the background baked in (draw_flipper_sprite
/// EP1 cs:3C12 blits them without a colour key), and the playfield under them is not the background
/// either (EP1-7, EP9-11 and EP13 have a flat placeholder shape there, EP8 and EP12 the rest frame).
/// The flipper colours differ per table. So which pixels are flipper is inferred from the frames:
///
/// * Frame k shows the flipper at angle index 3k (the last frame at 9, the rest pose): the frame
///   rule is (angle + 2) / 3 (EP1 cs:10F5), and the fitted art angles match the collision outlines'
///   angles 0, 3, 6, 9 (`testFlipperArtSeparation`).
/// * A pixel's background is what the frame whose flipper points furthest away from it shows (angle
///   around the pivot); it is known where that frame's flipper is clearly clear of the pixel, i.e.
///   everywhere except a disc around the pivot that every frame covers.
/// * A frame's mask is every pixel that differs from the background (so a shadow drawn with the
///   flipper moves with it). Unknown background pixels count as flipper unless their colour is
///   almost only ever seen as background; their background is filled from the neighbours.
/// * The first pass uses the collision outlines' geometry (`FlipperShape`: pivot, rotation per
///   angle); then each frame's rotation is refitted from its mask's principal axis (relative to the
///   rest frame) and the pivot from the mask centroids, and the split is repeated with that.
struct FlipperArt: Sendable {
    /// Union rectangle of all frames (table px).
    let x: Int, y: Int, w: Int, h: Int
    let frameCount: Int
    /// Per frame, union-rect sized: palette index + 1 where the frame covers the pixel, else 0.
    let values: [[UInt16]]
    /// Per frame, union-rect sized: 1 = flipper pixel.
    private(set) var masks: [[UInt8]] = []
    /// Background index per pixel (filled in where not `backgroundKnown`).
    private(set) var background: [UInt8] = []
    private(set) var backgroundKnown: [Bool] = []
    /// Rotation of each frame's art relative to the last frame (radians, y down) and the art's pivot
    /// (table px), from the masks.
    private(set) var thetas: [Double] = []
    private(set) var pivot = SIMD2<Double>(0, 0)
    /// Mean distance (px) between each frame's mask and the rest mask rotated by its fitted angle.
    private(set) var fitError = 0.0
    /// Angle index (0 up ... 9 rest) each frame shows.
    let frameAngles: [Double]

    /// Pixels (union rect) whose background had to be filled in.
    var unknownBackground: Int { backgroundKnown.filter { !$0 }.count }

    /// The split is trusted when the frames behave like one rigid sprite turning one way: every
    /// frame-to-frame rotation has the same sign and at least 0.04 rad, the masks fit their rotated
    /// rest mask within 0.6 px on average, and the pivot is near the rectangle. EP8's flippers fail
    /// (their colours are close to the table's, the masks are not clean): they keep the cross-fade.
    var usable: Bool {
        guard thetas.count == frameCount, frameCount >= 2, fitError <= 0.6 else { return false }
        let steps = zip(thetas.dropFirst(), thetas).map { $0 - $1 }
        let sign = steps[0] >= 0 ? 1.0 : -1.0
        guard steps.allSatisfy({ $0 * sign >= 0.04 }) else { return false }
        let m = 6.0
        return pivot.x >= Double(x) - m && pivot.y >= Double(y) - m && pivot.x <= Double(x + w) + m && pivot.y <= Double(y + h) + m
    }

    /// The two frames to draw at continuous angle index `alpha` (0 up ... 9 rest), each with the
    /// rotation (radians) that brings its art to the angle, and the weight of the second: between
    /// two frames' angles the art angle moves linearly with the angle index, and the frames
    /// cross-fade over the middle of the interval. At a frame's own angle: that frame, unrotated.
    func pose(alpha: Double) -> (k0: Int, r0: Double, k1: Int, r1: Double, weight: Double) {
        let a = min(max(alpha, frameAngles.first!), frameAngles.last!)
        var k0 = 0
        while k0 + 2 < frameCount && a > frameAngles[k0 + 1] { k0 += 1 }
        let k1 = k0 + 1
        let span = frameAngles[k1] - frameAngles[k0]
        let s = span > 0 ? (a - frameAngles[k0]) / span : 0
        let theta = thetas[k0] + s * (thetas[k1] - thetas[k0])
        let t = min(max((s - 0.3) / 0.4, 0), 1)
        return (k0, theta - thetas[k0], k1, theta - thetas[k1], t * t * (3 - 2 * t))
    }

    init?(frames: [IndexedSprite], palette: Palette, flipper: EngineData.Flipper) {
        guard frames.count >= 2, flipper.positions.count == 10 else { return nil }
        let x0 = frames.map(\.x).min()!, y0 = frames.map(\.y).min()!
        let x1 = frames.map { $0.x + $0.w }.max()!, y1 = frames.map { $0.y + $0.h }.max()!
        x = x0; y = y0; w = x1 - x0; h = y1 - y0
        frameCount = frames.count
        var values = [[UInt16]](repeating: [UInt16](repeating: 0, count: w * h), count: frames.count)
        for (k, s) in frames.enumerated() {
            for r in 0..<s.h { for c in 0..<s.w { values[k][(s.y - y0 + r) * w + s.x - x0 + c] = UInt16(s.pixels[r * s.w + c]) + 1 } }
        }
        self.values = values
        frameAngles = (0..<frames.count).map { $0 == frames.count - 1 ? 9 : Double(min(9, 3 * $0)) }
        // First pass: the collision outlines' rigid fit.
        let shape = FlipperShape(index: 0, flipper: flipper)
        let tw = TableGeometry.width
        let rest = flipper.positions[9].map { SIMD2(Double($0 % tw) + 0.5, Double($0 / tw) + 0.5) }
        guard !rest.isEmpty else { return nil }
        let restDir = rest.reduce(SIMD2(0, 0), +) / Double(rest.count) - shape.pivot
        let psi0 = atan2(restDir.y, restDir.x)
        classify(palette: palette, pivot: shape.pivot, directions: frameAngles.map { psi0 + shape.theta(alpha: $0).theta })
        guard fit() else { return nil }
        // Second pass with the art's own geometry.
        let restArt = maskPoints(frameCount - 1)
        let c = restArt.reduce(SIMD2(0, 0), +) / Double(max(1, restArt.count)) - pivot
        let psi = atan2(c.y, c.x)
        classify(palette: palette, pivot: pivot, directions: thetas.map { psi + $0 })
        guard fit() else { return nil }
    }

    private func maskPoints(_ k: Int) -> [SIMD2<Double>] {
        var q: [SIMD2<Double>] = []
        for p in 0..<(w * h) where masks[k][p] != 0 { q.append(SIMD2(Double(x + p % w) + 0.5, Double(y + p / w) + 0.5)) }
        return q
    }

    /// Background and masks for the given pivot and flipper axis direction per frame.
    private mutating func classify(palette: Palette, pivot P: SIMD2<Double>, directions psi: [Double]) {
        let n = w * h, K = frameCount
        // Colours compared as RGB (duplicate palette entries are one colour): value -> first index
        // with that colour.
        var firstOf: [Int: Int] = [:]
        let canon: [Int] = (0..<256).map { i in
            let e = palette[i]
            let rgb = Int(e.r) << 16 | Int(e.g) << 8 | Int(e.b)
            if let f = firstOf[rgb] { return f }
            firstOf[rgb] = i
            return i
        }
        func key(_ v: UInt16) -> Int { canon[Int(v) - 1] }
        func angDist(_ a: Double, _ b: Double) -> Double {
            var d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
            if d > .pi { d = 2 * .pi - d }
            return d
        }
        let halfWidth = 8.0   // a conservative half thickness of the flipper (px)
        var bg = [UInt8](repeating: 0, count: n), known = [Bool](repeating: false, count: n)
        var bgSeen = [Int](repeating: 0, count: 256), fgSeen = [Int](repeating: 0, count: 256)
        for p in 0..<n {
            let q = SIMD2(Double(x + p % w) + 0.5, Double(y + p / w) + 0.5) - P
            let d = (q * q).sum().squareRoot()
            let phi = atan2(q.y, q.x)
            var best = -1, bestDist = -1.0
            for k in 0..<K where values[k][p] != 0 {
                let a = angDist(phi, psi[k])
                if a > bestDist { bestDist = a; best = k }
            }
            guard best >= 0 else { continue }
            let clearance = d > halfWidth ? asin(min(1, halfWidth / d)) + 0.06 : .infinity
            guard bestDist > clearance else { continue }
            let b = values[best][p]
            bg[p] = UInt8(b - 1); known[p] = true
            let bk = key(b)
            for k in 0..<K where values[k][p] != 0 {
                let kk = key(values[k][p])
                if kk == bk { bgSeen[kk] += 1 } else { fgSeen[kk] += 1 }
            }
        }
        var masks = [[UInt8]](repeating: [UInt8](repeating: 0, count: n), count: K)
        for p in 0..<n {
            if known[p] {
                let bk = key(UInt16(bg[p]) + 1)
                for k in 0..<K where values[k][p] != 0 && key(values[k][p]) != bk { masks[k][p] = 1 }
            } else {
                for k in 0..<K where values[k][p] != 0 {
                    let kk = key(values[k][p])
                    masks[k][p] = bgSeen[kk] > 8 * (fgSeen[kk] + 1) ? 0 : 1
                }
            }
        }
        // Unknown background: nearest known neighbour, ring by ring (a frame that shows a
        // background colour there counts as known first).
        for p in 0..<n where !known[p] {
            for k in 0..<K where values[k][p] != 0 && masks[k][p] == 0 { bg[p] = UInt8(values[k][p] - 1); known[p] = true; break }
        }
        backgroundKnown = known
        var filled = known
        var frontier = (0..<n).filter { !known[$0] }
        while !frontier.isEmpty {
            var next: [Int] = [], set: [(Int, UInt8)] = []
            for p in frontier {
                let px = p % w, py = p / w
                var found: UInt8?
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)] {
                    let qx = px + dx, qy = py + dy
                    guard qx >= 0, qy >= 0, qx < w, qy < h, filled[qy * w + qx] else { continue }
                    found = bg[qy * w + qx]; break
                }
                if let f = found { set.append((p, f)) } else { next.append(p) }
            }
            if set.isEmpty { break }
            for (p, v) in set { bg[p] = v; filled[p] = true }
            frontier = next
        }
        background = bg
        self.masks = (0..<K).map { k in
            var m = Self.cleaned(masks[k], w: w, h: h)
            for p in 0..<n where values[k][p] == 0 { m[p] = 0 }
            return m
        }
    }

    /// The largest 8-connected part of a mask with its enclosed holes filled (a flipper colour that
    /// happens to equal the background at a pixel leaves a hole; stray background differences
    /// leave specks).
    static func cleaned(_ m: [UInt8], w: Int, h: Int) -> [UInt8] {
        var label = [Int](repeating: -1, count: w * h)
        var best = -1, bestSize = 0
        var stack: [Int] = []
        for s in 0..<(w * h) where m[s] != 0 && label[s] < 0 {
            var size = 0
            label[s] = s; stack.append(s)
            while let p = stack.popLast() {
                size += 1
                let px = p % w, py = p / w
                for dy in -1...1 { for dx in -1...1 {
                    let qx = px + dx, qy = py + dy
                    guard qx >= 0, qy >= 0, qx < w, qy < h else { continue }
                    let q = qy * w + qx
                    if m[q] != 0 && label[q] < 0 { label[q] = s; stack.append(q) }
                } }
            }
            if size > bestSize { bestSize = size; best = s }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for p in 0..<(w * h) where label[p] == best { out[p] = 1 }
        // Holes: zero pixels the border cannot reach (4-connected).
        var outside = [Bool](repeating: false, count: w * h)
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
        while let p = stack.popLast() {
            guard !outside[p], out[p] == 0 else { continue }
            outside[p] = true
            let px = p % w, py = p / w
            if px > 0 { stack.append(p - 1) }
            if px < w - 1 { stack.append(p + 1) }
            if py > 0 { stack.append(p - w) }
            if py < h - 1 { stack.append(p + w) }
        }
        for p in 0..<(w * h) where !outside[p] { out[p] = 1 }
        return out
    }

    /// Rigid fit of the masks: principal axis per frame, pivot from the centroids.
    private mutating func fit() -> Bool {
        let K = frameCount
        var axes: [Double] = [], cents: [SIMD2<Double>] = [], pts: [[SIMD2<Double>]] = []
        var prev: SIMD2<Double>?
        for k in stride(from: K - 1, through: 0, by: -1) {
            let q = maskPoints(k)
            guard q.count >= 8 else { return false }
            let c = q.reduce(SIMD2(0, 0), +) / Double(q.count)
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for v in q { let d = v - c; sxx += d.x * d.x; syy += d.y * d.y; sxy += d.x * d.y }
            let a = 0.5 * atan2(2 * sxy, sxx - syy)
            var axis = SIMD2(cos(a), sin(a))
            if let pa = prev, (axis * pa).sum() < 0 { axis = -axis }
            prev = axis
            axes.append(atan2(axis.y, axis.x)); cents.append(c); pts.append(q)
        }
        axes.reverse(); cents.reverse(); pts.reverse()
        for i in stride(from: axes.count - 2, through: 0, by: -1) {
            while axes[i] - axes[i + 1] > .pi { axes[i] -= 2 * .pi }
            while axes[i] - axes[i + 1] < -.pi { axes[i] += 2 * .pi }
        }
        let rel = axes.map { $0 - axes.last! }
        thetas = rel
        let cRest = cents.last!
        var a11 = 0.0, a12 = 0.0, a22 = 0.0, b = SIMD2<Double>(0, 0)
        for i in 0..<(rel.count - 1) {
            let cs = cos(rel[i]), sn = sin(rel[i])
            let m11 = 1 - cs, m12 = sn, m21 = -sn, m22 = 1 - cs
            let rhs = cents[i] - SIMD2(cs * cRest.x - sn * cRest.y, sn * cRest.x + cs * cRest.y)
            a11 += m11 * m11 + m21 * m21; a12 += m11 * m12 + m21 * m22; a22 += m12 * m12 + m22 * m22
            b.x += m11 * rhs.x + m21 * rhs.y; b.y += m12 * rhs.x + m22 * rhs.y
        }
        let det = a11 * a22 - a12 * a12
        let piv = abs(det) > 1e-9 ? SIMD2((a22 * b.x - a12 * b.y) / det, (a11 * b.y - a12 * b.x) / det) : cRest
        pivot = piv
        // Fit error over every other mask pixel (the full product is slow and adds nothing).
        var err = 0.0, cnt = 0
        for i in 0..<(rel.count - 1) {
            let cs = cos(rel[i]), sn = sin(rel[i])
            let moved = pts.last!.map { v -> SIMD2<Double> in let d = v - piv; return piv + SIMD2(cs * d.x - sn * d.y, sn * d.x + cs * d.y) }
            for v in stride(from: 0, to: pts[i].count, by: 2).map({ pts[i][$0] }) {
                var best = Double.greatestFiniteMagnitude
                for m in moved { best = min(best, ((v - m) * (v - m)).sum()) }
                err += best.squareRoot(); cnt += 1
            }
        }
        fitError = cnt > 0 ? err / Double(cnt) : 0
        return true
    }
}
