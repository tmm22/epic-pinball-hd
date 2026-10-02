import Foundation

// Per-table knowledge the rules runtime needs beyond rules.json: where the unlifted main-loop
// fragments are (executed from the user's EXE by `MiniX86`), which routines they call, and a few DS
// addresses that the engine owns or that the presentation reads. Only addresses (found by reverse
// engineering, docs/formats/*.md) live here; every byte of code and data comes from the EXE at run
// time, and every range is validated (it must decode with `MiniX86`) before it is used.
//
// EP1 (code segment 0x3223, data segment 0x0015), from the disassembly (tools/disasm.py, symbols in
// scratch/engine/ep1_symbols.json):
//   init        cs:0444..04D2  intro scroll loop (counts game_running ds:6C6C, attract lamp_update),
//                              then the non-demo boot tail: intro message, lamp 4 blink, skill lane 2
//   attract     cs:04D2..06E2  between-balls attract texts for multi-player games (bonus_count at 600)
//   scroller    cs:0813..0898  DMD text scroller driven by ds:0035 (cleared by the plunger release)
//   sound       cs:0898..09DC  sfx_pending (forced 11000 Hz, 5-frame gap), the three pitch sweeps,
//                              sfx_now: every sfx_play call becomes a SoundEvent
//   dmdTimer    cs:0A17..0A31  ds:589B countdown (never set in EP1; kept for exactness)
//   serve2      cs:0ACD..0AD3  serve delay reached 2: queue a sound
//   serve1      cs:0ADA..0AFD  serve delay reached 1: mode-4 lamps, mode and mode timer cleared
//   release     cs:0B90..0BBA  plunger released: manual scroll/scroller off, message, gate_draw, sound
//   release2    cs:0BCB..0BFE  after the launch impulse: idle text; first ball of a turn clears the
//                              bonus counters (jumps out to cs:0C48 otherwise)
//   release3    cs:0C14..0C19  clears the between-balls flag ds:096F (only after release2 completes)
//   tilt        cs:0E72..0E8A  TILT message, mode timer cleared, tilted = 1
//   scoreDirty  cs:111E..1134  score_dirty -> score_refresh
//   bigHit      cs:18C5..18E8  inside physics_step: hard hit (vy < -500 with 9 probe hits) queues a sound
//   flipperLeft/Right cs:3D1F..3D2B / 3DBD..3DC9  flipper_update: a flipper leaving rest queues its
//                              sound (pan left/right) and clears the queue delay
//   fadeTail    cs:3333..333E  end of ball_lost_fade's palette fade: between-balls flag, attract timer
//   endOfTurn   cs:340D..358E  after the bonus payout: multiplier reset, extra-ball check, player switch
//                              (per-player block save/restore via ds:6571), game over (pause_menu)
//   idleText    cs:3AF8        dmd_idle_text (routine): ball/player digits into its strings; when tilted
//                              only `mode = 0` (rules.md 3.1 stub_routines note)
//   renderFrame cs:3E35..4373  message effects: per-effect duration and sounds (decoded, not executed)

public struct TableGlue: Sendable {
    public var ranges: [String: GlueRange] = [:]
    /// Routine entries (cs offsets) by role.
    public var routines: [String: Int] = [:]
    /// DS addresses by role (1- or 2-byte variables, see `EP1`).
    public var ds: [String: Int] = [:]
    /// cs-relative keyboard flag bytes by input role.
    public var csKeys: [String: Int] = [:]
    /// Segment of the sound-driver API (far calls into it are no-ops here).
    public var soundAPISegment: Int?
    /// lamp_update's visiting order (cs table, indexed by the phase byte) and phase wrap limit.
    public var lampOrder: [Int] = []
    public var lampPhaseLimit: Int = 0
    /// render_frame message effects (effect byte ds:0B3A -> timing and sounds).
    public var messageEffects: [Int: MessageEffect] = [:]
    public var warnings: [String] = []

    public struct GlueRange: Sendable, Equatable {
        public var start: Int
        public var end: Int
        public init(_ start: Int, _ end: Int) { self.start = start; self.end = end }
    }

