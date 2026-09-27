"""Extract collision / table-geometry data from Epic Pinball table EXEs.

Usage:  .venv/bin/python tools/collision.py [original_dir] [out_dir]

Key finding (see docs/formats/collision.md): there is NO separate collision
map.  The engine collides the ball against the *palette indices of the
playfield bitmap itself* (the in-memory 320x400 copy that lives in the
relocated playfield segments).  Artists painted walls, bumpers, ramp rails,
sensors etc. with reserved palette ranges; the per-table code decides what
each index means.  This tool locates that code in every EPn.EXE, evaluates
the comparison chains symbolically for all 256 index values, and writes:

  extracted/tables/EPn/collision_idx.npy   400x320 uint8: the collision buffer
                                           (= playfield after the engine's
                                           start-up index substitution)
  extracted/tables/EPn/collision.npy       (2,400,320) uint8 per-level class
                                           map (level 0 = table, 1 = ramp)
  extracted/tables/EPn/collision.json      all LUTs, ball ring, normal table,
                                           flipper outlines, trigger dispatch
  extracted/tables/EPn/collision.png       visualisation (level 0 | level 1)
  extracted/tables/EPn/ball.png            ball sprite (defines ring size)

Class codes in collision.npy / wall_lut:
  0 empty  1 wall  2 conditional wall (hit on some code paths only)
  3 active wall (hit + table-specific handler call: bumpers, slingshots)
  4 active, non-blocking/conditional  5 flipper (hit + flipper-contact flag)
"""
import json
import os
import re
import struct
import sys

import numpy as np
from PIL import Image
from capstone import CS_ARCH_X86, CS_MODE_16, Cs
from capstone.x86 import X86_OP_IMM, X86_OP_MEM, X86_OP_REG

sys.path.insert(0, os.path.dirname(__file__))
import epexe  # noqa: E402

W, H = 320, 400
EMPTY, WALL, WALL_COND, ACTIVE, ACTIVE_COND, FLIPPER = range(6)
CLASS_NAMES = ["empty", "wall", "wall_conditional", "active", "active_conditional", "flipper"]
OCC_BEHIND, OCC_OVER, OCC_SENSOR, OCC_SENSOR_COND = range(4)
OCC_NAMES = ["ball_in_front", "occludes_ball", "sensor", "sensor_conditional"]

R8 = ["al", "ah", "bl", "bh", "cl", "ch", "dl", "dh"]
R16 = {"ax": ("al", "ah"), "bx": ("bl", "bh"), "cx": ("cl", "ch"), "dx": ("dl", "dh")}


class Code:
    """Lazy 16-bit disassembler over one code segment of a table EXE."""

    def __init__(self, exe, seg):
        self.exe = exe
        self.base = exe.image_off(seg)
        self.md = Cs(CS_ARCH_X86, CS_MODE_16)
        self.md.detail = True
        self.cache = {}

    def at(self, ip):
        if ip not in self.cache:
            buf = self.exe.data[self.base + ip : self.base + ip + 16]
            ins = next(self.md.disasm(buf, ip), None)
            self.cache[ip] = ins
        return self.cache[ip]

    def linear(self, ip, n):
        out = []
        for _ in range(n):
            ins = self.at(ip)
            if ins is None:
                break
            out.append(ins)
            ip += ins.size
        return out

    def find(self, pattern):
        """Regex over the code segment; yields (ip, match)."""
        seg = self.exe.data[self.base :]
        for m in re.finditer(pattern, seg, re.S):
            yield m.start(), m


# --------------------------------------------------------------------------
# Tiny symbolic interpreter: enough x86 to walk the pixel-classification
# chains (cmp / jcc / mov r8 / call / mov byte [m],imm).  Unknown comparisons
# fork.  Each path ends at a named terminal address, a ret, or a step limit.
# --------------------------------------------------------------------------

JCC = {
    "jb": lambda f: f["cf"], "jc": lambda f: f["cf"], "jnae": lambda f: f["cf"],
    "jae": lambda f: not f["cf"], "jnb": lambda f: not f["cf"], "jnc": lambda f: not f["cf"],
    "je": lambda f: f["zf"], "jz": lambda f: f["zf"],
    "jne": lambda f: not f["zf"], "jnz": lambda f: not f["zf"],
    "jbe": lambda f: f["cf"] or f["zf"], "jna": lambda f: f["cf"] or f["zf"],
    "ja": lambda f: not (f["cf"] or f["zf"]), "jnbe": lambda f: not (f["cf"] or f["zf"]),
    "jl": lambda f: f["lt"], "jnge": lambda f: f["lt"],
    "jge": lambda f: not f["lt"], "jnl": lambda f: not f["lt"],
    "jle": lambda f: f["lt"] or f["zf"], "jng": lambda f: f["lt"] or f["zf"],
    "jg": lambda f: not (f["lt"] or f["zf"]), "jnle": lambda f: not (f["lt"] or f["zf"]),
}


