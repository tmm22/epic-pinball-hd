// CPU xBRZ scaler: a Swift port of tools/hdpack/xbrz.py (the HD pack generator's filter), which
// is the same rule set as the renderer's Metal xBRZ (Pinball.metal: xbrz_prepass + xbrz_sample),
// after Zenju's published (GPL-3) xBRZ. Scale-free form: blend regions are evaluated
// analytically at output-pixel centres with one output pixel of anti-aliasing.
//
// The arithmetic follows numpy 2's type rules for the Python code step by step, so the output
// is pixel-identical to the Python tool (HDPackTests): colour work in Float (float32
// arrays; Python float constants are "weak" scalars and become float32), the half-plane
// coverages in Double (they divide by `np.hypot` of Python floats, a float64 scalar, which
// promotes) and rounded to Float where the Python code does `.astype(np.float32)`. Swift does
// not fuse multiply-adds, so every operation rounds the way numpy's separate ufuncs do.
import Foundation

enum XBRZ {
    // Python floats rounded to float32 the way numpy casts them (via Double, not the literal).
    private static let eqTol = Float(30.0 as Double)
    private static let dominant = Float(3.6 as Double)
    private static let steepK = Float(2.2 as Double)
    private static let centreW = Float(4.0 as Double)
    private static let kbD = 0.0593, krD = 0.2627
    private static let kb = Float(kbD), kr = Float(krD), kg = Float(1.0 - kbD - krD)
    private static let cbK = Float(0.5 / (1.0 - kbD)), crK = Float(0.5 / (1.0 - krD))
    private static let tiny = Float(1e-6 as Double)

    /// Premultiplied RGBA in 0...1.
    struct Px: Equatable { var r, g, b, a: Float }

    /// YCbCr distance (0-255 scale), alpha-aware like xBRZ's ARGB variant (xbrz.py dist).
    @inline(__always) static func dist(_ p: Px, _ q: Px) -> Float {
        let d0 = (p.r - q.r) * 255, d1 = (p.g - q.g) * 255, d2 = (p.b - q.b) * 255
        let y = kr * d0 + kg * d1 + kb * d2
        let cb = cbK * (d2 - y)
        let cr = crK * (d0 - y)
        let dd = (y * y + cb * cb + cr * cr).squareRoot()
        let a1 = p.a, a2 = q.a
        return a1 < a2 ? a1 * dd + 255 * (a2 - a1) : a2 * dd + 255 * (a1 - a2)
    }

    @inline(__always) static func near(_ p: Px, _ q: Px) -> Bool { dist(p, q) < eqTol }

