#!/usr/bin/env python3
"""Cross-check scratch/engine/ep1_physics_ref.py against the emulator (original code).

For every scenario the Python reference Sim is started from the same raw ball state
(flippers at rest) and driven frame by frame with the same inputs; each physics step is
compared field by field with the emulator trace.  The emulator is ground truth.

  .venv/bin/python tools/emu/compare_ref.py [scenario.json ...] [--plunger-adapter] [-v]

--plunger-adapter adds the main-loop lane/plunger rules that the reference lacks
(cs:0A9D..0C48: vx=0 while in the lane and the plunger is up; charge +12/frame while
<=700; on release vy -= charge, y -= 1), so the remaining differences are physics only.
"""
import argparse
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, 'scratch', 'engine'))
import run_scenario  # noqa: E402

FIELDS = ('x', 'y', 'xf', 'yf', 'vx', 'vy')


def contact_dir(hits):
    """cs:1A66..1ACE, same formula the reference uses internally."""
    lo, hi = min(hits), max(hits)
    if lo == 1 and hi == 48:
        first, last = hits[0], hits[-1]
        d = last + (((first + 48 - last) & 0xFF) >> 1)
        return d - 48 if d > 48 else d
    d = hi - lo
    if d > 24:
        r = lo + (d >> 1) + 24
        return r - 48 if r > 48 else r
    return lo + (d >> 1)


def ref_trace(scn, plunger_adapter=False, n_steps=None):
    import ep1_physics_ref as ref

    class Sim(ref.Sim):
        def respond(self, hits, kick, flipflag, collided):
            self.step_resp.append((contact_dir(hits), collided))
            return super().respond(hits, kick, flipflag, collided)

    s = Sim()
    b = scn['ball']
    s.x, s.y, s.ax, s.ay, s.vx, s.vy = b['x'], b['y'], b.get('xf', 0), b.get('yf', 0), b.get('vx', 0), b.get('vy', 0)
    if scn.get('params'):
        raise SystemExit('params overrides are not supported by the reference (module constants)')
    charge = 0
    out = []
    inputs = scn.get('inputs', [])
    for f in range(scn['frames']):
        m = inputs[f] if f < len(inputs) else 0
        held = {'left': bool(m & 1), 'right': bool(m & 2)}
        if plunger_adapter and s.x >= 0x118 and s.y >= 0xDC:
            if m & 4:
                if charge <= 700:
                    charge += 12
            else:
                s.vx = 0
                if charge:
                    s.vy -= charge
                    s.y -= 1
                    charge = 0
        # Sim.frame(), unrolled so each step can be recorded
        if s.kick_cooldown:
            s.kick_cooldown -= 1
        if s.vy <= 0x140:
            s.vy += ref.GRAVITY
        for st in range(3):
            s.step_resp = []
            s.step(held)
            first = [k for k, c in s.step_resp if not c]
            out.append(dict(frame=f, step=st,
                            ball=dict(x=s.x, y=s.y, xf=s.ax, yf=s.ay, vx=s.vx, vy=s.vy),
                            collided=bool(s.step_resp), k=first[0] if first else None,
                            left_flipper_pos=s.flip['left'], right_flipper_pos=s.flip['right']))
            if n_steps and len(out) >= n_steps:
                return out
    return out


def compare(emu, ref):
    """Return (index, list of differing fields) of the first mismatch, or None."""
    for i, (a, b) in enumerate(zip(emu, ref)):
        diffs = [k for k in FIELDS if a['ball'][k] != b['ball'][k]]
        for k in ('collided', 'k', 'left_flipper_pos', 'right_flipper_pos'):
            if a[k] != b[k]:
                diffs.append(k)
        if diffs:
            return i, diffs
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('scenarios', nargs='*')
    ap.add_argument('--plunger-adapter', action='store_true')
    ap.add_argument('-v', '--verbose', action='store_true')
    a = ap.parse_args()
    files = a.scenarios or sorted(glob.glob(os.path.join(HERE, 'scenarios', '*.json')))
    n_ok = 0
    for fn in files:
        scn = json.load(open(fn))
        emu = run_scenario.run(scn)
        ref = ref_trace(scn, a.plunger_adapter, len(emu))
        r = compare(emu, ref)
        name = os.path.basename(fn)[:-5]
        if r is None:
            n_ok += 1
            print(f'{name:30s} MATCH  {len(emu)} steps')
            continue
        i, diffs = r
        e, p = emu[i], ref[i]
        print(f'{name:30s} DIFFER at step {i} (frame {e["frame"]}.{e["step"]}) of {len(emu)}: {",".join(diffs)}')
        print(f'    emu {e["ball"]} coll={e["collided"]} k={e["k"]} L={e["left_flipper_pos"]} R={e["right_flipper_pos"]}')
        print(f'    ref {p["ball"]} coll={p["collided"]} k={p["k"]} L={p["left_flipper_pos"]} R={p["right_flipper_pos"]}')
        if a.verbose and i:
            q = emu[i - 1]
            print(f'    prev emu {q["ball"]} k={q["k"]}  extra={q["extra"]}')
            print(f'    emu extra at diff {e["extra"]}')
    print(f'{n_ok}/{len(files)} scenarios match step-for-step')


if __name__ == '__main__':
    main()
