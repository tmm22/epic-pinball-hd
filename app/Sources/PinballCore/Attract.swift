import Foundation

// The original's demo mode ("attract"): what a table EXE does when PINBALL.EXE starts it with
// players = 'D' (engine.md section 8). PINBALL.EXE does that when its menu sits idle for 900 frames
// (menu loop counter cs:[002E], file 0x843..0x85C, [M] for the frame rate) or when the menu's demo
// item is chosen (file 0x9B7); it passes 'D' for the first installed table (file 0x4EC7..0x4EEB).
// The table's entry code then sets demo_mode = 1 and one player (EP1 cs:007A..0086), and every
// demo branch tests that DS byte. EP1 addresses (cs 0x3223, ds 0x0015), read from the disassembly
// [H] and run in the Unicorn harness (tools/emu, players 'D' and full mode) [H]:
//
//   cs:0B44  plunger: demo counts as Ctrl held, so the charge grows 12/frame while ball 0 is in the
//            lane. cs:0B79 (EP1 only): once the charge is past 700 the demo takes the release path
//            (vy -= 708). EP2-EP13 have no such test: their demo holds the plunger forever and the
//            ball never leaves the lane (harness, 900 frames on every table).
//   cs:0C48  attract_autoflip, the whole block below, then `jmp 0E8A`: the key handling and
//            nudge/tilt code cs:0D1D..0E8A (Esc/P/T/Enter/split line, nudges) do not run in demo.
//     0C4F   flip timer ds:000B: counts down; at 0 both flipper keys (cs:028D/028F) are released.
//     0C6C   slots 0..2 (di < 6), active ones only:
//            stuck ball: x,y equal to the last frame's (ds:0018/0026 + 2*slot) -> ds:0034 += 1, and
//            on reaching 25 vx += 1; otherwise remember x,y and clear the counter (one counter for
//            all slots). Slot 2's x word, ds:001C, is also read by save_ball_bg (cs:56F4) [M].
//            y >= 350 (unsigned) and x in 88..138 -> left key, x in 148..193 -> right key, timer =
//            10, and the loop ends.
//     0CFF   key repeat ds:000A: if 0 and a key is down (last_scancode < 80h) pause_menu runs, which
//            in demo jumps straight to the quit path (cs:13E3 -> 14FA): any key ends the demo.
//            Otherwise a non-zero count is decremented.
//   cs:3AFF  dmd_idle_text shows the demo string ds:6C5B (dmd_message AX=0100h, DI=E100h) instead
//            of the ball/player text; cs:44A0 score_refresh draws nothing; cs:03CB the boot's idle
//            text and cs:04AD its intro message are skipped; cs:34C3 at game over the demo quits.
//
// EP2-EP4 and EP6-EP13 have the same block byte for byte apart from addresses. EP5 (cs:091E) has
// an older one: ball 0 only, no active test, no stuck-ball nudge.

/// Where one table keeps its demo-mode code and state, found in the user's EXE.
public struct AttractLayout: Sendable, Equatable {
    /// demo_mode (EP1 ds:6C5A).
    public var flag: Int
    /// The flip-hold timer (EP1 ds:000B) and the key-repeat counter (ds:000A).
    public var flipTimer: Int
    public var keyRepeat: Int
    /// Stuck-ball counter (ds:0034), the last-position word arrays (ds:0018 x, ds:0026 y) and the
    /// frame count that nudges (25); nil in EP5.
    public var stuck: Stuck?
    public struct Stuck: Sendable, Equatable {
        public var counter: Int, x: Int, y: Int, limit: Int
    }
    /// Ball slots the block visits (3; EP5 ball 0 only) and whether it skips inactive ones.
    public var slots: Int
    public var activeTest: Bool
    /// Auto-flip zone: y >= flipMinY, x in leftX or rightX (all unsigned compares).
    public var flipMinY: Int
    public var leftX: ClosedRange<Int>
    public var rightX: ClosedRange<Int>
    public var flipFrames: Int
    /// Value the key test stores in the key-repeat counter (20).
    public var keyRepeatFrames: Int
    /// EP1 cs:0B79: the demo releases the plunger once the charge is past its maximum.
    public var releaseAtMax: Bool
    /// cs offsets: the block (EP1 0C48), the non-demo continuation (0D1D) and where the demo
    /// continues (0E8A). Main-loop code in [keys, resume) does not run in demo mode.
    public var block: Int
    public var keys: Int
    public var resume: Int

