import Foundation

// Decoded, pre-resolved form of `extracted/tables/EP<n>/rules.json` (schema `epic-pinball-rules/1`,
// written by tools/rules.py from the user's own EXE; format in docs/formats/rules.md section 3).
//
// The JSON is lifted machine code: every handler/hook is a graph of blocks, each a list of ops and an
// `end` (goto / if / return). Loading resolves every label to a block index, every named variable to
// its DS address and width, and every register name to a slot, so the interpreter (`RulesMachine`)
// only walks arrays. Nothing from the game is compiled into the app: this file only knows the schema.

public enum RulesError: Error, CustomStringConvertible, Equatable {
    case decode(String)
    case invalid(String)
    case missingFile(String)

    public var description: String {
        switch self {
        case let .decode(s): return "rules.json could not be decoded: \(s)"
        case let .invalid(s): return "rules.json is invalid: \(s)"
        case let .missingFile(s): return s
        }
    }
}

/// Expression over mathematical integers; `RulesMachine.eval` truncates exactly where the reference
/// interpreter (scratch/rules/verify_ir.py, class `IR`) does.
public indirect enum RExpr: Sendable, Equatable {
    case k(Int64)
    /// `w` bytes at a DS address (named variables resolve to a constant address).
    case mem(Int, RExpr)
    case memAt(Int, Int)
    /// `w` bytes of the code segment (read from the user's EXE).
    case cmem(Int, RExpr)
    case reg(Int)
    /// 0 = left flipper key, 1 = right flipper key (EP1 cs:028D / cs:028F).
    case input(Int)
    /// The pixel value the kicker probe hit (EP2/EP10 kicker hooks).
    case contactColour
    /// A value clobbered by a display call: reading it is an interpreter fault.
    case unknown(Int)
    case unary(UOp, RExpr)
    case binary(BOp, RExpr, RExpr)
    case ltu(RExpr, RExpr, Int)

    public enum UOp: String, Sendable { case neg, lo, hi, lo16, hi16, sext8 }
    public enum BOp: String, Sendable {
        case add, sub, mul, and, or, xor, shl, shr, sar, setlo, sethi, join, mul32, div32, mod32, div, mod
    }
}

public enum RCmp: String, Sendable { case eq, ne, ult, ule, ugt, uge, slt, sle, sgt, sge }

public struct RCond: Sendable, Equatable {
    public var cmp: RCmp
    public var a: RExpr
    public var b: RExpr
    public var w: Int
}

/// A DS write target: `w` bytes at `addr`.
public struct RSlot: Sendable, Equatable {
    public var addr: Int
    public var w: Int
}

/// One write of a multi-write op.
public struct RWrite: Sendable, Equatable {
    public var slot: RSlot
    public var value: RExpr
}

public enum ROp: Sendable, Equatable {
    /// Register / temporary assignment; `mask` = truncate to 16 bits (ax..bp, fa, fb, cf, t_*).
    case reg(Int, RExpr, mask: Bool)
    case regUnknown(Int)
    case store(Int, RExpr, RExpr)          // w, address expression, value
    case storeAt(RSlot, RExpr)
    /// Several writes whose values are all evaluated before any is stored (`ball`, `ball_slot`,
    /// `sound_sweep_start`).
    case storeMany([RWrite])
    case score(RExpr)
    case lamp(RExpr, RExpr)
    case pixels(RExpr, [Int], outside: Int?)
    /// A pixel write at a computed offset (EP11 L3FFD, EP12 L40AB): half * 64000 + (offset & 0xFFFF).
    case pixelAt(RExpr, half: Int, offset: RExpr)
    /// An unlifted near call (`{"op": "call"}`, EP6 cs:31E1, EP8 cs:3613, EP9 cs:A48D): executed from
    /// the EXE by the runtime (`RulesMachine.nativeCall`) with the current registers.
    case native(target: Int, ip: Int)
    /// An instruction the lift could not express (`{"op": "asm"}` other than `out`); the handler that
    /// contains it runs from the EXE instead (`RulesProgram.nativeBlocks`).
    case asm(ip: Int)
    case gate(Int)
    /// dot-matrix message: string (DS offset), DI position, AX mode (AH font/centring, AL effect).
    case message(RExpr, pos: RExpr, mode: RExpr)
    /// score-strip text: string (DS offset), DI position, drawing routine (cs offset).
    case text(RExpr, pos: RExpr, routine: Int)
    case numberText(RExpr, RExpr)
    case scoreRefresh
    case display(String)
    case push(RExpr)
    case pop(Int)
    case pushAll
    case popAll
    case gosub(Int)
    case callHook(Int)
}

