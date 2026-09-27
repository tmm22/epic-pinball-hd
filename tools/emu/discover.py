#!/usr/bin/env python3
"""Find, per table EXE, every code address and variable the emulator harness needs.

The harness (ep_emu.py) runs pieces of the ORIGINAL table code: boot to the top of the
main loop, the ball-relevant fragments of the main loop, physics_step, and (rules mode)
the sensor scan.  All 13 tables share one engine, but every EXE has its own layout, and
some tables differ in structure (EP8 has no plunger lane and no serve; EP4 draws 4 flipper
outlines and EP12 3; EP7/EP8 use flipper colour 0xFF; EP8's wall threshold is a variable; EP11-13
draw two-row outlines; EP5/EP6 use one counter for sensor lockout and kicker cooldown; EP9-13
keep one sensor lockout per ball; the CS keyboard flags move around).  This module finds everything by byte
signatures / structural search in the user's own original/EPn.EXE.  The signatures are
shapes of EP1 code (cs:XXXX below = EP1 code segment 0x3223), generalised with wildcards.

Result per table: tools/emu/tables/EPn.json
  {"table": n, "exe_sha1": ..., "generated_by": "tools/emu/discover.py",
   "auto": {config...},          # what the search found (regenerated on every run)
   "evidence": {field: "cs:XXXX" or note},
   "missing": [fields not found], "notes": [...],
   "overrides": {config subset}} # hand-maintained; preserved when the file is rewritten
The effective config is auto with overrides applied on top (a shallow per-key replace;
"ds_vars" and "cs_vars" are merged per name).

Usage:
  .venv/bin/python tools/emu/discover.py            # all tables: write tables/EPn.json, print a summary
  .venv/bin/python tools/emu/discover.py 1 8 -v     # some tables, verbose
  .venv/bin/python tools/emu/discover.py --check    # EP1: auto vs the hand-verified ep_emu.EP1 dict
Nothing from the game is stored: only offsets, counts and small integers found in the code.
"""
import argparse
import hashlib
import json
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import epexe  # noqa: E402

TABLE_DIR = os.path.join(HERE, 'tables')
FORMAT = 'epic-pinball-emu-table/1'


def u16(b, o=0):
    return struct.unpack_from('<H', b, o)[0]


def s16(b, o=0):
    return struct.unpack_from('<h', b, o)[0]


def w(v):
    """struct-pack a 16-bit value for use inside a regex."""
    return re.escape(struct.pack('<H', v & 0xFFFF))


class NotFound(Exception):
    pass


class Code:
    def __init__(self, n, exe_path=None):
        self.n = n
        self.path = exe_path or os.path.join(ROOT, 'original', f'EP{n}.EXE')
        self.exe = epexe.load(self.path)
        self.cs = self.exe.entry_cs
        self.ds = epexe.data_segment(self.exe)
        self.cbase = self.exe.image_off(self.cs)
        self.dbase = self.exe.image_off(self.ds)
        self.code = self.exe.data[self.cbase:self.cbase + 0x10000]
        self.sha1 = hashlib.sha1(self.exe.data).hexdigest()
        self.evidence = {}
        self.missing = []
        self.notes = []

    def find(self, pat, name=None, start=0, end=None, all_=False):
        end = len(self.code) if end is None else end
        ms = list(re.finditer(pat, self.code[start:end], re.S))
        if all_:
            return [(m, m.start() + start) for m in ms]
        if not ms:
            return None
        m = ms[0]
        if name:
            self.evidence[name] = f'cs:{m.start() + start:04x}'
        return m, m.start() + start

    def need(self, pat, name, start=0, end=None):
        r = self.find(pat, name, start, end)
        if r is None:
            raise NotFound(name)
        return r

    def rel16(self, at):
        """Target of a near call/jmp (e8/e9 rel16) whose opcode is at `at`."""
        return (at + 3 + s16(self.code, at + 1)) & 0xFFFF

    def rel8(self, at):
        """Target of a short jump (jcc/eb rel8) whose opcode is at `at`."""
        return (at + 2 + struct.unpack_from('<b', self.code, at + 1)[0]) & 0xFFFF

    def follow_jmps(self, a, limit=8):
        """Follow unconditional jmp chains (e9/eb) starting at a."""
        for _ in range(limit):
            op = self.code[a]
            if op == 0xE9:
                a = self.rel16(a)
            elif op == 0xEB:
                a = self.rel8(a)
            else:
                break
        return a

    def dsw(self, off):
        return s16(self.exe.data, self.dbase + off)


def _isr_key_map(c, start):
    """Parse the keyboard ISR (int 9): scancode -> [(cs_var, value)], plus the last-scancode var.
    EP1 cs:314B: cmp al,SC; je/jne ...; mov byte cs:[X],V; jmp exit ... mov cs:[X],al."""
    from capstone import Cs, CS_ARCH_X86, CS_MODE_16
    md = Cs(CS_ARCH_X86, CS_MODE_16)
    md.detail = False
    insns = []
    a = start
    while a < start + 0x400:
        i = next(md.disasm(c.code[a:a + 16], a), None)
        if i is None:
            break
        insns.append(i)
        a += i.size
        if i.mnemonic == 'iret':
            break
    labels = {}
    for k, i in enumerate(insns[:-1]):
        j = insns[k + 1]
        m = re.fullmatch(r'al, (0x[0-9a-f]+|\d+)', i.op_str)
        if i.mnemonic == 'cmp' and m and j.mnemonic in ('je', 'jne'):
            sc = int(m.group(1), 0)
            if j.mnemonic == 'je':
                labels.setdefault(int(j.op_str, 16), set()).add(sc)
            else:
                labels.setdefault(j.address + j.size, set()).add(sc)
    keys, last = {}, None
    cur = None
    for i in insns:
        if i.address in labels:
            cur = labels[i.address]
        m = re.fullmatch(r'byte ptr cs:\[(0x[0-9a-f]+)\], (0x[0-9a-f]+|\d+)', i.op_str)
        if i.mnemonic == 'mov' and m and cur:
            for sc in cur:
                keys.setdefault(sc, []).append((int(m.group(1), 16), int(m.group(2), 0)))
        m = re.fullmatch(r'byte ptr cs:\[(0x[0-9a-f]+)\], al', i.op_str)
        if i.mnemonic == 'mov' and m:
            last = int(m.group(1), 16)
        if i.mnemonic in ('jmp', 'iret', 'ret'):
            cur = None
    return keys, last, insns[-1].address + insns[-1].size if insns else start


