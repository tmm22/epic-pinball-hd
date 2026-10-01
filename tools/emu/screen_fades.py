#!/usr/bin/env python3
"""Ground truth for the whole-screen palette fades: boot the ORIGINAL EPn.EXE under Unicorn and record the VGA DAC
at every frame of the boot (the fade-in and the intro scroll), then run the original fade-out routine (the quit
path's, EP1 cs:136F) with entry counts 0 and FFh and record the DAC at every one of its frames.

Usage:
  .venv/bin/python tools/emu/screen_fades.py --tables 1,8,10 [-o out.json]

A frame's DAC is taken where wait_frame starts its retrace wait (`mov dx,3DAh`), i.e. after everything the
frame writes before the picture is shown (EP8's palette rotation runs at the top of wait_frame). Values are 6-bit,
768 bytes as hex. Output per table:
  boot:     [{"from": call site, "display": display start (AX of the far display routine), "dac": hex}, ...]
  after_boot: {"working", "dac", "counter", "speed"}   (W, the DAC, EP8's rotation counter and speed bytes)
  fade_out: [{"count": n, "start": {...as after_boot}, "frames": [hex, ...]}, ...]
The routines are found by the same code shapes as app/Sources/PinballCore/Presentation/ScreenFade.swift
(docs/enhanced/presentation.md section 3).
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
from unicorn import UC_HOOK_CODE, UC_HOOK_INSN  # noqa: E402
from unicorn.x86_const import UC_X86_INS_OUT, UC_X86_REG_AX, UC_X86_REG_SP, UC_X86_REG_SS  # noqa: E402


def pat(p):
    return re.compile(b''.join(b'.' if x is None else re.escape(bytes([x])) for x in p), re.S)


def layout(code):
    w = lambda i: struct.unpack_from('<H', code, i)[0]
    loop = next(pat([0x05, 0x50, 0x00, 0x3D, None, None, 0x73, None, 0x50, 0x9A]).finditer(code)).start()
    display = w(loop + 10)
    fo = next(m.start() for m in pat([0xB0, 0x00, 0xB9, 0x00, 0x00, 0xBF, 0x00, 0x00, 0x8A, 0xA5, None, None, 0x80, 0xFC,
                                      0x00, 0x74, 0x09, 0xC0, 0xEC, 0x03, 0xFE, 0xC4, 0x28, 0xA5]).finditer(code)
              if pat([0xFE, 0xC0, 0x3A, 0x06]).search(code, m.start(), m.start() + 0x40))
    working = w(fo + 10)
    n = pat([0xFE, 0xC0, 0x3A, 0x06]).search(code, fo, fo + 0x40).start()
    count = w(n + 4)
    call = code.index(b'\xe8', n + 6)
    wait = (call + 3 + struct.unpack_from('<h', code, call + 1)[0]) & 0xFFFF
    vsync = code.index(bytes([0xBA, 0xDA, 0x03]), wait)
    assert vsync - wait < 0x20 and code[fo - 3:fo] == b'\x06\x1e\x60'
    # EP8's rotation: pusha; inc byte [C]; mov al,[C]; cmp al,[S] ... (PaletteCycle.swift)
    cyc = pat([0x60, 0xFE, 0x06, None, None, 0xA0, None, None, 0x3A, 0x06]).search(code)
    counter = speed = None
    if cyc and w(cyc.start() + 3) == w(cyc.start() + 6):
        counter, speed = w(cyc.start() + 3), w(cyc.start() + 10)
    return dict(display=display, fade_out=fo - 3, working=working, count=count, wait=wait, vsync=vsync,
                counter=counter, speed=speed)


class Recorder:
    def __init__(self, table):
        self.table = table
        exe = epexe.load(os.path.join(ep_emu.ROOT, 'original', f'EP{table}.EXE'))
        self.code = exe.data[exe.image_off(exe.entry_cs):][:0x10000]
        self.L = layout(self.code)
        self.e = ep_emu.EpEmu(table, boot=False)
        self.dac = bytearray(768)
        self.idx = self.part = 0
        self.disp = None
        self.frames = []
        e, cs = self.e, self.e.cs
        e.uc.hook_add(UC_HOOK_INSN, self._out, None, 1, 0, UC_X86_INS_OUT)
        a = e.lin(cs, self.L['display'])
        e.uc.hook_add(UC_HOOK_CODE, self._display, None, a, a)
        a = e.lin(cs, self.L['vsync'])
        e.uc.hook_add(UC_HOOK_CODE, self._vsync, None, a, a)

    def _out(self, uc, port, size, value, _):
        v = value & 0xFF
        if port == 0x3C8:
            self.idx, self.part = v, 0
        elif port == 0x3C9:
            self.dac[3 * self.idx + self.part] = v & 0x3F
            self.part += 1
            if self.part == 3:
                self.part, self.idx = 0, (self.idx + 1) & 0xFF

    def _display(self, uc, address, size, _):
        self.disp = uc.reg_read(UC_X86_REG_AX)

    def _vsync(self, uc, address, size, _):
        ss, sp = uc.reg_read(UC_X86_REG_SS), uc.reg_read(UC_X86_REG_SP)
        ret = struct.unpack('<H', bytes(uc.mem_read((ss << 4) + sp + 18, 2)))[0]   # wait_frame: push ds; pusha
        self.frames.append(dict(src=ret - 3, display=self.disp, dac=bytes(self.dac).hex()))

    def state(self):
        e, L = self.e, self.L
        return dict(working=bytes(e.uc.mem_read(e.lin(e.ds, L['working']), 768)).hex(), dac=bytes(self.dac).hex(),
                    counter=e.rb(e.ds, L['counter']) if L['counter'] is not None else 0,
                    speed=e.rb(e.ds, L['speed']) if L['speed'] is not None else 0)

    def run(self):
        e, L = self.e, self.L
        e.boot()
        boot = [dict(src=f['src'], display=f['display'], dac=f['dac']) for f in self.frames]
        after = self.state()
        snap, dac0 = e.snapshot(), bytes(self.dac)
        outs = []
        for n in (0, 0xFF):
            e.restore(snap)
            self.dac[:] = dac0
            e.wb(e.ds, L['count'], n)
            start = self.state()
            del self.frames[:]
            e.call_near(L['fade_out'], limit=50_000_000)
            outs.append(dict(count=n, start=start, frames=[f['dac'] for f in self.frames]))
        return dict(table=self.table, layout=L, boot=boot, after_boot=after, fade_out=outs)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--tables', default=','.join(str(t) for t in range(1, 14)))
    ap.add_argument('-o', '--out')
    a = ap.parse_args()
    res = [Recorder(int(t)).run() for t in a.tables.split(',')]
    s = json.dumps(res)
    if a.out:
        open(a.out, 'w').write(s)
    else:
        print(s)


if __name__ == '__main__':
    main()
