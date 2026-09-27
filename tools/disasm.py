#!/usr/bin/env python3
"""Disassembly / annotation helper for Epic Pinball table executables.

Loads an EPn.EXE with tools/epexe.py, disassembles the entry code segment
with capstone (16-bit real mode), resolves DS- and CS-relative memory
operands to names from an optional JSON symbol file, and prints
cross-references.

Addresses are code-segment offsets (the entry CS, e.g. EP1 CS=0x3223) unless
written as SEG:OFF.  File offset = 0x400 + seg*16 + off.

Usage (from the repo root):
  .venv/bin/python tools/disasm.py [--exe original/EP1.EXE] [--syms FILE] CMD ...

  func  ADDR|NAME            disassemble a function by recursive descent
                             (follows jumps, not calls) in address order
  range START END            linear sweep START..END (END exclusive)
  xref  ADDR|NAME [--cs]     readers/writers of a DS variable (--cs: a
                             CS-relative variable, i.e. cs:[x] operands)
  callers ADDR|NAME          call sites of a routine
  io    [PORT]               every in/out, with DX resolved where possible
  imm   VALUE                instructions using an immediate/displacement
  funcs                      list discovered routines (call targets)
  vars                       list all DS/CS variables touched, with R/W counts
  fileoff ADDR               print file offset of cs:ADDR (or SEG:OFF)

Symbol file (JSON), all keys hex strings:
  {"exe": "EP1.EXE", "cs": "0x3223", "ds": "0x0015",
   "code":    {"0x2fc6": {"name": "timer_isr", "desc": "...", "conf": "high"}},
   "data":    {"0x679b": {"name": "opt_no_timer", "size": 1, "desc": "..."}},
   "cs_data": {"0x28b":  {"name": "vsync_locked", "size": 1}}}
"data" is DS-relative; "cs_data" is code-segment-relative (cs: overrides,
and DS-default operands while DS is known to equal CS).

Limitations: DS tracking is a per-path heuristic (see _ds_after); indirect
jumps/calls are not followed unless the target is listed under "code";
data embedded in the code segment can confuse the linear sweep.
"""
import argparse
import bisect
import json
import os
import re
import struct
import sys
from collections import defaultdict

from capstone import CS_ARCH_X86, CS_MODE_16, Cs
from capstone import x86 as X

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import epexe  # noqa: E402

CS_AC_READ, CS_AC_WRITE = 1, 2
BRANCH_UNCOND = {"jmp"}
RET = {"ret", "retf", "iret", "retn"}
SS_BASES = {X.X86_REG_BP, X.X86_REG_SP}


class Syms:
    def __init__(self, path=None):
        self.code, self.data, self.cs_data = {}, {}, {}
        self.meta = {}
        if path and os.path.exists(path) and os.path.getsize(path) > 0:
            j = json.load(open(path))
            self.meta = j
            for key in ("code", "data", "cs_data"):
                tbl = getattr(self, key)
                for k, v in j.get(key, {}).items():
                    tbl[int(k, 16)] = v
        self._sorted = {k: sorted(getattr(self, k)) for k in ("data", "cs_data")}

    def lookup_var(self, space, addr):
        """Return 'name' or 'name+N' for an address inside a sized symbol."""
        tbl = getattr(self, space)
        if addr in tbl:
            return tbl[addr]["name"]
        keys = self._sorted[space]
        i = bisect.bisect_right(keys, addr) - 1
        if i >= 0:
            base = keys[i]
            size = tbl[base].get("size", 1)
            if addr < base + size:
                return f"{tbl[base]['name']}+{addr - base:#x}"
        return None

    def by_name(self, name):
        for space in ("code", "data", "cs_data"):
            for a, v in getattr(self, space).items():
                if v["name"] == name:
                    return space, a
        return None, None


