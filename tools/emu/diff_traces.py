#!/usr/bin/env python3
"""Differential test: the ORIGINAL table code (Unicorn harness) vs the Swift port, per scenario.

Every scenario is run through
  * tools/emu/run_scenario.py (the original EPn.EXE machine code; ground truth), in-process, and
  * the Swift port: `EpicPinball --trace SCENARIO --out TRACE --table N` (app/.build/debug/EpicPinball),
and the two JSONL traces are compared record by record (one record per physics step). For each
scenario the first divergent record is reported with its frame, step and every field that
differs (original value, port value), plus a few records of context.

Usage (from the project root):
  .venv/bin/python tools/emu/diff_traces.py                       # tools/emu/scenarios/ + scenarios_pathological/
  .venv/bin/python tools/emu/diff_traces.py --table 4             # EP4: tools/emu/scenarios/EP4/ (make_scenarios.py --table 4)
  .venv/bin/python tools/emu/diff_traces.py tools/emu/scenarios/bumper_hit.json [more ...]
  .venv/bin/python tools/emu/diff_traces.py --mode rules          # override every scenario's mode
  .venv/bin/python tools/emu/diff_traces.py --modes physics,rules # run each scenario in several modes
  .venv/bin/python tools/emu/diff_traces.py --build               # `swift build` the port first
  .venv/bin/python tools/emu/diff_traces.py --save-golden         # also store the original's traces in
                                                                  # scratch/diff/golden/ (read by swift test;
                                                                  # a hang/fault adds a last {"orig_error":..} line)
  .venv/bin/python tools/emu/diff_traces.py --a X.jsonl --b Y.jsonl   # just diff two existing traces

Options: --table N (default 1; also overrides the scenarios' own "table"), --contract-only (ignore the
optional `extra` diagnostics), --context N, --json FILE (machine-readable summary), --out-dir DIR (traces,
default scratch/diff/traces, scratch/diff/traces/EPn for n >= 2), --bin PATH.

Outcomes per scenario:
  EXACT          every record identical (all contract fields and, unless --contract-only, `extra`)
  DIVERGES       first divergent record reported; exit status 1
  LENGTH         identical records but different counts (e.g. drain stop at a different frame)
  ORIG_HANG      the original never returns from physics_step in some step (push-out loop without an
                 iteration cap, cs:1826..18FA).  Passes only if all earlier records are identical AND the
                 port's record for that step shows its loop guard tripping (extra.loop_guard).
  ORIG_FAULT     the original raises a divide error (#DE) in some step.  Passes only if earlier records are
                 identical AND the port's record for that step shows extra.divide_faults.
  RULES_GAP      (rules/full mode only) diverges, and the original dispatched a rule handler the port does
                 not run (not in engine.json sensors nor rules.json handlers, and not a `jmp exit` no-op) within
                 64 frames before the
                 divergence; the latest such handler is named, plus the original's event_lockout/cooldown at
                 that frame (a lockout set by a rule blocks later sensors).  This is a heuristic attribution:
                 it still counts as a failure, and a real port bug inside that window would be mislabelled,
                 so check the named handler (physics mode has no such ambiguity).
  HARNESS_ERROR  anything else the harness raised; exit status 1
Port-only diagnostic keys (loop_guard, divide_faults) are never compared as ordinary fields.
Exit status 0 iff every scenario passes.
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)

CONTRACT = ('frame', 'step', 'collided', 'k', 'left_flipper_pos', 'right_flipper_pos')
BALL = ('x', 'y', 'xf', 'yf', 'vx', 'vy')
PORT_ONLY = ('loop_guard', 'divide_faults')
DEFAULT_BIN = os.path.join(ROOT, 'app', '.build', 'debug', 'EpicPinball')


def flatten(r, use_extra=True):
    """Record -> ordered {field: value}; contract fields first, then ball, then extra."""
    d = {k: r.get(k) for k in CONTRACT}
    for k in BALL:
        d['ball.' + k] = r.get('ball', {}).get(k)
    for k in sorted(r.get('ball', {})):
        if k not in BALL:
            d['ball.' + k] = r['ball'][k]
    if use_extra:
        for k, v in r.get('extra', {}).items():
            if k not in PORT_ONLY:
                d['extra.' + k] = v
    return d


def compare(a, b, use_extra=True):
    """Return (index of first differing record or None, {field: (a, b)})."""
    for i in range(min(len(a), len(b))):
        fa, fb = flatten(a[i], use_extra), flatten(b[i], use_extra)
        if fa != fb:
            keys = list(fa) + [k for k in fb if k not in fa]
            return i, {k: (fa.get(k), fb.get(k)) for k in keys if fa.get(k) != fb.get(k)}
    return None, {}


def fmt_rec(r):
    b = r.get('ball', {})
    e = r.get('extra', {})
    s = (f"f{r.get('frame')}.{r.get('step')} x={b.get('x')} y={b.get('y')} xf={b.get('xf')} yf={b.get('yf')} "
         f"vx={b.get('vx')} vy={b.get('vy')} col={int(bool(r.get('collided')))} k={r.get('k')} "
         f"L={r.get('left_flipper_pos')} R={r.get('right_flipper_pos')}")
    if e:
        s += f" lay={e.get('layer')} resp={e.get('responses')} k_all={e.get('k_all')}"
        for k in ('flipper_contact', 'kick') + PORT_ONLY:
            if e.get(k):
                s += f' {k}={e[k]}'
    return s


def read_jsonl(path):
    with open(path) as f:
        return [json.loads(l) for l in f if l.strip()]


def write_jsonl(path, recs):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, 'w') as f:
        for r in recs:
            f.write(json.dumps(r, separators=(',', ':')) + '\n')


def run_port(binary, scn_path, out_path, table=1):
    r = subprocess.run([binary, '--trace', scn_path, '--out', out_path, '--table', str(table)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f'port failed ({r.returncode}): {r.stderr.strip()[-400:]}')
    return read_jsonl(out_path)


def diff_one(a, b, use_extra, context, orig_error=None):
    """Compare traces; returns a result dict (status, ok, message lines)."""
    lines = []
    i, fields = compare(a, b, use_extra)
    res = dict(records_orig=len(a), records_port=len(b), first_diff=None, fields=None)
    if orig_error is not None:
        kind, frame, step = orig_error
        n = len(a)
        res.update(status=kind, frame=frame, step=step)
        if i is not None:
            res.update(ok=False, first_diff=i, fields=fields)
            lines.append(f'{kind}: the original fails at frame {frame} step {step}, but the traces already '
                         f'diverge at record {i}')
        elif len(b) <= n:
            res.update(ok=False)
            lines.append(f'{kind}: the original fails at frame {frame} step {step} (record {n}); the port trace '
                         f'ends after {len(b)} records')
        else:
            key = 'loop_guard' if kind == 'ORIG_HANG' else 'divide_faults'
            flagged = bool(b[n].get('extra', {}).get(key))
            res.update(ok=flagged)
            lines.append(f'{kind}: {n} records identical; the original ' +
                         ('never returns from physics_step' if kind == 'ORIG_HANG' else 'raises a divide error') +
                         f' at frame {frame} step {step}; port record {n} ' +
                         (f'flags extra.{key}={b[n]["extra"][key]} (same step)' if flagged else f'does NOT flag extra.{key}'))
        if not res['ok'] and i is None:
            return res, lines
    if i is None and orig_error is None:
        if len(a) == len(b):
            res.update(status='EXACT', ok=True)
            lines.append(f'EXACT: {len(a)} records')
        else:
            res.update(status='LENGTH', ok=False)
            lines.append(f'LENGTH: first {min(len(a), len(b))} records identical, but original has {len(a)} '
                         f'records and port {len(b)}')
        return res, lines
    if i is None:
        return res, lines
    if orig_error is None:
        res.update(status='DIVERGES', ok=False, first_diff=i, fields=fields)
    r = a[i]
    lines.append(f'DIVERGES at record {i} (frame {r.get("frame")} step {r.get("step")})')
    lines.append('  fields (original vs port):')
    for k, (va, vb) in fields.items():
        lines.append(f'    {k}: {va!r} vs {vb!r}')
    for j in range(max(0, i - context), min(max(len(a), len(b)), i + 2)):
        mark = '>>' if j == i else '  '
        if j < len(a):
            lines.append(f'  {mark} orig {j:5d} {fmt_rec(a[j])}')
        if j < len(b):
            lines.append(f'  {mark} port {j:5d} {fmt_rec(b[j])}')
    return res, lines


def load_ported_sensors(table=1):
    """(ported, skipped, exit_ip) from the port's engine.json: which (layer, colour) handlers the port runs."""
    path = os.path.join(ROOT, 'extracted', 'tables', f'EP{table}', 'engine.json')
    try:
        sens = json.load(open(path))['sensors']
    except (OSError, KeyError, ValueError):
        return set(), {}, None
    ported = {(lv, int(c)) for lv, level in enumerate(sens.get('levels', [])) for c in level}
    # With rules.json the port runs every lifted handler (app/Sources/PinballCore/Rules): only colours
    # without a lifted handler remain candidates for a rules gap.
    try:
        rj = json.load(open(os.path.join(ROOT, 'extracted', 'tables', f'EP{table}', 'rules.json')))
        for h in rj.get('handlers', {}).values():
            for c in h.get('colours', []):
                ported.update({(0, int(c, 16)), (1, int(c, 16))})
    except (OSError, ValueError):
        pass
    skipped = {tuple(int(x) for x in k.split(':')): v for k, v in sens.get('skipped', {}).items()}
    exit_ip = int(sens['exit_ip'], 16) if isinstance(sens.get('exit_ip'), str) else sens.get('exit_ip')
    return ported, skipped, exit_ip