    /// The block in `code` (the EXE's code segment, 64 KB), or nil.
    public static func discover(code: [UInt8]) -> AttractLayout? {
        let s = ByteSearch(code)
        return discoverSlots(s, code) ?? discoverBall0(s, code)
    }

    static func word(_ m: ByteSearch.Match, _ g: Int) -> Int { m.u16(g) ?? -1 }

    /// EP1 cs:0C48..0D1D (every table but EP5). Groups are checked for consistency below instead of
    /// back references.
    static func discoverSlots(_ s: ByteSearch, _ c: [UInt8]) -> AttractLayout? {
        let p = #"\x80\x3e(..)\x01\x75\x0e\x80\x3e(..)\x00\x74\x0a\xfe\x0e(..)\xeb\x10\x90\xe9(..)"#       // 1 flag 2-3 timer 4 keys
            + #"\x2e\xc6\x06(..)\x00\x2e\xc6\x06(..)\x00\xbf\x00\x00"#                                       // 5 lkey 6 rkey
            + #"\x83\xbd(..)\x01\x75\x7e\x8b\x85(..)\x3b\x85(..)\x75\x1c\x8b\x85(..)\x39\x85(..)\x75\x12"#     // 7 active 8 y 9 sy 10 x 11 sx
            + #"\xfe\x06(..)\x80\x3e(..)(.)\x75\x1c\xff\x85(..)\xeb\x16\x90"#                                // 12-13 counter 14 limit 15 vx
            + #"\x8b\x85(..)\x89\x85(..)\x8b\x85(..)\x89\x85(..)\xc6\x06(..)\x00"#                           // 16 x 17 sx 18 y 19 sy 20 counter
            + #"\x81\xbd(..)(..)\x72\x3b\x81\xbd(..)(..)\x77\x15\x83\xbd(..)(.)\x72\x2c"#                    // 21 y 22 minY 23 x 24 lmax 25 x 26 lmin
            + #"\x2e\xc6\x06(..)\x01\xc6\x06(..)(.)\xeb\x2a\x90"#                                            // 27 lkey 28 timer 29 frames
            + #"\x81\xbd(..)(..)\x72\x16\x81\xbd(..)(..)\x77\x0e\x2e\xc6\x06(..)\x01\xc6\x06(..)(.)\xeb\x0c\x90"#  // 30 x 31 rmin 32 x 33 rmax 34 rkey 35 timer 36 frames
            + #"\x83\xc7\x02\x83\xff(.)\x73\x03\xe9\x70\xff"#                                               // 37 slot end
            + #"\x80\x3e(..)\x00\x75\x10\x2e\x80\x3e(..)\x80\x73\x0c\xe8(..)\xc6\x06(..)(.)\xfe\x0e(..)\xe9(..)"#  // 38 kr 39 scan 40 call 41 kr 42 frames 43 kr 44 resume
        let ms = s.all(p)
        guard ms.count == 1, let m = ms.first else { return nil }
        let w = { word(m, $0) }
        guard w(2) == w(3), w(2) == w(28), w(2) == w(35), w(12) == w(13), w(12) == w(20), w(38) == w(41), w(38) == w(43),
              w(5) == w(27), w(6) == w(34), w(9) == w(19), w(11) == w(17), w(8) == w(18), w(8) == w(21),
              [16, 23, 25, 30, 32].allSatisfy({ w($0) == w(10) }), m.u8(29) == m.u8(36) else { return nil }
        let keysJmp = m.start + 21          // the `jmp` behind `jne +0Eh`
        let resumeJmp = m.end - 3
        var a = AttractLayout(
            flag: w(1), flipTimer: w(2), keyRepeat: w(38),
            stuck: Stuck(counter: w(12), x: w(11), y: w(9), limit: m.u8(14) ?? 0), slots: (m.u8(37) ?? 2) / 2, activeTest: true,
            flipMinY: w(22), leftX: (m.u8(26) ?? 0)...w(24), rightX: w(31)...w(33), flipFrames: m.u8(29) ?? 0,
            keyRepeatFrames: m.u8(42) ?? 0, releaseAtMax: false, block: m.start,
            keys: EngineLayout.rel16(c, keysJmp), resume: EngineLayout.rel16(c, resumeJmp))
        a.releaseAtMax = releaseAtMax(s, c, flag: a.flag)
        return a
    }

