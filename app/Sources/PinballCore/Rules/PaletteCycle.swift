import Foundation

/// A main-loop palette rotation (EP8 ENIGMA, cs:1281), found by its code shape in the user's EXE:
///
///     pusha; inc byte [C]; mov al,[C]; cmp al,[S]; jb done; mov byte [C],0
///     mov di,0; mov al,I; (mov dx,3C8h; out dx,al; inc dx; push ax; mov al,[di+X]; out dx,al
///       mov al,[di+X+1]; out dx,al; mov al,[di+X+2]; out dx,al; pop ax; inc al; add di,3
///       cmp di,E; jne loop)
///     mov ax,[X+E-3]; mov [T],ax; mov al,[X+E-1]; mov [T+2],al
///     std; ... rep movsb (shift X..X+E-4 up by 3 bytes); cld; mov ax,[T]; mov [X],ax; mov al,[T+2]; mov [X+2],al
///
/// Every call counts C up; when it reaches the speed byte S (set by the rules: EP8 writes 1..3 per
/// level, cs:2329/262B/2AF4; 4 at boot) it resets C, writes the E/3 colours at X (6-bit DAC values,
/// the working palette's entries I...) to the DAC starting at index I, then rotates them by one colour.
/// X is inside the 768-byte working palette W (X = W + 3*I) that the boot fade-in (`lea di,[W];
/// mov cx,300h; mov al,0; rep stosb; lea si,[B]`) fills from the base palette B (>> 2), and cs:3613
/// reloads the ring from a per-level colour set (a lifted `call`). The main loop calls the routine
/// once per frame (EP8 cs:0843); the frame-wait routine (EP8 cs:0240: `push ds; pusha; call cycle;
/// ...; vsync wait`) calls it too, which rule code uses as a delay. [H] for the code shape. The boot's
/// fade-in and intro scroll call the frame wait too, so the ring after boot is a rotated, partly faded-in
/// ring, not base >> 2: `RulesRuntime.boot` takes it from `ScreenFade.boot` (checked against the harness,
/// ScreenFadeTests); `bootRing` is the fallback where the fade routines are not found.
public struct PaletteCycle: Sendable, Equatable {
    public var routine: Int
    /// The frame-wait routine that starts with a call to `routine` (nil if none).
    public var waitRoutine: Int?
    /// Near-call sites of `routine` outside `waitRoutine` (the main loop's per-frame call).
    public var callSites: [Int]
    public var counter: Int, speed: Int
    public var firstIndex: Int
    public var ring: Int, ringBytes: Int
    public var temp: Int
    /// Working palette (6-bit) and base palette (8-bit) DS offsets, from the fade routine.
    public var working: Int?, base: Int?

    public var colours: Int { ringBytes / 3 }

