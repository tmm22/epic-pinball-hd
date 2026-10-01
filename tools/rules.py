#!/usr/bin/env python3
"""Lift Epic Pinball table rules into a data-driven JSON form.

Every table EXE carries its own rules as real-mode code: a jump table indexed
by (palette index - 0xAA) that is dispatched when the ball overlaps a sensor
pixel, plus a few rule fragments in the main loop (kicker scoring, timers,
lane change on flipper press, end of ball).  This tool lifts that code into
the "epic-pinball-rules/1" schema documented in docs/formats/rules.md:

  * a state model: the table's own data segment (read from the user's EXE at
    runtime) with named variables, lamp table, per-player block;
  * sensors: palette index -> handler, per ball level, with pixel regions;
  * handlers/hooks: control-flow graphs of blocks whose ops are either
    semantic (score, lamp, sound, message, ball set, layer, pixel/gate edit)
    or generic (set/store/reg on 16-bit integer expressions);
  * messages by data-segment offset only (the text stays in the EXE).

Nothing from the game is embedded in this file.  All values (scores, lamp
slots, positions, timers, message offsets) are read from original/EPn.EXE
when the tool runs.  The EP1 annotations below are names and descriptions
written during reverse engineering; they are keyed by EP1 code/data
addresses and only applied to EP1.

Usage (repo root):
  .venv/bin/python tools/rules.py 1            # -> extracted/tables/EP1/rules.json
  .venv/bin/python tools/rules.py 2 10 --report
  .venv/bin/python tools/rules.py 1 --dump h2379   # print one handler as text
"""
import argparse
import json
import os
import re
import struct
import sys
from collections import Counter, defaultdict, deque

import numpy as np
from capstone import x86 as X

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import disasm  # noqa: E402
import epexe  # noqa: E402

SCHEMA = "epic-pinball-rules/1"
REG16 = ("ax", "bx", "cx", "dx", "si", "di", "bp", "sp")
REG8 = {"al": ("ax", 0), "ah": ("ax", 1), "bl": ("bx", 0), "bh": ("bx", 1),
        "cl": ("cx", 0), "ch": ("cx", 1), "dl": ("dx", 0), "dh": ("dx", 1)}
JCC = {"je": "eq", "jne": "ne", "jb": "ult", "jae": "uge", "jbe": "ule", "ja": "ugt",
       "jl": "slt", "jge": "sge", "jle": "sle", "jg": "sgt", "js": "neg", "jns": "nonneg"}
NEGATE = {"eq": "ne", "ne": "eq", "ult": "uge", "uge": "ult", "ule": "ugt", "ugt": "ule",
          "slt": "sge", "sge": "slt", "sle": "sgt", "sgt": "sle", "neg": "nonneg", "nonneg": "neg"}


def h(v):
    return f"{v:#06x}"


# ---------------------------------------------------------------------------
# expressions: int | ["reg", r] | ["mem", w, addr] | ["cmem", w, addr] | [op, a, b...]
# All arithmetic is 16-bit wrap-around unless the op name says 32.

def is_const(e):
    return isinstance(e, int)


def simp(e):
    if not isinstance(e, list):
        return e
    op = e[0]
    a = e[1] if len(e) > 1 else None
    b = e[2] if len(e) > 2 else None
    if op in ("add", "sub", "and", "or", "xor", "shl", "shr", "mul") and is_const(a) and is_const(b):
        r = {"add": a + b, "sub": a - b, "and": a & b, "or": a | b, "xor": a ^ b,
             "shl": a << b, "shr": a >> b, "mul": a * b}[op]
        return r & 0xFFFF
    if op == "add" and b == 0:
        return a
    if op == "add" and a == 0:
        return b
    if op == "sub" and b == 0:
        return a
    if op in ("add", "sub") and is_const(b) and isinstance(a, list) and a[0] == "add" and is_const(a[2]):
        k = a[2] + b if op == "add" else a[2] - b
        return simp(["add", a[1], k & 0xFFFF])
    if op == "lo" and is_const(a):
        return a & 0xFF
    if op == "hi" and is_const(a):
        return (a >> 8) & 0xFF
    if op == "lo" and isinstance(a, list) and a[0] == "setlo":
        return a[2] if is_byte(a[2]) else ["and", a[2], 0xFF]
    if op == "hi" and isinstance(a, list) and a[0] == "sethi":
        return a[2] if is_byte(a[2]) else ["and", a[2], 0xFF]
    if op == "hi" and isinstance(a, list) and a[0] == "setlo":
        return simp(["hi", a[1]])
    if op == "lo" and isinstance(a, list) and a[0] == "sethi":
        return simp(["lo", a[1]])
    if op == "sethi" and b == 0 and isinstance(a, list) and a[0] == "setlo":
        return a[2] if is_byte(a[2]) else ["and", a[2], 0xFF]
    if op == "setlo" and is_const(a) and is_const(b):
        return (a & 0xFF00) | (b & 0xFF)
    if op == "sethi" and is_const(a) and is_const(b):
        return (a & 0x00FF) | ((b & 0xFF) << 8)
    if op == "neg" and is_const(a):
        return (-a) & 0xFFFF
    if op == "join" and is_const(a) and is_const(b):
        return ((a & 0xFFFF) << 16) | (b & 0xFFFF)
    if op == "join" and isinstance(a, list) and isinstance(b, list):
        if a[0] == "hi16" and b[0] == "lo16" and a[1] == b[1]:
            return a[1]
        if a[0] == "mem" and b[0] == "mem" and a[1] == 2 and b[1] == 2 and is_const(a[2]) and is_const(b[2]) and a[2] == b[2] + 2:
            return ["mem", 4, b[2]]
    return e


def has_mem(e):
    if not isinstance(e, list):
        return False
    if e[0] == "mem":
        return True
    return any(has_mem(x) for x in e[1:])


def has_tag(e, tag):
    if not isinstance(e, list):
        return False
    if e and e[0] == tag:
        return True
    return any(has_tag(x, tag) for x in e[1:])


def may_alias(e, addr, w):
    """Could expression e read DS memory overlapping [addr, addr+w)?"""
    if not isinstance(e, list):
        return False
    if e and e[0] == "mem":
        ma, mw = e[2], e[1]
        if not is_const(ma) or not is_const(addr):
            return True
        return ma < addr + w and addr < ma + mw
    return any(may_alias(x, addr, w) for x in e[1:])


def signed(e):
    return e - 0x10000 if is_const(e) and 0x8000 <= e <= 0xFFFF else e


def is_byte(e):
    if is_const(e):
        return 0 <= e < 256
    if isinstance(e, list) and e:
        if e[0] == "mem" and e[1] == 1:
            return True
        if e[0] in ("lo", "hi"):
            return True
        if e[0] == "and" and is_const(e[2]) and e[2] < 256:
            return True
    return False


def regs_in(e, out):
    if isinstance(e, list):
        if e[0] == "reg":
            out.add(e[1])
        else:
            for x in e[1:]:
                regs_in(x, out)
    elif isinstance(e, dict):
        for v in e.values():
            regs_in(v, out)
    return out


def walk_expr(e, fn):
    """Post-order rewrite."""
    if isinstance(e, list) and e and isinstance(e[0], str):
        e = [e[0]] + [walk_expr(x, fn) for x in e[1:]]
        return fn(e)
    if isinstance(e, dict):
        return {k: walk_expr(v, fn) for k, v in e.items()}
    return e


def fmt_expr(e):
    if is_const(e):
        return f"{e:#x}" if e > 9 else str(e)
    if isinstance(e, dict):
        return "{" + ", ".join(f"{k}: {fmt_expr(v)}" for k, v in e.items()) + "}"
    if not isinstance(e, list):
        return str(e)
    if not e or not isinstance(e[0], str):
        return "[" + " ".join(fmt_expr(x) for x in e) + "]"
    op = e[0]
    if op == "reg":
        return "$" + e[1]
    if op == "var":
        return e[1]
    if op == "mem":
        return f"mem{e[1]}[{fmt_expr(e[2])}]"
    if op == "cmem":
        return f"cs:mem{e[1]}[{fmt_expr(e[2])}]"
    if op == "ball":
        return f"ball.{e[1]}"
    if op == "lamp":
        return f"lamp[{fmt_expr(e[1])}]"
    sym = {"add": "+", "sub": "-", "and": "&", "or": "|", "xor": "^", "shl": "<<", "shr": ">>", "mul": "*"}
    if op in sym:
        return f"({fmt_expr(e[1])} {sym[op]} {fmt_expr(e[2])})"
    return f"{op}(" + ", ".join(fmt_expr(x) for x in e[1:]) + ")"


# ---------------------------------------------------------------------------
# table context: addresses of engine variables and helper routines


