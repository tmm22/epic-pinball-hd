import Foundation
import Metal
import PinballCore

// Mirrors of the enhanced MSL structs in Pinball.metal (float4 members only).
struct EnhSceneUniforms {
    typealias F4 = SIMD4<Float>
    var view: F4 = .zero
    var flipRect: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    var flipInfo: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    /// Rotated flippers (scene_hd): union rect; pivot + native atlas row + frame count;
    /// sprite row + rotation of the two frames; enabled, weight of the second, background row, pad.
    var rotRect: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    var rotPivot: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    var rotFrames: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    var rotInfo: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)

    mutating func setFlipper(_ i: Int, rect: F4, info: F4) {
        switch i {
        case 0: flipRect.0 = rect; flipInfo.0 = info
        case 1: flipRect.1 = rect; flipInfo.1 = info
        case 2: flipRect.2 = rect; flipInfo.2 = info
        case 3: flipRect.3 = rect; flipInfo.3 = info
        default: break
        }
    }

    mutating func setRotation(_ i: Int, rect: F4, pivot: F4, frames: F4, info: F4) {
        switch i {
        case 0: rotRect.0 = rect; rotPivot.0 = pivot; rotFrames.0 = frames; rotInfo.0 = info
        case 1: rotRect.1 = rect; rotPivot.1 = pivot; rotFrames.1 = frames; rotInfo.1 = info
        case 2: rotRect.2 = rect; rotPivot.2 = pivot; rotFrames.2 = frames; rotInfo.2 = info
        case 3: rotRect.3 = rect; rotPivot.3 = pivot; rotFrames.3 = frames; rotInfo.3 = info
        default: break
        }
    }
}

struct EnhPresentUniforms {
    typealias F4 = SIMD4<Float>
    var dst: F4 = .zero, src: F4 = .zero, mode: F4 = .zero, frame: F4 = .zero
    var ball: F4 = .zero, ballInfo: F4 = .zero, light: F4 = .zero, crt: F4 = .zero, viewport: F4 = .zero
    /// More balls (multiball) after `ball`, in slot order: x: count; per ball xy top-left (zw size),
    /// and z of `extraInfo` its occlusion level.
    var extra: F4 = .zero
    var extraBall: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    var extraInfo: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    static let maxExtraBalls = 4
    /// Rotated flippers at output resolution (no HD pack, FC_ROTATE): union rect; pivot + native atlas
    /// row + frame count; sprite row + rotation of the two frames; enabled, weight of the second,
    /// sprite scale, padding.
    var rotRect: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    var rotPivot: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    var rotFrames: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    var rotInfo: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)

    mutating func setExtraBall(_ i: Int, ball: F4, info: F4) {
        switch i {
        case 0: extraBall.0 = ball; extraInfo.0 = info
        case 1: extraBall.1 = ball; extraInfo.1 = info
        case 2: extraBall.2 = ball; extraInfo.2 = info
        case 3: extraBall.3 = ball; extraInfo.3 = info
        default: break
        }
    }

    mutating func setRotation(_ i: Int, rect: F4, pivot: F4, frames: F4, info: F4) {
        switch i {
        case 0: rotRect.0 = rect; rotPivot.0 = pivot; rotFrames.0 = frames; rotInfo.0 = info
        case 1: rotRect.1 = rect; rotPivot.1 = pivot; rotFrames.1 = frames; rotInfo.1 = info
        case 2: rotRect.2 = rect; rotPivot.2 = pivot; rotFrames.2 = frames; rotInfo.2 = info
        case 3: rotRect.3 = rect; rotPivot.3 = pivot; rotFrames.3 = frames; rotInfo.3 = info
        default: break
        }
    }
}

struct QuadUniforms {
    typealias F4 = SIMD4<Float>
    var dst: F4 = .zero, target: F4 = .zero, src: F4 = .zero, tint: F4 = .zero
}

/// GPU timing of the last completed frame (command buffer GPU start to end).
public struct RenderTiming: Sendable {
    public var gpuMilliseconds: Double
}

/// HD-pack GPU resources (created when a pack is active).
final class HDResources {
    let pack: HDPack
    let S: Int
    let vram: MTLTexture
    let frame: MTLTexture
    let strip: MTLTexture
    let playfield: MTLTexture?
    var sprites: [String: MTLTexture] = [:]
    var nativeSprites: [String: MTLTexture] = [:]
    let fontAtlas: MTLTexture?
    let flipAtlas: MTLTexture?
    let ball: MTLTexture?
    var vramValid = false
    var stripKey: (Int, [UInt8])?
    /// Rotated flippers: built in the background the first time they are needed (nil until then,
    /// or when no flipper's split is usable).
    var rotation: FlipperRotationSet?
    var rotationJob: FlipperRotationJob?

    func flipperRotation(composer c: ClassicComposer, basePalette: Palette, device: MTLDevice) -> FlipperRotationSet? {
        if rotation != nil { return rotation }
        if rotationJob == nil {
            rotationJob = FlipperRotationJob(frames: c.flipperFrames, flippers: c.flipperData, sprites: pack.sprites, scale: S,
                                             basePalette: basePalette)
        }
        if let done = rotationJob?.finished {
            rotation = done.flatMap { FlipperRotationSet(device: device, data: $0) }
        }
        return rotation
    }
    init(pack: HDPack, S: Int, vram: MTLTexture, frame: MTLTexture, strip: MTLTexture, playfield: MTLTexture?,
         fontAtlas: MTLTexture?, flipAtlas: MTLTexture?, ball: MTLTexture?) {
        self.pack = pack; self.S = S; self.vram = vram; self.frame = frame; self.strip = strip; self.playfield = playfield
        self.fontAtlas = fontAtlas; self.flipAtlas = flipAtlas; self.ball = ball
    }
}

/// The enhanced passes (docs/enhanced/rendering.md): created lazily by `PinballRenderer` the
/// first time a non-classic frame is encoded.
final class EnhancedPipeline {
    let device: MTLDevice
    let library: MTLLibrary
    let sceneNative: MTLRenderPipelineState
    let sceneHD: MTLRenderPipelineState
    let stripPSO: MTLRenderPipelineState
    let quadRGBA: MTLRenderPipelineState
    let quadIndexed: MTLRenderPipelineState
    let quadMask: MTLRenderPipelineState
    let quadDisc: MTLRenderPipelineState
    let prepass: MTLComputePipelineState
    let emissive: MTLComputePipelineState
    let blur: MTLComputePipelineState
    let flipperUpscale: MTLComputePipelineState
    private var presentPSOs: [PresentKey: MTLRenderPipelineState] = [:]

    /// Function-constant specialisation of present_enhanced (Pinball.metal FC_*).
    struct PresentKey: Hashable {
        var format: UInt
        var filter: Int32
        var winHD, strip, stripHD, light: Bool
        var ball: Int32
        var ballHD, occlusion, dots, round, curve: Bool
        /// Flippers rotated at output resolution (no HD pack).
        var rotate = false
    }

    let stripRGB: MTLTexture
    let frameBlend: MTLTexture
    let stripBlend: MTLTexture
    let glowA: MTLTexture
    let glowB: MTLTexture
    let lampMask: MTLTexture
    let occlusion: MTLTexture
    let basePaletteTex: MTLTexture
    let stripBgTex: MTLTexture
    let basePlayfieldTex: MTLTexture
    private(set) var ballTex: MTLTexture
    private(set) var ballBlend: MTLTexture
    private var flipAtlas: MTLTexture
    /// Per flipper index: rect and atlas row of each frame.
    private var flipLayout: [Int: (rect: SIMD4<Float>, rows: [Int])] = [:]
    let dummyF: MTLTexture
    let dummyU: MTLTexture
    let dummyU16: MTLTexture

