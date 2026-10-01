import Foundation
import Metal
import PinballCore

/// What drawing flippers rotated with an HD pack needs (docs/enhanced/rendering.md, "Rotated
/// flippers"): per flipper, the clean HD sprite of every frame and the HD background under the
/// flipper (`FlipperArt` split, at the pack's scale), plus the frames' native indices for the "is
/// this pixel still the flipper record" test. Built on the CPU from plain values (so it can run
/// off the main thread), uploaded by `FlipperRotationSet`.
struct FlipperRotationData: Sendable {
    struct Entry: Sendable {
        let art: FlipperArt
        /// First row of this flipper's frames in `native` (frame k at nativeRow + k * art.h).
        let nativeRow: Int
        /// Top row of each frame's padded HD sprite in `hd`, and of the padded HD background.
        let spriteRows: [Int]
        let backgroundRow: Int
    }
    /// Transparent border (HD px) around every sub-image, so bilinear taps never reach a neighbour.
    static let pad = 2
    let scale: Int
    /// By flipper index (`EngineData.flippers`); flippers whose split is not usable are missing.
    let entries: [Int: Entry]
    /// palette index + 1 of each frame (0 = not covered), union rect per frame, `nativeW` wide.
    let native: [UInt16]
    let nativeW: Int, nativeH: Int
    /// RGBA8 premultiplied: sprites and backgrounds, `hdW` wide.
    let hd: [UInt8]
    let hdW: Int, hdH: Int
    /// Seconds spent building (CPU).
    let buildTime: Double