public enum REnd: Sendable, Equatable {
    case goto(Int)
    case branch(RCond, then: Int, else: Int)
    case ret
}

public struct RBlock: Sendable {
    public var label: String
    public var ip: Int
    public var ops: [ROp]
    public var end: REnd
    /// The hook stop (cs ip) a return here reaches (`end.stop`, `end.stops_at`); nil = none/epilogue.
    public var stopRet: Int? = nil
    public var stopThen: Int? = nil
    public var stopElse: Int? = nil
}

public struct RulesProgram: Sendable {
    public static let schema = "epic-pinball-rules/1"
    /// Label index meaning "return from the current graph".
    public static let returnLabel = -1

    public struct Var: Sendable, Equatable { public var addr: Int; public var size: Int }
    public struct EngineVar: Sendable, Equatable { public var addr: Int; public var size: Int; public var count: Int; public var stride: Int }
    public struct Hook: Sendable {
        public var name: String; public var entry: Int; public var entryIP: Int
        /// Automatic hooks (rules.md 4.1): shape label, when to run, stop ips, and for `ball_end`
        /// hooks the next hook after each cut (`continues`).
        public var kind: String? = nil
        public var when: String? = nil
        public var stops: [Int] = []
        public var continues: [Int: String] = [:]
        /// `ball_end` hooks: the cuts passed on the way to the `continues` hook (straight-line code
        /// between two display calls, rules.json `via`; optional, older rules.json files have none).
        public var via: [Int: [Int]] = [:]
    }
    public struct Handler: Sendable { public var name: String; public var entry: Int; public var entryIP: Int; public var colours: [Int] }
    public struct Gate: Sendable {
        public var id: String
        public var routine: Int?
        public var controlVar: Int
        public var valueIfZero: UInt8
        public var valueIfNonzero: UInt8
        public var offsets: [Int]
    }
    public struct Sweep: Sendable, Equatable {
        public var counter: Int
        public var mask: Int
        public var phase: Int
        public var rateStep: Int
        public var rateLimit: Int
        /// DS words holding the sound id played on each step / at the end.
        public var stepIDVars: [Int]
        public var endIDVars: [Int]
        /// Constant ids (if the generator records them; see `docs/formats/rules.md`).
        public var stepConstIDs: [Int]
    }
    public struct Message: Sendable, Equatable { public var ds: Int; public var fileOffset: Int; public var length: Int }
    public struct Stub: Sendable, Equatable { public var kind: String; public var far: Bool }

