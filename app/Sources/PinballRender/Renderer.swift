import Foundation
import Metal
import PinballCore

/// Upscaling filter of the present pass (docs/enhanced/rendering.md).
/// * `nearest`: the classic look (the unchanged classic pass when nothing else is enabled;
///   sharp-bilinear at fractional scales in the enhanced path).
/// * `smooth`: Catmull-Rom bicubic.
/// * `xbrz`: xBRZ edge-directed pixel-art scaling at any scale (prepass + freescale evaluation).
/// * `crt`: scanlines with brightness-dependent beam width, aperture-grille mask, subtle curvature.
public enum UpscaleFilter: String, Sendable, CaseIterable {
    case nearest
    case smooth
    case xbrz
    case crt

    /// Older name of `xbrz` (the Scale2x-style placeholder it replaced).
    public static let xbrzLike = UpscaleFilter.xbrz

    /// Also accepts the old spelling "xbrz-like".
    public init?(rawValue: String) {
        switch rawValue {
        case "nearest": self = .nearest
        case "smooth", "bicubic": self = .smooth
        case "xbrz", "xbrz-like": self = .xbrz
        case "crt": self = .crt
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .nearest: return "nearest"
        case .smooth: return "smooth"
        case .xbrz: return "xbrz"
        case .crt: return "crt"
        }
    }

    var fragmentFunctionName: String { "present_nearest" }
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
    /// x: 1 = draw the window dot overlay; y: overlay rows.
    var overlayInfo: F4 = .zero

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
    /// x: strip rows visible below the window (0 = none).
    var strip: SIMD4<Float> = .zero
}

/// The original's 320x240 Mode X screen: the scrolling playfield window above the VGA
/// split line and the display strip below it (docs/formats/sprites.md 2.5).
public struct ScreenLayout: Sendable, Equatable {
    /// Strip rows currently on screen (0 = hidden or legacy 320x200 view).
    public var stripRows: Int
    /// Screen height in source pixels.
    public static let screenRows = 240
    public init(stripRows: Int) { self.stripRows = stripRows }
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
    /// Enhanced rendering options; `.classic` (the default) keeps the original passes.
    public var settings = RenderSettings.classic
    /// The upscale filter (shorthand for `settings.filter`).
    public var filter: UpscaleFilter {
        get { settings.filter }
        set { settings.filter = newValue }
    }
    /// High refresh: the front end sets this every display frame (`MotionInterpolation(simulation:)`);
    /// used when `settings.interpolate` is on.
    public var interpolation: MotionInterpolation?
    /// GPU time of the most recently completed frame encoded by `encode` (nil until one completes).
    public var lastGPUTime: RenderTiming? { timingBox.get() }
    private let timingBox = TimingBox()
    /// Warnings from loading the HD pack (empty if none was requested or it loaded cleanly).
    public var hdPackWarnings: [String] { enhanced?.hdWarnings ?? [] }
    /// True while an HD pack is drawn.
    public var hdPackActive: Bool { settings.useHDPack && enhanced?.hd != nil }
    let tableNumber: Int
    let assetsDirectory: URL
    private var enhanced: EnhancedPipeline?
    private var lastLampStates: [UInt8] = []
    private var presentCalls = 0
    private var lastInterpFrame: Int?
    public private(set) var palette: Palette
    /// Palette before per-frame overrides (PresentationState.paletteOverrides).
    public private(set) var basePalette: Palette
    /// Classic presentation (lamp overlays, strip, dot messages). nil = playfield only.
    public private(set) var composer: ClassicComposer?
    /// Strip rows shown below the window (set by the front end; 0 = none).
    public var stripRows = 0

    let library: MTLLibrary
    private let scenePipeline: MTLRenderPipelineState
    private var presentPipelines: [String: MTLRenderPipelineState] = [:]
    let indexTexture: MTLTexture
    let paletteTexture: MTLTexture
    private let atlasTexture: MTLTexture
    /// Window-relative dot overlay (320x240 R8Uint, 0 = transparent) and strip (320x30 R8Uint).
    let overlayTexture: MTLTexture
    let stripTexture: MTLTexture
    /// Flipper sprite frames (nil entries fall back to procedural capsules).
    public let flipperSprites: FlipperSpriteSet?
    private let assets: TableAssets
    /// Native frame: 320 x (400 + 1). One spare row allows sub-row smooth scrolling.
    let frameTexture: MTLTexture
    static let frameFormat: MTLPixelFormat = .rgba8Unorm

