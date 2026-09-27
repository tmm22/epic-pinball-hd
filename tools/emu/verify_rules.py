#!/usr/bin/env python3
"""Differential test of lifted rules (extracted/tables/EPn/rules.json) against the ORIGINAL code.

For every sensor handler and hook, the rules.json block graph is run by a small IR interpreter
(what an app implements) and the same code is run from the handler/hook entry on Unicorn with the
user's EPn.EXE mapped (display routines stubbed: message/text/number/score refresh).  Resulting DS
bytes, collision-buffer bytes and display calls are compared.  Two phases per target:

  * random: N states built from the EXE's initial DS with rule variables randomised towards the
    constants the target compares against, ball inside the sensor's regions, random registers and
    random flipper keys (method of scratch/rules/verify_ir.py, generalised to every table);
  * directed: for every block the random phase never executed, a path from the entry is taken and
    the branch conditions along it (on variables, memory, ball, lamp and slot fields compared with
    constants, also through `and` masks and `add` offsets) are solved greedily into a state; the
    state is checked to reach the block in the interpreter (small +-1/+-2 search) and then run
    differentially like a random one.

The whole 64 KB DS window is modelled by default (past data_segment_size it is the playfield image,
as in the original; --no-fullseg compares only the exported DS range with a separate tail).

  .venv/bin/python tools/emu/verify_rules.py 1 2 3 [--trials 300] [--directed 3] [--only NAME] [--json OUT]
  .venv/bin/python tools/emu/verify_rules.py --all --json scratch/rules/verify_all.json

Exit status 1 if any comparison fails.  Reproduces verify_ir.py's EP1/EP2/EP10 results with --no-fullseg.
"""
import argparse
import json
import os
import random
import struct
import sys
import time

import numpy as np
from unicorn import UC_ARCH_X86, UC_MODE_16, UC_HOOK_CODE, Uc, UcError
from unicorn.x86_const import (UC_X86_REG_AX, UC_X86_REG_BP, UC_X86_REG_BX, UC_X86_REG_CS, UC_X86_REG_CX,
                               UC_X86_REG_DI, UC_X86_REG_DS, UC_X86_REG_DX, UC_X86_REG_ES, UC_X86_REG_IP,
                               UC_X86_REG_SI, UC_X86_REG_SP, UC_X86_REG_SS, UC_X86_REG_FLAGS)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, HERE)
import epexe  # noqa: E402

REGS = {"ax": UC_X86_REG_AX, "bx": UC_X86_REG_BX, "cx": UC_X86_REG_CX, "dx": UC_X86_REG_DX,
        "si": UC_X86_REG_SI, "di": UC_X86_REG_DI, "bp": UC_X86_REG_BP}


class Unknown(Exception):
    pass