    /// How render_frame animates one message effect ([M]: decoded from the counter comparisons).
    public struct MessageEffect: Sendable, Equatable {
        /// Counter value (ds:0B3D, 1 after dmd_message, +1 per frame) after which the message ends.
        public var endCount: Int
        /// Extra frames of the fade-out that some effects run after `endCount`.
        public var fadeFrames: Int
        /// sfx_play calls made at a counter value: (count, AX).
        public var sounds: [SoundAt]
        public struct SoundAt: Sendable, Equatable { public var count: Int; public var ax: Int }
    }

    /// Near-call targets MiniX86 executes (collision-buffer drawing routines called by glue ranges).
    public var follow: Set<Int> = []
    /// Ranges whose near calls are all executed from the EXE (the discovered lane glue: EP6 cs:0BD5
    /// calls dmd_idle_text cs:31E1, which the lift treats as a display call), as in rule-code `call`
    /// ops; far calls still go through the callout (display, sound).
    public var followNearCalls: Set<String> = []

    public static let none = TableGlue()
    public var isEmpty: Bool { ranges.isEmpty }

    public func range(_ name: String) -> GlueRange? { ranges[name] }

    /// Glue for a table whose code we have read (EP1 fully, EP10 one physics fragment). Other tables
    /// get `.none` (their main-loop fragments are not annotated yet, rules.md 4 item 1).
    public static func make(program p: RulesProgram, machine m: RulesMachine, layout: EngineLayout? = nil) -> TableGlue {
        if p.table == 10, p.codeSegment == 0x31A4, p.dispatcherIP == 0x1E32 {
            var g = ep10(m)
            discoverSound(program: p, machine: m, into: &g)
            discoverEndOfTurn(machine: m, into: &g)
            if let l = layout { discoverLane(machine: m, layout: l, into: &g); discoverBootTail(machine: m, layout: l, into: &g); discoverBetweenBalls(machine: m, layout: l, into: &g) }
            return g
        }
        if (p.table == 8 && p.codeSegment == 0x353A && p.dispatcherIP == 0x1F9F)
            || (p.table == 9 && p.codeSegment == 0x309A && p.dispatcherIP == 0x1F9A) {
            var g = ruleDrivenMainLoop(p.table, m)
            discoverSound(program: p, machine: m, into: &g)
            discoverEndOfTurn(machine: m, into: &g)
            if let l = layout { discoverLane(machine: m, layout: l, into: &g); discoverBootTail(machine: m, layout: l, into: &g); discoverBetweenBalls(machine: m, layout: l, into: &g) }
            return g
        }
        guard p.table == 1, p.codeSegment == 0x3223, p.dataSegment == 0x0015, p.dispatcherIP == 0x1E3B,
              p.hooks["drain"]?.entryIP == 0x0A31, p.hooks["kicker"]?.entryIP == 0x19C1 else {
            var g = TableGlue()
            discoverSound(program: p, machine: m, into: &g)
            discoverEndOfTurn(machine: m, into: &g)
            if let l = layout { discoverLane(machine: m, layout: l, into: &g); discoverBootTail(machine: m, layout: l, into: &g); discoverBetweenBalls(machine: m, layout: l, into: &g) }
            return g
        }
        var g = TableGlue()
        let x = MiniX86(machine: m)
        func add(_ name: String, _ s: Int, _ e: Int) {
            let v = x.validate(from: s, to: e)
            if v == .completed { g.ranges[name] = GlueRange(s, e) } else { g.warnings.append("glue \(name) cs:\(hex4(s)) does not decode (\(v)); skipped") }
        }
        add("init", 0x0444, 0x04D2)
        add("attract", 0x04D2, 0x06E2)
        add("scroller", 0x0813, 0x0898)
        add("sound", 0x0898, 0x09DC)
        add("dmdTimer", 0x0A17, 0x0A31)
        add("serve2", 0x0ACD, 0x0AD3)
        add("serve1", 0x0ADA, 0x0AFD)
        add("release", 0x0B90, 0x0BBA)
        add("release2", 0x0BCB, 0x0BFE)
        add("release3", 0x0C14, 0x0C19)
        add("tilt", 0x0E72, 0x0E8A)
        add("scoreDirty", 0x111E, 0x1134)
        add("bigHit", 0x18C5, 0x18E8)
        add("flipperLeft", 0x3D1F, 0x3D2B)
        add("flipperRight", 0x3DBD, 0x3DC9)
        add("fadeTail", 0x3333, 0x333E)
        add("endOfTurn", 0x340D, 0x358E)
        add("idleText", 0x3AF8, 0x3B6E)
        g.routines = [
            "sfx_play": 0x014A, "wait_frame": 0x0249, "wait_frame_far": 0x027E, "pause_menu": 0x13DD,
            "camera_update": 0x308D, "ball_lost_fade": 0x32E9, "idle_text": 0x3AF8, "flipper_sprite": 0x3C12,
            "render_frame": 0x3E35, "raster_bar": 0x44AE, "split_line": 0x4683, "set_scroll": 0x46E3,
            "blit_list": 0x472F, "lamp_update": 0x478D, "draw_plunger": 0x4959, "pause_overlay": 0x49DE,
            "restore_ball_bg": 0x57B9, "save_ball_bg": 0x5657, "text3": 0x5A9D,
        ]
        g.ds = [
            "snd_present": 0x0008, "demo_mode": 0x6C5A, "opt_sfx": 0x679A, "opt_music": 0x6799,
            "ball_number": 0x675F, "current_player": 0x6760, "player_count": 0x6761, "balls_per_game": 0x6798,
            "player_blocks": 0x6571, "between_balls": 0x096F, "highlight_player": 0x0339,
            "msg_effect": 0x0B3A, "msg_scroll": 0x0B3B, "msg_counter": 0x0B3D, "sfx_pending_delay": 0x0014,
            "serve_delay": 0x5896, "plunger_charge": 0x5897, "nudge_timer": 0x5870, "tilt_meter": 0x5871,
            "hit_count": 0x6C1E, "acc_x": 0x6A18, "acc_y": 0x6A24, "flipper_angle_left": 0x6CD2,
            "flipper_angle_right": 0x6CD4, "flipper_drawn_left": 0x6CD6, "flipper_drawn_right": 0x6CD8,
            "flipper_moving_left": 0x676F, "flipper_moving_right": 0x6770,
        ]
        g.csKeys = ["left": 0x028D, "joy_absent": 0x028E, "right": 0x028F, "up": 0x0292, "down": 0x0293,
                    "space": 0x0296, "ctrl": 0x0297, "nudge_a": 0x0298, "nudge_b": 0x0299, "scancode": 0x029B]
        g.soundAPISegment = 0x3D35
        // lamp_update cs:4807..481E: `mov cl, cs:[bx + table]` (2E 8A 8F iw) then `cmp byte [si], limit`
        // (80 3C ib) -> phase wrap. Both operands are read from the EXE.
        let c = m.code
        if c[0x480D] == 0x2E, c[0x480E] == 0x8A, c[0x480F] == 0x8F, c[0x4819] == 0x80, c[0x481A] == 0x3C {
            let table = Int(c[0x4810]) | Int(c[0x4811]) << 8
            g.lampPhaseLimit = Int(c[0x481B])
            g.lampOrder = (0...0xFF).map { Int(c[(table + $0) & 0xFFFF]) }
        } else {
            g.warnings.append("lamp_update order table at cs:480D does not decode; lamps use the generic updater")
        }
        g.messageEffects = messageEffects(code: c, start: 0x3E35, end: 0x4373, effectVar: 0x0B3A, counterVar: 0x0B3D,
                                          fadeVar: 0x0B3F, sfxPlay: 0x014A)
        return g
    }

