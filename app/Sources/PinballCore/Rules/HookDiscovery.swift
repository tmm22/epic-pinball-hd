import Foundation

// Where a table's rule code lives outside the sensor jump table, found in the user's EXE: the
// kicker routine, the dispatcher tail, the main-loop rule fragments and the end-of-ball regions
// (tools/rules.py `auto_hooks`, rules.md 4.1), the global hook stops, and the display routines
// rule code calls (`stub_routines`). A Swift port of the Python passes so that the direct-EXE rules
// backend finds exactly the code the lifted backend runs, without rules.json:
//
// * `Reach` is rules.py's `Lifter.discover` / `rule_like`: control flow from an entry, following
//   rule-like near calls (gosubs), ending at hook stops, the dispatcher epilogue and `ret`.
// * `autoHooks` is `auto_hooks`: main-loop statements (single-entry/single-exit instruction runs)
//   that lift completely and write rule state (a fixpoint over what rule code reads), merged into
//   hooks; and the liftable regions of ball_lost_fade.
// * `expressible` stands in for the lifter's "unexpressed op" test (an automatic hook the lift
//   cannot express completely is dropped, rules.md 4.1 item 6).
//
// EP1 keeps its hand annotation (rules.py EP1_HOOKS; addresses only), checked against the EXE.

public struct DiscoveredHook: Sendable, Equatable {
    public var name: String
    public var entry: Int
    public var stops: [Int]
    public var kind: String?
    public var when: String?
    public var continues: [Int: String] = [:]
}

struct Reach {
    let d: RulesDiscovery
    var routines: [Int: String]
    var body: [Int: X86Insn] = [:]
    var leaders = Set<Int>()
    var stops = Set<Int>()
    var subs = Set<Int>()
    var entries = Set<Int>()
    private var ruleLikeCache: [Int: Bool] = [:]

    init(_ d: RulesDiscovery, routines: [Int: String]) { self.d = d; self.routines = routines }

    static let jcc: Set<String> = ["je", "jne", "jb", "jae", "jbe", "ja", "jl", "jge", "jle", "jg", "js", "jns"]

    func isEpilogue(_ a: Int) -> Bool { RulesDiscovery.isEpilogue(d.code, a) }

    mutating func discover(_ entry: Int) {
        var work = [entry]
        entries.insert(entry)
        leaders.insert(entry)
        while var a = work.popLast() {
            while true {
                if (stops.contains(a) && a != entry) || isEpilogue(a) { break }
                if body[a] != nil { break }
                guard let i = d.map.insn(a) else { break }
                body[a] = i
                let m = i.mn
                let nxt = i.next
                if Self.jcc.contains(m) || m == "loop" || m == "jcxz" {
                    if let t = i.target { leaders.insert(t); leaders.insert(nxt); work.append(t) }
                } else if m == "jmp" {
                    if let t = i.target { leaders.insert(t); work.append(t) }
                    break
                } else if ["ret", "retf", "iret"].contains(m) {
                    break
                } else if m == "call", let t = i.target {
                    if routines[t] == nil, !subs.contains(t), ruleLike(t) {
                        subs.insert(t); entries.insert(t); leaders.insert(t); work.append(t)
                    }
                }
                a = nxt
            }
        }
    }

    /// A near routine lifted as a gosub: no port I/O, interrupts, string ops, far calls (except to
    /// known CS routines) or indirect jumps, within 400 instructions (following jumps, not calls).
    mutating func ruleLike(_ tgt: Int, limit: Int = 400) -> Bool {
        if let v = ruleLikeCache[tgt] { return v }
        var seen = Set<Int>(), work = [tgt]
        var ok = true
        scan: while var a = work.popLast() {
            while !seen.contains(a) {
                if seen.count > limit { ok = false; break scan }
                guard let i = d.map.insn(a) else { ok = false; break scan }
                seen.insert(a)
                let m = i.mn
                if m == "lcall", let f = i.farTarget, f.seg == d.image.entryCS, routines[f.off] != nil { a = i.next; continue }
                if ["in", "out", "int", "lcall", "ljmp", "iret", "retf"].contains(m)
                    || ["rep", "movs", "stos", "lods", "outs", "ins"].contains(where: { m.hasPrefix($0) }) { ok = false; break scan }
                if (m == "jmp" || m == "call") && i.target == nil { ok = false; break scan }
                if Self.jcc.contains(m) || m == "loop" || m == "jcxz" { if let t = i.target { work.append(t) } }
                if m == "jmp" { if let t = i.target { work.append(t) }; break }
                if m == "ret" { break }
                a = i.next
            }
        }
        ruleLikeCache[tgt] = ok
        return ok
    }
}