    public var table: Int
    public var exe: String
    public var annotated: Bool
    public var codeSegment: Int
    public var dataSegment: Int
    public var dispatcherIP: Int?
    /// The dispatcher's jump table (cs offset, 86 words for colours 0xAA...0xFF), `source.sensor_table`.
    public var sensorTable: Int?
    public var dsFileOffset: Int
    public var dsSize: Int
    public var playerBlock: Range<Int>?
    public var lampFirst: Int
    public var lampCount: Int
    public var lampPhase: Int?
    public var lampSlotCount: Int
    public var vars: [String: Var]
    public var engineVars: [String: EngineVar]
    public var blocks: [RBlock]
    public var labels: [String: Int]
    public var hooks: [String: Hook]
    public var handlers: [String: Handler]
    /// Colour value (0xAA...0xFF) -> handler (the dispatcher's jump table, from `handlers[].colours`).
    public var colourHandler: [Int: String]
    /// Colours the dispatcher passes on the ramp level (`cmp al, X; je` at the level-1 test).
    public var level1Colours: Set<Int>
    /// Colours the dispatcher passes on level 0 even while tilted.
    public var tiltColours: Set<Int>
    /// Colours whose sensor pixels fire during a lockout (`sensors[].ignores_lockout`).
    public var lockoutFreeColours: Set<Int>
    public var gates: [Gate]
    public var sweeps: [Sweep]
    public var messages: [Int: Message]
    public var messageTables: [Int: [Int]]
    public var stubs: [Int: Stub]
    public var registerNames: [String]
    /// Blocks that contain an `asm` op (their handler/hook must run from the EXE).
    /// Register slots that are 16-bit machine registers or temporaries (truncated on assignment).
    public var maskedRegisters: [Bool]
    /// Blocks that contain an `asm` op (their handler/hook must run from the EXE).
    public var nativeBlocks: Set<Int> = []
    /// Built by `RulesProgram.discover` for the direct-EXE backend: no blocks, every handler and
    /// hook runs from the EXE (`RulesBackend.direct`).
    public var direct = false
    /// End-of-ball regions that do not lift (rules.json `native_hooks`, EP5 cs:1F4A): entry ip, stops,
    /// `continues` and `via` like `hooks`, no graph (`entry` = -1); both backends run them from the EXE.
    public var nativeHooks: [String: Hook] = [:]
    /// Direct backend: every hook stop (rules.py `Lifter.stops`: lifted code returns there whichever
    /// graph reaches it).
    public var hookStops: Set<Int> = []
    /// Direct backend: DS variables holding the playfield segments (collision.json top/bottom_seg_var).
    public var segmentVars: [Int: Int] = [:]
    /// Direct backend: the collision-buffer gate routines (rules.json `gates[].routine`), executed
    /// from the EXE wherever they are called.
    public var gateRoutines: Set<Int> = []
    /// Direct backend: CS keyboard flags rule code reads as flipper keys (rules.json `["input", ...]`):
    /// cs offset -> 0 left, 1 right.
    public var inputKeys: [Int: Int] = [:]
    /// Direct backend: the near routines rule code runs as subroutines (rules.py gosubs; the lifted
    /// program has a block at each of them).
    public var subs: Set<Int> = []
    /// Direct backend: the instructions the `ball_end` hooks (and native hooks) cover.
    public var ballEndCode: Set<Int> = []

    /// Whether a near call to `ip` is a call of rule code (a gosub of the lifted graphs, or one the
    /// direct discovery found): glue code that calls it runs it from the EXE (EP2 cs:0CAF -> cs:3BAF,
    /// dmd_idle_text after the plunger release).
    public func isRuleSubroutine(_ ip: Int) -> Bool {
        direct ? subs.contains(ip) : labels[String(format: "L%04x", ip)] != nil
    }

    /// Whether the end-of-ball hooks contain code in `r`. Direct: an address of the ball_end /
    /// native hook code is in `r`. Lifted: any block of the program starts in `r` (handlers too, so
    /// this is wider than the hooks; the two agree on the 13 EXEs, where no handler starts inside
    /// end_of_turn's first 24 bytes).
    public func ballEndHooksCover(_ r: Range<Int>) -> Bool {
        direct ? r.contains(where: ballEndCode.contains) : blocks.contains { r.contains($0.ip) }
    }

    /// Address of a named variable (`vars`, then `engine_vars`, then `name.hi` = +2).
    public func address(of name: String) -> Var? {
        if let v = vars[name] { return v }
        if let e = engineVars[name] { return Var(addr: e.addr, size: e.size) }
        if name.hasSuffix(".hi"), let base = address(of: String(name.dropLast(3))) { return Var(addr: base.addr + 2, size: 2) }
        return nil
    }

    public func hook(_ name: String) -> Hook? { hooks[name] }
    public func block(named label: String) -> Int? { labels[label] }

    // MARK: loading

    public static func load(contentsOf url: URL) throws -> RulesProgram {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw RulesError.missingFile("cannot read \(url.path): \(error)") }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> RulesProgram {
        let any: Any
        do { any = try JSONSerialization.jsonObject(with: data) } catch { throw RulesError.decode("\(error)") }
        guard let root = any as? [String: Any] else { throw RulesError.decode("top level is not an object") }
        var b = Builder(root: root)
        return try b.build()
    }
}

// MARK: - Builder

private struct Builder {
    let root: [String: Any]
    var registers: [String: Int] = [:]
    var registerNames: [String] = []
    var masked: [Bool] = []
    var labels: [String: Int] = [:]
    var vars: [String: RulesProgram.Var] = [:]
    var engineVars: [String: RulesProgram.EngineVar] = [:]
    var lampFirst = 0
    var gateIndex: [String: Int] = [:]
    var hookEntries: [String: String] = [:]
    var nativeBlocks: Set<Int> = []