def discover(n, exe_path=None):
    """Return (config, evidence, missing, notes) for table n.  Raises NotFound only for the
    pieces without which nothing can run (frame_sync, physics_step, main loop)."""
    c = Code(n, exe_path)
    ev = c.evidence
    cfg = dict(exe=f'EP{n}.EXE', cs=c.cs, ds=c.ds)
    dsv, csv = {}, {}

    # ---- frame_sync (EP1 cs:1243): mov byte cs:[mode],0; mov dx,3dah; in; and al,8; jne; cmp cs:[vsync],0; je
    m, fs = c.need(rb'\x2e\xc6\x06(..)\x00\xba\xda\x03\xec\x24\x08\x75.\x2e\x80\x3e(..)\x00\x74.', 'frame_sync')
    cfg['frame_sync'] = fs
    csv['isr_frame_mode'] = u16(m.group(1))
    csv['vsync_flag'] = u16(m.group(2))
    # no-timer path (cs:125C): cmp byte [opt_no_timer],1; jne; call physics_step x3
    m, a = c.need(rb'\x80\x3e(..)\x01\x75.\xe8(..)\xe8..\xe8..', 'physics_step', fs, fs + 0x40)
    dsv['opt_no_timer'] = u16(m.group(1))
    cfg['physics_step'] = c.rel16(a + 7)
    # cs:127F: mov byte cs:[isr_steps_left],3 ; mov byte cs:[vsync],0
    #   (EP5/EP6 store the two in the other order)
    m, a = c.need(rb'\x2e\xc6\x06(..)\x03', 'isr_steps_left', fs + 0x20, fs + 0x60)
    csv['isr_steps_left'] = u16(m.group(1))
    # end of retrace wait then jmp main_loop (cs:1290..129F)
    m, a = c.need(rb'\xba\xda\x03\xec\x24\x08\x75\xfb', 'main_loop_jmp', a, a + 0x30)
    j = c.find(rb'\xe9', None, a + 8, a + 0x20)
    if j is None:
        raise NotFound('main_loop')
    cfg['main_loop'] = c.rel16(j[1])
    ev['main_loop'] = f'jmp at cs:{j[1]:04x}'

    # ---- physics_step head (cs:1724): pusha; push es; mov byte [collided],0; mov di,0; cmp word [di+active],1
    ps = cfg['physics_step']
    m, _ = c.need(rb'\x60\x06\xc6\x06(..)\x00\xbf\x00\x00\x83\xbd(..)\x01', 'physics_step_head', ps, ps + 16)
    dsv['collided'] = u16(m.group(1))
    dsv['ball_active'] = u16(m.group(2))
    # slot loop end: add di,2; cmp di,N  -> number of ball slots
    m, _ = c.need(rb'\x83\xc7\x02\x83\xff(.)\x75', 'ball_slots', ps, ps + 0x30)
    cfg['ball_slots'] = m.group(1)[0] // 2
    # cs:1740: mov byte [flipper_contact],0; mov byte [kick_strength],0; then integration
    m, a = c.need(rb'\xc6\x06(..)\x00\xc6\x06(..)\x00\x8b\x85', 'contact_clear', ps, ps + 0x40)
    dsv['flipper_contact'] = u16(m.group(1))
    dsv['kick_strength'] = u16(m.group(2))
    integ = (rb'\x8b\x85(..)\x01\x85(..)\x8b\x85\2\x3d\x00\x00\x7c.\xc1\xe8\x07\x3d.\x00\x76.\xb8.\x00'
             rb'\x81\xbd\2..\x7e\x06\xc7\x85\2..\x01\x85(..)')
    ms = c.find(integ, None, ps, ps + 0x200, all_=True)
    if len(ms) < 2:
        raise NotFound('integration')
    ev['integration'] = f'cs:{ms[0][1]:04x}, cs:{ms[1][1]:04x}'
    dsv['ball_vx'], dsv['ball_accx'], dsv['ball_x'] = (u16(ms[0][0].group(k)) for k in (1, 2, 3))
    dsv['ball_vy'], dsv['ball_accy'], dsv['ball_y'] = (u16(ms[1][0].group(k)) for k in (1, 2, 3))
    # wall loop layer test (cs:1855): cmp byte [di+layer],1; jne +6; mov dh,0
    r = c.find(rb'\x80\xbd(..)\x01\x75\x06\xb6\x00', 'ball_layer', ps, ps + 0x300)
    if r:
        dsv['ball_layer'] = u16(r[0].group(1))
    else:
        c.missing.append('ds_vars.ball_layer')
    # wall test register setup (cs:184A): mov si,60h; mov dl,FLIP; mov al,LO | mov al,[VAR] (EP8 ds:04A7);
    #   mov ah,HI; mov dh,ACTIVE_BELOW; cmp byte [di+layer],1; jne; mov dh,0; mov al,LO1; mov ah,HI1
    r = c.find(rb'\xbe\x60\x00\xb2(.)(?:\xb0(.)|\xa0(..))\xb4(.)\xb6(.)\x80\xbd..\x01\x75\x06\xb6\x00\xb0(.)\xb4(.)',
               'wall_test', ps, ps + 0x300)
    if r:
        m = r[0]
        cfg['wall_test'] = dict(flipper=m.group(1)[0], lo=m.group(2)[0] if m.group(2) else None,
                                lo_var=u16(m.group(3)) if m.group(3) else None, hi=m.group(4)[0],
                                active_below=m.group(5)[0], level1_lo=m.group(6)[0], level1_hi=m.group(7)[0])
        if m.group(3):
            dsv['wall_threshold'] = u16(m.group(3))
            c.notes.append(f'level-0 wall lower bound is the variable ds:{u16(m.group(3)):04x} (runtime), not a constant')
    else:
        c.missing.append('wall_test')
    # kicker (active surface) call in the wall loop (cs:18A1): cmp byte [KC],0; jne SKIP; call KICKER
    #   (EP2 adds an x/y window: cmp word [di+x],X; ja; cmp word [di+y],Y; jb; before the call)
    r = c.find(rb'\x80\x3e(..)\x00\x75.((?:(?:\x81\xbd....|\x83\xbd...)[\x77\x72].)*)\xe8(..)', 'kicker_call', ps, ps + 0x300)
    if r:
        dsv['kicker_cooldown'] = u16(r[0].group(1))
        cfg['kicker_hit'] = c.rel16(r[1] + 7 + len(r[0].group(2)))
        if r[0].group(2):
            c.notes.append('the kicker call in the wall loop has an extra x/y window test (conditional active surface)')
    else:
        c.missing.append('ds_vars.kicker_cooldown')
    # flipper_update: the call right after the slot loop's exit (cs:1900 call 3CDD)
    fu = None
    r = c.find(rb'\xe8(..)\x83\x3e' + w(dsv['ball_active'] + 2) + rb'\x01', 'flipper_update_call', ps, ps + 0x400)
    if r:
        fu = c.rel16(r[1])
        cfg['flipper_update'] = fu

    # ---- collision_response (cs:1A66): hit list, contact direction store (cs:1AD0) and hook (cs:1AEC)
    m, a = c.need(rb'\x8b\x1e(..)\x4b\x8a\x87(..)\x8a\xe0', 'collision_response', ps, ps + 0x800)
    dsv['hit_count'] = u16(m.group(1))
    cfg['hit_list'] = u16(m.group(2))
    m, a = c.need(rb'\x8a\xd8\xa2(..)\xfe\xcb\xb7\x00\x88\x1e(..)\x80\x06\2\x18\x80\x3e\2\x30\x76\x05\x80\x2e\2\x30',
                  'contact_dir', a, a + 0x200)
    dsv['contact_dir'] = u16(m.group(1))
    cfg['collision_response_dir_stored'] = a + len(m.group(0))
    # flipper-path y gates (EP4, EP8-13): cmp byte [flipper_contact],0; je PLAIN; cmp word [di+y],Y; jb PLAIN
    ca = cfg['collision_response_dir_stored']
    gates = c.find(rb'\x80\x3e' + w(dsv['flipper_contact']) + rb'\x00(?:\x74.|\x75\x03\xe9..)\x81\xbd' + w(dsv['ball_y']) +
                   rb'(..)\x72', None, ca, ca + 0x120, all_=True)
    cfg['flipper_kick_min_y'] = [u16(g[0].group(1)) for g in gates]
    if gates:
        ev['flipper_kick_min_y'] = ', '.join(f'cs:{g[1]:04x}' for g in gates)
        c.notes.append('flipper kicks only below y ' + ' / '.join(str(u16(g[0].group(1))) for g in gates) +
                       ' (side/tip path, top path): a flipper contact higher up gets the normal push-out and, on the '
                       'first response, the top kick (EP9/EP10, no second gate) or the upper-flipper kick (EP4, EP11-13; '
                       'engine.json flipper_kick.upper_kick)')
    ev['collision_response_dir_stored'] = f'cs:{cfg["collision_response_dir_stored"]:04x} (after the contact_dir store)'

    # ---- sensor dispatcher (cs:1E66): mov bl,al; xor bh,bh; sub bx,0aah; shl bx,1; mov bx,cs:[bx+T]; jmp bx
    m, a = c.need(rb'\x8a\xd8\x32\xff\x81\xeb\xaa\x00\xd1\xe3\x2e\x8b\x9f(..)\xff\xe3', 'sensor_dispatch')
    cfg['sensor_dispatch'] = a
    cfg['sensor_table'] = u16(m.group(1))
    # dispatcher head (cs:1E3B): push es; pusha; cmp al,0aah; jb; cmp byte [cur_layer],1
    r = c.find(rb'\x3c.\x72.\x80\x3e(..)\x01\x75', 'cur_layer', a - 0x40, a)
    if r:
        dsv['cur_layer'] = u16(r[0].group(1))
    else:
        c.missing.append('ds_vars.cur_layer')
    # tilted: the last "cmp byte [T],1; je" before the jump table index (cs:1E5F)
    ts = c.find(rb'\x80\x3e(..)\x01\x74', None, a - 0x20, a, all_=True)
    if ts:
        dsv['tilted'] = u16(ts[-1][0].group(1))
        ev['tilted'] = f'cs:{ts[-1][1]:04x}'

    # ---- keyboard ISR (cs:314B): cli; push ax; push di; push ds; push cs; pop ds; in al,60h
    r = c.find(rb'\x0e\x1f\xe4\x60', 'keyboard_isr')
    if r is None:
        raise NotFound('keyboard_isr')
    keys, last, isr_end = _isr_key_map(c, r[1] - 4)
    def key(sc, name, value=1):
        for var, v in keys.get(sc, []):
            if v == value:
                csv[name] = var
                return
        c.missing.append(f'cs_vars.{name}')
    key(0x2A, 'key_lflip')      # LShift
    key(0x36, 'key_rflip')      # RShift
    key(0x48, 'key_up')
    key(0x50, 'key_down')
    key(0x39, 'key_space')
    key(0x1D, 'key_ctrl')
    key(0x2C, 'key_nudge_a')    # Z
    key(0x35, 'key_nudge_b')    # /
    if last is not None:
        csv['last_scancode'] = last
    else:
        c.missing.append('cs_vars.last_scancode')

    # ---- flipper_update (cs:3CDD): per group "cmp byte cs:[KEY],1; je; mov byte [MOVING],0; cmp word [ANGLE],REST; je; inc word [ANGLE]"
    groups = []
    if fu is not None:
        for m, a in c.find(rb'\x2e\x80\x3e(..)\x01\x74.\xc6\x06(..)\x00\x83\x3e(..)(.)(?:\x74.|\x75\x03(?:\xe9..|\xeb.\x90)|\x75\x02\xeb.)\xff\x06\3', None, fu, fu + 0x400, all_=True):
            keyv, mov, ang, rest = u16(m.group(1)), u16(m.group(2)), u16(m.group(3)), m.group(4)[0]
            d = c.find(rb'\x8b\x36(..)\xd1\xe6\x8b\xb4(..)', None, a, a + 0x80)
            side = 'left' if keyv == csv.get('key_lflip') else 'right' if keyv == csv.get('key_rflip') else None
            groups.append(dict(side=side, key=keyv, angle=ang, moving=mov, rest=rest, at=a,
                               drawn=u16(d[0].group(1)) if d else None, outline=u16(d[0].group(2)) if d else None))
        ev['flipper_groups'] = ', '.join(f'cs:{g["at"]:04x}' for g in groups)
    for g in groups:
        if g['side'] in ('left', 'right'):
            p = 'lflip' if g['side'] == 'left' else 'rflip'
            if f'{p}_angle' in dsv:
                continue
            dsv[f'{p}_angle'], dsv[f'{p}_moving'] = g['angle'], g['moving']
            if g['drawn'] is not None:
                dsv[f'{p}_drawn'], dsv[f'{p}_outline'] = g['drawn'], g['outline']
    for p in ('lflip', 'rflip'):
        if f'{p}_angle' not in dsv:
            c.missing.append(f'ds_vars.{p}_angle')
    cfg['flipper_groups'] = [{k: v for k, v in g.items() if k != 'at'} for g in groups]
    cfg['flipper_rest'] = groups[0]['rest'] if groups else 9

    # ---- flipper outlines: every draw site inside flipper_update (EP1 cs:3D50):
    #   mov si,[ANGLE]; shl si,1; mov si,[si+TABLE]; lodsw; mov cx,ax; mov dl,COLOUR; lodsw; mov di,ax;
    #   [add di,BASE]; mov es:[di],dl; [mov es:[di+ROW],dl]; loop
    # The erase pass (colour 0x2A, index [DRAWN]) has the same shape.  Several outlines can share one
    # angle variable (EP4: 4 outlines / 2 groups; EP12: 3 / 2).  EP7/EP8 draw 0xFF; EP11-13 draw a
    # second row (ROW = +320).  The ES segment is the last `mov es,[pf_seg_*]` before the site (EP4's 4th
    # and EP12's 3rd outline use the top half).
    outlines, erase = [], None
    if fu is not None:
        fend = func_end(c, fu)
        pat = (rb'\x8b\x36(..)\xd1\xe6\x8b\xb4(..)\xad\x8b\xc8\xb2(.)\xad\x8b\xf8(?:\x81\xc7(..))?'
               rb'\x26\x88\x15(?:\x26\x88\x95(..))?\xe2')
        sites = c.find(pat, None, fu, fend, all_=True)
        for m, a in sites:
            es = c.find(rb'\x8e\x06(..)', None, fu, a, all_=True)
            rec = dict(at=a, angle=u16(m.group(1)), table=u16(m.group(2)), colour=m.group(3)[0],
                       base=u16(m.group(4)) if m.group(4) else 0,
                       second_row=s16(m.group(5)) if m.group(5) else None,
                       seg_var=u16(es[-1][0].group(1)) if es else None)
            drawn_vars = {g['drawn'] for g in groups}
            if rec['angle'] in drawn_vars:
                erase = rec['colour']
                continue
            outlines.append(rec)
        ev['flipper_outlines'] = ', '.join(f'cs:{o["at"]:04x}' for o in outlines)
        if not outlines:
            c.missing.append('flipper_outlines')
    cfg['flipper_outlines'] = [{k: v for k, v in o.items() if k != 'at'} for o in outlines]
    if outlines:
        cfg['flipper_colour'] = outlines[0]['colour']
    if erase is not None:
        cfg['flipper_erase'] = erase

    # ---- parameter block (hidden F1 editor, cs:146C): add di,2; lea ax,[P+14h]; cmp di,ax
    r = c.find(rb'\x83\xc7\x02\x8d\x06(..)\x3b\xf8', 'params')
    if r:
        dsv['params'] = u16(r[0].group(1)) - 0x14
    else:
        c.missing.append('ds_vars.params')

    # ---- per-frame main-loop fragments ("physics" mode ranges), each with evidence
    ranges = []
    main = cfg['main_loop']

    # (a) gravity + object scan (cs:119F..1236): mov byte [kick],0; mov di,0; cmp word [di+active],0; je;
    #     cmp word [di+vy],140h; jg; mov ax,[g]; (add ax,[extra]); add [di+vy],ax
    m, ga = c.need(rb'\xc6\x06' + w(dsv['kick_strength']) + rb'\x00\xbf\x00\x00\x83\xbd' + w(dsv['ball_active']) +
                   rb'\x00(?:\x74.|\x75\x03\xe9..)\x81\xbd' + w(dsv['ball_vy']) + rb'(..)\x7f.\xa1(..)', 'gravity')
    cfg['gravity_cutoff'] = s16(m.group(1))
    tail = c.code[ga + len(m.group(0)):ga + len(m.group(0)) + 4]
    extra = u16(tail, 2) if tail[:2] == b'\x03\x06' else None
    if extra is not None:
        dsv['extra_gravity_timer'] = extra
    # save_ball_bg + writeback flag + ball_pixel_scan (cs:11F2..11FD): push di; lcall SAVE; mov byte [wb],0; call SCAN
    m, a = c.need(rb'\x57\x9a....\xc6\x06(..)\x00\xe8(..)', 'ball_pixel_scan_call', ga, ga + 0x80)
    save_call, scan_call = a + 1, a + 11
    dsv['obj_writeback'] = u16(m.group(1))
    cfg['ball_pixel_scan'] = c.rel16(scan_call)
    # object copy (cs:11C1): mov ax,[di+x]; mov bx,[di+y]; mov cl,[di+layer]; mov [cur],cl; mov [ox],ax; mov [oy],bx
    r = c.find(rb'\x8b\x85' + w(dsv['ball_x']) + rb'\x8b\x9d' + w(dsv['ball_y']) + rb'\x8a\x8d(..)\x88\x0e(..)\xa3(..)\x89\x1e(..)',
               'obj_copy', ga, ga + 0x40)
    if r:
        dsv.setdefault('cur_layer', u16(r[0].group(2)))
        dsv['obj_x'], dsv['obj_y'] = u16(r[0].group(3)), u16(r[0].group(4))
    # loop end: add di,2; cmp di,N; je +3; jmp loop
    m, a = c.need(rb'\x83\xc7\x02\x83\xff.\x74\x03\xe9', 'gravity_end', ga, ga + 0x100)
    grav_range = (ga, c.rel8(a + 6), [save_call, scan_call])

    # (b) extra-gravity decay (cs:06E2): cmp word [G],0; je +4; dec word [G]
    decay = None
    if extra is not None:
        r = c.find(rb'\x83\x3e' + w(extra) + rb'\x00\x74\x04\xff\x0e' + w(extra), 'extra_gravity_decay', main, ga)
        if r:
            decay = (r[1], r[1] + 11, [])
        else:
            c.missing.append('ranges.extra_gravity_decay')

    # (c) per-frame counters (cs:09EC..0A0D): runs of "cmp byte [X],0; je +4; dec byte [X]" containing the
    #     sensor lockout, kicker cooldown and sensor cooldown
    lock = None
    counters = None
    r = c.find(rb'\x80\x3e(..)\x00\x75.\xe8(..)\x8a\x26', 'event_cooldown', cfg['ball_pixel_scan'], cfg['ball_pixel_scan'] + 0x100)
    if r:
        dsv['event_cooldown'] = u16(r[0].group(1))
    # ball_pixel_scan (cs:16D6..16E9): cmp al,0FEh; je; cmp ah,0 (lockout loaded into ah)...  lockout = the var
    # the dispatcher re-reads: mov ah,[L] right after the dispatch call
    r = c.find(rb'\xe8..\x8a\x26(..)', 'event_lockout', cfg['ball_pixel_scan'], cfg['ball_pixel_scan'] + 0x100)
    if r:
        lock = u16(r[0].group(1))
        dsv['event_lockout'] = lock
    runs, cur = [], []
    for mm, a in c.find(rb'\x80\x3e(..)\x00\x74\x04\xfe\x0e\1', None, main, ga, all_=True):
        if cur and a == cur[-1][0] + 11:
            cur.append((a, u16(mm.group(1))))
        else:
            if cur:
                runs.append(cur)
            cur = [(a, u16(mm.group(1)))]
    if cur:
        runs.append(cur)
    # EP9-13 keep one lockout per ball: gravity loop "mov cl,[di+ARR]; mov [lock],cl" (EP9 cs:1346)
    lock_arr = None
    if lock is not None:
        r = c.find(rb'\x8a\x8d(..)\x88\x0e' + w(lock), 'event_lockout_array', ga, ga + 0x80)
        if r:
            lock_arr = u16(r[0].group(1))
            dsv['event_lockout_array'] = lock_arr
    lock_set = {lock} | ({lock_arr + 2 * i for i in range(cfg['ball_slots'])} if lock_arr is not None else set())
    for run in runs:
        if lock is not None and any(v in lock_set for _, v in run):
            counters = (run[0][0], run[-1][0] + 11, [])
            ev['counters'] = f'cs:{run[0][0]:04x} ({len(run)} decrements)'
            vs = [v for _, v in run]
            others = [v for v in vs if v not in lock_set and v != dsv.get('event_cooldown')]
            cfg['frame_counters'] = vs
            kc = dsv.get('kicker_cooldown')
            if kc is None and others:
                dsv['kicker_cooldown'] = others[0]
            elif kc is not None and kc in lock_set:
                c.notes.append(f'kicker cooldown and sensor lockout are one variable (ds:{kc:04x})')
            elif kc is not None and kc not in vs:
                c.notes.append(f'kicker cooldown ds:{kc:04x} is not decremented in the counters fragment')
            break
    if counters is None:
        c.missing.append('ranges.counters')

    # (d) drain + serve (cs:0A31..0A9A): mov di,2N; mov cx,0; cmp word [di+A-2],0; je; cmp word [di+Y-2],DRAIN; jb
    m, da = c.need(rb'\xbf(.)\x00\xb9\x00\x00\x83\xbd(..)\x00\x74.\x81\xbd(..)(..)\x72.', 'drain', main, ga)
    cfg['drain_y'] = u16(m.group(4))
    #   loop end: sub di,2; jne loop (EP2: je +3; jmp loop); cmp cx,N; jne END
    m2, a = c.need(rb'\x83\xef\x02(?:\x75.|\x74\x03\xe9..)\x83\xf9(.)\x75(.)', 'drain_end', da, da + 0x100)
    a += len(m2.group(0)) - 2
    drain_end = c.rel8(a)
    drain = (da, drain_end, [])
    # serve: mov byte [serve_delay],N; mov word [y0],Y; ... mov word [active0],1
    r = c.find(rb'\xc6\x06(..)(.)\xc7\x06' + w(dsv['ball_y']) + rb'(..)', 'serve', a, drain_end)
    if r:
        dsv['serve_delay'] = u16(r[0].group(1))
        seg = c.code[r[1]:drain_end]
        cfg['serve'] = dict(delay=r[0].group(2)[0], y=u16(r[0].group(3)))
        for nm in ('x', 'vx', 'vy'):
            mm = re.search(rb'\xc7\x06' + w(dsv['ball_' + nm]) + rb'(..)', seg, re.S)
            if mm:
                cfg['serve'][nm] = s16(mm.group(1))
    else:
        cfg['serve'] = None
        c.notes.append('drain does not serve a new ball (no serve code between the drain loop and its exit)')

    # (e) plunger lane (cs:0A9D..0C48, skip 0AFD ball_lost_fade): cmp word [active0],0; je OUT; [cmp byte [layer0],0; jne OUT];
    #     cmp word [x0],MINX; jb OUT; cmp word [y0],MINY; jb OUT; cmp byte [serve_delay],0; je
    lane = None
    r = c.find(rb'\x83\x3e' + w(dsv['ball_active']) + rb'\x00\x74(.)(?:\x80\x3e..\x00\x75.)?\x81\x3e' + w(dsv['ball_x']) +
               rb'(..)\x72.\x81\x3e' + w(dsv['ball_y']) + rb'(..)\x72.\x80\x3e(..)\x00\x74.', 'lane', drain_end, ga)
    if r:
        m, la = r
        out = c.rel8(la + 5)
        cfg['lane'] = dict(min_x=u16(m.group(2)), min_y=u16(m.group(3)))
        dsv.setdefault('serve_delay', u16(m.group(4)))
    else:
        # EP8: no lane; the ball is launched from the bottom when no slot is active (cs:0B62 in EP8):
        #   cmp byte [X],0; jne OUT; cmp word [active0],1; je OUT; cmp word [active1],1; je OUT ...
        r = c.find(rb'\x80\x3e..\x00\x75(.)\x83\x3e' + w(dsv['ball_active']) + rb'\x01\x74.\x83\x3e' + w(dsv['ball_active'] + 2) + rb'\x01\x74.',
                   'launch_gate', drain_end, ga)
        if r:
            m, la = r
            out = c.rel8(la + 5)
            cfg['lane'] = None
            c.notes.append(f'no plunger lane: launch-from-bottom block at cs:{la:04x} (runs while no ball is active)')
        else:
            la = None
            c.missing.append('ranges.lane')
    if la is not None:
        stop = c.follow_jmps(out)
        # the blocking call of the serve-delay path (ball_lost_fade) sits right before OUT
        skips = [out - 3] if c.code[out - 3] == 0xE8 else []
        lane = (la, stop, skips)
        ev['lane_stop'] = f'cs:{stop:04x} (exit cs:{out:04x} followed through jmps)'
        if skips:
            cfg['ball_lost_fade'] = c.rel16(out - 3)
            ev['ball_lost_fade'] = f'call at cs:{out - 3:04x}'
        seg = (la, stop)
        # plunger: cmp word [P],MAX; ja|jae; add word [P],STEP
        r = c.find(rb'\x81\x3e(..)(..)([\x77\x73]).\x83\x06\1(.)', 'plunger', *seg)
        if r:
            dsv['plunger_charge'] = u16(r[0].group(1))
            cfg['plunger'] = dict(max=u16(r[0].group(2)), step=r[0].group(4)[0],
                                  cmp='ja' if r[0].group(3) == b'\x77' else 'jae', kind='charge')
        else:
            # EP8: while held the launch flag is set to a constant: mov word [P],IMM; jmp
            r = c.find(rb'\x2e\x80\x3e..\x01\x75.\xc7\x06(..)(..)\xeb', 'plunger_flag', *seg)
            if r:
                dsv['plunger_charge'] = u16(r[0].group(1))
                cfg['plunger'] = dict(max=u16(r[0].group(2)), step=None, cmp=None, kind='launch_flag')
                # on release the ball is placed and launched by constant stores into slot 0 (EP8 cs:0C3F..0C5F)
                launch = {}
                for nm in ('vx', 'vy', 'x', 'y', 'active'):
                    mm = c.find(rb'\xc7\x06' + w(dsv['ball_' + nm]) + rb'(..)', None, r[1], stop)
                    if mm:
                        launch[nm] = s16(mm[0].group(1))
                if all(k in launch for k in ('x', 'y', 'vx', 'vy')):
                    cfg['launch'] = launch
                    ev['launch'] = f'constant stores to slot 0 after cs:{r[1]:04x}'
                else:
                    c.missing.append('launch')
            else:
                c.missing.append('ds_vars.plunger_charge')
        # demo flag tested in front of the plunger key tests: cmp byte [demo],1; je; cmp byte cs:[ctrl],1
        r = c.find(rb'\x80\x3e(..)\x01\x74.\x2e\x80\x3e' + (w(csv['key_ctrl']) if 'key_ctrl' in csv else b'..') + rb'\x01', 'demo_mode', *seg)
        if r:
            dsv['demo_mode'] = u16(r[0].group(1))

    # (f) nudge / tilt (cs:0DFD..0E8A): cmp byte cs:[nudgeA],1; je; cmp cs:[nudgeB],1; je; cmp cs:[space],1; jne
    nudge = None
    if all(k in csv for k in ('key_nudge_a', 'key_nudge_b', 'key_space')):
        r = c.find(rb'\x2e\x80\x3e' + w(csv['key_nudge_a']) + rb'\x01\x74.\x2e\x80\x3e' + w(csv['key_nudge_b']) +
                   rb'\x01\x74.\x2e\x80\x3e' + w(csv['key_space']) + rb'\x01\x75.', 'nudge', main, ga)
        if r:
            na = r[1]
            m = c.find(rb'\x80\x06(..)(.)\xc6\x06(..)(.)', 'nudge_add', na, na + 0x60)
            t = c.find(rb'\x80\x3e(..)(.)\x76(.)\x80\x3e(..)\x01\x74', 'tilt', na, na + 0x90)
            if m and t:
                dsv['tilt_meter'], dsv['nudge_timer'] = u16(m[0].group(1)), u16(m[0].group(3))
                dsv.setdefault('tilted', u16(t[0].group(4)))
                nudge = (na, c.rel8(t[1] + 5), [])
    if nudge is None:
        c.missing.append('ranges.nudge')

    for fr in (decay, counters, drain, lane, nudge, grav_range):
        if fr is not None:
            ranges.append(fr)
    ranges.sort(key=lambda r: r[0])
    cfg['physics_ranges'] = [(a, b, list(s)) for a, b, s in ranges]
    cfg['rules_ranges'] = [(a, b, [x for x in s if x != scan_call]) for a, b, s in ranges]

    # ---- collision buffer segments (flipper_update: mov es,[pf_seg_bottom]); pf_seg_top = bottom - 2
    if fu is not None:
        r = c.find(rb'\x8e\x06(..)', 'pf_seg_bottom', fu, fu + 8)
        if r:
            dsv['pf_seg_bottom'] = u16(r[0].group(1))
            dsv['pf_seg_top'] = dsv['pf_seg_bottom'] - 2
            ev['pf_seg_top'] = ev['pf_seg_bottom'] + ' (the word before)'

    # ---- code-integrity check: cs:0000..end minus every byte that any instruction writes through cs:
    #      (the harness fails a run when other code bytes change: e.g. an unpaired save_ball_bg overflowing)
    cfg['code_check_end'] = func_end(c, fu) if fu is not None else isr_end
    cfg['code_vars'] = code_vars(c, cfg['code_check_end'])
    ev['code_check_end'] = 'end of flipper_update (the last engine routine the harness runs)'
    ev['code_vars'] = 'linear sweep for cs: writes below code_check_end'

    # ---- informational (other tools): sound flag, probe ring, normal and push-out tables
    r = c.find(rb'\x80\xec\x30\x80\xfc\x0f\x76\x05\xc6\x06(..)\x00', 'snd_present', 0, 0x400)
    if r:
        dsv['snd_present'] = u16(r[0].group(1))
    r = c.find(rb'\x03\x9c(..)\x26\x38\x07', 'ring', ps, ps + 0x400)
    if r:
        dsv['ring'] = u16(r[0].group(1))
    r = c.find(rb'\x8b\x87(..)\xf7\xd8\xa3', 'normals', ps, ps + 0xA00)
    if r:
        dsv['normals'] = u16(r[0].group(1))
    r = c.find(rb'\xc1\xe3\x02\x8b\x87(..)\x29\x85', 'pushout', ps, ps + 0xA00)
    if r:
        dsv['pushout'] = u16(r[0].group(1))

    cfg['ds_vars'] = dsv
    cfg['cs_vars'] = csv
    return cfg, c


