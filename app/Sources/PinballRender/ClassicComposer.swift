import Foundation
import PinballCore

/// CPU side of the classic presentation: keeps the original's persistent VRAM picture
/// (playfield + everything the game blits into it and never erases) and builds the
/// display strip and the dot-message overlay for a frame, all as palette indices.
///
/// Draw order, as in the original:
/// 1. VRAM (`vram`, 320x400): playfield, then opaque blits in the order the game makes
///    them: lamp overlays when their state changes (lamp_update cs:478D -> blit_list
///    cs:472F, rectangles with the background baked in, no colour key), then flipper
///    frames when their angle changes (flipper_update -> draw_flipper_sprite cs:3C12, also
///    opaque), then the plunger (draw_plunger cs:4959). A later blit overwrites an earlier
///    one where their rectangles overlap, like on the VGA.
/// 2. Ball (GPU, colour key 0), composited by the engine from the *collision map*, not
///    from VRAM (ball_pixel_scan cs:1679): occluder pixels show the static art even where
///    an overlay is drawn. This is what the original does.
/// 3. Dot messages in DAC colour 255 on top (render_frame cs:43D5, plotted into the page
///    at the window's top-left each frame). EP9-13 plot them into the strip instead.
/// The strip (VRAM rows 0-19 / 0-29) sits below the split line and never scrolls.
public final class ClassicComposer {
    public let graphics: GameGraphics
    public let spec: StripSpec
    public let exe: TableExe?
    public let width = TableGeometry.width
    public let height = TableGeometry.height
    /// Visible strip rows are at most 30 (EP9-13); the buffer always has 30.
    public static let stripBufferRows = 30
    public static let overlayRows = 240

    public private(set) var vram: [UInt8]
    public private(set) var strip: [UInt8]
    /// Window-relative dot overlay (320x240), 0 = nothing, else a palette index.
    public private(set) var overlay: [UInt8]
    /// VRAM rows changed since the last `takeDirtyRows()`.
    public private(set) var dirtyRows: Range<Int>?
    public private(set) var overlayDirty = true
    public private(set) var stripDirty = true

    private let base: [UInt8]
    private var lampShown: [Bool?]
    private var flipperShown: [Int: Int] = [:]
    private var plungerShown: Int?
    private var lastStripKey: StripKey?
    private var lastOverlayKey: [Int] = []

    /// Flipper sprite frames by `EngineData.flippers` index (resolved by name from graphics).
    public let flipperFrames: [[IndexedSprite]?]

    public init(graphics: GameGraphics, spec: StripSpec, exe: TableExe?, playfield: [UInt8], engine: EngineData? = nil) {
        precondition(playfield.count == TableGeometry.width * TableGeometry.height)
        self.graphics = graphics
        self.spec = spec
        self.exe = exe
        self.base = playfield
        self.vram = playfield
        self.strip = [UInt8](repeating: spec.fill, count: TableGeometry.width * Self.stripBufferRows)
        self.overlay = [UInt8](repeating: 0, count: TableGeometry.width * Self.overlayRows)
        self.lampShown = Array(repeating: nil, count: graphics.lampCount)
        self.flipperFrames = (engine?.flippers ?? []).map { f -> [IndexedSprite]? in
            guard let s = f.sprite else { return nil }
            let frames = s.frames.compactMap { graphics.byName[($0 as NSString).deletingPathExtension] }
            // Frames are position-bound records; engine.json also gives x,y (same values).
            return frames.count == s.frames.count && !frames.isEmpty ? frames : nil
        }
    }

    /// True if every flipper has EXE/PNG frames, i.e. the composer draws them into VRAM
    /// (the renderer then skips its own flipper path).
    public var drawsFlippers: Bool { !flipperFrames.isEmpty && flipperFrames.allSatisfy { $0 != nil } }

    /// True while a window dot message is plotted.
    public var hasOverlay: Bool { !lastOverlayKey.isEmpty }

    public func takeDirtyRows() -> Range<Int>? { defer { dirtyRows = nil }; return dirtyRows }
    public func markOverlayUploaded() { overlayDirty = false }
    public func markStripUploaded() { stripDirty = false }