    /// Scans a 64 KB code segment.
    public static func find(code c: [UInt8]) -> PaletteCycle? {
        func b(_ i: Int) -> Int { Int(c[i & 0xFFFF]) }
        func w(_ i: Int) -> Int { b(i) | b(i + 1) << 8 }
        for p in 0..<0xFF80 where c[p] == 0x60 && c[p + 1] == 0xFE && c[p + 2] == 0x06 {
            let cnt = w(p + 3)
            guard b(p + 5) == 0xA0, w(p + 6) == cnt, b(p + 8) == 0x3A, b(p + 9) == 0x06, b(p + 12) == 0x72,
                  b(p + 14) == 0xC6, b(p + 15) == 0x06, w(p + 16) == cnt, b(p + 18) == 0,
                  b(p + 19) == 0xBF, w(p + 20) == 0, b(p + 22) == 0xB0,
                  b(p + 24) == 0xBA, w(p + 25) == 0x3C8, b(p + 27) == 0xEE, b(p + 28) == 0x42, b(p + 29) == 0x50,
                  b(p + 30) == 0x8A, b(p + 31) == 0x85 else { continue }
            let speed = w(p + 10), first = b(p + 23), x = w(p + 32)
            // mov al,[di+X+1]; out; mov al,[di+X+2]; out; pop ax; inc al; add di,3; cmp di,E; jne
            guard b(p + 34) == 0xEE, b(p + 35) == 0x8A, b(p + 36) == 0x85, w(p + 37) == x + 1, b(p + 39) == 0xEE,
                  b(p + 40) == 0x8A, b(p + 41) == 0x85, w(p + 42) == x + 2, b(p + 44) == 0xEE, b(p + 45) == 0x58,
                  b(p + 46) == 0xFE, b(p + 47) == 0xC0, b(p + 48) == 0x83, b(p + 49) == 0xC7, b(p + 50) == 0x03,
                  b(p + 51) == 0x81, b(p + 52) == 0xFF, b(p + 55) == 0x75 else { continue }
            let e = w(p + 53)
            guard e > 3, e % 3 == 0 else { continue }
            // mov ax,[X+E-3]; mov [T],ax; mov al,[X+E-1]; mov [T+2],al; std
            let q = p + 57
            guard b(q) == 0xA1, w(q + 1) == x + e - 3, b(q + 3) == 0xA3, b(q + 6) == 0xA0, w(q + 7) == x + e - 1,
                  b(q + 9) == 0xA2 else { continue }
            let t = w(q + 4)
            guard w(q + 10) == t + 2, b(q + 12) == 0xFD else { continue }
            // rep movsb, cld, then the saved colour stored at X (checked, not interpreted)
            var tail = false
            for r in (q + 13)..<(q + 40) where b(r) == 0xF3 && b(r + 1) == 0xA4 && b(r + 2) == 0xFC
                && b(r + 3) == 0xA1 && w(r + 4) == t && b(r + 6) == 0xA3 && w(r + 7) == x {
                tail = true; break
            }
            guard tail else { continue }
            var cyc = PaletteCycle(routine: p, waitRoutine: nil, callSites: [], counter: cnt, speed: speed, firstIndex: first,
                                   ring: x, ringBytes: e, temp: t, working: nil, base: nil)
            // callers: `call routine`; a routine starting `push ds; pusha; call routine` is the frame wait
            for s in 0..<0xFFF0 where c[s] == 0xE8 && ((s + 3 + w(s + 1)) & 0xFFFF) == p {
                if s >= 2, c[s - 2] == 0x1E, c[s - 1] == 0x60 { cyc.waitRoutine = s - 2 } else { cyc.callSites.append(s) }
            }
            // fade routine: lea di,[W]; mov cx,300h; mov al,0; rep stosb; lea si,[B]
            for f in 0..<0xFFF0 where c[f] == 0x8D && c[f + 1] == 0x3E && b(f + 4) == 0xB9 && w(f + 5) == 0x300
                && b(f + 7) == 0xB0 && b(f + 8) == 0 && b(f + 9) == 0xF3 && b(f + 10) == 0xAA && b(f + 11) == 0x8D && b(f + 12) == 0x36 {
                let wk = w(f + 2)
                if wk + 3 * first == x { cyc.working = wk; cyc.base = w(f + 13); break }
            }
            return cyc
        }
        return nil
    }

    /// The ring as base palette entries >> 2 (fallback; the boot's real end state is `ScreenFade.boot`).
    func bootRing(_ m: RulesMachine) {
        guard let bp = base else { return }
        for k in 0..<ringBytes { m.write8(ring + k, m.read8(bp + 3 * firstIndex + k) >> 2) }
    }

    /// One call of the routine. Returns the DAC values written (6-bit, `ringBytes` bytes) or nil.
    func step(_ m: RulesMachine) -> [UInt8]? {
        let n = m.read8(counter) &+ 1
        m.write8(counter, n)
        guard n >= m.read8(speed) else { return nil }
        m.write8(counter, 0)
        let dac = (0..<ringBytes).map { m.read8(ring + $0) }
        // save the last colour, shift the rest up by one colour (std; rep movsb), put it first
        m.write(temp, 2, Int64(m.read(ring + ringBytes - 3, 2)))
        m.write8(temp + 2, m.read8(ring + ringBytes - 1))
        for k in stride(from: ringBytes - 1, through: 3, by: -1) { m.write8(ring + k, m.read8(ring + k - 3)) }
        m.write(ring, 2, Int64(m.read(temp, 2)))
        m.write8(ring + 2, m.read8(temp + 2))
        return dac
    }
}
