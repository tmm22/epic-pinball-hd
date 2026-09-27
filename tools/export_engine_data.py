#!/usr/bin/env python3
"""Export the per-table engine data the Swift port needs (extracted/tables/EPn/engine.json).

Everything in engine.json comes from the user's own copy of the game:
  * parsed from original/EPn.EXE (parameter block, integration caps, gravity cut-off,
    kicker cooldown, flipper variables/initial angles, plunger/serve/nudge/tilt
    constants, ball sprite pixels, sensor handlers), located by byte patterns taken
    from EP1's code (docs/formats/engine.md, collision.md), and
  * copied from the other extractors' outputs: extracted/tables/EPn/collision.json
    (probe ring, normal and push-out tables, wall/occlusion LUTs, flipper outlines,
    sensor dispatch) and sprites/sprites.json (flipper sprite names and rectangles).

The Swift app never embeds any of these tables; it loads engine.json at runtime.

Usage (repo root):
    .venv/bin/python tools/export_engine_data.py            # all 13 tables
    .venv/bin/python tools/export_engine_data.py 1 4 12     # some tables
    .venv/bin/python tools/export_engine_data.py 1 --print  # dump summary

Every field that could not be located by pattern falls back to the EP1 value and is
listed in "fallbacks" so the port (and a human) can see what is unverified.
Addresses in comments are EP1 cs:ip (code segment 0x3223) / ds: (data segment 0x15).
"""
import argparse
import hashlib
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import epexe  # noqa: E402

try:
    import capstone
except ImportError:  # the sensor-handler interpreter needs it; everything else does not
    capstone = None

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
W, H = 320, 400
HALF = 64000
FORMAT = "epic-pinball-engine"
VERSION = 1

PARAM_NAMES = ["rest_div_x", "rest_div_y", "kicker", "flip_top_x", "flip_top_y",
               "flip_side_x", "flip_side_y", "up_div_y", "up_div_x", "gravity"]


def u16(b, o=0):
    return struct.unpack_from("<H", b, o)[0]


def s16(b, o=0):
    return struct.unpack_from("<h", b, o)[0]


class Exe:
    def __init__(self, n):
        self.n = n
        self.path = os.path.join(ROOT, "original", f"EP{n}.EXE")
        self.e = epexe.load(self.path)
        self.cs = self.e.entry_cs
        self.ds = epexe.data_segment(self.e)
        self.cbase = self.e.image_off(self.cs)
        self.dbase = self.e.image_off(self.ds)
        self.code = self.e.data[self.cbase:]
        self.data = self.e.data
        self.fallbacks = []
        self.found = {}

    def dsw(self, off, signed=True):
        return (s16 if signed else u16)(self.data, self.dbase + off)

    def dsb(self, off):
        return self.data[self.dbase + off]

    def all(self, pat, start=0, end=None):
        return [m for m in re.finditer(pat, self.code[start:end] if end else self.code[start:], re.S)]

    def first(self, pat, name, start=0, end=None):
        ms = self.all(pat, start, end)
        if not ms:
            return None
        m = ms[0]
        self.found[name] = hex(m.start() + start)
        return m, m.start() + start

    def fallback(self, name, value):
        self.fallbacks.append(name)
        return value


# EP1 values, used only when a pattern is not found (listed in "fallbacks").
EP1_DEFAULTS = {
    "step_cap": [5, 5, 5, 5], "acc_clamp": [2000, -2000], "collision_y_limit": 0x180,
    "y_reset": 3, "gravity_cutoff": 0x140, "kicker_cooldown": 3, "split_x": 0x8C,
    "side_ranges": {"lo": 5, "side_max": 31, "top_max": 40, "side_index": 31, "tip_index": 41},
    "vy_zero_side": 0x1E, "vy_zero_top": 0x28, "plunger": {"step": 12, "max": 700},
    "lane": {"min_x": 0x118, "min_y": 0xDC}, "serve": {"x": 0x11C, "y": 0x150, "delay": 7},
    "drain_y": 0x18F, "nudge": {"tilt_add": 35, "frames": 10}, "tilt_threshold": 0x50,
    "nudge_lane": {"min_x": 0x118, "max_y": 0x64},
    "nudge_impulse": {"min_timer": 2, "dir_min": 4, "dir_max": 42, "vy_shift": 3, "vx": 20},
    "ball_ball_divisor": 35, "flip_tbl_x": [-3, -2, -1, -1, 1, 2, 3, 4, 4, 5],
    "flip_tbl_y": [48, 49, 50, 50, 49, 49, 48, 47, 46, 46], "sfx_big_hit_vy": -500,
}