    private func markDirty(_ y0: Int, _ y1: Int) {
        let lo = max(0, y0), hi = min(height, y1)
        guard lo < hi else { return }
        dirtyRows = dirtyRows.map { min($0.lowerBound, lo)..<max($0.upperBound, hi) } ?? lo..<hi
    }

    /// Opaque blit (blit_list cs:472F: no colour key; rows outside 0..399 are dropped).
    public func blit(_ s: IndexedSprite, x: Int? = nil, y: Int? = nil, clipBottom: Int? = nil) {
        let x0 = x ?? s.x, y0 = y ?? s.y
        let bottom = min(height, clipBottom ?? height)
        for r in 0..<s.h {
            let ty = y0 + r
            guard ty >= 0, ty < bottom else { continue }
            let src = r * s.w
            let dst = ty * width
            for c in 0..<s.w {
                let tx = x0 + c
                if tx >= 0 && tx < width { vram[dst + tx] = s.pixels[src + c] }
            }
        }
        markDirty(y0, y0 + s.h)
    }

    /// Back to the bare playfield (nothing drawn).
    public func reset() {
        vram = base
        lampShown = Array(repeating: nil, count: graphics.lampCount)
        flipperShown = [:]
        plungerShown = nil
        markDirty(0, height)
    }

    // MARK: VRAM updates

    /// Lamp k lit (`true`) draws record "a", unlit draws "b" (PresentationState.lamps).
    /// Only slots whose state changed are blitted, in slot order. An empty array after a
    /// non-empty one resets VRAM to the playfield.
    public func applyLamps(_ lamps: [Bool]) {
        if lamps.isEmpty {
            if lampShown.contains(where: { $0 != nil }) {
                let f = flipperShown, p = plungerShown
                reset()
                for (i, fr) in f { setFlipper(i, frame: fr, force: true) }
                if let p { setPlunger(y: p) }
            }
            return
        }
        for k in 0..<min(lamps.count, lampShown.count) where lampShown[k] != lamps[k] { blitLamp(k, a: lamps[k]) }
    }

    /// Tri-state lamp input (the rules runtime's `lampDrawn`): 0 = not drawn since boot
    /// (baked playfield shows), 1 = record "a", 2 = record "b". Changed slots are blitted in
    /// slot order; a slot going back to 0 (new game) restores the playfield and redraws the rest.
    public func applyLampSprites(_ drawn: [UInt8]) {
        let n = min(drawn.count, lampShown.count)
        let back = (0..<n).contains { drawn[$0] == 0 && lampShown[$0] != nil }
        if back {
            let f = flipperShown, p = plungerShown
            reset()
            for k in 0..<n where drawn[k] != 0 { blitLamp(k, a: drawn[k] == 1) }
            for (i, fr) in f { setFlipper(i, frame: fr, force: true) }
            if let p { plungerShown = nil; setPlunger(y: p) }
            return
        }
        for k in 0..<n where drawn[k] != 0 && lampShown[k] != (drawn[k] == 1) { blitLamp(k, a: drawn[k] == 1) }
    }

    private func blitLamp(_ k: Int, a: Bool) {
        lampShown[k] = a
        if let s = a ? graphics.lampA[k] : graphics.lampB[k], Self.blitterAccepts(s) { blit(s) }
    }

    /// blit_list refuses records with w4 > 30 or h > 100 (cs:472F).
    static func blitterAccepts(_ s: IndexedSprite) -> Bool { s.w / 4 <= 30 && s.h <= 100 }

    public func setFlipper(_ index: Int, frame: Int, force: Bool = false) {
        guard index >= 0, index < flipperFrames.count, let frames = flipperFrames[index] else { return }
        let f = max(0, min(frames.count - 1, frame))
        if !force, flipperShown[index] == f { return }
        flipperShown[index] = f
        blit(frames[f])
    }

    /// Plunger at row `y` (draw_plunger: rows stop at 399, both pages). nil = leave as is.
    ///
    /// The original redraws it every frame while the charge grows (cs:0B71, y rises by 0 or
    /// 1 row per frame), each draw covering the previous one; a jump of several rows (e.g. a
    /// snapshot or a dropped frame) is replayed row by row so no stale rows stay above it.
    /// Release draws once at the base row (cs:0B9F).
    public func setPlunger(y: Int?) {
        guard let y, let p = graphics.plunger, y != plungerShown else { return }
        let from = plungerShown ?? spec.plungerBaseY
        if y > from {
            for yy in (from + 1)...y { blit(p, y: yy, clipBottom: height) }
        } else {
            blit(p, y: y, clipBottom: height)
        }
        plungerShown = y
    }