    init(root: [String: Any]) { self.root = root }

    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String {
            if s.hasPrefix("cs:") || s.hasPrefix("ds:") {   // "cs:1e77" is hex without a prefix
                let t = String(s.dropFirst(3))
                return Int(t.hasPrefix("0x") ? String(t.dropFirst(2)) : t, radix: 16)
            }
            if s.hasPrefix("0x") || s.hasPrefix("0X") { return Int(s.dropFirst(2), radix: 16) }
            return Int(s)
        }
        return nil
    }
    static func hexLabel(_ s: String) -> Int? { s.hasPrefix("L") || s.hasPrefix("h") ? Int(s.dropFirst(), radix: 16) : nil }

    mutating func reg(_ name: String) -> Int {
        if let i = registers[name] { return i }
        let i = registerNames.count
        registers[name] = i
        registerNames.append(name)
        let machine = ["ax", "bx", "cx", "dx", "si", "di", "bp"].contains(name)
        masked.append(machine || ["fa", "fb", "cf"].contains(name) || name.hasPrefix("t_"))
        return i
    }

    func label(_ s: Any?) throws -> Int {
        guard let s = s as? String else { throw RulesError.invalid("missing label") }
        if s == "@return" { return RulesProgram.returnLabel }
        guard let i = labels[s] else { throw RulesError.invalid("unknown label \(s)") }
        return i
    }

    mutating func addr(ofVar name: String) throws -> RulesProgram.Var {
        if let v = vars[name] { return v }
        if let e = engineVars[name] { return .init(addr: e.addr, size: e.size) }
        if name.hasSuffix(".hi") {
            let base = try addr(ofVar: String(name.dropLast(3)))
            return .init(addr: base.addr + 2, size: 2)
        }
        throw RulesError.invalid("unknown variable '\(name)'")
    }

    func engineVar(_ role: String) throws -> RulesProgram.EngineVar {
        guard let e = engineVars[role] else { throw RulesError.invalid("engine_vars has no '\(role)'") }
        return e
    }

    // MARK: expressions

    mutating func expr(_ x: Any?) throws -> RExpr {
        if let n = x as? NSNumber { return .k(n.int64Value) }
        guard let a = x as? [Any], let op = a.first as? String else { throw RulesError.invalid("bad expression \(String(describing: x))") }
        func arg(_ i: Int) throws -> Any? { i < a.count ? a[i] : nil }
        switch op {
        case "var":
            guard let name = a[1] as? String, let w = Self.int(a[2]) else { throw RulesError.invalid("bad var expression") }
            return .memAt(w, try addr(ofVar: name).addr)
        case "mem":
            guard let w = Self.int(a[1]) else { throw RulesError.invalid("bad mem width") }
            let e = try expr(a[2])
            if case let .k(c) = e { return .memAt(w, Int(c & 0xFFFF)) }
            return .mem(w, e)
        case "cmem":
            guard let w = Self.int(a[1]) else { throw RulesError.invalid("bad cmem width") }
            return .cmem(w, try expr(a[2]))
        case "ball":
            guard let f = a[1] as? String else { throw RulesError.invalid("bad ball field") }
            let e = try engineVar("ball." + f)
            return .memAt(e.size, e.addr)
        case "ball_slot":
            guard let n = Self.int(a[1]), let f = a[2] as? String else { throw RulesError.invalid("bad ball_slot") }
            let e = try engineVar("ball_slots." + f)
            return .memAt(e.size, e.addr + e.stride * n)
        case "lamp":
            return .mem(1, .binary(.add, .k(Int64(lampFirst)), try expr(a[1])))
        case "reg":
            guard let r = a[1] as? String else { throw RulesError.invalid("bad reg") }
            return .reg(reg(r))
        case "input":
            guard let w = a[1] as? String else { throw RulesError.invalid("bad input") }
            return .input(w == "flipper_left" ? 0 : 1)
        case "contact_colour":
            return .contactColour
        case "unknown":
            return .unknown(Self.int(a[1]) ?? 0)
        case "ltu":
            return .ltu(try expr(a[1]), try expr(a[2]), Self.int(a[3]) ?? 2)
        default:
            if let u = RExpr.UOp(rawValue: op) { return .unary(u, try expr(try arg(1))) }
            if let bop = RExpr.BOp(rawValue: op) { return .binary(bop, try expr(try arg(1)), try expr(try arg(2))) }
            throw RulesError.invalid("unsupported expression op '\(op)'")
        }
    }

    // MARK: ops

    mutating func slot(role: String) throws -> RSlot {
        let e = try engineVar(role)
        return RSlot(addr: e.addr, w: e.size)
    }

    mutating func op(_ o: [String: Any]) throws -> ROp? {
        guard let k = o["op"] as? String else { throw RulesError.invalid("op without 'op'") }
        switch k {
        case "reg":
            guard let r = o["r"] as? String else { throw RulesError.invalid("reg op without r") }
            let ri = reg(r)
            if let v = o["val"] as? [Any], (v.first as? String) == "unknown" { return .regUnknown(ri) }
            return .reg(ri, try expr(o["val"]), mask: masked[ri])
        case "set":
            guard let name = o["var"] as? String else { throw RulesError.invalid("set without var") }
            let v = try addr(ofVar: name)
            return .storeAt(RSlot(addr: v.addr, w: Self.int(o["w"]) ?? v.size), try expr(o["val"]))
        case "store":
            return .store(Self.int(o["w"]) ?? 1, try expr(o["addr"]), try expr(o["val"]))
        case "score":
            return .score(try expr(o["add"]))
        case "lamp":
            return .lamp(try expr(o["slot"]), try expr(o["state"]))
        case "lamps":
            guard let s = Self.int(o["slot"]) else { throw RulesError.invalid("lamps without slot") }
            return .storeAt(RSlot(addr: lampFirst + s, w: 2), try expr(o["states16"]))
        case "ball", "ball_slot":
            guard let set = o["set"] as? [String: Any] else { throw RulesError.invalid("\(k) without set") }
            let n = Self.int(o["slot"]) ?? 0
            var list: [RWrite] = []
            for f in set.keys.sorted() {
                let e = try engineVar((k == "ball" ? "ball." : "ball_slots.") + f)
                let a = k == "ball" ? e.addr : e.addr + e.stride * n
                list.append(RWrite(slot: RSlot(addr: a, w: e.size), value: try expr(set[f])))
            }
            return .storeMany(list)
        case "ball_commit": return .storeAt(try slot(role: "ball.writeback"), try expr(o["val"]))
        case "layer": return .storeAt(try slot(role: "ball.layer"), try expr(o["val"]))
        case "sound": return .storeAt(try slot(role: "sound.queue"), try expr(o["id"]))
        case "sound_now": return .storeAt(try slot(role: "sound.now"), try expr(o["id"]))
        case "sound_rate": return .storeAt(try slot(role: "sound.rate"), try expr(o["hz"]))
        case "lockout": return .storeAt(try slot(role: "sensor_lockout"), try expr(o["frames"]))
        case "cooldown": return .storeAt(try slot(role: "sensor_cooldown"), try expr(o["frames"]))
        case "extra_gravity": return .storeAt(try slot(role: "extra_gravity"), try expr(o["frames"]))
        case "sound_sweep_start":
            guard let d = o["sweep"] as? String else { throw RulesError.invalid("sound_sweep_start without sweep") }
            var list: [RWrite] = []
            for key in o.keys.sorted() where key != "op" && key != "sweep" && key != "dir" {
                let role = key == "active" ? "sound.sweep@\(d)" : "sound.sweep@\(d).\(key)"
                guard let e = engineVars[role] else { throw RulesError.invalid("sound_sweep_start writes unknown engine var '\(role)'") }
                list.append(RWrite(slot: RSlot(addr: e.addr, w: e.size), value: try expr(o[key])))
            }
            return .storeMany(list)
        case "sound_play":
            return .storeAt(try slot(role: "sound.now"), try expr(o["id"]))
        case "pixels":
            var offs: [Int] = []
            for p in o["xy"] as? [[Any]] ?? [] {
                if let x = Self.int(p[0]), let y = Self.int(p[1]) { offs.append(y * TableGeometry.width + x) }
            }
            if let h = Self.int(o["half"]), let off = Self.int(o["offset"]) { offs.append(h * 64000 + off) }
            var outside: Int?
            if let op = o["outside_playfield"] as? [String: Any] { outside = (Self.int(op["half"]) ?? 0) * 64000 + (Self.int(op["offset"]) ?? 0) }
            if o["offset"] != nil, Self.int(o["offset"]) == nil {
                return .pixelAt(try expr(o["val"]), half: Self.int(o["half"]) ?? 0, offset: try expr(o["offset"]))
            }
            return .pixels(try expr(o["val"]), offs, outside: outside)
        case "gate":
            guard let g = o["gate"] as? String, let i = gateIndex[g] else { throw RulesError.invalid("unknown gate") }
            return .gate(i)
        case "message":
            // `mode` is AX at the call: a constant, or an expression (EP8 L2975, EP13 L2372: ["reg", "ax"])
            let mode: RExpr = o["mode"] is [Any] ? try expr(o["mode"]) : .k(Int64(Self.int(o["mode"]) ?? 0))
            return .message(try expr(o["msg"]), pos: try position(o["pos"]), mode: mode)
        case "text":
            return .text(try expr(o["msg"]), pos: try position(o["pos"]), routine: Self.int(o["routine"]) ?? 0)
        case "number_text":
            return .numberText(try expr(o["value"]), try expr(o["buf"]))
        case "score_refresh": return .scoreRefresh
        case "display": return .display(o["what"] as? String ?? "")
        case "push": return .push(try expr(o["val"]))
        case "pop":
            guard let r = o["r"] as? String else { throw RulesError.invalid("pop without r") }
            return .pop(reg(r))
        case "push_all": return .pushAll
        case "pop_all": return .popAll
        case "gosub": return .gosub(try label(o["entry"]))
        case "call_hook":
            guard let h = o["hook"] as? String, let e = hookEntries[h] else { throw RulesError.invalid("unknown hook in call_hook") }
            return .callHook(try label(e))
        case "call":
            guard let t = Self.int(o["target"]) else { throw RulesError.invalid("call without target") }
            return .native(target: t, ip: Self.int(o["ip"]) ?? 0)
        case "asm":
            let text = o["text"] as? String ?? ""
            if text.hasPrefix("out ") { return nil }            // VGA register writes: display only
            return .asm(ip: Self.int(o["ip"]) ?? 0)
        default:
            throw RulesError.invalid("unsupported op '\(k)'")
        }
    }

    /// `pos` is `{x, y, raw}` (raw = DI) or an expression (EP2 L260c: `["reg", "di"]`).
    mutating func position(_ p: Any?) throws -> RExpr {
        if let d = p as? [String: Any] { return .k(Int64(Self.int(d["raw"]) ?? 0)) }
        if p == nil { return .k(0) }
        return try expr(p)
    }

    mutating func cond(_ c: [String: Any]) throws -> RCond {
        guard let s = c["cmp"] as? String, let cmp = RCmp(rawValue: s) else { throw RulesError.invalid("condition uses unsupported comparison \(c["cmp"] ?? "?")") }
        return RCond(cmp: cmp, a: try expr(c["a"]), b: try expr(c["b"]), w: Self.int(c["w"]) ?? 2)
    }

    // MARK: build

    mutating func build() throws -> RulesProgram {
        guard (root["schema"] as? String) == RulesProgram.schema else {
            throw RulesError.invalid("schema is '\(root["schema"] ?? "none")', expected '\(RulesProgram.schema)'")
        }
        let table = Self.int(root["table"]) ?? 0
        let source = root["source"] as? [String: Any] ?? [:]
        let memory = root["memory"] as? [String: Any] ?? [:]
        guard let dsOff = Self.int(memory["data_segment_file_offset"]), let dsSize = Self.int(memory["data_segment_size"]),
              dsSize > 0, dsSize <= 0x10000 else { throw RulesError.invalid("memory.data_segment_* missing") }
        let lamps = memory["lamps"] as? [String: Any] ?? [:]
        lampFirst = Self.int(lamps["first"]) ?? 0
        var playerBlock: Range<Int>?
        if let pb = memory["player_block"] as? [String: Any], let s = Self.int(pb["start"]), let e = Self.int(pb["end"]), e > s { playerBlock = s..<e }

        for (name, v) in root["vars"] as? [String: [String: Any]] ?? [:] {
            guard let a = Self.int(v["addr"]) else { continue }
            vars[name] = .init(addr: a, size: Self.int(v["size"]) ?? 1)
        }
        for (role, v) in root["engine_vars"] as? [String: [String: Any]] ?? [:] {
            guard let a = Self.int(v["addr"]) else { continue }
            engineVars[role] = .init(addr: a, size: Self.int(v["size"]) ?? 1, count: Self.int(v["count"]) ?? 1, stride: Self.int(v["stride"]) ?? 2)
        }
        var gates: [RulesProgram.Gate] = []
        for g in root["gates"] as? [[String: Any]] ?? [] {
            guard let id = g["id"] as? String, let cv = Self.int(g["control_var"]) else { continue }
            let offs = (g["pixels"] as? [[Any]] ?? []).compactMap { p -> Int? in
                guard let x = Self.int(p[0]), let y = Self.int(p[1]) else { return nil }
                return y * TableGeometry.width + x
            }
            gateIndex[id] = gates.count
            gates.append(.init(id: id, routine: Self.int(g["routine"]), controlVar: cv,
                               valueIfZero: UInt8(truncatingIfNeeded: Self.int(g["value_if_control_zero"]) ?? 0),
                               valueIfNonzero: UInt8(truncatingIfNeeded: Self.int(g["value_if_control_nonzero"]) ?? 0), offsets: offs))
        }
        let hooksJSON = root["hooks"] as? [String: [String: Any]] ?? [:]
        for (name, h) in hooksJSON { if let e = h["entry"] as? String { hookEntries[name] = e } }

        // labels first (ops reference them), in a stable order
        guard let blocksJSON = root["blocks"] as? [String: [String: Any]] else { throw RulesError.invalid("no blocks") }
        let names = blocksJSON.keys.sorted()
        for (i, n) in names.enumerated() { labels[n] = i }
        var blocks: [RBlock] = []
        blocks.reserveCapacity(names.count)
        for n in names {
            let bj = blocksJSON[n]!
            var ops: [ROp] = []
            for o in bj["ops"] as? [[String: Any]] ?? [] { if let op = try op(o) { ops.append(op) } }
            let e = bj["end"] as? [String: Any] ?? ["return": true]
            let end: REnd
            if let c = e["if"] as? [String: Any] {
                end = .branch(try cond(c), then: try label(e["then"]), else: try label(e["else"]))
            } else if e["goto"] != nil {
                end = .goto(try label(e["goto"]))
            } else {
                end = .ret
            }
            if ops.contains(where: { if case .asm = $0 { return true }; return false }) { nativeBlocks.insert(blocks.count) }
            var blk = RBlock(label: n, ip: Self.int(bj["ip"]) ?? (Self.hexLabel(n) ?? 0), ops: ops, end: end)
            blk.stopRet = Self.int(e["stop"])
            if let sa = e["stops_at"] as? [String: Any] { blk.stopThen = Self.int(sa["then"]); blk.stopElse = Self.int(sa["else"]) }
            blocks.append(blk)
        }
        var hooks: [String: RulesProgram.Hook] = [:]
        for (name, e) in hookEntries {
            let i = try label(e)
            var hk = RulesProgram.Hook(name: name, entry: i, entryIP: Self.hexLabel(e) ?? 0)
            if let hj = hooksJSON[name] {
                hk.kind = hj["kind"] as? String
                hk.when = hj["when"] as? String
                hk.stops = (hj["stops"] as? [Any] ?? []).compactMap { Self.int($0) }
                for (k, v) in hj["continues"] as? [String: Any] ?? [:] { if let a = Self.int(k), let n = v as? String { hk.continues[a] = n } }
                for (k, v) in hj["via"] as? [String: Any] ?? [:] { if let a = Self.int(k), let l = v as? [Any] { hk.via[a] = l.compactMap { Self.int($0) } } }
            }
            hooks[name] = hk
        }
        var handlers: [String: RulesProgram.Handler] = [:]
        var colourHandler: [Int: String] = [:]
        for (name, h) in root["handlers"] as? [String: [String: Any]] ?? [:] {
            guard let e = h["entry"] as? String else { continue }
            let colours = (h["colours"] as? [String] ?? []).compactMap { Int($0, radix: 16) }
            handlers[name] = .init(name: name, entry: try label(e), entryIP: Self.hexLabel(e) ?? 0, colours: colours)
            for c in colours { colourHandler[c] = name }
        }
        var level1 = Set<Int>(), tilt = Set<Int>(), lockoutFree = Set<Int>()
        for s in root["sensors"] as? [[String: Any]] ?? [] {
            guard let v = Self.int(s["value"]) else { continue }
            let lv = Self.int(s["level"]) ?? 0
            if lv == 1 { level1.insert(v) } else if (s["fires_when_tilted"] as? Bool) == true { tilt.insert(v) }
            if (s["ignores_lockout"] as? Bool) == true { lockoutFree.insert(v) }
            if colourHandler[v] == nil, let h = s["handler"] as? String, handlers[h] != nil { colourHandler[v] = h }
        }
        var sweeps: [RulesProgram.Sweep] = []
        for s in root["sound_sweeps"] as? [[String: Any]] ?? [] {
            guard let v = Self.int(s["var"]) else { continue }
            var step: [Int] = [], end: [Int] = [], consts: [Int] = []
            for q in s["ids"] as? [[String: Any]] ?? [] {
                let played = q["played"] as? String ?? "each_step"
                if let c = Self.int(q["const"]) { if played == "each_step" { consts.append(c) }; continue }
                guard let a = Self.int(q["var"]) else { continue }
                if played == "at_end" { end.append(a) } else { step.append(a) }
            }
            sweeps.append(.init(counter: v, mask: Self.int(s["every_frames_mask"]) ?? 0, phase: Self.int(s["phase"]) ?? 1,
                                rateStep: Self.int(s["rate_step"]) ?? 0, rateLimit: Self.int(s["rate_limit"]) ?? 11000,
                                stepIDVars: step, endIDVars: end, stepConstIDs: consts))
        }
        var messages: [Int: RulesProgram.Message] = [:]
        for m in root["messages"] as? [[String: Any]] ?? [] {
            guard let ds = Self.int(m["ds"]) else { continue }
            messages[ds] = .init(ds: ds, fileOffset: Self.int(m["file_offset"]) ?? (ds + dsOff), length: Self.int(m["length"]) ?? 0)
        }
        var tables: [Int: [Int]] = [:]
        for (k, v) in root["message_tables"] as? [String: [Any]] ?? [:] {
            if let a = Self.int(k) { tables[a] = v.compactMap { Self.int($0) } }
        }
        var stubs: [Int: RulesProgram.Stub] = [:]
        for (k, v) in root["stub_routines"] as? [String: [Any]] ?? [:] {
            if let a = Self.int(k) { stubs[a] = .init(kind: v.first as? String ?? "", far: v.count > 1 ? (v[1] as? Bool ?? false) : false) }
        }
        let lampSlots = (root["lamp_slots"] as? [Any])?.count ?? 0
        var nativeHooks: [String: RulesProgram.Hook] = [:]
        for (name, hj) in root["native_hooks"] as? [String: [String: Any]] ?? [:] {
            guard let ip = Self.int(hj["entry"]) else { continue }
            var hk = RulesProgram.Hook(name: name, entry: -1, entryIP: ip)
            hk.kind = hj["kind"] as? String
            hk.when = hj["when"] as? String
            hk.stops = (hj["stops"] as? [Any] ?? []).compactMap { Self.int($0) }
            for (k, v) in hj["continues"] as? [String: Any] ?? [:] { if let a = Self.int(k), let n = v as? String { hk.continues[a] = n } }
            for (k, v) in hj["via"] as? [String: Any] ?? [:] { if let a = Self.int(k), let l = v as? [Any] { hk.via[a] = l.compactMap { Self.int($0) } } }
            nativeHooks[name] = hk
        }
        var program = RulesProgram(
            table: table, exe: root["exe"] as? String ?? "EP\(table).EXE", annotated: root["annotated"] as? Bool ?? false,
            codeSegment: Self.int(source["code_segment"]) ?? 0, dataSegment: Self.int(source["data_segment"]) ?? 0,
            dispatcherIP: Self.int(source["sensor_dispatch"]), sensorTable: Self.int(source["sensor_table"]), dsFileOffset: dsOff, dsSize: dsSize, playerBlock: playerBlock,
            lampFirst: lampFirst, lampCount: Self.int(lamps["count"]) ?? lampSlots, lampPhase: Self.int(lamps["phase"]),
            lampSlotCount: lampSlots, vars: vars, engineVars: engineVars, blocks: blocks, labels: labels, hooks: hooks,
            handlers: handlers, colourHandler: colourHandler, level1Colours: level1, tiltColours: tilt,
            lockoutFreeColours: lockoutFree, gates: gates,
            sweeps: sweeps, messages: messages, messageTables: tables, stubs: stubs, registerNames: registerNames,
            maskedRegisters: masked, nativeBlocks: nativeBlocks)
        program.nativeHooks = nativeHooks
        return program
    }
}