def func_end(c, start, limit=0x800):
    """End of a near routine: the first ret past every jump target seen so far (linear sweep)."""
    from capstone import Cs, CS_ARCH_X86, CS_MODE_16
    md = Cs(CS_ARCH_X86, CS_MODE_16)
    a, far = start, start
    while a < start + limit:
        i = next(md.disasm(c.code[a:a + 16], a), None)
        if i is None:
            return a
        if i.mnemonic.startswith('j') and i.op_str.startswith('0x'):
            far = max(far, int(i.op_str, 16))
        a += i.size
        if i.mnemonic in ('ret', 'iret', 'retf') and a > far:
            return a
    return a


def code_vars(c, end):
    """[(lo, hi), ...]: bytes in cs:0000..end that some instruction writes through a cs: override
    (linear capstone sweep; the keyboard ISR's flags, the timer ISR's counters, ...)."""
    from capstone import Cs, CS_ARCH_X86, CS_MODE_16
    md = Cs(CS_ARCH_X86, CS_MODE_16)
    written = set()
    a = 0
    while a < min(end + 0x2000, len(c.code) - 16):
        i = next(md.disasm(c.code[a:a + 16], a), None)
        if i is None:
            a += 1
            continue
        a += i.size
        ops = i.op_str.split(', ')
        if i.mnemonic in ('cmp', 'test', 'push') or not ops or not ops[0].startswith(('byte ptr cs:[0x', 'word ptr cs:[0x')):
            continue
        m = re.fullmatch(r'(byte|word) ptr cs:\[(0x[0-9a-f]+)\]', ops[0])
        if not m:
            continue
        lo = int(m.group(2), 16)
        written.update(range(lo, lo + (2 if m.group(1) == 'word' else 1)))
    spans = []
    for x in sorted(v for v in written if v < end):
        if spans and x <= spans[-1][1]:
            spans[-1][1] = x + 1
        else:
            spans.append([x, x + 1])
    return [tuple(s) for s in spans]