def _flags(a, b, bits):
    mask = (1 << bits) - 1
    a &= mask
    b &= mask
    sa = a - (1 << bits) if a >> (bits - 1) else a
    sb = b - (1 << bits) if b >> (bits - 1) else b
    return {"cf": a < b, "zf": a == b, "lt": sa < sb}


def symrun(code, start, regs, pixel, known_mem, terminals, max_steps=300):
    """Explore all paths from `start`.

    regs: dict r8 -> int|None.  pixel: value of any byte read through ES.
    known_mem: {disp: byte} for DS memory with known contents (e.g. level flag).
    terminals: {ip: name}.  Returns set of (terminal_name, events_tuple).
    """
    results = set()
    stack = [(start, dict(regs), None, (), 0)]
    while stack:
        ip, r, flags, events, steps = stack.pop()
        while True:
            if ip in terminals:
                results.add((terminals[ip], events))
                break
            if steps > max_steps:
                results.add(("LOST", events))
                break
            ins = code.at(ip)
            if ins is None:
                results.add(("BADCODE", events))
                break
            steps += 1
            m, ops, nxt = ins.mnemonic, ins.operands, ip + ins.size

            def val(op):
                if op.type == X86_OP_REG:
                    name = ins.reg_name(op.reg)
                    if name in R8:
                        return r.get(name)
                    if name in R16:
                        lo, hi = (r.get(x) for x in R16[name])
                        return None if lo is None or hi is None else lo | hi << 8
                    return None
                if op.type == X86_OP_IMM:
                    return op.imm & 0xFFFF
                if op.type == X86_OP_MEM:
                    mem = op.mem
                    if mem.segment and ins.reg_name(mem.segment) == "es" and op.size == 1:
                        return pixel
                    if op.size == 1 and mem.base == 0 and mem.index == 0 and mem.disp in known_mem:
                        return known_mem[mem.disp]
                    if op.size == 1 and mem.base and ins.reg_name(mem.base) == "di" and mem.disp in known_mem:
                        return known_mem[mem.disp]  # per-ball arrays [di+disp]
                    return None
                return None

            if m == "cmp":
                a, b = val(ops[0]), val(ops[1])
                flags = None if a is None or b is None else _flags(a, b, ops[0].size * 8)
                ip = nxt
                continue
            if m in JCC:
                tgt = ops[0].imm
                if flags is None:
                    stack.append((tgt, dict(r), None, events, steps))
                    ip = nxt
                else:
                    ip = tgt if JCC[m](flags) else nxt
                continue
            if m == "jmp":
                if ops[0].type == X86_OP_IMM:
                    ip = ops[0].imm
                    continue
                results.add(("INDIRECT", events))
                break
            if m in ("ret", "retf", "iret"):
                results.add(("RET", events))
                break
            if m in ("call", "lcall"):
                tgt = ops[-1].imm if ops and ops[-1].type == X86_OP_IMM else None
                events = events + (("call", tgt),)
                ip = nxt
                continue
            if m in ("loop", "jcxz"):
                stack.append((ops[0].imm, dict(r), None, events, steps))
                ip = nxt
                continue
            if m == "mov" and ops[0].type == X86_OP_MEM and ops[0].size == 1 and ops[1].type == X86_OP_IMM:
                mem = ops[0].mem
                if not (mem.segment and ins.reg_name(mem.segment) == "es"):
                    events = events + (("set", mem.disp, ops[1].imm & 0xFF),)
                ip = nxt
                continue
            if m == "mov" and ops[0].type == X86_OP_REG:
                name = ins.reg_name(ops[0].reg)
                v = val(ops[1])
                if name in R8:
                    r[name] = None if v is None else v & 0xFF
                elif name in R16:
                    lo, hi = R16[name]
                    r[lo] = None if v is None else v & 0xFF
                    r[hi] = None if v is None else (v >> 8) & 0xFF
                ip = nxt
                continue
            # anything else: invalidate written registers, keep flags only for
            # instructions that cannot touch them (push/pop/mov handled above)
            try:
                _, written = ins.regs_access()
            except Exception:
                written = []
            for reg in written:
                name = ins.reg_name(reg)
                if name in R8:
                    r[name] = None
                elif name in R16:
                    for x in R16[name]:
                        r[x] = None
            if m not in ("push", "pop", "nop", "cld", "std", "lea", "pushaw", "popaw", "pusha", "popa"):
                flags = None
            ip = nxt
    return results