    /// EP10 (code segment 0x31A4), two main-loop fragments around the extra-gravity decay
    /// (cs:0566..0571), executed from the EXE [H: code; M: meaning]:
    /// * `preFrame` cs:053E..0566 steers ball 0 near the top: if |vy| < 5 and y < 200 then vx += 2,
    ///   and vx -= 4 more when x >= 145.
    /// * `postTimers` cs:0571..05D2: a gate across the top (routine cs:4313 writes its pixel list
    ///   from ds:062C into the collision buffer, closed or open by ds:062B) opens while ball 0 is in
    ///   the plunger lane (x >= 280) and closes once it is back in x 180..220 below y 22; then two
    ///   rule bytes (ds:00C2, the ds:046C countdown clearing ds:046B).
    static func ep10(_ m: RulesMachine) -> TableGlue {
        var g = TableGlue()
        let x = MiniX86(machine: m)
        for (name, s, e) in [("preFrame", 0x053E, 0x0566), ("postTimers", 0x0571, 0x05D2)] {
            let v = x.validate(from: s, to: e)
            if v == .completed { g.ranges[name] = GlueRange(s, e) } else { g.warnings.append("EP10 glue \(name) does not decode (\(v))") }
        }
        g.routines["gate_top"] = 0x4313
        return g
    }