    /// EP5 cs:091E..099D: ball 0 only, no active test, no stuck-ball nudge; `jne` straight to the keys.
    static func discoverBall0(_ s: ByteSearch, _ c: [UInt8]) -> AttractLayout? {
        let p = #"\x80\x3e(..)\x01\x75(.)\x80\x3e(..)\x00\x74\x07\xfe\x0e(..)\xeb\x0d\x90"#                 // 1 flag 2 rel 3-4 timer
            + #"\x2e\xc6\x06(..)\x00\x2e\xc6\x06(..)\x00"#                                                  // 5 lkey 6 rkey
            + #"\x81\x3e(..)(..)\x72.\x81\x3e(..)(..)\x77.\x83\x3e(..)(.)\x72."#                            // 7 y 8 minY 9 x 10 lmax 11 x 12 lmin
            + #"\x2e\xc6\x06(..)\x01\xc6\x06(..)(.)\xeb.\x90"#                                              // 13 lkey 14 timer 15 frames
            + #"\x81\x3e(..)(..)\x72.\x81\x3e(..)(..)\x77.\x2e\xc6\x06(..)\x01\xc6\x06(..)(.)"#             // 16 x 17 rmin 18 x 19 rmax 20 rkey 21 timer 22 frames
            + #"\x80\x3e(..)\x00\x75.\x2e\x80\x3e(..)\x80\x73.\xe8(..)\xc6\x06(..)(.)\xfe\x0e(..)\xe9(..)"#  // 23 kr 24 scan 25 call 26 kr 27 frames 28 kr 29 resume
        let ms = s.all(p)
        guard ms.count == 1, let m = ms.first else { return nil }
        let w = { word(m, $0) }
        guard w(3) == w(4), w(3) == w(14), w(3) == w(21), w(5) == w(13), w(6) == w(20), w(23) == w(26), w(23) == w(28),
              [11, 16, 18].allSatisfy({ w($0) == w(9) }), m.u8(15) == m.u8(22) else { return nil }
        var a = AttractLayout(
            flag: w(1), flipTimer: w(3), keyRepeat: w(23), stuck: nil, slots: 1, activeTest: false,
            flipMinY: w(8), leftX: (m.u8(12) ?? 0)...w(10), rightX: w(17)...w(19), flipFrames: m.u8(15) ?? 0,
            keyRepeatFrames: m.u8(27) ?? 0, releaseAtMax: false, block: m.start,
            keys: EngineLayout.rel8(c, m.start + 5), resume: EngineLayout.rel16(c, m.end - 3))
        a.releaseAtMax = releaseAtMax(s, c, flag: a.flag)
        return a
    }

    /// EP1 cs:0B44 `cmp [demo],1; je 0B5B; cmp cs:[ctrl],1` -> cs:0B5B `cmp [charge],MAX; ja 0B79` ->
    /// cs:0B79 `cmp [demo],1; je +3; jmp`: the demo goes on to the release once the charge is past MAX.
    static func releaseAtMax(_ s: ByteSearch, _ c: [UInt8], flag: Int) -> Bool {
        let f = ByteSearch.w(flag)
        for m in s.all(#"\x80\x3e"# + f + #"\x01\x74(.)\x2e\x80\x3e"#) {
            let t = (m.start + 7 + Int(Int8(bitPattern: UInt8(m.u8(1) ?? 0)))) & 0xFFFF
            guard let cm = s.first(#"\x81\x3e....([\x77\x73])(.)"#, t, t + 8), cm.start == t else { continue }
            let j = (t + 8 + Int(Int8(bitPattern: UInt8(cm.u8(2) ?? 0)))) & 0xFFFF
            if let r = s.first(#"\x80\x3e"# + f + #"\x01\x74\x03\xe9"#, j, j + 8), r.start == j { return true }
        }
        return false
    }
}
