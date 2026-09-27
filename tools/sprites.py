"""Extract non-playfield graphics from Epic Pinball table executables.

Usage:  .venv/bin/python tools/sprites.py [original_dir] [out_dir] [table ...]

For every table n (default 1..13) writes
  <out>/tables/EPn/sprites/*.png      RGBA PNGs (alpha 0 = transparent pixel)
  <out>/tables/EPn/sprites/sprites.json
  <out>/tables/EPn/sprites/_sheet_*.png   contact sheets for eyeballing
and for EP8 additionally
  <out>/tables/EP8/playfield_composited.png        (all toy overlays shown)
  <out>/tables/EP8/playfield_composited_robot.png  (+ centre robot set)

Everything is located by code signatures in the engine (the same hand-written
routines are linked into every table EXE), not by hard-coded offsets.  See
docs/formats/sprites.md for the formats and the EP1 disassembly addresses.

Sprite formats (all little-endian u16 headers):
  planar  : x, y, w4, h, then h rows of [plane0 w4 bytes][plane1][plane2][plane3]
            pixel (4*i + p) of a row is plane p byte i.  Drawn opaque by the
            Mode X blitter (EP1 cs:472f).  x,y are absolute playfield coords.
  chunky  : x, y, w, h, then w*h linear bytes.  ("pause" banner)
  ball    : w, h, then w*h linear bytes, index 0 = transparent.
  font8   : 8 bytes per glyph (7 rows used), MSB = leftmost pixel, from ' '.
  font5   : 5 bytes per glyph, 5 rows, bits 7..3 = 5 columns, from ' '.
"""
import json
import os
import re
import struct
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import epexe  # noqa: E402

# ---------------------------------------------------------------- decoding


def valid_planar(d, o):
    if o < 0 or o + 8 > len(d):
        return False
    x, y, w4, h = struct.unpack_from("<4H", d, o)
    return x < 320 and y < 400 and 1 <= w4 <= 30 and 1 <= h <= 100 and o + 8 + w4 * 4 * h <= len(d)


def decode_planar(d, o):
    x, y, w4, h = struct.unpack_from("<4H", d, o)
    raw = np.frombuffer(d[o + 8 : o + 8 + w4 * 4 * h], np.uint8).reshape(h, 4, w4)
    img = np.zeros((h, w4 * 4), np.uint8)
    for p in range(4):
        img[:, p::4] = raw[:, p, :]
    return x, y, img, 8 + w4 * 4 * h


def decode_chunky(d, o, header=4):
    if header == 8:
        x, y, w, h = struct.unpack_from("<4H", d, o)
    else:
        (w, h), x, y = struct.unpack_from("<2H", d, o), None, None
    img = np.frombuffer(d[o + header : o + header + w * h], np.uint8).reshape(h, w).copy()
    return x, y, img, header + w * h


def decode_font(d, o, count, bpg, rows, cols, first_bit=7):
    glyphs = []
    for g in range(count):
        b = d[o + g * bpg : o + g * bpg + rows]
        img = np.zeros((rows, cols), np.uint8)
        for r in range(rows):
            for c in range(cols):
                img[r, c] = (b[r] >> (first_bit - c)) & 1
        glyphs.append(img)
    return glyphs


# ---------------------------------------------------------------- palette


def find_palette(exe, n, extracted_dir):
    """The fade-in routine does: lea di,[work]; mov cx,300h; mov al,0; rep stosb; lea si,[pal]."""
    cb = exe.image_off(exe.entry_cs)
    m = re.search(rb"\x8d\x3e..\xb9\x00\x03\xb0\x00\xf3\xaa\x8d\x36(..)", exe.data[cb:], re.S)
    if m:
        off = exe.image_off(epexe.data_segment(exe), struct.unpack("<H", m.group(1))[0])
        return np.frombuffer(exe.data[off : off + 768], np.uint8).reshape(256, 3), off
    pj = os.path.join(extracted_dir, "tables", f"EP{n}", "palette.json")
    return np.array(json.load(open(pj)), np.uint8), None


# ---------------------------------------------------------------- locating


