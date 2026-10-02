import Foundation

/// The palette the original's fades leave in the VGA DAC, as a 6-bit working palette W (EP1
/// ds:5012) mirrored from its own code shapes (EP1 shown; EP2-EP8 have the same routines at other
/// addresses, found by signature):
///
/// * Boot fade-in (EP1 cs:1301, called from init cs:0421): `lea di,[W]; mov cx,300h; mov al,0;
///   rep stosb; lea si,[B]`, then N passes (`cmp ch,11h`, one `wait_frame` each) of
///   `if W < B>>2: W += ((B>>2 - W) >> 3) + 1` over all 768 components, each pass written to the DAC.
///   17 passes do not reach B>>2 for bright components (63 ends at 60): the game is played with this
///   palette until the first restore below. [H] verified by running the code: the harness's W after
///   boot equals the 17-pass result (125 of 768 components below B>>2), and every colour of the
///   DOSBox-X capture of ball 1 (scratch/present/frames f00600..f01740, 181 colours) is a W colour,
///   41 of them not in B>>2.
/// * Ball lost (ball_lost_fade EP1 cs:32E9..3333): `passes` (3) passes of `if W: W -= (W >> 3) + 1`
///   over all components, written to the DAC with no frame wait (an immediate dim), then
///   `mov byte [F],1` (F = ds:096F, the between-balls flag).
/// * Next plunger release while F = 1 (EP1 cs:0BD3..0C46): `lea si,[B]; lea di,[W]; mov cx,300h;
///   lodsb; shr al,2; stosb; loop` (W = B>>2), `mov byte [F],0`, and DAC 0..254 written from B>>2
///   (255 stays the message colour).
///
/// F is written only by those two places (checked by `find`), so the dim and the restore follow
/// its value in the rules' data segment. The visible fades (the boot fade-in frame by frame, EP9-EP13's
/// intro fade-in EP10 cs:12B6, the quit path's fade-out EP1 cs:136F) are `ScreenFade`. EP3, EP5 and EP8
/// have no ball-loss dim; EP9-13 are not matched here (they play with B >> 2).
public struct PaletteFade: Sendable, Equatable {
    /// DS offsets: base palette (8-bit, 768 bytes), working palette (6-bit), between-balls flag.
    public var base: Int, working: Int
    public var flag: Int?
    public var fadeInPasses: Int
    public var dimPasses: Int
    /// EP7 only: init darkens the base palette in place before the fade-in (cs:0311..0324:
    /// `lea si,[B]; mov cx,300h; mov al,[si]; mov ah,al; shr ah,2; sub al,ah; mov [si],al; inc si;
    /// loop`, B -= B >> 2), so the running game is a quarter darker than the palette stored in the EXE.
    /// [H] verified in the harness: B after boot equals this, and W the 15-pass fade-in of it.
    public var darkenShift: Int? = nil

    /// Scans a 64 KB code segment (nil if the boot fade-in is not there).
    public static func find(code c: [UInt8]) -> PaletteFade? {
        func b(_ i: Int) -> Int { Int(c[i & 0xFFFF]) }
        func w(_ i: Int) -> Int { b(i) | b(i + 1) << 8 }
        func match(_ p: Int, _ pat: [Int?]) -> Bool {
            for (k, v) in pat.enumerated() where v != nil && b(p + k) != v! { return false }
            return true
        }
        func all(_ pat: [Int?], in r: Range<Int> = 0..<0xFFC0) -> [Int] { r.filter { match($0, pat) } }
        // Boot fade-in: lea di,[W]; mov cx,300h; mov al,0; rep stosb; lea si,[B]; ... call wait; inc ch; cmp ch,N
        let fi = all([0x8D, 0x3E, nil, nil, 0xB9, 0x00, 0x03, 0xB0, 0x00, 0xF3, 0xAA, 0x8D, 0x36])
        guard fi.count == 1, let f = fi.first else { return nil }
        let working = w(f + 2), base = w(f + 13)
        guard let n = all([0xE8, nil, nil, 0xFE, 0xC5, 0x80, 0xFD], in: f..<(f + 0x80)).first else { return nil }
        var out = PaletteFade(base: base, working: working, flag: nil, fadeInPasses: b(n + 7), dimPasses: 0)
        let dk = all([0x8D, 0x36, base & 0xFF, base >> 8, 0xB9, 0x00, 0x03, 0x8A, 0x04, 0x8A, 0xE0, 0xC0, 0xEC, nil,
                      0x2A, 0xC4, 0x88, 0x04, 0x46, 0xE2, 0xF2])
        if dk.count == 1, let d = dk.first { out.darkenShift = b(d + 13) }
        // Ball-loss dim: mov ah,[di+W]; cmp ah,0; je +9; shr ah,3; inc ah; sub [di+W],ah ... inc ch;
        // cmp ch,P; jne; mov byte [F],1
        let wl = working & 0xFF, wh = working >> 8
        for d in all([0x8A, 0xA5, wl, wh, 0x80, 0xFC, 0x00, 0x74, 0x09, 0xC0, 0xEC, 0x03, 0xFE, 0xC4, 0x28, 0xA5, wl, wh]) {
            guard let e = all([0xFE, 0xC5, 0x80, 0xFD, nil, 0x75, nil, 0xC6, 0x06, nil, nil, 0x01], in: d..<(d + 0x60)).first else { continue }
            let flag = w(e + 9)
            // F must be set only here and cleared only next to a B -> W copy (the release restore).
            let fl = flag & 0xFF, fh = flag >> 8
            let sets = all([0xC6, 0x06, fl, fh, 0x01]), clears = all([0xC6, 0x06, fl, fh, 0x00])
            let copies = all([0x8D, 0x36, base & 0xFF, base >> 8, 0x8D, 0x3E, wl, wh, 0xB9, 0x00, 0x03])
            let others = all([0xC6, 0x06, fl, fh, nil]).filter { b($0 + 4) > 1 } + all([0xA2, fl, fh]) + all([0xFE, 0x06, fl, fh])
            guard sets == [e + 7], !clears.isEmpty, others.isEmpty,
                  clears.allSatisfy({ cl in copies.contains { abs($0 - cl) < 0x60 } }) else { continue }
            out.flag = flag
            out.dimPasses = b(e + 4)
            break
        }
        return out
    }

    /// The base palette as the running game has it (`darkenShift` applied to the EXE's bytes).
    public func runtimeBase(_ exe: [UInt8]) -> [UInt8] {
        guard let s = darkenShift else { return exe }
        return exe.map { $0 &- ($0 >> UInt8(s)) }
    }

    /// W after the boot fade-in, from the (runtime) base palette bytes (8-bit, 768).
    public func bootPalette(base pal: [UInt8]) -> [UInt8] {
        var w = [UInt8](repeating: 0, count: 768)
        for _ in 0..<fadeInPasses {
            for i in 0..<min(768, pal.count) {
                let t = pal[i] >> 2
                if w[i] < t { w[i] += ((t - w[i]) >> 3) + 1 }
            }
        }
        return w
    }

    /// One ball_lost_fade dim (all passes).
    public func dim(_ w: inout [UInt8]) {
        for _ in 0..<dimPasses {
            for i in w.indices where w[i] != 0 { w[i] -= (w[i] >> 3) + 1 }
        }
    }

    /// The release restore: W = B >> 2.
    public func restored(base pal: [UInt8]) -> [UInt8] { pal.prefix(768).map { $0 >> 2 } }
}
