// export_engine_data.sensors() and apply_overrides(): the sensor-handler interpreter (turns a
// handler that only touches physics state into set/if ops) and the engine_overrides merge.
import Foundation

extension EngineExport {
    struct Reject: Error { var message: String }

    /// Python: re.fullmatch(r"(byte|word) ptr \[(0x[0-9a-f]+)\]", op)
    static func memOperand(_ op: String) -> (String, Int)? {
        for size in ["byte", "word"] {
            let pre = "\(size) ptr [0x"
            guard op.hasPrefix(pre), op.hasSuffix("]") else { continue }
            let hex = op.dropFirst(pre.count).dropLast()
            guard !hex.isEmpty, hex.allSatisfy({ "0123456789abcdef".contains($0) }), let v = Int(hex, radix: 16) else { return nil }
            return (size, v)
        }
        return nil
    }

    /// Python: int(op, 0)
    static func immOperand(_ op: String) -> Int? {
        var t = Substring(op)
        var neg = false
        if t.hasPrefix("-") { neg = true; t = t.dropFirst() } else if t.hasPrefix("+") { t = t.dropFirst() }
        var v: Int?
        if t.hasPrefix("0x") || t.hasPrefix("0X") { v = Int(t.dropFirst(2), radix: 16) }
        else if t.hasPrefix("0o") || t.hasPrefix("0O") { v = Int(t.dropFirst(2), radix: 8) }
        else if t.hasPrefix("0b") || t.hasPrefix("0B") { v = Int(t.dropFirst(2), radix: 2) }
        else if t.allSatisfy(\.isASCII), !t.isEmpty, t.allSatisfy(\.isNumber), !(t.count > 1 && t.first == "0" && t.contains { $0 != "0" }) { v = Int(t) }
        return v.map { neg ? -$0 : $0 }
    }

