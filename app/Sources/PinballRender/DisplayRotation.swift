import Foundation
import Metal
import PinballCore

/// Cabinet / portrait display (docs/enhanced/rendering.md "Display rotation").
///
/// The frame is rendered upright into a *logical* target: the output with width and height
/// swapped for 90 and 270 degrees. One extra pass (`present_rotate`) then turns it into the real
/// target in whole pixels. Every filter of both pipelines therefore letterboxes and scales in
/// the logical target exactly as it does unrotated, in backing (Retina) pixels, and the turn
/// itself neither resamples nor blurs. With `.none` nothing changes (no extra pass or texture).
///
/// Rotations are clockwise: with 90 the picture's top is at the output's right-hand edge, which
/// is upright on a monitor turned 90 degrees anticlockwise (its right-hand edge now at the top).
public struct DisplayTransform: Sendable, Equatable {
    public var rotation: GameSettings.DisplayRotation
    /// The real output (drawable) in pixels.
    public var outputWidth: Int
    public var outputHeight: Int

    public init(rotation: GameSettings.DisplayRotation, outputWidth: Int, outputHeight: Int) {
        self.rotation = rotation; self.outputWidth = outputWidth; self.outputHeight = outputHeight
    }

    /// Clockwise quarter turns (0...3).
    public var quarterTurns: Int { rotation.rawValue / 90 }
    public var swapsAxes: Bool { rotation == .clockwise90 || rotation == .clockwise270 }
    /// The upright render target the frame is drawn into.
    public var logicalWidth: Int { swapsAxes ? outputHeight : outputWidth }
    public var logicalHeight: Int { swapsAxes ? outputWidth : outputHeight }

    /// Output pixel that shows logical pixel `p`.
    public func physical(fromLogical p: SIMD2<Int>) -> SIMD2<Int> {
        let w = outputWidth, h = outputHeight
        switch rotation {
        case .none: return p
        case .clockwise90: return SIMD2(w - 1 - p.y, p.x)
        case .upsideDown: return SIMD2(w - 1 - p.x, h - 1 - p.y)
        case .clockwise270: return SIMD2(p.y, h - 1 - p.x)
        }
    }

    /// Logical pixel shown at output pixel `p` (what `present_rotate` reads).
    public func logical(fromPhysical p: SIMD2<Int>) -> SIMD2<Int> {
        let w = outputWidth, h = outputHeight
        switch rotation {
        case .none: return p
        case .clockwise90: return SIMD2(p.y, w - 1 - p.x)
        case .upsideDown: return SIMD2(w - 1 - p.x, h - 1 - p.y)
        case .clockwise270: return SIMD2(h - 1 - p.y, p.x)
        }
    }

    /// A logical rectangle (e.g. the letterboxed viewport) in output pixels.
    public func physicalRect(x: Double, y: Double, width: Double, height: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        let w = Double(outputWidth), h = Double(outputHeight)
        switch rotation {
        case .none: return (x, y, width, height)
        case .clockwise90: return (w - (y + height), x, height, width)
        case .upsideDown: return (w - (x + width), h - (y + height), width, height)
        case .clockwise270: return (y, h - (x + width), height, width)
        }
    }
}

extension PinballRenderer {
    /// Renders the frame upright into the cached logical texture, then turns it into `target`.
    func encodeRotated(scene: SceneState, into cb: MTLCommandBuffer, target: MTLTexture) throws {
        let t = DisplayTransform(rotation: settings.rotation, outputWidth: target.width, outputHeight: target.height)
        let upright = try uprightTarget(width: t.logicalWidth, height: t.logicalHeight, format: target.pixelFormat, cache: &rotationScratch)
        try encodeFrame(scene: scene, into: cb, target: upright)
        try encodeTurn(upright, by: t, into: cb, target: target)
    }

    /// `present_rotate`: the upright texture turned into `target` (whole pixels).
    func encodeTurn(_ upright: MTLTexture, by t: DisplayTransform, into cb: MTLCommandBuffer, target: MTLTexture) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.resourceCreation("rotate encoder") }
        enc.label = "display rotation (\(t.rotation.rawValue))"
        enc.setRenderPipelineState(try rotatePipeline(for: target.pixelFormat))
        var u = SIMD4<Int32>(Int32(t.quarterTurns), Int32(target.width), Int32(target.height), 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<SIMD4<Int32>>.stride, index: 0)
        enc.setFragmentTexture(upright, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    func uprightTarget(width: Int, height: Int, format: MTLPixelFormat, cache: inout MTLTexture?) throws -> MTLTexture {
        if let t = cache, t.width == width, t.height == height, t.pixelFormat == format { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, width), height: max(1, height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw RenderError.resourceCreation("rotation texture") }
        cache = t
        return t
    }

    private func rotatePipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let p = rotatePipelines[format.rawValue] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        guard let f = library.makeFunction(name: "present_rotate") else { throw RenderError.shaderCompile("missing function present_rotate") }
        d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = format
        let p: MTLRenderPipelineState
        do { p = try device.makeRenderPipelineState(descriptor: d) } catch { throw RenderError.shaderCompile("present_rotate: \(error)") }
        rotatePipelines[format.rawValue] = p
        return p
    }
}

