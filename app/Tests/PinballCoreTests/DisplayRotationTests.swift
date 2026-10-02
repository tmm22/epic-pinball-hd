import Foundation
import Metal
import XCTest
import PinballCore
@testable import PinballRender

/// Cabinet display: the rotation transform, the letterbox in the rotated (logical) target, the
/// settings mapping, and (with the user's data) the GPU output of every filter at every rotation
/// against the unrotated frame turned on the CPU, plus the score window's strip-only render.
final class DisplayRotationTests: XCTestCase {
    typealias R = GameSettings.DisplayRotation

    // MARK: - transform maths (no data, no GPU)

    func testLogicalSizeSwapsForQuarterTurns() {
        for r in R.allCases {
            let t = DisplayTransform(rotation: r, outputWidth: 1920, outputHeight: 1080)
            XCTAssertEqual(t.quarterTurns, r.rawValue / 90)
            if r == .clockwise90 || r == .clockwise270 {
                XCTAssertEqual([t.logicalWidth, t.logicalHeight], [1080, 1920], "\(r)")
            } else {
                XCTAssertEqual([t.logicalWidth, t.logicalHeight], [1920, 1080], "\(r)")
            }
        }
    }

    func testPixelMappingIsABijectionAndInverse() {
        for r in R.allCases {
            let t = DisplayTransform(rotation: r, outputWidth: 7, outputHeight: 5)
            var seen = Set<Int>()
            for ly in 0..<t.logicalHeight {
                for lx in 0..<t.logicalWidth {
                    let p = t.physical(fromLogical: SIMD2(lx, ly))
                    XCTAssertTrue((0..<7).contains(p.x) && (0..<5).contains(p.y), "\(r) \(lx),\(ly) -> \(p)")
                    XCTAssertEqual(t.logical(fromPhysical: p), SIMD2(lx, ly), "\(r)")
                    seen.insert(p.y * 7 + p.x)
                }
            }
            XCTAssertEqual(seen.count, 35, "\(r) covers every output pixel once")
        }
    }

    /// Clockwise: the picture's top-left corner goes to the output's top-right (90), bottom-right
    /// (180) and bottom-left (270) corner.
    func testClockwiseCorners() {
        let cases: [(R, SIMD2<Int>)] = [(.none, SIMD2(0, 0)), (.clockwise90, SIMD2(9, 0)), (.upsideDown, SIMD2(9, 3)), (.clockwise270, SIMD2(0, 3))]
        for (r, corner) in cases {
            XCTAssertEqual(DisplayTransform(rotation: r, outputWidth: 10, outputHeight: 4).physical(fromLogical: .zero), corner, "\(r)")
        }
    }

    /// The physical rectangle of a logical rectangle is the bounding box of its turned pixels.
    func testPhysicalRectMatchesPixels() {
        for r in R.allCases {
            let t = DisplayTransform(rotation: r, outputWidth: 40, outputHeight: 30)
            let (x, y, w, h) = (3, 5, 11, 7)
            var minP = SIMD2(Int.max, Int.max), maxP = SIMD2(Int.min, Int.min)
            for ly in y..<(y + h) { for lx in x..<(x + w) {
                let p = t.physical(fromLogical: SIMD2(lx, ly)); minP = pointwiseMin(minP, p); maxP = pointwiseMax(maxP, p)
            } }
            let rect = t.physicalRect(x: Double(x), y: Double(y), width: Double(w), height: Double(h))
            XCTAssertEqual([rect.x, rect.y, rect.width, rect.height],
                           [Double(minP.x), Double(minP.y), Double(maxP.x - minP.x + 1), Double(maxP.y - minP.y + 1)], "\(r)")
        }
    }

