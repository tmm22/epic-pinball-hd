import Foundation

/// The original's visible whole-screen palette fades, found by their code shapes in the user's EXE (EP1
/// addresses; every table has the same routines at other addresses):
///
/// * **Boot fade-in, EP1-EP8** (cs:1301, called once from init cs:0421 with the display start at row 0): W
///   (ds:5012, 6-bit) = 0, then `fadeInPasses` (17; EP7 15) passes of `if W < B>>2: W += ((B>>2 - W) >> 3) + 1`
///   over all 768 components of the base palette B (ds:0DC0), each pass written to DAC 0..255 and followed by
///   one `wait_frame` (cs:0249). Then the intro scroll (cs:0479: display start 80*k for k = 1...177, one
///   wait_frame each) runs with that palette.
/// * **Intro fade-in, EP9-EP13** (EP10 cs:12B6, called from the intro scroll loop cs:0478 before each
///   wait_frame): while the intro frame counter ds:4843 is below 22h, one pass with `>> 4` (W = ds:09FA); the
///   scroll starts at row 1 (display start 50h) and runs 182 frames. 32 of the 34 passes change W; it ends at
///   exactly B >> 2.
/// * **Fade-out** (EP1 cs:136F, called only by the quit path cs:14FA): 18 passes (`cmp ch,12h`) of
///   `if W: W -= (W >> 3) + 1` over DAC entries 0 ..< n, n = ds:0AD3 (0 = all 256), each followed by a
///   wait_frame. ds:0AD3 is 0 in the EXE; the end of game stores FFh (cs:3524: entry 255, the message colour,
///   is left alone). EP1-EP8: after the 5th pass (`cmp ch,4`), with ds:0AD2 = 1 (stored at the end of game,
///   cs:351F) and not in demo mode, the final-score screen cs:3832 runs, then the remaining 13 passes. Then
///   the game exits to the launcher. The quit path runs at the end of a game (cs:3529, pause_menu with
///   DI = 3039h goes straight to it), from the quit prompt (Esc; Y), and in demo mode on any key.
/// * EP8 only: wait_frame (cs:0240) first calls the palette rotation (`PaletteCycle`, cs:1281), which writes
///   DAC A0h..DFh from W's ring and rotates the ring inside W; the intro loop calls it once more per frame
///   (cs:0435). So the ring entries move during every fade and the boot leaves W's ring rotated, not B >> 2.
///
/// The P pause does not fade (EP1 cs:0DCB: dmd_clear, the PAUSED picture cs:49DE, wait for a key) and neither
/// does the quit prompt itself (pause_menu cs:13DD shows a dot message and waits); cs:1301 is called by init only.
/// [H] verified by running the original (tools/emu/screen_fades.py, `ScreenFadeTests`) on all 13 tables: the DAC
/// at every wait_frame of the boot equals `boot(ds:)` (except DAC 255, which the boot's dmd_message sets after the
/// fade, and EP3/EP5's colour-lamp entries B0h..BFh, which lamp_update writes), W after the boot and EP8's
/// rotation counter; every pass of the fade-out with n = 0 and n = FFh equals `fadeOut`.
public struct ScreenFade: Sendable, Equatable {
    public var base: Int, working: Int
    public var fadeInPasses: Int, fadeInShift: Int
    /// EP9-EP13: the passes run inside the intro scroll, one per intro frame (else before it, EP1-EP8).
    public var fadeInDuringIntro: Bool
    /// Frames of the intro scroll loop (177 EP1-EP8, 182 EP9-EP13).
    public var introFrames: Int
    /// EP7: init darkens B in place before the fade-in (`PaletteFade.darkenShift`).
    public var darkenShift: Int?
    public var fadeOutPasses: Int
    /// DS byte with the fade-out's entry count (0 = 256) and its value in the EXE.
    public var fadeOutCount: Int
    public var fadeOutCountInitial: Int
    /// EP1-EP8: passes done before the final-score screen (5), nil if the fade-out has no such call.
    public var scoreScreenPass: Int?
    /// EP8's palette rotation, run by every wait_frame; `introRingCalls` per intro frame (2 in EP8).
    public var cycle: PaletteCycle?
    public var introRingCalls: Int = 0

    /// The 6-bit palette state the fades work on: W, the DAC and EP8's rotation counter / speed.
    public struct Machine: Sendable, Equatable {
        public var working: [UInt8]
        public var dac: [UInt8]
        public var counter: UInt8
        public var speed: UInt8
        public init(working: [UInt8], dac: [UInt8], counter: UInt8 = 0, speed: UInt8 = 0) {
            self.working = working; self.dac = dac; self.counter = counter; self.speed = speed
        }
    }

