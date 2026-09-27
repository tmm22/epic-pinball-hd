import Foundation

/// Vertical camera over the 320x400 table.
///
/// The original shows a 320x200 window and scrolls it with the VGA start
/// address (Mode X hardware scroll, integer scanlines). Here `y` is continuous
/// so the renderer can scroll smoothly at output resolution.
public struct Camera: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// Follow the ball, smoothed.
        case follow
        /// Arrow keys took over; returns to `.follow` after `manualHoldTime`.
        case manual(idle: Double)
    }

    public var tableHeight: Double = Double(TableGeometry.height)
    public var windowHeight: Double = Double(TableGeometry.windowHeight)
    /// Top edge of the window in table pixels, 0...(tableHeight - windowHeight).
    public private(set) var y: Double = 0
    public var mode: Mode = .follow
    /// Show the whole 320x400 table instead of the scrolling window.
    public var showFullTable = false

    /// Exponential follow rate (1/s): higher = snappier.
    public var followRate: Double = 7
    /// Where in the window the ball should sit (0 = top, 1 = bottom).
    public var followAnchor: Double = 0.5
    public var manualScrollSpeed: Double = 320 // px/s
    public var manualHoldTime: Double = 1.5    // s

    public init() {}

    public var maxY: Double { max(0, tableHeight - windowHeight) }

    /// Source rows currently visible: (top, height) in table pixels.
    public var visibleSpan: (top: Double, height: Double) {
        showFullTable ? (0, tableHeight) : (y, windowHeight)
    }

    public func target(forBallY ballY: Double) -> Double {
        clamp(ballY - windowHeight * followAnchor)
    }

    public mutating func setY(_ value: Double) { y = clamp(value) }

    /// Jump straight to the follow target (no smoothing) - used for snapshots / resets.
    public mutating func snap(toBallY ballY: Double) { y = target(forBallY: ballY) }

    /// - Parameter scroll: -1 (up), 0, +1 (down) from the arrow keys.
    public mutating func update(dt: Double, ballY: Double, scroll: Int) {
        if scroll != 0 {
            mode = .manual(idle: 0)
            y = clamp(y + Double(scroll.signum()) * manualScrollSpeed * dt)
            return
        }
        switch mode {
        case let .manual(idle):
            let t = idle + dt
            mode = t >= manualHoldTime ? .follow : .manual(idle: t)
        case .follow:
            let k = 1 - exp(-followRate * dt)
            y = clamp(y + (target(forBallY: ballY) - y) * k)
        }
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0), maxY) }
}

/// How source pixels are shaped on screen.
public enum PixelAspect: String, Sendable, CaseIterable {
    /// 1:1 pixels (what the extracted PNGs show).
    case square
    /// 320x200 on a 4:3 VGA monitor: pixels are 1.2x taller than wide.
    case vga

    public var heightOverWidth: Double { self == .square ? 1.0 : 1.2 }
}

/// Integer-scaled, aspect-correct placement of a source image in an output surface.
public struct ViewportFit: Sendable, Equatable {
    /// Output pixels per source pixel horizontally / vertically.
    public var scaleX: Double
    public var scaleY: Double
    /// Destination rectangle in output pixels (origin top-left).
    public var x: Double, y: Double, width: Double, height: Double
    /// True when both scales are integers.
    public var isInteger: Bool

    /// - Parameters:
    ///   - source: source size in source pixels (e.g. 320x200).
    ///   - output: drawable size in physical pixels (Retina backing pixels).
    public static func fit(sourceWidth sw: Int, sourceHeight sh: Int,
                           outputWidth ow: Int, outputHeight oh: Int,
                           aspect: PixelAspect = .square) -> ViewportFit {
        func sy(_ sx: Int) -> Int {
            // For VGA aspect keep Y integer too: exact 6:5 whenever sx is a multiple of 5.
            aspect == .square ? sx : Int((Double(sx) * aspect.heightOverWidth).rounded())
        }
        var best = 0
        var s = 1
        while sw * s <= ow && sh * sy(s) <= oh { best = s; s += 1 }
        let scaleX: Double, scaleY: Double, integer: Bool
        if best >= 1 {
            scaleX = Double(best); scaleY = Double(sy(best)); integer = true
        } else {
            // Output smaller than 1x: fall back to a fractional fit.
            let f = min(Double(ow) / Double(sw), Double(oh) / (Double(sh) * aspect.heightOverWidth))
            scaleX = max(f, 1e-6); scaleY = max(f * aspect.heightOverWidth, 1e-6); integer = false
        }
        let w = Double(sw) * scaleX, h = Double(sh) * scaleY
        // Centre on whole pixels so nearest sampling stays crisp.
        let x = ((Double(ow) - w) / 2).rounded(.down), y = ((Double(oh) - h) / 2).rounded(.down)
        return ViewportFit(scaleX: scaleX, scaleY: scaleY, x: x, y: y, width: w, height: h, isInteger: integer)
    }
}
