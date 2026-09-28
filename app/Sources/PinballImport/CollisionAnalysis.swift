// tools/collision.py in Swift: locates the pixel-classification code of a table EXE, evaluates
// its comparison chains for all 256 palette indices with a small symbolic interpreter, and
// produces collision_idx.npy, collision.npy and collision.json (same fields and values).
import Foundation

enum WallClass { static let empty = 0, wall = 1, wallCond = 2, active = 3, activeCond = 4, flipper = 5 }
enum OccClass { static let behind = 0, over = 1, sensor = 2, sensorCond = 3 }

/// One symbolic path's side effect (collision.py events): `call tgt` or `set byte [disp]=v`.
struct SymEvent: Hashable {
    var isCall: Bool
    var a: Int?      // call target (nil = indirect) or set disp
    var b: Int = 0   // set value

    var text: String {
        if isCall { return a.map { "call \(pyHex($0))" } ?? "call ?" }
        return "set byte [\(pyHex(a!))]=\(pyHex(b))"
    }
}

struct SymOutcome: Hashable {
    var name: String
    var events: [SymEvent]
}

/// collision.py symrun(): explores every path from `start`; registers are r8 values or unknown,
/// bytes read through ES are `pixel`, DS bytes in `knownMem` are known, unknown compares fork.
enum SymbolicRun {
    static let r8Index: [String: Int] = ["al": 0, "ah": 1, "bl": 2, "bh": 3, "cl": 4, "ch": 5, "dl": 6, "dh": 7]
    static let r16Halves: [String: (Int, Int)] = ["ax": (0, 1), "bx": (2, 3), "cx": (4, 5), "dx": (6, 7)]
    static let jccNames: Set<String> = ["jb", "jc", "jnae", "jae", "jnb", "jnc", "je", "jz", "jne", "jnz", "jbe", "jna", "ja",
                                        "jnbe", "jl", "jnge", "jge", "jnl", "jle", "jng", "jg", "jnle"]
    static let keepFlags: Set<String> = ["push", "pop", "nop", "cld", "std", "lea", "pushaw", "popaw", "pusha", "popa"]

    struct Flags { var cf: Bool; var zf: Bool; var lt: Bool }

    static func flags(_ a0: Int, _ b0: Int, bits: Int) -> Flags {
        let mask = (1 << bits) - 1
        let a = a0 & mask, b = b0 & mask
        let sa = a >> (bits - 1) != 0 ? a - (1 << bits) : a
        let sb = b >> (bits - 1) != 0 ? b - (1 << bits) : b
        return Flags(cf: a < b, zf: a == b, lt: sa < sb)
    }

    static func taken(_ m: String, _ f: Flags) -> Bool {
        switch m {
        case "jb", "jc", "jnae": return f.cf
        case "jae", "jnb", "jnc": return !f.cf
        case "je", "jz": return f.zf
        case "jne", "jnz": return !f.zf
        case "jbe", "jna": return f.cf || f.zf
        case "ja", "jnbe": return !(f.cf || f.zf)
        case "jl", "jnge": return f.lt
        case "jge", "jnl": return !f.lt
        case "jle", "jng": return f.lt || f.zf
        default: return !(f.lt || f.zf)   // jg, jnle
        }
    }

