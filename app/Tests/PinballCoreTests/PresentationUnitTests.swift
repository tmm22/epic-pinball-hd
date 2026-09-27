import Foundation
import XCTest
@testable import PinballCore
@testable import PinballRender

/// Presentation pieces on synthetic data only (made-up glyphs, records and code bytes; nothing
/// from the game): dmd_message dot geometry, the VRAM composer's lamp/plunger rules, the strip
/// layout scan, and the palette-rotation interpreter.
final class DotTextTests: XCTestCase {
    /// 96 glyphs; glyph `g` has only its top-left dot set (bit 7 of row 0) when `g` is marked.
    func font(rows: Int, marked: Set<Int>) -> [[UInt8]] {
        (0..<96).map { g in (0..<rows).map { r in r == 0 && marked.contains(g) ? 0x80 : 0 } }
    }
    let a = Int(UInt8(ascii: "A")) - 0x20

    func testCentringFont5AndFont8() {
        let f5 = font(rows: 5, marked: [a]), f8 = font(rows: 7, marked: [a])
        // AH=0 (font5, 11 px per char): di += (320 - 11) / 2 + 1 = 155
        XCTAssertEqual(DotText.dots(DotMessage(text: Array("A".utf8), ax: 0x0000, di: 0), font8: f8, font5: f5, font5b: []), [155])
        // AH=1 (font8, 16 px): (320 - 16) / 2 + 1 = 153; two chars: (320 - 32) / 2 + 1 = 145, second at +16
        XCTAssertEqual(DotText.dots(DotMessage(text: Array("A".utf8), ax: 0x0100, di: 0), font8: f8, font5: f5, font5b: []), [153])
        XCTAssertEqual(DotText.dots(DotMessage(text: Array("AA".utf8), ax: 0x0100, di: 640), font8: f8, font5: f5, font5b: []),
                       [640 + 145, 640 + 161])
    }

    func testNoCentringLowercaseFoldAndLimits() {
        let f5 = font(rows: 5, marked: [a]), f8 = font(rows: 7, marked: [a])
        // AH >= 3: no centring, font AH-3 (3 -> font5)
        XCTAssertEqual(DotText.dots(DotMessage(text: Array("a".utf8), ax: 0x0300, di: 7), font8: f8, font5: f5, font5b: []), [7])
        // longer than 30 characters: nothing is drawn (the length scan gives up)
        XCTAssertEqual(DotText.dots(DotMessage(text: [UInt8](repeating: 0x41, count: 31), ax: 0, di: 0), font8: f8, font5: f5, font5b: []), [])
        // AH=2 without a font5b (EP1-8: cs:5925 is a bare retf): nothing
        XCTAssertEqual(DotText.dots(DotMessage(text: Array("A".utf8), ax: 0x0200, di: 0), font8: f8, font5: f5, font5b: []), [])
        // too wide to centre (> 320 px): nothing
        XCTAssertEqual(DotText.dots(DotMessage(text: [UInt8](repeating: 0x41, count: 21), ax: 0x0100, di: 0), font8: f8, font5: f5, font5b: []), [])
    }

    func testDotGeometry() {
        // A glyph with every dot set: 2 px between columns, 2 rows (0x280) between rows, column-major order.
        var f5 = font(rows: 5, marked: [])
        f5[a] = [UInt8](repeating: 0xF8, count: 5)
        let d = DotText.lineDots(DotLine(text: Array("A".utf8), font8: false, di: 1000), font8: [], font5: f5)
        XCTAssertEqual(d.count, 25)
        XCTAssertEqual(Array(d.prefix(6)), [1000, 1000 + 0x280, 1000 + 2 * 0x280, 1000 + 3 * 0x280, 1000 + 4 * 0x280, 1002])
        XCTAssertEqual(d.last, 1000 + 8 + 4 * 0x280)
    }
}

