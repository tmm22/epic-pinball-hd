import Foundation

// The per-table main-loop layout the rules discovery needs, found by the byte signatures of
// tools/emu/discover.py (EP1 code shapes generalised with wildcards; the harness caches the same
// result in tools/emu/tables/EPn.json `auto`). Only the parts the hook search uses are ported: the
// frame sync and main-loop head, the ball slot arrays, the physics-mode main-loop ranges (extra
// gravity decay, per-frame counters, drain + serve, plunger lane, nudge/tilt, gravity + object
// scan), ball_lost_fade, the keyboard ISR's CS flags and a few DS variables.

public struct EngineLayout: Sendable {
    public var cs = 0, ds = 0
    public var frameSync = 0, physicsStep = 0, mainLoop = 0
    public var ballSlots = 5
    public var dsVars: [String: Int] = [:]
    public var csVars: [String: Int] = [:]
    public var kickerHit: Int?
    public var ballPixelScan: Int?
    /// (start, end, skipped call sites) in main-loop order.
    public var physicsRanges: [(start: Int, end: Int, skips: [Int])] = []
    public var ballLostFade: Int?
    public var drainY: Int?
    public var frameCounters: [Int] = []
    public var sensorDispatchIndex: Int?
    public var sensorTable: Int?
    public var flipperUpdate: Int?
    public var missing: [String] = []

    public enum Failure: Error, CustomStringConvertible {
        case notFound(String)
        public var description: String { switch self { case let .notFound(s): return "engine layout: \(s) not found" } }
    }

    static func rel16(_ c: [UInt8], _ at: Int) -> Int {
        let d = Int(c[(at + 1) & 0xFFFF]) | Int(c[(at + 2) & 0xFFFF]) << 8
        return (at + 3 + (d >= 0x8000 ? d - 0x10000 : d)) & 0xFFFF
    }
    static func rel8(_ c: [UInt8], _ at: Int) -> Int {
        let d = Int(c[(at + 1) & 0xFFFF])
        return (at + 2 + (d >= 0x80 ? d - 0x100 : d)) & 0xFFFF
    }

    /// Follows unconditional jmp chains (e9/eb).
    static func followJmps(_ c: [UInt8], _ a0: Int, limit: Int = 8) -> Int {
        var a = a0
        for _ in 0..<limit {
            if c[a] == 0xE9 { a = rel16(c, a) } else if c[a] == 0xEB { a = rel8(c, a) } else { break }
        }
        return a
    }

    /// End of a near routine: the first ret past every jump target seen so far (linear sweep).
    static func funcEnd(_ c: [UInt8], _ start: Int, limit: Int = 0x800) -> Int {
        var a = start, far = start
        while a < start + limit {
            guard let i = X86Decoder.decode(c, a) else { return a }
            if i.mn.hasPrefix("j"), let t = i.target { far = max(far, t) }
            a += i.length
            if ["ret", "iret", "retf"].contains(i.mn), a > far { return a }
        }
        return a
    }

    /// Keyboard ISR (int 9): scancode -> [(cs var, value)] and the last-scancode var.
    static func isrKeyMap(_ c: [UInt8], _ start: Int) -> ([Int: [(Int, Int)]], Int?) {
        var insns: [X86Insn] = []
        var a = start
        while a < start + 0x400, let i = X86Decoder.decode(c, a) {
            insns.append(i); a += i.length
            if i.mn == "iret" { break }
        }
        var labels: [Int: Set<Int>] = [:]
        for k in 0..<max(0, insns.count - 1) {
            let i = insns[k], j = insns[k + 1]
            if i.mn == "cmp", i.ops.count == 2, i.ops[0] == .reg(0, 1), let sc = i.ops[1].immValue, j.mn == "je" || j.mn == "jne" {
                if j.mn == "je", let t = j.target { labels[t, default: []].insert(sc) } else { labels[j.next, default: []].insert(sc) }
            }
        }
        var keys: [Int: [(Int, Int)]] = [:], last: Int?
        var cur: Set<Int>?
        for i in insns {
            if let l = labels[i.ip] { cur = l }
            if i.mn == "mov", i.ops.count == 2, let m = i.ops[0].memValue, m.seg == 1, m.isDirect, m.size == 1 {
                if let v = i.ops[1].immValue, let cs = cur {
                    for sc in cs { keys[sc, default: []].append((m.offset, v)) }
                }
                if i.ops[1] == .reg(0, 1) { last = m.offset }
            }
            if ["jmp", "iret", "ret"].contains(i.mn) { cur = nil }
        }
        return (keys, last)
    }