# --------------------------------------------------------------------------
# Locating the relevant code in each table
# --------------------------------------------------------------------------


def s16(b):
    return struct.unpack("<h", b)[0]


def u16(b):
    return struct.unpack("<H", b)[0]


class Table:
    def __init__(self, n, src):
        self.n = n
        self.exe = epexe.load(os.path.join(src, f"EP{n}.EXE"))
        self.ds = epexe.data_segment(self.exe)
        self.segs = epexe.find_playfield_segments(self.exe)
        self.code = Code(self.exe, self.exe.entry_cs)
        self.notes = []

    def dsb(self, off, n=1):
        return self.exe.data[self.exe.image_off(self.ds, off) : self.exe.image_off(self.ds, off) + n]

    def dsw(self, off, n=1, signed=True):
        return list(struct.unpack(f"<{n}{'h' if signed else 'H'}", self.dsb(off, 2 * n)))

    def fo(self, ip):
        return self.code.base + ip

    # playfield segment pointer variables: lcall getter / mov [top],ax / add ax,0FA0h / mov [bot],ax
    def pf_ptrs(self):
        ip, m = next(self.code.find(rb"\x9a....\xa3(..)\x05\xa0\x0f\xa3(..)"))
        return {"top_var": u16(m.group(1)), "bottom_var": u16(m.group(2)), "code_ip": ip}

    def init_substitutions(self):
        """Start-up loops: for each byte of a playfield half, lo<=v<=hi -> repl."""
        out = []
        pat = rb"\xa1(..)\x8e\xc0\xb0(.)\xb4(.)\xb3(.)\x26\x38\x05\x72\x08\x26\x38\x25\x77\x03\x26\x88\x1d"
        for ip, m in self.code.find(pat):
            out.append({"code_ip": ip - 3, "seg_var": u16(m.group(1)), "lo": m.group(2)[0],
                        "hi": m.group(3)[0], "replace": m.group(4)[0]})
        return out

    def wall_loop(self):
        """Ball-vs-wall sampling loop (EP1 cs:1846..18c3)."""
        ip_add, m = next(self.code.find(rb"\x03\x9c(..)\x26\x38\x07"))
        ring_tab = u16(m.group(1))
        # walk back to 'mov si, 0060h'
        for back in range(4, 80):
            if self.exe.data[self.fo(ip_add - back) : self.fo(ip_add - back) + 3] == b"\xbe\x60\x00":
                start = ip_add - back
                break
        else:
            raise ValueError("wall loop: mov si,60h not found")
        # the row/column variables: 'mov bx,[di+X]' just before, and 'mov ax,[di+Y]; mov bx,14h; mul bx; add ax,[top]'
        pre = self.exe.data[self.fo(start) - 40 : self.fo(start)]
        mx = re.search(rb"\x8b\x9d(..)$", pre, re.S)
        my = re.search(rb"\x8b\x85(..)\xbb\x14\x00\xf7\xe3\x03\x06(..)\x8e\xc0", pre, re.S)
        ins = self.code.linear(start, 60)
        level_disp, hit, miss, sub_si = None, None, None, None
        setup_mem = []
        for i, x in enumerate(ins):
            if x.mnemonic == "cmp" and level_disp is None and x.operands[0].type == X86_OP_MEM \
                    and x.operands[1].type == X86_OP_IMM and x.operands[1].imm == 1:
                level_disp = x.operands[0].mem.disp
            if x.mnemonic == "mov" and x.operands[0].type == X86_OP_REG and x.operands[1].type == X86_OP_MEM \
                    and x.address < ip_add and x.operands[1].size == 1:
                setup_mem.append(x.operands[1].mem.disp)
            if x.mnemonic == "shr" and x.op_str == "si, 1" and hit is None:
                hit = x.address
            if x.mnemonic == "sub" and x.op_str == "si, 2":
                sub_si = x.address
                miss = ins[i - 1].address  # the 'pop bx' that ends every probe
                break
        if None in (level_disp, hit, miss):
            raise ValueError("wall loop structure not recognised")
        return {"start_ip": start, "sample_ip": ip_add, "hit_ip": hit, "miss_ip": miss,
                "ring_table": ring_tab, "level_var": level_disp, "setup_mem": setup_mem,
                "ball_x_var": u16(mx.group(1)) if mx else None,
                "ball_y_var": u16(my.group(1)) if my else None,
                "seg_var": u16(my.group(2)) if my else None}

    def ball_ring(self, ring_tab):
        offs = self.dsw(ring_tab + 2, 48)
        pts = []
        for o in offs:
            y, x = divmod(o, W)
            if x > W // 2:
                x -= W
                y += 1
            pts.append((x, y))
        # index k (1..48) is at ring_tab + 2k; list is stored k=1..48
        return offs, pts

    def occlusion_loop(self):
        """Ball background/overlap scan (EP1 cs:1679): copies ball sprite, then
        walks every pixel under the ball's bounding box."""
        ip, m = next(self.code.find(rb"\x8d\x3e(..)\xb9(..)\xf3\xa4"))
        buf, size = u16(m.group(1)), u16(m.group(2))
        pre = self.exe.data[self.fo(ip) - 4 : self.fo(ip)]
        sprite_table = None
        if pre[:2] == b"\x8d\x36":  # lea si,[sprite]
            sprite, ip = u16(pre[2:]), ip - 4
        elif pre[:2] == b"\x8b\xb7":  # mov si,[bx+table] -- several ball sprites (EP8)
            sprite_table = u16(pre[2:])
            sprite, ip = self.dsw(sprite_table, 1, signed=False)[0], ip - 4
        else:
            raise ValueError("ball sprite source not recognised")
        ins = self.code.linear(ip, 80)
        setup_mem = [x.operands[1].mem.disp for x in ins[:30]
                     if x.mnemonic == "mov" and x.operands and x.operands[0].type == X86_OP_REG
                     and ins[0].reg_name(x.operands[0].reg) in ("bl", "bh")
                     and x.operands[1].type == X86_OP_MEM]
        load, inc_di, level_disp = None, None, None
        for x in ins:
            if x.mnemonic == "cmp" and level_disp is None and x.operands[0].type == X86_OP_MEM \
                    and x.operands[1].type == X86_OP_IMM and x.operands[1].imm == 1 and x.operands[0].size == 1:
                level_disp = x.operands[0].mem.disp
            if x.mnemonic == "mov" and x.op_str == "al, byte ptr es:[di]" and load is None:
                load = x.address
            if load is not None and x.mnemonic == "inc" and x.op_str == "di":
                inc_di = x.address
                break
        store = None
        for x in ins:
            if load is not None and x.address > load and x.mnemonic == "mov" and x.op_str == "byte ptr [si], al":
                store = x.address
                break
        return {"start_ip": ip, "pixel_load_ip": load, "next_pixel_ip": inc_di, "store_ip": store,
                "level_var": level_disp, "ball_sprite": sprite, "ball_sprite_table": sprite_table,
                "sprite_copy": buf, "sprite_bytes": size, "setup_mem": setup_mem}

    def trigger_dispatch(self):
        ip, m = next(self.code.find(rb"\x81\xeb(..)\xd1\xe3\x2e\x8b\x9f(..)\xff\xe3"))
        first, tab = u16(m.group(1)), u16(m.group(2))
        n = 0x100 - first - 1  # values first..0xfe
        handlers = struct.unpack(f"<{n}H", self.exe.data[self.fo(tab) : self.fo(tab) + 2 * n])
        return {"dispatch_ip": ip, "first_value": first, "table_ip": tab, "handlers": list(handlers)}

    def normals(self):
        ip, m = next(self.code.find(rb"\x8b\x87(..)\xf7\xd8\xa3"))
        ntab = u16(m.group(1))
        ip2, m2 = next(self.code.find(rb"\xc1\xe3\x02\x8b\x87(..)\x29\x85(..)\x8b\x87(..)\x01\x85(..)"))
        ptab = u16(m2.group(1))
        normal = [tuple(self.dsw(ntab + 4 * i, 2)) for i in range(48)]
        push = [tuple(self.dsw(ptab + 4 * i, 2)) for i in range(48)]
        return {"normal_table": ntab, "normal_ip": ip, "pushout_table": ptab, "pushout_ip": ip2,
                "normal": normal, "pushout": push}

    def flippers(self, ptrs):
        pat = rb"\x8b\xb4(..)\xad\x8b\xc8\xb2(.)\xad\x8b\xf8(\x81\xc7..)?\x26\x88\x15"
        out = []
        for ip, m in self.code.find(pat):
            tab, val = u16(m.group(1)), m.group(2)[0]
            if val == 0x2A:
                continue  # erase pass
            base = u16(m.group(3)[2:]) if m.group(3) else 0
            # nearest preceding 'mov es,[var]'
            seg_var = None
            for back in range(3, 0x300):
                p = self.fo(ip) - back
                if self.exe.data[p : p + 2] == b"\x8e\x06":
                    seg_var = u16(self.exe.data[p + 2 : p + 4])
                    break
            half = {ptrs["top_var"]: 0, ptrs["bottom_var"]: 1}.get(seg_var)
            positions = []
            for k in range(10):
                pp = self.dsw(tab + 2 * k, 1, signed=False)[0]
                cnt = self.dsw(pp, 1, signed=False)[0]
                if cnt > 4000:
                    positions = None
                    break
                offs = self.dsw(pp + 2, cnt, signed=False)
                pix = []
                for o in offs:
                    a = (o + base) & 0xFFFF
                    y, x = divmod(a, W)
                    pix.append((x, y + 200 * (half or 0)))
                positions.append({"list_ptr": pp, "count": cnt, "pixels": pix})
            out.append({"code_ip": ip, "pointer_table": tab, "value": val, "base": base,
                        "seg_var": seg_var, "half": half, "positions": positions})
        return out