# ---------------------------------------------------------------------------------------------
# config files


def _jsonable(cfg):
    out = dict(cfg)
    for k in ('physics_ranges', 'rules_ranges'):
        if k in out:
            out[k] = [[h(a), h(b), [h(x) for x in s]] for a, b, s in out[k]]
    for k in ('code_vars',):
        if k in out:
            out[k] = [[h(a), h(b)] for a, b in out[k]]
    for k in ('ds_vars', 'cs_vars'):
        if k in out:
            out[k] = {n: h(v) for n, v in out[k].items()}
    for k in ('cs', 'ds', 'main_loop', 'frame_sync', 'physics_step', 'collision_response_dir_stored', 'sensor_dispatch',
              'sensor_table', 'code_check_end', 'flipper_update', 'ball_pixel_scan', 'hit_list', 'ball_lost_fade',
              'kicker_hit', 'flipper_colour', 'flipper_erase'):
        if k in out and isinstance(out[k], int):
            out[k] = h(out[k])
    if 'flipper_groups' in out:
        out['flipper_groups'] = [{k: (h(v) if isinstance(v, int) and k not in ('rest',) else v) for k, v in g.items()}
                                 for g in out['flipper_groups']]
    if 'flipper_outlines' in out:
        out['flipper_outlines'] = [{k: (h(v) if isinstance(v, int) and k != 'second_row' else v) for k, v in o.items()}
                                   for o in out['flipper_outlines']]
    if isinstance(out.get('wall_test'), dict):
        out['wall_test'] = {k: (h(v) if isinstance(v, int) else v) for k, v in out['wall_test'].items()}
    return out


