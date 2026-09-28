// The part of tools/emu/discover.py that tools/export_engine_data.py consults (`emu`): code
// addresses and DS variables of the physics step, kicker, serve, drain, plunger / EP8 launch
// block and sensor scan. Same signatures, same search windows. The keyboard-ISR key map,
// flipper-group table, nudge ranges and code-integrity spans of discover.py are not needed by
// the exporter and are not reproduced (the ISR is still required to exist, as there).
import Foundation

/// A code segment viewed as Python `bytes` (`code = data[cbase:]` or `data[cbase:cbase+0x10000]`).
struct CodeView {
    let data: [UInt8]
    let base: Int      // file offset of cs:0
    let end: Int       // file offset one past the last byte of the view

    var count: Int { end - base }

    subscript(_ i: Int) -> UInt8 { data[base + i] }
    func u16(_ i: Int) -> Int { Int(data[base + i]) | Int(data[base + i + 1]) << 8 }
    func s16(_ i: Int) -> Int { let v = u16(i); return v >= 0x8000 ? v - 0x10000 : v }
    func s8(_ i: Int) -> Int { let v = Int(data[base + i]); return v >= 0x80 ? v - 0x100 : v }
    /// Python slice `code[a:b]` bounds (clamped), as absolute file offsets.
    func range(_ a: Int, _ b: Int?) -> Range<Int> {
        let lo = base + max(0, min(a, count)), hi = base + max(0, min(b ?? count, count))
        return lo..<max(lo, hi)
    }
    func bytes(_ a: Int, _ b: Int) -> [UInt8] { Array(data[range(a, b)]) }

    /// re.finditer(pat, code[start:end]) -> (match, cs offset of the match start)
    func all(_ re: ByteRegex, _ start: Int = 0, _ end: Int? = nil) -> [(ByteRegex.Match, Int)] {
        re.all(data, in: range(start, end)).map { ($0, $0.start - base) }
    }
    func first(_ re: ByteRegex, _ start: Int = 0, _ end: Int? = nil) -> (ByteRegex.Match, Int)? {
        re.search(data, in: range(start, end)).map { ($0, $0.start - base) }
    }
    /// re.match(pat, code[a:b]) (anchored at a).
    func matchAt(_ re: ByteRegex, _ a: Int, _ b: Int) -> ByteRegex.Match? {
        let r = range(a, b)
        return re.match(data, at: r.lowerBound, in: r)
    }
    /// cs offset of group g's start.
    func pos(_ m: ByteRegex.Match, _ g: Int) -> Int { m.group(g)!.lowerBound - base }
}

struct DiscoverNotFound: Error { var what: String }

/// The `emu` config the exporter reads (discover.discover(n) subset).
struct EmuConfig {
    var dsVars: [String: Int] = [:]
    var physicsStep: Int?
    var kickerHit: Int?
    var collisionResponseDirStored: Int?
    var ballPixelScan: Int?
    var drainY: Int?
    /// nil = not found (cfg['serve'] = None); keys delay, y, x, vx, vy as found.
    var serve: [String: Int]?
    var serveKeyOrder: [String] = []
    var plunger: (kind: String, max: Int, step: Int?, cmp: String?)?
    var launch: [(String, Int)]?
    var ballSlots = 0
}

enum Discover {
    static func w(_ v: Int) -> String { ByteRegex.word(v) }