def _u16(b):
    return struct.unpack("<H", b)[0]


def _table(d, off, count):
    return list(struct.unpack_from(f"<{count}H", d, off))


def locate(exe):
    """Find every sprite source via engine code signatures. Returns dict of finds."""
    d = exe.data
    cs = exe.entry_cs
    cb = exe.image_off(cs)
    code = d[cb:]
    ds = epexe.data_segment(exe)
    f = {"cs": cs, "ds": ds}

    # Lamp / overlay table:  mov dx,SEG; mov ds,dx; mov si,[bx+TBL]; push si; call far blit
    m = re.search(rb"\xba(..)\x8e\xda\x8b\xb7(..)\x56\x9a", code, re.S)
    if m:
        seg, tbl = _u16(m.group(1)), _u16(m.group(2))
        f["objseg"] = seg
        f["lamp"] = dict(seg=seg, tbl=tbl, code=cb + m.start(), cs_ip=m.start())

    # Bounded tables:  cmp bx,N ; jb/jbe ; mov bx,N ; [push bx] ; shl bx,1 ; mov si,[cs:]bx+TBL
    f["bounded"] = []
    for m in re.finditer(rb"\x83\xfb(.)(\x72|\x76)\x03\xbb(.)\x00(\x53)?\xd1\xe3(\x2e)?\x8b\xb7(..)", code, re.S):
        bound, jcc, clamp = m.group(1)[0], m.group(2), m.group(3)[0]
        count = bound + 1 if jcc == b"\x72" or clamp == bound else bound + 1
        seg = cs if m.group(5) else None  # None = current DS, resolved below
        f["bounded"].append(dict(bound=bound, clamp=clamp, count=count, seg=seg, tbl=_u16(m.group(6)),
                                 cs_ip=m.start(), ctx=code[max(0, m.start() - 8) : m.start()]))

    # Frame-counter animations: mov bx,cs:[CNT]; shl bx,1; mov si,cs:[bx+TBL]; counter wraps at N
    f["anim"] = []
    for m in re.finditer(rb"\x2e\x8b\x1e(..)\xd1\xe3\x2e\x8b\xb7(..)", code, re.S):
        cnt, tbl = _u16(m.group(1)), _u16(m.group(2))
        w = re.search(rb"\x2e\x83\x3e" + re.escape(m.group(1)) + rb"(.)\x76", code[max(0, m.start() - 64) : m.start()], re.S)
        n = w.group(1)[0] + 1 if w else None
        if not any(a["tbl"] == tbl for a in f["anim"]):
            f["anim"].append(dict(tbl=tbl, count=n, cs_ip=m.start()))

    # Other data-segment tables indexed via mov si,[si+TBL] (EP6)
    # (not generically handled; picked up by the heuristic scan below)

    # Ball template: lea si,[BALL]; lea di,[buf]; mov cx,0D6h; rep movsb
    m = re.search(rb"\x8d\x36(..)\x8d\x3e..\xb9\xd6\x00\xf3\xa4", code, re.S)
    if m:
        f["balls"] = [exe.image_off(ds, _u16(m.group(1)))]
        f["ball_code"] = m.start()
    else:  # EP8: mov si,[bx+TBL]; lea di,[buf]; mov cx,0D6h  (per-level balls)
        m = re.search(rb"\x83\xfb(.)\x76\x03\xbb\x00\x00\xd1\xe3\x8b\xb7(..)\x8d\x3e..\xb9\xd6\x00\xf3\xa4", code, re.S)
        if m:
            f["balls"] = [exe.image_off(ds, p) for p in _table(d, exe.image_off(ds, _u16(m.group(2))), m.group(1)[0] + 1)]
            f["ball_code"] = m.start()
    if "ball_code" in f:
        seg = code[f["ball_code"] : f["ball_code"] + 0x80]
        f["ball_occlusion"] = [(a, b) for a, b in re.findall(rb"\xb3(.)\xb7(.)", seg, re.S)]
        f["ball_occlusion"] = [(a[0], b[0]) for a, b in f["ball_occlusion"]]

    # Pause banner: mov dx,SEG; mov ds,dx; lea si,[P]; mov cx,[si]; mov ax,[si+2]; add si,4
    m = re.search(rb"\xba(..)\x8e\xda\x8d\x36(..)\x8b\x0c\x8b\x44\x02\x83\xc6\x04", code, re.S)
    if m:
        f["pause"] = exe.image_off(_u16(m.group(1)), _u16(m.group(2)))

    # Plunger: lea si,[P]; mov [P+2],ax; mov ax,SEG; mov es,ax; cld; push bp ...; add di,PAGEOFS
    m = re.search(rb"\x8d\x36(..)\xa3..\xb8(..)\x8e\xc0\xfc\x55\x8b\xec\xad\x8b\xc8\xad\x8b\xf8\xd1\xe7\x26\x8b\xbd..\x81\xc7(..)", code, re.S)
    if m:
        f["plunger"] = exe.image_off(_u16(m.group(2)), _u16(m.group(1)))
        f["display_rows"] = _u16(m.group(3)) // 80

    # Fonts
    oseg = f.get("objseg", ds)
    m = re.search(rb"\x8d\x36(..)\x2c\x20\x3c\x80", code, re.S)
    if m:
        f["font8"] = exe.image_off(oseg, _u16(m.group(1)))
    f5 = sorted({_u16(x) for x in re.findall(rb"\xbb\x05\x00\xf7\xe3\x8b\xd8\xb1\x01\xb2\x05\x53\x57\x8a\x87(..)", code, re.S)})
    # disp8 operand is (font - 0x10000) style negative; stored as unsigned u16 == offset
    f["font5"] = [exe.image_off(oseg, v) for v in f5]

    # EP8 centre "robot" sets in extra segment: mov dx,SEG; mov ds,dx; mov cx,6; mov bx,0; lea di,[A]; cmp al,1; je; lea di,[B]
    m = re.search(rb"\xba(..)\x8e\xda\xb9(.)\x00\xbb\x00\x00\x8d\x3e(..)\x3c\x01\x74\x04\x8d\x3e(..)", code, re.S)
    if m:
        seg = _u16(m.group(1))
        f["sets"] = dict(seg=seg, count=m.group(2)[0], on=_u16(m.group(3)), off=_u16(m.group(4)), cs_ip=m.start())
    return f


