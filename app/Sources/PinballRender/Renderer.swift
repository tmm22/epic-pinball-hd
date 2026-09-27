import Foundation
import Metal
import PinballCore

/// Upscaling filter applied in the present pass. Add a case + a fragment
/// function in Pinball.metal to plug in a new filter (e.g. xBR, CRT mask).
public enum UpscaleFilter: String, Sendable, CaseIterable {
    case nearest

    var fragmentFunctionName: String {
        switch self {
        case .nearest: return "present_nearest"
        }
    }
}

public enum RenderError: Error, CustomStringConvertible {
    case noDevice
    case shaderSourceMissing
    case shaderCompile(String)
    case resourceCreation(String)

    public var description: String {
        switch self {
        case .noDevice: return "no Metal device available"
        case .shaderSourceMissing: return "Pinball.metal resource not found in the PinballRender bundle"
        case let .shaderCompile(s): return "Metal shader compilation failed: \(s)"
        case let .resourceCreation(s): return "could not create Metal resource: \(s)"
        }
    }
}

// Mirrors of the MSL structs in Pinball.metal (16-byte vector members only => identical layout).
struct SceneUniforms {
    typealias F4 = SIMD4<Float>
    var view: F4 = .zero
    var ball: F4 = .zero
    var ballInfo: F4 = .zero
    var flipperRect: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    var flipperInfo: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    var capsule: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    var ballPixels: (SIMD4<UInt32>, SIMD4<UInt32>, SIMD4<UInt32>, SIMD4<UInt32>, SIMD4<UInt32>, SIMD4<UInt32>, SIMD4<UInt32>,
                     SIMD4<UInt32>, SIMD4<UInt32>, SIMD4<UInt32>, SIMD4<UInt32>, SIMD4<UInt32>, SIMD4<UInt32>, SIMD4<UInt32>)
        = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)

    static let maxFlippers = 4
    static let ballBytes = 14 * 16

    mutating func setFlipper(_ i: Int, rect: F4, info: F4, capsule c: F4) {
        switch i {
        case 0: flipperRect.0 = rect; flipperInfo.0 = info; capsule.0 = c
        case 1: flipperRect.1 = rect; flipperInfo.1 = info; capsule.1 = c
        case 2: flipperRect.2 = rect; flipperInfo.2 = info; capsule.2 = c
        case 3: flipperRect.3 = rect; flipperInfo.3 = info; capsule.3 = c
        default: break
        }
    }

    mutating func setBallPixels(_ px: [UInt8]) {
        withUnsafeMutableBytes(of: &ballPixels) { raw in
            for i in 0..<min(px.count, raw.count) { raw[i] = px[i] }
        }
    }
}

struct PresentUniforms {
    var dst: SIMD4<Float>
    var src: SIMD4<Float>
}

/// Two-pass palette renderer.
///
/// Pass 1 renders the visible table rows at native 320-wide resolution into an
/// offscreen RGBA texture (index texture -> palette lookup -> flipper sprite frames
/// and the composited ball; procedural shapes only when sprites are missing).
/// Pass 2 upscales that frame into the output with an integer, aspect-correct
/// viewport using the selected `UpscaleFilter`.
public final class PinballRenderer {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public var aspect: PixelAspect = .square
    public var filter: UpscaleFilter = .nearest
    public private(set) var palette: Palette

    private let library: MTLLibrary
    private let scenePipeline: MTLRenderPipelineState
    private var presentPipelines: [String: MTLRenderPipelineState] = [:]
    private let indexTexture: MTLTexture
    private let paletteTexture: MTLTexture
    private let atlasTexture: MTLTexture
    /// Flipper sprite frames (nil entries fall back to procedural capsules).
    public let flipperSprites: FlipperSpriteSet?
    /// Native frame: 320 x (400 + 1). One spare row allows sub-row smooth scrolling.
    private let frameTexture: MTLTexture
    static let frameFormat: MTLPixelFormat = .rgba8Unorm