    /// The boot: the DAC shown in each frame of the fade-in (EP1-EP8 the passes before the scroll; EP9-EP13
    /// the first `fadeInPasses` intro frames) and the state when the boot reaches the main loop.
    public struct Boot: Sendable, Equatable {
        public var frames: [[UInt8]]
        public var end: Machine
    }

    // MARK: finding

    /// From a whole EXE file (nil if it does not parse or the routines are not there).
    public static func find(exe: [UInt8]) -> ScreenFade? {
        guard let img = try? ExeImage(exe: exe) else { return nil }
        return find(code: img.code, ds: img.dsBytes)
    }

    /// Scans a 64 KB code segment; `ds` is the data segment as in the EXE (for the count's initial value).
    public static func find(code c: [UInt8], ds: [UInt8]) -> ScreenFade? {
        func b(_ i: Int) -> Int { Int(c[i & 0xFFFF]) }
        func w(_ i: Int) -> Int { b(i) | b(i + 1) << 8 }
        func match(_ p: Int, _ pat: [Int?]) -> Bool {
            for (k, v) in pat.enumerated() where v != nil && b(p + k) != v! { return false }
            return true
        }
        func all(_ pat: [Int?], in r: Range<Int> = 0..<0xFFC0) -> [Int] { r.filter { match($0, pat) } }
        func near(_ p: Int) -> Int { (p + 3 + w(p + 1)) & 0xFFFF }

        // Fade-out: mov al,0; mov cx,0; mov di,0; mov ah,[di+W]; cmp ah,0; je +9; shr ah,3; inc ah; sub [di+W],ah
        // ... inc al; cmp al,[N]; jne; ...; call wait; [cmp ch,4; jne; cmp byte [F],1; ...; call score]; inc ch; cmp ch,P
        var out: ScreenFade?
        for f in all([0xB0, 0x00, 0xB9, 0x00, 0x00, 0xBF, 0x00, 0x00, 0x8A, 0xA5, nil, nil, 0x80, 0xFC, 0x00, 0x74, 0x09,
                      0xC0, 0xEC, 0x03, 0xFE, 0xC4, 0x28, 0xA5]) {
            guard let n = all([0xFE, 0xC0, 0x3A, 0x06], in: f..<(f + 0x40)).first,
                  let e = all([0xFE, 0xC5, 0x80, 0xFD, nil, 0x75], in: n..<(n + 0x40)).first,
                  let call = all([0xE8], in: (n + 6)..<e).first else { continue }
            let count = w(n + 4)
            let score = all([0x80, 0xFD, 0x04, 0x75], in: call..<e).isEmpty ? nil : 5
            out = ScreenFade(base: 0, working: w(f + 10), fadeInPasses: 0, fadeInShift: 3, fadeInDuringIntro: false,
                             introFrames: 0, darkenShift: nil, fadeOutPasses: b(e + 4), fadeOutCount: count,
                             fadeOutCountInitial: count < ds.count ? Int(ds[count]) : 0, scoreScreenPass: score)
            break
        }
        guard var sf = out else { return nil }
        // Intro scroll: add ax,50h; cmp ax,END; jae; push ax; call far display_start ...
        guard let loop = all([0x05, 0x50, 0x00, 0x3D, nil, nil, 0x73, nil, 0x50, 0x9A]).first else { return nil }
        let end = w(loop + 4)
        sf.introFrames = (end + 0x4F) / 0x50 - 1
        if let pf = PaletteFade.find(code: c), pf.working == sf.working {
            // EP1-EP8: init's fade-in routine
            sf.base = pf.base
            sf.fadeInPasses = pf.fadeInPasses
            sf.darkenShift = pf.darkenShift
            sf.fadeInDuringIntro = false
        } else {
            // EP9-EP13: cmp word [cnt],N; jae; pusha; mov ax,ds; mov es,ax; lea si,[B] ... shr ah,S ... [di+W]
            let wl = sf.working & 0xFF, wh = sf.working >> 8
            guard let p = all([0x83, 0x3E, nil, nil, nil, 0x73, nil, 0x60, 0x8C, 0xD8, 0x8E, 0xC0, 0x8D, 0x36]).first,
                  let s = all([0x2A, 0xA5, wl, wh, 0xC0, 0xEC, nil, 0xFE, 0xC4, 0x00, 0xA5, wl, wh], in: p..<(p + 0x40)).first
            else { return nil }
            sf.base = w(p + 14)
            sf.fadeInPasses = b(p + 4)
            sf.fadeInShift = b(s + 6)
            sf.fadeInDuringIntro = true
        }
        if let cyc = PaletteCycle.find(code: c), cyc.working == sf.working {
            sf.cycle = cyc
            // the loop body up to its jump back: calls of the rotation or of wait_frame (which calls it first)
            let back = (loop..<(loop + 0x60)).first { b($0) == 0xEB && (($0 + 2 + Int(Int8(bitPattern: UInt8(b($0 + 1))))) & 0xFFFF) == loop }
            if let back {
                sf.introRingCalls = (loop..<back).filter { b($0) == 0xE8 && (near($0) == cyc.routine || near($0) == cyc.waitRoutine) }.count
            }
        }
        return sf
    }