    /// Edge-replicated source image.
    struct Source {
        let w: Int, h: Int
        let px: [Px]
        @inline(__always) func at(_ y: Int, _ x: Int) -> Px {
            px[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)]
        }
    }

    /// Blend bits per 2x2 block (xbrz.py prepass): result[(r) * (W+1) + c] is the block whose
    /// top-left pixel is (c-1, r-1), bits 0-1 F bottom-right, 2-3 G bottom-left, 4-5 J top-right,
    /// 6-7 K top-left (0 none, 1 normal, 2 dominant).
    static func prepass(_ s: Source) -> [UInt8] {
        let bw = s.w + 1, bh = s.h + 1
        var res = [UInt8](repeating: 0, count: bw * bh)
        for r in 0..<bh {
            for c in 0..<bw {
                let y = r - 1, x = c - 1
                let b = s.at(y - 1, x), cc = s.at(y - 1, x + 1)
                let e = s.at(y, x - 1), f = s.at(y, x), g = s.at(y, x + 1), hh = s.at(y, x + 2)
                let i = s.at(y + 1, x - 1), j = s.at(y + 1, x), k = s.at(y + 1, x + 1), l = s.at(y + 1, x + 2)
                let n = s.at(y + 2, x), o = s.at(y + 2, x + 1)
                let fg = f == g, jk = j == k, fj = f == j, gk = g == k
                if (fg && jk) || (fj && gk) { continue }
                let jg = dist(i, f) + dist(f, cc) + dist(n, k) + dist(k, hh) + centreW * dist(j, g)
                let fk = dist(e, j) + dist(j, o) + dist(b, g) + dist(g, l) + centreW * dist(f, k)
                var v: UInt8 = 0
                if jg < fk {
                    let t1: UInt8 = dominant * jg < fk ? 2 : 1
                    if !fg && !fj { v |= t1 }
                    if !jk && !gk { v |= t1 << 6 }
                } else if fk < jg {
                    let t2: UInt8 = dominant * fk < jg ? 2 : 1
                    if !fj && !jk { v |= t2 << 4 }
                    if !fg && !gk { v |= t2 << 2 }
                }
                res[r * bw + c] = v
            }
        }
        return res
    }

    /// One of the four corner orientations (xbrz.py _ROTS): r and d as (dy, dx), and which
    /// corner of the pixel's blend info is the corner itself, its "top right" and "bottom left".
    private struct Rot { let ry, rx, dy, dx: Int; let corner, topR, bottomL: Corner }
    private enum Corner { case br, bl, tr, tl }
    private static let rots: [Rot] = [
        Rot(ry: 0, rx: 1, dy: 1, dx: 0, corner: .br, topR: .tr, bottomL: .bl),
        Rot(ry: 1, rx: 0, dy: 0, dx: -1, corner: .bl, topR: .br, bottomL: .tl),
        Rot(ry: 0, rx: -1, dy: -1, dx: 0, corner: .tl, topR: .bl, bottomL: .tr),
        Rot(ry: -1, rx: 0, dy: 0, dx: 1, corner: .tr, topR: .tl, bottomL: .br),
    ]

    /// Coverage of the five blend cases (0 corner, 1 diagonal, 2 shallow, 3 steep, 4 both) at
    /// every sub-pixel centre, per rotation: [rot][case][sy * S + sx].
    static func coverageTables(_ S: Int) -> [[[Float]]] {
        let offs = (0..<S).map { (Float($0) + 0.5) / Float(S) - 0.5 }
        let sc = Double(S)
        func half(_ u: Float, _ v: Float, _ n0: Double, _ n1: Double, _ c: Double) -> Double {
            let num = Float(n0) * u + Float(n1) * v - Float(c)
            return min(max(Double(num) / hypot(n0, n1) * sc + 0.5, 0), 1)
        }
        return rots.map { rot in
            var tab = [[Float]](repeating: [Float](repeating: 0, count: S * S), count: 5)
            for sy in 0..<S {
                for sx in 0..<S {
                    let fx = offs[sx], fy = offs[sy]
                    let u = fx * Float(rot.rx) + fy * Float(rot.ry)
                    let v = fx * Float(rot.dx) + fy * Float(rot.dy)
                    let cs = half(u, v, 0.5, 1.0, 0.25)
                    let ct = half(u, v, 1.0, 0.5, 0.25)
                    let cd = half(u, v, 1.0, 1.0, 0.5)
                    let cc: Float = (u > 0 && v > 0) ? min(max((hypotf(u, v) - 0.5) * Float(sc) + 0.5, 0), 1) : 0
                    let i = sy * S + sx
                    tab[0][i] = cc
                    tab[1][i] = Float(cd)
                    tab[2][i] = Float(cs)
                    tab[3][i] = Float(ct)
                    tab[4][i] = Float(max(cs, ct))
                }
            }
            return tab
        }
    }

    /// xBRZ-scales premultiplied RGBA (xbrz.py scale). Rows are processed in parallel; `cancelled`
    /// is polled per row and makes the result meaningless (the caller checks it again).
    static func scale(_ s: Source, _ S: Int, cancelled: (@Sendable () -> Bool)? = nil) -> [Px] {
        let W = s.w, H = s.h, OW = W * S
        let blend = prepass(s)
        let bw = W + 1
        let cov = coverageTables(S)
        var out = [Px](repeating: Px(r: 0, g: 0, b: 0, a: 0), count: W * S * H * S)
        let rows = H
        out.withUnsafeMutableBufferPointer { outBuf in
            let ob = UnsafeMutableSendable(outBuf)
            DispatchQueue.concurrentPerform(iterations: rows) { y in
                if let c = cancelled, c() { return }
                let o = ob.buffer
                var cell = [Px](repeating: Px(r: 0, g: 0, b: 0, a: 0), count: S * S)
                for x in 0..<W {
                    let e = s.at(y, x)
                    for i in 0..<(S * S) { cell[i] = e }
                    let corners: (Corner) -> UInt8 = { k in
                        switch k {
                        case .br: return blend[(y + 1) * bw + x + 1] & 3
                        case .bl: return (blend[(y + 1) * bw + x] >> 2) & 3
                        case .tr: return (blend[y * bw + x + 1] >> 4) & 3
                        case .tl: return (blend[y * bw + x] >> 6) & 3
                        }
                    }
                    for (ri, rot) in rots.enumerated() {
                        let bc = corners(rot.corner)
                        if bc == 0 { continue }
                        let (ry, rx, dy, dx) = (rot.ry, rot.rx, rot.dy, rot.dx)
                        let B = s.at(y - dy, x - dx)
                        let C = s.at(y + ry - dy, x + rx - dx)
                        let D = s.at(y - ry, x - rx)
                        let F = s.at(y + ry, x + rx)
                        let G = s.at(y - ry + dy, x - rx + dx)
                        let Hh = s.at(y + dy, x + dx)
                        let I = s.at(y + ry + dy, x + rx + dx)
                        let line: Bool
                        if bc >= 2 { line = true }
                        else if corners(rot.topR) != 0 && !near(e, G) { line = false }
                        else if corners(rot.bottomL) != 0 && !near(e, C) { line = false }
                        else if !near(e, I) && near(G, Hh) && near(Hh, I) && near(I, F) && near(F, C) { line = false }
                        else { line = true }
                        let col = dist(e, F) <= dist(e, Hh) ? F : Hh
                        let kase: Int
                        if !line { kase = 0 } else {
                            let fgd = dist(F, G), hcd = dist(Hh, C)
                            let shallow = steepK * fgd <= hcd && e != G && D != G
                            let steep = steepK * hcd <= fgd && e != C && B != C
                            kase = shallow && steep ? 4 : shallow ? 2 : steep ? 3 : 1
                        }
                        let tab = cov[ri][kase]
                        for i in 0..<(S * S) {
                            let t = tab[i]
                            if t == 0 { continue }
                            var p = cell[i]
                            p.r = p.r + (col.r - p.r) * t
                            p.g = p.g + (col.g - p.g) * t
                            p.b = p.b + (col.b - p.b) * t
                            p.a = p.a + (col.a - p.a) * t
                            cell[i] = p
                        }
                    }
                    for sy in 0..<S {
                        let base = (y * S + sy) * OW + x * S
                        for sx in 0..<S { o[base + sx] = cell[sy * S + sx] }
                    }
                }
            }
        }
        return out
    }

    /// Straight RGBA8 (w x h) -> straight RGBA8 (w*S x h*S) (xbrz.py scale_rgba8).
    static func scaleRGBA8(_ rgba: [UInt8], width w: Int, height h: Int, scale S: Int,
                           cancelled: (@Sendable () -> Bool)? = nil) -> [UInt8] {
        precondition(rgba.count == w * h * 4 && S >= 1)
        var src = [Px](repeating: Px(r: 0, g: 0, b: 0, a: 0), count: w * h)
        for i in 0..<(w * h) {
            let a = Float(rgba[i * 4 + 3]) / 255
            src[i] = Px(r: Float(rgba[i * 4]) / 255 * a, g: Float(rgba[i * 4 + 1]) / 255 * a,
                        b: Float(rgba[i * 4 + 2]) / 255 * a, a: a)
        }
        let o = scale(Source(w: w, h: h, px: src), S, cancelled: cancelled)
        var out = [UInt8](repeating: 0, count: o.count * 4)
        @inline(__always) func q(_ v: Float) -> UInt8 { UInt8(min(max((v * 255).rounded(.toNearestOrEven), 0), 255)) }
        for i in 0..<o.count {
            let p = o[i]
            let a = p.a
            if a > tiny {
                let d = max(a, tiny)
                out[i * 4] = q(p.r / d); out[i * 4 + 1] = q(p.g / d); out[i * 4 + 2] = q(p.b / d)
            }
            out[i * 4 + 3] = q(a)
        }
        return out
    }

    /// Pixel replication (make_pack.py --method nearest).
    static func nearest(_ rgba: [UInt8], width w: Int, height h: Int, scale S: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * S * S * 4)
        let OW = w * S
        for y in 0..<(h * S) {
            for x in 0..<OW {
                let si = ((y / S) * w + x / S) * 4, di = (y * OW + x) * 4
                out[di] = rgba[si]; out[di + 1] = rgba[si + 1]; out[di + 2] = rgba[si + 2]; out[di + 3] = rgba[si + 3]
            }
        }
        return out
    }
}

/// A buffer pointer shared by the rows of a concurrentPerform (each row writes its own range).
struct UnsafeMutableSendable<T>: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<T>
    init(_ b: UnsafeMutableBufferPointer<T>) { buffer = b }
}