# ---------------------------------------------------------------------------
class IR:
    def __init__(self, rules, code, ds_mem, pf, inputs):
        self.r = rules
        self.code = code
        self.mem = ds_mem
        self.pf = pf
        self.inputs = inputs
        self.regs = {}
        self.stack = []
        self.events = []
        self.vars = rules["vars"]
        self.ev = rules["engine_vars"]
        lt = rules["memory"]["lamps"]
        self.lamp0 = int(lt["first"], 16)
        self.steps = 0
        self.visited = set()

    # memory helpers
    def rd(self, a, w):
        a &= 0xFFFF
        return int.from_bytes(self.mem[a:a + w], "little")

    def wr(self, a, w, v):
        a &= 0xFFFF
        self.mem[a:a + w] = (v & ((1 << (8 * w)) - 1)).to_bytes(w, "little")

    def var_addr(self, name):
        if name in self.vars:
            return int(self.vars[name]["addr"], 16)
        if name in self.ev:
            return int(self.ev[name]["addr"], 16)
        if name.endswith(".hi"):
            return self.var_addr(name[:-3]) + 2
        raise KeyError(name)

    def ev_addr(self, role):
        return int(self.ev[role]["addr"], 16), self.ev[role]["size"]

    # expressions
    def e(self, x):
        if isinstance(x, int):
            return x
        if isinstance(x, dict):
            raise ValueError(x)
        op = x[0]
        E = self.e
        if op == "reg":
            if x[1] not in self.regs or self.regs[x[1]] == "UNDEF":
                raise Unknown(f"reg {x[1]} undefined")
            return self.regs[x[1]]
        if op == "mem":
            return self.rd(E(x[2]), x[1])
        if op == "cmem":
            a = E(x[2]) & 0xFFFF
            return int.from_bytes(self.code[a:a + x[1]], "little")
        if op == "var":
            return self.rd(self.var_addr(x[1]), x[2])
        if op == "ball":
            a, w = self.ev_addr("ball." + x[1])
            return self.rd(a, w)
        if op == "ball_slot":
            base = self.ev["ball_slots." + x[2]]
            return self.rd(int(base["addr"], 16) + 2 * x[1], base["size"])
        if op == "lamp":
            return self.mem[(self.lamp0 + E(x[1])) & 0xFFFF]
        if op == "input":
            return self.inputs[x[1]]
        if op == "contact_colour":
            return self.inputs["contact_colour"]
        if op == "unknown":
            raise Unknown(f"unknown value from {x[1]}")
        a = [E(v) for v in x[1:]]
        if op == "add":
            return a[0] + a[1]
        if op == "sub":
            return a[0] - a[1]
        if op == "mul":
            return a[0] * a[1]
        if op == "and":
            return a[0] & a[1]
        if op == "or":
            return a[0] | a[1]
        if op == "xor":
            return a[0] ^ a[1]
        # shift counts are taken mod 32, as on the 80186 and later (the game's 386/486 targets; EP9 cs:2e07
        # shifts by a counter that can exceed 31)
        if op == "shl":
            return (a[0] << (a[1] & 31)) & 0xFFFF
        if op == "shr":
            return (a[0] & 0xFFFF) >> (a[1] & 31)
        if op == "sar":
            v = a[0] & 0xFFFF
            v = v - 0x10000 if v & 0x8000 else v
            return (v >> (a[1] & 31)) & 0xFFFF
        if op == "neg":
            return (-a[0]) & 0xFFFF
        if op == "lo":
            return a[0] & 0xFF
        if op == "hi":
            return (a[0] >> 8) & 0xFF
        if op == "setlo":
            return (a[0] & 0xFF00) | (a[1] & 0xFF)
        if op == "sethi":
            return (a[0] & 0x00FF) | ((a[1] & 0xFF) << 8)
        if op == "join":
            return ((a[0] & 0xFFFF) << 16) | (a[1] & 0xFFFF)
        if op == "lo16":
            return a[0] & 0xFFFF
        if op == "hi16":
            return (a[0] >> 16) & 0xFFFF
        if op == "mul32":
            return (a[0] & 0xFFFF) * (a[1] & 0xFFFF)
        if op == "div32":
            return ((a[0] & 0xFFFFFFFF) // (a[1] & 0xFFFF)) & 0xFFFF
        if op == "mod32":
            return (a[0] & 0xFFFFFFFF) % (a[1] & 0xFFFF)
        if op == "div":
            return ((a[0] & 0xFFFF) // (a[1] & 0xFF)) & 0xFF
        if op == "mod":
            return (a[0] & 0xFFFF) % (a[1] & 0xFF)
        if op == "sext8":
            v = a[0] & 0xFF
            return (v - 0x100 if v & 0x80 else v) & 0xFFFF
        if op == "ltu":
            m = (1 << (8 * a[2])) - 1
            return 1 if (a[0] & m) < (a[1] & m) else 0
        raise ValueError(f"expr op {op}")

    def cond(self, c):
        w = c["w"]
        m = (1 << (8 * w)) - 1
        a, b = self.e(c["a"]) & m, self.e(c["b"]) & m
        sa = a - (1 << (8 * w)) if a >> (8 * w - 1) else a
        sb = b - (1 << (8 * w)) if b >> (8 * w - 1) else b
        return {"eq": a == b, "ne": a != b, "ult": a < b, "ule": a <= b, "ugt": a > b, "uge": a >= b,
                "slt": sa < sb, "sle": sa <= sb, "sgt": sa > sb, "sge": sa >= sb}[c["cmp"]]

    # ops
    def op(self, o):
        k = o["op"]
        E = self.e
        if k == "reg" and isinstance(o["val"], list) and o["val"][0] == "unknown":
            self.regs[o["r"]] = "UNDEF"
        elif k == "reg":
            self.regs[o["r"]] = E(o["val"]) & 0xFFFF if o["r"] in REGS or o["r"] in ("fa", "fb", "cf") or o["r"].startswith("t_") else E(o["val"])
        elif k == "set":
            self.wr(self.var_addr(o["var"]), o["w"], E(o["val"]))
        elif k == "store":
            self.wr(E(o["addr"]), o["w"], E(o["val"]))
        elif k == "score":
            a, w = self.ev_addr("score")
            self.wr(a, 4, self.rd(a, 4) + E(o["add"]))
        elif k == "lamp":
            self.mem[(self.lamp0 + E(o["slot"])) & 0xFFFF] = E(o["state"]) & 0xFF
        elif k == "lamps":
            self.wr(self.lamp0 + o["slot"], 2, E(o["states16"]))
        elif k == "ball":
            vals = {f: E(v) for f, v in o["set"].items()}
            for f, v in vals.items():
                a, w = self.ev_addr("ball." + f)
                self.wr(a, w, v)
        elif k == "ball_slot":
            vals = {f: E(v) for f, v in o["set"].items()}
            for f, v in vals.items():
                base = self.ev["ball_slots." + f]
                self.wr(int(base["addr"], 16) + 2 * o["slot"], base["size"], v)
        elif k == "ball_commit":
            a, w = self.ev_addr("ball.writeback")
            self.wr(a, w, E(o["val"]))
        elif k == "layer":
            a, w = self.ev_addr("ball.layer")
            self.wr(a, w, E(o["val"]))
        elif k in ("sound", "sound_rate", "sound_now", "lockout", "cooldown", "extra_gravity"):
            role = {"sound": "sound.queue", "sound_rate": "sound.rate", "sound_now": "sound.now", "lockout": "sensor_lockout",
                    "cooldown": "sensor_cooldown", "extra_gravity": "extra_gravity"}[k]
            v = o.get("id", o.get("hz", o.get("frames")))
            a, w = self.ev_addr(role)
            self.wr(a, w, E(v))
        elif k == "sound_sweep_start":
            d = o["sweep"]
            for key, v in o.items():
                if key in ("op", "sweep"):
                    continue
                role = f"sound.sweep@{d}" if key == "active" else f"sound.sweep@{d}.{key}"
                a, w = self.ev_addr(role)
                self.wr(a, w, E(v))
        elif k == "pixels":
            v = E(o["val"]) & 0xFF
            for x, y in o.get("xy", []):
                self.pf[y * 320 + x] = v
            if "outside_playfield" in o:
                self.events.append(("outside_write", o["outside_playfield"]["offset"], v))
            if "offset" in o:
                off = E(o["offset"]) & 0xFFFF
                self.pf[o["half"] * 64000 + off] = v
        elif k == "gate":
            g = next(g for g in self.r["gates"] if g["id"] == o["gate"])
            ctl = self.mem[int(g["control_var"], 16)]
            v = g["value_if_control_zero"] if ctl == 0 else g["value_if_control_nonzero"]
            for x, y in g["pixels"]:
                self.pf[y * 320 + x] = v
        elif k in ("message", "text"):
            self.events.append((k, E(o["msg"]) & 0xFFFF, o["pos"]["raw"] if isinstance(o["pos"], dict) else E(o["pos"]) & 0xFFFF) + ((E(o["mode"]) & 0xFFFF,) if k == "message" and "mode" in o else ()))
        elif k == "number_text":
            self.events.append(("number", E(o["value"]) & 0xFFFFFFFF, E(o["buf"]) & 0xFFFF))
        elif k in ("score_refresh", "display"):
            self.events.append((k,))
        elif k == "push":
            try:
                self.stack.append(E(o["val"]) & 0xFFFF)
            except Unknown:
                self.stack.append("UNDEF")
        elif k == "pop":
            self.regs[o["r"]] = self.stack.pop()
        elif k == "push_all":
            self.stack.append(dict(self.regs))
        elif k == "pop_all":
            self.regs = self.stack.pop()
        elif k == "gosub":
            self.run(o["entry"])
        elif k == "call_hook":
            self.run(self.r["hooks"][o["hook"]]["entry"])
        else:
            raise ValueError(f"op {k}")

    def run(self, label):
        B = self.r["blocks"]
        while label != "@return" and label is not None:
            self.steps += 1
            if self.steps > 20000:
                raise RuntimeError("IR loop")
            b = B[label]
            self.visited.add(label)
            for o in b["ops"]:
                self.op(o)
            e = b["end"]
            if "if" in e:
                label = e["then"] if self.cond(e["if"]) else e["else"]
            elif "goto" in e:
                label = e["goto"]
            else:
                label = None



# ---------------------------------------------------------------------------
class X86:
    """One Unicorn instance per table; each run rewrites DS, the playfield chain and the key bytes."""
    SENT = 0xFFF0

    def __init__(self, n, rules):
        self.exe = epexe.load(os.path.join(ROOT, "original", f"EP{n}.EXE"))
        self.cs = self.exe.entry_cs
        self.ds = epexe.data_segment(self.exe)
        self.top = epexe.find_playfield_segments(self.exe)[0]
        self.img = bytes(self.exe.data[self.exe.header_size:])
        self.stubs = {}
        self.uc = Uc(UC_ARCH_X86, UC_MODE_16)
        self.uc.mem_map(0, 0x110000)
        self.uc.mem_write(0, self.img[:0x100000])
        self.events = []
        self.uc.hook_add(UC_HOOK_CODE, self._hook)
        self.stops = ()

    def _hook(self, uc, addr, size, _):
        ip = addr - self.cs * 16
        if ip in self.stops:
            uc.emu_stop()
            return
        if ip in self.stubs:
            kind, far = self.stubs[ip]
            bx, di, ax, dx = (uc.reg_read(r) for r in (UC_X86_REG_BX, UC_X86_REG_DI, UC_X86_REG_AX, UC_X86_REG_DX))
            if kind == "message":
                self.events.append((kind, bx, di, ax))
            elif kind == "text":
                self.events.append((kind, bx, di))
            elif kind == "number":
                self.events.append(("number", (dx << 16) | ax, bx))
            else:
                self.events.append((kind,))
            s = uc.reg_read(UC_X86_REG_SP)
            base = uc.reg_read(UC_X86_REG_SS) * 16
            ret = struct.unpack("<H", uc.mem_read(base + s, 2))[0]
            s += 2
            if far:
                cs_ = struct.unpack("<H", uc.mem_read(base + s, 2))[0]
                s += 2
                uc.reg_write(UC_X86_REG_CS, cs_)
            uc.reg_write(UC_X86_REG_SP, s)
            uc.reg_write(UC_X86_REG_IP, ret)

    def run(self, entry, mem, pf, regs, cs_patch=(), es_val=0x7000, es_bytes=None, stops=()):
        uc = self.uc
        uc.mem_write(self.ds * 16, bytes(mem))
        uc.mem_write(self.top * 16, bytes(pf[:64000]))
        uc.mem_write((self.top + 0xFA0) * 16, bytes(pf[64000:128000]))
        uc.mem_write((self.top + 0x1F40) * 16, bytes(pf[128000:]))
        for a, v in cs_patch:
            uc.mem_write(self.cs * 16 + a, bytes([v]))
        if es_bytes is not None:
            uc.mem_write(es_val * 16, es_bytes)
        uc.ctl_flush_tb()
        ss, sp = 0x9000, 0xFF00
        uc.reg_write(UC_X86_REG_SS, ss)
        uc.reg_write(UC_X86_REG_DS, self.ds)
        uc.reg_write(UC_X86_REG_ES, es_val)
        uc.reg_write(UC_X86_REG_CS, self.cs)
        uc.reg_write(UC_X86_REG_FLAGS, 0x0002)
        for r, u in REGS.items():
            uc.reg_write(u, regs.get(r, 0))

        def push(v):
            nonlocal sp
            sp -= 2
            uc.mem_write(ss * 16 + sp, struct.pack("<H", v & 0xFFFF))
        push(self.SENT)
        if regs.get("_dispatch_frame"):
            push(es_val)
            for v in [regs.get("ax", 0), regs.get("cx", 0), regs.get("dx", 0), regs.get("bx", 0), sp, regs.get("bp", 0),
                      regs.get("si", 0), regs.get("di", 0)]:
                push(v)
        uc.reg_write(UC_X86_REG_SP, sp)
        self.events = []
        self.stops = set(stops)
        uc.emu_start(self.cs * 16 + entry, self.cs * 16 + self.SENT, count=5_000_000)
        ip = uc.reg_read(UC_X86_REG_IP)
        cs_ = uc.reg_read(UC_X86_REG_CS)
        if not (cs_ == self.cs and (ip == self.SENT or ip in self.stops)):
            raise UcError(0) if False else RuntimeError(f"x86 did not return (stopped at {cs_:04x}:{ip:04x})")
        ds_out = bytearray(uc.mem_read(self.ds * 16, len(mem)))
        pf_out = bytearray(uc.mem_read(self.top * 16, 64000)) + bytearray(uc.mem_read((self.top + 0xFA0) * 16, 64000)) \
            + bytearray(uc.mem_read((self.top + 0x1F40) * 16, len(pf) - 128000))
        for a, v in cs_patch:                       # restore the key bytes
            uc.mem_write(self.cs * 16 + a, self.img[self.cs * 16 + a:self.cs * 16 + a + 1])
        return ds_out, pf_out, list(self.events)


# ---------------------------------------------------------------------------
def graph(rules, entry):
    """Reachable labels from entry (following gosubs) and predecessor edges {label: [(pred, cond, taken)]}."""
    B = rules["blocks"]
    seen, work, preds = set(), [entry], {}
    while work:
        l = work.pop()
        if l in seen or l not in B:
            continue
        seen.add(l)
        e = B[l]["end"]
        if "if" in e:
            for k, taken in (("then", True), ("else", False)):
                preds.setdefault(e[k], []).append((l, e["if"], taken))
                work.append(e[k])
        elif "goto" in e:
            preds.setdefault(e["goto"], []).append((l, None, None))
            work.append(e["goto"])
        for o in B[l]["ops"]:
            if o["op"] == "gosub":
                preds.setdefault(o["entry"], []).append((l, None, None))
                work.append(o["entry"])
            elif o["op"] == "call_hook" and o["hook"] in rules["hooks"]:
                t = rules["hooks"][o["hook"]]["entry"]
                preds.setdefault(t, []).append((l, None, None))
                work.append(t)
    return seen, preds


def consts_in(rules, entry):
    B = rules["blocks"]
    reach, _ = graph(rules, entry)
    cs = set()
    for l in reach:
        e = B[l]["end"]
        if "if" in e and isinstance(e["if"]["b"], int):
            cs.add(e["if"]["b"])
    return sorted(cs)


def path_to(preds, entry, target, rng, limit=40):
    """A random predecessor walk from target back to entry: [(pred, cond, taken)] in entry->target order."""
    path, cur, seen = [], target, {target}
    for _ in range(limit):
        if cur == entry:
            return list(reversed(path))
        ps = [p for p in preds.get(cur, []) if p[0] not in seen]
        if not ps:
            return None
        p = rng.choice(ps)
        path.append(p)
        seen.add(p[0])
        cur = p[0]
    return None


def solve(cond, taken):
    """(lvalue expr, value) making `cond` evaluate to `taken`, or None."""
    a, b, c = cond["a"], cond["b"], cond["cmp"]
    if not isinstance(b, int):
        if isinstance(a, int):
            a, b = b, a
            c = {"ult": "ugt", "ugt": "ult", "ule": "uge", "uge": "ule", "slt": "sgt", "sgt": "slt",
                 "sle": "sge", "sge": "sle"}.get(c, c)
        else:
            return None
    if not taken:
        c = {"eq": "ne", "ne": "eq", "ult": "uge", "uge": "ult", "ule": "ugt", "ugt": "ule",
             "slt": "sge", "sge": "slt", "sle": "sgt", "sgt": "sle"}[c]
    v = {"eq": b, "ne": b + 1, "ult": b - 1, "ule": b, "ugt": b + 1, "uge": b, "slt": b - 1, "sle": b, "sgt": b + 1, "sge": b}[c]
    # peel simple wrappers
    for _ in range(4):
        if isinstance(a, list) and a[0] in ("and",) and isinstance(a[2], int):
            a = a[1]
        elif isinstance(a, list) and a[0] == "add" and isinstance(a[2], int):
            v, a = v - a[2], a[1]
        elif isinstance(a, list) and a[0] == "sub" and isinstance(a[2], int):
            v, a = v + a[2], a[1]
        elif isinstance(a, list) and a[0] in ("lo", "lo16", "sext8"):
            a = a[1]
        else:
            break
    if isinstance(a, list) and a[0] in ("var", "mem", "ball", "ball_slot", "lamp", "input") and \
            (a[0] != "mem" or isinstance(a[2], int)) and (a[0] != "lamp" or isinstance(a[1], int)):
        return a, v
    return None


def _subst(e, env):
    if isinstance(e, list):
        if e[0] == "reg":
            return env.get(("reg", e[1]), e)
        if e[0] == "var":
            return env.get(("var", e[1]), e)
        if e[0] == "mem" and isinstance(e[2], int):
            return env.get(("mem", e[2]), e)
        if e[0] == "ball":
            return env.get(("ball", e[1]), e)
        if e[0] == "lamp" and isinstance(e[1], int):
            return env.get(("lamp", e[1]), e)
        return [e[0]] + [_subst(x, env) for x in e[1:]]
    return e


_CF = {"add": lambda a, b: (a + b) & 0xFFFF, "sub": lambda a, b: (a - b) & 0xFFFF, "and": lambda a, b: a & b,
       "or": lambda a, b: a | b, "xor": lambda a, b: a ^ b, "mul": lambda a, b: (a * b) & 0xFFFF,
       "shl": lambda a, b: (a << b) & 0xFFFF, "shr": lambda a, b: (a & 0xFFFF) >> b}


def _fold(e):
    """Constant folding, and add/sub chains merged so solve() can peel them: add(add(x,1),1) -> add(x,2)."""
    if not isinstance(e, list):
        return e
    e = [e[0]] + [_fold(x) for x in e[1:]]
    if e[0] in _CF and len(e) == 3 and isinstance(e[1], int) and isinstance(e[2], int):
        return _CF[e[0]](e[1], e[2])
    if e[0] in ("lo", "hi") and isinstance(e[1], int):
        return e[1] & 0xFF if e[0] == "lo" else (e[1] >> 8) & 0xFF
    if e[0] == "add" and isinstance(e[1], int) and not isinstance(e[2], int):
        e = ["add", e[2], e[1]]
    if e[0] == "add" and e[2] == 0:
        return e[1]
    if e[0] == "mem" and isinstance(e[2], list):
        return e
    if e[0] in ("add", "sub") and isinstance(e[2], int) and isinstance(e[1], list) and e[1][0] in ("add", "sub") \
            and isinstance(e[1][2], int):
        k = (e[2] if e[0] == "add" else -e[2]) + (e[1][2] if e[1][0] == "add" else -e[1][2])
        return ["add", e[1][1], k]
    if e[0] == "sub" and isinstance(e[2], int):
        return ["add", e[1], -e[2]]
    return e


def path_constraints(rules, path):
    """Branch conditions along `path`, rewritten over the initial state by symbolic execution of the
    reg/set/store/lamp/ball ops of every block on the way."""
    B = rules["blocks"]
    env, out = {}, []
    for pred, cond, taken in path:
        for o in B[pred]["ops"]:
            k = o["op"]
            if k == "reg":
                env[("reg", o["r"])] = _subst(o["val"], env)
            elif k == "set":
                env[("var", o["var"])] = _subst(o["val"], env)
            elif k == "store" and isinstance(o["addr"], int):
                env[("mem", o["addr"])] = _subst(o["val"], env)
            elif k == "lamp" and isinstance(o["slot"], int):
                env[("lamp", o["slot"])] = _subst(o["state"], env)
            elif k == "ball":
                for f, v in o["set"].items():
                    env[("ball", f)] = _subst(v, env)
            elif k in ("gosub", "call_hook", "pop_all", "pop"):
                for key in [x for x in env if x[0] == "reg"]:
                    del env[key]
        if cond is not None:
            c = dict(cond)
            c["a"], c["b"] = _fold(_subst(c["a"], env)), _fold(_subst(c["b"], env))
            out.append((c, taken))
    return out


class Verifier:
    def __init__(self, n, fullseg=True, seed=1234):
        self.n = n
        self.rules = json.load(open(os.path.join(ROOT, "extracted", "tables", f"EP{n}", "rules.json")))
        R = self.rules
        self.x86 = X86(n, R)
        x86 = self.x86
        self.code = x86.img[x86.cs * 16:x86.cs * 16 + 0x10000]
        self.ds_init = bytearray(x86.img[x86.ds * 16: x86.ds * 16 + R["memory"]["data_segment_size"]])
        cb = np.load(os.path.join(ROOT, "extracted", "tables", f"EP{n}", "collision_idx.npy")).reshape(-1)
        self.pf0 = bytearray(cb.tobytes()) + bytearray(2048)
        col = json.load(open(os.path.join(ROOT, "extracted", "tables", f"EP{n}", "collision.json")))
        struct.pack_into("<H", self.ds_init, int(col["collision_buffer"]["top_seg_var"], 16), x86.top)
        struct.pack_into("<H", self.ds_init, int(col["collision_buffer"]["bottom_seg_var"], 16), x86.top + 0xFA0)
        for ip_s, role in R.get("stub_routines", {}).items():
            x86.stubs[int(ip_s, 16)] = tuple(role)
        self.fullseg = fullseg
        self.rng = random.Random(seed)
        self.varlist = list(R["vars"].values())
        self.ev = R["engine_vars"]
        try:
            import discover
            csv = discover.load_config(n)["cs_vars"]
            self.keys = {"flipper_left": csv.get("key_lflip"), "flipper_right": csv.get("key_rflip")}
        except Exception:  # noqa: BLE001
            self.keys = {"flipper_left": 0x28D, "flipper_right": 0x28F} if n == 1 else {}
        self.keys = {k: v for k, v in self.keys.items() if v is not None}

    # -- state -------------------------------------------------------------------------------------
    def rand_state(self, entry, regions):
        rng, ev = self.rng, self.ev
        ds = bytearray(self.ds_init)
        cs = consts_in(self.rules, entry)
        for v in self.varlist + [e for k, e in ev.items() if not k.startswith("ball_slots") and k != "score"]:
            a, w = int(v["addr"], 16), v["size"]
            if w > 2 and rng.random() < 0.5:
                continue
            r = rng.random()
            if r < 0.35 and cs:
                val = rng.choice(cs) + rng.choice((0, 0, 0, 1, -1))
            elif r < 0.7:
                val = rng.randrange(0, 12)
            elif r < 0.85:
                val = int.from_bytes(self.ds_init[a:a + w], "little")
            else:
                val = rng.randrange(0, 1 << (8 * min(w, 2)))
            ds[a:a + w] = (val & ((1 << (8 * w)) - 1)).to_bytes(w, "little")
        if regions:
            x0, y0, x1, y1 = rng.choice(regions)["bbox"]
            bx_, by_ = rng.randint(max(0, x0 - 14), x1), rng.randint(max(0, y0 - 13), y1)
        else:
            bx_, by_ = rng.randrange(0, 300), rng.randrange(0, 390)
        for f, val in (("x", bx_), ("y", by_), ("vx", rng.randrange(-400, 400)), ("vy", rng.randrange(-400, 400))):
            if "ball." + f in ev:
                a = int(ev["ball." + f]["addr"], 16)
                ds[a:a + 2] = (val & 0xFFFF).to_bytes(2, "little")
        for f, val in (("x", bx_), ("y", by_)):
            a = int(ev["ball_slots." + f]["addr"], 16)
            ds[a:a + 2] = val.to_bytes(2, "little")
        return ds

    def apply(self, ds, inputs, lv, val):
        R, ev = self.rules, self.ev
        k = lv[0]
        if k == "var":
            v = R["vars"].get(lv[1]) or ev.get(lv[1])
            if v is None and lv[1].endswith(".hi"):
                base = R["vars"].get(lv[1][:-3]) or ev.get(lv[1][:-3])
                a, w = int(base["addr"], 16) + 2, lv[2]
            elif v is None:
                return
            else:
                a, w = int(v["addr"], 16), lv[2]
        elif k == "mem":
            a, w = lv[2], lv[1]
        elif k == "ball":
            a, w = int(ev["ball." + lv[1]]["addr"], 16), 2
        elif k == "ball_slot":
            b = ev["ball_slots." + lv[2]]
            a, w = int(b["addr"], 16) + 2 * lv[1], b["size"]
        elif k == "lamp":
            a, w = int(R["memory"]["lamps"]["first"], 16) + lv[1], 1
        elif k == "input":
            inputs[lv[1]] = 1 if val else 0
            return
        else:
            return
        if a + w <= len(ds):
            ds[a:a + w] = (val & ((1 << (8 * w)) - 1)).to_bytes(w, "little")

    # -- one comparison ----------------------------------------------------------------------------
    def compare(self, name, entry, kind, stops, ds, regs, inputs):
        """Returns ('ok'|'fail'|'undefined'|'skipped', detail, visited labels)."""
        R, x86 = self.rules, self.x86
        es_bytes = None
        if name == "kicker":
            regs["bx"] = 0x100
            es_bytes = bytes([0] * 0x100 + [inputs["contact_colour"]] + [0] * 0xF)
        code_b = bytearray(self.code)
        patch = []
        for k, a in self.keys.items():
            code_b[a] = inputs[k]
            patch.append((a, inputs[k]))
        pf = bytearray(self.pf0)
        mem = bytearray(ds)
        if self.fullseg:
            lin = x86.ds * 16 + len(ds)
            top = x86.top * 16
            tail = bytearray(x86.img[lin:x86.ds * 16 + 0x10000])
            o0, o1 = max(lin, top), min(lin + len(tail), top + 128000)
            if o0 < o1:                              # the part of the DS window that is the playfield image
                tail[o0 - lin:o1 - lin] = pf[o0 - top:o1 - top]
            mem += tail
        mem0 = bytes(mem)                            # the IR mutates `mem` in place
        ir = IR(R, bytes(code_b), mem, bytearray(pf), inputs)
        ir.regs = {r: v for r, v in regs.items() if r in REGS}
        try:
            ir.run(entry)
        except Unknown as ex:
            return "undefined", str(ex), ir.visited
        except RuntimeError as ex:
            return "skipped", f"IR: {ex}", ir.visited
        except (KeyError, IndexError, ZeroDivisionError, ValueError, TypeError) as ex:
            return "skipped", f"IR error {type(ex).__name__}: {ex}", ir.visited
        ip = int(entry[1:], 16)
        try:
            ds2, pf2, ev2 = x86.run(ip, ds, pf, regs, cs_patch=patch, es_bytes=es_bytes, es_val=0x7000, stops=stops)
        except (UcError, RuntimeError) as ex:
            return "skipped", f"unicorn: {ex}", ir.visited
        ev1 = [e for e in ir.events if e[0] != "outside_write"]
        ev1 = [e if e[0] != "message" or len(e) > 3 else e + (None,) for e in ev1]
        ev2 = [e if e[0] != "message" else (e[:3] + (e[3],) if any(len(x) > 3 for x in ev1 if x[0] == "message") else e[:3])
               for e in ev2]
        if self.fullseg:
            # the IR's tail models the playfield image seen through DS: fold it back before comparing
            lin = x86.ds * 16 + len(ds)
            top = x86.top * 16
            irpf = bytearray(ir.pf)
            o0, o1 = max(lin, top), min(lin + len(ir.mem) - len(ds), top + 128000)
            if o0 < o1:
                new = np.frombuffer(bytes(ir.mem[len(ds) + o0 - lin:len(ds) + o1 - lin]), np.uint8)
                old = np.frombuffer(mem0[len(ds) + o0 - lin:len(ds) + o1 - lin], np.uint8)
                ch = np.nonzero(new != old)[0]
                for k in ch:
                    irpf[o0 - top + int(k)] = int(new[k])
        else:
            irpf = ir.pf
        irm = ir.mem[:len(ds2)]
        dd = [] if ds2 == irm else [int(a) for a in np.nonzero(np.frombuffer(bytes(ds2), np.uint8) != np.frombuffer(bytes(irm), np.uint8))[0]]
        dp = [] if pf2[:128000] == irpf[:128000] else \
            [int(a) for a in np.nonzero(np.frombuffer(bytes(pf2[:128000]), np.uint8) != np.frombuffer(bytes(irpf[:128000]), np.uint8))[0]]
        if not dd and not dp and ev1 == ev2:
            return "ok", None, ir.visited
        k = next((j for j in range(min(len(ev1), len(ev2))) if ev1[j] != ev2[j]), min(len(ev1), len(ev2)))
        return "fail", (f"ds diffs {[hex(a) for a in dd[:8]]} (x86 {[ds2[a] for a in dd[:8]]} ir {[irm[a] for a in dd[:8]]}) "
                        f"pf diffs {len(dp)} {[(a % 320, a // 320, pf2[a], irpf[a]) for a in dp[:3]]} "
                        f"events ({len(ev2)} x86, {len(ev1)} ir) first difference #{k}: x86 {ev2[k:k + 2]} ir {ev1[k:k + 2]}"), ir.visited

    def fresh(self, kind, name, ip, colour):
        rng = self.rng
        regs = {r: rng.randrange(0, 0x10000) for r in REGS}
        if colour is not None:
            regs["ax"] = colour
        if kind == "handler" or name == "dispatch_tail":
            regs["bx"] = ip
            regs["_dispatch_frame"] = True
        else:
            regs["di"] = 0
        inputs = {"flipper_left": rng.randrange(2), "flipper_right": rng.randrange(2),
                  "contact_colour": rng.choice((0xCF, 0xD0, 0xD1, 0xD2))}
        return regs, inputs

    def targets(self, only=None):
        R = self.rules
        out = []
        for name, hd in R["handlers"].items():
            colours = [int(c, 16) for c in hd["colours"]] or [None]
            regs_ = []
            for s in R["sensors"]:
                if s["handler"] == name:
                    regs_ += s["regions"]
            out.append((name, hd["entry"], colours, regs_, "handler", ()))
        for name, hk in R["hooks"].items():
            out.append((name, hk["entry"], [None], [], "hook", tuple(int(x, 16) for x in hk["stops"])))
        return [t for t in out if not only or t[0] == only]

    def run(self, trials=300, directed=3, only=None, log=print):
        R = self.rules
        res = {"table": self.n, "targets": {}, "fail": 0, "trials": 0, "directed_cases": 0}
        all_reach, all_cov = set(), set()
        for name, entry, colours, regions, kind, stops in self.targets(only):
            ip = int(entry[1:], 16)
            reach, preds = graph(R, entry)
            cnt = {"ok": 0, "fail": 0, "undefined": 0, "skipped": 0}
            first = None
            cov = set()
            for _ in range(trials):
                ds = self.rand_state(entry, regions)
                regs, inputs = self.fresh(kind, name, ip, self.rng.choice(colours))
                st, det, vis = self.compare(name, entry, kind, stops, ds, regs, inputs)
                cnt[st] += 1
                cov |= vis
                if st == "fail" and first is None:
                    first = det
            rnd_cov = set(cov)
            dcnt = {"ok": 0, "fail": 0, "undefined": 0, "skipped": 0, "cases": 0, "unreached": 0}
            if directed:
                for target in sorted(reach - cov):
                    if target in cov:
                        continue
                    hit = False
                    for attempt in range(24):
                        path = path_to(preds, entry, target, self.rng)
                        if path is None:
                            break
                        cons = [solve(c, tk) for c, tk in path_constraints(R, path)]
                        cons = [c for c in cons if c]
                        for jitter, fill in ((0, 0), (1, 0), (-1, 0), (0, 1), (0, 2), (2, 0), (-2, 0), (1, 1), (1, 2)):
                            ds = self.rand_state(entry, regions)
                            regs, inputs = self.fresh(kind, name, ip, self.rng.choice(colours))
                            for lv, v in cons:
                                vv = v + (jitter if lv[0] != "input" else 0)
                                self.apply(ds, inputs, lv, vv)
                                if fill and lv[0] == "mem":        # loops over arrays: the same value in the neighbours
                                    for k in range(1, 8):
                                        self.apply(ds, inputs, ["mem", lv[1], (lv[2] + fill * k) & 0xFFFF], vv)
                                        self.apply(ds, inputs, ["mem", lv[1], (lv[2] - fill * k) & 0xFFFF], vv)
                            ir = IR(R, bytes(self.code), bytearray(ds) + bytearray(0x10000 - len(ds)), bytearray(self.pf0), inputs)
                            ir.regs = {r: v for r, v in regs.items() if r in REGS}
                            try:
                                ir.run(entry)
                            except Exception:  # noqa: BLE001
                                pass
                            if target not in ir.visited:
                                continue
                            for _ in range(directed):
                                st, det, vis = self.compare(name, entry, kind, stops, bytearray(ds), dict(regs), dict(inputs))
                                dcnt[st] += 1
                                dcnt["cases"] += 1
                                cov |= vis
                                if st == "fail" and first is None:
                                    first = "directed " + str(det)
                            hit = True
                            break
                        if hit:
                            break
                    if not hit and target not in cov:
                        dcnt["unreached"] += 1
            all_reach |= reach
            all_cov |= cov
            res["targets"][name] = {"kind": kind, "random": cnt, "directed": dcnt, "blocks": len(reach),
                                    "covered_random": len(rnd_cov & reach), "covered": len(cov & reach), "first_fail": first,
                                    "never": sorted(reach - cov)}
            res["fail"] += cnt["fail"] + dcnt["fail"]
            res["trials"] += trials
            res["directed_cases"] += dcnt["cases"]
            log(f"  {kind:7} {name:26} random ok {cnt['ok']:4} fail {cnt['fail']:3} undef {cnt['undefined']:3} skip {cnt['skipped']:3} | "
                f"directed {dcnt['cases']:4} fail {dcnt['fail']:3} | blocks {len(cov & reach)}/{len(reach)} (random {len(rnd_cov & reach)})"
                + (f"\n      first failure: {first}" if first else ""))
        res["blocks_total"] = len(all_reach)
        res["blocks_covered"] = len(all_cov & all_reach)
        res["blocks_in_file"] = len(R["blocks"])
        return res


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__)
    ap.add_argument("tables", nargs="*", type=int)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--trials", type=int, default=300)
    ap.add_argument("--directed", type=int, default=3, help="trials per directed state (0 = no directed phase)")
    ap.add_argument("--only", help="one handler/hook name")
    ap.add_argument("--no-fullseg", action="store_true")
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--json", help="write per-table results here")
    a = ap.parse_args()
    tables = list(range(1, 14)) if a.all else a.tables or [1]
    out, bad = [], 0
    for n in tables:
        t0 = time.time()
        print(f"EP{n}:")
        v = Verifier(n, fullseg=not a.no_fullseg, seed=a.seed)
        r = v.run(a.trials, a.directed, a.only)
        r["seconds"] = round(time.time() - t0, 1)
        print(f"EP{n}: {len(r['targets'])} targets, {r['trials']} random trials + {r['directed_cases']} directed, "
              f"{r['fail']} failures; blocks covered {r['blocks_covered']}/{r['blocks_total']} reachable "
              f"({r['blocks_in_file']} in file); {r['seconds']} s")
        bad += r["fail"]
        out.append(r)
    if a.json:
        os.makedirs(os.path.dirname(os.path.abspath(a.json)), exist_ok=True)
        json.dump(out, open(a.json, "w"), indent=1)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