    public init(device: MTLDevice, assets: TableAssets, flipperSprites: FlipperSpriteSet? = nil) throws {
        self.device = device
        self.flipperSprites = flipperSprites
        guard let q = device.makeCommandQueue() else { throw RenderError.resourceCreation("command queue") }
        self.commandQueue = q
        self.palette = assets.palette
        self.basePalette = assets.palette
        self.tableNumber = assets.table
        self.assetsDirectory = assets.directory
        self.assets = assets
        if let env = RenderSettings.fromEnvironment() { settings = env }

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

        func r8(_ w: Int, _ h: Int, _ what: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: w, height: h, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d) else { throw RenderError.resourceCreation(what) }
            let zero = [UInt8](repeating: 0, count: w * h)
            zero.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w) }
            return t
        }
        overlayTexture = try r8(w, ClassicComposer.overlayRows, "overlay texture")
        stripTexture = try r8(w, ClassicComposer.stripBufferRows, "strip texture")

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

    /// Replace the whole palette (e.g. after lamp logic edits entries 200-254). Also becomes
    /// the base that per-frame overrides apply to.
    public func setPalette(_ p: Palette) {
        palette = p
        basePalette = p
        uploadPalette()
    }

    /// Base palette with this frame's overrides (entries not listed revert to the base).
    public func applyPaletteOverrides(_ overrides: [PaletteOverride], messageColour: Palette.RGB? = nil) {
        var p = basePalette
        if let m = messageColour { p[255] = m }
        for o in overrides { p[Int(o.index)] = Palette.RGB(r: o.r, g: o.g, b: o.b) }
        guard p != palette else { return }
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

    // MARK: - Classic presentation

    /// Attaches the classic composer: its VRAM replaces the playfield index texture.
    public func attach(composer c: ClassicComposer) {
        composer = c
        uploadIndexRows(0..<TableGeometry.height, from: c.vram)
        _ = c.takeDirtyRows()
    }

    private func uploadIndexRows(_ rows: Range<Int>, from buf: [UInt8]) {
        let w = TableGeometry.width
        buf.withUnsafeBytes { raw in
            indexTexture.replace(region: MTLRegionMake2D(0, rows.lowerBound, w, rows.count), mipmapLevel: 0,
                                 withBytes: raw.baseAddress! + rows.lowerBound * w, bytesPerRow: w)
        }
    }

    /// Applies one frame of presentation state: lamp overlays, flipper frames and the plunger
    /// into VRAM, palette overrides (DAC 255 = message colour unless overridden), the strip
    /// and the dot overlay. `message` carries the placement the original needs (AX, DI);
    /// see `DotMessage`. No-op without a composer.
    /// `lampSprites`: optional tri-state per slot (0 not drawn, 1 "a", 2 "b"; the rules
    /// runtime's lampDrawn) that replaces `state.lamps`, which cannot say "not drawn yet".
    public func present(_ state: PresentationState, message: DotMessage?, flippers: [SceneState.FlipperSprite] = [],
                        plungerY: Int? = nil, paused: Bool = false, lampSprites: [UInt8]? = nil) {
        guard let c = composer else { return }
        lastLampStates = state.lampStates
        presentCalls += 1
        if let ls = lampSprites { c.applyLampSprites(ls) } else { c.applyLamps(state.lamps) }
        for f in flippers { c.setFlipper(f.index, frame: f.frame) }
        c.setPlunger(y: plungerY)
        if let rows = c.takeDirtyRows() { uploadIndexRows(rows, from: c.vram) }
        let score = state.scores.indices.contains(state.currentPlayer) ? state.scores[state.currentPlayer] : (state.scores.first ?? 0)
        c.buildStrip(score: score, ball: state.ballNumber, player: state.currentPlayer + 1, tilted: state.tilted,
                     paused: paused, message: message)
        c.buildOverlay(message: message)
        let w = TableGeometry.width
        if c.stripDirty {
            c.strip.withUnsafeBytes { stripTexture.replace(region: MTLRegionMake2D(0, 0, w, ClassicComposer.stripBufferRows), mipmapLevel: 0,
                                                            withBytes: $0.baseAddress!, bytesPerRow: w) }
            c.markStripUploaded()
        }
        if c.overlayDirty {
            c.overlay.withUnsafeBytes { overlayTexture.replace(region: MTLRegionMake2D(0, 0, w, ClassicComposer.overlayRows), mipmapLevel: 0,
                                                                withBytes: $0.baseAddress!, bytesPerRow: w) }
            c.markOverlayUploaded()
        }
        applyPaletteOverrides(state.paletteOverrides, messageColour: c.messageColour)
    }

    /// Viewport the scene will occupy in an output of the given pixel size.
    public func fit(for scene: SceneState, outputWidth: Int, outputHeight: Int) -> ViewportFit {
        ViewportFit.fit(sourceWidth: TableGeometry.width, sourceHeight: Int(scene.viewHeight.rounded()) + visibleStripRows(for: scene),
                        outputWidth: outputWidth, outputHeight: outputHeight, aspect: aspect)
    }

    /// Strip rows drawn for this scene (none in the 400-row full-table view).
    public func visibleStripRows(for scene: SceneState) -> Int {
        if !settings.isClassic {
            return EnhancedPipeline.stripRows(scene, settings: settings, composer: composer, stripRows: stripRows)
        }
        guard composer != nil, scene.viewHeight < Double(TableGeometry.height) else { return 0 }
        return max(0, min(stripRows, ClassicComposer.stripBufferRows))
    }

    /// Encodes the frame, finishing with `target` cleared to black outside the viewport.
    /// Classic settings run the original two passes; anything else the enhanced pipeline.
    public func encode(scene: SceneState, into commandBuffer: MTLCommandBuffer, target: MTLTexture) throws {
        let box = timingBox
        commandBuffer.addCompletedHandler { cb in
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            if ms > 0 { box.set(RenderTiming(gpuMilliseconds: ms)) }
        }
        if settings.isClassic {
            try encodeClassic(scene: scene, into: commandBuffer, target: target)
            return
        }
        if enhanced == nil { enhanced = try EnhancedPipeline(device: device, library: library, assets: assets) }
        var frames = 1
        if let ip = interpolation {
            frames = lastInterpFrame.map { max(0, ip.frame - $0) } ?? 0
            lastInterpFrame = ip.frame
        } else {
            frames = presentCalls > 0 ? 1 : 0
            presentCalls = 0
        }
        let inputs = EnhancedPipeline.FrameInputs(scene: scene, settings: settings, interpolation: interpolation, aspect: aspect,
                                                  composer: composer, palette: palette, basePalette: basePalette,
                                                  stripRows: stripRows, lampStates: lastLampStates, framesAdvanced: frames)
        try enhanced!.encode(inputs, renderer: self, into: commandBuffer, target: target)
    }

    /// The original two passes (palette lookup + ball + dots at native resolution, then the
    /// integer nearest upscale). Unchanged by the enhanced work (EnhancedRenderTests).
    private func encodeClassic(scene: SceneState, into commandBuffer: MTLCommandBuffer, target: MTLTexture) throws {
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
        let composerFlippers = composer?.drawsFlippers ?? false
        if let c = composer, c.hasOverlay, scene.viewHeight < Double(TableGeometry.height) {
            su.overlayInfo = SIMD4(1, Float(ClassicComposer.overlayRows), 0, 0)
        }
        for (slot, f) in scene.flippers.prefix(SceneUniforms.maxFlippers).enumerated() where !composerFlippers {
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
        enc1.setFragmentTexture(overlayTexture, index: 3)
        enc1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc1.endEncoding()

        // Pass 2: upscale into the output.
        var pu = PresentUniforms(
            dst: SIMD4(Float(fit.x), Float(fit.y), Float(fit.scaleX), Float(fit.scaleY)),
            src: SIMD4(Float(TableGeometry.width), Float(visibleRows), Float(frac), 0),
            strip: SIMD4(Float(visibleStripRows(for: scene)), 0, 0, 0))
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
        enc2.setFragmentTexture(stripTexture, index: 1)
        enc2.setFragmentTexture(paletteTexture, index: 2)
        enc2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc2.endEncoding()
    }
}

/// Written from Metal's completion thread, read by the owner.
final class TimingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RenderTiming?
    func set(_ v: RenderTiming) { lock.lock(); value = v; lock.unlock() }
    func get() -> RenderTiming? { lock.lock(); defer { lock.unlock() }; return value }
}
