// tools/export_engine_data.py in Swift: engine.json from the user's EPn.EXE plus the
// collision.json / sprites.json produced by the other extractors, then the hand-verified
// overrides (EngineOverrides.swift: code addresses and flags only) merged on top.
import CryptoKit
import Foundation

final class EngineExport {
    static let W = 320, HALF = 64000
    static let paramNames = ["rest_div_x", "rest_div_y", "kicker", "flip_top_x", "flip_top_y",
                             "flip_side_x", "flip_side_y", "up_div_y", "up_div_x", "gravity"]

    /// EP1 values, used only when a pattern is not found (listed in "fallbacks").
    enum EP1 {
        static let stepCap = [5, 5, 5, 5]
        static let accClamp = [2000, -2000]
        static let collisionYLimit = 0x180, yReset = 3, gravityCutoff = 0x140, kickerCooldown = 3, splitX = 0x8C
        static var sideRanges: JSONValue { .obj([("lo", .int(5)), ("side_max", .int(31)), ("top_max", .int(40)), ("side_index", .int(31)), ("tip_index", .int(41))]) }
        static let vyZeroSide = 0x1E, vyZeroTop = 0x28
        static var plunger: JSONObject { JSONObject([("step", .int(12)), ("max", .int(700))]) }
        static var lane: (Int, Int) { (0x118, 0xDC) }
        static var serve: JSONObject { JSONObject([("x", .int(0x11C)), ("y", .int(0x150)), ("delay", .int(7))]) }
        static let drainY = 0x18F
        static var nudge: JSONObject { JSONObject([("tilt_add", .int(35)), ("frames", .int(10))]) }
        static let tiltThreshold = 0x50
        static var nudgeLane: (Int, Int) { (0x118, 0x64) }
        static var nudgeImpulse: JSONValue { .obj([("min_timer", .int(2)), ("dir_min", .int(4)), ("dir_max", .int(42)), ("vy_shift", .int(3)), ("vx", .int(20))]) }
        static let ballBallDivisor = 35
        static let flipTblX = [-3, -2, -1, -1, 1, 2, 3, 4, 4, 5]
        static let flipTblY = [48, 49, 50, 50, 49, 49, 48, 47, 46, 46]
    }

    let n: Int
    let exe: MZImage
    let cj: JSONValue          // collision.json
    let sj: JSONValue?         // sprites.json
    let cs: Int, ds: Int
    let code: CodeView         // data[cbase:]
    let dbase: Int
    var data: [UInt8] { exe.data }
    var fallbacks: [String] = []
    var found = JSONObject()

    init(table n: Int, exe: MZImage, collision: JSONValue, sprites: JSONValue?) throws {
        self.n = n; self.exe = exe; cj = collision; sj = sprites
        cs = exe.entryCS
        ds = try exe.dataSegment()
        code = CodeView(data: exe.data, base: exe.imageOff(cs), end: exe.data.count)
        dbase = exe.imageOff(ds)
    }

    func dsw(_ off: Int, signed: Bool = true) -> Int { signed ? exe.s16(dbase + off) : exe.u16(dbase + off) }
    func dsb(_ off: Int) -> Int { exe.u8(dbase + off) }
    func all(_ p: String, _ start: Int = 0, _ end: Int? = nil) -> [(ByteRegex.Match, Int)] {
        code.all(rx(p), start, (end ?? 0) != 0 ? end : nil)
    }
    func first(_ p: String, _ name: String, _ start: Int = 0, _ end: Int? = nil) -> (ByteRegex.Match, Int)? {
        guard let r = code.all(rx(p), start, (end ?? 0) != 0 ? end : nil).first else { return nil }
        found[name] = .hex(r.1)
        return r
    }
    func fallback<T>(_ name: String, _ v: T) -> T { fallbacks.append(name); return v }
    /// re.search over a byte slice (a..<b) of the code, returns offset of the match within the slice.
    func search(_ p: String, _ a: Int, _ b: Int) -> ByteRegex.Match? { rx(p).search(code.data, in: code.range(a, b)) }
    func w(_ v: Int) -> String { ByteRegex.word(v) }

    // MARK: export

