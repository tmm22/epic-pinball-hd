#!/usr/bin/env python3
"""Demo-mode ("attract") scenarios: tools/emu/scenarios/EPn/attract/*.json for every table.

The original plays itself when PINBALL.EXE passes players 'D' (demo_mode = 1, EP1 cs:0081): auto
plunge (cs:0B44), auto-flip and the stuck-ball nudge (attract_autoflip cs:0C48), no key handling or
nudge/tilt (cs:0D1D..0E8A skipped).  The scenarios poke demo_mode = 1 after the boot (run_scenario.py
then pokes no keys) and must run in `full` mode, the only mode that executes the whole main loop:

  .venv/bin/python tools/emu/make_attract_scenarios.py            # (re)write all 13 sets
  .venv/bin/python tools/emu/diff_traces.py -q --mode full --table N tools/emu/scenarios/EPn/attract

Per table (ball positions are taken from the table's own generated scenarios):
  attract_boot         the demo as PINBALL.EXE starts it: `"start": "boot"`, players 'D' on the command line,
                       from the first main-loop arrival after the table's own boot.
  attract_serve        ball 0 at the serve position (plunger_launch.json): the demo's plunge.  EP1 plays
                       on through drains and serves; EP2-EP13 hold the plunger forever (no cs:0B79).
  attract_drop_left/right  ball 0 dropped onto a resting lower flipper (fall_*_flipper_released.json):
                       the auto-flip zones and, once the ball sits still, the stuck-ball nudge.
Nothing from the game is written: only positions, frame counts and the poke.
"""
import argparse
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SC = os.path.join(HERE, 'scenarios')


def load(table, name):
    p = os.path.join(SC, f'EP{table}', name + '.json')
    if not os.path.exists(p) and table == 1:
        p = os.path.join(SC, name + '.json')
    return json.load(open(p)) if os.path.exists(p) else None


def make(table):
    out = [('attract_boot', None, 6000 if table == 1 else 900,
            "The demo as PINBALL.EXE starts it: players 'D' on the command line, from the first main-loop arrival "
            "after the boot (flippers at their boot angle, the EXE's ball slots).")]
    serve = load(table, 'plunger_launch')
    if serve:
        out.append(('attract_serve', serve['ball'], 6000 if table == 1 else 900,
                    'Demo mode from the serve position: the demo plunges (EP1 releases past 700, cs:0B79; the other '
                    'tables hold the plunger at its maximum and the ball stays in the lane), auto-flips and nudges.'))
    for side in ('left', 'right'):
        s = load(table, f'fall_{side}_flipper_released')
        if s:
            out.append((f'attract_drop_{side}', s['ball'], 1200,
                        f'Demo mode, ball dropped onto the resting {side} flipper: the auto-flip zone (y >= 350, '
                        f'x 88..138 / 148..193) presses the key for 10 frames; drains are served (on_drain continue).'))
    d = os.path.join(SC, f'EP{table}', 'attract')
    os.makedirs(d, exist_ok=True)
    for name, ball, frames, desc in out:
        scn = dict(name=name, table=table, frames=frames)
        scn.update(dict(start='boot') if ball is None else dict(ball=ball))
        scn.update(mode='full', on_drain='continue', pokes=dict(demo_mode=1), description=desc, inputs=[])
        with open(os.path.join(d, name + '.json'), 'w') as f:
            json.dump(scn, f, indent=1)
            f.write('\n')
    return [o[0] for o in out]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--table', type=int, nargs='*', default=list(range(1, 14)))
    a = ap.parse_args()
    for t in a.table:
        print(f'EP{t}: {", ".join(make(t))}')


if __name__ == '__main__':
    main()