def scan_pointer_tables(exe, exclude, minrun=3):
    """Heuristic: runs of u16 that all point at plausible planar headers (any relocated segment)."""
    d = exe.data
    top, bot, _ = epexe.find_playfield_segments(exe)
    pfs, pfe = exe.image_off(top), exe.image_off(bot) + 64000
    res = []
    for seg in sorted(exe.seg_values):
        if seg in (top, bot):
            continue
        base = exe.image_off(seg)
        for par in (0, 1):
            o, run = 0x400 + par, []
            while o < len(d) - 1:
                if pfs <= o < pfe:
                    o, run = pfe + par, []
                    continue
                v = struct.unpack_from("<H", d, o)[0]
                t = base + v
                if v and valid_planar(d, t) and not (pfs <= t < pfe):
                    run.append((o, t))
                else:
                    if len(run) >= minrun and len({t for _, t in run}) >= max(2, len(run) // 2):
                        if not any(abs(run[0][0] - e) < 2 * len(run) for e in exclude):
                            res.append((seg, run[0][0], [t for _, t in run]))
                    run = []
                o += 2
    return res


# Visual identifications of tables that no generic code signature classifies
# (keyed by table number and file offset of the pointer table).
NAME_GUESS = {
    (6, "0x26560"): "centre award plaque (15 captions + blank)",
    (6, "0x29817"): "falling apple animation",
    (2, "0x3d8fc"): "spinner rotation frames",
    (3, "0x3bce2"): "spinner rotation frames",
    (4, "0x2f05d"): "ball-lock indicator: [0] empty background, [1..6] ball in slot",
    (9, "0x3b20f"): "two-digit red LED counter frames",
    (10, "0x3c2e0"): "eye blink (sequence ping-pongs open->closed->open)",
}

# ---------------------------------------------------------------- output


class Out:
    def __init__(self, sdir, pal, pf):
        self.sdir, self.pal, self.pf = sdir, pal, pf
        self.entries = []
        self.imgs = {}

    def add(self, name, img, fmt, off, alpha=None, x=None, y=None, group="misc", extra=None, scale_font=False):
        if alpha is None:
            alpha = np.full(img.shape, 255, np.uint8)
        if scale_font:
            rgba = np.zeros(img.shape + (4,), np.uint8)
            rgba[img == 1] = (255, 255, 255, 255)
        else:
            rgba = np.dstack([self.pal[img], alpha])
        Image.fromarray(rgba).save(os.path.join(self.sdir, name + ".png"))
        e = dict(name=name, group=group, format=fmt, w=int(img.shape[1]), h=int(img.shape[0]), file_offset=hex(off))
        if x is not None:
            e["x"], e["y"] = int(x), int(y)
            xa = x & ~3
            ph, pw = img.shape
            if xa + pw <= 320 and y + ph <= 400:
                e["playfield_match"] = round(float((self.pf[y : y + ph, xa : xa + pw] == img).mean()), 3)
        if extra:
            e.update(extra)
        self.entries.append(e)
        self.imgs[name] = (rgba, group)
        return e

    def sheets(self):
        groups = {}
        for name, (rgba, g) in self.imgs.items():
            groups.setdefault(g, []).append((name, rgba))
        for g, items in groups.items():
            cols = 12 if g != "font" else 32
            pad = 2
            cw = max(i.shape[1] for _, i in items) + pad
            ch = max(i.shape[0] for _, i in items) + pad
            rows = (len(items) + cols - 1) // cols
            sheet = np.zeros((rows * ch, min(cols, len(items)) * cw, 4), np.uint8)
            sheet[..., :3] = 64
            sheet[..., 3] = 255
            for k, (_, i) in enumerate(items):
                r, c = divmod(k, cols)
                a = i[..., 3:4] / 255.0
                cell = sheet[r * ch : r * ch + i.shape[0], c * cw : c * cw + i.shape[1]]
                cell[..., :3] = (i[..., :3] * a + cell[..., :3] * (1 - a)).astype(np.uint8)
            s = 3 if g in ("font", "ball", "digit") else 2
            Image.fromarray(sheet).resize((sheet.shape[1] * s, sheet.shape[0] * s), Image.NEAREST).save(
                os.path.join(self.sdir, f"_sheet_{g}.png"))


def extract_table(n, src, out):
    exe = epexe.load(os.path.join(src, f"EP{n}.EXE"))
    d = exe.data
    pf = epexe.playfield(exe)
    pal, pal_off = find_palette(exe, n, out)
    tdir = os.path.join(out, "tables", f"EP{n}")
    sdir = os.path.join(tdir, "sprites")
    os.makedirs(sdir, exist_ok=True)
    for fn in os.listdir(sdir):
        if fn.endswith(".png"):
            os.remove(os.path.join(sdir, fn))
    f = locate(exe)
    o = Out(sdir, pal, pf)
    known_tables = []
    notes = []
    sequences = {}

    # ---- lamps / overlays
    lamp_records = []
    if "lamp" in f:
        L = f["lamp"]
        toff = exe.image_off(L["seg"], L["tbl"])
        known_tables.append(toff)
        base = exe.image_off(L["seg"])
        ptrs, k = [], 0
        while True:  # table runs until the first sprite it points at
            p = struct.unpack_from("<H", d, toff + 2 * k)[0]
            if not valid_planar(d, base + p):
                break
            ptrs.append(p)
            k += 1
            if toff + 2 * k >= min(base + q for q in ptrs):
                break
        # Records are packed back to back; a header whose pixel data would run into
        # the next record is a disabled slot (EP8 lamp 36) - flag it as dummy.
        offs = sorted({base + q for q in ptrs})
        for i, p in enumerate(ptrs):
            src_off = base + p
            x, y, img, size = decode_planar(d, src_off)
            nxt = [q for q in offs if q > src_off]
            dummy = img.size <= 16 or (bool(nxt) and src_off + size > nxt[0])
            name = f"lamp{i // 2:03d}_{'a' if i % 2 == 0 else 'b'}"
            e = o.add(name, img, "planar", src_off, x=x, y=y, group="lamp",
                      extra=dict(index=i, lamp=i // 2, state="a(state1)" if i % 2 == 0 else "b(state2)",
                                 dummy=bool(dummy)))
            lamp_records.append((i, x, y, img, dummy))
        f["lamp"]["count"] = len(ptrs)
        uses = {}
        for p in ptrs:
            uses[base + p] = uses.get(base + p, 0) + 1
        for e in o.entries:
            if e["group"] == "lamp" and uses.get(int(e["file_offset"], 16), 1) > 1:
                e["shared_by_slots"] = uses[int(e["file_offset"], 16)]

    # ---- bounded tables: flippers, big score digits, misc
    for bt in f["bounded"]:
        seg = bt["seg"] if bt["seg"] is not None else f.get("objseg", f["ds"])
        if bt["seg"] is None:
            # DS-relative tables: DS at that point is the object segment in all
            # tables we checked (mov dx,SEG / mov ds,dx precedes the routine).
            pass
        toff = exe.image_off(seg, bt["tbl"])
        if toff + 2 * bt["count"] > len(d):
            continue
        ptrs = _table(d, toff, bt["count"])
        base = exe.image_off(seg)
        if bt["count"] == 11 and bt["bound"] == 10 and valid_planar(d, base + ptrs[0]) \
                and decode_planar(d, base + ptrs[0])[2].size <= 16:
            notes.append(f"big score digit table at {hex(toff)} is a 1x1 stub (big digits unused; score presumably drawn with the dot-matrix font)")
            continue
        if not all(valid_planar(d, base + p) for p in ptrs):
            # try the data segment (DS) as base (EP4 misc table)
            base = exe.image_off(f["ds"])
            toff = exe.image_off(f["ds"], bt["tbl"])
            ptrs = _table(d, toff, bt["count"])
            if not all(valid_planar(d, base + p) for p in ptrs):
                continue
        known_tables.append(toff)
        recs = [decode_planar(d, base + p) + (base + p,) for p in ptrs]
        if bt["count"] == 11 and bt["bound"] == 10:
            kind = "digit"
            if all(r[2].size <= 16 for r in recs):
                notes.append(f"big score digit table at {hex(toff)} is a 1x1 stub (big digits unused; score presumably drawn with the dot-matrix font)")
                continue
            names = [f"digit_{i}" for i in range(10)] + ["digit_blank"]
        elif bt["ctx"].endswith(b"\x8e\xda") or (bt["seg"] == f["cs"] and recs[0][1] > 300):
            kind = "flipper"
            # Consecutive frames sharing x,y belong to one flipper (EP4/EP12 have
            # extra upper flippers after the main left/right pair).
            names, k, fr, prev = [], -1, 0, None
            for r in recs:
                if (r[0], r[1]) != prev:
                    k, fr, prev = k + 1, 0, (r[0], r[1])
                    side = "L" if r[0] + r[2].shape[1] / 2 < 160 else "R"
                names.append(f"flipper{k}{side}_{fr}")
                fr += 1
        else:
            kind = "anim"
            names = [f"table{bt['tbl']:04x}_{i}" for i in range(len(recs))]
        seen = {}
        seq = []
        for i, ((x, y, img, size, so), nm) in enumerate(zip(recs, names)):
            if so in seen:
                seq.append(seen[so])
                continue
            seen[so] = nm
            seq.append(nm)
            extra = dict(index=i, table_file_offset=hex(toff))
            if (n, hex(toff)) in NAME_GUESS:
                extra["name_guess"] = NAME_GUESS[(n, hex(toff))]
            if kind == "flipper":
                extra["note"] = "frame 0 = fully raised ... last = at rest (verified visually on EP1/EP4/EP10/EP12)"
            o.add(nm, img, "planar", so, x=x if kind != "digit" else None, y=y if kind != "digit" else None,
                  group=kind, extra=extra)
        sequences[f"{kind}@{hex(toff)}"] = seq

    for a in f["anim"]:
        toff = exe.image_off(f["cs"], a["tbl"])
        known_tables.append(toff)
        cnt = a["count"] or 6
        base = exe.image_off(f["cs"])
        ptrs = _table(d, toff, cnt)
        if not all(valid_planar(d, base + p) for p in ptrs):
            continue
        seen, seq = {}, []
        for i, p in enumerate(ptrs):
            if base + p in seen:
                seq.append(seen[base + p])
                continue
            x, y, img, _ = decode_planar(d, base + p)
            nm = f"anim{a['tbl']:04x}_{i}"
            seen[base + p] = nm
            seq.append(nm)
            o.add(nm, img, "planar", base + p, x=x, y=y, group="anim",
                  extra=dict(index=i, table_file_offset=hex(toff), note="cycled by a frame counter",
                             name_guess=NAME_GUESS.get((n, hex(toff)), "unknown")))
        sequences[f"anim@{hex(toff)}"] = seq

    if "sets" in f:
        S = f["sets"]
        known_tables += [exe.image_off(S["seg"], S["on"]), exe.image_off(S["seg"], S["off"])]

    # ---- heuristic leftovers (tables not reached through a recognised code signature)
    for seg, toff, targets in scan_pointer_tables(exe, known_tables):
        guess = NAME_GUESS.get((n, hex(toff)))
        seq = []
        for i, t in enumerate(targets):
            dup = [e["name"] for e in o.entries if e["file_offset"] == hex(t)]
            if dup:
                seq.append(dup[0])
                continue
            seq.append(f"unk{toff:05x}_{i}")
            x, y, img, _ = decode_planar(d, t)
            o.add(f"unk{toff:05x}_{i}", img, "planar", t, x=x, y=y, group="anim" if guess else "unknown",
                  extra=dict(index=i, table_file_offset=hex(toff), table_seg=hex(seg),
                             name_guess=guess or "unknown",
                             note="found by pointer-table heuristic only; name_guess is from visual inspection"))
        sequences[f"heuristic@{hex(toff)}"] = seq

    # ---- ball(s)
    for i, bo in enumerate(f.get("balls", [])):
        _, _, img, _ = decode_chunky(d, bo, 4)
        alpha = np.where(img == 0, 0, 255).astype(np.uint8)
        o.add("ball" if len(f["balls"]) == 1 else f"ball_{i}", img, "ball", bo, alpha=alpha, group="ball",
              extra=dict(transparent_index=0, occlusion_ranges=[list(r) for r in f.get("ball_occlusion", [])]))

    if "pause" in f:
        x, y, img, _ = decode_chunky(d, f["pause"], 8)
        o.add("pause", img, "chunky", f["pause"], x=None, y=None, group="display",
              extra=dict(display_x=x, display_y=y, note="drawn into the split-screen display area"))

    if "plunger" in f:
        x, y, img, _ = decode_planar(d, f["plunger"])
        o.add("plunger", img, "planar", f["plunger"], x=x, y=y, group="plunger",
              extra=dict(note="y is overwritten at runtime (pull distance); drawn to both pages"))

    # ---- fonts
    if "font8" in f:
        start = f["font8"]
        end = min([x for x in f["font5"] if x > start] or [start + 96 * 8])
        cnt = min((end - start) // 8, 96)
        for gi, g in enumerate(decode_font(d, start, cnt, 8, 8, 8)):
            o.add(f"font8_{0x20 + gi:02x}", g, "font8", start + gi * 8, group="font", scale_font=True,
                  extra=dict(char=0x20 + gi))
    f5 = f["font5"]
    for fi, start in enumerate(f5):
        if len(f5) == 1:
            cnt = 71  # EP1-8: codes 0x20-0x66; 0x5E-0x66 are 9 Polish capitals; followed by the 10^n score table
        else:
            cnt = (f5[1] - f5[0]) // 5  # EP9-13: two 64-glyph fonts back to back
        for gi, g in enumerate(decode_font(d, start, cnt, 5, 5, 5)):
            o.add(f"font5{'ab'[fi] if len(f5) > 1 else ''}_{0x20 + gi:02x}", g, "font5", start + gi * 5,
                  group="font", scale_font=True, extra=dict(char=0x20 + gi))

    o.sheets()

    # ---- EP8-style composite: all "state a" overlays that differ from the playfield
    composites = {}
    if lamp_records:
        mean_a = np.mean([e.get("playfield_match", 1) for e in o.entries if e["group"] == "lamp" and e["name"].endswith("_a")])
        mean_b = np.mean([e.get("playfield_match", 1) for e in o.entries if e["group"] == "lamp" and e["name"].endswith("_b")])
        # Objects live in the overlays only in EP8 (identified by its centre-set routine).
        # (EP9/11/12 also have mean_a < mean_b, but there state a is simply "lamp lit".)
        if "sets" in f and mean_b > 0.9 and mean_a < 0.7:
            comp = pf.copy()
            drawn = []
            for i, x, y, img, dummy in lamp_records:
                if i % 2 or dummy:
                    continue
                h, w = img.shape
                xa = x & ~3
                # Later slots that sit inside an already drawn object are alternate
                # states of it (e.g. "ball held in kicker"); keep the primary art.
                if any(xa >= X - 2 and y >= Y - 2 and xa + w <= X + W + 2 and y + h <= Y + H + 2
                       for X, Y, W, H in drawn):
                    continue
                drawn.append((xa, y, w, h))
                comp[y : y + h, xa : xa + w] = img[: 400 - y, : 320 - xa]
            composites["playfield_composited"] = comp
            if "sets" in f:
                S = f["sets"]
                base = exe.image_off(S["seg"])
                c2 = comp.copy()
                for p in _table(d, base + S["on"], S["count"]):
                    x, y, img, _ = decode_planar(d, base + p)
                    h, w = img.shape
                    c2[y : y + h, (x & ~3) : (x & ~3) + w] = img
                    o.add(f"centre_set1_{len([e for e in o.entries if e['name'].startswith('centre_set1')])}", img,
                          "planar", base + p, x=x, y=y, group="centre")
                for p in _table(d, base + S["off"], S["count"]):
                    x, y, img, _ = decode_planar(d, base + p)
                    o.add(f"centre_set0_{len([e for e in o.entries if e['name'].startswith('centre_set0')])}", img,
                          "planar", base + p, x=x, y=y, group="centre")
                composites["playfield_composited_robot"] = c2
        for k, v in composites.items():
            im = Image.frombytes("P", (320, 400), v.tobytes())
            im.putpalette(pal.flatten().tolist())
            im.save(os.path.join(tdir, k + ".png"))
        if composites:
            o.sheets()

    meta = dict(
        table=n,
        palette_file_offset=hex(pal_off) if pal_off else "from palette.json",
        code_segment=hex(f["cs"]), data_segment=hex(f["ds"]), object_segment=hex(f.get("objseg", 0)),
        lamp_table=dict(file_offset=hex(exe.image_off(f["lamp"]["seg"], f["lamp"]["tbl"])),
                        entries=f["lamp"]["count"], code_cs_ip=hex(f["lamp"]["cs_ip"])) if "lamp" in f else None,
        display_rows=f.get("display_rows"),
        ball_occlusion_ranges=f.get("ball_occlusion"),
        composites=list(composites),
        sequences=sequences,
        notes=notes,
        sprites=o.entries,
    )
    with open(os.path.join(sdir, "sprites.json"), "w") as fh:
        json.dump(meta, fh, indent=1)
    return meta


def main():
    args = sys.argv[1:]
    src = args[0] if len(args) > 0 else "original"
    out = args[1] if len(args) > 1 else "extracted"
    tables = [int(a) for a in args[2:]] or list(range(1, 14))
    for n in tables:
        m = extract_table(n, src, out)
        groups = {}
        for e in m["sprites"]:
            groups[e["group"]] = groups.get(e["group"], 0) + 1
        print(f"EP{n:<2} " + " ".join(f"{g}={c}" for g, c in sorted(groups.items()))
              + (f"  composites={m['composites']}" if m["composites"] else "") + ("  " + "; ".join(m["notes"]) if m["notes"] else ""))


if __name__ == "__main__":
    main()