    // MARK: strip

    struct StripKey: Equatable {
        var score: UInt32, ball: Int, player: Int, tilted: Bool, paused: Bool, dots: [Int], colours: [UInt8]
    }

    /// All dots of a message (main text in DAC 255, appended lines in their colour).
    func messageDots(_ m: DotMessage) -> (dots: [Int], colours: [UInt8]) {
        var d = DotText.dots(m, font8: graphics.font8, font5: graphics.font5, font5b: graphics.font5b)
        let main = spec.messagesInStrip ? (m.colour ?? spec.messageDotColour) : 255
        var c = [UInt8](repeating: main, count: d.count)
        // Appended lines only exist while the list does (draw_text checks [50Ch] != 0).
        if !d.isEmpty {
            for line in m.appended {
                let ld = DotText.lineDots(line, font8: graphics.font8, font5: graphics.font5)
                d += ld; c += [UInt8](repeating: line.colour, count: ld.count)
            }
        }
        return (d, c)
    }

    /// Strip font8 text (cs:5A34): 7 glyph rows, cell 0-39 on row 2, 40-79 on row 10, pixel i
    /// of a cell set when glyph bit (7-i) is set; only set pixels are written.
    func stripText(_ bytes: [UInt8], cell startCell: Int, colour: UInt8) {
        var cell = startCell
        for ch in bytes {
            if ch == 0 { break }
            var g = Int(ch &- 0x20)
            if g >= 0x80 { g = 0 }
            let row0 = cell < 40 ? 2 : 10
            let x0 = (cell < 40 ? cell : cell - 40) * 8
            if g < graphics.font8.count {
                let glyph = graphics.font8[g]
                for r in 0..<min(7, glyph.count) {
                    let y = row0 + r
                    guard y < Self.stripBufferRows else { continue }
                    for i in 0..<8 where glyph[r] & (0x80 >> i) != 0 {
                        let x = x0 + i
                        if x >= 0 && x < width { strip[y * width + x] = colour }
                    }
                }
            }
            cell += 1
        }
    }

    func stripBlit(_ s: IndexedSprite, x: Int, y: Int) {
        for r in 0..<s.h {
            let ty = y + r
            guard ty >= 0, ty < Self.stripBufferRows else { continue }
            for c in 0..<s.w {
                let tx = x + c
                if tx >= 0 && tx < width { strip[ty * width + tx] = s.pixels[r * s.w + c] }
            }
        }
    }

    /// Text of a DS string with its patched digit (first byte = colour for the strip routine).
    func idleString(_ ref: StripSpec.TextRef, digit: Int, digitRef: Int, hasColourByte: Bool) -> (colour: UInt8, text: [UInt8])? {
        guard let exe else { return nil }
        let off = exe.fileOffset(segment: graphics.dataSegment, offset: ref.ds)
        var bytes = exe.cString(at: off, max: 40)
        guard !bytes.isEmpty else { return nil }
        let di = digitRef - ref.ds
        if di >= 0, di < bytes.count { bytes[di] = UInt8(0x30 + max(0, min(9, digit))) }
        return hasColourByte ? (bytes[0], Array(bytes.dropFirst())) : (ref.dotColour ?? 255, bytes)
    }