    /// Rule-driven main-loop blocks that move the ball or edit the collision buffer, which the
    /// harness's rules mode runs (tools/emu/tables/EPn.json `rules_ranges`, emulation.md 12) and the
    /// lifted hooks do not cover [H: code, verified in the harness]:
    /// * EP8 `ruleTimers` cs:05D4..0843: the magnet (while [0454]==1 ball 0 within 60 px of
    ///   ([0456],[0458]) is pulled, v -= d*[0460]/max(d.d,20)) and the [04A4]/[04A3]/[04AA] transport
    ///   state machine (places ball 0, sets its velocity and the lockout, switches the level-0 wall
    ///   threshold [04A7] and the scan bounds [04A6]/[04A9]).
    /// * EP8 `preGravity` cs:1095..10A9: per lamp, cs:429E draws or clears that lamp's toy shape in the
    ///   collision buffer when the state's low bit changes.
    /// * EP9 `ruleTimers` cs:058B..05C2: the [3F1E] timer that swaps the bottom-half diverter
    ///   (cs:40B0, pixel lists ds:051C / ds:053E).
    static func ruleDrivenMainLoop(_ table: Int, _ m: RulesMachine) -> TableGlue {
        var g = TableGlue()
        let x = MiniX86(machine: m)
        let list: [(String, Int, Int)] = table == 8 ? [("ruleTimers", 0x05D4, 0x0843), ("preGravity", 0x1095, 0x10A9)]
                                                    : [("ruleTimers", 0x058B, 0x05C2)]
        for (name, s, e) in list {
            let v = x.validate(from: s, to: e)
            if v == .completed { g.ranges[name] = GlueRange(s, e) } else { g.warnings.append("EP\(table) glue \(name) does not decode (\(v))") }
        }
        g.follow = table == 8 ? [0x429E] : [0x40B0]
        return g
    }