    /// `frames` / `flippers`: `ClassicComposer.flipperFrames` / `flipperData`; `sprites` and `scale`
    /// from the HD pack.
    init?(frames flipperFrames: [[IndexedSprite]?], flippers: [EngineData.Flipper], sprites: [String: RGBAImage], scale S: Int,
          basePalette: Palette) {
        let t0 = Date()
        let pad = Self.pad
        var arts: [(Int, FlipperArt)] = []
        for (i, frames) in flipperFrames.enumerated() {
            guard let frames, flippers.indices.contains(i),
                  let art = FlipperArt(frames: frames, palette: basePalette, flipper: flippers[i]), art.usable else { continue }
            arts.append((i, art))
        }
        guard !arts.isEmpty else { return nil }
        // Layouts.
        let nativeW = arts.map { $0.1.w }.max()!, nativeH = arts.reduce(0) { $0 + $1.1.h * $1.1.frameCount }
        let hdW = arts.map { $0.1.w * S + 2 * pad }.max()!
        let hdH = arts.reduce(0) { $0 + ($1.1.h * S + 2 * pad) * ($1.1.frameCount + 1) }
        var nat = [UInt16](repeating: 0, count: nativeW * nativeH)
        var img = [UInt8](repeating: 0, count: hdW * hdH * 4)
        var entries: [Int: Entry] = [:]
        var nrow = 0, hrow = 0
        for (i, art) in arts {
            let frames = flipperFrames[i]!
            let W = art.w * S, H = art.h * S, n = art.w * art.h
            for k in 0..<art.frameCount {
                for y in 0..<art.h { for x in 0..<art.w { nat[(nrow + k * art.h + y) * nativeW + x] = art.values[k][y * art.w + x] } }
            }
            // HD frames in union-rect coordinates (pack sprite, else the original pixels, nearest).
            var hdFrames = [[Float]](repeating: [Float](repeating: 0, count: W * H * 3), count: art.frameCount)
            for (k, s) in frames.enumerated() {
                let ox = (s.x - art.x) * S, oy = (s.y - art.y) * S
                let packImg = sprites[s.name]
                for Y in 0..<(s.h * S) {
                    for X in 0..<(s.w * S) {
                        let d = ((oy + Y) * W + ox + X) * 3
                        if let p = packImg {
                            let o = (Y * p.width + X) * 4
                            for ch in 0..<3 { hdFrames[k][d + ch] = Float(p.pixels[o + ch]) }
                        } else {
                            let e = basePalette[Int(s.pixels[(Y / S) * s.w + X / S])]
                            hdFrames[k][d] = Float(e.r); hdFrames[k][d + 1] = Float(e.g); hdFrames[k][d + 2] = Float(e.b)
                        }
                    }
                }
            }
            func mask(_ k: Int, _ x: Int, _ y: Int) -> UInt8? {
                guard x >= 0, y >= 0, x < art.w, y < art.h else { return nil }
                return art.masks[k][y * art.w + x]
            }
            // Background: per native pixel the frame that shows it with no flipper pixel around it
            // (xBRZ blends across edges), else any frame that shows it, else the filled-in native one.
            var bgFrame = [Int](repeating: -1, count: n)
            for p in 0..<n {
                let px = p % art.w, py = p / art.w
                var any = -1
                for k in 0..<art.frameCount where art.values[k][p] != 0 && art.masks[k][p] == 0 {
                    if any < 0 { any = k }
                    var clean = true
                    for dy in -1...1 { for dx in -1...1 where mask(k, px + dx, py + dy) == 1 { clean = false } }
                    if clean { any = k; break }
                }
                bgFrame[p] = any
            }
            var bg = [Float](repeating: 0, count: W * H * 3)
            var bgKnown = [Bool](repeating: false, count: W * H)
            for Y in 0..<H {
                for X in 0..<W {
                    let p = (Y / S) * art.w + X / S, d = (Y * W + X) * 3
                    if bgFrame[p] >= 0 {
                        for ch in 0..<3 { bg[d + ch] = hdFrames[bgFrame[p]][d + ch] }
                        bgKnown[Y * W + X] = true
                    } else {
                        let e = basePalette[Int(art.background[p])]
                        bg[d] = Float(e.r); bg[d + 1] = Float(e.g); bg[d + 2] = Float(e.b)
                    }
                }
            }
            // Soften the filled-in part (it is almost always under the flipper anyway).
            for _ in 0..<(2 * S) {
                var next = bg
                for Y in 0..<H {
                    for X in 0..<W where !bgKnown[Y * W + X] {
                        var acc = SIMD3<Float>(0, 0, 0), cnt: Float = 0
                        for dy in -1...1 { for dx in -1...1 {
                            let x = X + dx, y = Y + dy
                            guard x >= 0, y >= 0, x < W, y < H else { continue }
                            let o = (y * W + x) * 3
                            acc += SIMD3(bg[o], bg[o + 1], bg[o + 2]); cnt += 1
                        } }
                        let d = (Y * W + X) * 3, v = acc / cnt
                        next[d] = v.x; next[d + 1] = v.y; next[d + 2] = v.z
                    }
                }
                bg = next
            }
            // Sprites: alpha 1 inside the mask, 0 outside, and on the native edge band from the HD
            // pixel's difference to the background (difference keying), premultiplied by unmixing
            // the background: frame = alpha * sprite + (1 - alpha) * background.
            var rows: [Int] = []
            for k in 0..<art.frameCount {
                rows.append(hrow)
                for Y in 0..<H {
                    for X in 0..<W {
                        let px = X / S, py = Y / S
                        guard art.values[k][py * art.w + px] != 0 else { continue }
                        let m = mask(k, px, py) == 1
                        var interior = m, exterior = !m
                        for dy in -1...1 { for dx in -1...1 {
                            let v = mask(k, px + dx, py + dy) ?? (m ? 1 : 0)
                            if v == 0 && (dx == 0 || dy == 0) { interior = false }
                            if v == 1 { exterior = false }
                        } }
                        let d = (Y * W + X) * 3
                        let f = SIMD3(hdFrames[k][d], hdFrames[k][d + 1], hdFrames[k][d + 2])
                        let b = SIMD3(bg[d], bg[d + 1], bg[d + 2])
                        var a: Float
                        if interior { a = 1 } else if exterior { a = 0 } else if bgKnown[Y * W + X] {
                            let diff = f - b
                            a = min(1, (diff * diff).sum().squareRoot() / 60)
                        } else { a = m ? 1 : 0 }
                        guard a > 0 else { continue }
                        let c = (f - (1 - a) * b).clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 255 * a))
                        let o = ((hrow + pad + Y) * hdW + pad + X) * 4
                        img[o] = UInt8(c.x.rounded()); img[o + 1] = UInt8(c.y.rounded()); img[o + 2] = UInt8(c.z.rounded())
                        img[o + 3] = UInt8((a * 255).rounded())
                    }
                }
                hrow += H + 2 * pad
            }
            let bgRow = hrow
            for Y in 0..<H {
                for X in 0..<W {
                    let d = (Y * W + X) * 3, o = ((hrow + pad + Y) * hdW + pad + X) * 4
                    img[o] = UInt8(bg[d].rounded()); img[o + 1] = UInt8(bg[d + 1].rounded()); img[o + 2] = UInt8(bg[d + 2].rounded()); img[o + 3] = 255
                }
            }
            hrow += H + 2 * pad
            entries[i] = Entry(art: art, nativeRow: nrow, spriteRows: rows, backgroundRow: bgRow)
            nrow += art.h * art.frameCount
        }
        native = nat; hd = img; scale = S
        self.nativeW = nativeW; self.nativeH = nativeH; self.hdW = hdW; self.hdH = hdH
        self.entries = entries
        buildTime = Date().timeIntervalSince(t0)
    }
}

