import AppKit
import Foundation
import SwiftUI
import PinballCore
import PinballRender
import XCTest
@testable import EpicPinball

/// Cabinet settings in settings.json: old files keep decoding, the new fields round-trip, and a
/// value that is not a supported rotation falls back to the default without losing the rest.
final class CabinetSettingsTests: XCTestCase {
    func testOldSettingsFileKeepsDefaults() {
        let json = #"{"version":1,"game":{"physicsMode":"enhanced","upscaleFilter":"crt","musicVolume":0.5},"frontEnd":{"players":2}}"#
        let s = StoredSettings.decode(Data(json.utf8))
        XCTAssertEqual(s.game.physicsMode, .enhanced)
        XCTAssertEqual(s.game.upscaleFilter, .crt)
        XCTAssertEqual(s.game.displayRotation, .none)
        XCTAssertFalse(s.game.scoreWindow)
        XCTAssertEqual(s.frontEnd.players, 2)
    }

    func testRoundTripAndBadRotation() throws {
        var s = StoredSettings()
        s.game.displayRotation = .clockwise90
        s.game.scoreWindow = true
        XCTAssertEqual(StoredSettings.decode(try s.encoded()), s)

        let json = #"{"version":1,"game":{"displayRotation":45,"scoreWindow":true,"upscaleFilter":"xbrz"}}"#
        let b = StoredSettings.decode(Data(json.utf8))
        XCTAssertEqual(b.game.displayRotation, .none, "45 degrees is not a rotation: default kept")
        XCTAssertTrue(b.game.scoreWindow)
        XCTAssertEqual(b.game.upscaleFilter, .xbrz)
    }

    func testRotationOption() throws {
        XCTAssertEqual(try Options.parse(["--rotate", "270"]).rotation, .clockwise270)
        XCTAssertNil(try Options.parse([]).rotation)
        XCTAssertThrowsError(try Options.parse(["--rotate", "45"]))
        let o = try Options.parse(["--score-window", "--score-snapshot", "/tmp/s.png", "--score-size", "1280x160"])
        XCTAssertTrue(o.scoreWindow)
        XCTAssertEqual(o.scoreSnapshot, "/tmp/s.png")
        XCTAssertEqual(o.scoreSize.map { [$0.0, $0.1] }, [1280, 160])
    }
}

