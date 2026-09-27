#!/usr/bin/env python3
"""Run a physics scenario on the ORIGINAL table code (EPn.EXE under Unicorn) and write a JSONL trace.

Usage:
  .venv/bin/python tools/emu/run_scenario.py SCENARIO.json [-o OUT.jsonl] [--mode physics|rules|full]
                                             [--frames N] [--quiet]
  .venv/bin/python tools/emu/run_scenario.py --batch OUT_DIR SCENARIO.json|DIR ...   (one boot; used by swift test)

Scenario (see tools/emu/trace_schema.json, "scenario"):
  {"table": 1, "frames": N,                                                 (table 1..13)
   "ball": {"x":..,"y":..,"xf":0,"yf":0,"vx":..,"vy":.., "layer":0, "active":1},   (active optional, default 1)
   "balls": [{"x":.., "y":.., ...}, ...],                                  (optional, slots 1..4 in order, as the port reads it)
   "extra_balls": [{"slot": 2, "x":.., "y":.., ...}],                        (optional, other slots by number)
   "inputs": [mask per frame; 1=left flipper, 2=right flipper, 4=plunger, 8=nudge Z, 16=nudge /, 32=Space],
                                                                             (missing frames = 0)
   "ds_pokes": [[offset, value, width], ...]   raw data-segment writes after "pokes" (optional)
   "players", "balls_per_game": game options as DS bytes (optional)
   "params": {"gravity": 4, ...} or [10 values / null],                      (optional)
   "on_drain": "stop" | "continue",                                          (optional, default "stop")
   "mode": "physics" | "rules" | "full"}                                     (optional, default "physics")

Output: one JSON object per physics step (3 per frame), in execution order.
Frame f = the main-loop work for frame f (plunger, gravity, ...) followed by 3 physics
steps (cs:1724).  See docs/formats/emulation.md for why this is the original order.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ep_emu  # noqa: E402

DRAIN_Y = 0x18F     # cs:0A3E
WARMUP_STEPS = 12   # flippers start at angle 2 with no outline drawn; 7 steps bring them to rest (9)


_BASE = {}   # table -> (emu, snapshot after boot + warm-up); reused within one process


def setup(scn, mode=None):
    table = scn.get('table', 1)
    if table in _BASE:
        emu, snap = _BASE[table]
        emu.restore(snap)
    else:
        emu = ep_emu.EpEmu(table=table)
        emu.reset_play_state()
        # Let the flippers fall from their boot angle (2) to rest (9) so the rest outline is in
        # the collision buffer, exactly as the first frames of a real game do.  No ball is active.
        for _ in range(WARMUP_STEPS):
            emu.physics_step()
        _BASE[table] = (emu, emu.snapshot())
    if scn.get('params') is not None:
        emu.set_params(scn['params'])
    b = dict(scn['ball'])
    emu.set_ball(0, x=b['x'], y=b['y'], xf=b.get('xf', 0), yf=b.get('yf', 0),
                 vx=b.get('vx', 0), vy=b.get('vy', 0), layer=b.get('layer', 0), active=b.get('active', 1))
    for i, eb in enumerate(scn.get('balls', [])[:4]):   # the Swift port's form: slots 1..4 in order
        emu.set_ball(i + 1, x=eb['x'], y=eb['y'], xf=eb.get('xf', 0), yf=eb.get('yf', 0),
                     vx=eb.get('vx', 0), vy=eb.get('vy', 0), layer=eb.get('layer', 0), active=eb.get('active', 1))
    for eb in scn.get('extra_balls', []):          # e.g. EP3's captive ball in slot 2
        emu.set_ball(eb['slot'], x=eb['x'], y=eb['y'], xf=eb.get('xf', 0), yf=eb.get('yf', 0),
                     vx=eb.get('vx', 0), vy=eb.get('vy', 0), layer=eb.get('layer', 0), active=eb.get('active', 1))
    if scn.get('players') is not None or scn.get('balls_per_game') is not None:
        eot = emu.end_of_turn_vars()        # the options PINBALL.EXE passes, as DS bytes
        if eot is None:
            raise ep_emu.EmuError('players/balls_per_game: end-of-turn counters not found in this table')
        if scn.get('players') is not None:
            emu.wb(emu.ds, eot['player_count'], int(scn['players']))
        if scn.get('balls_per_game') is not None:
            emu.wb(emu.ds, eot['balls_per_game'], int(scn['balls_per_game']))
    for k, v in scn.get('pokes', {}).items():      # raw DS pokes, e.g. {"kicker_cooldown": 0}
        if k in ('extra_gravity', 'gravity_extra'):  # aliases (Swift port / engine.md names)
            k = 'extra_gravity_timer'
        if k in ('plunger_charge', 'extra_gravity_timer'):
            emu.set_dsw(k, v)
        else:
            emu.set_dsb(k, v)
    for off, v, w in scn.get('ds_pokes', []):    # raw DS offsets (rule state without a name), last
        off = int(off, 16) if isinstance(off, str) else int(off)
        (emu.ww if int(w) == 2 else emu.wb)(emu.ds, off, int(v))
    return emu


def run(scn, mode=None, frames=None, sensor_log=None, frame_state=None):
    """Returns the trace records.  sensor_log (optional list) receives (frame, [(colour, layer,
    handler_ip), ...]) for every frame in which the original dispatched rule handlers (rules/full mode).
    frame_state (optional list) receives {event_lockout, event_cooldown} after each frame's main-loop work."""
    mode = mode or scn.get('mode', 'physics')
    frames = frames if frames is not None else scn['frames']
    on_drain = scn.get('on_drain', 'stop')
    inputs = scn.get('inputs', [])
    emu = setup(scn, mode)
    drain_y = emu.A.get('drain_y', DRAIN_Y)
    out = []
    for f in range(frames):
        if on_drain == 'stop' and emu.dsw('ball_y') >= drain_y:
            break
        emu.set_keys(inputs[f] if f < len(inputs) else 0)
        emu.sensor_log = []
        if mode == 'full':
            try:
                emu.main_loop_full()
            except ep_emu.EmuError as e:
                if emu.code_intact():
                    raise
                err = ep_emu.CodeOverwritten(f'frame {f}: the main loop overwrote the code segment and then failed ({e})')
                err.records, err.frame, err.step = out, f, 0
                raise err from e
            if not emu.code_intact():
                # render code (save/restore_ball_bg) overran into the code segment: the next physics_step
                # would run corrupted code (EP10 upper_layer_loop: ball x = -1)
                err = ep_emu.CodeOverwritten(f'frame {f}: the main loop overwrote the code segment')
                err.records, err.frame, err.step = out, f, 0
                raise err
        else:
            emu.main_loop_physics(mode)
        if sensor_log is not None and emu.sensor_log:
            sensor_log.append((f, list(emu.sensor_log)))
        if frame_state is not None:
            frame_state.append(dict(event_lockout=emu.dsb('event_lockout') if emu.has('event_lockout') else 0,
                                    event_cooldown=emu.dsb('event_cooldown') if emu.has('event_cooldown') else 0))
        for s in range(3):
            try:
                resp = emu.physics_step()
            except ep_emu.EmuError as e:
                # The original hangs (push-out livelock) or faults (divide error) in this step.
                # Keep what was traced so far so callers can compare up to the failure.
                e.records, e.frame, e.step = out, f, s
                raise
            b = emu.ball(0)
            mine = [r for r in resp if r['ball'] == 0]
            first = [r for r in mine if r['first']]
            collided = emu.dsb('collided') == 1
            rec = dict(
                frame=f, step=s,
                ball=dict(x=b['x'], y=b['y'], xf=b['xf'], yf=b['yf'], vx=b['vx'], vy=b['vy']),
                collided=collided,
                k=first[0]['k'] if first else None,
                left_flipper_pos=emu.dsw('lflip_angle'),
                right_flipper_pos=emu.dsw('rflip_angle'),
                extra=dict(
                    layer=b['layer'], active=b['active'],
                    responses=len(mine),
                    k_all=[r['k'] for r in mine],
                    flipper_contact=first[0]['flipper_contact'] if first else 0,
                    kick=first[0]['kick'] if first else 0,
                    lflip_moving=emu.dsb('lflip_moving'), rflip_moving=emu.dsb('rflip_moving'),
                    plunger_charge=emu.dsw('plunger_charge') if emu.has('plunger_charge') else 0,
                ),
            )
            out.append(rec)
    if not emu.code_intact():
        raise ep_emu.EmuError('the game code segment was overwritten during the run; trace is invalid')
    return out