    static func run(exe: MZImage) throws -> EmuConfig {
        let cbase = exe.imageOff(exe.entryCS)
        let c = CodeView(data: exe.data, base: cbase, end: min(exe.data.count, cbase + 0x10000))
        func need(_ p: String, _ name: String, _ s: Int = 0, _ e: Int? = nil) throws -> (ByteRegex.Match, Int) {
            guard let r = c.first(rx(p), s, e) else { throw DiscoverNotFound(what: name) }
            return r
        }
        func find(_ p: String, _ s: Int = 0, _ e: Int? = nil) -> (ByteRegex.Match, Int)? { c.first(rx(p), s, e) }
        func rel16(_ at: Int) -> Int { (at + 3 + c.s16(at + 1)) & 0xFFFF }
        func rel8(_ at: Int) -> Int { (at + 2 + c.s8(at + 1)) & 0xFFFF }
        func followJmps(_ a0: Int, limit: Int = 8) -> Int {
            var a = a0
            for _ in 0..<limit {
                let op = c[a]
                if op == 0xE9 { a = rel16(a) } else if op == 0xEB { a = rel8(a) } else { break }
            }
            return a
        }
        var cfg = EmuConfig()
        var dsv: [String: Int] = [:]

        // frame_sync, physics_step, isr_steps_left, main loop jmp
        let (_, fs) = try need(#"\x2e\xc6\x06(..)\x00\xba\xda\x03\xec\x24\x08\x75.\x2e\x80\x3e(..)\x00\x74."#, "frame_sync")
        var (m, a) = try need(#"\x80\x3e(..)\x01\x75.\xe8(..)\xe8..\xe8.."#, "physics_step", fs, fs + 0x40)
        let ps = rel16(a + 7)
        cfg.physicsStep = ps
        (m, a) = try need(#"\x2e\xc6\x06(..)\x03"#, "isr_steps_left", fs + 0x20, fs + 0x60)
        (m, a) = try need(#"\xba\xda\x03\xec\x24\x08\x75\xfb"#, "main_loop_jmp", a, a + 0x30)
        guard let j = find(#"\xe9"#, a + 8, a + 0x20) else { throw DiscoverNotFound(what: "main_loop") }
        let main = rel16(j.1)

        // physics_step head, slots, contact clear, integration
        (m, _) = try need(#"\x60\x06\xc6\x06(..)\x00\xbf\x00\x00\x83\xbd(..)\x01"#, "physics_step_head", ps, ps + 16)
        dsv["collided"] = m.u16(1); dsv["ball_active"] = m.u16(2)
        (m, _) = try need(#"\x83\xc7\x02\x83\xff(.)\x75"#, "ball_slots", ps, ps + 0x30)
        cfg.ballSlots = m.u8(1) / 2
        (m, a) = try need(#"\xc6\x06(..)\x00\xc6\x06(..)\x00\x8b\x85"#, "contact_clear", ps, ps + 0x40)
        dsv["flipper_contact"] = m.u16(1); dsv["kick_strength"] = m.u16(2)
        let integ = #"\x8b\x85(..)\x01\x85(..)\x8b\x85\2\x3d\x00\x00\x7c.\xc1\xe8\x07\x3d.\x00\x76.\xb8.\x00\x81\xbd\2..\x7e\x06\xc7\x85\2..\x01\x85(..)"#
        let ms = c.all(rx(integ), ps, ps + 0x200)
        guard ms.count >= 2 else { throw DiscoverNotFound(what: "integration") }
        dsv["ball_vx"] = ms[0].0.u16(1); dsv["ball_accx"] = ms[0].0.u16(2); dsv["ball_x"] = ms[0].0.u16(3)
        dsv["ball_vy"] = ms[1].0.u16(1); dsv["ball_accy"] = ms[1].0.u16(2); dsv["ball_y"] = ms[1].0.u16(3)
        if let r = find(#"\x80\xbd(..)\x01\x75\x06\xb6\x00"#, ps, ps + 0x300) { dsv["ball_layer"] = r.0.u16(1) }
        // kicker call in the wall loop
        if let r = find(#"\x80\x3e(..)\x00\x75.((?:(?:\x81\xbd....|\x83\xbd...)[\x77\x72].)*)\xe8(..)"#, ps, ps + 0x300) {
            dsv["kicker_cooldown"] = r.0.u16(1)
            cfg.kickerHit = rel16(r.1 + 7 + (r.0.group(2)?.count ?? 0))
        }
        // collision_response and the contact direction store
        (m, a) = try need(#"\x8b\x1e(..)\x4b\x8a\x87(..)\x8a\xe0"#, "collision_response", ps, ps + 0x800)
        dsv["hit_count"] = m.u16(1)
        (m, a) = try need(#"\x8a\xd8\xa2(..)\xfe\xcb\xb7\x00\x88\x1e(..)\x80\x06\2\x18\x80\x3e\2\x30\x76\x05\x80\x2e\2\x30"#, "contact_dir", a, a + 0x200)
        dsv["contact_dir"] = m.u16(1)
        cfg.collisionResponseDirStored = a + m.length

        // sensor dispatcher
        (m, a) = try need(#"\x8a\xd8\x32\xff\x81\xeb\xaa\x00\xd1\xe3\x2e\x8b\x9f(..)\xff\xe3"#, "sensor_dispatch")
        if let r = find(#"\x3c.\x72.\x80\x3e(..)\x01\x75"#, a - 0x40, a) { dsv["cur_layer"] = r.0.u16(1) }
        // keyboard ISR (discover.py requires it; its key map is not used by the exporter)
        guard find(#"\x0e\x1f\xe4\x60"#) != nil else { throw DiscoverNotFound(what: "keyboard_isr") }
        if let r = find(#"\x83\xc7\x02\x8d\x06(..)\x3b\xf8"#) { dsv["params"] = r.0.u16(1) - 0x14 }

        // gravity + object scan
        let gp = #"\xc6\x06"# + w(dsv["kick_strength"]!) + #"\x00\xbf\x00\x00\x83\xbd"# + w(dsv["ball_active"]!)
            + #"\x00(?:\x74.|\x75\x03\xe9..)\x81\xbd"# + w(dsv["ball_vy"]!) + #"(..)\x7f.\xa1(..)"#
        let (gm, ga) = try need(gp, "gravity")
        let tailAt = ga + gm.length
        if c.bytes(tailAt, tailAt + 2) == [0x03, 0x06] { dsv["extra_gravity_timer"] = c.u16(tailAt + 2) }
        (m, a) = try need(#"\x57\x9a....\xc6\x06(..)\x00\xe8(..)"#, "ball_pixel_scan_call", ga, ga + 0x80)
        dsv["obj_writeback"] = m.u16(1)
        let bps = rel16(a + 11)
        cfg.ballPixelScan = bps
        _ = try need(#"\x83\xc7\x02\x83\xff.\x74\x03\xe9"#, "gravity_end", ga, ga + 0x100)

        // per-frame counters: event cooldown / lockout, kicker cooldown fallback
        if let r = find(#"\x80\x3e(..)\x00\x75.\xe8(..)\x8a\x26"#, bps, bps + 0x100) { dsv["event_cooldown"] = r.0.u16(1) }
        var lock: Int? = nil
        if let r = find(#"\xe8..\x8a\x26(..)"#, bps, bps + 0x100) { lock = r.0.u16(1); dsv["event_lockout"] = lock }
        var runs: [[(Int, Int)]] = []
        var cur: [(Int, Int)] = []
        for (mm, at) in c.all(rx(#"\x80\x3e(..)\x00\x74\x04\xfe\x0e\1"#), main, ga) {
            if let last = cur.last, at == last.0 + 11 { cur.append((at, mm.u16(1))) }
            else { if !cur.isEmpty { runs.append(cur) }; cur = [(at, mm.u16(1))] }
        }
        if !cur.isEmpty { runs.append(cur) }
        var lockArr: Int? = nil
        if let lock, let r = find(#"\x8a\x8d(..)\x88\x0e"# + w(lock), ga, ga + 0x80) { lockArr = r.0.u16(1) }
        var lockSet = Set<Int>()
        if let lock { lockSet.insert(lock) }
        if let la = lockArr { for i in 0..<cfg.ballSlots { lockSet.insert(la + 2 * i) } }
        for run in runs where lock != nil && run.contains(where: { lockSet.contains($0.1) }) {
            let vs = run.map { $0.1 }
            let others = vs.filter { !lockSet.contains($0) && $0 != dsv["event_cooldown"] }
            if dsv["kicker_cooldown"] == nil, let o = others.first { dsv["kicker_cooldown"] = o }
            break
        }

        // drain + serve
        (m, a) = try need(#"\xbf(.)\x00\xb9\x00\x00\x83\xbd(..)\x00\x74.\x81\xbd(..)(..)\x72."#, "drain", main, ga)
        cfg.drainY = m.u16(4)
        let da = a
        let (m2, a2) = try need(#"\x83\xef\x02(?:\x75.|\x74\x03\xe9..)\x83\xf9(.)\x75(.)"#, "drain_end", da, da + 0x100)
        let a3 = a2 + m2.length - 2
        let drainEnd = rel8(a3)
        if let r = find(#"\xc6\x06(..)(.)\xc7\x06"# + w(dsv["ball_y"]!) + #"(..)"#, a3, drainEnd) {
            dsv["serve_delay"] = r.0.u16(1)
            var serve: [String: Int] = ["delay": r.0.u8(2), "y": r.0.u16(3)]
            var order = ["delay", "y"]
            for nm in ["x", "vx", "vy"] {
                if let mm = rx(#"\xc7\x06"# + w(dsv["ball_" + nm]!) + #"(..)"#).search(c.data, in: c.range(r.1, drainEnd)) {
                    serve[nm] = mm.s16(1); order.append(nm)
                }
            }
            cfg.serve = serve; cfg.serveKeyOrder = order
        }

        // plunger lane (or EP8's launch-from-bottom block)
        var la: Int? = nil
        var out = 0
        let lanePat = #"\x83\x3e"# + w(dsv["ball_active"]!) + #"\x00\x74(.)(?:\x80\x3e..\x00\x75.)?\x81\x3e"# + w(dsv["ball_x"]!)
            + #"(..)\x72.\x81\x3e"# + w(dsv["ball_y"]!) + #"(..)\x72.\x80\x3e(..)\x00\x74."#
        if let r = find(lanePat, drainEnd, ga) {
            la = r.1; out = rel8(r.1 + 5)
            if dsv["serve_delay"] == nil { dsv["serve_delay"] = r.0.u16(4) }
        } else {
            let lg = #"\x80\x3e..\x00\x75(.)\x83\x3e"# + w(dsv["ball_active"]!) + #"\x01\x74.\x83\x3e"# + w(dsv["ball_active"]! + 2) + #"\x01\x74."#
            if let r = find(lg, drainEnd, ga) { la = r.1; out = rel8(r.1 + 5) }
        }
        if let la {
            let stop = followJmps(out)
            if let r = find(#"\x81\x3e(..)(..)([\x77\x73]).\x83\x06\1(.)"#, la, stop) {
                dsv["plunger_charge"] = r.0.u16(1)
                cfg.plunger = ("charge", r.0.u16(2), r.0.u8(4), r.0.u8(3) == 0x77 ? "ja" : "jae")
            } else if let r = find(#"\x2e\x80\x3e..\x01\x75.\xc7\x06(..)(..)\xeb"#, la, stop) {
                dsv["plunger_charge"] = r.0.u16(1)
                cfg.plunger = ("launch_flag", r.0.u16(2), nil, nil)
                var launch: [(String, Int)] = []
                for nm in ["vx", "vy", "x", "y", "active"] {
                    if let mm = find(#"\xc7\x06"# + w(dsv["ball_" + nm]!) + #"(..)"#, r.1, stop) { launch.append((nm, mm.0.s16(1))) }
                }
                let keys = Set(launch.map { $0.0 })
                if ["x", "y", "vx", "vy"].allSatisfy({ keys.contains($0) }) { cfg.launch = launch }
            }
        }
        cfg.dsVars = dsv
        return cfg
    }
}
