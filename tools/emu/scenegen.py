#!/usr/bin/env python3
"""Generate a per-table scenario set from each table's own geometry, checked on the original code.

Used by make_scenarios.py (`--table N` / `--all`); writes tools/emu/scenarios/EPn/*.json.
EP1's hand-made set stays in tools/emu/scenarios/*.json; `--table 1` writes a generated EP1 set to
tools/emu/scenarios/EP1/ as a check of the generator itself.

Every placement is found and then *verified with the harness* (the user's EPn.EXE under Unicorn):
  * geometry: the collision buffer after boot + warm-up (flippers drawn at rest), classified with
    the table's own wall LUT (extracted/tables/EPn/collision.json: wall_lut, 0 empty 1 wall
    2 wall_conditional 3 active 4 active_conditional 5 flipper; EP8 uses the LUT variant for the
    runtime value of its threshold variable), and the flipper rest outlines from the pointer tables
    that tools/emu/tables/EPn.json names;
  * each candidate is simulated in physics mode with probe capture on (ep_emu.capture_probes): the
    collision-buffer values under the probes of every response.  A candidate is kept only if its
    first response of ball 0 is the advertised kind (flipper colour, a kicker colour of the
    targeted cluster with a kick, or plain wall with the advertised contact direction k).
Search order is deterministic (seeded per table and kind), so re-running gives the same files.

Kinds (name: what is verified):
  plunger_launch, plunger_short     ball at the table's serve position, plunger held until the charge
                                    saturates (from the table's step/max/cmp) / 20 frames; the ball must
                                    leave the lane.  EP8 (no lane): ball 0 inactive, plunger held 10 frames,
                                    the table's launch code places the ball (launch_from_bottom).
  fall_<o>_held / _released         drop onto flipper outline <o> (left, right, upper_left, ...) held up /
                                    at rest: first contact is a flipper-colour probe.
  <o>_shot                          as _released, flipper pressed just before landing: a response with the
                                    moving-flipper contact flag set.
  bumper_hit_<i>, slingshot_hit_<i> kicker-colour clusters above / below y=200: first contact is that
                                    cluster, with a kick.
  flat_wall_hit, flat_ceiling_hit,  first contact is plain wall with k in {1,25} / 13 / {7,19,31,43}.
  diagonal_wall_hit
  multi_bounce_upper                fast ball in the upper playfield: at least 4 responses.
  upper_layer_loop                  (tables with level-1 wall colours) ball on layer 1: 3+ responses.
  long_600_scripted                 launch, flipper presses every 45 frames, drain and the table's own
                                    serve (on_drain=continue), second plunge; must not hang.
"""
import json
import math
import os
import random
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)
import ep_emu  # noqa: E402
import run_scenario  # noqa: E402

L, R, P = 1, 2, 4
EMPTY, WALL, WALLC, ACTIVE, ACTIVEC, FLIP = range(6)


def seq(*parts, total):
    out = []
    for m, n in parts:
        out += [m] * n
    return (out + [0] * total)[:total]


def ball(x, y, vx=0, vy=0, xf=0, yf=0, **kw):
    return dict(dict(x=int(x), y=int(y), xf=xf, yf=yf, vx=int(vx), vy=int(vy)), **kw)