    /// Rebuilds the strip. Returns true if it changed.
    @discardableResult
    public func buildStrip(score: UInt32, ball: Int, player: Int, tilted: Bool, paused: Bool, message: DotMessage?) -> Bool {
        let dmd = spec.messagesInStrip
        var dots: [Int] = []
        var colours: [UInt8] = []
        if dmd {
            if let m = message {
                (dots, colours) = messageDots(m)
            } else if !tilted, let ref = spec.ballText, let pref = spec.playerText, let ax = ref.ax,
                      var s = idleString(ref, digit: ball, digitRef: ref.digitDS, hasColourByte: false) {
                // EP9-13 idle display (EP10 cs:3449-348F): the ball/player string in the small dot
                // font, then the score appended as font8 dots.
                let pd = pref.digitDS - ref.ds
                if pd >= 0, pd < s.text.count { s.text[pd] = UInt8(0x30 + max(0, min(9, player))) }
                var m = DotMessage(text: s.text, ax: ax, di: ref.cell)
                if let sdi = spec.scoreDotDI {
                    let digits = Array(String(score).utf8.suffix(10))
                    let text = [UInt8](repeating: 0x20, count: 11 - digits.count) + digits
                    m.appended = [DotLine(text: text, font8: true, di: sdi, colour: spec.scoreDotColour)]
                }
                (dots, colours) = messageDots(m)
                let n = DotText.dots(DotMessage(text: s.text, ax: ax, di: ref.cell), font8: graphics.font8,
                                     font5: graphics.font5, font5b: graphics.font5b).count
                for i in 0..<min(n, colours.count) { colours[i] = s.colour }
            }
        }
        let key = StripKey(score: score, ball: ball, player: player, tilted: tilted, paused: paused, dots: dots, colours: colours)
        if key == lastStripKey { return false }
        lastStripKey = key
        stripDirty = true

        // draw_status_panel: row 0 border, then fill (18 rows in EP1-8; the rest of the buffer too).
        for x in 0..<width { strip[x] = spec.border }
        for i in width..<strip.count { strip[i] = spec.fill }
        // dmd_clear: rows 1..clearRows, x < clearWidth (EP9-13: the whole dot strip).
        if spec.clearRows > 0 {
            for y in 1...min(spec.clearRows, Self.stripBufferRows - 1) {
                for x in 0..<min(width, spec.clearWidth) { strip[y * width + x] = spec.clearColour }
            }
        }

        if dmd {
            for (i, d) in dots.enumerated() {
                let y = d / width, x = d % width
                if d >= 0, y < Self.stripBufferRows { strip[y * width + x] = colours[i] }
            }
        } else if !tilted {
            // dmd_idle_text: the ball-number and player-number strings, digits patched in as the code does.
            if let ref = spec.ballText, let s = idleString(ref, digit: ball, digitRef: ref.digitDS, hasColourByte: true) {
                stripText(s.text, cell: ref.cell, colour: s.colour)
            }
            if let ref = spec.playerText, let s = idleString(ref, digit: player, digitRef: ref.digitDS, hasColourByte: true) {
                stripText(s.text, cell: ref.cell, colour: s.colour)
            }
        }
        // Score (cs:5AD8 + cs:5371): 10 cells, leading zeros blank, last digit always drawn
        // (EP5 draws only the last 6 characters).
        if graphics.digits.count == 11 {
            let text = String(score)
            let all = Array(repeating: Character(" "), count: max(0, 10 - text.count)) + Array(text.suffix(10))
            let cells = Array(all.suffix(spec.scoreCells))
            for (i, ch) in cells.enumerated() {
                let d = ch.wholeNumberValue ?? 10
                let pos = min(spec.scoreFirstPos + i, 20)
                stripBlit(graphics.digits[d], x: spec.digitX0 + 12 * pos, y: spec.digitY)
            }
        }
        if paused, let p = graphics.pause { stripBlit(p, x: graphics.pausePosition.x, y: graphics.pausePosition.y) }
        return true
    }

    // MARK: window dot messages

    /// Rebuilds the window overlay (EP1-8 only; EP9-13 messages go to the strip).
    /// Returns true if it changed.
    @discardableResult
    public func buildOverlay(message: DotMessage?) -> Bool {
        var dots: [Int] = []
        if let m = message, !spec.messagesInStrip { dots = messageDots(m).dots }
        if dots == lastOverlayKey { return false }
        for d in lastOverlayKey where d >= 0 && d < overlay.count { overlay[d] = 0 }
        for d in dots where d >= 0 && d < overlay.count { overlay[d] = 255 }
        lastOverlayKey = dots
        overlayDirty = true
        return true
    }

    /// DAC 255 as dmd_message sets it (6-bit -> 8-bit like the VGA DAC read-back).
    public var messageColour: Palette.RGB {
        func c(_ v: UInt8) -> UInt8 { let x = min(v, 63); return x << 2 | x >> 4 }
        return Palette.RGB(r: c(spec.messageRGB6.0), g: c(spec.messageRGB6.1), b: c(spec.messageRGB6.2))
    }
}