class Table:
    def __init__(self, n):
        self.n = n
        self.path = os.path.join(ROOT, "original", f"EP{n}.EXE")
        syms = os.path.join(ROOT, "scratch", "engine", "ep1_symbols.json") if n == 1 else None
        self.img = disasm.Image(self.path, syms)
        self.exe = self.img.exe
        self.cs, self.ds = self.img.cs, self.img.ds
        self.code = self.img.code
        self.col = json.load(open(os.path.join(ROOT, "extracted", "tables", f"EP{n}", "collision.json")))
        self.cb = np.load(os.path.join(ROOT, "extracted", "tables", f"EP{n}", "collision_idx.npy"))
        top = epexe.find_playfield_segments(self.exe)[0]
        self.ds_size = (top - self.ds) * 16
        self.ds_file = self.exe.image_off(self.ds)
        self.dsmem = self.exe.data[self.ds_file:self.ds_file + self.ds_size]
        self.img.explore()
        self.roles = {}      # ds addr -> (role, width)
        self.routines = {}   # cs addr -> role
        self.notes = []
        self.discover()

    # -- helpers -------------------------------------------------------------
    def insn(self, a):
        return self.img.insn(a)

    def seq(self, a, n):
        out = []
        for _ in range(n):
            i = self.insn(a)
            if i is None:
                break
            out.append(i)
            a += i.size
        return out

    def ds_word(self, a):
        return struct.unpack_from("<H", self.dsmem, a)[0]

    def cs_word(self, a):
        return struct.unpack_from("<H", self.code, a)[0]

    def all_insns(self):
        return sorted(self.img.insns.items())

    def find_bytes(self, pat, start=0, end=None):
        end = len(self.code) if end is None else end
        return [m.start() + start for m in re.finditer(pat, self.code[start:end], re.S)]

    @staticmethod
    def mem_disp(i, k):
        op = i.operands[k]
        if op.type == X.X86_OP_MEM and op.mem.base == 0 and op.mem.index == 0 and op.mem.segment in (0, X.X86_REG_DS):
            return op.mem.disp & 0xFFFF
        return None

    # -- discovery -----------------------------------------------------------
    def discover(self):
        c = self.col
        R = self.roles
        wl, occ = c["wall_loop"], c["occlusion"]
        bx_ = int(wl["ball_x_var"], 16)
        R[int(occ["level_var"], 16)] = ("ball.layer", 1)
        R[int(c["sensor_debounce_var"], 16)] = ("sensor_lockout", 1)
        self.ball_x_arr = bx_
        self.ball_layer_arr = int(wl["level_var"], 16)
        self.dispatch_ip = int(c["sensor_routine_ip"][0], 16)
        self.table_ip = int(c["trigger_table"]["table_ip"], 16)
        self.seg_top = int(c["collision_buffer"]["top_seg_var"], 16)
        self.seg_bottom = int(c["collision_buffer"]["bottom_seg_var"], 16)
        kick = set()
        for ev in c["wall_events"][0].values():
            for s in ev:
                m = re.match(r"call (0x[0-9a-f]+)", s)
                if m:
                    kick.add(int(m.group(1), 16))
        self.kicker_routines = sorted(kick)

        # ball working copy + writeback: "cmp byte [W],0; je; mov ax,[O]; mov [di+ARR],ax" x4
        self.ball_arrays = {"x": bx_, "y": int(wl["ball_y_var"], 16)}
        # slot arrays: from the emulator harness's search when available (EP3/EP5/EP6 lay them out differently
        # from EP1); EP1's offsets otherwise (identical for EP1)
        self.emu_cfg = _emu_config(self.n, self.path)
        ecfg = (self.emu_cfg or {}).get("ds_vars", {})
        field_of = {bx_: "x", bx_ + 0x0C: "y", bx_ - 0x46: "vx", bx_ - 0x3A: "vy"}
        if all(k in ecfg for k in ("ball_x", "ball_y", "ball_vx", "ball_vy")) and ecfg["ball_x"] == bx_:
            field_of = {ecfg["ball_x"]: "x", ecfg["ball_y"]: "y", ecfg["ball_vx"]: "vx", ecfg["ball_vy"]: "vy"}
        for a, (i, _) in self.all_insns():
            if i.mnemonic == "cmp" and i.op_str.endswith(", 0") and i.operands[0].size == 1:
                w = self.mem_disp(i, 0)
                if w is None:
                    continue
                s = self.seq(a, 10)
                if len(s) < 10 or not s[1].mnemonic == "je":
                    continue
                pairs = []
                for k in range(2, 10, 2):
                    ld, st = s[k], s[k + 1]
                    if not (ld.mnemonic == "mov" and st.mnemonic == "mov" and ld.op_str.startswith("ax, word ptr [")):
                        break
                    o = self.mem_disp(ld, 1)
                    m = re.match(r"word ptr \[di \+ (0x[0-9a-f]+)\], ax", st.op_str)
                    if o is None or not m:
                        break
                    pairs.append((o, int(m.group(1), 16)))
                if len(pairs) == 4 and any(arr == bx_ for _, arr in pairs):
                    R[w] = ("ball.writeback", 1)
                    for o, arr in pairs:
                        field = field_of.get(arr)
                        if field is None:
                            self.notes.append(f"unexpected writeback array {h(arr)}")
                            continue
                        R[o] = (f"ball.{field}", 2)
                        self.ball_arrays[field] = arr
                    break
        if "vx" not in self.ball_arrays:
            self.notes.append("ball working copy not found")
        # keyboard flags (set by the int 9 handler in CS) read by rule code -> ["input", name]
        if self.n == 1:
            self.cs_inputs = dict(EP1_CS_INPUTS)
        else:
            csv = (self.emu_cfg or {}).get("cs_vars", {})
            self.cs_inputs = {csv[k]: nm for k, nm in (("key_lflip", "flipper_left"), ("key_rflip", "flipper_right")) if k in csv}
        self.ball_arrays.setdefault("active", ecfg.get("ball_active", bx_ - 0x0C))
        self.ball_arrays.setdefault("vx", ecfg.get("ball_vx", bx_ - 0x46))
        self.ball_arrays.setdefault("vy", ecfg.get("ball_vy", bx_ - 0x3A))

        # score: most common "add word [S], imm ; adc word [S+2], imm"
        cnt = Counter()
        for a, (i, _) in self.all_insns():
            if i.mnemonic == "add" and i.op_str.startswith("word ptr [") and i.operands[1].type == X.X86_OP_IMM:
                s = self.mem_disp(i, 0)
                j = self.insn(a + i.size)
                if s is not None and j is not None and j.mnemonic == "adc" and self.mem_disp(j, 0) == s + 2:
                    cnt[s] += 1
        self.score = cnt.most_common(1)[0][0]
        R[self.score] = ("score", 4)

        # score_refresh: near call right after "mov ax,[S]; mov dx,[S+2]"
        cnt = Counter()
        for a, (i, _) in self.all_insns():
            if i.mnemonic == "mov" and i.op_str == f"ax, word ptr [{self.score:#x}]":
                s = self.seq(a, 3)
                if len(s) == 3 and s[1].op_str == f"dx, word ptr [{self.score + 2:#x}]" and s[2].mnemonic == "call":
                    cnt[s[2].operands[0].imm] += 1
        if cnt:
            self.routines[cnt.most_common(1)[0][0]] = "score_refresh"

        # message routine: near call preceded (within 3) by lea bx,[str] and mov di,imm
        cnt = Counter()
        far = Counter()
        prev = deque(maxlen=4)
        for a, (i, _) in self.all_insns():
            if i.mnemonic in ("call", "lcall") and any(p.mnemonic == "lea" and p.op_str.startswith("bx, [") for p in prev) \
                    and any(p.op_str.startswith("di, ") for p in prev):
                if i.mnemonic == "call" and i.operands[0].type == X.X86_OP_IMM:
                    cnt[i.operands[0].imm] += 1
                elif i.mnemonic == "lcall" and len(i.operands) == 2 and i.operands[0].imm == self.cs:
                    far[i.operands[1].imm] += 1
            prev.append(i)
        if cnt:
            self.routines[cnt.most_common(1)[0][0]] = "message"
        for t, k in far.most_common(3):
            self.routines.setdefault(t, "text")
        # number formatting: far call preceded by lea bx,[buf] and whose body compares dx,ax with a table
        for a, (i, _) in self.all_insns():
            if i.mnemonic == "lcall" and len(i.operands) == 2 and i.operands[0].imm == self.cs:
                t = i.operands[1].imm
                if t in self.routines:
                    continue
                body = self.seq(t, 12)
                if any(b.mnemonic == "cmp" and b.op_str.startswith("dx, word ptr [di") for b in body):
                    self.routines[t] = "number_text"

        # sfx: queued id  "cmp word [Q], -1"  then mov ax,[Q] ... lcall play
        for a, (i, _) in self.all_insns():
            if i.mnemonic == "cmp" and i.op_str.endswith(", -1") and i.op_str.startswith("word ptr ["):
                q = self.mem_disp(i, 0)
                if q is None:
                    continue
                s = self.seq(a, 24)
                ld = [k for k, j in enumerate(s) if j.op_str == f"ax, word ptr [{q:#x}]"]
                if not ld:
                    continue
                for j in s[ld[0]:]:
                    if j.mnemonic == "mov" and j.op_str.startswith("word ptr [") and j.operands[1].type == X.X86_OP_IMM and j.operands[1].imm == 0x2AF8:
                        R[self.mem_disp(j, 0)] = ("sound.rate", 2)
                    if j.mnemonic == "lcall":
                        self.routines[j.operands[1].imm] = "sound_play"
                        R[q] = ("sound.queue", 2)
                        break
                if q in R:
                    break
        # immediate sound: "cmp word [N],0; je; mov ax,[N]; lcall play; mov word [N],0"
        play = [t for t, r in self.routines.items() if r == "sound_play"]
        for a, (i, _) in self.all_insns():
            if i.mnemonic == "cmp" and i.op_str.startswith("word ptr [") and i.op_str.endswith(", 0"):
                N = self.mem_disp(i, 0)
                if N is None:
                    continue
                s = self.seq(a, 5)
                if len(s) == 5 and s[2].op_str == f"ax, word ptr [{N:#x}]" and s[3].mnemonic == "lcall" and play and s[3].operands[1].imm in play \
                        and s[4].op_str == f"word ptr [{N:#x}], 0":
                    R.setdefault(N, ("sound.now", 2))

        # pitch sweeps: "inc byte [A]; (..) mov al,[A]; and al,M; cmp al,P" then
        # "add/sub word [rate], step; cmp word [rate], limit" and sound-id loads
        self.sweeps = []
        rate = next((a_ for a_, r in R.items() if r[0] == "sound.rate"), None)
        found = []
        for a, (i, _) in self.all_insns():
            if i.mnemonic == "inc" and i.op_str.startswith("byte ptr ["):
                A = self.mem_disp(i, 0)
                if A is None:
                    continue
                s = self.seq(a, 7)
                k0 = next((k for k in range(1, 5) if k + 2 < len(s) and s[k].op_str == f"al, byte ptr [{A:#x}]"), None)
                if k0 is not None and s[k0 + 1].mnemonic == "and" and s[k0 + 2].mnemonic == "cmp" and s[k0 + 2].op_str.startswith("al, "):
                    found.append((a, A, s[k0 + 1].operands[1].imm, s[k0 + 2].operands[1].imm))
        for n_, (a, A, mask, phase) in enumerate(found):
            end_a = found[n_ + 1][0] if n_ + 1 < len(found) else a + 0x80
            body = []
            x = a
            while x < end_a and len(body) < 40:
                j = self.insn(x)
                if j is None:
                    break
                body.append(j)
                x += j.size
            sw = {"var": h(A), "every_frames_mask": mask, "phase": phase, "rate_step": None, "rate_limit": None, "ids": []}
            for k, j in enumerate(body):
                if rate is not None and j.mnemonic in ("add", "sub") and self.mem_disp(j, 0) == rate and j.operands[1].type == X.X86_OP_IMM and sw["rate_step"] is None:
                    sw["rate_step"] = j.operands[1].imm if j.mnemonic == "add" else -j.operands[1].imm
                if rate is not None and j.mnemonic == "cmp" and self.mem_disp(j, 0) == rate and sw["rate_limit"] is None:
                    sw["rate_limit"] = j.operands[1].imm
                if j.mnemonic == "mov" and j.op_str.startswith("ax, word ptr [") and k + 1 < len(body):
                    v = self.mem_disp(j, 1)
                    if v is None or v == rate or v in [int(q["var"], 16) for q in sw["ids"]]:
                        continue
                    if v in R and not R[v][0].startswith("sound.sweep@"):
                        continue
                    at_end = body[k + 1].mnemonic == "cmp" and body[k + 1].op_str == "ax, 0"
                    sw["ids"].append({"var": h(v), "played": "at_end" if at_end else "each_step"})
            key = f"sound.sweep@{A:04x}"
            R[A] = (key, 1)
            for q in sw["ids"]:
                nm = "end_id" if q["played"] == "at_end" else "step_id"
                R.setdefault(int(q["var"], 16), (f"{key}.{nm}", 2))
            self.sweeps.append(sw)
        # lamp table: callers "lea si,[T]; lcall L" where L contains the lamp blit signature
        lamp_rt = None
        for m in re.finditer(rb"\xba..\x8e\xda\x8b\xb7..\x56\x9a", self.code, re.S):
            fs = sorted(f for f in self.img.funcs if f <= m.start())
            if fs:
                lamp_rt = fs[-1]
        self.lamp_table = None
        if lamp_rt is not None:
            self.routines[lamp_rt] = "lamp_update"
            cands, shows = [], []
            addrs = sorted(self.img.insns)
            import bisect as _b
            for a, (i, _) in self.all_insns():
                if i.mnemonic == "lcall" and len(i.operands) == 2 and i.operands[1].imm == lamp_rt:
                    k = _b.bisect_left(addrs, a)
                    for b_ in reversed(addrs[max(0, k - 24):k]):
                        p = self.img.insns[b_][0]
                        if p.mnemonic == "lea" and p.op_str.startswith("si, ["):
                            cands.append(self.mem_disp(p, 1))
                            break
                        m2 = re.match(r"si, word ptr \[bx \+ (0x[0-9a-f]+)\]", p.op_str)
                        if p.mnemonic == "mov" and m2:
                            shows.append(int(m2.group(1), 16))
            self.player_block = None
            for m in re.finditer(rb"\x8d\x3e(..)\x8d\x0e(..)\x2b\xcf", self.code, re.S):
                self.player_block = (struct.unpack("<H", m.group(1))[0], struct.unpack("<H", m.group(2))[0])
                break
            best = None
            for t in set(cands):
                if t is None:
                    continue
                end = self.dsmem.index(b"\xff", t + 1)
                inside = bool(self.player_block and self.player_block[0] <= t < self.player_block[1])
                stores = sum(1 for a, (i, _) in self.all_insns() if i.mnemonic == "mov" and i.op_str.startswith("byte ptr [")
                             and self.mem_disp(i, 0) is not None and t < self.mem_disp(i, 0) < end)
                key = (inside, stores)
                if best is None or key > best[2]:
                    best = (t, end, key)
            if best:
                self.lamp_table = {"phase": best[0], "first": best[0] + 1, "count": best[1] - best[0] - 1, "terminator": best[1],
                                   "other_tables": sorted(h(c) for c in set(cands) if c not in (None, best[0])),
                                   "show_table_pointers": [h(x) for x in sorted(set(shows))]}


        # extra gravity: "mov ax,[G0]; add ax,[G]; add [di+vy],ax"
        for a, (i, _) in self.all_insns():
            if i.mnemonic == "add" and i.op_str.startswith("ax, word ptr ["):
                j = self.insn(a + i.size)
                if j is not None and j.mnemonic == "add" and j.op_str == f"word ptr [di + {self.ball_arrays['vy']:#x}], ax":
                    R[self.mem_disp(i, 1)] = ("extra_gravity", 2)
        # dispatcher: tilt test "cmp byte [T],1" and sensor cooldown before the call
        self.dispatch_tail = None
        for i in self.seq(self.dispatch_ip, 6):
            if i.mnemonic == "jb":
                j = self.insn(i.operands[0].imm)
                if j is not None and j.mnemonic == "jmp" and j.operands[0].type == X.X86_OP_IMM:
                    tgt = j.operands[0].imm
                    if self.code[tgt:tgt + 3] not in (b"\x61\x07\xc3", b"\x07\x61\xc3", b"\x61\xc3"):
                        self.dispatch_tail = tgt
                break
        for i in self.seq(self.dispatch_ip, 40):
            if i.mnemonic == "cmp" and i.op_str.startswith("byte ptr [") and i.op_str.endswith(", 1"):
                t = self.mem_disp(i, 0)
                if t is not None and t not in R:
                    R[t] = ("tilted", 1)
            if i.mnemonic == "jmp" and i.operands[0].type == X.X86_OP_REG:
                break
        occ_ip = int(occ["start_ip"], 16)
        for i in self.seq(occ_ip, 60):
            if i.mnemonic == "cmp" and i.op_str.startswith("byte ptr [") and i.op_str.endswith(", 0"):
                t = self.mem_disp(i, 0)
                if t is not None and t not in R:
                    R[t] = ("sensor_cooldown", 1)
        # kicker: "mov al,[param]; mov [K],al; mov byte [C],3" (EP3 cs:175F: through ah)
        for k in self.kicker_routines:
            s = self.seq(k, 12)
            for x, i in enumerate(s):
                if i.mnemonic == "mov" and i.op_str.startswith("byte ptr [") and i.op_str.endswith((", al", ", ah")) and x + 1 < len(s):
                    R.setdefault(self.mem_disp(i, 0), ("kick_strength", 1))
                    nx = s[x + 1]
                    if nx.mnemonic == "mov" and nx.op_str.startswith("byte ptr [") and nx.operands[1].type == X.X86_OP_IMM:
                        R.setdefault(self.mem_disp(nx, 0), ("kicker_cooldown", 1))
                    break

        # gates: routines storing a cs-table of offsets into the collision buffer
        self.gates = []
        pat = rb"\x2e\x8b\xbc(..)\x26\x88\x05"  # mov di,cs:[si+T]; mov es:[di],al
        for m in re.finditer(pat, self.code, re.S):
            t = struct.unpack("<H", m.group(1))[0]
            fs = sorted(f for f in self.img.funcs if f <= m.start())
            if not fs:
                continue
            rt = fs[-1]
            body = self.seq(rt, 20)
            vals, ctrl, seg = [], None, None
            for i in body:
                if i.mnemonic == "mov" and i.op_str.startswith("al, ") and i.operands[1].type == X.X86_OP_IMM:
                    vals.append(i.operands[1].imm)
                if i.mnemonic == "cmp" and i.op_str.startswith("byte ptr [") and i.op_str.endswith(", 0"):
                    ctrl = self.mem_disp(i, 0)
                if i.mnemonic == "mov" and i.op_str.startswith("es, word ptr ["):
                    seg = self.mem_disp(i, 1)
            count = self.cs_word(t)
            offs = [self.cs_word(t + 2 + 2 * k) for k in range(count)]
            half = 1 if seg == self.seg_bottom else 0
            gid = f"gate{len(self.gates)}"
            self.gates.append({"id": gid, "routine": h(rt), "table": f"cs:{t:04x}", "control_var": ctrl,
                               "value_if_control_zero": vals[0] if vals else None,
                               "value_if_control_nonzero": vals[1] if len(vals) > 1 else None,
                               "half": half,
                               "pixels": [[o % 320, o // 320 + 200 * half] for o in offs]})
            self.routines[rt] = f"gate:{gid}"
            if ctrl is not None:
                R.setdefault(ctrl, (f"{gid}.open", 1))
        for rt in self.kicker_routines:
            self.routines.setdefault(rt, "kicker")

        seen = Counter()
        for a_ in sorted(R):
            name, w = R[a_]
            seen[name] += 1
            if seen[name] > 1:
                R[a_] = (f"{name}#{seen[name]}", w)
                self.notes.append(f"duplicate role {name} at {h(a_)} renamed")

    def far_ds_display(self, tgt):
        """A display routine that switches DS to a constant (graphics library) segment before any memory
        write: "[cld|push r|pusha]*; mov dx|ax,SEG; mov ds,dx|ax".  It cannot touch the table's DS state,
        so rule code calling it is lifted with a display op (EP4 cs:c5cb, EP6 cs:41a0, EP8 cs:a42f).
        Not applied to EP1, whose rule code calls no such routine."""
        if self.n == 1:
            return False
        body = self.seq(tgt, 8)
        for k, j in enumerate(body[:-1]):
            if j.mnemonic == "mov" and j.op_str in ("ds, dx", "ds, ax", "ds, cx"):
                prev = body[k - 1] if k else None
                # EP9 cs:A48D: "pusha; push ds; mov cx, cs; mov ds, cx" (a sprite blit reading its table via DS = CS)
                if (prev is not None and prev.mnemonic == "mov" and prev.op_str == j.op_str[4:] + ", cs"
                        and all(b.mnemonic in ("push", "pusha", "pushaw", "cld") for b in body[:k - 1])):
                    return True
                return (prev is not None and prev.mnemonic == "mov" and prev.op_str.startswith(("dx, 0x", "ax, 0x"))
                        and prev.operands[1].imm != self.ds
                        and all(b.mnemonic in ("push", "pusha", "pushaw", "cld", "mov") and b.operands and
                                b.operands[0].type != X.X86_OP_MEM or b.mnemonic in ("pusha", "pushaw", "cld") for b in body[:k]))
        return False

    # -- role lookup -----------------------------------------------------------
    def role_of(self, a):
        if a in self.roles:
            return self.roles[a]
        lt = self.lamp_table
        if lt and lt["first"] <= a < lt["terminator"]:
            return ("lamp", a - lt["first"])
        return None

    def ball_slot(self, a):
        for field, base in self.ball_arrays.items():
            if base <= a < base + 10 and (a - base) % 2 == 0:
                return field, (a - base) // 2
        if self.ball_layer_arr <= a < self.ball_layer_arr + 10 and (a - self.ball_layer_arr) % 2 == 0:
            return "layer", (a - self.ball_layer_arr) // 2
        return None


# ---------------------------------------------------------------------------
# lifter


class Lifter:
    def __init__(self, t: Table):
        self.t = t
        self.blocks = {}        # ip -> block dict
        self.leaders = set()
        self.body = {}          # ip -> insn (discovered)
        self.stops = set()      # ips treated as "return"
        self.subs = set()       # near routines lifted as gosub targets
        self.entries = set()    # handler/hook entry ips
        self.stub_routines = {}  # display-only routines called from rule code
        self.kicker_blocks = set()
        self.unsupported = Counter()
        self.flags_in = {}       # block start -> flags state at entry (flag joins only)
        self.capture_end = set()  # blocks whose final flags are captured into fa/fb for a join

    def is_epilogue(self, a):
        b = self.t.code[a:a + 3]
        return b in (b"\x61\x07\xc3", b"\x07\x61\xc3", b"\x61\xc3")

    def discover(self, entry):
        work = [entry]
        self.entries.add(entry)
        self.leaders.add(entry)
        while work:
            a = work.pop()
            while True:
                # a hook may start where an adjacent hook stops: the entry itself is lifted, only
                # control flow reaching it from elsewhere ends there
                if (a in self.stops and a != entry) or self.is_epilogue(a):
                    break
                if a in self.body:
                    break
                i = self.t.insn(a)
                if i is None:
                    break
                self.body[a] = i
                m = i.mnemonic
                nxt = a + i.size
                if m in JCC or m in ("loop", "jcxz"):
                    tgt = i.operands[0].imm
                    self.leaders.update((tgt, nxt))
                    work.append(tgt)
                elif m == "jmp":
                    if i.operands[0].type == X.X86_OP_IMM:
                        tgt = i.operands[0].imm
                        self.leaders.add(tgt)
                        work.append(tgt)
                    break
                elif m in ("ret", "retf", "iret"):
                    break
                elif m == "call" and i.operands[0].type == X.X86_OP_IMM:
                    tgt = i.operands[0].imm
                    if tgt not in self.t.routines and tgt not in self.subs and self.rule_like(tgt):
                        self.subs.add(tgt)
                        self.entries.add(tgt)
                        self.leaders.add(tgt)
                        work.append(tgt)
                a = nxt

    def rule_like(self, tgt, limit=400):
        """A near routine is lifted as a gosub if its body (followed through
        jumps, not calls) has no port I/O, interrupts, string ops, far calls
        or indirect jumps."""
        seen, work = set(), [tgt]
        while work:
            a = work.pop()
            while a not in seen:
                if len(seen) > limit:
                    return False
                i = self.t.insn(a)
                if i is None:
                    return False
                seen.add(a)
                m = i.mnemonic
                if m == "lcall" and len(i.operands) == 2 and i.operands[0].imm == self.t.cs and i.operands[1].imm in self.t.routines:
                    a += i.size
                    continue
                if m in ("in", "out", "int", "lcall", "ljmp", "iret", "retf") or m.startswith(("rep", "movs", "stos", "lods", "outs", "ins")) \
                        or "rep" in i.op_str:
                    return False
                if m in ("jmp", "call") and i.operands[0].type != X.X86_OP_IMM:
                    return False
                if m in JCC or m in ("loop", "jcxz"):
                    work.append(i.operands[0].imm)
                if m == "jmp":
                    work.append(i.operands[0].imm)
                    break
                if m in ("ret",):
                    break
                a += i.size
        return True

    def block_insns(self, start):
        out, a = [], start
        while a in self.body:
            i = self.body[a]
            out.append(i)
            a += i.size
            m = i.mnemonic
            if m in JCC or m in ("jmp", "ret", "retf", "iret", "loop", "jcxz"):
                break
            if a in self.leaders:
                break
        return out, a

    def label(self, a):
        return f"L{a:04x}"

    def note_stops(self, end, then_ip, else_ip):
        """Which hook stop a branch returns at (additive `stops_at`: the runtime follows `continues`)."""
        at = {k: h(a) for k, a in (("then", then_ip), ("else", else_ip)) if a in self.stops}
        if at:
            end["stops_at"] = at

    def target(self, a):
        return "@return" if (a in self.stops or self.is_epilogue(a)) else self.label(a)

    def es_flow(self):
        """ES at block entry: forward dataflow over 'mov es,[playfield seg var]',
        'push es'/'pop es'.  Unknown ('?') at routine entries and merges of
        different values."""
        t = self.t
        starts = [s for s in sorted(self.leaders) if s in self.body]
        succ = {}
        out_fn = {}
        for s0 in starts:
            insns, fall = self.block_insns(s0)
            ops = []
            for i in insns:
                if i.mnemonic == "mov" and i.op_str.startswith("es, word ptr ["):
                    d = i.operands[1].mem.disp & 0xFFFF
                    ops.append(("set", "pf_top" if d == t.seg_top else "pf_bottom" if d == t.seg_bottom else "?"))
                elif i.mnemonic == "mov" and i.op_str.startswith("es, "):
                    ops.append(("set", "?"))
                elif i.mnemonic == "push" and i.op_str == "es":
                    ops.append(("push", None))
                elif i.mnemonic == "pop" and i.op_str == "es":
                    ops.append(("pop", None))
            last = insns[-1]
            ss = []
            if last.mnemonic in JCC or last.mnemonic in ("loop", "jcxz"):
                ss = [last.operands[0].imm, last.address + last.size]
            elif last.mnemonic == "jmp" and last.operands[0].type == X.X86_OP_IMM:
                ss = [last.operands[0].imm]
            elif last.mnemonic not in ("ret", "retf", "iret", "jmp"):
                ss = [fall]
            succ[s0] = [x for x in ss if x in self.body]
            out_fn[s0] = ops
        es_in = {s0: None for s0 in starts}
        for e in self.entries:
            es_in[e] = ("?",)
        changed = True
        while changed:
            changed = False
            for s0 in starts:
                cur = es_in[s0]
                if cur is None:
                    continue
                stack = list(cur)
                for kind, v in out_fn[s0]:
                    if kind == "set":
                        stack[-1] = v
                    elif kind == "push":
                        stack.append(stack[-1])
                    elif kind == "pop":
                        stack = stack[:-1] if len(stack) > 1 else ["?"]
                res = tuple(stack)
                for x in succ[s0]:
                    old = es_in[x]
                    new = res if old is None or old == res else tuple("?" for _ in res) if len(old) == len(res) else ("?",)
                    if new != old:
                        es_in[x] = new
                        changed = True
        self.es_in = {k: (list(v) if v else ["?"]) for k, v in es_in.items()}

    def lift_all(self):
        self.es_flow()
        for s in sorted(self.leaders):
            if s in self.body and s not in self.blocks:
                self.blocks[s] = self.lift_block(s)
        self.resolve_flag_joins()

    FLAG_SETTERS = ("cmp", "test", "add", "sub", "and", "or", "xor", "inc", "dec", "neg", "shl", "shr", "sar", "sal",
                    "adc", "sbb", "rcl", "rcr", "rol", "ror", "mul", "imul", "div", "idiv", "sahf", "popf", "stc", "clc", "cmc")

    def resolve_flag_joins(self):
        """A conditional jump whose flags were set in an earlier block (EP8 kicker cs:1b20: `jne` after a
        join of two compare paths) lifts as ["flags"].  If every block that can supply those flags (walking
        back through blocks that do not touch them) ends with a compare of the same width, those blocks
        copy their operands into fa/fb and the join block starts with flags cmp(fa, fb)."""
        preds = {}
        for a, b in self.blocks.items():
            e = b["end"]
            for k in ("goto", "then", "else"):
                if k in e and e[k] != "@return" and e[k][1:] != "return":
                    preds.setdefault(int(e[k][1:], 16), []).append(a)

        def sets_flags(a):
            insns, _ = self.block_insns(a)
            return any(i.mnemonic in self.FLAG_SETTERS for i in insns[:-1] if not (i.mnemonic in JCC)) or \
                (insns and insns[-1].mnemonic in self.FLAG_SETTERS)

        def final_flags(a):
            """(kind, width) of the last flag setter in block a, or None."""
            insns, _ = self.block_insns(a)
            for i in reversed(insns):
                if i.mnemonic in ("cmp", "sub"):
                    return ("cmp", i.operands[0].size)
                if i.mnemonic in self.FLAG_SETTERS:
                    return None
            return "none"

        todo = [a for a, b in self.blocks.items() if "if" in b["end"] and b["end"]["if"].get("a") == ["flags"]]
        changed = False
        for s in todo:
            insns, _ = self.block_insns(s)
            if any(i.mnemonic in self.FLAG_SETTERS for i in insns[:-1]):
                continue                      # flags set inside the block: not a join problem
            sources, work, seen, ok = set(), list(preds.get(s, [])), set(), True
            while work and ok:
                p = work.pop()
                if p in seen:
                    continue
                seen.add(p)
                ff = final_flags(p)
                if ff == "none":
                    if p in self.entries or not preds.get(p):
                        ok = False
                    work += preds.get(p, [])
                elif ff is None:
                    ok = False
                else:
                    sources.add((p, ff[1]))
            if not ok or not sources or len({w for _, w in sources}) != 1:
                continue
            w = next(iter(sources))[1]
            for p, _ in sources:
                self.capture_end.add(p)
                del self.blocks[p]
            self.flags_in[s] = ("cmp", ["reg", "fa"], ["reg", "fb"], w)
            del self.blocks[s]
            changed = True
        if changed:
            for a in sorted(self.leaders):
                if a in self.body and a not in self.blocks:
                    self.blocks[a] = self.lift_block(a)
        self.dce()

    # -- block lifting ---------------------------------------------------------
    def lift_block(self, start):
        t = self.t
        insns, fall = self.block_insns(start)
        regs = {}
        ops = []
        es = list(self.es_in.get(start, ["?"]))
        F = [self.flags_in.get(start)]  # flags: (kind, a, b, width); live-in flags only at flag joins
        end = None

        def R(r):
            return regs.get(r, ["reg", r])

        def get(r):
            if r in REG8:
                base, hi = REG8[r]
                return simp(["hi" if hi else "lo", R(base)])
            return R(r)

        def put(r, v):
            v = simp(v)
            if r in REG8:
                base, hi = REG8[r]
                regs[base] = simp(["sethi" if hi else "setlo", R(base), v])
            else:
                regs[r] = v

        def capture_flags():
            f = F[0]
            if f is None:
                return
            kind, a, b, w = f
            if a is None:                      # nothing to capture (e.g. the carry state after a gosub)
                return
            if a == ["reg", "fa"] and (b is None or is_const(b) or b == ["reg", "fb"]):
                return
            ops.append({"op": "reg", "r": "fa", "val": a})
            nb = b
            if b is not None and not is_const(b):
                ops.append({"op": "reg", "r": "fb", "val": b})
                nb = ["reg", "fb"]
            F[0] = (kind, ["reg", "fa"], nb, w)

        def materialize(pred=has_mem, alias=None, keep=None):
            """Emit 'reg' ops for registers whose symbolic value satisfies pred.

            Registers whose expressions refer to a materialized register's old
            value are materialized first; flags that depend on it are captured
            into the pseudo registers fa/fb.  alias=(addr, w): only memory reads
            that may overlap this store count for the default predicate."""
            if alias is not None and pred is has_mem:
                pred = lambda e: may_alias(e, *alias)
            M = {r for r, e in regs.items() if e != ["reg", r] and pred(e)}
            if F[0] is not None and (pred(F[0][1]) or pred(F[0][2])):
                capture_flags()
            if not M:
                return
            grown = True
            while grown:
                grown = False
                for r, e in regs.items():
                    if r not in M and e != ["reg", r] and regs_in(e, set()) & M:
                        M.add(r)
                        grown = True
            if F[0] is not None and (regs_in(F[0][1], set()) | regs_in(F[0][2], set())) & M:
                capture_flags()
            pending = {r: regs[r] for r in M}
            if keep is not None:
                # in-flight expressions of the current instruction still refer to
                # the old register values: save those in temporaries first
                used = set()
                for k_ in keep:
                    regs_in(k_, used)
                for r in sorted(used & M):
                    tmp = "t_" + r
                    ops.append({"op": "reg", "r": tmp, "val": ["reg", r]})
                    for idx in range(len(keep)):
                        keep[idx] = walk_expr(keep[idx], lambda x, r=r, tmp=tmp: ["reg", tmp] if x == ["reg", r] else x)
            while pending:
                ready = [r for r in pending if not any(r in regs_in(e, set()) for s2, e in pending.items() if s2 != r)]
                if not ready:  # cycle: save one old value in a temporary
                    r = sorted(pending)[0]
                    tmp = "t_" + r
                    ops.append({"op": "reg", "r": tmp, "val": ["reg", r]})
                    for s2 in pending:
                        if s2 != r:
                            pending[s2] = walk_expr(pending[s2], lambda x: ["reg", tmp] if x == ["reg", r] else x)
                    continue
                r = sorted(ready)[0]
                ops.append({"op": "reg", "r": r, "val": pending.pop(r)})
                regs[r] = ["reg", r]

        def addr_of(mem):
            e = mem.disp & 0xFFFF
            for rr in (mem.base, mem.index):
                if rr:
                    e = simp(["add", R(i.reg_name(rr)), e])
            return e

        def seg_of(mem):
            if mem.segment == X.X86_REG_CS:
                return "cs"
            if mem.segment == X.X86_REG_ES:
                return es[-1]
            if mem.base in (X.X86_REG_BP, X.X86_REG_SP) and mem.segment == 0:
                return "ss"
            return "ds"

        def read(k, w=None):
            op = i.operands[k]
            w = w or op.size
            if op.type == X.X86_OP_IMM:
                return op.imm & (0xFF if w == 1 else 0xFFFF)
            if op.type == X.X86_OP_REG:
                return get(i.reg_name(op.reg))
            sg = seg_of(op.mem)
            a = addr_of(op.mem)
            if sg == "ds":
                return ["mem", w, a]
            if sg == "cs":
                return ["cmem", w, a]
            if sg in ("pf_top", "pf_bottom"):
                return ["pixel", 0 if sg == "pf_top" else 1, a]
            if sg == "?" and start in self.kicker_blocks and a == ["reg", "bx"] and w == 1:
                return ["contact_colour"]
            if sg == "?":
                return ["esmem", w, a]
            raise NotImplementedError(f"read seg {sg}")

        def write(k, v, w=None):
            op = i.operands[k]
            w = w or op.size
            v = simp(v)
            if op.type == X.X86_OP_REG:
                put(i.reg_name(op.reg), v)
                return
            sg = seg_of(op.mem)
            a = addr_of(op.mem)
            keep = [a, v]
            if sg == "ds":
                materialize(alias=(a, w), keep=keep)
            else:
                materialize(lambda e: has_tag(e, "pixel"), keep=keep)
            a, v = keep
            if sg == "ds":
                ops.append({"op": "store", "w": w, "addr": a, "val": v, "ip": h(i.address)})
            elif sg in ("pf_top", "pf_bottom"):
                ops.append({"op": "pixel", "half": 0 if sg == "pf_top" else 1, "offset": a, "val": v, "ip": h(i.address)})
            else:
                raise NotImplementedError(f"write seg {sg}")

        for i in insns:
            m = i.mnemonic
            ops_n = len(i.operands)
            try:
                if m == "mov" and ops_n == 2 and i.operands[0].type == X.X86_OP_REG and i.reg_name(i.operands[0].reg) in ("es", "ds"):
                    src = i.operands[1]
                    sreg = i.reg_name(i.operands[0].reg)
                    tgt = None
                    if src.type == X.X86_OP_MEM:
                        d = src.mem.disp & 0xFFFF
                        tgt = "pf_top" if d == t.seg_top else "pf_bottom" if d == t.seg_bottom else None
                    elif src.type == X.X86_OP_REG and i.reg_name(src.reg) == "ax" and R("ax") == ["reg", "ds_value"]:
                        tgt = "ds"
                    if sreg == "es":
                        es[-1] = tgt or "?"
                    else:
                        raise NotImplementedError("mov ds")
                elif m == "mov" and ops_n == 2 and i.operands[1].type == X.X86_OP_REG and i.reg_name(i.operands[1].reg) == "ds":
                    put(i.reg_name(i.operands[0].reg), ["reg", "ds_value"])
                elif m == "mov":
                    write(0, read(1))
                elif m == "lea":
                    put(i.reg_name(i.operands[0].reg), addr_of(i.operands[1].mem))
                elif m in ("push", "pop") and i.op_str in ("es", "ds"):
                    if m == "push" and i.op_str == "es":
                        es.append(es[-1])
                    elif m == "pop" and i.op_str == "es":
                        if len(es) > 1:
                            es.pop()
                        else:
                            es[-1] = "?"
                    elif m == "push" and i.op_str == "ds":
                        pass
                elif m in ("pushaw", "pusha"):
                    materialize(lambda e: True)
                    ops.append({"op": "push_all"})
                elif m in ("popaw", "popa"):
                    materialize(lambda e: True)
                    ops.append({"op": "pop_all"})
                    regs.clear()
                elif m in ("stc", "clc"):
                    ops.append({"op": "reg", "r": "cf", "val": 1 if m == "stc" else 0})
                elif m in ("cld", "nop", "cli", "sti"):
                    pass
                elif m == "push":
                    ops.append({"op": "push", "val": read(0)})
                elif m == "pop":
                    r = i.reg_name(i.operands[0].reg)
                    materialize(lambda e, r=r: r in regs_in(e, set()))
                    ops.append({"op": "pop", "r": r})
                    regs.pop(r, None)
                elif m in ("add", "sub", "and", "or", "xor", "adc", "sbb"):
                    w = i.operands[0].size
                    a_ = read(0)
                    b_ = read(1)
                    if m == "xor" and i.operands[0].type == X.X86_OP_REG and i.operands[1].type == X.X86_OP_REG and i.operands[0].reg == i.operands[1].reg:
                        write(0, 0)
                        F[0] = ("res", 0, None, w)
                        continue
                    if m == "adc":
                        # merge with the preceding "add [X],a" into a 32-bit add
                        prev = ops[-1] if ops else None
                        op0 = i.operands[0]
                        if (prev and prev["op"] == "store" and prev["w"] == 2 and op0.type == X.X86_OP_MEM and seg_of(op0.mem) == "ds"
                                and is_const(prev["addr"]) and addr_of(op0.mem) == prev["addr"] + 2
                                and isinstance(prev["val"], list) and prev["val"][0] == "add" and prev["val"][1] == ["mem", 2, prev["addr"]]):
                            lo = prev["val"][2]
                            prev["w"] = 4
                            prev["val"] = ["add32", ["mem", 4, prev["addr"]], simp(["join", b_, lo])]
                            F[0] = None
                            continue
                        f = F[0]
                        if f and f[0] == "addres":
                            write(0, ["add", ["add", a_, b_], ["ltu", f[1], f[2], f[3]]])
                            F[0] = ("res", read(0), None, w)
                            continue
                        raise NotImplementedError("adc")
                    if m == "sbb":
                        # "sub r1,a; sbb r2,b": 32-bit subtract in a register pair (borrow = r1_before < a, unsigned)
                        f = F[0]
                        if f and f[0] == "sub":
                            write(0, ["sub", ["sub", a_, b_], ["ltu", f[1], f[2], f[3]]])
                            F[0] = ("res", read(0) if i.operands[0].type == X.X86_OP_MEM else get(i.reg_name(i.operands[0].reg)), None, w)
                            continue
                        raise NotImplementedError("sbb")
                    res = simp([m, a_, b_])
                    write(0, res)
                    if m == "add":
                        # keep the operand for a following adc (carry = result < operand)
                        F[0] = ("addres", read(0) if i.operands[0].type == X.X86_OP_MEM else get(i.reg_name(i.operands[0].reg)), b_, w)
                    elif i.operands[0].type == X.X86_OP_MEM:
                        F[0] = ("res", read(0), None, w)
                    else:
                        F[0] = ("sub", a_, b_, w) if m == "sub" else ("res", get(i.reg_name(i.operands[0].reg)), None, w)
                elif m in ("inc", "dec", "neg", "not"):
                    w = i.operands[0].size
                    a_ = read(0)
                    res = {"inc": ["add", a_, 1], "dec": ["sub", a_, 1], "neg": ["neg", a_], "not": ["xor", a_, 0xFF if w == 1 else 0xFFFF]}[m]
                    write(0, res)
                    F[0] = ("res", read(0), None, w)
                elif m == "cmp":
                    F[0] = ("cmp", read(0), read(1), i.operands[0].size)
                elif m == "test":
                    F[0] = ("test", read(0), read(1), i.operands[0].size)
                elif m in ("shl", "shr", "sar", "sal"):
                    n = read(1) if ops_n > 1 else 1
                    w = i.operands[0].size
                    src = read(0)
                    if is_const(n):
                        carry = simp(["and", ["shr", src, n - 1], 1]) if m in ("shr", "sar") else \
                            simp(["and", ["shr", ["and", src, 0xFF if w == 1 else 0xFFFF], 8 * w - n], 1])
                    else:
                        carry = ["unknown", h(i.address)]
                    write(0, [{"sal": "shl"}.get(m, m), src, n])
                    F[0] = ("shiftc", read(0), carry, w)
                elif m == "rcl" and F[0] and F[0][0] == "shiftc" and ops_n > 1 and is_const(read(1)) and read(1) == 1 \
                        and not (isinstance(F[0][2], list) and F[0][2][0] == "unknown"):
                    # "shl lo,1; rcl hi,1": 32-bit shift left, the carry is the bit shifted out of lo (EP4, EP7)
                    w = i.operands[0].size
                    src = read(0)
                    carry = F[0][2]
                    write(0, ["or", ["shl", src, 1], carry])
                    F[0] = ("shiftc", read(0), simp(["and", ["shr", ["and", src, 0xFF if w == 1 else 0xFFFF], 8 * w - 1], 1]), w)
                elif m == "mul":
                    w = i.operands[0].size
                    src = read(0)
                    if w == 2:
                        p = ["mul32", R("ax"), src]
                        put("ax", ["lo16", p])
                        put("dx", ["hi16", p])
                    else:
                        put("ax", ["mul", get("al"), src])
                elif m == "div":
                    w = i.operands[0].size
                    src = read(0)
                    if w == 2:
                        n = simp(["join", R("dx"), R("ax")])
                        put("ax", ["div32", n, src])
                        put("dx", ["mod32", n, src])
                    else:
                        put("ax", ["setlo", ["sethi", 0, ["mod", R("ax"), src]], ["div", R("ax"), src]])
                elif m == "xchg":
                    a_, b_ = read(0), read(1)
                    write(0, b_)
                    write(1, a_)
                elif m == "cbw":
                    put("ax", ["sext8", get("al")])
                elif m in JCC:
                    end = {"if": self.cond(F[0], m), "then": self.target(i.operands[0].imm), "else": self.target(i.address + i.size)}
                    self.note_stops(end, i.operands[0].imm, i.address + i.size)
                elif m == "loop":
                    put("cx", ["sub", R("cx"), 1])
                    materialize(lambda e: True)
                    end = {"if": {"cmp": "ne", "a": ["reg", "cx"], "b": 0, "w": 2}, "then": self.target(i.operands[0].imm),
                           "else": self.target(i.address + i.size)}
                    self.note_stops(end, i.operands[0].imm, i.address + i.size)
                elif m == "jmp":
                    if i.operands[0].type != X.X86_OP_IMM:
                        raise NotImplementedError("indirect jmp")
                    tgt = i.operands[0].imm
                    end = {"return": True} if (tgt in self.stops or self.is_epilogue(tgt)) else {"goto": self.label(tgt)}
                    if tgt in self.stops:
                        end["stop"] = h(tgt)
                elif m in ("ret", "retf"):
                    end = {"return": True, "regs_live": True}
                elif m == "call" and i.operands[0].type == X.X86_OP_IMM and i.operands[0].imm in self.subs:
                    materialize(lambda e: True)
                    capture_flags()
                    ops.append({"op": "gosub", "entry": self.label(i.operands[0].imm)})
                    regs.clear()
                    F[0] = ("cf", None, None, 1)
                elif m in ("call", "lcall"):
                    self.lift_call(i, R, get, regs, ops, materialize)
                else:
                    raise NotImplementedError(m)
            except NotImplementedError as ex:
                self.unsupported[f"{m} ({ex})"] += 1
                materialize(lambda e: True)
                ops.append({"op": "asm", "ip": h(i.address), "text": f"{m} {i.op_str}"})
                for op in i.operands:
                    if op.type == X.X86_OP_REG and op.access & 2:
                        r = i.reg_name(op.reg)
                        regs[REG8[r][0] if r in REG8 else r] = ["unknown", h(i.address)]
        if end is None:
            end = {"return": True} if (fall in self.stops or self.is_epilogue(fall)) else {"goto": self.label(fall)}
            if fall in self.stops:
                end["stop"] = h(fall)
        if start in self.capture_end and F[0] is not None and F[0][0] in ("cmp", "sub"):
            # a later block reads these flags after a join (see resolve_flag_joins): keep both operands in
            # fa/fb (fb too when it is a constant: every path into the join must define it)
            kind_, fa_, fb_, w_ = F[0]
            if fa_ != ["reg", "fa"]:
                ops.append({"op": "reg", "r": "fa", "val": fa_})
            if fb_ != ["reg", "fb"]:
                ops.append({"op": "reg", "r": "fb", "val": fb_ if fb_ is not None else 0})
            if "if" in end:
                c = end["if"]
                c["a"] = walk_expr(c["a"], lambda x: ["reg", "fa"] if x == fa_ else x) if fa_ is not None else c["a"]
            F[0] = (kind_, ["reg", "fa"], ["reg", "fb"], w_)
        if "if" in end:
            # the condition was built from pre-block register names: capture it
            # if a register it uses is about to be reassigned
            mod = {r for r, e in regs.items() if e != ["reg", r]}
            c = end["if"]
            if (regs_in(c["a"], set()) | regs_in(c["b"], set())) & mod:
                F[0] = ("cmp", c["a"], c["b"], c["w"])
                capture_flags()
                c["a"], c["b"] = F[0][1], F[0][2] if F[0][2] is not None else c["b"]
            F[0] = None
        materialize(lambda e: True)  # every modified register
        return {"ip": h(start), "ops": ops, "end": end}

    @staticmethod
    def cond(flags, m):
        c = JCC[m]
        if flags is None:
            return {"cmp": c, "a": ["flags"], "b": 0, "w": 2}
        kind, a, b, w = flags
        if kind == "shiftc":
            if c in ("ult", "uge"):
                return {"cmp": "ne" if c == "ult" else "eq", "a": b, "b": 0, "w": 1}
            kind, b = "res", None
        if kind == "addres":
            if c in ("ult", "uge"):
                return {"cmp": "ne" if c == "ult" else "eq", "a": ["ltu", a, b, w], "b": 0, "w": 1}
            kind = "res"
        if kind == "res" and c in ("ult", "uge", "ule", "ugt"):
            return {"cmp": c, "a": ["flags"], "b": 0, "w": 2}
        if kind == "cf":
            if c in ("ult", "uge"):
                return {"cmp": "ne" if c == "ult" else "eq", "a": ["reg", "cf"], "b": 0, "w": 1}
            return {"cmp": c, "a": ["flags"], "b": 0, "w": 2}
        if kind == "cmp" or kind == "sub":
            if c in ("neg", "nonneg"):
                return {"cmp": "slt" if c == "neg" else "sge", "a": simp(["sub", a, b]), "b": 0, "w": w}
            return {"cmp": c, "a": a, "b": b, "w": w}
        if kind == "test":
            v = a if a == b else simp(["and", a, b])
            if c in ("eq", "ne"):
                return {"cmp": c, "a": v, "b": 0, "w": w}
            return {"cmp": {"neg": "slt", "nonneg": "sge"}.get(c, c), "a": v, "b": 0, "w": w}
        # result of an arithmetic op compared with zero
        cc = {"neg": "slt", "nonneg": "sge"}.get(c, c)
        return {"cmp": cc, "a": a, "b": 0, "w": w}

    def lift_call(self, i, R, get, regs, ops, materialize):
        t = self.t
        if i.mnemonic == "call":
            if i.operands[0].type != X.X86_OP_IMM:
                raise NotImplementedError("indirect call")
            tgt = i.operands[0].imm
        else:
            if len(i.operands) != 2 or i.operands[0].imm != t.cs:
                raise NotImplementedError("far call outside cs")
            tgt = i.operands[1].imm
        role = t.routines.get(tgt)
        if role is None and t.far_ds_display(tgt):
            role = t.routines[tgt] = f"display:routine_{tgt:04x}"
        materialize()
        if role in ("message", "text", "number_text", "score_refresh") or (role or "").startswith("display:"):
            kind = {"number_text": "number"}.get(role, role if not role.startswith("display:") else "display")
            self.stub_routines[h(tgt)] = [kind, i.mnemonic == "lcall"]
        if role == "message":
            ops.append({"op": "message", "msg": R("bx"), "pos": R("di"), "mode": R("ax"), "ip": h(i.address)})
        elif role == "text":
            ops.append({"op": "text", "msg": R("bx"), "pos": R("di"), "routine": h(tgt), "ip": h(i.address)})
        elif role == "number_text":
            ops.append({"op": "number_text", "value": simp(["join", R("dx"), R("ax")]), "buf": R("bx"), "ip": h(i.address)})
        elif role == "score_refresh":
            ops.append({"op": "score_refresh"})
        elif role == "sound_play":
            ops.append({"op": "sound_play", "id": R("ax"), "ip": h(i.address)})
        elif role and role.startswith("gate:"):
            ops.append({"op": "gate", "gate": role[5:], "ip": h(i.address)})
        elif role and role.startswith("hook:"):
            ops.append({"op": "call_hook", "hook": role[5:]})
        elif role and role.startswith("display:"):
            ops.append({"op": "display", "what": role[8:]})
        else:
            name = t.img.syms.code.get(tgt, {}).get("name") if t.n == 1 else None
            ops.append({"op": "call", "target": h(tgt), "name": name or role, "ip": h(i.address)})
            self.unsupported[f"call {h(tgt)} {name or role or ''}".strip()] += 1
        kept = self.preserved(tgt)
        for r in ("ax", "bx", "cx", "dx", "si", "di"):
            if r not in kept:
                regs[r] = ["unknown", h(i.address)]

    def preserved(self, tgt):
        """Registers a routine saves in its prologue (push r16 / pusha)."""
        kept = set()
        a = tgt
        for _ in range(8):
            i = self.t.insn(a)
            if i is None:
                break
            if i.mnemonic in ("pushaw", "pusha"):
                return set(REG16)
            if i.mnemonic == "push" and i.op_str in REG16:
                kept.add(i.op_str)
            elif not (i.mnemonic == "push" and i.op_str in ("es", "ds")):
                break
            a += i.size
        return kept

    # -- dead register assignment elimination -----------------------------------
    def dce(self):
        """Remove register assignments nobody reads.  A gosub/call_hook reads what its callee reads
        before writing it (callee_reads: liveness with nothing live at the callee's returns), so an
        assignment made for a subroutine (EP3 cs:264c `mov si,0Fh; call 2D1Ch`) is kept."""
        succ = {}
        for a, b in self.blocks.items():
            e = b["end"]
            s = []
            for k in ("goto", "then", "else"):
                if k in e and e[k] != "@return":
                    s.append(int(e[k][1:], 16))
            succ[a] = [x for x in s if x in self.blocks]
        ALL = set(REG16) | {"cf", "fa", "fb"}

        def callee(op):
            lab = op.get("entry") if op["op"] == "gosub" else None
            if op["op"] == "call_hook":
                ent = next((e for e, r in self.t.routines.items() if r == f"hook:{op['hook']}"), None)
                lab = self.label(ent) if ent is not None else None
            if lab and lab.startswith("L"):
                a = int(lab[1:], 16)
                return a if a in self.blocks else None
            return None

        def fixpoint(ret_live, reads):
            live_in = {a: set() for a in self.blocks}
            changed = True
            while changed:
                changed = False
                for a in sorted(self.blocks, reverse=True):
                    b = self.blocks[a]
                    live = set(ret_live) if b["end"].get("regs_live") else set()
                    for s_ in succ[a]:
                        live |= live_in[s_]
                    live |= regs_in(b["end"].get("if", {}), set())
                    for op in reversed(b["ops"]):
                        if op["op"] in ("reg", "pop"):
                            live.discard(op["r"])
                        live |= regs_in({k: v for k, v in op.items() if k not in ("op", "r", "ip")}, set())
                        c = callee(op)
                        if c is not None:
                            live |= (reads if reads is not None else live_in).get(c, set())
                    if live != live_in[a]:
                        live_in[a] = live
                        changed = True
            return live_in

        reads = fixpoint(set(), None)          # registers each block reads before writing, returns contribute none
        live_in = fixpoint(ALL, reads)
        for a, b in self.blocks.items():
            live = set(ALL) if b["end"].get("regs_live") else set()
            for s_ in succ[a]:
                live |= live_in[s_]
            live |= regs_in(b["end"].get("if", {}), set())
            keep = []
            for op in reversed(b["ops"]):
                if op["op"] == "reg":
                    if op["r"] not in live:
                        continue
                    live.discard(op["r"])
                if op["op"] == "pop":
                    live.discard(op["r"])
                live |= regs_in({k: v for k, v in op.items() if k not in ("op", "r", "ip")}, set())
                c = callee(op)
                if c is not None:
                    live |= reads.get(c, set())
                keep.append(op)
            b["ops"] = keep[::-1]


# ---------------------------------------------------------------------------
# semantic pass


class Semantics:
    def __init__(self, t: Table):
        self.t = t
        self.vars = {}     # addr -> {"name", "w"}
        self.messages = {}  # ds offset -> info
        self.msg_tables = {}
        self.bx_consts = set()
        self.dwords = set()

    def var_name(self, a, w):
        t = self.t
        if (a - 2) in self.dwords and w <= 2:
            return self.var_name(a - 2, 4) + ".hi"
        if a in self.dwords:
            w = 4
        v = self.vars.setdefault(a, {"w": w})
        v["w"] = max(v["w"], w)
        role = t.roles.get(a)
        if role:
            return role[0]
        if t.n == 1 and a in EP1_VARS:
            return EP1_VARS[a][0]
        if t.n == 1:
            s = t.img.syms.data.get(a)
            if s:
                return s["name"]
        return f"v{a:04x}"

    def expr(self, e):
        t = self.t

        def fn(x):
            if x[0] == "mem" and is_const(x[2]):
                a, w = x[2], x[1]
                r = t.role_of(a)
                if r and r[0] == "lamp" and w == 1:
                    return ["lamp", r[1]]
                if r and r[0].startswith("ball.") and r[0] not in ("ball.writeback", "ball.layer"):
                    return ["ball", r[0][5:]]
                bs = t.ball_slot(a)
                if bs:
                    return ["ball_slot", bs[1], bs[0]]
                return ["var", self.var_name(a, w), w]
            if x[0] == "add32":
                return ["add", x[1], x[2]]
            if x[0] == "cmem" and is_const(x[2]) and x[2] in t.cs_inputs:
                return ["input", t.cs_inputs[x[2]]]
            return x
        return walk_expr(e, fn)

    def op(self, o):
        t = self.t
        k = o["op"]
        if k == "store" and is_const(o["addr"]):
            a, w, v = o["addr"], o["w"], o["val"]
            r = t.role_of(a)
            if r:
                role = r[0]
                if role == "score" and w == 4 and isinstance(v, list) and v[0] == "add32" and v[1] == ["mem", 4, a]:
                    return {"op": "score", "add": self.expr(v[2])}
                if role == "lamp" and w == 1:
                    return {"op": "lamp", "slot": r[1], "state": self.expr(v)}
                if role == "lamp" and w == 2:
                    return {"op": "lamps", "slot": r[1], "count": 2, "states16": self.expr(v)}
                if role.startswith("ball.") and role not in ("ball.writeback", "ball.layer"):
                    return {"op": "ball", "set": {role[5:]: signed(self.expr(v))}}
                if role == "ball.writeback":
                    return {"op": "ball_commit", "val": self.expr(v)}
                if role == "ball.layer":
                    return {"op": "layer", "val": self.expr(v)}
                if role == "sound.queue":
                    return {"op": "sound", "id": self.expr(v)}
                if role == "sound.rate":
                    return {"op": "sound_rate", "hz": self.expr(v)}
                if role == "sound.now":
                    return {"op": "sound_now", "id": self.expr(v)}
                if role.startswith("sound.sweep@"):
                    rest = role[12:]
                    sw, _, param = rest.partition(".")
                    return {"op": "sound_sweep", "sweep": sw, "param": param or "active", "val": self.expr(v)}
                if role == "sensor_lockout":
                    return {"op": "lockout", "frames": self.expr(v)}
                if role == "sensor_cooldown":
                    return {"op": "cooldown", "frames": self.expr(v)}
                if role == "extra_gravity":
                    return {"op": "extra_gravity", "frames": self.expr(v)}
            bs = t.ball_slot(a)
            if bs:
                return {"op": "ball_slot", "slot": bs[1], "set": {bs[0]: signed(self.expr(v))}}
            return {"op": "set", "var": self.var_name(a, w), "w": w, "val": self.expr(v)}
        if k == "store":
            a = o["addr"]
            # indexed lamp store: [reg + first..]
            if isinstance(a, list) and a[0] == "add" and is_const(a[2]) and o["w"] == 1:
                r = t.role_of(a[2])
                if r and r[0] == "lamp":
                    return {"op": "lamp", "slot": self.expr(simp(["add", a[1], r[1]])), "state": self.expr(o["val"])}
                if t.lamp_table and a[2] == t.lamp_table["phase"]:
                    return {"op": "lamp", "slot": self.expr(simp(["sub", a[1], 1])), "state": self.expr(o["val"])}
            if isinstance(a, list) and a[0] == "add" and is_const(a[2]):
                self.var_name(a[2], o["w"])
            return {"op": "store", "w": o["w"], "addr": self.expr(a), "val": self.expr(o["val"])}
        if k == "pixel":
            off = o["offset"]
            d = {"op": "pixels", "val": self.expr(o["val"])}
            if is_const(off) and off < 64000:
                y = off // 320 + 200 * o["half"]
                d["xy"] = [[off % 320, y]]
            elif is_const(off):
                d["outside_playfield"] = {"half": o["half"], "offset": off,
                                          "note": "offset >= 64000 inside the playfield segment: the write lands in the next segment (game bug)"}
            else:
                d["half"] = o["half"]
                d["offset"] = self.expr(off)
            return d
        if k in ("message", "text"):
            msg = o["msg"]
            self.note_msg(msg)
            d = {"op": k, "msg": self.expr(msg), "pos": self.expr(o["pos"])}
            if k == "message":
                d["mode"] = self.expr(o["mode"])
            if is_const(o["pos"]):
                d["pos"] = {"x": o["pos"] % 320, "y": o["pos"] // 320, "raw": o["pos"]}
            if k == "text":
                d["routine"] = o["routine"]
            return d
        if k in ("reg", "push", "number_text", "sound_play", "call", "gate", "asm", "pop", "score_refresh"):
            return {kk: (self.expr(vv) if kk in ("val", "value", "buf", "id") else vv) for kk, vv in o.items() if kk != "ip" or k in ("asm", "call")}
        return o

    def note_msg(self, msg):
        t = self.t
        if is_const(msg):
            self.add_msg(msg)
        elif msg == ["reg", "bx"]:
            for p in self.bx_consts:
                self.add_msg(p)
        elif isinstance(msg, list) and msg[0] == "mem" and msg[1] == 2 and isinstance(msg[2], list) and msg[2][0] == "add" and is_const(msg[2][2]):
            base = msg[2][2]
            if base in self.msg_tables:
                return
            ptrs = []
            a = base
            # message pointer table: words pointing at NUL-terminated strings inside DS
            while a + 2 <= len(t.dsmem) and len(ptrs) < 32:
                p = t.ds_word(a)
                if not (0x20 <= p < len(t.dsmem)) or not self.looks_like_string(p):
                    break
                ptrs.append(p)
                a += 2
            self.msg_tables[base] = ptrs
            for p in ptrs:
                self.add_msg(p)

    def looks_like_string(self, p):
        s = self.t.dsmem[p:p + 48]
        n = s.find(b"\x00")
        return n > 0 and all(0x20 <= c < 0x7F for c in s[:n])

    def add_msg(self, p):
        t = self.t
        s = t.dsmem[p:p + 64]
        n = s.find(b"\x00")
        self.messages[p] = {"ds": h(p), "file_offset": h(t.ds_file + p), "length": n if n >= 0 else None,
                            "printable": bool(n > 0 and all(0x20 <= c < 0x7F for c in s[:n]))}


def has_field_ref(e, fields):
    if not isinstance(e, list):
        return False
    if e and e[0] == "ball" and e[1] in fields:
        return True
    return any(has_field_ref(x, fields) for x in e[1:])


def merge_ops(ops):
    """Fold runs of ball/ball_slot/pixel/sweep ops into single ops."""
    out = []
    for o in ops:
        p = out[-1] if out else None
        if p and o["op"] == "ball" and p["op"] == "ball" and not (set(o["set"]) & set(p["set"])) \
                and not any(has_field_ref(v, p["set"]) for v in o["set"].values()):
            p["set"].update(o["set"])
            continue
        if p and o["op"] == "ball_slot" and p["op"] == "ball_slot" and p["slot"] == o["slot"] and not (set(o["set"]) & set(p["set"])) \
                and not any(has_tag(v, "ball_slot") for v in o["set"].values()):
            p["set"].update(o["set"])
            continue
        if p and o["op"] == "pixels" and p["op"] == "pixels" and "xy" in o and "xy" in p and o["val"] == p["val"]:
            p["xy"] += o["xy"]
            continue
        out.append(o)
    # sound sweeps: collect params of one sweep start into a single op
    res = []
    for o in out:
        if o["op"] == "sound_sweep":
            sw = o["sweep"]
            prev = next((r for r in reversed(res[-6:]) if r["op"] == "sound_sweep_start" and r["sweep"] == sw and o["param"] not in r), None)
            if prev is None:
                prev = {"op": "sound_sweep_start", "sweep": sw}
                res.append(prev)
            prev[o["param"]] = o["val"]
            continue
        res.append(o)
    return res


# ---------------------------------------------------------------------------
# EP1 annotations (names and meanings from reverse engineering; no game data)

# lamp slot -> meaning (from which rule code writes the slot; medium confidence unless noted)
EP1_LAMPS = {
    0: "left pop bumper flash", 1: "right pop bumper flash", 2: "top lane 1", 3: "top lane 2", 4: "top lane 3", 5: "top lane 4",
    7: "left lane / kicker lit", 8: "jackpot (mode 1)", 10: "physical systems armed", 11: "android activated (a)",
    12: "android activated (b)", 13: "test step 1", 14: "test step 2", 15: "test step 3", 16: "test step 4", 17: "test step 5",
    18: "computer link", 19: "virus (off)", 20: "virus (on)", 21: "level BASIC IO", 22: "level AI", 23: "level AI2",
    24: "level DATABASE", 25: "level ACTIVATE", 26: "drop target 1 (a)", 27: "drop target 2 (a)", 28: "drop target 3 (a)",
    29: "drop target 1 (b)", 30: "drop target 2 (b)", 31: "drop target 3 (b)",
    32: "power 1", 33: "power 2", 34: "power 3", 35: "power 4", 36: "power 5", 37: "power 6", 38: "power 7", 39: "power 8",
    40: "power 9", 41: "power 10 / physical level 1 (shared slot)", 42: "physical level 2", 43: "physical level 3",
    44: "physical level 4", 45: "physical level 5", 46: "physical level 6", 47: "physical level 7",
    48: "super jackpot", 50: "left slingshot flash", 51: "right slingshot flash", 52: "test hole", 53: "centre eject",
    54: "right sink (entry)", 55: "right sink / right hole eject", 57: "diverter (a)", 58: "left hole", 59: "left kickback flash",
    60: "diverter (b)", 61: "kickback gate open",
}

# ds addr -> (name, description, confidence)
EP1_VARS = {
    0x0012: ("sfx_pending", "queued sound id (played at 11000 Hz next frame)", "high"),
    0x0adc: ("sfx_rate_hz", "sample rate for the next sound", "high"),
    0x0adf: ("sfx_now", "sound id played next frame at the current sfx_rate_hz", "high"),
    0x0ade: ("sfx_sweep_up", "rising pitch effect: every 8 frames rate += 2000 Hz up to 24000, plays sfx_sweep_up_step", "high"),
    0x0ae1: ("sfx_sweep_up_step", "sound id played on every step of the rising effect", "high"),
    0x0ae3: ("sfx_sweep_up_end", "sound id played when the rising effect ends (0 = none)", "high"),
    0x0ae5: ("sfx_sweep_small", "slow rising effect (+500 Hz every 32 frames, sound 0x12)", "high"),
    0x0ae6: ("sfx_sweep_down", "falling pitch effect: every 16 frames rate -= 1000 Hz down to 3000", "high"),
    0x0ae7: ("sfx_sweep_down_step", "sound id per step of the falling effect", "high"),
    0x0ae9: ("sfx_sweep_down_end", "sound id at the end of the falling effect", "high"),
    0x0ad0: ("power_level", "power-up count 0..10 (right sink hole awards); lamps 32..41", "high"),
    0x0ad2: ("fade_flag_a", "palette fade control (end of game)", "low"),
    0x0ad3: ("fade_flag_b", "palette fade control (end of game)", "low"),
    0x0ad4: ("test_hole_timer", "F5 test hole: hold/eject countdown, 70 frames", "high"),
    0x0ad5: ("center_hole_timer", "shared hold/eject countdown of the centre hole (F6 x<220) and left hole (F8 left)", "high"),
    0x0ad6: ("right_sink_timer", "F6/F7 right sink hole hold/eject countdown, 80 frames", "high"),
    0x0ad7: ("right_hole_timer", "F8 right hole (x>=145) hold/eject countdown, 50 frames", "high"),
    0x0ad8: ("right_sink_count", "times the right sink (F7 path) was entered", "medium"),
    0x0ad9: ("right_hole_count", "times the F8 right hole was entered", "medium"),
    0x0ada: ("center_hole_count", "times the centre hole was entered", "medium"),
    0x0adb: ("test_hole_count", "times the test hole was entered", "medium"),
    0x0b2a: ("skill_lane_rng", "0..3 counter incremented every frame; picks the next skill-shot lane", "high"),
    0x0b2b: ("skill_lane", "top lane (0..3) that awards the skill shot; 0xFFFF once used", "high"),
    0x0b2d: ("score_at_ball_start", "score (dword) at the start of the ball; unchanged at drain => 'try again' ball", "high"),
    0x0b31: ("flip_lane_latch", "flipper-held latch so one press rotates the top lanes once", "high"),
    0x03a1: ("millions_count", "per-ball count used by the 'MIL' award (left hole), 1..9", "medium"),
    0x03a3: ("bonus_tests", "per-ball bonus counter: test hole entries", "medium"),
    0x03a5: ("bonus_power_ups", "per-ball bonus counter: centre hole entries", "medium"),
    0x03a7: ("bonus_phys_holes", "per-ball bonus counter: right hole entries", "medium"),
    0x03a9: ("bonus_ramps", "per-ball bonus counter: ramp/orbit shots", "medium"),
    0x03ab: ("bonus_left_lanes", "per-ball bonus counter: left lane (FB) shots", "medium"),
    0x06d6: ("gate_timer", "frames until the left kickback gate closes again (120)", "high"),
    0x0645: ("msg_digit_mult", "digit patched into a message string (bonus multiplier)", "high"),
    0x0644: ("left_lane_msg_toggle", "alternates the message shown by the right sink award", "high"),
    0x04a8: ("msg_digit_millions", "digit patched into the millions message", "high"),
    0x5886: ("mode_seconds", "timed mode countdown in seconds (0 = no mode)", "high"),
    0x5888: ("mode_frame", "frames within the current second (counts to 60)", "high"),
    0x588e: ("mode", "timed mode: 0 none, 1 jackpot (multiball), 2 double jackpot, 3 super jackpot, 4 virus", "high"),
    0x5885: ("extra_ball_flag", "1 = shoot again; never set to 1 in EP1", "high"),
    0x5ab1: ("iq", "I.Q. value: 99 when the computer link is made, +1 per bumper hit, x10000 on I.Q. upgrade", "high"),
    0x5ab3: ("req_basic_io", "objective bits for level 1: F9 left=1, F9 right=2, F7/F9 middle=4 (goal 7)", "high"),
    0x5ab4: ("req_ai", "objective bits for level 2: ramps 1,2,4 + drop target bank 8 (goal 0x0F)", "high"),
    0x5ab5: ("req_ai2", "objective bits for level 3 (goal 0x1F): ramps 1,2,4, test hole 8, left lane FB 0x10", "high"),
    0x5ab6: ("req_database", "objective bits for level 4 (goal 0x0F): right hole 1, right sink 2, centre hole 4, test hole 8", "high"),
    0x5ab7: ("req_activate", "objective bit for level 5 (goal 1): drop target bank", "high"),
    0x5ab8: ("skill_value", "skill shot value (dword), +1,000,000 each time it is collected", "high"),
    0x5ac2: ("target_bank_count", "drop target bank completions (pitch of the award sound)", "high"),
    0x5ac4: ("bonus_mult", "bonus multiplier 1..5", "high"),
    0x5ac6: ("phys_level", "physical-systems test level 0..7 (arms, legs, head, torso)", "high"),
    0x5acc: ("android_level", "main progression 0..6: 0 link, 1 basic io, 2 AI, 3 AI2, 4 database, 5 activate, 6 activated", "high"),
    0x5acd: ("phys_armed", "1 = right hole lit to advance the physical-systems level", "high"),
    0x5acf: ("bumper_value", "score per pop bumper hit (dword), +30000 by the right sink 'kicker active' award", "high"),
    0x5ad3: ("test_step", "test hole award step 0,4,8,12,16 (index into the per-level dword table at ds:0821)", "high"),
    0x5ad5: ("kicker_lit", "set by the left lane (FB); next right sink award raises the bumper value", "high"),
    0x5ad6: ("phys_complete", "1 = all physical tests done", "high"),
    0x5ad7: ("top_lanes", "4 bytes, one per top rollover lane: 2 = not made, 1 = made; mirrored into lamps 2..5", "high"),
    0x5adb: ("iq_shown", "last I.Q. value printed", "high"),
    0x5add: ("diverter_state", "0/1 upper-level diverter near (41,204); toggled by the F8 middle sensor", "medium"),
    0x5ade: ("kickback_gate_open", "gate0 control: 0 = closed (EB wall pixels), 1 = open", "high"),
    0x5adf: ("sink_count_for_gate", "right sink entries; at 3 the kickback gate opens", "high"),
    0x5abc: ("drop_targets", "3 bytes: 1 = target F2/F3/F4 down", "high"),
    0x6762: ("lamp_flash_slot", "lamp slot to reset to state 1 when lamp_flash_frames reaches 0", "high"),
    0x6763: ("lamp_flash_frames", "countdown for lamp_flash_slot", "high"),
    0x5875: ("num_buf", "10-byte text buffer for number_text", "high"),
    0x6c6c: ("game_running", "0 in attract, incremented when a game starts; gates the mode timer (engine.md calls this word the ring table's slot 0)", "high"),
    0x588a: ("bonus_total", "end-of-ball bonus (dword): tests x400,000 + power ups x100,000 + holes x200,000 + ramps x60,000 + left lanes x300,000 (values from bonus_count code)", "high"),
    0x0b2f: ("score_at_ball_start.hi", "high word of score_at_ball_start", "high"),
    0x5890: ("tilt_reset_word", "cleared when a tilted ball ends", "low"),
    0x6760: ("current_player", "0-based? current player index used for the player-block copy", "medium"),
    0x589b: ("dmd_timer", "frames until the message strip reverts to idle text", "medium"),
    0x0ac6: ("mode_seconds_text", "2 digits + NUL", "high"),
}

# cs addr -> (name, description, confidence, tags)
EP1_HANDLERS = {
    0x1f31: ("top_lanes", "FA: 4 top rollover lanes; lane index from ball x (<180, <210, <243, else). If the lane is skill_lane: "
             "skill_value += 1,000,000 and the new skill_value is scored (first skill shot 2,000,000). skill_lane is then "
             "cleared. A lane already made only sets lockout. A new lane scores 50,000; when all 4 are made they reset, the "
             "bonus multiplier goes up (max 5, digit patched into the message) and 2,000,000 is added. Lamps 2..5 mirror "
             "top_lanes (state 1 = sprite a = lit)", "high", ["rollover", "skill_shot", "bonus_multiplier"]),
    0x206f: ("ramp_enter", "F0: ball moves to the upper level (wire ramps); extra gravity 13 for 13 frames", "high", ["layer_enter"]),
    0x2082: ("ramp_exit", "F1: only on the upper level: back to level 0, extra gravity off; if ball y >= 200 the ball is also "
             "stopped (vx = vy = 0) where the ramp drops it onto an inlane", "high", ["layer_exit"]),
    0x20bd: ("drop_targets", "F2/F3/F4: 3 targets at x=49 (index = colour - F2). New target: lamps 26+i and 29+i state 2, 10,000. "
             "Bank complete: targets and lamps reset (29.. state 1, 26.. blink), 1,000,000, objective bits AI|8 and ACTIVATE|1, "
             "falling-pitch sound whose rate grows with target_bank_count; if phys_armed: phys_level + 1 (max 7), test steps "
             "reset, lamp 40+level blinks, 'shoot right hole' message", "high", ["target_bank", "progression"]),
    0x21bd: ("test_hole", "F5 (7-18, 16-19): test hole. Hold 70 frames, eject from the centre scoop (178,150) v=(-65,170). 5 frames "
             "after entry: in mode 2 double jackpot 60,000,000 and the mode ends; else if phys_level = 0 a hint message; else "
             "award ds:0821[(level-1)*32 + test_step] (5 dwords per level), test step lamp 13+step/4, test_step += 4 (max 16)", "high",
             ["kickout", "jackpot", "table_award"]),
    0x2379: ("center_hole", "F6 at ball x < 220 (centre hole, 183-195/146-153). Hold 50 frames, eject (178,150) v=(-65,170). "
             "5 frames after entry (not tilted): power_level + 1 with lamp 31+level blinking and 500,000; at 10 the power lamps "
             "reset and 10,000,000 is awarded. x >= 220 jumps to the right sink code", "high", ["kickout", "power_up"]),
    0x24cc: ("right_sink", "F7 (no pixels) and F6 at ball x >= 220 (right sink, 257-267/208-216). Hold 80 frames, eject at "
             "(247,232) v=(-120,90). Objective bits; the 3rd entry lights lamp 61 and opens gate0 (kickback lane). 5 frames after "
             "entry: if kicker_lit, bumper_value += 30,000 and it is displayed; else 50,000 and an alternating hint message", "high",
             ["kickout", "gate"]),
    0x2658: ("left_hole", "F8 at ball x <= 50, y <= 320 (left hole, 7-17/252-254; also active on the upper level). Forces level 0. "
             "Hold 80 frames (shares center_hole_timer), eject at the centre scoop. 5 frames after entry: millions award "
             "(millions_count x 1,000,000, count 1..9 per ball); 25 frames after entry: diverter reset (pixels written with the "
             "entry AH, i.e. 0) and lamps", "high", ["kickout", "millions", "collision_edit"]),
    0x279b: ("left_kickback", "F8 at ball x <= 50, y > 320 (29-33/391, bottom of the left outlane): vx = 0, vy = -300, lamp 59 on for "
             "5 frames (lamp_flash), lamp 61 off, sound 3, gate0 open; gate_timer = 120 closes it again", "high", ["kickback", "gate"]),
    0x27e6: ("diverter_switch", "F8 at 50 < ball x < 145 (82-83/268-272): toggles diverter_state, lamps 57/60, and rewrites 15 "
             "collision pixels around (40-47, 200-205) with 0xC0 (solid on the upper level) or 0x01 (open). One of the 15 offsets "
             "wraps past the 64000-byte bottom half (a game bug: it lands in the graphics data segment)", "medium",
             ["diverter", "collision_edit"]),
    0x2869: ("right_hole", "F8 at ball x >= 145 (right hole, 246-258/229-239). Hold 50 frames, eject at (239,236) v=(-190,90). "
             "5 frames after entry: phys_level 0 -> level 1 + armed; complete -> message; armed -> hint; otherwise arm, lamp "
             "40+level on, body-part message, 5,000,000, and at levels 3/5 a 2-ball multiball (mode 1, 30 s), at level 7 a "
             "3-ball multiball (mode 2, 30 s) and phys_complete", "high", ["kickout", "multiball", "mode_start", "progression"]),
    0x2ab8: ("ramps", "F9 (also on the upper level): ball x < 75 left ramp (38, 52-61), x > 280 right ramp (300, 112-147), "
             "otherwise objective bits only (no pixels there). Left ramp: super jackpot 100,000,000 in mode 3, else the "
             "android_level progression (level n needs its objective bits; awards 5M/10M/20M/35M, starts virus mode 4 after "
             "levels 2 and 4 and super jackpot mode 3 at level 6). Right ramp: virus flushed (15,000,000) in mode 4, computer "
             "link at level 0 (I.Q. = 99), else I.Q. upgrade = I.Q. x 10,000", "high", ["progression", "jackpot", "mode_start"]),
    0x2ea2: ("left_lane", "FB (96-100, 26-35): kicker_lit = 1 (lamp 7 blinks), objective AI2|0x10, bonus counter; in mode 1 "
             "jackpot 15,000,000 and the mode ends, else a hint message", "high", ["jackpot"]),
    0x2f3c: ("post_debounce", "FC (244, 369-370): lockout 15 only", "high", []),
    0x2f44: ("one_way_gate_left", "FD (140-156, 11-28): if ball vx <= 0: vx = -vx, x += 3, sound 0x11 at 3000 + 100*|vx| Hz "
             "(max 12000). Lockout 2", "high", ["one_way_gate"]),
    0x2f83: ("one_way_gate_right", "FE (269-288, 20-39; fires even during lockout): if ball vx >= 0: vx = -vx, x -= 3, sound 0x11 "
             "at 6000 + 100*vx Hz (max 15000). Sets sensor_cooldown 2 (not the lockout)", "high", ["one_way_gate"]),
    0x1f29: ("lockout_only", "C8..CF: lockout 1 (never reached at level 0: the scan only dispatches values > 0xCF)", "high", []),
    0x206c: ("noop_d0", "D0..D2: no-op", "high", []),
    0x1f23: ("noop", "D3..EF: no-op", "high", []),
    0x1f26: ("noop_low", "AA..C7: no-op", "high", []),
    0x2fc0: ("noop_ff", "FF: no-op", "high", []),
}

EP1_CS_INPUTS = {0x028d: "flipper_left", 0x028f: "flipper_right"}
EP1_DISPLAY_CLEAR = 0x5c23  # clear the message strip
EP1_DISPLAY_IDLE = 0x3af8   # redraw the idle strip text

# first block after the position tests of a shared colour -> name
EP1_BRANCHES = {0x2384: "center_hole", 0x2874: "right_hole", 0x27ed: "diverter_switch", 0x27a6: "left_kickback",
                0x2ac2: "left_ramp", 0x2d55: "right_ramp", 0x1f55: "top_lanes"}

# rule fragments outside the sensor table: name -> (entry, stop ips, description, confidence)
EP1_HOOKS = {
    "kicker": (0x19c1, (), "Bumper/slingshot contact (colour CF..D2). y<200: pop bumper (x<203 lamp 0 else lamp 1 flashes 3 frames), "
               "scores bumper_value, I.Q. +1 once the computer link is made. y>=200: slingshot 5,000 (x<145 lamp 50 else 51, 5 frames)", "high"),
    "frame_timers": (0x06e2, (0x0711,), "Per frame: extra gravity decay, kickback gate closes when gate_timer reaches 0", "high"),
    "frame_counters": (0x09dc, (0x0a17,), "Per frame: skill lane RNG, lockout/cooldown decrements, mode timer tick", "high"),
    "mode_timer": (0x3b6e, (), "Once per frame: timed mode countdown (seconds) and mode end", "high"),
    "flipper_lane_change": (0x102e, (0x1080,), "On flipper press (latched): rotate the 4 top lanes, re-light the skill lane", "high"),
    "lamp_flash": (0x10d0, (0x10f5,), "Per frame: lamp_flash_slot goes back to state 1 after lamp_flash_frames", "high"),
    "iq_display": (0x1134, (0x119f,), "Per frame: show I.Q. when it changed and is >= 100", "high"),
    "drain": (0x0a31, (0x0a9a,), "Drain: ball slot freed at y>=399; mode 1 ends when a ball drains; serve a new ball when all 5 slots are empty", "high"),
    "ball_end": (0x333e, (0x33e4,), "End of ball (after fade): power level lamps reset; tilt clears per-ball counters", "high"),
    "bonus_multiplier_payout": (0x33e7, (0x340d,), "Add the bonus total once per multiplier step, then multiplier = 1", "high"),
    "bonus_count": (0x35d1, (), "End of ball: bonus_total = sum of per-ball counters x award values, shown line by line", "high"),
    "next_ball_skill": (0x358e, (), "Next ball: remember score, choose skill lane from skill_lane_rng and blink its lamp", "high"),
}


# ---------------------------------------------------------------------------
# main-loop hook discovery (all tables)
#
# The main loop (and the end-of-ball routine it calls) is a straight sequence of
# statements.  A statement boundary is an instruction address that no branch
# crosses (a jump may land on it) and that does not separate a flag setter from
# its consumer; each statement is then single-entry / single-exit, so it can be
# lifted as a hook {entry, stops: [end]}.  A statement is a rule fragment when it
#   * lies outside the engine's own ball fragments (plunger lane, nudge/tilt,
#     gravity + object scan; tools/emu/discover.py finds them per table),
#   * lifts completely: only rule-like near calls (gosub) and the display / sound /
#     gate routines the lifter already stubs, no port I/O, interrupts, string ops,
#     far calls into the graphics library or indirect jumps,
#   * and writes rule state: a DS address that the sensor handlers read or write,
#     the lamp table, or the score (writes that only touch sound or pitch-sweep
#     variables do not count: sweeps are exported as `sound_sweeps`).
# Adjacent rule statements are merged.  The EP1 run reproduces all 6 hand-annotated
# main-loop fragments of EP1_HOOKS (same entry and stop); see --report.

CALL_ROLES_OK = ("message", "text", "number_text", "score_refresh", "sound_play")
FLAG_USERS = ("adc", "sbb", "cmc", "rcl", "rcr", "lahf", "pushf", "setc")


def _emu_config(n, path):
    try:
        sys.path.insert(0, os.path.join(HERE, "emu"))
        import discover  # noqa: E402
        return discover.discover(n, path)[0]
    except Exception as e:  # noqa: BLE001
        print(f"EP{n}: tools/emu/discover.py failed ({e}); no automatic hooks", file=sys.stderr)
        return None


def _statements(t, a, b, exits=()):
    """Statement boundaries of cs:a..b.  Jumps to `exits` (the main-loop head: "restart the frame")
    leave the statement and do not tie it to the code in between."""
    ins, x = [], a
    while x < b:
        i = t.insn(x)
        if i is None:
            break
        ins.append(i)
        x += i.size
    br = []
    for i in ins:
        if (i.mnemonic in JCC or i.mnemonic in ("jmp", "loop", "jcxz")) and i.operands and i.operands[0].type == X.X86_OP_IMM:
            if i.operands[0].imm not in exits:
                br.append((i.address, i.operands[0].imm))
    cuts = [a]
    for k in range(1, len(ins)):
        c = ins[k].address
        if ins[k].mnemonic in JCC or ins[k].mnemonic in FLAG_USERS:
            continue
        if any((s < c < d) if s < d else (d < c <= s) for s, d in br):
            continue
        cuts.append(c)
    cuts.append(x)
    return [(cuts[k], cuts[k + 1]) for k in range(len(cuts) - 1)]


def _insn_ok(t, L, i):
    """Can the lifter express this instruction inside a hook?  Returns (ok, gosub target or None)."""
    m = i.mnemonic
    if m in ("in", "out", "int", "iret", "retf", "ljmp", "hlt") or m.startswith(("rep", "movs", "stos", "lods", "cmps", "scas")) \
            or "rep" in i.op_str:
        return False, None
    if m in ("jmp", "call") and i.operands and i.operands[0].type != X.X86_OP_IMM:
        return False, None
    if m == "lcall":
        tgt = i.operands[1].imm if len(i.operands) == 2 and i.operands[0].imm == t.cs else None
        role = t.routines.get(tgt) if tgt is not None else None
        return (role in CALL_ROLES_OK or (role or "").startswith(("gate:", "display:", "hook:"))), None
    if m == "call":
        tgt = i.operands[0].imm
        role = t.routines.get(tgt)
        if role in CALL_ROLES_OK or (role or "").startswith(("gate:", "display:", "hook:")):
            return True, None
        if L.rule_like(tgt):
            return True, tgt
        return False, None
    return True, None


def _mem_refs(i):
    """(writes, reads): DS addresses of direct memory operands; indexed operands give their displacement
    (tables such as the lamp slots are addressed as [bx+disp])."""
    w, r = set(), set()
    for k, op in enumerate(i.operands):
        if op.type != X.X86_OP_MEM or op.mem.segment not in (0, X.X86_REG_DS):
            continue
        d = op.mem.disp & 0xFFFF
        span = set(range(d, d + max(1, op.size)))
        if k == 0 and i.mnemonic not in ("cmp", "test", "push") and not i.mnemonic.startswith("j"):
            w |= span
            if i.mnemonic not in ("mov",):
                r |= span
        else:
            r |= span
    return w, r


def _code_info(t, L, a, b, seen=None, depth=0):
    """(ok, writes, reads, uses cs: flags) over cs:a..b, following rule-like near calls."""
    seen = set() if seen is None else seen
    W, Rd, keys = set(), set(), False
    x = a
    while x < b:
        i = t.insn(x)
        if i is None:
            return False, W, Rd, keys
        x += i.size
        if i.mnemonic == "ret" and depth == 0:
            return False, W, Rd, keys
        ok, sub = _insn_ok(t, L, i)
        if not ok:
            return False, W, Rd, keys
        if "cs:[" in i.op_str:
            keys = True
        w, r = _mem_refs(i)
        W |= w
        Rd |= r
        if sub is not None and sub not in seen:
            seen.add(sub)
            ok2, w2, r2, k2 = _code_info(t, L, sub, _routine_end(t, sub), seen, depth + 1)
            if not ok2:
                return False, W, Rd, keys
            W |= w2
            Rd |= r2
            keys |= k2
    return True, W, Rd, keys


def _calls_message(t, L, a, b, seen=None):
    """Whether cs:a..b (following rule-like near calls) calls the dot-matrix message routine.  Such a
    main-loop statement is rule code even when it writes nothing rule code reads: the message is what the
    player sees (EP2 cs:04AB..0530, a message every 280 frames until the first plunger release)."""
    seen = set() if seen is None else seen
    for i in _iter_insns(t, a, b):
        if i.mnemonic != "call" or i.operands[0].type != X.X86_OP_IMM:
            continue
        tgt = i.operands[0].imm
        if t.routines.get(tgt) == "message":
            return True
        if tgt not in seen and L.rule_like(tgt):
            seen.add(tgt)
            if _calls_message(t, L, tgt, _routine_end(t, tgt), seen):
                return True
    return False


def _regions(t, L, entry, end):
    """Maximal liftable regions of the routine cs:entry..end: control flow is followed from each region
    start and cut at every instruction the lifter cannot express (fades, waits, graphics calls); the
    instruction after a cut starts the next region.  Returns [(start, stops, blocks_seen)]."""
    out, todo, done = [], [entry], set()
    while todo:
        r = todo.pop(0)
        if r in done or not (entry <= r < end):
            continue
        done.add(r)
        seen, cuts, work = set(), set(), [r]
        while work:
            x = work.pop()
            while x not in seen and entry <= x < end:
                i = t.insn(x)
                if i is None:
                    break
                ok, _ = _insn_ok(t, L, i)
                if not ok:
                    cuts.add(x)
                    todo.append(_cut_next(t, x))
                    break
                seen.add(x)
                m = i.mnemonic
                if (m in JCC or m in ("loop", "jcxz")) and i.operands[0].type == X.X86_OP_IMM:
                    work.append(i.operands[0].imm)
                if m == "jmp":
                    x = i.operands[0].imm
                    continue
                if m in ("ret", "retf", "iret"):
                    break
                x += i.size
        out.append((r, sorted(cuts), seen, _stack_ok(t, r, seen)))
    return out


def _cut_next(t, c):
    """Where the code after the cut at cs:c goes on: the next instruction, or for port I/O inside a loop
    (ball_lost_fade's palette fade, EP2 cs:35AE..35EE: DAC writes, `jne` back to the loop head) the exit of
    that loop, so the code after the fade (EP2 cs:35F0, the between-balls flag) is a region of its own and
    not the loop's `pop ax` tail."""
    i = t.insn(c)
    nxt = c + i.size
    if i.mnemonic not in ("in", "out"):
        return nxt
    x, exit_ = nxt, None
    while x < c + 0x60:
        j = t.insn(x)
        if j is None:
            break
        if (j.mnemonic in JCC or j.mnemonic == "loop") and j.operands[0].type == X.X86_OP_IMM and j.operands[0].imm <= c:
            exit_ = x + j.size
        if j.mnemonic in ("jmp", "ret", "retf", "iret", "call", "lcall"):
            break
        x += j.size
    return exit_ if exit_ is not None else nxt


def _region_via(regions_by_start, kept, nx, cut_next):
    """From the region start nx after a cut, the regions the end-of-ball code passes through before the
    next kept region: straight-line regions (no branch, one cut, no rule writes) such as EP2 cs:385F
    (`lcall`) between the frame wait cs:385C and the hook cs:3864, or EP9 cs:2F39 (the second
    dmd_idle_text call) after the frame wait cs:2F36.  Returns (next kept start or None, [cuts passed])."""
    via, seen = [], set()
    while nx not in kept:
        r = regions_by_start.get(nx)
        if r is None or nx in seen:
            return None, []
        seen.add(nx)
        cuts, straight = r
        if not straight or len(cuts) != 1:
            return None, []
        via.append(cuts[0])
        nx = cut_next(cuts[0])
    return nx, via


def _stack_ok(t, r, seen):
    """False if some path from r pops more than it pushed (the region uses stack values pushed before
    the display call that precedes it, so it cannot run on its own)."""
    work, depth_at = [(r, 0)], {}
    while work:
        x, d = work.pop()
        while x in seen:
            if depth_at.get(x, 99) <= d:
                break
            depth_at[x] = d
            i = t.insn(x)
            m = i.mnemonic
            if m in ("push", "pushf"):
                d += 1
            elif m in ("pusha", "pushaw"):
                d += 1
            elif m in ("pop", "popf", "popa", "popaw"):
                d -= 1
                if d < 0:
                    return False
            elif m in ("ret", "retf", "iret"):
                if d > 0:
                    pass
                break
            if (m in JCC or m in ("loop", "jcxz")) and i.operands[0].type == X.X86_OP_IMM:
                work.append((i.operands[0].imm, d))
            if m == "jmp":
                x = i.operands[0].imm
                continue
            x += i.size
    return True


def auto_hooks(t, handler_ips):
    """Main-loop / end-of-ball rule fragments found by pattern (see the comment above).
    Returns ({name: hook}, report dict)."""
    cfg = t.emu_cfg
    if cfg is None:
        return {}, {"error": "discover failed"}
    L0 = Lifter(t)
    for a in handler_ips + list(t.kicker_routines):
        L0.discover(a)
    rule = set()
    for a, i in L0.body.items():
        w, r = _mem_refs(i)
        rule |= w | r
    lt = t.lamp_table
    if lt:
        rule.update(range(lt["phase"], lt["terminator"]))
    rule.update(range(t.score, t.score + 4))
    for a_, (role, w) in t.roles.items():
        if not role.startswith(("sound", "ball.")):
            rule.update(range(a_, a_ + w))
    sound = set()
    for a_, (role, w) in t.roles.items():
        if role.startswith("sound"):
            sound.update(range(a_, a_ + w))
    for sw in t.sweeps:
        sound.add(int(sw["var"], 16))
    engine_only = set()
    for rname in ("ball_x", "ball_y", "ball_vx", "ball_vy", "ball_accx", "ball_accy", "ball_active", "ball_layer"):
        base = cfg["ds_vars"].get(rname)
        if base is not None:
            engine_only.update(range(base, base + 10))
    ranges = cfg.get("physics_ranges", [])
    engine_spans, whole = [], []
    for k, (a, b, s_) in enumerate(ranges):
        seg = t.code[a:b]
        if k == len(ranges) - 1:
            engine_spans.append((a, b))              # gravity + object scan
        elif cfg["cs_vars"].get("key_nudge_a") is not None and \
                b"\x2e\x80\x3e" + struct.pack("<H", cfg["cs_vars"]["key_nudge_a"]) in seg:
            engine_spans.append((a, b))              # nudge / tilt
        elif cfg.get("ball_lost_fade") is not None and cfg["ball_lost_fade"] in [
                (x + 3 + struct.unpack_from("<h", t.code, x + 1)[0]) & 0xFFFF for x in s_ if t.code[x] == 0xE8]:
            engine_spans.append((a, b))              # plunger lane / launch
        else:
            whole.append((a, b))                     # counters, drain, extra-gravity decay: rule candidates
    report = {"statements": 0, "rejected_unliftable": 0}

    # --- main loop: statements
    stmts = _statements(t, cfg["main_loop"], cfg["frame_sync"], exits=(cfg["main_loop"],))
    report["statements"] = len(stmts)
    info = []
    shows = set()                                    # statements that call dmd_message (EP2 cs:04AB: the timed message)
    for a, b in stmts:
        if any(sa <= a < sb for sa, sb in engine_spans):
            info.append((a, b, "engine", set(), set(), False, 0))
            continue
        ok, W, Rd, keys = _code_info(t, L0, a, b)
        n_ins = sum(1 for _ in _iter_insns(t, a, b))
        if not ok:
            report["rejected_unliftable"] += 1
        info.append((a, b, "ok" if ok else "bad", W, Rd, keys, n_ins))
        if ok and _calls_message(t, L0, a, b):
            shows.add(len(info) - 1)
    blf = cfg.get("ball_lost_fade")
    regions = []
    by_start = {}                                    # every region: start -> (cuts, straight-line)
    if blf is not None:
        for r0, cuts, seen, stack_ok in _regions(t, L0, blf, _routine_end(t, blf)):
            by_start[r0] = (cuts, not any(t.insn(x).mnemonic in JCC or t.insn(x).mnemonic in ("loop", "jcxz") for x in seen))
            if not stack_ok:
                continue
            W, Rd = set(), set()
            for x in seen:
                w, r = _mem_refs(t.insn(x))
                W |= w
                Rd |= r
                i = t.insn(x)
                if i.mnemonic == "call":
                    ok_, sub = _insn_ok(t, L0, i)
                    if sub is not None:
                        _, w2, r2, _k = _code_info(t, L0, sub, _routine_end(t, sub), depth=1)
                        W |= w2
                        Rd |= r2
            regions.append((r0, cuts, seen, W, Rd))
    R = set(rule)
    sel, rsel = set(), set()
    for _ in range(6):                               # fixpoint: writers of what rule code reads are rule code
        for k, (a, b, st, W, Rd, keys, n_ins) in enumerate(info):
            if st == "ok" and (((W & R) - sound - engine_only) or k in shows):
                sel.add(k)
        for k, reg in enumerate(regions):
            if (reg[3] & R) - sound - engine_only:
                rsel.add(k)
        R2 = R.union(*(info[k][4] for k in sel), *(regions[k][4] for k in rsel))
        if R2 == R:
            break
        R = R2
    hooks = {}
    # whole counters / drain fragments are one hook when any statement in them is rule code
    for sa, sb in whole:
        ks = [k for k, x in enumerate(info) if sa <= x[0] < sb]
        if any(k in sel for k in ks) and all(info[k][2] == "ok" for k in ks):
            sel.update(ks)
            for k in ks:                             # never split inside the fragment
                info[k] = info[k][:6] + (0,)
    run = []

    def flush():
        while run and run[-1] not in sel:
            run.pop()
        if run:
            a0, b0 = info[run[0]][0], info[run[-1]][1]
            W = set().union(*(info[k][3] for k in run))
            keys = any(info[k][5] for k in run)
            kind = _hook_kind(t, cfg, a0, b0, W, keys, "main")
            name = f"{kind or 'main'}_{a0:04x}"
            restart = any(i.mnemonic == "jmp" and i.operands[0].type == X.X86_OP_IMM and i.operands[0].imm == cfg["main_loop"]
                          for i in _iter_insns(t, a0, b0))
            hooks[name] = {"entry": a0, "stops": (b0,) + ((cfg["main_loop"],) if restart else ()), "conf": "auto",
                           "kind": kind or "main", "when": "every_frame",
                           "desc": f"automatic: main-loop statement(s) cs:{a0:04x}..{b0:04x} that write rule state"}
        run.clear()

    for k, (a, b, st, W, Rd, keys, n_ins) in enumerate(info):
        neutral = st == "ok" and not W and not keys and k not in sel
        big = n_ins > 12
        if k in sel:
            if run and (big or any(info[j][6] > 12 for j in run if j in sel)):
                # large statements are hooks of their own; keep the register set-up glue in front
                glue = []
                while run and run[-1] not in sel:
                    glue.insert(0, run.pop())
                flush()
                run.extend(glue)
            run.append(k)
        elif neutral:
            run.append(k)                            # register set-up, compares: glue
        else:
            flush()
    flush()
    # --- end of ball: liftable regions of ball_lost_fade that write rule state
    kept = {regions[k][0] for k in rsel}
    for k in sorted(rsel):
        r0, cuts, seen, W, Rd = regions[k]
        cont, via = {}, {}
        for c_ in cuts:
            nx, passed = _region_via(by_start, kept, _cut_next(t, c_), lambda c: _cut_next(t, c))
            if nx is not None:
                cont[h(c_)] = f"ball_end_{nx:04x}"
                if passed:
                    via[h(c_)] = [h(v) for v in passed]
        hooks[f"ball_end_{r0:04x}"] = {"entry": r0, "stops": tuple(cuts), "conf": "auto", "kind": "ball_end",
                                       "when": "ball_end", "continues": cont, **({"via": via} if via else {}),
                                       "desc": f"automatic: end-of-ball code from cs:{r0:04x} (inside ball_lost_fade cs:{blf:04x}) up to "
                                               "the next display/fade call" + (f"s {', '.join(f'cs:{c:04x}' for c in cuts)}" if cuts else "")}
    report["candidates"] = sorted((v["entry"], v["stops"], k) for k, v in hooks.items())
    return hooks, report


def _routine_end(t, a, limit=0x800):
    """End of a near routine: the first ret past every jump target seen so far (linear sweep)."""
    far, x = a, a
    while x < a + limit:
        i = t.insn(x)
        if i is None:
            return x
        if (i.mnemonic in JCC or i.mnemonic in ("jmp", "loop", "jcxz")) and i.operands and i.operands[0].type == X.X86_OP_IMM:
            far = max(far, i.operands[0].imm)
        x += i.size
        if i.mnemonic in ("ret", "retf", "iret") and x > far:
            return x
    return x


def _iter_insns(t, a, b):
    x = a
    while x < b:
        i = t.insn(x)
        if i is None:
            return
        yield i
        x += i.size


def _hook_kind(t, cfg, a, b, writes, keys, when):
    ds_ = cfg["ds_vars"]
    code = t.code[a:b]
    if when == "ball_end":
        return "ball_end"
    xg = ds_.get("extra_gravity_timer")
    if xg is not None and b"\x83\x3e" + struct.pack("<H", xg) + b"\x00" in code:
        return "frame_timers"
    if cfg.get("drain_y") is not None and re.search(rb"\x81\xbd.." + re.escape(struct.pack("<H", cfg["drain_y"])), code, re.S):
        return "drain"
    if any(b"\xfe\x0e" + struct.pack("<H", v) in code for v in cfg.get("frame_counters", []) + [ds_.get("event_lockout", -1) & 0xFFFF]):
        return "frame_counters"
    if keys and any(struct.pack("<H", cfg["cs_vars"].get(k, 0xFFFF)) in code for k in ("key_lflip", "key_rflip")):
        return "flipper_press"
    lt = t.lamp_table
    if lt and any(lt["first"] <= w < lt["terminator"] for w in writes) and re.search(rb"\x80\x3e..\x00", code, re.S):
        return "lamp_timer"
    return None


# ---------------------------------------------------------------------------
# regions and sensors


def components(mask):
    seen = np.zeros_like(mask, bool)
    out = []
    for y, x in zip(*np.nonzero(mask)):
        if seen[y, x]:
            continue
        q = deque([(y, x)])
        seen[y, x] = True
        pts = []
        while q:
            cy, cx = q.popleft()
            pts.append((int(cx), int(cy)))
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    ny, nx = cy + dy, cx + dx
                    if 0 <= ny < mask.shape[0] and 0 <= nx < mask.shape[1] and mask[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        q.append((ny, nx))
        out.append(pts)
    return out


def regions_for(cb, v):
    out = []
    for p in components(cb == v):
        xs = [q[0] for q in p]
        ys = [q[1] for q in p]
        out.append({"bbox": [min(xs), min(ys), max(xs), max(ys)], "pixels": len(p)})
    out.sort(key=lambda r: (r["bbox"][1], r["bbox"][0]))
    return out


# ---------------------------------------------------------------------------
# summaries


def reachable(blocks, entry):
    seen, work = [], [entry]
    while work:
        l = work.pop()
        if l in seen or l not in blocks:
            continue
        seen.append(l)
        e = blocks[l]["end"]
        for k in ("else", "then", "goto"):
            if k in e:
                work.append(e[k])
    return seen


def position_branch(blocks, entry, bx, by):
    """Follow the handler's leading tests on ball.x / ball.y (blocks without
    other side effects) for a ball at top-left (bx, by); return the label
    where real work starts."""
    l = entry
    for _ in range(12):
        b = blocks.get(l)
        if b is None:
            return l
        if any(o["op"] != "reg" for o in b["ops"]):
            return l
        e = b["end"]
        if "goto" in e:
            l = e["goto"]
            continue
        if "if" not in e:
            return l
        c = e["if"]
        if not (isinstance(c["a"], list) and c["a"][0] == "ball" and c["a"][1] in ("x", "y") and is_const(c["b"])):
            return l
        a = bx if c["a"][1] == "x" else by
        b_ = c["b"]
        res = {"eq": a == b_, "ne": a != b_, "ult": a < b_, "ule": a <= b_, "ugt": a > b_, "uge": a >= b_,
               "slt": a < b_, "sle": a <= b_, "sgt": a > b_, "sge": a >= b_}[c["cmp"]]
        l = e["then"] if res else e["else"]
    return l


def summarize(blocks, entry):
    s = defaultdict(list)
    counts = Counter()
    for l in reachable(blocks, entry):
        b = blocks[l]
        for o in b["ops"]:
            k = o["op"]
            counts[k] += 1
            if k == "score":
                s["score"].append(o["add"])
            elif k == "lamp":
                s["lamps"].append([o["slot"], o["state"]])
            elif k in ("sound", "sound_now", "sound_play"):
                s["sounds"].append(o["id"])
            elif k in ("message", "text"):
                s["messages"].append(o["msg"])
            elif k == "set":
                s["writes"].append(o["var"])
            elif k in ("ball", "ball_slot"):
                s["ball"].append({kk: vv for kk, vv in o.items() if kk != "op"})
            elif k == "pixels":
                s["pixels"].append({"val": o["val"], "n": len(o.get("xy", []))})
            elif k == "gate":
                s["gates"].append(o["gate"])
            elif k in ("layer", "extra_gravity", "lockout", "cooldown"):
                s[k].append(o.get("val", o.get("frames")))
        c = b["end"].get("if")
        if c:
            s["conditions"].append(fmt_expr(c["a"]) + f" {c['cmp']} " + fmt_expr(c["b"]))
    out = {}
    for k, v in s.items():
        uniq = []
        for x in v:
            if x not in uniq:
                uniq.append(x)
        out[k] = uniq
    return out, counts


def detect_kickouts(blocks, entry):
    """Hold+eject pattern, one per countdown variable T found in the handler:
    a block does T = T - 1, and from there (without passing another countdown)
    one path stops the ball (vx = vy = 0) and one path places it at a constant
    position/velocity.  The hold time is the constant stored into T."""
    reach = reachable(blocks, entry)
    decs = {}
    for l in reach:
        for o in blocks[l]["ops"]:
            v = o.get("val")
            if o["op"] == "set" and isinstance(v, list) and v[0] == "sub" and v[2] == 1 and isinstance(v[1], list) and v[1][:2] == ["var", o["var"]]:
                decs[l] = o["var"]
    out = []
    for l0, tv in decs.items():
        hold = eject = None
        seen, work = set(), [l0]
        while work:
            l = work.pop()
            if l in seen or l not in blocks or (l != l0 and l in decs):
                continue
            seen.add(l)
            for o in blocks[l]["ops"]:
                if o["op"] == "ball":
                    st = o["set"]
                    if st.get("vx") == 0 and st.get("vy") == 0 and "x" not in st:
                        hold = l
                    if all(k in st and is_const(st[k]) for k in ("x", "y", "vx", "vy")):
                        eject = {k: st[k] for k in ("x", "y", "vx", "vy")}
            e = blocks[l]["end"]
            work += [e[k] for k in ("goto", "then", "else") if k in e]
        if not (hold and eject):
            continue
        init = None
        for l in reach:
            if not any(o["op"] == "set" and o["var"] == tv and is_const(o["val"]) and o["val"] > 1 for o in blocks[l]["ops"]):
                continue
            # does this block lead to l0 without passing another countdown?
            seen2, work2, hit = set(), [l], False
            while work2 and not hit:
                x = work2.pop()
                if x in seen2 or x not in blocks:
                    continue
                seen2.add(x)
                e = blocks[x]["end"]
                for k in ("goto", "then", "else"):
                    if k in e:
                        if e[k] == l0:
                            hit = True
                        elif e[k] not in decs:
                            work2.append(e[k])
            if hit:
                init = next(o["val"] for o in blocks[l]["ops"] if o["op"] == "set" and o["var"] == tv and is_const(o["val"]) and o["val"] > 1)
        awards = []
        for l in reach:
            c = blocks[l]["end"].get("if")
            if c and isinstance(c["a"], list) and c["a"][:2] == ["var", tv] and is_const(c["b"]) and c["b"] not in (0, init):
                awards.append(c["b"])
        out.append({"timer": tv, "hold_frames": init, "eject": eject, "decrement_block": l0,
                    "timer_values_with_actions": sorted(set(awards), reverse=True)})
    return out


def build(n, auto=True, drop=()):
    t = Table(n)
    L = Lifter(t)
    handler_ips = sorted(set(int(v, 16) for v in t.col["trigger_table"]["handlers"].values()))
    hooks = {}
    native_hooks = {}
    if n == 1:
        for name, (entry, stops, desc, conf) in EP1_HOOKS.items():
            hooks[name] = {"entry": entry, "stops": stops, "desc": desc, "conf": conf}
        for name, (entry, stops, desc, conf) in EP1_HOOKS.items():
            if not stops:
                t.routines.setdefault(entry, f"hook:{name}")
        t.routines[EP1_DISPLAY_CLEAR] = "display:clear"
        t.routines[EP1_DISPLAY_IDLE] = "display:idle_text"
    else:
        for k in t.kicker_routines:
            hooks["kicker"] = {"entry": k, "stops": (), "desc": "active surface contact routine (from collision.json wall_events)", "conf": "high"}
        if auto:
            ah, _rep = auto_hooks(t, handler_ips)
            for name, hk in sorted(ah.items(), key=lambda kv: kv[1]["entry"]):
                if name not in drop:
                    hooks[name] = hk
                elif hk.get("when") == "ball_end":
                    # an end-of-ball region that does not lift (EP5 cs:1F4A, the demo/tilt/extra-ball tests
                    # before the bonus): the runtime executes it from the EXE so the chain still starts there
                    native_hooks[name] = hk
    if t.dispatch_tail is not None:
        hooks["dispatch_tail"] = {"entry": t.dispatch_tail, "stops": (), "conf": "high",
                                  "desc": "shared exit of the sensor dispatcher: runs after every handler that jumps to it, and on "
                                          "dispatcher calls for colours < 0xAA or while tilted"}
    for hk in hooks.values():
        L.stops.update(hk["stops"])
    for a in handler_ips:
        L.discover(a)
    for hk in hooks.values():
        L.discover(hk["entry"])
    for name, hk in hooks.items():
        if name == "kicker":
            seen, work = set(), [hk["entry"]]
            while work:
                a = work.pop()
                if a in seen or a not in L.body:
                    continue
                seen.add(a)
                insns, fall = L.block_insns(a)
                last = insns[-1]
                if last.mnemonic in JCC:
                    work += [last.operands[0].imm, fall]
                elif last.mnemonic == "jmp" and last.operands[0].type == X.X86_OP_IMM:
                    work.append(last.operands[0].imm)
                elif last.mnemonic not in ("ret", "jmp"):
                    work.append(fall)
            L.kicker_blocks |= seen
    L.lift_all()
    # an automatic hook that does not lift completely (an instruction the lifter has no op for) is dropped
    bad = []
    for name, hk in hooks.items():
        if hk.get("conf") != "auto":
            continue
        seen, work = set(), [L.label(hk["entry"])]
        while work:
            l = work.pop()
            if l in seen or l[1:].isalpha():
                continue
            a_ = int(l[1:], 16) if l.startswith("L") else None
            if a_ is None or a_ not in L.blocks:
                continue
            seen.add(l)
            b = L.blocks[a_]
            if any(o["op"] in ("asm", "call") for o in b["ops"]):
                bad.append(name)
                break
            e = b["end"]
            work += [e[k] for k in ("then", "else", "goto") if k in e]
            work += [o["entry"] for o in b["ops"] if o["op"] == "gosub"]
    if bad:
        return build(n, auto, tuple(drop) + tuple(bad))

    S = Semantics(t)
    for b in L.blocks.values():
        for o in b["ops"]:
            if o["op"] == "store" and o["w"] == 4 and is_const(o["addr"]):
                S.dwords.add(o["addr"])
            walk_expr({k: v for k, v in o.items() if k != "op"},
                      lambda x: (S.dwords.add(x[2]) if x[0] == "mem" and x[1] == 4 and is_const(x[2]) else None) or x)
    S.dwords.discard(t.score) if False else None
    # message/text ops whose string comes from a register: the constants and
    # pointer tables assigned to that register anywhere in the lifted code
    for b in L.blocks.values():
        for o in b["ops"]:
            if o["op"] == "reg" and o["r"] == "bx":
                v = o["val"]
                if is_const(v) and 0x20 <= v < len(t.dsmem) and S.looks_like_string(v) and v > 0x30:
                    S.bx_consts.add(v)
                elif isinstance(v, list) and v[0] == "mem" and v[1] == 2:
                    S.note_msg(v)
    blocks = {}
    for a, b in sorted(L.blocks.items()):
        ops = merge_ops([S.op(o) for o in b["ops"]])
        end = dict(b["end"])
        if "if" in end:
            c = dict(end["if"])
            c["a"], c["b"] = S.expr(c["a"]), S.expr(c["b"])
            end["if"] = c
        blocks[L.label(a)] = {"ip": b["ip"], "ops": ops, "end": end}

    # sensors (blocks are final here; position branches are evaluated on them)
    sensors = []
    # the lockout-bypass value of this table's ball_pixel_scan (EP1 cs:16D6 cmp al,0FEh; je +5; cmp ah,0;
    # EP7 cs:1738 uses 0DBh); tables whose scan has no such test bypass nothing
    bm = re.search(rb"\x3c(.)\x74\x05\x80\xfc\x00", t.code)
    bypass = bm.group(1)[0] if bm else None
    for lvl, tbl in enumerate(t.col["sensors"]):
        for v, info in sorted(tbl.items(), key=lambda kv: int(kv[0])):
            v = int(v)
            hip = int(info["handler_ip"], 16)
            regs_ = regions_for(t.cb, v)
            for r in regs_:
                x0, y0, x1, y1 = r["bbox"]
                # ball top-left when its centre is on the region centre
                br = position_branch(blocks, f"L{hip:04x}", (x0 + x1) // 2 - 7, (y0 + y1) // 2 - 7)
                if br and br != f"L{hip:04x}":
                    r["branch"] = br
                    if n == 1 and int(br[1:], 16) in EP1_HANDLERS:
                        r["branch_name"] = EP1_HANDLERS[int(br[1:], 16)][0]
                    elif n == 1 and int(br[1:], 16) in EP1_BRANCHES:
                        r["branch_name"] = EP1_BRANCHES[int(br[1:], 16)]
            sensors.append({"colour": f"{v:02X}", "value": v, "level": lvl, "handler": f"h{hip:04x}",
                            "fires_when_tilted": info["always"], "ignores_lockout": v == bypass,
                            "regions": regs_})
    handlers = {}
    for a in handler_ips:
        entry = L.label(a)
        summ, counts = summarize(blocks, entry)
        colours = sorted(int(k) for k, v in t.col["trigger_table"]["handlers"].items() if int(v, 16) == a)
        d = {"entry": entry, "colours": [f"{c:02X}" for c in colours], "summary": summ, "op_counts": dict(counts)}
        ko = detect_kickouts(blocks, entry)
        if ko:
            d["kickouts"] = ko
        if n == 1 and a in EP1_HANDLERS:
            nm, desc, conf, tags = EP1_HANDLERS[a]
            d.update({"name": nm, "desc": desc, "conf": conf, "tags": tags})
        handlers[f"h{a:04x}"] = d
    # sub-handlers reached by position tests inside EP1 handlers
    if n == 1:
        for a in (0x24cc, 0x2658, 0x279b, 0x27e6):
            if f"h{a:04x}" not in handlers:
                entry = L.label(a)
                summ, counts = summarize(blocks, entry)
                nm, desc, conf, tags = EP1_HANDLERS[a]
                d = {"entry": entry, "colours": [], "reached_from_position_test": True, "summary": summ, "op_counts": dict(counts),
                     "name": nm, "desc": desc, "conf": conf, "tags": tags}
                ko = detect_kickouts(blocks, entry)
                if ko:
                    d["kickouts"] = ko
                handlers[f"h{a:04x}"] = d
    hook_out = {}
    for name, hk in hooks.items():
        entry = L.label(hk["entry"])
        summ, counts = summarize(blocks, entry)
        hook_out[name] = {"entry": entry, "stops": [h(x) for x in hk["stops"]], "desc": hk["desc"], "conf": hk["conf"],
                          "summary": summ, "op_counts": dict(counts)}
        for k in ("kind", "when", "continues", "via"):   # automatic hooks only (additive keys)
            if k in hk:
                hook_out[name][k] = hk[k]

    # variables
    pb = t.player_block
    vars_out = {}
    for a, info in sorted(S.vars.items()):
        name = S.var_name(a, info["w"])
        w = info["w"]
        d = {"addr": h(a), "size": w, "init": int.from_bytes(t.dsmem[a:a + w], "little") if a + w <= len(t.dsmem) else None,
             "scope": "player" if pb and pb[0] <= a < pb[1] else "game"}
        if a in t.roles:
            d["role"] = t.roles[a][0]
        if n == 1 and a in EP1_VARS:
            d["desc"], d["conf"] = EP1_VARS[a][1], EP1_VARS[a][2]
        elif n == 1 and a in t.img.syms.data:
            d["desc"] = t.img.syms.data[a].get("desc", "")
        vars_out[name] = d
    engine = {}
    for a, (role, w) in sorted(t.roles.items()):
        engine[role] = {"addr": h(a), "size": w}
    for f, base in t.ball_arrays.items():
        engine[f"ball_slots.{f}"] = {"addr": h(base), "size": 2, "count": 5, "stride": 2}
    engine["ball_slots.layer"] = {"addr": h(t.ball_layer_arr), "size": 1, "count": 5, "stride": 2}

    # coverage
    cov = Counter()
    for b in blocks.values():
        for o in b["ops"]:
            cov[o["op"]] += 1
    lowlevel = sum(cov[k] for k in ("store", "reg", "push", "pop", "push_all", "pop_all", "gosub"))
    state = cov["set"]
    unexpressed = sum(cov[k] for k in ("asm", "call"))
    total = sum(cov.values())
    generic = lowlevel + state

    lt = t.lamp_table
    lamp_info = []
    sp_path = os.path.join(ROOT, "extracted", "tables", f"EP{n}", "sprites", "sprites.json")
    if lt and os.path.exists(sp_path):
        sp = json.load(open(sp_path))
        by = {}
        for e in sp.get("sprites", []):
            if e.get("group") == "lamp" and "lamp" in e:
                by.setdefault(e["lamp"], {})[e["name"][-1]] = e
        for k in range(lt["count"]):
            e = by.get(k, {})
            d = {"slot": k}
            for ab in ("a", "b"):
                if ab in e:
                    d[ab] = {"sprite": e[ab]["name"], "bbox": [e[ab]["x"], e[ab]["y"], e[ab]["w"], e[ab]["h"]],
                             "playfield_match": e[ab].get("playfield_match"), "dummy": e[ab].get("dummy", False)}
            if n == 1 and k in EP1_LAMPS:
                d["name"] = EP1_LAMPS[k]
            lamp_info.append(d)
    out = {
        "schema": SCHEMA,
        "table": n,
        "exe": os.path.basename(t.path),
        "generator": "tools/rules.py",
        "annotated": n == 1,
        "source": {"code_segment": h(t.cs), "data_segment": h(t.ds), "sensor_dispatch": h(t.dispatch_ip),
                   "sensor_table": f"cs:{t.table_ip:04x}"},
        "memory": {
            "data_segment_file_offset": h(t.ds_file), "data_segment_size": t.ds_size,
            "note": "Load these bytes from the user's EPn.EXE at startup; they are the initial state. var/mem addresses are offsets in it.",
            "player_block": {"start": h(pb[0]), "end": h(pb[1])} if pb else None,
            "lamps": {"phase": h(lt["phase"]), "first": h(lt["first"]), "count": lt["count"],
                      "other_tables": lt["other_tables"], "show_table_pointers": lt["show_table_pointers"],
                      "states": {"0": "off (not drawn)", "1": "draw sprite a once, then 5", "2": "draw sprite b once, then 6",
                                 "3": "blink, a next", "4": "blink, b next", "5": "a steady", "6": "b steady"}} if lt else None,
        },
        "lamp_slots": lamp_info,
        "engine_vars": engine,
        "vars": vars_out,
        "stub_routines": L.stub_routines,
        "sound_sweeps": t.sweeps,
        "gates": [{k: (h(v) if k == "control_var" and v is not None else v) for k, v in g.items()} for g in t.gates],
        "messages": sorted(S.messages.values(), key=lambda m: int(m["ds"], 16)),
        "message_tables": {h(k): [h(p) for p in v] for k, v in S.msg_tables.items()},
        "sensors": sensors,
        "handlers": handlers,
        "hooks": hook_out,
        **({"native_hooks": {name: {"entry": h(hk["entry"]), "stops": [h(x) for x in hk["stops"]], "kind": hk["kind"],
                                    "when": hk["when"], "continues": hk["continues"], **({"via": hk["via"]} if "via" in hk else {}),
                                    "desc": hk["desc"] + "; not lifted (an instruction the lifter has no op for): run from the EXE"}
                             for name, hk in sorted(native_hooks.items())}} if native_hooks else {}),
        "blocks": blocks,
        "coverage": {"ops": dict(cov), "total": total, "semantic": total - generic - unexpressed, "state_updates": state,
                     "low_level": lowlevel, "generic": generic, "unexpressed": unexpressed, "unsupported": dict(L.unsupported),
                     "note": "semantic = engine-facing ops (score, lamp, sound, ball, layer, message, gate, ...); state_updates = "
                             "'set' on named variables; low_level = reg/store/push/pop/gosub"},
        "notes": t.notes + [f"automatic hook {d} dropped: it does not lift completely" for d in drop],
    }
    return out, t, L


def dump_handler(out, name):
    blocks = out["blocks"]
    hd = out["handlers"].get(name) or out["hooks"].get(name)
    if hd is None:
        raise SystemExit(f"no handler {name}")
    print(f"# {name} {hd.get('name', '')}: {hd.get('desc', '')}")
    for l in sorted(reachable(blocks, hd["entry"])):
        b = blocks[l]
        print(f"{l}:")
        for o in b["ops"]:
            k = o["op"]
            rest = {kk: vv for kk, vv in o.items() if kk != "op"}
            print(f"    {k:<12} " + ", ".join(f"{kk}={fmt_expr(vv)}" for kk, vv in rest.items()))
        e = b["end"]
        if "if" in e:
            c = e["if"]
            print(f"    if {fmt_expr(c['a'])} {c['cmp']} {fmt_expr(c['b'])} (w{c['w']}) -> {e['then']} else {e['else']}")
        elif "goto" in e:
            print(f"    goto {e['goto']}")
        else:
            print("    return")


def report(out):
    c = out["coverage"]
    print(f"EP{out['table']}: {len(out['handlers'])} handlers, {len(out['blocks'])} blocks, {c['total']} ops: "
          f"semantic {c['semantic']}, state {c['state_updates']}, low-level {c['low_level']}, unexpressed {c['unexpressed']}")
    print("   ops:", dict(sorted(c["ops"].items(), key=lambda kv: -kv[1])))
    if c["unsupported"]:
        print("   unsupported:", c["unsupported"])
    ev = out["engine_vars"]
    print("   engine vars:", {k: v["addr"] for k, v in ev.items()})
    print("   lamps:", out["memory"]["lamps"], " player block:", out["memory"]["player_block"])
    print("   gates:", [(g["id"], g["control_var"], len(g["pixels"])) for g in out["gates"]])
    print("   messages:", len(out["messages"]), "tables:", list(out["message_tables"]))
    for k, v in out["handlers"].items():
        for ko in v.get("kickouts", []):
            print(f"   kickout {k}: {ko['timer']} hold {ko['hold_frames']} eject {ko['eject']} actions at {ko['timer_values_with_actions']}")
    for note in out["notes"]:
        print("   note:", note)


def hooks_check(n):
    t = Table(n)
    hips = sorted(set(int(v, 16) for v in t.col["trigger_table"]["handlers"].values()))
    ah, rep_ = auto_hooks(t, hips)
    print(f"EP{n}: {rep_.get('statements')} main-loop statements, {rep_.get('rejected_unliftable')} not liftable; "
          f"{len(ah)} automatic hooks")
    for name, hk in sorted(ah.items(), key=lambda kv: kv[1]["entry"]):
        print(f"   {name:22s} cs:{hk['entry']:04x} stops {[h(x) for x in hk['stops']]}")
    if n == 1:
        auto_ranges = {(hk["entry"], tuple(hk["stops"])) for hk in ah.values()}
        for name, (entry, stops, desc, conf) in EP1_HOOKS.items():
            if not stops:
                continue
            same = (entry, tuple(stops)) in auto_ranges
            print(f"   EP1_HOOKS {name:24s} cs:{entry:04x}..{stops[0]:04x}: {'found exactly' if same else 'NOT found as one hook'}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tables", nargs="+", type=int)
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--dump", default=None, help="print a handler/hook as text")
    ap.add_argument("--no-write", action="store_true")
    ap.add_argument("--no-auto-hooks", action="store_true",
                    help="EP2-EP13: only kicker/dispatch_tail hooks (the output before automatic hook discovery)")
    ap.add_argument("--hooks-check", action="store_true",
                    help="print the automatic hook discovery and, for EP1, compare it with the hand annotation EP1_HOOKS")
    a = ap.parse_args(argv)
    for n in a.tables:
        if a.hooks_check:
            hooks_check(n)
            continue
        out, t, L = build(n, auto=not a.no_auto_hooks)
        if not a.no_write:
            p = os.path.join(ROOT, "extracted", "tables", f"EP{n}", "rules.json")
            with open(p, "w") as f:
                json.dump(out, f, indent=1)
            print("wrote", os.path.relpath(p, ROOT))
        if a.report:
            report(out)
        if a.dump:
            if a.dump == "all":
                for k in list(out["handlers"]) + list(out["hooks"]):
                    dump_handler(out, k)
                    print()
            else:
                dump_handler(out, a.dump)


if __name__ == "__main__":
    main()