class Image:
    def __init__(self, exe_path, sym_path=None):
        self.exe = epexe.load(exe_path)
        self.cs = self.exe.entry_cs
        try:
            self.ds = epexe.data_segment(self.exe)
        except ValueError:  # not a table EXE (e.g. PINBALL.EXE): DS unknown
            self.ds = None
        base = self.exe.image_off(self.cs)
        self.code = self.exe.data[base:]
        self.base = base
        self.md = Cs(CS_ARCH_X86, CS_MODE_16)
        self.md.detail = True
        self.syms = Syms(sym_path)
        self._cache = {}
        self.insns = {}  # addr -> (insn, ds_state)
        self.funcs = set()
        self.labels = set()
        self._explored = False

    # ---- low level -----------------------------------------------------
    def insn(self, addr):
        if addr in self._cache:
            return self._cache[addr]
        if addr < 0 or addr >= len(self.code):
            return None
        it = next(self.md.disasm(self.code[addr : addr + 16], addr), None)
        self._cache[addr] = it
        return it

    def fileoff(self, off, seg=None):
        return self.exe.image_off(self.cs if seg is None else seg, off)

    def parse_addr(self, s):
        """Accept NAME, 0xOFF, OFF (hex), SEG:OFF."""
        if s in (v["name"] for v in self.syms.code.values()) or not re.fullmatch(
            r"(0x)?[0-9a-fA-F]+(:(0x)?[0-9a-fA-F]+)?", s
        ):
            space, a = self.syms.by_name(s)
            if a is None:
                raise SystemExit(f"unknown symbol {s}")
            return a
        if ":" in s:
            seg, off = (int(x, 16) for x in s.split(":"))
            return (seg - self.cs) * 16 + off
        return int(s, 16)

    # ---- control flow --------------------------------------------------
    @staticmethod
    def _target(i):
        if i.operands and i.operands[0].type == X.X86_OP_IMM:
            return i.operands[0].imm
        return None

    def _far_target(self, i):
        # capstone renders "lcall seg, off" with two imm operands
        if i.mnemonic in ("lcall", "ljmp") and len(i.operands) == 2:
            if all(o.type == X.X86_OP_IMM for o in i.operands):
                seg, off = i.operands[0].imm, i.operands[1].imm
                if seg == self.cs:
                    return off
        return None

    def _ds_after(self, i, prev, state):
        """Very small DS tracker: 'DS' (data seg), 'CS', a known constant
        segment such as '0x2623', or '?'.  Operands are only resolved to
        symbols while DS is 'DS' (data) or 'CS' (cs_data)."""
        m, ops = i.mnemonic, i.op_str
        if m == "pop" and ops == "ds":
            if prev is not None and prev.mnemonic == "push" and prev.op_str == "cs":
                return "CS"
            return "DS"  # assume it restores a pushed DS (typical epilogue)
        if m == "mov" and ops.startswith("ds,"):
            src = ops.split(",", 1)[1].strip()
            m2 = re.search(r"cs:\[(0x[0-9a-f]+|\d+)\]", src)
            if m2:  # mov ds, cs:[x] where x is flagged "holds_ds" in the symbol file
                ent = self.syms.cs_data.get(int(m2.group(1), 0), {})
                return "DS" if ent.get("holds_ds") else "?"
            if prev is not None and prev.mnemonic == "mov" and prev.op_str.split(",")[0] == src:
                try:
                    v = int(prev.op_str.split(",")[1], 0)
                    return "DS" if v == self.ds else f"{v:#06x}"
                except ValueError:
                    return "?"
            return "?"
        return state

    def explore(self, extra_roots=()):
        if self._explored and not extra_roots:
            return
        roots = [(self.exe.entry_ip, "DS")] + [(a, "DS") for a in self.syms.code] + [(a, "DS") for a in extra_roots]
        # interrupt handlers installed with int 21h/25h (dx = offset) and far calls into cs
        work = list(roots)
        self.funcs.update(a for a, _ in roots)
        seen_vec = set()
        while work:
            addr, state = work.pop()
            prev = None
            hist = []
            while addr not in self.insns:
                i = self.insn(addr)
                if i is None:
                    break
                self.insns[addr] = (i, state)
                state = self._ds_after(i, prev, state)
                m = i.mnemonic
                t = self._target(i)
                ft = self._far_target(i)
                if m == "call" and t is not None:
                    self.funcs.add(t)
                    work.append((t, "DS"))
                elif ft is not None:
                    self.funcs.add(ft)
                    work.append((ft, "DS"))
                elif (m.startswith("j") or m.startswith("loop")) and t is not None:
                    self.labels.add(t)
                    work.append((t, state))
                if m == "mov" and i.op_str.endswith(", cs") and prev is not None:
                    # "lea dx,[handler]; ... mov dx,cs" builds a far pointer to code
                    # (how EP1 installs its int 8 / int 9 handlers)
                    for h in hist[-3:]:
                        self._maybe_codeptr(h, seen_vec, work)
                if m == "int" and i.op_str == "0x21" and prev is not None:
                    self._maybe_vector(addr, seen_vec, work)
                if m == "jmp" and t is None:
                    for tgt in self._jump_table(i, prev):
                        self.labels.add(tgt)
                        work.append((tgt, state))
                if m in RET or m in ("jmp", "ljmp") or m == "hlt":
                    break
                prev = i
                hist.append(i)
                addr += i.size
        self._explored = True

    def _jump_table(self, i, prev):
        """Targets of 'jmp cs:[bx+T]' or 'mov bx,cs:[bx+T]; jmp bx' tables.

        Reads words from T while they look like code addresses and the
        cursor has not run into the lowest target seen so far.
        """
        tbl = None
        op = i.operands[0]
        if op.type == X.X86_OP_MEM and op.mem.segment == X.X86_REG_CS and op.mem.base != X.X86_REG_INVALID:
            tbl = op.mem.disp & 0xFFFF
        elif op.type == X.X86_OP_REG and prev is not None and prev.mnemonic == "mov":
            src = prev.operands[1] if len(prev.operands) == 2 else None
            if (src is not None and src.type == X.X86_OP_MEM and src.mem.segment == X.X86_REG_CS
                    and prev.operands[0].type == X.X86_OP_REG and prev.operands[0].reg == op.reg):
                tbl = src.mem.disp & 0xFFFF
        if tbl is None:
            return []
        self.tables = getattr(self, "tables", {})
        out, cur, lowest = [], tbl, len(self.code)
        while cur + 2 <= len(self.code) and cur < lowest and len(out) < 256:
            v = struct.unpack_from("<H", self.code, cur)[0]
            if not (0 < v < len(self.code)) or self.insn(v) is None:
                break
            out.append(v)
            lowest = min(lowest, v)
            cur += 2
        self.tables[tbl] = out
        return out

    def _maybe_codeptr(self, prev, seen, work):
        v = None
        if prev.mnemonic == "lea" and prev.operands[1].type == X.X86_OP_MEM:
            v = prev.operands[1].mem.disp & 0xFFFF
        elif prev.mnemonic == "mov" and prev.op_str.startswith("dx, ") and prev.operands[1].type == X.X86_OP_IMM:
            v = prev.operands[1].imm
        if v is not None and v not in seen and v < len(self.code):
            seen.add(v)
            self.funcs.add(v)
            work.append((v, "DS"))

    def _maybe_vector(self, int_addr, seen, work):
        """Look back a few instructions for 'mov dx, imm' + 'mov ah,25h'."""
        back = [a for a in self.insns if int_addr - 16 <= a < int_addr]
        dx = ah = None
        for a in sorted(back):
            i = self.insns[a][0]
            if i.mnemonic == "mov" and i.op_str.startswith("dx, ") and i.operands[1].type == X.X86_OP_IMM:
                dx = i.operands[1].imm
            if i.mnemonic == "mov" and i.op_str.startswith("ah, ") and i.operands[1].type == X.X86_OP_IMM:
                ah = i.operands[1].imm
            if i.mnemonic == "mov" and i.op_str.startswith("ax, ") and i.operands[1].type == X.X86_OP_IMM:
                ah = i.operands[1].imm >> 8
        if ah == 0x25 and dx is not None and dx not in seen:
            seen.add(dx)
            self.funcs.add(dx)
            work.append((dx, "DS"))

    # ---- memory operand classification ---------------------------------
    def mem_refs(self, i, ds_state="DS"):
        """Yield (space, addr, access, has_index) for absolute-ish memory operands."""
        for op in i.operands:
            if op.type != X.X86_OP_MEM:
                continue
            mem = op.mem
            seg = mem.segment
            if seg == X.X86_REG_CS:
                space = "cs_data"
            elif seg == X.X86_REG_INVALID and mem.base not in SS_BASES:
                space = {"DS": "data", "CS": "cs_data"}.get(ds_state)
            elif seg == X.X86_REG_DS:
                space = {"DS": "data", "CS": "cs_data"}.get(ds_state)
            else:
                space = None
            if space is None:
                continue
            if i.mnemonic == "lea":
                acc = 0
            else:
                acc = op.access
            indexed = mem.base != X.X86_REG_INVALID or mem.index != X.X86_REG_INVALID
            yield space, mem.disp & 0xFFFF, acc, indexed

    def annotate(self, i, ds_state):
        notes = []
        for space, addr, acc, idx in self.mem_refs(i, ds_state):
            name = self.syms.lookup_var(space, addr)
            if name:
                notes.append(("cs:" if space == "cs_data" else "") + name + ("[]" if idx else ""))
        if i.mnemonic in ("call", "jmp") or i.mnemonic.startswith("j"):
            t = self._target(i)
            if t is not None and t in self.syms.code:
                notes.append(self.syms.code[t]["name"])
        ft = self._far_target(i)
        if ft is not None and ft in self.syms.code:
            notes.append(self.syms.code[ft]["name"])
        if i.mnemonic == "lcall" and len(i.operands) == 2 and i.operands[0].imm != self.cs:
            seg = i.operands[0].imm
            notes.append(f"far {seg:#06x}:{i.operands[1].imm:#x} (file {self.exe.image_off(seg, i.operands[1].imm):#x})")
        if ds_state != "DS":
            notes.append(f"DS={ds_state}")
        return notes

    def fmt(self, i, ds_state="DS"):
        lab = ""
        if i.address in self.syms.code:
            lab = f"\n{self.syms.code[i.address]['name']}:  ; {self.syms.code[i.address].get('desc', '')}\n"
        elif i.address in self.funcs:
            lab = f"\nsub_{i.address:04x}:\n"
        elif i.address in self.labels:
            lab = f"loc_{i.address:04x}:\n"
        notes = self.annotate(i, ds_state)
        c = ("  ; " + ", ".join(notes)) if notes else ""
        return f"{lab}  {i.address:04x}  {i.bytes.hex():<16} {i.mnemonic:<6} {i.op_str}{c}"

    # ---- commands -------------------------------------------------------
    def func(self, start):
        self.explore([start])
        body = {}
        work = [start]
        while work:
            a = work.pop()
            while a in self.insns and a not in body:
                i, st = self.insns[a]
                body[a] = (i, st)
                t = self._target(i)
                if (i.mnemonic.startswith("j") or i.mnemonic.startswith("loop")) and t is not None:
                    work.append(t)
                if i.mnemonic in RET or i.mnemonic in ("jmp", "ljmp"):
                    break
                a += i.size
        prev_end = None
        out = []
        for a in sorted(body):
            i, st = body[a]
            if prev_end is not None and a != prev_end:
                out.append("  ...")
            out.append(self.fmt(i, st))
            prev_end = a + i.size
        return "\n".join(out)

    def linear(self, start, end):
        self.explore()
        out = []
        a = start
        while a < end:
            if a in self.insns:
                i, st = self.insns[a]
            else:
                i, st = self.insn(a), "DS"
                if i is None:
                    out.append(f"  {a:04x}  db {self.code[a]:02x}")
                    a += 1
                    continue
            flag = "" if a in self.insns else "   (unreached)"
            out.append(self.fmt(i, st) + flag)
            a += i.size
        return "\n".join(out)

    def all_refs(self):
        self.explore()
        refs = defaultdict(list)  # (space, addr) -> [(insn_addr, acc, indexed)]
        for a, (i, st) in self.insns.items():
            for space, addr, acc, idx in self.mem_refs(i, st):
                refs[(space, addr)].append((a, acc, idx))
        return refs

    def owner(self, addr):
        fs = sorted(self.funcs)
        k = bisect.bisect_right(fs, addr) - 1
        if k < 0:
            return "?"
        f = fs[k]
        return self.syms.code.get(f, {}).get("name", f"sub_{f:04x}")

    def xref(self, space, addr):
        refs = self.all_refs()
        out = []
        size = getattr(self.syms, space).get(addr, {}).get("size", 1)
        for (sp, a), lst in sorted(refs.items()):
            if sp != space or not (addr <= a < addr + size):
                continue
            for ia, acc, idx in sorted(lst):
                rw = ("R" if acc & CS_AC_READ else "") + ("W" if acc & CS_AC_WRITE else "") or "&"
                i = self.insns[ia][0]
                out.append(f"  {rw:<2} {ia:04x} in {self.owner(ia):<24} {i.mnemonic} {i.op_str}" + (f"   (+{a - addr:#x})" if a != addr else ""))
        return "\n".join(out) or "  (no references found)"

    def callers(self, target):
        self.explore()
        out = []
        for a, (i, _) in sorted(self.insns.items()):
            if (i.mnemonic == "call" and self._target(i) == target) or self._far_target(i) == target:
                out.append(f"  {a:04x} in {self.owner(a)}")
        return "\n".join(out) or "  (no direct callers)"

    def io(self, port=None):
        self.explore()
        out = []
        addrs = sorted(self.insns)
        for k, a in enumerate(addrs):
            i = self.insns[a][0]
            if i.mnemonic not in ("in", "out", "insb", "outsb", "insw", "outsw"):
                continue
            p = None
            imm = [o.imm for o in i.operands if o.type == X.X86_OP_IMM]
            if imm:
                p = imm[0]
            else:  # walk back for mov dx, imm / inc dx / dec dx / add dx
                delta = 0
                for b in reversed(addrs[max(0, k - 30) : k]):
                    j = self.insns[b][0]
                    if j.op_str.startswith("dx") or j.op_str == "dx":
                        if j.mnemonic == "mov" and len(j.operands) == 2 and j.operands[1].type == X.X86_OP_IMM:
                            p = j.operands[1].imm + delta
                            break
                        if j.mnemonic == "inc":
                            delta += 1
                            continue
                        if j.mnemonic == "dec":
                            delta -= 1
                            continue
                        if j.mnemonic in ("add", "sub") and j.operands[1].type == X.X86_OP_IMM:
                            delta += j.operands[1].imm if j.mnemonic == "add" else -j.operands[1].imm
                            continue
                        break
            if port is not None and p != port:
                continue
            ps = f"{p:#05x}" if p is not None else "dx=?"
            out.append(f"  {a:04x} {ps:<7} {i.mnemonic:<4} {i.op_str:<10} in {self.owner(a)}")
        return "\n".join(out)

    def imm(self, value):
        self.explore()
        out = []
        for a, (i, st) in sorted(self.insns.items()):
            hit = any((o.type == X.X86_OP_IMM and (o.imm & 0xFFFF) == value) or (o.type == X.X86_OP_MEM and (o.mem.disp & 0xFFFF) == value) for o in i.operands)
            if hit:
                out.append(f"  {a:04x} in {self.owner(a):<24} {i.mnemonic} {i.op_str}")
        return "\n".join(out)

    def list_funcs(self):
        self.explore()
        callers = defaultdict(int)
        for a, (i, _) in self.insns.items():
            t = self._target(i) if i.mnemonic == "call" else self._far_target(i)
            if t is not None:
                callers[t] += 1
        out = []
        for f in sorted(self.funcs):
            s = self.syms.code.get(f, {})
            out.append(f"  {f:04x} file {self.fileoff(f):#07x} callers={callers[f]:<3} {s.get('name', '')}  {s.get('desc', '')}")
        return "\n".join(out)

    def list_vars(self):
        refs = self.all_refs()
        out = []
        for (sp, a), lst in sorted(refs.items()):
            r = sum(1 for _, acc, _ in lst if acc & CS_AC_READ)
            w = sum(1 for _, acc, _ in lst if acc & CS_AC_WRITE)
            name = self.syms.lookup_var(sp, a) or ""
            pre = "cs:" if sp == "cs_data" else "ds:"
            out.append(f"  {pre}{a:04x}  R{r:<3} W{w:<3} {name}")
        return "\n".join(out)

    def read_var(self, space, addr, size=2):
        seg = self.ds if space == "data" else self.cs
        off = self.exe.image_off(seg, addr)
        return self.exe.data[off : off + size]