    static func run(_ code: X86Code, start: Int, regs: [String: Int] = [:], pixel: Int, knownMem: [Int: Int],
                    terminals: [Int: String], maxSteps: Int = 300) -> Set<SymOutcome> {
        var results = Set<SymOutcome>()
        var r0 = [Int?](repeating: nil, count: 8)
        for (k, v) in regs { if let i = r8Index[k] { r0[i] = v } }
        var stack: [(Int, [Int?], Flags?, [SymEvent], Int)] = [(start, r0, nil, [], 0)]
        while let (ip0, rr, fl0, ev0, st0) = stack.popLast() {
            var ip = ip0, r = rr, flags = fl0, events = ev0, steps = st0
            while true {
                if let t = terminals[ip] { results.insert(SymOutcome(name: t, events: events)); break }
                if steps > maxSteps { results.insert(SymOutcome(name: "LOST", events: events)); break }
                guard let ins = code.at(ip) else { results.insert(SymOutcome(name: "BADCODE", events: events)); break }
                steps += 1
                let m = ins.mnemonic, ops = ins.operands, nxt = ip + ins.size

                func val(_ op: X86Operand) -> Int? {
                    switch op.kind {
                    case .reg:
                        if let i = r8Index[op.reg] { return r[i] }
                        if let (lo, hi) = r16Halves[op.reg] {
                            guard let a = r[lo], let b = r[hi] else { return nil }
                            return a | b << 8
                        }
                        return nil
                    case .imm:
                        return op.imm & 0xFFFF
                    case .mem:
                        if op.segment == "es" && op.size == 1 { return pixel }
                        if op.size == 1 && op.base == nil && op.index == nil, let v = knownMem[op.disp] { return v }
                        if op.size == 1 && op.base == "di", let v = knownMem[op.disp] { return v }   // per-ball arrays [di+disp]
                        return nil
                    }
                }

                if m == "cmp" {
                    if let a = val(ops[0]), let b = val(ops[1]) { flags = self.flags(a, b, bits: ops[0].size * 8) } else { flags = nil }
                    ip = nxt; continue
                }
                if jccNames.contains(m) {
                    let tgt = ops[0].imm
                    if let f = flags { ip = taken(m, f) ? tgt : nxt }
                    else { stack.append((tgt, r, nil, events, steps)); ip = nxt }
                    continue
                }
                if m == "jmp" {
                    if ops.first?.kind == .imm { ip = ops[0].imm; continue }
                    results.insert(SymOutcome(name: "INDIRECT", events: events)); break
                }
                if m == "ret" || m == "retf" || m == "iret" { results.insert(SymOutcome(name: "RET", events: events)); break }
                if m == "call" || m == "lcall" {
                    let tgt = (ops.last?.kind == .imm) ? ops.last!.imm : nil
                    events.append(SymEvent(isCall: true, a: tgt))
                    ip = nxt; continue
                }
                if m == "loop" || m == "jcxz" {
                    stack.append((ops[0].imm, r, nil, events, steps))
                    ip = nxt; continue
                }
                if m == "mov" && ops[0].kind == .mem && ops[0].size == 1 && ops[1].kind == .imm {
                    if ops[0].segment != "es" { events.append(SymEvent(isCall: false, a: ops[0].disp, b: ops[1].imm & 0xFF)) }
                    ip = nxt; continue
                }
                if m == "mov" && ops[0].kind == .reg {
                    let v = val(ops[1])
                    if let i = r8Index[ops[0].reg] { r[i] = v.map { $0 & 0xFF } }
                    else if let (lo, hi) = r16Halves[ops[0].reg] { r[lo] = v.map { $0 & 0xFF }; r[hi] = v.map { ($0 >> 8) & 0xFF } }
                    ip = nxt; continue
                }
                for w in ins.written {
                    if let i = r8Index[w] { r[i] = nil } else if let (lo, hi) = r16Halves[w] { r[lo] = nil; r[hi] = nil }
                }
                if !keepFlags.contains(m) { flags = nil }
                ip = nxt
            }
        }
        return results
    }
}

final class CollisionAnalysis {
    static let W = 320, H = 400
    static let classNames = ["empty", "wall", "wall_conditional", "active", "active_conditional", "flipper"]
    static let occNames = ["ball_in_front", "occludes_ball", "sensor", "sensor_conditional"]

    let n: Int
    let exe: MZImage
    let ds: Int
    let segs: (Int, Int, Int)
    let code: X86Code
    /// Code segment bytes from the code base to the end of the file (collision.py `Code.find`).
    var d: [UInt8] { exe.data }

    // outputs
    var info = JSONObject()
    var buffer: [UInt8] = []          // collision_idx.npy
    var classes: [UInt8] = []         // collision.npy (2, 400, 320)
    var ball: (w: Int, h: Int, pixels: [UInt8]) = (0, 0, [])
    var playfield: [UInt8] = []

    init(table n: Int, exe: MZImage) throws {
        self.n = n
        self.exe = exe
        ds = try exe.dataSegment()
        segs = try exe.playfieldSegments()
        code = X86Code(data: exe.data, base: exe.imageOff(exe.entryCS))
    }

    // DS access (dsb / dsw)
    func dsb(_ off: Int) -> Int { exe.u8(exe.imageOff(ds, off)) }
    func dsw(_ off: Int, signed: Bool = true) -> Int { signed ? exe.s16(exe.imageOff(ds, off)) : exe.u16(exe.imageOff(ds, off)) }
    func fo(_ ip: Int) -> Int { code.base + ip }

    /// `Code.find`: regex over data[code base:] -> matches with ip = offset from the code base.
    func find(_ p: String) -> [ByteRegex.Match] { rx(p).all(d, in: code.base..<d.count) }
    func find(bytes p: [UInt8]) throws -> [ByteRegex.Match] { try rx(bytes: p).all(d, in: code.base..<d.count) }
    func ip(_ m: ByteRegex.Match) -> Int { m.start - code.base }
    func first(_ p: String, _ what: String) throws -> ByteRegex.Match {
        guard let m = rx(p).search(d, in: code.base..<d.count) else { throw ImportError("EP\(n): \(what) not found") }
        return m
    }

