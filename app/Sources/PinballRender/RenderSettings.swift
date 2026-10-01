import Foundation
import PinballCore

/// Everything the enhanced renderer can do on top of the classic presentation
/// (docs/enhanced/rendering.md). `RenderSettings.classic` is the original look and takes
/// the unchanged classic code path (byte-identical output, EnhancedRenderTests).
public struct RenderSettings: Sendable, Equatable {
    public enum Scaling: String, Sendable, CaseIterable {
        /// Largest integer scale that fits (the classic behaviour).
        case integer
        /// Largest scale that fits, fractional allowed (aspect kept; filters anti-alias).
        case fill
        /// `integer` for the nearest filter without an HD pack, `fill` otherwise.
        case auto
    }

    public enum Lighting: String, Sendable, CaseIterable {
        case off
        /// Lamp glow, ball specular and contact shadow, kept subtle (the default when enabled).
        case subtle
        /// Stronger glow and flasher pulses.
        case vivid
    }

    public var filter: UpscaleFilter = .nearest
    /// Use the table's HD asset pack if one is installed (falls back per asset).
    public var useHDPack = false
    public var lighting: Lighting = .off
    /// Draw ball, camera and flippers between the last two simulation frames
    /// (needs `PinballRenderer.interpolation` from the front end).
    public var interpolate = false
    public var scaling: Scaling = .auto
    /// Full-table view (400 rows): show the display strip below the table.
    public var stripInFullTable = true
    /// Round, anti-aliased message dots (enhanced filters); the nearest filter keeps squares.
    public var roundDots = true
    /// High refresh with an HD pack: flippers rotate continuously between the game's frames
    /// (`FlipperArt`) instead of cross-fading them. Falls back to the cross-fade per flipper.
    public var rotateFlippers = true
    /// CRT look: barrel curvature (0 = flat, 0.03 = subtle), scanline depth 0...1, mask 0...1.
    public var crtCurvature: Float = 0.025
    public var crtScanlines: Float = 0.75
    public var crtMask: Float = 0.18
    /// Cabinet / portrait display: the finished picture turned clockwise (DisplayTransform).
    /// Independent of `isClassic`: a rotated classic frame is still the classic passes.
    public var rotation: GameSettings.DisplayRotation = .none

    public init() {}

    public static let classic = RenderSettings()

    /// True when nothing enhanced is enabled: the renderer then runs the classic passes.
    public var isClassic: Bool {
        filter == .nearest && !useHDPack && lighting == .off && !interpolate && scaling != .fill
    }

    /// The shared front-end settings (GameSettings) mapped onto the renderer.
    public init(_ g: GameSettings) {
        self.init()
        filter = UpscaleFilter(g.upscaleFilter)
        useHDPack = g.useHDPack
        lighting = !g.dynamicLighting ? .off : g.lightingStrength == .vivid ? .vivid : .subtle
        interpolate = g.highRefresh
        scaling = Scaling(g.outputScaling)
        rotation = g.displayRotation
        // Settings > Display > Enhanced rendering (defaults = the built-in values above).
        func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Float { v.isFinite ? Float(min(max(v, r.lowerBound), r.upperBound)) : Float(r.lowerBound) }
        crtScanlines = clamp(g.crtScanlines, GameSettings.crtScanlinesRange)
        crtCurvature = clamp(g.crtCurvature, GameSettings.crtCurvatureRange)
        crtMask = clamp(g.crtMask, GameSettings.crtMaskRange)
        roundDots = g.roundDots
        stripInFullTable = g.stripInFullTable
        rotateFlippers = g.rotateFlippers
    }

    /// Resolved scaling for a frame (auto -> integer or fill).
    func resolvedScaling(hdActive: Bool) -> Scaling {
        if scaling != .auto { return scaling }
        return filter == .nearest && !hdActive ? .integer : .fill
    }

    /// Developer override from `EPIC_PINBALL_RENDER`, e.g. `filter=xbrz,hd=1,lighting=subtle,interp=1,scaling=fill,rotate=90`
    /// (lets the existing headless snapshot mode show enhanced output).
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> RenderSettings? {
        guard let spec = env["EPIC_PINBALL_RENDER"], !spec.isEmpty else { return nil }
        var s = RenderSettings()
        for part in spec.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            let k = kv[0], v = kv.count > 1 ? kv[1] : "1"
            let on = v == "1" || v == "on" || v == "true" || v == "yes"
            switch k {
            case "filter": if let f = UpscaleFilter(rawValue: v) { s.filter = f }
            case "hd": s.useHDPack = on
            case "lighting", "light": s.lighting = Lighting(rawValue: v) ?? (on ? .subtle : .off)
            case "interp", "interpolate": s.interpolate = on
            case "scaling": if let sc = Scaling(rawValue: v) { s.scaling = sc }
            case "strip": s.stripInFullTable = on
            case "dots": s.roundDots = v == "round" || on
            case "flippers": s.rotateFlippers = v == "rotate" || on
            case "curvature": s.crtCurvature = Float(v) ?? s.crtCurvature
            case "scanlines": s.crtScanlines = Float(v) ?? s.crtScanlines
            case "mask": s.crtMask = Float(v) ?? s.crtMask
            case "rotate", "rotation": if let r = Int(v).flatMap(GameSettings.DisplayRotation.init(rawValue:)) { s.rotation = r }
            default: break
            }
        }
        return s
    }

    // Lighting parameters (subtle = default when enabled).
    var glowGain: Float { lighting == .vivid ? 1.0 : 0.55 }
    var shadowStrength: Float { lighting == .vivid ? 0.45 : 0.32 }
    var specularStrength: Float { lighting == .vivid ? 0.55 : 0.35 }
    var pulseGain: Float { lighting == .vivid ? 1.6 : 0.8 }
}