class Table:
    """Geometry + a simulator for one table (one boot, snapshot reused)."""

    def __init__(self, n, log=print):
        self.n = n
        self.log = log
        self.emu = run_scenario.setup(self.scn(ball(0, 0, active=0)))
        self.A = self.emu.A
        e = self.emu
        self.buf = e.collision_buffer()
        cj = json.load(open(os.path.join(ROOT, 'extracted', 'tables', f'EP{n}', 'collision.json')))
        lut = np.array(cj['wall_lut'], dtype=np.uint8)
        self.lut_note = 'wall_lut'
        wt = self.A.get('wall_test') or {}
        if wt.get('lo_var') is not None:        # EP8: level-0 lower bound from a DS variable
            v = e.rb(e.ds, wt['lo_var'])
            key = f'level0_with_[{wt["lo_var"]:#x}]={v:#x}'
            if key in cj.get('wall_lut_variants', {}):
                lut[0] = np.array(cj['wall_lut_variants'][key], dtype=np.uint8)
                self.lut_note = key
            else:
                self.lut_note = f'wall_lut (runtime ds:{wt["lo_var"]:04x} = {v:#x})'
        self.lut = lut
        self.cls = [lut[lv][self.buf] for lv in (0, 1)]
        self.solid = [c != EMPTY for c in self.cls]
        ring = self.A['ds_vars']['ring']
        self.ring = []
        for k in range(1, 49):
            o = e.rw(e.ds, ring + 2 * k, signed=False)
            self.ring.append((o % 320, o // 320))
        self.drain_y = self.A.get('drain_y', 0x18F)
        self.outlines = self._outlines()

    # ------------------------------------------------------------------ geometry
    def scn(self, b, frames=0, inputs=(), **kw):
        return dict(dict(table=self.n, frames=frames, ball=b, inputs=list(inputs)), **kw)

    def _outlines(self):
        e, A = self.emu, self.A
        bottom = A['ds_vars'].get('pf_seg_bottom')
        rest = A.get('flipper_rest', 9)
        side_of = {g['angle']: g['side'] for g in A.get('flipper_groups', [])}
        out = []
        for i, o in enumerate(A.get('flipper_outlines', [])):
            half = 1 if o.get('seg_var') in (None, bottom) else 0
            ptr = e.rw(e.ds, o['table'] + 2 * rest, signed=False)
            cnt = e.rw(e.ds, ptr, signed=False)
            pts = []
            for j in range(cnt):
                off = e.rw(e.ds, ptr + 2 + 2 * j, signed=False)
                for extra in ([0] if o.get('second_row') is None else [0, o['second_row']]):
                    lin = half * 64000 + ((off + o['base'] + extra) & 0xFFFF)
                    pts.append((lin % 320, lin // 320))
            side = side_of.get(o['angle'], 'left' if np.mean([p[0] for p in pts]) < 160 else 'right')
            out.append(dict(index=i, side=side, mask=L if side == 'left' else R, pts=pts, colour=o['colour'],
                            ymean=float(np.mean([p[1] for p in pts]))))
        # names: the lowest outline per side is "left"/"right", others "upper_left", "upper_right2", ...
        for side in ('left', 'right'):
            os_ = sorted((o for o in out if o['side'] == side), key=lambda o: -o['ymean'])
            for j, o in enumerate(os_):
                o['name'] = side if j == 0 else ('upper_' + side + (str(j) if j > 1 else ''))
        return out

    def clear(self, x, y, level=0, margin=3):
        x0, y0, x1, y1 = x - margin, y - margin, x + 15 + margin, y + 14 + margin
        if x0 < 1 or y0 < 1 or x1 > 319 or y1 > 383:
            return False
        return not self.solid[level][y0:y1, x0:x1].any()

    def corridor_clear(self, x, y0, y1, level=0):
        """Box at column x clear for every y in [y0, y1] (a straight drop)."""
        lo, hi = min(y0, y1), max(y0, y1)
        if x < 1 or x + 15 > 319 or lo < 1:
            return False
        return not self.solid[level][lo:hi + 14, x:x + 15].any()

    # ------------------------------------------------------------------ simulation
    def simulate(self, scn, frames=None):
        """Run a scenario in physics mode with probe capture.  Returns (steps, error) where steps is
        a list of (frame, step, ball dict, [responses of ball 0]) and error is None / 'hang' / 'error'."""
        frames = scn['frames'] if frames is None else frames
        emu = run_scenario.setup(scn)
        emu.capture_probes = True
        inputs = scn.get('inputs', [])
        steps = []
        err = None
        try:
            for f in range(frames):
                if scn.get('on_drain', 'stop') == 'stop' and emu.dsw('ball_y') >= self.drain_y:
                    break
                emu.set_keys(inputs[f] if f < len(inputs) else 0)
                emu.main_loop_physics('physics')
                for s in range(3):
                    resp = emu.physics_step()
                    steps.append((f, s, emu.ball(0), [r for r in resp if r['ball'] == 0]))
        except ep_emu.PushoutLivelock:
            err = 'hang'
        except ep_emu.EmuError:
            err = 'error'
        finally:
            emu.capture_probes = False
        return steps, err

    @staticmethod
    def first_response(steps):
        for f, s, b, rs in steps:
            if rs:
                return f, s, b, rs[0]
        return None

    def probe_xy(self, r):
        x, y = r['xy']
        return [(x + self.ring[k - 1][0], y + self.ring[k - 1][1]) for k in r['hit_list']]

    def classes(self, r, level=0):
        return {int(self.lut[level][v]) for v in r['probe_colours']}


# ---------------------------------------------------------------------------------------------
# kinds


def plunger(t, S):
    A = t.A
    pl = A.get('plunger') or {}
    if A.get('lane') and A.get('serve') and pl.get('kind') == 'charge':
        sv = A['serve']
        adds = (pl['max'] // pl['step'] + 1) if pl['cmp'] == 'ja' else -(-pl['max'] // pl['step'])
        sat = adds * pl['step']
        hold = adds + 3
        for name, inputs, frames, what in (
                ('plunger_launch', seq((P, hold), total=300), 300,
                 f'plunger held {hold} frames (charge saturates at {sat} after {adds}: step {pl["step"]}, max {pl["max"]} '
                 f'{pl["cmp"]}), released'),
                ('plunger_short', seq((0, 5), (P, 20), total=240), 240,
                 f'weak plunge: held 20 frames (charge {min(20, adds) * pl["step"]})')):
            # the level the game serves on (EP2 cs:0AFB serves on layer 1; tools/emu/tables/EPn.json serve.layer)
            scn = t.scn(ball(sv['x'], sv['y'], **({'layer': sv['layer']} if sv.get('layer') else {})), frames, inputs)
            steps, err = t.simulate(scn)
            if err:
                t.log(f'  {name}: original {err}s; skipped')
                continue
            miny = min(b['y'] for _, _, b, _ in steps)
            S[name] = dict(scn, description=f'Ball at the serve position ({sv["x"]},{sv["y"]}); {what}. '
                                            f'Highest point reached y={miny}.')
        return 'lane'
    if pl.get('kind') == 'launch_flag' and A.get('launch'):
        la = A['launch']
        for name, inputs, frames in (('plunger_launch', seq((P, 10), total=300), 300),):
            scn = t.scn(ball(la['x'], min(la['y'], t.drain_y - 1), active=0), frames, inputs)
            steps, err = t.simulate(scn)
            if err:
                t.log(f'  {name}: original {err}s; skipped')
                continue
            act = next((f for f, s, b, _ in steps if b['active']), None)
            S[name] = dict(scn, description=f'No plunger lane: ball 0 starts inactive; plunger held 10 frames (the table '
                                            f'sets its launch flag to {pl["max"]}), released: the launch code places the '
                                            f'ball at ({la["x"]},{la["y"]}) with v=({la["vx"]},{la["vy"]}) (active from '
                                            f'frame {act}).')
        return 'launch'
    t.log('  plunger: no lane and no launch code found')
    return None


def flippers(t, S):
    made = []
    for o in t.outlines:
        pts = o['pts']
        xs = [p[0] for p in pts]
        x0, x1 = min(xs), max(xs)
        pivot, tip = (x0, x1) if o['side'] == 'left' else (x1, x0)
        found = None
        for frac in (0.35, 0.3, 0.4, 0.25, 0.45, 0.2, 0.5):
            cx = int(round(pivot + frac * (tip - pivot)))
            col = [p[1] for p in pts if abs(p[0] - cx) <= 3]
            if not col:
                continue
            ytop = min(col)
            bx = cx - 7
            for by in range(ytop - 14 - 30, ytop - 14 - 140, -4):
                if not t.clear(bx, by):
                    continue
                if not t.corridor_clear(bx, by, ytop - 14 - 3):
                    continue
                scn = t.scn(ball(bx, by), 150, [])
                steps, err = t.simulate(scn)
                fr = t.first_response(steps)
                if err or fr is None or t.lut[0][o['colour']] != FLIP:
                    continue
                if o['colour'] not in fr[3]['probe_colours']:
                    continue
                # contact must be on this outline
                if not set(t.probe_xy(fr[3])) & set(pts):
                    continue
                found = (bx, by, fr)
                break
            if found:
                break
        vx = vy = 0
        how = 'Free fall'
        if not found:
            # no straight drop (upper flippers tucked against walls): aim at the outline from nearby clear spots
            rnd = random.Random(1000 * t.n + 31 + o['index'])
            ocx, ocy = float(np.mean(xs)), float(np.mean([p[1] for p in pts]))
            pset = set(pts)
            for attempt in range(3000):
                a = rnd.uniform(0, 2 * math.pi)
                d = rnd.uniform(18, 70)
                bx, by = int(ocx + d * math.cos(a) - 7), int(ocy + d * math.sin(a) - 7)
                if not t.clear(bx, by, margin=1):
                    continue
                sp = rnd.choice((150, 250, 350))
                vx, vy = int(-sp * math.cos(a)), int(-sp * math.sin(a))
                steps, err = t.simulate(t.scn(ball(bx, by, vx, vy), 150, []), frames=60)
                fr = t.first_response(steps)
                if err or fr is None or o['colour'] not in fr[3]['probe_colours'] or not set(t.probe_xy(fr[3])) & pset:
                    continue
                found = (bx, by, fr)
                how = f'Ball aimed with v=({vx},{vy})'
                break
        if not found:
            t.log(f'  flipper {o["name"]}: no approach found')
            continue
        bx, by, fr = found
        nm, m = o['name'], o['mask']
        land = fr[0]
        S[f'fall_{nm}_flipper_released'] = dict(
            t.scn(ball(bx, by, vx, vy), 150, []),
            description=f'{how} from ({bx},{by}) onto the resting {nm} flipper (outline {o["index"]}), no input: '
                        f'first contact frame {land} step {fr[1]}, k={fr[3]["k"]}.')
        held = t.scn(ball(bx, by, vx, vy), 150, seq((m, 150), total=150))
        steps, err = t.simulate(held)
        if not err:
            f2 = t.first_response(steps)
            S[f'fall_{nm}_flipper_held'] = dict(
                held, description=f'{how} from ({bx},{by}) onto the {nm} flipper held up from frame 0'
                                  + (f': first contact frame {f2[0]}, k={f2[3]["k"]}' if f2 else '')
                                  # EP12 upper_right: the ball arrives while the flipper is still rising
                                  + ('; the flipper is still moving up at that contact (a moving-flipper hit, '
                                     'not a raised-flipper rest)' if f2 and f2[3].get('flipper_contact') else '') + '.')
        # shot: press just before the landing frame, so the flipper hits the ball while moving
        for d in (3, 2, 4, 1, 5, 6, 0):
            p = land - d
            if p < 0:
                continue
            scn = t.scn(ball(bx, by, vx, vy), 200, seq((0, p), (m, 20), total=200))
            steps, err = t.simulate(scn)
            if err:
                continue
            hit = next(((f, s, r) for f, s, b, rs in steps for r in rs if r['flipper_contact']), None)
            if hit:
                vy = min(b['vy'] for _, _, b, _ in steps)
                S[f'{nm}_flipper_shot'] = dict(
                    scn, description=f'{how} from ({bx},{by}); {nm} flipper pressed at frame {p} (the ball lands at '
                                     f'frame {land} at rest) and held 20 frames: moving-flipper contact at frame {hit[0]} '
                                     f'step {hit[1]} (k={hit[2]["k"]}, flipper_contact {hit[2]["flipper_contact"]}); '
                                     f'lowest vy {vy}.')
                break
        else:
            t.log(f'  flipper {nm}: no press frame gives a moving-flipper contact')
        made.append(nm)
    return made


def components(mask, dil=2):
    """8-connected components of mask after a square dilation by dil (merges rings of one bumper)."""
    h, w = mask.shape
    d = np.zeros_like(mask)
    ys, xs = np.nonzero(mask)
    for dy in range(-dil, dil + 1):
        for dx in range(-dil, dil + 1):
            yy, xx = np.clip(ys + dy, 0, h - 1), np.clip(xs + dx, 0, w - 1)
            d[yy, xx] = True
    lab = np.zeros((h, w), dtype=np.int32)
    comps = []
    for y0, x0 in zip(*np.nonzero(d)):
        if lab[y0, x0]:
            continue
        n = len(comps) + 1
        stack = [(y0, x0)]
        lab[y0, x0] = n
        pix = []
        while stack:
            y, x = stack.pop()
            if mask[y, x]:
                pix.append((x, y))
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < h and 0 <= xx < w and d[yy, xx] and not lab[yy, xx]:
                        lab[yy, xx] = n
                        stack.append((yy, xx))
        comps.append(pix)
    return [c for c in comps if len(c) >= 6]


def kickers(t, S):
    act = np.isin(t.cls[0], (ACTIVE, ACTIVEC))
    act[384:, :] = False                      # no collision test below y=384
    comps = components(act)
    comps.sort(key=lambda c: -len(c))
    made = {'bumper': 0, 'slingshot': 0}
    limit = {'bumper': 3, 'slingshot': 2}
    for pix in comps:
        xs, ys = [p[0] for p in pix], [p[1] for p in pix]
        cx, cy = float(np.mean(xs)), float(np.mean(ys))
        kind = 'bumper' if cy < 200 else 'slingshot'
        if made[kind] >= limit[kind]:
            continue
        rad = max(max(xs) - min(xs), max(ys) - min(ys)) / 2
        pset = set(pix)
        found = None
        for d in range(int(rad) + 12, int(rad) + 50, 4):
            for ai in range(16):
                a = 2 * math.pi * ((ai * 7) % 16) / 16   # scattered order
                bx = int(round(cx + d * math.cos(a) - 7))
                by = int(round(cy + d * math.sin(a) - 7))
                if not t.clear(bx, by):
                    continue
                for speed in (300, 420):
                    vx, vy = -speed * math.cos(a), -speed * math.sin(a)
                    scn = t.scn(ball(bx, by, vx, vy), 200, [])
                    steps, err = t.simulate(scn, frames=60)
                    fr = t.first_response(steps)
                    if err or fr is None or not fr[3]['kick']:
                        continue
                    if not (set(t.probe_xy(fr[3])) & pset):
                        continue
                    found = (bx, by, int(vx), int(vy), fr)
                    break
                if found:
                    break
            if found:
                break
        if not found:
            t.log(f'  {kind} at ({cx:.0f},{cy:.0f}) ({len(pix)} px): no approach found')
            continue
        bx, by, vx, vy, fr = found
        made[kind] += 1
        cols = sorted({t.buf[y, x] for x, y in pix})
        name = f'{kind}_hit' if made[kind] == 1 else f'{kind}_hit_{made[kind]}'
        steps, err = t.simulate(t.scn(ball(bx, by, vx, vy), 200, []))
        S[name] = dict(t.scn(ball(bx, by, vx, vy), 200 if not err else max(1, steps[-1][0]), []),
                       description=f'Ball at ({bx},{by}) with v=({vx},{vy}) into the kicker cluster around ({cx:.0f},{cy:.0f}) '
                                   f'(colours {" ".join(f"{c:02X}" for c in cols)}, {len(pix)} px): first contact frame '
                                   f'{fr[0]} step {fr[1]}, k={fr[3]["k"]}, kick {fr[3]["kick"]}.')
    return made


def walls(t, S):
    rnd = random.Random(1000 * t.n + 7)
    lane_x = (t.A.get('lane') or {}).get('min_x', 400)
    kinds = [
        ('flat_wall_hit', lambda: rnd.choice([(-300, 0), (300, 0)]), {1, 25}),
        ('flat_ceiling_hit', lambda: (0, -350), {13}),
        ('diagonal_wall_hit', lambda: rnd.choice([(250, -250), (-250, -250), (250, 250), (-250, 250)]), {7, 19, 31, 43}),
    ]
    for name, vel, ks in kinds:
        found = None
        for attempt in range(2500):
            bx, by = rnd.randrange(8, min(lane_x, 300) - 16), rnd.randrange(12, 360)
            if not t.clear(bx, by):
                continue
            vx, vy = vel()
            scn = t.scn(ball(bx, by, vx, vy), 120, [])
            steps, err = t.simulate(scn, frames=30)
            fr = t.first_response(steps)
            if err or fr is None or fr[3]['kick'] or fr[3]['flipper_contact']:
                continue
            if fr[3]['k'] not in ks or t.classes(fr[3]) - {WALL}:
                continue
            found = (bx, by, vx, vy, fr)
            break
        if not found:
            t.log(f'  {name}: not found in 2500 tries')
            continue
        bx, by, vx, vy, fr = found
        steps, err = t.simulate(t.scn(ball(bx, by, vx, vy), 120, []))
        frames = 120 if not err else steps[-1][0]
        S[name] = dict(t.scn(ball(bx, by, vx, vy), frames, []),
                       description=f'Ball at ({bx},{by}) with v=({vx},{vy}): first contact frame {fr[0]} step {fr[1]} is plain '
                                   f'wall (colours {" ".join(f"{c:02X}" for c in sorted(set(fr[3]["probe_colours"])))}), '
                                   f'k={fr[3]["k"]}, no kicker' + (' (the original hangs later; frames cut)' if err else '') + '.')

    # fast ball in the upper playfield: the best (most responses) of the first 12 valid candidates
    best, tried = None, 0
    for attempt in range(400):
        bx, by = rnd.randrange(20, min(lane_x, 300) - 20), rnd.randrange(30, 170)
        if not t.clear(bx, by):
            continue
        scn = t.scn(ball(bx, by, 250, -350), 300, [])
        steps, err = t.simulate(scn)
        n = sum(len(rs) for _, _, _, rs in steps)
        if err or n < 4:
            continue
        tried += 1
        if best is None or n > best[0]:
            best = (n, bx, by, scn, len(steps) // 3)
        if tried >= 12:
            break
    if best:
        n, bx, by, scn, nf = best
        S['multi_bounce_upper'] = dict(scn, description=f'Fast ball in the upper playfield, ({bx},{by}) with (250,-350): '
                                                        f'{n} responses in {nf} frames.')
    else:
        t.log('  multi_bounce_upper: not found')


def upper_layer(t, S):
    wt = t.A.get('wall_test') or {}
    n1 = int(((t.buf >= wt.get('level1_lo', 256)) & (t.buf <= wt.get('level1_hi', -1))).sum())
    if n1 < 200:
        t.log(f'  upper_layer_loop: only {n1} level-1 wall pixels; skipped')
        return
    rnd = random.Random(1000 * t.n + 11)
    best, tried = None, 0
    for attempt in range(1500):
        bx, by = rnd.randrange(10, 290), rnd.randrange(20, 300)
        if not t.clear(bx, by, level=1):
            continue
        # start close to level-1 walls
        if not t.solid[1][max(0, by - 20):by + 34, max(0, bx - 20):bx + 35].any():
            continue
        vx, vy = rnd.choice([(0, -450), (200, -400), (-200, -400)])
        scn = t.scn(ball(bx, by, vx, vy, layer=1), 250, [])
        steps, err = t.simulate(scn)
        n = sum(len(rs) for _, _, _, rs in steps)
        if err or n < 3:
            continue
        tried += 1
        if best is None or n > best[0]:
            best = (n, bx, by, vx, vy, scn, len(steps) // 3)
        if tried >= 12:
            break
    if best:
        n, bx, by, vx, vy, scn, nf = best
        S['upper_layer_loop'] = dict(scn, description=f'Ball on the upper level (layer 1) at ({bx},{by}) with ({vx},{vy}): only '
                                                      f'level-1 colours {wt["level1_lo"]:02X}..{wt["level1_hi"]:02X} collide; '
                                                      f'{n} responses in {nf} frames.')
        return
    t.log('  upper_layer_loop: not found')


def long_run(t, S, launch_kind):
    A = t.A
    pl = A.get('plunger') or {}
    if launch_kind == 'lane':
        adds = (pl['max'] // pl['step'] + 1) if pl['cmp'] == 'ja' else -(-pl['max'] // pl['step'])
        start, hold = A['serve'], adds - 4
        b0 = ball(start['x'], start['y'], **({'layer': start['layer']} if start.get('layer') else {}))
    elif launch_kind == 'launch':
        la = A['launch']
        hold = 10
        b0 = ball(la['x'], min(la['y'], t.drain_y - 1), active=0)
    else:
        return
    for phase in (0, 7, 15, 22, 30):
        m = [0] * 600
        for f in range(hold):
            m[f] |= P
        for st in range(120 + phase, 600, 45):
            side = [L, R, L | R][((st - phase) // 45) % 3]
            for f in range(st, min(600, st + 12)):
                m[f] |= side
        for f in range(330, 330 + max(hold, 10)):
            m[f] |= P
        scn = t.scn(b0, 600, m, on_drain='continue')
        steps, err = t.simulate(scn)
        if err:
            continue
        n = sum(len(rs) for _, _, _, rs in steps)
        drains = sum(1 for i in range(1, len(steps)) if steps[i][2]['y'] < steps[i - 1][2]['y'] - 30)
        S['long_600_scripted'] = dict(scn, description=f'600 frames: launch (plunger {hold} frames), flipper presses every 45 '
                                                       f'frames from frame {120 + phase}, the table\'s own drain/serve '
                                                       f'(on_drain=continue), second plunge at frames 330..; '
                                                       f'{n} responses, {drains} large upward jumps (serve/launch).')
        return
    t.log('  long_600_scripted: the original hangs for every flipper phase tried')


def generate(n, log=print):
    t = Table(n, log)
    log(f'EP{n}: geometry {t.lut_note}; outlines {[o["name"] for o in t.outlines]}')
    S = {}
    lk = plunger(t, S)
    flippers(t, S)
    kickers(t, S)
    walls(t, S)
    upper_layer(t, S)
    long_run(t, S, lk)
    return S, t
