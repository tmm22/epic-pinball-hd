#!/usr/bin/env python3
"""Does EP9-EP13 render_frame's plot skip change what is on screen?  Runs ORIGINAL games (EPn.EXE under Unicorn,
full mode, the frame order of run_scenario.py) and watches every render_frame call.

EP9-EP13 render_frame (EP10 cs:38E1) joins its effect blocks at `cmp word [F],2; ja skip` (EP10 cs:3ED7, F = ds:0619,
the idle-display flag: 0 after every dmd_message (cs:1614), 1 at the end of the idle display cs:341B (cs:34D4), +1 per
render_frame call while non-zero (cs:3F7E)).  With F > 2 the call clears nothing, plots nothing and leaves an ended
message's counter at 0FFFFh, so the strip keeps what the last plot drew.  The port plots every frame.  That changes no
pixel as long as, at each skipped call:
  * the counter is not 0FFFFh (an ended message would vanish in the port but stay in the original),
  * the dots and colours the plot loop would draw now equal the ones it drew last, and
  * no other code wrote into the strip's VRAM (A000:0000..095F, rows 0..29) since that plot.
The tool counts the skipped calls that break any of these, and lists the other code that wrote into the strip
(found this way: the main loop's background restore of a draining ball on the second VRAM page, which wraps past
A000:FFFF into the strip; docs/enhanced/presentation.md section 6).

Usage:
  .venv/bin/python tools/emu/plot_skip_check.py [--tables 9,10,11,12,13] [--frames 6000] [-o out.json]
Runs per table: the demo (players 'D', the table plays itself) and a one-player game with a plunge and
alternating flips (until the original waits for a key in a loop the fixed inputs do not answer; the run stops
there).  Exit status 0 iff no skipped call can change a pixel.
"""
import argparse
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import dot_effects  # noqa: E402
import ep_emu  # noqa: E402
import epexe  # noqa: E402
import run_scenario  # noqa: E402
from unicorn import UC_HOOK_CODE, UC_HOOK_MEM_WRITE  # noqa: E402
from unicorn.x86_const import UC_X86_REG_CS, UC_X86_REG_IP  # noqa: E402

STRIP = (0xA0000, 0xA0000 + 80 * 30)


def inputs_game(frames):
    out = []
    for f in range(frames):
        k = 0
        if f % 600 < 50:
            k |= 4                      # plunger held, then let go
        if f % 90 in range(60, 66):
            k |= 1
        if f % 90 in range(75, 81):
            k |= 2
        out.append(k)
    return out


def check(table, frames, demo):
    scn = dict(table=table, start='boot', mode='full', frames=frames, on_drain='continue',
               pokes={'demo_mode': 1} if demo else {})
    emu = run_scenario.setup(scn, 'full')
    exe = epexe.load(emu.exe_path)
    code = bytes(exe.data[exe.image_off(exe.entry_cs):][:0x10000])
    L = dot_effects.find_layout(code)
    m = re.search(rb'\x83\x3e(..)\x02\x77.\x53\xb3', code[L['effects_end']:L['effects_end'] + 0x20], re.S)
    if not m:
        return dict(table=table, demo=demo, error='no plot-skip check')
    at = L['effects_end'] + m.start()
    flag = struct.unpack('<H', m.group(1))[0]
    rf_lo, rf_hi = L['render_frame_entry'], L['plot'] + 0x80
    st = dict(calls=0, skipped=0, ended=0, changed=0, foreign=0, plots=0, writes=0, first=None, writers={})
    last = {'plot': None, 'foreign': False}
    frame = [0]

    def on_check(uc, a, s, _):
        st['calls'] += 1
        if emu.rw(emu.ds, flag, signed=False) <= 2:
            return
        st['skipped'] += 1
        bad = []
        if emu.rw(emu.ds, L['counter'], signed=False) == 0xFFFF:
            st['ended'] += 1; bad.append('ended')
        if last['plot'] is not None and dot_effects.plotted(emu, L) != last['plot']:
            st['changed'] += 1; bad.append('changed')
        if last['foreign']:
            st['foreign'] += 1; bad.append('foreign')
        if bad and st['first'] is None:
            st['first'] = dict(frame=frame[0], why=bad)

    def on_plot(uc, a, s, _):
        st['plots'] += 1
        last['plot'] = dot_effects.plotted(emu, L)
        last['foreign'] = False

    def on_write(uc, access, address, size, value, _):
        st['writes'] += 1
        ip, cs = uc.reg_read(UC_X86_REG_IP), uc.reg_read(UC_X86_REG_CS)
        if cs != emu.cs or not (rf_lo <= ip < rf_hi):   # render_frame's own clear and plot are not foreign
            last['foreign'] = True
            k = f'{cs:04x}:{ip:04x}'
            st['writers'][k] = st['writers'].get(k, 0) + 1

    hooks = []
    for addr, fn in ((at, on_check), (L['plot'], on_plot)):
        a = emu.lin(emu.cs, addr)
        hooks.append(emu.uc.hook_add(UC_HOOK_CODE, fn, None, a, a))
        emu.uc.ctl_remove_cache(a, a + 1)
    hooks.append(emu.uc.hook_add(UC_HOOK_MEM_WRITE, on_write, None, STRIP[0], STRIP[1] - 1))
    keys = [] if demo else inputs_game(frames)
    try:
        for f in range(frames):
            frame[0] = f
            if not demo:
                emu.set_keys(keys[f])
            emu.main_loop_full()
            for _ in range(3):
                emu.physics_step()
            emu.post_frame()
    except ep_emu.EmuError as e:
        st['stopped'] = f'frame {frame[0]}: {e}'
    finally:
        for h in hooks:
            emu.uc.hook_del(h)
    st.update(table=table, demo=demo, frames=frames, check=at, flag=flag)
    return st


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--tables', default='9,10,11,12,13')
    ap.add_argument('--frames', type=int, default=6000)
    ap.add_argument('--game-only', action='store_true', help='only the one-player game run')
    ap.add_argument('-o', '--out')
    a = ap.parse_args()
    res = []
    for t in a.tables.split(','):
        for demo in ((True, False) if not a.game_only else (False,)):
            r = check(int(t), a.frames, demo)
            res.append(r)
            print(f"EP{t} {'demo' if demo else 'game'}: {r.get('calls', 0)} render_frame calls, {r.get('skipped', 0)} skipped "
                  f"({r.get('plots', 0)} plots, {r.get('writes', 0)} strip writes); ended {r.get('ended', 0)}, list changed {r.get('changed', 0)}, other strip writes {r.get('foreign', 0)}"
                  + (f"; first {r['first']}" if r.get('first') else '') + (f"; {r['stopped']}" if r.get('stopped') else '')
                  + (f"; {r['error']}" if r.get('error') else '')
                  + (f"; other writers {dict(sorted(r['writers'].items(), key=lambda kv: -kv[1])[:6])}" if r.get('writers') else ''))
    if a.out:
        json.dump(res, open(a.out, 'w'))
    bad = sum(r.get('ended', 0) + r.get('changed', 0) + r.get('foreign', 0) for r in res)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