    // MARK: running

    /// The base palette as the running game has it (EP7's darkening applied to the EXE's bytes).
    public func runtimeBase(_ exe: [UInt8]) -> [UInt8] {
        guard let s = darkenShift else { return exe }
        return exe.map { $0 &- ($0 >> UInt8(s)) }
    }

    /// One wait_frame: EP8's rotation (counter up to the speed byte, then DAC A0h.. from W's ring, ring rotated).
    public func waitFrame(_ m: inout Machine) {
        guard let cyc = cycle else { return }
        m.counter &+= 1
        guard m.counter >= m.speed else { return }
        m.counter = 0
        let r0 = cyc.ring - working, n = cyc.ringBytes
        guard r0 >= 0, r0 + n <= 768 else { return }
        let first = 3 * cyc.firstIndex
        for k in 0..<n where first + k < 768 { m.dac[first + k] = m.working[r0 + k] }
        let ring = Array(m.working[r0..<(r0 + n)])
        m.working.replaceSubrange(r0..<(r0 + n), with: ring.suffix(3) + ring.dropLast(3))
    }

    /// One fade-in pass over all 768 components (written to the whole DAC).
    public func fadeInPass(_ m: inout Machine, base: [UInt8]) {
        let sh = UInt8(fadeInShift)
        for i in 0..<min(768, base.count) {
            let t = base[i] >> 2
            if m.working[i] < t { m.working[i] += ((t - m.working[i]) >> sh) + 1 }
        }
        m.dac = m.working
    }

    /// The boot from W = 0 (`ds` = the EXE's data segment: B, EP8's rotation counter and speed).
    public func boot(ds: [UInt8]) -> Boot {
        let b = runtimeBase(Array(ds[base..<min(ds.count, base + 768)]))
        var m = Machine(working: [UInt8](repeating: 0, count: 768), dac: [UInt8](repeating: 0, count: 768),
                        counter: cycle.map { ds[$0.counter] } ?? 0, speed: cycle.map { ds[$0.speed] } ?? 0)
        var frames: [[UInt8]] = []
        if !fadeInDuringIntro {
            for _ in 0..<fadeInPasses {
                fadeInPass(&m, base: b)
                waitFrame(&m)
                frames.append(m.dac)
            }
            for _ in 0..<introFrames { for _ in 0..<max(1, introRingCalls) { waitFrame(&m) } }
        } else {
            for k in 0..<introFrames {
                if k < fadeInPasses { fadeInPass(&m, base: b) }
                for _ in 0..<max(1, introRingCalls) { waitFrame(&m) }
                if k < fadeInPasses { frames.append(m.dac) }
            }
        }
        return Boot(frames: frames, end: m)
    }

    /// The fade-out passes `passes` (0-based, of `fadeOutPasses`) over DAC entries 0 ..< `count` (0 = 256):
    /// the DAC shown in each pass's frame. `m` is left after the last one.
    public func fadeOut(_ m: inout Machine, count: Int, passes: Range<Int>) -> [[UInt8]] {
        let n = count == 0 ? 256 : min(256, count)
        var frames: [[UInt8]] = []
        for _ in passes.clamped(to: 0..<fadeOutPasses) {
            for i in 0..<(3 * n) where m.working[i] != 0 {
                m.working[i] -= (m.working[i] >> 3) + 1
            }
            m.dac.replaceSubrange(0..<(3 * n), with: m.working[0..<(3 * n)])
            waitFrame(&m)
            frames.append(m.dac)
        }
        return frames
    }