    /// The rule side of the plunger lane (EP1 hand glue `serve2`, `serve1`, `release`, `release2`),
    /// found in the other tables by the shape they share with EP1 cs:0A9D..0C48 (EP2 cs:0BB4..0D2E shown)
    /// [H: code; the effects are checked against the harness by the scenarios in tools/emu/scenarios/EPn/hand]:
    /// * `serve2` after `dec byte [SD]; cmp byte [SD],2; jne` (EP2 cs:0BDD `mov word [sound.queue],5`),
    /// * `serve1` after `cmp byte [SD],1; jne` up to the `call ball_lost_fade` (EP2 cs:0BEA..0BFC),
    /// * `release` after `mov word [vx0],0; cmp word [C],0; je` up to `mov ax,[C]; mov word [C],0;
    ///   sub [vy0],ax; dec word [y0]` (the launch impulse the engine applies; EP2 cs:0C85..0C99: the
    ///   plunger drawn back, the launch sound),
    /// * `release2` after the impulse up to the DAC write `mov dx,3C8h` or the lane's end (EP2
    ///   cs:0CAA..0D04: the idle text, the timed message off, and with the between-balls flag set
    ///   ds:0713 the next-ball message, the bonus counters cleared, W = B >> 2 and the flag cleared).
    /// SD is the serve delay (EngineLayout), C the plunger charge (from the impulse). EP8's lane has
    /// another shape (its launch block, `ClassicEngine.launchBlock`) and gets none of these.
    static func discoverLane(machine m: RulesMachine, layout l: EngineLayout, into g: inout TableGlue) {
        guard g.ranges["release"] == nil, let blf = l.ballLostFade,
              let lane = l.physicsRanges.first(where: { r in r.skips.contains { m.code[$0] == 0xE8 && EngineLayout.rel16(m.code, $0) == blf } }),
              let sd = l.dsVars["serve_delay"], let vx = l.dsVars["ball_vx"], let vy = l.dsVars["ball_vy"], let y0 = l.dsVars["ball_y"] else { return }
        let c = m.code
        func w(_ i: Int) -> Int { Int(c[i & 0xFFFF]) | Int(c[(i + 1) & 0xFFFF]) << 8 }
        func r8(_ i: Int) -> Int { let v = Int(c[i & 0xFFFF]); return (i + 1 + (v >= 0x80 ? v - 0x100 : v)) & 0xFFFF }
        let x = MiniX86(machine: m)
        var found: [String: GlueRange] = [:]
        let (a, b) = (lane.start, lane.end)
        let call = lane.skips.first { c[$0] == 0xE8 && EngineLayout.rel16(c, $0) == blf }!
        // dec byte [SD]; cmp byte [SD],2; jne L2; ...; L2: cmp byte [SD],1; jne PL; ...; call ball_lost_fade
        // (EP5, EP6: no `cmp 2` step, `dec byte [SD]` is followed by the `cmp byte [SD],1`)
        for i in a..<(b - 18) where c[i] == 0xFE && c[i + 1] == 0x0E && w(i + 2) == sd
            && c[i + 4] == 0x80 && c[i + 5] == 0x3E && w(i + 6) == sd && (c[i + 8] == 2 || c[i + 8] == 1) && c[i + 9] == 0x75 {
            let l2 = c[i + 8] == 2 ? r8(i + 10) : i + 4
            guard c[l2] == 0x80, c[l2 + 1] == 0x3E, w(l2 + 2) == sd, c[l2 + 4] == 1, c[l2 + 5] == 0x75, l2 + 6 <= call else { break }
            if i + 11 < l2 { found["serve2"] = GlueRange(i + 11, l2) }
            if l2 + 7 < call { found["serve1"] = GlueRange(l2 + 7, call) }
            break
        }
        // mov word [vx0],0; cmp word [C],0; je OUT; R1; mov ax,[C]; mov word [C],0; sub [vy0],ax; dec word [y0]; R2
        for i in a..<(b - 11) where c[i] == 0xC7 && c[i + 1] == 0x06 && w(i + 2) == vx && w(i + 4) == 0
            && c[i + 6] == 0x83 && c[i + 7] == 0x3E && c[i + 10] == 0 && c[i + 11] == 0x74 {
            let ch = w(i + 8)
            let r1 = i + 13
            guard let imp = (r1..<(b - 17)).first(where: { j in
                c[j] == 0xA1 && w(j + 1) == ch && c[j + 3] == 0xC7 && c[j + 4] == 0x06 && w(j + 5) == ch && w(j + 7) == 0
                    && c[j + 9] == 0x29 && c[j + 10] == 0x06 && w(j + 11) == vy && c[j + 13] == 0xFF && c[j + 14] == 0x0E && w(j + 15) == y0
            }) else { break }
            if r1 < imp { found["release"] = GlueRange(r1, imp) }
            let r2 = imp + 17
            let end = (r2..<(b - 2)).first { c[$0] == 0xBA && w($0 + 1) == 0x3C8 } ?? b
            if r2 < end { found["release2"] = GlueRange(r2, end) }
            break
        }
        for (name, r) in found {
            let v = x.validate(from: r.start, to: r.end)
            if v == .completed { g.ranges[name] = r; g.followNearCalls.insert(name) } else {
                g.warnings.append("lane glue \(name) cs:\(hex4(r.start)) does not decode (\(v)); skipped")
            }
        }
    }