def fmt_event(ev):
    if ev[0] == "call":
        return f"call {ev[1]:#x}" if ev[1] is not None else "call ?"
    return f"set byte [{ev[1]:#x}]={ev[2]:#x}"


def class_from_outcomes(outs, hit="HIT", miss="MISS"):
    outs = {o for o in outs if o[0] in (hit, miss)} or outs
    hits = [o for o in outs if o[0] == hit]
    calls = any(e[0] == "call" for o in outs for e in o[1])
    sets = any(e[0] == "set" for o in outs for e in o[1])
    all_hit = len(hits) == len(outs)
    if sets and hits:
        return FLIPPER
    if calls:
        return ACTIVE if all_hit else ACTIVE_COND
    if all_hit:
        return WALL
    if hits:
        return WALL_COND
    return EMPTY


def analyse(n, src):
    t = Table(n, src)
    ptrs = t.pf_ptrs()
    subs = t.init_substitutions()
    wl = t.wall_loop()
    occ = t.occlusion_loop()
    trig = t.trigger_dispatch()
    nrm = t.normals()
    flips = t.flippers(ptrs)
    ring_offs, ring_pts = t.ball_ring(wl["ring_table"])

    # runtime threshold variables used in wall-loop setup (EP8: mov al,[4A7h])
    thresholds = {}
    for disp in wl["setup_mem"]:
        init = t.dsb(disp)[0]
        writes = sorted({m.group(1)[0] for _, m in t.code.find(rb"\xc6\x06" + struct.pack("<H", disp) + rb"(.)")})
        thresholds[disp] = {"initial": init, "values_written_by_code": writes}
    known_base = {d: v["initial"] for d, v in thresholds.items()}

    # --- wall LUTs
    wall_lut, wall_events = [], []
    term = {wl["hit_ip"]: "HIT", wl["miss_ip"]: "MISS"}
    for level in (0, 1):
        lut, evs = [], {}
        for v in range(256):
            outs = symrun(t.code, wl["start_ip"], {}, v, {**known_base, wl["level_var"]: level}, term)
            lut.append(class_from_outcomes(outs))
            e = sorted({fmt_event(ev) for o in outs if o[0] in ("HIT", "MISS") for ev in o[1]})
            if e:
                evs[v] = e
        wall_lut.append(lut)
        wall_events.append(evs)
    variants = {}
    for disp, info in thresholds.items():
        for alt in info["values_written_by_code"]:
            if alt == info["initial"]:
                continue
            lut = [class_from_outcomes(symrun(t.code, wl["start_ip"], {}, v,
                                              {**known_base, disp: alt, wl["level_var"]: 0}, term))
                   for v in range(256)]
            variants[f"level0_with_[{disp:#x}]={alt:#x}"] = lut

    # --- occlusion / sensor LUTs
    occ_known = {d: t.dsb(d)[0] for d in occ["setup_mem"]}
    occ_thresholds = {d: {"initial": v, "values_written_by_code": sorted(
        {m.group(1)[0] for _, m in t.code.find(rb"\xc6\x06" + struct.pack("<H", d) + rb"(.)")})}
        for d, v in occ_known.items()}
    occ_lut, sensor_calls = [], set()
    oterm = {occ["next_pixel_ip"]: "NEXT"}
    if occ["store_ip"]:
        oterm[occ["store_ip"]] = "OVER"
    for level in (0, 1):
        lut = []
        for v in range(256):
            outs = symrun(t.code, occ["start_ip"], {}, v, {**occ_known, occ["level_var"]: level}, oterm)
            outs = {o for o in outs if o[0] in ("NEXT", "OVER")}
            calls = [e for o in outs for e in o[1] if e[0] == "call"]
            for e in calls:
                sensor_calls.add(e[1])
            if any(o[0] == "OVER" for o in outs):
                lut.append(OCC_OVER)
            elif calls:
                lut.append(OCC_SENSOR if all(any(e[0] == "call" for e in o[1]) for o in outs) else OCC_SENSOR_COND)
            else:
                lut.append(OCC_BEHIND)
        occ_lut.append(lut)

    # --- which sensor values reach the dispatch jump table, per level
    handlers = trig["handlers"]
    null_handler = max(set(handlers), key=handlers.count)

    def jmp_chain(h):
        seen = set()
        while h not in seen:
            seen.add(h)
            x = t.code.at(h)
            if x is None or x.mnemonic != "jmp" or x.operands[0].type != X86_OP_IMM:
                break
            h = x.operands[0].imm
        return h

    null_end = jmp_chain(null_handler)
    sensor_fn = sorted(sensor_calls - {None})
    dispatch = [{}, {}]
    if sensor_fn:
        fn = sensor_fn[0]
        # the instruction that indexes the table: 'sub bx, first' (4 bytes before shl)
        dterm = {trig["dispatch_ip"]: "DISPATCH"}
        for level in (0, 1):
            for v in range(256):
                if occ_lut[level][v] not in (OCC_SENSOR, OCC_SENSOR_COND):
                    continue
                outs = symrun(t.code, fn, {"al": v}, v, {occ["level_var"]: level}, dterm)
                reach = [o for o in outs if o[0] == "DISPATCH"]
                if reach and trig["first_value"] <= v <= 0xFE:
                    h = handlers[v - trig["first_value"]]
                    if jmp_chain(h) != null_end:
                        dispatch[level][v] = {"handler_ip": h, "always": len(reach) == len(outs)}

    def describe(h):
        ins = []
        for x in t.code.linear(h, 10):
            ins.append(x)
            if x.mnemonic in ("jmp", "ret", "retf"):
                break
        return ins

    # sensor debounce counter: 'mov ah, byte ptr [cd]' in the occlusion setup
    cd = None
    for x in t.code.linear(occ["start_ip"], 30):
        if x.mnemonic == "mov" and x.op_str.startswith("ah, byte ptr [") and x.operands[1].mem.base == 0:
            cd = x.operands[1].mem.disp
            break
    handler_desc = {}
    for level in (0, 1):
        for v, d in dispatch[level].items():
            h = d["handler_ip"]
            if h not in handler_desc:
                ins = describe(h)
                txt = "; ".join(f"{x.mnemonic} {x.op_str}".strip() for x in ins)
                lv = occ["level_var"]
                movs = [x.op_str for x in ins if x.mnemonic == "mov"]
                tag = []
                if f"byte ptr [{lv:#x}], 1" in movs:
                    tag.append("enters_ramp_level")
                if f"byte ptr [{lv:#x}], 0" in movs:
                    tag.append("leaves_ramp_level")
                if cd is not None and len(ins) == 2 and ins[0].mnemonic == "mov" \
                        and ins[0].op_str.startswith(f"byte ptr [{cd:#x}],") and ins[1].mnemonic == "jmp":
                    tag.append("debounce_only")
                handler_desc[h] = {"first_instructions": txt, "tags": tag}

    # --- other code that loads ES with a playfield segment pointer and writes
    # bytes through it: runtime edits of the collision buffer (gates, doors...)
    writers = []
    for var, half in ((ptrs["top_var"], 0), (ptrs["bottom_var"], 1)):
        for ip, _ in t.code.find(b"\x8e\x06" + struct.pack("<H", var)):
            ins = t.code.linear(ip, 40)
            stores = [x for x in ins if x.mnemonic == "mov" and x.op_str.startswith("byte ptr es:")]
            if not stores:
                continue
            writers.append({"code_ip": hex(ip), "half": half, "es_byte_stores_in_next_40_insns": len(stores),
                            "is_flipper_routine": any(0 < f["code_ip"] - ip < 0x100 for f in flips)})

    # --- collision buffer
    pf = epexe.playfield(t.exe)
    buf = pf.copy()
    for s in subs:
        half = {ptrs["top_var"]: 0, ptrs["bottom_var"]: 1}.get(s["seg_var"])
        rows = slice(0, 200) if half == 0 else slice(200, 400) if half == 1 else slice(0, 400)
        sub = buf[rows]
        sub[(sub >= s["lo"]) & (sub <= s["hi"])] = s["replace"]
    lut_arr = np.array(wall_lut, np.uint8)
    classes = np.stack([lut_arr[0][buf], lut_arr[1][buf]])

    # --- ball sprite
    spr = occ["ball_sprite"]
    bw, bh = t.dsb(spr)[0], t.dsb(spr + 2)[0]
    ball = np.frombuffer(t.dsb(spr + 4, bw * bh), np.uint8).reshape(bh, bw)

    def lut_ranges(lut, names):
        out, start = [], 0
        for v in range(1, 257):
            if v == 256 or lut[v] != lut[start]:
                if lut[start]:
                    out.append({"from": start, "to": v - 1, "class": names[lut[start]]})
                start = v
        return out

    info = {
        "table": n,
        "code_segment": hex(t.exe.entry_cs),
        "data_segment": hex(t.ds),
        "note": "ip values are offsets in the code segment; file offset = 0x400 + code_segment*16 + ip. "
                "DS offsets are in the data segment. Addresses differ per table.",
        "collision_buffer": {
            "source": "playfield segments " + ", ".join(hex(s) for s in t.segs[:2]),
            "top_seg_var": hex(ptrs["top_var"]), "bottom_seg_var": hex(ptrs["bottom_var"]),
            "init_substitutions": [{**s, "code_ip": hex(s["code_ip"]), "seg_var": hex(s["seg_var"])} for s in subs],
            "addressing": "ES = top_seg + y*20 (paragraphs, i.e. y*320 bytes); byte ES:[x + ring_offset]",
        },
        "wall_loop": {k: (hex(v) if isinstance(v, int) else v) for k, v in wl.items() if k != "setup_mem"},
        "runtime_thresholds": {hex(k): v for k, v in thresholds.items()},
        "wall_lut_ranges": [lut_ranges(wall_lut[0], CLASS_NAMES), lut_ranges(wall_lut[1], CLASS_NAMES)],
        "wall_lut": wall_lut,
        "wall_lut_variants": variants,
        "wall_events": [{str(k): v for k, v in e.items()} for e in wall_events],
        "ball": {"width": int(bw), "height": int(bh), "sprite_ds": hex(spr),
                 "ring_ds": hex(wl["ring_table"] + 2),
                 "ring_offsets": ring_offs, "ring_xy": ring_pts,
                 "ring_note": "index k=1..48 stored at ring_ds+2(k-1); offsets are y*320+x from the "
                              "ball's top-left (x_var,y_var)"},
        "normals": {"normal_ds": hex(nrm["normal_table"]), "pushout_ds": hex(nrm["pushout_table"]),
                    "normal_ip": hex(nrm["normal_ip"]), "pushout_ip": hex(nrm["pushout_ip"]),
                    "normal": nrm["normal"], "pushout": nrm["pushout"],
                    "note": "entry i (0..47) used for averaged ring index i+1; velocity normal = (-nx, ny); "
                            "position correction x -= px, y += py"},
        "occlusion": {**{k: (hex(v) if isinstance(v, int) else v) for k, v in occ.items() if k != "setup_mem"},
                      "runtime_thresholds": {hex(k): v for k, v in occ_thresholds.items()},
                      "lut_ranges": [lut_ranges(occ_lut[0], OCC_NAMES), lut_ranges(occ_lut[1], OCC_NAMES)],
                      "lut": occ_lut},
        "sensor_routine_ip": [hex(x) for x in sensor_fn],
        "sensor_debounce_var": hex(cd) if cd is not None else None,
        "trigger_table": {"dispatch_ip": hex(trig["dispatch_ip"]), "table_ip": hex(trig["table_ip"]),
                          "first_value": trig["first_value"], "null_handler": hex(null_handler),
                          "handlers": {str(trig["first_value"] + i): hex(h) for i, h in enumerate(handlers)}},
        "sensors": [{str(v): {**d, "handler_ip": hex(d["handler_ip"])} for v, d in sorted(dispatch[lv].items())}
                    for lv in (0, 1)],
        "sensor_handlers": {hex(h): d for h, d in handler_desc.items()},
        "flippers": [{**f, "code_ip": hex(f["code_ip"]), "pointer_table": hex(f["pointer_table"]),
                      "seg_var": hex(f["seg_var"]) if f["seg_var"] is not None else None}
                     for f in flips],
        "runtime_buffer_writers": writers,
        "flipper_note": "positions[0..9]: pixel outline written with `value` into the collision buffer "
                        "each frame (previous outline erased with 0x2a). Index 9 = rest, 0 = fully raised.",
        "class_codes": CLASS_NAMES,
        "occlusion_codes": OCC_NAMES,
    }
    return info, buf, classes, ball, pf