def explain_rules(res, a, sensor_log, emu, frame_state=None, window=64, table=1):
    """For a rules/full-mode divergence: the last rule handler the ORIGINAL dispatched (within `window`
    frames before the divergent record) that the port does not run.  Handlers whose code is a single
    `jmp exit` are no-ops and are ignored."""
    ported, skipped, exit_ip = load_ported_sensors(table)
    frame = a[res['first_diff']]['frame'] if res['first_diff'] < len(a) else None
    if frame is None:
        return None
    cands = []
    for f, events in sensor_log:
        if not (frame - window <= f <= frame):
            continue
        for colour, layer, ip in events:
            if (layer, colour) in ported or ip is None:
                continue
            op = emu.rb(emu.cs, ip)
            if op == 0xE9 and exit_ip is not None:
                rel = emu.rw(emu.cs, ip + 1, signed=False)
                if (ip + 3 + rel) & 0xFFFF == exit_ip:
                    continue            # no-op handler
            cands.append((f, colour, layer, ip, skipped.get((layer, colour), 'not exported')))
    if not cands:
        return None
    f, colour, layer, ip, why = cands[-1]
    msg = (f'unported rule handler 0x{colour:02X} (layer {layer}, cs:{ip:04X}; exporter: {why}) dispatched by the '
           f'original at frame {f}' + (f' (+{len(cands) - 1} earlier)' if len(cands) > 1 else ''))
    if frame_state and frame < len(frame_state):
        st = frame_state[frame]
        if st['event_lockout'] or st['event_cooldown']:
            # A lockout set by an unported handler blocks later (ported) sensors such as F1/FD.
            msg += (f'; at frame {frame} the original has event_lockout={st["event_lockout"]}, '
                    f'event_cooldown={st["event_cooldown"]}')
    return msg


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument('scenarios', nargs='*', help='scenario files or directories (default tools/emu/scenarios '
                    '+ scenarios_pathological for table 1, tools/emu/scenarios/EPn for table n)')
    ap.add_argument('--table', type=int, default=None, choices=range(1, 14), metavar='N',
                    help='table 1..13 (default 1); overrides each scenario\'s "table"')
    ap.add_argument('--mode', choices=['physics', 'rules', 'full'], help='override the scenarios\' mode')
    ap.add_argument('--modes', help='comma list of modes; each scenario is run once per mode')
    ap.add_argument('--bin', default=DEFAULT_BIN, help='Swift EpicPinball binary')
    ap.add_argument('--build', action='store_true', help='run `swift build` in app/ first')
    ap.add_argument('--out-dir', default=None, help='default scratch/diff/traces (EPn/ below it for n >= 2)')
    ap.add_argument('--save-golden', action='store_true',
                    help='write the original\'s traces to scratch/diff/golden/<name>.jsonl (scenario mode only)')
    ap.add_argument('--golden-dir', default=None, help='default scratch/diff/golden (EPn/ below it for n >= 2)')
    ap.add_argument('--contract-only', action='store_true', help='ignore the extra diagnostics')
    ap.add_argument('--context', type=int, default=3)
    ap.add_argument('--json', help='write a JSON summary here')
    ap.add_argument('--a', help='diff two existing traces: original trace')
    ap.add_argument('--b', help='diff two existing traces: port trace')
    ap.add_argument('-q', '--quiet', action='store_true', help='one line per scenario')
    args = ap.parse_args()
    use_extra = not args.contract_only

    if args.a or args.b:
        res, lines = diff_one(read_jsonl(args.a), read_jsonl(args.b), use_extra, args.context)
        print('\n'.join(lines))
        sys.exit(0 if res['ok'] else 1)

    if args.build or not os.path.exists(args.bin):
        print('building the Swift port ...', file=sys.stderr)
        subprocess.run(['swift', 'build'], cwd=os.path.join(ROOT, 'app'), check=True)

    import ep_emu
    import run_scenario

    table = args.table or 1
    sub = [] if table == 1 else [f'EP{table}']
    if args.out_dir is None:
        args.out_dir = os.path.join(ROOT, 'scratch', 'diff', 'traces', *sub)
    if args.golden_dir is None:
        args.golden_dir = os.path.join(ROOT, 'scratch', 'diff', 'golden', *sub)
    default_dirs = ([os.path.join(HERE, 'scenarios'), os.path.join(HERE, 'scenarios_pathological')] if table == 1
                    else [os.path.join(HERE, 'scenarios', f'EP{table}')])
    if table != 1:
        # hand-made / directed sets live in subdirectories (make_scenarios.py --table N rewrites EPn/*.json)
        default_dirs += [d for d in (os.path.join(HERE, 'scenarios', f'EP{table}', sub) for sub in ('hand', 'extra'))
                         if os.path.isdir(d)]
    paths = []
    for p in args.scenarios or default_dirs:
        paths += sorted(glob.glob(os.path.join(p, '*.json'))) if os.path.isdir(p) else [p]
    modes = args.modes.split(',') if args.modes else [args.mode]

    results = []
    t0 = time.time()
    for path in paths:
        scn = json.load(open(path))
        if args.table is not None and scn.get('table', 1) != args.table:
            scn = dict(scn, table=args.table)
        base = os.path.splitext(os.path.basename(path))[0]
        for mode in modes:
            s = dict(scn)
            name = base
            if mode and mode != s.get('mode', 'physics'):
                s['mode'] = mode
                name = f'{base}.{mode}'
            eff_mode = s.get('mode', 'physics')
            scn_path = path
            if s != json.load(open(path)):
                scn_path = os.path.join(args.out_dir, f'{name}.scenario.json')
                os.makedirs(args.out_dir, exist_ok=True)
                json.dump(s, open(scn_path, 'w'))
            orig_error = None
            sensor_log, frame_state = [], []
            try:
                a = run_scenario.run(s, sensor_log=sensor_log, frame_state=frame_state)
            except ep_emu.EmuError as e:
                a = getattr(e, 'records', [])
                if isinstance(e, ep_emu.PushoutLivelock):
                    orig_error = ('ORIG_HANG', getattr(e, 'frame', None), getattr(e, 'step', None))
                elif 'divide error' in str(e):
                    orig_error = ('ORIG_FAULT', getattr(e, 'frame', None), getattr(e, 'step', None))
                else:
                    results.append(dict(name=name, mode=eff_mode, status='HARNESS_ERROR', ok=False, error=str(e)))
                    print(f'{name:40s} HARNESS_ERROR: {e}')
                    continue
            write_jsonl(os.path.join(args.out_dir, f'{name}.orig.jsonl'), a)
            if args.save_golden and s == scn:
                tail = [] if orig_error is None else [dict(orig_error='hang' if orig_error[0] == 'ORIG_HANG' else 'fault',
                                                           frame=orig_error[1], step=orig_error[2])]
                write_jsonl(os.path.join(args.golden_dir, f'{base}.jsonl'), a + tail)
            try:
                b = run_port(args.bin, scn_path, os.path.join(args.out_dir, f'{name}.port.jsonl'), s.get('table', 1))
            except RuntimeError as e:
                results.append(dict(name=name, mode=eff_mode, status='PORT_ERROR', ok=False, error=str(e)))
                print(f'{name:40s} PORT_ERROR: {e}')
                continue
            res, lines = diff_one(a, b, use_extra, args.context, orig_error)
            res.update(name=name, mode=eff_mode, table=s.get('table', 1))
            if res['status'] == 'DIVERGES' and eff_mode != 'physics':
                why = explain_rules(res, a, sensor_log, run_scenario._BASE[s.get('table', 1)][0], frame_state,
                                    table=s.get('table', 1))
                if why:
                    res.update(status='RULES_GAP', explanation=why)
                    lines[0] = lines[0].replace('DIVERGES', 'RULES_GAP', 1)
                    lines.insert(1, f'  explained: {why}')
            results.append(res)
            print(f'{name:40s} {lines[0]}')
            for l in lines[1:]:
                if not args.quiet or l.startswith('  explained'):
                    print(l)

    npass = sum(1 for r in results if r['ok'])
    print(f'\n{npass}/{len(results)} passed ({time.time() - t0:.1f} s); '
          + ', '.join(f'{st}={sum(1 for r in results if r["status"] == st)}'
                      for st in sorted({r['status'] for r in results})))
    if args.json:
        with open(args.json, 'w') as f:
            json.dump(results, f, indent=1, default=str)
    sys.exit(0 if npass == len(results) else 1)


if __name__ == '__main__':
    main()