    /// The boot's last piece before the main loop (EP1 glue `init` ends with it, cs:04B5..04D2), found
    /// after the intro scroll loop every table shares (`add ax,50h; cmp ax,37A0h; jae TAIL`, EP2
    /// cs:0465; EP9-13 `cmp ax,3930h`, EP10 cs:046D): TAIL up to the main loop, `bootTail` (EP2 cs:0486..04AB: unless demo mode the intro
    /// message dmd_message(ds:07E1, AX 6, DI 7080h), then the message counter ds:0A22 = 32h, a lamp
    /// set blinking and the skill lane). The intro loop itself (scroll, frame waits, the attract lamp
    /// table) is display and is not run. [H: code; the counter and the message are checked against the
    /// harness by tools/emu/scenarios/EPn/hand/boot_*.json]
    static func discoverBootTail(machine m: RulesMachine, layout l: EngineLayout, into g: inout TableGlue) {
        let c = m.code
        let lo = max(0, l.mainLoop - 0x100)
        guard let i = (lo..<l.mainLoop).last(where: { j in
            c[j] == 0x05 && c[j + 1] == 0x50 && c[j + 2] == 0x00 && c[j + 3] == 0x3D && c[j + 6] == 0x73
        }) else { return }
        let tail = (i + 8 + Int(c[i + 7])) & 0xFFFF
        guard tail < l.mainLoop, l.mainLoop - tail < 0x80 else { return }
        let v = MiniX86(machine: m).validate(from: tail, to: l.mainLoop)
        if v == .completed { g.ranges["bootTail"] = GlueRange(tail, l.mainLoop); g.followNearCalls.insert("bootTail") } else {
            g.warnings.append("boot tail cs:\(hex4(tail)) does not decode (\(v)); skipped")
        }
    }

    /// EP9-EP13: the main loop starts with the between-balls display (EP12 cs:049A: `cmp byte [F],0;
    /// je G; inc word [C]; call R; jmp OUT`, F set by ball_lost_fade, R = cs:4149): while F is set, R
    /// shows the end-of-ball bonus lines one after the other as C counts frames, then clears the
    /// per-ball counters, sets four lamps and clears F. The statement also holds the game-over menu
    /// call (at G), so the hook search rejects it; `betweenBalls` is the first part, run from the EXE.
    /// [H: code; the messages are checked against the harness by the EPn attract and hand scenarios]
    static func discoverBetweenBalls(machine m: RulesMachine, layout l: EngineLayout, into g: inout TableGlue) {
        let c = m.code, a = l.mainLoop
        guard a + 16 < 0x10000, c[a] == 0x80, c[a + 1] == 0x3E, c[a + 4] == 0, c[a + 5] == 0x74,
              c[a + 7] == 0xFF, c[a + 8] == 0x06, c[a + 11] == 0xE8, c[a + 14] == 0xEB,
              (a + 7 + Int(c[a + 6])) & 0xFFFF == a + 16 || c[a + 16] == 0x90 && (a + 7 + Int(c[a + 6])) & 0xFFFF == a + 17 else { return }
        let v = MiniX86(machine: m).validate(from: a, to: a + 16)
        if v == .completed { g.ranges["betweenBalls"] = GlueRange(a, a + 16); g.followNearCalls.insert("betweenBalls") } else {
            g.warnings.append("between-balls display cs:\(hex4(a)) does not decode (\(v)); skipped")
        }
    }