// MARK: - score window (strip only)

extension PinballRenderer {
    /// Viewport of the display strip alone (`rows` strip rows) in an output of the given size:
    /// the score window's letterbox, with the same integer / fill rules as the main view.
    public func stripFit(rows: Int, outputWidth: Int, outputHeight: Int) -> EnhancedFit {
        let rows = max(1, min(rows, ClassicComposer.stripBufferRows))
        return EnhancedFit.fit(sourceWidth: TableGeometry.width, sourceHeight: rows, outputWidth: outputWidth,
                               outputHeight: outputHeight, aspect: aspect,
                               scaling: settings.isClassic ? .integer : settings.resolvedScaling(hdActive: hdPackActive))
    }

    /// Encodes the display strip alone (the score / DMD window) into `target`, letterboxed and
    /// upscaled with the current filter. `rotation` is the score window's own picture rotation
    /// (its screen may be mounted differently from the playfield's; `settings.rotation` is not
    /// used here): the strip is drawn upright into a cached texture of the swapped size and turned,
    /// as `encode` does. Uses the strip the last `present` built, so call it after the main
    /// window's frame. No-op without a composer.
    public func encodeStrip(rows: Int, into cb: MTLCommandBuffer, target: MTLTexture,
                            rotation: GameSettings.DisplayRotation = .none) throws {
        guard composer != nil else { return }
        if rotation != .none {
            let t = DisplayTransform(rotation: rotation, outputWidth: target.width, outputHeight: target.height)
            let upright = try uprightTarget(width: t.logicalWidth, height: t.logicalHeight, format: target.pixelFormat,
                                            cache: &stripRotationScratch)
            try encodeStrip(rows: rows, into: cb, target: upright)
            try encodeTurn(upright, by: t, into: cb, target: target)
            return
        }
        let rows = max(1, min(rows, ClassicComposer.stripBufferRows))
        if !settings.isClassic {
            if enhanced == nil { enhanced = try EnhancedPipeline(device: device, library: library, assets: assets) }
            try enhanced!.encodeStrip(rows: rows, settings: settings, aspect: aspect, composer: composer, palette: palette,
                                      renderer: self, into: cb, target: target)
            return
        }
        // Classic: the original present pass with no window rows (every row is a strip row).
        let fit = stripFit(rows: rows, outputWidth: target.width, outputHeight: target.height)
        var pu = PresentUniforms(dst: SIMD4(Float(fit.x), Float(fit.y), Float(fit.scaleX), Float(fit.scaleY)),
                                 src: SIMD4(Float(TableGeometry.width), 0, 0, 0),
                                 strip: SIMD4(Float(rows), 0, 0, 0))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.resourceCreation("strip encoder") }
        enc.label = "score window (strip)"
        enc.setViewport(MTLViewport(originX: fit.x, originY: fit.y, width: fit.width, height: fit.height, znear: 0, zfar: 1))
        let sx = max(0, Int(fit.x)), sy = max(0, Int(fit.y))
        enc.setScissorRect(MTLScissorRect(x: sx, y: sy, width: max(1, min(Int(fit.width.rounded(.up)), target.width - sx)),
                                          height: max(1, min(Int(fit.height.rounded(.up)), target.height - sy))))
        enc.setRenderPipelineState(try presentPipeline(for: target.pixelFormat))
        enc.setFragmentBytes(&pu, length: MemoryLayout<PresentUniforms>.stride, index: 0)
        enc.setFragmentTexture(frameTexture, index: 0)
        enc.setFragmentTexture(stripTexture, index: 1)
        enc.setFragmentTexture(paletteTexture, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// The strip alone rendered offscreen as RGBA8 (score-window snapshots and tests).
    public func renderStripOffscreen(rows: Int, width: Int, height: Int, rotation: GameSettings.DisplayRotation = .none) throws -> [UInt8] {
        try renderOffscreen(width: width, height: height) { cb, target in
            try encodeStrip(rows: rows, into: cb, target: target, rotation: rotation)
        }
    }
}
