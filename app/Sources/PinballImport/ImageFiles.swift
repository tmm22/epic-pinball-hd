// File formats the library uses: ZSoft PCX (EPn.DAT previews, tools/pcx.py), numpy .npy
// (uint8 arrays, byte-identical to numpy's own writer) and PNG (ImageIO).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PCXImage {
    var width: Int
    var height: Int
    /// Row-major palette indices.
    var pixels: [UInt8]
    /// 256 RGB triplets (8-bit); zero if the file has no trailing palette.
    var palette: [UInt8]
    var rleEnd: Int

    /// tools/pcx.py decode(): 8 bpp, 1 plane, RLE, trailing 0x0C + 768-byte palette.
    static func decode(_ d: [UInt8], name: String = "PCX") throws -> PCXImage {
        guard d.count > 128, d[0] == 0x0A, d[2] == 1, d[3] == 8 else { throw ImportError("\(name): not an 8bpp RLE PCX") }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        let xmin = u16(4), ymin = u16(6), xmax = u16(8), ymax = u16(10)
        guard d[65] == 1 else { throw ImportError("\(name): unsupported plane count \(d[65])") }
        let bpl = u16(66)
        let w = xmax - xmin + 1, h = ymax - ymin + 1
        guard w > 0, h > 0, bpl >= w else { throw ImportError("\(name): bad PCX dimensions") }
        let total = bpl * h
        var out = [UInt8](repeating: 0, count: total)
        var pos = 128, o = 0
        while o < total {
            guard pos < d.count else { throw ImportError("\(name): PCX data ends early") }
            let b = d[pos]; pos += 1
            var count = 1, val = b
            if b >= 0xC0 {
                guard pos < d.count else { throw ImportError("\(name): PCX data ends early") }
                count = Int(b & 0x3F); val = d[pos]; pos += 1
            }
            let end = min(o + count, total)
            if end > o { for j in o..<end { out[j] = val } }
            o += count
        }
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { px[y * w + x] = out[y * bpl + x] } }
        var pal = [UInt8](repeating: 0, count: 768)
        if d.count >= 769 && d[d.count - 769] == 0x0C { pal = Array(d[(d.count - 768)...]) }
        return PCXImage(width: w, height: h, pixels: px, palette: pal, rleEnd: pos)
    }
}

enum NPYFile {
    /// numpy.save of a C-order uint8 array (format 1.0): identical bytes to numpy's writer.
    static func data(uint8 values: [UInt8], shape: [Int]) -> Data {
        let shapeText = shape.count == 1 ? "(\(shape[0]),)" : "(" + shape.map(String.init).joined(separator: ", ") + ")"
        var header = "{'descr': '|u1', 'fortran_order': False, 'shape': \(shapeText), }"
        // magic(6) + version(2) + len(2) + header + '\n' padded to a multiple of 64
        let unpadded = 10 + header.utf8.count + 1
        let pad = (64 - unpadded % 64) % 64
        header += String(repeating: " ", count: pad) + "\n"
        var d = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 0x01, 0x00])
        let n = header.utf8.count
        d.append(UInt8(n & 0xFF)); d.append(UInt8(n >> 8))
        d.append(contentsOf: Array(header.utf8))
        d.append(contentsOf: values)
        return d
    }
}

enum PNGFile {
    /// Writes 8-bit RGBA (straight alpha) or RGB pixels.
    static func write(_ url: URL, width w: Int, height h: Int, rgba: [UInt8]) throws {
        precondition(rgba.count == w * h * 4)
        guard w > 0, h > 0 else { throw ImportError("\(url.lastPathComponent): empty image") }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ImportError("cannot create \(url.path)")
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw ImportError("cannot write \(url.path)") }
    }

    /// Palette-indexed pixels through a 256 x RGB palette, opaque (or index `transparent` clear).
    static func writeIndexed(_ url: URL, width w: Int, height h: Int, indices: [UInt8], palette: [UInt8], alpha: [UInt8]? = nil) throws {
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let c = Int(indices[i]) * 3
            rgba[i * 4] = palette[c]; rgba[i * 4 + 1] = palette[c + 1]; rgba[i * 4 + 2] = palette[c + 2]
            if let a = alpha { rgba[i * 4 + 3] = a[i] }
        }
        try write(url, width: w, height: h, rgba: rgba)
    }

    /// RGBA8 (premultiplied) pixels of a PNG, decoded the way the app's loaders do
    /// (FlipperSpriteSet.decodePNG: drawn into an sRGB RGBA context). For checks.
    static func read(_ url: URL) -> (w: Int, h: Int, rgba: [UInt8])? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, buf)
    }
}

extension Data {
    func writeAtomically(to url: URL) throws { try write(to: url, options: .atomic) }
}