    /// The end-of-turn player/ball counters, found by the code every table shares with EP1 cs:343E
    /// (endOfTurn glue): `mov bl,[P]; (mov [H],bl;) mov bh,0; cmp [PC],bl; jbe +3; jmp NEXT_PLAYER;
    /// inc byte [B]; mov byte [P],0; mov al,[BPG]; inc al; cmp [B],al; jne NEXT_PLAYER` (EP10 cs:30A6,
    /// EP5 cs:1FCC). Gives the DS bytes current_player (P), player_count (PC), ball_number (B) and
    /// balls_per_game (BPG), and the ip of the `inc byte [B]` (`endOfTurn` entry of the generic model).
    static func discoverEndOfTurn(machine m: RulesMachine, into g: inout TableGlue) {
        let c = m.code
        func w(_ i: Int) -> Int { Int(c[i & 0xFFFF]) | Int(c[(i + 1) & 0xFFFF]) << 8 }
        var found: [(Int, Int, Int, Int, Int)] = []
        for i in 0..<(0x10000 - 40) where c[i] == 0x8A && c[i + 1] == 0x1E {
            let p = w(i + 2)
            var j = i + 4
            if c[j] == 0x88 && c[j + 1] == 0x1E { j += 4 }
            guard c[j] == 0xB7, c[j + 1] == 0x00, c[j + 2] == 0x38, c[j + 3] == 0x1E, c[j + 6] == 0x76, c[j + 7] == 0x03 else { continue }
            let pc = w(j + 4)
            j += 8
            if c[j] == 0xE9 { j += 3 } else if c[j] == 0xEB && c[j + 2] == 0x90 { j += 3 } else { continue }
            let incAt = j
            guard c[j] == 0xFE, c[j + 1] == 0x06 else { continue }
            let b = w(j + 2)
            j += 4
            guard c[j] == 0xC6, c[j + 1] == 0x06, w(j + 2) == p, c[j + 4] == 0 else { continue }
            j += 5
            guard c[j] == 0xA0 else { continue }
            let bpg = w(j + 1)
            j += 3
            guard c[j] == 0xFE, c[j + 1] == 0xC0, c[j + 2] == 0x38, c[j + 3] == 0x06, w(j + 4) == b else { continue }
            found.append((p, pc, b, bpg, i))
            _ = incAt
        }
        guard found.count == 1, let f = found.first else {
            if found.count > 1 { g.warnings.append("end-of-turn counters: \(found.count) matches, none used") }
            return
        }
        g.ds["current_player"] = f.0
        g.ds["player_count"] = f.1
        g.ds["ball_number"] = f.2
        g.ds["balls_per_game"] = f.3
        g.routines["end_of_turn"] = f.4   // the `mov bl, [P]` that starts the player/ball test
    }

    /// Finds the main loop's sound code in tables we have not annotated, by its structure (the EP1
    /// shape, cs:0898..09DC): it starts with `cmp word [sound.queue], -1` and ends after
    /// `call far sfx_play; mov word [sound.now], 0`. The range must decode, every far call in it must
    /// go to one routine that starts with `cli; pusha` (sfx_play), and the byte tested before the
    /// sweep step sounds (`cmp byte [x], 0; je +8; mov ax, [step]; call far`) is the sound-card flag. Also the
    /// flipper_update fragments `mov word [sound.queue], 1004h/F004h; mov word [delay], 0`.
    static func discoverSound(program p: RulesProgram, machine m: RulesMachine, into g: inout TableGlue) {
        guard let q = p.engineVars["sound.queue"]?.addr, let now = p.engineVars["sound.now"]?.addr else { return }
        let c = m.code
        func w(_ i: Int) -> Int { Int(c[i & 0xFFFF]) | Int(c[(i + 1) & 0xFFFF]) << 8 }
        let x = MiniX86(machine: m)
        search: for e in 5..<0xFFF0 where c[e] == 0xC7 && c[e + 1] == 0x06 && w(e + 2) == now && w(e + 4) == 0 && c[e - 5] == 0x9A {
            for s in stride(from: e - 5, through: max(0, e - 0x300), by: -1)
            where c[s] == 0x83 && c[s + 1] == 0x3E && w(s + 2) == q && c[s + 4] == 0xFF {
                guard x.validate(from: s, to: e + 6) == .completed else { continue search }
                var targets = Set<Int>(), flags = Set<Int>()
                var ip = s
                while ip < e + 6, let n = x.length(at: ip) {
                    if c[ip] == 0x9A { targets.insert(w(ip + 1)) }
                    if c[ip] == 0x80, c[ip + 1] == 0x3E, c[ip + 4] == 0, c[ip + 5] == 0x74, c[ip + 6] == 0x08, c[ip + 7] == 0xA1,
                       c[ip + 10] == 0x9A { flags.insert(w(ip + 2)) }
                    ip += n
                }
                guard targets.count == 1, let t = targets.first, c[t] == 0xFA, c[t + 1] == 0x60 else { continue search }
                g.ranges["sound"] = GlueRange(s, e + 6)
                g.routines["sfx_play"] = t
                if flags.count == 1 { g.ds["snd_present"] = flags.first! }
                break search
            }
        }
        for ip in 0..<0xFFF0 where c[ip] == 0xC7 && c[ip + 1] == 0x06 && w(ip + 2) == q && c[ip + 4] == 0x04
            && c[ip + 6] == 0xC7 && c[ip + 7] == 0x06 && w(ip + 10) == 0 {
            if c[ip + 5] == 0x10 { g.ranges["flipperLeft"] = GlueRange(ip, ip + 12) }
            if c[ip + 5] == 0xF0 { g.ranges["flipperRight"] = GlueRange(ip, ip + 12) }
        }
    }