def export_table(n):
    x = Exe(n)
    cj = json.load(open(os.path.join(ROOT, "extracted", "tables", f"EP{n}", "collision.json")))
    sp_path = os.path.join(ROOT, "extracted", "tables", f"EP{n}", "sprites", "sprites.json")
    sj = json.load(open(sp_path)) if os.path.exists(sp_path) else None
    out = {"format": FORMAT, "version": VERSION, "table": n}
    forbidden = set()   # physics state a sensor handler may not touch (handler rejected if it does)
    out["source"] = {
        "exe": f"EP{n}.EXE",
        "sha1": hashlib.sha1(x.data).hexdigest(),
        "code_segment": hex(x.cs), "data_segment": hex(x.ds),
        "inputs": ["original/EP%d.EXE" % n, "extracted/tables/EP%d/collision.json" % n]
                  + (["extracted/tables/EP%d/sprites/sprites.json" % n] if sj else []),
    }

    # ---- parameter block (ds:6781, hidden F1 editor at cs:1408): lea di,[P]..; add di,2; lea ax,[P+14h]; cmp di,ax
    m = x.first(rb"\x83\xc7\x02\x8d\x06(..)\x3b\xf8", "params")
    if not m:
        raise SystemExit(f"EP{n}: parameter block not found")
    p_end = u16(m[0].group(1))
    p_ds = p_end - 0x14
    forbidden.update(range(p_ds, p_ds + 20))
    params = [x.dsw(p_ds + 2 * i) for i in range(10)]
    out["params"] = {"ds": hex(p_ds), "names": PARAM_NAMES, "values": params}

    # ---- integration (physics_step cs:1724): shr ax,7; cmp ax,N; jbe; mov ax,N; cmp [di+acc],CLAMP
    caps = x.all(rb"\xc1\xe8\x07\x3d(.)\x00\x76.\xb8.\x00\x81\xbd(..)(..)")
    if len(caps) >= 4:
        step_cap = [c.group(1)[0] for c in caps[:4]]
        acc_clamp = [s16(caps[0].group(3)), s16(caps[1].group(3))]
        acc_arr = [u16(caps[0].group(2)), u16(caps[2].group(2))]
        integ_end = caps[3].end()
        x.found["integration"] = hex(caps[0].start())
    else:
        step_cap = x.fallback("integration.step_cap", EP1_DEFAULTS["step_cap"])
        acc_clamp = x.fallback("integration.acc_clamp", EP1_DEFAULTS["acc_clamp"])
        integ_end, acc_arr = 0, None
    # y < min -> y = RESET, vy = 0 : cmp [di+y],1; jge +0c; mov [di+y],RESET; mov [di+vy],0
    m = x.first(rb"\x83\xbd(..)\x01\x7d\x0c\xc7\x85(..)(..)\xc7\x85(..)\x00\x00", "y_reset", integ_end)
    if m:
        y_reset = s16(m[0].group(3))
        y_arr = u16(m[0].group(1))
    else:
        y_reset, y_arr = x.fallback("integration.y_reset", EP1_DEFAULTS["y_reset"]), None
    # collision loop guard: cmp [di+y],180h; jb +3; jmp
    m = x.first(rb"\x81\xbd(..)(..)\x72\x03\xe9", "collision_y_limit", integ_end)
    coll_y = u16(m[0].group(2)) if m else x.fallback("integration.collision_y_limit", EP1_DEFAULTS["collision_y_limit"])
    out["integration"] = {
        "step_cap": {"x_pos": step_cap[0], "x_neg": step_cap[1], "y_pos": step_cap[2], "y_neg": step_cap[3]},
        "acc_clamp_pos": acc_clamp[0], "acc_clamp_neg": acc_clamp[1],
        "min_x": 1, "min_y": 1, "y_reset": y_reset, "collision_y_limit": coll_y,
        "note": "per axis: acc+=v; m=|acc|>>7 (unsigned); if m>cap {m=cap; clamp acc}; pos+=/-=m; acc-/+=m<<7. "
                "x<1 -> x=1 after x move; y<1 -> y=reset, vy=0 only after an upward y move. "
                "Collision loop runs while (u16)y < collision_y_limit.",
    }

    # ---- gravity (cs:11AE): cmp [di+vy],CUT; jg; mov ax,[g]; (add ax,[extra]); add [di+vy],ax
    m = x.first(rb"\x81\xbd(..)(..)\x7f.\xa1(..)", "gravity")
    extra_var = None
    if m:
        cutoff = s16(m[0].group(2))
        g_var = u16(m[0].group(3))
        tail = x.code[m[1] + len(m[0].group(0)):m[1] + len(m[0].group(0)) + 4]
        if tail[:2] == b"\x03\x06":
            extra_var = u16(tail, 2)
        if g_var != p_ds + 18:
            out.setdefault("notes", []).append(f"gravity variable {g_var:#x} is not param[9]")
    else:
        cutoff = x.fallback("gravity.cutoff", EP1_DEFAULTS["gravity_cutoff"])
    out["gravity"] = {"cutoff": cutoff, "extra_var": hex(extra_var) if extra_var is not None else None,
                      "extra_initial": x.dsw(extra_var) if extra_var is not None else 0,
                      "note": "per frame, per active ball: if vy <= cutoff: vy += params.gravity + extra; "
                              "extra (if present) is decremented once per frame while nonzero"}

    # ---- probe ring, normals, push-out, LUTs: from collision.json (itself parsed from the EXE)
    ring = cj["ball"]["ring_offsets"]
    out["probe_ring"] = {"offsets": ring, "xy": cj["ball"]["ring_xy"],
                         "note": "k=1..48 (index k-1); probed k=48 down to 1; word offsets dy*320+dx from the ball's top-left"}
    out["normals"] = cj["normals"]["normal"]
    out["pushout"] = cj["normals"]["pushout"]
    codes = cj["class_codes"]
    out["wall"] = {"codes": codes, "lut": cj["wall_lut"],
                   "note": "per level (0 table, 1 ramp): class per palette index. conditional classes are "
                           "treated as their unconditional form by the port"}
    occ = cj["occlusion"]
    out["occlusion"] = {"codes": cj["occlusion_codes"], "lut": occ["lut"],
                        "ranges": (sj or {}).get("ball_occlusion_ranges")}

    # ---- wall loop: flipper contact split and moving flags (cs:1876..189E)
    #   cmp es:[bx],dl; jne; cmp [di+x],SPLIT; ja; cmp [mvL],1; jne; mov [fc],1; jmp; nop; cmp [mvR],1; jne; mov [fc],2
    m = x.first(rb"\x26\x38\x17\x75.\x81\xbd(..)(..)\x77.\x80\x3e(..)\x01\x75.\xc6\x06(..)\x01\xeb.\x90"
                rb"\x80\x3e(..)\x01\x75.\xc6\x06(..)\x02", "flipper_contact")
    if m:
        split_x = u16(m[0].group(2))
        mv_l, mv_r, fc_var = u16(m[0].group(3)), u16(m[0].group(5)), u16(m[0].group(4))
    else:
        split_x = x.fallback("flipper_contact.split_x", EP1_DEFAULTS["split_x"])
        mv_l = mv_r = fc_var = None
    # kicker_hit (cs:19C1): cmp [tilt],1; jne; jmp; mov al,[p_kicker]; mov [kick],al; mov [cool],N
    # wall loop: cmp byte [cool],0; jne +3; call kicker_hit
    kcool, tilt_in_kicker = None, None
    m = x.first(rb"\x80\x3e(..)\x00\x75\x03\xe8(..)", "kicker_call")
    if m:
        cool_var = u16(m[0].group(1))
        forbidden.add(cool_var)
        kip = (m[1] + len(m[0].group(0)) + s16(m[0].group(2))) & 0xFFFF
        body = x.code[kip:kip + 0x60]
        # kicker_hit starts with pusha; push es; cmp byte [tilted],1; jne +3; jmp
        tilt_in_kicker = re.search(rb"\x80\x3e..\x01\x75\x03\xe9", body[:16], re.S) is not None
        cm = re.search(rb"\xc6\x06" + re.escape(struct.pack("<H", cool_var)) + rb"(.)", body, re.S)
        if cm:
            kcool = cm.group(1)[0]
            x.found["kicker_hit"] = hex(kip)
    if kcool is None:
        kcool = x.fallback("kicker.cooldown_frames", EP1_DEFAULTS["kicker_cooldown"])
    out["kicker"] = {"cooldown_frames": kcool, "tilt_disables": True if tilt_in_kicker is None else tilt_in_kicker,
                     "note": "any probe on an 'active' index calls the kicker when cooldown==0: kick=params.kicker, "
                             "cooldown=N (decremented per frame). Not while tilted."}

    # ---- collision_response constants (cs:1AEC..1B47): side/tip kick index ranges
    m = x.first(rb"\x83\xfb(.)\x77.\x83\xfb(.)\x72.\x83\xfb.\x77.\x83\xc3.\xbb(..)\xeb.\x90\x81\xfb(..)\x72.\xbb(..)",
                "flipper_side")
    if m:
        top_lo4, lo4, side4, tip4a, tip4 = m[0].group(1)[0], m[0].group(2)[0], u16(m[0].group(3)), u16(m[0].group(4)), u16(m[0].group(5))
        side_ranges = {"lo": lo4 // 4, "side_max": top_lo4 // 4, "top_max": tip4a // 4 - 1,
                       "side_index": side4 // 4, "tip_index": tip4 // 4}
    else:
        side_ranges = x.fallback("flipper_kick.ranges", EP1_DEFAULTS["side_ranges"])
    m = x.first(rb"\x83\xbd(..)(.)\x7c\x06\xc7\x85..\x00\x00\x8b\x87", "vy_zero_side")
    vy_zero_side = m[0].group(2)[0] if m else x.fallback("flipper_kick.vy_zero_side", EP1_DEFAULTS["vy_zero_side"])
    m = x.first(rb"\x83\xbd(..)(.)\x7c\x06\xc7\x85..\x00\x00\x80\x3e", "vy_zero_top")
    vy_zero_top = m[0].group(2)[0] if m else x.fallback("flipper_kick.vy_zero_top", EP1_DEFAULTS["vy_zero_top"])
    # top kick tables and which angle variable each contact uses:
    #   right: mov bx,[angR]; shl bx,1; mov ax,[bx+FX]; mov cx,[p3]; imul cx; sub [di+vx],ax; mov ax,[bx+FY]
    m_r = x.first(rb"\x8b\x1e(..)\xd1\xe3\x8b\x87(..)\x8b\x0e(..)\xf7\xe9\x29\x85(..)\x8b\x87(..)", "top_kick_right")
    m_l = x.first(rb"\x8b\x1e(..)\xd1\xe3\x8b\x87(..)\x8b\x0e(..)\xf7\xe9\x01\x85(..)\x8b\x87(..)", "top_kick_left")
    if m_r and m_l:
        fx_tab, fy_tab = u16(m_l[0].group(2)), u16(m_l[0].group(5))
        fx = [x.dsw(fx_tab + 2 * i) for i in range(10)]
        fy = [x.dsw(fy_tab + 2 * i) for i in range(10)]
        ang_r, ang_l = u16(m_r[0].group(1)), u16(m_l[0].group(1))
    else:
        fx = x.fallback("flipper_kick.fx", EP1_DEFAULTS["flip_tbl_x"])
        fy = x.fallback("flipper_kick.fy", EP1_DEFAULTS["flip_tbl_y"])
        ang_r = ang_l = None
    # nudge impulse at the end of the reflection path (cs:1D06..1D41)
    m = x.first(rb"\x80\x3e(..)(.)\x72.\x80\x3e(..)(.)\x72.\x80\x3e(..)(.)\x77.\xa0(..)\xc0\xe0(.)\xb4\x00"
                rb"\x29\x85(..)\x83\x85(..)(.)", "nudge_impulse")
    if m:
        g = m[0].groups()
        nudge_imp = {"min_timer": g[1][0], "dir_min": g[3][0], "dir_max": g[5][0], "vy_shift": g[7][0], "vx": g[10][0]}
    else:
        nudge_imp = x.fallback("nudge.impulse", EP1_DEFAULTS["nudge_impulse"])
    # big-hit SFX trigger in the wall loop (cs:18CC): cmp [di+vy],-500; jge; ... cmp [hits],9
    m = x.first(rb"\x81\xbd(..)(..)\x7d.\x83\x3e..\xff\x75.\x83\x3e..(.)", "sfx_big_hit")
    out["collision"] = {
        "flipper_contact_split_x": split_x,
        "big_hit_sfx": {"vy_below": s16(m[0].group(2)), "hit_count": m[0].group(3)[0]} if m else None,
        "note": "probe order 48..1; wall LUT per level; 'active' -> kicker (cooldown gated), 'flipper' value -> "
                "contact 1 if (u16)x <= split else 2, only if that flipper moved up on the previous flipper_update",
    }
    out["flipper_kick"] = {
        "ranges": side_ranges, "vy_zero_side": vy_zero_side, "vy_zero_top": vy_zero_top, "fx": fx, "fy": fy,
        "note": "k=dir-1. contact && lo<=k<=side_max: v += n[side_index]*(p5,p6) (vy zeroed first if vy>=vy_zero_side); "
                "contact && (k<lo || k>top_max): same with tip_index; both every loop iteration, y-=1, no push-out. "
                "side_max<k<=top_max: y-=1, then (first response only) vy=0 if vy>=vy_zero_top; "
                "left: vx+=fx[a]*p3, right: vx-=fx[a]*p3; vy-=fy[a]*p4 (a = that flipper's angle)",
    }
    out["nudge_impulse"] = nudge_imp

    # ---- flippers: outlines from collision.json + variables parsed from flipper_update (cs:3CDD)
    key_l = x.first(rb"\x3c\x2a\x75.\x2e\xc6\x06(..)\x01", "key_lflip")
    key_r = x.first(rb"\x3c\x36\x75.\x2e\xc6\x06(..)\x01", "key_rflip")
    key_vars = {}
    if key_l:
        key_vars[u16(key_l[0].group(1))] = "left"
    if key_r:
        key_vars[u16(key_r[0].group(1))] = "right"
    # Several outlines can share one angle variable (EP4's and EP12's extra flippers move with the
    # main ones): they form one "group" with one angle/drawn/moving state and one key.
    flippers, groups = [], []
    fl_list = sorted(cj["flippers"], key=lambda f: int(f["code_ip"], 16))
    for i, f in enumerate(fl_list):
        tab = int(f["pointer_table"], 16)
        half = f["half"] if f["half"] is not None else 1
        base = f["base"]
        ip = int(f["code_ip"], 16)
        # draw loop body: lodsw; mov di,ax; [add di,base]; mov es:[di],dl; [mov es:[di+D],dl]  (EP11-13 draw 2 rows)
        body = x.code[ip:ip + 0x20]
        dm = re.search(rb"\x26\x88\x15(\x26\x88\x95(..))?\xe2", body, re.S)
        extra = s16(dm.group(2)) if dm and dm.group(1) else None
        positions = []
        for k in range(10):
            pp = x.dsw(tab + 2 * k, signed=False)
            cnt = x.dsw(pp, signed=False)
            offs = []
            for j in range(cnt):
                o = x.dsw(pp + 2 + 2 * j, signed=False)
                offs.append(half * HALF + ((o + base) & 0xFFFF))
                if extra is not None:
                    offs.append(half * HALF + ((o + base + extra) & 0xFFFF))
            positions.append(offs)
        # angle var: mov si,[A]; shl si,1; mov si,[si+TAB] just before the draw pass; the erase pass uses [drawn]
        refs = [m for m in re.finditer(rb"\x8b\x36(..)\xd1\xe6\x8b\xb4" + re.escape(struct.pack("<H", tab)), x.code, re.S)]
        angle_var = drawn_var = None
        for r in refs:
            if r.start() < ip and ip - r.start() < 0x10:
                angle_var = u16(r.group(1))
            elif r.start() < ip and ip - r.start() < 0x100:
                drawn_var = u16(r.group(1))
        gi = next((j for j, g in enumerate(groups) if angle_var is not None and g["angle_var"] == hex(angle_var)), None)
        if gi is None:
            # routine head: key test, moving flag and rest test precede the first erase pass
            seg = x.code[max(0, ip - 0x90):ip]
            key = None
            km = [mm for mm in re.finditer(rb"\x2e\x80\x3e(..)\x01\x74", seg, re.S)]
            if km:
                key = key_vars.get(u16(km[-1].group(1)))
            mv = [mm for mm in re.finditer(rb"\xc6\x06(..)\x01\xff\x0e(..)", seg, re.S)]
            moving_var = u16(mv[-1].group(1)) if mv else None
            rm = [mm.group(2)[0] for mm in re.finditer(rb"\x83\x3e(..)(.)[\x74\x75]", seg, re.S)
                  if angle_var and u16(mm.group(1)) == angle_var and mm.group(2)[0] != 0]
            rest = max(rm) if rm else x.fallback(f"flipper_groups[{len(groups)}].rest_angle", 9)
            if key is None:
                pts = positions[-1]
                key = "left" if sum(o % W for o in pts) / max(1, len(pts)) < W / 2 else "right"
                x.fallbacks.append(f"flipper_groups[{len(groups)}].key")
            groups.append({
                "key": key, "value": f["value"], "rest_angle": rest,
                "init_angle": x.dsw(angle_var) if angle_var is not None else x.fallback(f"flipper_groups[{len(groups)}].init_angle", 2),
                "init_drawn": x.dsw(drawn_var) if drawn_var is not None else x.fallback(f"flipper_groups[{len(groups)}].init_drawn", 2),
                "angle_var": hex(angle_var) if angle_var else None, "drawn_var": hex(drawn_var) if drawn_var else None,
                "moving_var": hex(moving_var) if moving_var else None,
            })
            gi = len(groups) - 1
        flippers.append({"group": gi, "outline_half": half, "outline_base": base, "second_row": extra,
                         "draw_ip": hex(ip), "positions": positions})
    # contact 1/2 -> group (by moving var); top kick 1/2 -> group (by angle var)
    def by_var(field, var, default):
        for j, g in enumerate(groups):
            if var is not None and g[field] == hex(var):
                return j
        x.fallbacks.append(f"flipper_map.{field}")
        return default
    left_default = next((j for j, g in enumerate(groups) if g["key"] == "left"), 0)
    right_default = next((j for j, g in enumerate(groups) if g["key"] == "right"), min(1, len(groups) - 1))
    out["flipper_map"] = {
        "contact1_moving": by_var("moving_var", mv_l, left_default),
        "contact2_moving": by_var("moving_var", mv_r, right_default),
        "contact1_angle": by_var("angle_var", ang_l, left_default),
        "contact2_angle": by_var("angle_var", ang_r, right_default),
        "note": "indices into flipper_groups",
    }
    # sprite frames: match each outline to the sprite group covering its rest outline
    if sj:
        sgroups = {}
        for sp in sj["sprites"]:
            if sp["group"] == "flipper":
                gk, fr = sp["name"].rsplit("_", 1)
                sgroups.setdefault(gk, []).append((int(fr), sp))
        for fe in flippers:
            pts = [(o % W, o // W) for o in fe["positions"][groups[fe["group"]]["rest_angle"]]]
            best, score = None, 0
            for gk, frs in sgroups.items():
                s0 = frs[0][1]
                inside = sum(1 for (px, py) in pts if s0["x"] <= px < s0["x"] + s0["w"] and s0["y"] <= py < s0["y"] + s0["h"])
                if inside > score:
                    best, score = gk, inside
            if best is not None:
                frs = sorted(sgroups[best], key=lambda t: t[0])
                s0 = frs[0][1]
                fe["sprite"] = {"frames": [sp["name"] + ".png" for _, sp in frs], "x": s0["x"], "y": s0["y"],
                                "w": s0["w"], "h": s0["h"],
                                "frame_rule": "frame = (angle + 2) / 3 (EP1 cs:10F5), clamped to frames-1"}
    # erase colour of the outline redraw (EP1 cs:3D42 mov dl,2Ah) = start-up substitution value
    em = x.first(rb"\x8b\xb4(..)\xad\x8b\xc8\xb2(.)\xad", "flipper_erase")
    erase = em[0].group(2)[0] if em else x.fallback("flipper_erase_value", 0x2A)
    out["flipper_erase_value"] = erase
    subs = cj["collision_buffer"].get("init_substitutions") or []
    if subs and subs[0].get("replace") != erase:
        out.setdefault("notes", []).append(f"start-up substitution value {subs[0].get('replace')} != flipper erase value {erase}")
    out["flipper_groups"] = groups
    out["flippers"] = flippers
    out["flipper_note"] = ("flipper_update (EP1 cs:3CDD) once per physics step, groups in order: tilted -> angle=rest, "
                           "moving=0, redraw; key held -> if angle==0 {moving=0} else {moving=1; angle-=1; redraw}; "
                           "released -> moving=0; if angle!=rest {angle+=1; redraw}. redraw = write 0x2A over every "
                           "member's positions[drawn], then value over positions[angle], drawn=angle. Offsets are "
                           "linear into the 320x400 collision buffer.")

    # ---- plunger / serve / drain (cs:0A31..0BC7)
    # cmp word [charge],MAX; ja|jae; add word [charge],STEP   (EP1 ja/700/12, EP4 jae/400/10, EP10 jae/800/10)
    m = x.first(rb"\x81\x3e(..)(..)([\x77\x73]).\x83\x06\1(.)", "plunger")
    plunger = ({"step": m[0].group(4)[0], "max": u16(m[0].group(2)), "cmp": "ja" if m[0].group(3) == b"\x77" else "jae"}
               if m else x.fallback("plunger", dict(EP1_DEFAULTS["plunger"], cmp="ja")))
    m = x.first(rb"\x81\x3e(..)(..)\x72.\x81\x3e(..)(..)\x72.\x80\x3e(..)\x00\x74", "lane")
    lane = {"min_x": u16(m[0].group(2)), "min_y": u16(m[0].group(4))} if m else x.fallback("plunger.lane", EP1_DEFAULTS["lane"])
    m = x.first(rb"\xc6\x06(..)(.)\xc7\x06(..)(..)\xc7\x06(..)\x00\x00\xc7\x06(..)\x00\x00\xc7\x06(..)(..)\xc7\x06(..)\x01\x00", "serve")
    if m:
        forbidden.add(u16(m[0].group(1)))
    serve = ({"x": u16(m[0].group(8)), "y": u16(m[0].group(4)), "delay": m[0].group(2)[0]} if m
             else x.fallback("serve", EP1_DEFAULTS["serve"]))
    m = x.first(rb"\x81\xbd(..)(..)\x72.\x83\xbd", "drain")
    drain_y = u16(m[0].group(2)) if m else x.fallback("drain_y", EP1_DEFAULTS["drain_y"])
    plunger.update({"lane_min_x": lane["min_x"], "lane_min_y": lane["min_y"], "zero_vx_in_lane_when_released": True,
                    "note": "only when ball 0 active, level 0, x>=lane_min_x, y>=lane_min_y (unsigned): held -> "
                            "if charge<=max: charge+=step; released -> vx=0; if charge: vy-=charge, y-=1, charge=0"})
    out["plunger"] = plunger
    out["serve"] = serve
    out["drain_y"] = drain_y

    # ---- nudge / tilt (cs:0DFD..0E85)
    m = x.first(rb"\x80\x06(..)(.)\xc6\x06(..)(.)\x83\x2e", "nudge")
    if m:
        forbidden.update({u16(m[0].group(1)), u16(m[0].group(3)), u16(m[0].group(1)) + 1})  # meter, timer, tilted
    nudge = {"tilt_add": m[0].group(2)[0], "frames": m[0].group(4)[0]} if m else x.fallback("nudge", EP1_DEFAULTS["nudge"])
    m = x.first(rb"\x81\x3e(..)(..)\x72\x07\x83\x3e(..)(.)\x77", "nudge_lane")
    nl = {"min_x": u16(m[0].group(2)), "max_y": m[0].group(4)[0]} if m else x.fallback("nudge.lane", EP1_DEFAULTS["nudge_lane"])
    m = x.first(rb"\x80\x3e(..)(.)\x76.\x80\x3e(..)\x01\x74", "tilt")
    tilt_th = m[0].group(2)[0] if m else x.fallback("tilt_threshold", EP1_DEFAULTS["tilt_threshold"])
    nudge.update({"tilt_threshold": tilt_th, "lane_min_x": nl["min_x"], "lane_max_y": nl["max_y"],
                  "note": "per frame: if (nudgeA|nudgeB|space) && !tilted && !(x>=lane_min_x && y>lane_max_y) && "
                          "timer==0: meter+=tilt_add (u8), timer=frames. Then timer--, meter-- (if nonzero); "
                          "meter>threshold -> tilted"})
    out["nudge"] = nudge

    # ---- ball-ball (cs:1D47): divisors forced to N for both balls
    bb = None
    for mm in x.all(rb"\xc7\x06(..)(..)\xc7\x06(..)(..)\x83\x3e"):
        if u16(mm.group(1)) == p_ds:
            bb = s16(mm.group(2))
            x.found["ball_ball"] = hex(mm.start())
    out["ball_ball"] = {"divisor": bb if bb is not None else x.fallback("ball_ball.divisor", EP1_DEFAULTS["ball_ball_divisor"]),
                        "max_dx": 15, "max_dy": 14, "pairs": [[0, 1], [0, 2], [1, 2]]}

    # ---- ball sprite (ds:6B36: w, h, pixels; index 0 transparent)
    ball = None
    if sj:
        for s in sj["sprites"]:
            if s["group"] == "ball":
                fo = int(s["file_offset"], 16)
                w, h = u16(x.data, fo), u16(x.data, fo + 2)
                if (w, h) == (15, 14):
                    ball = {"w": w, "h": h, "transparent": 0, "pixels": list(x.data[fo + 4:fo + 4 + w * h]),
                            "file_offset": s["file_offset"]}
                break
    out["ball"] = ball or {"w": 15, "h": 14, "transparent": 0, "pixels": None}

    # ---- sensors: a tiny interpreter for handlers that only touch physics state
    for g in groups:
        for k in ("angle_var", "drawn_var", "moving_var"):
            if g.get(k):
                forbidden.update({int(g[k], 16), int(g[k], 16) + 1})
    pm = x.first(rb"\x81\x3e(..)(..)([\x77\x73]).\x83\x06\1(.)", "plunger_var")
    if pm:
        forbidden.update({u16(pm[0].group(1)), u16(pm[0].group(1)) + 1})
    out["sensors"] = sensors(x, cj, extra_var, p_ds, forbidden)
    # ball_pixel_scan (EP1 cs:16D6): cmp al,0FEh; je -> this index fires even while locked out
    fm = x.first(rb"\x3c(.)\x74\x05\x80\xfc\x00", "sensor_always")
    out["sensors"]["always_fires_value"] = fm[0].group(1)[0] if fm else x.fallback("sensors.always_fires_value", 0xFE)

    # ---- initial contents of the 5 ball slots in the DS image (inactive slots keep stale values)
    arr = {k: int(v, 16) for k, v in out["sensors"].get("vars", {}).items() if k.endswith(".0")}
    lm = x.first(rb"\x80\xbd(..)\x01\x75\x06\xb6\x00", "layer_array")
    if acc_arr and lm and all(k in arr for k in ("ball_x.0", "ball_y.0", "ball_vx.0", "ball_vy.0", "ball_active.0")):
        la = u16(lm[0].group(1))
        out["ball_slots_initial"] = [
            {"active": x.dsw(arr["ball_active.0"] + 2 * i, signed=False), "x": x.dsw(arr["ball_x.0"] + 2 * i),
             "y": x.dsw(arr["ball_y.0"] + 2 * i), "vx": x.dsw(arr["ball_vx.0"] + 2 * i), "vy": x.dsw(arr["ball_vy.0"] + 2 * i),
             "accx": x.dsw(acc_arr[0] + 2 * i), "accy": x.dsw(acc_arr[1] + 2 * i), "layer": x.dsb(la + 2 * i)}
            for i in range(5)]
    else:
        x.fallbacks.append("ball_slots_initial")

    out["timing"] = {"frame_hz": 59.94, "steps_per_frame": 3, "pit_step_divisor": 0x189C,
                     "note": "3 physics steps per video frame (timer ISR cs:2FC6). Gravity and all per-frame logic run "
                             "once per frame in the main loop; its phase relative to the 3 steps is load dependent."}
    out["found_at"] = x.found
    out["fallbacks"] = x.fallbacks
    return out


# ---------------------------------------------------------------------------
# Sensor handlers.  A small symbolic interpreter turns a handler's machine code into an
# op tree the port can run, but only if every path consists of:
#   * reads of physics variables (ball level, lockout/cooldown, extra gravity, the obj_*
#     copy of the ball, ball arrays) into registers, register arithmetic (neg, add, sub,
#     mul by constant, shifts), compares of physics variables or registers + jcc,
#   * writes of constants/registers to physics variables,
#   * writes to any other variable (score, lamps, SFX pitch...): ignored, since the
#     physics never reads them (listed in "ignored_writes").
# Anything else (calls, compares on rule state, string ops) rejects the handler; it is
# table rules and not ported.  EP1 examples: F0/F1 ramp enter/leave, FC debounce,
# FD/FE one-way gates (vx = -vx, x +-= 3).

def sensors(x, cj, extra_var, p_ds, forbidden=()):
    res = {"supported": capstone is not None, "levels": [{}, {}], "skipped": {}}
    level_var = int(cj["occlusion"]["level_var"], 16)
    lockout_var = int(cj["sensor_debounce_var"], 16) if cj.get("sensor_debounce_var") else None
    names = {level_var: "level"}
    if lockout_var is not None:
        names[lockout_var] = "lockout"
    if extra_var is not None:
        names[extra_var] = "extra_gravity"
    # gravity_and_objects (EP1 cs:11C1): mov ax,[di+X]; mov bx,[di+Y]; mov cl,[di+L]; mov [cur],cl;
    #   mov [ox],ax; mov [oy],bx; mov cx,[di+VX]; mov [ovx],cx; mov cx,[di+VY]; mov [ovy],cx
    m = x.first(rb"\x8b\x85(..)\x8b\x9d(..)\x8a\x8d(..)\x88\x0e(..)\xa3(..)\x89\x1e(..)\x8b\x8d(..)\x89\x0e(..)"
                rb"\x8b\x8d(..)\x89\x0e(..)", "obj_copy")
    arrays = {}
    if m:
        g = [u16(v) for v in m[0].groups()]
        arrays = {"ball_x": g[0], "ball_y": g[1], "ball_vx": g[6], "ball_vy": g[8]}
        names.update({g[4]: "obj_x", g[5]: "obj_y", g[7]: "obj_vx", g[9]: "obj_vy"})
        wb = x.first(rb"\xc6\x06(..)\x00\xe8", "obj_writeback", m[1])
        if wb:
            names[u16(wb[0].group(1))] = "writeback"
    # event_cooldown is tested right before the dispatch call in ball_pixel_scan (EP1 cs:16DF)
    ec = x.first(rb"\x80\x3e(..)\x00\x75.\xe8(..)\x8a\x26", "event_cooldown")
    if ec:
        names[u16(ec[0].group(1))] = "event_cooldown"
    am = x.first(rb"\x83\xbd(..)\x00\x74.\x81\xbd(..)\x40\x01", "active_array")
    if am:
        arrays["ball_active"] = u16(am[0].group(1))
    for arr, base in arrays.items():
        for i in range(5):
            names[base + 2 * i] = f"{arr}.{i}"
    res["vars"] = {v: hex(k) for k, v in names.items()}
    forbidden = set(forbidden) - set(names)
    res["forbidden_vars"] = sorted(hex(v) for v in forbidden)
    trig = cj["trigger_table"]
    null_ip = int(trig["null_handler"], 16)
    if capstone is None:
        return res
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)
    ins = next(md.disasm(x.code[null_ip:null_ip + 3], null_ip))
    exit_ip = int(ins.op_str, 16) if ins.mnemonic == "jmp" else None
    res["exit_ip"] = hex(exit_ip) if exit_ip else None
    JCC = {"jne": "ne", "je": "eq", "jb": "b", "jae": "ae", "ja": "a", "jbe": "be",
           "jl": "lt", "jge": "ge", "jg": "gt", "jle": "le"}
    REG16 = {"ax", "bx", "cx", "dx"}
    ignored = set()

    class Reject(Exception):
        pass

    def mem(op):
        mm = re.fullmatch(r"(byte|word) ptr \[(0x[0-9a-f]+)\]", op.strip())
        return (mm.group(1), int(mm.group(2), 16)) if mm else None

    def imm(op):
        try:
            return int(op.strip(), 0)
        except ValueError:
            return None

    def interp(ip, regs, depth=0, seen=None):
        seen = set() if seen is None else seen
        ops = []
        regs = dict(regs)
        while True:
            if ip == exit_ip:
                return ops
            if ip in seen or depth > 24 or len(seen) > 400:
                raise Reject("loop")
            seen.add(ip)
            i = next(md.disasm(x.code[ip:ip + 8], ip), None)
            if i is None:
                raise Reject("decode")
            mn = i.mnemonic
            a = [t.strip() for t in i.op_str.split(",")] if i.op_str else []
            nxt = ip + i.size

            def val(o):
                if o in REG16:
                    if regs.get(o) is None:
                        raise Reject(f"undefined {o}")
                    return regs[o]
                c = imm(o)
                if c is not None:
                    return ["const", c]
                mm_ = mem(o)
                if mm_:
                    if mm_[1] not in names:
                        raise Reject(f"read {mm_[1]:#x}")
                    return ["var", names[mm_[1]]]
                raise Reject(f"operand {o}")

            if mn == "nop":
                ip = nxt
                continue
            if mn == "jmp":
                ip = int(a[0], 16)
                continue
            if mn == "mov" and len(a) == 2:
                d = mem(a[0])
                if d and d[1] in forbidden:
                    raise Reject(f"writes physics state {d[1]:#x}")
                if d:
                    if d[1] in names:
                        ops.append({"op": "set", "var": names[d[1]], "expr": val(a[1])})
                    else:
                        ignored.add(hex(d[1]))
                    ip = nxt
                    continue
                if a[0] in REG16:
                    regs[a[0]] = val(a[1])
                    ip = nxt
                    continue
                raise Reject(f"insn {mn} {i.op_str}")
            if mn in ("add", "sub", "inc", "dec", "or", "and") and a and mem(a[0]):
                d = mem(a[0])
                if d[1] in forbidden:
                    raise Reject(f"writes physics state {d[1]:#x}")
                if d[1] not in names:
                    ignored.add(hex(d[1]))
                    ip = nxt
                    continue
                if mn in ("inc", "dec"):
                    e = ["add", ["var", names[d[1]]], ["const", 1 if mn == "inc" else -1]]
                elif mn in ("add", "sub"):
                    c = val(a[1])
                    e = ["add", ["var", names[d[1]]], c if mn == "add" else ["neg", c]]
                else:
                    raise Reject(f"insn {mn} on physics var")
                ops.append({"op": "set", "var": names[d[1]], "expr": e})
                ip = nxt
                continue
            if mn == "neg" and a[0] in REG16:
                regs[a[0]] = ["neg", val(a[0])]
                ip = nxt
                continue
            if mn in ("add", "sub") and a[0] in REG16:
                c = val(a[1])
                regs[a[0]] = ["add", val(a[0]), c if mn == "add" else ["neg", c]]
                ip = nxt
                continue
            if mn in ("shl", "shr", "sar") and a[0] in REG16 and imm(a[1]) is not None:
                regs[a[0]] = [mn, val(a[0]), ["const", imm(a[1])]]
                ip = nxt
                continue
            if mn == "mul" and a == ["cx"]:
                regs["ax"] = ["mul", val("ax"), val("cx")]
                regs["dx"] = None
                ip = nxt
                continue
            if mn == "cmp" and len(a) == 2:
                lhs = val(a[0])
                size = 8 if a[0].startswith("byte") else 16
                rhs = val(a[1])
                j = next(md.disasm(x.code[nxt:nxt + 4], nxt))
                cond = JCC.get(j.mnemonic)
                if cond is None:
                    raise Reject(f"branch {j.mnemonic}")
                taken = interp(int(j.op_str, 16), regs, depth + 1, set(seen))
                fall = interp(j.address + j.size, regs, depth + 1, set(seen))
                if taken != fall:
                    ops.append({"op": "if", "lhs": lhs, "cmp": cond, "rhs": rhs, "size": size,
                                "then": taken, "else": fall})
                else:
                    ops.extend(taken)
                return ops
            raise Reject(f"insn {mn} {i.op_str}")

    for level in (0, 1):
        for v, info in (cj.get("sensors") or [{}, {}])[level].items():
            h = int(info["handler_ip"], 16)
            ignored.clear()
            try:
                ops = interp(h, {})
            except (Reject, StopIteration) as e:
                res["skipped"][f"{level}:{v}"] = f"{info['handler_ip']}: {e}"
                continue
            if ops:
                ent = {"handler_ip": info["handler_ip"], "always": info.get("always"), "ops": ops}
                if ignored:
                    ent["ignored_writes"] = sorted(ignored)
                res["levels"][level][v] = ent
    res["note"] = ("per frame per ball (ball_pixel_scan EP1 cs:1679): each pixel of the 15x14 box classed 'sensor' for "
                   "the ball's level fires if (v==0xFE or lockout==0) and event_cooldown==0; the handler for the current "
                   "level runs (non-'always' handlers are skipped while tilted). ops: set var=expr; if lhs cmp rhs "
                   "(size 8/16 bits; b/ae/a/be unsigned, lt/ge/gt/le signed). expr: [const n] [var name] [neg e] "
                   "[add e e] [mul e e] [shl|shr|sar e e], 16-bit wrapping.")
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tables", nargs="*", type=int)
    ap.add_argument("--print", action="store_true", help="print a one-line summary per table")
    a = ap.parse_args()
    tables = a.tables or list(range(1, 14))
    for n in tables:
        d = export_table(n)
        path = os.path.join(ROOT, "extracted", "tables", f"EP{n}", "engine.json")
        with open(path, "w") as f:
            json.dump(d, f, separators=(",", ":"))
        fl = d["flippers"]
        print(f"EP{n}: params={d['params']['values']} caps={list(d['integration']['step_cap'].values())} "
              f"flippers={[(d['flipper_groups'][f['group']]['key'], f['group'], len(f['positions'][9]), f.get('sprite', {}).get('frames', [''])[0]) for f in fl]} "
              f"sensors={[sorted(l) for l in d['sensors']['levels']]} fallbacks={d['fallbacks']} -> {os.path.relpath(path, ROOT)}")
        if a.print:
            print(json.dumps({k: v for k, v in d.items() if k not in ("normals", "pushout", "wall", "occlusion", "flippers",
                                                                     "probe_ring", "ball")}, indent=1)[:4000])


if __name__ == "__main__":
    main()