    public static func discover(image: ExeImage, search s: ByteSearch) throws -> EngineLayout {
        let c = image.code
        let w = ByteSearch.w
        var L = EngineLayout()
        L.cs = image.entryCS
        L.ds = image.dataSegment
        var dsv: [String: Int] = [:], csv: [String: Int] = [:]
        func need(_ p: String, _ name: String, _ a: Int = 0, _ b: Int? = nil) throws -> ByteSearch.Match {
            guard let m = s.first(p, a, b) else { throw Failure.notFound(name) }
            return m
        }
        // frame_sync (EP1 cs:1243)
        let fsm = try need(#"\x2e\xc6\x06(..)\x00\xba\xda\x03\xec\x24\x08\x75.\x2e\x80\x3e(..)\x00\x74."#, "frame_sync")
        let fs = fsm.start
        L.frameSync = fs
        csv["isr_frame_mode"] = fsm.u16(1)
        csv["vsync_flag"] = fsm.u16(2)
        let pm = try need(#"\x80\x3e(..)\x01\x75.\xe8(..)\xe8..\xe8.."#, "physics_step", fs, fs + 0x40)
        dsv["opt_no_timer"] = pm.u16(1)
        L.physicsStep = rel16(c, pm.start + 7)
        let im = try need(#"\x2e\xc6\x06(..)\x03"#, "isr_steps_left", fs + 0x20, fs + 0x60)
        csv["isr_steps_left"] = im.u16(1)
        let mj = try need(#"\xba\xda\x03\xec\x24\x08\x75\xfb"#, "main_loop_jmp", im.start, im.start + 0x30)
        guard let j = s.first(#"\xe9"#, mj.start + 8, mj.start + 0x20) else { throw Failure.notFound("main_loop") }
        L.mainLoop = rel16(c, j.start)
        // physics_step head
        let ps = L.physicsStep
        let hm = try need(#"\x60\x06\xc6\x06(..)\x00\xbf\x00\x00\x83\xbd(..)\x01"#, "physics_step_head", ps, ps + 16)
        dsv["collided"] = hm.u16(1)
        dsv["ball_active"] = hm.u16(2)
        let bs = try need(#"\x83\xc7\x02\x83\xff(.)\x75"#, "ball_slots", ps, ps + 0x30)
        L.ballSlots = (bs.u8(1) ?? 10) / 2
        let cc = try need(#"\xc6\x06(..)\x00\xc6\x06(..)\x00\x8b\x85"#, "contact_clear", ps, ps + 0x40)
        dsv["flipper_contact"] = cc.u16(1)
        dsv["kick_strength"] = cc.u16(2)
        let integ = #"\x8b\x85(..)\x01\x85(..)\x8b\x85\2\x3d\x00\x00\x7c.\xc1\xe8\x07\x3d.\x00\x76.\xb8.\x00"#
            + #"\x81\xbd\2..\x7e\x06\xc7\x85\2..\x01\x85(..)"#
        let ms = s.all(integ, ps, ps + 0x200)
        guard ms.count >= 2 else { throw Failure.notFound("integration") }
        dsv["ball_vx"] = ms[0].u16(1); dsv["ball_accx"] = ms[0].u16(2); dsv["ball_x"] = ms[0].u16(3)
        dsv["ball_vy"] = ms[1].u16(1); dsv["ball_accy"] = ms[1].u16(2); dsv["ball_y"] = ms[1].u16(3)
        if let r = s.first(#"\x80\xbd(..)\x01\x75\x06\xb6\x00"#, ps, ps + 0x300) { dsv["ball_layer"] = r.u16(1) } else { L.missing.append("ds_vars.ball_layer") }
        if let r = s.first(#"\x80\x3e(..)\x00\x75.((?:(?:\x81\xbd....|\x83\xbd...)[\x77\x72].)*)\xe8(..)"#, ps, ps + 0x300) {
            dsv["kicker_cooldown"] = r.u16(1)
            L.kickerHit = rel16(c, r.start + 7 + r.groupLength(2))
        } else { L.missing.append("ds_vars.kicker_cooldown") }
        if let active = dsv["ball_active"], let r = s.first(#"\xe8(..)\x83\x3e"# + w(active + 2) + #"\x01"#, ps, ps + 0x400) {
            L.flipperUpdate = rel16(c, r.start)
        }
        // sensor dispatcher (cs:1E66) and the tilt byte
        let sd = try need(#"\x8a\xd8\x32\xff\x81\xeb\xaa\x00\xd1\xe3\x2e\x8b\x9f(..)\xff\xe3"#, "sensor_dispatch")
        L.sensorDispatchIndex = sd.start
        L.sensorTable = sd.u16(1)
        if let r = s.first(#"\x3c.\x72.\x80\x3e(..)\x01\x75"#, sd.start - 0x40, sd.start) { dsv["cur_layer"] = r.u16(1) }
        if let t = s.all(#"\x80\x3e(..)\x01\x74"#, sd.start - 0x20, sd.start).last { dsv["tilted"] = t.u16(1) }
        // keyboard ISR
        guard let isr = s.first(#"\x0e\x1f\xe4\x60"#) else { throw Failure.notFound("keyboard_isr") }
        let (keys, last) = isrKeyMap(c, isr.start - 4)
        func key(_ sc: Int, _ name: String, _ value: Int = 1) {
            if let e = keys[sc]?.first(where: { $0.1 == value }) { csv[name] = e.0 } else { L.missing.append("cs_vars.\(name)") }
        }
        key(0x2A, "key_lflip"); key(0x36, "key_rflip"); key(0x48, "key_up"); key(0x50, "key_down")
        key(0x39, "key_space"); key(0x1D, "key_ctrl"); key(0x2C, "key_nudge_a"); key(0x35, "key_nudge_b")
        if let l = last { csv["last_scancode"] = l }

        // ---- per-frame main-loop fragments ("physics" mode ranges)
        let main = L.mainLoop
        guard let ks = dsv["kick_strength"], let act = dsv["ball_active"], let vy = dsv["ball_vy"], let bx = dsv["ball_x"],
              let by = dsv["ball_y"] else { throw Failure.notFound("ball arrays") }
        let gm = try need(#"\xc6\x06"# + w(ks) + #"\x00\xbf\x00\x00\x83\xbd"# + w(act) + #"\x00(?:\x74.|\x75\x03\xe9..)\x81\xbd"#
                          + w(vy) + #"(..)\x7f.\xa1(..)"#, "gravity")
        let ga = gm.start
        var extra: Int?
        let tail = gm.end
        if c[tail] == 0x03, c[tail + 1] == 0x06 { extra = Int(c[tail + 2]) | Int(c[tail + 3]) << 8 }
        if let e = extra { dsv["extra_gravity_timer"] = e }
        let pc = try need(#"\x57\x9a....\xc6\x06(..)\x00\xe8(..)"#, "ball_pixel_scan_call", ga, ga + 0x80)
        let saveCall = pc.start + 1, scanCall = pc.start + 11
        dsv["obj_writeback"] = pc.u16(1)
        L.ballPixelScan = rel16(c, scanCall)
        let ge = try need(#"\x83\xc7\x02\x83\xff.\x74\x03\xe9"#, "gravity_end", ga, ga + 0x100)
        let grav = (ga, rel8(c, ge.start + 6), [saveCall, scanCall])
        var decay: (Int, Int, [Int])?
        if let e = extra {
            if let r = s.first(#"\x83\x3e"# + w(e) + #"\x00\x74\x04\xff\x0e"# + w(e), main, ga) { decay = (r.start, r.start + 11, []) }
            else { L.missing.append("ranges.extra_gravity_decay") }
        }
        let scan = L.ballPixelScan!
        if let r = s.first(#"\x80\x3e(..)\x00\x75.\xe8(..)\x8a\x26"#, scan, scan + 0x100) { dsv["event_cooldown"] = r.u16(1) }
        var lock: Int?
        if let r = s.first(#"\xe8..\x8a\x26(..)"#, scan, scan + 0x100) { lock = r.u16(1); dsv["event_lockout"] = lock }
        var runs: [[(Int, Int)]] = [], cur: [(Int, Int)] = []
        for mm in s.all(#"\x80\x3e(..)\x00\x74\x04\xfe\x0e\1"#, main, ga) {
            let v = mm.u16(1)!
            if let l = cur.last, mm.start == l.0 + 11 { cur.append((mm.start, v)) } else { if !cur.isEmpty { runs.append(cur) }; cur = [(mm.start, v)] }
        }
        if !cur.isEmpty { runs.append(cur) }
        var lockArr: Int?
        if let l = lock, let r = s.first(#"\x8a\x8d(..)\x88\x0e"# + w(l), ga, ga + 0x80) { lockArr = r.u16(1); dsv["event_lockout_array"] = lockArr }
        var lockSet = Set<Int>()
        if let l = lock { lockSet.insert(l) }
        if let la = lockArr { for i in 0..<L.ballSlots { lockSet.insert(la + 2 * i) } }
        var counters: (Int, Int, [Int])?
        for run in runs where lock != nil && run.contains(where: { lockSet.contains($0.1) }) {
            counters = (run[0].0, run[run.count - 1].0 + 11, [])
            let vs = run.map(\.1)
            L.frameCounters = vs
            let others = vs.filter { !lockSet.contains($0) && $0 != dsv["event_cooldown"] }
            if dsv["kicker_cooldown"] == nil, let o = others.first { dsv["kicker_cooldown"] = o }
            break
        }
        if counters == nil { L.missing.append("ranges.counters") }
        // drain + serve
        let dm = try need(#"\xbf(.)\x00\xb9\x00\x00\x83\xbd(..)\x00\x74.\x81\xbd(..)(..)\x72."#, "drain", main, ga)
        L.drainY = dm.u16(4)
        let de = try need(#"\x83\xef\x02(?:\x75.|\x74\x03\xe9..)\x83\xf9(.)\x75(.)"#, "drain_end", dm.start, dm.start + 0x100)
        let a = de.start + de.length - 2
        let drainEnd = rel8(c, a)
        let drain = (dm.start, drainEnd, [Int]())
        if let r = s.first(#"\xc6\x06(..)(.)\xc7\x06"# + w(by) + #"(..)"#, a, drainEnd) { dsv["serve_delay"] = r.u16(1) }
        // plunger lane (or EP8's launch-from-bottom block)
        var lane: (Int, Int, [Int])?
        var la: Int?, out = 0
        if let r = s.first(#"\x83\x3e"# + w(act) + #"\x00\x74(.)(?:\x80\x3e..\x00\x75.)?\x81\x3e"# + w(bx) + #"(..)\x72.\x81\x3e"# + w(by)
                           + #"(..)\x72.\x80\x3e(..)\x00\x74."#, drainEnd, ga) {
            la = r.start; out = rel8(c, r.start + 5)
            if dsv["serve_delay"] == nil { dsv["serve_delay"] = r.u16(4) }
        } else if let r = s.first(#"\x80\x3e..\x00\x75(.)\x83\x3e"# + w(act) + #"\x01\x74.\x83\x3e"# + w(act + 2) + #"\x01\x74."#, drainEnd, ga) {
            la = r.start; out = rel8(c, r.start + 5)
        } else { L.missing.append("ranges.lane") }
        if let la {
            let stop = followJmps(c, out)
            let skips = c[out - 3] == 0xE8 ? [out - 3] : []
            lane = (la, stop, skips)
            if !skips.isEmpty { L.ballLostFade = rel16(c, out - 3) }
        }
        // nudge / tilt
        var nudge: (Int, Int, [Int])?
        if let na = csv["key_nudge_a"], let nb = csv["key_nudge_b"], let sp = csv["key_space"],
           let r = s.first(#"\x2e\x80\x3e"# + w(na) + #"\x01\x74.\x2e\x80\x3e"# + w(nb) + #"\x01\x74.\x2e\x80\x3e"# + w(sp) + #"\x01\x75."#, main, ga) {
            let m = s.first(#"\x80\x06(..)(.)\xc6\x06(..)(.)"#, r.start, r.start + 0x60)
            let t = s.first(#"\x80\x3e(..)(.)\x76(.)\x80\x3e(..)\x01\x74"#, r.start, r.start + 0x90)
            if let m, let t {
                dsv["tilt_meter"] = m.u16(1); dsv["nudge_timer"] = m.u16(3)
                if dsv["tilted"] == nil { dsv["tilted"] = t.u16(4) }
                nudge = (r.start, rel8(c, t.start + 5), [])
            }
        }
        if nudge == nil { L.missing.append("ranges.nudge") }
        var ranges: [(Int, Int, [Int])] = []
        for fr in [decay, counters, drain, lane, nudge, grav] { if let fr { ranges.append(fr) } }
        ranges.sort { $0.0 < $1.0 }
        L.physicsRanges = ranges.map { ($0.0, $0.1, $0.2) }
        if let fu = L.flipperUpdate, let r = s.first(#"\x8e\x06(..)"#, fu, fu + 8) {
            dsv["pf_seg_bottom"] = r.u16(1)
            dsv["pf_seg_top"] = r.u16(1)! - 2
        }
        if let r = s.first(#"\x80\xec\x30\x80\xfc\x0f\x76\x05\xc6\x06(..)\x00"#, 0, 0x400) { dsv["snd_present"] = r.u16(1) }
        L.dsVars = dsv
        L.csVars = csv
        return L
    }
}