final class ClassicComposerTests: XCTestCase {
    func sprite(_ name: String, x: Int, y: Int, w: Int, h: Int, colour: UInt8) -> IndexedSprite {
        IndexedSprite(name: name, x: x, y: y, w: w, h: h, pixels: [UInt8](repeating: colour, count: w * h))
    }

    func composer(lampA: [IndexedSprite?], lampB: [IndexedSprite?], plunger: IndexedSprite? = nil) -> ClassicComposer {
        let g = GameGraphics(lampA: lampA, lampB: lampB, lampRestIsA: lampA.map { _ in true }, byName: [:], digits: [],
                             pause: nil, pausePosition: (0, 0), plunger: plunger, font8: [], font5: [], font5b: [],
                             displayRows: nil, codeSegment: 0, dataSegment: 0, table: 1, source: "test", warnings: [])
        var pf = [UInt8](repeating: 3, count: TableGeometry.width * TableGeometry.height)
        pf[0] = 4
        return ClassicComposer(graphics: g, spec: StripSpec(), exe: nil, playfield: pf)
    }

    func px(_ c: ClassicComposer, _ x: Int, _ y: Int) -> UInt8 { c.vram[y * TableGeometry.width + x] }

    func testLampSpritesAandBAndBackToPlayfield() {
        let c = composer(lampA: [sprite("l0a", x: 8, y: 10, w: 4, h: 2, colour: 7)],
                         lampB: [sprite("l0b", x: 8, y: 10, w: 4, h: 2, colour: 9)])
        c.applyLampSprites([0])
        XCTAssertEqual(px(c, 8, 10), 3, "0 = not drawn: the playfield shows")
        c.applyLampSprites([1])
        XCTAssertEqual(px(c, 8, 10), 7)
        XCTAssertEqual(px(c, 11, 11), 7)
        XCTAssertEqual(px(c, 12, 11), 3, "opaque rectangle, nothing outside it")
        c.applyLampSprites([2])
        XCTAssertEqual(px(c, 9, 10), 9)
        c.applyLampSprites([0])
        XCTAssertEqual(px(c, 9, 10), 3, "a slot going back to 0 restores the playfield")
        XCTAssertEqual(px(c, 0, 0), 4)
    }

    func testBlitterRejectsWideOrTallRecords() {
        let c = composer(lampA: [sprite("wide", x: 0, y: 20, w: 124, h: 1, colour: 7), sprite("tall", x: 0, y: 30, w: 4, h: 101, colour: 8)],
                         lampB: [nil, nil])
        c.applyLampSprites([1, 1])
        XCTAssertEqual(px(c, 0, 20), 3, "w4 = 31 > 30: blit_list refuses it")
        XCTAssertEqual(px(c, 0, 30), 3, "h = 101 > 100: refused")
    }

    func testPlungerReplaysEveryRow() {
        let base = StripSpec().plungerBaseY
        let c = composer(lampA: [], lampB: [], plunger: sprite("plunger", x: 300, y: 0, w: 4, h: 1, colour: 5))
        c.setPlunger(y: base + 3)
        // a jump of 3 rows is replayed row by row (the original redraws every frame): rows base+1..base+3
        for y in (base + 1)...(base + 3) { XCTAssertEqual(px(c, 300, y), 5, "row \(y)") }
        XCTAssertEqual(px(c, 300, base), 3)
        XCTAssertEqual(px(c, 300, base + 4), 3)
    }
}

