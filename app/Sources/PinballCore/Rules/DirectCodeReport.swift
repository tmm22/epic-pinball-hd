import Foundation

/// Static inventory of the code the direct backend can execute for a table: every instruction
/// reachable from the sensor dispatcher, the jump-table handlers, the kicker routine and every
/// main-loop / end-of-ball hook, following jumps and every call the runtime's callout would execute
/// (`RulesRuntime.classifyCall` with direct rule code running), up to hook stops, the dispatcher
/// epilogue and `ret`/`retf` of the entry routine. Used to show that `MiniX86` covers every
/// instruction and addressing form the rule code uses (docs/enhanced/rules-direct.md).
public struct DirectCodeReport: Sendable {
    /// Instructions reached.
    public var instructions = 0
    /// Instruction form ("mov r16, [disp]", "add [di+d], imm", ...) -> count.
    public var forms: [String: Int] = [:]
    /// Reached instructions MiniX86 does not execute: (ip, form).
    public var unsupported: [(Int, String)] = []
    /// Calls the callout would not resolve (unknown near/far targets): (ip, target, far segment).
    public var unknownCalls: [(Int, Int, Int?)] = []
    /// Calls handled without executing the callee (display, sound, engine routines): target -> count.
    public var handledCalls: [Int: Int] = [:]
    /// Routines executed as subroutines (near and far into CS).
    public var followed = Set<Int>()
    /// Instructions that load DS/ES with something else than DS (display segments; each executed
    /// access is checked at run time).
    public var segmentLoads: [Int] = []

    static func form(_ i: X86Insn) -> String {
        func op(_ o: X86Operand) -> String {
            switch o {
            case let .reg(_, w): return w == 1 ? "r8" : "r16"
            case .sreg: return "sreg"
            case .imm: return "imm"
            case .far: return "far"
            case let .mem(m):
                let s = m.seg.map { ["es:", "cs:", "ss:", "ds:"][$0] } ?? (m.usesBP ? "ss:" : "")
                let regs = m.registers.joined(separator: "+")
                let body = regs.isEmpty ? "disp" : regs + (m.disp != 0 ? "+d" : "")
                return (m.size == 1 ? "byte " : (m.size == 4 ? "dword " : "")) + s + "[" + body + "]"
            }
        }
        let branch = i.mn.hasPrefix("j") || i.mn.hasPrefix("loop") || i.mn == "call"
        if branch, i.target != nil { return i.mn + " rel" }
        return ([i.mn] + [i.ops.map(op).joined(separator: ", ")]).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

extension RulesRuntime {
    /// The static inventory for this table's direct backend (see `DirectCodeReport`).
    public func directCodeReport() -> DirectCodeReport {
        var rep = DirectCodeReport()
        let code = machine.code
        var roots: [Int] = []
        if let d = program.dispatcherIP { roots.append(d) }
        roots += program.handlers.values.map(\.entryIP)
        roots += program.hooks.values.map(\.entryIP)
        var seen = Set<Int>()
        var work: [(ip: Int, depth: Int, start: Int)] = roots.map { ($0, 0, $0) }
        let stops = program.hookStops
        while let (ip0, depth, start) = work.popLast() {
            var ip = ip0
            while true {
                if depth == 0, ip != start, stops.contains(ip) { break }
                if depth == 0, MiniX86.isEpilogue(code, ip) { break }
                if seen.contains(ip) { break }
                seen.insert(ip)
                guard let i = X86Decoder.decode(code, ip) else {
                    rep.unsupported.append((ip, String(format: "undecodable %02X", code[ip]))); break
                }
                rep.instructions += 1
                let f = DirectCodeReport.form(i)
                rep.forms[f, default: 0] += 1
                if !MiniX86.supports(i) { rep.unsupported.append((ip, f)) }
                if i.mn == "mov", i.ops.count == 2, i.ops[0] == .sreg(0) || i.ops[0] == .sreg(3) { rep.segmentLoads.append(ip) }
                if i.mn == "les" || i.mn == "lds" { rep.segmentLoads.append(ip) }
                let m = i.mn
                if m == "call" || m == "lcall" {
                    var target: Int?, far: Int?
                    if m == "call" { target = i.target } else if let t = i.farTarget { target = t.off; far = t.seg }
                    if let t = target {
                        let (res, _) = classifyCall(t, far, direct: true)
                        switch res {
                        case .follow:
                            rep.followed.insert(t)
                            work.append((t, depth + 1, t))
                        case .handled: rep.handledCalls[t, default: 0] += 1
                        case .halt: break
                        case .unknown: rep.unknownCalls.append((ip, t, far))
                        }
                    } else {
                        rep.unknownCalls.append((ip, -1, nil))   // indirect: resolved at run time
                    }
                    ip = i.next
                    continue
                }
                if i.isJcc || ["loop", "loope", "loopne", "jcxz"].contains(m) {
                    if let t = i.target { work.append((t, depth, start)) }
                } else if m == "jmp" {
                    if let t = i.target { ip = t; continue }
                    break   // indirect (the dispatcher's jmp bx): the jump table entries are roots
                }
                if ["ret", "retf", "iret", "ljmp", "hlt", "int", "into", "int3"].contains(m) { break }
                ip = i.next
            }
        }
        return rep
    }
}