def batch(paths, out_dir):
    """Run many scenarios in one process (one boot).  Writes OUT_DIR/<name>.jsonl for each; when the
    original hangs or faults, the records up to that step are written and the last line is
    {"orig_error": "hang"|"fault", "frame": f, "step": s, "message": ...}."""
    os.makedirs(out_dir, exist_ok=True)
    for p in paths:
        scn = json.load(open(p))
        name = os.path.splitext(os.path.basename(p))[0]
        tail = None
        try:
            recs = run(scn)
        except ep_emu.EmuError as e:
            if not hasattr(e, 'records'):
                raise
            recs = e.records
            kind = 'hang' if isinstance(e, ep_emu.PushoutLivelock) else 'fault'
            tail = dict(orig_error=kind, frame=e.frame, step=e.step, message=str(e)[:300])
        with open(os.path.join(out_dir, name + '.jsonl'), 'w') as f:
            for r in recs + ([tail] if tail else []):
                f.write(json.dumps(r, separators=(',', ':')) + '\n')
        print(f'{name}: {len(recs)} records' + (f' (original {tail["orig_error"]}s at frame {tail["frame"]} '
                                                 f'step {tail["step"]})' if tail else ''))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--batch':
        # run_scenario.py --batch OUT_DIR SCENARIO.json|DIR ...
        import glob
        paths = []
        for p in sys.argv[3:]:
            paths += sorted(glob.glob(os.path.join(p, '*.json'))) if os.path.isdir(p) else [p]
        batch(paths, sys.argv[2])
        return
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('scenario')
    ap.add_argument('-o', '--out', help='output .jsonl (default: stdout)')
    ap.add_argument('--mode', choices=['physics', 'rules', 'full'])
    ap.add_argument('--frames', type=int)
    ap.add_argument('--quiet', action='store_true')
    a = ap.parse_args()
    scn = json.load(open(a.scenario))
    recs = run(scn, a.mode, a.frames)
    text = ''.join(json.dumps(r, separators=(',', ':')) + '\n' for r in recs)
    if a.out:
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        open(a.out, 'w').write(text)
        if not a.quiet:
            last = recs[-1] if recs else None
            print(f'{a.scenario}: {len(recs)} steps -> {a.out}; last {last and last["ball"]}', file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == '__main__':
    main()
