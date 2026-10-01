#!/usr/bin/env python3
"""Ground truth for the dot-message effects: run the ORIGINAL dmd_message and render_frame (EPn.EXE under
Unicorn) and record, per frame, what render_frame's plot loop draws.

Usage:
  .venv/bin/python tools/emu/dot_effects.py --table 1 --string 0x873 --ax 0x1 --di 0x12c0 --frames 260 [-o out.json]
  .venv/bin/python tools/emu/dot_effects.py --batch CASES.json -o OUT.json      (one boot per table; used by swift test)

--string is a FILE offset in the user's EXE (as `EpicPinball --message`). A case in a batch file:
  {"table": 1, "string": 2163, "ax": 1, "di": 4800, "frames": 260, "colour": 255,
   "lines": [{"frame": 0, "routine": 22956, "string": 2200, "di": 9000}]}
"lines" are draw_text calls (routine = cs offset of a dot-list text routine) made after render_frame call
`frame` (0 = right after dmd_message).

Output per case: the initial dot list dmd_message wrote (`list`, the raw words up to the terminator) and per
render_frame call the counter word after it, the dots the plot loop draws (`dots`: list words other than 1
up to the zero terminator, the first word always tested; EP9-13 also skip words above the strip limit), the
EP9-13 colour byte of each dot (`colours`), and the DAC entries written during the call (`dac`: index ->
6-bit [r, g, b]) and the sounds it played (`sfx`: AX of each `call far sfx_play` in the effect blocks). After the call that ends the message (counter 0FFFFh -> 0) nothing is drawn; EP9-13 then
redraw their idle display, which is itself a new dmd_message, so recording stops there.

The routines and DS addresses are found by the same code signatures as app/Sources/PinballCore/Presentation/
DotEffects.swift (docs/enhanced/presentation.md).
"""
import argparse
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import ep_emu  # noqa: E402
import epexe  # noqa: E402
from unicorn.x86_const import UC_X86_REG_SP  # noqa: E402


def find_layout(code):
    w = lambda i: struct.unpack_from('<H', code, i)[0]
    dm = re.search(rb'\x06\x60\x80\xfc\x02\x76\x06\x80\xec\x03', code).start()
    body = code[dm:dm + 0x120]
    s = re.search(rb'\xc7\x06..\x00\x00\xa2..\x8d\x36', body, re.S).start() + dm
    k = re.search(rb'\xc7\x06..\x01\x00\xb0\xff\xba\xc8\x03\xee\x42', body, re.S).start() + dm
    counter, effect, lst = w(k + 2), w(s + 7), w(s + 11)
    q = re.search(rb'\xa0..\x8d\x3e..\x81\xc7..\xb9..\xf3\xab', body, re.S)
    colour_var = colour_off = None
    if q and w(q.start() + dm + 5) == lst:
        colour_var, colour_off = w(q.start() + dm + 1), w(q.start() + dm + 9)
    cw, ew = re.escape(struct.pack('<H', counter)), re.escape(struct.pack('<H', effect))
    pat = b'\x83\x3e' + cw + b'\x00\x75\x03\xe9..\x80\x3e' + ew + b'\x01\x74\x03\xe9..\xff\x06' + cw
    rf = re.search(pat, code, re.S).start()
    j = rf + 24
    j += 6 if code[j] == 0x81 else 5
    end = (j + 5 + w(j + 3)) & 0xFFFF
    # cmp word [counter],-1; jne PLOT (EP1 cs:43C5 -> cs:43D5): where the plot loop starts
    m = re.search(b'\x83\x3e' + cw + b'\xff\x75', code[end:end + 0x100], re.S)
    plot = end + m.start() + 7 + code[end + m.start() + 6]
    limit = None
    if colour_var is not None:
        p = re.search(rb'\xad\x3d..\x77', code[end:end + 0x100], re.S)
        limit = w(end + p.start() + 2)
    if code[rf - 1] == 0x06:   # EP9-13: render_frame starts with push es (EP10 cs:38E1 ... pop es; ret)
        rf_entry = rf - 1
    else:
        rf_entry = rf
    if code[dm - 7:dm - 4] == b'\x2e\xc7\x06':   # EP9-13: mov word cs:[x],0FFF8h first (EP10 cs:1563)
        dm -= 7
    return dict(dmd_message=dm, render_frame=rf, render_frame_entry=rf_entry, plot=plot, effects_end=end, counter=counter, effect=effect, list=lst,
                colour_var=colour_var, colour_offset=colour_off, plot_limit=limit)


