import Foundation
import Metal
import XCTest
import PinballCore
@testable import PinballRender

/// GPU end-to-end check: the palette-lookup pass must reproduce the indexed
/// playfield exactly (synthetic data, so it needs no game files).
final class RenderTests: XCTestCase {
    func makeAssets() throws -> TableAssets {
        let w = TableGeometry.width, h = TableGeometry.height
        var idx = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { idx[y * w + x] = UInt8((x + y * 3) & 0xFF) } }
        var entries: [Palette.RGB] = []
        for i in 0..<256 {
            let b: Int = (i * 7) & 0xFF
            entries.append(Palette.RGB(r: UInt8(i), g: UInt8(255 - i), b: UInt8(b)))
        }
        let pal = try Palette(entries: entries)
        return TableAssets(table: 1, indices: idx, palette: pal, directory: URL(fileURLWithPath: "/"))
    }

    func testPaletteLookupAndCameraWindow() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let assets = try makeAssets()
        let r = try PinballRenderer(device: device, assets: assets)
        let scene = SceneState(viewTop: 37, viewHeight: 200, ball: nil, flippers: [])
        let px = try r.renderOffscreen(scene: scene, width: 640, height: 400) // 2x
        for (x, y) in [(0, 0), (319, 0), (100, 150), (319, 199)] {
            let i: Int = Int(assets.indices[(y + 37) * 320 + x])
            let o: Int = ((y * 2) * 640 + x * 2) * 4
            let expected: [UInt8] = [UInt8(i), UInt8(255 - i), UInt8((i * 7) & 0xFF)]
            XCTAssertEqual(Array(px[o..<o + 3]), expected, "pixel \(x),\(y)")
        }
    }

    func testPaletteEditChangesOutput() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let r = try PinballRenderer(device: device, assets: try makeAssets())
        r.setPaletteEntry(0, Palette.RGB(r: 1, g: 2, b: 3))   // index at (0,0) is 0
        let px = try r.renderOffscreen(scene: SceneState(viewTop: 0, viewHeight: 400, ball: nil, flippers: []), width: 320, height: 400)
        XCTAssertEqual(Array(px[0..<3]), [1, 2, 3])
    }

    func testFlipperAtlasFrameAndIndexedBall() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let assets = try makeAssets()
        // 4x2 frames stacked: frame 0 red, frame 1 green (synthetic)
        var atlas = [UInt8]()
        for row in 0..<4 { for _ in 0..<4 { atlas += row < 2 ? [255, 0, 0, 255] : [0, 255, 0, 255] } }
        let sprites = FlipperSpriteSet(entries: [.init(x: 10, y: 20, w: 4, h: 2, frameRows: [0, 2])],
                                       atlasWidth: 4, atlasHeight: 4, atlas: atlas)
        let r = try PinballRenderer(device: device, assets: assets, flipperSprites: sprites)
        var ball = [UInt8](repeating: 0, count: 210)
        ball[1] = 7                                    // row 0, column 1
        let scene = SceneState(viewTop: 0, viewHeight: 400,
                               ball: .init(topLeft: Vec2(100, 50), pixels: ball),
                               flippers: [.init(index: 0, frame: 1, pivot: .zero, tip: .zero, radius: 3)])
        let px = try r.renderOffscreen(scene: scene, width: 320, height: 400)
        func at(_ x: Int, _ y: Int) -> [UInt8] { let o = (y * 320 + x) * 4; return Array(px[o..<o + 3]) }
        func pal(_ i: Int) -> [UInt8] { [UInt8(i), UInt8(255 - i), UInt8((i * 7) & 0xFF)] }
        XCTAssertEqual(at(11, 21), [0, 255, 0])        // frame 1 of the atlas
        XCTAssertEqual(at(14, 21), pal(Int(assets.indices[21 * 320 + 14])))  // outside the sprite rect
        XCTAssertEqual(at(101, 50), pal(7))            // ball pixel -> palette
        XCTAssertEqual(at(100, 50), pal(Int(assets.indices[50 * 320 + 100])))  // index 0 = transparent
    }

    func testProceduralFallbackWhenSpriteMissing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let assets = try makeAssets()
        let r = try PinballRenderer(device: device, assets: assets, flipperSprites: nil)
        let scene = SceneState(viewTop: 0, viewHeight: 400, ball: .init(topLeft: Vec2(200, 100), pixels: nil),
                               flippers: [.init(index: 0, frame: 0, pivot: Vec2(40, 300), tip: Vec2(80, 310), radius: 3)])
        let px = try r.renderOffscreen(scene: scene, width: 320, height: 400)
        func at(_ x: Int, _ y: Int) -> [UInt8] { let o = (y * 320 + x) * 4; return Array(px[o..<o + 3]) }
        func pal(_ x: Int, _ y: Int) -> [UInt8] { let i = Int(assets.indices[y * 320 + x]); return [UInt8(i), UInt8(255 - i), UInt8((i * 7) & 0xFF)] }
        XCTAssertNotEqual(at(60, 305), pal(60, 305))   // capsule drawn
        XCTAssertNotEqual(at(207, 107), pal(207, 107)) // procedural ball drawn
        XCTAssertEqual(at(5, 5), pal(5, 5))
    }
}