public struct HookDiscovery: Sendable {
    public var hooks: [String: DiscoveredHook] = [:]
    /// Every hook stop (the lifted graphs return there, whatever graph reaches them).
    public var stops = Set<Int>()
    /// Display routines called from rule code: target -> (kind, far) (rules.json `stub_routines`).
    public var stubs: [Int: (kind: String, far: Bool)] = [:]
    /// Near routines rule code runs as subroutines.
    public var subs = Set<Int>()
    public var dropped: [String] = []
    public var notes: [String] = []

    static let callRolesOK = ["message", "text", "number_text", "score_refresh", "sound_play"]
    static let flagUsers: Set<String> = ["adc", "sbb", "cmc", "rcl", "rcr", "lahf", "pushf", "setc"]

    /// EP1's hand-annotated hooks (rules.py EP1_HOOKS): name -> (entry, stops).
    static let ep1Hooks: [(String, Int, [Int])] = [
        ("kicker", 0x19C1, []), ("frame_timers", 0x06E2, [0x0711]), ("frame_counters", 0x09DC, [0x0A17]),
        ("mode_timer", 0x3B6E, []), ("flipper_lane_change", 0x102E, [0x1080]), ("lamp_flash", 0x10D0, [0x10F5]),
        ("iq_display", 0x1134, [0x119F]), ("drain", 0x0A31, [0x0A9A]), ("ball_end", 0x333E, [0x33E4]),
        ("bonus_multiplier_payout", 0x33E7, [0x340D]), ("bonus_count", 0x35D1, []), ("next_ball_skill", 0x358E, []),
    ]
    static let ep1DisplayClear = 0x5C23, ep1DisplayIdle = 0x3AF8

    public static func run(_ d: RulesDiscovery, table: Int) -> HookDiscovery {
        var out = HookDiscovery()
        var routines = d.routines
        var hooks: [String: DiscoveredHook] = [:]
        let isEP1 = table == 1 && d.image.entryCS == 0x3223 && d.image.dataSegment == 0x0015 && d.layout.kickerHit == 0x19C1
        if isEP1 {
            for (n, e, s) in ep1Hooks { hooks[n] = DiscoveredHook(name: n, entry: e, stops: s) }
            for (n, e, s) in ep1Hooks where s.isEmpty { if routines[e] == nil { routines[e] = "hook:\(n)" } }
            routines[ep1DisplayClear] = "display:clear"
            routines[ep1DisplayIdle] = "display:idle_text"
        } else {
            for k in d.kickerRoutines { hooks["kicker"] = DiscoveredHook(name: "kicker", entry: k, stops: []) }
        }
        var drop = Set<String>()
        var auto: [String: DiscoveredHook] = [:]
        if !isEP1 { auto = autoHooks(d, routines: routines, notes: &out.notes) }
        // an automatic hook the lift cannot express completely is dropped (and the rest found again
        // without it, as rules.py rebuilds; the automatic hooks do not depend on each other)
        while true {
            var hk = hooks
            for (n, h) in auto where !drop.contains(n) { hk[n] = h }
            if let t = d.dispatchTail { hk["dispatch_tail"] = DiscoveredHook(name: "dispatch_tail", entry: t, stops: []) }
            var L = Reach(d, routines: routines)
            for h in hk.values { L.stops.formUnion(h.stops) }
            for a in d.handlerIPs { L.discover(a) }
            for h in hk.values.sorted(by: { $0.entry < $1.entry }) { L.discover(h.entry) }
            var bad: [String] = []
            var es = ESFlow(d, L)
            for (n, h) in hk where auto[n] != nil {
                if !expressible(from: h.entry, L, &routines, d, table: table, es: &es) { bad.append(n) }
            }
            if !bad.isEmpty {
                drop.formUnion(bad)
                continue
            }
            out.hooks = hk
            out.stops = L.stops
            out.subs = L.subs
            // stub routines: calls in lifted code that are not gosubs
            for i in L.body.values.sorted(by: { $0.ip < $1.ip }) where i.mn == "call" || i.mn == "lcall" {
                var tgt: Int?
                if i.mn == "call" { tgt = i.target } else if let f = i.farTarget, f.seg == d.image.entryCS { tgt = f.off }
                guard let t = tgt, !(i.mn == "call" && L.subs.contains(t)) else { continue }
                var role = routines[t]
                if role == nil, d.farDSDisplay(t, table: table) { role = "display:routine_\(hex4(t).lowercased())"; routines[t] = role }
                guard let r = role else { continue }
                if ["message", "text", "number_text", "score_refresh"].contains(r) || r.hasPrefix("display:") {
                    let kind = r == "number_text" ? "number" : (r.hasPrefix("display:") ? "display" : r)
                    out.stubs[t] = (kind, i.mn == "lcall")
                }
            }
            break
        }
        out.dropped = drop.sorted()
        return out
    }