def plotted(e, L):
    """The dots render_frame's plot loop draws from the list now, and their EP9-13 colour bytes."""
    limit = L['plot_limit'] if L['plot_limit'] is not None else 0xFFFF
    dots, cols, i = [], [], 0
    while i < 0x4000:
        a = L['list'] + 2 * i
        v = e.rw(e.ds, a, signed=False)
        if i > 0 and v == 0:
            break
        if v <= limit and v != 1:
            dots.append(v)
            if L['colour_var'] is not None:
                cols.append(e.rb(e.ds, a + L['colour_offset']))
        i += 1
    return dots, (cols if L['colour_var'] is not None else None)


def run_game(scn):
    """A full-mode scenario (run_scenario.py format): per frame, the dots render_frame plotted in that frame
    (None = it plotted nothing) and DAC 255 at the end of the frame; with "palette": {"working": W, "flag": F}
    also the 6-bit working palette at ds:W and the byte ds:F after every frame."""
    import run_scenario
    emu = run_scenario.setup(scn, 'full')
    exe = epexe.load(emu.exe_path)
    base = exe.image_off(exe.entry_cs)
    L = find_layout(exe.data[base:base + 0x10000])
    emu.log_io = True
    got = {}
    # optional: sensor colour painted into the collision buffer ([x, y, w, h, value], linear 320x400 from
    # the top playfield segment) and a sprite-set routine whose calls (AL) are recorded per frame
    top = emu.dsw('pf_seg_top', signed=False)
    for x0, y0, w, h, v in scn.get('collision_fill', []):
        for y in range(y0, y0 + h):
            emu.uc.mem_write(emu.lin(top, 0) + y * 320 + x0, bytes([v]) * w)
    sprite_calls = []
    hooks = []
    if scn.get('sprite_routine') is not None:
        from unicorn.x86_const import UC_X86_REG_AX
        sa = emu.lin(emu.cs, scn['sprite_routine'])
        hooks.append(emu.uc.hook_add(ep_emu.UC_HOOK_CODE, lambda uc, a, sz, _: sprite_calls.append(uc.reg_read(UC_X86_REG_AX) & 0xFF),
                                     None, sa, sa))
        emu.uc.ctl_remove_cache(sa, sa + 1)

    def on_plot(uc, address, size, _):
        got['dots'], got['colours'] = plotted(emu, L)
    a = emu.lin(emu.cs, L['plot'])
    h = emu.uc.hook_add(ep_emu.UC_HOOK_CODE, on_plot, None, a, a)
    emu.uc.ctl_remove_cache(a, a + 1)   # blocks translated before the hook was added would not call it
    dac, idx, part, rgb = None, 0, 0, [0, 0, 0]
    frames, inputs = [], scn.get('inputs', [])
    try:
        for f in range(scn['frames']):
            if scn.get('on_drain', 'stop') == 'stop' and emu.dsw('ball_y') >= emu.A.get('drain_y', 0x18F):
                break
            emu.set_keys(inputs[f] if f < len(inputs) else 0)
            emu.log.clear()
            got.clear()
            del sprite_calls[:]
            emu.main_loop_full()
            for _ in range(3):
                emu.physics_step()
            for rec in emu.log:
                if rec[0] != 'out':
                    continue
                port, v = int(rec[1], 16), int(rec[2], 16) & 0xFF
                if port == 0x3C8:
                    idx, part = v, 0
                elif port == 0x3C9:
                    rgb[part] = v & 0x3F
                    part += 1
                    if part == 3:
                        if idx == 255:
                            dac = list(rgb)
                        part, idx = 0, (idx + 1) & 0xFF
            rec = dict(dots=got.get('dots'), colours=got.get('colours'), dac255=dac,
                       counter=emu.rw(emu.ds, L['counter'], signed=False), sprites=list(sprite_calls))
            pal = scn.get('palette')
            if pal:   # the working palette (6-bit) and the between-balls flag, after the frame
                rec['working'] = list(emu.uc.mem_read(emu.lin(emu.ds, pal['working']), 768))
                if pal.get('flag') is not None:
                    rec['flag'] = emu.rb(emu.ds, pal['flag'])
            frames.append(rec)
    finally:
        emu.uc.hook_del(h)
        for k in hooks:
            emu.uc.hook_del(k)
        emu.log_io = False
    return dict(table=scn.get('table', 1), frames=frames)