    private let basePlayfield: [UInt8]
    private var collision: [UInt8]?
    private var occludes: [[Bool]]?
    /// Per ball slot: the last inferred occlusion level.
    private var occlusionLevels = [Int](repeating: 0, count: 5)
    private var lighting: LampLighting?
    private var lightingComposer: ObjectIdentifier?
    private var uploadedBasePalette: Palette?
    private var ballKey: [UInt8] = []
    private var flipperComposer: ObjectIdentifier?
    private var occlusionComposer: ObjectIdentifier?

    // Interpolation history (per simulation frame).
    private var lastSimFrame: Int?
    private var camPrev: Double = 0, camCur: Double = 0
    private var flipPrev: [Int: Int] = [:], flipCur: [Int: Int] = [:]
    private var anglePrev: [Int: Double] = [:], angleCur: [Int: Double] = [:]

    /// Rotated flippers without an HD pack: the resources in use and the build in progress.
    private(set) var nativeRotation: NativeFlipperRotation?
    private(set) var nativeRotationJob: NativeFlipperRotationJob?

    var hd: HDResources?
    private var hdFailed = false
    private(set) var hdWarnings: [String] = []

    static let frameRows = TableGeometry.height + 1

    init(device: MTLDevice, library: MTLLibrary, assets: TableAssets) throws {
        self.device = device
        self.library = library
        self.basePlayfield = assets.indices
        func render(_ frag: String, vertex: String = "fullscreen_vertex", blend: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            guard let f = library.makeFunction(name: frag) else { throw RenderError.shaderCompile("missing function \(frag)") }
            d.fragmentFunction = f
            d.colorAttachments[0].pixelFormat = .rgba8Unorm
            if blend {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .one; a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do { return try device.makeRenderPipelineState(descriptor: d) } catch { throw RenderError.shaderCompile("\(frag): \(error)") }
        }
        func compute(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: name) else { throw RenderError.shaderCompile("missing function \(name)") }
            do { return try device.makeComputePipelineState(function: f) } catch { throw RenderError.shaderCompile("\(name): \(error)") }
        }
        sceneNative = try render("scene_enhanced")
        sceneHD = try render("scene_hd")
        stripPSO = try render("strip_rgb")
        quadRGBA = try render("quad_rgba", vertex: "quad_vertex")
        quadIndexed = try render("quad_indexed", vertex: "quad_vertex")
        quadMask = try render("quad_mask", vertex: "quad_vertex", blend: true)
        quadDisc = try render("quad_disc", vertex: "quad_vertex", blend: true)
        prepass = try compute("xbrz_prepass")
        emissive = try compute("glow_emissive")
        blur = try compute("glow_blur")
        flipperUpscale = try compute("flipper_upscale")

        let w = TableGeometry.width, h = TableGeometry.height
        func tex(_ f: MTLPixelFormat, _ tw: Int, _ th: Int, _ usage: MTLTextureUsage, shared: Bool = false, _ what: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: max(1, tw), height: max(1, th), mipmapped: false)
            d.usage = usage
            d.storageMode = shared ? .shared : .private
            guard let t = device.makeTexture(descriptor: d) else { throw RenderError.resourceCreation(what) }
            return t
        }
        stripRGB = try tex(.rgba8Unorm, w, ClassicComposer.stripBufferRows, [.renderTarget, .shaderRead], "strip rgb")
        frameBlend = try tex(.r8Uint, w + 2, Self.frameRows + 2, [.shaderRead, .shaderWrite], "frame blend")
        stripBlend = try tex(.r8Uint, w + 2, ClassicComposer.stripBufferRows + 2, [.shaderRead, .shaderWrite], "strip blend")
        glowA = try tex(.rgba16Float, w, Self.frameRows, [.shaderRead, .shaderWrite], "glow A")
        glowB = try tex(.rgba16Float, w, Self.frameRows, [.shaderRead, .shaderWrite], "glow B")
        lampMask = try tex(.r8Unorm, w, h, [.shaderRead], shared: true, "lamp mask")
        occlusion = try tex(.r8Uint, w, h, [.shaderRead], shared: true, "occlusion")
        stripBgTex = try tex(.r8Uint, w, ClassicComposer.stripBufferRows, [.shaderRead], shared: true, "strip background")
        basePlayfieldTex = try tex(.r8Uint, w, h, [.shaderRead], shared: true, "base playfield")
        ballTex = try tex(.rgba8Unorm, 17, 16, [.shaderRead], shared: true, "ball")
        ballBlend = try tex(.r8Uint, 19, 18, [.shaderRead, .shaderWrite], "ball blend")
        flipAtlas = try tex(.r8Uint, 1, 1, [.shaderRead], shared: true, "flipper atlas")
        dummyF = try tex(.rgba8Unorm, 1, 1, [.shaderRead], shared: true, "dummy")
        dummyU = try tex(.r8Uint, 1, 1, [.shaderRead], shared: true, "dummy")
        dummyU16 = try tex(.r16Uint, 1, 1, [.shaderRead], shared: true, "dummy")
        let pd = MTLTextureDescriptor()
        pd.textureType = .type1D; pd.pixelFormat = .rgba8Unorm; pd.width = Palette.count
        pd.usage = .shaderRead; pd.storageMode = .shared
        guard let bp = device.makeTexture(descriptor: pd) else { throw RenderError.resourceCreation("base palette") }
        basePaletteTex = bp
        assets.indices.withUnsafeBytes { basePlayfieldTex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w) }
        let zero = [UInt8](repeating: 0, count: w * h)
        zero.withUnsafeBytes {
            lampMask.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w)
            occlusion.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w)
        }
        // Occlusion needs the static collision map (the ball's occluders are static art).
        let npy = assets.directory.appendingPathComponent("collision_idx.npy")
        if let a = try? NPYReader.read(contentsOf: npy), a.rows == h, a.columns == w { collision = a.data }
    }

    // MARK: - per-frame state

    private func syncBasePalette(_ p: Palette) {
        guard uploadedBasePalette != p else { return }
        uploadedBasePalette = p
        let bytes = p.rgba8
        bytes.withUnsafeBytes { basePaletteTex.replace(region: MTLRegionMake1D(0, Palette.count), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: Palette.count * 4) }
    }

    private func syncFlipperAtlas(_ c: ClassicComposer?) throws {
        guard let c, flipperComposer != ObjectIdentifier(c) else { return }
        flipperComposer = ObjectIdentifier(c)
        flipLayout = [:]
        var width = 1, height = 0
        for f in c.flipperFrames { if let f { width = max(width, f.map(\.w).max() ?? 1); height += f.reduce(0) { $0 + $1.h } } }
        guard height > 0 else { return }
        var bytes = [UInt8](repeating: 0, count: width * height)
        var row = 0
        for (i, f) in c.flipperFrames.enumerated() {
            guard let f, let first = f.first else { continue }
            var rows: [Int] = []
            for s in f {
                for y in 0..<s.h { for x in 0..<s.w { bytes[(row + y) * width + x] = s.pixels[y * s.w + x] } }
                rows.append(row); row += s.h
            }
            flipLayout[i] = (SIMD4(Float(first.x), Float(first.y), Float(first.w), Float(first.h)), rows)
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead; d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { throw RenderError.resourceCreation("flipper atlas") }
        bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width) }
        flipAtlas = t
    }

    private func syncOcclusion(_ c: ClassicComposer?) {
        guard let c, occlusionComposer != ObjectIdentifier(c) else { return }
        occlusionComposer = ObjectIdentifier(c)
        occludes = c.occludes
        guard let occ = occludes, let col = collision else { return }
        var bytes = [UInt8](repeating: 0, count: col.count)
        for i in col.indices {
            var v: UInt8 = 0
            for (l, lut) in occ.prefix(2).enumerated() where lut[Int(col[i])] { v |= UInt8(1 << l) }
            bytes[i] = v
        }
        let w = TableGeometry.width
        bytes.withUnsafeBytes { occlusion.replace(region: MTLRegionMake2D(0, 0, w, TableGeometry.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w) }
    }

    /// The ball level whose occlusion reproduces the engine's composited pixels at the ball's
    /// integer position (ties keep the slot's previous level).
    private func inferLevel(composited: [UInt8], raw: [UInt8], at p: SIMD2<Int>, w: Int, h: Int, slot: Int) -> Int {
        let s = max(0, min(occlusionLevels.count - 1, slot))
        guard let occ = occludes, let col = collision, occ.count >= 2 else { return occlusionLevels[s] }
        var miss = [0, 0]
        for l in 0..<2 {
            for r in 0..<h {
                let ty = p.y + r
                for c in 0..<w {
                    let i = r * w + c
                    var predicted = raw[i]
                    let tx = p.x + c
                    if ty >= 0, ty < TableGeometry.height, tx >= 0, tx < TableGeometry.width {
                        let v = col[ty * TableGeometry.width + tx]
                        if occ[l][Int(v)] { predicted = v }
                    }
                    if predicted != composited[i] { miss[l] += 1 }
                }
            }
        }
        if miss[0] != miss[1] { occlusionLevels[s] = miss[0] < miss[1] ? 0 : 1 }
        return occlusionLevels[s]
    }

    private func syncBallTexture(raw: [UInt8], w: Int, h: Int, palette: Palette) throws {
        var key = raw
        for i in Set(raw) { let c = palette[Int(i)]; key += [c.r, c.g, c.b] }
        key += [UInt8(w), UInt8(h)]
        guard key != ballKey else { return }
        ballKey = key
        let tw = w + 2, th = h + 2
        if ballTex.width != tw || ballTex.height != th {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: tw, height: th, mipmapped: false)
            d.usage = .shaderRead; d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d) else { throw RenderError.resourceCreation("ball") }
            ballTex = t
            let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: tw + 2, height: th + 2, mipmapped: false)
            bd.usage = [.shaderRead, .shaderWrite]; bd.storageMode = .private
            guard let b = device.makeTexture(descriptor: bd) else { throw RenderError.resourceCreation("ball blend") }
            ballBlend = b
        }
        var px = [UInt8](repeating: 0, count: tw * th * 4)
        for r in 0..<h {
            for c in 0..<w {
                let v = raw[r * w + c]
                guard v != 0 else { continue }
                let e = palette[Int(v)], o = ((r + 1) * tw + c + 1) * 4
                px[o] = e.r; px[o + 1] = e.g; px[o + 2] = e.b; px[o + 3] = 255
            }
        }
        px.withUnsafeBytes { ballTex.replace(region: MTLRegionMake2D(0, 0, tw, th), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: tw * 4) }
    }

    // MARK: - HD pack

    func activateHD(pack: HDPack, composer: ClassicComposer?, basePalette: Palette) throws {
        let S = pack.scale
        let w = TableGeometry.width, h = TableGeometry.height
        func tex(_ f: MTLPixelFormat, _ tw: Int, _ th: Int, _ usage: MTLTextureUsage, shared: Bool) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: max(1, tw), height: max(1, th), mipmapped: false)
            d.usage = usage; d.storageMode = shared ? .shared : .private
            guard let t = device.makeTexture(descriptor: d) else { throw RenderError.resourceCreation("HD texture \(tw)x\(th)") }
            return t
        }
        func upload(_ img: RGBAImage) throws -> MTLTexture {
            let t = try tex(.rgba8Unorm, img.width, img.height, [.shaderRead], shared: true)
            img.pixels.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: img.width * 4) }
            return t
        }
        let vram = try tex(.rgba8Unorm, w * S, h * S, [.renderTarget, .shaderRead], shared: false)
        let frame = try tex(.rgba8Unorm, w * S, Self.frameRows * S, [.renderTarget, .shaderRead], shared: false)
        let strip = try tex(.rgba8Unorm, w * S, ClassicComposer.stripBufferRows * S, [.renderTarget, .shaderRead], shared: false)
        let playfield = try pack.playfield.map(upload)
        var warnings = pack.warnings
        if pack.playfield == nil { warnings.append("no usable HD playfield: original playfield shown (nearest)") }

        // font8 atlas: pack masks, else the original glyph bits (nearest).
        var fontAtlas: MTLTexture?
        if let g = composer?.graphics, !g.font8.isEmpty {
            let cell = 8 * S, n = g.font8.count
            var bytes = [UInt8](repeating: 0, count: cell * cell * n)
            var missing = 0
            for gi in 0..<n {
                if let m = pack.font8[gi], m.count == cell * cell {
                    for i in 0..<m.count { bytes[gi * cell * cell + i] = m[i] }
                } else {
                    missing += 1
                    let bits = g.font8[gi]
                    for y in 0..<cell { for x in 0..<cell where (y / S) < bits.count && bits[y / S] & (0x80 >> (x / S)) != 0 { bytes[gi * cell * cell + y * cell + x] = 255 } }
                }
            }
            if missing > 0 && !pack.font8.isEmpty { warnings.append("font8: \(missing) glyphs missing from the pack (original bits used)") }
            let t = try tex(.r8Unorm, cell, cell * n, [.shaderRead], shared: true)
            bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, cell, cell * n), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: cell) }
            fontAtlas = t
        }

        // HD flipper atlas, same row layout as the native one times S.
        var flipHD: MTLTexture?
        if let c = composer, c.drawsFlippers {
            var width = 1, height = 0
            for f in c.flipperFrames { if let f { width = max(width, f.map(\.w).max() ?? 1); height += f.reduce(0) { $0 + $1.h } } }
            let W = width * S, H = height * S
            var bytes = [UInt8](repeating: 0, count: W * H * 4)
            var row = 0
            var missing = 0
            for f in c.flipperFrames {
                guard let f else { continue }
                for s in f {
                    if let img = pack.sprites[s.name] {
                        for y in 0..<img.height {
                            let src = y * img.width * 4, dst = ((row * S + y) * W) * 4
                            bytes.replaceSubrange(dst..<(dst + img.width * 4), with: img.pixels[src..<(src + img.width * 4)])
                        }
                    } else {
                        missing += 1
                        for y in 0..<(s.h * S) {
                            for x in 0..<(s.w * S) {
                                let e = basePalette[Int(s.pixels[(y / S) * s.w + x / S])], o = ((row * S + y) * W + x) * 4
                                bytes[o] = e.r; bytes[o + 1] = e.g; bytes[o + 2] = e.b; bytes[o + 3] = 255
                            }
                        }
                    }
                    row += s.h
                }
            }
            if missing > 0 { warnings.append("\(missing) flipper frames missing from the pack (original art used)") }
            let t = try tex(.rgba8Unorm, W, H, [.shaderRead], shared: true)
            bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: W * 4) }
            flipHD = t
        }

        // Ball: premultiplied, one table pixel (S HD pixels) of transparent padding.
        var ballT: MTLTexture?
        if let b = pack.ball {
            let tw = b.width + 2 * S, th = b.height + 2 * S
            var px = [UInt8](repeating: 0, count: tw * th * 4)
            for y in 0..<b.height {
                for x in 0..<b.width {
                    let s = (y * b.width + x) * 4, d = ((y + S) * tw + x + S) * 4
                    let a = UInt16(b.pixels[s + 3])
                    for k in 0..<3 { px[d + k] = UInt8((UInt16(b.pixels[s + k]) * a + 127) / 255) }
                    px[d + 3] = UInt8(a)
                }
            }
            let t = try tex(.rgba8Unorm, tw, th, [.shaderRead], shared: true)
            px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, tw, th), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: tw * 4) }
            ballT = t
        } else {
            warnings.append("no HD ball in the pack: original ball shown")
        }

        let res = HDResources(pack: pack, S: S, vram: vram, frame: frame, strip: strip, playfield: playfield,
                              fontAtlas: fontAtlas, flipAtlas: flipHD, ball: ballT)
        for (name, img) in pack.sprites { res.sprites[name] = try upload(img) }
        hd = res
        hdWarnings = warnings
        composer?.recordsVRAMOps = true
    }

    func deactivateHD(composer: ClassicComposer?) {
        hd = nil
        composer?.recordsVRAMOps = false
    }

    private func nativeSprite(_ s: IndexedSprite, hd: HDResources) -> MTLTexture? {
        if let t = hd.nativeSprites[s.name] { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: s.w, height: s.h, mipmapped: false)
        d.usage = .shaderRead; d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        s.pixels.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, s.w, s.h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: s.w) }
        hd.nativeSprites[s.name] = t
        return t
    }

    /// Draws a rect of `tex` (HD RGBA at scale 1, or native indexed at 1/S) into `target`.
    private func drawQuad(_ enc: MTLRenderCommandEncoder, target: MTLTexture, dst: SIMD4<Float>, clip: SIMD4<Int>? = nil,
                          srcScale: Float, tex: MTLTexture, indexed: Bool, palette: MTLTexture) {
        let x0 = max(0, Int(dst.x)), y0 = max(0, Int(dst.y))
        var x1 = min(target.width, Int(dst.z)), y1 = min(target.height, Int(dst.w))
        var cx0 = x0, cy0 = y0
        if let c = clip { cx0 = max(x0, c.x); cy0 = max(y0, c.y); x1 = min(x1, c.z); y1 = min(y1, c.w) }
        guard x1 > cx0, y1 > cy0 else { return }
        enc.setScissorRect(MTLScissorRect(x: cx0, y: cy0, width: x1 - cx0, height: y1 - cy0))
        var u = QuadUniforms(dst: dst, target: SIMD4(Float(target.width), Float(target.height), 0, 0),
                             src: SIMD4(0, 0, srcScale, srcScale), tint: .zero)
        enc.setRenderPipelineState(indexed ? quadIndexed : quadRGBA)
        enc.setVertexBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentTexture(palette, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// Replays VRAM blits into the HD VRAM (a reset redraws the HD playfield).
    private func replayHD(_ hd: HDResources, composer: ClassicComposer?, cb: MTLCommandBuffer) throws {
        var ops: [ClassicComposer.VRAMOp]
        if !hd.vramValid {
            ops = [.reset] + (composer?.liveVRAMOps ?? [])
            _ = composer?.takePendingVRAMOps()
            hd.vramValid = true
        } else {
            ops = composer?.takePendingVRAMOps() ?? []
        }
        guard !ops.isEmpty else { return }
        let S = hd.S
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = hd.vram
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.resourceCreation("HD VRAM encoder") }
        enc.label = "HD VRAM replay (\(ops.count) ops)"
        let full = SIMD4<Float>(0, 0, Float(hd.vram.width), Float(hd.vram.height))
        for op in ops {
            switch op {
            case .reset:
                if let pf = hd.playfield {
                    drawQuad(enc, target: hd.vram, dst: full, srcScale: 1, tex: pf, indexed: false, palette: basePaletteTex)
                } else {
                    drawQuad(enc, target: hd.vram, dst: full, srcScale: 1 / Float(S), tex: basePlayfieldTex, indexed: true, palette: basePaletteTex)
                }
            case let .blit(name, x, y, w, h, clipBottom):
                let dst = SIMD4(Float(x * S), Float(y * S), Float((x + w) * S), Float((y + h) * S))
                let clip = SIMD4(0, 0, TableGeometry.width * S, clipBottom * S)
                if let t = hd.sprites[name] {
                    drawQuad(enc, target: hd.vram, dst: dst, clip: clip, srcScale: 1, tex: t, indexed: false, palette: basePaletteTex)
                } else if let s = composer?.graphics.byName[name] ?? composer?.extraSprites[name], let t = nativeSprite(s, hd: hd) {
                    drawQuad(enc, target: hd.vram, dst: dst, clip: clip, srcScale: 1 / Float(S), tex: t, indexed: true, palette: basePaletteTex)
                }
            }
        }
        enc.endEncoding()
    }

    /// Rebuilds the HD strip when the native strip or the palette changed.
    private func renderHDStrip(_ hd: HDResources, composer c: ClassicComposer, palette: Palette, paletteTex: MTLTexture, cb: MTLCommandBuffer) throws {
        let key = (c.stripGeneration, palette.rgba8)
        if let k = hd.stripKey, k.0 == key.0, k.1 == key.1 { return }
        hd.stripKey = key
        let w = TableGeometry.width, rows = ClassicComposer.stripBufferRows, S = hd.S
        c.stripBackground.withUnsafeBytes { stripBgTex.replace(region: MTLRegionMake2D(0, 0, w, rows), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w) }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = hd.strip
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.resourceCreation("HD strip encoder") }
        enc.label = "HD strip"
        drawQuad(enc, target: hd.strip, dst: SIMD4(0, 0, Float(hd.strip.width), Float(hd.strip.height)), srcScale: 1 / Float(S),
                 tex: stripBgTex, indexed: true, palette: paletteTex)
        let fullClip = SIMD4(0, 0, hd.strip.width, hd.strip.height)
        for op in c.stripOps {
            switch op {
            case let .sprite(name, x, y):
                guard let s = c.graphics.byName[name] else { continue }
                let dst = SIMD4(Float(x * S), Float(y * S), Float((x + s.w) * S), Float((y + s.h) * S))
                if let t = hd.sprites[name] {
                    drawQuad(enc, target: hd.strip, dst: dst, clip: fullClip, srcScale: 1, tex: t, indexed: false, palette: paletteTex)
                } else if let t = nativeSprite(s, hd: hd) {
                    drawQuad(enc, target: hd.strip, dst: dst, clip: fullClip, srcScale: 1 / Float(S), tex: t, indexed: true, palette: paletteTex)
                }
            case let .glyph(g, x, y, colour):
                guard let atlas = hd.fontAtlas else { continue }
                let cell = 8 * S
                let dst = SIMD4(Float(x * S), Float(y * S), Float(x * S + cell), Float(y * S + cell))
                let clip = SIMD4(x * S, y * S, x * S + cell, (y + 7) * S)   // the strip font draws 7 rows
                let x0 = max(0, clip.x), y0 = max(0, clip.y), x1 = min(hd.strip.width, clip.z), y1 = min(hd.strip.height, clip.w)
                guard x1 > x0, y1 > y0 else { continue }
                enc.setScissorRect(MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
                let e = palette[Int(colour)]
                var u = QuadUniforms(dst: dst, target: SIMD4(Float(hd.strip.width), Float(hd.strip.height), 0, 0),
                                     src: SIMD4(0, Float(g * cell), 1, 1),
                                     tint: SIMD4(Float(e.r) / 255, Float(e.g) / 255, Float(e.b) / 255, 0))
                enc.setRenderPipelineState(quadMask)
                enc.setVertexBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                enc.setFragmentTexture(atlas, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            case let .dot(x, y, colour):
                let e = palette[Int(colour)]
                let cx = (Float(x) + 0.5) * Float(S), cy = (Float(y) + 0.5) * Float(S), r = 0.62 * Float(S)
                let dst = SIMD4(cx - r - 1, cy - r - 1, cx + r + 1, cy + r + 1)
                let x0 = max(0, Int(dst.x)), y0 = max(0, Int(dst.y)), x1 = min(hd.strip.width, Int(dst.z.rounded(.up))), y1 = min(hd.strip.height, Int(dst.w.rounded(.up)))
                guard x1 > x0, y1 > y0 else { continue }
                enc.setScissorRect(MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
                // The dot pixel itself: back to the panel colour first (quad over the one native pixel).
                drawQuad(enc, target: hd.strip, dst: SIMD4(Float(x * S), Float(y * S), Float((x + 1) * S), Float((y + 1) * S)), clip: fullClip,
                         srcScale: 1 / Float(S), tex: stripBgTex, indexed: true, palette: paletteTex)
                enc.setScissorRect(MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
                var u = QuadUniforms(dst: dst, target: SIMD4(Float(hd.strip.width), Float(hd.strip.height), 0, 0), src: .zero,
                                     tint: SIMD4(Float(e.r) / 255, Float(e.g) / 255, Float(e.b) / 255, r))
                enc.setRenderPipelineState(quadDisc)
                enc.setVertexBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }
        enc.endEncoding()
    }

    // MARK: - encode

    /// Flippers drawn rotated at output resolution in the last frame (no HD pack).
    private(set) var lastOutputRotations = 0
    private var nativeRotationUnusable: NativeFlipperRotationKey?

    /// Rotated flippers without an HD pack for this frame's filter and output scale: nil until the
    /// background build is done (or when no flipper's split is usable). While a rebuild for another
    /// filter or scale runs, the previous resources of the same table are kept.
    private func nativeFlipperRotation(composer c: ClassicComposer, filter: UpscaleFilter, outputScale: Double,
                                       basePalette: Palette) -> NativeFlipperRotation? {
        let key = NativeFlipperRotationKey(composer: ObjectIdentifier(c), filter: filter,
                                           scale: NativeFlipperRotation.scale(forOutputScale: outputScale))
        if nativeRotation?.key == key { return nativeRotation }
        if nativeRotationUnusable == key { return nil }
        if nativeRotationJob?.key != key {
            nativeRotationJob = NativeFlipperRotationJob(key: key, device: device, upscale: flipperUpscale, prepass: prepass,
                                                         frames: c.flipperFrames, flippers: c.flipperData, playfield: basePlayfield,
                                                         basePalette: basePalette)
        }
        if let done = nativeRotationJob?.finished {
            if let d = done, let res = NativeFlipperRotation(device: device, key: key, data: d) {
                nativeRotation = res
                return res
            }
            nativeRotationUnusable = key
            return nil
        }
        if let r = nativeRotation, r.key.composer == key.composer { return r }
        return nil
    }

    private func presentPipeline(_ k: PresentKey) throws -> MTLRenderPipelineState {
        if let p = presentPSOs[k] { return p }
        let cv = MTLFunctionConstantValues()
        var filter = k.filter, ball = k.ball
        var flags = [k.winHD, k.strip, k.stripHD, k.light]
        cv.setConstantValue(&filter, type: .int, index: 0)
        for i in 0..<4 { cv.setConstantValue(&flags[i], type: .bool, index: 1 + i) }
        cv.setConstantValue(&ball, type: .int, index: 5)
        var more = [k.ballHD, k.occlusion, k.dots, k.round, k.curve, k.rotate]
        for i in 0..<6 { cv.setConstantValue(&more[i], type: .bool, index: 6 + i) }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        do { d.fragmentFunction = try library.makeFunction(name: "present_enhanced", constantValues: cv) } catch {
            throw RenderError.shaderCompile("present_enhanced: \(error)")
        }
        d.colorAttachments[0].pixelFormat = MTLPixelFormat(rawValue: k.format) ?? .bgra8Unorm
        let p: MTLRenderPipelineState
        do { p = try device.makeRenderPipelineState(descriptor: d) } catch { throw RenderError.shaderCompile("present_enhanced: \(error)") }
        presentPSOs[k] = p
        return p
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, width: Int, height: Int) {
        enc.setComputePipelineState(pso)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
    }

    struct FrameInputs {
        var scene: SceneState
        var settings: RenderSettings
        var interpolation: MotionInterpolation?
        var aspect: PixelAspect
        var composer: ClassicComposer?
        var palette: Palette
        var basePalette: Palette
        var stripRows: Int
        var lampStates: [UInt8]
        var framesAdvanced: Int
    }

    /// Strip rows shown for a scene in the enhanced path.
    static func stripRows(_ scene: SceneState, settings: RenderSettings, composer: ClassicComposer?, stripRows: Int) -> Int {
        guard composer != nil else { return 0 }
        if scene.viewHeight >= Double(TableGeometry.height) && !settings.stripInFullTable { return 0 }
        return max(0, min(stripRows, ClassicComposer.stripBufferRows))
    }

    func encode(_ f: FrameInputs, renderer r: PinballRenderer, into cb: MTLCommandBuffer, target: MTLTexture) throws {
        let st = f.settings
        let c = f.composer
        let W = TableGeometry.width
        try syncFlipperAtlas(c)
        syncOcclusion(c)
        syncBasePalette(f.basePalette)

        // HD pack on/off.
        if st.useHDPack, hd == nil, !hdFailed {
            let dataRoot = r.assetsDirectory.deletingLastPathComponent().deletingLastPathComponent()
            if let dir = HDPack.locate(table: r.tableNumber, dataRoot: dataRoot) {
                do {
                    let pack = try HDPack.load(from: dir, table: r.tableNumber, playfield: basePlayfield, graphics: c?.graphics,
                                               ballSize: c?.ballSize ?? (15, 14))
                    try activateHD(pack: pack, composer: c, basePalette: f.basePalette)
                } catch {
                    hdFailed = true
                    hdWarnings = ["\(error)"]
                }
            } else {
                hdFailed = true
                hdWarnings = ["no HD pack for table \(r.tableNumber) (make one in Settings > Library, with --make-hd-pack \(r.tableNumber), "
                              + "or with tools/hdpack/make_pack.py)"]
            }
        } else if !st.useHDPack {
            if hd != nil { deactivateHD(composer: c) }
            hdFailed = false   // look again the next time it is switched on (a pack may have been made since)
        }
        let hd = st.useHDPack ? self.hd : nil
        let S = hd?.S ?? 1

        // Interpolation history (per simulation frame).
        let ip = st.interpolate ? f.interpolation : nil
        let alpha = Float(min(max(ip?.alpha ?? 1, 0), 1))
        if let ip, ip.frame != lastSimFrame {
            let first = lastSimFrame == nil
            lastSimFrame = ip.frame
            camPrev = first ? f.scene.viewTop : camCur
            camCur = f.scene.viewTop
            flipPrev = first ? [:] : flipCur
            flipCur = Dictionary(f.scene.flippers.map { ($0.index, $0.frame) }, uniquingKeysWith: { a, _ in a })
            anglePrev = first ? [:] : angleCur
            angleCur = Dictionary(f.scene.flippers.compactMap { fl in fl.angle.map { (fl.index, $0) } }, uniquingKeysWith: { a, _ in a })
        }
        var viewTop = f.scene.viewTop
        if let ip, ip.interpolateCamera, abs(camCur - camPrev) < 60, abs(camCur - f.scene.viewTop) < 0.5 {
            viewTop = camPrev + (camCur - camPrev) * Double(alpha)
        }

        let visibleRows = f.scene.viewHeight.rounded()
        let tableH = Double(TableGeometry.height)
        let stripShown = Self.stripRows(f.scene, settings: st, composer: c, stripRows: f.stripRows)
        let scaling = st.resolvedScaling(hdActive: hd != nil)
        let fit = EnhancedFit.fit(sourceWidth: W, sourceHeight: Int(visibleRows) + stripShown,
                                  outputWidth: target.width, outputHeight: target.height, aspect: f.aspect, scaling: scaling)
        let top = min(max(viewTop, 0), max(0, tableH - visibleRows))
        var origin = top.rounded(.down)
        var frac = top - origin
        if fit.isInteger {
            frac = (frac * fit.scaleY).rounded() / fit.scaleY
            if frac >= 1 { origin += 1; frac = 0 }
        }
        let rendered = min(Int(visibleRows) + 1, Self.frameRows)

        // Scene pass (window rows without ball / dots).
        var su = EnhSceneUniforms()
        su.view = SIMD4(Float(origin), Float(rendered), Float(S), alpha)
        // Flippers rotated at output resolution (no HD pack): per scene slot, the present uniforms.
        var nrot: NativeFlipperRotation?
        var outputRotations: [(slot: Int, rect: SIMD4<Float>, pivot: SIMD4<Float>, frames: SIMD4<Float>, info: SIMD4<Float>)] = []
        if ip != nil {
            // HD pack: rotate (when the `FlipperArt` split is usable) between the last two frames'
            // angles. Without a pack and with a smoothing filter: rotate at output resolution with
            // the frames upscaled by that filter. Otherwise (nearest, EP8's flippers, while the
            // resources are built) cross-fade the game's frames.
            var rot: FlipperRotationSet?
            if let hd, st.rotateFlippers, let c { rot = hd.flipperRotation(composer: c, basePalette: f.basePalette, device: device) }
            if hd == nil, st.rotateFlippers, st.filter != .nearest, let c, c.drawsFlippers {
                nrot = nativeFlipperRotation(composer: c, filter: st.filter, outputScale: min(fit.scaleX, fit.scaleY), basePalette: f.basePalette)
            }
            for (slot, fl) in f.scene.flippers.prefix(4).enumerated() {
                if let nrot, let e = nrot.entries[fl.index], let bgRow = nrot.backgroundRows[fl.index], let cur = angleCur[fl.index] {
                    let prev = anglePrev[fl.index].flatMap { abs($0 - cur) <= 3.5 ? $0 : nil } ?? cur
                    let art = e.art
                    let p = art.pose(alpha: prev + (cur - prev) * Double(alpha))
                    let rect = SIMD4(Float(art.x), Float(art.y), Float(art.w), Float(art.h))
                    let pivot = SIMD4(Float(art.pivot.x), Float(art.pivot.y), Float(e.nativeRow), Float(art.frameCount))
                    su.setRotation(slot, rect: rect, pivot: pivot, frames: .zero, info: SIMD4(1, 0, Float(bgRow), 0))
                    outputRotations.append((slot, rect, pivot,
                                            SIMD4(Float(e.spriteRows[p.k0]), Float(p.r0), Float(e.spriteRows[p.k1]), Float(p.r1)),
                                            SIMD4(1, Float(p.weight), Float(nrot.scale), Float(FlipperRotationData.pad))))
                    continue
                }
                if let rot, let e = rot.entries[fl.index], let cur = angleCur[fl.index] {
                    let prev = anglePrev[fl.index].flatMap { abs($0 - cur) <= 3.5 ? $0 : nil } ?? cur
                    let art = e.art
                    let p = art.pose(alpha: prev + (cur - prev) * Double(alpha))
                    su.setRotation(slot, rect: SIMD4(Float(art.x), Float(art.y), Float(art.w), Float(art.h)),
                                   pivot: SIMD4(Float(art.pivot.x), Float(art.pivot.y), Float(e.nativeRow), Float(art.frameCount)),
                                   frames: SIMD4(Float(e.spriteRows[p.k0]), Float(p.r0), Float(e.spriteRows[p.k1]), Float(p.r1)),
                                   info: SIMD4(1, Float(p.weight), Float(e.backgroundRow), Float(FlipperRotationData.pad)))
                    continue
                }
                guard let lay = flipLayout[fl.index], let prev = flipPrev[fl.index], prev != fl.frame,
                      lay.rows.indices.contains(prev), lay.rows.indices.contains(fl.frame) else { continue }
                su.setFlipper(slot, rect: lay.rect, info: SIMD4(1, Float(lay.rows[prev]), Float(lay.rows[fl.frame]), 0))
            }
        }
        if let hd { try replayHD(hd, composer: c, cb: cb) }
        let frameTex = hd?.frame ?? r.frameTexture
        do {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = frameTex
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.resourceCreation("enhanced scene encoder") }
            enc.label = hd == nil ? "scene (enhanced)" : "scene (HD x\(S))"
            enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(W * S), height: Double(rendered * S), znear: 0, zfar: 1))
            enc.setFragmentBytes(&su, length: MemoryLayout<EnhSceneUniforms>.stride, index: 0)
            if let hd {
                enc.setRenderPipelineState(sceneHD)
                enc.setFragmentTexture(hd.vram, index: 0)
                enc.setFragmentTexture(r.indexTexture, index: 1)
                enc.setFragmentTexture(r.paletteTexture, index: 2)
                enc.setFragmentTexture(basePaletteTex, index: 3)
                enc.setFragmentTexture(flipAtlas, index: 4)
                enc.setFragmentTexture(hd.flipAtlas ?? dummyF, index: 5)
                enc.setFragmentTexture(hd.rotation?.native ?? dummyU16, index: 6)
                enc.setFragmentTexture(hd.rotation?.hd ?? dummyF, index: 7)
            } else {
                enc.setRenderPipelineState(sceneNative)
                enc.setFragmentTexture(r.indexTexture, index: 0)
                enc.setFragmentTexture(r.paletteTexture, index: 1)
                enc.setFragmentTexture(flipAtlas, index: 2)
                enc.setFragmentTexture(nrot?.sprites.native ?? dummyU16, index: 3)
                enc.setFragmentTexture(nrot?.background ?? dummyU, index: 4)
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // Strip layer.
        var stripTex = stripRGB
        var stripScale = 1
        if stripShown > 0, let c {
            if let hd, hd.fontAtlas != nil || !hd.pack.sprites.isEmpty {
                try renderHDStrip(hd, composer: c, palette: f.palette, paletteTex: r.paletteTexture, cb: cb)
                stripTex = hd.strip
                stripScale = hd.S
            } else {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = stripRGB
                pass.colorAttachments[0].loadAction = .dontCare
                pass.colorAttachments[0].storeAction = .store
                guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.resourceCreation("strip encoder") }
                enc.label = "strip rgb"
                enc.setRenderPipelineState(stripPSO)
                enc.setFragmentTexture(r.stripTexture, index: 0)
                enc.setFragmentTexture(r.paletteTexture, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        // Ball layer input: ball 0, then the other balls in play in slot order (multiball). They
        // share the sprite (every slot uses the same 15x14 record); position, interpolation and
        // occlusion level are per ball.
        var ballKind: Float = 0
        var ballSize = SIMD2<Float>(15, 14)
        var ballScale: Float = 1
        var level: Float = -1
        var useHDBall = false
        var drawnBalls: [(pos: SIMD2<Float>, level: Float)] = []
        let balls = (f.scene.ball.map { [$0] } ?? []) + f.scene.extraBalls
        for b in balls.prefix(1 + EnhPresentUniforms.maxExtraBalls) {
            let m = ip?.motion(slot: b.slot)
            var p = b.topLeft
            if let p0 = m?.previous, let p1 = m?.current {
                let d = p1 - p0
                p = (d * d).sum() < 24 * 24 ? p0 + d * Double(alpha) : p1
            }
            if drawnBalls.isEmpty {
                ballSize = SIMD2(Float(b.width), Float(b.height))
                ballKind = b.pixels?.count == b.width * b.height ? 1 : 2
            }
            var lv: Float = -1
            if ballKind == 1, let px = b.pixels, px.count == b.width * b.height {
                let raw = (c?.ballPixels?.count == px.count ? c?.ballPixels : nil) ?? px
                if drawnBalls.isEmpty {
                    try syncBallTexture(raw: raw, w: b.width, h: b.height, palette: f.palette)
                    if let hd, hd.ball != nil { useHDBall = true; ballScale = Float(hd.S) }
                }
                if occludes != nil, collision != nil {
                    let at = m?.integer ?? b.pixelTopLeft ?? SIMD2(Int(b.topLeft.x.rounded()), Int(b.topLeft.y.rounded()))
                    lv = Float(inferLevel(composited: px, raw: raw, at: at, w: b.width, h: b.height, slot: b.slot))
                }
            }
            if drawnBalls.isEmpty { level = lv }
            drawnBalls.append((SIMD2(Float(p.x), Float(p.y)), lv))
        }
        let ballPos = drawnBalls.first?.pos ?? .zero

        // xBRZ corner analysis (native layers only; an HD pack replaces the upscaler).
        let xbrz = st.filter == .xbrz
        if xbrz, let enc = cb.makeComputeCommandEncoder() {
            enc.label = "xBRZ prepass"
            if hd == nil {
                var size = SIMD4<Int32>(Int32(W), Int32(rendered), 0, 0)
                enc.setTexture(r.frameTexture, index: 0); enc.setTexture(frameBlend, index: 1)
                enc.setBytes(&size, length: 16, index: 0)
                dispatch(enc, prepass, width: W + 1, height: rendered + 1)
            }
            if stripShown > 0, stripScale == 1 {
                var size = SIMD4<Int32>(Int32(W), Int32(ClassicComposer.stripBufferRows), 0, 0)
                enc.setTexture(stripRGB, index: 0); enc.setTexture(stripBlend, index: 1)
                enc.setBytes(&size, length: 16, index: 0)
                dispatch(enc, prepass, width: W + 1, height: ClassicComposer.stripBufferRows + 1)
            }
            if ballKind == 1, !useHDBall {
                var size = SIMD4<Int32>(Int32(ballTex.width), Int32(ballTex.height), 0, 0)
                enc.setTexture(ballTex, index: 0); enc.setTexture(ballBlend, index: 1)
                enc.setBytes(&size, length: 16, index: 0)
                dispatch(enc, prepass, width: ballTex.width + 1, height: ballTex.height + 1)
            }
            enc.endEncoding()
        }

        // Lighting: lamp emissive mask -> blur.
        let lit = st.lighting != .off
        if lit {
            if let c {
                if lighting == nil || lightingComposer != ObjectIdentifier(c) {
                    lighting = LampLighting(graphics: c.graphics, playfield: basePlayfield, palette: f.basePalette)
                    lightingComposer = ObjectIdentifier(c)
                }
                lighting!.pulseGain = st.pulseGain
                if lighting!.update(composer: c, lampStates: f.lampStates, framesAdvanced: f.framesAdvanced) {
                    lighting!.mask.withUnsafeBytes {
                        lampMask.replace(region: MTLRegionMake2D(0, 0, W, TableGeometry.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: W)
                    }
                }
            }
            guard let enc = cb.makeComputeCommandEncoder() else { throw RenderError.resourceCreation("glow encoder") }
            enc.label = "glow"
            var eu = SIMD4<Float>(Float(origin), Float(rendered), LampLighting.maskScale, 2.0)
            enc.setTexture(r.indexTexture, index: 0); enc.setTexture(r.paletteTexture, index: 1)
            enc.setTexture(basePaletteTex, index: 2); enc.setTexture(lampMask, index: 3); enc.setTexture(glowA, index: 4)
            enc.setBytes(&eu, length: 16, index: 0)
            dispatch(enc, emissive, width: W, height: rendered)
            var bh = SIMD4<Float>(1, 0, 4.0, 12)
            enc.setTexture(glowA, index: 0); enc.setTexture(glowB, index: 1); enc.setBytes(&bh, length: 16, index: 0)
            dispatch(enc, blur, width: W, height: rendered)
            var bv = SIMD4<Float>(0, 1, 4.0, 12)
            enc.setTexture(glowB, index: 0); enc.setTexture(glowA, index: 1); enc.setBytes(&bv, length: 16, index: 0)
            dispatch(enc, blur, width: W, height: rendered)
            enc.endEncoding()
        }

        // Present.
        let filterIndex: Float
        switch st.filter {
        case .nearest: filterIndex = 0
        case .smooth: filterIndex = 1
        case .xbrz: filterIndex = 2
        case .crt: filterIndex = 3
        }
        var pu = EnhPresentUniforms()
        pu.dst = SIMD4(Float(fit.x), Float(fit.y), Float(fit.scaleX), Float(fit.scaleY))
        pu.src = SIMD4(Float(W), Float(visibleRows), Float(frac), Float(stripShown))
        pu.mode = SIMD4(filterIndex, Float(S), Float(stripScale), st.roundDots && st.filter != .nearest ? 1 : 0)
        let overlayOn = (c?.hasOverlay ?? false) && f.scene.viewHeight < tableH
        pu.frame = SIMD4(Float(rendered), Float(origin), Float(ClassicComposer.overlayRows), overlayOn ? 1 : 0)
        pu.ball = SIMD4(ballPos.x, ballPos.y, ballSize.x, ballSize.y)
        pu.ballInfo = SIMD4(ballKind, ballScale, level, 1)
        pu.light = SIMD4(st.glowGain, st.shadowStrength, st.specularStrength, lit ? 1 : 0)
        pu.crt = SIMD4(st.crtCurvature, st.crtScanlines, st.crtMask, st.filter == .crt ? 1 : 0)
        pu.viewport = SIMD4(Float(fit.width), Float(fit.height), Float(Self.frameRows), 0)
        pu.extra = SIMD4(Float(max(0, drawnBalls.count - 1)), 0, 0, 0)
        for (i, b) in drawnBalls.dropFirst().enumerated() {
            pu.setExtraBall(i, ball: SIMD4(b.pos.x, b.pos.y, ballSize.x, ballSize.y), info: SIMD4(1, 0, max(0, b.level), 0))
        }
        for (i, o) in outputRotations.enumerated() { pu.setRotation(i, rect: o.rect, pivot: o.pivot, frames: o.frames, info: o.info) }
        lastOutputRotations = outputRotations.count

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.resourceCreation("present encoder") }
        enc.label = "present (enhanced \(st.filter.rawValue)\(hd != nil ? ", HD x\(S)" : "")\(lit ? ", lighting" : ""))"
        enc.setViewport(MTLViewport(originX: fit.x, originY: fit.y, width: fit.width, height: fit.height, znear: 0, zfar: 1))
        let sx = max(0, Int(fit.x)), sy = max(0, Int(fit.y))
        enc.setScissorRect(MTLScissorRect(x: sx, y: sy, width: max(1, min(Int(fit.width.rounded(.up)), target.width - sx)),
                                          height: max(1, min(Int(fit.height.rounded(.up)), target.height - sy))))
        let filterConst: Int32 = [UpscaleFilter.nearest: 0, .smooth: 1, .xbrz: 2, .crt: 3][st.filter] ?? 0
        let key = PresentKey(format: target.pixelFormat.rawValue, filter: filterConst, winHD: hd != nil, strip: stripShown > 0,
                             stripHD: stripScale > 1, light: lit, ball: Int32(ballKind), ballHD: useHDBall,
                             occlusion: level >= 0, dots: overlayOn, round: st.roundDots && st.filter != .nearest,
                             curve: st.filter == .crt && st.crtCurvature > 0)
        enc.setRenderPipelineState(try presentPipeline(key))
        enc.setFragmentBytes(&pu, length: MemoryLayout<EnhPresentUniforms>.stride, index: 0)
        enc.setFragmentTexture(frameTex, index: 0)
        enc.setFragmentTexture(xbrz && hd == nil ? frameBlend : dummyU, index: 1)
        enc.setFragmentTexture(stripTex, index: 2)
        enc.setFragmentTexture(xbrz && stripScale == 1 ? stripBlend : dummyU, index: 3)
        enc.setFragmentTexture(r.overlayTexture, index: 4)
        enc.setFragmentTexture(r.paletteTexture, index: 5)
        enc.setFragmentTexture(glowA, index: 6)
        enc.setFragmentTexture(occlusion, index: 7)
        enc.setFragmentTexture(useHDBall ? hd!.ball! : ballTex, index: 8)
        enc.setFragmentTexture(xbrz && !useHDBall ? ballBlend : dummyU, index: 9)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if let nrot, !outputRotations.isEmpty,
           let box = Self.rotationScissor(outputRotations.map(\.rect), fit: fit, origin: origin, frac: frac,
                                          margin: key.curve ? Self.curveMargin(Double(st.crtCurvature)) * max(fit.width, fit.height) + 4 : 2,
                                          targetWidth: target.width, targetHeight: target.height) {
            // Rotated flippers: the same pass again, specialised with FC_ROTATE, only over the
            // flippers' rectangles (compiling the rotation into the full-screen draw slowed every
            // pixel by about 0.5-0.8 ms at 4K, even with nothing to rotate).
            var rk = key; rk.rotate = true
            enc.setRenderPipelineState(try presentPipeline(rk))
            enc.setScissorRect(box)
            enc.setFragmentTexture(r.indexTexture, index: 10)
            enc.setFragmentTexture(nrot.sprites.native, index: 11)
            enc.setFragmentTexture(nrot.sprites.hd, index: 12)
            enc.setFragmentTexture(basePaletteTex, index: 13)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
    }

    /// Fraction of the larger window side the CRT barrel warp can move a pixel: `cc *= 1 + k * cc'^2`
    /// with |cc| <= 1 shifts by up to k in [-1, 1] units, i.e. k / 2 of the size (plus a little).
    /// Settings > Display allows k up to 0.08 (0.04 of the size), more than the old fixed 0.03.
    static func curveMargin(_ curvature: Double) -> Double { max(0.03, 0.5 * curvature + 0.005) }

    /// Output-pixel scissor covering the flippers' union rectangles (table px) in the window, plus
    /// `margin` output px (the CRT curvature moves pixels), clipped to the viewport; nil if empty.
    static func rotationScissor(_ rects: [SIMD4<Float>], fit: EnhancedFit, origin: Double, frac: Double, margin: Double,
                                targetWidth: Int, targetHeight: Int) -> MTLScissorRect? {
        guard !rects.isEmpty else { return nil }
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for r in rects {
            x0 = min(x0, fit.x + Double(r.x) * fit.scaleX)
            x1 = max(x1, fit.x + Double(r.x + r.z) * fit.scaleX)
            y0 = min(y0, fit.y + (Double(r.y) - origin - frac) * fit.scaleY)
            y1 = max(y1, fit.y + (Double(r.y + r.w) - origin - frac) * fit.scaleY)
        }
        let vx0 = max(0, fit.x), vy0 = max(0, fit.y)
        let vx1 = min(Double(targetWidth), fit.x + fit.width), vy1 = min(Double(targetHeight), fit.y + fit.height)
        let ix0 = Int(max(vx0, (x0 - margin).rounded(.down))), iy0 = Int(max(vy0, (y0 - margin).rounded(.down)))
        let ix1 = Int(min(vx1, (x1 + margin).rounded(.up))), iy1 = Int(min(vy1, (y1 + margin).rounded(.up)))
        guard ix1 > ix0, iy1 > iy0 else { return nil }
        return MTLScissorRect(x: ix0, y: iy0, width: ix1 - ix0, height: iy1 - iy0)
    }
}

// MARK: - score window (strip only)

extension EnhancedPipeline {
    /// The display strip alone into `target` (the score window): the strip layer of `encode`
    /// (native strip_rgb, or the HD strip when a pack is active) through present_enhanced with no
    /// window rows, so every filter and the CRT post apply. Leaves the main frame's state
    /// (interpolation history, lighting, HD loading) alone.
    func encodeStrip(rows: Int, settings st: RenderSettings, aspect: PixelAspect, composer c: ClassicComposer?, palette: Palette,
                     renderer r: PinballRenderer, into cb: MTLCommandBuffer, target: MTLTexture) throws {
        guard let c else { return }
        let W = TableGeometry.width
        let hd = st.useHDPack ? self.hd : nil
        var stripTex = stripRGB
        var stripScale = 1
        if let hd, hd.fontAtlas != nil || !hd.pack.sprites.isEmpty {
            try renderHDStrip(hd, composer: c, palette: palette, paletteTex: r.paletteTexture, cb: cb)
            stripTex = hd.strip
            stripScale = hd.S
        } else {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = stripRGB
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.resourceCreation("strip encoder") }
            enc.label = "strip rgb (score window)"
            enc.setRenderPipelineState(stripPSO)
            enc.setFragmentTexture(r.stripTexture, index: 0)
            enc.setFragmentTexture(r.paletteTexture, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        let xbrz = st.filter == .xbrz
        if xbrz, stripScale == 1, let enc = cb.makeComputeCommandEncoder() {
            enc.label = "xBRZ prepass (score window)"
            var size = SIMD4<Int32>(Int32(W), Int32(ClassicComposer.stripBufferRows), 0, 0)
            enc.setTexture(stripRGB, index: 0); enc.setTexture(stripBlend, index: 1)
            enc.setBytes(&size, length: 16, index: 0)
            dispatch(enc, prepass, width: W + 1, height: ClassicComposer.stripBufferRows + 1)
            enc.endEncoding()
        }

        let fit = EnhancedFit.fit(sourceWidth: W, sourceHeight: rows, outputWidth: target.width, outputHeight: target.height,
                                  aspect: aspect, scaling: st.resolvedScaling(hdActive: hd != nil))
        let filterConst: Int32 = [UpscaleFilter.nearest: 0, .smooth: 1, .xbrz: 2, .crt: 3][st.filter] ?? 0
        var pu = EnhPresentUniforms()
        pu.dst = SIMD4(Float(fit.x), Float(fit.y), Float(fit.scaleX), Float(fit.scaleY))
        pu.src = SIMD4(Float(W), 0, 0, Float(rows))
        pu.mode = SIMD4(Float(filterConst), 1, Float(stripScale), 0)
        pu.frame = SIMD4(1, 0, Float(ClassicComposer.overlayRows), 0)
        pu.crt = SIMD4(st.crtCurvature, st.crtScanlines, st.crtMask, st.filter == .crt ? 1 : 0)
        pu.viewport = SIMD4(Float(fit.width), Float(fit.height), Float(Self.frameRows), 0)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.resourceCreation("score window encoder") }
        enc.label = "score window (enhanced \(st.filter.rawValue)\(stripScale > 1 ? ", HD x\(stripScale)" : ""))"
        enc.setViewport(MTLViewport(originX: fit.x, originY: fit.y, width: fit.width, height: fit.height, znear: 0, zfar: 1))
        let sx = max(0, Int(fit.x)), sy = max(0, Int(fit.y))
        enc.setScissorRect(MTLScissorRect(x: sx, y: sy, width: max(1, min(Int(fit.width.rounded(.up)), target.width - sx)),
                                          height: max(1, min(Int(fit.height.rounded(.up)), target.height - sy))))
        let key = PresentKey(format: target.pixelFormat.rawValue, filter: filterConst, winHD: false, strip: true,
                             stripHD: stripScale > 1, light: false, ball: 0, ballHD: false, occlusion: false, dots: false,
                             round: false, curve: st.filter == .crt && st.crtCurvature > 0)
        enc.setRenderPipelineState(try presentPipeline(key))
        enc.setFragmentBytes(&pu, length: MemoryLayout<EnhPresentUniforms>.stride, index: 0)
        enc.setFragmentTexture(r.frameTexture, index: 0)
        enc.setFragmentTexture(dummyU, index: 1)
        enc.setFragmentTexture(stripTex, index: 2)
        enc.setFragmentTexture(xbrz && stripScale == 1 ? stripBlend : dummyU, index: 3)
        enc.setFragmentTexture(r.overlayTexture, index: 4)
        enc.setFragmentTexture(r.paletteTexture, index: 5)
        enc.setFragmentTexture(glowA, index: 6)
        enc.setFragmentTexture(occlusion, index: 7)
        enc.setFragmentTexture(ballTex, index: 8)
        enc.setFragmentTexture(dummyU, index: 9)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}