    func export(emuConfig: EmuConfig?, overrides: JSONValue?) throws -> JSONObject {
        var out = JSONObject()
        out["format"] = .string("epic-pinball-engine")
        out["version"] = .int(1)
        out["table"] = .int(n)
        var forbidden = Set<Int>()
        let emu = emuConfig
        let emuDS = emu?.dsVars ?? [:]
        let sha1 = Insecure.SHA1.hash(data: Data(exe.data)).map { String(format: "%02x", $0) }.joined()
        var inputs = ["original/EP\(n).EXE", "extracted/tables/EP\(n)/collision.json"]
        if sj != nil { inputs.append("extracted/tables/EP\(n)/sprites/sprites.json") }
        out["source"] = .obj([("exe", .string("EP\(n).EXE")), ("sha1", .string(sha1)), ("code_segment", .hex(cs)), ("data_segment", .hex(ds)),
                              ("inputs", .strings(inputs))])
        func addNote(_ s: String) {
            var a = out["notes"]?.arrayValue ?? []
            a.append(.string(s))
            out["notes"] = .array(a)
        }

        // ---- parameter block
        guard let pm0 = first(#"\x83\xc7\x02\x8d\x06(..)\x3b\xf8"#, "params") else { throw ImportError("EP\(n): parameter block not found") }
        let pDS = pm0.0.u16(1) - 0x14
        forbidden.formUnion(pDS..<(pDS + 20))
        let params = (0..<10).map { dsw(pDS + 2 * $0) }
        out["params"] = .obj([("ds", .hex(pDS)), ("names", .strings(EngineExport.paramNames)), ("values", .ints(params))])

        // ---- integration
        let caps = all(#"\xc1\xe8\x07\x3d(.)\x00\x76.\xb8.\x00\x81\xbd(..)(..)"#)
        var stepCap: [Int], accClamp: [Int], integEnd = 0
        var accArr: [Int]? = nil
        if caps.count >= 4 {
            stepCap = caps.prefix(4).map { $0.0.u8(1) }
            accClamp = [caps[0].0.s16(3), caps[1].0.s16(3)]
            accArr = [caps[0].0.u16(2), caps[2].0.u16(2)]
            integEnd = caps[3].0.end - code.base
            found["integration"] = .hex(caps[0].1)
        } else {
            stepCap = fallback("integration.step_cap", EP1.stepCap)
            accClamp = fallback("integration.acc_clamp", EP1.accClamp)
        }
        var yReset: Int
        if let m = first(#"\x83\xbd(..)\x01\x7d\x0c\xc7\x85(..)(..)\xc7\x85(..)\x00\x00"#, "y_reset", integEnd) { yReset = m.0.s16(3) }
        else { yReset = fallback("integration.y_reset", EP1.yReset) }
        let collY: Int
        if let m = first(#"\x81\xbd(..)(..)\x72\x03\xe9"#, "collision_y_limit", integEnd) { collY = m.0.u16(2) }
        else { collY = fallback("integration.collision_y_limit", EP1.collisionYLimit) }
        out["integration"] = .obj([
            ("step_cap", .obj([("x_pos", .int(stepCap[0])), ("x_neg", .int(stepCap[1])), ("y_pos", .int(stepCap[2])), ("y_neg", .int(stepCap[3]))])),
            ("acc_clamp_pos", .int(accClamp[0])), ("acc_clamp_neg", .int(accClamp[1])),
            ("min_x", .int(1)), ("min_y", .int(1)), ("y_reset", .int(yReset)), ("collision_y_limit", .int(collY)),
            ("note", .string("per axis: acc+=v; m=|acc|>>7 (unsigned); if m>cap {m=cap; clamp acc}; pos+=/-=m; acc-/+=m<<7. x<1 -> x=1 after x move; y<1 -> y=reset, vy=0 only after an upward y move. Collision loop runs while (u16)y < collision_y_limit.")),
        ])

        // ---- gravity
        var extraVar: Int? = nil
        let gm = first(#"\x81\xbd(..)(..)\x7f.\xa1(..)"#, "gravity")
        let cutoff: Int
        if let (m, at) = gm {
            cutoff = m.s16(2)
            let gVar = m.u16(3)
            let t = at + m.length
            if code.bytes(t, t + 2) == [0x03, 0x06] { extraVar = code.u16(t + 2) }
            if gVar != pDS + 18 { addNote("gravity variable \(pyHex(gVar)) is not param[9]") }
        } else {
            cutoff = fallback("gravity.cutoff", EP1.gravityCutoff)
        }
        var grav = JSONObject([("cutoff", .int(cutoff)), ("extra_var", .hexOrNull(extraVar)), ("extra_initial", .int(extraVar.map { dsw($0) } ?? 0)),
                               ("note", .string("per frame, per active ball: if vy <= cutoff: vy += params.gravity + extra; extra (if present) is decremented once per frame while nonzero"))])
        if let (m, at) = gm {
            var a = at + m.length
            var terms: [JSONValue] = []
            while [[0x03, 0x06], [0x2B, 0x06]].contains(code.bytes(a, a + 2)) {
                let v = code.u16(a + 2)
                terms.append(.obj([("op", .string(code[a] == 0x03 ? "add" : "sub")), ("var", .hex(v)), ("initial", .int(dsw(v)))]))
                a += 4
            }
            grav["terms"] = .array(terms)
            grav["terms_note"] = .string("vy += params.gravity, then each term in order (add/sub the DS word); EP1: one add (extra). Only the extra term is decremented per frame by the engine")
            if let sb = code.matchAt(rx(#"\x01\x85..\x83\xff(.)\x75.\x83\x85..(.)"#), a, a + 16) {
                grav["slot_bonus"] = .obj([("slot", .int(sb.u8(1) / 2)), ("add", .int(sb.s8(2))),
                                           ("note", .string("after the add, this ball slot gets vy += add (same cutoff test)"))])
            }
        }
        out["gravity"] = .object(grav)

        // ---- probe ring, normals, push-out, LUTs (collision.json)
        out["probe_ring"] = .obj([("offsets", cj["ball"]!["ring_offsets"]!), ("xy", cj["ball"]!["ring_xy"]!),
                                  ("note", .string("k=1..48 (index k-1); probed k=48 down to 1; word offsets dy*320+dx from the ball's top-left"))])
        out["normals"] = cj["normals"]!["normal"]!
        out["pushout"] = cj["normals"]!["pushout"]!
        out["wall"] = .obj([("codes", cj["class_codes"]!), ("lut", cj["wall_lut"]!),
                            ("note", .string("per level (0 table, 1 ramp): class per palette index. conditional classes are treated as their unconditional form by the port"))])
        out["occlusion"] = .obj([("codes", cj["occlusion_codes"]!), ("lut", cj["occlusion"]!["lut"]!), ("ranges", sj?["ball_occlusion_ranges"] ?? .null)])

        // ---- flipper contact split / moving flags
        var splitX: Int, mvL: Int? = nil, mvR: Int? = nil
        if let (m, _) = first(#"\x26\x38\x17\x75.\x81\xbd(..)(..)\x77.\x80\x3e(..)\x01\x75.\xc6\x06(..)\x01\xeb.\x90\x80\x3e(..)\x01\x75.\xc6\x06(..)\x02"#, "flipper_contact") {
            splitX = m.u16(2); mvL = m.u16(3); mvR = m.u16(5)
        } else {
            splitX = fallback("flipper_contact.split_x", EP1.splitX)
        }
        // ---- kicker
        var kcool: Int? = nil
        var tiltInKicker: Bool? = nil
        if let (m, at) = first(#"\x80\x3e(..)\x00\x75\x03\xe8(..)"#, "kicker_call") {
            let coolVar = m.u16(1)
            forbidden.insert(coolVar)
            let kip = (at + m.length + m.s16(2)) & 0xFFFF
            tiltInKicker = search(#"\x80\x3e..\x01\x75\x03\xe9"#, kip, kip + 16) != nil
            if let cm = search(#"\xc6\x06"# + w(coolVar) + #"(.)"#, kip, kip + 0x60) {
                kcool = cm.u8(1)
                found["kicker_hit"] = .hex(kip)
            }
        }
        var coolBeforeTilt = false
        if kcool == nil, let kip = emu?.kickerHit, let coolVar = emuDS["kicker_cooldown"] {
            forbidden.insert(coolVar)
            let cm = search(#"\xc6\x06"# + w(coolVar) + #"(.)"#, kip, kip + 0x60)
            let tm = search(#"\x80\x3e..\x01(?:\x75\x03[\xe9\xeb]|\x74)"#, kip, kip + 0x20)
            if let cm {
                kcool = cm.u8(1)
                found["kicker_hit"] = .hex(kip)
                tiltInKicker = tm != nil
                coolBeforeTilt = tm != nil && cm.start < tm!.start
            }
        }
        if kcool == nil { kcool = fallback("kicker.cooldown_frames", EP1.kickerCooldown) }
        var kicker = JSONObject([("cooldown_frames", .int(kcool!)), ("tilt_disables", .bool(tiltInKicker ?? true)),
                                 ("note", .string("any probe on an 'active' index calls the kicker when cooldown==0: kick=params.kicker, cooldown=N (decremented per frame). Not while tilted."))])
        for (k, v) in kickerPath(emu).pairs { kicker[k] = v }
        kicker["cooldown_set_when_tilted"] = .bool(coolBeforeTilt)
        if let kc = emuDS["kicker_cooldown"], kc == emuDS["event_lockout"] { kicker["cooldown_is_sensor_lockout"] = .bool(true) }
        out["kicker"] = .object(kicker)

        // ---- collision_response constants
        let sideRanges: JSONValue
        if let (m, _) = first(#"\x83\xfb(.)\x77.\x83\xfb(.)\x72.\x83\xfb.\x77.\x83\xc3.\xbb(..)\xeb.\x90\x81\xfb(..)\x72.\xbb(..)"#, "flipper_side") {
            let topLo4 = m.u8(1), lo4 = m.u8(2), side4 = m.u16(3), tip4a = m.u16(4), tip4 = m.u16(5)
            sideRanges = .obj([("lo", .int(lo4 / 4)), ("side_max", .int(topLo4 / 4)), ("top_max", .int(tip4a / 4 - 1)),
                               ("side_index", .int(side4 / 4)), ("tip_index", .int(tip4 / 4))])
        } else {
            sideRanges = fallback("flipper_kick.ranges", EP1.sideRanges)
        }
        let vyZeroSide = first(#"\x83\xbd(..)(.)\x7c\x06\xc7\x85..\x00\x00\x8b\x87"#, "vy_zero_side").map { $0.0.u8(2) } ?? fallback("flipper_kick.vy_zero_side", EP1.vyZeroSide)
        let vyZeroTop = first(#"\x83\xbd(..)(.)\x7c\x06\xc7\x85..\x00\x00\x80\x3e"#, "vy_zero_top").map { $0.0.u8(2) } ?? fallback("flipper_kick.vy_zero_top", EP1.vyZeroTop)
        let mR = first(#"\x8b\x1e(..)\xd1\xe3\x8b\x87(..)\x8b\x0e(..)\xf7\xe9\x29\x85(..)\x8b\x87(..)"#, "top_kick_right")
        let mL = first(#"\x8b\x1e(..)\xd1\xe3\x8b\x87(..)\x8b\x0e(..)\xf7\xe9\x01\x85(..)\x8b\x87(..)"#, "top_kick_left")
        var fx: [Int], fy: [Int], angR: Int? = nil, angL: Int? = nil
        if let mR, let mL {
            let fxTab = mL.0.u16(2), fyTab = mL.0.u16(5)
            fx = (0..<10).map { dsw(fxTab + 2 * $0) }
            fy = (0..<10).map { dsw(fyTab + 2 * $0) }
            angR = mR.0.u16(1); angL = mL.0.u16(1)
        } else {
            fx = fallback("flipper_kick.fx", EP1.flipTblX)
            fy = fallback("flipper_kick.fy", EP1.flipTblY)
        }
        let nudgeImp: JSONValue
        if let (m, _) = first(#"\x80\x3e(..)(.)\x72.\x80\x3e(..)(.)\x72.\x80\x3e(..)(.)\x77.\xa0(..)\xc0\xe0(.)\xb4\x00\x29\x85(..)\x83\x85(..)(.)"#, "nudge_impulse") {
            nudgeImp = .obj([("min_timer", .int(m.u8(2))), ("dir_min", .int(m.u8(4))), ("dir_max", .int(m.u8(6))), ("vy_shift", .int(m.u8(8))), ("vx", .int(m.u8(11)))])
        } else {
            nudgeImp = fallback("nudge.impulse", EP1.nudgeImpulse)
        }
        let bigHit = first(#"\x81\xbd(..)(..)\x7d.\x83\x3e..\xff\x75.\x83\x3e..(.)"#, "sfx_big_hit")
        out["collision"] = .obj([
            ("flipper_contact_split_x", .int(splitX)),
            ("big_hit_sfx", bigHit.map { .obj([("vy_below", .int($0.0.s16(2))), ("hit_count", .int($0.0.u8(3)))]) } ?? .null),
            ("note", .string("probe order 48..1; wall LUT per level; 'active' -> kicker (cooldown gated), 'flipper' value -> contact 1 if (u16)x <= split else 2, only if that flipper moved up on the previous flipper_update")),
        ])
        var fk = JSONObject([("ranges", sideRanges), ("vy_zero_side", .int(vyZeroSide)), ("vy_zero_top", .int(vyZeroTop)), ("fx", .ints(fx)), ("fy", .ints(fy)),
                             ("note", .string("k=dir-1. contact && lo<=k<=side_max: v += n[side_index]*(p5,p6) (vy zeroed first if vy>=vy_zero_side); contact && (k<lo || k>top_max): same with tip_index; both every loop iteration, y-=1, no push-out. side_max<k<=top_max: y-=1, then (first response only) vy=0 if vy>=vy_zero_top; left: vx+=fx[a]*p3, right: vx-=fx[a]*p3; vy-=fy[a]*p4 (a = that flipper's angle)"))])
        out["flipper_kick"] = .object(fk)   // (key position as in Python; completed below)
        out["nudge_impulse"] = nudgeImp
        var gates: [(Int, Int)] = []
        if let ca = emu?.collisionResponseDirStored, let fc = emuDS["flipper_contact"], let by = emuDS["ball_y"] {
            let gp = #"\x80\x3e"# + w(fc) + #"\x00(?:\x74.|\x75\x03\xe9..)\x81\xbd"# + w(by) + #"(..)\x72"#
            gates = rx(gp).all(code.data, in: code.range(ca, ca + 0x120)).map { ($0.start - code.base, $0.u16(1)) }
        }
        fk["side_min_y"] = gates.first.map { .int($0.1) } ?? .null
        fk["top_min_y"] = gates.count > 1 ? .int(gates[1].1) : .null
        fk["gate_note"] = .string("if not null: a flipper contact with (u16) ball y < side_min_y takes the plain one-pixel push-out instead of the side/tip kick; on the first response it still takes the top kick, or with y < top_min_y the upper_kick (tools/engine_overrides)")
        out["flipper_kick"] = .object(fk)
        for (a, v) in gates { found["flipper_gate_\(v)"] = .hex(a) }

        // ---- flippers
        var keyVars: [Int: String] = [:]
        if let k = first(#"\x3c\x2a\x75.\x2e\xc6\x06(..)\x01"#, "key_lflip") { keyVars[k.0.u16(1)] = "left" }
        if let k = first(#"\x3c\x36\x75.\x2e\xc6\x06(..)\x01"#, "key_rflip") { keyVars[k.0.u16(1)] = "right" }
        var groups: [JSONObject] = []
        var flippers: [JSONObject] = []
        let flList = (cj["flippers"]?.arrayValue ?? []).sorted { ($0["code_ip"]!.hexInt ?? 0) < ($1["code_ip"]!.hexInt ?? 0) }
        var allPositions: [[[Int]]] = []
        for f in flList {
            let tab = f["pointer_table"]!.hexInt!
            let half = f["half"]!.isNull ? 1 : f["half"]!.intValue!
            let base = f["base"]!.intValue!
            let ip = f["code_ip"]!.hexInt!
            let dm = search(#"\x26\x88\x15(\x26\x88\x95(..))?\xe2"#, ip, ip + 0x20)
            let extra: Int? = (dm != nil && dm!.has(1)) ? dm!.s16(2) : nil
            var positions: [[Int]] = []
            for k in 0..<10 {
                let pp = dsw(tab + 2 * k, signed: false)
                let cnt = dsw(pp, signed: false)
                var offs: [Int] = []
                for j in 0..<cnt {
                    let o = dsw(pp + 2 + 2 * j, signed: false)
                    offs.append(half * EngineExport.HALF + ((o + base) & 0xFFFF))
                    if let e = extra { offs.append(half * EngineExport.HALF + ((o + base + e) & 0xFFFF)) }
                }
                positions.append(offs)
            }
            var angleVar: Int? = nil, drawnVar: Int? = nil
            for r in code.all(rx(#"\x8b\x36(..)\xd1\xe6\x8b\xb4"# + w(tab))) {
                let s = r.1
                if s < ip && ip - s < 0x10 { angleVar = r.0.u16(1) }
                else if s < ip && ip - s < 0x100 { drawnVar = r.0.u16(1) }
            }
            var gi = groups.firstIndex { angleVar != nil && $0["angle_var"]?.stringValue == pyHex(angleVar!) }
            if gi == nil {
                let segA = max(0, ip - 0x90)
                var key: String? = nil
                if let km = code.all(rx(#"\x2e\x80\x3e(..)\x01\x74"#), segA, ip).last { key = keyVars[km.0.u16(1)] }
                let mv = code.all(rx(#"\xc6\x06(..)\x01\xff\x0e(..)"#), segA, ip)
                let movingVar = mv.last.map { $0.0.u16(1) }
                let rm = code.all(rx(#"\x83\x3e(..)(.)[\x74\x75]"#), segA, ip).filter { angleVar != nil && angleVar != 0 && $0.0.u16(1) == angleVar! && $0.0.u8(2) != 0 }.map { $0.0.u8(2) }
                let rest = rm.max() ?? fallback("flipper_groups[\(groups.count)].rest_angle", 9)
                if key == nil {
                    let pts = positions[9]
                    let meanX = Double(pts.reduce(0) { $0 + $1 % EngineExport.W }) / Double(max(1, pts.count))
                    key = meanX < Double(EngineExport.W) / 2 ? "left" : "right"
                    fallbacks.append("flipper_groups[\(groups.count)].key")
                }
                var g = JSONObject()
                g["key"] = .string(key!)
                g["value"] = f["value"]!
                g["rest_angle"] = .int(rest)
                g["init_angle"] = .int(angleVar.map { dsw($0) } ?? fallback("flipper_groups[\(groups.count)].init_angle", 2))
                g["init_drawn"] = .int(drawnVar.map { dsw($0) } ?? fallback("flipper_groups[\(groups.count)].init_drawn", 2))
                g["angle_var"] = (angleVar ?? 0) != 0 ? .hex(angleVar!) : .null
                g["drawn_var"] = (drawnVar ?? 0) != 0 ? .hex(drawnVar!) : .null
                g["moving_var"] = (movingVar ?? 0) != 0 ? .hex(movingVar!) : .null
                groups.append(g)
                gi = groups.count - 1
            }
            flippers.append(JSONObject([("group", .int(gi!)), ("outline_half", .int(half)), ("outline_base", .int(base)), ("second_row", .intOrNull(extra)),
                                        ("draw_ip", .hex(ip)), ("positions", .array(positions.map { .ints($0) }))]))
            allPositions.append(positions)
        }
        func byVar(_ field: String, _ v: Int?, _ def: Int) -> Int {
            for (j, g) in groups.enumerated() where v != nil && g[field]?.stringValue == pyHex(v!) { return j }
            fallbacks.append("flipper_map.\(field)")
            return def
        }
        let leftDefault = groups.firstIndex { $0["key"]?.stringValue == "left" } ?? 0
        let rightDefault = groups.firstIndex { $0["key"]?.stringValue == "right" } ?? min(1, groups.count - 1)
        let c1m = byVar("moving_var", mvL, leftDefault), c2m = byVar("moving_var", mvR, rightDefault)
        let c1a = byVar("angle_var", angL, leftDefault), c2a = byVar("angle_var", angR, rightDefault)
        out["flipper_map"] = .obj([("contact1_moving", .int(c1m)), ("contact2_moving", .int(c2m)), ("contact1_angle", .int(c1a)),
                                   ("contact2_angle", .int(c2a)), ("note", .string("indices into flipper_groups"))])
        // sprite frames: the sprite group that covers each outline's rest position
        if let sj {
            var sgroups: [(String, [(Int, JSONValue)])] = []
            for sp in sj["sprites"]?.arrayValue ?? [] where sp["group"]?.stringValue == "flipper" {
                let name = sp["name"]!.stringValue!
                guard let us = name.lastIndex(of: "_") else { continue }
                let gk = String(name[..<us]), fr = Int(name[name.index(after: us)...]) ?? 0
                if let i = sgroups.firstIndex(where: { $0.0 == gk }) { sgroups[i].1.append((fr, sp)) } else { sgroups.append((gk, [(fr, sp)])) }
            }
            for (fi, positions) in allPositions.enumerated() {
                let g = flippers[fi]["group"]!.intValue!
                let rest = groups[g]["rest_angle"]!.intValue!
                let pts = positions[rest].map { ($0 % EngineExport.W, $0 / EngineExport.W) }
                var best: String? = nil, score = 0
                for (gk, frs) in sgroups {
                    let s0 = frs[0].1
                    let x = s0["x"]!.intValue!, y = s0["y"]!.intValue!, w = s0["w"]!.intValue!, h = s0["h"]!.intValue!
                    let inside = pts.filter { x <= $0.0 && $0.0 < x + w && y <= $0.1 && $0.1 < y + h }.count
                    if inside > score { best = gk; score = inside }
                }
                if let best, let frs0 = sgroups.first(where: { $0.0 == best })?.1 {
                    let frs = frs0.enumerated().sorted { $0.element.0 != $1.element.0 ? $0.element.0 < $1.element.0 : $0.offset < $1.offset }.map { $0.element }
                    let s0 = frs[0].1
                    flippers[fi]["sprite"] = .obj([("frames", .strings(frs.map { $0.1["name"]!.stringValue! + ".png" })), ("x", s0["x"]!), ("y", s0["y"]!),
                                                   ("w", s0["w"]!), ("h", s0["h"]!), ("frame_rule", .string("frame = (angle + 2) / 3 (EP1 cs:10F5), clamped to frames-1"))])
                }
            }
        }
        let erase = first(#"\x8b\xb4(..)\xad\x8b\xc8\xb2(.)\xad"#, "flipper_erase").map { $0.0.u8(2) } ?? fallback("flipper_erase_value", 0x2A)
        out["flipper_erase_value"] = .int(erase)
        if let subs = cj["collision_buffer"]?["init_substitutions"]?.arrayValue, let s0 = subs.first, s0["replace"]?.intValue != erase {
            addNote("start-up substitution value \(s0["replace"]?.intValue.map(String.init) ?? "None") != flipper erase value \(erase)")
        }
        out["flipper_groups"] = .array(groups.map { .object($0) })
        out["flippers"] = .array(flippers.map { .object($0) })
        out["flipper_note"] = .string("flipper_update (EP1 cs:3CDD) once per physics step, groups in order: tilted -> angle=rest, moving=0, redraw; key held -> if angle==0 {moving=0} else {moving=1; angle-=1; redraw}; released -> moving=0; if angle!=rest {angle+=1; redraw}. redraw = write 0x2A over every member's positions[drawn], then value over positions[angle], drawn=angle. Offsets are linear into the 320x400 collision buffer.")

        // ---- plunger / serve / drain
        var plunger: JSONObject
        if let (m, _) = first(#"\x81\x3e(..)(..)([\x77\x73]).\x83\x06\1(.)"#, "plunger") {
            plunger = JSONObject([("step", .int(m.u8(4))), ("max", .int(m.u16(2))), ("cmp", .string(m.u8(3) == 0x77 ? "ja" : "jae"))])
        } else {
            var p = EP1.plunger; p["cmp"] = .string("ja")
            plunger = fallback("plunger", p)
        }
        let lane: (Int, Int)
        if let (m, _) = first(#"\x81\x3e(..)(..)\x72.\x81\x3e(..)(..)\x72.\x80\x3e(..)\x00\x74"#, "lane") { lane = (m.u16(2), m.u16(4)) }
        else { lane = fallback("plunger.lane", EP1.lane) }
        var serve: JSONObject
        if let (m, _) = first(#"\xc6\x06(..)(.)\xc7\x06(..)(..)\xc7\x06(..)\x00\x00\xc7\x06(..)\x00\x00\xc7\x06(..)(..)\xc7\x06(..)\x01\x00"#, "serve") {
            forbidden.insert(m.u16(1))
            serve = JSONObject([("x", .int(m.u16(8))), ("y", .int(m.u16(4))), ("delay", .int(m.u8(2)))])
        } else {
            serve = fallback("serve", EP1.serve)
        }
        var drainY = first(#"\x81\xbd(..)(..)\x72.\x83\xbd"#, "drain").map { $0.0.u16(2) } ?? fallback("drain_y", EP1.drainY)
        plunger["lane_min_x"] = .int(lane.0); plunger["lane_min_y"] = .int(lane.1)
        plunger["zero_vx_in_lane_when_released"] = .bool(true)
        plunger["note"] = .string("only when ball 0 active, level 0, x>=lane_min_x, y>=lane_min_y (unsigned): held -> if charge<=max: charge+=step; released -> vx=0; if charge: vy-=charge, y-=1, charge=0")
        if fallbacks.contains("serve"), let sv = emu?.serve {
            serve = JSONObject([("x", .int(sv["x"]!)), ("y", .int(sv["y"]!)), ("delay", .int(sv["delay"]!))])
            fallbacks.removeAll { $0 == "serve" }
            found["serve"] = .string("tools/emu/discover.py")
        }
        if let sv = emu?.serve {
            serve["vx"] = .int(sv["vx"] ?? 0)
            serve["vy"] = .int(sv["vy"] ?? 0)
        } else if emu != nil {
            serve["present"] = .bool(false)
            serve["note"] = .string("no serve code after the drain loop (EP1 values kept so the fields stay integers)")
        }
        if fallbacks.contains("drain_y"), let dy = emu?.drainY, dy != 0 {
            drainY = dy
            fallbacks.removeAll { $0 == "drain_y" }
            found["drain"] = .string("tools/emu/discover.py")
        }
        plunger["kind"] = .string(emu?.plunger?.kind ?? "charge")
        if emu?.plunger?.kind == "launch_flag" {
            plunger["note"] = .string("no plunger lane: while no ball is active, holding the plunger sets the launch flag (ds:\(String(format: "%04x", emuDS["plunger_charge"] ?? 0))) to max; on release the ball is placed per 'launch'. step/cmp/lane fields are EP1 fallbacks")
            plunger["launch"] = emu?.launch.map { .object(JSONObject($0.map { ($0.0, .int($0.1)) })) } ?? .null
        }
        out["plunger"] = .object(plunger)
        out["serve"] = .object(serve)
        out["drain_y"] = .int(drainY)

        // ---- nudge / tilt
        var nudge: JSONObject
        if let (m, _) = first(#"\x80\x06(..)(.)\xc6\x06(..)(.)\x83\x2e"#, "nudge") {
            forbidden.formUnion([m.u16(1), m.u16(3), m.u16(1) + 1])
            nudge = JSONObject([("tilt_add", .int(m.u8(2))), ("frames", .int(m.u8(4)))])
        } else {
            nudge = fallback("nudge", EP1.nudge)
        }
        let nl: (Int, Int)
        if let (m, _) = first(#"\x81\x3e(..)(..)\x72\x07\x83\x3e(..)(.)\x77"#, "nudge_lane") { nl = (m.u16(2), m.u8(4)) }
        else { nl = fallback("nudge.lane", EP1.nudgeLane) }
        let tiltTh = first(#"\x80\x3e(..)(.)\x76.\x80\x3e(..)\x01\x74"#, "tilt").map { $0.0.u8(2) } ?? fallback("tilt_threshold", EP1.tiltThreshold)
        nudge["tilt_threshold"] = .int(tiltTh); nudge["lane_min_x"] = .int(nl.0); nudge["lane_max_y"] = .int(nl.1)
        nudge["note"] = .string("per frame: if (nudgeA|nudgeB|space) && !tilted && !(x>=lane_min_x && y>lane_max_y) && timer==0: meter+=tilt_add (u8), timer=frames. Then timer--, meter-- (if nonzero); meter>threshold -> tilted")
        out["nudge"] = .object(nudge)

        // ---- ball-ball
        var bb: Int? = nil
        for (mm, at) in all(#"\xc7\x06(..)(..)\xc7\x06(..)(..)\x83\x3e"#) where mm.u16(1) == pDS {
            bb = mm.s16(2)
            found["ball_ball"] = .hex(at)
        }
        out["ball_ball"] = .obj([("divisor", .int(bb ?? fallback("ball_ball.divisor", EP1.ballBallDivisor))), ("max_dx", .int(15)), ("max_dy", .int(14)),
                                 ("pairs", .array([.ints([0, 1]), .ints([0, 2]), .ints([1, 2])]))])

        // ---- ball sprite
        var ball: JSONValue? = nil
        if let sj {
            for s in sj["sprites"]?.arrayValue ?? [] where s["group"]?.stringValue == "ball" {
                let fo = s["file_offset"]!.hexInt!
                let w = exe.u16(fo), h = exe.u16(fo + 2)
                if w == 15 && h == 14 {
                    ball = .obj([("w", .int(w)), ("h", .int(h)), ("transparent", .int(0)), ("pixels", .ints(data[(fo + 4)..<(fo + 4 + w * h)].map { Int($0) })),
                                 ("file_offset", s["file_offset"]!)])
                }
                break
            }
        }
        out["ball"] = ball ?? .obj([("w", .int(15)), ("h", .int(14)), ("transparent", .int(0)), ("pixels", .null)])

        // ---- sensors
        for g in groups {
            for k in ["angle_var", "drawn_var", "moving_var"] {
                if let v = g[k]?.hexInt { forbidden.formUnion([v, v + 1]) }
            }
        }
        if let pm = first(#"\x81\x3e(..)(..)([\x77\x73]).\x83\x06\1(.)"#, "plunger_var") { forbidden.formUnion([pm.0.u16(1), pm.0.u16(1) + 1]) }
        var sensors = try sensorHandlers(extraVar: extraVar, forbidden: forbidden)
        if let fm = first(#"\x3c(.)\x74\x05\x80\xfc\x00"#, "sensor_always") {
            sensors["always_fires_value"] = .int(fm.0.u8(1))
            sensors["always_fires"] = .int(fm.0.u8(1))
        } else {
            sensors["always_fires_value"] = .int(fallback("sensors.always_fires_value", 0xFE))
            if let sc = emu?.ballPixelScan, search(#"\x80\xfc\x00\x75"#, sc, sc + 0x100) != nil {
                sensors["always_fires"] = .null
                sensors["always_fires_note"] = .string("no value bypasses the lockout in this table's scan (always_fires_value is an EP1 fallback, do not use it)")
            }
        }
        out["sensors"] = .object(sensors)

        // ---- initial contents of the 5 ball slots
        var arr: [String: Int] = [:]
        for (k, v) in sensors["vars"]?.objectValue?.pairs ?? [] where k.hasSuffix(".0") { arr[k] = v.hexInt }
        let lm = first(#"\x80\xbd(..)\x01\x75\x06\xb6\x00"#, "layer_array")
        if let accArr, let lm, ["ball_x.0", "ball_y.0", "ball_vx.0", "ball_vy.0", "ball_active.0"].allSatisfy({ arr[$0] != nil }) {
            let la = lm.0.u16(1)
            out["ball_slots_initial"] = .array((0..<5).map { i in
                .obj([("active", .int(dsw(arr["ball_active.0"]! + 2 * i, signed: false))), ("x", .int(dsw(arr["ball_x.0"]! + 2 * i))),
                      ("y", .int(dsw(arr["ball_y.0"]! + 2 * i))), ("vx", .int(dsw(arr["ball_vx.0"]! + 2 * i))), ("vy", .int(dsw(arr["ball_vy.0"]! + 2 * i))),
                      ("accx", .int(dsw(accArr[0] + 2 * i))), ("accy", .int(dsw(accArr[1] + 2 * i))), ("layer", .int(dsb(la + 2 * i)))])
            })
        } else {
            fallbacks.append("ball_slots_initial")
        }
        out["timing"] = .obj([("frame_hz", .double(59.94)), ("steps_per_frame", .int(3)), ("pit_step_divisor", .int(0x189C)),
                              ("note", .string("3 physics steps per video frame (timer ISR cs:2FC6). Gravity and all per-frame logic run once per frame in the main loop; its phase relative to the 3 steps is load dependent."))])
        out["found_at"] = .object(found)
        out["fallbacks"] = .strings(fallbacks)
        if let overrides { try applyOverrides(&out, overrides) }
        return out
    }

    // MARK: kicker path (export_engine_data.kicker_path)

    func kickerPath(_ emu: EmuConfig?) -> JSONObject {
        guard let emu, let ps = emu.physicsStep, let kip = emu.kickerHit, let cool = emu.dsVars["kicker_cooldown"] else { return JSONObject() }
        let app = search(#"\xd1\xee\x53\x8b\x1e"#, ps, ps + 0x400)
        let skp = search(#"\x5b\x83\xee\x02\x75"#, ps, ps + 0x400)
        var call: Int? = nil
        for m in rx(#"\xe8"#).all(code.data, in: code.range(ps, ps + 0x400)) {
            let a = m.start - code.base
            if (a + 3 + code.s16(a + 1)) & 0xFFFF == kip { call = a; break }
        }
        guard let app, skp != nil, let call else { return JSONObject() }
        let append = app.start - code.base
        guard let head = search(#"(\x26\x80\x3f(.)\x77(.))?\x80\x3e"# + w(cool) + #"\x00\x75(.)"#, call - 0x30, call) else { return JSONObject() }
        let h0 = head.start - code.base
        let jneAt = code.pos(head, 4) - 1
        let target = (jneAt + 2 + head.s8(4)) & 0xFFFF
        var res = JSONObject([("cooling_contact", .bool(target == append)), ("path_ip", .hex(h0))])
        res["active_max"] = head.has(1) ? .int(head.u8(2)) : .null
        var window: [JSONValue] = []
        var a = head.end - code.base
        var names: [Int: String] = [:]
        if let bx = emu.dsVars["ball_x"] { names[bx] = "x" }
        if let by = emu.dsVars["ball_y"] { names[by] = "y" }
        let wre = rx(#"(?:\x81\xbd(..)(..)|\x83\xbd(..)(.))([\x77\x72])"#)
        while a < call {
            guard let mm = code.matchAt(wre, a, a + 8) else { break }
            let v = mm.has(1) ? mm.u16(1) : mm.u16(3)
            let val = mm.has(2) ? mm.u16(2) : mm.s8(4)
            window.append(.obj([("coord", .string(names[v] ?? pyHex(v))), ("no_contact_if", .string(mm.u8(5) == 0x77 ? "ja" : "jb")), ("value", .int(val))]))
            a += mm.length + 1
        }
        res["window"] = .array(window)
        var after = call + 3
        while code.bytes(after, after + 2) == [0xC7, 0x06] { after += 6 }
        let dest: Int
        if code[after] == 0xEB { dest = (after + 2 + code.s8(after + 1)) & 0xFFFF }
        else if code[after] == 0xE9 { dest = (after + 3 + code.s16(after + 1)) & 0xFFFF }
        else { dest = after }
        res["contact_on_fire"] = .bool(dest == append)
        res["path_note"] = .string("active probe: if active_max and v > active_max -> no contact; if cooldown != 0 -> contact (cooling_contact) else no contact; window tests (coord of the ball's top-left, unsigned) -> no contact; else kicker fires, and the probe counts as a contact only if contact_on_fire")
        return res
    }
}