    /// The cabinet case: a 1920x1080 (landscape) output turned 90 degrees shows the 320x400 table
    /// as a 1080-wide portrait picture: integer 3x (960x1200) for the classic look, the full 1080
    /// width with fill scaling, centred, at any backing scale (Retina 2x doubles everything).
    func testFullTableFillsAPortraitMonitor() {
        for backing in [1, 2] {
            let ow = 1920 * backing, oh = 1080 * backing
            let t = DisplayTransform(rotation: .clockwise90, outputWidth: ow, outputHeight: oh)
            let i = ViewportFit.fit(sourceWidth: 320, sourceHeight: 400, outputWidth: t.logicalWidth, outputHeight: t.logicalHeight)
            XCTAssertTrue(i.isInteger)
            XCTAssertEqual(i.scaleX, Double(3 * backing))
            XCTAssertEqual([i.width, i.height], [Double(960 * backing), Double(1200 * backing)])
            XCTAssertEqual(i.x, Double(60 * backing)); XCTAssertEqual(i.y, Double(360 * backing))
            let f = EnhancedFit.fit(sourceWidth: 320, sourceHeight: 400, outputWidth: t.logicalWidth, outputHeight: t.logicalHeight,
                                    aspect: .square, scaling: .fill)
            XCTAssertEqual(f.width, Double(t.logicalWidth), accuracy: 1e-9, "fill uses the whole portrait width")
            XCTAssertEqual(f.scaleX, 3.375 * Double(backing), accuracy: 1e-9)
            // On the landscape output the picture is a centred column, full height.
            let p = t.physicalRect(x: f.x, y: f.y, width: f.width, height: f.height)
            XCTAssertEqual(p.y, 0); XCTAssertEqual(p.height, Double(oh), accuracy: 1e-9)
            XCTAssertEqual(p.x + p.width / 2, Double(ow) / 2, accuracy: 1)
        }
        // VGA pixels keep 6:5 in the logical target.
        let t = DisplayTransform(rotation: .clockwise270, outputWidth: 2560, outputHeight: 1440)
        let v = ViewportFit.fit(sourceWidth: 320, sourceHeight: 400, outputWidth: t.logicalWidth, outputHeight: t.logicalHeight, aspect: .vga)
        XCTAssertEqual(v.scaleY, (v.scaleX * 1.2).rounded(), "integer VGA scales as unrotated (ViewportFit)")
        XCTAssertLessThanOrEqual(v.width, 1440); XCTAssertLessThanOrEqual(v.height, 2560)
    }

    // MARK: - settings