    // MARK: - expressibility (the lifter's asm / call ops)

    /// ES per instruction: forward dataflow over `mov es,[pf seg var]` / push es / pop es (rules.py
    /// `es_flow`), in the lifted code.
    struct ESFlow {
        var state: [Int: String] = [:]
        init(_ d: RulesDiscovery, _ L: Reach) {
            // per block start: walk the block and propagate; entries are unknown
            var esIn: [Int: String] = [:]
            for e in L.entries { esIn[e] = "?" }
            var changed = true
            var rounds = 0
            while changed && rounds < 50 {
                changed = false; rounds += 1
                for s in L.leaders.sorted() where L.body[s] != nil {
                    guard var cur = esIn[s] else { continue }
                    var stack: [String] = [cur]
                    var a = s
                    var last: X86Insn?
                    while let i = L.body[a] {
                        state[a] = stack.last!
                        if i.mn == "mov", i.ops.count == 2, i.ops[0] == .sreg(0) {
                            if let m = i.ops[1].memValue { stack[stack.count - 1] = m.offset == d.segTop ? "pf_top" : (m.offset == d.segBottom ? "pf_bottom" : "?") }
                            else { stack[stack.count - 1] = "?" }
                        } else if i.mn == "push", i.ops.first == .sreg(0) { stack.append(stack.last!) }
                        else if i.mn == "pop", i.ops.first == .sreg(0) { if stack.count > 1 { stack.removeLast() } else { stack[0] = "?" } }
                        last = i
                        a = i.next
                        if Reach.jcc.contains(i.mn) || ["jmp", "ret", "retf", "iret", "loop", "jcxz"].contains(i.mn) || L.leaders.contains(a) { break }
                    }
                    cur = stack.last!
                    var succ: [Int] = []
                    if let l = last {
                        if Reach.jcc.contains(l.mn) || l.mn == "loop" || l.mn == "jcxz" { if let t = l.target { succ = [t, l.next] } }
                        else if l.mn == "jmp", let t = l.target { succ = [t] }
                        else if !["ret", "retf", "iret", "jmp"].contains(l.mn) { succ = [a] }
                    }
                    for x in succ where L.body[x] != nil {
                        let old = esIn[x]
                        let new = old == nil || old == cur ? cur : "?"
                        if new != old { esIn[x] = new; changed = true }
                    }
                }
            }
        }
    }