    /// Scans render_frame's per-effect blocks (`cmp byte [effectVar], e`): the last counter compare
    /// before `mov word [counterVar], 0FFFFh` is the end count, `mov byte [fadeVar], n` adds a fade
    /// of about n frames, and `mov ax, imm; call far sfx_play` after `cmp word [counterVar], n` is a
    /// sound at count n. [M]: the model ignores the exact fade arithmetic (presentation only).
    static func messageEffects(code c: [UInt8], start: Int, end: Int, effectVar: Int, counterVar: Int,
                               fadeVar: Int, sfxPlay: Int) -> [Int: MessageEffect] {
        var out: [Int: MessageEffect] = [:]
        var effect: Int?
        var lastCmp: Int?
        var cur = MessageEffect(endCount: 0, fadeFrames: 0, sounds: [])
        var ended = false
        func lo(_ v: Int) -> UInt8 { UInt8(v & 0xFF) }
        func hi(_ v: Int) -> UInt8 { UInt8(v >> 8) }
        func w(_ i: Int) -> Int { Int(c[i]) | Int(c[i + 1]) << 8 }
        func close() { if let e = effect, out[e] == nil { out[e] = cur } }
        var ip = start
        while ip + 6 < end {
            if c[ip] == 0x80, c[ip + 1] == 0x3E, c[ip + 2] == lo(effectVar), c[ip + 3] == hi(effectVar) {
                close()
                effect = Int(c[ip + 4]); lastCmp = nil; ended = false
                cur = MessageEffect(endCount: 0, fadeFrames: 0, sounds: [])
                ip += 5; continue
            }
            if c[ip] == 0x81 || c[ip] == 0x83, c[ip + 1] == 0x3E, c[ip + 2] == lo(counterVar), c[ip + 3] == hi(counterVar) {
                lastCmp = c[ip] == 0x81 ? w(ip + 4) : Int(c[ip + 4])
                ip += c[ip] == 0x81 ? 6 : 5; continue
            }
            if c[ip] == 0xC6, c[ip + 1] == 0x06, c[ip + 2] == lo(fadeVar), c[ip + 3] == hi(fadeVar) {
                cur.fadeFrames = Int(c[ip + 4]); ip += 5; continue
            }
            if c[ip] == 0xB8, c[ip + 3] == 0x9A, w(ip + 4) == sfxPlay, let n = lastCmp {
                cur.sounds.append(.init(count: n, ax: w(ip + 1)))
                ip += 8; continue
            }
            if c[ip] == 0xC7, c[ip + 1] == 0x06, c[ip + 2] == lo(counterVar), c[ip + 3] == hi(counterVar), c[ip + 4] == 0xFF, c[ip + 5] == 0xFF {
                if !ended, let n = lastCmp { cur.endCount = n; ended = true }
                ip += 6; continue
            }
            ip += 1
        }
        close()
        return out
    }
}

@inline(__always) func hex4(_ v: Int) -> String { String(format: "%04X", v) }
