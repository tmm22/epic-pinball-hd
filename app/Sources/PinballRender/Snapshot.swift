import CoreGraphics
import Foundation
import ImageIO
import Metal
import PinballCore
import UniformTypeIdentifiers

/// Headless offscreen rendering for verification (no window, no MetalKit).
public extension PinballRenderer {
    /// Renders one frame into an offscreen texture and returns it as RGBA8 bytes
    /// (row-major, top row first, `width * 4` bytes per row).
    func renderOffscreen(scene: SceneState, width: Int, height: Int) throws -> [UInt8] {
        try renderOffscreen(width: width, height: height) { cb, target in try encode(scene: scene, into: cb, target: target) }
    }

    /// Runs `encode` into a fresh RGBA8 target of the given size and reads it back.
    func renderOffscreen(width: Int, height: Int, encode: (MTLCommandBuffer, MTLTexture) throws -> Void) throws -> [UInt8] {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let target = device.makeTexture(descriptor: desc) else { throw RenderError.resourceCreation("snapshot target") }
        let bytesPerRow = width * 4
        guard let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let cb = commandQueue.makeCommandBuffer() else {
            throw RenderError.resourceCreation("snapshot readback buffer")
        }
        try encode(cb, target)
        guard let blit = cb.makeBlitCommandEncoder() else { throw RenderError.resourceCreation("blit encoder") }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let err = cb.error { throw RenderError.resourceCreation("GPU error: \(err)") }
        let ptr = buffer.contents().bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        return Array(UnsafeBufferPointer(start: ptr, count: bytesPerRow * height))
    }
}

public enum PNGWriter {
    /// Writes RGBA8 bytes (alpha ignored) as an sRGB-tagged PNG.
    public static func write(rgba: [UInt8], width: Int, height: Int, to url: URL) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: cs,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw RenderError.resourceCreation("CGImage")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.resourceCreation("PNG destination at \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.resourceCreation("PNG encode \(url.path)") }
    }
}