/// `FlipperRotationData` on the GPU.
final class FlipperRotationSet {
    let data: FlipperRotationData
    var entries: [Int: FlipperRotationData.Entry] { data.entries }
    var buildTime: Double { data.buildTime }
    /// R16Uint frame indices and RGBA8 premultiplied sprites / backgrounds.
    let native: MTLTexture
    let hd: MTLTexture

    init?(device: MTLDevice, data d: FlipperRotationData) {
        let nd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: d.nativeW, height: d.nativeH, mipmapped: false)
        nd.usage = .shaderRead; nd.storageMode = .shared
        let hdd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: d.hdW, height: d.hdH, mipmapped: false)
        hdd.usage = .shaderRead; hdd.storageMode = .shared
        guard let nt = device.makeTexture(descriptor: nd), let ht = device.makeTexture(descriptor: hdd) else { return nil }
        d.native.withUnsafeBytes { nt.replace(region: MTLRegionMake2D(0, 0, d.nativeW, d.nativeH), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: d.nativeW * 2) }
        d.hd.withUnsafeBytes { ht.replace(region: MTLRegionMake2D(0, 0, d.hdW, d.hdH), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: d.hdW * 4) }
        data = d; native = nt; hd = ht
    }
}

/// Builds `FlipperRotationData` on a background queue (a few hundred ms in a debug build); the
/// renderer cross-fades the flippers until it is done.
final class FlipperRotationJob: @unchecked Sendable {
    private let lock = NSLock()
    private var result: FlipperRotationData??
    private let group = DispatchGroup()

    init(frames: [[IndexedSprite]?], flippers: [EngineData.Flipper], sprites: [String: RGBAImage], scale: Int, basePalette: Palette) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let d = FlipperRotationData(frames: frames, flippers: flippers, sprites: sprites, scale: scale, basePalette: basePalette)
            lock.lock(); result = .some(d); lock.unlock()
            group.leave()
        }
    }

    /// nil while building; then the data (or .some(nil): no flipper usable).
    var finished: FlipperRotationData?? { lock.lock(); defer { lock.unlock() }; return result }

    func wait() { group.wait() }
}

// MARK: - without an HD pack