    /// Passes the end-of-game fade-out runs before the final-score screen: 5 on EP1-EP8 (cs:13BC); 0 on
    /// EP9-EP13, whose final-score screen comes before pause_menu (EP10 cs:0533) and so before the fade.
    public var gameOverHoldPass: Int { scoreScreenPass ?? 0 }

    /// The end-of-game fade-out's entry count: FFh (EP1 cs:3524, EP10 cs:0527), DAC 255 stays.
    public static let gameOverCount = 0xFF
}

/// Plays the visible fades in the app, one DAC frame per original frame, on top of the rules' palette:
///
/// * `boot`: the boot fade-in from black (`ScreenFade.boot`), at every game start. The game waits for it
///   (`blocksPlay`), as the original's main loop starts after it (the intro scroll, which the port does
///   not show, is skipped).
/// * `gameOver`: the end-of-game fade-out from the palette on screen (count FFh), its first
///   `gameOverHoldPass` passes at once; the picture then stays at that palette while the port's
///   game-over panel is up (the original's final-score screen), and the next `boot` first runs the
///   remaining passes, as the original's quit path does before it exits and the next game boots.
///
/// The P pause and the port's Esc menu do not fade (the original's P pause has no fade, EP1 cs:0DCB).
public struct ScreenFadePlayer: Sendable {
    public let fade: ScreenFade
    /// The boot's DAC frames (6-bit, 768 each) and the state they leave (from the EXE's data segment).
    public let bootFrames: [[UInt8]]
    private var queue: [[PaletteOverride]] = []
    /// The game-over fade-out's machine and passes done (until the next boot finishes it).
    private var outMachine: ScreenFade.Machine?
    private var outPasses = 0
    /// Overrides of the frame on screen (nil: the rules' palette alone).
    public private(set) var current: [PaletteOverride]?
    /// Original frames played so far (tests).
    public private(set) var framesPlayed = 0
    /// A game-over fade-out is holding its palette (until the next `boot`).
    public var holding: Bool { outMachine != nil }

    public init(fade: ScreenFade, ds: [UInt8]) {
        self.fade = fade
        bootFrames = fade.boot(ds: ds).frames
    }

    /// Frames still queued.
    public var pending: Int { queue.count }
    /// The game must not run: frames are queued (the boot fade-in, or the end of a game-over fade-out).
    public var blocksPlay: Bool { !queue.isEmpty }

    /// A game starts: the rest of a game-over fade-out, then the boot fade-in.
    public mutating func boot() {
        queue.removeAll()   // a game started during a fade-in starts its own
        if var m = outMachine {
            queue += fade.fadeOut(&m, count: ScreenFade.gameOverCount, passes: outPasses..<fade.fadeOutPasses)
                .map { ScreenFade.overrides($0, count: ScreenFade.gameOverCount) }
            outMachine = nil
        }
        queue += bootFrames.map { ScreenFade.overrides($0) }
        step()   // the first frame is on screen at once (no frame of the old palette in between)
    }

    /// The rules reported game over with `start` on screen: the passes before the final-score screen.
    public mutating func gameOver(from start: ScreenFade.Machine) {
        var m = start
        outPasses = fade.gameOverHoldPass
        queue += fade.fadeOut(&m, count: ScreenFade.gameOverCount, passes: 0..<outPasses)
            .map { ScreenFade.overrides($0, count: ScreenFade.gameOverCount) }
        outMachine = m
        if outPasses > 0 { step() }
    }

    /// Drops everything (practice state loads, leaving the table).
    public mutating func cancel() {
        queue.removeAll()
        outMachine = nil
        current = nil
    }

    /// One original frame: the next queued frame goes on screen. After the queue, a game-over fade-out
    /// holds its last frame; otherwise the rules' palette is shown again.
    public mutating func step() {
        if !queue.isEmpty {
            current = queue.removeFirst()
            framesPlayed += 1
        } else if outMachine == nil {
            current = nil
        }
    }
}

extension ScreenFade {
    /// 6-bit DAC values as palette overrides for entries 0 ..< `count` (0 = all 256; 8-bit, widened like
    /// the DAC read-back).
    public static func overrides(_ dac: [UInt8], count: Int = 0) -> [PaletteOverride] {
        func c(_ v: UInt8) -> UInt8 { let x = v & 0x3F; return x << 2 | x >> 4 }
        let n = count == 0 ? 256 : min(256, count)
        return (0..<min(n, dac.count / 3)).map { i in
            PaletteOverride(index: UInt8(i), r: c(dac[3 * i]), g: c(dac[3 * i + 1]), b: c(dac[3 * i + 2]))
        }
    }
}
