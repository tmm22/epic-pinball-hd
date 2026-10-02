#!/usr/bin/env python3
"""Rules/message fidelity scenarios: tools/emu/scenarios/EPn/fidelity/*.json for EP2..EP13.

Full-mode scenarios that record, besides the ball trace, what the rules show and keep between balls
(scenario key "watch", run_scenario.py / the port's --trace: the last record of every frame gets
`extra.watch_ds` and `extra.messages`, the frame's dmd_message calls as [string DS offset, AX, DI]):

  release        ball 0 drains at once; the serve, ball_lost_fade, then the plunger held 40 frames and let go.
                 Watches the between-balls flag (EP2 ds:0713 / EP4 ds:070C / EP6 ds:4924 / EP7 ds:093A: set after
                 the palette loop, EP2 cs:35F0, cleared by the release code, cs:0CFA), the message counter and
                 the messages (next-ball message EP2 cs:0CC9, idle text, EP9-13 score refresh).  Not EP8 (no lane).
  serve_idle     ball 0 at the serve position, no input, 900 frames: the timed message (EP2 cs:04AB, every 281
                 frames until the first release) and the counter.
  boot           `"start": "boot"`, 1 player: the boot tail (EP2 cs:0486: intro message, counter 32h).
  nodemo_drop_left / demo_drop_left / demo_drop_right
                 the attract drop scenarios (make_attract_scenarios.py positions) without and with demo mode, with
                 messages and counter: the ball-end chain (EP5 cs:1F4A, EP9 cs:2F39), EP8's transport message
                 (cs:296E reads the counter), EP9-13's between-balls display (EP12 cs:049A).

  .venv/bin/python tools/emu/make_fidelity_scenarios.py
  .venv/bin/python tools/emu/diff_traces.py -q --mode full --table N tools/emu/scenarios/EPn/fidelity

The flag and counter addresses are found in the user's EXE by the code shapes the port uses (PaletteFade.find,
DotEffects.find); only addresses, positions and frame counts are written.
"""
import argparse
import json
import os
import re
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
SC = os.path.join(HERE, 'scenarios')


def code_segment(table):
    cfg = json.load(open(os.path.join(HERE, 'tables', f'EP{table}.json')))['auto']
    exe = open(os.path.join(ROOT, 'original', f'EP{table}.EXE'), 'rb').read()
    hdr = struct.unpack_from('<H', exe, 8)[0] * 16
    cs = int(cfg['cs'], 16)
    return exe[hdr + cs * 16: hdr + cs * 16 + 0x10000]


def addresses(table):
    c = code_segment(table)
    # dmd_message: mov word [counter],1; mov al,0FFh; mov dx,3C8h; out dx,al; inc dx
    m = re.search(rb'\xc7\x06(..)\x01\x00\xb0\xff\xba\xc8\x03\xee\x42', c, re.S)
    counter = struct.unpack('<H', m.group(1))[0] if m else None
    # ball_lost_fade's dim: inc ch; cmp ch,P; jne; mov byte [F],1
    fl = [struct.unpack('<H', x.group(1))[0] for x in re.finditer(rb'\xfe\xc5\x80\xfd.\x75.\xc6\x06(..)\x01', c, re.S)]
    return counter, (fl[0] if len(fl) == 1 else None)


def load(table, path):
    p = os.path.join(SC, f'EP{table}', path + '.json')
    return json.load(open(p)) if os.path.exists(p) else None


def make(table):
    counter, flag = addresses(table)
    ds = ([[f'0x{flag:04x}', 1]] if flag is not None else []) + ([[f'0x{counter:04x}', 2]] if counter is not None else [])
    watch = dict(ds=ds, messages=True)
    out = []
    if table != 8:
        out.append(('release', dict(ball=dict(x=150, y=392, xf=0, yf=0, vx=0, vy=300), frames=300, inputs=[0] * 40 + [4] * 40),
                    'Ball 0 drains at once: serve, ball_lost_fade (between-balls flag, ball-end messages), then the '
                    'plunger held for 40 frames and let go (release code: flag cleared, next-ball message, idle text).'))
    serve = load(table, 'attract/attract_serve')
    if serve:
        out.append(('serve_idle', dict(ball=serve['ball'], frames=900, inputs=[]),
                    'Ball 0 waits at the serve position, no input: the timed message cycle and the message counter.'))
    out.append(('boot', dict(start='boot', frames=300, inputs=[]),
                'The first main-loop arrival after the boot, 1 player: the boot tail (intro message, counter 32h).'))
    for side, demo in (('left', False), ('left', True), ('right', True)):
        s = load(table, f'attract/attract_drop_{side}')
        if s:
            out.append((f'{"demo" if demo else "nodemo"}_drop_{side}', dict(ball=s['ball'], frames=1200, inputs=[],
                                                                            **({'pokes': {'demo_mode': 1}} if demo else {})),
                        f'Ball 0 dropped onto the resting {side} flipper{" in demo mode" if demo else ""}; drains are '
                        'served (on_drain continue): ball-end chain, between-balls display, messages and counter.'))
    d = os.path.join(SC, f'EP{table}', 'fidelity')
    os.makedirs(d, exist_ok=True)
    for name, body, desc in out:
        scn = dict(name=name, table=table)
        scn.update(body)
        scn.update(mode='full', on_drain='continue', watch=watch, description=desc)
        with open(os.path.join(d, name + '.json'), 'w') as f:
            json.dump(scn, f, indent=1)
            f.write('\n')
    return [o[0] for o in out], counter, flag


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--table', type=int, nargs='*', default=list(range(2, 14)))
    a = ap.parse_args()
    for t in a.table:
        names, counter, flag = make(t)
        print(f'EP{t}: {", ".join(names)} (counter {counter and hex(counter)}, flag {flag and hex(flag)})')


if __name__ == '__main__':
    main()
