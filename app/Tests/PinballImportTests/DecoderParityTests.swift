import Foundation
import XCTest
@testable import PinballImport

/// The Swift x86 decoder against capstone (what the Python extractors use), at every byte
/// offset of all 13 code segments. Needs the user's EXEs and .venv with capstone; skipped otherwise.
final class DecoderParityTests: XCTestCase {
    static let dumpScript = #"""
import sys, os
sys.path.insert(0, 'tools')
import epexe
from capstone import Cs, CS_ARCH_X86, CS_MODE_16
from capstone.x86 import X86_OP_IMM, X86_OP_MEM, X86_OP_REG
md = Cs(CS_ARCH_X86, CS_MODE_16); md.detail = True
TR = {'al','ah','bl','bh','cl','ch','dl','dh','ax','bx','cx','dx'}
out = sys.argv[1]
for n in range(1, 14):
    exe = epexe.load(f'original/EP{n}.EXE')
    base = exe.image_off(exe.entry_cs)
    d = exe.data
    with open(os.path.join(out, f'cs{n}.txt'), 'w') as f:
        for ip in range(0, 0x10000):
            buf = d[base + ip: base + ip + 16]
            if not buf: break
            i = next(md.disasm(buf, ip), None)
            if i is None:
                f.write(f'{ip:04x} -\n'); continue
            ops = []
            for o in i.operands:
                if o.type == X86_OP_REG: ops.append(f'r:{i.reg_name(o.reg)}:{o.size}')
                elif o.type == X86_OP_IMM: ops.append(f'i:{o.imm}:{o.size}')
                elif o.type == X86_OP_MEM:
                    m = o.mem
                    ops.append(f'm:{i.reg_name(m.segment) if m.segment else ""}:{i.reg_name(m.base) if m.base else ""}:{i.reg_name(m.index) if m.index else ""}:{m.disp}:{o.size}')
            try:
                _, wr = i.regs_access(); wr = sorted(i.reg_name(r) for r in wr if i.reg_name(r) in TR)
            except Exception:
                wr = ['ERR']
            f.write(f'{ip:04x} {i.size} {i.mnemonic}|{i.op_str}|{" ".join(ops)}|{",".join(wr)}\n')
"""#

    static func line(_ i: X86Instruction?, ip: Int) -> String {
        guard let i else { return String(format: "%04x -", ip) }
        let ops = i.operands.map { o -> String in
            switch o.kind {
            case .reg: return "r:\(o.reg):\(o.size)"
            case .imm: return "i:\(o.imm):\(o.size)"
            case .mem: return "m:\(o.segment ?? ""):\(o.base ?? ""):\(o.index ?? ""):\(o.disp):\(o.size)"
            }
        }.joined(separator: " ")
        return String(format: "%04x %d ", ip, i.size) + "\(i.mnemonic)|\(i.opStr)|\(ops)|\(i.written.sorted().joined(separator: ","))"
    }

    func testMatchesCapstoneOnEveryOffset() throws {
        try Repo.requireOriginal()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ep-cs-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let r = Repo.runPython(Self.dumpScript, args: [dir.path]), r.status == 0 else {
            throw XCTSkip(".venv/bin/python with capstone not available")
        }
        var compared = 0, skipped = 0
        var bad: [String] = []
        for n in 1...13 {
            let exeData = [UInt8](try Data(contentsOf: Repo.original.appendingPathComponent("EP\(n).EXE")))
            let exe = try MZImage(name: "EP\(n).EXE", data: exeData)
            let code = X86Code(data: exeData, base: exe.imageOff(exe.entryCS))
            let ref = try String(contentsOf: dir.appendingPathComponent("cs\(n).txt"), encoding: .utf8).split(separator: "\n")
            for l in ref {
                let ip = Int(l.prefix(4), radix: 16)!
                let mine = Self.line(code.at(ip), ip: ip)
                if mine == l { compared += 1; continue }
                // Outside the covered map: 0F / x87 / 66 / 67 (capstone decodes, we return nil).
                var b = code.base + ip
                var sawSize = false
                while b < exeData.count, [0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0xF2, 0xF3, 0xF0, 0x66, 0x67].contains(exeData[b]) {
                    if exeData[b] == 0x66 || exeData[b] == 0x67 { sawSize = true }
                    b += 1
                }
                let op = b < exeData.count ? exeData[b] : 0
                let xop = (op == 0x8F && b + 1 < exeData.count && (exeData[b + 1] >> 3) & 7 != 0)   // AMD XOP
                    || ((op == 0xC4 || op == 0xC5) && b + 1 < exeData.count && exeData[b + 1] >= 0xC0)   // VEX
                if code.at(ip) == nil && (sawSize || xop || op == 0x0F || (0xD8...0xDF).contains(op)) { skipped += 1; continue }
                if code.at(ip) == nil && exeData[code.base + ip] == 0xF0 { skipped += 1; continue }   // lock on 0F / x87
                bad.append("EP\(n) capstone: \(l)\n      swift:    \(mine)")
            }
        }
        print("decoder parity: \(compared) identical, \(skipped) outside the covered map, \(bad.count) different")
        for b in bad.prefix(60) { print(b) }
        XCTAssertTrue(bad.isEmpty, "\(bad.count) offsets decode differently from capstone")
    }
}