    public init(device: MTLDevice, assets: TableAssets, flipperSprites: FlipperSpriteSet? = nil) throws {
        self.device = device
        self.flipperSprites = flipperSprites
        guard let q = device.makeCommandQueue() else { throw RenderError.resourceCreation("command queue") }
        self.commandQueue = q
        self.palette = assets.palette

        let source = try Self.shaderSource()
        do { library = try device.makeLibrary(source: source, options: nil) } catch {
            throw RenderError.shaderCompile(String(describing: error))
        }

        let w = TableGeometry.width, h = TableGeometry.height

        let idxDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: w, height: h, mipmapped: false)
        idxDesc.usage = .shaderRead
        idxDesc.storageMode = .shared
        guard let idx = device.makeTexture(descriptor: idxDesc) else { throw RenderError.resourceCreation("index texture") }
        assets.indices.withUnsafeBytes { raw in
            idx.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: w)
        }
        indexTexture = idx

        let palDesc = MTLTextureDescriptor()
        palDesc.textureType = .type1D
        palDesc.pixelFormat = .rgba8Unorm
        palDesc.width = Palette.count
        palDesc.usage = .shaderRead
        palDesc.storageMode = .shared
        guard let pal = device.makeTexture(descriptor: palDesc) else { throw RenderError.resourceCreation("palette texture") }
        paletteTexture = pal

        let frameDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.frameFormat, width: w, height: h + 1, mipmapped: false)
        frameDesc.usage = [.renderTarget, .shaderRead]
        frameDesc.storageMode = .private
        guard let frame = device.makeTexture(descriptor: frameDesc) else { throw RenderError.resourceCreation("frame texture") }
        frameTexture = frame

        let sprites = flipperSprites
        let atlasDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: sprites?.atlasWidth ?? 1,
                                                                 height: sprites?.atlasHeight ?? 1, mipmapped: false)
        atlasDesc.usage = .shaderRead
        atlasDesc.storageMode = .shared
        guard let atlas = device.makeTexture(descriptor: atlasDesc) else { throw RenderError.resourceCreation("sprite atlas") }
        if let sprites {
            sprites.atlas.withUnsafeBytes { raw in
                atlas.replace(region: MTLRegionMake2D(0, 0, sprites.atlasWidth, sprites.atlasHeight), mipmapLevel: 0,
                              withBytes: raw.baseAddress!, bytesPerRow: sprites.atlasWidth * 4)
            }
        }
        atlasTexture = atlas

        scenePipeline = try Self.makePipeline(device: device, library: library, fragment: "scene_fragment", format: Self.frameFormat)
        uploadPalette()
    }

    static func shaderSource() throws -> String {
        guard let url = Bundle.module.url(forResource: "Pinball", withExtension: "metal"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            throw RenderError.shaderSourceMissing
        }
        return s
    }

    private static func makePipeline(device: MTLDevice, library: MTLLibrary, fragment: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        guard let f = library.makeFunction(name: fragment) else { throw RenderError.shaderCompile("missing function \(fragment)") }
        d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = format
        do { return try device.makeRenderPipelineState(descriptor: d) } catch {
            throw RenderError.shaderCompile("\(fragment): \(error)")
        }
    }

    private func presentPipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let key = "\(filter.rawValue)/\(format.rawValue)"
        if let p = presentPipelines[key] { return p }
        let p = try Self.makePipeline(device: device, library: library, fragment: filter.fragmentFunctionName, format: format)
        presentPipelines[key] = p
        return p
    }

    // MARK: - Palette (lamp animation hook)

    /// Replace the whole palette (e.g. after lamp logic edits entries 200-254).
    public func setPalette(_ p: Palette) {
        palette = p
        uploadPalette()
    }

    /// Change a single entry - cheap enough to call per frame for lamp cycling.
    public func setPaletteEntry(_ index: Int, _ rgb: Palette.RGB) {
        palette[index] = rgb
        var bytes: [UInt8] = [rgb.r, rgb.g, rgb.b, 255]
        paletteTexture.replace(region: MTLRegionMake1D(index, 1), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: 4)
    }

    private func uploadPalette() {
        let bytes = palette.rgba8
        bytes.withUnsafeBytes { raw in
            paletteTexture.replace(region: MTLRegionMake1D(0, Palette.count), mipmapLevel: 0,
                                   withBytes: raw.baseAddress!, bytesPerRow: Palette.count * 4)
        }
    }

    // MARK: - Frame encoding

    /// Viewport the scene will occupy in an output of the given pixel size.
    public func fit(for scene: SceneState, outputWidth: Int, outputHeight: Int) -> ViewportFit {
        ViewportFit.fit(sourceWidth: TableGeometry.width, sourceHeight: Int(scene.viewHeight.rounded()),
                        outputWidth: outputWidth, outputHeight: outputHeight, aspect: aspect)
    }

    /// Encodes both passes, finishing with `target` cleared to black outside the viewport.
    public func encode(scene: SceneState, into commandBuffer: MTLCommandBuffer, target: MTLTexture) throws {
        let fit = fit(for: scene, outputWidth: target.width, outputHeight: target.height)
        let tableH = Double(TableGeometry.height)
        let visibleRows = scene.viewHeight.rounded()

        // Split the (possibly fractional) top row into integer origin + snapped fraction.
        let top = min(max(scene.viewTop, 0), max(0, tableH - visibleRows))
        var origin = top.rounded(.down)
        var frac = top - origin
        if fit.isInteger {
            frac = (frac * fit.scaleY).rounded() / fit.scaleY  // move in whole output pixels
            if frac >= 1 { origin += 1; frac = 0 }
        }
        let rendered = Int(visibleRows) + 1

        // Pass 1: native-resolution palette lookup + sprites.
        var su = SceneUniforms()
        su.view = SIMD4(Float(origin), Float(rendered), Float(TableGeometry.width), Float(tableH))
        if let b = scene.ball {
            su.ball = SIMD4(Float(b.topLeft.x), Float(b.topLeft.y), Float(b.width), Float(b.height))
            if let px = b.pixels, px.count == b.width * b.height, px.count <= SceneUniforms.ballBytes {
                su.ballInfo = SIMD4(1, 0, 0, 0)
                su.setBallPixels(px)
            } else {
                su.ballInfo = SIMD4(2, 0, 0, 0)
            }
        }
        for (slot, f) in scene.flippers.prefix(SceneUniforms.maxFlippers).enumerated() {
            let cap = SIMD4(Float(f.pivot.x), Float(f.pivot.y), Float(f.tip.x), Float(f.tip.y))
            if let sp = flipperSprites, sp.entries.indices.contains(f.index), let e = sp.entries[f.index] {
                let frame = max(0, min(e.frameRows.count - 1, f.frame))
                su.setFlipper(slot, rect: SIMD4(Float(e.x), Float(e.y), Float(e.w), Float(e.h)),
                              info: SIMD4(1, Float(e.frameRows[frame]), 0, 0), capsule: cap)
            } else {
                su.setFlipper(slot, rect: .zero, info: SIMD4(2, 0, Float(f.radius), 0), capsule: cap)
            }
        }

        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = frameTexture
        scenePass.colorAttachments[0].loadAction = .dontCare
        scenePass.colorAttachments[0].storeAction = .store
        guard let enc1 = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) else {
            throw RenderError.resourceCreation("scene encoder")
        }
        enc1.label = "scene (palette lookup)"
        enc1.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(TableGeometry.width), height: Double(rendered), znear: 0, zfar: 1))
        enc1.setRenderPipelineState(scenePipeline)
        enc1.setFragmentBytes(&su, length: MemoryLayout<SceneUniforms>.stride, index: 0)
        enc1.setFragmentTexture(indexTexture, index: 0)
        enc1.setFragmentTexture(paletteTexture, index: 1)
        enc1.setFragmentTexture(atlasTexture, index: 2)
        enc1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc1.endEncoding()

        // Pass 2: upscale into the output.
        var pu = PresentUniforms(
            dst: SIMD4(Float(fit.x), Float(fit.y), Float(fit.scaleX), Float(fit.scaleY)),
            src: SIMD4(Float(TableGeometry.width), Float(visibleRows), Float(frac), 0))
        let presentPass = MTLRenderPassDescriptor()
        presentPass.colorAttachments[0].texture = target
        presentPass.colorAttachments[0].loadAction = .clear
        presentPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        presentPass.colorAttachments[0].storeAction = .store
        guard let enc2 = commandBuffer.makeRenderCommandEncoder(descriptor: presentPass) else {
            throw RenderError.resourceCreation("present encoder")
        }
        enc2.label = "present (\(filter.rawValue))"
        enc2.setViewport(MTLViewport(originX: fit.x, originY: fit.y, width: fit.width, height: fit.height, znear: 0, zfar: 1))
        let sx = max(0, Int(fit.x)), sy = max(0, Int(fit.y))
        enc2.setScissorRect(MTLScissorRect(x: sx, y: sy,
                                           width: max(1, min(Int(fit.width.rounded(.up)), target.width - sx)),
                                           height: max(1, min(Int(fit.height.rounded(.up)), target.height - sy))))
        enc2.setRenderPipelineState(try presentPipeline(for: target.pixelFormat))
        enc2.setFragmentBytes(&pu, length: MemoryLayout<PresentUniforms>.stride, index: 0)
        enc2.setFragmentTexture(frameTexture, index: 0)
        enc2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc2.endEncoding()
    }
}