/// Rotated flippers without an HD pack (docs/enhanced/rendering.md, "Rotated flippers without an
/// HD pack"): the scene pass is native 320 px there, so the flippers are rotated at output
/// resolution in `present_enhanced` instead. Their art comes from the game's frames upscaled `scale`
/// times on the GPU by the active filter (`flipper_upscale`: the same xBRZ / bicubic functions the
/// present pass filters the window with; each frame in a crop of the playfield so its edges blend
/// as in context), then split exactly like an HD pack's frames (`FlipperRotationData` at that
/// scale). The scene pass writes the frames' background (`FlipperArt.background`, native palette
/// indices) where VRAM shows a flipper frame, so the filter sees the table without the flipper,
/// and the present pass composites the rotated sprite on top.
struct NativeFlipperRotationKey: Equatable, Sendable {
    var composer: ObjectIdentifier
    var filter: UpscaleFilter
    var scale: Int
}

/// The GPU resources: `FlipperRotationSet` (sprites at `scale`, ownership atlas) plus the native
/// background indices per flipper (r8Uint, one slab per flipper at `backgroundRows`).
final class NativeFlipperRotation {
    let key: NativeFlipperRotationKey
    let sprites: FlipperRotationSet
    let background: MTLTexture
    let backgroundRows: [Int: Int]
    var entries: [Int: FlipperRotationData.Entry] { sprites.entries }
    var scale: Int { key.scale }

    init?(device: MTLDevice, key: NativeFlipperRotationKey, data d: FlipperRotationData) {
        guard let sprites = FlipperRotationSet(device: device, data: d) else { return nil }
        let order = d.entries.keys.sorted()
        let w = max(1, order.map { d.entries[$0]!.art.w }.max() ?? 1)
        let h = max(1, order.reduce(0) { $0 + d.entries[$1]!.art.h })
        var bytes = [UInt8](repeating: 0, count: w * h)
        var rows: [Int: Int] = [:]
        var row = 0
        for i in order {
            let art = d.entries[i]!.art
            for y in 0..<art.h { for x in 0..<art.w { bytes[(row + y) * w + x] = art.background[y * art.w + x] } }
            rows[i] = row
            row += art.h
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: w, height: h, mipmapped: false)
        td.usage = .shaderRead; td.storageMode = .shared
        guard let t = device.makeTexture(descriptor: td) else { return nil }
        bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w) }
        self.key = key; self.sprites = sprites; background = t; backgroundRows = rows
    }

    /// Upscale factor for an output scale (output px per table px): enough that the sprite is not
    /// magnified much more than 1x at the output, capped to keep the build short.
    static func scale(forOutputScale s: Double) -> Int { min(8, max(2, Int(s.rounded(.up)))) }
}

/// Builds the data for `NativeFlipperRotation` on a background queue (GPU upscale with its own
/// command queue, then the CPU split); the renderer cross-fades the flippers until it is done.
final class NativeFlipperRotationJob: @unchecked Sendable {
    let key: NativeFlipperRotationKey
    private let lock = NSLock()
    private var result: FlipperRotationData??
    private let group = DispatchGroup()
    /// Playfield margin (table px) around each frame in the upscaled crop.
    static let margin = 3

