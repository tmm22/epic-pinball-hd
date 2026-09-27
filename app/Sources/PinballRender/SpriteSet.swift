import CoreGraphics
import Foundation
import ImageIO
import PinballCore

/// Flipper sprite frames extracted from the user's EXE (`extracted/tables/EPn/sprites/*.png`,
/// named in engine.json / sprites.json), packed into one RGBA8 atlas (frames stacked vertically).
public struct FlipperSpriteSet: Sendable {
    public struct Entry: Sendable, Equatable {
        /// Destination rectangle in table pixels (the sprites are opaque and position-bound).
        public var x: Int, y: Int, w: Int, h: Int
        /// Atlas row of each frame's top edge.
        public var frameRows: [Int]
    }

    /// Indexed like `EngineData.flippers`; nil where the sprite could not be loaded.
    public let entries: [Entry?]
    public let atlasWidth: Int
    public let atlasHeight: Int
    /// RGBA8, row-major, `atlasWidth * 4` bytes per row.
    public let atlas: [UInt8]

    public var isEmpty: Bool { entries.allSatisfy { $0 == nil } }

    /// Loads every flipper's frames. Missing or unreadable files leave that flipper nil
    /// (the renderer then draws the procedural fallback) and add a warning.
    public static func load(engine: EngineData, spriteDirectory dir: URL) -> (FlipperSpriteSet, [String]) {
        var warnings: [String] = []
        var images: [[(w: Int, h: Int, rgba: [UInt8])]?] = []
        for (i, f) in engine.flippers.enumerated() {
            guard let s = f.sprite else {
                warnings.append("flipper \(i): no sprite in engine.json")
                images.append(nil)
                continue
            }
            var frames: [(w: Int, h: Int, rgba: [UInt8])] = []
            for name in s.frames {
                let url = dir.appendingPathComponent(name)
                guard let img = decodePNG(url) else { warnings.append("flipper \(i): cannot read \(url.path)"); break }
                frames.append(img)
            }
            images.append(frames.count == s.frames.count && !frames.isEmpty ? frames : nil)
        }
        let width = max(1, images.compactMap { $0?.map(\.w).max() }.max() ?? 1)
        var height = 0
        var entries: [Entry?] = []
        for (i, fr) in images.enumerated() {
            guard let fr, let s = engine.flippers[i].sprite else { entries.append(nil); continue }
            var rows: [Int] = []
            for f in fr { rows.append(height); height += f.h }
            entries.append(Entry(x: s.x, y: s.y, w: fr[0].w, h: fr[0].h, frameRows: rows))
        }
        height = max(1, height)
        var atlas = [UInt8](repeating: 0, count: width * height * 4)
        var row = 0
        for fr in images {
            guard let fr else { continue }
            for f in fr {
                for y in 0..<f.h {
                    let src = y * f.w * 4, dst = (row + y) * width * 4
                    atlas.replaceSubrange(dst..<(dst + f.w * 4), with: f.rgba[src..<(src + f.w * 4)])
                }
                row += f.h
            }
        }
        return (FlipperSpriteSet(entries: entries, atlasWidth: width, atlasHeight: height, atlas: atlas), warnings)
    }

    /// PNG -> straight (non-premultiplied) RGBA8 bytes, top row first.
    static func decodePNG(_ url: URL) -> (w: Int, h: Int, rgba: [UInt8])? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        // Draw into an sRGB RGBA context without colour conversion surprises: the PNGs are
        // tagged sRGB (or untagged) and hold the palette's 8-bit values.
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Flipper frames are opaque; un-premultiply defensively anyway.
        for i in stride(from: 0, to: buf.count, by: 4) where buf[i + 3] != 0 && buf[i + 3] != 255 {
            let a = Double(buf[i + 3]) / 255
            for c in 0..<3 { buf[i + c] = UInt8(min(255, (Double(buf[i + c]) / a).rounded())) }
        }
        return (w, h, buf)
    }
}
