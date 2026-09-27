import XCTest
@testable import PinballCore

final class CameraTests: XCTestCase {
    func testClampAndSnap() {
        var cam = Camera()
        cam.snap(toBallY: 390)
        XCTAssertEqual(cam.y, 200)
        cam.snap(toBallY: 5)
        XCTAssertEqual(cam.y, 0)
        cam.snap(toBallY: 250)
        XCTAssertEqual(cam.y, 150)
        cam.showFullTable = true
        XCTAssertEqual(cam.visibleSpan.top, 0)
        XCTAssertEqual(cam.visibleSpan.height, 400)
    }

    func testFollowConvergesSmoothly() {
        var cam = Camera()
        cam.snap(toBallY: 0)
        var last = cam.y
        for _ in 0..<120 {
            cam.update(dt: 1.0 / 60, ballY: 300, scroll: 0)
            XCTAssertGreaterThanOrEqual(cam.y, last)   // monotone, no overshoot
            last = cam.y
        }
        XCTAssertEqual(cam.y, 200, accuracy: 0.5)
    }

    func testManualScrollOverridesThenResumesFollow() {
        var cam = Camera()
        cam.snap(toBallY: 390) // y = 200
        cam.update(dt: 0.25, ballY: 390, scroll: -1)
        XCTAssertEqual(cam.y, 200 - 80, accuracy: 1e-9)
        cam.update(dt: 1.0, ballY: 390, scroll: 0)   // still holding
        XCTAssertEqual(cam.y, 120, accuracy: 1e-9)
        for _ in 0..<200 { cam.update(dt: 1.0 / 60, ballY: 390, scroll: 0) }
        XCTAssertEqual(cam.y, 200, accuracy: 0.5)
    }
}

final class ViewportTests: XCTestCase {
    func testIntegerScaleRetinaWindow() {
        let f = ViewportFit.fit(sourceWidth: 320, sourceHeight: 200, outputWidth: 1920, outputHeight: 1200)
        XCTAssertEqual(f.scaleX, 6); XCTAssertEqual(f.scaleY, 6)
        XCTAssertEqual(f.x, 0); XCTAssertEqual(f.y, 0)
        XCTAssertTrue(f.isInteger)
    }

    func testFullTableLetterboxed() {
        let f = ViewportFit.fit(sourceWidth: 320, sourceHeight: 400, outputWidth: 1920, outputHeight: 1200)
        XCTAssertEqual(f.scaleX, 3)
        XCTAssertEqual(f.width, 960); XCTAssertEqual(f.height, 1200)
        XCTAssertEqual(f.x, 480)
    }

    func testNonMultipleSizeUsesLargestIntegerScale() {
        let f = ViewportFit.fit(sourceWidth: 320, sourceHeight: 200, outputWidth: 1000, outputHeight: 700)
        XCTAssertEqual(f.scaleX, 3)
        XCTAssertEqual(f.x, 20); XCTAssertEqual(f.y, 50)
    }

    func testVGAAspect() {
        let f = ViewportFit.fit(sourceWidth: 320, sourceHeight: 200, outputWidth: 1600, outputHeight: 1200, aspect: .vga)
        XCTAssertEqual(f.scaleX, 5); XCTAssertEqual(f.scaleY, 6)   // exactly 4:3
    }

    func testTinyOutputFallsBackToFractional() {
        let f = ViewportFit.fit(sourceWidth: 320, sourceHeight: 200, outputWidth: 160, outputHeight: 100)
        XCTAssertFalse(f.isInteger)
        XCTAssertEqual(f.scaleX, 0.5, accuracy: 1e-9)
    }
}