    init(key: NativeFlipperRotationKey, device: MTLDevice, upscale: MTLComputePipelineState, prepass: MTLComputePipelineState,
         frames: [[IndexedSprite]?], flippers: [EngineData.Flipper], playfield: [UInt8], basePalette: Palette) {
        self.key = key
        group.enter()
        let dev = UnsafeSendableBox((device, upscale, prepass))
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let (device, upscale, prepass) = dev.value
            var d: FlipperRotationData?
            if let sprites = Self.upscaleFrames(device: device, upscale: upscale, prepass: prepass, frames: frames,
                                                playfield: playfield, palette: basePalette, filter: key.filter, scale: key.scale) {
                d = FlipperRotationData(frames: frames, flippers: flippers, sprites: sprites, scale: key.scale, basePalette: basePalette)
            }
            lock.lock(); result = .some(d); lock.unlock()
            group.leave()
        }
    }

    var finished: FlipperRotationData?? { lock.lock(); defer { lock.unlock() }; return result }

    func wait() { group.wait() }

    /// Every flipper frame upscaled `scale` times by `flipper_upscale` (straight RGBA8, the frame's
    /// own rectangle times `scale`), keyed by sprite name; nil if the GPU work failed.
    static func upscaleFrames(device: MTLDevice, upscale: MTLComputePipelineState, prepass: MTLComputePipelineState,
                              frames: [[IndexedSprite]?], playfield: [UInt8], palette: Palette,
                              filter: UpscaleFilter, scale K: Int) -> [String: RGBAImage]? {
        guard let queue = device.makeCommandQueue(), let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return nil }
        let M = margin, TW = TableGeometry.width, TH = TableGeometry.height
        let rgba = palette.rgba8
        var outputs: [(String, MTLTexture)] = []
        func tex(_ f: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage, shared: Bool) -> MTLTexture? {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: max(1, w), height: max(1, h), mipmapped: false)
            td.usage = usage; td.storageMode = shared ? .shared : .private
            return device.makeTexture(descriptor: td)
        }
        func dispatch(_ pso: MTLComputePipelineState, _ w: Int, _ h: Int) {
            enc.setComputePipelineState(pso)
            enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        for s in frames.compactMap({ $0 }).joined() {
            // The frame over the playfield around it (base palette, as the pack sprites are).
            let cw = s.w + 2 * M, ch = s.h + 2 * M
            var crop = [UInt8](repeating: 0, count: cw * ch * 4)
            for y in 0..<ch {
                for x in 0..<cw {
                    let lx = x - M, ly = y - M
                    let v: UInt8
                    if lx >= 0, ly >= 0, lx < s.w, ly < s.h {
                        v = s.pixels[ly * s.w + lx]
                    } else {
                        let tx = min(max(s.x + lx, 0), TW - 1), ty = min(max(s.y + ly, 0), TH - 1)
                        v = playfield.count == TW * TH ? playfield[ty * TW + tx] : 0
                    }
                    let o = (y * cw + x) * 4, p = Int(v) * 4
                    crop[o] = rgba[p]; crop[o + 1] = rgba[p + 1]; crop[o + 2] = rgba[p + 2]; crop[o + 3] = 255
                }
            }
            guard let src = tex(.rgba8Unorm, cw, ch, [.shaderRead], shared: true),
                  let blend = tex(.r8Uint, cw + 2, ch + 2, [.shaderRead, .shaderWrite], shared: false),
                  let dst = tex(.rgba8Unorm, s.w * K, s.h * K, [.shaderRead, .shaderWrite], shared: true) else { enc.endEncoding(); return nil }
            crop.withUnsafeBytes { src.replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: cw * 4) }
            if filter == .xbrz {
                var size = SIMD4<Int32>(Int32(cw), Int32(ch), 0, 0)
                enc.setTexture(src, index: 0); enc.setTexture(blend, index: 1)
                enc.setBytes(&size, length: 16, index: 0)
                dispatch(prepass, cw + 1, ch + 1)
            }
            var u = SIMD4<Float>(filter == .xbrz ? 2 : 1, Float(K), Float(M), 0)
            enc.setTexture(src, index: 0); enc.setTexture(blend, index: 1); enc.setTexture(dst, index: 2)
            enc.setBytes(&u, length: 16, index: 0)
            dispatch(upscale, s.w * K, s.h * K)
            outputs.append((s.name, dst))
        }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else { return nil }
        var images: [String: RGBAImage] = [:]
        for (name, t) in outputs {
            var px = [UInt8](repeating: 0, count: t.width * t.height * 4)
            px.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0) }
            images[name] = RGBAImage(width: t.width, height: t.height, pixels: px)
        }
        return images
    }
}

/// Metal objects are thread-safe; this only carries them into the build closure.
private struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}