    /// Whether the lift of the graph from `entry` (following gosubs) has no `asm`/`call` op.
    static func expressible(from entry: Int, _ L: Reach, _ routines: inout [Int: String], _ d: RulesDiscovery,
                            table: Int, es: inout ESFlow) -> Bool {
        var seen = Set<Int>(), work = [entry]
        while let s0 = work.popLast() {
            guard !seen.contains(s0), L.body[s0] != nil else { continue }
            seen.insert(s0)
            // one block: flags state as the lifter tracks it
            var F: (kind: String, constCount: Bool)? = nil
            var a = s0
            while let i = L.body[a] {
                let m = i.mn
                func memOK(_ o: X86Operand, write: Bool) -> Bool {
                    guard let mm = o.memValue else { return true }
                    let sg: String
                    if mm.seg == 1 { sg = "cs" } else if mm.seg == 0 { sg = es.state[i.ip] ?? "?" }
                    else if mm.seg == nil && mm.usesBP { sg = "ss" } else { sg = "ds" }
                    if write { return sg == "ds" || sg == "pf_top" || sg == "pf_bottom" }
                    return sg != "ss"
                }
                var ok = true
                switch m {
                case "mov":
                    if i.ops[0] == .sreg(3) { ok = false }
                    else if i.ops[0] == .sreg(0) { ok = true }
                    else { ok = memOK(i.ops[0], write: true) && memOK(i.ops[1], write: false) }
                case "lea", "stc", "clc", "cld", "nop", "cli", "sti", "pusha", "popa", "cbw": break
                case "push":
                    if case .sreg? = i.ops.first {} else { ok = memOK(i.ops[0], write: false) }
                case "pop":
                    if case .sreg? = i.ops.first {} else if case .reg? = i.ops.first {} else { ok = false }
                case "add", "sub", "and", "or", "xor":
                    ok = memOK(i.ops[0], write: true) && memOK(i.ops[1], write: false)
                    if m == "add" { F = ("addres", false) }
                    else if m == "sub", case .reg = i.ops[0] { F = ("sub", false) }
                    else { F = ("res", false) }
                case "adc":
                    ok = F?.kind == "addres" && memOK(i.ops[0], write: true) && memOK(i.ops[1], write: false)
                    F = ("res", false)
                case "sbb":
                    ok = F?.kind == "sub" && memOK(i.ops[0], write: true) && memOK(i.ops[1], write: false)
                    F = ("res", false)
                case "inc", "dec", "neg", "not":
                    ok = memOK(i.ops[0], write: true); F = ("res", false)
                case "cmp", "test":
                    ok = memOK(i.ops[0], write: false) && memOK(i.ops[1], write: false); F = ("cmp", false)
                case "shl", "shr", "sar", "sal":
                    ok = memOK(i.ops[0], write: true)
                    F = ("shiftc", i.ops.count < 2 || i.ops[1].immValue != nil)
                case "rcl":
                    ok = F?.kind == "shiftc" && F?.constCount == true && i.ops.count > 1 && i.ops[1].immValue == 1 && memOK(i.ops[0], write: true)
                    F = ("shiftc", true)
                case "mul", "div":
                    ok = memOK(i.ops[0], write: false)
                case "xchg":
                    ok = memOK(i.ops[0], write: true) && memOK(i.ops[1], write: true)
                case "loop", "ret", "retf": break
                case "jmp":
                    ok = i.target != nil
                case "call", "lcall":
                    if m == "call", let t = i.target, L.subs.contains(t) { F = ("cf", false); work.append(t); break }
                    var tgt: Int?
                    if m == "call" { tgt = i.target } else if let f = i.farTarget, f.seg == d.image.entryCS { tgt = f.off }
                    guard let t = tgt else { ok = false; break }
                    var role = routines[t]
                    if role == nil, d.farDSDisplay(t, table: table) { role = "display:routine_\(hex4(t).lowercased())"; routines[t] = role }
                    let r = role ?? ""
                    ok = ["message", "text", "number_text", "score_refresh", "sound_play"].contains(r)
                        || r.hasPrefix("gate:") || r.hasPrefix("hook:") || r.hasPrefix("display:")
                default:
                    ok = Reach.jcc.contains(m)
                }
                if !ok { return false }
                a = i.next
                if Reach.jcc.contains(m) || m == "loop" { if let t = i.target { work.append(t) }; work.append(a); break }
                if m == "jmp" { if let t = i.target { work.append(t) }; break }
                if ["ret", "retf", "iret"].contains(m) { break }
                if L.leaders.contains(a) { work.append(a); break }
            }
        }
        return true
    }