final class StripSpecScanTests: XCTestCase {
    func testScanFindsSignaturesAndReportsFallbacks() {
        var code = [UInt8](repeating: 0x90, count: 0x10000)
        func put(_ at: Int, _ b: [UInt8]) { for (i, v) in b.enumerated() { code[at + i] = v } }
        // set_split_line clamp: cmp ax,441; jae +3; mov ax,441; mov dx,3D4h  -> 221 window rows
        put(0x100, [0x3D, 0xB9, 0x01, 0x73, 0x03, 0xB8, 0xB9, 0x01, 0xBA, 0xD4, 0x03])
        // mov bl,border; mov bh,fill; call far
        put(0x200, [0xB3, 0x11, 0xB7, 0x22, 0x9A])
        // dmd_clear: mov al,0Fh; out; mov al,colour; mov di,50h; mov ah,rows; push di; mov cx,words
        put(0x300, [0xB0, 0x0F, 0xEE, 0xB0, 0x33, 0xBF, 0x50, 0x00, 0xB4, 0x12, 0x57, 0xB9, 0x31, 0x00])
        // plunger: shr ax,5; add ax,base; call far
        put(0x400, [0xC1, 0xE8, 0x05, 0x05, 0x70, 0x01, 0x9A])
        let s = StripSpec.scan(exe: TableExe(bytes: code), codeSegment: 0, dataSegment: 0, table: 1, displayRows: nil)
        XCTAssertEqual(s.windowRows, 221)
        XCTAssertEqual(s.border, 0x11); XCTAssertEqual(s.fill, 0x22)
        XCTAssertEqual(s.clearColour, 0x33); XCTAssertEqual(s.clearRows, 0x12); XCTAssertEqual(s.clearWidth, 0x31 * 4)
        XCTAssertEqual(s.plungerShift, 5); XCTAssertEqual(s.plungerBaseY, 0x170)
        XCTAssertFalse(s.fallbacks.contains("windowRows"))
        XCTAssertTrue(s.fallbacks.contains("camera"), "no camera_update in the synthetic code")
        XCTAssertTrue(s.messagesInStrip, "no window dot plotter: messages go to the strip")
    }

    func testEmptyCodeUsesDefaults() {
        let s = StripSpec.scan(exe: TableExe(bytes: [UInt8](repeating: 0, count: 0x10000)), codeSegment: 0, dataSegment: 0, table: 10, displayRows: nil)
        XCTAssertEqual(s.windowRows, 211, "EP9-13 default")
        XCTAssertEqual(s.stripRows, 30)
        XCTAssertTrue(s.fallbacks.contains("windowRows"))
    }
}

/// The EP8-style palette rotation (PaletteCycle), on a routine assembled with made-up addresses.
final class PaletteCycleTests: XCTestCase {
    static let counter = 0x500, speed = 0x501, first = 0x10, working = 0x5D0, base = 0x680, temp = 0x640
    static var ring: Int { working + 3 * first }   // 0x600
    static let bytes = 12                          // 4 colours