/// Score window rotation and the SwiftUI overlays turned with the picture (OverlayRotation.swift).
final class CabinetRotationTests: XCTestCase {
    func testScoreWindowRotationSetting() throws {
        let old = StoredSettings.decode(Data(#"{"version":1,"game":{"displayRotation":90,"scoreWindow":true}}"#.utf8))
        XCTAssertEqual(old.game.scoreWindowRotation, .none, "a file without the field keeps the default")
        XCTAssertEqual(old.game.displayRotation, .clockwise90)
        var s = StoredSettings()
        s.game.scoreWindowRotation = .clockwise270
        XCTAssertEqual(StoredSettings.decode(try s.encoded()).game.scoreWindowRotation, .clockwise270)
        let bad = StoredSettings.decode(Data(#"{"version":1,"game":{"scoreWindowRotation":45,"scoreWindow":true}}"#.utf8))
        XCTAssertEqual(bad.game.scoreWindowRotation, .none)
        XCTAssertTrue(bad.game.scoreWindow)
        XCTAssertEqual(try Options.parse(["--score-rotate", "90"]).scoreRotation, .clockwise90)
        XCTAssertNil(try Options.parse([]).scoreRotation)
        XCTAssertThrowsError(try Options.parse(["--score-rotate", "45"]))
    }

    func testOverlayTransformMath() {
        let size = CGSize(width: 800, height: 600)
        for r in GameSettings.DisplayRotation.allCases {
            let t = OverlayTransform(rotation: r, size: size)
            let l = t.logicalSize
            XCTAssertEqual(l, r == .clockwise90 || r == .clockwise270 ? CGSize(width: 600, height: 800) : size)
            // Bijection between the logical frame and the container.
            for p in [CGPoint(x: 0, y: 0), CGPoint(x: 13.5, y: 77.25), CGPoint(x: l.width, y: l.height), CGPoint(x: l.width / 2, y: 3)] {
                let v = t.view(fromLogical: p)
                XCTAssertTrue(v.x >= 0 && v.y >= 0 && v.x <= size.width && v.y <= size.height, "\(r) \(p) -> \(v)")
                let back = t.logical(fromView: v)
                XCTAssertEqual(back.x, p.x, accuracy: 1e-9); XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
            }
            // The centre stays put (the overlay is turned about it).
            let c = t.view(fromLogical: CGPoint(x: l.width / 2, y: l.height / 2))
            XCTAssertEqual(c.x, 400, accuracy: 1e-9); XCTAssertEqual(c.y, 300, accuracy: 1e-9)
            // Pixel centres map like the picture's DisplayTransform (same clockwise convention).
            let d = DisplayTransform(rotation: r, outputWidth: 800, outputHeight: 600)
            for p in [SIMD2(0, 0), SIMD2(5, 9), SIMD2(d.logicalWidth - 1, d.logicalHeight - 1), SIMD2(123, 45)] {
                let v = t.view(fromLogical: CGPoint(x: Double(p.x) + 0.5, y: Double(p.y) + 0.5))
                let q = d.physical(fromLogical: p)
                XCTAssertEqual(v.x - 0.5, Double(q.x), accuracy: 1e-9, "\(r) \(p)")
                XCTAssertEqual(v.y - 0.5, Double(q.y), accuracy: 1e-9, "\(r) \(p)")
            }
            // Rectangles keep their size (swapped for 90 / 270).
            let rect = t.view(fromLogical: CGRect(x: 10, y: 20, width: 100, height: 40))
            let swaps = r == .clockwise90 || r == .clockwise270
            XCTAssertEqual(rect.width, swaps ? 40 : 100, accuracy: 1e-9)
            XCTAssertEqual(rect.height, swaps ? 100 : 40, accuracy: 1e-9)
        }
        // 90 clockwise: the overlay's top edge is at the container's right-hand edge.
        let t90 = OverlayTransform(rotation: .clockwise90, size: size)
        XCTAssertEqual(t90.view(fromLogical: CGPoint(x: 0, y: 0)), CGPoint(x: 800, y: 0))
        XCTAssertEqual(t90.view(fromLogical: CGPoint(x: 600, y: 0)), CGPoint(x: 800, y: 600))
        let t270 = OverlayTransform(rotation: .clockwise270, size: size)
        XCTAssertEqual(t270.view(fromLogical: CGPoint(x: 0, y: 0)), CGPoint(x: 0, y: 600))
    }

    /// Clicks reach the turned buttons: a real NSHostingView in an offscreen window, mouse events at
    /// the transformed position of a button hit it, at its upright position they do not.
    @MainActor
    func testMouseHitsTurnedButton() throws {
        _ = NSApplication.shared
        let W: CGFloat = 640, H: CGFloat = 480
        final class Hits { var count = 0 }
        for r in GameSettings.DisplayRotation.allCases {
            let hits = Hits()
            let t = OverlayTransform(rotation: r, size: CGSize(width: W, height: H))
            // A 120x40 button whose centre is at logical (110, 70) (top-left part of the upright overlay).
            let button = CGRect(x: 50, y: 50, width: 120, height: 40)
            let view = ZStack(alignment: .topLeading) {
                Color.clear
                Button { hits.count += 1 } label: { Color.orange.frame(width: button.width, height: button.height) }
                    .buttonStyle(.plain)
                    .offset(x: button.minX, y: button.minY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cabinetRotated(r)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: W, height: H)
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: W, height: H), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            func click(_ p: CGPoint) {
                // SwiftUI points (y down) -> window coordinates (y up).
                let loc = NSPoint(x: p.x, y: H - p.y)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                    window.sendEvent(e)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            }
            let centre = CGPoint(x: button.midX, y: button.midY)
            click(t.view(fromLogical: centre))
            XCTAssertEqual(hits.count, 1, "\(r): click at the turned button")
            if r != .none {
                click(centre)   // where the button would be unturned
                XCTAssertEqual(hits.count, 1, "\(r): nothing at the upright position")
            }
            // Near the turned button's far corner (inside), still a hit.
            click(t.view(fromLogical: CGPoint(x: button.maxX - 4, y: button.maxY - 4)))
            XCTAssertEqual(hits.count, 2, "\(r): click inside the turned button's corner")
            window.orderOut(nil)
        }
    }
}