    func pfPtrs() throws -> (top: Int, bottom: Int, ip: Int) {
        let m = try first(#"\x9a....\xa3(..)\x05\xa0\x0f\xa3(..)"#, "playfield segment pointers")
        return (m.u16(1), m.u16(2), ip(m))
    }

    struct Substitution { var ip: Int; var segVar: Int; var lo: Int; var hi: Int; var replace: Int }

    func initSubstitutions() -> [Substitution] {
        find(#"\xa1(..)\x8e\xc0\xb0(.)\xb4(.)\xb3(.)\x26\x38\x05\x72\x08\x26\x38\x25\x77\x03\x26\x88\x1d"#).map {
            Substitution(ip: ip($0) - 3, segVar: $0.u16(1), lo: $0.u8(2), hi: $0.u8(3), replace: $0.u8(4))
        }
    }

    struct WallLoop {
        var start: Int, sample: Int, hit: Int, miss: Int, ringTable: Int, levelVar: Int
        var setupMem: [Int]
        var ballX: Int?, ballY: Int?, segVar: Int?
    }

    func wallLoop() throws -> WallLoop {
        let m = try first(#"\x03\x9c(..)\x26\x38\x07"#, "wall loop")
        let ipAdd = ip(m), ringTab = m.u16(1)
        var start: Int? = nil
        for back in 4..<80 {
            let p = fo(ipAdd - back)
            if d[p] == 0xBE && d[p + 1] == 0x60 && d[p + 2] == 0x00 { start = ipAdd - back; break }
        }
        guard let start else { throw ImportError("EP\(n): wall loop: mov si,60h not found") }
        let preRange = max(0, fo(start) - 40)..<fo(start)
        let mx = rx(#"\x8b\x9d(..)$"#).search(d, in: preRange)
        let my = rx(#"\x8b\x85(..)\xbb\x14\x00\xf7\xe3\x03\x06(..)\x8e\xc0"#).search(d, in: preRange)
        let ins = code.linear(start, 60)
        var level: Int?, hit: Int?, miss: Int?
        var setup: [Int] = []
        for (i, x) in ins.enumerated() {
            if x.mnemonic == "cmp" && level == nil && x.operands[0].kind == .mem && x.operands[1].kind == .imm && x.operands[1].imm == 1 {
                level = x.operands[0].disp
            }
            if x.mnemonic == "mov" && x.operands[0].kind == .reg && x.operands[1].kind == .mem && x.address < ipAdd && x.operands[1].size == 1 {
                setup.append(x.operands[1].disp)
            }
            if x.mnemonic == "shr" && x.opStr == "si, 1" && hit == nil { hit = x.address }
            if x.mnemonic == "sub" && x.opStr == "si, 2" {
                miss = ins[i - 1].address
                break
            }
        }
        guard let level, let hit, let miss else { throw ImportError("EP\(n): wall loop structure not recognised") }
        return WallLoop(start: start, sample: ipAdd, hit: hit, miss: miss, ringTable: ringTab, levelVar: level, setupMem: setup,
                        ballX: mx.map { $0.u16(1) }, ballY: my.map { $0.u16(1) }, segVar: my.map { $0.u16(2) })
    }

    func ballRing(_ ringTab: Int) -> ([Int], [(Int, Int)]) {
        let offs = (0..<48).map { dsw(ringTab + 2 + 2 * $0) }
        let pts = offs.map { o -> (Int, Int) in
            var y = Int((Double(o) / Double(CollisionAnalysis.W)).rounded(.down))
            var x = o - y * CollisionAnalysis.W
            if x > CollisionAnalysis.W / 2 { x -= CollisionAnalysis.W; y += 1 }
            return (x, y)
        }
        return (offs, pts)
    }

    struct Occlusion {
        var start: Int, load: Int?, nextPixel: Int?, store: Int?, levelVar: Int?
        var sprite: Int, spriteTable: Int?, spriteCopy: Int, spriteBytes: Int
        var setupMem: [Int]
    }

    func occlusionLoop() throws -> Occlusion {
        let m = try first(#"\x8d\x3e(..)\xb9(..)\xf3\xa4"#, "ball occlusion scan")
        var start = ip(m)
        let buf = m.u16(1), size = m.u16(2)
        let pre = Array(d[(fo(start) - 4)..<fo(start)])
        var spriteTable: Int? = nil
        let sprite: Int
        if pre[0] == 0x8D && pre[1] == 0x36 {
            sprite = Int(pre[2]) | Int(pre[3]) << 8; start -= 4
        } else if pre[0] == 0x8B && pre[1] == 0xB7 {
            spriteTable = Int(pre[2]) | Int(pre[3]) << 8
            sprite = dsw(spriteTable!, signed: false); start -= 4
        } else {
            throw ImportError("EP\(n): ball sprite source not recognised")
        }
        let ins = code.linear(start, 80)
        let setup = ins.prefix(30).filter {
            $0.mnemonic == "mov" && !$0.operands.isEmpty && $0.operands[0].kind == .reg && ["bl", "bh"].contains($0.operands[0].reg)
                && $0.operands[1].kind == .mem
        }.map { $0.operands[1].disp }
        var load: Int?, incDI: Int?, level: Int?
        for x in ins {
            if x.mnemonic == "cmp" && level == nil && x.operands[0].kind == .mem && x.operands[1].kind == .imm
                && x.operands[1].imm == 1 && x.operands[0].size == 1 {
                level = x.operands[0].disp
            }
            if x.mnemonic == "mov" && x.opStr == "al, byte ptr es:[di]" && load == nil { load = x.address }
            if load != nil && x.mnemonic == "inc" && x.opStr == "di" { incDI = x.address; break }
        }
        var store: Int? = nil
        if let load {
            for x in ins where x.address > load && x.mnemonic == "mov" && x.opStr == "byte ptr [si], al" { store = x.address; break }
        }
        return Occlusion(start: start, load: load, nextPixel: incDI, store: store, levelVar: level, sprite: sprite,
                         spriteTable: spriteTable, spriteCopy: buf, spriteBytes: size, setupMem: setup)
    }

    func triggerDispatch() throws -> (ip: Int, first: Int, table: Int, handlers: [Int]) {
        let m = try first(#"\x81\xeb(..)\xd1\xe3\x2e\x8b\x9f(..)\xff\xe3"#, "sensor dispatch")
        let f = m.u16(1), tab = m.u16(2)
        let count = 0x100 - f - 1
        let handlers = (0..<max(0, count)).map { exe.u16(fo(tab) + 2 * $0) }
        return (ip(m), f, tab, handlers)
    }

    func normals() throws -> (ntab: Int, nip: Int, ptab: Int, pip: Int, normal: [(Int, Int)], push: [(Int, Int)]) {
        let m = try first(#"\x8b\x87(..)\xf7\xd8\xa3"#, "normal table")
        let m2 = try first(#"\xc1\xe3\x02\x8b\x87(..)\x29\x85(..)\x8b\x87(..)\x01\x85(..)"#, "push-out table")
        let nt = m.u16(1), pt = m2.u16(1)
        return (nt, ip(m), pt, ip(m2), (0..<48).map { (dsw(nt + 4 * $0), dsw(nt + 4 * $0 + 2)) },
                (0..<48).map { (dsw(pt + 4 * $0), dsw(pt + 4 * $0 + 2)) })
    }

    struct FlipperOutline {
        var ip: Int, pointerTable: Int, value: Int, base: Int, segVar: Int?, half: Int?
        var positions: [(listPtr: Int, count: Int, pixels: [(Int, Int)])]?
    }

    func flippers(top: Int, bottom: Int) -> [FlipperOutline] {
        var out: [FlipperOutline] = []
        for m in find(#"\x8b\xb4(..)\xad\x8b\xc8\xb2(.)\xad\x8b\xf8(\x81\xc7..)?\x26\x88\x15"#) {
            let at = ip(m), tab = m.u16(1), val = m.u8(2)
            if val == 0x2A { continue }
            let base = m.has(3) ? (Int(d[m.group(3)!.lowerBound + 2]) | Int(d[m.group(3)!.lowerBound + 3]) << 8) : 0
            var segVar: Int? = nil
            for back in 3..<0x300 {
                let p = fo(at) - back
                if p >= 0 && d[p] == 0x8E && d[p + 1] == 0x06 { segVar = exe.u16(p + 2); break }
            }
            let half: Int? = segVar == top ? 0 : segVar == bottom ? 1 : nil
            var positions: [(listPtr: Int, count: Int, pixels: [(Int, Int)])]? = []
            for k in 0..<10 {
                let pp = dsw(tab + 2 * k, signed: false)
                let cnt = dsw(pp, signed: false)
                if cnt > 4000 { positions = nil; break }
                let pix = (0..<cnt).map { j -> (Int, Int) in
                    let a = (dsw(pp + 2 + 2 * j, signed: false) + base) & 0xFFFF
                    return (a % CollisionAnalysis.W, a / CollisionAnalysis.W + 200 * (half ?? 0))
                }
                positions!.append((pp, cnt, pix))
            }
            out.append(FlipperOutline(ip: at, pointerTable: tab, value: val, base: base, segVar: segVar, half: half, positions: positions))
        }
        return out
    }

    static func classFromOutcomes(_ outs0: Set<SymOutcome>, hit: String = "HIT", miss: String = "MISS") -> Int {
        let filtered = outs0.filter { $0.name == hit || $0.name == miss }
        let outs = filtered.isEmpty ? outs0 : filtered
        let hits = outs.filter { $0.name == hit }
        let calls = outs.contains { $0.events.contains { $0.isCall } }
        let sets = outs.contains { $0.events.contains { !$0.isCall } }
        let allHit = hits.count == outs.count
        if sets && !hits.isEmpty { return WallClass.flipper }
        if calls { return allHit ? WallClass.active : WallClass.activeCond }
        if allHit { return WallClass.wall }
        if !hits.isEmpty { return WallClass.wallCond }
        return WallClass.empty
    }

    static func lutRanges(_ lut: [Int], _ names: [String]) -> JSONValue {
        var out: [JSONValue] = []
        var start = 0
        for v in 1...256 {
            if v == 256 || lut[v] != lut[start] {
                if lut[start] != 0 {
                    out.append(.obj([("from", .int(start)), ("to", .int(v - 1)), ("class", .string(names[lut[start]]))]))
                }
                start = v
            }
        }
        return .array(out)
    }

    /// Values some `mov byte [disp], imm` in the code writes (sorted, unique). The Python tool
    /// concatenates the raw address bytes into the pattern, so they keep any regex meaning.
    func valuesWritten(_ disp: Int) throws -> [Int] {
        let pat: [UInt8] = [0x5C, 0x78, 0x63, 0x36, 0x5C, 0x78, 0x30, 0x36] + [UInt8(disp & 0xFF), UInt8((disp >> 8) & 0xFF)] + Array("(.)".utf8)
        return Array(Set(try find(bytes: pat).map { Int(d[$0.group(1)!.lowerBound]) })).sorted()
    }

    func analyse() throws {
        let ptrs = try pfPtrs()
        let subs = initSubstitutions()
        let wl = try wallLoop()
        let occ = try occlusionLoop()
        let trig = try triggerDispatch()
        let nrm = try normals()
        let flips = flippers(top: ptrs.top, bottom: ptrs.bottom)
        let (ringOffs, ringPts) = ballRing(wl.ringTable)

        // runtime thresholds used in the wall-loop setup (EP8: mov al,[4A7h])
        var thresholdOrder: [Int] = []
        var thresholds: [Int: (initial: Int, written: [Int])] = [:]
        for disp in wl.setupMem where thresholds[disp] == nil {
            thresholds[disp] = (dsb(disp), try valuesWritten(disp))
            thresholdOrder.append(disp)
        }
        var knownBase: [Int: Int] = [:]
        for (k, v) in thresholds { knownBase[k] = v.initial }

        // wall LUTs
        var wallLUT: [[Int]] = [], wallEvents: [[(Int, [String])]] = []
        let term = [wl.hit: "HIT", wl.miss: "MISS"]
        for level in 0...1 {
            var lut: [Int] = [], evs: [(Int, [String])] = []
            var km = knownBase; km[wl.levelVar] = level
            for v in 0..<256 {
                let outs = SymbolicRun.run(code, start: wl.start, pixel: v, knownMem: km, terminals: term)
                lut.append(CollisionAnalysis.classFromOutcomes(outs))
                let e = Set(outs.filter { $0.name == "HIT" || $0.name == "MISS" }.flatMap { $0.events.map(\.text) }).sorted()
                if !e.isEmpty { evs.append((v, e)) }
            }
            wallLUT.append(lut); wallEvents.append(evs)
        }
        var variants = JSONObject()
        for disp in thresholdOrder {
            let t = thresholds[disp]!
            for alt in t.written where alt != t.initial {
                var km = knownBase; km[disp] = alt; km[wl.levelVar] = 0
                let lut = (0..<256).map { v in
                    CollisionAnalysis.classFromOutcomes(SymbolicRun.run(code, start: wl.start, pixel: v, knownMem: km, terminals: term))
                }
                variants["level0_with_[\(pyHex(disp))]=\(pyHex(alt))"] = .ints(lut)
            }
        }

        // occlusion / sensor LUTs
        var occKnown: [Int: Int] = [:]
        var occOrder: [Int] = []
        for d0 in occ.setupMem where occKnown[d0] == nil { occKnown[d0] = dsb(d0); occOrder.append(d0) }
        var occThresholds = JSONObject()
        for d0 in occOrder {
            occThresholds[pyHex(d0)] = .obj([("initial", .int(occKnown[d0]!)), ("values_written_by_code", .ints(try valuesWritten(d0)))])
        }
        var occLUT: [[Int]] = []
        var sensorCalls = Set<Int?>()
        var oterm: [Int: String] = [:]
        if let np = occ.nextPixel { oterm[np] = "NEXT" }
        if let s = occ.store { oterm[s] = "OVER" }
        for level in 0...1 {
            var lut: [Int] = []
            var km = occKnown
            if let lv = occ.levelVar { km[lv] = level }
            for v in 0..<256 {
                let outs = SymbolicRun.run(code, start: occ.start, pixel: v, knownMem: km, terminals: oterm).filter { $0.name == "NEXT" || $0.name == "OVER" }
                let calls = outs.flatMap { $0.events.filter(\.isCall) }
                for e in calls { sensorCalls.insert(e.a) }
                if outs.contains(where: { $0.name == "OVER" }) { lut.append(OccClass.over) }
                else if !calls.isEmpty { lut.append(outs.allSatisfy { $0.events.contains { $0.isCall } } ? OccClass.sensor : OccClass.sensorCond) }
                else { lut.append(OccClass.behind) }
            }
            occLUT.append(lut)
        }

        // which sensor values reach the dispatch jump table, per level
        let handlers = trig.handlers
        var counts: [Int: Int] = [:]
        for h in handlers { counts[h, default: 0] += 1 }
        let nullHandler = counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key ?? 0
        func jmpChain(_ h0: Int) -> Int {
            var h = h0
            var seen = Set<Int>()
            while !seen.contains(h) {
                seen.insert(h)
                guard let x = code.at(h), x.mnemonic == "jmp", x.operands.first?.kind == .imm else { break }
                h = x.operands[0].imm
            }
            return h
        }
        let nullEnd = jmpChain(nullHandler)
        let sensorFn = sensorCalls.compactMap { $0 }.sorted()
        var dispatch: [[(Int, Int, Bool)]] = [[], []]
        if let fn = sensorFn.first {
            let dterm = [trig.ip: "DISPATCH"]
            for level in 0...1 {
                for v in 0..<256 where occLUT[level][v] == OccClass.sensor || occLUT[level][v] == OccClass.sensorCond {
                    var km: [Int: Int] = [:]
                    if let lv = occ.levelVar { km[lv] = level }
                    let outs = SymbolicRun.run(code, start: fn, regs: ["al": v], pixel: v, knownMem: km, terminals: dterm)
                    let reach = outs.filter { $0.name == "DISPATCH" }
                    if !reach.isEmpty && trig.first <= v && v <= 0xFE {
                        let h = handlers[v - trig.first]
                        if jmpChain(h) != nullEnd { dispatch[level].append((v, h, reach.count == outs.count)) }
                    }
                }
            }
        }

        func describe(_ h: Int) -> [X86Instruction] {
            var out: [X86Instruction] = []
            for x in code.linear(h, 10) {
                out.append(x)
                if ["jmp", "ret", "retf"].contains(x.mnemonic) { break }
            }
            return out
        }
        // sensor debounce counter: 'mov ah, byte ptr [cd]' in the occlusion setup
        var cd: Int? = nil
        for x in code.linear(occ.start, 30) where x.mnemonic == "mov" && x.opStr.hasPrefix("ah, byte ptr [") && x.operands[1].base == nil {
            cd = x.operands[1].disp
            break
        }
        var handlerDesc = JSONObject()
        for level in 0...1 {
            for (_, h, _) in dispatch[level] where handlerDesc[pyHex(h)] == nil {
                let ins = describe(h)
                let txt = ins.map { "\($0.mnemonic) \($0.opStr)".trimmingCharacters(in: .whitespaces) }.joined(separator: "; ")
                let movs = ins.filter { $0.mnemonic == "mov" }.map(\.opStr)
                var tags: [String] = []
                if let lv = occ.levelVar {
                    if movs.contains("byte ptr [\(pyHex(lv))], 1") { tags.append("enters_ramp_level") }
                    if movs.contains("byte ptr [\(pyHex(lv))], 0") { tags.append("leaves_ramp_level") }
                } else {
                    if movs.contains("byte ptr [None], 1") { tags.append("enters_ramp_level") }
                }
                if let cd, ins.count == 2, ins[0].mnemonic == "mov", ins[0].opStr.hasPrefix("byte ptr [\(pyHex(cd))],"), ins[1].mnemonic == "jmp" {
                    tags.append("debounce_only")
                }
                handlerDesc[pyHex(h)] = .obj([("first_instructions", .string(txt)), ("tags", .strings(tags))])
            }
        }

        // other code that loads ES with a playfield segment pointer and writes through it
        var writers: [JSONValue] = []
        for (v, half) in [(ptrs.top, 0), (ptrs.bottom, 1)] {
            for m in try find(bytes: [0x5C, 0x78, 0x38, 0x65, 0x5C, 0x78, 0x30, 0x36, UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) {
                let at = ip(m)
                let stores = code.linear(at, 40).filter { $0.mnemonic == "mov" && $0.opStr.hasPrefix("byte ptr es:") }
                if stores.isEmpty { continue }
                writers.append(.obj([("code_ip", .hex(at)), ("half", .int(half)), ("es_byte_stores_in_next_40_insns", .int(stores.count)),
                                     ("is_flipper_routine", .bool(flips.contains { 0 < $0.ip - at && $0.ip - at < 0x100 }))]))
            }
        }

        // collision buffer
        let pf = try exe.playfield()
        playfield = pf
        var buf = pf
        for s in subs {
            let rows: Range<Int> = s.segVar == ptrs.top ? 0..<200 : s.segVar == ptrs.bottom ? 200..<400 : 0..<400
            for i in (rows.lowerBound * 320)..<(rows.upperBound * 320) where Int(buf[i]) >= s.lo && Int(buf[i]) <= s.hi {
                buf[i] = UInt8(s.replace)
            }
        }
        buffer = buf
        classes = [UInt8](repeating: 0, count: 2 * 400 * 320)
        for i in 0..<(400 * 320) {
            classes[i] = UInt8(wallLUT[0][Int(buf[i])])
            classes[400 * 320 + i] = UInt8(wallLUT[1][Int(buf[i])])
        }

        // ball sprite
        let bw = dsb(occ.sprite), bh = dsb(occ.sprite + 2)
        let bo = exe.imageOff(ds, occ.sprite + 4)
        ball = (bw, bh, Array(d[bo..<min(d.count, bo + bw * bh)]))

        // collision.json (same keys and order as tools/collision.py)
        func hexOrValue(_ v: Int?) -> JSONValue { v.map { .hex($0) } ?? .null }
        var o = JSONObject()
        o["table"] = .int(n)
        o["code_segment"] = .hex(exe.entryCS)
        o["data_segment"] = .hex(ds)
        o["note"] = .string("ip values are offsets in the code segment; file offset = 0x400 + code_segment*16 + ip. DS offsets are in the data segment. Addresses differ per table.")
        o["collision_buffer"] = .obj([
            ("source", .string("playfield segments " + pyHex(segs.0) + ", " + pyHex(segs.1))),
            ("top_seg_var", .hex(ptrs.top)), ("bottom_seg_var", .hex(ptrs.bottom)),
            ("init_substitutions", .array(subs.map { .obj([("code_ip", .hex($0.ip)), ("seg_var", .hex($0.segVar)), ("lo", .int($0.lo)),
                                                           ("hi", .int($0.hi)), ("replace", .int($0.replace))]) })),
            ("addressing", .string("ES = top_seg + y*20 (paragraphs, i.e. y*320 bytes); byte ES:[x + ring_offset]")),
        ])
        o["wall_loop"] = .obj([("start_ip", .hex(wl.start)), ("sample_ip", .hex(wl.sample)), ("hit_ip", .hex(wl.hit)), ("miss_ip", .hex(wl.miss)),
                               ("ring_table", .hex(wl.ringTable)), ("level_var", .hex(wl.levelVar)),
                               ("ball_x_var", hexOrValue(wl.ballX)), ("ball_y_var", hexOrValue(wl.ballY)), ("seg_var", hexOrValue(wl.segVar))])
        var rt = JSONObject()
        for disp in thresholdOrder {
            let t = thresholds[disp]!
            rt[pyHex(disp)] = .obj([("initial", .int(t.initial)), ("values_written_by_code", .ints(t.written))])
        }
        o["runtime_thresholds"] = .object(rt)
        o["wall_lut_ranges"] = .array([CollisionAnalysis.lutRanges(wallLUT[0], CollisionAnalysis.classNames),
                                       CollisionAnalysis.lutRanges(wallLUT[1], CollisionAnalysis.classNames)])
        o["wall_lut"] = .array(wallLUT.map { .ints($0) })
        o["wall_lut_variants"] = .object(variants)
        o["wall_events"] = .array(wallEvents.map { evs in .object(JSONObject(evs.map { (String($0.0), .strings($0.1)) })) })
        o["ball"] = .obj([("width", .int(bw)), ("height", .int(bh)), ("sprite_ds", .hex(occ.sprite)), ("ring_ds", .hex(wl.ringTable + 2)),
                          ("ring_offsets", .ints(ringOffs)), ("ring_xy", .array(ringPts.map { .ints([$0.0, $0.1]) })),
                          ("ring_note", .string("index k=1..48 stored at ring_ds+2(k-1); offsets are y*320+x from the ball's top-left (x_var,y_var)"))])
        o["normals"] = .obj([("normal_ds", .hex(nrm.ntab)), ("pushout_ds", .hex(nrm.ptab)), ("normal_ip", .hex(nrm.nip)), ("pushout_ip", .hex(nrm.pip)),
                             ("normal", .array(nrm.normal.map { .ints([$0.0, $0.1]) })), ("pushout", .array(nrm.push.map { .ints([$0.0, $0.1]) })),
                             ("note", .string("entry i (0..47) used for averaged ring index i+1; velocity normal = (-nx, ny); position correction x -= px, y += py"))])
        o["occlusion"] = .obj([
            ("start_ip", .hex(occ.start)), ("pixel_load_ip", hexOrValue(occ.load)), ("next_pixel_ip", hexOrValue(occ.nextPixel)),
            ("store_ip", hexOrValue(occ.store)), ("level_var", hexOrValue(occ.levelVar)), ("ball_sprite", .hex(occ.sprite)),
            ("ball_sprite_table", hexOrValue(occ.spriteTable)), ("sprite_copy", .hex(occ.spriteCopy)), ("sprite_bytes", .hex(occ.spriteBytes)),
            ("runtime_thresholds", .object(occThresholds)),
            ("lut_ranges", .array([CollisionAnalysis.lutRanges(occLUT[0], CollisionAnalysis.occNames),
                                   CollisionAnalysis.lutRanges(occLUT[1], CollisionAnalysis.occNames)])),
            ("lut", .array(occLUT.map { .ints($0) })),
        ])
        o["sensor_routine_ip"] = .strings(sensorFn.map(pyHex))
        o["sensor_debounce_var"] = hexOrValue(cd)
        o["trigger_table"] = .obj([("dispatch_ip", .hex(trig.ip)), ("table_ip", .hex(trig.table)), ("first_value", .int(trig.first)),
                                   ("null_handler", .hex(nullHandler)),
                                   ("handlers", .object(JSONObject(handlers.enumerated().map { (String(trig.first + $0.offset), .hex($0.element)) })))])
        o["sensors"] = .array((0...1).map { lv in
            .object(JSONObject(dispatch[lv].sorted { $0.0 < $1.0 }.map { (String($0.0), .obj([("handler_ip", .hex($0.1)), ("always", .bool($0.2))])) }))
        })
        o["sensor_handlers"] = .object(handlerDesc)
        o["flippers"] = .array(flips.map { f in
            .obj([("code_ip", .hex(f.ip)), ("pointer_table", .hex(f.pointerTable)), ("value", .int(f.value)), ("base", .int(f.base)),
                  ("seg_var", hexOrValue(f.segVar)), ("half", .intOrNull(f.half)),
                  ("positions", f.positions.map { ps in .array(ps.map { p in
                      .obj([("list_ptr", .int(p.listPtr)), ("count", .int(p.count)), ("pixels", .array(p.pixels.map { .ints([$0.0, $0.1]) }))])
                  }) } ?? .null)])
        })
        o["runtime_buffer_writers"] = .array(writers)
        o["flipper_note"] = .string("positions[0..9]: pixel outline written with `value` into the collision buffer each frame (previous outline erased with 0x2a). Index 9 = rest, 0 = fully raised.")
        o["class_codes"] = .strings(CollisionAnalysis.classNames)
        o["occlusion_codes"] = .strings(CollisionAnalysis.occNames)
        info = o
    }

    func write(to dir: URL, palette: [UInt8]) throws {
        try NPYFile.data(uint8: buffer, shape: [400, 320]).writeAtomically(to: dir.appendingPathComponent("collision_idx.npy"))
        try NPYFile.data(uint8: classes, shape: [2, 400, 320]).writeAtomically(to: dir.appendingPathComponent("collision.npy"))
        try Data(serialize(.object(info), style: .indent(1)).utf8).writeAtomically(to: dir.appendingPathComponent("collision.json"))
        if ball.w > 0 && ball.h > 0 && ball.pixels.count == ball.w * ball.h {
            try PNGFile.writeIndexed(dir.appendingPathComponent("ball.png"), width: ball.w, height: ball.h, indices: ball.pixels, palette: palette)
        }
    }
}