public extension UpscaleFilter {
    init(_ f: GameSettings.UpscaleFilter) {
        switch f {
        case .nearest: self = .nearest
        case .smooth: self = .smooth
        case .xbrz: self = .xbrz
        case .crt: self = .crt
        }
    }
}

public extension RenderSettings.Scaling {
    init(_ s: GameSettings.OutputScaling) {
        switch s {
        case .auto: self = .auto
        case .integer: self = .integer
        case .fill: self = .fill
        }
    }
}

/// Motion between the last two simulation frames, filled by the front end once per
/// display frame (high refresh). The renderer draws each ball at its previous +
/// (current - previous) * `alpha` (ball 0: `ballPrevious` / `ballCurrent`, the others: `balls`),
/// and rotates or cross-fades the flippers and eases the camera over the same interval.
/// Simulation timing is untouched.
public struct MotionInterpolation: Sendable, Equatable {
    /// One ball slot's motion over the last frame.
    public struct BallMotion: Sendable, Equatable {
        public var slot: Int
        /// Top-left (sub-pixel) before and after the latest frame; previous nil = just came into play.
        public var previous: Vec2?
        public var current: Vec2
        /// Integer position in the latest frame (where the engine composited its occlusion).
        public var integer: SIMD2<Int>
        public init(slot: Int, previous: Vec2?, current: Vec2, integer: SIMD2<Int>) {
            self.slot = slot; self.previous = previous; self.current = current; self.integer = integer
        }
    }
    /// 0 = the previous simulation frame, 1 = the latest (time since the last frame / frame period).
    public var alpha: Double
    /// Ball 0's top-left (sub-pixel: x + acc/128) before and after the latest frame.
    public var ballPrevious: Vec2?
    public var ballCurrent: Vec2?
    /// Ball 0's integer position in the latest frame (where the engine composited its occlusion).
    public var ballInteger: SIMD2<Int>?
    /// Simulation frame counter; the renderer keeps per-frame history (camera, flippers) by it.
    public var frame: Int
    /// Ease the camera between frames (for the original's per-frame camera; turn off when the
    /// front end already moves the camera continuously).
    public var interpolateCamera: Bool
    /// Slots 1...4 in play (multiball), in slot order.
    public var balls: [BallMotion]

    public init(alpha: Double, ballPrevious: Vec2?, ballCurrent: Vec2?, ballInteger: SIMD2<Int>? = nil,
                frame: Int, interpolateCamera: Bool = true, balls: [BallMotion] = []) {
        self.alpha = alpha; self.ballPrevious = ballPrevious; self.ballCurrent = ballCurrent
        self.ballInteger = ballInteger; self.frame = frame; self.interpolateCamera = interpolateCamera
        self.balls = balls
    }

    /// From the running simulation (call after `advance(by:)`).
    public init(simulation sim: GameSimulation, interpolateCamera: Bool = true) {
        let e = sim.engine, b = e.balls[0]
        let extra = sim.currentBalls.enumerated().dropFirst().compactMap { i, p -> BallMotion? in
            guard let p else { return nil }
            return BallMotion(slot: i, previous: sim.previousBalls.indices.contains(i) ? sim.previousBalls[i] : nil, current: p,
                              integer: SIMD2(Int(e.balls[i].x), Int(e.balls[i].y)))
        }
        self.init(alpha: min(max(sim.accumulator / sim.frameDuration, 0), 1),
                  ballPrevious: sim.previousBall, ballCurrent: sim.currentBall,
                  ballInteger: SIMD2(Int(b.x), Int(b.y)), frame: e.frameCount,
                  interpolateCamera: interpolateCamera, balls: extra)
    }

    /// Previous, current and integer position of `slot` (nil if unknown).
    func motion(slot: Int) -> (previous: Vec2?, current: Vec2?, integer: SIMD2<Int>?)? {
        if slot == 0 { return (ballPrevious, ballCurrent, ballInteger) }
        guard let m = balls.first(where: { $0.slot == slot }) else { return nil }
        return (m.previous, m.current, m.integer)
    }
}

/// Viewport placement for the enhanced path: integer (exactly `ViewportFit`) or fractional fill.
public struct EnhancedFit: Sendable, Equatable {
    public var scaleX: Double, scaleY: Double
    public var x: Double, y: Double, width: Double, height: Double
    public var isInteger: Bool

    public static func fit(sourceWidth sw: Int, sourceHeight sh: Int, outputWidth ow: Int, outputHeight oh: Int,
                           aspect: PixelAspect, scaling: RenderSettings.Scaling) -> EnhancedFit {
        let i = ViewportFit.fit(sourceWidth: sw, sourceHeight: sh, outputWidth: ow, outputHeight: oh, aspect: aspect)
        let integer = EnhancedFit(scaleX: i.scaleX, scaleY: i.scaleY, x: i.x, y: i.y, width: i.width, height: i.height, isInteger: i.isInteger)
        guard scaling == .fill else { return integer }
        let f = min(Double(ow) / Double(sw), Double(oh) / (Double(sh) * aspect.heightOverWidth))
        let sx = max(f, 1e-6), sy = max(f * aspect.heightOverWidth, 1e-6)
        let w = Double(sw) * sx, h = Double(sh) * sy
        let x = ((Double(ow) - w) / 2).rounded(.down), y = ((Double(oh) - h) / 2).rounded(.down)
        let isInt = sx == sx.rounded() && sy == sy.rounded()
        return EnhancedFit(scaleX: sx, scaleY: sy, x: x, y: y, width: w, height: h, isInteger: isInt)
    }
}
