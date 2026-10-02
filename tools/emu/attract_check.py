#!/usr/bin/env python3
"""Demo mode, original vs port, beyond the ball trace: every dmd_message call (string DS offset, AX, DI)
frame by frame, the demo's DS state, and for EP1 the whole data segment outside display buffers.

The ball traces of the same scenarios are compared by diff_traces.py (`--mode full`); this adds what the
dot display shows (the demo's idle text, EP1 cs:3AFF -> dmd_message, and every rule message) and the
demo-mode bytes (flip timer, key repeat, stuck-ball counter and positions; Attract.swift).

  .venv/bin/python tools/emu/attract_check.py                    # all 13 tables, tools/emu/scenarios/EPn/attract/
  .venv/bin/python tools/emu/attract_check.py --table 1 10 --frames 3000
  .venv/bin/python tools/emu/attract_check.py --scenario tools/emu/scenarios/EP1/attract/attract_serve.json

Needs the port built (app/.build/debug/EpicPinball) and the user's data (original/, extracted/). The
dmd_message entry of each table is read from extracted/tables/EPn/rules.json (stub_routines). Prints
only offsets and counts, never text from the game. Exit status 0 iff everything matches.
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)
import ep_emu  # noqa: E402
import run_scenario  # noqa: E402
from unicorn import UC_HOOK_CODE  # noqa: E402
from unicorn.x86_const import UC_X86_REG_AX, UC_X86_REG_BX, UC_X86_REG_DI  # noqa: E402

BIN = os.path.join(ROOT, 'app', '.build', 'debug', 'EpicPinball')
# RulesLiveTests.ignored: EP1 display-only / physics-scratch DS ranges
EP1_IGNORED = [(0x0000, 0x0008), (0x0009, 0x000B), (0x0DC0, 0x5870), (0x5315, 0x5317), (0x6C10, 0x6C1C), (0x6C1E, 0x6C6C),
               (0x586E, 0x5870), (0x6768, 0x6769), (0x6A38, 0x6A3A), (0x6A5E, 0x6B36), (0x0B38, 0x0B3D), (0x0B3F, 0x0B40)]


def message_entry(table):
    r = json.load(open(os.path.join(ROOT, 'extracted', 'tables', f'EP{table}', 'rules.json')))
    ms = [int(k, 16) for k, v in r['stub_routines'].items() if v[0] == 'message']
    if len(ms) != 1:
        raise SystemExit(f'EP{table}: rules.json has {len(ms)} message routines')
    m = r['memory']
    return ms[0], int(m['data_segment_file_offset'], 16), int(str(m['data_segment_size']), 0)


def original(scn, frames, msg_ip, ds_size):
    emu = run_scenario.setup(scn)
    calls = []
    h = emu.uc.hook_add(UC_HOOK_CODE, lambda uc, a, s, _: calls.append(
        [uc.reg_read(UC_X86_REG_BX), uc.reg_read(UC_X86_REG_AX), uc.reg_read(UC_X86_REG_DI)]),
        None, emu.lin(emu.cs, msg_ip), emu.lin(emu.cs, msg_ip))
    out = []
    try:
        for f in range(frames):
            emu.main_loop_full()
            for _ in range(3):
                emu.physics_step()
            out.append(dict(msg=calls[:], ds=bytes(emu.uc.mem_read(emu.ds * 16, ds_size)) if ds_size else None))
            calls.clear()
            emu.post_frame()   # EP9-EP13 render_frame (cs:1238); as in run_scenario.py, counted with the next frame
    finally:
        emu.uc.hook_del(h)
    return out


def port(path, table, frames):
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, 't.jsonl')
        subprocess.run([BIN, '--trace', path, '--out', out, '--table', str(table), '--state'],
                       check=True, capture_output=True, cwd=os.path.join(ROOT, 'app'))
        recs = [json.loads(l) for l in open(out)]
    return [r['extra'] for r in recs if 'ds' in r.get('extra', {})]


def check(path, frames_cap):
    scn = json.load(open(path))
    table = scn['table']
    frames = min(scn['frames'], frames_cap) if frames_cap else scn['frames']
    scn = dict(scn, frames=frames)
    msg_ip, ds_file, size = message_entry(table)
    exe = open(os.path.join(ROOT, 'original', f'EP{table}.EXE'), 'rb').read()
    ds_size = size if table == 1 else None   # the per-frame DS check is EP1's (RulesLiveTests' ignore list)
    tmp = tempfile.NamedTemporaryFile('w', suffix='.json', delete=False)
    json.dump(scn, tmp)
    tmp.close()
    try:
        o = original(scn, frames, msg_ip, ds_size)
        p = port(tmp.name, table, frames)
    finally:
        os.unlink(tmp.name)
    name = f'EP{table} {os.path.basename(path)[:-5]}'
    if len(o) != len(p):
        return False, f'{name}: frame count original {len(o)} port {len(p)}'
    msgs = 0
    a = bytearray(exe[ds_file:ds_file + ds_size]) if ds_size else None
    b = bytearray(a) if a is not None else None
    skip = set()
    for lo, hi in EP1_IGNORED:
        skip.update(range(lo, hi))
    for f in range(len(o)):
        if o[f]['msg'] != p[f]['msg']:
            return False, f'{name} frame {f}: dmd_message calls differ: original {o[f]["msg"]} port {p[f]["msg"]}'
        msgs += len(o[f]['msg'])
        if a is not None:
            cur = o[f]['ds']
            for i in range(ds_size):
                if i not in skip:
                    a[i] = cur[i]
            for off, v in p[f]['ds']:
                if off < ds_size and off not in skip:
                    b[off] = v
            if a != b:
                diffs = [i for i in range(ds_size) if a[i] != b[i]][:6]
                return False, f'{name} frame {f}: DS differs at ' + ', '.join(f'ds:{i:04X} orig {a[i]} port {b[i]}' for i in diffs)
    return True, f'{name}: {len(o)} frames, {msgs} dmd_message calls identical' + (', data segment identical' if a is not None else '')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--table', type=int, nargs='*', default=list(range(1, 14)))
    ap.add_argument('--frames', type=int, default=0, help='cap per scenario (default: the scenario frames)')
    ap.add_argument('--scenario', nargs='*')
    a = ap.parse_args()
    paths = a.scenario or [p for t in a.table for p in sorted(glob.glob(os.path.join(HERE, 'scenarios', f'EP{t}', 'attract', '*.json')))]
    ok_all = True
    for p in paths:
        ok, line = check(p, a.frames)
        ok_all &= ok
        print(('OK    ' if ok else 'FAIL  ') + line, flush=True)
    sys.exit(0 if ok_all else 1)


if __name__ == '__main__':
    main()
