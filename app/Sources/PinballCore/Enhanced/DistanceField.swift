import Foundation

// Signed distance fields over pixel masks, for the enhanced ball physics.
//
// A field is sampled at pixel centres. The raw value at a pixel is the Euclidean distance from its
// centre to the nearest solid pixel centre, minus 0.5 (so roughly the distance to the solid pixel's
// square), and inside solid regions minus the distance to the nearest empty pixel centre (so the
// gradient always points out of the solid). The raw field is capped at +-`cap`. It is smoothed with
// a separable binomial kernel (sigma about 1 px) and its gradient is taken by central differences,
// which gives sub-pixel smooth surface normals on stair-stepped pixel walls. Queries interpolate
// value and gradient bilinearly. The smoothed field is still 1-Lipschitz (a convolution of a
// 1-Lipschitz function with a normalised kernel), so `value - radius` is a safe step length for
// conservative advancement (the bilinear interpolation adds at most a factor sqrt(2), see
// `EnhancedPhysics.advance`).
//
// Exact distance transform: Felzenszwalb & Huttenlocher, "Distance Transforms of Sampled
// Functions" (1D lower envelope of parabolas, applied to rows then columns).

/// One sample of a field: value and gradient (not normalised).
public struct FieldSample: Sendable, Equatable {
    public var value: Double
    public var gx: Double
    public var gy: Double
    public init(value: Double, gx: Double, gy: Double) { self.value = value; self.gx = gx; self.gy = gy }
    /// Unit normal pointing away from the surface (zero vector if the gradient vanishes).
    public var normal: SIMD2<Double> {
        let l = (gx * gx + gy * gy).squareRoot()
        return l > 1e-9 ? SIMD2(gx / l, gy / l) : SIMD2(0, 0)
    }
    public static let far = FieldSample(value: .greatestFiniteMagnitude, gx: 0, gy: 0)
}

/// A capped, smoothed signed distance field on a `w` x `h` grid whose cell (i, j) centre sits at
/// world position (originX + i + 0.5, originY + j + 0.5).
public struct DistanceField: Sendable {
    public let originX: Int, originY: Int
    public let w: Int, h: Int
    public let cap: Float
    /// Solid mask (1 = solid).
    public private(set) var solid: [UInt8]
    var raw: [Float]
    /// Interleaved (smoothed value, gx, gy, 0) per cell.
    var fg: [SIMD4<Float>]
    /// True when no cell is solid (every query returns `cap`).
    public private(set) var isEmpty: Bool

    public init(originX: Int, originY: Int, w: Int, h: Int, solid: [UInt8], cap: Float = 24) {
        precondition(solid.count == w * h)
        self.originX = originX; self.originY = originY; self.w = w; self.h = h
        self.cap = cap
        self.solid = solid
        raw = [Float](repeating: cap, count: w * h)
        fg = [SIMD4<Float>](repeating: SIMD4(cap, 0, 0, 0), count: w * h)
        isEmpty = !solid.contains(where: { $0 != 0 })
        if !isEmpty { recompute(x0: 0, y0: 0, x1: w, y1: h) }
    }

