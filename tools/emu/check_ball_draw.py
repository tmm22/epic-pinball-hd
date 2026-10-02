#!/usr/bin/env python3
"""Which ball slots does the original draw? (docs/enhanced/rendering.md, "Multiball")

Runs the user's EPn.EXE in the harness, puts a ball in every slot (and a case with slot 0 empty),
runs the real main loop (cs:04D2 .. frame sync) and counts the calls of the ball blit that ends
ball_pixel_scan (EP1 cs:171E lcall cs:54D8, EP10 cs:16BB lcall cs:484A). The blit is found by
signature: the scan starts with `mov cx,0D6h; rep movsb` (EP1 cs:1685), and its blit is the first
far call followed by `ret`. A ball whose sensor handler sets the "moved" flag (EP1 [589Ah], tested at
cs:170A) is not blitted that frame, so a test row on a sensor shows fewer blits (try another --y).
Result on the 1995 CD's EXEs (--y 200): EP1-8 blit all five slots, EP9-13 slots 0-2, with or without
slot 0 (EP8 hangs with slot 0 empty at that row; EP12 skips one ball on a sensor).

    .venv/bin/python tools/emu/check_ball_draw.py [--tables 1,3,10]
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from unicorn import UC_HOOK_CODE  # noqa: E402
from unicorn.x86_const import UC_X86_REG_AX, UC_X86_REG_CX  # noqa: E402
from ep_emu import EpEmu  # noqa: E402


def find_blit(emu):
    code = bytes(emu.uc.mem_read(emu.lin(emu.cs, 0), 0x10000))
    scan = code.find(bytes.fromhex('b9d600f3a4'))
    if scan < 0:
        return None, None
    j = code.find(b'\x9a', scan)
    while 0 <= j < scan + 0x120:
        if code[j + 5] == 0xC3:
            return scan, int.from_bytes(code[j + 1:j + 3], 'little'), j
        j = code.find(b'\x9a', j + 1)
    return scan, None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--y', type=int, default=200, help='row the test balls are placed on')
    ap.add_argument('--tables', default=','.join(str(n) for n in range(1, 14)))
    args = ap.parse_args()
    for n in [int(t) for t in args.tables.split(',')]:
        emu = EpEmu(table=n)
        boot = [(i, emu.ball(i)['x'], emu.ball(i)['y']) for i in range(emu.slots) if emu.ball(i)['active']]
        scan, blit, site = find_blit(emu)
        if blit is None:
            print(f'EP{n}: ball blit not found')
            continue
        calls = []
        a = emu.lin(emu.cs, blit)
        emu.uc.hook_add(UC_HOOK_CODE, lambda uc, addr, size, _: calls.append((uc.reg_read(UC_X86_REG_AX), uc.reg_read(UC_X86_REG_CX))), None, a, a)
        emu.main_loop_full()
        at_boot = list(calls)
        out = []
        for name, empty0 in (('all 5 slots', False), ('slot 0 empty', True)):
            emu.reset_play_state()
            for i in range(emu.slots):
                emu.set_ball(i, x=40 + 50 * i, y=args.y, active=0 if (empty0 and i == 0) else 1)
            calls.clear()
            try:
                emu.main_loop_full()
            except Exception as e:  # e.g. a ball placed where the original's code hangs
                out.append(f'{name}: {type(e).__name__}')
                continue
            out.append(f'{name}: {len(calls)} blits at {calls}')
        print(f'EP{n}: scan cs:{scan:04X}, blit lcall at cs:{site:04X} -> cs:{blit:04X}; after boot active {boot}, '
              f'blitted {at_boot}; ' + '; '.join(out))


if __name__ == '__main__':
    main()
