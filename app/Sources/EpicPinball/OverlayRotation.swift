import Observation
import PinballCore
import SwiftUI

/// Cabinet display (docs/enhanced/frontend.md "Cabinet"): the SwiftUI layers over the running table
/// (pause menu, initials entry, game-over panel, replay / practice banner, status HUD) turn with
/// the Metal picture (`RenderSettings.rotation`), so a cabinet with a monitor on its side reads
/// them upright too. Only the drawing turns: keys and controllers are untouched, and mouse clicks
/// land on the turned buttons because the turn is a SwiftUI transform (hit testing goes through it).
///
/// The overlay is laid out upright in a *logical* frame (the container with width and height
/// swapped for 90 / 270, like `DisplayTransform.logicalWidth/Height` for the picture), turned
/// clockwise about its centre and centred in the container. `OverlayTransform` is that mapping in
/// view points (SwiftUI coordinates: origin top left, y down).
struct OverlayTransform: Equatable {
    var rotation: GameSettings.DisplayRotation
    /// The container (the game view's bounds) in points.
    var size: CGSize

    var swapsAxes: Bool { rotation == .clockwise90 || rotation == .clockwise270 }
    /// The upright frame the overlay is laid out in.
    var logicalSize: CGSize { swapsAxes ? CGSize(width: size.height, height: size.width) : size }
    /// Clockwise turn on screen (SwiftUI's `rotationEffect`, y down: positive = clockwise).
    var degrees: Double { Double(rotation.rawValue) }

    /// Container point that shows logical (upright overlay) point `p`. Clockwise, as the picture:
    /// with 90 the overlay's top is at the container's right-hand edge.
    func view(fromLogical p: CGPoint) -> CGPoint {
        let w = size.width, h = size.height
        switch rotation {
        case .none: return p
        case .clockwise90: return CGPoint(x: w - p.y, y: p.x)
        case .upsideDown: return CGPoint(x: w - p.x, y: h - p.y)
        case .clockwise270: return CGPoint(x: p.y, y: h - p.x)
        }
    }

    /// Logical point under container point `p` (where a click at `p` lands in the upright overlay).
    func logical(fromView p: CGPoint) -> CGPoint {
        let w = size.width, h = size.height
        switch rotation {
        case .none: return p
        case .clockwise90: return CGPoint(x: p.y, y: w - p.x)
        case .upsideDown: return CGPoint(x: w - p.x, y: h - p.y)
        case .clockwise270: return CGPoint(x: h - p.y, y: p.x)
        }
    }

    /// A logical rectangle (e.g. a button's frame) in container points.
    func view(fromLogical r: CGRect) -> CGRect {
        let a = view(fromLogical: CGPoint(x: r.minX, y: r.minY)), b = view(fromLogical: CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

/// The rotation the game's overlays follow; set by `GameController.apply` from the render settings.
@MainActor
@Observable
final class OverlayOrientation {
    var rotation: GameSettings.DisplayRotation
    init(rotation: GameSettings.DisplayRotation = .none) { self.rotation = rotation }
}

/// Lays the content out upright in the logical frame and turns it with the picture. `.none` leaves
/// the view exactly as it was (no GeometryReader, no transform).
struct CabinetRotated: ViewModifier {
    var rotation: GameSettings.DisplayRotation

    @ViewBuilder
    func body(content: Content) -> some View {
        if rotation == .none {
            content
        } else {
            GeometryReader { geo in
                let t = OverlayTransform(rotation: rotation, size: geo.size)
                content
                    .frame(width: t.logicalSize.width, height: t.logicalSize.height)
                    .rotationEffect(.degrees(t.degrees))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
    }
}

extension View {
    /// Turns the view with the cabinet picture rotation (`CabinetRotated`).
    func cabinetRotated(_ rotation: GameSettings.DisplayRotation) -> some View { modifier(CabinetRotated(rotation: rotation)) }
}