    // MARK: - automatic hooks (rules.py auto_hooks)

    static func memRefs(_ i: X86Insn) -> (w: Set<Int>, r: Set<Int>) {
        var w = Set<Int>(), r = Set<Int>()
        for (k, o) in i.ops.enumerated() {
            guard let m = o.memValue, m.capstoneDS else { continue }
            let d = m.offset
            let span = Set(d..<(d + max(1, m.size)))
            if k == 0 && !["cmp", "test", "push"].contains(i.mn) && !i.mn.hasPrefix("j") {
                w.formUnion(span)
                if i.mn != "mov" { r.formUnion(span) }
            } else {
                r.formUnion(span)
            }
        }
        return (w, r)
    }

    /// (ok, gosub target) for an instruction inside a hook (rules.py `_insn_ok`).
    static func insnOK(_ i: X86Insn, _ L: inout Reach, _ cs: Int) -> (Bool, Int?) {
        let m = i.mn
        if ["in", "out", "int", "iret", "retf", "ljmp", "hlt"].contains(m) || ["rep", "movs", "stos", "lods", "cmps", "scas"].contains(where: { m.hasPrefix($0) }) {
            return (false, nil)
        }
        if (m == "jmp" || m == "call"), !i.ops.isEmpty, i.target == nil { return (false, nil) }
        if m == "lcall" {
            let tgt = i.farTarget.flatMap { $0.seg == cs ? $0.off : nil }
            let role = tgt.flatMap { L.routines[$0] } ?? ""
            return (callRolesOK.contains(role) || role.hasPrefix("gate:") || role.hasPrefix("display:") || role.hasPrefix("hook:"), nil)
        }
        if m == "call", let t = i.target {
            let role = L.routines[t] ?? ""
            if callRolesOK.contains(role) || role.hasPrefix("gate:") || role.hasPrefix("display:") || role.hasPrefix("hook:") { return (true, nil) }
            if L.ruleLike(t) { return (true, t) }
            return (false, nil)
        }
        return (true, nil)
    }

    static func routineEnd(_ d: RulesDiscovery, _ a: Int, limit: Int = 0x800) -> Int {
        var far = a, x = a
        while x < a + limit {
            guard let i = d.map.insn(x) else { return x }
            if (Reach.jcc.contains(i.mn) || ["jmp", "loop", "jcxz"].contains(i.mn)), let t = i.target { far = max(far, t) }
            x += i.length
            if ["ret", "retf", "iret"].contains(i.mn), x > far { return x }
        }
        return x
    }

    static func codeInfo(_ d: RulesDiscovery, _ L: inout Reach, _ a: Int, _ b: Int, _ seen: inout Set<Int>, depth: Int = 0)
        -> (ok: Bool, w: Set<Int>, r: Set<Int>, keys: Bool) {
        var W = Set<Int>(), R = Set<Int>(), keys = false
        var x = a
        while x < b {
            guard let i = d.map.insn(x) else { return (false, W, R, keys) }
            x += i.length
            if i.mn == "ret" && depth == 0 { return (false, W, R, keys) }
            let (ok, sub) = insnOK(i, &L, d.image.entryCS)
            if !ok { return (false, W, R, keys) }
            if i.usesCS { keys = true }
            let (w, r) = memRefs(i)
            W.formUnion(w); R.formUnion(r)
            if let s = sub, !seen.contains(s) {
                seen.insert(s)
                let c2 = codeInfo(d, &L, s, routineEnd(d, s), &seen, depth: depth + 1)
                if !c2.ok { return (false, W, R, keys) }
                W.formUnion(c2.w); R.formUnion(c2.r); keys = keys || c2.keys
            }
        }
        return (true, W, R, keys)
    }