def h(v):
    return f'0x{v:04x}'


def _parse(v):
    if isinstance(v, str) and v.startswith('0x'):
        return int(v, 16)
    if isinstance(v, list):
        return [_parse(x) for x in v]
    if isinstance(v, dict):
        return {k: _parse(x) for k, x in v.items()}
    return v


def from_json(d):
    """Inverse of _jsonable: hex strings back to ints; ranges back to tuples."""
    cfg = {}
    for k, v in d.items():
        if k in ('exe',):
            cfg[k] = v
        elif k in ('physics_ranges', 'rules_ranges'):
            cfg[k] = [(int(a, 16), int(b, 16), [int(x, 16) for x in s]) for a, b, s in v]
        elif k == 'code_vars':
            cfg[k] = [(int(a, 16), int(b, 16)) for a, b in v]
        elif k in ('ds_vars', 'cs_vars'):
            cfg[k] = {n: int(x, 16) for n, x in v.items()}
        elif k == 'flipper_groups':
            cfg[k] = [{kk: (_parse(vv) if kk != 'side' else vv) for kk, vv in g.items()} for g in v]
        else:
            cfg[k] = _parse(v)
    return cfg


def merge(auto, overrides):
    cfg = dict(auto)
    for k, v in (overrides or {}).items():
        if k.startswith('_'):
            continue
        if k in ('ds_vars', 'cs_vars'):
            cfg[k] = dict(cfg.get(k, {}), **v)
        else:
            cfg[k] = v
    return cfg


