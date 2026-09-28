import Foundation

// The engine roles and routine roles of a table's rule code, found in the user's EXE with the code
// patterns of tools/rules.py (`Table.discover`) and the collision-loop shapes of tools/collision.py
// that it reads through collision.json (wall loop, occlusion scan, sensor dispatcher, jump table,
// playfield segment variables). This is what the direct-EXE rules backend needs instead of
// rules.json: where the score, ball working copy, lamps, sounds, lockouts and display routines are.

public struct RulesDiscovery: @unchecked Sendable {
    public let map: CodeMap
    public let search: ByteSearch
    public let layout: EngineLayout
    public var image: ExeImage { map.image }
    public var code: [UInt8] { map.image.code }

    /// DS address -> (role, width) (rules.json `engine_vars` roles).
    public private(set) var roles: [Int: (name: String, width: Int)] = [:]
    /// CS address -> routine role (score_refresh, message, text, number_text, sound_play,
    /// lamp_update, gate:gN, kicker).
    public internal(set) var routines: [Int: String] = [:]
    /// Ball slot arrays (x, y, vx, vy, active) and the slot level array.
    public private(set) var ballArrays: [String: Int] = [:]
    public private(set) var ballLayerArray = 0
    /// Sensor dispatcher entry (collision.json sensor_routine_ip) and its jump table.
    public private(set) var dispatchIP = 0
    public private(set) var tableIP = 0
    public private(set) var firstValue = 0xAA
    public private(set) var handlerIPs: [Int] = []
    public private(set) var jumpTable: [Int] = []
    public private(set) var segTop = 0, segBottom = 0
    public private(set) var kickerRoutines: [Int] = []
    public private(set) var score = 0
    public private(set) var occlusionStart = 0
    public private(set) var dispatchTail: Int?
    public struct Sweep: Sendable { public var counter: Int; public var mask: Int; public var phase: Int; public var ids: [(Int, Bool)] }
    public private(set) var sweeps: [Sweep] = []
    public struct LampTable: Sendable { public var phase: Int; public var first: Int; public var count: Int; public var terminator: Int }
    public private(set) var lampTable: LampTable?
    public private(set) var playerBlock: Range<Int>?
    public struct Gate: Sendable { public var routine: Int; public var control: Int?; public var values: [Int]; public var half: Int; public var offsets: [Int] }
    public private(set) var gates: [Gate] = []
    public private(set) var notes: [String] = []

    public enum Failure: Error, CustomStringConvertible {
        case notFound(String)
        public var description: String { switch self { case let .notFound(s): return "rules discovery: \(s) not found" } }
    }

    // MARK: helpers (capstone idioms of rules.py)

    /// `mem_disp(i, k)`: a direct DS operand's offset.
    static func memDisp(_ i: X86Insn, _ k: Int) -> Int? {
        guard k < i.ops.count, let m = i.ops[k].memValue, m.isDirect, m.capstoneDS else { return nil }
        return m.offset
    }
    /// op0 is `size ptr [..]` without a segment prefix.
    static func isMemNoSeg(_ o: X86Operand?, _ size: Int) -> Bool {
        guard let m = o?.memValue else { return false }
        return m.size == size && m.seg == nil
    }

    public init(image: ExeImage) throws {
        let s = ByteSearch(image.code)
        search = s
        layout = try EngineLayout.discover(image: image, search: s)
        map = CodeMap(image: image)
        try discover()
    }

    // MARK: collision.py shapes