    static func statements(_ d: RulesDiscovery, _ a: Int, _ b: Int, exits: Set<Int>) -> [(Int, Int)] {
        var ins: [X86Insn] = [], x = a
        while x < b, let i = d.map.insn(x) { ins.append(i); x += i.length }
        var br: [(Int, Int)] = []
        for i in ins where (Reach.jcc.contains(i.mn) || ["jmp", "loop", "jcxz"].contains(i.mn)) {
            if let t = i.target, !exits.contains(t) { br.append((i.ip, t)) }
        }
        var cuts = [a]
        for k in 1..<max(1, ins.count) {
            let c = ins[k].ip
            if Reach.jcc.contains(ins[k].mn) || flagUsers.contains(ins[k].mn) { continue }
            if br.contains(where: { s, e in s < e ? (s < c && c < e) : (e < c && c <= s) }) { continue }
            cuts.append(c)
        }
        cuts.append(x)
        return (0..<(cuts.count - 1)).map { (cuts[$0], cuts[$0 + 1]) }
    }

    struct Region { var start: Int; var cuts: [Int]; var seen: Set<Int>; var stackOK: Bool }

    static func regions(_ d: RulesDiscovery, _ L: inout Reach, _ entry: Int, _ end: Int) -> [Region] {
        var out: [Region] = [], todo = [entry], done = Set<Int>()
        while !todo.isEmpty {
            let r = todo.removeFirst()
            if done.contains(r) || !(entry <= r && r < end) { continue }
            done.insert(r)
            var seen = Set<Int>(), cuts = Set<Int>(), work = [r]
            while var x = work.popLast() {
                while !seen.contains(x) && entry <= x && x < end {
                    guard let i = d.map.insn(x) else { break }
                    if !insnOK(i, &L, d.image.entryCS).0 { cuts.insert(x); todo.append(x + i.length); break }
                    seen.insert(x)
                    let m = i.mn
                    if Reach.jcc.contains(m) || m == "loop" || m == "jcxz", let t = i.target { work.append(t) }
                    if m == "jmp", let t = i.target { x = t; continue }
                    if ["ret", "retf", "iret"].contains(m) { break }
                    x += i.length
                }
            }
            out.append(Region(start: r, cuts: cuts.sorted(), seen: seen, stackOK: stackOK(d, r, seen)))
        }
        return out
    }

    static func stackOK(_ d: RulesDiscovery, _ r: Int, _ seen: Set<Int>) -> Bool {
        var work = [(r, 0)], depthAt: [Int: Int] = [:]
        while let (x0, d0) = work.popLast() {
            var x = x0, dd = d0
            while seen.contains(x) {
                if (depthAt[x] ?? 99) <= dd { break }
                depthAt[x] = dd
                guard let i = d.map.insn(x) else { break }
                let m = i.mn
                if m == "push" || m == "pushf" || m == "pusha" { dd += 1 }
                else if m == "pop" || m == "popf" || m == "popa" { dd -= 1; if dd < 0 { return false } }
                else if ["ret", "retf", "iret"].contains(m) { break }
                if Reach.jcc.contains(m) || m == "loop" || m == "jcxz", let t = i.target { work.append((t, dd)) }
                if m == "jmp", let t = i.target { x = t; continue }
                x += i.length
            }
        }
        return true
    }