    func sensorHandlers(extraVar: Int?, forbidden forbidden0: Set<Int>) throws -> JSONObject {
        var res = JSONObject([("supported", .bool(true)), ("levels", .array([.object(JSONObject()), .object(JSONObject())])), ("skipped", .object(JSONObject()))])
        let levelVar = cj["occlusion"]!["level_var"]!.hexInt!
        let lockoutVar = cj["sensor_debounce_var"]?.hexInt
        var names: [Int: String] = [:]
        var nameOrder: [Int] = []
        func name(_ a: Int, _ s: String) { if names[a] == nil { nameOrder.append(a) }; names[a] = s }
        name(levelVar, "level")
        if let l = lockoutVar { name(l, "lockout") }
        if let e = extraVar { name(e, "extra_gravity") }
        var arrays: [(String, Int)] = []
        if let (m, at) = first(#"\x8b\x85(..)\x8b\x9d(..)(?:\x8a\x8d..\x88\x0e..)?\x8a\x8d(..)\x88\x0e(..)\xa3(..)\x89\x1e(..)\x8b\x8d(..)\x89\x0e(..)\x8b\x8d(..)\x89\x0e(..)"#, "obj_copy") {
            let g = (1...10).map { m.u16($0) }
            arrays = [("ball_x", g[0]), ("ball_y", g[1]), ("ball_vx", g[6]), ("ball_vy", g[8])]
            name(g[4], "obj_x"); name(g[5], "obj_y"); name(g[7], "obj_vx"); name(g[9], "obj_vy")
            if let wb = first(#"\xc6\x06(..)\x00\xe8"#, "obj_writeback", at) { name(wb.0.u16(1), "writeback") }
        }
        if let ec = first(#"\x80\x3e(..)\x00\x75.\xe8(..)\x8a\x26"#, "event_cooldown") { name(ec.0.u16(1), "event_cooldown") }
        if let am = first(#"\x83\xbd(..)\x00(?:\x74.|\x75\x03\xe9..)\x81\xbd(..)\x40\x01"#, "active_array") { arrays.append(("ball_active", am.0.u16(1))) }
        for (arr, base) in arrays { for i in 0..<5 { name(base + 2 * i, "\(arr).\(i)") } }
        // res["vars"] = {name: hex(addr)} in names' insertion order (later duplicates of a name win)
        var vars = JSONObject()
        for a in nameOrder { vars[names[a]!] = .hex(a) }
        res["vars"] = .object(vars)
        let forbidden = forbidden0.subtracting(names.keys)
        res["forbidden_vars"] = .strings(forbidden.map(pyHex).sorted())
        let nullIP = cj["trigger_table"]!["null_handler"]!.hexInt!
        guard let nullIns = X86.decode(code.data, start: code.base + nullIP, limit: code.base + nullIP + 3, address: nullIP) else {
            throw ImportError("EP\(n): cannot decode the null sensor handler")
        }
        let exitIP: Int? = nullIns.mnemonic == "jmp" ? Int(nullIns.opStr.dropFirst(2), radix: 16) : nil
        res["exit_ip"] = (exitIP ?? 0) != 0 ? .hex(exitIP!) : .null
        let jcc: [String: String] = ["jne": "ne", "je": "eq", "jb": "b", "jae": "ae", "ja": "a", "jbe": "be", "jl": "lt", "jge": "ge", "jg": "gt", "jle": "le"]
        let reg16: Set<String> = ["ax", "bx", "cx", "dx"]
        var ignored = Set<String>()

        func dis(_ ip: Int, _ len: Int) -> X86Instruction? {
            let s = code.base + ip
            guard s >= code.base, s < code.data.count else { return nil }
            return X86.decode(code.data, start: s, limit: min(code.data.count, s + len), address: ip)
        }

        func interp(_ ip0: Int, _ regs0: [String: JSONValue?], _ depth: Int, _ seen0: Set<Int>) throws -> [JSONValue] {
            var ip = ip0
            var regs = regs0
            var seen = seen0
            var ops: [JSONValue] = []
            while true {
                if ip == exitIP { return ops }
                if seen.contains(ip) || depth > 24 || seen.count > 400 { throw Reject(message: "loop") }
                seen.insert(ip)
                guard let i = dis(ip, 8) else { throw Reject(message: "decode") }
                let mn = i.mnemonic
                let a = i.opStr.isEmpty ? [] : i.opStr.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                let nxt = ip + i.size

                func val(_ o: String) throws -> JSONValue {
                    if reg16.contains(o) {
                        guard let r = regs[o], let v = r else { throw Reject(message: "undefined \(o)") }
                        return v
                    }
                    if let c = EngineExport.immOperand(o) { return .array([.string("const"), .int(c)]) }
                    if let m = EngineExport.memOperand(o) {
                        guard let nm = names[m.1] else { throw Reject(message: "read \(pyHex(m.1))") }
                        return .array([.string("var"), .string(nm)])
                    }
                    throw Reject(message: "operand \(o)")
                }

                if mn == "nop" { ip = nxt; continue }
                if mn == "jmp" {
                    guard let t = a.first, t.hasPrefix("0x"), let v = Int(t.dropFirst(2), radix: 16) else { throw Reject(message: "insn \(mn) \(i.opStr)") }
                    ip = v; continue
                }
                if mn == "mov" && a.count == 2 {
                    if let d = EngineExport.memOperand(a[0]) {
                        if forbidden.contains(d.1) { throw Reject(message: "writes physics state \(pyHex(d.1))") }
                        if let nm = names[d.1] { ops.append(.obj([("op", .string("set")), ("var", .string(nm)), ("expr", try val(a[1]))])) }
                        else { ignored.insert(pyHex(d.1)) }
                        ip = nxt; continue
                    }
                    if reg16.contains(a[0]) { regs[a[0]] = .some(try val(a[1])); ip = nxt; continue }
                    throw Reject(message: "insn \(mn) \(i.opStr)")
                }
                if ["add", "sub", "inc", "dec", "or", "and"].contains(mn), let a0 = a.first, let d = EngineExport.memOperand(a0) {
                    if forbidden.contains(d.1) { throw Reject(message: "writes physics state \(pyHex(d.1))") }
                    guard let nm = names[d.1] else { ignored.insert(pyHex(d.1)); ip = nxt; continue }
                    let v: JSONValue = .array([.string("var"), .string(nm)])
                    let e: JSONValue
                    if mn == "inc" || mn == "dec" { e = .array([.string("add"), v, .array([.string("const"), .int(mn == "inc" ? 1 : -1)])]) }
                    else if mn == "add" || mn == "sub" {
                        let c = try val(a[1])
                        e = .array([.string("add"), v, mn == "add" ? c : .array([.string("neg"), c])])
                    } else { throw Reject(message: "insn \(mn) on physics var") }
                    ops.append(.obj([("op", .string("set")), ("var", .string(nm)), ("expr", e)]))
                    ip = nxt; continue
                }
                if mn == "neg", let a0 = a.first, reg16.contains(a0) { regs[a0] = .some(.array([.string("neg"), try val(a0)])); ip = nxt; continue }
                if mn == "add" || mn == "sub", let a0 = a.first, reg16.contains(a0) {
                    let c = try val(a[1])
                    regs[a0] = .some(.array([.string("add"), try val(a0), mn == "add" ? c : .array([.string("neg"), c])]))
                    ip = nxt; continue
                }
                if ["shl", "shr", "sar"].contains(mn), let a0 = a.first, reg16.contains(a0), a.count > 1, let k = EngineExport.immOperand(a[1]) {
                    regs[a0] = .some(.array([.string(mn), try val(a0), .array([.string("const"), .int(k)])]))
                    ip = nxt; continue
                }
                if mn == "mul" && a == ["cx"] {
                    regs["ax"] = .some(.array([.string("mul"), try val("ax"), try val("cx")]))
                    regs["dx"] = .some(nil)
                    ip = nxt; continue
                }
                if mn == "cmp" && a.count == 2 {
                    let lhs = try val(a[0])
                    let size = a[0].hasPrefix("byte") ? 8 : 16
                    let rhs = try val(a[1])
                    guard let j = dis(nxt, 4) else { throw Reject(message: "") }   // Python: StopIteration
                    guard let cond = jcc[j.mnemonic] else { throw Reject(message: "branch \(j.mnemonic)") }
                    guard j.opStr.hasPrefix("0x"), let t = Int(j.opStr.dropFirst(2), radix: 16) else { throw Reject(message: "branch \(j.mnemonic)") }
                    let taken = try interp(t, regs, depth + 1, seen)
                    let fall = try interp(j.address + j.size, regs, depth + 1, seen)
                    if taken != fall {
                        ops.append(.obj([("op", .string("if")), ("lhs", lhs), ("cmp", .string(cond)), ("rhs", rhs), ("size", .int(size)),
                                         ("then", .array(taken)), ("else", .array(fall))]))
                    } else {
                        ops.append(contentsOf: taken)
                    }
                    return ops
                }
                throw Reject(message: "insn \(mn) \(i.opStr)")
            }
        }

        var levels: [JSONObject] = [JSONObject(), JSONObject()]
        var skipped = JSONObject()
        let sensorLevels = cj["sensors"]?.arrayValue ?? [.object(JSONObject()), .object(JSONObject())]
        for level in 0...1 {
            for (v, info) in sensorLevels[level].objectValue?.pairs ?? [] {
                let hs = info["handler_ip"]!.stringValue!
                let h = pyInt(hs, base: 16)!
                ignored.removeAll()
                let ops: [JSONValue]
                do { ops = try interp(h, [:], 0, []) } catch let e as Reject {
                    skipped["\(level):\(v)"] = .string("\(hs): \(e.message)")
                    continue
                }
                if !ops.isEmpty {
                    var ent = JSONObject([("handler_ip", .string(hs)), ("always", info["always"] ?? .null), ("ops", .array(ops))])
                    if !ignored.isEmpty { ent["ignored_writes"] = .strings(ignored.sorted()) }
                    levels[level][v] = .object(ent)
                }
            }
        }
        res["levels"] = .array(levels.map { .object($0) })
        res["skipped"] = .object(skipped)
        res["note"] = .string("per frame per ball (ball_pixel_scan EP1 cs:1679): each pixel of the 15x14 box classed 'sensor' for the ball's level fires if (v==0xFE or lockout==0) and event_cooldown==0; the handler for the current level runs (non-'always' handlers are skipped while tilted). ops: set var=expr; if lhs cmp rhs (size 8/16 bits; b/ae/a/be unsigned, lt/ge/gt/le signed). expr: [const n] [var name] [neg e] [add e e] [mul e e] [shl|shr|sar e e], 16-bit wrapping.")
        return res
    }

    // MARK: overrides (export_engine_data.apply_overrides)

    func readDSWords(_ off: Int, _ words: Int, signed: Bool = true) -> JSONValue { .ints((0..<words).map { dsw(off + 2 * $0, signed: signed) }) }

    func readPixelList(_ off: Int) throws -> JSONValue {
        let count = dsw(off, signed: false)
        guard 0 < count && count < 4096 else { throw ImportError("pixel list at ds:\(String(format: "%04x", off)) has count \(count)") }
        return .ints((0..<count).map { dsw(off + 2 + 2 * $0, signed: false) })
    }

    func resolveTables(_ o: JSONValue) -> JSONValue {
        switch o {
        case let .array(a): return .array(a.map(resolveTables))
        case let .object(obj):
            if obj.values["ds"] != nil && obj.values["words"] != nil, let ds = obj["ds"]?.stringValue, obj.count <= 4 {
                return readDSWords(pyInt(ds, base: 16)!, obj["words"]!.intValue!, signed: obj["signed"]?.boolValue ?? true)
            }
            var out = JSONObject()
            for (k, v) in obj.pairs { out[k] = resolveTables(v) }
            for (key, dst) in [("vx_sub_table", "vx_sub"), ("vy_sub_table", "vy_sub")] {
                if let s = out[key]?.stringValue, let tw = out["table_words"]?.intValue { out[dst] = readDSWords(pyInt(s, base: 16)!, tw) }
            }
            return .object(out)
        default: return o
        }
    }

    func merge(_ dst: inout JSONObject, _ src: JSONObject, _ path: String, _ applied: inout [String], _ replaced: inout [String]) {
        for (k, v) in src.pairs {
            let p = path + k
            if case let .object(sv) = v, case var .object(dv)? = dst[k] {
                merge(&dv, sv, p + ".", &applied, &replaced)
                dst[k] = .object(dv)
                continue
            }
            if let cur = dst[k], cur != v { replaced.append(p) }
            dst[k] = v
            applied.append(p)
        }
    }

    func setPath(_ d: inout JSONObject, _ keys: ArraySlice<String>, _ value: JSONValue) {
        guard let k = keys.first else { return }
        if keys.count == 1 { d[k] = value; return }
        var sub = d[k]?.objectValue ?? JSONObject()
        setPath(&sub, keys.dropFirst(), value)
        d[k] = .object(sub)
    }

    func applyOverrides(_ out: inout JSONObject, _ ov: JSONValue) throws {
        var applied: [String] = [], replaced: [String] = []
        if case let .object(patch)? = ov["patch"], case let .object(rp) = resolveTables(.object(patch)) {
            merge(&out, rp, "", &applied, &replaced)
        }
        for (k, v) in ov["set"]?.objectValue?.pairs ?? [] {
            let parts = k.split(separator: ".").map(String.init)
            var cur: JSONValue? = .object(out)
            for part in parts.dropLast() { cur = cur?.objectValue.map { $0[part] ?? .object(JSONObject()) } ?? .object(JSONObject()) }
            if let c = cur?.objectValue, let existing = c[parts.last!], existing != v { replaced.append(k) }
            setPath(&out, parts[...], resolveTables(v))
            applied.append(k)
        }
        try normalise(&out)
        out["overrides"] = .obj([("file", .string("tools/engine_overrides/EP\(n).json")), ("applied", .strings(applied)), ("replaced", .strings(replaced)),
                                 ("note", .string("hand-verified additions (cs:ip evidence in the override file); tables resolved from the EXE"))])
    }

    func normalise(_ out: inout JSONObject) throws {
        if var fk = out["flipper_kick"]?.objectValue, let uk = fk["upper_kick"]?.objectValue, uk["right"] == nil, uk["vx_table"] != nil {
            let side = JSONValue.obj([("angle_group", uk["angle_group"] ?? .null), ("dx", uk["dx"] ?? .null), ("dy", uk["dy"] ?? .null),
                                      ("vx_sub", uk["vx_table"]!), ("vy_sub", uk["vy_table"] ?? .null)])
            fk["upper_kick"] = .obj([("split_x", .null), ("vy_zero_if_positive", uk["vy_positive_to_zero"] ?? .bool(true)), ("right", side), ("left", .null),
                                     ("code", uk["code"] ?? .null), ("reachable", uk["reachable"] ?? .null)])
            out["flipper_kick"] = .object(fk)
        }
        if let gates = out["gates"]?.arrayValue {
            var ng: [JSONValue] = []
            for g0 in gates {
                guard var g = g0.objectValue else { ng.append(g0); continue }
                if let px = g["pixels"] {
                    if var p = px.objectValue, let l = p["list"]?.stringValue {
                        p["offsets"] = try readPixelList(pyInt(l, base: 16)!)
                        g["pixels"] = .object(p)
                    } else if let list = px.arrayValue {
                        g["pixels"] = .array(try list.map { e in
                            var p = e.objectValue ?? JSONObject()
                            p["offsets"] = try readPixelList(pyInt(p["list"]!.stringValue!, base: 16)!)
                            return .object(p)
                        })
                    }
                }
                ng.append(.object(g))
            }
            out["gates"] = .array(ng)
        }
        if out["sensors"]?["lockout_is_kicker_cooldown"]?.truthy == true, var k = out["kicker"]?.objectValue {
            k["cooldown_is_sensor_lockout"] = .bool(true)
            out["kicker"] = .object(k)
        }
        if var s = out["sensors"]?.objectValue, s["always_fires"] != nil, var fb = out["fallbacks"]?.arrayValue,
           let i = fb.firstIndex(of: .string("sensors.always_fires_value")) {
            fb.remove(at: i)
            out["fallbacks"] = .array(fb)
            s["always_fires_value_note"] = .string("EP1 fallback; superseded by always_fires (null = no bypass)")
            out["sensors"] = .object(s)
        }
    }
}