    func testSettingsMappingAndDefaults() throws {
        let g = GameSettings()
        XCTAssertEqual(g.displayRotation, .none)
        XCTAssertFalse(g.scoreWindow)
        XCTAssertEqual(RenderSettings(g).rotation, .none)
        var r = GameSettings(); r.displayRotation = .clockwise270
        let rs = RenderSettings(r)
        XCTAssertEqual(rs.rotation, .clockwise270)
        XCTAssertTrue(rs.isClassic, "a rotated classic frame still runs the classic passes")
        XCTAssertEqual(RenderSettings.fromEnvironment(["EPIC_PINBALL_RENDER": "rotate=90"])?.rotation, .clockwise90)
        XCTAssertEqual(RenderSettings.fromEnvironment(["EPIC_PINBALL_RENDER": "rotate=45"])?.rotation, R.none)
        // Stored as degrees.
        let data = try JSONEncoder().encode(r)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["displayRotation"] as? Int, 270)
        XCTAssertEqual(obj["scoreWindow"] as? Bool, false)
    }

    // MARK: - GPU (user's data)

    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        return d
    }

    /// Every filter of both pipelines, every rotation: the rotated frame is exactly the upright
    /// frame of the swapped output size turned on the CPU (the turn moves whole pixels).
    func testRotatedFramesAreTheUprightFrameTurned() throws {
        let dev = try device()
        guard let t = RealTable.load(10) ?? RealTable.load(1) else { throw XCTSkip("no extracted data / original EXEs") }
        var variants = EnhancedRenderTests.variants().filter { $0.0 != "hd+light" }   // "hd": the HD pack when installed
        var full = RenderSettings(); full.filter = .xbrz
        variants.append(("xbrz-full", full))
        for (name, base) in variants {
            let isFull = name.hasSuffix("-full")
            let (_, upright) = try EnhancedRenderTests.render(t, device: dev, settings: base, width: 300, height: 420, full: isFull)
            for r in R.allCases where r != .none {
                var s = base; s.rotation = r
                let swaps = r != .upsideDown
                let (w, h) = swaps ? (420, 300) : (300, 420)
                let (_, px) = try EnhancedRenderTests.render(t, device: dev, settings: s, width: w, height: h, full: isFull)
                let tr = DisplayTransform(rotation: r, outputWidth: w, outputHeight: h)
                var bad = 0
                for py in 0..<h { for pxl in 0..<w {
                    let l = tr.logical(fromPhysical: SIMD2(pxl, py))
                    let a = (py * w + pxl) * 4, b = (l.y * 300 + l.x) * 4
                    if px[a] != upright[b] || px[a + 1] != upright[b + 1] || px[a + 2] != upright[b + 2] { bad += 1 }
                } }
                XCTAssertEqual(bad, 0, "\(name) at \(r.rawValue): \(bad) pixels differ from the turned upright frame")
            }
        }
    }

    /// Rotation .none leaves the classic output byte-identical (no extra pass).
    func testNoRotationIsUnchanged() throws {
        let dev = try device()
        guard let t = RealTable.load(1) else { throw XCTSkip("no extracted data / original EXEs") }
        let (r0, a) = try EnhancedRenderTests.render(t, device: dev, settings: .classic, width: 960, height: 720)
        var s = RenderSettings.classic; s.rotation = .none
        let (_, b) = try EnhancedRenderTests.render(t, device: dev, settings: s, width: 960, height: 720)
        XCTAssertEqual(fnv64(a), fnv64(b))
        XCTAssertNil(r0.rotationScratch, "no rotation texture without rotation")
    }

    /// Score window: the strip-only render at the main view's scale is the strip rows of the main
    /// frame: exactly for classic nearest, within 1/255 for the enhanced smooth / xBRZ layers.
    func testStripOnlyRenderMatchesTheMainFramesStrip() throws {
        let dev = try device()
        for n in [1, 10] {
            guard let t = RealTable.load(n) else { continue }
            let rows = t.stripRows
            let window = 240 - rows
            var smooth = RenderSettings(); smooth.filter = .smooth
            var xbrz = RenderSettings(); xbrz.filter = .xbrz
            for (name, s) in [("nearest", RenderSettings.classic), ("smooth", smooth), ("xbrz", xbrz)] {
                let (r, main) = try EnhancedRenderTests.render(t, device: dev, settings: s, width: 960, height: 720)
                XCTAssertEqual(r.visibleStripRows(for: t.scene(viewTop: 150)), rows)
                let strip = try r.renderStripOffscreen(rows: rows, width: 960, height: rows * 3)
                let fit = r.stripFit(rows: rows, outputWidth: 960, outputHeight: rows * 3)
                XCTAssertEqual([fit.x, fit.y, fit.scaleX, fit.scaleY], [0, 0, 3, 3])
                let tail = Array(main[(window * 3 * 960 * 4)...])
                XCTAssertEqual(tail.count, strip.count)
                var bad = 0, worst = 0, rowsHit = Set<Int>()
                for i in stride(from: 0, to: strip.count, by: 4) {
                    let d = (0..<3).map { abs(Int(strip[i + $0]) - Int(tail[i + $0])) }.max()!
                    if d > 0 { bad += 1; worst = max(worst, d); rowsHit.insert(i / 4 / 960) }
                }
                if name == "nearest" {
                    XCTAssertEqual(bad, 0, "EP\(n) \(name): \(bad) strip pixels differ (rows \(rowsHit.sorted().prefix(8)))")
                } else {
                    // The filters evaluate at (y - window rows) instead of y: float rounding only.
                    XCTAssertLessThanOrEqual(worst, 1, "EP\(n) \(name): \(bad) strip pixels differ by up to \(worst)")
                }
            }
            // Letterboxed in a wide backglass window (Retina 2x): integer scale, centred.
            let (r, _) = try EnhancedRenderTests.render(t, device: dev, settings: .classic, width: 960, height: 720)
            let f = r.stripFit(rows: rows, outputWidth: 3840, outputHeight: 600)
            XCTAssertTrue(f.isInteger)
            XCTAssertEqual(f.scaleX, Double(min(3840 / 320, 600 / rows)))
            XCTAssertEqual(f.x, ((3840 - f.width) / 2).rounded(.down))
            XCTAssertEqual(f.y, ((600 - f.height) / 2).rounded(.down))
        }
    }

    /// Score window with its own rotation: the turned strip is the upright strip of the swapped
    /// size turned, pixel for pixel, for classic and enhanced filters; the main picture's rotation
    /// does not apply to it.
    func testRotatedStripIsTheUprightStripTurned() throws {
        let dev = try device()
        guard let t = RealTable.load(10) ?? RealTable.load(1) else { throw XCTSkip("no extracted data / original EXEs") }
        let rows = t.stripRows
        var xbrz = RenderSettings(); xbrz.filter = .xbrz
        var crt = RenderSettings(); crt.filter = .crt
        for (name, s) in [("nearest", RenderSettings.classic), ("xbrz", xbrz), ("crt", crt)] {
            var main = s; main.rotation = .clockwise90   // must not turn the score window
            let (r, _) = try EnhancedRenderTests.render(t, device: dev, settings: main, width: 640, height: 480)
            let W = 960, H = rows * 3
            let upright = try r.renderStripOffscreen(rows: rows, width: W, height: H)
            for rot in R.allCases where rot != .none {
                let swaps = rot != .upsideDown
                let (w, h) = swaps ? (H, W) : (W, H)
                let px = try r.renderStripOffscreen(rows: rows, width: w, height: h, rotation: rot)
                let tr = DisplayTransform(rotation: rot, outputWidth: w, outputHeight: h)
                var bad = 0
                for py in 0..<h { for x in 0..<w {
                    let l = tr.logical(fromPhysical: SIMD2(x, py))
                    let a = (py * w + x) * 4, b = (l.y * W + l.x) * 4
                    if px[a] != upright[b] || px[a + 1] != upright[b + 1] || px[a + 2] != upright[b + 2] { bad += 1 }
                } }
                XCTAssertEqual(bad, 0, "\(name) strip at \(rot.rawValue): \(bad) pixels differ from the turned upright strip")
            }
        }
    }
}