    static func le(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    static func code() -> [UInt8] {
        let c = le(counter), s = le(speed), x = ring, e = bytes, t = temp
        var r: [UInt8] = [0x60, 0xFE, 0x06] + c + [0xA0] + c + [0x3A, 0x06] + s + [0x72, 0x5A, 0xC6, 0x06] + c + [0x00,
                          0xBF, 0x00, 0x00, 0xB0, UInt8(first), 0xBA, 0xC8, 0x03, 0xEE, 0x42, 0x50,
                          0x8A, 0x85] + le(x) + [0xEE, 0x8A, 0x85] + le(x + 1) + [0xEE, 0x8A, 0x85] + le(x + 2) + [0xEE,
                          0x58, 0xFE, 0xC0, 0x83, 0xC7, 0x03, 0x81, 0xFF] + le(e) + [0x75, 0xDF]
        r += [0xA1] + le(x + e - 3) + [0xA3] + le(t) + [0xA0] + le(x + e - 1) + [0xA2] + le(t + 2) + [0xFD]
        r += [0x8C, 0xDE, 0x8E, 0xC6, 0x8D, 0x36] + le(x + e - 3) + [0x8D, 0x3E] + le(x + e - 3) + [0x4E, 0x83, 0xC7, 0x02,
              0xB9] + le(e - 3) + [0xF3, 0xA4, 0xFC, 0xA1] + le(t) + [0xA3] + le(x) + [0xA0] + le(t + 2) + [0xA2] + le(x + 2) + [0x61, 0xC3]
        return r
    }

    func program() throws -> (RulesRuntime, [UInt8]) {
        var code = Self.code()                                   // cs:0800 (fixture default)
        let routine = 0x0800
        // frame wait at cs:0880: push ds; pusha; call routine; ...
        let wait = 0x0880
        var tail = [UInt8](repeating: 0x90, count: 0x0880 - 0x0800 - code.count)
        code += tail
        let rel = (routine - (wait + 5)) & 0xFFFF
        code += [0x1E, 0x60, 0xE8] + Self.le(rel) + [0x61, 0x1F, 0xC3]
        // a main-loop call site at cs:0890
        tail = [UInt8](repeating: 0x90, count: 0x0890 - 0x0800 - code.count)
        code += tail
        code += [0xE8] + Self.le((routine - (0x0890 + 3)) & 0xFFFF)
        // fade: lea di,[W]; mov cx,300h; mov al,0; rep stosb; lea si,[B]
        code += [0x8D, 0x3E] + Self.le(Self.working) + [0xB9, 0x00, 0x03, 0xB0, 0x00, 0xF3, 0xAA, 0x8D, 0x36] + Self.le(Self.base)
        var exe = RulesFixture.exe(code: code)
        // base palette entries first..first+3 (8-bit, made up): 4 * (10 + k), ...
        for k in 0..<Self.bytes { exe[RulesFixture.dsFileOffset + Self.base + 3 * Self.first + k] = UInt8(4 * (10 + k)) }
        exe[RulesFixture.dsFileOffset + Self.speed] = 2
        let r = try RulesRuntime(program: try RulesFixture.program(), exe: exe)
        return (r, exe)
    }

    func testFindsTheRoutineItsWaitAndCallSites() throws {
        let (r, _) = try program()
        let pc = try XCTUnwrap(r.paletteCycle)
        XCTAssertEqual(pc.routine, 0x0800)
        XCTAssertEqual(pc.waitRoutine, 0x0880)
        XCTAssertEqual(pc.callSites, [0x0890])
        XCTAssertEqual(pc.counter, Self.counter); XCTAssertEqual(pc.speed, Self.speed)
        XCTAssertEqual(pc.firstIndex, Self.first); XCTAssertEqual(pc.ring, Self.ring); XCTAssertEqual(pc.colours, 4)
        XCTAssertEqual(pc.working, Self.working); XCTAssertEqual(pc.base, Self.base)
    }

    func testBootRingRotationAndOverrides() throws {
        let (r, _) = try program()
        r.boot()
        let m = r.machine
        // boot: ring = base >> 2 = 10, 11, 12, ...
        XCTAssertEqual((0..<Self.bytes).map { Int(m.read8(Self.ring + $0)) }, Array(10..<(10 + Self.bytes)))
        var s = PresentationState()
        r.takePresentation(into: &s)
        XCTAssertEqual(s.paletteOverrides, [], "no DAC write yet: the base palette is shown")
        r.paletteCycleStep()                       // counter 1 < speed 2: nothing
        XCTAssertEqual(m.read8(Self.counter), 1)
        XCTAssertEqual(m.read8(Self.ring), 10)
        r.paletteCycleStep()                       // counter 2 >= 2: DAC write, then rotate by one colour
        XCTAssertEqual(m.read8(Self.counter), 0)
        XCTAssertEqual((0..<Self.bytes).map { Int(m.read8(Self.ring + $0)) }, [19, 20, 21, 10, 11, 12, 13, 14, 15, 16, 17, 18])
        XCTAssertEqual(m.read(Self.temp, 2), Int64(19 | 20 << 8))
        r.takePresentation(into: &s)
        XCTAssertEqual(s.paletteOverrides.count, 4)
        // the DAC got the ring as it was before the rotation, 6-bit -> 8-bit
        XCTAssertEqual(s.paletteOverrides[0], PaletteOverride(index: UInt8(Self.first), r: 10 << 2 | 10 >> 4, g: 11 << 2, b: 12 << 2))
        XCTAssertEqual(s.paletteOverrides[3].index, UInt8(Self.first + 3))
    }
}