def path_for(n):
    return os.path.join(TABLE_DIR, f'EP{n}.json')


def write_table(n, verbose=False):
    cfg, c = discover(n)
    p = path_for(n)
    old = json.load(open(p)) if os.path.exists(p) else {}
    doc = {
        'format': FORMAT, 'table': n, 'exe': f'EP{n}.EXE', 'exe_sha1': c.sha1, 'generated_by': 'tools/emu/discover.py',
        'note': 'auto = found by byte signatures in the user\'s EXE (regenerated by discover.py); overrides = hand-maintained, '
                'preserved on rewrite, applied on top of auto. Addresses: cs = offsets in the entry code segment, '
                'ds = offsets in the data segment (unrelocated).',
        'auto': _jsonable(cfg), 'evidence': c.evidence, 'missing': c.missing, 'notes': c.notes,
        'overrides': old.get('overrides', {}),
    }
    os.makedirs(TABLE_DIR, exist_ok=True)
    with open(p, 'w') as f:
        json.dump(doc, f, indent=1)
        f.write('\n')
    return doc


def load_config(n, exe_path=None):
    """Effective harness config for table n: tables/EPn.json (auto + overrides).  The file is
    (re)generated when it is missing or was made from a different EXE."""
    p = path_for(n)
    doc = json.load(open(p)) if os.path.exists(p) else None
    sha = hashlib.sha1(open(exe_path or os.path.join(ROOT, 'original', f'EP{n}.EXE'), 'rb').read()).hexdigest()
    if doc is None or doc.get('exe_sha1') != sha:
        doc = write_table(n)
    cfg = merge(from_json(doc['auto']), from_json(doc.get('overrides', {})))
    cfg['_missing'] = doc.get('missing', [])
    cfg['_overridden'] = sorted(k for k in doc.get('overrides', {}) if not k.startswith('_'))
    return cfg