class Runner:
    def __init__(self, table):
        self.table = table
        self.emu = ep_emu.EpEmu(table=table, log_io=True)
        exe = epexe.load(self.emu.exe_path)
        self.ds_file = exe.image_off(epexe.data_segment(exe))
        base = exe.image_off(exe.entry_cs)
        self.L = find_layout(exe.data[base:base + 0x10000])
        self.snap = self.emu.snapshot()
        self.restarted = False
        a = self.emu.lin(self.emu.cs, self.L['dmd_message'])
        self.emu.uc.hook_add(ep_emu.UC_HOOK_CODE, self._on_dmd, None, a, a)
        self.emu.uc.ctl_remove_cache(a, a + 1)
        # The effect blocks' sounds: `call far sfx_play` (EP1 cs:3E6B -> cs:014A); AX at the call is recorded.
        code = exe.data[base:base + 0x10000]
        self.sfx, self.sounds = [], []
        for i in range(self.L['render_frame'], self.L['effects_end']):
            if code[i] == 0x9A and struct.unpack_from('<H', code, i + 1)[0] < 0x1000 and code[i - 3] == 0xB8:
                self.sfx.append(i)   # mov ax,imm16; call far (the sound's AX right before the call)
        for i in self.sfx:
            a = self.emu.lin(self.emu.cs, i)
            self.emu.uc.hook_add(ep_emu.UC_HOOK_CODE, self._on_sfx, None, a, a)

    def words(self, start, n):
        return list(struct.unpack('<%dH' % n, bytes(self.emu.uc.mem_read(self.emu.lin(self.emu.ds, start), 2 * n))))

    def raw_list(self):
        out, i = [], 0
        while i < 0x4000:
            v = self.words(self.L['list'] + 2 * i, 1)[0]
            if v == 0:
                break
            out.append(v)
            i += 1
        return out

    def plotted(self):
        return plotted(self.emu, self.L)

    def dac_writes(self):
        out, idx, part, rgb = {}, 0, 0, [0, 0, 0]
        for rec in self.emu.log:
            if rec[0] != 'out':
                continue
            port, v = int(rec[1], 16), int(rec[2], 16) & 0xFF
            if port == 0x3C8:
                idx, part = v, 0
            elif port == 0x3C9:
                rgb[part] = v & 0x3F
                part += 1
                if part == 3:
                    out[str(idx)] = list(rgb)
                    part, idx = 0, (idx + 1) & 0xFF
        return out

    def call_far(self, ip, **regs):
        """Call a far (retf) routine of the code segment."""
        e = self.emu
        e._prep_regs()
        from unicorn import x86_const
        for k, v in regs.items():
            e.uc.reg_write(getattr(x86_const, 'UC_X86_REG_' + k.upper()), v)
        ss, sp = e.boot_sp
        sp -= 4
        e.ww(ss, sp, ep_emu.SENTINEL_IP)
        e.ww(ss, sp + 2, e.cs)
        e.uc.reg_write(UC_X86_REG_SP, sp)
        e._run(e.cs, ip, ep_emu.SENTINEL_IP, 5_000_000)

    def run(self, case):
        e, L = self.emu, self.L
        e.restore(self.snap)
        if L['colour_var'] is not None and case.get('colour') is not None:
            e.wb(e.ds, L['colour_var'], case['colour'])
        bx = case['string'] - self.ds_file
        text = bytes(e.uc.mem_read(e.lin(e.ds, bx), 64)).split(b'\0')[0]   # the live string (boot can patch it)
        e.log.clear()
        e.call_near(L['dmd_message'], ax=case['ax'] & 0xFFFF, bx=bx, di=case.get('di', 0) & 0xFFFF)
        lines = case.get('lines', [])

        def draw_lines(f):
            for ln in lines:
                if ln.get('frame', 0) == f:
                    if L['colour_var'] is not None and ln.get('colour') is not None:
                        e.wb(e.ds, L['colour_var'], ln['colour'])
                    self.call_far(ln['routine'], bx=ln['string'] - self.ds_file, di=ln['di'] & 0xFFFF)
        out = dict(table=self.table, layout=L, text=list(text), list=self.raw_list(), start_dac=self.dac_writes(), frames=[])
        draw_lines(0)
        for f in range(case['frames']):
            e.log.clear()
            self.restarted = False
            del self.sounds[:]
            e.call_near(L['render_frame_entry'])
            c = e.rw(e.ds, L['counter'], signed=False)
            rec = dict(counter=c, dac=self.dac_writes(), sfx=self.sounds[:])
            if c == 0 or self.restarted:
                # cs:43C5 / EP10 cs:3EE5: the counter was 0FFFFh, the message is gone (EP9-13 then run their
                # idle display, which starts a new message; recording stops here).
                rec.update(dots=[], colours=None, ended=True)
                out['frames'].append(rec)
                break
            rec['dots'], rec['colours'] = self.plotted()
            out['frames'].append(rec)
            draw_lines(f + 1)
        return out

    def _on_dmd(self, uc, address, size, _):
        self.restarted = True

    def _on_sfx(self, uc, address, size, _):
        from unicorn.x86_const import UC_X86_REG_AX
        self.sounds.append(uc.reg_read(UC_X86_REG_AX))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--table', type=int, default=1)
    ap.add_argument('--string', type=lambda s: int(s, 0))
    ap.add_argument('--ax', type=lambda s: int(s, 0), default=0x101)
    ap.add_argument('--di', type=lambda s: int(s, 0), default=0)
    ap.add_argument('--colour', type=lambda s: int(s, 0))
    ap.add_argument('--frames', type=int, default=300)
    ap.add_argument('--batch')
    ap.add_argument('--games', help='JSON list of full-mode scenarios (run_scenario.py format)')
    ap.add_argument('-o', '--out')
    a = ap.parse_args()
    if a.games:
        s = json.dumps([run_game(scn) for scn in json.load(open(a.games))])
        if a.out:
            open(a.out, 'w').write(s)
        else:
            print(s)
        return
    if a.batch:
        cases = json.load(open(a.batch))
    else:
        cases = [dict(table=a.table, string=a.string, ax=a.ax, di=a.di, frames=a.frames, colour=a.colour)]
    runners, results = {}, []
    for c in cases:
        t = c.get('table', 1)
        if t not in runners:
            runners[t] = Runner(t)
        results.append(runners[t].run(c))
    s = json.dumps(results if a.batch else results[0])
    if a.out:
        open(a.out, 'w').write(s)
    else:
        print(s)


if __name__ == '__main__':
    main()
