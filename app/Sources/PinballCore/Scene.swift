import Foundation

/// Everything the renderer needs for one frame, in table pixel coordinates.
/// Built from simulation + camera state; contains no platform types.
public struct SceneState: Sendable, Equatable {
    public struct BallSprite: Sendable, Equatable {
        /// Top-left of the 15x14 box (may be fractional in enhanced mode).
        public var topLeft: Vec2
        public var width: Int
        public var height: Int
        /// Composited palette indices (0 = transparent), row-major, or nil to draw
        /// the procedural fallback ball.
        public var pixels: [UInt8]?
        public init(topLeft: Vec2, width: Int = 15, height: Int = 14, pixels: [UInt8]?) {
            self.topLeft = topLeft; self.width = width; self.height = height; self.pixels = pixels
        }
    }

    public struct FlipperSprite: Sendable, Equatable {
        /// Index into `EngineData.flippers` (the renderer's sprite set uses the same order).
        public var index: Int
        /// Sprite frame to show (0 = raised ... last = rest).
        public var frame: Int
        /// Procedural fallback: capsule from the current collision outline.
        public var pivot: Vec2
        public var tip: Vec2
        public var radius: Double
        public init(index: Int, frame: Int, pivot: Vec2, tip: Vec2, radius: Double) {
            self.index = index; self.frame = frame; self.pivot = pivot; self.tip = tip; self.radius = radius
        }
    }

    /// Top source row of the visible region (may be fractional for smooth scroll).
    public var viewTop: Double
    /// Number of source rows visible (200 for the scrolling window, 400 for full table).
    public var viewHeight: Double
    public var ball: BallSprite?
    public var flippers: [FlipperSprite]

    public init(viewTop: Double, viewHeight: Double, ball: BallSprite?, flippers: [FlipperSprite]) {
        self.viewTop = viewTop; self.viewHeight = viewHeight; self.ball = ball; self.flippers = flippers
    }

    public init(simulation sim: GameSimulation, camera: Camera, showSprites: Bool = true) {
        let span = camera.visibleSpan
        viewTop = span.top
        viewHeight = span.height
        guard showSprites else { ball = nil; flippers = []; return }
        let e = sim.engine
        if sim.ballVisible {
            ball = BallSprite(topLeft: sim.renderBallTopLeft, width: e.data.ball.w, height: e.data.ball.h,
                              pixels: e.compositedBallPixels(ball: 0))
        } else {
            ball = nil
        }
        flippers = e.data.flippers.enumerated().map { i, f in
            let angle = Int(e.groups[f.group].angle)
            let frames = f.sprite?.frames.count ?? 4
            let (p, t) = sim.flipperCapsule(flipper: i, angle: angle)
            return FlipperSprite(index: i, frame: ClassicEngine.spriteFrame(angle: angle, frameCount: frames),
                                 pivot: p, tip: t, radius: 3)
        }
    }

    /// Fallback flipper shape: a capsule between the two outline pixels farthest apart.
    static func capsule(outline: [Int]) -> (Vec2, Vec2) {
        let pts = outline.map { Vec2(Double($0 % TableGeometry.width) + 0.5, Double($0 / TableGeometry.width) + 0.5) }
        guard pts.count >= 2 else { return (pts.first ?? .zero, pts.first ?? .zero) }
        var best = (pts[0], pts[1]), bestD = -1.0
        // O(n^2) over <= ~200 points, only on the fallback path.
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                let d = pts[i] - pts[j]
                let dd = (d * d).sum()
                if dd > bestD { bestD = dd; best = (pts[i], pts[j]) }
            }
        }
        // Pull the ends inwards by the capsule radius so the shape covers the outline.
        let dir = best.1 - best.0
        let len = max((dir * dir).sum().squareRoot(), 1e-6)
        let u = dir / len
        return (best.0 + u * 3, best.1 - u * 3)
    }
}