    /// Changes solid cells (grid coordinates) and recomputes the affected neighbourhood.
    public mutating func update(cells: [(Int, Int, Bool)]) {
        guard !cells.isEmpty else { return }
        var x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min
        var changed = false
        for (x, y, s) in cells where x >= 0 && x < w && y >= 0 && y < h {
            let v: UInt8 = s ? 1 : 0
            if solid[y * w + x] == v { continue }
            solid[y * w + x] = v
            changed = true
            x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1)
        }
        guard changed else { return }
        isEmpty = !solid.contains(where: { $0 != 0 })
        if isEmpty {
            for i in raw.indices { raw[i] = cap; fg[i] = SIMD4(cap, 0, 0, 0) }
            return
        }
        recompute(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    /// Recomputes raw distances for the cells whose value can change when cells in [x0,x1)x[y0,y1)
    /// changed (the box grown by `cap`), from the solid cells within 2 x `cap` of the box, then the
    /// smoothed values and gradients around them.
    mutating func recompute(x0: Int, y0: Int, x1: Int, y1: Int) {
        let c = Int(cap.rounded(.up)) + 1
        let full = x0 <= 0 && y0 <= 0 && x1 >= w && y1 >= h
        // Output box (raw changes) and input box (solid cells that can influence it).
        let ox0 = full ? 0 : max(0, x0 - c), oy0 = full ? 0 : max(0, y0 - c)
        let ox1 = full ? w : min(w, x1 + c), oy1 = full ? h : min(h, y1 + c)
        let ix0 = full ? 0 : max(0, x0 - 2 * c), iy0 = full ? 0 : max(0, y0 - 2 * c)
        let ix1 = full ? w : min(w, x1 + 2 * c), iy1 = full ? h : min(h, y1 + 2 * c)
        let bw = ix1 - ix0, bh = iy1 - iy0
        var inMask = [UInt8](repeating: 0, count: bw * bh)
        for y in 0..<bh {
            let src = (iy0 + y) * w + ix0
            for x in 0..<bw { inMask[y * bw + x] = solid[src + x] }
        }
        let dOut = Self.squaredEDT(mask: inMask, w: bw, h: bh, feature: 1)
        let dIn = Self.squaredEDT(mask: inMask, w: bw, h: bh, feature: 0)
        for y in oy0..<oy1 {
            for x in ox0..<ox1 {
                let li = (y - iy0) * bw + (x - ix0)
                let v: Float
                if inMask[li] != 0 { v = -(dIn[li].squareRoot() - 0.5) } else { v = dOut[li].squareRoot() - 0.5 }
                raw[y * w + x] = min(cap, max(-cap, v))
            }
        }
        smooth(x0: max(0, ox0 - 2), y0: max(0, oy0 - 2), x1: min(w, ox1 + 2), y1: min(h, oy1 + 2))
    }

    /// Binomial [1 4 6 4 1]/16 smoothing of `raw` and central-difference gradient in the box.
    mutating func smooth(x0: Int, y0: Int, x1: Int, y1: Int) {
        // The gradient needs smoothed values one cell around the box, which need raw rows two further.
        let gx0 = max(0, x0 - 1), gy0 = max(0, y0 - 1), gx1 = min(w, x1 + 1), gy1 = min(h, y1 + 1)
        let sy0 = max(0, gy0 - 2), sy1 = min(h, gy1 + 2)
        let bw = gx1 - gx0, sh = sy1 - sy0, gh = gy1 - gy0
        let w = self.w, h = self.h
        var horiz = [Float](repeating: 0, count: bw * sh)
        var sm = [Float](repeating: 0, count: bw * gh)
        raw.withUnsafeBufferPointer { rp in
            horiz.withUnsafeMutableBufferPointer { hp in
                for y in sy0..<sy1 {
                    let row = y * w
                    for x in gx0..<gx1 {
                        let xm2 = max(0, x - 2), xm1 = max(0, x - 1), xp1 = min(w - 1, x + 1), xp2 = min(w - 1, x + 2)
                        let s = rp[row + xm2] + 4 * rp[row + xm1] + 6 * rp[row + x] + 4 * rp[row + xp1] + rp[row + xp2]
                        hp[(y - sy0) * bw + (x - gx0)] = s / 16
                    }
                }
                sm.withUnsafeMutableBufferPointer { sp in
                    for y in gy0..<gy1 {
                        // Rows outside the grid clamp to the edge row (as the raw field is clamped).
                        func r(_ yy: Int) -> Int { (min(sy1 - 1, max(sy0, min(h - 1, max(0, yy)))) - sy0) * bw }
                        let a = r(y - 2), b = r(y - 1), c = r(y), d = r(y + 1), e = r(y + 2)
                        for x in 0..<bw {
                            sp[(y - gy0) * bw + x] = (hp[a + x] + 4 * hp[b + x] + 6 * hp[c + x] + 4 * hp[d + x] + hp[e + x]) / 16
                        }
                    }
                }
            }
        }
        sm.withUnsafeBufferPointer { sp in
            fg.withUnsafeMutableBufferPointer { out in
                @inline(__always) func at(_ x: Int, _ y: Int) -> Float {
                    sp[(min(gy1 - 1, max(gy0, y)) - gy0) * bw + (min(gx1 - 1, max(gx0, x)) - gx0)]
                }
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let v = at(x, y)
                        // One-sided differences at the grid edge.
                        let l = x > 0 ? at(x - 1, y) : v, rr = x < w - 1 ? at(x + 1, y) : v
                        let u = y > 0 ? at(x, y - 1) : v, dd = y < h - 1 ? at(x, y + 1) : v
                        let dx: Float = (x > 0 && x < w - 1) ? 2 : 1
                        let dy: Float = (y > 0 && y < h - 1) ? 2 : 1
                        out[y * w + x] = SIMD4(v, (rr - l) / dx, (dd - u) / dy, 0)
                    }
                }
            }
        }
    }

    /// Bilinear sample at world position (x, y). Outside the grid the nearest edge cell is used
    /// (callers pad their grids so that this never matters in the contact band).
    @inline(__always)
    public func sample(_ x: Double, _ y: Double) -> FieldSample {
        if isEmpty { return FieldSample(value: Double(cap), gx: 0, gy: 0) }
        let u = x - Double(originX) - 0.5, v = y - Double(originY) - 0.5
        let fu = u.rounded(.down), fv = v.rounded(.down)
        let i0 = Int(fu), j0 = Int(fv)
        let tx = Float(u - fu), ty = Float(v - fv)
        let ia = min(w - 1, max(0, i0)), ib = min(w - 1, max(0, i0 + 1))
        let ja = min(h - 1, max(0, j0)), jb = min(h - 1, max(0, j0 + 1))
        let a = fg[ja * w + ia], b = fg[ja * w + ib], c = fg[jb * w + ia], d = fg[jb * w + ib]
        let top = a + (b - a) * tx, bot = c + (d - c) * tx
        let s = top + (bot - top) * ty
        return FieldSample(value: Double(s.x), gx: Double(s.y), gy: Double(s.z))
    }

    /// Bilinear sample of the exact (unsmoothed) signed distance at world position (x, y): the
    /// penetration depth (smoothing would lift the inside of 1-px walls above 0 and lower ridges).
    @inline(__always)
    public func sampleRaw(_ x: Double, _ y: Double) -> Double {
        if isEmpty { return Double(cap) }
        let u = x - Double(originX) - 0.5, v = y - Double(originY) - 0.5
        let fu = u.rounded(.down), fv = v.rounded(.down)
        let i0 = Int(fu), j0 = Int(fv)
        let tx = Float(u - fu), ty = Float(v - fv)
        let ia = min(w - 1, max(0, i0)), ib = min(w - 1, max(0, i0 + 1))
        let ja = min(h - 1, max(0, j0)), jb = min(h - 1, max(0, j0 + 1))
        let a = raw[ja * w + ia], b = raw[ja * w + ib], c = raw[jb * w + ia], d = raw[jb * w + ib]
        let top = a + (b - a) * tx, bot = c + (d - c) * tx
        return Double(top + (bot - top) * ty)
    }

    /// Raw (unsmoothed) value at a cell, for tests.
    public func rawValue(cellX x: Int, cellY y: Int) -> Float { raw[y * w + x] }

    // MARK: - Exact squared Euclidean distance transform

    /// Squared distance from every cell centre to the nearest cell whose mask equals `feature`
    /// (a large value when there is none).
    static func squaredEDT(mask: [UInt8], w: Int, h: Int, feature: UInt8) -> [Float] {
        let inf: Float = 1e20
        var g = [Float](repeating: inf, count: w * h)
        let n = max(w, h)
        var f = [Float](repeating: 0, count: n), d = [Float](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n), z = [Float](repeating: 0, count: n + 1)
        let want = feature != 0
        g.withUnsafeMutableBufferPointer { gp in
            mask.withUnsafeBufferPointer { mp in
                for i in 0..<(w * h) where (mp[i] != 0) == want { gp[i] = 0 }
            }
            f.withUnsafeMutableBufferPointer { fp in
            d.withUnsafeMutableBufferPointer { dp in
            v.withUnsafeMutableBufferPointer { vp in
            z.withUnsafeMutableBufferPointer { zp in
                // Columns first (vertical), then rows.
                for x in 0..<w {
                    for y in 0..<h { fp[y] = gp[y * w + x] }
                    edt1D(fp, h, dp, vp, zp)
                    for y in 0..<h { gp[y * w + x] = dp[y] }
                }
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w { fp[x] = gp[row + x] }
                    edt1D(fp, w, dp, vp, zp)
                    for x in 0..<w { gp[row + x] = dp[x] }
                }
            } } } }
        }
        return g
    }

    /// 1D squared distance transform of the sampled function f[0..<n] (lower envelope of parabolas).
    static func edt1D(_ f: UnsafeMutableBufferPointer<Float>, _ n: Int, _ d: UnsafeMutableBufferPointer<Float>,
                      _ v: UnsafeMutableBufferPointer<Int>, _ z: UnsafeMutableBufferPointer<Float>) {
        let inf: Float = 1e30
        var k = 0
        v[0] = 0
        z[0] = -inf
        z[1] = inf
        if n > 1 {
            for q in 1..<n {
                let fq = f[q] + Float(q * q)
                var s: Float
                while true {
                    let p = v[k]
                    s = (fq - (f[p] + Float(p * p))) / Float(2 * q - 2 * p)
                    if s <= z[k] && k > 0 { k -= 1 } else { break }
                }
                k += 1
                v[k] = q
                z[k] = s
                z[k + 1] = inf
            }
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Float(q) { k += 1 }
            let p = v[k]
            d[q] = Float((q - p) * (q - p)) + f[p]
        }
    }
}