def check_ep1():
    """Compare EP1's effective config (auto + overrides) with the hand-verified dict in ep_emu.py."""
    import ep_emu
    ref = ep_emu.EP1
    cfg = load_config(1)
    diffs = []
    for k, v in ref.items():
        if k in ('ds_vars', 'cs_vars'):
            for n, x in v.items():
                if cfg[k].get(n) != x:
                    diffs.append(f'{k}.{n}: ref {x:#x} auto {cfg[k].get(n)!r}')
        elif cfg.get(k) != v:
            diffs.append(f'{k}: ref {v!r}\n      auto {cfg.get(k)!r}')
    return diffs


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('tables', nargs='*', type=int)
    ap.add_argument('-v', '--verbose', action='store_true')
    ap.add_argument('--check', action='store_true', help='compare the effective EP1 config with ep_emu.EP1')
    ap.add_argument('--no-write', action='store_true')
    a = ap.parse_args()
    if a.check:
        d = check_ep1()
        print('EP1 effective config == ep_emu.EP1' if not d else 'EP1 effective config differs from ep_emu.EP1:\n  ' + '\n  '.join(d))
        return
    for n in a.tables or range(1, 14):
        try:
            if a.no_write:
                cfg, c = discover(n)
                doc = dict(auto=_jsonable(cfg), missing=c.missing, notes=c.notes, evidence=c.evidence, overrides={})
            else:
                doc = write_table(n)
        except NotFound as e:
            print(f'EP{n}: NOT FOUND {e}')
            continue
        au = doc['auto']
        print(f"EP{n}: main_loop {au['main_loop']} physics_step {au['physics_step']} slots {au['ball_slots']} "
              f"ranges {[(r[0], r[1]) for r in au['physics_ranges']]} missing {doc['missing']} "
              f"overrides {sorted(doc['overrides'])}")
        if a.verbose:
            print(json.dumps({k: doc[k] for k in ('auto', 'evidence', 'notes')}, indent=1))


if __name__ == '__main__':
    main()