COLORS = {EMPTY: None, WALL: (220, 40, 40), WALL_COND: (160, 60, 160), ACTIVE: (255, 150, 0),
          ACTIVE_COND: (255, 220, 120), FLIPPER: (255, 255, 0)}


def render(info, buf, classes, pal, flips):
    panels = []
    for level in (0, 1):
        rgb = (pal[buf] * 0.3).astype(np.uint8)
        sens = info["sensors"][level]
        for v in sens:
            tags = info["sensor_handlers"][sens[v]["handler_ip"]]["tags"]
            if "debounce_only" in tags:
                continue
            rgb[buf == int(v)] = (0, 255, 120) if "enters_ramp_level" in tags else \
                (255, 0, 255) if "leaves_ramp_level" in tags else (0, 200, 255)
        for c, col in COLORS.items():
            if col:
                rgb[classes[level] == c] = col
        if level == 0:
            for f in flips:
                for k, p in enumerate(f["positions"] or []):
                    for x, y in p["pixels"]:
                        if 0 <= x < W and 0 <= y < H:
                            rgb[y, x] = (255, 255, 255) if k in (0, 9) else (200, 200, 60)
        panels.append(rgb)
    img = Image.fromarray(np.hstack(panels))
    return img.resize((img.width * 2, img.height * 2), Image.NEAREST)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "original"
    out = sys.argv[2] if len(sys.argv) > 2 else "extracted"
    summary = []
    for n in range(1, 14):
        info, buf, classes, ball, pf = analyse(n, src)
        tdir = os.path.join(out, "tables", f"EP{n}")
        os.makedirs(tdir, exist_ok=True)
        np.save(os.path.join(tdir, "collision_idx.npy"), buf)
        np.save(os.path.join(tdir, "collision.npy"), classes)
        with open(os.path.join(tdir, "collision.json"), "w") as f:
            json.dump(info, f, indent=1)
        pal_path = os.path.join(tdir, "palette.json")
        pal = np.array(json.load(open(pal_path)), np.uint8) if os.path.exists(pal_path) else \
            np.stack([np.arange(256)] * 3, 1).astype(np.uint8)
        render(info, buf, classes, pal, info["flippers"]).save(os.path.join(tdir, "collision.png"))
        bimg = Image.frombytes("P", (ball.shape[1], ball.shape[0]), ball.tobytes())
        bimg.putpalette(pal.flatten().tolist())
        bimg.save(os.path.join(tdir, "ball.png"))
        l0 = info["wall_lut_ranges"][0]
        l1 = info["wall_lut_ranges"][1]
        fmt = lambda rs: " ".join(f"{r['from']:02x}-{r['to']:02x}:{r['class'][:6]}" for r in rs)
        print(f"EP{n:<2} L0[{fmt(l0)}]  L1[{fmt(l1)}]  flippers={len(info['flippers'])} "
              f"sensors={len(info['sensors'][0])}/{len(info['sensors'][1])} subs={len(info['collision_buffer']['init_substitutions'])}")
        summary.append({"table": n, "wall_lut_ranges": info["wall_lut_ranges"],
                        "flippers": len(info["flippers"]), "runtime_thresholds": info["runtime_thresholds"]})
    with open(os.path.join(out, "tables", "collision_summary.json"), "w") as f:
        json.dump(summary, f, indent=1)


if __name__ == "__main__":
    main()