    static func hookKind(_ d: RulesDiscovery, _ a: Int, _ b: Int, _ writes: Set<Int>, _ keys: Bool) -> String? {
        let L = d.layout, ds = L.dsVars
        let s = d.search
        func has(_ p: String) -> Bool { s.first(p, a, b) != nil }
        if let xg = ds["extra_gravity_timer"], has(#"\x83\x3e"# + ByteSearch.w(xg) + #"\x00"#) { return "frame_timers" }
        if let dy = L.drainY, has(#"\x81\xbd.."# + ByteSearch.w(dy)) { return "drain" }
        let lock = ds["event_lockout"].map { $0 & 0xFFFF } ?? 0xFFFF
        if (L.frameCounters + [lock]).contains(where: { has(#"\xfe\x0e"# + ByteSearch.w($0)) }) { return "frame_counters" }
        if keys, ["key_lflip", "key_rflip"].contains(where: { has(ByteSearch.w(L.csVars[$0] ?? 0xFFFF)) }) { return "flipper_press" }
        if let lt = d.lampTable, writes.contains(where: { lt.first <= $0 && $0 < lt.terminator }), has(#"\x80\x3e..\x00"#) { return "lamp_timer" }
        return nil
    }

    static func autoHooks(_ d: RulesDiscovery, routines: [Int: String], notes: inout [String]) -> [String: DiscoveredHook] {
        let cfg = d.layout
        var L0 = Reach(d, routines: routines)
        for a in d.handlerIPs + d.kickerRoutines { L0.discover(a) }
        var rule = Set<Int>()
        for i in L0.body.values { let (w, r) = memRefs(i); rule.formUnion(w); rule.formUnion(r) }
        if let lt = d.lampTable { rule.formUnion(lt.phase..<lt.terminator) }
        rule.formUnion(d.score..<(d.score + 4))
        var sound = Set<Int>()
        for (a, r) in d.roles {
            if !r.name.hasPrefix("sound") && !r.name.hasPrefix("ball.") { rule.formUnion(a..<(a + r.width)) }
            if r.name.hasPrefix("sound") { sound.formUnion(a..<(a + r.width)) }
        }
        for sw in d.sweeps { sound.insert(sw.counter) }
        var engineOnly = Set<Int>()
        for n in ["ball_x", "ball_y", "ball_vx", "ball_vy", "ball_accx", "ball_accy", "ball_active", "ball_layer"] {
            if let b = cfg.dsVars[n] { engineOnly.formUnion(b..<(b + 10)) }
        }
        let code = d.code
        var engineSpans: [(Int, Int)] = [], whole: [(Int, Int)] = []
        for (k, r) in cfg.physicsRanges.enumerated() {
            let seg = Array(code[r.start..<r.end])
            var isNudge = false
            if let na = cfg.csVars["key_nudge_a"] {
                let pat: [UInt8] = [0x2E, 0x80, 0x3E, UInt8(na & 0xFF), UInt8(na >> 8)]
                isNudge = seg.count >= 5 && (0...(seg.count - 5)).contains { Array(seg[$0..<($0 + 5)]) == pat }
            }
            let callsFade = cfg.ballLostFade.map { blf in r.skips.contains { code[$0] == 0xE8 && EngineLayout.rel16(code, $0) == blf } } ?? false
            if k == cfg.physicsRanges.count - 1 || isNudge || callsFade { engineSpans.append((r.start, r.end)) } else { whole.append((r.start, r.end)) }
        }
        // main loop statements
        let stmts = statements(d, cfg.mainLoop, cfg.frameSync, exits: [cfg.mainLoop])
        struct Info { var a: Int; var b: Int; var st: String; var w: Set<Int>; var r: Set<Int>; var keys: Bool; var n: Int }
        var info: [Info] = []
        for (a, b) in stmts {
            if engineSpans.contains(where: { $0.0 <= a && a < $0.1 }) { info.append(Info(a: a, b: b, st: "engine", w: [], r: [], keys: false, n: 0)); continue }
            var seen = Set<Int>()
            let ci = codeInfo(d, &L0, a, b, &seen)
            let n = X86Decoder.linear(code, a, b).count
            info.append(Info(a: a, b: b, st: ci.ok ? "ok" : "bad", w: ci.w, r: ci.r, keys: ci.keys, n: n))
        }
        // end of ball: regions of ball_lost_fade
        var regs: [(Region, Set<Int>, Set<Int>)] = []
        if let blf = cfg.ballLostFade {
            for rg in regions(d, &L0, blf, routineEnd(d, blf)) where rg.stackOK {
                var W = Set<Int>(), Rd = Set<Int>()
                for x in rg.seen {
                    guard let i = d.map.insn(x) else { continue }
                    let (w, r) = memRefs(i); W.formUnion(w); Rd.formUnion(r)
                    if i.mn == "call", case let (_, sub?) = insnOK(i, &L0, d.image.entryCS) {
                        var seen = Set<Int>()
                        let c2 = codeInfo(d, &L0, sub, routineEnd(d, sub), &seen, depth: 1)
                        W.formUnion(c2.w); Rd.formUnion(c2.r)
                    }
                }
                regs.append((rg, W, Rd))
            }
        }
        var R = rule
        var sel = Set<Int>(), rsel = Set<Int>()
        for _ in 0..<6 {
            for (k, x) in info.enumerated() where x.st == "ok" && !x.w.intersection(R).subtracting(sound).subtracting(engineOnly).isEmpty { sel.insert(k) }
            for (k, rg) in regs.enumerated() where !rg.1.intersection(R).subtracting(sound).subtracting(engineOnly).isEmpty { rsel.insert(k) }
            var R2 = R
            for k in sel { R2.formUnion(info[k].r) }
            for k in rsel { R2.formUnion(regs[k].2) }
            if R2 == R { break }
            R = R2
        }
        for (sa, sb) in whole {
            let ks = info.indices.filter { sa <= info[$0].a && info[$0].a < sb }
            if ks.contains(where: { sel.contains($0) }) && ks.allSatisfy({ info[$0].st == "ok" }) {
                sel.formUnion(ks)
                for k in ks { info[k].n = 0 }
            }
        }
        var hooks: [String: DiscoveredHook] = [:]
        var run: [Int] = []
        func flush() {
            while let l = run.last, !sel.contains(l) { run.removeLast() }
            if let f = run.first, let l = run.last {
                let a0 = info[f].a, b0 = info[l].b
                var W = Set<Int>(); var keys = false
                for k in run { W.formUnion(info[k].w); keys = keys || info[k].keys }
                let kind = hookKind(d, a0, b0, W, keys)
                let name = "\(kind ?? "main")_\(String(format: "%04x", a0))"
                let restart = X86Decoder.linear(code, a0, b0).contains { $0.mn == "jmp" && $0.target == cfg.mainLoop }
                hooks[name] = DiscoveredHook(name: name, entry: a0, stops: [b0] + (restart ? [cfg.mainLoop] : []),
                                             kind: kind ?? "main", when: "every_frame")
            }
            run.removeAll()
        }
        for (k, x) in info.enumerated() {
            let neutral = x.st == "ok" && x.w.isEmpty && !x.keys && !sel.contains(k)
            let big = x.n > 12
            if sel.contains(k) {
                if !run.isEmpty && (big || run.contains { sel.contains($0) && info[$0].n > 12 }) {
                    var glue: [Int] = []
                    while let l = run.last, !sel.contains(l) { glue.insert(run.removeLast(), at: 0) }
                    flush()
                    run.append(contentsOf: glue)
                }
                run.append(k)
            } else if neutral {
                run.append(k)
            } else {
                flush()
            }
        }
        flush()
        let kept = Set(rsel.map { regs[$0].0.start })
        for k in rsel.sorted() {
            let rg = regs[k].0
            var cont: [Int: String] = [:]
            for c in rg.cuts {
                guard let i = d.map.insn(c) else { continue }
                let nx = c + i.length
                if kept.contains(nx) { cont[c] = "ball_end_\(String(format: "%04x", nx))" }
            }
            let name = "ball_end_\(String(format: "%04x", rg.start))"
            hooks[name] = DiscoveredHook(name: name, entry: rg.start, stops: rg.cuts, kind: "ball_end", when: "ball_end", continues: cont)
        }
        return hooks
    }
}