def main(argv=None):
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--exe", default=os.path.join(here, "original", "EP1.EXE"))
    ap.add_argument("--syms", default=None, help="symbol JSON (default: scratch/engine/<exe>_symbols.json if present)")
    ap.add_argument("cmd")
    ap.add_argument("args", nargs="*")
    ap.add_argument("--cs", action="store_true", help="xref: CS-relative variable")
    a = ap.parse_args(argv)
    if a.syms is None:
        stem = os.path.splitext(os.path.basename(a.exe))[0].lower()
        cand = os.path.join(here, "scratch", "engine", f"{stem}_symbols.json")
        a.syms = cand if os.path.exists(cand) else None
    img = Image(a.exe, a.syms)
    c = a.cmd
    if c == "func":
        print(img.func(img.parse_addr(a.args[0])))
    elif c == "range":
        print(img.linear(img.parse_addr(a.args[0]), img.parse_addr(a.args[1])))
    elif c == "xref":
        name = a.args[0]
        space, addr = img.syms.by_name(name)
        if addr is None:
            addr = int(name, 16)
            space = "cs_data" if a.cs else "data"
        print(f"xrefs to {space}:{addr:#06x} ({img.syms.lookup_var(space, addr) or 'unnamed'})")
        print(img.xref(space, addr))
    elif c == "callers":
        print(img.callers(img.parse_addr(a.args[0])))
    elif c == "io":
        print(img.io(int(a.args[0], 16) if a.args else None))
    elif c == "imm":
        print(img.imm(int(a.args[0], 0)))
    elif c == "funcs":
        print(img.list_funcs())
    elif c == "vars":
        print(img.list_vars())
    elif c == "fileoff":
        s = a.args[0]
        if ":" in s:
            seg, off = (int(x, 16) for x in s.split(":"))
            print(hex(img.exe.image_off(seg, off)))
        else:
            print(hex(img.fileoff(img.parse_addr(s))))
    else:
        ap.error(f"unknown command {c}")


if __name__ == "__main__":
    main()