    mutating func collisionShapes() throws {
        let c = code, s = search
        // pf_ptrs: lcall getter / mov [top],ax / add ax,0FA0h / mov [bot],ax
        guard let pf = s.first(#"\x9a....\xa3(..)\x05\xa0\x0f\xa3(..)"#) else { throw Failure.notFound("playfield segment variables") }
        segTop = pf.u16(1)!; segBottom = pf.u16(2)!
        // wall loop: add bx,[si+RING]; cmp es:[bx],al ... back to mov si,60h
        guard let wl = s.first(#"\x03\x9c(..)\x26\x38\x07"#) else { throw Failure.notFound("wall loop") }
        var start: Int?
        for back in 4..<80 where c[wl.start - back] == 0xBE && c[wl.start - back + 1] == 0x60 && c[wl.start - back + 2] == 0x00 {
            start = wl.start - back; break
        }
        guard let ws = start else { throw Failure.notFound("wall loop start") }
        // mov bx,[di+X] right before; mov ax,[di+Y]; mov bx,14h; mul bx; add ax,[top]; mov es,ax
        var bxv: Int?, byv: Int?
        if c[ws - 4] == 0x8B, c[ws - 3] == 0x9D { bxv = Int(c[ws - 2]) | Int(c[ws - 1]) << 8 }
        if let my = s.first(#"\x8b\x85(..)\xbb\x14\x00\xf7\xe3\x03\x06(..)\x8e\xc0"#, ws - 40, ws) { byv = my.u16(1) }
        var levelDisp: Int?
        for x in map.seq(ws, 60) where x.mn == "cmp" && levelDisp == nil {
            if x.ops.count == 2, let m = x.ops[0].memValue, x.ops[1].immValue == 1 { levelDisp = m.disp }
            if x.mn == "sub", x.ops == [.reg(6, 2), .imm(2, 2)] { break }
        }
        guard let bx = bxv, let lv = levelDisp else { throw Failure.notFound("wall loop variables") }
        ballArrays["x"] = bx
        if let y = byv { ballArrays["y"] = y }
        ballLayerArray = lv & 0xFFFF
        // occlusion scan: lea di,[copy]; mov cx,n; rep movsb, preceded by lea si,[sprite] / mov si,[bx+T]
        guard let oc = s.first(#"\x8d\x3e(..)\xb9(..)\xf3\xa4"#) else { throw Failure.notFound("occlusion loop") }
        var ip = oc.start
        if (c[ip - 4] == 0x8D && c[ip - 3] == 0x36) || (c[ip - 4] == 0x8B && c[ip - 3] == 0xB7) { ip -= 4 }
        else { throw Failure.notFound("ball sprite source") }
        occlusionStart = ip
        var occLevel: Int?
        for x in map.seq(ip, 80) where x.mn == "cmp" && occLevel == nil {
            if x.ops.count == 2, let m = x.ops[0].memValue, m.size == 1, x.ops[1].immValue == 1 { occLevel = m.disp }
        }
        guard let ol = occLevel else { throw Failure.notFound("occlusion level") }
        roles[ol & 0xFFFF] = ("ball.layer", 1)
        // sensor debounce counter: the first mov ah,[X] of the occlusion setup
        for x in map.seq(ip, 30) where x.mn == "mov" && x.ops.count == 2 && x.ops[0] == .reg(4, 1) {
            if let m = x.ops[1].memValue, m.rm == nil { roles[m.offset] = ("sensor_lockout", 1); break }
        }
        // jump table: sub bx,first; shl bx,1; mov bx,cs:[bx+T]; jmp bx
        guard let tr = s.first(#"\x81\xeb(..)\xd1\xe3\x2e\x8b\x9f(..)\xff\xe3"#) else { throw Failure.notFound("sensor jump table") }
        firstValue = tr.u16(1)!
        tableIP = tr.u16(2)!
        let n = 0x100 - firstValue - 1
        jumpTable = (0..<max(0, n)).map { image.csWord(tableIP + 2 * $0) }
        handlerIPs = Set(jumpTable).sorted()
        // the dispatcher: the routine the pixel scan calls (call D; mov ah,[lockout])
        guard let scan = layout.ballPixelScan, let dc = s.first(#"\xe8..\x8a\x26"#, scan, scan + 0x100) else { throw Failure.notFound("sensor dispatcher call") }
        dispatchIP = EngineLayout.rel16(c, dc.start)
        // kicker routine: the wall loop's call (collision.json wall_events)
        if let k = layout.kickerHit { kickerRoutines = [k] }
    }

    // MARK: rules.py Table.discover

    mutating func discover() throws {
        try collisionShapes()
        let bx = ballArrays["x"]!
        let ecfg = layout.dsVars
        var fieldOf: [Int: String] = [bx: "x", bx + 0x0C: "y", bx - 0x46: "vx", bx - 0x3A: "vy"]
        if let x = ecfg["ball_x"], let y = ecfg["ball_y"], let vx = ecfg["ball_vx"], let vy = ecfg["ball_vy"], x == bx {
            fieldOf = [x: "x", y: "y", vx: "vx", vy: "vy"]
        }
        let all = map.allInsns
        let md = Self.memDisp
        // ball working copy + writeback: cmp byte [W],0; je; 4x (mov ax,[O]; mov [di+ARR],ax)
        outer: for i in all where i.mn == "cmp" && i.ops.count == 2 && i.ops[1].immValue == 0 && i.ops[0].size == 1 {
            guard let wv = md(i, 0) else { continue }
            let s = map.seq(i.ip, 10)
            guard s.count == 10, s[1].mn == "je" else { continue }
            var pairs: [(Int, Int)] = []
            for k in stride(from: 2, to: 10, by: 2) {
                let ld = s[k], st = s[k + 1]
                guard ld.mn == "mov", st.mn == "mov", ld.ops.count == 2, ld.ops[0] == .reg(0, 2), Self.isMemNoSeg(ld.ops[1], 2) else { break }
                guard let o = md(ld, 1), st.ops.count == 2, st.ops[1] == .reg(0, 2), let m = st.ops[0].memValue, m.seg == nil,
                      m.rm == 5, m.disp > 0 else { break }
                pairs.append((o, m.disp & 0xFFFF))
            }
            if pairs.count == 4, pairs.contains(where: { $0.1 == bx }) {
                roles[wv] = ("ball.writeback", 1)
                for (o, arr) in pairs {
                    guard let f = fieldOf[arr] else { notes.append("unexpected writeback array \(hex4(arr))"); continue }
                    roles[o] = ("ball.\(f)", 2)
                    ballArrays[f] = arr
                }
                break outer
            }
        }
        if ballArrays["active"] == nil { ballArrays["active"] = ecfg["ball_active"] ?? bx - 0x0C }
        if ballArrays["vx"] == nil { ballArrays["vx"] = ecfg["ball_vx"] ?? bx - 0x46 }
        if ballArrays["vy"] == nil { ballArrays["vy"] = ecfg["ball_vy"] ?? bx - 0x3A }

        // score: the most common add word [S],imm; adc word [S+2],imm
        var counts: [Int: Int] = [:], order: [Int] = []
        for i in all where i.mn == "add" && i.ops.count == 2 && Self.isMemNoSeg(i.ops[0], 2) && i.ops[1].immValue != nil {
            guard let s0 = md(i, 0), let j = map.insn(i.ip + i.length), j.mn == "adc", md(j, 0) == s0 + 2 else { continue }
            if counts[s0] == nil { order.append(s0) }
            counts[s0, default: 0] += 1
        }
        guard let sc = Self.mostCommon(counts, order) else { throw Failure.notFound("score") }
        score = sc
        roles[sc] = ("score", 4)
        // score_refresh: near call right after mov ax,[S]; mov dx,[S+2]
        counts = [:]; order = []
        for i in all where i.mn == "mov" && i.ops.count == 2 && i.ops[0] == .reg(0, 2) && md(i, 1) == sc && Self.isMemNoSeg(i.ops[1], 2) {
            let s = map.seq(i.ip, 3)
            guard s.count == 3, s[1].mn == "mov", s[1].ops.count == 2, s[1].ops[0] == .reg(2, 2), md(s[1], 1) == sc + 2,
                  s[2].mn == "call", let t = s[2].target else { continue }
            if counts[t] == nil { order.append(t) }
            counts[t, default: 0] += 1
        }
        if let t = Self.mostCommon(counts, order) { routines[t] = "score_refresh" }
        // message routine: near call preceded (within 4) by lea bx,[..] and a `di, ..` instruction;
        // far calls into CS in the same context are text routines (top 3)
        counts = [:]; order = []
        var far: [Int: Int] = [:], farOrder: [Int] = []
        var prev: [X86Insn] = []
        for i in all {
            if i.mn == "call" || i.mn == "lcall" {
                let hasBX = prev.contains { $0.mn == "lea" && $0.ops.first == .reg(3, 2) }
                let hasDI = prev.contains { $0.ops.first == .reg(7, 2) }
                if hasBX && hasDI {
                    if i.mn == "call", let t = i.target {
                        if counts[t] == nil { order.append(t) }
                        counts[t, default: 0] += 1
                    } else if i.mn == "lcall", let f = i.farTarget, f.seg == image.entryCS {
                        if far[f.off] == nil { farOrder.append(f.off) }
                        far[f.off, default: 0] += 1
                    }
                }
            }
            prev.append(i)
            if prev.count > 4 { prev.removeFirst() }
        }
        if let t = Self.mostCommon(counts, order) { routines[t] = "message" }
        for t in Self.topN(far, farOrder, 3) where routines[t] == nil { routines[t] = "text" }
        // number formatting: far call into CS whose first 12 instructions compare dx with [di..]
        for i in all where i.mn == "lcall" {
            guard let f = i.farTarget, f.seg == image.entryCS, routines[f.off] == nil else { continue }
            if map.seq(f.off, 12).contains(where: { b in
                b.mn == "cmp" && b.ops.count == 2 && b.ops[0] == .reg(2, 2) && (b.ops[1].memValue.map { $0.size == 2 && $0.seg == nil && $0.registers.first == "di" && $0.rm == 5 } ?? false)
            }) { routines[f.off] = "number_text" }
        }
        // sfx queue: cmp word [Q],-1 ... mov ax,[Q] ... lcall play (sound.rate = the word set to 11000)
        sfx: for i in all where i.mn == "cmp" && i.ops.count == 2 && Self.isMemNoSeg(i.ops[0], 2) && i.ops[1].immValue == -1 {
            guard let q = md(i, 0) else { continue }
            let s = map.seq(i.ip, 24)
            guard let k0 = s.firstIndex(where: { $0.ops.count == 2 && $0.ops[0] == .reg(0, 2) && md($0, 1) == q && Self.isMemNoSeg($0.ops[1], 2) }) else { continue }
            for j in s[k0...] {
                if j.mn == "mov", j.ops.count == 2, Self.isMemNoSeg(j.ops[0], 2), j.ops[1].immValue == 0x2AF8, let r = md(j, 0) { roles[r] = ("sound.rate", 2) }
                if j.mn == "lcall", let f = j.farTarget {
                    routines[f.off] = "sound_play"
                    roles[q] = ("sound.queue", 2)
                    break
                }
            }
            if roles[q] != nil { break sfx }
        }
        // immediate sound: cmp word [N],0; je; mov ax,[N]; lcall play; mov word [N],0
        let play = Set(routines.filter { $0.value == "sound_play" }.keys)
        for i in all where i.mn == "cmp" && i.ops.count == 2 && Self.isMemNoSeg(i.ops[0], 2) && i.ops[1].immValue == 0 {
            guard let nv = md(i, 0) else { continue }
            let s = map.seq(i.ip, 5)
            guard s.count == 5, s[2].ops.count == 2, s[2].ops[0] == .reg(0, 2), md(s[2], 1) == nv, Self.isMemNoSeg(s[2].ops[1], 2),
                  s[3].mn == "lcall", let f = s[3].farTarget, play.contains(f.off),
                  s[4].ops.count == 2, md(s[4], 0) == nv, s[4].ops[1].immValue == 0, Self.isMemNoSeg(s[4].ops[0], 2) else { continue }
            if roles[nv] == nil { roles[nv] = ("sound.now", 2) }
        }
        // pitch sweeps: inc byte [A]; (..) mov al,[A]; and al,M; cmp al,P
        let rate = roles.first { $0.value.name == "sound.rate" }?.key
        var found: [(Int, Int, Int, Int)] = []
        for i in all where i.mn == "inc" && i.ops.count == 1 && Self.isMemNoSeg(i.ops[0], 1) {
            guard let A = md(i, 0) else { continue }
            let s = map.seq(i.ip, 7)
            guard let k0 = (1..<5).first(where: { k in k + 2 < s.count && s[k].ops.count == 2 && s[k].ops[0] == .reg(0, 1) && md(s[k], 1) == A && Self.isMemNoSeg(s[k].ops[1], 1) }) else { continue }
            guard s[k0 + 1].mn == "and", s[k0 + 2].mn == "cmp", s[k0 + 2].ops.first == .reg(0, 1),
                  let mask = s[k0 + 1].ops.last?.immValue, let phase = s[k0 + 2].ops.last?.immValue else { continue }
            found.append((i.ip, A, mask, phase))
        }
        for (n, f) in found.enumerated() {
            let endA = n + 1 < found.count ? found[n + 1].0 : f.0 + 0x80
            var body: [X86Insn] = []
            var x = f.0
            while x < endA, body.count < 40, let j = map.insn(x) { body.append(j); x += j.length }
            var ids: [(Int, Bool)] = []
            for (k, j) in body.enumerated() where j.mn == "mov" && j.ops.count == 2 && j.ops[0] == .reg(0, 2) && Self.isMemNoSeg(j.ops[1], 2) && k + 1 < body.count {
                guard let v = md(j, 1), v != rate, !ids.contains(where: { $0.0 == v }) else { continue }
                if let r = roles[v], !r.name.hasPrefix("sound.sweep@") { continue }
                let atEnd = body[k + 1].mn == "cmp" && body[k + 1].ops.count == 2 && body[k + 1].ops[0] == .reg(0, 2) && body[k + 1].ops[1].immValue == 0
                ids.append((v, atEnd))
            }
            let key = String(format: "sound.sweep@%04x", f.1)
            roles[f.1] = (key, 1)
            for (v, atEnd) in ids where roles[v] == nil { roles[v] = ("\(key).\(atEnd ? "end_id" : "step_id")", 2) }
            sweeps.append(Sweep(counter: f.1, mask: f.2, phase: f.3, ids: ids))
        }
        // lamp table: callers "lea si,[T]; lcall L" of the routine with the lamp blit signature
        var lampRT: Int?
        for m in search.all(#"\xba..\x8e\xda\x8b\xb7..\x56\x9a"#) {
            if let f = map.function(containing: m.start) { lampRT = f }
        }
        if let lr = lampRT {
            routines[lr] = "lamp_update"
            var cands: [Int?] = []
            let addrs = map.sortedAddrs
            for (k, i) in all.enumerated() where i.mn == "lcall" {
                guard let f = i.farTarget, f.off == lr else { continue }
                for b in addrs[max(0, k - 24)..<k].reversed() {
                    let p = map.insns[b]!
                    if p.mn == "lea", p.ops.first == .reg(6, 2) { cands.append(md(p, 1)); break }
                    if p.mn == "mov", p.ops.count == 2, p.ops[0] == .reg(6, 2), let mm = p.ops[1].memValue, mm.rm == 7, mm.seg == nil { continue }
                }
            }
            if let m = search.first(#"\x8d\x3e(..)\x8d\x0e(..)\x2b\xcf"#) { playerBlock = m.u16(1)!..<m.u16(2)! }
            var best: (Int, Int, (Bool, Int))?
            for t in Set(cands.compactMap { $0 }).sorted() {
                guard let end = (t + 1..<image.dsBytes.count).first(where: { image.dsBytes[$0] == 0xFF }) else { continue }
                let inside = playerBlock?.contains(t) ?? false
                let stores = all.filter { i in
                    i.mn == "mov" && Self.isMemNoSeg(i.ops.first, 1) && (md(i, 0).map { t < $0 && $0 < end } ?? false)
                }.count
                let key = (inside, stores)
                if best == nil || (key.0 ? 1 : 0, key.1) > (best!.2.0 ? 1 : 0, best!.2.1) { best = (t, end, key) }
            }
            if let b = best { lampTable = LampTable(phase: b.0, first: b.0 + 1, count: b.1 - b.0 - 1, terminator: b.1) }
        }
        // extra gravity: mov ax,[G0]; add ax,[G]; add [di+vy],ax
        if let vy = ballArrays["vy"] {
            for i in all where i.mn == "add" && i.ops.count == 2 && i.ops[0] == .reg(0, 2) && Self.isMemNoSeg(i.ops[1], 2) {
                guard let j = map.insn(i.ip + i.length), j.mn == "add", j.ops.count == 2, j.ops[1] == .reg(0, 2),
                      let m = j.ops[0].memValue, m.seg == nil, m.rm == 5, m.disp & 0xFFFF == vy, let g = md(i, 1) else { continue }
                roles[g] = ("extra_gravity", 2)
            }
        }
        // dispatcher tail: the first jb's target is `jmp X`, X not the shared epilogue
        for i in map.seq(dispatchIP, 6) where i.mn == "jb" {
            if let t = i.target, let j = map.insn(t), j.mn == "jmp", let tg = j.target, !Self.isEpilogue(code, tg) { dispatchTail = tg }
            break
        }
        // tilted: cmp byte [T],1 in the dispatcher (before the table jump)
        for i in map.seq(dispatchIP, 40) {
            if i.mn == "cmp", i.ops.count == 2, Self.isMemNoSeg(i.ops[0], 1), i.ops[1].immValue == 1, let t = md(i, 0), roles[t] == nil { roles[t] = ("tilted", 1) }
            if i.mn == "jmp", case .reg? = i.ops.first { break }
        }
        // sensor cooldown: cmp byte [T],0 in the occlusion scan
        for i in map.seq(occlusionStart, 60) where i.mn == "cmp" && i.ops.count == 2 && Self.isMemNoSeg(i.ops[0], 1) && i.ops[1].immValue == 0 {
            if let t = md(i, 0), roles[t] == nil { roles[t] = ("sensor_cooldown", 1) }
        }
        // kicker: mov byte [K],al|ah (kick strength) then mov byte [C],imm (cooldown)
        for k in kickerRoutines {
            let s = map.seq(k, 12)
            for (x, i) in s.enumerated() where i.mn == "mov" && i.ops.count == 2 && Self.isMemNoSeg(i.ops[0], 1) && (i.ops[1] == .reg(0, 1) || i.ops[1] == .reg(4, 1)) && x + 1 < s.count {
                if let a = md(i, 0), roles[a] == nil { roles[a] = ("kick_strength", 1) }
                let nx = s[x + 1]
                if nx.mn == "mov", nx.ops.count == 2, Self.isMemNoSeg(nx.ops[0], 1), nx.ops[1].immValue != nil, let a = md(nx, 0), roles[a] == nil {
                    roles[a] = ("kicker_cooldown", 1)
                }
                break
            }
        }
        // gates: routines storing a cs table of offsets into the collision buffer
        for m in search.all(#"\x2e\x8b\xbc(..)\x26\x88\x05"#) {
            guard let rt = map.function(containing: m.start) else { continue }
            let t = m.u16(1)!
            var vals: [Int] = [], ctrl: Int?, seg: Int?
            for i in map.seq(rt, 20) {
                if i.mn == "mov", i.ops.count == 2, i.ops[0] == .reg(0, 1), let v = i.ops[1].immValue { vals.append(v) }
                if i.mn == "cmp", i.ops.count == 2, Self.isMemNoSeg(i.ops[0], 1), i.ops[1].immValue == 0 { ctrl = md(i, 0) }
                if i.mn == "mov", i.ops.count == 2, i.ops[0] == .sreg(0), let mm = i.ops[1].memValue { seg = mm.offset }
            }
            let count = image.csWord(t)
            let offs = (0..<count).map { image.csWord(t + 2 + 2 * $0) }
            let half = seg == segBottom ? 1 : 0
            let gid = "gate\(gates.count)"
            gates.append(Gate(routine: rt, control: ctrl, values: vals, half: half, offsets: offs))
            routines[rt] = "gate:\(gid)"
            if let cv = ctrl, roles[cv] == nil { roles[cv] = ("\(gid).open", 1) }
        }
        for rt in kickerRoutines where routines[rt] == nil { routines[rt] = "kicker" }
        // duplicate role names get #n (rules.py)
        var seen: [String: Int] = [:]
        for a in roles.keys.sorted() {
            let r = roles[a]!
            seen[r.name, default: 0] += 1
            if seen[r.name]! > 1 { roles[a] = ("\(r.name)#\(seen[r.name]!)", r.width) }
        }
    }

    static func isEpilogue(_ c: [UInt8], _ a: Int) -> Bool {
        let b0 = c[a & 0xFFFF], b1 = c[(a + 1) & 0xFFFF], b2 = c[(a + 2) & 0xFFFF]
        return (b0 == 0x61 && b1 == 0x07 && b2 == 0xC3) || (b0 == 0x07 && b1 == 0x61 && b2 == 0xC3) || (b0 == 0x61 && b1 == 0xC3)
    }

    /// Counter.most_common(1): the highest count, ties broken by first appearance.
    static func mostCommon(_ counts: [Int: Int], _ order: [Int]) -> Int? {
        var best: Int?, bc = 0
        for k in order where counts[k]! > bc { best = k; bc = counts[k]! }
        return best
    }
    static func topN(_ counts: [Int: Int], _ order: [Int], _ n: Int) -> [Int] {
        let idx = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return order.sorted { (counts[$0]!, -idx[$0]!) > (counts[$1]!, -idx[$1]!) }.prefix(n).map { $0 }
    }

    /// The role's address.
    public func address(of role: String) -> (addr: Int, width: Int)? {
        roles.first { $0.value.name == role }.map { ($0.key, $0.value.width) }
    }

    /// rules.py `far_ds_display`: a routine that switches DS to a constant (graphics) segment, or to
    /// CS for a table read, before any memory write (not applied to EP1).
    func farDSDisplay(_ tgt: Int, table: Int) -> Bool {
        if table == 1 { return false }
        let body = map.seq(tgt, 8)
        guard body.count > 1 else { return false }
        for k in 0..<(body.count - 1) {
            let j = body[k]
            guard j.mn == "mov", j.ops.count == 2, j.ops[0] == .sreg(3), case let .reg(r, 2) = j.ops[1], [2, 0, 1].contains(r) else { continue }
            let prev: X86Insn? = k > 0 ? body[k - 1] : nil
            if let p = prev, p.mn == "mov", p.ops.count == 2, p.ops[0] == .reg(r, 2), p.ops[1] == .sreg(1),
               body[..<(k - 1)].allSatisfy({ ["push", "pusha", "cld"].contains($0.mn) }) { return true }
            guard let p = prev, p.mn == "mov", p.ops.count == 2, p.ops[0] == .reg(2, 2) || p.ops[0] == .reg(0, 2),
                  let v = p.ops[1].immValue, case .imm(_, 2) = p.ops[1], v != image.dataSegment else { return false }
            return body[..<k].allSatisfy { b in
                (["push", "pusha", "cld", "mov"].contains(b.mn) && !b.ops.isEmpty && b.ops[0].memValue == nil) || ["pusha", "cld"].contains(b.mn)
            }
        }
        return false
    }
}
